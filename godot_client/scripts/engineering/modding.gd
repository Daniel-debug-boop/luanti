class_name EngModding
extends RefCounted
## The stable extension API.
##
## Everything in the engineering system is a table, and this file is the one
## place a mod or an AI has to know to reach. Adding a material, a component,
## a process, a tool, a machine behaviour or a whole recognised assembly is
## one call. None of it requires editing engine code, and none of it requires
## the mod author to understand the simulation.
##
## What a mod can register, and what it gets for free:
##
##   register_material       a row in the material table
##   register_component      a part with typed ports; instantly placeable,
##                           carryable, savable and blueprintable
##   register_process        a manufacturing operation, with the same
##                           tool/energy/shape gates as the stock ones
##   register_tool           an implement that drives a process
##   register_machine_behavior  what a component does on a network
##   register_assembly       a recognition pattern, giving a name and a
##                           summary to a structure the game did not know
##   register_sensor         something a controller can read
##   register_controller     a program that reads data and drives actuators
##   register_blueprint      a pre-authored assembly
##
## The design rule throughout: registration is additive and never
## destructive. A mod that re-registers a stock id overrides it deliberately,
## and a mod that adds something the game has never heard of still simulates,
## saves and reloads correctly.

static var _log: Array[Dictionary] = []
static var _sensors := {}
static var _controllers := {}
static var _built := false


# --- materials --------------------------------------------------------------

static func register_material(id: String, properties: Dictionary) -> bool:
	if id == "":
		push_error("[modding] a material needs an id")
		return false
	EngMaterials.register_material(id, properties)
	_record("material", id)
	return true

# --- components -------------------------------------------------------------

## Register a component from plain data, for a mod that would rather not
## construct EngPorts.Component by hand. Ports are given as a dictionary of
## name -> "kind:flow" or name -> "kind", e.g. { "power": "electrical:in" }.
static func register_component(id: String, spec: Dictionary) -> bool:
	if id == "":
		push_error("[modding] a component needs an id")
		return false
	var kind := String(spec.get("category", "machine"))
	var material := String(spec.get("material", "steel"))
	var cost := float(spec.get("material_cost", 0.01))
	var ports: Array = []
	for pname in (spec.get("ports", {}) as Dictionary).keys():
		ports.append(parse_port(String(pname), String(
			spec["ports"][pname])))
	var c := EngPorts.Component.new(id, kind, ports, material, cost)
	for k in (spec.get("properties", {}) as Dictionary).keys():
		c.properties[k] = spec["properties"][k]
	for k in (spec.get("requires", []) as Array):
		c.requires.append(String(k))
	EngPorts.register_component(c)
	_record("component", id)
	return true


## Turn "electrical:in" into a real port. Accepts a bare kind too, defaulting
## to bidirectional, which is the right default for a passive part.
static func parse_port(name: String, spec: String) -> EngPorts.Port:
	var parts := spec.split(":")
	var kind := _kind_of(parts[0])
	var flow := EngPorts.Flow.BIDIRECTIONAL
	if parts.size() > 1:
		flow = _flow_of(parts[1])
	return EngPorts.Port.new(name, kind, flow)


static func _kind_of(name: String) -> int:
	match name.strip_edges().to_lower():
		"mechanical", "mech": return EngPorts.Kind.MECHANICAL
		"electrical", "elec", "power": return EngPorts.Kind.ELECTRICAL
		"fluid": return EngPorts.Kind.FLUID
		"data": return EngPorts.Kind.DATA
		"thermal", "heat": return EngPorts.Kind.THERMAL
		"structural", "mount": return EngPorts.Kind.STRUCTURAL
		_: return EngPorts.Kind.STRUCTURAL


static func _flow_of(name: String) -> int:
	match name.strip_edges().to_lower():
		"in", "input": return EngPorts.Flow.INPUT
		"out", "output": return EngPorts.Flow.OUTPUT
		_: return EngPorts.Flow.BIDIRECTIONAL

# --- processes and tools ----------------------------------------------------

## Register a manufacturing operation. Missing fields get the same defaults
## the stock table uses, so a one-line process is a legal process.
static func register_process(spec: Dictionary) -> bool:
	var def := spec.duplicate(true)
	if not def.has("id"):
		push_error("[modding] a process needs an id")
		return false
	if not def.has("required_difficulty"):
		def["required_difficulty"] = 0.2
	if not def.has("energy"):
		def["energy"] = 2.0
	if not def.has("duration"):
		def["duration"] = 1.0
	if not def.has("waste"):
		def["waste"] = 0.05
	if not def.has("quality_delta"):
		def["quality_delta"] = 0.0
	EngProcesses.register_process(def)
	_record("process", String(def["id"]))
	return true


