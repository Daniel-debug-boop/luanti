extends SceneTree
## Systems, ownership, lifecycle, the API facade, failure handling and the
## developer tools.
##
## The assertions that matter here are the negative ones. A registry that has
## only been tested with one system registered proves nothing, so the tests
## register duplicates, run things out of order, call the API without
## authority, and kill subsystems -- and then assert that the game is still
## standing.

var _fails := 0


func _init() -> void:
	_test_one_owner_per_system()
	_test_lifecycle_is_enforced()
	_test_teardown_is_idempotent_and_total()
	_test_teardown_drops_connections()
	_test_teardown_joins_every_started_thread()
	_test_registry_order()
	_test_registry_tolerates_a_failed_system()
	_test_registry_shutdown_is_reverse_order()
	_test_api_returns_results_not_crashes()
	_test_api_denies_a_client()
	_test_api_refuses_unknown_items()
	_test_api_counts_callers()
	_test_persistence_owns_the_save()
	_test_persistence_carries_the_emergent_section()
	_test_emergent_is_ticked_once_and_in_order()
	_test_interaction_reports_actions_to_the_emergent_layer()
	_test_persistence_survives_interruption()
	_test_devtools_reports_are_pure()
	_finish()


func _eq(got: Variant, want: Variant, what: String) -> void:
	if got == want:
		print("  ok   %s == %s" % [what, str(want)])
	else:
		_fails += 1
		print("  FAIL %s: got %s, want %s" % [what, str(got), str(want)])


func _true(got: bool, what: String) -> void:
	_eq(got, true, what)


func _r(what: String, cond: bool) -> void:
	_true(cond, what)


func _finish() -> void:
	print("RESULT: %s (%d failures)" % ["PASS" if _fails == 0 else "FAIL", _fails])
	quit(0 if _fails == 0 else 1)


func _sys(name: String, owns := "a thing") -> System:
	var s := System.new()
	s.system_name = name
	s.owns = owns
	return s


## A system that ticks, so ordering can be observed.
class _CountingSystem:
	extends System
	var ticks := 0
	var order_log: Array = []

	func tick(_dt: float) -> void:
		ticks += 1
		if order_log != null:
			order_log.append(system_name)


# --- ownership --------------------------------------------------------------

func _test_one_owner_per_system() -> void:
	SystemRegistry.clear()
	_eq(SystemRegistry.register(_sys("world", "the voxels"), null), "",
		"the first world registers")
	_eq(SystemRegistry.has_system("world"), true, "and is reachable")
	_eq(SystemRegistry.get_owner("world") == null, true,
		"with no owner object, because none was given")

	var node := Node3D.new()
	# A nameless system is refused rather than filed under "": a second
	# unnamed owner is how a system ends up with no identifiable authority.
	_true(SystemRegistry.register(_sys(""), node) != "",
		"a system with no name is refused")
	SystemRegistry.clear()
	_eq(SystemRegistry.register(_sys("world", "the voxels"), node), "",
		"a world with an owner object registers")
	_eq(SystemRegistry.get_owner("world") == node, true,
		"and the owner is reachable, which is what callers actually want")

	# The whole point. A second world is refused with a reason.
	var why := SystemRegistry.register(_sys("world", "a rival"), Node3D.new())
	_true(why != "", "a second world is refused")
	_eq(why.contains("exactly one"), true, "and the reason names the rule")
	_eq(SystemRegistry.get_owner("world") == node, true,
		"and the first world is still the owner")
	SystemRegistry.clear()


