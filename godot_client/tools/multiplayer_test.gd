extends SceneTree
## Server authority, replication and exploit resistance.
##
## Every test here is written as an attack: "a client does the bad thing, the
## server must refuse it and the world must be unchanged." A test that only
## checks the happy path proves nothing about a networked game, because the
## happy path is what an honest client already does.

var _fails := 0
var _applied := 0


func _init() -> void:
	_test_join_required()
	_test_schema_rejects_junk()
	_test_unknown_op_rejected()
	_test_rate_limit()
	_test_reach_limit()
	_test_ownership()
	_test_economy_is_server_side()
	_test_movement_clamp()
	_test_revoke_midflight()
	_test_accepted_command_applies_once()
	_test_replication_filters_by_distance()
	_test_audit_log()
	_finish()


func _eq(got: Variant, want: Variant, what: String) -> void:
	if got == want:
		print("  ok   %s == %s" % [what, str(want)])
	else:
		_fails += 1
		print("  FAIL %s: got %s, want %s" % [what, str(got), str(want)])


func _finish() -> void:
	print("RESULT: %s (%d failures)" % ["PASS" if _fails == 0 else "FAIL", _fails])
	quit(0 if _fails == 0 else 1)


## The stand-in for "the world changed". Counts how many times the server
## actually let something through, so a test can assert not just "rejected"
## but "and nothing was mutated".
func _apply(_command: Variant = null) -> Dictionary:
	_applied += 1
	return {"applied": _applied}


func _reset() -> void:
	_applied = 0


## A server with two joined peers at known positions.
func _server() -> NetAuthority:
	var a := NetAuthority.new()
	a.join(1, "alice", Vector3.ZERO, 0.0)
	a.join(2, "bob", Vector3(50, 0, 0), 0.0)
	return a


# --- session ----------------------------------------------------------------

func _test_join_required() -> void:
	var a := NetAuthority.new()
	_reset()
	var r := a.submit(99, {"op": "place", "component": "beam"}, _apply)
	_eq(bool(r["ok"]), false, "a peer that never joined is refused")
	_eq(_applied, 0, "and the world did not change")
	_eq(String(r["reason"]).contains("session"), true,
		"the reason names the session, so the client knows to re-handshake")
	a.join(1, "alice", Vector3.ZERO, 0.0)
	_eq(bool(a.submit(1, {"op": "place", "component": "beam"}, _apply)["ok"]), true,
		"and is accepted once it has")
	_eq(_applied, 1, "exactly once")


func _test_schema_rejects_junk() -> void:
	var a := _server()
	_reset()
	# A client is free to send anything at all. Nothing may reach the apply
	# closure until it has been checked, and nothing may crash the server
	# while it is being checked.
	for junk in [{}, {"op": ""}, {"op": "place"},
			{"op": "place", "component": "beam", "position": "here"},
			{"op": "manufacture", "cost": {"iron_ingot": 1}}]:
		var r := a.submit(1, junk, _apply)
		_eq(bool(r["ok"]), false,
			"malformed command %s is refused" % JSON.stringify(junk))
	_eq(_applied, 0, "and nothing was applied")


func _test_unknown_op_rejected() -> void:
	var a := _server()
	_reset()
	var r := a.submit(1, {"op": "delete_everything"}, _apply)
	_eq(bool(r["ok"]), false, "an op outside the allow-list is refused")
	_eq(String(r["reason"]).contains("unknown op"), true, "naming the op")
	# The point of the allow-list: a method that exists on the object but was
	# never meant to be networked is unreachable.
	_eq(a.ALLOWED.has("execute"), false, "arbitrary code is not an op")
	_eq(_applied, 0, "and nothing was applied")


# --- rate limiting ----------------------------------------------------------

func _test_rate_limit() -> void:
	var a := _server()
	_reset()
	# Emptying the bucket is legal; the *first* command beyond it is not.
	var accepted := 0
	for i in 40:
		if bool(a.submit(1, {"op": "operate", "component": "switch", "node": 7}, _apply)["ok"]):
			accepted += 1
	_eq(accepted, int(NetAuthority.BUCKET_DEPTH),
		"a client gets a bucket's worth of commands and no more")
	_eq(_applied, int(NetAuthority.BUCKET_DEPTH), "and only those reached the world")
	var refused := a.submit(1, {"op": "operate", "component": "switch", "node": 7}, _apply)
	_eq(String(refused["reason"]).contains("rate"), true, "the refusal says why")

	# It refills over time, so a legitimate slow builder is never locked out.
	a.advance_clock(10.0)
	_eq(a.tokens_of(1) > 0.0, true, "the bucket refills")
	_eq(bool(a.submit(1, {"op": "operate", "component": "switch", "node": 7}, _apply)["ok"]), true,
		"so a patient client gets through again")
	# And the two peers do not share a bucket: one flooding must not lock
	# everyone else out of the server.
	_eq(bool(a.submit(2, {"op": "operate", "component": "switch", "node": 7}, _apply)["ok"]), true,
		"one client's flood does not throttle another")


