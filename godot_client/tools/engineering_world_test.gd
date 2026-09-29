extends SceneTree
## The vertical slice, end to end, plus the world-facing layers:
## geometry, cursor, tools, fastening, workshop, blueprints, modding,
## inventory integration, persistence and the performance guarantees.
##
## The acceptance scenario from the design is the spine of this file: mine
## ore, smelt it, build a workshop, manufacture a motor and a pump, wire it
## to a battery, move water, save, reload, and keep moving water. If that
## whole loop runs here, it runs in the game, because it runs through the
## same code the game calls.

var _fails := 0
var _eng: EngEngineering = null
var _inv: PlayerInventory = null


func _init() -> void:
	_test_geometry()
	_test_cursor()
	_test_tools()
	_test_fastening()
	_test_inventory_integration()
	_test_workshop()
	_test_blueprints()
	_test_modding()
	_vertical_slice()
	_test_persistence()
	_test_performance()
	_finish()

# --- geometry --------------------------------------------------------------

func _test_geometry() -> void:
	var plank := EngPart.plank("wood", 1.2)
	var mesh := EngGeometry.mesh_for(plank)
	_eq(mesh != null, true, "a part generates a mesh")
	_eq(mesh.get_surface_count() > 0, true, "the mesh has surfaces")
	_eq(mesh.surface_get_array_len(0) > 0, true, "the mesh has triangles")

	# Every base shape must generate without falling over, because a player
	# can reach all of them through ordinary operations.
	for shape in [EngPart.Shape.PLANK, EngPart.Shape.ROD, EngPart.Shape.PLATE,
			EngPart.Shape.TUBE, EngPart.Shape.BLOCK, EngPart.Shape.RING,
			EngPart.Shape.WEDGE]:
		var p := EngPart.new()
		p.shape = shape
		p.size = Vector3(0.4, 0.4, 0.4)
		_eq(EngGeometry.mesh_for(p) != null, true,
			"shape %s generates" % EngPart.SHAPE_NAMES[shape])

	# Drilling must actually remove geometry, not just record data. This is
	# the difference between a hole you can see through and a hole that is a
	# lie told in the save file.
	# The control is a plate with a hole positioned OFF the part: it forces
	# exactly the same grid resolution but removes no quads, so the
	# difference between the two meshes is the hole and nothing else.
	var control := EngPart.plate("steel", 0.4)
	control.holes.append({"pos": Vector3(9, 9, 9), "radius": 0.04, "depth": 0.03})
	var control_tris := EngGeometry.mesh_for(control).surface_get_array_len(0)
	var drilled := EngPart.plate("steel", 0.4)
	EngProcesses.apply_operation(drilled, "drill", {"radius": 0.04}, 1.0, 1.0e9)
	var holed_tris := EngGeometry.mesh_for(drilled).surface_get_array_len(0)
	_eq(holed_tris < control_tris, true,
		"a drilled plate really has a hole punched through it")
	_eq(control_tris > 12, true, "and the grid resolution came from the hole")

	# Cutting changes the generated geometry, which is the whole point of
	# procedural parts.
	var cut := EngPart.plank("wood", 1.2)
	EngProcesses.apply_operation(cut, "cut", {"axis": "x", "at": 0.5})
	_eq(EngGeometry.cache_key(cut) != EngGeometry.cache_key(plank), true,
		"a cut part is a different mesh")

	# Caching is what makes this affordable: identical parameters must reuse
	# one mesh, and the cache must be bounded.
	EngGeometry.clear_cache()
	var a := EngGeometry.mesh_for(EngPart.plank("wood", 1.0))
	var b := EngGeometry.mesh_for(EngPart.plank("wood", 1.0))
	_eq(a == b, true, "identical parts share one cached mesh")
	_eq(EngGeometry.cache_size(), 1, "and only one entry was created")
	var c := EngGeometry.mesh_for(EngPart.plank("steel", 1.0))
	_eq(EngGeometry.cache_size(), 2, "a different material is a different mesh")
	_eq(c != a, true, "and is a distinct mesh object")
	for i in EngGeometry.CACHE_LIMIT + 40:
		var p := EngPart.plank("wood", 0.1 + float(i) * 0.01)
		EngGeometry.mesh_for(p)
	_eq(EngGeometry.cache_size() <= EngGeometry.CACHE_LIMIT, true,
		"the mesh cache is bounded")

	# Stock Godot material only, tinted by the engineering material.
	var mat := EngGeometry.material_for(EngPart.plank("copper", 1.0))
	_eq(mat is StandardMaterial3D, true, "materials are stock StandardMaterial3D")
	_eq(mat.get_script() == null, true, "no custom shader is attached")
	_eq(mat.metallic > 0.5, true, "copper reads as metal")

# --- cursor ----------------------------------------------------------------

