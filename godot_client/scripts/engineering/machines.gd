class_name EngMachines
extends RefCounted
## Machine System: what a component *does* on a network.
##
## A port says how a component may be wired. A role says what it does once it
## is wired. Keeping those separate is what stops the component library from
## turning into nine unrelated machine implementations: the motor, the pump
## and the conveyor are three different roles, and a role is a dozen lines of
## arithmetic over the network's totals rather than a bespoke simulation.
##
## Roles are data. A mod registers a component and then gives it a role:
##
##     EngPorts.register_component(EngPorts.Component.new("water_wheel", "machine",
##         [EngPorts.mech_out("rotation", 400.0)], "wood", 0.3))
##     EngMachines.register_behavior("water_wheel", EngMachines.ROTARY_SOURCE,
##         {"max_rpm": 30.0, "max_torque": 200.0})
##
## and it is immediately usable by everything that speaks the role vocabulary.

## The role vocabulary. A component has exactly one role, and the simulation
## layer switches on these -- never on a component id.
const ROLE_NONE := "none"
const POWER_SOURCE := "power_source"      # battery: stores and supplies watts
const POWER_SINK := "power_sink"          # lamp, valve actuator: draws watts
const ROTARY_SOURCE := "rotary_source"    # hand crank, water wheel
const ROTARY_DRIVE := "rotary_drive"      # motor: watts in, torque out
const ELECTRIC_GENERATOR := "electric_generator"  # generator: torque in, watts out
const ROTARY_LOAD := "rotary_load"        # impeller, fan, grinder, conveyor
const FLUID_SOURCE := "fluid_source"      # tank, reservoir
const FLUID_PUMP := "fluid_pump"          # pump: torque in, flow out
const FLUID_SINK := "fluid_sink"          # a tap or a machine that consumes
const THERMAL_SOURCE := "thermal_source"  # furnace, forge
const WORKSTATION := "workstation"        # the workshop progression
const CONTROLLER := "controller"          # reads data, drives actuators

## Nominal bus voltage. Everything electrical is expressed in watts against
## this, which keeps the arithmetic in one place and makes brownout a single
## comparison rather than a model.
const NOMINAL_VOLTAGE := 12.0
## How much of a stalled machine's rated draw is still drawn. Without this a
## single shorted motor would drag the whole bus to zero.
const STALL_FACTOR := 0.15

static var _roles := {}       # component id -> role
static var _params := {}      # component id -> Dictionary
static var _order: Array[String] = []
static var _built := false


## Give a component a role. Re-registering replaces the role, which is how a
## mod overrides stock behaviour without editing the component library.
static func register_behavior(component_id: String, role: String,
		params := {}) -> void:
	_build()
	if not EngPorts.has(component_id):
		push_warning("[machines] '%s' is not a registered component" % component_id)
		return
	if not _roles.has(component_id):
		_order.append(component_id)
	_roles[component_id] = role
	_params[component_id] = params.duplicate(true)


static func role_of(component_id: String) -> String:
	_build()
	return String(_roles.get(component_id, ROLE_NONE))


## The tuning numbers for a role: max_rpm, max_torque, draw, supply, capacity.
## Merged over the component's own properties, so a component table can override
## any default without touching this file.
static func params_of(component_id: String) -> Dictionary:
	_build()
	var def := EngPorts.get_def(component_id)
	var out := _defaults_for(role_of(component_id), component_id)
	if def != null:
		for k in def.properties.keys():
			out[k] = def.properties[k]
	var extra: Dictionary = _params.get(component_id, {})
	for k in extra.keys():
		out[k] = extra[k]
	return out


static func num(component_id: String, key: String, fallback := 0.0) -> float:
	return float(params_of(component_id).get(key, fallback))


## Every component that carries a given role, for the UI and for validation.
static func components_with_role(role: String) -> Array[String]:
	_build()
	var out: Array[String] = []
	for id in _order:
		if String(_roles[id]) == role:
			out.append(id)
	return out