# --- reach ------------------------------------------------------------------

func _test_reach_limit() -> void:
	var a := _server()
	_reset()
	var far := Vector3(NetAuthority.MAX_REACH + 5.0, 0, 0)
	var r := a.submit(1, {"op": "place", "component": "beam", "position": far}, _apply)
	_eq(bool(r["ok"]), false, "building out of reach is refused")
	_eq(String(r["reason"]).contains("reach"), true, "and the reason says so")
	_eq(_applied, 0, "nothing was placed")
	_eq(bool(a.submit(1, {"op": "place", "component": "beam",
		"position": Vector3(1, 0, 0)}, _apply)["ok"]), true,
		"a nearby placement is fine")
	# Precision mode does not extend your arms.
	_eq(bool(a.submit(1, {"op": "place", "component": "beam", "position": far,
		"precision": true}, _apply)["ok"]), false,
		"and precision mode does not grant reach")
	# Nor does a coordinate outside the world, even with the reach check off.
	_eq(bool(a.submit(1, {"op": "place", "component": "beam",
		"position": Vector3(99999999, 0, 0), "ignore_reach": true}, _apply)["ok"]),
		false, "a position outside the world is refused regardless")


# --- ownership --------------------------------------------------------------

func _test_ownership() -> void:
	var a := _server()
	_reset()
	a.claim(500, 2)
	var r := a.submit(1, {"op": "remove", "node": 500}, _apply)
	_eq(bool(r["ok"]), false, "a player cannot modify another player's node")
	_eq(String(r["reason"]).contains("belongs to peer 2"), true,
		"the reason names the owner, which is what a grief report needs")
	_eq(_applied, 0, "nothing changed")
	_eq(bool(a.submit(2, {"op": "remove", "node": 500}, _apply)["ok"]), true,
		"the owner can")
	# The same rule on the nodes a connection touches, not just the target.
	a.claim(501, 2)
	_eq(bool(a.submit(1, {"op": "connect", "a": 501, "b": 1}, _apply)["ok"]), false,
		"and it applies to both ends of a connection")
	# Unowned is free for all, so a fresh world is not grief-proof by accident.
	_eq(bool(a.submit(1, {"op": "remove", "node": 999}, _apply)["ok"]), true,
		"an unowned node is free to modify")


# --- economy ----------------------------------------------------------------

func _test_economy_is_server_side() -> void:
	var a := _server()
	_reset()
	# The client claims it has the money. It does not, on the server.
	a.set_ledger(1, {"iron_ingot": 4})
	var r := a.submit(1, {"op": "manufacture", "component": "motor",
		"cost": {"iron_ingot": 10}}, _apply)
	_eq(bool(r["ok"]), false, "a client cannot spend what the server says it lacks")
	_eq(_applied, 0, "and nothing is manufactured")
	_eq(a.ledger_of(1)["iron_ingot"], 4, "the server's ledger is untouched")

	# And when it does have it, the *server's* copy is what is debited.
	_eq(bool(a.submit(1, {"op": "manufacture", "component": "bolt",
		"cost": {"iron_ingot": 2}}, _apply)["ok"]), true, "an affordable order goes through")
	_eq(a.ledger_of(1)["iron_ingot"], 2, "charged at the server's price")
	_eq(_applied, 1, "and applied exactly once")
	# Peer 2's money is peer 1's business not at all.
	a.set_ledger(2, {"iron_ingot": 0})
	_eq(bool(a.submit(2, {"op": "manufacture", "component": "bolt",
		"cost": {"iron_ingot": 1}}, _apply)["ok"]), false, "one player's stock is not another's")


# --- movement ---------------------------------------------------------------

