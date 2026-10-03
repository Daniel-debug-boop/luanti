class_name EmergentCausal
extends RefCounted
## The causal engine: what turns a chain of relationships into something that
## happens.
##
##     INPUT -> CONDITION -> TRANSFORMATION -> STATE CHANGE -> EVENT
##
## The engine's job is to walk that chain, honestly and within a budget.
## Every part of the design here exists because of a way this can go wrong,
## and players WILL find all of them:
##
##   * A -> B -> C -> A. A rule that re-emits its own event is a loop, and a
##     loop in a naive event bus is a hang. Depth is capped, each event
##     carries its depth, and a rule cannot fire twice for the same event at
##     the same depth.
##   * Ten thousand sensors all noticing at once. The queue is bounded and
##     the engine drains it within a budget, reporting what it dropped rather
##     than silently losing it.
##   * Two clients evaluating the same creation and getting different answers.
##     The queue is drained in sorted order -- priority, then sequence, then
##     subject id -- so the same inputs always produce the same outputs in the
##     same order. This is not cosmetic: an out-of-order score is a desync.
##   * A rule storm: a player wires 500 gates to one counter. Rules are budgeted
##     per frame and the cooldown field exists so a rule cannot monopolise it.
##
## The engine holds no opinions about what a "golf hole" is. It observes
## subjects, emits events for what it observed, applies behaviours whose
## constraints hold, and lets the player's rules connect one event to another.

## An event in flight. Data only -- no object references, so an event cannot
## keep a deleted entity alive or resolve to something a client no longer has.
class Event:
	var name: String
	var subject: int = 0
	## An entity the emitter means, when that is not the subject. A zone that
	## notices a ball emits on the zone's id, but the rule the player wrote
	## may act on the scoreboard; carrying the intent on the event is what
	## lets "this hole tells that counter" work without either side knowing
	## about the other.
	var target: int = 0
	var depth := 0
	## Monotonic sequence number, assigned at enqueue. Two events with equal
	## priority are ordered by this, which is what makes the drain order
	## total and therefore identical on two machines.
	var seq := 0
	var value := 0.0
	## The rule whose action raised this event, or 0 if the engine raised it.
	##
	## This is what stops a rule from reacting to its own consequences.
	## `WHEN on_actuated DO score 1 counter` is a perfectly reasonable thing
	## for a player to write and it counts gate openings -- but the actuate
	## action also raises on_actuated, so the rule heard itself, once more,
	## every frame, and the score climbed forever. MAX_FIRES_PER_RULE did
	## not help: it bounds a rule within one tick, and this loop spans
	## ticks. The invariant has to be carried by the event, because "did I
	## cause this?" is a property of the event and not of the tick it
	## happened to land in.
	var cause_rule := 0

	func to_dict() -> Dictionary:
		return {"name": name, "subject": subject, "depth": depth,
			"seq": seq, "value": value, "cause_rule": cause_rule}

	static func from_dict(d: Dictionary) -> Event:
		var e := Event.new()
		e.name = String(d.get("name", ""))
		e.subject = int(d.get("subject", 0))
		e.depth = int(d.get("depth", 0))
		e.seq = int(d.get("seq", 0))
		e.value = float(d.get("value", 0.0))
		e.cause_rule = int(d.get("cause_rule", 0))
		return e


## Budgets. Every one of these is a hard stop. A budget that is advisory is a
## budget that is not there.
const MAX_DEPTH := 8
const MAX_QUEUE := 4096
## Events processed per tick. Sized so a normal player construction never
## notices and a pathological one degrades instead of freezing.
const MAX_PER_TICK := 128
## Rules evaluated per tick.
const MAX_RULES_PER_TICK := 256
## How many times one rule may fire for one event name within one tick. The
## direct defence against a self-triggering rule.
const MAX_FIRES_PER_RULE := 1

## Rule event names the engine itself raises, so a player never has to guess
## what a collision is called.
const ENTERED := "on_entered"
const SCORED := "on_scored"
const ACTUATED := "on_actuated"
const GOAL_REACHED := "on_goal_reached"
const COMPLETED := "on_completed"