static func has_role(component_id: String) -> bool:
	return role_of(component_id) != ROLE_NONE


## Components that physically break a circuit when they are switched off.
##
## This is the mechanism behind "battery -> switch -> motor": a disabled
## switch must actually disconnect the two halves of the bus, otherwise the
## switch is a decoration and the player is right to distrust it. The graph
## consults this when it partitions, so an open switch splits the network
## exactly as cutting the wire would.
const CIRCUIT_BREAKERS := ["switch", "fuse", "relay", "brake", "valve"]


static func breaks_circuit(component_id: String) -> bool:
	_build()
	return CIRCUIT_BREAKERS.has(component_id)

# --- per-node behaviour ----------------------------------------------------

## Advance one node by dt given the state of the networks it belongs to.
##
## `ctx` carries the electrical and mechanical network states the node is on
## (any of them may be an empty Dictionary, meaning "not on such a network").
## The function only ever writes to `node.state`, so it is safe to run at any
## simulation LOD and the same call is made whether the node is fully
## simulated or abstracted.
static func step_node(node: EngGraph.EngNode, ctx: Dictionary, dt: float) -> void:
	if node == null:
		return
	var role := role_of(node.component_id)
	var p := params_of(node.component_id)
	var elec: Dictionary = ctx.get("electrical", {})
	var mech: Dictionary = ctx.get("mechanical", {})
	var fluid: Dictionary = ctx.get("fluid", {})

	match role:
		POWER_SOURCE:
			# A battery drains by what the bus actually drew, and only
			# discharges while something is asking for power. This is the
			# thing that makes a dead battery a real consequence rather
			# than a decoration.
			var drawn := float(elec.get("demand", 0.0))
			var stored := float(node.state.get("stored", p.get("capacity", 1000.0)))
			var rate := float(p.get("discharge_rate", 40.0)) * dt
			if node.enabled and drawn > 0.0:
				stored = maxf(0.0, stored - rate)
			elif node.state.get("recharging", false):
				stored = minf(float(p.get("capacity", 1000.0)),
					stored + rate * 0.5)
			node.state["stored"] = stored
			node.state["voltage"] = stored / maxf(float(p.get("capacity", 1000.0)),
				1.0) * NOMINAL_VOLTAGE

		POWER_SINK:
			var powered := node.enabled and float(elec.get("voltage", 0.0)) > 0.0
			node.state["active"] = powered
			node.state["draw"] = float(p.get("draw", 10.0)) if powered else 0.0

		ROTARY_SOURCE:
			# A hand crank only turns while the player is turning it.
			var driving := node.enabled and float(node.state.get("effort", 0.0)) > 0.0
			node.state["rpm"] = float(p.get("max_rpm", 100.0)) if driving else 0.0
			node.state["torque"] = float(p.get("max_torque", 20.0)) if driving else 0.0

		ROTARY_DRIVE:
			# The motor is the keystone: it converts electrical power into
			# shaft speed, and it does so from the bus voltage alone. Nothing
			# downstream knows or cares what is spinning it.
			var volts := float(elec.get("voltage", 0.0))
			var frac := clampf(volts / NOMINAL_VOLTAGE, 0.0, 1.0)
			if not node.enabled:
				frac = 0.0
			var max_rpm := float(p.get("max_rpm", 1000.0))
			# Torque falls off as speed rises, so a loaded shaft bogs the
			# motor down instead of it delivering full torque at any speed.
			var load := clampf(float(mech.get("load_fraction", 0.0)), 0.0, 1.0)
			var rpm := max_rpm * frac * (1.0 - 0.35 * load)
			node.state["rpm"] = rpm
			node.state["torque"] = float(p.get("max_torque", 10.0)) * frac * \
				(1.0 - load)
			node.state["draw"] = _motor_draw(p, rpm, float(p.get("max_torque", 10.0)))
			node.state["heat"] = float(node.state.get("draw", 0.0)) * \
				(1.0 - float(p.get("efficiency", 0.8))) * dt

		ELECTRIC_GENERATOR:
			var in_rpm := float(mech.get("rpm", 0.0))
			var max_rpm := float(p.get("max_rpm", 1000.0))
			var frac := clampf(in_rpm / maxf(max_rpm, 1.0), 0.0, 1.0) * \
				(1.0 if node.enabled else 0.0)
			node.state["supply"] = float(p.get("max_output", 100.0)) * frac * \
				float(p.get("efficiency", 0.8))
			node.state["heat"] = float(node.state.get("supply", 0.0)) * 0.2 * dt

		ROTARY_LOAD:
			# A load does not care what drives it. It reports how much torque
			# it resists at the speed it sees, and the mechanical network
			# decides whether that is affordable.
			node.state["rpm"] = float(mech.get("rpm", 0.0))
			node.state["demand"] = float(p.get("max_torque", 5.0)) * \
				clampf(node.state["rpm"] / maxf(float(p.get("rated_rpm", 1000.0)), 1.0),
					0.0, 1.0) if node.enabled else 0.0

		FLUID_SOURCE:
			var stored := float(node.state.get("stored", 0.0))
			var taken := float(fluid.get("drawn", 0.0)) * dt
			if node.enabled:
				stored = maxf(0.0, stored - taken)
			node.state["stored"] = stored

		FLUID_PUMP:
			# A pump is a rotary load that happens to make pressure. What
			# makes it a pump is not this code: it is that a motor, a shaft,
			# an impeller and a housing are wired together, which the
			# assembly layer recognises. This role only says what the
			# resulting thing does.
			var in_rpm := float(mech.get("rpm", 0.0))
			var max_rpm := maxf(float(p.get("max_rpm", 1000.0)), 1.0)
			var frac := clampf(in_rpm / max_rpm, 0.0, 1.0) * \
				(1.0 if node.enabled else 0.0)
			node.state["rpm"] = in_rpm
			node.state["flow"] = float(p.get("max_flow", 8.0)) * frac
			node.state["pressure"] = float(p.get("max_pressure", 100.0)) * frac
			node.state["demand"] = float(p.get("drag_torque", 4.0)) * frac
			node.state["heat"] = float(p.get("drag_torque", 4.0)) * frac * dt * 2.0

		FLUID_SINK:
			node.state["draw"] = float(p.get("draw", 1.0)) if node.enabled else 0.0

		THERMAL_SOURCE:
			# A furnace is a heat source whose output is the workhorse
			# operation: heating a part so a forge becomes legal.
			node.state["output"] = float(p.get("heat_output", 900.0)) if \
				node.enabled else 0.0

		WORKSTATION:
			node.state["active"] = node.enabled

		CONTROLLER:
			# A controller is the automation hook. Its program is looked up
			# in the data network's signal rather than being an if-chain
			# here, so a mod can add a program without touching this file.
			var sig := float(ctx.get("data", {}).get("signal", 0.0))
			node.state["signal"] = sig
			node.state["active"] = node.enabled

		_:
			pass


