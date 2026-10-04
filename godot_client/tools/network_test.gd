extends SceneTree
## The wire, under load.
##
## `multiplayer_test` proves each rule refuses the attack it is about, one at
## a time. This one is about the things that only break when the packets keep
## coming: a sequence number sent twice, a hole in the stream, a peer whose
## every command is malformed, a price the client made up, and a flood of a
## few thousand mixed packets at a server that has to stay standing.
##
## The rule being tested throughout is the same one, from the other end: a
## command that the server refuses must cost the server nothing, and a command
## it accepts must be one it would have chosen to accept.

var _fails := 0
var _applied := 0


func _init() -> void:
	_test_sequence_rejects_replays()
	_test_sequence_refuses_gaps()
	_test_stream_resynchronises_after_a_gap()
	_test_sequence_tracking_is_per_peer()
	_test_the_server_prices_the_order()
	_test_a_refusal_costs_the_server_a_slot()
	_test_payload_bounds()
	_test_a_refusal_costs_the_server_a_slot()
	_test_one_griefer_does_not_lock_out_a_player()
	_test_mixed_flood()
	_test_protocol_table_is_derived()
	_finish()


func _eq(got: Variant, want: Variant, what: String) -> void:
	if got == want:
		print("  ok   %s == %s" % [what, str(want)])
	else:
		_fails += 1
		print("  FAIL %s: got %s, want %s" % [what, str(got), str(want)])


func _true(cond: bool, what: String) -> void:
	_eq(cond, true, what)


func _finish() -> void:
	print("network: %s" % ["PASS" if _fails == 0 else "%d FAILURES" % _fails])
	quit(1 if _fails > 0 else 0)


func _apply(_command: Variant = null) -> Dictionary:
	_applied += 1
	return {"applied": _applied}


func _reset() -> void:
	_applied = 0


## A server with two joined peers at known positions and a clock we drive.
func _server() -> NetAuthority:
	var a := NetAuthority.new()
	a.join(1, "alice", Vector3.ZERO, 0.0)
	a.join(2, "bob", Vector3(50, 0, 0), 0.0)
	return a


## A price list the server owns: three motors cost four ingots each.
func _catalogue(op: String, command: Dictionary) -> Dictionary:
	if String(command.get("component", "")) != "motor":
		return {}
	var n := maxi(1, int(command.get("count", 1)))
	return {"iron_ingot": 4 * n}


# --- ordering ---------------------------------------------------------------

## A client that resends a command it already had accepted gets a second copy
## of the thing it asked for. Nothing about the command is wrong; that is the
## point, which is why it can only be caught by the sequence number.
func _test_sequence_rejects_replays() -> void:
	var a := _server()
	_reset()
	var make := func(i: int) -> Dictionary:
		return {"op": "place", "component": "beam",
			"position": Vector3(float(i % 5), 0, 0)}
	var r := a.submit_sequenced(1, 0, make.call(0), _apply)
	_true(bool(r["ok"]), "the first message in a stream is accepted")
	r = a.submit_sequenced(1, 1, make.call(1), _apply)
	_true(bool(r["ok"]), "and so is the next")
	_eq(_applied, 2, "both reached the world")

	r = a.submit_sequenced(1, 1, make.call(1), _apply)
	_eq(bool(r["ok"]), false, "the same sequence number again is a replay")
	_true(String(r["reason"]).begins_with("replayed"),
		"and says so: %s" % String(r["reason"]))
	_eq(_applied, 2, "so the world did not change")
	r = a.submit_sequenced(1, 0, make.call(0), _apply)
	_eq(bool(r["ok"]), false, "an older one is refused too")
	_eq(_applied, 2, "still no change")
	_eq(a.replay_count(), 2, "and both replays were counted")
	# The refused replays did not cost the peer its session or its budget for
	# real work: a legitimate next command still goes through.
	_true(bool(a.submit_sequenced(1, 2, make.call(2), _apply)["ok"]),
		"the stream continues afterwards")


## Commands are not observations. "Place a motor" then "connect the wire to it"
## only means anything in order, so a hole in the stream means the two ends no
## longer agree about the world and the server has to say so.
func _test_sequence_refuses_gaps() -> void:
	var a := _server()
	_reset()
	var cmd := {"op": "place", "component": "beam", "position": Vector3.ONE}
	_true(bool(a.submit_sequenced(1, 0, cmd, _apply)["ok"]), "seq 0 goes")
	var r := a.submit_sequenced(1, 3, cmd, _apply)
	_eq(bool(r["ok"]), false, "a command after a hole is refused")
	_true(String(r["reason"]).contains("gap"),
		"and the reason names the gap: %s" % String(r["reason"]))
	_eq(_applied, 1, "nothing after the hole was applied")
	_eq(int(a.sequence_stats(1)["gaps"]), 2, "two lost messages were counted")