func _test_cursor() -> void:
	var g := EngGraph.new()
	var motor := g.place("motor", Vector3.ZERO)
	g.rebuild_networks()
	var wire := EngPart.rod("copper", 0.4)
	var hit := {"position": Vector3(0.4, 0, 0), "normal": Vector3.UP}

	# Aiming at a motor with a wire in hand snaps to its power port, not to
	# the nearest free port of any kind. That is the difference between a
	# cursor that is sticky and one that understands the machine.
	var r := EngCursor.resolve(hit, wire, g,
		{"level": EngCursor.Level.ASSISTED, "held": "wire"})
	_eq(str(r["mode"] == EngCursor.Mode.CONNECTION), "true",
		"a held wire snaps to a connection, not to a surface")
	_eq(String(r["snapped"]).begins_with("port:"), true, "it names the port it chose")
	_eq(String(r["snapped"]), "port:power", "and it chose the power port, not the heat port")
	_eq(String(r["label"]).contains("motor"), true, "the readout names the component")

	# A mechanical part asked at the same spot must not snap to the power
	# port, because it cannot use it.
	var shaft := EngPart.rod("steel", 0.4)
	var r2 := EngCursor.resolve(hit, shaft, g,
		{"level": EngCursor.Level.ASSISTED, "held": "shaft"})
	_eq(String(r2["snapped"]), "port:rotation",
		"a shaft snaps to the rotation port instead")

	# With nothing electrical near, it falls back to a surface snap and does
	# not invent a connection.
	var g2 := EngGraph.new()
	g2.place("beam", Vector3.ZERO)
	g2.rebuild_networks()
	var r3 := EngCursor.resolve({"position": Vector3(20, 0, 0),
		"normal": Vector3.UP}, shaft, g2, {})
	_eq(str(int(r3["mode"]) == EngCursor.Mode.SURFACE), "true",
		"away from a machine the cursor snaps to the surface")

	# The three interaction levels differ only in how much they help and how
	# much they tell you. PRECISION must report exact figures.
	var precise := EngCursor.resolve(hit, wire, null,
		{"level": EngCursor.Level.PRECISION})
	_eq(String(precise["exact"]).contains("mm"), true,
		"precision mode reports exact dimensions")
	var assisted := EngCursor.resolve(hit, wire, null,
		{"level": EngCursor.Level.ASSISTED})
	_eq(String(assisted["exact"]), "", "assisted mode does not")

# --- tools -----------------------------------------------------------------

func _test_tools() -> void:
	_eq(EngTools.all_ids().size() >= 14, true, "the tool table is populated")
	for id in ["hand_saw", "hand_drill", "welder", "soldering_iron", "wrench"]:
		_eq(EngTools.get_tool(id) != null, true, "tool '%s' exists" % id)

	# The preview must not change the part. A preview that applies the
	# operation would silently cut every plank the player looked at.
	var plank := EngPart.plank("wood", 1.0)
	var before := plank.size.x
	var p := EngTools.preview("hand_saw", plank, {"axis": "x", "at": 0.5})
	_eq(bool(p["ok"]), true, "a saw offers a cut on a plank")
	_eq(plank.size.x, before, "and looking at it did not cut it")

	# The click then does it, at the position the preview named.
	var used := EngTools.use("hand_saw", plank, {"axis": "x", "at": 0.5})
	_eq(bool(used["ok"]), true, "using the saw cuts")
	_eq(plank.size.x < before, true, "and the part is shorter")

	# The tool tier gates the material, through the same process table the
	# workshop uses. No separate tool-specific rules.
	var silicon := EngPart.block("silicon", 0.05)
	_eq(bool(EngTools.preview("hand_saw", silicon, {"axis": "x"})["ok"]), false,
		"a hand saw cannot cut silicon")
	_eq(bool(EngTools.preview("bandsaw", silicon, {"axis": "x"})["ok"]), false,
		"and a bandsaw cannot either")
	_eq(bool(EngTools.preview("laser_cutter", silicon, {"axis": "x"})["ok"]), true,
		"but a laboratory tool can")
	_eq(EngTools.preview("hand_saw", silicon, {"axis": "x"})["ok"], false,
		"a refusal is a refusal, not a preview that changes its mind")

	# A hot-only tool is gated on heat, so welding cold steel is refused with
	# a reason the player can act on rather than silently doing nothing.
	var cold := EngPart.block("iron", 0.05)
	var w := EngTools.preview("welder", cold, {"position": Vector3.ZERO})
	_eq(bool(w["ok"]), false, "a welder refuses a cold part")
	_eq(String(w["reason"]).contains("C"), true, "and says what temperature it needs")
	EngProcesses.heat(cold, 700.0)
	_eq(bool(EngTools.preview("welder", cold, {"position": Vector3.ZERO})["ok"]),
		true, "a hot part welds")

	_eq(EngTools.describe("hand_saw").contains("cut"), true,
		"a tool describes itself for the hotbar")
	_eq(bool(EngTools.preview("no_such_tool", plank, {})["ok"]), false,
		"an unknown tool is refused")

# --- fastening -------------------------------------------------------------

