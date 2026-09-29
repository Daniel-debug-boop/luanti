class_name EngPorts
extends RefCounted
## Layer 2 of the engineering system: typed ports, and the component library
## that exposes them.
##
## A port is a typed connection point. Type is the whole point: a mechanical
## rotation_output cannot be wired to an electrical power_input, and the
## connection system rejects it unless an explicit adapter exists. This is what
## lets one motor drive a pump, a fan or a conveyor without any of them
## knowing about each other.
##
## Flow direction is separate from type: a port is an input, an output, or
## bidirectional. Connections are therefore symmetric to reason about while
## still having real one-way semantics.

enum Kind { MECHANICAL, ELECTRICAL, FLUID, DATA, THERMAL, STRUCTURAL }
enum Flow { INPUT, OUTPUT, BIDIRECTIONAL }

const KIND_NAMES := {
	Kind.MECHANICAL: "mechanical",
	Kind.ELECTRICAL: "electrical",
	Kind.FLUID: "fluid",
	Kind.DATA: "data",
	Kind.THERMAL: "thermal",
	Kind.STRUCTURAL: "structural",
}


static func kind_name(kind: int) -> String:
	return String(KIND_NAMES.get(kind, "unknown"))


## One port on a component. Immutable once the component is registered.
class Port:
	var name: String
	var kind: int
	var flow: int
	## Optional: restricts which material family may flow (e.g. a fluid port
	## that only carries water). Empty means anything of the right kind.
	var carries := ""
	## Max throughput in the simulation's abstract units. 0 = unlimited.
	var capacity := 0.0
	## For mechanical ports: the shaft speed this port is rated for.
	var max_rpm := 0.0

	func _init(p_name: String, p_kind: int, p_flow: int, p_carries := "",
			p_capacity := 0.0, p_max_rpm := 0.0) -> void:
		name = p_name
		kind = p_kind
		flow = p_flow
		carries = p_carries
		capacity = p_capacity
		max_rpm = p_max_rpm

	func can_receive() -> bool:
		return flow == EngPorts.Flow.INPUT or flow == EngPorts.Flow.BIDIRECTIONAL

	func can_emit() -> bool:
		return flow == EngPorts.Flow.OUTPUT or flow == EngPorts.Flow.BIDIRECTIONAL

	## True when this port and `other` may be joined directly.
	func compatible_with(other: Port) -> bool:
		if kind != other.kind:
			return false
		if other.flow == EngPorts.Flow.OUTPUT and not can_receive():
			return false
		if other.flow == EngPorts.Flow.INPUT and not can_emit():
			return false
		if carries != "" and other.carries != "" and carries != other.carries:
			return false
		# Deliberately NOT rejecting on differing speed ratings. A gearbox
		# rated 2000 rpm driving a shaft rated 3000 rpm is a perfectly normal
		# connection that simply runs at the lower limit; refusing it would
		# make a gearbox impossible to use with anything better than itself.
		# The limit is applied to the whole network instead, by
		# EngSimulation, which is the only place that knows the other end.
		return true

	func describe() -> String:
		var flow_name := "in"
		if flow == EngPorts.Flow.OUTPUT:
			flow_name = "out"
		elif flow == EngPorts.Flow.BIDIRECTIONAL:
			flow_name = "inout"
		return "%s:%s(%s)" % [EngPorts.kind_name(kind), name, flow_name]

	func to_dict() -> Dictionary:
		return {
			"name": name, "kind": kind, "flow": flow, "carries": carries,
			"capacity": capacity, "max_rpm": max_rpm,
		}


## One reusable engineering component definition.
class Component:
	var id: String
	var category: String
	## Material the component is made of.
	var material := "steel"
	## How much material one unit costs, in cubic-block equivalents.
	var material_cost := 0.01
	var ports: Array = []            # Array[Port]
	## Component ids that must be present in the same assembly.
	var requires: Array[String] = []
	## Free-form data for the simulation and the mod API.
	var properties := {}

	func _init(p_id: String, p_category: String, p_ports: Array = [],
			p_material := "steel", p_cost := 0.01) -> void:
		id = p_id
		category = p_category
		ports = p_ports
		material = p_material
		material_cost = p_cost

	func port(p_name: String) -> Port:
		for p in ports:
			if (p as Port).name == p_name:
				return p
		return null

	func port_names() -> Array[String]:
		var out: Array[String] = []
		for p in ports:
			out.append((p as Port).name)
		return out

	func ports_of_kind(kind: int) -> Array:
		var out: Array = []
		for p in ports:
			if (p as Port).kind == kind:
				out.append(p)
		return out

	func to_dict() -> Dictionary:
		var ps: Array = []
		for p in ports:
			ps.append((p as Port).to_dict())
		return {
			"id": id, "category": category, "material": material,
			"material_cost": material_cost, "ports": ps,
			"requires": Array(requires), "properties": properties.duplicate(),
		}


