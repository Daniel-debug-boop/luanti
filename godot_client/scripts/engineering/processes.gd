class_name EngProcesses
extends RefCounted
## Layer 5 of the engineering system: generic manufacturing operations.
##
## The player never "unlocks motor". They smelt ore into copper, draw copper
## into wire, cut steel into a shaft, assemble the pieces. Each of those is one
## of these operations applied to a part, so the same operation works on every
## material and every shape.
##
## Every operation is a table: inputs, the tool tier it needs, the energy it
## costs, how long it takes, what it does to the part, and what it wastes. No
## operation knows what a motor is.

static var _ops := {}
static var _order: Array[String] = []


static func register_process(def: Dictionary) -> void:
	var id := String(def.get("id", ""))
	if id == "":
		push_error("[processes] a process needs an id")
		return
	if not _ops.has(id):
		_order.append(id)
	_ops[id] = def.duplicate(true)


static func has(id: String) -> bool:
	_ensure()
	return _ops.has(id)


static func operation(id: String) -> Dictionary:
	_ensure()
	return _ops.get(id, {})


static func all_ids() -> Array[String]:
	_ensure()
	return _order.duplicate()


## Would this operation be legal right now? Same gates as apply_operation,
## but it does not touch the part.
##
## This exists so the in-world preview and the actual click cannot disagree.
## The alternative -- previewing by applying and then undoing -- is how a
## manufacturing system ends up with a half-cut part every time the player
## looks at a plank.
static func check_operation(part: EngPart, op_id: String, params := {},
		tool_difficulty := 1.0, energy_budget := 1.0e9) -> Dictionary:
	_ensure()
	if part == null:
		return {"ok": false, "reason": "no part"}
	if not _ops.has(op_id):
		return {"ok": false, "reason": "unknown process '%s'" % op_id}
	var def: Dictionary = _ops[op_id]

	# Tool tier gate: the material must be within what this tool can shape.
	var required := float(def.get("required_difficulty", 0.0))
	if not EngMaterials.is_machinable(part.material, maxf(tool_difficulty, required)):
		return {"ok": false, "reason": "%s is too hard for this tool (%s needs difficulty %.2f)" % [
			part.material, op_id, required]}

	# Energy gate.
	var cost := float(def.get("energy", 0.0))
	if cost > energy_budget:
		return {"ok": false, "reason": "not enough energy for %s (needs %.1f, have %.1f)" % [
			op_id, cost, energy_budget]}

	# Shape gate: an operation may only be legal on certain base shapes.
	var allowed: Array = def.get("allowed_shapes", [])
	if not allowed.is_empty() and not allowed.has(part.shape):
		return {"ok": false, "reason": "%s cannot be applied to a %s" % [op_id,
			EngPart.SHAPE_NAMES.get(part.shape, "?")]}

	# Thermal gate: a cold part cannot be forged. Each hot process declares the
	# temperature it needs, and the player reaches it with a furnace or forge,
	# which run the "heat" operation below.
	if bool(def.get("needs_heat", false)):
		var need := float(def.get("min_temperature", 0.0))
		if part.temperature < need:
			return {"ok": false, "reason": "%s needs a part at %d C (this one is %.0f C)" % [
				op_id, int(need), part.temperature]}

	# Material constraint: some processes simply do not apply to some
	# materials (you cannot draw a steel wire by bending it).
	var forbidden: Array = def.get("forbidden_materials", [])
	if forbidden.has(part.material):
		return {"ok": false, "reason": "%s cannot be %s" % [part.material, op_id]}

	return {"ok": true, "reason": "", "energy": cost,
		"waste": float(def.get("waste", 0.0))}


## Apply an operation to a part.
##
## Returns { "ok": bool, "reason": String }. The part is left untouched when
## the operation is rejected, so a failed operation never half-mangles a part.
static func apply_operation(part: EngPart, op_id: String,
		params := {}, tool_difficulty := 1.0,
		energy_budget := 1.0e9) -> Dictionary:
	var check := check_operation(part, op_id, params, tool_difficulty,
		energy_budget)
	if not bool(check["ok"]):
		return check
	# An operation that consumes the whole part (melt, cast) resets it to a
	# block of stock before the operation is recorded.
	if op_id == "melt" or op_id == "cast":
		part.shape = EngPart.Shape.BLOCK
		part.size = Vector3(0.08, 0.08, 0.08)
	part.record_operation(op_id, params)
	return check


## Bring a part up to `target` degrees C. This is what a furnace or a forge
## does, and it is an ordinary operation so a mod can gate heating the same way
## it gates anything else. Heat capacity and thermal conductivity decide how
## much energy that costs, so a big steel plate takes longer to heat than a
## small copper one.
static func heat(part: EngPart, target: float) -> Dictionary:
	if part == null:
		return {"ok": false, "reason": "no part"}
	var cap := maxf(EngMaterials.get_prop(part.material, "heat_capacity"), 0.05)
	var cond := maxf(EngMaterials.get_prop(part.material, "thermal_conductivity"), 0.01)
	var delta := target - part.temperature
	if delta <= 0.0:
		return {"ok": false, "reason": "already at or above %.0f C" % target}
	var cost := delta * cap * part.volume() * (2.0 - cond)
	return apply_operation(part, "heat", {"to": target},
		1.0, cost + 0.0001)


## Passive cooling towards ambient. Called by the simulation LOD when a part is
## in a room rather than a furnace, so a part taken out of a forge goes cold.
static func cool(part: EngPart, ambient := 20.0, dt := 1.0) -> void:
	if part == null:
		return
	var cond := maxf(EngMaterials.get_prop(part.material, "thermal_conductivity"), 0.01)
	var k := clampf(dt * (0.05 + cond * 0.3), 0.0, 1.0)
	part.temperature += (ambient - part.temperature) * k