func _test_movement_clamp() -> void:
	var a := _server()
	# Reach checking is only as good as the server's belief about where a
	# player is. If the client could teleport, reach would be meaningless.
	var moved := a.set_peer_position(1, Vector3(1, 0, 0), 1.0)
	_eq(moved.length() <= 41.0, true, "an ordinary step is accepted")
	_at(a, 1, Vector3(5000, 0, 0), 1.0, Vector3(1, 0, 0),
		"a teleport is pulled back to where the server last believed")
	_at(a, 1, Vector3(5000, 0, 0), 1.0, Vector3(1, 0, 0),
		"and it stays there, so the cheat cannot creep")

	# With movement clamped, a reach check cannot be defeated by lying.
	_reset()
	_at(a, 1, a.peer_position(1), 1.0, a.peer_position(1),
		"the server's belief is what the reach check used")
	_eq(bool(a.submit(1, {"op": "place", "component": "beam",
		"position": Vector3(4000, 0, 0)}, _apply)["ok"]), false,
		"so building far away is still refused")
	_eq(_applied, 0, "and nothing was placed")


## Move a peer and assert where the server decided they ended up.
func _at(a: NetAuthority, peer: int, want_pos: Vector3, dt: float,
		expect: Vector3, what: String) -> void:
	var got := a.set_peer_position(peer, want_pos, dt)
	if got.distance_to(expect) < 0.001:
		print("  ok   %s" % what)
	else:
		_fails += 1
		print("  FAIL %s: server put them at %s, expected %s" % [what, str(got), str(expect)])


# --- revocation -------------------------------------------------------------

func _test_revoke_midflight() -> void:
	var a := _server()
	_reset()
	_eq(bool(a.submit(1, {"op": "operate", "component": "switch", "node": 7}, _apply)["ok"]), true, "works while joined")
	a.revoke(1)
	_eq(bool(a.submit(1, {"op": "operate", "component": "switch", "node": 7}, _apply)["ok"]), false,
		"a revoked peer is refused immediately")
	_eq(_applied, 1, "and only the pre-revocation command was applied")
	a.leave(1)
	_eq(bool(a.submit(1, {"op": "operate", "component": "switch", "node": 7}, _apply)["ok"]), false,
		"a peer that left cleanly is refused too")


# --- application ------------------------------------------------------------

func _test_accepted_command_applies_once() -> void:
	var a := _server()
	_reset()
	# A rejected command must not leave a partial mutation behind. The
	# simplest way to prove the gate is before the apply, not after: count.
	a.claim(500, 2)
	var r := a.submit(1, {"op": "remove", "node": 500}, _apply)
	_eq(_applied, 0, "a rejected command never reaches the world, even once")
	_eq(bool(r["ok"]), false, "and reports failure")
	_eq(a.accepted_count(), 0, "nothing was accepted")
	_eq(a.rejected_count(), 1, "the refusal was recorded")
	_eq(a.log().size(), 1, "and appears in the audit log exactly once")


# --- replication ------------------------------------------------------------

func _test_replication_filters_by_distance() -> void:
	var g := EngGraph.new()
	var near := g.place("beam", Vector3.ZERO)
	var far := g.place("beam", Vector3(900, 0, 0))
	g.rebuild_networks()
	var a := _server()
	var snap := a.snapshot_for(1, g, 50.0)
	var ids: Array = []
	for n in snap["nodes"]:
		ids.append(int(n["id"]))
	_eq(ids.has(near), true, "a nearby component is replicated")
	_eq(ids.has(far), false, "a distant one is not")
	_eq(int((snap["nodes"][0] as Dictionary)["owner"]), 0,
		"and the client is told who owns what, so it can grey it out locally")
	# The snapshot is derived on the server: there is no field in it the
	# client filled in.
	_eq(snap.has("at"), true, "and it is timestamped server-side")


# --- audit ------------------------------------------------------------------

func _test_audit_log() -> void:
	var a := _server()
	_reset()
	a.submit(1, {"op": "place", "component": "beam"}, _apply)
	a.submit(1, {"op": "place", "position": Vector3(9999, 0, 0)}, _apply)
	var log := a.log()
	_eq(log.size(), 2, "every command is recorded, accepted or not")
	_eq(bool(log[0]["ok"]), true, "the accepted one is marked accepted")
	_eq(bool(log[1]["ok"]), false, "the refused one is marked refused")
	_eq(int(log[1]["peer"]), 1, "and attributed")
	_eq(String(log[1]["reason"]) != "", true, "with a reason a dispute can be settled on")
