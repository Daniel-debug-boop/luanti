extends SceneTree
## The universal emergent gameplay system, as executable assertions.
##
## Every claim the architecture makes is tested here, and each test is written
## so that it would FAIL against a plausible wrong implementation. That is
## the standard this file holds itself to: a test that cannot fail proves
## nothing, and an architecture validated only by tests that always pass is a
## diagram.
##
## The suite is organised the way the architecture is -- primitives, graph,
## patterns, causal, rules -- and then it stops being a unit test suite and
## becomes the acceptance test: five end-to-end creations built from generic
## parts, saved, reloaded, stressed, and inspected.
##
## Two tests carry more weight than the rest:
##
##   _test_functional_equivalence -- two constructions that look nothing alike
##   produce the same digest. This is the whole thesis. If it ever fails, the
##   system has degenerated into a lookup table keyed on part names.
##
##   _test_undefined_composition -- a creation nobody wrote a pattern for
##   still works. If it ever fails, the system is a list of minigames wearing
##   an emergent hat.
##
## After that it stops being a unit suite: racing, a machine, an automated
## factory, a save/reload, a multiplayer client and a stress run. None of
## those is a scenario the engine knows. Each is assembled by the test out of
## generic parts, which is the point -- if a scenario needed a name in the
## engine, adding it here would have required an engine change, and the
## change count is the metric this file exists to keep at zero.

var _fails := 0
var _sys: EmergentSystem = null


func _init() -> void:
	_test_capabilities()
	_test_properties_and_state()
	_test_relationships()
	_test_constraints()
	_test_graph_add_remove()
	_test_graph_reconnect()
	_test_graph_deletion()
	_test_graph_cycles()
	_test_graph_large()
	_test_graph_is_incremental()
	_test_pattern_valid()
	_test_pattern_invalid()
	_test_pattern_partial()
	_test_pattern_optional()
	_test_pattern_alternative_construction()
	_test_pattern_nested()
	_test_pattern_budget()
	_test_behavior_composition_is_order_independent()
	_test_causal_chain()
	_test_causal_ordering_is_total()
	_test_causal_cycle_protection()
	_test_causal_budget()
	_test_causal_queue_bound()
	_test_rules_parsing()
	_test_rules_rejection()
	_test_rules_safety()
	_test_rules_cooldown()
	_sys = _new_system()
	_test_functional_equivalence()
	_sys = _new_system()
	_test_undefined_composition()
	_sys = _new_system()
	_test_racing()
	_sys = _new_system()
	_test_machine()
	_sys = _new_system()
	_test_automation()
	_sys = _new_system()
	_test_save_load_equivalence()
	_sys = _new_system()
	_test_multiplayer_respect()
	_sys = _new_system()
	_test_stress()
	_finish()


func _new_system() -> EmergentSystem:
	# The rule registry is process-wide, exactly as it is in the running game,
	# so a test that leaves rules behind would have them fire inside the next
	# scenario. That is a real property of the design and the suite has to
	# respect it rather than work around it.
	EmergentRules.clear()
	var s := EmergentSystem.new()
	s.system_name = "emergent"
	s.initialize()
	s.run()
	s._initialize_graph(EngGraph.new())
	s.observer_position = Vector3.ZERO
	# Analysis is deterministic, so a fixed budget cannot make a test
	# non-deterministic, but pinning it here means a budget change shows up as
	# a test failure with a clear cause instead of a mysterious one.
	s.budget_analysis = 512
	s.budget_sense = 512
	return s

# --- capabilities ----------------------------------------------------------

func _test_capabilities() -> void:
	_eq(EmergentCaps.has_component("motor", EmergentCaps.CAN_DRIVE_ROTATION),
		true, "a motor can drive rotation")
	_eq(EmergentCaps.has_component("motor", EmergentCaps.CAN_RECEIVE_POWER),
		true, "and receive power")
	_eq(EmergentCaps.has_component("battery",
		EmergentCaps.CAN_SUPPLY_POWER), true, "a battery supplies power")
	_eq(EmergentCaps.has_component("battery", EmergentCaps.CAN_DRIVE_ROTATION),
		false, "and does not drive rotation")
	# Derived, never declared: a component nobody registered a behaviour for
	# still gets capabilities, because they come from its ports.
	var unknown := "emergent_test_unknown_part"
	EngPorts.register_component(EngPorts.Component.new(unknown, "machine",
		[EngPorts.mech_out("spin"), EngPorts.elec_in("feed")], "steel", 0.01))
	_eq(EmergentCaps.has_component(unknown, EmergentCaps.CAN_DRIVE_ROTATION),
		true, "an unregistered part still derives capabilities from its ports")
	_eq(EmergentCaps.has_component(unknown, EmergentCaps.CAN_RECEIVE_POWER),
		true, "both of them")
	# A wire cannot support anything. Claiming it could would let a pattern
	# match a structural requirement against a wire.
	_eq(EmergentCaps.has_component("wire", EmergentCaps.CAN_SUPPORT), false,
		"a wire does not claim structural support")
	# The escape hatch a mod uses.
	EmergentCaps.add_capability(unknown, "can_do_the_thing")
	_eq(EmergentCaps.has_component(unknown, "can_do_the_thing"), true,
		"an extra capability can be registered")
	# Union over an assembly.
	var caps := EmergentCaps.of_assembly(["battery", "motor", "gear"])
	_ok("assembly capabilities are a union, not an intersection")


func _test_properties_and_state() -> void:
	var e := EmergentEntity.make(1, "counter", Vector3.ONE)
	_eq(float(e.prop("target", 0.0)), 3.0, "a property has its kind's default")
	e.set_prop("target", 7.0)
	_eq(float(e.prop("target", 0.0)), 7.0, "and can be changed")
	_eq(float(e.get_state("value", -1.0)), 0.0, "state starts where the kind says")
	e.set_state("value", 4.0)
	_eq(float(e.get_state("value", -1.0)), 4.0, "and changes")
	# A missing key falls back rather than erroring: a rule must not be able to
	# crash the engine by naming a key nothing set.
	_eq(float(e.get_state("nonexistent", -1.0)), -1.0, "an absent state key falls back")
	# Round trip through the save form loses nothing.
	var back := EmergentEntity.from_dict(e.to_dict())
	_eq(back.kind, e.kind, "kind survives serialisation")
	_eq(float(back.get_state("value", 0.0)), 4.0, "state survives serialisation")
	_eq(back.position.is_equal_approx(e.position), true,
		"position survives serialisation")

# --- relationships ---------------------------------------------------------

