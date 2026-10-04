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
	_test_the_host_goes_through_the_gate()
	_test_schema_rejects_junk()
	_test_unknown_op_rejected()
	_test_one_schema_for_both_ends()
	_test_client_cannot_ask_to_skip_validation()
	_test_field_types_are_checked()
	_test_rate_limit()
	_test_reach_limit()
	_test_ownership()
	_test_ownership_covers_node_zero()
	_test_ownership_covers_node_zero()
	_test_economy_is_server_side()
	_test_cost_cannot_be_a_credit()
	_test_charge_and_mutation_are_one_event()
	_test_a_dead_handler_is_not_a_sale()
	_test_movement_clamp()
	_test_movement_tick_is_clamped()
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
	var cmd := {"op": "place", "component": "beam", "position": Vector3.ONE}
	var r := a.submit(99, cmd, _apply)
	_eq(bool(r["ok"]), false, "a peer that never joined is refused")
	_eq(_applied, 0, "and the world did not change")
	_eq(String(r["reason"]).contains("session"), true,
		"the reason names the session, so the client knows to re-handshake")
	a.join(1, "alice", Vector3.ZERO, 0.0)
	_eq(bool(a.submit(1, cmd, _apply)["ok"]), true,
		"and is accepted once it has")
	_eq(_applied, 1, "exactly once")


## Single player is not an exemption. The host is a peer like any other:
## same session check, same schema, same refusals. This is the entry point
## `GameApi.request` has been calling for the host's own verbs, and while it
## did not exist the host's commands went straight into the world while a
## client's went through the gate -- which is precisely the asymmetry an
## exploit looks for.
func _test_the_host_goes_through_the_gate() -> void:
	var a := NetAuthority.new()
	_reset()
	var unapplied := a.submit_local("place", {"component": "beam",
		"position": Vector3.ONE})
	_eq(bool(unapplied["ok"]), false,
		"a host command with no applier installed is refused")
	_eq(String(unapplied["reason"]).contains("applier"), true,
		"and says the wiring is missing rather than claiming success")
	a.set_local_applier(_apply)
	var unjoined := a.submit_local("place", {"component": "beam",
		"position": Vector3.ONE})
	_eq(bool(unjoined["ok"]), false,
		"and the host still has to have joined: the session check is not "
		+ "skipped for the host")
	_eq(_applied, 0, "nothing was applied along the way")
	a.join(NetAuthority.HOST_PEER, "host", Vector3.ZERO, 0.0)
	_eq(bool(a.submit_local("place", {"component": "beam",
		"position": Vector3.ONE})["ok"]), true,
		"a well-formed host command is accepted once it has")
	_eq(_applied, 1, "and applied exactly once")
	# The whole point: the refusals a remote client gets, the host gets too.
	var bypass := a.submit_local("place", {"component": "beam",
		"position": Vector3.ONE, "ignore_reach": true})
	_eq(bool(bypass["ok"]), false,
		"the host cannot ask to skip validation either")
	_eq(_applied, 1, "and the refused command changed nothing")
	var junk := a.submit_local("emergent_place", {"kind": 7})
	_eq(bool(junk["ok"]), false,
		"a mistyped host command is refused like any other")
	_eq(_applied, 1, "still nothing applied")
	_eq(String(junk["reason"]) != "", true,
		"with a reason the HUD can show")


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
	_eq(a.allowed_ops().has("execute"), false, "arbitrary code is not an op")
	_eq(_applied, 0, "and nothing was applied")


## The two places that used to describe the wire -- the list of op names and
## the list of required fields -- described it differently. `disconnect`
## wanted an `a` in one table and an `edge` in the other; the emergent ops
## existed only in one of them. Two tables are two things to forget to update,
## so there is one now and this is what keeps it one.
func _test_one_schema_for_both_ends() -> void:
	_eq(NetAuthority.allowed_ops(), NetProtocol.command_ops(),
		"the authority accepts exactly the protocol's post-handshake requests")
	# The handshake is a request too, and it is the one that creates the
	# session, so it is not something a session check can admit.
	_eq(NetProtocol.command_ops().has("hello"), false,
		"the handshake is not one of the commands")
	_eq(bool(NetProtocol.spec_of("hello").get("pre_session", false)), true,
		"and it says why, in the table rather than in the code")
	# Every command the authority accepts is one the protocol can describe,
	# and every field the table names is one the authority can check.
	for op in NetAuthority.allowed_ops():
		var spec: Dictionary = NetProtocol.MESSAGES[op]
		_eq(String(spec["dir"]), NetProtocol.CLIENT_TO_SERVER,
			"%s travels client to server" % op)
		for group in ["required", "optional"]:
			for field in spec[group]:
				_eq(bool(_known_kind(String(spec[group][field]))), true,
					"%s.%s names a kind the checker understands" % [op, field])
	# The two disagreeing fields are now one field, named the same way by
	# both ends because there is only one table to name it in.
	_eq(NetProtocol.field_names("disconnect"), ["a"] as Array[String],
		"disconnect names the same field the authority checks")