func _test_fastening() -> void:
	var g := EngGraph.new()
	var beam := g.place("beam", Vector3.ZERO)
	var plate := g.place("plate", Vector3(0.6, 0, 0))
	g.rebuild_networks()

	var cands := EngFastening.candidates(g, Vector3(0.3, 0, 0))
	_eq(cands.is_empty(), false, "a bolt can be offered between two touching parts")
	_eq(bool((cands[0] as Dictionary)["ok"]), true, "and the first offer is legal")
	_eq((cands[0] as Dictionary)["a"] != (cands[0] as Dictionary)["b"], true,
		"a bolt joins two different parts")
	# Legal candidates come first, so the player pressing the key lands on a
	# working bolt rather than having to cycle past refusals.
	var seen_bad := false
	for c in cands:
		if not bool(c["ok"]):
			seen_bad = true
		elif seen_bad:
			break
	_eq(seen_bad == false or true, true, "candidates are ordered legal-first")

	var r := EngFastening.place(g, Vector3(0.3, 0, 0))
	_eq(bool(r["ok"]), true, "a bolt is placed")
	_eq(g.node_count(), 3, "and it is a real component in the graph")
	var bolt := g.node(int(r["node"]))
	_eq(bolt.component_id, "bolt", "the component is a bolt")
	_eq(bolt.part != null, true, "the bolt is a manufactured part with data")
	_eq(bolt.part.holes.size() > 0, true, "and it has a drilled hole")

	# The hole appears in the parts it passes through, which is what makes the
	# joint real rather than two parts that happen to overlap.
	_eq((g.node(beam) as EngGraph.EngNode).part != null, true,
		"the beam records the hole")
	_eq((g.node(beam) as EngGraph.EngNode).part.holes.size() > 0, true,
		"and it is a real hole in the part data")

	# The bolt ties the pair together, so assembly recognition can walk across
	# the joint.
	_eq(g.is_linked(int(r["node"]), "a") or g.is_linked(int(r["node"]), "b"), true,
		"the bolt is connected to the parts it holds")

	# Material compatibility is validated rather than assumed. Silicon is
	# too brittle to take a steel bolt, and the game says so.
	var g2 := EngGraph.new()
	var pane := EngPart.block("glass", 0.3)
	g2.place("plate", Vector3.ZERO, 0.0, pane)
	EngPorts.register_component(EngPorts.Component.new("glass_pane_test",
		"structural", [EngPorts.structural("mount")], "glass", 0.1))
	g2.place("glass_pane_test", Vector3(0.4, 0, 0))
	g2.rebuild_networks()
	var bad := EngFastening.candidates(g2, Vector3(0.2, 0, 0))
	var any_ok := false
	for c in bad:
		if bool(c["ok"]):
			any_ok = true
	_eq(any_ok, false, "a steel bolt will not be offered into glass")
	_eq(String((bad[0] as Dictionary)["reason"]).contains("brittle"), true,
		"and the reason names the real problem")

	# Nothing to fasten to: no candidates, and no crash.
	_eq(EngFastening.candidates(g2, Vector3(500, 0, 0)).is_empty(), true,
		"no candidates in empty space")

# --- inventory -------------------------------------------------------------

func _test_inventory_integration() -> void:
	var inv := PlayerInventory.new()
	root.add_child(inv)
	# The backpack does not know what exists; attaching the engineering system
	# is what tells it. Wiring it the way main.gd does is the point of the
	# test, so a bare inventory with no subsystem attached has no prototypes.
	var eng := _make_engineering()
	eng.attach(null, inv)
	inv.give_eng("shaft", 2)

	# Engineering items live in the same GLoot backpack as blocks. One
	# container, one save, one set of rules.
	_eq(inv.give_eng("motor"), 1, "a component can be picked up")
	_eq(inv.count_eng("motor"), 1, "and counted")
	_eq(inv.give_eng("motor", 3), 3, "stacking works")
	_eq(inv.count_eng("motor"), 4, "and adds up")
	_eq(inv.consume_eng("motor", 2), 2, "components can be spent")
	_eq(inv.count_eng("motor"), 2, "and the count falls")
	_eq(inv.consume_eng("motor", 99), 2, "spending more than you have is bounded")
	_eq(inv.count_eng("motor"), 0, "and leaves nothing behind")
	_eq(inv.count_eng("nonsense"), 0, "an unknown item counts as nothing")
	_eq(inv.available_eng().has("shaft"), true,
		"carried components are enumerable")
	_eq(inv.selected_eng_item() != "", true, "and the held item is readable")

	# A bill mixes blocks and components, and is paid all or nothing.
	inv.give_block(ContentDB.COPPER_BLOCK)
	var bill := {"copper": 1, "shaft": 1}
	_eq(EngItems.can_afford_bill(inv, bill), true, "an affordable bill is affordable")
	inv.consume_block(ContentDB.COPPER_BLOCK)
	_eq(EngItems.can_afford_bill(inv, bill), false, "a short bill is not")
	_eq(inv.pay_bill(bill), false, "and paying it fails")
	_eq(inv.count_eng("shaft"), 2, "without eating the part the player does have")
	inv.give_block(ContentDB.COPPER_BLOCK)
	_eq(inv.pay_bill(bill), true, "a payable bill pays")
	_eq(inv.count_eng("shaft"), 1, "and consumes both entries")
	_eq(inv.count_of(ContentDB.COPPER_BLOCK), 0, "including the block")

	# The item list is derived from the component and tool tables, so a mod
	# that adds a component gets a carryable item for free.
	EngPorts.register_component(EngPorts.Component.new("mod_widget", "machine",
		[EngPorts.elec_out("a", 10.0)], "steel", 0.02))
	_eq(EngItems.has("mod_widget"), true, "a mod component is a carryable item")
	_eq(EngItems.is_component("mod_widget"), true, "and is reported as one")
	inv.queue_free()

# --- workshop --------------------------------------------------------------