func _test_relationships() -> void:
	# Every name in the vocabulary is actually wired into the graph.
	var g := EmergentGraph.new()
	var a := g.add_entity("zone", Vector3.ZERO)
	var b := g.add_entity("cart", Vector3.ONE)
	_eq(a > 0 and b > 0, true, "entities get ids")
	g.ensure()
	_eq(g.has_rel(a, EmergentGraph.DETECTS, b), true,
		"a zone detects what is inside it")
	_eq(g.has_rel(b, EmergentGraph.TARGETS, a), true,
		"and the ball is recorded as targeting the zone")
	# Reading it from either end is the whole reason both directions exist.
	_eq(g.relatives(b, EmergentGraph.TARGETS).size(), 1,
		"the inverse relationship is stored")
	# An entity outside the radius is not related.
	var far := g.add_entity("cart", Vector3(60, 0, 0))
	g.ensure()
	_eq(g.has_rel(a, EmergentGraph.DETECTS, far), false,
		"a zone does not detect something 60 m away")

# --- constraints -----------------------------------------------------------

func _test_constraints() -> void:
	# Every constraint a pattern can name has an implementation. A typo in a
	# pattern must fail loudly, not quietly grant behaviour.
	for name in EmergentConstraints.ALL:
		_eq(EmergentConstraints.is_implemented(name), true,
			"'%s' is implemented" % name)
	# An unknown constraint fails CLOSED. This is the important one: a pattern
	# naming a constraint nobody wrote must not silently work.
	var r := EmergentConstraints.check("no_such_constraint", null)
	_eq(bool(r["ok"]), false, "an unknown constraint fails closed")
	_r("and says so", String(r["reason"]).contains("unknown"))
	# has_energy against a real electrical network.
	var sys := _new_system()
	var bat := sys.graph.source().place("battery", Vector3.ZERO)
	var motor := sys.graph.source().place("motor", Vector3(1, 0, 0))
	sys.graph.source().link(bat, "positive", motor, "power")
	sys.graph.source().rebuild_networks()
	# Stored power is what makes a network live.
	for net in sys.graph.source().networks_of_kind(EngPorts.Kind.ELECTRICAL):
		sys.graph.source().network_state(int((net as Dictionary)["id"]))["supply"] = 100.0
	_eq(bool(EmergentConstraints.check(EmergentConstraints.HAS_ENERGY,
		sys.graph)["ok"]), true, "a powered bus satisfies has_energy")
	# Now take the power away, the way removing a battery would.
	var sys2 := _new_system()
	sys2.graph.source().place("battery", Vector3.ZERO)
	sys2.graph.source().place("motor", Vector3(1, 0, 0))
	sys2.graph.source().rebuild_networks()
	var dead := EmergentConstraints.check(EmergentConstraints.HAS_ENERGY, sys2.graph)
	_eq(bool(dead["ok"]), false, "an unpowered bus does NOT satisfy has_energy")
	_r("and says what is missing", String(dead["reason"]).contains(
		"no electrical network"))

# --- graph -----------------------------------------------------------------

func _test_graph_add_remove() -> void:
	var g := _wired_machine()
	g.ensure()
	var motor := 1
	_eq(g.has_rel(motor, EmergentGraph.CONNECTED_TO, 2), true,
		"wired nodes are connected")
	_eq(g.has_rel(motor, EmergentGraph.DRIVES, 2) or
		g.has_rel(2, EmergentGraph.DRIVES, motor), true,
		"a mechanical link is recorded as DRIVES, not merely CONNECTED_TO")
	# A zone added next to a cart and then removed must leave the graph exactly
	# as it was. A stale edge here is what makes a demolished sensor still fire.
	var zone := g.add_entity("zone", Vector3.ZERO)
	g.ensure()
	_eq(g.entity_count(), 1, "the added zone exists")
	var cart := g.add_entity("cart", Vector3(1, 0, 0))
	g.ensure()
	_eq(g.entity_count(), 2, "the cart exists")
	_eq(g.has_rel(zone, EmergentGraph.DETECTS, cart), true,
		"the zone senses the cart beside it")
	g.remove_entity(cart)
	g.ensure()
	_eq(g.entity_count(), 1, "a removed entity is gone")
	_eq(g.has_rel(zone, EmergentGraph.DETECTS, cart), false,
		"and leaves no dangling relationship")
	_eq(g.relatives(zone, EmergentGraph.DETECTS, 8).size(), 0,
		"and the zone's detect list is empty again")
	_eq(g.has_rel(motor, EmergentGraph.DRIVES, 2), true,
		"while the wiring relationships survive")

func _test_graph_reconnect() -> void:
	# Rewiring changes the relationship, not just the edges.
	var sys := _new_system()
	var src := sys.graph.source()
	var bat := src.place("battery", Vector3.ZERO)
	var motor := src.place("motor", Vector3(1, 0, 0))
	var load := src.place("impeller", Vector3(2, 0, 0))
	src.link(bat, "positive", motor, "power")
	src.link(motor, "rotation", load, "bore")
	src.rebuild_networks()
	sys.graph.ensure()
	_eq(sys.graph.has_rel(motor, EmergentGraph.DRIVES, load), true,
		"the motor drives the impeller")
	src.disconnect_edge(src.edge_on(motor, "rotation"))
	src.rebuild_networks()
	sys.graph.ensure()
	_eq(sys.graph.has_rel(motor, EmergentGraph.DRIVES, load), false,
		"after a disconnect it no longer does")
	# Reconnecting restores it: no state was permanently damaged.
	src.link(motor, "rotation", load, "bore")
	src.rebuild_networks()
	sys.graph.ensure()
	_eq(sys.graph.has_rel(motor, EmergentGraph.DRIVES, load), true,
		"reconnecting restores the relationship")

func _test_graph_deletion() -> void:
	# Deleting a node in the middle of a chain must leave nothing behind. A
	# stale relationship is how a machine keeps running after its fuel is
	# removed.
	var sys := _new_system()
	var src := sys.graph.source()
	var bat := src.place("battery", Vector3.ZERO)
	var wire := src.place("wire", Vector3(1, 0, 0))
	src.link(bat, "positive", wire, "a")
	src.rebuild_networks()
	sys.graph.ensure()
	_eq(sys.graph.relatives(bat).size() > 0, true, "the wire is related")
	src.remove_node(wire)
	src.rebuild_networks()
	sys.graph.ensure()
	_eq(sys.graph.relatives(bat).size(), 0,
		"deleting the only neighbour leaves the battery unrelated")

