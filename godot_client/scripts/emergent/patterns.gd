class_name EmergentPatterns
extends RefCounted
## Patterns: what a functional object IS, stated as a shape over
## capabilities and relationships rather than a list of part ids.
##
## The distinction is the whole point.
##
##   A pattern saying "motor + shaft + wheel = vehicle" only recognises
##   vehicles built as motor + shaft + wheel. A player who builds a crank +
##   flywheel + pulley, which drives exactly as well, gets nothing -- and the
##   fix is always to add another id, which is the bespoke-system treadmill
##   this architecture exists to avoid.
##
##   A pattern saying "something that can drive rotation, wired to something
##   that can move" recognises every construction that satisfies it,
##   including ones nobody anticipated.
##
## So patterns never name components. They name capabilities, the
## relationships between the holders of those capabilities, and the
## constraints under which the resulting behaviour may actually run. A pattern
## that matched but whose constraints are unsatisfied is NOT active: "the
## shape is right" and "the thing works" are different claims, and the gap
## between them is the constraint system.
##
## Four tiers, from one part to a whole activity. They are not special
## mechanisms -- a primitive and a gameplay pattern are the same structure,
## which is what lets a player-authored pattern sit beside a built-in one.

const TIER_PRIMITIVE := "primitive"     # a single part's function
const TIER_FUNCTIONAL := "functional"   # a recognisable object
const TIER_SYSTEM := "system"           # a machine or network
const TIER_GAMEPLAY := "gameplay"       # something a player does


class Pattern:
	var id: String
	var tier: String
	## Capabilities that must be present for the pattern to apply.
	var requires: Array[String] = []
	## Capabilities that improve it but are not required.
	var optional: Array[String] = []
	## Machine roles that must be present.
	var roles: Array[String] = []
	## Minimum component count.
	var min_members := 1
	## Ordered capability chains that must be wired end to end. Each entry is
	## an array of capability names: [["can_drive_rotation", "can_move"], ...]
	var chains: Array = []
	## Behaviour names this pattern contributes when it matches.
	var behaviours: Array[String] = []
	## Constraints that must hold for the behaviour to actually run.
	var constraints: Array = []
	## What the developer view says this is.
	var description := ""

	func _init(p_id: String, p_tier := TIER_FUNCTIONAL) -> void:
		id = p_id
		tier = p_tier


static var _patterns := {}
static var _order: Array[String] = []


static func register(p: Pattern) -> void:
	if p == null or p.id == "":
		push_warning("[patterns] refusing to register a pattern with no id")
		return
	if not _patterns.has(p.id):
		_order.append(p.id)
	_patterns[p.id] = p


static func get_pattern(id: String) -> Pattern:
	_ensure()
	return _patterns.get(id, null)


static func all_ids() -> Array[String]:
	_ensure()
	return _order.duplicate()


static func of_tier(tier: String) -> Array[String]:
	_ensure()
	var out: Array[String] = []
	for id in _order:
		var p: Pattern = _patterns[id]
		if p.tier == tier:
			out.append(id)
	return out


# --- the built-in pattern library ------------------------------------------
#
# Not one of these names a component. Each is a shape, and any construction
# filling the shape works.