func _known_kind(kind: String) -> bool:
	return ["name", "text", "id", "int", "count", "flag", "vector", "angle",
		"level", "cost"].has(kind)


## A client used to be able to send `{"ignore_reach": true}` and skip the
## reach check, which made every other reach check decorative. The field is
## refused, not ignored: silently dropping it would teach the client that
## asking is allowed.
func _test_client_cannot_ask_to_skip_validation() -> void:
	var a := _server()
	_reset()
	var far := Vector3(NetAuthority.MAX_REACH + 5.0, 0, 0)
	for field in NetAuthority.BYPASS_FIELDS:
		var cmd := {"op": "place", "component": "beam", "position": far,
			field: true}
		var r := a.submit(1, cmd, _apply)
		_eq(bool(r["ok"]), false, "'%s' does not buy a skipped check" % field)
		_eq(String(r["reason"]).contains("not something a client may ask for"),
			true, "and says what the field is, not 'out of reach'")
	_eq(_applied, 0, "nothing was placed by any of them")
	# A command that does not need the bypass still works, so the check is
	# refusing the field and not the command.
	_eq(bool(a.submit(1, {"op": "place", "component": "beam",
		"position": Vector3(2, 0, 0)}, _apply)["ok"]), true,
		"a nearby placement without it goes through")


## Present is not the same as well-formed. Every one of these is a Dictionary
## with the field present, which is what the old presence-only check accepted
## and handed to a handler expecting something else.
func _test_field_types_are_checked() -> void:
	var a := _server()
	_reset()
	var bad := [
		{"op": "place", "component": {"nested": "dict"}},
		{"op": "place", "component": 7},
		{"op": "place", "component": "beam", "position": "over there"},
		{"op": "place", "component": "beam", "position": Vector3(NAN, 0, 0)},
		{"op": "remove", "node": {}},
		{"op": "remove", "node": -1},
		{"op": "remove", "node": 1.5},
		{"op": "manufacture", "component": "bolt", "count": 0},
		{"op": "manufacture", "component": "bolt",
			"count": NetAuthority.MAX_COUNT + 1},
		{"op": "capture_blueprint", "name": "x".repeat(
			NetAuthority.MAX_NAME + 1)},
		{"op": "emergent_rule", "text": ""},
		{"op": "set_interaction_level", "level": 99},
	]
	for cmd in bad:
		var r := a.submit(1, cmd, _apply)
		_eq(bool(r["ok"]), false,
			"wrongly-typed command %s is refused" % JSON.stringify(cmd))
	_eq(_applied, 0, "and none of them reached the world")
	# The legitimate shapes still pass, so this is a type check and not a
	# blanket refusal of these ops.
	_eq(bool(a.submit(1, {"op": "remove", "node": 0}, _apply)["ok"]), true,
		"node 0 is a node, not a missing field")
	_eq(bool(a.submit(1, {"op": "manufacture", "component": "bolt",
		"count": NetAuthority.MAX_COUNT}, _apply)["ok"]), true,
		"a batch at the limit is allowed")
	_eq(bool(a.submit(1, {"op": "manufacture", "component": "bolt",
		"count": 2.0}, _apply)["ok"]), true,
		"a whole number that arrived as a float is a whole number")


## `charge` subtracts. A cost of -5 therefore *adds*, and a server that only
## checked affordability would be a server that pays people to build.
func _test_cost_cannot_be_a_credit() -> void:
	var a := _server()
	a.set_ledger(1, {"iron_ingot": 0})
	_reset()
	for cost in [{"iron_ingot": -5}, {"iron_ingot": 0}, {"iron_ingot": 1.5},
			{"iron_ingot": "2"}, {"" : 1}, {"iron_ingot": -1}]:
		var r := a.submit(1, {"op": "manufacture", "component": "bolt",
			"cost": cost}, _apply)
		_eq(bool(r["ok"]), false,
			"cost %s is refused" % JSON.stringify(cost))
	_eq(a.ledger_of(1)["iron_ingot"], 0, "and the ledger is untouched")
	# `charge` is public, so it defends itself too rather than trusting a
	# caller that has already been validated.
	_eq(a.charge(1, {"iron_ingot": -5}), false,
		"charge() refuses a negative amount even when called directly")
	_eq(a.ledger_of(1)["iron_ingot"], 0, "so the credit never happened")