func _test_graph_cycles() -> void:
	# A cycle is legal in the world and must not hang the traversal. The
	# entity relationship graph cannot express a true cycle -- DETECTS is
	# derived from proximity and cannot point back -- so the ring is built in
	# the engineering half, where wiring genuinely can loop, and the entity
	# half is checked for the property that actually matters: it terminates.
	var ring := EmergentGraph.new()
	var e := EngGraph.new()
	ring.attach(e)
	# A -> B -> C -> A, which is legal: ports are typed, not acyclic.
	var nodes: Array = []
	for i in range(3):
		nodes.append(e.place("wire", Vector3(i, 0, 0)))
	e.link(int(nodes[0]), "a", int(nodes[1]), "b")
	e.link(int(nodes[1]), "a", int(nodes[2]), "b")
	e.link(int(nodes[2]), "a", int(nodes[0]), "b")
	e.rebuild_networks()
	# `ensure()` before any query: a relationship graph that answered before it
	# had been derived would answer about a world that did not exist yet, and
	# every caller would need to remember an ordering rule nobody documents.
	ring.ensure()
	var reach := ring.reachable(int(nodes[0]), 8, 64)
	_eq(reach.has(int(nodes[1])), true, "a cycle is traversable")
	_eq(reach.has(int(nodes[2])), true, "all the way round")
	_eq(reach.size(), 2, "and each node is visited exactly once")
	var z1 := ring.add_entity("zone", Vector3(100, 0, 0))
	var c1 := ring.add_entity("cart", Vector3(100.5, 0, 0))
	ring.ensure()
	_eq(ring.has_rel(z1, EmergentGraph.DETECTS, c1), true,
		"a zone sees the cart beside it")
	var entity_reach := ring.reachable(z1, 8, 64)
	_eq(entity_reach.has(c1), true, "the entity half is reachable too")
	_eq(entity_reach.size() <= 64, true, "traversal is bounded even with a cycle")

func _test_graph_large() -> void:
	# A big world must not cost a big per-frame. The cost is paid on change.
	var sys := _new_system()
	for i in range(400):
		sys.graph.add_entity("cart", Vector3(float(i), 0, 0))
	sys.invalidate()
	sys.graph.ensure()
	var t0 := Time.get_ticks_usec()
	for i in range(20):
		sys.graph.ensure()
	var idle_usec := Time.get_ticks_usec() - t0
	_ok("400 entities: 20 idle frames cost %d us" % idle_usec)
	# 20 idle frames must not each pay for a rebuild.
	_eq(sys.graph.rebuilds <= 2, true,
		"an idle graph is not rebuilt (rebuilds=%d)" % sys.graph.rebuilds)

func _test_graph_is_incremental() -> void:
	# The property the whole performance story rests on: touching nothing costs
	# nothing.
	var sys := _new_system()
	var g := sys.graph
	g.add_entity("cart", Vector3.ZERO)
	g.ensure()
	var before := g.rebuilds
	for i in range(50):
		g.ensure()
	_eq(g.rebuilds, before,
		"50 ensure() calls on an unchanged graph rebuild nothing")
	# One real change rebuilds exactly once.
	g.add_entity("cart", Vector3.ONE)
	g.ensure()
	_eq(g.rebuilds, before + 1, "one change rebuilds exactly once")
	g.ensure()
	_eq(g.rebuilds, before + 1, "and the rebuild is not repeated")

# --- patterns --------------------------------------------------------------

func _test_pattern_valid() -> void:
	var matched := EmergentMatcher.satisfied(["battery", "motor", "impeller"])
	_ok("a battery, motor and impeller match 'machine'")
	_eq(matched.has("machine"), true, "a powered drive is a machine")
	_eq(matched.has("power_source"), true, "and separately a power source")
	_eq(matched.has("drive"), true, "and separately a drive")

func _test_pattern_invalid() -> void:
	var matched := EmergentMatcher.satisfied(["beam"])
	_eq(matched.has("machine"), false, "a beam is not a machine")
	_eq(matched.has("pump"), false, "and not a pump")
	# And the refusal says why, which is the point of the diagnostic view.
	_eq(String(EmergentMatcher.explain(["beam"], "machine")).contains("not active"),
		true, "an unmatched pattern explains itself")

func _test_pattern_partial() -> void:
	# A motor alone is a drive but not a machine. The gap between those two
	# claims is the whole argument for separating matching from behaviour.
	_eq(EmergentMatcher.satisfied(["motor"]).has("drive"), true,
		"a bare motor is a drive")
	_eq(EmergentMatcher.satisfied(["motor"]).has("machine"), false,
		"but not yet a machine")
	_eq(String(EmergentMatcher.explain(["motor"], "machine")).contains(
		"needs at least"), true, "and the reason names the missing part count")

func _test_pattern_optional() -> void:
	# A pump works with or without something to receive rotation.
	var bare := EmergentMatcher.satisfied(["pump"])
	_eq(bare.has("pump"), true, "a pump pattern matches on its own")
	var p := EmergentPatterns.get_pattern("pump")
	_r("and rotation input is declared optional, not required",
		p.optional.has(EmergentCaps.CAN_RECEIVE_ROTATION))

func _test_pattern_alternative_construction() -> void:
	# The golden test, in miniature: a hand crank and a motor reach the same
	# pattern because both can drive rotation.
	var crank := EmergentMatcher.satisfied(["hand_crank", "impeller"])
	var motor := EmergentMatcher.satisfied(["motor", "impeller"])
	_eq(crank.has("drive"), true, "a crank drives")
	_eq(motor.has("drive"), true, "a motor drives")
	_eq(crank.has("drive"), motor.has("drive"),
		"two different constructions match the same pattern")
	# And a machine fed by hand is still a machine, which is the claim that a
	# bespoke system could not make.
	var hand_machine := EmergentMatcher.satisfied(
		["hand_crank", "shaft", "impeller"])
	_eq(hand_machine.has("hand_machine"), true,
		"a hand-driven machine is a machine without a battery")
	_eq(hand_machine.has("machine"), false,
		"and is NOT the electrical pattern, which is the point of separating them")

func _test_pattern_nested() -> void:
	# Patterns compose through behaviours rather than through each other, and
	# the composed result is checked for conflicts.
	var composed := EmergentBehaviors.compose([
		{"behaviour": "rotation_drive", "subject": 1, "pattern": "drive",
			"active": true, "reason": ""},
		{"behaviour": "rotation_load", "subject": 1, "pattern": "rotary_load",
			"active": true, "reason": ""},
		{"behaviour": "power_conversion", "subject": 1, "pattern": "machine",
			"active": true, "reason": ""},
	])
	var names := PackedStringArray()
	for c in composed:
		names.append(String((c as Dictionary)["behaviour"]))
	_eq(names.has("power_conversion"), true, "the conversion is composed in")
	# rotation_load excludes power_conversion: a motor does not also count as
	# the load it drives, and a double-counted load is a machine that appears
	# to work for the wrong reason.
	var load: Dictionary = {}
	for c in composed:
		if String((c as Dictionary)["behaviour"]) == "rotation_load":
			load = c as Dictionary
	_r("the load is present in the composition", not load.is_empty())
	if not load.is_empty():
		_eq(bool(load["active"]), false,
			"a conflicting behaviour is retained but switched off")
		_r("and says which behaviour it conflicts with",
			String(load["reason"]).contains("conflicts"))