## A peer whose stream dropped a packet is not stuck for ever: the tracker
## moves past the hole so the next message is judged against reality rather
## than against a number from before the loss.
func _test_stream_resynchronises_after_a_gap() -> void:
	var a := _server()
	_reset()
	var cmd := {"op": "place", "component": "beam", "position": Vector3.ONE}
	a.submit_sequenced(1, 0, cmd, _apply)
	a.submit_sequenced(1, 5, cmd, _apply)
	var r := a.submit_sequenced(1, 6, cmd, _apply)
	_true(bool(r["ok"]),
		"the message after the hole is judged on its own, not refused for ever")
	_eq(_applied, 2, "and it reached the world")
	# A client that resends from before the hole is still a replay: resyncing
	# the stream must not open a window onto the ones already applied.
	r = a.submit_sequenced(1, 5, cmd, _apply)
	_eq(bool(r["ok"]), false, "and the pre-hole numbers are still replays")


func _test_sequence_tracking_is_per_peer() -> void:
	var a := _server()
	_reset()
	var cmd := {"op": "place", "component": "beam", "position": Vector3.ZERO}
	var other := {"op": "place", "component": "beam", "position": Vector3(50, 0, 0)}
	_true(bool(a.submit_sequenced(1, 0, cmd, _apply)["ok"]), "peer 1 sends 0")
	_true(bool(a.submit_sequenced(2, 0, other, _apply)["ok"]),
		"peer 2 sends 0 as its first, not a replay of peer 1's")
	_eq(_applied, 2, "both went through")
	# Leaving drops the tracker, so a peer that reconnects starts a new stream
	# rather than inheriting the old one's numbers.
	a.leave(1)
	a.join(1, "alice", Vector3.ZERO, 1.0)
	a.advance_clock(100.0)
	_true(bool(a.submit_sequenced(1, 0, cmd, _apply)["ok"]),
		"a returning peer starts a fresh stream")
	_eq(_applied, 3, "and all three commands were applied once")


# --- pricing ----------------------------------------------------------------

## The ledger used to be authoritative about whether a player could pay and
## not at all about what it cost, so the only number in the system came from
## the client and `{"cost": {}}` built a motor for nothing.
func _test_the_server_prices_the_order() -> void:
	var a := _server()
	a.set_ledger(1, {"iron_ingot": 100})
	a.set_pricer(_catalogue)
	_true(a.has_pricer(), "the server has a price list")
	_reset()

	# A client that quotes nothing is charged the server's price anyway.
	var r := a.submit(1, {"op": "manufacture", "component": "motor"}, _apply)
	_true(bool(r["ok"]), "an unquoted order is still accepted")
	_eq(a.ledger_of(1)["iron_ingot"], 96, "at the server's price, not zero")

	# A client that quotes a different price is refused, not corrected.
	r = a.submit(1, {"op": "manufacture", "component": "motor",
		"cost": {"iron_ingot": 1}}, _apply)
	_eq(bool(r["ok"]), false, "quoting a price the server does not sell at fails")
	_true(String(r["reason"]).contains("price mismatch"),
		"and names the disagreement: %s" % String(r["reason"]))
	_eq(a.ledger_of(1)["iron_ingot"], 96, "and nothing was charged")

	# Quoting it correctly is not penalised.
	r = a.submit(1, {"op": "manufacture", "component": "motor",
		"cost": {"iron_ingot": 4}}, _apply)
	_true(bool(r["ok"]), "the honest quote goes through")

	# A batch is priced per unit, so quoting the unit price for four is refused.
	r = a.submit(1, {"op": "manufacture", "component": "motor", "count": 4,
		"cost": {"iron_ingot": 4}}, _apply)
	_eq(bool(r["ok"]), false, "a batch cannot be quoted at the unit price")
	r = a.submit(1, {"op": "manufacture", "component": "motor", "count": 4,
		"cost": {"iron_ingot": 16}}, _apply)
	_true(bool(r["ok"]), "and is accepted at the batch price")
	_eq(a.ledger_of(1)["iron_ingot"], 76, "charged sixteen, not four")

	# Something the catalogue does not price is free, and the client's figure
	# stands -- which is the honest behaviour while the catalogue is partial.
	_true(bool(a.submit(1, {"op": "manufacture", "component": "bolt",
		"cost": {"iron_ingot": 2}}, _apply)["ok"]),
		"an item the catalogue does not price is charged what was quoted")
	_eq(a.ledger_of(1)["iron_ingot"], 74, "two")

	# With no pricer at all, the server says so rather than pretending.
	var bare := _server()
	bare.set_ledger(1, {"iron_ingot": 10})
	_eq(bare.has_pricer(), false, "a server with no catalogue says so")
	_true(bool(bare.submit(1, {"op": "manufacture", "component": "motor",
		"cost": {"iron_ingot": 10}}, _apply)["ok"]),
		"and falls back to the client's figure rather than refusing everything")


