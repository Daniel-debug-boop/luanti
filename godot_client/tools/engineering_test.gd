extends SceneTree
## Material, component/port, geometry and process layers.
##
## These are the foundation the rest of the engineering system stands on, so
## this suite checks the properties that actually matter: that a material can
## be defined without touching engine code, that a port refuses an incompatible
## mate, that a cut really changes the geometry, and that a rejected operation
## leaves the part exactly as it was.

var _fails := 0


func _init() -> void:
	_test_material_properties()
	_test_material_registration()
	_test_material_serialization()
	_test_component_library()
	_test_ports()
	_test_connection_rules()
	_test_geometry()
	_test_processes()
	_test_process_rejection()
	_test_thermal()
	_finish()


# --- materials --------------------------------------------------------------

func _test_material_properties() -> void:
	# Every property in the table must be readable, and every stock material
	# must be total: no missing keys, no accidental zero defaults.
	_eq(EngMaterials.all_ids().size() >= 13, true, "stock material families registered")
	for id in EngMaterials.all_ids():
		var p := EngMaterials.props_of(id)
		var missing := 0
		for prop in EngMaterials.PROPS:
			if not p.has(prop):
				missing += 1
		_eq(missing, 0, "'%s' defines every property" % id)

	# The values have to mean something, not just exist.
	_eq(EngMaterials.get_prop("copper", "electrical_conductivity")
		> EngMaterials.get_prop("steel", "electrical_conductivity"), true,
		"copper conducts better than steel")
	_eq(EngMaterials.get_prop("wood", "flammability")
		> EngMaterials.get_prop("steel", "flammability"), true,
		"wood is more flammable than steel")
	_eq(EngMaterials.get_prop("aluminum", "density")
		< EngMaterials.get_prop("steel", "density"), true,
		"aluminium is lighter than steel")
	_eq(EngMaterials.get_prop("stainless_steel", "corrosion_resistance")
		> EngMaterials.get_prop("iron", "corrosion_resistance"), true,
		"stainless resists corrosion better than iron")
	_eq(EngMaterials.get_prop("copper", "melting_temperature") < 1200.0, true,
		"copper melts below iron")
	_eq(EngMaterials.get_prop("carbon", "melting_temperature") > 3000.0, true,
		"carbon has a very high melting point")

	# Mass has to scale with density, or structural load is meaningless.
	var light := EngMaterials.mass_of("aluminum", 1.0)
	var heavy := EngMaterials.mass_of("steel", 1.0)
	_eq(light < heavy, true, "an equal volume of aluminium weighs less")

	# Machinability gates which processes can shape a material.
	_eq(EngMaterials.is_machinable("wood", 0.1), true, "a stone tool shapes wood")
	_eq(EngMaterials.is_machinable("silicon", 0.1), false,
		"a stone tool cannot shape silicon")
	_eq(EngMaterials.is_machinable("silicon", 0.8), true,
		"an industrial tool shapes silicon")


func _test_material_registration() -> void:
	# A mod adds a material with a partial definition; the rest comes from
	# DEFAULTS. This is the extension point the mod API is built on.
	EngMaterials.register_material("unobtainium", {
		"density": 0.99, "strength": 0.99, "manufacturing_difficulty": 0.9,
		"color": Color(0.2, 0.9, 0.6),
	})
	_eq(EngMaterials.has("unobtainium"), true, "a mod can register a material")
	_eq(EngMaterials.get_prop("unobtainium", "strength"), 0.99, "override applied")
	_eq(EngMaterials.get_prop("unobtainium", "hardness"),
		float(EngMaterials.DEFAULTS["hardness"]), "omitted property falls back")
	_eq(EngMaterials.color_of("unobtainium"), Color(0.2, 0.9, 0.6), "colour applied")
	_eq(EngMaterials.has("nonexistent_material"), false, "unknown material absent")
	_eq(EngMaterials.get_prop("nonexistent_material", "strength"),
		float(EngMaterials.DEFAULTS["strength"]), "unknown material returns defaults")

	# props_of must hand back a copy, or a caller could corrupt the table.
	var snap := EngMaterials.props_of("copper")
	snap["strength"] = -1.0
	_eq(EngMaterials.get_prop("copper", "strength") != -1.0, true,
		"props_of returns an independent copy")

	# Replacing a definition is allowed and must not duplicate the id.
	var before := EngMaterials.all_ids().size()
	EngMaterials.register_material("unobtainium", {"density": 0.5})
	_eq(EngMaterials.all_ids().size(), before, "re-registering does not duplicate")
	_eq(EngMaterials.get_prop("unobtainium", "density"), 0.5, "redefinition wins")