## Is this part currently hot enough for `op_id`? The in-world preview uses this
## to grey out a forge icon on a cold part instead of letting the player fail.
static func is_hot_enough(part: EngPart, op_id: String) -> bool:
	var def: Dictionary = operation(op_id)
	if not bool(def.get("needs_heat", false)):
		return true
	return part != null and part.temperature >= float(def.get("min_temperature", 0.0))


## Can this operation be applied at all, without doing it? Used by the
## in-world preview so a cut line only appears where the cut is legal.
static func would_apply(part: EngPart, op_id: String,
		tool_difficulty := 1.0) -> bool:
	_ensure()
	if part == null or not _ops.has(op_id):
		return false
	var def: Dictionary = _ops[op_id]
	var allowed: Array = def.get("allowed_shapes", [])
	if not allowed.is_empty() and not allowed.has(part.shape):
		return false
	if not is_hot_enough(part, op_id):
		return false
	return EngMaterials.is_machinable(part.material,
		maxf(tool_difficulty, float(def.get("required_difficulty", 0.0))))


## Total energy to run a whole process chain, for the UI and for scheduling.
static func chain_energy(chain: Array) -> float:
	var total := 0.0
	for op in chain:
		total += float(operation(String(op)).get("energy", 0.0))
	return total


static func serialize() -> Dictionary:
	_ensure()
	return {"version": 1, "processes": _ops.duplicate(true)}


static func _ensure() -> void:
	if not _ops.is_empty():
		return
	for def in _default_processes():
		register_process(def)


static func _default_processes() -> Array:
	return [
		# --- stock reduction ---
		{
			"id": "cut", "name": "Cut", "required_difficulty": 0.0,
			"energy": 1.0, "duration": 0.4, "waste": 0.15,
			"quality_delta": -0.02,
			"allowed_shapes": [EngPart.Shape.PLANK, EngPart.Shape.PLATE,
				EngPart.Shape.ROD, EngPart.Shape.BLOCK],
		},
		{
			"id": "drill", "name": "Drill", "required_difficulty": 0.15,
			"energy": 2.0, "duration": 0.8, "waste": 0.05,
			"quality_delta": 0.03,
			"allowed_shapes": [EngPart.Shape.PLANK, EngPart.Shape.PLATE,
				EngPart.Shape.BLOCK],
		},
		{
			"id": "mill", "name": "Mill", "required_difficulty": 0.35,
			"energy": 3.0, "duration": 1.0, "waste": 0.08,
			"quality_delta": 0.04,
		},
		{
			"id": "grind", "name": "Grind", "required_difficulty": 0.2,
			"energy": 2.0, "duration": 0.7, "waste": 0.04,
			"quality_delta": 0.02,
		},
		{
			"id": "polish", "name": "Polish", "required_difficulty": 0.25,
			"energy": 2.5, "duration": 1.2, "waste": 0.01,
			"quality_delta": 0.06,
		},
		{
			"id": "bend", "name": "Bend", "required_difficulty": 0.3,
			"energy": 3.0, "duration": 1.0, "waste": 0.06,
			"quality_delta": -0.03,
		},
		{
			"id": "extrude", "name": "Extrude", "required_difficulty": 0.4,
			"energy": 4.0, "duration": 1.4, "waste": 0.12,
			"quality_delta": -0.02,
		},
		{
			"id": "press", "name": "Press", "required_difficulty": 0.45,
			"energy": 4.0, "duration": 1.3, "waste": 0.05,
			"quality_delta": 0.01,
		},
		# --- thermal ---
		{
			"id": "heat", "name": "Heat", "required_difficulty": 0.0,
			"energy": 0.0, "duration": 1.0, "waste": 0.0, "quality_delta": 0.0,
		},
		{
			"id": "melt", "name": "Melt", "required_difficulty": 0.0,
			"energy": 12.0, "duration": 3.0, "waste": 0.25,
			"quality_delta": -0.08, "needs_heat": true, "min_temperature": 1085.0,
		},
		{
			"id": "cast", "name": "Cast", "required_difficulty": 0.1,
			"energy": 8.0, "duration": 2.5, "waste": 0.2,
			"quality_delta": -0.06, "needs_heat": true, "min_temperature": 900.0,
		},
		{
			"id": "forge", "name": "Forge", "required_difficulty": 0.35,
			"energy": 10.0, "duration": 2.2, "waste": 0.1,
			"quality_delta": 0.05, "needs_heat": true, "min_temperature": 800.0,
		},
		{
			"id": "heat_treat", "name": "Heat treat", "required_difficulty": 0.45,
			"energy": 9.0, "duration": 2.0, "waste": 0.05,
			"quality_delta": 0.12, "needs_heat": true, "min_temperature": 700.0,
		},
		# --- joining ---
		{
			"id": "weld", "name": "Weld", "required_difficulty": 0.5,
			"energy": 11.0, "duration": 2.5, "waste": 0.08,
			"quality_delta": 0.02, "needs_heat": true, "min_temperature": 600.0,
		},
		{
			"id": "solder", "name": "Solder", "required_difficulty": 0.25,
			"energy": 4.0, "duration": 1.0, "waste": 0.03,
			"quality_delta": -0.01, "needs_heat": true, "min_temperature": 250.0,
		},
		{
			"id": "assemble", "name": "Assemble", "required_difficulty": 0.0,
			"energy": 2.0, "duration": 1.0, "waste": 0.0,
			"quality_delta": 0.0,
		},
		{
			"id": "disassemble", "name": "Disassemble", "required_difficulty": 0.0,
			"energy": 1.0, "duration": 0.6, "waste": 0.0,
			"quality_delta": 0.0,
		},
	]