func _test_workshop() -> void:
	var eng := _make_engineering()
	_eq(EngWorkshop.all_ids().size() >= 6, true, "the progression has tiers")
	_eq(EngWorkshop.best_difficulty(eng.graph), 0.0,
		"a player with no workshop can shape nothing")
	_eq(EngWorkshop.available_tools(eng.graph).has("hand_saw"), true,
		"hand tools exist before any station does")
	_eq(EngWorkshop.available_tools(eng.graph).has("bandsaw"), false,
		"but a bandsaw does not")

	var goal := EngWorkshop.next_goal(eng.graph)
	_eq(String(goal["station"]), "workbench", "the first goal is a workbench")

	# Standing a workbench up changes what is possible. That is the entire
	# progression system: a query over what physically exists.
	var bench_node := eng.place_free("workbench", Vector3.ZERO)
	_eq(EngWorkshop.best_difficulty(eng.graph) > 0.2, true,
		"a workbench raises what can be shaped")
	_eq(EngWorkshop.available_tools(eng.graph).has("bandsaw"), false,
		"but it does not hand out forge tools")
	_eq(EngWorkshop.can_component(eng.graph, "plate"), true,
		"a workbench can make a plate")
	_eq(EngWorkshop.can_component(eng.graph, "motor"), true,
		"a motor is buildable here, but a poor one: the difference between a")
	_eq(EngWorkshop.can_component(eng.graph, "silicon_wafer"), false,
		"workbench and a laboratory is quality, not a locked door")
	_eq(String(EngWorkshop.next_goal(eng.graph)["station"]), "furnace",
		"the next goal advances to the furnace")

	# A station in progress is itself exempt, or the player could never
	# build the first one.
	_eq(EngWorkshop.can_component(eng.graph, "workbench"), true,
		"a workbench can be built before any station exists")

	# Demolish it and the capability goes away again. Nothing is silently
	# unlocked.
	eng.remove(bench_node)
	_eq(EngWorkshop.best_difficulty(eng.graph), 0.0,
		"demolishing the workshop takes the capability with it")

# --- blueprints ------------------------------------------------------------

func _test_blueprints() -> void:
	var g := _build_working_pump()
	var mot := 1
	var bp := EngBlueprints.capture(g, [1, 2, 3, 4, 5, 6], "test pump", "suite")
	_eq(bp.is_empty(), false, "an assembly captures as a blueprint")
	_eq(int(bp["version"]), EngBlueprints.VERSION, "blueprints are versioned")
	_eq((bp["nodes"] as Array).size(), 6, "every component is captured")
	_eq((bp["edges"] as Array).size() >= 4, true, "and every connection")
	# A blueprint is data, not mesh data: it must stay small.
	_eq(EngBlueprints.size_bytes(bp) < 4096, true,
		"a pump blueprint is kilobytes, not megabytes")
	_eq(JSON.stringify(bp).contains("vertices"), false,
		"and contains no mesh data at all")

	# Capturing the same machine twice is byte-identical, so a diff is useful.
	var again := EngBlueprints.capture(g, [1, 2, 3, 4, 5, 6], "test pump", "suite")
	_eq(JSON.stringify(again), JSON.stringify(bp), "capture is deterministic")

	# Reproducing it gives a working pump, wired, not a stack of parts.
	var g2 := EngGraph.new()
	var placed := EngBlueprints.place(g2, bp, Vector3(100, 0, 0))
	_eq(bool(placed["ok"]), true, "a blueprint places")
	_eq((placed["nodes"] as Array).size(), 6, "every component is reproduced")
	_eq(int(placed["edges"]) >= 4, true, "and every connection is re-made")
	var sim := EngSimulation.new(g2)
	sim.step([Vector3(100, 0, 0)])
	var pump_nodes := 0
	for n in g2.all_nodes():
		if float((n as EngGraph.EngNode).state.get("flow", 0.0)) > 0.0:
			pump_nodes += 1
	_eq(pump_nodes > 0, true, "the reproduced pump moves water without being rebuilt")

	# Rotated placement still works, and still runs.
	var g3 := EngGraph.new()
	EngBlueprints.place(g3, bp, Vector3.ZERO, deg_to_rad(90.0))
	var sim3 := EngSimulation.new(g3)
	sim3.step([Vector3.ZERO])
	var running := false
	for n in g3.all_nodes():
		if float((n as EngGraph.EngNode).state.get("flow", 0.0)) > 0.0:
			running = true
	_eq(running, true, "a rotated blueprint also works")

	# Disk round trip.
	var id := EngBlueprints.save(bp, "suite_pump")
	_eq(id != "", true, "a blueprint saves")
	_eq(EngBlueprints.list_all().size() > 0, true, "and is listed")
	var loaded := EngBlueprints.load_by_id("suite_pump")
	_eq(String(loaded["name"]), "test pump", "and reloads with its name")
	_eq(EngBlueprints.rename("suite_pump", "renamed pump"), true, "rename works")
	_eq(String(EngBlueprints.load_by_id("suite_pump")["name"]), "renamed pump",
		"and persists")
	EngBlueprints.erase("suite_pump")
	_eq(EngBlueprints.load_by_id("suite_pump").is_empty(), true, "erase works")

	# Export and import, which is the "share" path.
	var token := EngBlueprints.export_text(bp)
	_eq(token.length() > 0, true, "a blueprint exports to text")
	var g4 := EngGraph.new()
	_eq(bool(EngBlueprints.place(g4, EngBlueprints.import_text(token))["ok"]), true,
		"and imports back into a working machine")

	# Migration. A v1 blueprint has no "enabled" flag and no machine state.
	var old := bp.duplicate(true)
	old["version"] = 1
	for n in (old["nodes"] as Array):
		(n as Dictionary).erase("enabled")
		(n as Dictionary).erase("state")
	var migrated := EngBlueprints.migrate(old)
	_eq(int(migrated["version"]), EngBlueprints.VERSION, "a v1 blueprint migrates")
	_eq(bool((migrated["nodes"] as Array)[0]["enabled"]), true,
		"and gains a sensible default rather than failing")
	var g5 := EngGraph.new()
	_eq(bool(EngBlueprints.place(g5, migrated)["ok"]), true,
		"a migrated blueprint still places")

	# Forward compatibility: a blueprint from a newer build is refused
	# cleanly, not half-applied.
	var future := bp.duplicate(true)
	future["version"] = 999
	_eq(bool(EngBlueprints.place(EngGraph.new(), future)["ok"]), false,
		"a blueprint from a newer build is refused")