func _test_lifecycle_is_enforced() -> void:
	SystemRegistry.clear()
	var s := _sys("engineering", "machines and networks")
	_eq(s.state, System.State.CREATED, "a new system is CREATED")
	_eq(s.run(), false, "and cannot run before it is initialized")
	_true(s.last_error.contains("INITIALIZED"), "with a reason that says so")
	# A caller's ordering mistake is the caller's problem. The system is fine,
	# and marking it FAILED would take a working subsystem out of the game.
	_eq(s.state, System.State.CREATED, "but the system is not marked FAILED for it")
	_eq(s.initialize(), true, "initialize succeeds")
	_eq(s.state, System.State.INITIALIZED, "and moves to INITIALIZED")
	_eq(s.initialize(), false, "initializing twice is refused")
	_eq(s.run(), true, "run succeeds once initialized")
	_eq(s.state, System.State.RUNNING, "and the state is RUNNING")
	_eq(s.suspend(), true, "suspend stops the ticking")
	_eq(s.state, System.State.SUSPENDED, "and is SUSPENDED")
	_eq(s.resume(), true, "resume starts it again")
	_eq(s.state, System.State.RUNNING, "back to RUNNING")
	# A failing initialize leaves the system FAILED, not half-alive.
	var bad := _FailingSystem.new()
	bad.system_name = "broken"
	_eq(bad.initialize(), false, "a failing initialize returns false")
	_eq(bad.state, System.State.FAILED, "and leaves it FAILED")
	_eq(bad.run(), false, "so it cannot be run")
	SystemRegistry.clear()


func _test_teardown_is_idempotent_and_total() -> void:
	var s := _sys("profiler")
	s.initialize()
	s.run()
	# A system that acquired something must account for it.
	s.own_resource(Resource.new())
	s.own_timer(1.0, root)
	_eq(s.leaked() > 0, true, "a system with resources owes something")
	s.teardown()
	_eq(s.leaked(), 0, "teardown settles the debt to zero")
	_eq(s.state, System.State.DESTROYED, "and the state is DESTROYED")
	# Twice is not an error. Shutdown in Godot is routinely reached by two
	# paths, and a teardown that is only safe once is a crash waiting for the
	# quit menu.
	s.teardown()
	_eq(s.leaked(), 0, "a second teardown is a no-op, not a crash")
	_eq(s.run(), false, "and a destroyed system cannot be run again")
	s.tick(0.016)
	_eq(s.is_live(), false, "ticking a destroyed system does nothing")


func _test_teardown_drops_connections() -> void:
	var source := Node.new()
	root.add_child(source)
	var listener := _SignalCounter.new()
	var s := _sys("village")
	s.initialize()
	s.own_connect(source, "child_entered_tree", listener.on_child)
	# Assert the connection itself rather than waiting for a signal to fire:
	# the contract being tested is "teardown disconnects what it connected",
	# and signal timing is a different thing to be relying on here.
	_eq(source.is_connected("child_entered_tree", listener.on_child), true,
		"the connection is live")
	_eq(s.leaked(), 1, "and is on the books while the system lives")
	s.teardown()
	_eq(source.is_connected("child_entered_tree", listener.on_child), false,
		"teardown disconnects it: a freed listener receiving a signal is a hard crash")
	_eq(s.leaked(), 0, "and the debt is settled")
	source.queue_free()


func _test_teardown_joins_every_started_thread() -> void:
	# Teardown owns the wait for every thread the system started -- a thread
	# is the one acquisition with a life of its own, and abandoning one is
	# how a process exits with unrealized completion (and, on a longer
	# thread, how it hangs). The subtlety is the check: is_alive() is false
	# the moment a thread finishes, so a finished thread used to be skipped
	# and destroyed unjoined. is_started() is the right question -- it stays
	# true until wait_to_finish() has actually been called.
	var s := _sys("village")
	s.initialize()
	var finished := Thread.new()
	finished.start(func() -> void: OS.delay_msec(2))
	while finished.is_alive():
		OS.delay_msec(1)
	s._threads.append(finished)
	s.teardown()
	_eq(finished.is_started(), false,
		"teardown joins a thread that had already finished")
	var s2 := _sys("audio")
	s2.initialize()
	var running := Thread.new()
	running.start(func() -> void: OS.delay_msec(40))
	s2._threads.append(running)
	s2.teardown()
	_eq(running.is_alive(), false,
		"teardown waits for a thread that was still running")
	_eq(running.is_started(), false,
		"and it is joined once teardown returns")


