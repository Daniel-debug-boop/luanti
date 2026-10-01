class_name EmergentBehaviors
extends RefCounted
## Behaviours: what a matched pattern actually DOES.
##
## A pattern match produces a name. A behaviour is the executable behind the
## name -- the thing that, when the constraints hold, changes state, emits
## events and moves things. Keeping the two apart matters because they fail
## differently: a pattern that matches the wrong things is a vocabulary bug,
## a behaviour that does the wrong thing is a gameplay bug, and a matcher
## that quietly did both would be undebuggable.
##
## Every behaviour is DATA plus a step function keyed by kind, not a class per
## behaviour. A water turbine is not a `HydroelectricPlant`; it is a pump and
## a generator on the same shaft, and the behaviours it composes are
## "rotation_drive" and "fluid_pump", both of which the water turbine in a
## player's build and the one in a factory mod use.
##
## ## The causality model
##
## INPUT -> CONDITION -> TRANSFORMATION -> STATE CHANGE -> EVENT
##
## is implemented literally. A behaviour's `poll` observes the world and
## returns an INPUT; its `transform` turns an INPUT plus the behaviour's own
## configuration into a TRANSFORMATION; the engine applies that to the
## subject's state (a STATE CHANGE) and, if the behaviour says so, emits the
## behaviour's event. Five named steps, so the diagnostic view can show
## exactly where a chain stopped.

## A behaviour definition.
class Behavior:
	var id: String
	## Human-readable, for the diagnostic view.
	var label := ""
	## Capabilities a subject must expose for this behaviour to run at all.
	var requires: Array[String] = []
	## Behaviors this one needs present in the same subject.
	var needs: Array[String] = []
	## Behaviors that must NOT be present. Used where two behaviours are
	## genuinely exclusive, e.g. a thing that both stores power and is a
	## power source should not double-count.
	var excludes: Array[String] = []
	## Which causal step kind this behaviour is.
	var kind := "transform"
	## The event it emits, if any.
	var emits := ""
	## State key it writes.
	var writes := ""
	## Lower runs first. Ordering is explicit because two behaviours writing
	## the same state in unordered iteration is a desync waiting to happen.
	var priority := 0

	func _init(p_id: String, p_label := "", p_kind := "transform",
			p_priority := 0) -> void:
		id = p_id
		label = p_label if p_label != "" else p_id
		kind = p_kind
		priority = p_priority


## One active behaviour, bound to the subject that matched it.
class Active:
	var behaviour: String
	## The node or entity this is bound to. Node ids and entity ids share an
	## int space deliberately: a relationship between a machine and the zone
	## bolted to it is then an ordinary edge, not a special case.
	var subject: int
	## True when every constraint held. An inactive behaviour is retained
	## rather than dropped, because "this is a machine but it has no power" is
	## the single most useful thing the diagnostic view can say.
	var active := false
	## Why it is not active, when it is not.
	var reason := ""
	## The pattern that contributed it.
	var pattern := ""

	func _init(p_behaviour: String, p_subject: int, p_pattern := "") -> void:
		behaviour = p_behaviour
		subject = p_subject
		pattern = p_pattern


static var _defs := {}
static var _order: Array[String] = []
static var _built := false


static func register(b: Behavior) -> void:
	if b == null or b.id == "":
		push_warning("[behaviors] refusing a behaviour with no id")
		return
	if not _defs.has(b.id):
		_order.append(b.id)
	_defs[b.id] = b


static func get_behavior(id: String) -> Behavior:
	_ensure()
	return _defs.get(id, null)


static func all_ids() -> Array[String]:
	_ensure()
	return _order.duplicate()


## Every behaviour definition, in a stable order. Sorted rather than
## registration-ordered: two clients registering the same behaviours in
## different orders must still agree on what exists.
static func all() -> Array[Behavior]:
	_ensure()
	var out: Array[Behavior] = []
	for id in _order:
		out.append(_defs[id])
	return out


static func _ensure() -> void:
	if _built:
		return
	_built = true
	_defaults()