static func _defaults() -> void:
	# --- primitives -------------------------------------------------------
	var hinge := Pattern.new("hinge", TIER_PRIMITIVE)
	hinge.requires = [EmergentCaps.CAN_DRIVE_ROTATION]
	hinge.optional = [EmergentCaps.CAN_RECEIVE_ROTATION]
	hinge.description = "a part that turns"
	register(hinge)

	var support := Pattern.new("support", TIER_PRIMITIVE)
	support.requires = [EmergentCaps.CAN_SUPPORT]
	support.description = "a part that carries load"
	register(support)

	var reservoir := Pattern.new("reservoir", TIER_PRIMITIVE)
	reservoir.requires = [EmergentCaps.CAN_STORE_FLUID]
	reservoir.description = "a part that holds fluid"
	register(reservoir)

	var cell := Pattern.new("cell", TIER_PRIMITIVE)
	cell.requires = [EmergentCaps.CAN_STORE_POWER]
	cell.description = "a part that holds power"
	register(cell)

	var sensor := Pattern.new("sensor", TIER_PRIMITIVE)
	sensor.requires = [EmergentCaps.CAN_PRODUCE_SIGNAL]
	sensor.description = "a part that reports what it observes"
	register(sensor)

	var trigger := Pattern.new("trigger", TIER_PRIMITIVE)
	trigger.requires = [EmergentCaps.CAN_ACTUATE]
	trigger.description = "a part that can be actuated"
	register(trigger)

	var conductor := Pattern.new("conductor", TIER_PRIMITIVE)
	conductor.requires = [EmergentCaps.CAN_CONNECT]
	conductor.description = "a part that carries something between others"
	register(conductor)

	# --- functional objects ----------------------------------------------
	var source := Pattern.new("power_source", TIER_FUNCTIONAL)
	source.requires = [EmergentCaps.CAN_SUPPLY_POWER]
	source.optional = [EmergentCaps.CAN_STORE_POWER]
	source.description = "a part that can supply power"
	register(source)

	var drive := Pattern.new("drive", TIER_FUNCTIONAL)
	drive.requires = [EmergentCaps.CAN_DRIVE_ROTATION]
	drive.optional = [EmergentCaps.CAN_RECEIVE_POWER,
		EmergentCaps.CAN_RECEIVE_ROTATION]
	drive.behaviours = ["rotation_drive"]
	drive.description = "a part that drives rotation"
	register(drive)

	var load := Pattern.new("rotary_load", TIER_FUNCTIONAL)
	load.requires = [EmergentCaps.CAN_RECEIVE_ROTATION]
	load.behaviours = ["rotation_load"]
	load.description = "a part that resists rotation and does work"
	register(load)

	var pump := Pattern.new("pump", TIER_FUNCTIONAL)
	pump.requires = [EmergentCaps.CAN_MOVE_FLUID]
	pump.optional = [EmergentCaps.CAN_RECEIVE_ROTATION]
	pump.behaviours = ["fluid_pump"]
	pump.description = "a part that moves fluid"
	register(pump)

	# --- systems ----------------------------------------------------------
	# A full mechanical chain: power, then drive, then something that loads.
	var machine := Pattern.new("machine", TIER_SYSTEM)
	machine.requires = [EmergentCaps.CAN_DRIVE_ROTATION]
	machine.optional = [EmergentCaps.CAN_SUPPLY_POWER, EmergentCaps.CAN_MOVE_FLUID]
	machine.min_members = 3
	# The chain states what the comment above says: a supply, something that
	# turns, and something that resists. The load used to be missing from it,
	# which meant the pattern was satisfied by a battery wired to a motor with
	# nothing on the far end -- a motor spinning into empty air is not a
	# machine, and a pattern that says it is will eventually be believed.
	machine.chains = [[EmergentCaps.CAN_SUPPLY_POWER,
		EmergentCaps.CAN_DRIVE_ROTATION, EmergentCaps.CAN_RECEIVE_ROTATION]]
	machine.behaviours = ["powered_drive"]
	machine.constraints = [EmergentConstraints.HAS_ENERGY]
	machine.description = "a driven assembly fed by a power path"
	register(machine)

	# A hand-driven machine is still a machine. This is the pattern that makes
	# "build it differently" a first-class claim rather than a courtesy: the
	# stock `machine` demands an electrical chain, and a crank + shaft +
	# impeller has none. Without this second pattern a player who builds a
	# water-powered contraption by hand would get no machine at all, and the
	# only fix would be to widen the first one until it stopped meaning
	# anything.
	var hand_machine := Pattern.new("hand_machine", TIER_SYSTEM)
	hand_machine.requires = [EmergentCaps.CAN_DRIVE_ROTATION]
	hand_machine.min_members = 3
	hand_machine.chains = [[EmergentCaps.CAN_DRIVE_ROTATION,
		EmergentCaps.CAN_RECEIVE_ROTATION]]
	hand_machine.behaviours = ["powered_drive"]
	hand_machine.description = "a driven assembly turned by hand or by flow"
	register(hand_machine)

	var fluid_system := Pattern.new("fluid_system", TIER_SYSTEM)
	fluid_system.requires = [EmergentCaps.CAN_MOVE_FLUID]
	fluid_system.min_members = 2
	fluid_system.behaviours = ["fluid_transport"]
	fluid_system.constraints = [EmergentConstraints.HAS_FLUID_SOURCE]
	fluid_system.description = "an assembly that moves fluid from a source"
	register(fluid_system)

	var automation := Pattern.new("automation", TIER_SYSTEM)
	automation.requires = [EmergentCaps.CAN_TRANSFORM,
		EmergentCaps.CAN_MOVE_FLUID]
	automation.min_members = 3
	automation.behaviours = ["processing"]
	automation.description = "an assembly that transforms and moves material"
	register(automation)

	# --- gameplay ---------------------------------------------------------
	# Deliberately expressed as capabilities, so this recognises anything the
	# player built out of sensing, timing and scoring rather than one object.
	var challenge := Pattern.new("challenge", TIER_GAMEPLAY)
	challenge.requires = [EmergentCaps.CAN_PRODUCE_SIGNAL]
	challenge.optional = [EmergentCaps.CAN_ACTUATE,
		EmergentCaps.CAN_TRANSFORM]
	challenge.min_members = 3
	challenge.behaviours = ["goal_check", "score"]
	challenge.description = "anything that senses a condition and reacts"
	register(challenge)

	var transport := Pattern.new("transport", TIER_GAMEPLAY)
	transport.requires = [EmergentCaps.CAN_DRIVE_ROTATION]
	transport.optional = [EmergentCaps.CAN_RECEIVE_ROTATION]
	transport.min_members = 2
	transport.behaviours = ["movement"]
	transport.description = "anything that converts rotation into motion"
	register(transport)

	# --- world entities ----------------------------------------------------
	#
	# The patterns above describe machines. These describe the OTHER half of
	# the world -- the things a player places that are not components -- and
	# they are stated in the same vocabulary, which is the point: a pattern
	# does not know or care whether the part that can sense is a silicon
	# sensor or a chalk circle on the ground.
	#
	# None of them is a golf pattern or a racing pattern. They are "something
	# that notices", "something that counts", "something that opens", and
	# what the player builds out of them is up to them.

	var goal := Pattern.new("goal", TIER_GAMEPLAY)
	goal.requires = [EmergentCaps.CAN_EMIT_EVENT]
	goal.behaviours = ["sense"]
	goal.description = "a place that notices when something arrives"
	register(goal)

	var score := Pattern.new("score", TIER_GAMEPLAY)
	score.requires = [EmergentCaps.CAN_ACCUMULATE]
	score.behaviours = ["score"]
	score.description = "a thing that keeps a count of what happened"
	register(score)

	var gate := Pattern.new("gate", TIER_GAMEPLAY)
	gate.requires = [EmergentCaps.CAN_ACTUATE, EmergentCaps.CAN_EMIT_EVENT]
	gate.behaviours = ["actuate"]
	gate.description = "a thing that opens and closes"
	register(gate)

	var vehicle := Pattern.new("vehicle", TIER_GAMEPLAY)
	vehicle.requires = [EmergentCaps.CAN_MOVE]
	vehicle.behaviours = ["movement"]
	vehicle.description = "a thing that travels"
	register(vehicle)

	# A scored goal. This is the shape a golf hole, a checkpoint and a finish
	# line all share, and it is expressed as "a counter next to something
	# that notices" rather than as any one of those three.
	var activity := Pattern.new("activity", TIER_GAMEPLAY)
	activity.requires = [EmergentCaps.CAN_EMIT_EVENT, EmergentCaps.CAN_ACCUMULATE]
	activity.min_members = 2
	activity.behaviours = ["goal_check", "score"]
	activity.constraints = [EmergentConstraints.WITHIN_RANGE]
	activity.description = "a goal and something that keeps score for it"
	register(activity)


static func _ensure() -> void:
	if not _patterns.is_empty():
		return
	_defaults()


static func all() -> Array[String]:
	_ensure()
	return _order.duplicate()


static func describe(id: String) -> String:
	_ensure()
	var p := get_pattern(id)
	if p == null:
		return "%s: not a pattern" % id
	return "%s (%s): %s" % [p.id, p.tier, p.description]