# --- the cost of being wrong ------------------------------------------------

## Rate limiting after the schema check is no rate limit at all for the
## cheapest attack there is: a packet that is malformed from end to end spends
## nothing and costs the server a full validation pass.
func _test_a_refusal_costs_the_server_a_slot() -> void:
	var a := _server()
	_reset()
	# Ten seconds of twenty packets a second, all of them nonsense.
	var past_gate := 0
	var packets := 0
	var t := 0.0
	while t < 10.0:
		a.advance_clock(t)
		t += 0.05
		packets += 1
		var r := a.submit(1, {"op": "place", "component": 42}, _apply)
		if not String(r["reason"]).contains("rate limited"):
			past_gate += 1
	_eq(_applied, 0, "nothing malformed ever reached the world")
	# The bound the second bucket exists to impose: validation work is bounded
	# by *its* refill rate, not by how fast the peer can send.
	var refuse_bound := int(NetAuthority.BUCKET_DEPTH
		+ NetAuthority.REFUSE_BUCKET_DEPTH
		+ NetAuthority.REFUSE_TOKENS_PER_SECOND * 10.0)
	_true(past_gate <= refuse_bound,
		"only %d of %d packets were validated (bound %d)"
			% [past_gate, packets, refuse_bound])
	# And measurably fewer than the command bucket alone would have allowed:
	# that difference is the whole argument for having a second one.
	var command_only := int(NetAuthority.BUCKET_DEPTH
		+ NetAuthority.TOKENS_PER_SECOND * 10.0)
	_true(past_gate < command_only,
		"a flood of nonsense is validated %d times where the command bucket "
			% past_gate + "alone would have allowed %d" % command_only)
	_eq(a.rejected_count(), packets, "every one of them was refused")


## One peer being throttled must never cost another peer its turn.
func _test_one_griefer_does_not_lock_out_a_player() -> void:
	var a := _server()
	_reset()
	var good := {"op": "place", "component": "beam", "position": Vector3(50, 0, 0)}
	var t := 0.0
	while t < 5.0:
		a.advance_clock(t)
		t += 0.05
		a.submit(1, {"op": "place", "component": 42}, _apply)
	var ok := 0
	t = 0.0
	while t < 5.0:
		a.advance_clock(t)
		t += 0.05
		if bool(a.submit(2, good, _apply)["ok"]):
			ok += 1
	_true(ok >= 5 * 8,
		"the other peer still sent %d commands in five seconds" % ok)
	_eq(_applied, ok, "and every one of them reached the world")
	# And the griefer is reported rather than merely throttled.
	var reports := a.grief_report()
	_eq(reports.size(), 1, "the flooder is named in the grief report")
	if reports.size() == 1:
		_eq(int(reports[0]["peer"]), 1, "and it is the right peer")
		_true(float(reports[0]["refusal_share"]) > 0.9,
			"with the share of refusals that says so")


# --- payload bounds ---------------------------------------------------------

func _test_payload_bounds() -> void:
	var a := _server()
	_reset()
	# A name longer than the protocol allows, at a size a real client would
	# never send and a hostile one would.
	var huge := "x".repeat(200000)
	var r := a.submit(1, {"op": "place", "component": huge,
		"position": Vector3.ZERO}, _apply)
	_eq(bool(r["ok"]), false, "a 200 kB component name is refused")
	_true(String(r["reason"]).contains("at most"),
		"and the reason is about length, not a crash")
	_eq(_applied, 0, "nothing reached the world")

	# Nesting. Every level is a frame in the server's own stack, chosen by
	# the client.
	var nested: Variant = "leaf"
	for _i in 40:
		nested = {"deeper": nested}
	r = a.submit(1, {"op": "place", "component": "beam", "position": Vector3.ZERO,
		"cost": nested}, _apply)
	_eq(bool(r["ok"]), false, "a deeply nested payload is refused")
	_true(String(r["reason"]).contains("nests"),
		"and says why: %s" % String(r["reason"]))
	# A cost that is a dictionary of the wrong shape never reaches `charge`.
	r = a.submit(1, {"op": "manufacture", "component": "bolt",
		"cost": {"iron_ingot": {"nested": true}}}, _apply)
	_eq(bool(r["ok"]), false, "a cost whose values are not numbers is refused")