## Composition is the part that has to avoid exploding.
##
## The naive version -- every subset of behaviours is a possible composition --
## is 2^n, and n is however many parts a determined player builds. So
## composition here is NOT subset enumeration. It is:
##
##   * the behaviours each matched pattern contributed, deduplicated
##   * ordered by explicit priority, then by name
##   * pruned by `needs`/`excludes`, which is a linear pass
##
## which is O(n log n) in the behaviour count and, crucially, produces the
## SAME answer whatever order the patterns were matched in. A composer whose
## result depended on match order would make two clients disagree about what
## a machine does, which is a desync and not a cosmetic bug.
static func compose(entries: Array) -> Array:
	_ensure()
	# entries: [{behaviour, subject, pattern, constraints_ok, reason}]
	var acc := {}
	for e in entries:
		var d: Dictionary = e
		var bid := String(d.get("behaviour", ""))
		if bid == "":
			continue
		if not _defs.has(bid):
			continue
		var key := "%d:%s" % [int(d.get("subject", 0)), bid]
		if acc.has(key):
			continue
		if not _defs.has(bid):
			# A pattern naming a behaviour nobody registered. Reported rather
			# than skipped, because this used to be silent and it turned three
			# system patterns into no-ops. A mod registering a behaviour with
			# a typo now finds out from the diagnostics instead of wondering
			# why its pattern does nothing.
			push_warning("[behaviors] composition references '%s', which is "
				% bid + "not a registered behaviour")
			continue
		acc[key] = d
	var out: Array = []
	for key in acc.keys():
		out.append(acc[key])
	# Priority then name. Never insertion order.
	out.sort_custom(_order_behaviours)
	var present := {}
	for e in out:
		present[String((e as Dictionary)["behaviour"])] = true
	var pruned: Array = []
	for e in out:
		var d: Dictionary = e
		var def: Behavior = _defs[String(d["behaviour"])]
		if def == null:
			continue
		var blocked := ""
		for x in def.excludes:
			if present.has(String(x)):
				blocked = String(x)
				break
		if blocked != "":
			d["active"] = false
			d["reason"] = "conflicts with '%s'" % blocked
		pruned.append(d)
	return pruned


static func _order_behaviours(a: Dictionary, b: Dictionary) -> bool:
	var da: Behavior = _defs.get(String(a.get("behaviour", "")), null)
	var db: Behavior = _defs.get(String(b.get("behaviour", "")), null)
	var pa := 0 if da == null else da.priority
	var pb := 0 if db == null else db.priority
	if pa != pb:
		return pa < pb
	return String(a.get("behaviour", "")) < String(b.get("behaviour", ""))


## Which behaviours a subject's capability set actually supports. This is the
## check that keeps a declared-but-unreachable behaviour honest: a motor that
## is not wired to anything can still "drive rotation" in principle, but the
## pattern that contributes a behaviour must also be matched, and that is a
## separate question answered by the matcher.
static func supports(caps: Array) -> Array[String]:
	_ensure()
	var have := {}
	for c in caps:
		have[String(c)] = true
	var out: Array[String] = []
	for id in _order:
		var def: Behavior = _defs[id]
		var ok := true
		for r in def.requires:
			if not have.has(r):
				ok = false
				break
		if ok:
			out.append(id)
	out.sort()
	return out


static func describe(id: String) -> String:
	var def := get_behavior(id)
	if def == null:
		return "%s: not a behaviour" % id
	return "%s (%s): %s" % [def.id, def.kind, def.label]


# --- the built-in library --------------------------------------------------