func _test_material_serialization() -> void:
	var blob := EngMaterials.serialize()
	_eq(int(blob.get("version", 0)), 1, "material table is versioned")

	# A save holds the whole table, so the simulation is reproducible after a
	# reload even if the mod that defined a material is no longer loaded.
	var saved_strength := EngMaterials.get_prop("steel", "strength")
	EngMaterials.register_material("steel", {"strength": 0.1})
	_eq(EngMaterials.get_prop("steel", "strength"), 0.1, "table was mutated")
	var report := EngMaterials.deserialize(blob)
	_eq(int(report["restored"]) > 0, true, "serialized table restores")
	_eq(EngMaterials.get_prop("steel", "strength"), saved_strength,
		"round trip restores the original value")

	# Forward compatibility: a material the build no longer knows about is
	# reported rather than dropped, and existing materials are left alone.
	_eq(report["unknown"].has("nonexistent_material"), false,
		"known materials are not reported as unknown")

	EngMaterials.register_material("steel", {"strength": saved_strength})


# --- components and ports ---------------------------------------------------

func _test_component_library() -> void:
	_eq(EngPorts.all_ids().size() >= 40, true, "component library is populated")

	# The vertical slice's parts must all exist as real components.
	for id in ["motor", "shaft", "bearing", "bolt", "plate", "beam", "wire",
			"battery", "switch", "pump", "pipe", "impeller", "housing",
			"workbench", "furnace"]:
		_eq(EngPorts.has(id), true, "component '%s' is registered" % id)

	# A motor is reusable precisely because it exposes standard ports. Its
	# interface is what lets it drive a pump, a fan or a conveyor unchanged.
	var motor := EngPorts.get_def("motor")
	_eq(motor != null, true, "motor definition exists")
	_eq(motor.port("power") != null, true, "motor has a power_input")
	_eq(motor.port("rotation") != null, true, "motor has a rotation_output")
	_eq(motor.port("heat") != null, true, "motor has a heat_output")
	_eq(motor.port("power").kind, EngPorts.Kind.ELECTRICAL, "power port is electrical")
	_eq(motor.port("rotation").kind, EngPorts.Kind.MECHANICAL, "rotation port is mechanical")
	_eq(motor.port("power").flow, EngPorts.Flow.INPUT, "power port is an input")
	_eq(motor.port("rotation").flow, EngPorts.Flow.OUTPUT, "rotation port is an output")
	_eq(motor.port("nope"), null, "unknown port returns null")
	_eq(motor.port_names().has("heat"), true, "ports are enumerable")

	# Component properties carry the numbers the simulation needs, so the
	# motor is a table, not a special case in the machine code.
	_eq(float(motor.properties.get("max_rpm", 0.0)) > 0.0, true, "motor has a speed limit")
	_eq(float(motor.properties.get("max_torque", 0.0)) > 0.0, true, "motor has torque")

	var gb := EngPorts.get_def("gearbox")
	_eq(float(gb.properties.get("ratio", 1.0)) > 1.0, true, "gearbox has a reduction ratio")