## Several thousand packets of every kind at once. The property is not "the
## right number went through" -- the rate limiter moves that around on purpose
## -- it is that the gate is *consistent*: every packet it accepted is one it
## would have accepted alone, and every packet it refused for a reason other
## than throttling is one it would have refused alone. A gate that gets those
## two backwards is a gate whose decisions depend on what arrived before.
func _test_mixed_flood() -> void:
	var a := _server()
	a.set_ledger(1, {"iron_ingot": 100000})
	a.set_pricer(_catalogue)
	_reset()
	var accepted := 0
	var throttled := 0
	var wrongly_accepted := 0
	var wrongly_refused := 0
	var billed := 0
	var seq := 0
	var t := 0.0
	var noop := func(_c: Variant = null) -> Dictionary:
		return {"ok": true, "reason": ""}
	for i in 3000:
		a.advance_clock(t)
		t += 0.02
		var packet := _flood_packet(i)
		var r := a.submit_sequenced(1, seq, packet, _apply)
		seq += 1
		# The same packet, to a server that has seen nothing else and is not
		# throttled. This is the verdict the gate is supposed to be giving.
		var alone := _server()
		alone.set_ledger(1, {"iron_ingot": 100000})
		alone.set_pricer(_catalogue)
		alone.advance_clock(0.0)
		var fair := bool(alone.submit_sequenced(1, 0, packet, noop)["ok"])
		if bool(r["ok"]):
			accepted += 1
			if String(packet.get("op", "")) == "manufacture":
				billed += 4
			if not fair:
				wrongly_accepted += 1
		elif not String(r["reason"]).contains("rate limited"):
			if fair:
				wrongly_refused += 1
		else:
			throttled += 1
		_true_or_fail(String(r["reason"]) != "" or bool(r["ok"]),
			"every refusal names a reason")
	_eq(wrongly_accepted, 0,
		"of %d packets, none was accepted that should not have been" % 3000)
	_eq(wrongly_refused, 0,
		"and none was refused, short of throttling, that should not have been")
	_true(accepted > 0 and throttled > 0,
		"the mix really did exercise both paths (%d accepted, %d throttled)"
			% [accepted, throttled])
	_eq(_applied, accepted, "and each accepted packet was applied once")
	_eq(int(a.ledger_of(1)["iron_ingot"]), 100000 - billed,
		"and the ledger moved once per sale, at the server's price")
	_true(a.log().size() <= 512, "the audit log stayed bounded")
	_eq(a.rejected_count(), 3000 - accepted,
		"and every other packet is on the record as refused")


func _true_or_fail(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("  FAIL %s" % what)


## A third of each: a good command, an op nobody can call, a command aimed at
## another player's node, a replay, a position out of reach, and a malformed
## field. Deterministic in `i`, so the same packet is the same packet every run.
func _flood_packet(i: int) -> Dictionary:
	match i % 6:
		0:
			return {"op": "place", "component": "beam",
				"position": Vector3(float(i % 7), 0, 0)}
		1:
			return {"op": "definitely_not_an_op", "component": "beam"}
		2:
			return {"op": "remove", "node": 500}
		3:
			return {"op": "manufacture", "component": "motor",
				"cost": {"iron_ingot": 4}}
		4:
			return {"op": "place", "component": "beam",
				"position": Vector3(9000, 0, 0)}
		_:
			return {"op": "place", "component": {"not": "a name"},
				"position": Vector3.ZERO}


# --- the table --------------------------------------------------------------

## `spec_of` hands back the stored shape *and* the derived arrays the
## documentation and the tests read, so there is one table and no caller has
## to care which form it wanted.
func _test_protocol_table_is_derived() -> void:
	for op in NetProtocol.ops():
		var spec := NetProtocol.spec_of(op)
		_true(spec.has("required"), "%s declares its required fields" % op)
		_true(spec.has("fields"), "%s exposes them as a list" % op)
		_eq(Array(spec["fields"]).size(),
			(spec["required"] as Dictionary).size(),
			"and the list is the map, for %s" % op)
		# Nothing required may also be optional; that is a typo waiting for
		# the one build where it matters.
		for field in spec["required"]:
			_true(not (spec["optional"] as Dictionary).has(field),
				"%s.%s is not both required and optional" % [op, field])
	# The table renders, which is what keeps ARCHITECTURE.md honest.
	_true(NetProtocol.describe().contains("emergent_rule"),
		"the emergent commands are on the wire, not beside it")
	_true(NetProtocol.describe().contains("pre_session") == false,
		"and the rendering stays about the protocol, not about this file")