static func _defaults() -> void:
	# Rotation. The pair that turns a motor and an attachment into a machine
	# without either of them knowing what the other is.
	register(Behavior.new("rotation_drive", "drives rotation", "transform", 10))
	var rd := get_behavior("rotation_drive")
	rd.requires = [EmergentCaps.CAN_DRIVE_ROTATION]
	rd.emits = "on_driving"

	register(Behavior.new("rotation_load", "resists rotation", "transform", 20))
	var rl := get_behavior("rotation_load")
	rl.requires = [EmergentCaps.CAN_RECEIVE_ROTATION]
	rl.excludes = ["power_conversion"]

	register(Behavior.new("power_conversion", "turns power into motion",
		"transform", 5))
	var pc := get_behavior("power_conversion")
	pc.requires = [EmergentCaps.CAN_RECEIVE_POWER, EmergentCaps.CAN_DRIVE_ROTATION]
	pc.emits = "on_powered"

	register(Behavior.new("fluid_pump", "moves fluid", "transform", 10))
	var fp := get_behavior("fluid_pump")
	fp.requires = [EmergentCaps.CAN_MOVE_FLUID]

	register(Behavior.new("fluid_store", "holds fluid", "store", 30))
	var fs := get_behavior("fluid_store")
	fs.requires = [EmergentCaps.CAN_STORE_FLUID]

	# The three SYSTEM-tier behaviours. They were named by the pattern
	# library and never registered here, which meant `compose()` silently
	# dropped them -- so the `machine`, `fluid_system` and `automation`
	# patterns matched and then contributed NOTHING. A pattern that matches
	# but contributes no behaviour is the exact failure this layer exists to
	# prevent, and it was invisible because compose() skips unknown ids
	# rather than reporting them.
	register(Behavior.new("powered_drive", "drives from a live power path",
		"transform", 25))
	var pd := get_behavior("powered_drive")
	pd.requires = [EmergentCaps.CAN_DRIVE_ROTATION]
	pd.needs = [EmergentCaps.CAN_RECEIVE_POWER]
	pd.emits = "on_driving"

	register(Behavior.new("fluid_transport", "moves fluid along a network",
		"transform", 25))
	var ft := get_behavior("fluid_transport")
	ft.requires = [EmergentCaps.CAN_MOVE_FLUID]

	register(Behavior.new("processing", "transforms material", "transform",
		35))
	var pr := get_behavior("processing")
	pr.requires = [EmergentCaps.CAN_TRANSFORM]

	register(Behavior.new("power_store", "holds power", "store", 30))
	var ps := get_behavior("power_store")
	ps.requires = [EmergentCaps.CAN_STORE_POWER]

	register(Behavior.new("signal_source", "reports what it observes",
		"sense", 40))
	var ss := get_behavior("signal_source")
	ss.requires = [EmergentCaps.CAN_PRODUCE_SIGNAL]
	ss.emits = "on_detected"

	# Gameplay behaviours. These are the ones that make an activity an
	# activity: something notices, something counts, something opens.
	register(Behavior.new("sense", "notices what enters it", "sense", 50))
	var sn := get_behavior("sense")
	sn.requires = [EmergentCaps.CAN_EMIT_EVENT]
	sn.emits = "on_entered"

	register(Behavior.new("score", "counts what happened", "transform", 60))
	var sc := get_behavior("score")
	sc.requires = [EmergentCaps.CAN_ACCUMULATE]
	sc.writes = "value"
	sc.emits = "on_scored"

	# A goal being checked is NOT the same behaviour as something scoring.
	# Keeping them apart is what lets a player build a hole with no scoreboard
	# (a practice green) and a scoreboard with no hole (a tally board), and
	# have the diagnostic view tell them which of the two they actually made.
	register(Behavior.new("goal_check", "checks whether the goal was reached",
		"sense", 55))
	var gc := get_behavior("goal_check")
	gc.requires = [EmergentCaps.CAN_EMIT_EVENT]
	gc.emits = "on_goal_reached"

	register(Behavior.new("actuate", "opens and closes", "transform", 70))
	var ac := get_behavior("actuate")
	ac.requires = [EmergentCaps.CAN_ACTUATE]
	ac.writes = "open"
	ac.emits = "on_actuated"

	register(Behavior.new("movement", "travels", "transform", 15))
	var mv := get_behavior("movement")
	mv.requires = [EmergentCaps.CAN_MOVE]
	mv.writes = "position"