static var _components := {}
static var _order: Array[String] = []
## Re-entrancy guard: the stock library is registered through
## register_component, so building must not re-enter itself.
static var _building := false

# --- shorthand port constructors, so a component table stays readable -------

static func mech_in(n: String, rpm := 0.0) -> Port:
	return Port.new(n, Kind.MECHANICAL, Flow.INPUT, "", 0.0, rpm)


static func mech_out(n: String, rpm := 0.0) -> Port:
	return Port.new(n, Kind.MECHANICAL, Flow.OUTPUT, "", 0.0, rpm)


static func elec_in(n: String, cap := 0.0) -> Port:
	return Port.new(n, Kind.ELECTRICAL, Flow.INPUT, "", cap)


static func elec_out(n: String, cap := 0.0) -> Port:
	return Port.new(n, Kind.ELECTRICAL, Flow.OUTPUT, "", cap)


## A wire carries power in both directions along a network: it has no inherent
## source or sink role, so it is bidirectional. This is what lets
## source -> wire -> switch -> load chains build without special cases.
static func elec_io(n: String, cap := 0.0) -> Port:
	return Port.new(n, Kind.ELECTRICAL, Flow.BIDIRECTIONAL, "", cap)


## Same reasoning for pipe segments and hoses.
static func fluid_io(n: String, carries := "", cap := 0.0) -> Port:
	return Port.new(n, Kind.FLUID, Flow.BIDIRECTIONAL, carries, cap)


static func fluid_in(n: String, carries := "", cap := 0.0) -> Port:
	return Port.new(n, Kind.FLUID, Flow.INPUT, carries, cap)


static func fluid_out(n: String, carries := "", cap := 0.0) -> Port:
	return Port.new(n, Kind.FLUID, Flow.OUTPUT, carries, cap)


static func thermal_out(n: String) -> Port:
	return Port.new(n, Kind.THERMAL, Flow.OUTPUT)


static func data_out(n: String) -> Port:
	return Port.new(n, Kind.DATA, Flow.OUTPUT)


static func data_in(n: String) -> Port:
	return Port.new(n, Kind.DATA, Flow.INPUT)


static func structural(n: String) -> Port:
	return Port.new(n, Kind.STRUCTURAL, Flow.BIDIRECTIONAL)


## Register (or replace) a component definition.
static func register_component(c: Component) -> void:
	_ensure()
	if c.id == "":
		push_error("[ports] a component needs an id")
		return
	if not _components.has(c.id):
		_order.append(c.id)
	_components[c.id] = c


static func has(id: String) -> bool:
	_ensure()
	return _components.has(id)


static func get_def(id: String) -> Component:
	_ensure()
	return _components.get(id, null)


static func all_ids() -> Array[String]:
	_ensure()
	return _order.duplicate()


## Can `a` and `b` be wired port-to-port? Returns "" on success, or a human
## readable reason the connection is refused.
static func check_connection(id_a: String, port_a: String,
		id_b: String, port_b: String) -> String:
	var ca := get_def(id_a)
	var cb := get_def(id_b)
	if ca == null:
		return "unknown component '%s'" % id_a
	if cb == null:
		return "unknown component '%s'" % id_b
	var pa := ca.port(port_a)
	var pb := cb.port(port_b)
	if pa == null:
		return "'%s' has no port '%s'" % [id_a, port_a]
	if pb == null:
		return "'%s' has no port '%s'" % [id_b, port_b]
	if not pa.compatible_with(pb):
		return "%s cannot mate with %s" % [pa.describe(), pb.describe()]
	return ""


# --- the stock library ------------------------------------------------------

