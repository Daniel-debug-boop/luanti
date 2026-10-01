class_name EmergentCaps
extends RefCounted
## Capabilities: what a component can *do*, as opposed to what it *is*.
##
## The engineering layer already has two vocabularies and neither answers this
## question. A port says how a component may be wired; a role says what it
## does on a network. Neither says "this assembly, taken as a whole, can
## rotate" -- that is a property of the connections between components, and
## it is exactly the property a pattern needs to match on.
##
## Without capabilities, recognising a functional object means matching
## component ids, which means a golf club made of different parts does not
## look like a golf club and every new object needs code. With them, a
## pattern states "something that can strike, connected to something rigid
## and elongated" and any construction satisfying that is recognised.
##
## Capabilities are DERIVED, never declared per object. They come from the
## component's own ports and role, so registering a new component in the
## existing engineering library gives it capabilities for free, with no
## second place to keep the two in sync.
##
## The vocabulary is deliberately small. A capability earns its place only if
## some pattern or constraint actually tests for it; an unused one is a lie
## the player can be told.

# --- the vocabulary --------------------------------------------------------
const CAN_RECEIVE_POWER := "can_receive_power"      # electrical in
const CAN_SUPPLY_POWER := "can_supply_power"        # electrical out
const CAN_DRIVE_ROTATION := "can_drive_rotation"    # mechanical out
const CAN_RECEIVE_ROTATION := "can_receive_rotation" # mechanical in
const CAN_MOVE_FLUID := "can_move_fluid"            # fluid out
const CAN_RECEIVE_FLUID := "can_receive_fluid"      # fluid in
const CAN_STORE_FLUID := "can_store_fluid"          # tank
const CAN_STORE_POWER := "can_store_power"          # battery
const CAN_EMIT_HEAT := "can_emit_heat"              # thermal out
const CAN_PRODUCE_SIGNAL := "can_produce_signal"    # data out
const CAN_RECEIVE_SIGNAL := "can_receive_signal"    # data in
const CAN_ACTUATE := "can_actuate"                  # has an actuated port
const CAN_SUPPORT := "can_support"                  # structural
const CAN_CONNECT := "can_connect"                  # has any port
const CAN_TRANSFORM := "can_transform"              # role that changes something
const CAN_WORK := "can_work"                        # a workstation
# --- world-entity capabilities -------------------------------------------
# An assembly is only half the world. A player also builds things that are
# not components: a zone that notices a ball, a counter that adds up, a
# marker anybody can see. Those are entities, and they need capabilities too
# or the pattern vocabulary would only ever describe machines -- and a golf
# course is not a machine.
const CAN_ACCUMULATE := "can_accumulate"            # keeps a running count
const CAN_EMIT_EVENT := "can_emit_event"            # raises gameplay events
const CAN_MOVE := "can_move"                        # travels under physics

const ALL := [
	CAN_RECEIVE_POWER, CAN_SUPPLY_POWER, CAN_DRIVE_ROTATION,
	CAN_RECEIVE_ROTATION, CAN_MOVE_FLUID, CAN_RECEIVE_FLUID,
	CAN_STORE_FLUID, CAN_STORE_POWER, CAN_EMIT_HEAT, CAN_PRODUCE_SIGNAL,
	CAN_RECEIVE_SIGNAL, CAN_ACTUATE, CAN_SUPPORT, CAN_CONNECT,
	CAN_TRANSFORM, CAN_WORK, CAN_ACCUMULATE, CAN_EMIT_EVENT, CAN_MOVE,
]

## Capabilities implied by a port kind and flow. This is the whole mapping
## from the existing port vocabulary to the capability vocabulary; keeping it
## in one table is what stops the two drifting apart.
const BY_PORT := {
	EngPorts.Kind.ELECTRICAL: {
		EngPorts.Flow.INPUT: CAN_RECEIVE_POWER,
		EngPorts.Flow.OUTPUT: CAN_SUPPLY_POWER,
		EngPorts.Flow.BIDIRECTIONAL: CAN_RECEIVE_POWER,
	},
	EngPorts.Kind.MECHANICAL: {
		EngPorts.Flow.INPUT: CAN_RECEIVE_ROTATION,
		EngPorts.Flow.OUTPUT: CAN_DRIVE_ROTATION,
		EngPorts.Flow.BIDIRECTIONAL: CAN_RECEIVE_ROTATION,
	},
	EngPorts.Kind.FLUID: {
		EngPorts.Flow.INPUT: CAN_RECEIVE_FLUID,
		EngPorts.Flow.OUTPUT: CAN_MOVE_FLUID,
		EngPorts.Flow.BIDIRECTIONAL: CAN_RECEIVE_FLUID,
	},
	EngPorts.Kind.DATA: {
		EngPorts.Flow.INPUT: CAN_RECEIVE_SIGNAL,
		EngPorts.Flow.OUTPUT: CAN_PRODUCE_SIGNAL,
		EngPorts.Flow.BIDIRECTIONAL: CAN_RECEIVE_SIGNAL,
	},
	EngPorts.Kind.STRUCTURAL: {
		EngPorts.Flow.INPUT: CAN_SUPPORT,
		EngPorts.Flow.OUTPUT: CAN_SUPPORT,
		EngPorts.Flow.BIDIRECTIONAL: CAN_SUPPORT,
	},
}