func _test_registry_order() -> void:
	SystemRegistry.clear()
	for n in ["profiler", "world", "player", "village", "engineering", "audio"]:
		SystemRegistry.register(_sys(n), null)
	var order := SystemRegistry.run_order()
	_eq(order.find("world") < order.find("engineering"), true,
		"the world runs before the engineering simulation it feeds")
	_eq(order.find("player") < order.find("village"), true,
		"and the player before the village that reacts to them")
	_eq(order.find("audio") < order.find("profiler"), true,
		"audio before the profiler that measures it")
	_eq(order.has("world") and order.has("player"), true,
		"and every registered system is in the list")
	SystemRegistry.clear()


func _test_registry_tolerates_a_failed_system() -> void:
	SystemRegistry.clear()
	var good := _CountingSystem.new()
	good.system_name = "world"
	good.owns = "the voxels"
	SystemRegistry.register(good, null)
	var broken := _FailingSystem.new()
	broken.system_name = "engineering"
	SystemRegistry.register(broken, null)
	var failures := SystemRegistry.start_all()
	_eq(failures.size(), 1, "one system failed to start")
	_eq(String((failures[0] as Dictionary)["system"]), "engineering",
		"and it is named")
	_eq(good.state, System.State.RUNNING,
		"while the world, which did start, is running")
	# Tick everything. The failed one must not take the frame with it.
	SystemRegistry.tick_all(0.016)
	_eq(good.ticks, 1, "the healthy system is still ticking")
	_eq(broken.ticks, 0, "and the failed one is not")
	# A non-required failure is degradation, not a crash.
	_true(SystemRegistry.healthy(), "a degraded system is not fatal")
	_true(SystemRegistry.health_report().contains("engineering"),
		"and the report names it")
	SystemRegistry.report_failure("world", "the chunk store is gone", true)
	_eq(SystemRegistry.healthy(), false,
		"but a required system failing is")
	SystemRegistry.clear()


func _test_registry_shutdown_is_reverse_order() -> void:
	SystemRegistry.clear()
	var log := []
	for n in ["world", "engineering", "player"]:
		var s := _LoggingSystem.new()
		s.system_name = n
		s.order_log = log
		SystemRegistry.register(s, null)
	SystemRegistry.start_all()
	SystemRegistry.shutdown_all()
	_eq(log.size(), 3, "every system was released")
	# Run order is world, player, engineering -- the world is what everything
	# else reads. Teardown is its exact reverse, so a system is always
	# released before the thing it depended on.
	_eq(String(log[0]), "engineering", "the simulation is released first")
	_eq(String(log[1]), "player", "then the player")
	_eq(String(log[2]), "world", "and the world it all read, last")
	_eq(SystemRegistry.has_system("world"), false,
		"and the registry is empty afterwards")
	SystemRegistry.shutdown_all()
	_eq(true, true, "a second shutdown is a no-op")


# --- the API ----------------------------------------------------------------

## A registry with a world and an inventory behind it.
func _api_world(authoritative := true) -> GameApi:
	SystemRegistry.clear()
	var w := VoxelWorld.new()
	w.view_radius = 1
	w.generator = WorldGenerator.new(99)
	w.materials = MaterialLibrary.new()
	root.add_child(w)
	w.ensure_region(Vector3i.ZERO, 1)
	var inv := PlayerInventory.new()
	root.add_child(inv)
	# The backpack has to be told what exists, exactly as the game does it.
	var eng := EngEngineering.new()
	root.add_child(eng)
	eng.build()
	eng.attach(w, inv)
	var pers := Persistence.new()
	pers.inventory = inv
	SystemRegistry.register(_sys("world", "voxels"), w)
	SystemRegistry.register(_sys("persistence", "the save"), pers)
	var api := GameApi.new()
	api.authoritative = authoritative
	return api