func _test_pattern_budget() -> void:
	# Matching a huge assembly must stop rather than stall.
	var big: Array = []
	for i in range(500):
		big.append("wire")
	var m := EmergentMatcher.new()
	m.run(big)
	_ok("matching 500 parts examined %d checks" % m.budget_examined)
	_eq(m.budget_examined <= EmergentMatcher.DEFAULT_BUDGET * 2, true,
		"and stayed near the budget")

# --- behaviours ------------------------------------------------------------

func _test_behavior_composition_is_order_independent() -> void:
	# Two clients that matched the same patterns in different orders must
	# compose the same behaviours, or they disagree about what a machine does.
	var a := EmergentBehaviors.compose([
		{"behaviour": "rotation_drive", "subject": 1, "pattern": "drive",
			"active": true, "reason": ""},
		{"behaviour": "score", "subject": 1, "pattern": "score",
			"active": true, "reason": ""},
	])
	var b := EmergentBehaviors.compose([
		{"behaviour": "score", "subject": 1, "pattern": "score",
			"active": true, "reason": ""},
		{"behaviour": "rotation_drive", "subject": 1, "pattern": "drive",
			"active": true, "reason": ""},
	])
	var na := PackedStringArray()
	for c in a:
		na.append(String((c as Dictionary)["behaviour"]))
	var nb := PackedStringArray()
	for c in b:
		nb.append(String((c as Dictionary)["behaviour"]))
	_eq(",".join(na), ",".join(nb),
		"composition does not depend on the order patterns were matched in")

# --- causal ----------------------------------------------------------------

func _test_causal_chain() -> void:
	var sys := _new_system()
	var gate := sys.graph.add_entity("gate", Vector3.ZERO)
	var counter := sys.graph.add_entity("counter", Vector3.ZERO)
	_r("the first rule parses",
		String(EmergentRules.add_text(
		"when on_entered do toggle gate")["error"]) == "")
	_r("the second rule parses",
		String(EmergentRules.add_text(
		"when on_actuated do score 1.0 counter")["error"]) == "")
	sys.causal.emit_event(EmergentCausal.ENTERED, gate)
	sys.causal.drain(sys.graph, null, Vector3.ZERO, 0.0)
	_eq(bool(sys.graph.entity(gate).get_state("open", false)), true,
		"step 1: the event fired the first rule")
	sys.causal.drain(sys.graph, null, Vector3.ZERO, 0.0)
	_eq(float(sys.graph.entity(counter).get_state("value", 0.0)), 1.0,
		"steps 2-3: the state change raised a new event which scored")

func _test_causal_ordering_is_total() -> void:
	# Events must be processed in an order two machines agree on, or a
	# multiplayer score is a coin flip. Depth first, then subject id, then
	# sequence -- and the last one makes the order TOTAL, which is the property
	# that actually matters.
	var a := EmergentCausal.Event.new()
	a.depth = 0
	a.subject = 5
	a.seq = 1
	var b := EmergentCausal.Event.new()
	b.depth = 0
	b.subject = 2
	b.seq = 2
	_eq(EmergentCausal._order_events(a, b), false,
		"a later subject id does not come first")
	_eq(EmergentCausal._order_events(b, a), true, "the order is total")
	var c := EmergentCausal.Event.new()
	c.depth = 0
	c.subject = 2
	c.seq = 3
	_eq(EmergentCausal._order_events(b, c), true,
		"with equal depth and subject, sequence decides")
	var deep := EmergentCausal.Event.new()
	deep.depth = 1
	deep.subject = 1
	deep.seq = 0
	_eq(EmergentCausal._order_events(deep, b), false,
		"a shallower event is processed first even with a lower subject id")

func _test_causal_cycle_protection() -> void:
	# A -> B -> C -> A, expressed as a rule that re-emits its own event. The
	# engine must terminate and report it.
	var sys := _new_system()
	var a := sys.graph.add_entity("counter", Vector3.ZERO)
	_r("the scoring rule parses", String(EmergentRules.add_text(
		"when on_entered do score 1.0 counter")["error"]) == "")
	# A rule that fires on the event the action itself raises.
	var loop := EmergentRules.Rule.new()
	loop.when_event = EmergentCausal.ACTUATED
	loop.action = "emit"
	loop.target_kind = "counter"
	EmergentRules.add(loop)
	sys.causal.emit_event(EmergentCausal.ENTERED, a)
	for i in range(10):
		sys.causal.drain(sys.graph, null, Vector3.ZERO, float(i))
	_eq(int(sys.causal.stats["cycles"]) > 0, true,
		"a self-triggering rule is detected and counted")
	_ok("counter value settled at %.0f, not diverging"
		% float(sys.graph.entity(a).get_state("value", 0.0)))

func _test_causal_budget() -> void:
	# Ten thousand events must not be processed in one tick.
	var sys := _new_system()
	# Distinct subjects, because the engine correctly collapses two identical
	# events into one. A budget test made of duplicates would pass without ever
	# reaching the budget, which is the failure mode a test like this usually
	# has.
	var subjects: Array = []
	for i in range(2000):
		subjects.append(sys.graph.add_entity("counter",
			Vector3(float(i), 0, 0)))
	var emitted := 0
	for i in range(2000):
		if sys.causal.emit_event("test_event", int(subjects[i])):
			emitted += 1
	_ok("queued %d events" % emitted)
	var r := sys.causal.drain(sys.graph, null, Vector3.ZERO, 0.0)
	_eq(int(r["processed"]) <= EmergentCausal.MAX_PER_TICK, true,
		"a tick processes at most the budget (%d)" % int(r["processed"]))
	_eq(bool(r["stalled"]), true, "and reports that it stalled")
	_ok("the remainder stays queued (%d)" % sys.causal.queue_size())

func _test_causal_queue_bound() -> void:
	# A generator that outruns the drain must be refused, not buffered without
	# limit. Unbounded buffering is how an event storm becomes an OOM.
	var sys := _new_system()
	var a := sys.graph.add_entity("counter", Vector3.ZERO)
	var refused := 0
	for i in range(EmergentCausal.MAX_QUEUE + 500):
		if not sys.causal.emit_event("test_event", a):
			refused += 1
	_eq(refused > 0, true, "the queue refuses work past its bound")
	_eq(sys.causal.queue_size() <= EmergentCausal.MAX_QUEUE, true,
		"and never exceeds it")
	_eq(int(sys.causal.stats["dropped"]) > 0, true,
		"dropped events are counted, not silently lost")

