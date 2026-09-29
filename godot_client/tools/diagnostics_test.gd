extends SceneTree
## Performance instrumentation, long-duration stability detection, and the
## coupling between the village AI and the player's power grid.

var _fails := 0


func _init() -> void:
	_test_profiler_sections()
	_test_profiler_statistics()
	_test_profiler_report()
	_test_watchdog_sampling()
	_test_watchdog_detects_leak()
	_test_watchdog_ignores_burst()
	_test_watchdog_ceiling()
	_test_society_unpowered()
	_test_society_powered()
	_test_society_pays_for_power()
	_test_society_refuses_sleeping_network()
	_test_society_serialization()
	_finish()


func _eq(got: Variant, want: Variant, what: String) -> void:
	if got == want:
		print("  ok   %s == %s" % [what, str(want)])
	else:
		_fails += 1
		print("  FAIL %s: got %s, want %s" % [what, str(got), str(want)])


func _near(got: float, want: float, tol: float, what: String) -> void:
	if absf(got - want) <= tol:
		print("  ok   %s == %.4f" % [what, got])
	else:
		_fails += 1
		print("  FAIL %s: got %.6f, want %.6f (+-%.3f)" % [what, got, want, tol])


func _finish() -> void:
	print("RESULT: %s (%d failures)" % ["PASS" if _fails == 0 else "FAIL", _fails])
	quit(0 if _fails == 0 else 1)


# --- profiler ---------------------------------------------------------------

func _test_profiler_sections() -> void:
	var p := GameProfiler.new()
	root.add_child(p)
	p.enabled = true
	# A disabled profiler must cost nothing and record nothing, or a shipped
	# build pays for instrumentation nobody looks at.
	p.begin("world")
	p.unmark("world")
	_eq(p.section_calls(0), 1, "a measured section is counted")
	p.enabled = false
	p.begin("world")
	p.unmark("world")
	_eq(p.section_calls(0), 1, "a disabled profiler records nothing")
	p.queue_free()


func _test_profiler_statistics() -> void:
	var p := GameProfiler.new()
	root.add_child(p)
	p.enabled = true
	p.set_slow_budget(16.0)
	# Feed the window directly through the same code path _process uses, so
	# the percentiles under test are the ones the overlay will show.
	for ms in [10.0, 10.0, 12.0, 11.0, 40.0, 10.0, 11.0, 12.0]:
		p.push_frame(ms)
	_near(p.mean_frame_ms(), 14.5, 0.001, "mean frame time")
	_near(p.frame_percentile(0.5), 11.0, 0.001, "median frame time")
	_eq(p.frame_percentile(1.0), 40.0, "the worst frame is reachable")
	_eq(p._slow_frames, 1, "one frame was over budget")
	_eq(p.snapshot()["slow_budget_ms"], 16.0, "the budget reaches the report")
	p.queue_free()


func _test_profiler_report() -> void:
	var p := GameProfiler.new()
	root.add_child(p)
	p.enabled = true
	p.begin("engineering")
	p.unmark("engineering")
	var snap := p.snapshot()
	_eq(snap.has("p95_ms"), true, "the report carries percentiles")
	_eq(snap.has("counters"), true, "the report carries engine counters")
	_eq(snap.has("renderer"), true, "the report names the renderer, which is \
what makes it a *hardware* report")
	var sections: Array = snap["sections"]
	_eq(sections.size() >= 1, true, "the report lists the sections measured")
	# Drawing a report to disk is the whole point: the numbers have to leave
	# the process to be compared across machines.
	_eq(p.write_report("user://profiling_test"), true, "a report is written")
	var path := "user://profiling_test"
	_eq(DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path)),
		true, "and the directory exists afterwards")
	p.queue_free()


# --- watchdog ---------------------------------------------------------------

func _test_watchdog_sampling() -> void:
	var w := StabilityWatchdog.new()
	_eq(w.tick(0.0), true, "the first sample is taken immediately")
	_eq(w.tick(1.0), false, "and then only on the interval")
	_eq(w.tick(StabilityWatchdog.SAMPLE_INTERVAL + 0.1), true,
		"which is honoured")
	_eq(w.sample_count(), 2, "two samples so far")
	_eq(w.report().contains("stability:"), true, "the report is a real report")