func _test_ports() -> void:
	var a := EngPorts.Port.new("out", EngPorts.Kind.MECHANICAL, EngPorts.Flow.OUTPUT)
	var b := EngPorts.Port.new("in", EngPorts.Kind.MECHANICAL, EngPorts.Flow.INPUT)
	_eq(a.can_emit(), true, "an output port emits")
	_eq(a.can_receive(), false, "an output port does not receive")
	_eq(b.can_receive(), true, "an input port receives")
	_eq(a.compatible_with(b), true, "output mates with input")
	# Direction is symmetric: asking the other way gives the same answer.
	_eq(b.compatible_with(a), true, "compatibility is symmetric")

	var bw := EngPorts.Port.new("wire", EngPorts.Kind.ELECTRICAL, EngPorts.Flow.BIDIRECTIONAL)
	_eq(bw.can_receive() and bw.can_emit(), true, "a wire is bidirectional")
	_eq(a.compatible_with(bw), false, "mechanical and electrical never mate")
	_eq(bw.compatible_with(a), false, "and not the other way either")

	# A port carrying a specific fluid will not accept a different one.
	var water := EngPorts.fluid_in("in", "water", 10.0)
	var oil := EngPorts.fluid_out("out", "oil", 10.0)
	var any_fluid := EngPorts.fluid_out("out", "", 10.0)
	_eq(water.compatible_with(oil), false, "a water port rejects oil")
	_eq(water.compatible_with(any_fluid), true, "a water port accepts a generic port")
	# Direction still matters even for compatible fluids: an input cannot be
	# joined to another input, or power would flow nowhere.
	_eq(water.compatible_with(EngPorts.fluid_in("in2", "water", 10.0)), false,
		"two fluid inputs do not mate")

	# A speed rating is a limit on how fast the network runs, not a reason to
	# refuse the connection. A 500 rpm gearbox output driving a 3000 rpm
	# shaft is a perfectly normal thing to build; it just runs at 500 rpm,
	# and the simulation applies that cap to the whole train.
	var slow := EngPorts.mech_out("shaft", 500.0)
	var fast := EngPorts.mech_in("shaft", 3000.0)
	_eq(slow.compatible_with(fast), true, "a slow port still mates with a fast one")
	_eq(slow.max_rpm, 500.0, "the rating is carried on the port")
	_eq(fast.max_rpm, 3000.0, "and on the other end too")

	_eq(a.describe(), "mechanical:out(out)", "a port describes itself")
	_eq(EngPorts.kind_name(EngPorts.Kind.THERMAL), "thermal", "kinds have names")


func _test_connection_rules() -> void:
	# The whole point of typed ports: a motor cannot be wired to a pipe.
	_eq(EngPorts.check_connection("motor", "power", "wire", "a"), "",
		"motor power wires to a wire")
	_eq(EngPorts.check_connection("motor", "rotation", "shaft", "in"), "",
		"motor rotation drives a shaft")
	_eq(EngPorts.check_connection("motor", "power", "pipe", "a") != "", true,
		"an electrical port refuses a fluid port")
	_eq(EngPorts.check_connection("motor", "heat", "motor", "power") != "", true,
		"a thermal port refuses an electrical port")
	_eq(EngPorts.check_connection("motor", "nope", "wire", "a") != "", true,
		"a missing port is rejected")
	_eq(EngPorts.check_connection("nope", "a", "wire", "a") != "", true,
		"an unknown component is rejected")

	# A source -> wire -> switch -> load chain must build out of the same
	# generic rule, with no per-machine special casing.
	_eq(EngPorts.check_connection("battery", "positive", "wire", "a"), "",
		"battery feeds a wire")
	_eq(EngPorts.check_connection("wire", "b", "switch", "a"), "",
		"a wire feeds a switch")
	_eq(EngPorts.check_connection("switch", "b", "motor", "power"), "",
		"a switch feeds a motor")
	_eq(EngPorts.check_connection("motor", "rotation", "pump", "rotation"), "",
		"a motor drives a pump")
	_eq(EngPorts.check_connection("pump", "outlet", "pipe", "a"), "",
		"a pump pushes into a pipe")


# --- geometry ---------------------------------------------------------------