var _queue: Array = []
var _seq := 0
var _depth := 0
## Events already processed this tick, so re-emitting one is visible rather
## than an infinite descent.
var _seen_this_tick := {}
## (rule id, event name) -> fires this tick.
var _rule_fires := {}

# --- instrumentation, all of it real ---------------------------------------
## Counters the profiler and the stress tests read. A budget nobody measures
## is a budget nobody knows is working.
var stats := {
	"queued": 0, "processed": 0, "dropped": 0, "cycles": 0,
	"rules_fired": 0, "budget_stalls": 0,
}
var last_tick_processed := 0
var last_tick_dropped := 0


func reset() -> void:
	_queue.clear()
	_seen_this_tick.clear()
	_rule_fires.clear()
	_depth = 0
	for k in stats.keys():
		stats[k] = 0
	last_tick_processed = 0
	last_tick_dropped = 0


# --- enqueue ---------------------------------------------------------------

## Raise an event. Returns false when the queue is full or the depth cap is
## hit, and says why -- an engine that drops silently cannot be debugged.
func emit_event(name: String, subject: int, value := 0.0, target := 0,
		cause_rule := 0) -> bool:
	if _depth >= MAX_DEPTH:
		stats["cycles"] = int(stats["cycles"]) + 1
		return false
	if _queue.size() >= MAX_QUEUE:
		stats["dropped"] = int(stats["dropped"]) + 1
		return false
	var e := Event.new()
	e.name = name
	e.subject = subject
	e.target = target
	e.depth = _depth
	e.value = value
	e.cause_rule = cause_rule
	_seq += 1
	e.seq = _seq
	_queue.append(e)
	stats["queued"] = int(stats["queued"]) + 1
	return true


func queue_size() -> int:
	return _queue.size()


# --- drain -----------------------------------------------------------------

## Process the queue for one tick. Returns a report:
##   { processed, dropped, rules_fired, cycles }
##
## Order is total and explicit. Nothing here iterates a Dictionary.
func drain(graph: EmergentGraph, world: Object, origin: Vector3,
		now: float) -> Dictionary:
	_seen_this_tick.clear()
	_rule_fires.clear()
	var processed := 0
	var stalled := false
	_depth = 0

	# Sort once, by the total order, then take what fits in the budget. Taking
	# the budget from a sorted queue means a system under load degrades by
	# dropping the LEAST important work, not a random slice of it.
	var pending := _queue.duplicate()
	_queue.clear()
	pending.sort_custom(_order_events)
	for i in range(pending.size()):
		if processed >= MAX_PER_TICK:
			# Everything left stays for next tick rather than being lost.
			for j in range(i, pending.size()):
				_queue.append(pending[j])
			stats["dropped"] = int(stats["dropped"]) + (pending.size() - i)
			stalled = true
			break
		var e: Event = pending[i]
		var key := "%s#%d" % [e.name, e.subject]
		if _seen_this_tick.has(key):
			# Same event, same subject, this tick. Processing it twice is how a
			# rule that adds to a counter turns into a doubling machine.
			stats["cycles"] = int(stats["cycles"]) + 1
			continue
		_seen_this_tick[key] = true
		_depth = e.depth + 1
		_dispatch(e, graph, world, origin, now)
		processed += 1
	_depth = 0
	last_tick_processed = processed
	last_tick_dropped = _queue.size()
	if stalled:
		stats["budget_stalls"] = int(stats["budget_stalls"]) + 1
	stats["processed"] = int(stats["processed"]) + processed
	return {
		"processed": processed,
		"dropped": last_tick_dropped,
		"rules_fired": int(stats["rules_fired"]),
		"cycles": int(stats["cycles"]),
		"stalled": stalled,
	}


## The total order. Sequence breaks every tie, so no two events can ever be
## ordered differently on two machines.
static func _order_events(a: Event, b: Event) -> bool:
	if a.depth != b.depth:
		return a.depth < b.depth
	if a.subject != b.subject:
		return a.subject < b.subject
	return a.seq < b.seq