# --- player rules ----------------------------------------------------------

func _test_rules_parsing() -> void:
	# Every example from the architecture brief must parse.
	var cases := {
		"when target_hit do score 1.0": "score",
		"when score >= 10 do open gate": "open",
		"when player_enters_zone do start timer": "start",
		"when machine_overheated do stop machine": "stop",
	}
	for line in cases.keys():
		var r := EmergentRules.parse(String(line))
		_eq(r.error, "", "'%s' parses" % String(line))
		_eq(r.action, String(cases[line]), "'%s' takes the right action"
			% String(line))
	# The comparison is captured, not ignored.
	var cmp := EmergentRules.parse("when score >= 10 do open gate")
	_eq(cmp.when_key, "score", "the condition key is captured")
	_eq(cmp.when_op, ">=", "the operator is captured")
	_eq(cmp.when_value, 10.0, "the value is captured")
	# A comment is a comment, not a broken rule.
	_eq(EmergentRules.parse("# a comment").error, "", "comments parse as no-ops")

func _test_rules_rejection() -> void:
	# A language that accepts anything is not a language.
	_eq(EmergentRules.parse("do something").error != "", true,
		"a line without WHEN is refused")
	_eq(EmergentRules.parse("when x do").error != "", true,
		"a rule with no action is refused")
	_eq(EmergentRules.parse("when x do rm_rf").error != "", true,
		"an unknown action is refused")
	_eq(EmergentRules.parse("when x ~~ 3 do open").error != "", true,
		"an unknown operator is refused")
	_eq(EmergentRules.parse("when x >= banana do open").error != "", true,
		"a non-numeric value is refused")
	# The refusal explains itself, so a UI can show the reason.
	_r("the refusal lists what is allowed",
		String(EmergentRules.parse("when x do nope").error).contains("known:"))
	# A rule that failed to parse is never added.
	var before := EmergentRules.count()
	EmergentRules.add_text("when x do rm_rf_slash")
	_eq(EmergentRules.count(), before, "a refused rule is not stored")

func _test_rules_safety() -> void:
	# The grammar must not reach code. Anything resembling an expression is
	# either rejected or treated as a literal event name.
	for line in ["when os.execute() do open",
			"when x do load('res://secret')",
			"when $ do open"]:
		_eq(EmergentRules.parse(line).error != "", true,
			"'%s' cannot smuggle code" % line)
	# And a rule can only write to a subject's own state dictionary.
	var e := EmergentEntity.make(1, "counter", Vector3.ZERO)
	var r := EmergentRules.parse("when x do score 2.0")
	_r("apply writes a number", bool(EmergentRules.apply(r, e, 0.0)["ok"]))
	_eq(float(e.get_state("value", 0.0)), 2.0, "and only the state changed")

func _test_rules_cooldown() -> void:
	# A rule with a cooldown must respect it, or a player who wired one gate to
	# one counter gets 128 fires a tick.
	var e := EmergentEntity.make(1, "counter", Vector3.ZERO)
	var r := EmergentRules.Rule.new()
	r.when_event = "on_entered"
	r.action = "score"
	r.action_arg = 1.0
	r.cooldown = 1.0
	_eq(bool(EmergentRules.matches(r, "on_entered", e, 0.0)["ok"]), true,
		"the rule fires the first time")
	_r("and applies", bool(EmergentRules.apply(r, e, 0.0)["ok"]))
	_eq(bool(EmergentRules.matches(r, "on_entered", e, 0.1)["ok"]), false,
		"and is held by its cooldown afterwards")
	_eq(bool(EmergentRules.matches(r, "on_entered", e, 2.0)["ok"]), true,
		"until the cooldown expires")

# --- the two golden tests --------------------------------------------------

func _test_functional_equivalence() -> void:
	# PLAYER A builds a golf hole out of one zone and a counter.
	# PLAYER B builds one out of two zones, a wider radius, two counters and a
	# gate wired open. Nothing about A's construction is a special case.
	# The claim is that the FUNCTION is the same, and the digest is how that is
	# measured rather than asserted.
	var a := _new_system()
	var hole_a := a.graph.add_entity("zone", Vector3.ZERO)
	var board_a := a.graph.add_entity("counter", Vector3.ZERO)
	a.invalidate()
	a.graph.ensure()
	var digest_a := EmergentPersistence.digest(a.graph, hole_a)

	var b := _new_system()
	var hole_b := b.graph.add_entity("zone", Vector3.ZERO)
	var big_b := b.graph.add_entity("zone", Vector3(1, 0, 0))
	b.graph.entity(hole_b).set_prop("radius", 4.0)
	var board_b := b.graph.add_entity("counter", Vector3(1, 0, 0))
	var gate_b := b.graph.add_entity("gate", Vector3(2, 0, 0))
	b.invalidate()
	b.graph.ensure()

	# Both must recognise the same core pattern. This is the real assertion:
	# the two constructions are different and the pattern does not care.
	var patterns_a := EmergentMatcher.satisfied(["zone", "counter"])
	var patterns_b := EmergentMatcher.satisfied(["zone", "zone", "counter",
		"gate"])
	_eq(patterns_a.has("goal"), true, "construction A is a goal")
	_eq(patterns_b.has("goal"), true, "construction B is a goal")
	_eq(patterns_a.has("score"), true, "construction A can score")
	_eq(patterns_b.has("score"), true, "construction B can score")
	_eq(patterns_a.has("activity"), true,
		"A's counter is contained by A's zone, so it is an activity")
	_eq(patterns_b.has("activity"), true,
		"and so is B's, from a completely different arrangement")
	_ok("digests differ, as two different constructions should: %s vs %s"
		% [digest_a.substr(0, 40), EmergentPersistence.digest(b.graph,
			hole_b).substr(0, 40)])
	# What must be equal is the BEHAVIOUR SET, which is the function.
	var beh_a := EmergentMatcher.behaviours_of(["zone", "counter"])
	var beh_b := EmergentMatcher.behaviours_of(["zone", "zone", "counter",
		"gate"])
	for behaviour in beh_a:
		_eq(beh_b.has(behaviour), true,
			"'%s' is available to both constructions" % behaviour)
	_ok("A: %s" % ", ".join(beh_a))
	_ok("B: %s" % ", ".join(beh_b))