static func _build_library() -> void:
	if _building or not _components.is_empty():
		return
	_building = true

	# --- structural ---
	register_component(Component.new("beam", "structural",
		[structural("mount")], "wood", 0.02))
	register_component(Component.new("plate", "structural",
		[structural("mount"), structural("face")], "steel", 0.01))
	register_component(Component.new("bracket", "structural",
		[structural("mount_a"), structural("mount_b")], "steel", 0.005))
	register_component(Component.new("frame", "structural",
		[structural("mount")], "steel", 0.04))
	register_component(Component.new("housing", "structural",
		[structural("mount"), mech_out("shaft_bore", 2000.0)], "iron", 0.06))

	# --- fastening ---
	register_component(Component.new("bolt", "fastening",
		[structural("a"), structural("b")], "steel", 0.002))
	register_component(Component.new("nut", "fastening",
		[structural("a")], "steel", 0.002))
	register_component(Component.new("screw", "fastening",
		[structural("a")], "iron", 0.001))
	register_component(Component.new("clamp", "fastening",
		[structural("a"), structural("b")], "iron", 0.004))

	# --- mechanical transmission ---
	register_component(Component.new("shaft", "mechanical",
		[mech_in("in", 3000.0), mech_out("out", 3000.0)], "steel", 0.008))
	register_component(Component.new("axle", "mechanical",
		[mech_in("in", 2000.0), mech_out("out", 2000.0)], "iron", 0.01))
	register_component(Component.new("bearing", "mechanical",
		[mech_out("bore", 4000.0)], "steel", 0.004))
	register_component(Component.new("coupling", "mechanical",
		[mech_in("in", 2500.0), mech_out("out", 2500.0)], "steel", 0.005))
	register_component(Component.new("gear", "mechanical",
		[mech_in("in", 2000.0), mech_out("out", 2000.0)], "steel", 0.006))
	var gb := Component.new("gearbox", "mechanical",
		[mech_in("in", 2000.0), mech_out("out", 2000.0)], "iron", 0.05)
	gb.properties["ratio"] = 3.0
	gb.properties["efficiency"] = 0.9
	register_component(gb)
	register_component(Component.new("pulley", "mechanical",
		[mech_in("in", 2000.0), mech_out("out", 2000.0)], "wood", 0.006))
	register_component(Component.new("flywheel", "mechanical",
		[mech_in("in", 1500.0)], "iron", 0.03))
	register_component(Component.new("lead_screw", "mechanical",
		[mech_in("in", 500.0), mech_out("out", 500.0)], "steel", 0.02))
	# A chain drive is the one-to-many mechanical part: it is how a single
	# shaft reaches more than one attachment without a special case in the
	# simulation. Ratio 1 by default, so it only exists to fan out.
	var chain := Component.new("chain_drive", "mechanical",
		[mech_in("in", 2000.0), mech_out("a", 2000.0), mech_out("b", 2000.0)],
		"steel", 0.012)
	chain.properties["ratio"] = 1.0
	register_component(chain)
	register_component(Component.new("brake", "mechanical",
		[mech_in("in", 1500.0), elec_in("actuate", 1.0)], "iron", 0.01))

	# --- electrical ---
	register_component(Component.new("wire", "electrical",
		[elec_io("a", 100.0), elec_io("b", 100.0)], "copper", 0.004))
	register_component(Component.new("cable", "electrical",
		[elec_io("a", 200.0), elec_io("b", 200.0)], "copper", 0.01))
	register_component(Component.new("terminal", "electrical",
		[elec_io("a", 100.0), structural("mount")], "copper", 0.003))
	register_component(Component.new("switch", "electrical",
		[elec_io("a", 100.0), elec_io("b", 100.0)], "copper", 0.006))
	register_component(Component.new("relay", "electrical",
		[elec_in("coil", 5.0), elec_io("a", 100.0), elec_io("b", 100.0)],
		"copper", 0.01))
	register_component(Component.new("fuse", "electrical",
		[elec_io("a", 100.0), elec_io("b", 100.0)], "glass", 0.002))
	register_component(Component.new("battery", "electrical",
		[elec_out("positive", 100.0), elec_io("negative", 100.0)], "carbon", 0.05))
	register_component(Component.new("transformer", "electrical",
		[elec_in("primary", 100.0), elec_out("secondary", 50.0)], "copper", 0.08))
	var sensor := Component.new("sensor", "control",
		[elec_in("power", 5.0), data_out("data")], "silicon", 0.004)
	sensor.properties["reads"] = "temperature"
	register_component(sensor)
	var controller := Component.new("controller", "control",
		[elec_in("power", 20.0), data_in("input"), data_out("output")],
		"silicon", 0.01)
	controller.properties["program"] = "pump_on"
	register_component(controller)

	# --- rotary machines (the reusable core) ---
	# Every machine exposes a structural mount port as well as its working
	# ports, so it can be bolted into a housing or a frame. That is what
	# lets smart fastening hold a motor in place without the fastening code
	# needing to know what a motor is.
	var motor := Component.new("motor", "machine",
		[elec_in("power", 200.0), mech_out("rotation", 3000.0),
		thermal_out("heat"), structural("mount")], "copper", 0.06)
	motor.properties["max_rpm"] = 3000.0
	motor.properties["max_torque"] = 12.0
	motor.properties["efficiency"] = 0.85
	register_component(motor)

	var generator := Component.new("generator", "machine",
		[mech_in("rotation", 2000.0), elec_out("power", 150.0),
		thermal_out("heat"), structural("mount")], "copper", 0.06)
	generator.properties["max_rpm"] = 2000.0
	generator.properties["efficiency"] = 0.8
	register_component(generator)

	var hand_crank := Component.new("hand_crank", "machine",
		[mech_out("rotation", 300.0), structural("mount")], "wood", 0.01)
	hand_crank.properties["max_rpm"] = 300.0
	hand_crank.properties["max_torque"] = 20.0
	register_component(hand_crank)

	# --- fluid ---
	register_component(Component.new("pipe", "fluid",
		[fluid_io("a", "", 10.0), fluid_io("b", "", 10.0)], "iron", 0.01))
	register_component(Component.new("hose", "fluid",
		[fluid_io("a", "", 6.0), fluid_io("b", "", 6.0)], "rubber", 0.006))
	register_component(Component.new("tank", "fluid",
		[fluid_in("fill", "", 100.0), fluid_out("drain", "", 100.0)],
		"iron", 0.05))
	register_component(Component.new("valve", "fluid",
		[fluid_io("a", "", 10.0), fluid_io("b", "", 10.0),
		elec_in("actuate", 2.0)], "iron", 0.01))
	var pump := Component.new("pump", "machine",
		[mech_in("rotation", 2000.0), fluid_in("inlet", "", 10.0),
		fluid_out("outlet", "", 10.0), thermal_out("heat"),
		structural("mount")], "iron", 0.08)
	pump.properties["max_rpm"] = 2000.0
	pump.properties["efficiency"] = 0.7
	register_component(pump)

	# --- rotating attachments: one motor drives any of these ---
	register_component(Component.new("impeller", "mechanical",
		[mech_in("bore", 2000.0), structural("mount")], "copper", 0.01))
	register_component(Component.new("fan", "mechanical",
		[mech_in("bore", 2000.0)], "steel", 0.01))
	register_component(Component.new("grinder_wheel", "mechanical",
		[mech_in("bore", 2000.0)], "carbon", 0.008))
	register_component(Component.new("conveyor_belt", "mechanical",
		[mech_in("drive", 500.0), mech_out("out", 500.0)], "rubber", 0.02))
	register_component(Component.new("drill_bit", "mechanical",
		[mech_in("chuck", 1500.0)], "carbon", 0.006))
	register_component(Component.new("winch_drum", "mechanical",
		[mech_in("drive", 600.0), mech_out("out", 600.0)], "steel", 0.02))

	# --- workshop stations ---
	register_component(Component.new("workbench", "workstation", [], "wood", 0.5))
	register_component(Component.new("furnace", "workstation", [], "stone", 0.8))
	register_component(Component.new("forge", "workstation", [], "stone", 1.0))
	register_component(Component.new("drill_press", "workstation",
		[mech_in("drive", 1200.0)], "steel", 1.0))
	register_component(Component.new("lathe", "workstation",
		[mech_in("drive", 900.0)], "steel", 1.0))
	register_component(Component.new("press", "workstation", [], "iron", 1.2))
	register_component(Component.new("electrical_bench", "workstation", [], "wood", 0.8))
	register_component(Component.new("machine_shop", "workstation", [], "steel", 2.0))
	register_component(Component.new("electronics_lab", "workstation", [],
		"silicon", 2.5))

	_building = false


## Force the library to build. Called by every public entry point, so a mod
## can register a component before anything has read the stock table.
static func _ensure() -> void:
	_build_library()


## Serializable snapshot of the whole component library.
static func serialize() -> Dictionary:
	_ensure()
	var out := {}
	for id in _components.keys():
		out[id] = (_components[id] as Component).to_dict()
	return {"version": 1, "components": out}