## Register a tool. `process` names the operation it performs and
## `difficulty` is its tier, compared against a material's
## manufacturing_difficulty.
static func register_tool(id: String, process: String, difficulty: float,
		mode := "point", display_name := "") -> bool:
	if id == "" or process == "":
		push_error("[modding] a tool needs an id and a process")
		return false
	EngTools.register_tool(EngTools.Tool.new(id, process, difficulty, mode,
		display_name))
	_record("tool", id)
	return true

# --- machines ---------------------------------------------------------------

## Give a component a role, which is what makes it do something. Without this
## a mod-registered component is inert: it can be placed, saved and wired, but
## it will not appear in any network's totals.
static func register_machine_behavior(component_id: String, role: String,
		params := {}) -> bool:
	if not EngPorts.has(component_id):
		push_warning("[modding] '%s' is not a registered component"
			% component_id)
		return false
	EngMachines.register_behavior(component_id, role, params)
	_record("machine_behavior", component_id)
	return true

# --- assemblies -------------------------------------------------------------

## Register a recognition pattern. The same dictionary keys the stock
## definitions use, so a mod can copy one and change it.
static func register_assembly(spec: Dictionary) -> bool:
	if not spec.has("id"):
		push_error("[modding] an assembly needs an id")
		return false
	EngAssemblies.register_assembly(spec)
	_record("assembly", String(spec["id"]))
	return true

# --- control ----------------------------------------------------------------

## A sensor is a component that publishes onto a data network. It reuses the
## stock `sensor` component with a different `reads` property, so a mod adds a
## new measurement without a new simulation pass.
static func register_sensor(id: String, reads: String,
		spec: Dictionary = {}) -> bool:
	_sensors[id] = reads
	var full := spec.duplicate(true)
	full["category"] = String(full.get("category", "control"))
	if not full.has("ports"):
		full["ports"] = {"power": "electrical:in", "data": "data:out"}
	register_component(id, full)
	EngMachines.register_behavior(id, EngMachines.ROLE_NONE, {})
	_record("sensor", id)
	return true


## A controller is a component that reads a data network and drives
## actuators. `program` is recorded and read by the machine layer, so a new
## program is a data change rather than a code change.
static func register_controller(id: String, program: String,
		spec: Dictionary = {}) -> bool:
	_controllers[id] = program
	var full := spec.duplicate(true)
	full["category"] = String(full.get("category", "control"))
	if not full.has("ports"):
		full["ports"] = {"power": "electrical:in", "input": "data:in",
			"output": "data:out"}
	if not full.has("properties"):
		full["properties"] = {}
	(full["properties"] as Dictionary)["program"] = program
	register_component(id, full)
	EngMachines.register_behavior(id, EngMachines.CONTROLLER, {})
	_record("controller", id)
	return true


static func sensor_reads(id: String) -> String:
	return String(_sensors.get(id, ""))


static func controller_program(id: String) -> String:
	return String(_controllers.get(id, ""))

# --- blueprints -------------------------------------------------------------

## Register a pre-authored assembly the player can place immediately. The
## blueprint is captured through the same path a player-built one uses, so
## there is no privileged format.
static func register_blueprint(name: String, nodes: Array, edges: Array) -> String:
	var bp := {
		"version": EngBlueprints.VERSION,
		"name": name,
		"author": "mod",
		"nodes": nodes,
		"edges": edges,
	}
	var id := EngBlueprints.save(bp)
	_record("blueprint", name)
	return id

# --- introspection ----------------------------------------------------------

static func registrations() -> Array[Dictionary]:
	return _log.duplicate()


## A one-screen description of what a mod has added, for a console command
## and for the engineering UI's "about this world" line.
static func describe() -> String:
	var by_kind := {}
	for entry in _log:
		var k := String(entry["kind"])
		by_kind[k] = int(by_kind.get(k, 0)) + 1
	if by_kind.is_empty():
		return "no mods registered anything"
	var parts := PackedStringArray()
	for k in by_kind.keys():
		parts.append("%s x%d" % [String(k), int(by_kind[k])])
	return ", ".join(parts)


static func _record(kind: String, id: String) -> void:
	_built = true
	_log.append({"kind": kind, "id": id})