## Electrical draw of a motor spinning at `rpm`. Torque times angular speed is
## mechanical power; the electrical side pays for it plus the losses.
static func _motor_draw(p: Dictionary, rpm: float, max_torque: float) -> float:
	if rpm <= 0.0:
		return STALL_FACTOR * _max_rpm_power(p)
	var omega := rpm * TAU / 60.0
	var torque := max_torque * (rpm / maxf(float(p.get("max_rpm", 1000.0)), 1.0))
	var mech_w := torque * omega
	return mech_w / maxf(float(p.get("efficiency", 0.8)), 0.05)


static func _max_rpm_power(p: Dictionary) -> float:
	var omega := float(p.get("max_rpm", 1000.0)) * TAU / 60.0
	return float(p.get("max_torque", 10.0)) * omega / maxf(
		float(p.get("efficiency", 0.8)), 0.05)

# --- defaults --------------------------------------------------------------

## Sensible numbers for a role, so a component only has to override what is
## actually different about it. A mod that registers a brand new component
## therefore gets working behaviour for free.
static func _defaults_for(role: String, component_id: String) -> Dictionary:
	match role:
		POWER_SOURCE:
			return {"capacity": 1000.0, "discharge_rate": 40.0}
		POWER_SINK:
			return {"draw": 10.0}
		ROTARY_SOURCE:
			return {"max_rpm": 60.0, "max_torque": 30.0}
		ROTARY_DRIVE:
			return {"max_rpm": 1200.0, "max_torque": 10.0, "efficiency": 0.85}
		ELECTRIC_GENERATOR:
			return {"max_rpm": 1200.0, "max_output": 100.0, "efficiency": 0.8}
		ROTARY_LOAD:
			return {"rated_rpm": 1000.0, "max_torque": 5.0}
		FLUID_SOURCE:
			return {"capacity": 200.0}
		FLUID_PUMP:
			return {"max_rpm": 1200.0, "max_flow": 8.0, "max_pressure": 100.0,
				"drag_torque": 4.0}
		FLUID_SINK:
			return {"draw": 1.0}
		THERMAL_SOURCE:
			return {"heat_output": 900.0, "max_temperature": 1400.0}
		CONTROLLER:
			return {}
		_:
			return {}


