class_name EngTools
extends RefCounted
## Context-aware tools: the tool decides the operation.
##
## The player equips a saw and looks at a plank. The game does not open a
## menu. It works out that a saw cuts, works out where the cut lands from the
## cursor, shows the cut, and applies it on click. Everything else -- which
## materials the saw can touch, how long it takes, what it wastes -- comes
## from the same process table the workshop uses, so a hand saw and a bandsaw
## are the same operation at different tool tiers rather than two systems.
##
## A tool is a small table: which process it performs, the tool tier it
## represents, and how it reads the world. That is the entire extension point
## a mod needs for a new implement.

## One tool definition.
class Tool:
	var id: String
	var name: String
	## The manufacturing process this tool performs.
	var process: String
	## Tool tier, compared against a material's manufacturing_difficulty.
	var difficulty: float
	## How the tool reads the world to build its parameters.
	## "cursor"  a position along an axis (saw)
	## "point"   a point on a face (drill, welding)
	var mode: String
	## Energy it costs per operation, on top of the process cost.
	var energy: float
	## Component this tool places, if any, when used with nothing targeted.
	var places: String

	func _init(p_id: String, p_process: String, p_difficulty: float,
			p_mode: String, p_name: String = "") -> void:
		id = p_id
		process = p_process
		difficulty = p_difficulty
		mode = p_mode
		name = p_name if p_name != "" else p_id.capitalize()


static var _tools := {}
static var _order: Array[String] = []
static var _built := false

## Pseudo-process for tools that place a component instead of shaping a part.
const PLACE := "place"


static func register_tool(t: Tool) -> void:
	_build()
	if t.id == "" or t.process == "":
		push_error("[tools] a tool needs an id and a process")
		return
	if not _tools.has(t.id):
		_order.append(t.id)
	_tools[t.id] = t


static func get_tool(id: String) -> Tool:
	_build()
	return _tools.get(id, null)


static func all_ids() -> Array[String]:
	_build()
	return _order.duplicate()


## Work out what using `tool_id` on `part` at `context` would do, without
## doing it. Returns { ok, reason, process, params, tool }.
##
## The result is what the in-world preview draws, so legality is decided in
## exactly one place and the preview can never offer something the click
## would then refuse.
static func preview(tool_id: String, part: EngPart, context := {},
		energy_budget := 1.0e9) -> Dictionary:
	_build()
	var t: Tool = _tools.get(tool_id, null)
	if t == null:
		return {"ok": false, "reason": "unknown tool '%s'" % tool_id}
	# A placement tool used on nothing becomes a component; used on something,
	# it is not a shaping tool and says so rather than guessing.
	if t.process == PLACE:
		if part != null:
			return {"ok": false, "reason": "%s places a component, not an operation" % t.name}
		if t.places == "":
			return {"ok": false, "reason": "%s has nothing to place" % t.name}
		return {"ok": true, "reason": "", "process": PLACE,
			"params": {"component": t.places}, "tool": t.id}
	if part == null:
		return {"ok": false, "reason": "%s needs something to work on" % t.name}
	if not EngProcesses.has(t.process):
		return {"ok": false, "reason": "%s performs an unknown process" % t.name}
	var params := _params_for(t, part, context)
	# check_operation, not apply_operation: the preview must not cut the
	# plank the player is merely looking at.
	var r := EngProcesses.check_operation(part, t.process, params,
		t.difficulty, energy_budget)
	return {"ok": bool(r["ok"]), "reason": String(r["reason"]),
		"process": t.process, "params": params, "tool": t.id,
		"energy": float(r.get("energy", 0.0))}