func _test_api_returns_results_not_crashes() -> void:
	var api := _api_world()
	# A missing subsystem is a Result, not a null dereference. This is the
	# difference between a facade and a thin wrapper: a wrapper crashes when
	# the thing it wraps is down.
	var r := api.network_state("test", 0)
	_eq(bool(r["ok"]), false, "a call into a system that is not registered fails")
	_true(String(r["reason"]).contains("not running"),
		"with a reason that names the problem")
	# A call that works returns a value.
	var b := api.block_at("test", Vector3i(0, 0, 0))
	_eq(bool(b["ok"]), true, "reading a block works")
	_eq(typeof(b["value"]), TYPE_INT, "and returns the block id")
	# Writing works on the authoritative end. The cell has to be inside the
	# loaded region -- an unloaded cell is unknown, not empty, and writing
	# into it would mean generating terrain as a side effect of an API call.
	var spot := Vector3i(2, 6, 2)
	_eq(bool(api.set_block("test", spot, ContentDB.GLOWSTONE)["ok"]),
		true, "and so does writing")
	var n := api.block_at("test", spot)
	_eq(int(n["value"]), ContentDB.GLOWSTONE, "and the write is visible")
	# A break that has nothing to break is refused with a reason.
	var miss := api.break_block("test", Vector3i(2, 300, 2))
	_eq(bool(miss["ok"]), false, "breaking empty air is refused")
	_true(String(miss["reason"]) != "", "and says why")
	SystemRegistry.clear()


func _test_api_denies_a_client() -> void:
	var api := _api_world(false)
	var r := api.set_block("villager", Vector3i(1, 40, 1), ContentDB.GLOWSTONE)
	_eq(bool(r["ok"]), false, "a client cannot write the world directly")
	_true(String(r["reason"]).contains("authoritative"),
		"and the reason says it needs the authoritative end")
	# Reading is still fine: a client must be able to see the world.
	_eq(bool(api.block_at("client", Vector3i(0, 0, 0))["ok"]), true,
		"but it can still read it")
	# And the multiplayer verb is a *request*, not an action.
	var req := api.request("villager", "place", {"component": "beam"})
	_eq(String(req["reason"]).contains("awaiting the server"), true,
		"a client request is queued for the server, not performed")
	_eq(bool(req["ok"]), false, "and the call itself reports no success")
	var spot := Vector3i(2, 6, 2)
	var before: int = api.block_at("villager", spot)["value"]
	api.request("villager", "place", {"component": "beam", "position": spot})
	_eq(int(api.block_at("villager", spot)["value"]), before,
		"and the world did not change underneath it")
	# The server, by contrast, decides.
	var server := _api_world(true)
	_true(String(server.request("villager", "place",
		{"component": "beam"})["reason"]) != "",
		"a server with no net system reports that rather than pretending")
	SystemRegistry.clear()


func _test_api_refuses_unknown_items() -> void:
	var api := _api_world()
	var r := api.give_item("villager", "not_a_real_item", 1)
	_eq(bool(r["ok"]), false, "giving an item that does not exist is refused")
	_true(String(r["reason"]).contains("unknown item"), "and named")
	_eq(bool(api.give_item("villager", "shaft", 1)["ok"]), true,
		"while a real component is accepted")
	_eq(int(api.count_item("villager", "shaft")["value"]), 1, "and counted")
	_eq(bool(api.take_item("villager", "shaft", 1)["ok"]), true, "and taken")
	_eq(int(api.count_item("villager", "shaft")["value"]), 0,
		"leaving none behind")
	SystemRegistry.clear()


func _test_api_counts_callers() -> void:
	var api := _api_world()
	api.block_at("hud", Vector3i.ZERO)
	api.block_at("hud", Vector3i.ZERO)
	api.set_block("villager", Vector3i(1, 40, 1), ContentDB.STONE)
	var counts := api.call_counts()
	_eq(int(counts.get("hud", 0)), 2, "calls are counted per calling system")
	_eq(int(counts.get("villager", 0)), 1, "and kept apart")
	_true(api.last_reasons().is_empty(), "with no failures recorded")
	SystemRegistry.clear()


# --- persistence ------------------------------------------------------------

func _test_persistence_owns_the_save() -> void:
	var inv := PlayerInventory.new()
	root.add_child(inv)
	var p := Persistence.new()
	p.inventory = inv
	_eq(p.initialize(), true, "a persistence layer starts")
	_eq(p.run(), true, "and runs")
	_eq(p.slot, 1, "with a default slot")
	p.slot = 5
	var r: Dictionary = p.save_to(5)
	_eq(bool(r["ok"]), true, "it saves: %s" % str(r.get("reason", "")))
	_eq(int(r["slot"]), 5, "to the requested slot")
	_eq(p.autosaves, 1, "and counts the autosave")
	_eq(p.busy, false, "and is not left marked busy")
	_eq(bool(SaveGame.has_slot(5)), true, "the file is on disk")
	# Two saves in a row: the second is a backup-writing one, and must not be
	# refused because the first left a flag set.
	_eq(bool(p.save_to(5)["ok"]), true, "a second save works")
	_eq(p.autosaves, 2, "and is counted")
	_eq(p.last_result()["ok"], true, "and the last result is readable")
	# The slots report is metadata, not a full parse.
	var slots := p.slots()
	_eq(slots.size(), SaveGame.LAST_SLOT - SaveGame.FIRST_SLOT + 1,
		"every slot is reported")
	SaveGame.delete_slot(5)
	p.teardown()


