class_name EmergentEntity
extends RefCounted
## Entities: the things a player builds that are NOT components.
##
## The engineering graph already models everything with ports. A golf hole is
## not that. It has no power, no torque, no plumbing -- it has a position, a
## radius, and the ability to notice that something entered it. Building a
## second port-based model for those would be the second competing
## architecture this system is supposed to avoid, so instead an entity is the
## *other* half of the same vocabulary: it declares capabilities, it takes
## part in relationships, it matches patterns, and it holds state. What it
## does not do is pretend to be a machine.
##
## Every kind is DATA. `Kinds` below is a table, not a switch statement, and
## registering a kind registers capabilities through the same
## `EmergentCaps.add_capability` path a mod would use. Adding a new kind
## therefore adds a new way for players to express intent without touching
## the engine -- which is the whole thesis of this system, applied to
## entities rather than to machines.

## The registry. kind id -> definition.
##
## A `static var`, not a `const`, because registering a kind is the documented
## extension point and Godot 4 makes const Dictionaries read-only at runtime.
##
## A definition is:
##   caps       capabilities, registered into EmergentCaps on registration
##   props      default property values (a free-form float/bool dictionary)
##   state      default state values
##   label      what the player is told they placed
##   radius     default sensing radius, 0 for a point
##   behaviour  the behaviour this entity contributes when it matches
##   movable    whether physics integrates this entity's position
static var KINDS := {
	"marker": {
		"caps": [EmergentCaps.CAN_EMIT_EVENT],
		"props": {"radius": 2.0},
		"state": {"triggered": false, "count": 0},
		"label": "marker",
		"radius": 2.0,
		"behaviour": "sense",
		"movable": false,
	},
	"zone": {
		"caps": [EmergentCaps.CAN_EMIT_EVENT],
		"props": {"radius": 3.0},
		"state": {"triggered": false, "count": 0},
		"label": "zone",
		"radius": 3.0,
		"behaviour": "sense",
		"movable": false,
	},
	"counter": {
		"caps": [EmergentCaps.CAN_ACCUMULATE, EmergentCaps.CAN_EMIT_EVENT],
		"props": {"target": 3.0},
		"state": {"value": 0.0, "count": 0},
		"label": "counter",
		"radius": 0.0,
		"behaviour": "score",
		"movable": false,
	},
	"gate": {
		"caps": [EmergentCaps.CAN_ACTUATE, EmergentCaps.CAN_EMIT_EVENT],
		"props": {"radius": 1.5},
		"state": {"open": false, "count": 0},
		"label": "gate",
		"radius": 1.5,
		"behaviour": "actuate",
		"movable": false,
	},
	"cart": {
		"caps": [EmergentCaps.CAN_MOVE, EmergentCaps.CAN_EMIT_EVENT],
		"props": {"mass": 1.0, "speed": 6.0, "friction": 0.25},
		"state": {"distance": 0.0},
		"label": "cart",
		"radius": 0.6,
		"behaviour": "movement",
		"movable": true,
	},
}

## One placed entity in the world.
##
## Deliberately thin. It has an id, a position, properties, state and
## capabilities. It has no behaviour of its own: what it does is decided by
## which patterns its capabilities match, which is the entire point.
var id := 0
var kind := ""
var position := Vector3.ZERO
var props := {}
var state := {}
var enabled := true
## Optional link to an engineering node, when a player bolts a zone onto a
## machine. 0 when the entity stands alone.
var node_id := 0

## The free-running clock this entity integrates against. Physics here is
## deliberately the simplest thing that produces believable consequences:
## a ball that decelerates, stops and can be hit again. Not a rigid body
## solver, and not pretending to be one.
var velocity := Vector3.ZERO


## Registered once the capability vocabulary knows about them. Godot has no
## module-load hook for a `static var` table, so every public entry point
## calls this; it is a single boolean check after the first time.
static var _caps_registered := false


static func _register_builtin_caps() -> void:
	if _caps_registered:
		return
	_caps_registered = true
	for kind in KINDS.keys():
		for c in (KINDS[kind] as Dictionary).get("caps", []):
			EmergentCaps.add_capability(String(kind), String(c))


static func has_kind(kind: String) -> bool:
	_register_builtin_caps()
	return KINDS.has(kind)


static func definition(kind: String) -> Dictionary:
	_register_builtin_caps()
	return KINDS.get(kind, {})


static func label_of(kind: String) -> String:
	return String(definition(kind).get("label", kind))