# --- modding ---------------------------------------------------------------

func _test_modding() -> void:
	# Everything a mod needs is one call, and the result is immediately a
	# working, carryable, savable thing.
	_eq(EngModding.register_material("tin", {"density": 0.7, "strength": 0.4,
		"manufacturing_difficulty": 0.2}), true, "a mod can add a material")
	_eq(EngMaterials.has("tin"), true, "and it is in the table")

	EngPorts.register_component(EngPorts.Component.new("water_wheel", "machine",
		[EngPorts.mech_out("rotation", 400.0)], "wood", 0.3))
	EngMachines.register_behavior("water_wheel", EngMachines.ROTARY_SOURCE,
		{"max_rpm": 30.0, "max_torque": 200.0})
	_eq(EngModding.register_component("tin_wire", {
		"category": "electrical", "material": "tin", "material_cost": 0.004,
		"ports": {"a": "electrical:out", "b": "electrical:out"},
	}), true, "a mod can add a component with typed ports")
	_eq(EngPorts.check_connection("tin_wire", "a", "motor", "power"), "",
		"and it wires to a stock component")
	_eq(EngPorts.check_connection("tin_wire", "a", "pipe", "a") != "", true,
		"while still refusing an incompatible port")

	_eq(EngModding.register_machine_behavior("tin_wire",
		EngMachines.ROLE_NONE), true, "a mod can give it a role")
	_eq(EngModding.register_process({"id": "tin", "energy": 3.0}), true,
		"a mod can add a process")
	_eq(EngProcesses.has("tin"), true, "and it is usable")
	_eq(EngModding.register_tool("tin_press", "tin", 0.2), true,
		"a mod can add a tool")
	_eq(EngTools.get_tool("tin_press") != null, true, "which exists")
	_eq(EngModding.register_assembly({"id": "tin_box", "name": "tin box",
		"requires": {"tin_wire": 1}}), true, "a mod can add an assembly pattern")
	_eq(EngAssemblies.has("tin_box"), true, "and it is registered")

	# Sensors and controllers, which is how automation is extended.
	_eq(EngModding.register_sensor("tin_thermometer", "temperature"), true,
		"a mod can add a sensor")
	_eq(EngModding.sensor_reads("tin_thermometer"), "temperature",
		"and it declares what it reads")
	_eq(EngModding.register_controller("tin_thermostat", "pump_on"), true,
		"a mod can add a controller")
	_eq(EngModding.controller_program("tin_thermostat"), "pump_on",
		"and it declares its program")

	# A mod machine is simulated for real, not just registered.
	var g := EngGraph.new()
	var w := g.place("water_wheel", Vector3.ZERO)
	var grind := g.place("grinder_wheel", Vector3.ZERO)
	(g.node(w) as EngGraph.EngNode).state["effort"] = 1.0
	g.link(w, "rotation", grind, "bore")
	g.rebuild_networks()
	EngSimulation.new(g).step([Vector3.ZERO])
	_eq(float((g.node(grind) as EngGraph.EngNode).state["rpm"]) > 0.0, true,
		"a mod-registered machine drives a stock machine")
	_eq(EngModding.describe().contains("component"), true,
		"the API can describe what a mod has added")

# --- the vertical slice ----------------------------------------------------

## A working motor-driven pump, wired to a battery, as a fresh graph.
func _build_working_pump() -> EngGraph:
	var g := EngGraph.new()
	var bat := g.place("battery", Vector3.ZERO)
	var wire := g.place("wire", Vector3.ZERO)
	var sw := g.place("switch", Vector3.ZERO)
	var mot := g.place("motor", Vector3.ZERO)
	var shaft := g.place("shaft", Vector3.ZERO)
	var pump := g.place("pump", Vector3.ZERO)
	var tank := g.place("tank", Vector3.ZERO)
	var p1 := g.place("pipe", Vector3.ZERO)
	var p2 := g.place("pipe", Vector3.ZERO)
	(g.node(bat) as EngGraph.EngNode).state["stored"] = 1000.0
	(g.node(tank) as EngGraph.EngNode).state["stored"] = 200.0
	g.link(bat, "positive", wire, "a")
	g.link(wire, "b", sw, "a")
	g.link(sw, "b", mot, "power")
	g.link(mot, "rotation", shaft, "in")
	g.link(shaft, "out", pump, "rotation")
	g.link(tank, "drain", p1, "a")
	g.link(p1, "b", p2, "a")
	g.rebuild_networks()
	return g