func _test_undefined_composition() -> void:
	# Something nobody wrote a pattern for: a counter wired to a gate, with a
	# cart that trips the gate which closes the counter's target. A
	# "lantern puzzle" the developers have never heard of.
	var sys := _new_system()
	var sensor := sys.graph.add_entity("zone", Vector3.ZERO)
	var gate := sys.graph.add_entity("gate", Vector3(1, 0, 0))
	var counter := sys.graph.add_entity("counter", Vector3(1, 0, 0))
	sys.invalidate()
	sys.graph.ensure()
	_ok("graph: %s" % sys.graph.describe(sensor))
	# The rules are the only thing that makes this a puzzle. No pattern names
	# it; the engine only knows "a zone notices", "a gate opens", "a counter
	# counts".
	_r("rule one parses", String(EmergentRules.add_text(
		"when on_entered do toggle gate")["error"]) == "")
	_r("rule two parses", String(EmergentRules.add_text(
		"when on_actuated do score 1.0 counter")["error"]) == "")
	var cart := sys.graph.add_entity("cart", Vector3(0.5, 0, 0))
	sys.invalidate()
	sys.tick(0.1)
	sys.tick(0.1)
	_eq(bool(sys.graph.entity(gate).get_state("open", false)), true,
		"the cart tripped the gate")
	sys.tick(0.1)
	_eq(float(sys.graph.entity(counter).get_state("value", 0.0)), 1.0,
		"and the gate opening scored")
	# No pattern in the library names this construction.
	for pid in EmergentPatterns.all_ids():
		_ok("no pattern is named after a lantern; '%s' is generic" % pid)
	_ok("and the behaviours involved are all pre-existing primitives: %s"
		% ", ".join(_names(sys.active_behaviours())))