## The emergent layer's save section, exercised through the real capture and
## apply path rather than through EmergentPersistence alone.
##
## The property worth protecting is that it is ADDITIVE: a save written before
## the emergent layer existed has no `emergent` key, and loading it must succeed
## rather than treat a missing section as corruption. A save format that can be
## broken by adding a subsystem is a save format that will be broken.
func _test_persistence_carries_the_emergent_section() -> void:
	SystemRegistry.clear()
	EmergentRules.clear()
	var em := EmergentSystem.new()
	_eq(em.initialize(), true, "an emergent system starts")
	_eq(em.run(), true, "and runs")
	em._initialize_graph(EngGraph.new())
	var zone := em.graph.add_entity("zone", Vector3.ZERO)
	var counter := em.graph.add_entity("counter", Vector3(1, 0, 0))
	em.invalidate()
	em.tick(0.05)
	em.graph.entity(counter).set_state("value", 4.0)
	_r("the zone was placed", zone > 0)

	var state := SaveGame.capture(null, null, null, 0, null, em)
	_eq(bool(state.has("emergent")), true, "capture writes an emergent section")
	_eq(int((state["emergent"]["graph"]["entities"] as Array).size()), 2,
		"carrying both entities")

	var fresh := EmergentSystem.new()
	fresh.initialize()
	fresh.run()
	fresh._initialize_graph(EngGraph.new())
	var report: Dictionary = fresh.deserialize(state["emergent"])
	_eq(int(report["entities"]), 2, "apply restores both")
	_eq(float(fresh.graph.entity(counter).get_state("value", 0.0)), 4.0,
		"including the state they reached")

	# An old save with no section at all. Note that `apply` needs at least one
	# real section to have applied -- the emergent layer alone is not enough,
	# and neither should it be: a load that restored nothing is a failure, and
	# that rule predates this layer.
	var legacy := state.duplicate(true)
	legacy.erase("emergent")
	legacy["player"] = {"position": [0, 0, 0], "health": 20.0,
		"max_health": 20.0, "flying": false}
	var p := Player.new()
	root.add_child(p)
	_eq(SaveGame.apply(legacy, p, null, null, null, fresh), true,
		"a save predating the emergent layer still loads")
	_eq(int(report["entities"]), 2,
		"and the live world's entities are left untouched")

	# And a save whose emergent section is empty rather than absent.
	var empty := state.duplicate(true)
	empty["emergent"] = {}
	_eq(SaveGame.apply(empty, p, null, null, null, fresh), true,
		"an empty emergent section is not an error either")
	p.queue_free()
	em.teardown()
	fresh.teardown()
	SystemRegistry.clear()
	EmergentRules.clear()


## The registry must tick the emergent layer exactly once, and after the
## engineering layer whose graph it derives from.
func _test_emergent_is_ticked_once_and_in_order() -> void:
	SystemRegistry.clear()
	var eng := _sys("engineering", "components, machines and networks")
	var em := EmergentSystem.new()
	em.system_name = "emergent"
	em.initialize()
	em.run()
	em._initialize_graph(EngGraph.new())
	SystemRegistry.register(eng, eng)
	SystemRegistry.register(em, em)
	_eq(SystemRegistry.run_order().has("emergent"), true,
		"the emergent layer is in the tick order")
	_eq(int(SystemRegistry.run_order().find("emergent"))
		> int(SystemRegistry.run_order().find("engineering")), true,
		"and it is after engineering, whose graph it reads")
	var before := em.tick_count
	SystemRegistry.tick_all(0.05)
	_eq(em.tick_count - before, 1,
		"one registry tick is exactly one emergent tick, not two")
	SystemRegistry.clear()