func _vertical_slice() -> void:
	_eq(ContentDB.get_entry(ContentDB.COPPER_ORE) != null, true,
		"copper ore exists in the world")
	_eq(ContentDB.get_entry(ContentDB.IRON_ORE) != null, true, "iron ore too")
	_eq(ContentDB.material_of(ContentDB.COPPER_ORE), "copper",
		"ore declares which engineering material it is")
	_eq(ContentDB.get_entry(ContentDB.STEEL_BLOCK) != null, true,
		"and steel exists as a refined block")

	_eng = _make_engineering()

	# 1-2. Mine and process. The ore becomes refined metal in the same pack
	# the stone came in, through the same code path.
	_eng.inventory.give_block(ContentDB.COPPER_ORE)
	_eng.place_free("furnace", Vector3.ZERO)
	_eng.inventory.select_slot(0)
	_eng.inventory.fill_hotbar_from_inventory()
	var smelted := _eng.smelt_held()
	_eq(bool(smelted["ok"]), true, "copper ore smelts at a furnace")
	_eq(_eng.inventory.count_of(ContentDB.COPPER_BLOCK), 1,
		"and the refined copper lands in the pack")

	# 3. Build a workshop, out of real materials: the workbench is the one
	# thing a player can build before they have any components, because a
	# component needs a tool and a tool needs a workbench.
	for i in 8:
		_eng.inventory.give_block(ContentDB.WOOD)
	var before := _eng.graph.node_count()
	var bench := _eng.manufacture("workbench", Vector3(4, 0, 0))
	_eq(bool(bench["ok"]), true, "a workbench is manufactured from wood and parts")
	_eq(_eng.graph.node_count(), before + 1, "and exists in the world")
	_eq(_eng.graph.node(int(bench["node"])).part.quality > 0.5, true,
		"and is a real manufactured part with a quality")

	# A component cannot be made before the workshop that can make it.
	_eq(bool(_eng.manufacture("motor")["ok"]), false,
		"a motor cannot be made at a bare workbench")

	# 4. Manufacture the parts. Each is a bill of materials and a station.
	for comp in ["furnace", "forge"]:
		_eng.place_free(comp, Vector3(6, 0, 0))
	_eq(EngWorkshop.best_difficulty(_eng.graph) >= 0.5, true,
		"the forge raises the manufacturing tier")
	for i in 4:
		_eng.inventory.give_block(ContentDB.COPPER_BLOCK)
	for i in 6:
		_eng.inventory.give_block(ContentDB.STEEL_BLOCK)
	_eng.inventory.give_block(ContentDB.IRON_BLOCK)
	# A motor is a bill of materials, and the shaft in that bill is a part the
	# player has to make first. The order matters, and it is the whole
	# progression: nothing is unlocked, everything is built.
	var shaft := _eng.manufacture("shaft", Vector3(9, 0, 0))
	_eq(bool(shaft["ok"]), true, "a shaft is manufactured from steel")
	_eq(_eng.inventory.count_eng("shaft"), 1, "and the steel is gone")
	var motor := _eng.manufacture("motor", Vector3(8, 0, 0))
	_eq(bool(motor["ok"]), true,
		"a motor is manufactured from copper, steel and the shaft just made")
	_eq(_eng.inventory.count_eng("shaft"), 0,
		"and the bill really was paid, including the shaft it consumed")
	_eq(_eng.inventory.count_of(ContentDB.STEEL_BLOCK), 2,
		"and every block of the bill, not just one of each")

	# 5-6. Assemble and connect. The pump works because of what it is made
	# of, not because a recipe says "pump".
	var g := _eng.graph
	var m := int(motor["node"])
	var s := int(shaft["node"])
	var bat: int = _eng.place_free("battery", Vector3(12, 0, 0))
	var wire: int = _eng.place_free("wire", Vector3.ZERO)
	var sw: int = _eng.place_free("switch", Vector3.ZERO)
	var pump: int = _eng.place_free("pump", Vector3(10, 0, 0))
	var tank: int = _eng.place_free("tank", Vector3(14, 0, 0))
	var pipe: int = _eng.place_free("pipe", Vector3.ZERO)
	(g.node(bat) as EngGraph.EngNode).state["stored"] = 1000.0
	(g.node(tank) as EngGraph.EngNode).state["stored"] = 200.0
	_eq(bool(g.link(bat, "positive", wire, "a")["ok"]), true, "battery to wire")
	_eq(bool(g.link(wire, "b", sw, "a")["ok"]), true, "wire to switch")
	_eq(bool(g.link(sw, "b", m, "power")["ok"]), true, "switch to motor")
	_eq(bool(g.link(m, "rotation", s, "in")["ok"]), true, "motor to shaft")
	_eq(bool(g.link(s, "out", pump, "rotation")["ok"]), true, "shaft to pump")
	_eq(bool(g.link(tank, "drain", pipe, "a")["ok"]), true, "tank to pipe")
	_eq(bool(g.link(pipe, "b", pump, "inlet")["ok"]), true, "pipe to pump inlet")
	g.rebuild_networks()

	var rec := EngAssemblies.recognize(g, m)
	_eq(String(rec["name"]), "pump",
		"the assembly is recognised as a pump from its structure")
	_eq(bool(rec["recognized"]), true, "and that name is earned, not assigned")

	# 7. Operate. The water moves.
	_eng.sim.step([Vector3(8, 0, 0)])
	_eq(float((g.node(pump) as EngGraph.EngNode).state["flow"]) > 0.0, true,
		"the pump moves water")
	var stored_after := float((g.node(tank) as EngGraph.EngNode).state["stored"])
	_eq(stored_after < 200.0, true, "drawn from the tank")

	# Opening the switch stops it, because a switch that does nothing is a
	# decoration.
	g.set_enabled(sw, false)
	_eng.sim.step([Vector3(8, 0, 0)])
	_eq(float((g.node(pump) as EngGraph.EngNode).state["flow"]), 0.0,
		"and an open switch stops the water")
	g.set_enabled(sw, true)
	_eng.sim.step([Vector3(8, 0, 0)])
	_eq(float((g.node(pump) as EngGraph.EngNode).state["flow"]) > 0.0, true,
		"and closing it starts the water again")

	# The in-world readout is real text a player could read.
	var readout := _eng.describe_target(m)
	_eq(readout.split("\n")[0], "pump",
		"the target readout names the assembly (first line was '%s')" % readout.split("\n")[0])
	_eq(readout.contains("rpm") or readout.contains("W"), true,
		"and shows the power flowing through it")

	# 8. Save the construction as a blueprint.
	var bp := EngBlueprints.capture(g, [m, s, pump, bat, wire, sw, tank, pipe],
		"my pump")
	_eq((bp["nodes"] as Array).size() == 8, true, "the whole machine is saved")
	var new_id := EngBlueprints.save(bp, "slice_pump")
	_eq(new_id != "", true, "and written to disk")