## Capabilities implied by a machine role, for the things ports cannot
## express: storage, heat, transformation.
const BY_ROLE := {
	EngMachines.POWER_SOURCE: [CAN_STORE_POWER, CAN_SUPPLY_POWER],
	EngMachines.POWER_SINK: [CAN_RECEIVE_POWER],
	EngMachines.ROTARY_SOURCE: [CAN_DRIVE_ROTATION],
	EngMachines.ROTARY_DRIVE: [CAN_DRIVE_ROTATION],
	EngMachines.ELECTRIC_GENERATOR: [CAN_SUPPLY_POWER],
	EngMachines.ROTARY_LOAD: [CAN_RECEIVE_ROTATION],
	EngMachines.FLUID_SOURCE: [CAN_STORE_FLUID],
	EngMachines.FLUID_PUMP: [CAN_MOVE_FLUID],
	EngMachines.FLUID_SINK: [CAN_RECEIVE_FLUID],
	EngMachines.THERMAL_SOURCE: [CAN_EMIT_HEAT],
	EngMachines.WORKSTATION: [CAN_WORK],
	EngMachines.CONTROLLER: [CAN_RECEIVE_SIGNAL, CAN_PRODUCE_SIGNAL],
}

## Extra capabilities a component or world entity registers for itself.
## Free-form by design: this is how a mod adds a capability the shared
## vocabulary does not name, without changing this file -- and how the
## entity kinds (a zone, a counter) declare theirs, since they have no ports
## and no role to derive from.
static var _extra := {}      # component/entity id -> Array[String]


## Register an additional capability for a component. The escape hatch for
## modded content; the derived set above needs no registration at all.
static func add_capability(component_id: String, cap: String) -> void:
	var list: Array = _extra.get(component_id, [])
	if not list.has(cap):
		list.append(cap)
		_extra[component_id] = list


static func forget_capability(component_id: String, cap: String) -> void:
	var list: Array = _extra.get(component_id, [])
	list.erase(cap)
	_extra[component_id] = list


## Every capability a single component has, derived from its ports, its role
## and anything registered explicitly.
static func of_component(component_id: String) -> Array[String]:
	var out := {}
	var def := EngPorts.get_def(component_id)
	if def != null:
		for p in def.ports:
			var port := p as EngPorts.Port
			if port == null:
				continue
			var by_flow: Dictionary = BY_PORT.get(port.kind, {})
			if by_flow.has(port.flow):
				out[String(by_flow[port.flow])] = true
			if not port.can_receive() or not port.can_emit():
				out[CAN_ACTUATE] = true
			out[CAN_CONNECT] = true
	# Thermal output is a port kind the flow table cannot express as "heat":
	# a motor's heat port is not a heat *input*.
	if def != null:
		for p in def.ports:
			var port2 := p as EngPorts.Port
			if port2 != null and port2.kind == EngPorts.Kind.THERMAL \
					and port2.flow == EngPorts.Flow.OUTPUT:
				out[CAN_EMIT_HEAT] = true
	var role := EngMachines.role_of(component_id)
	if BY_ROLE.has(role):
		for c in BY_ROLE[role]:
			out[String(c)] = true
		if role != EngMachines.ROLE_NONE:
			out[CAN_TRANSFORM] = true
	for c in _extra.get(component_id, []):
		out[String(c)] = true
	# CAN_CONNECT means "has somewhere to attach", which an entity with no
	# ports does not have. Left out on purpose: claiming it would let a
	# pattern wire a zone into a power bus that cannot exist.
	# Dictionary.keys() is an untyped Array; the return type is not, so it has
	# to be converted rather than returned directly. Silently returning an
	# untyped array here fails at runtime, not at parse time, which is why
	# every capability lookup came back empty instead of erroring loudly.
	var result: Array[String] = []
	for k in out.keys():
		result.append(String(k))
	return result


static func has_component(component_id: String, cap: String) -> bool:
	return of_component(component_id).has(cap)


## The capabilities of a whole assembly: the union over its components.
##
## Deliberately a plain union. An assembly is capable of what its parts are
## capable of; whether it can *use* that capability depends on whether the
## parts are actually connected, and that is the graph's question, not this
## one's. Answering it here would make the two layers disagree.
static func of_assembly(component_ids: Array) -> Array[String]:
	var out := {}
	for id in component_ids:
		for c in of_component(String(id)):
			out[String(c)] = true
	var result: Array[String] = []
	for k in out.keys():
		result.append(String(k))
	return result


static func assembly_has(component_ids: Array, cap: String) -> bool:
	return of_assembly(component_ids).has(cap)


## Capabilities every member must have.
static func all_of_assembly(component_ids: Array, caps: Array) -> bool:
	for c in caps:
		if not assembly_has(component_ids, String(c)):
			return false
	return true


## One-line summary, for the diagnostic view.
static func describe(component_id: String) -> String:
	var caps := of_component(component_id)
	if caps.is_empty():
		return "%s: no capabilities" % component_id
	caps.sort()
	return "%s: %s" % [component_id, ", ".join(caps)]