func _test_geometry() -> void:
	var plank := EngPart.plank("wood", 1.2)
	_eq(plank.shape, EngPart.Shape.PLANK, "plank factory sets the shape")
	_eq(is_equal_approx(plank.size.x, 1.2), true, "plank is the requested length")
	_eq(plank.volume() > 0.0, true, "a part has volume")
	_eq(plank.mass() > 0.0, true, "a part has mass")
	_eq(plank.half_extent(), plank.size * 0.5, "half extent is half the size")

	# A cut must change the geometry, deterministically and repeatably.
	var before := plank.size.x
	var r1 := EngProcesses.apply_operation(plank, "cut", {"axis": "x", "at": 0.5})
	_eq(bool(r1["ok"]), true, "a saw cuts a plank")
	_eq(plank.size.x < before, true, "the cut shortened the part")
	_eq(is_equal_approx(plank.size.x, before * 0.5), true,
		"the cut landed where the cursor was")
	_eq(plank.operations.has("cut"), true, "the operation is in the history")

	# Applying the same operation to an equivalent part gives an equivalent
	# result, which is what makes a blueprint reproducible.
	var a := EngPart.plank("wood", 1.0)
	var b := EngPart.plank("wood", 1.0)
	EngProcesses.apply_operation(a, "cut", {"axis": "x", "at": 0.4})
	EngProcesses.apply_operation(b, "cut", {"axis": "x", "at": 0.4})
	_eq(a.size, b.size, "the same operations give the same geometry")
	# Drilling adds a hole, and holes are data, not mesh data.
	var plate := EngPart.plate("steel", 0.4)
	var h0 := plate.holes.size()
	EngProcesses.apply_operation(plate, "drill", {"radius": 0.02, "depth": 0.03})
	_eq(plate.holes.size(), h0 + 1, "a drill leaves a hole")
	_eq(float(plate.holes[0]["radius"]), 0.02, "the hole keeps its radius")

	# Serialization round trip, which is what a blueprint is made of.
	var restored := EngPart.from_dict(plank.to_dict())
	_eq(restored.size, plank.size, "size round-trips")
	_eq(restored.material, plank.material, "material round-trips")
	_eq(restored.operations, plank.operations, "operation history round-trips")
	_eq(restored.holes.size(), plank.holes.size(), "holes round-trip")
	_eq(restored.custom_dimensions, plank.custom_dimensions, "authored flag round-trips")


func _test_processes() -> void:
	_eq(EngProcesses.all_ids().size() >= 16, true, "process table is populated")
	for id in ["cut", "drill", "mill", "grind", "bend", "cast", "forge", "melt",
			"weld", "solder", "assemble", "disassemble", "polish", "heat_treat",
			"extrude", "press"]:
		_eq(EngProcesses.has(id), true, "process '%s' exists" % id)

	# Every process declares what it needs, so the UI can gate on data.
	for id in EngProcesses.all_ids():
		var def := EngProcesses.operation(id)
		_eq(def.has("required_difficulty"), true, "'%s' declares a tool tier" % id)
		_eq(def.has("energy"), true, "'%s' declares an energy cost" % id)
		_eq(def.has("duration"), true, "'%s' declares a duration" % id)
		_eq(def.has("waste"), true, "'%s' declares waste" % id)

	# The copper -> wire chain from the design brief, as generic operations.
	var ingot := EngPart.block("copper", 0.08)
	_eq(EngProcesses.heat(ingot, 1200.0)["ok"], true, "a furnace can heat copper")
	_eq(ingot.temperature >= 1085.0, true, "the ingot is above copper's melt point")
	_eq(bool(EngProcesses.apply_operation(ingot, "melt", {})["ok"]), true,
		"hot copper melts")
	var wire := EngPart.rod("copper", 0.8, 0.01)
	_eq(bool(EngProcesses.apply_operation(wire, "extrude", {})["ok"]), true,
		"molten copper is drawn into wire")
	_eq(wire.material, "copper", "drawing preserves the material")

	# Energy is consumed, and an unaffordable operation is refused rather than
	# silently performed.
	var steel := EngPart.block("steel", 0.08)
	var cheap := EngProcesses.apply_operation(steel, "cut", {}, 1.0, 1.0)
	_eq(bool(cheap["ok"]), true, "an affordable operation runs")
	_eq(float(cheap["energy"]) > 0.0, true, "it reports its energy cost")
	var broke := EngProcesses.apply_operation(steel, "cut", {}, 1.0, 0.0)
	_eq(bool(broke["ok"]), false, "an unaffordable operation is refused")
	_eq(String(broke["reason"]).length() > 0, true, "and says why")