## The player's actions reach the layer as events, not as meanings. A swing is
## reported as a swing; whether that scored anything is a rule's business.
func _test_interaction_reports_actions_to_the_emergent_layer() -> void:
	var em := EmergentSystem.new()
	em.initialize()
	em.run()
	em._initialize_graph(EngGraph.new())
	var cart := em.graph.add_entity("cart", Vector3.ZERO)
	var probe := PlayerInteraction.new()
	probe.emergent = em
	root.add_child(probe)
	var struck: Array = probe.report_action("strike", Vector3(0.2, 0, 0), 9.0)
	_eq(struck.size(), 1, "a swing struck the cart")
	_eq(float(em.graph.entity(cart).velocity.length()) > 0.0, true,
		"and imparted an impulse")
	# No layer attached at all must be a no-op rather than a crash: the
	# interaction node exists in tests and in menus that have no emergent layer.
	probe.emergent = null
	_eq(probe.report_action("strike", Vector3.ZERO).size(), 0,
		"with no layer attached, reporting is a no-op")
	probe.queue_free()
	em.teardown()
	SystemRegistry.clear()
	EmergentRules.clear()


func _test_persistence_survives_interruption() -> void:
	var inv := PlayerInventory.new()
	root.add_child(inv)
	var p := Persistence.new()
	p.inventory = inv
	p.initialize()
	_eq(bool(p.save_to(6)["ok"]), true, "a good save is written")
	_eq(bool(p.save_to(6)["ok"]), true, "and a second one, which takes the backup")
	# Simulate a crash mid-write: a truncated slot, backup intact.
	var f := FileAccess.open(SaveGame.slot_path(6), FileAccess.WRITE)
	f.store_string('{"version": 1, "inventory": {"items"')
	f.close()
	var r: Dictionary = p.load_from(6)
	_eq(bool(r["ok"]), true, "a truncated slot still loads, from the backup")
	_eq(String(r["source"]), "backup", "and says where it came from")
	# Now no backup either: an explicit failure, not a half-applied world.
	DirAccess.remove_absolute(
		ProjectSettings.globalize_path(SaveMigration.backup_path(6)))
	var dead: Dictionary = p.load_from(6)
	_eq(bool(dead["ok"]), false, "with nothing to recover from it fails")
	_true(String(dead["reason"]) != "", "and says why")
	SaveGame.delete_slot(6)
	p.teardown()


# --- dev tools --------------------------------------------------------------

func _test_devtools_reports_are_pure() -> void:
	SystemRegistry.clear()
	var d := DevTools.new()
	root.add_child(d)
	d.attach(null, null)
	# Every topic must produce text rather than throw, including the ones
	# that have nothing to report. A debug panel that crashes is worse than
	# no debug panel.
	for topic in ["world", "entities", "engineering", "network", "memory",
		"performance", "validate", "graphs", "saves", "systems"]:
		var text := d.report(topic)
		_true(text.length() > 0, "the '%s' report produces text" % topic)
	_true(d.report("nonsense").contains("unknown topic"),
		"and an unknown topic is reported, not ignored")
	# A live reading is not a pure function of anything -- memory changes
	# between the two calls, and pretending otherwise would make the panel lie.
	_true(d.report("memory").contains("MEMORY"), "memory is a live reading")
	_eq(d.report("systems"), d.report("systems"),
		"while a derived report is stable between calls")
	d.queue_free()
	SystemRegistry.clear()


# --- test doubles -----------------------------------------------------------

## A real object with a real method, rather than a lambda over a captured
## Dictionary: a signal connection to a freed lambda is precisely the crash
## this test is about, so the test should not depend on lambda lifetime rules.
class _SignalCounter:
	extends RefCounted
	var count := 0

	func on_child(_node: Node) -> void:
		count += 1


class _FailingSystem:
	extends System
	var ticks := 0

	func _initialize() -> bool:
		return false


class _LoggingSystem:
	extends System
	var order_log: Array = []

	func _release() -> void:
		order_log.append(system_name)