## One event, through the rule table.
func _dispatch(e: Event, graph: EmergentGraph, world: Object,
		origin: Vector3, now: float) -> void:
	var subject := graph.entity(e.subject) if graph != null else null
	var budget := MAX_RULES_PER_TICK
	for r in EmergentRules.all():
		var rule: EmergentRules.Rule = r
		if budget <= 0:
			stats["budget_stalls"] = int(stats["budget_stalls"]) + 1
			return
		# Cheap test before the expensive one: most rules are about a
		# different event entirely.
		if rule.when_event != e.name:
			continue
		budget -= 1
		# The target is resolved BEFORE the condition is tested, because the
		# condition is a claim about the thing being acted on. "WHEN score
		# >= 10 DO open gate" has to read the counter's score, not the hole's
		# -- testing the subject would make the rule compare the wrong
		# entity's state and the player would be told to fix a rule that was
		# written correctly.
		var target := _target_for(graph, rule, e, subject)
		# A rule never hears its own consequences. See Event.cause_rule.
		if e.cause_rule != 0 and e.cause_rule == rule.id:
			stats["cycles"] = int(stats["cycles"]) + 1
			continue
		var m := EmergentRules.matches(rule, e.name, target, now)
		if not bool(m["ok"]):
			continue
		var fires_key := "%d:%s" % [rule.id, e.name]
		if int(_rule_fires.get(fires_key, 0)) >= MAX_FIRES_PER_RULE:
			stats["cycles"] = int(stats["cycles"]) + 1
			continue
		var applied := EmergentRules.apply(rule, target, now)
		if not bool(applied["ok"]):
			continue
		_rule_fires[fires_key] = int(_rule_fires.get(fires_key, 0)) + 1
		stats["rules_fired"] = int(stats["rules_fired"]) + 1
		# The action produced a state change, so the chain continues: a rule
		# that opens a gate can fire a rule that counts the gate opening.
		# Stamped with the rule that caused it, so that rule cannot hear it.
		emit_event(EmergentCausal.ACTUATED, target.id if target != null
			else e.subject, 0.0, 0, rule.id)


## Where a rule's action lands.
##
## Priority order, and the order is the whole design:
##   1. the rule named a kind -- "do score 1 counter"
##   2. the rule named an id -- "do score 1 #7"
##   3. the emitter said who it meant -- the event's `target`
##   4. otherwise the subject that raised the event
##
## (1) beats (2) beats (3) because the player's written rule is a stronger
## statement of intent than anything the engine inferred. Every fallback is
## deterministic: ids are visited in ascending order, so two clients resolve
## the same target.
static func _target_for(graph: EmergentGraph, rule: EmergentRules.Rule,
		e: Event, subject: EmergentEntity) -> EmergentEntity:
	if graph == null:
		return subject
	if rule.target_kind != "":
		return _find_kind(graph, rule.target_kind)
	if rule.target_id != 0:
		var named := graph.entity(rule.target_id)
		return named if named != null else subject
	if e.target != 0:
		var hinted := graph.entity(e.target)
		return hinted if hinted != null else subject
	return subject


static func _find_kind(graph: EmergentGraph, kind: String) -> EmergentEntity:
	var ids: Array = []
	for e in graph.all_entities():
		var ent: EmergentEntity = e
		if ent.kind == kind:
			ids.append(ent.id)
	ids.sort()
	for id in ids:
		var found := graph.entity(int(id))
		if found != null:
			return found
	return null


# --- persistence -----------------------------------------------------------

## The queue is NOT saved. It is mid-flight derived state: replaying it after
## a load would fire events for things that happened before the save, and
## dropping it silently loses at most one tick of reactions, which the next
## observation reproduces. The counters that matter live on the subjects.
func serialize() -> Dictionary:
	return {"version": 1, "seq": _seq}


func deserialize(data: Dictionary) -> void:
	_seq = int(data.get("seq", 0))
	_queue.clear()
	_seen_this_tick.clear()
	_rule_fires.clear()
	_depth = 0


func report() -> String:
	return ("causal: %d processed, %d queued, %d dropped, %d cycles, "
		+ "%d rules fired") % [int(stats["processed"]), _queue.size(),
		int(stats["dropped"]), int(stats["cycles"]), int(stats["rules_fired"])]