## Build the process parameters from the world, per the tool's read mode.
static func _params_for(t: Tool, part: EngPart, context: Dictionary) -> Dictionary:
	match t.mode:
		"cursor":
			# A saw works along an axis at a fraction of the part's length.
			var axis := String(context.get("axis", "x"))
			var at := float(context.get("at", 0.5))
			return {"axis": axis, "at": at}
		"point":
			var pos: Vector3 = context.get("position",
				Vector3(part.size.x * 0.5, part.size.y * 0.5, part.size.z * 0.5))
			var radius := float(context.get("radius", 0.02))
			return {"pos": pos, "radius": radius, "depth": _axis_depth(part, pos)}
		_:
			return context.get("params", {})


## A drill goes as deep as the thinnest axis, which is what happens when you
## drill a plate: the bit breaks through rather than tunnelling.
static func _axis_depth(part: EngPart, pos: Vector3) -> float:
	return maxf(minf(minf(part.size.x, part.size.y), part.size.z), 0.01)


## Use the tool for real. Applies the operation, then optionally places the
## component the tool represents, and returns the same shape as preview() so
## the caller can report either identically.
static func use(tool_id: String, part: EngPart, context := {},
		energy_budget := 1.0e9) -> Dictionary:
	var p := preview(tool_id, part, context, energy_budget)
	if not bool(p["ok"]) or String(p["process"]) == PLACE:
		return p
	var r := EngProcesses.apply_operation(part, String(p["process"]),
		p["params"] as Dictionary, float((get_tool(tool_id) as Tool).difficulty),
		energy_budget)
	return {"ok": bool(r["ok"]), "reason": String(r["reason"]),
		"process": String(p["process"]), "params": p["params"], "tool": tool_id,
		"energy": float(r.get("energy", 0.0))}


## Human-readable summary of a tool for the hotbar, so the player knows what
## they picked up without opening anything.
static func describe(tool_id: String) -> String:
	var t := get_tool(tool_id)
	if t == null:
		return ""
	if t.process == PLACE:
		return "%s (places %s)" % [t.name, t.places]
	return "%s (%s, tier %.1f)" % [t.name, t.process, t.difficulty]

# --- stock tools -----------------------------------------------------------

static func _build() -> void:
	if _built:
		return
	_built = true
	for t in _default_tools():
		register_tool(t)


static func _default_tools() -> Array:
	return [
		# Hand tools first: everything above tier 0.2 is something the player
		# has to build a workshop to get.
		Tool.new("hand_saw", "cut", 0.10, "cursor", "hand saw"),
		Tool.new("stone_axe", "cut", 0.15, "cursor", "stone axe"),
		Tool.new("hand_drill", "drill", 0.15, "point", "hand drill"),
		Tool.new("hammer", "assemble", 0.05, "point", "assembly hammer"),
		Tool.new("wrench", "assemble", 0.25, "point", "wrench"),
		Tool.new("grinder", "grind", 0.30, "point", "angle grinder"),
		Tool.new("welder", "weld", 0.50, "point", "arc welder"),
		Tool.new("soldering_iron", "solder", 0.25, "point", "soldering iron"),
		Tool.new("file", "mill", 0.20, "cursor", "mill file"),
		Tool.new("polishing_block", "polish", 0.25, "point", "polishing block"),

		# Bench tools: higher tiers, unlocked by building the stations.
		Tool.new("bandsaw", "cut", 0.45, "cursor", "bandsaw"),
		Tool.new("press_tool", "press", 0.45, "point", "press"),
		Tool.new("dropper", "extrude", 0.40, "point", "dropper"),
		Tool.new("crucible", "melt", 0.0, "point", "crucible"),

		# Lab tools: the top tier, and the only things that touch silicon or
		# carbon. Deliberately unavailable until the laboratory is standing.
		Tool.new("engraver", "mill", 0.80, "point", "precision engraver"),
		Tool.new("laser_cutter", "cut", 0.85, "cursor", "laser cutter"),

		# Tools that place a component rather than shape a part. This is how
		# the player gets from raw material to a motor.
		Tool.new("assembly_hammer", "assemble", 0.30, "point", "assembly tool"),
		Tool.new("tongs", "place", 0.0, "point", "component tongs"),
	]