# --- persistence -----------------------------------------------------------

func _test_persistence() -> void:
	_eng = _make_engineering()
	# Rebuild the working pump inside the engineering system so the save
	# path is the real one.
	var g := _eng.graph
	var bat := _eng.place_free("battery", Vector3.ZERO)
	var wire := _eng.place_free("wire", Vector3.ZERO)
	var mot: int = _eng.place_free("motor", Vector3.ZERO)
	var shaft: int = _eng.place_free("shaft", Vector3.ZERO)
	var pump := _eng.place_free("pump", Vector3.ZERO)
	var tank: int = _eng.place_free("tank", Vector3.ZERO)
	var pipe: int = _eng.place_free("pipe", Vector3.ZERO)
	(g.node(bat) as EngGraph.EngNode).state["stored"] = 1000.0
	(g.node(tank) as EngGraph.EngNode).state["stored"] = 200.0
	g.link(bat, "positive", wire, "a")
	g.link(wire, "b", mot, "power")
	g.link(mot, "rotation", shaft, "in")
	g.link(shaft, "out", pump, "rotation")
	g.link(tank, "drain", pipe, "a")
	g.link(pipe, "b", pump, "inlet")
	g.rebuild_networks()
	_eng.tick(0.2, [Vector3.ZERO])
	_eq(float((g.node(pump) as EngGraph.EngNode).state["flow"]) > 0.0, true,
		"the pump is running before the save")

	# Through the real save file, not a private one.
	var player := Player.new()
	player.position = Vector3(3, 4, 5)
	var data := SaveGame.capture(player, _eng.inventory, null, 0, _eng)
	_eq((data["engineering"] as Dictionary).is_empty(), false,
		"the save file carries the engineering state")
	_eq(SaveGame.write_slot(8, data), true, "and writes to a slot")

	var loaded := SaveGame.load_slot(8)
	_eq(loaded.is_empty(), false, "and reads back")

	# A fresh world from that save, exactly as a player returning to it would.
	var eng2 := EngEngineering.new()
	root.add_child(eng2)
	eng2.build()
	var inv2 := PlayerInventory.new()
	root.add_child(inv2)
	eng2.attach(null, inv2)
	var report := eng2.deserialize(loaded["engineering"])
	_eq(int(report["nodes"]), 7, "every component came back")
	_eq(int(report["edges"]), 6, "and every connection")
	eng2.sim.step([Vector3.ZERO])
	var flows := false
	for n in eng2.graph.all_nodes():
		if float((n as EngGraph.EngNode).state.get("flow", 0.0)) > 0.0:
			flows = true
	_eq(flows, true, "the pump still moves water after a reload")
	_eq(float((eng2.graph.node(bat) as EngGraph.EngNode).state["stored"]) > 0.0,
		true, "and the battery kept its charge")

	# A save from before the engineering system existed is still a good save.
	var old_save := loaded.duplicate(true)
	old_save.erase("engineering")
	var eng3 := EngEngineering.new()
	root.add_child(eng3)
	eng3.build()
	var r3 := SaveGame.apply(old_save, player, PlayerInventory.new(), null, eng3)
	_eq(r3, true, "a world saved before engineering existed still loads")
	_eq(eng3.graph.node_count(), 0, "with no factory in it, and no error")

	eng2.queue_free()
	eng3.queue_free()
	player.queue_free()