## Default roles for the stock component library. This is the single place
## where "battery stores power" is stated, and it is stated as data.
static func _build() -> void:
	if _built:
		return
	_built = true
	var table := {
		"battery": [POWER_SOURCE, {}],
		"generator": [ELECTRIC_GENERATOR, {}],
		"motor": [ROTARY_DRIVE, {}],
		"hand_crank": [ROTARY_SOURCE, {}],

		"impeller": [ROTARY_LOAD, {"rated_rpm": 1500.0, "max_torque": 3.0}],
		"fan": [ROTARY_LOAD, {"rated_rpm": 1500.0, "max_torque": 1.5}],
		"grinder_wheel": [ROTARY_LOAD, {"rated_rpm": 2500.0, "max_torque": 6.0}],
		"conveyor_belt": [ROTARY_LOAD, {"rated_rpm": 120.0, "max_torque": 8.0}],
		"drill_bit": [ROTARY_LOAD, {"rated_rpm": 1200.0, "max_torque": 9.0}],
		"winch_drum": [ROTARY_LOAD, {"rated_rpm": 300.0, "max_torque": 12.0}],
		"shaft": [ROLE_NONE, {}],
		"gear": [ROLE_NONE, {}],
		"gearbox": [ROLE_NONE, {}],
		"coupling": [ROLE_NONE, {}],
		"bearing": [ROLE_NONE, {}],
		"bearing_mount": [ROLE_NONE, {}],
		"belt": [ROLE_NONE, {}],
		"piston": [ROLE_NONE, {}],

		"tank": [FLUID_SOURCE, {}],
		"pump": [FLUID_PUMP, {}],
		"valve": [POWER_SINK, {"draw": 4.0}],
		"pipe": [ROLE_NONE, {}],
		"hose": [ROLE_NONE, {}],

		"furnace": [THERMAL_SOURCE, {"heat_output": 1200.0}],
		"forge": [THERMAL_SOURCE, {"heat_output": 1000.0}],

		"controller": [CONTROLLER, {}],
		"sensor": [ROLE_NONE, {}],

		"workbench": [WORKSTATION, {}],
		"drill_press": [WORKSTATION, {}],
		"lathe": [WORKSTATION, {}],
		"press": [WORKSTATION, {}],
		"electrical_bench": [WORKSTATION, {}],
		"machine_shop": [WORKSTATION, {}],
		"electronics_lab": [WORKSTATION, {}],
	}
	for id in table.keys():
		var entry: Array = table[id]
		_roles[String(id)] = String(entry[0])
		_params[String(id)] = (entry[1] as Dictionary).duplicate(true)
		if not _order.has(String(id)):
			_order.append(String(id))