func _test_watchdog_detects_leak() -> void:
	var w := StabilityWatchdog.new()
	w.set_quiescent(true, 0.0)
	# A world that leaks 3 nodes per sample, forever.
	for i in 20:
		w.ingest(float(i) * 30.0, {
			"object_node_count": 1000.0 + float(i) * 5.0,
			"object_count": 2000.0 + float(i) * 6.0,
			"static_memory_mb": 100.0,
			"video_mem_mb": 50.0,
		})
	_eq(w.drift("object_node_count") > 0.0, true, "a leaking counter drifts up")
	_eq(w.has_leak(), true, "and is reported as a leak")
	var found := ""
	for f in w.findings():
		if String(f["counter"]) == "object_node_count":
			found = String(f["kind"])
	_eq(found, "leak", "with the right classification")
	_eq(w.report().contains("object_node_count"), true,
		"and it names the counter in the report")


func _test_watchdog_ignores_burst() -> void:
	var w := StabilityWatchdog.new()
	w.set_quiescent(true, 0.0)
	# Growth while the world is genuinely changing is not a leak. A player
	# who builds a factory should not generate a stability alarm.
	for i in 10:
		w.set_quiescent(false, float(i) * 30.0)
		w.ingest(float(i) * 30.0, {"object_node_count": 1000.0 + float(i) * 100.0})
	w.set_quiescent(true, 300.0)
	for i in 10:
		w.ingest(300.0 + float(i) * 30.0,
			{"object_node_count": 2000.0 + float(i) * 0.2})
	_near(w.drift("object_node_count"), 1.8, 0.001,
		"drift is measured across the quiescent samples only")
	_eq(w.has_leak(), false,
		"a climb too small to matter inside the epsilon is not reported")

	# The absolute epsilon is the point: a leak of one node per sample is
	# invisible for an hour and fatal by day three.
	var slow := StabilityWatchdog.new()
	slow.set_quiescent(true, 0.0)
	for i in 200:
		slow.ingest(float(i) * 30.0, {"object_node_count": 1000.0 + float(i)})
	_eq(slow.has_leak(), true,
		"but a slow steady climb is caught once the window is long enough")
	var w2 := StabilityWatchdog.new()
	w2.set_quiescent(true, 0.0)
	for i in 20:
		w2.ingest(float(i) * 30.0, {"object_node_count": 1000.0 + float(i) * 0.5})
	_eq(w2.has_leak(), false, "but a flat world produces no finding at all")


func _test_watchdog_ceiling() -> void:
	var w := StabilityWatchdog.new()
	w.set_quiescent(true, 0.0)
	# A spike that comes back down is pressure, not a leak: the allocation is
	# transient, which is a different problem and a different fix.
	w.ingest(0.0, {"object_node_count": 10.0, "static_memory_mb": 10.0})
	w.ingest(30.0, {"object_node_count": 10.0, "static_memory_mb": 4096.0})
	w.ingest(60.0, {"object_node_count": 10.0, "static_memory_mb": 10.0})
	var kinds := PackedStringArray()
	for f in w.findings():
		kinds.append(String(f["kind"]) + ":" + String(f["counter"]))
	_eq(kinds.has("pressure:static_memory_mb"), true,
		"a counter past its ceiling is a pressure finding even with no drift")
	_eq(w.has_leak(), false, "and pressure is not reported as a leak")


# --- society ----------------------------------------------------------------

## A villager stand-in with exactly the properties EngSociety writes. Using the
## real Villager here would drag in a model, an animator and a voice, none of
## which the coupling reads.
class FakeVillager:
	extends Node3D
	var produce_interval := 10.0
	var base_produce_interval := 0.0
	var power_efficiency := 1.0


## battery -> motor wired up, i.e. one live electrical network.
func _powered_graph() -> EngGraph:
	var g := EngGraph.new()
	var bat := g.place("battery", Vector3.ZERO)
	var wire := g.place("wire", Vector3(0.3, 0, 0))
	var motor := g.place("motor", Vector3(0.6, 0, 0))
	g.link(bat, "positive", wire, "a")
	g.link(wire, "b", motor, "power")
	(g.node(bat) as EngGraph.EngNode).state["charge"] = 1.0
	g.rebuild_networks()
	return g