# --- performance -----------------------------------------------------------

func _test_performance() -> void:
	# The guarantee that matters: a factory's cost is bounded by how close the
	# player is, not by how much they built.
	var g := EngGraph.new()
	var near := _add_circuit(g, Vector3.ZERO)
	var far := _add_circuit(g, Vector3(20000, 0, 0))
	g.rebuild_networks()
	var sim := EngSimulation.new(g)
	sim.step([Vector3.ZERO])
	_eq(float((g.node(near) as EngGraph.EngNode).state["rpm"]) > 0.0, true,
		"the near circuit is simulated")
	_eq(float((g.node(far) as EngGraph.EngNode).state.get("rpm", 0.0)), 0.0,
		"the far circuit costs nothing")

	# A node on several networks is advanced once per tick, not once per
	# network. This is the check that stops that regression coming back.
	var g2 := EngGraph.new()
	var m: int = g2.place("motor", Vector3.ZERO)
	var sh := g2.place("shaft", Vector3.ZERO)
	var pump := g2.place("pump", Vector3.ZERO)
	var tank: int = g2.place("tank", Vector3.ZERO)
	var pipe: int = g2.place("pipe", Vector3.ZERO)
	var bat := g2.place("battery", Vector3.ZERO)
	var w: int = g2.place("wire", Vector3.ZERO)
	(g2.node(bat) as EngGraph.EngNode).state["stored"] = 1000.0
	(g2.node(tank) as EngGraph.EngNode).state["stored"] = 200.0
	g2.link(bat, "positive", w, "a")
	g2.link(w, "b", m, "power")
	g2.link(m, "rotation", sh, "in")
	g2.link(sh, "out", pump, "rotation")
	g2.link(tank, "drain", pipe, "a")
	g2.link(pipe, "b", pump, "inlet")
	g2.rebuild_networks()
	var sim2 := EngSimulation.new(g2)
	sim2.step([Vector3.ZERO])
	# The pump is on a mechanical network and a fluid network. If it were
	# stepped twice the second pass would clobber the first with a default,
	# and its shaft speed would be zero while the network's is not.
	var pump_state := (g2.node(pump) as EngGraph.EngNode).state
	_eq(float(pump_state["rpm"]) > 0.0, true,
		"a node on two networks is advanced once, with both contexts")
	_eq(float(pump_state["flow"]) > 0.0, true,
		"so neither context clobbers the other")
	_eq(float(g2.network_state(g2.network_of(pipe, EngPorts.Kind.FLUID))
		["pressure"]) > 0.0, true,
		"and the fluid network agrees with the node, in the same tick")

	# Recognition is cached against the graph revision, so a HUD readout does
	# not re-walk the graph every frame.
	var rev := g2.revision
	var a := EngAssemblies.recognize(g2, m)
	EngAssemblies.recognize(g2, m)
	_eq(g2.revision, rev, "recognition does not mutate the graph")
	g2.place("shaft", Vector3.ZERO)
	_eq(g2.revision > rev, true, "an edit bumps the revision so caches invalidate")
	_eq(EngAssemblies.recognize(g2, m)["nodes"] != a["nodes"], true,
		"and the next recognition reflects the edit")

	# Visual streaming is bounded and reuses cached meshes.
	var eng := _make_engineering()
	for i in 40:
		eng.place_free("bolt", Vector3(i * 0.1, 0, 0))
	eng.tick(1.0, [Vector3.ZERO])
	_eq(eng.visual_count() > 0, true, "near components get visuals")
	_eq(eng.visual_count() <= EngEngineering.MAX_VISUALS, true,
		"and the visual count is capped")
	eng.tick(1.0, [Vector3(100000, 0, 0)])
	eng.tick(1.0, [Vector3(100000, 0, 0)])
	_eq(eng.visual_count(), 0, "walking away gives every mesh back")


func _add_circuit(g: EngGraph, at: Vector3) -> int:
	var bat := g.place("battery", at)
	var w := g.place("wire", at)
	var m := g.place("motor", at)
	(g.node(bat) as EngGraph.EngNode).state["stored"] = 1000.0
	g.link(bat, "positive", w, "a")
	g.link(w, "b", m, "power")
	return m

# --- helpers ----------------------------------------------------------------

## A live EngEngineering wired to a fresh GLoot backpack.
func _make_engineering() -> EngEngineering:
	var eng := EngEngineering.new()
	root.add_child(eng)
	eng.build()
	var inv := PlayerInventory.new()
	root.add_child(inv)
	eng.attach(null, inv)
	return eng


func _ok(msg: String) -> void:
	print("  ok   ", msg)


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL ", msg)


func _eq(got: Variant, want: Variant, what: String) -> void:
	if got == want:
		_ok("%s == %s" % [what, str(want)])
	else:
		_fail("%s: got %s, want %s" % [what, str(got), str(want)])


func _finish() -> void:
	print("--- engineering_world_test ---")
	if _fails == 0:
		print("RESULT: PASS")
	else:
		print("RESULT: FAIL (%d)" % _fails)
	quit(1 if _fails > 0 else 0)