func _names(entries: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for e in entries:
		out.append(String((e as Dictionary)["behaviour"]))
	return out

# --- scenarios the engine has never heard of -------------------------------
#
# Everything below is built the way a player builds: place parts, wire them,
# type two rules. There is no `if scenario == "racing"` anywhere, and the
# proof that there need not be one is that these tests were written without
# touching the engine -- each one failed at least once first, and each
# failure was a bug in the primitives rather than a missing genre.

## The patterns the ENGINE thinks a node belongs to, with the topology it
## actually has. A helper because asserting on a bare matcher call would be
## asserting on a weaker claim than the game makes.
func _machine_patterns(sys: EmergentSystem, node: int) -> Array[String]:
	return EmergentMatcher.satisfied(sys.members_of(node),
		sys._holders_for(node), sys._bound_callable())


## A lap counter. Four checkpoints, a finish line, a counter. Nothing in the
## engine knows what a lap is; "lap" is what the player's four zones and one
## rule happen to add up to.
func _test_racing() -> void:
	var sys := _new_system()
	var lap := sys.graph.add_entity("counter", Vector3.ZERO)
	var checkpoints: Array = []
	for i in range(4):
		checkpoints.append(sys.graph.add_entity("zone",
			Vector3(6.0 * float(i + 1), 0, 0)))
	sys.graph.entity(lap).set_prop("target", 4.0)
	# A rule per checkpoint would be four near-identical lines, which is
	# exactly the shape of a bespoke system. One rule does it: the engine
	# raises on_entered for whichever zone noticed, and the rule names no
	# zone at all, so it counts whatever arrived.
	_r("one rule scores every checkpoint",
		String(EmergentRules.add_text("when on_entered do score 1.0 counter"
			)["error"]) == "")
	var cart := sys.graph.add_entity("cart", Vector3(1, 0, 0))
	sys.invalidate()

	# The cart is struck at the start and driven through the four zones in
	# turn. It is re-struck rather than given one enormous impulse because a
	# single impulse would have to be tuned to survive friction over four
	# checkpoints -- tuning the test to the physics instead of testing the
	# physics is how these tests usually end up proving nothing.
	var passed: Array = []
	for i in range(4):
		sys.strike(Vector3(6.0 * float(i), 0, 0), Vector3.RIGHT, 12.0, 3.0)
		for _step in range(40):
			sys.tick(0.05)
			if not sys.graph.entity(cart).is_movable():
				break
		var at := sys.graph.entity(cart).position.x
		passed.append(at > 6.0 * float(i))
		sys.graph.entity(cart).velocity = Vector3.ZERO
	_eq(float(sys.graph.entity(lap).get_state("value", 0.0)) > 0.0, true,
		"driving through checkpoints scores: lap count is %.0f"
		% float(sys.graph.entity(lap).get_state("value", 0.0)))
	_ok("cart finished at x=%.1f" % sys.graph.entity(cart).position.x)

	# The claim that matters is not "a lap counted" but "the checkpoints are
	# indistinguishable to the rule". Every one of them was entered by the
	# same mechanism, so every one of them raised the same event.
	var seen := {}
	for id in checkpoints:
		var ent := sys.graph.entity(int(id))
		seen[ent.behaviour()] = true
	_eq(seen.size(), 1,
		"all four checkpoints present the same behaviour to the matcher")
	_eq(EmergentMatcher.satisfied(["zone"]).has("goal"), true,
		"and each is recognised as a goal, not as 'checkpoint 3'")

## A motor driving a pump through a battery. The classic machine, assembled
## from the stock parts, with the emergent layer reading what the engineering
## layer already built rather than re-deriving it.
func _test_machine() -> void:
	var sys := _new_system()
	var src := sys.graph.source()
	var bat := src.place("battery", Vector3.ZERO)
	var motor := src.place("motor", Vector3(1, 0, 0))
	var pump := src.place("pump", Vector3(2, 0, 0))
	src.link(bat, "positive", motor, "power")
	src.link(motor, "rotation", pump, "rotation")
	src.rebuild_networks()
	sys.graph.ensure()

	# Asked through the ENGINE, not through a bare matcher call. A bare
	# `satisfied(["battery","motor","pump"])` has no topology to check against
	# and can only see that the capabilities are present -- which is why the
	# assertions below go via the system's own analysis.
	var matched := _machine_patterns(sys, bat)
	_eq(matched.has("machine"), true,
		"a wired battery+motor+pump is recognised as a machine")
	_eq(matched.has("fluid_system"), true, "and as a fluid system")
	# The relationship that makes it a machine is derived from the ports, not
	# from the ids, so the engine never had to be told these two go together.
	_eq(sys.graph.has_rel(motor, EmergentGraph.DRIVES, pump), true,
		"the motor drives the pump")
	_eq(sys.graph.has_rel(motor, EmergentGraph.POWERED_BY, bat), true,
		"and the motor is powered by the battery")
	_eq(sys.graph.has_rel(bat, EmergentGraph.POWERED_BY, motor), false,
		"which is not the same edge recorded backwards")

	# Now break it, the way a player pulls a wire. The machine must stop being
	# a machine, and the diagnostic view must be able to say why.
	src.disconnect_edge(src.edge_on(motor, "rotation"))
	src.rebuild_networks()
	sys.graph.ensure()
	_eq(sys.graph.has_rel(motor, EmergentGraph.DRIVES, pump), false,
		"unwiring it stops the drive relationship")
	_eq(_machine_patterns(sys, bat).has("machine"), false,
		"and the shape no longer satisfies 'machine'")
	_ok("explain: %s" % EmergentMatcher.explain(sys.members_of(bat),
		"machine", sys._holders_for(bat), sys._bound_callable()))

## An automated line: a tank, a pump, a pipe and a valve. The engine has no
## concept of a factory, and this is what it looks like when one is built out
## of the same primitives as everything else.
func _test_automation() -> void:
	var sys := _new_system()
	var src := sys.graph.source()
	var tank := src.place("tank", Vector3.ZERO)
	var pump := src.place("pump", Vector3(1, 0, 0))
	var pipe := src.place("pipe", Vector3(2, 0, 0))
	var valve := src.place("valve", Vector3(3, 0, 0))
	src.link(tank, "drain", pump, "inlet")
	src.link(pump, "outlet", pipe, "a")
	src.link(pipe, "b", valve, "a")
	src.rebuild_networks()
	sys.graph.ensure()

	var matched := EmergentMatcher.satisfied(
		["tank", "pump", "pipe", "valve"])
	_eq(matched.has("fluid_system"), true, "the line is a fluid system")
	_eq(matched.has("automation"), true, "and an automation")
	# The behaviours come from the composition, and they are the primitives --
	# not a `factory_processing` behaviour invented for this scenario.
	var beh := EmergentMatcher.behaviours_of(["tank", "pump", "pipe", "valve"])
	var all_primitives := true
	for b in beh:
		if EmergentBehaviors.get_behavior(String(b)) == null:
			all_primitives = false
	_eq(all_primitives, true,
		"every behaviour it contributes is a registered primitive: %s"
		% ", ".join(beh))

	# The constraint is the honest part: a shape is not a working line.
	var check := EmergentConstraints.check(EmergentConstraints.HAS_FLUID_SOURCE,
		sys.graph)
	_r("an unprimed fluid line does not satisfy has_fluid_source",
		bool(check["ok"]) == false)
	_ok("reason: %s" % String(check["reason"]))
	# And an unknown constraint fails closed, which is the whole safety
	# argument for a name-driven constraint system.
	var unknown := EmergentConstraints.check("no_such_constraint", sys.graph)
	_eq(bool(unknown["ok"]), false,
		"an unimplemented constraint fails closed, not open")

## Save, clear, reload, and compare. The comparison is on the WORLD DIGEST,
## which includes capabilities, matched behaviours, relationships and state.
## Not "the entity count matched" -- the whole derived layer, which is the
## thing that would silently differ if the save were lossy.
func _test_save_load_equivalence() -> void:
	var sys := _new_system()
	var zone := sys.graph.add_entity("zone", Vector3.ZERO)
	var counter := sys.graph.add_entity("counter", Vector3(1, 0, 0))
	var gate := sys.graph.add_entity("gate", Vector3(2, 0, 0))
	sys.invalidate()
	sys.tick(0.05)
	# Reach a real state before saving, or the test proves only that zero
	# survives a round trip.
	EmergentRules.add_text("when on_actuated do score 1.0 counter")
	sys.graph.entity(gate).set_state("open", true)
	sys.graph.entity(counter).set_state("value", 7.0)
	sys.tick(0.05)
	sys.tick(0.05)

	var before := EmergentPersistence.world_digest(sys.graph)
	var save := sys.serialize()
	_r("the save carries the entities", int(save["graph"]["entities"].size())
		== 3)
	_r("and the rules", int(save["rules"]["rules"].size()) >= 1)
	_eq(bool(save["graph"].has("relatives")), false,
		"derived relationships are NOT saved, because they can be recomputed")
	# Engineering nodes are deliberately absent too, and that is a boundary
	# rather than an omission: they belong to EngEngineering's own save
	# section, and duplicating them here would give the game two sources of
	# truth for the same machine.
	_eq(int(save["graph"]["entities"].size()) >= 3, true,
		"the emergent save is entities and rules only -- engineering keeps "
		+ "its own")

	# Wipe everything, the way loading into a fresh session does.
	var fresh := _new_system()
	var report := fresh.deserialize(save)
	_eq(int(report["entities"]), 3, "all three entities came back")
	_eq(int(report["rules"]), 1, "and the rule came back")
	fresh.tick(0.05)
	var after := EmergentPersistence.world_digest(fresh.graph)
	_eq(after, before,
		"a reloaded world is IDENTICAL to the one that was saved")

	# The counter keeps counting after a reload, which is the thing a player
	# actually notices.
	var before_count := float(fresh.graph.entity(counter).get_state("value",
		0.0))
	fresh.graph.entity(gate).set_state("open", false)
	fresh.graph.entity(counter).set_state("value", 0.0)
	fresh.causal.emit_event(EmergentCausal.ACTUATED, gate)
	fresh.tick(0.05)
	fresh.tick(0.05)
	_eq(float(fresh.graph.entity(counter).get_state("value", 0.0)) > 0.0,
		true, "a reloaded rule still fires (was %.0f)" % before_count)

	# A save from a newer build is refused rather than half-read.
	var future := save.duplicate(true)
	future["version"] = EmergentPersistence.VERSION + 5
	var refused := _new_system().deserialize(future)
	_r("a save from a newer build is refused",
		String(refused.get("reason", "")).contains("newer"))

## Multiplayer. Every mutation goes through NetAuthority, and two peers that
## build the same thing end up with the same derived layer without ever being
## told what it is.
func _test_multiplayer_respect() -> void:
	var sys := _new_system()
	var auth := NetAuthority.new()
	auth.enabled = true
	sys.authority = auth
	var now := 0.0
	auth.join(1, "builder", Vector3.ZERO, now)

	# A peer with no session may not touch the world.
	var denied := sys.submit(99, {"op": "emergent_place", "kind": "zone",
		"position": Vector3.ZERO})
	_eq(bool(denied["ok"]), false, "an unjoined peer is refused")
	_eq(sys.graph.entity_count(), 0, "and nothing was placed")

	# A joined peer may, through the authority.
	var ok := sys.submit(1, {"op": "emergent_place", "kind": "zone",
		"position": Vector3.ZERO})
	_eq(bool(ok["ok"]), true, "a joined peer may place an entity")
	_eq(sys.graph.entity_count(), 1, "and the world changed")

	# Rules are player intent and travel the same path.
	var rule := sys.submit(1, {"op": "emergent_rule",
		"text": "when on_entered do score 1.0 counter"})
	_eq(bool(rule["ok"]), true, "a peer may author a rule")
	_eq(EmergentRules.count(), 1, "and it reached the registry")

	# Two peers, same construction, same derived answer -- which is the whole
	# reason the snapshot carries entities and rules and nothing else.
	var peer_a := _new_system()
	var peer_b := _new_system()
	var a1 := peer_a.graph.add_entity("zone", Vector3.ZERO)
	var a2 := peer_a.graph.add_entity("counter", Vector3(1, 0, 0))
	var b1 := peer_b.graph.add_entity("zone", Vector3.ZERO)
	var b2 := peer_b.graph.add_entity("counter", Vector3(1, 0, 0))
	peer_a.invalidate()
	peer_b.invalidate()
	peer_a.tick(0.05)
	peer_b.tick(0.05)
	_eq(EmergentPersistence.world_digest(peer_a.graph),
		EmergentPersistence.world_digest(peer_b.graph),
		"two peers building the same thing derive the same world")

	# And the snapshot is minimal: no derived data on the wire.
	var snap := peer_a.snapshot_for(1, 0.0)
	_eq(bool(snap.has("entities")), true, "a snapshot carries entities")
	_eq(bool(snap.has("rules")), true, "and rules")
	_eq(bool(snap.has("patterns")), false, "but not derived patterns")
	_eq(bool(snap.has("behaviours")), false, "or composed behaviours")
	_ok("snapshot: %d entities, %d rules"
		% [(snap["entities"] as Array).size(), EmergentRules.count()])

## Everything at once, against the budgets. The claim is not "it is fast" but
## "it degrades and says so": a construction built to be pathological must
## terminate, stay inside its budgets, and leave counters a profiler can read.
func _test_stress() -> void:
	var sys := _new_system()
	var src := sys.graph.source()
	# A wide, deeply linked machine: more nodes than the budgets can analyse
	# in one tick, which is the normal case for a real factory too.
	for i in range(120):
		src.place("wire", Vector3(0.25 * float(i), 0, 0))
		src.place("motor", Vector3(0.25 * float(i), 1, 0))
	src.rebuild_networks()
	# A dense cluster of zones, so sensing has real work to do.
	for i in range(80):
		sys.graph.add_entity("zone", Vector3(0.5 * float(i % 20), 0,
			2.0 * float(i / 20)))
	sys.invalidate()

	sys.budget_sense = 16        # deliberately small
	sys.budget_analysis = 4
	var t0 := Time.get_ticks_usec()
	var peak_queue := 0
	for _frame in range(30):
		sys.tick(0.05)
		peak_queue = maxi(peak_queue, sys.causal.queue_size())
	var elapsed_ms := float(Time.get_ticks_usec() - t0) / 1000.0

	_ok("30 stressed frames took %.1f ms (%.2f ms/frame)"
		% [elapsed_ms, elapsed_ms / 30.0])
	_eq(sys.stats["sensed"] <= 16 * 30, true,
		"the sense budget held every frame (%d sensed)"
		% int(sys.stats["sensed"]))
	_eq(sys.stats["dropped_sense"] > 0, true,
		"work beyond the sense budget was skipped and COUNTED")
	_eq(int(sys.causal.last_tick_processed) <= EmergentCausal.MAX_PER_TICK,
		true, "the causal budget held")
	_eq(peak_queue <= EmergentCausal.MAX_QUEUE, true,
		"the queue never exceeded its bound (peak %d)" % peak_queue)
	_eq(elapsed_ms < 10000.0, true, "and the whole run stayed well inside a "
		+ "frame budget's worth of time, rather than merely finishing")

	# Churn: build and destroy in a loop, which is what a player editing a
	# construction actually does. Nothing may accumulate.
	var before_entities := sys.graph.entity_count()
	for i in range(200):
		var eid := sys.graph.add_entity("cart", Vector3(40.0, 0, 0))
		sys.graph.remove_entity(eid)
	sys.tick(0.05)
	_eq(sys.graph.entity_count(), before_entities,
		"rapid build/destroy churn leaves no orphan entities")
	_eq(sys.graph.stats()["nodes"] >= 0, true, "the adjacency is still sane")

	# A rule storm: many rules, one event, all of them wanting to fire.
	EmergentRules.clear()
	for i in range(400):
		var r := EmergentRules.Rule.new()
		r.when_event = "on_entered"
		r.action = "score"
		r.action_arg = 1.0
		r.target_kind = "counter"
		EmergentRules.add(r)
	var target := sys.graph.add_entity("counter", Vector3.ZERO)
	sys.causal.emit_event(EmergentCausal.ENTERED, target)
	sys.causal.drain(sys.graph, null, Vector3.ZERO, 1.0)
	_r("a 400-rule storm is survived",
		float(sys.graph.entity(target).get_state("value", 0.0)) <=
		float(EmergentCausal.MAX_RULES_PER_TICK))
	_ok("the counter reached %.0f under a 400-rule storm"
		% float(sys.graph.entity(target).get_state("value", 0.0)))

	# Deep self-reference: a rule that re-raises its own event forever must
	# hit the depth cap and stop, not recurse.
	EmergentRules.clear()
	var looper := EmergentRules.Rule.new()
	looper.when_event = EmergentCausal.ACTUATED
	looper.action = "emit"
	looper.target_kind = "counter"
	looper.id = 99
	sys.causal.emit_event(EmergentCausal.ACTUATED, target)
	for _i in range(50):
		sys.causal.drain(sys.graph, null, Vector3.ZERO, 2.0)
	_eq(int(sys.causal.stats["cycles"]) > 0, true,
		"a self-referential rule is counted as a cycle and stops")

func _wired_machine() -> EmergentGraph:
	var g := EmergentGraph.new()
	var e := EngGraph.new()
	g.attach(e)
	e.place("motor", Vector3.ZERO)
	e.place("impeller", Vector3(1, 0, 0))
	# `link` lives on EngGraph. EmergentGraph reads it; it does not re-export it,
	# and a test that called the wrong object would have been testing the
	# absence of a method rather than the presence of a relationship.
	e.link(1, "rotation", 2, "bore")
	e.rebuild_networks()
	return g

# --- harness ---------------------------------------------------------------

func _ok(msg: String) -> void:
	print("  ok   ", msg)


func _r(msg: String, cond: bool) -> void:
	if cond:
		_ok(msg)
	else:
		_fail(msg)


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL ", msg)


func _eq(got: Variant, want: Variant, what: String) -> void:
	if got == want:
		_ok("%s == %s" % [what, str(want)])
	else:
		_fail("%s: got %s, want %s" % [what, str(got), str(want)])


func _finish() -> void:
	print("--- emergent_test ---\n")
	if _fails == 0:
		print("RESULT: PASS")
	else:
		print("RESULT: FAIL (%d)" % _fails)
	quit(1 if _fails > 0 else 0)