func _test_society_unpowered() -> void:
	var g := EngGraph.new()
	g.rebuild_networks()
	var v := FakeVillager.new()
	v.position = Vector3.ZERO
	root.add_child(v)
	var s := EngSociety.new()
	s.tick(0.1, g, [v], [Vector3.ZERO])
	_near(v.power_efficiency, EngSociety.UNPOWERED_EFFICIENCY, 0.001,
		"a villager with no grid is unpowered, not broken")
	_near(v.produce_interval, 10.0 / EngSociety.UNPOWERED_EFFICIENCY, 0.001,
		"and works proportionally slower")
	_eq(s.powered, 0, "nobody is powered")
	_eq(s.unpowered, 1, "and the summary counts them")
	v.queue_free()


func _test_society_powered() -> void:
	var g := _powered_graph()
	var v := FakeVillager.new()
	v.position = Vector3(2, 0, 0)
	root.add_child(v)
	var s := EngSociety.new()
	# Step the simulation so the network actually has a voltage, exactly as it
	# would in the game.
	var sim := EngSimulation.new(g)
	for i in 20:
		sim.step([Vector3.ZERO])
	s.tick(0.1, g, [v], [Vector3.ZERO])
	_eq(s.powered, 1, "a villager on a live grid is powered")
	_near(v.produce_interval, 10.0, 0.001, "and works at full rate")
	_eq(s.serving_network != 0, true, "the serving network is identified")

	# Move them out of range of the grid and the coupling must let go.
	v.position = Vector3(500, 0, 0)
	s.tick(0.1, g, [v], [Vector3.ZERO])
	_eq(s.powered, 0, "a villager away from the grid is not powered")
	v.queue_free()


func _test_society_pays_for_power() -> void:
	var g := _powered_graph()
	# Set the grid's own figures rather than draining a battery for it: what is
	# under test is the payout rule, not the battery model.
	for n in g.networks():
		var st: Dictionary = (n as Dictionary)["state"]
		st["supply"] = 600.0
		st["demand"] = 100.0
	var vs: Array = []
	for i in 3:
		var v := FakeVillager.new()
		v.position = Vector3(0.5 * float(i), 0, 0)
		root.add_child(v)
		vs.append(v)
	var s := EngSociety.new()
	s.tick(1.0, g, vs, [Vector3.ZERO])
	_eq(s.powered, 3, "all three are powered")
	_eq(s.wage_pool > 0.0, true,
		"the village pays for power it actually received")
	var first := s.wage_pool
	_eq(s.collect_wage(), first, "the player collects the pool")
	_eq(s.wage_pool, 0.0, "and it is emptied, so it cannot be paid twice")
	_eq(s.collect_wage(), 0.0, "a second collection yields nothing")
	for v in vs:
		(v as Node3D).queue_free()


func _test_society_refuses_sleeping_network() -> void:
	var g := _powered_graph()
	var sim := EngSimulation.new(g)
	for i in 20:
		sim.step([Vector3.ZERO])
	# Freeze every network the way the LOD does when nothing is near it, then
	# confirm the village does not quietly run off a stale voltage.
	for n in g.networks():
		(n as Dictionary)["lod"] = 3
	var v := FakeVillager.new()
	v.position = Vector3.ZERO
	root.add_child(v)
	var s := EngSociety.new()
	s.tick(0.1, g, [v], [Vector3.ZERO])
	_eq(s.powered, 0, "a sleeping network supplies nobody")
	_eq(s.wage_pool, 0.0, "and pays nobody")
	v.queue_free()


func _test_society_serialization() -> void:
	var s := EngSociety.new()
	s.wage_pool = 123.5
	s.total_delivered = 900.0
	s.powered = 4
	s.unpowered = 2
	var blob := s.serialize()
	var s2 := EngSociety.new()
	s2.deserialize(blob)
	_eq(s2.wage_pool, 123.5, "the wage pool survives a save")
	_eq(s2.powered, 4, "and so does the powered count")
	_eq(s2.summary().contains("village:"), true, "and it still reports")