## Every kind, in a stable order. Sorted, not insertion-ordered: two clients
## that registered the same kinds in different orders must agree on the list.
static func all_kinds() -> Array[String]:
	_register_builtin_caps()
	var out: Array[String] = []
	for k in KINDS.keys():
		out.append(String(k))
	out.sort()
	return out


## Register a kind at runtime. This is the whole extension point: a mod (or
## a future data file) adds a kind, its capabilities become visible to the
## matcher, and every pattern that wanted those capabilities now recognises
## it -- with no engine change.
static func register_kind(kind: String, def: Dictionary) -> bool:
	if kind == "":
		push_error("[entity] a kind needs an id")
		return false
	var full := {
		"caps": def.get("caps", []),
		"props": def.get("props", {}),
		"state": def.get("state", {}),
		"label": def.get("label", kind),
		"radius": float(def.get("radius", 0.0)),
		"behaviour": String(def.get("behaviour", "")),
		"movable": bool(def.get("movable", false)),
	}
	_register_builtin_caps()
	KINDS[kind] = full
	# One capability vocabulary, one registration path. An entity and a
	# component that both "can detect" are then recognised by the same
	# pattern, which is what lets a sensor switch be built out of either.
	for c in full["caps"]:
		EmergentCaps.add_capability(kind, String(c))
	return true


static func make(p_id: int, kind: String, pos: Vector3,
		node := 0) -> EmergentEntity:
	_register_builtin_caps()
	var e := EmergentEntity.new()
	e.id = p_id
	e.kind = kind
	e.position = pos
	e.node_id = node
	var def := definition(kind)
	e.props = (def.get("props", {}) as Dictionary).duplicate(true)
	e.state = (def.get("state", {}) as Dictionary).duplicate(true)
	return e


## The capabilities this entity exposes. Routed through the shared vocabulary
## rather than computed here, so there is exactly one definition of "what can
## this do" in the whole system.
func capabilities() -> Array[String]:
	return EmergentCaps.of_component(kind)


func has(cap: String) -> bool:
	return capabilities().has(cap)


func radius() -> float:
	return float(props.get("radius", definition(kind).get("radius", 0.0)))


func prop(key: String, fallback := 0.0) -> float:
	return float(props.get(key, fallback))


func set_prop(key: String, value: Variant) -> void:
	props[key] = value


func get_state(key: String, fallback: Variant = null) -> Variant:
	return state.get(key, fallback)


func set_state(key: String, value: Variant) -> void:
	state[key] = value


func behaviour() -> String:
	return String(definition(kind).get("behaviour", ""))


## Does this entity notice the world around it?
##
## Answered from the kind's declared `behaviour`, not from a list of kind
## names and not from "it happens to emit events". Both of those were wrong
## in ways a player would have hit immediately: a counter emits events but
## is not a sensor, so treating capability as sensing made every golf hole
## score itself the frame it was built; and a gate has a radius, so
## proximity made it detect the cart standing next to it and fire a second
## `on_entered` that cancelled the first one's effect.
##
## Reading the one data field that already says what a kind is FOR means a
## mod that registers a kind with behaviour "sense" gets a sensor, and one
## that registers "score" gets a scoreboard, with no engine change and no
## kind ever being named in the sensing code.
func is_sensor() -> bool:
	return behaviour() == "sense"


func is_movable() -> bool:
	return bool(definition(kind).get("movable", false))


## A stable key for multiplayer ordering and for save comparison. Position is
## quantised because floating point drift between a client and a server is
## not a thing any system should have to care about.
func stable_key() -> String:
	return "%d:%s:%d,%d,%d" % [id, kind, int(roundf(position.x * 16.0)),
		int(roundf(position.y * 16.0)), int(roundf(position.z * 16.0))]


func to_dict() -> Dictionary:
	return {
		"id": id, "kind": kind,
		"position": [position.x, position.y, position.z],
		"props": props.duplicate(true),
		"state": state.duplicate(true),
		"enabled": enabled,
		"node": node_id,
	}


static func from_dict(d: Dictionary) -> EmergentEntity:
	var raw: Array = d.get("position", [0.0, 0.0, 0.0])
	var pos := Vector3.ZERO
	if raw.size() == 3:
		pos = Vector3(float(raw[0]), float(raw[1]), float(raw[2]))
	var e := make(int(d.get("id", 0)), String(d.get("kind", "")), pos,
		int(d.get("node", 0)))
	e.enabled = bool(d.get("enabled", true))
	var p = d.get("props", {})
	if p is Dictionary:
		e.props.merge((p as Dictionary).duplicate(true), true)
	var s = d.get("state", {})
	if s is Dictionary:
		e.state.merge((s as Dictionary).duplicate(true), true)
	return e