## A player who was charged for a motor that was not built has no way to get
## the money back and no way to prove it happened. Charging and mutating are
## one event or neither.
func _test_charge_and_mutation_are_one_event() -> void:
	var a := _server()
	a.set_ledger(1, {"iron_ingot": 10})
	_reset()
	var refuse := func(_c: Dictionary) -> Variant:
		return {"ok": false, "reason": "no room on the graph"}
	var r := a.submit(1, {"op": "manufacture", "component": "motor",
		"cost": {"iron_ingot": 4}}, refuse)
	_eq(bool(r["ok"]), false, "a mutation that failed is reported failed")
	_eq(String(r["reason"]), "no room on the graph",
		"and the handler's own reason is what the client is told")
	_eq(a.ledger_of(1)["iron_ingot"], 10,
		"and the player was refunded, not charged for nothing")
	_eq(a.accepted_count(), 0, "the command was not accepted")
	_eq(a.rejected_count(), 1, "it was rejected")
	# The same command when the handler says yes is charged once.
	var yes := func(_c: Dictionary) -> Variant:
		return {"ok": true, "reason": "", "made": 1}
	_eq(bool(a.submit(1, {"op": "manufacture", "component": "motor",
		"cost": {"iron_ingot": 4}}, yes)["ok"]), true, "and a success charges")
	_eq(a.ledger_of(1)["iron_ingot"], 6, "exactly once, at the server's price")
	# A handler that returns no verdict at all is not second-guessed: the
	# authority validates the command, not the handler's self-assessment.
	_reset()
	_eq(bool(a.submit(1, {"op": "manufacture", "component": "bolt",
		"cost": {"iron_ingot": 1}}, _apply)["ok"]), true,
		"a handler with nothing to report is taken at its word")
	_eq(a.ledger_of(1)["iron_ingot"], 5, "and charged once")


## Without this, a command whose closure had gone away still returned
## `ok: true`, billed the player, and produced nothing at all.
func _test_a_dead_handler_is_not_a_sale() -> void:
	var a := _server()
	a.set_ledger(1, {"iron_ingot": 10})
	_reset()
	var r := a.submit(1, {"op": "manufacture", "component": "bolt",
		"cost": {"iron_ingot": 3}}, Callable())
	_eq(bool(r["ok"]), false, "a command with no handler is refused")
	_eq(String(r["reason"]).contains("no handler"), true, "and says so")
	_eq(a.ledger_of(1)["iron_ingot"], 10, "and nobody was charged")


## The movement clamp is `MAX_SPEED * dt`. An unclamped `dt` -- which came
## from the same client as the position -- is a teleport, and a teleport
## defeats every reach check that follows.
func _test_movement_tick_is_clamped() -> void:
	var a := _server()
	a.set_ledger(1, {"iron_ingot": 1})
	var got := a.set_peer_position(1, Vector3(50000, 0, 0), 100000.0)
	_eq(got.distance_to(Vector3.ZERO) <=
		NetAuthority.MAX_SPEED * NetAuthority.MAX_TICK + 0.5, true,
		"a claimed tick of 100000 s buys one tick's worth of movement, not 40 km")
	_eq(got.length() < 100.0, true, "the teleport did not happen")
	# And the cheat cannot creep up to the target one enormous tick at a time.
	var far := Vector3(NetAuthority.MAX_REACH + 5.0, 0, 0)
	a.set_peer_position(1, Vector3.ZERO, 0.0)
	var target := a.peer_position(1) + far
	for i in 200:
		a.set_peer_position(1, target, 100000.0)
	_reset()
	_eq(bool(a.submit(1, {"op": "place", "component": "beam",
		"position": target}, _apply)["ok"]), false,
		"so building there is still out of reach")
	_eq(_applied, 0, "and nothing was placed")


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
	# Nor does a coordinate outside the world. The extent check is a hard cap
	# that runs before reach, so this is refused for its own reason.
	var outside := a.submit(1, {"op": "place", "component": "beam",
		"position": Vector3(99999999, 0, 0)}, _apply)
	_eq(bool(outside["ok"]), false, "a position outside the world is refused")
	_eq(String(outside["reason"]).contains("outside the world"), true,
		"and named as such, not as a reach failure")


## Node ids start at zero, and the ownership check used to read a zero as
## "no node named" -- so `{"op":"remove","node":0}` skipped the check while
## `{"op":"remove","node":1}` did not. Whether you could strip somebody's
## machine depended on which machine it was.
func _test_ownership_covers_node_zero() -> void:
	var a := _server()
	_reset()
	a.claim(0, 2)
	_eq(bool(a.submit(1, {"op": "remove", "node": 0}, _apply)["ok"]), false,
		"node 0 is ownership-checked like every other node")
	_eq(_applied, 0, "and peer 1 did not touch peer 2's machine")
	_eq(bool(a.submit(2, {"op": "remove", "node": 0}, _apply)["ok"]), true,
		"its owner still can")
	# The same for the other ids an op can name.
	a.claim(3, 2)
	_eq(bool(a.submit(1, {"op": "connect", "a": 3, "b": 4}, _apply)["ok"]),
		false, "and for both ends of a connection")
	_eq(bool(a.submit(1, {"op": "emergent_remove", "entity": 3}, _apply)["ok"]),
		false, "and for an emergent entity")


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
	a.submit(1, {"op": "place", "component": "beam",
		"position": Vector3(1, 0, 0)}, _apply)
	a.submit(1, {"op": "place", "component": "beam",
		"position": Vector3(9999, 0, 0)}, _apply)
	var log := a.log()
	_eq(log.size(), 2, "every command is recorded, accepted or not")
	_eq(bool(log[0]["ok"]), true, "the accepted one is marked accepted")
	_eq(bool(log[1]["ok"]), false, "the refused one is marked refused")
	_eq(int(log[1]["peer"]), 1, "and attributed")
	_eq(String(log[1]["reason"]) != "", true, "with a reason a dispute can be settled on")