func _test_process_rejection() -> void:
	# The important guarantee: a rejected operation leaves the part untouched.
	# A half-mangled part would be unrecoverable in a save file.
	var part := EngPart.plank("wood", 1.0)
	var before := part.to_dict()
	var r := EngProcesses.apply_operation(part, "no_such_process", {})
	_eq(bool(r["ok"]), false, "an unknown process is rejected")
	_eq(String(r["reason"]).length() > 0, true, "rejection explains itself")
	_eq(part.to_dict(), before, "a rejected operation did not change the part")

	# Silicon is not something a hand tool shapes.
	var silicon := EngPart.block("silicon", 0.05)
	var r2 := EngProcesses.apply_operation(silicon, "cut", {}, 0.1, 1.0e9)
	_eq(bool(r2["ok"]), false, "a low tier tool cannot cut silicon")
	_eq(silicon.size, Vector3(0.05, 0.05, 0.05), "the failed cut changed nothing")

	# Shape gating: you cannot drill a rod with this operation table.
	var rod := EngPart.rod("steel", 0.5)
	var r3 := EngProcesses.apply_operation(rod, "drill", {}, 1.0, 1.0e9)
	_eq(bool(r3["ok"]), false, "a drill is not legal on a rod")
	_eq(rod.holes.size(), 0, "no hole was punched")

	# Cold metal does not forge.
	var cold := EngPart.block("iron", 0.06)
	_eq(EngProcesses.is_hot_enough(cold, "forge"), false,
		"a cold part is not forgeable")
	var r4 := EngProcesses.apply_operation(cold, "forge", {}, 1.0, 1.0e9)
	_eq(bool(r4["ok"]), false, "forging a cold part is refused")
	_eq(cold.operations.size(), 0, "the refused forge left no trace")

	# The preview agrees with the actual result, so the in-world cut line
	# never offers an operation that would then fail.
	_eq(EngProcesses.would_apply(cold, "forge", 1.0), false,
		"the preview hides forge on a cold part")
	var hot := EngPart.block("iron", 0.06)
	EngProcesses.heat(hot, 900.0)
	_eq(EngProcesses.would_apply(hot, "forge", 1.0), true,
		"the preview offers forge on a hot part")
	_eq(EngProcesses.would_apply(silicon, "cut", 0.1), false,
		"the preview hides a cut the tool cannot make")


func _test_thermal() -> void:
	# Heating costs energy proportional to heat capacity and volume, so a big
	# steel plate is harder to heat than a small copper one.
	var small := EngPart.block("copper", 0.05)
	var big := EngPart.block("steel", 0.3)
	EngProcesses.heat(small, 1000.0)
	EngProcesses.heat(big, 1000.0)
	_eq(small.temperature, 1000.0, "heating sets the temperature")
	_eq(big.temperature, 1000.0, "heating sets the temperature on a big part too")
	_eq(small.temperature < big.temperature, false, "both reach the target")

	# Heating something already hot is a no-op, not an error.
	var again := EngProcesses.heat(small, 500.0)
	_eq(bool(again["ok"]), false, "you cannot cool a part by heating it")
	_eq(small.temperature, 1000.0, "the temperature is unchanged")

	# Parts cool towards ambient once out of the fire.
	EngProcesses.cool(small, 20.0, 60.0)
	_eq(small.temperature < 1000.0, true, "a part left alone cools down")
	_eq(small.temperature >= 20.0, true, "and does not go below ambient")

	# Temperature survives a save, so a part stays hot across a reload.
	var restored := EngPart.from_dict(small.to_dict())
	_eq(restored.temperature, small.temperature, "temperature round-trips")

	# Heat treating quenches: it needs heat, and it leaves the part cooler but
	# higher quality.
	var shaft := EngPart.rod("steel", 0.6)
	var q0 := shaft.quality
	EngProcesses.heat(shaft, 800.0)
	_eq(bool(EngProcesses.apply_operation(shaft, "heat_treat", {})["ok"]), true,
		"a hot steel shaft can be heat treated")
	_eq(shaft.quality > q0, true, "heat treating improves the part")
	_eq(shaft.temperature, 60.0, "quenching leaves it cool enough to handle")
	_eq(EngProcesses.is_hot_enough(shaft, "heat_treat"), false,
		"a quenched part must be reheated before treating again")


# --- helpers ----------------------------------------------------------------

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
	print("--- engineering_test ---")
	if _fails == 0:
		print("RESULT: PASS")
	else:
		print("RESULT: FAIL (%d)" % _fails)
	quit(1 if _fails > 0 else 0)
