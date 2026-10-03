class_name EmergentSystem
extends System
## The emergent system: one object that owns the layer, ticks it under a
## budget, and is the single thing the game talks to.
##
## It is a `System` rather than a loose RefCounted for the reasons
## `SystemRegistry` already documents: exactly one owner, an explicit
## lifecycle, and a teardown that accounts for everything it created. An
## emergent layer with two instances ticking the same events is a double
## score; with none, nothing happens at all. Both are caught by "exactly one
## owner".
##
## ## The tick, and what it deliberately does not do
##
## Per frame, in this order:
##
##   1. `graph.ensure()`   -- one integer comparison if the player built
##      nothing, a bounded rebuild if they did. Never a world scan.
##   2. sense              -- entities notice what is near them and raise
##      events. Bounded by entity count and radius, and prioritised by
##      distance to the player.
##   3. integrate          -- movable entities move, under real physics from
##      the voxel world.
##   4. `causal.drain()`   -- the event queue, in a total order, under a
##      budget.
##   5. analysis, budgeted -- pattern matching and composition, only for
##      subjects whose graph neighbourhood changed.
##
## Steps 1 and 5 are the ones that could be expensive, and both are keyed on
## the engineering graph's revision counter plus a dirty set of subjects. A
## player who builds nothing pays for neither.
##
## ## Multiplayer
##
## The emergent layer derives, it does not author. A client may predict its
## own construction, but anything that changes authoritative gameplay state
## goes through `NetAuthority`, which re-derives it server-side. What is
## synchronised is the minimum: the entities (their kind and position) and
## the rules. Everything else -- relationships, patterns, behaviours -- is
## reconstructed independently on each peer and therefore cannot desync,
## because no peer is ever told the answer.

var graph: EmergentGraph = null
var causal: EmergentCausal = null

## Positions of things that can be detected: the player, mobs, other carts.
## Supplied by the game each tick rather than discovered by the layer, because
## "what is alive in this world" is the game's question, not this layer's.
var observers: Array = []
## The player's position, for range constraints and prioritisation.
var observer_position := Vector3.INF
## The voxel world, used for collision. Optional: the layer runs without one,
## and says so rather than pretending.
var world: Object = null
var authority: Object = null

var tick_count := 0
## Set when the derived layer is out of date. The world graph tracks its own
## dirty flag; this one covers the parts the emergent layer owns -- entities
## and rules.
var dirty := false
## Set when a subject needs re-analysis. Cleared by `rebuild`.
var _dirty := {}
## subject id -> [{behaviour, pattern, active, reason}]. The active behaviour
## set, kept so the diagnostic view and the tests can read it without
## recomputing.
var _active := {}
## subject id -> the chain of steps that produced its current state.
var _chains := {}

# --- budgets ---------------------------------------------------------------
## Everything below is a hard stop. These are the numbers that keep a
## pathological creation from being a frozen game, and the stress test
## asserts each one is actually enforced.
var budget_sense := 64         # entities sensed per tick
var budget_analysis := 16      # subjects re-analysed per tick
var budget_causal := 128       # events per tick (delegated to the engine)
var max_subjects := 4096       # a hard cap on tracked subjects

## Live counters, read by the profiler and the watchdog.
var stats := {
	"sensed": 0, "events": 0, "analysed": 0, "moved": 0,
	"dropped_sense": 0, "dropped_analysis": 0,
}


func _initialize() -> bool:
	graph = EmergentGraph.new()
	causal = EmergentCausal.new()
	dirty = true
	return true


func describes() -> String:
	return "%d entities, %d rules, %d patterns" % [
		graph.entity_count() if graph != null else 0,
		EmergentRules.count(),
		EmergentPatterns.all_ids().size()]


func _initialize_graph(eng_graph: EngGraph) -> void:
	graph.attach(eng_graph)
	invalidate()


## Point this layer at the engineering graph it derives from. Safe to call
## every frame and safe to call before `initialize()` -- the composition root
## runs `_process` between constructing the object and starting it in the
## registry, and a frame that skipped its own graph would otherwise crash on
## a null rather than simply not sense anything.
func attach_to(eng_graph: EngGraph) -> void:
	if graph == null or eng_graph == null:
		return
	graph.attach(eng_graph)


## Feed the layer the things it can sense. Separate from `tick` so the
## composition root sets up the frame's inputs while the registry owns the
## order in which the frame's work happens.
func observe(positions: Array, player_position := Vector3.INF) -> void:
	observers = positions
	observer_position = player_position


# --- invalidation ----------------------------------------------------------

## Mark the world as changed. Cheap, and the only thing a caller needs to
## remember to call after a build.
func invalidate() -> void:
	dirty = true
	if graph != null:
		for e in graph.all_entities():
			_dirty[int((e as EmergentEntity).id)] = true


func mark_dirty(subject: int) -> void:
	_dirty[subject] = true


## Force a full re-analysis of every subject. Used after a load, where the
## derived layer must be rebuilt before anyone looks at it.
func rebuild() -> void:
	if graph == null:
		return
	graph.ensure()
	invalidate()
	_analyse_all()


func _analyse_all() -> void:
	var ids: Array = _dirty.keys()
	ids.sort()
	_dirty.clear()
	for id in ids:
		_analyse(int(id))


# --- tick ------------------------------------------------------------------

## One tick. `dt` is the frame delta; the layer integrates its own movable
## entities with it.
func tick(dt: float) -> void:
	if graph == null:
		return
	tick_count += 1
	graph.ensure()
	_sense(dt)
	_integrate(dt)
	var report := causal.drain(graph, world, observer_position,
		float(tick_count))
	stats["events"] = int(stats["events"]) + int(report["processed"])
	_analyse_dirty()


## ## Sensing
##
## For each entity that can emit events, ask what is inside its radius and
## raise an event for what it found. This is the INPUT step of the causal
## chain and the only place the world is observed.
##
## Budgeted and prioritised: the nearest entities are sensed first, because
## they are the ones the player can see the consequences of. When the budget
## runs out the remainder is skipped and COUNTED, not silently dropped -- a
## counter the player can read is the difference between "my far-away hole
## does not score" and a mystery.
func _sense(_dt: float) -> void:
	var candidates := _sense_candidates()
	var done := 0
	for entry in candidates:
		if done >= budget_sense:
			stats["dropped_sense"] = int(stats["dropped_sense"]) + (
				candidates.size() - done)
			break
		var e: EmergentEntity = entry
		if not e.enabled:
			continue
		done += 1
		stats["sensed"] = int(stats["sensed"]) + 1
		var occupants := _occupants_of(e)
		if occupants.is_empty():
			continue
		# One event per (sensing entity, occupant), not per frame: a ball
		# sitting in the hole is an ENTRY once, and the rule decides whether
		# that is worth anything.
		#
		# The pair is kept as TWO state entries rather than one "a:b" key.
		# A combined key has to be parsed back to find out who left, and
		# `int("1:4")` is 14, not 4 -- so the arrival flag was cleared every
		# frame and the zone re-announced the same cart forever. Two keys
		# cannot be misparsed, and they are individually valid state names,
		# which matters because state is what a player rule reads.
		var here: Array = []
		for o in occupants:
			here.append(int((o as Dictionary)["id"]))
		for id in here:
			if e.get_state(_seen_key(e.id, id)) == true:
				continue
			e.set_state(_seen_key(e.id, id), true)
			causal.emit_event(EmergentCausal.ENTERED, e.id)
			_record_chain(e, "observed %s" % String(
				_occupant_name(id)))
		# Occupants that left stop being occupants, so coming back is an
		# arrival again. This is the difference between a hole and a
		# continuous event source.
		for key in e.state.keys():
			var ks := String(key)
			if not ks.begins_with("seen_"):
				continue
			var other_id := _parse_seen_key(e.id, ks)
			if other_id == 0 or here.has(other_id):
				continue
			e.set_state(ks, false)


## Relationships that express PROXIMITY or NESTING rather than a connection.
## Present in the graph because a pattern may legitimately ask "what is
## attached to this", and absent from the connectivity check because
## "standing next to it" is not "wired to it".
const NOT_WIRING := [EmergentGraph.ATTACHED_TO, EmergentGraph.CONTAINS,
	EmergentGraph.CONSTRAINS]


const SEEN_PREFIX := "seen_"


## The state key recording that `senser` has seen `occupant`.
static func _seen_key(senser: int, occupant: int) -> String:
	return "%s%d_%d" % [SEEN_PREFIX, senser, occupant]


## Read a `seen_` key back, refusing anything that does not belong to
## `senser`. Parsed rather than stripped, because a key that cannot be
## parsed must be IGNORED rather than guessed at -- an unrecognised key is
## a bug, and treating it as occupant 0 would silently delete another
## entity's arrival flag.
static func _parse_seen_key(senser: int, key: String) -> int:
	if not key.begins_with(SEEN_PREFIX):
		return 0
	var parts := key.substr(SEEN_PREFIX.length()).split("_")
	if parts.size() != 2:
		return 0
	if not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return 0
	if int(parts[0]) != senser:
		return 0
	return int(parts[1])


## What a sensed id is called in the chain text. Entities have names; the
## player does not, and that is fine -- it is recorded separately from the
## observers the game supplies.
func _occupant_name(id: int) -> String:
	var ent := graph.entity(id)
	return ent.kind if ent != null else "player"


## Sensing entities, nearest first. `observer_position` being unset (no
## player yet) puts everything at distance zero, which degrades to
## registration order -- deterministic, and correct if not clever.
func _sense_candidates() -> Array:
	var out: Array = []
	for e in graph.all_entities():
		var ent: EmergentEntity = e
		# Sensors only. Derived from the kind's behaviour rather than from
		# a name list, so a counter standing in the hole does not announce
		# its own arrival and a gate does not fire a second on_entered that
		# cancels the first. See EmergentEntity.is_sensor().
		if not ent.is_sensor():
			continue
		var d := 0.0
		if observer_position != Vector3.INF:
			d = ent.position.distance_to(observer_position)
		out.append({"entity": ent, "d": d})
	out.sort_custom(func(a, b): return float(a["d"]) < float(b["d"]))
	var ids := PackedInt32Array()
	for o in out:
		ids.append(int((o as Dictionary)["entity"].id))
	return _entities_in_order(ids)


func _entities_in_order(ids: PackedInt32Array) -> Array:
	var out: Array = []
	for id in ids:
		var e := graph.entity(int(id))
		if e != null:
			out.append(e)
	return out


## What is inside an entity's radius: other entities, and the observers (the
## player, mobs) the game registered. Sorted by id so two peers agree.
func _occupants_of(e: EmergentEntity) -> Array:
	var out: Array = []
	var ids: Array = []
	for o in graph.all_entities():
		var other: EmergentEntity = o
		if other.id == e.id or not EmergentGraph.SENSES.has(other.kind):
			continue
		if e.position.distance_to(other.position) <= e.radius():
			ids.append(other.id)
	ids.sort()
	for id in ids:
		var oe := graph.entity(int(id))
		if oe != null:
			out.append({"id": oe.id, "name": oe.kind, "node": oe.node_id})
	for o in observers:
		if not (o is Vector3):
			continue
		var p: Vector3 = o
		if e.position.distance_to(p) <= e.radius():
			out.append({"id": -1, "name": "player", "node": 0, "pos": p})
	return out


## The thing a rule should act on: what the rule named, if anything, and the
## event's subject otherwise. A rule that says "do score 1 counter" scores the
## counter; one that says nothing acts on whatever raised the event. The
## distinction is the difference between "this hole scores" and "this hole
## tells the scoreboard", and both are constructions a player should be able
## to make.
static func resolve_target(graph: EmergentGraph, rule: EmergentRules.Rule,
		subject: EmergentEntity) -> EmergentEntity:
	if rule.target_kind == "" and rule.target_id == 0:
		return subject
	if graph == null:
		return null
	if rule.target_id != 0:
		return graph.entity(rule.target_id)
	var ids: Array = []
	for e in graph.all_entities():
		var ent: EmergentEntity = e
		if ent.kind == rule.target_kind:
			ids.append(ent.id)
	ids.sort()
	for id in ids:
		var found := graph.entity(int(id))
		if found != null:
			return found
	return null


## ## Integration
##
## Movable entities move. The physics here is deliberately the smallest thing
## that gives believable consequences: constant deceleration, a floor, and a
## check against the real voxel world when one is available. It is not a
## rigid body solver and it does not pretend to be -- a voxel world with a
## character controller already does not benefit from one, and pretending
## otherwise is how a physics rewrite ends up owning the whole codebase.
func _integrate(dt: float) -> void:
	for e in graph.all_entities():
		var ent: EmergentEntity = e
		if not ent.is_movable() or not ent.enabled:
			continue
		var friction := ent.prop("friction", 0.25)
		# Deceleration is `friction` per second, so the stopping distance of a
		# struck object is velocity / friction -- a number the player can
		# reason about. The earlier 4x made a ball dropped from a realistic
		# swing stop inside three metres, which reads as the ball being
		# glued down rather than as friction.
		ent.velocity = ent.velocity * maxf(0.0, 1.0 - friction * dt)
		if ent.velocity.length_squared() > 0.0001:
			var step := ent.velocity * dt
			var next := ent.position + step
			if world != null and is_instance_valid(world) \
					and _blocked(next):
				ent.velocity = Vector3.ZERO
			else:
				graph.move_entity(ent.id, next)
				stats["moved"] = int(stats["moved"]) + 1
		var travelled := float(ent.get_state("distance", 0.0))
		ent.set_state("distance", travelled + ent.velocity.length() * dt)


## A position the voxel world says is solid. Kept behind a null check so the
## layer is testable, and testable headlessly, without building a world.
func _blocked(p: Vector3) -> bool:
	if world == null or not is_instance_valid(world):
		return false
	var fp := Vector3i(floorf(p.x), floorf(p.y), floorf(p.z))
	return bool(world.solid_at(fp))


## ## Analysis
##
## Pattern match and compose, for the subjects that changed. Budgeted, and
## when the budget is spent the rest wait for the next tick rather than being
## dropped -- a subject that was not analysed yet simply has no active
## behaviours yet, which is the same state it was in before the player built
## the thing that changed it.
func _analyse_dirty() -> void:
	if _dirty.is_empty():
		return
	var ids: Array = _dirty.keys()
	ids.sort()   # total order: analysis must not depend on dictionary order
	var done := 0
	for id in ids:
		if done >= budget_analysis:
			stats["dropped_analysis"] = int(stats["dropped_analysis"]) + (
				ids.size() - done)
			break
		_dirty.erase(int(id))
		_analyse(int(id))
		done += 1
		stats["analysed"] = int(stats["analysed"]) + 1


## Match the patterns around one subject, check the constraints, compose the
## behaviours, and record why each one is or is not active.
##
## The subject's neighbourhood is the unit of analysis, not the subject. A
## pattern is a statement about a shape, so matching a motor in isolation
## would answer a question nobody asked.
func _analyse(subject: int) -> void:
	if graph == null:
		return
	var entries: Array = []
	var reasons: Array[String] = []
	var pattern_ids: Array[String] = []

	var e := graph.entity(subject)
	var members: Array = []
	if e != null:
		members.append(e.kind)
		# An entity bolted to a node is analysed together with it, which is
		# how a sensor wired into a machine becomes one system.
		if e.node_id != 0:
			members.append_array(_components_near(subject, 3))
		# So is everything it is RELATED to. A pattern is a claim about a
		# shape -- "a goal and something that keeps score" -- and a counter
		# standing alone is half a shape. Without this the zone and the
		# scoreboard are two objects that happen to be within three metres,
		# and the player who put them there gets nothing for it.
		members.append_array(_related_kinds(subject))
	else:
		members.append_array(_components_near(subject, 3))
	if members.is_empty():
		_active[subject] = []
		return

	# Topology is supplied, so a pattern's `chains` are tested as claims about
	# WIRING and not about which parts happen to be in the same pile. See
	# EmergentMatcher.match_assembly.
	for m in EmergentMatcher.match_assembly(members, _holders_for(subject),
			_bound_callable()):
		var mm: EmergentMatcher.Match = m
		if not mm.satisfied:
			continue
		pattern_ids.append(mm.pattern_id)
		var check := EmergentConstraints.evaluate(mm.constraints, graph,
			world, observer_position)
		for b in mm.behaviours:
			entries.append({
				"behaviour": String(b), "subject": subject,
				"pattern": mm.pattern_id, "active": bool(check["ok"]),
				"reason": "" if bool(check["ok"]) else _first_reason(check),
			})
	for r in reasons:
		pass
	_active[subject] = EmergentBehaviors.compose(entries)
	_chains[subject] = _chain_for(subject, pattern_ids)


## capability -> the ids within reach of `subject` that hold it.
##
## This is what lets the matcher test a chain as a claim about WIRING rather
## than about which parts are in the same pile. Node ids and entity ids share
## one int space deliberately, so "the motor" and "the zone bolted to it" are
## both addressable by the same connectivity question.
func _holders_for(subject: int) -> Dictionary:
	var out := {}
	# The subject itself plus everything within reach, deduplicated and
	# sorted. Node ids and entity ids share an int space, so one loop covers
	# both and a zone bolted to a motor is connected to that motor by the
	# ordinary ATTACHED_TO edge.
	var ids: Array = [subject]
	ids.append_array(graph.reachable(subject, 3, 64))
	var sorted: Array = ids.duplicate()
	sorted.sort()
	for raw in sorted:
		var id := int(raw)
		if out.has(id):
			continue
		for c in graph.capabilities_of(id):
			var list: Array = out.get(String(c), [])
			list.append(id)
			out[String(c)] = list
	return out


## Are these two things WIRED to each other? A pure lookup on the DERIVED
## relationships, so it cannot disagree with the graph the rest of the layer
## reads. Direct adjacency only, NOT transitive reach: a chain pattern asks
## about specific ends, and letting a reachability walk answer it would make
## "supplier reaches driver" true through a third part that has nothing to do
## with either.
##
## `attached_to` is deliberately NOT a connection. It means "these two parts
## are standing near each other", which is real and useful and says nothing
## about power or rotation -- and three parts in a row on a bench are all
## mutually attached. Counting that as wiring made a disconnected motor pass
## the `machine` chain purely because a battery was within arm's reach.
func _bound_callable() -> Callable:
	return func(a: int, b: int) -> bool:
		if a == b:
			return true
		for r in graph.relatives(a, "", 64):
			var d: Dictionary = r
			if int(d["other"]) != b:
				continue
			if NOT_WIRING.has(String(d["rel"])):
				continue
			return true
		return false


## The exact membership list analysis uses for a subject. Exposed so the
## diagnostic view reports the SAME match the engine acted on -- a viewer that
## re-derived its own membership could disagree with the engine, and then it
## would be showing the player a fiction.
func members_of(subject: int) -> Array:
	var e := graph.entity(subject)
	if e == null:
		return _components_near(subject, 3)
	var members: Array = [e.kind]
	if e.node_id != 0:
		members.append_array(_components_near(subject, 3))
	members.append_array(_related_kinds(subject))
	return members


## The kinds of everything related to a subject, sorted and deduplicated.
## Bounded at eight so a hub cannot pull the whole world into one analysis,
## and sorted so two clients build the same member list from the same graph.
func _related_kinds(subject: int) -> Array:
	var out := {}
	var ids: Array = []
	for r in graph.relatives(subject, "", 8):
		ids.append(int((r as Dictionary)["other"]))
	ids.sort()
	for id in ids:
		var other := graph.entity(int(id))
		if other != null:
			out[other.kind] = true
	var kinds: Array = []
	for k in out.keys():
		kinds.append(String(k))
	kinds.sort()
	return kinds


## Components within `depth` hops of `subject`, INCLUDING `subject` itself, as
## component ids. Bounded: a hub node must not drag the whole factory into one
## analysis.
##
## The subject is included because `reachable()` starts by stepping away, and
## a pattern's `min_members` counts the thing being matched. Without this a
## three-part machine was analysed as a two-part assembly and no pattern with
## a floor of three could ever match it -- the analysis was quietly dropping
## the part the player was looking at.
func _components_near(subject: int, depth: int) -> Array:
	var src := graph.source()
	if src == null:
		return []
	var out: Array = []
	var here: EngGraph.EngNode = src.node(subject)
	if here != null:
		out.append(here.component_id)
	for id in graph.reachable(subject, depth, 32):
		var n: EngGraph.EngNode = src.node(int(id))
		if n != null:
			out.append(n.component_id)
	out.sort()
	return out


static func _first_reason(check: Dictionary) -> String:
	for r in check.get("results", []):
		var d: Dictionary = r
		if not bool(d["ok"]):
			return "%s: %s" % [String(d["name"]), String(d["reason"])]
	return "unknown"


## The chain a subject went through, reconstructed rather than remembered.
## Reconstructing means the diagnostic view cannot show a chain that did not
## happen.
func _chain_for(subject: int, pattern_ids: Array[String]) -> Array:
	var chain: Array = []
	var e := graph.entity(subject)
	chain.append("INPUT: %s" % ("entity %s" % e.kind if e != null
		else "node %d" % subject))
	var caps := graph.capabilities_within(subject, 2, 32)
	chain.append("CONDITION: capabilities [%s]" % ", ".join(caps))
	var sorted_patterns := pattern_ids.duplicate()
	sorted_patterns.sort()
	chain.append("TRANSFORMATION: patterns [%s]"
		% ", ".join(sorted_patterns))
	var states: Array = []
	for a in _active.get(subject, []):
		var d: Dictionary = a
		if bool(d.get("active", false)):
			states.append(String(d["behaviour"]))
	var active_list := PackedStringArray()
	for s in states:
		active_list.append(String(s))
	active_list.sort()
	chain.append("STATE: behaviours [%s]" % ", ".join(active_list))
	chain.append("EVENT: %s" % EmergentCausal.ENTERED)
	return chain


func _record_chain(e: EmergentEntity, step: String) -> void:
	e.set_state("last_step", step)


# --- queries ---------------------------------------------------------------

func active_for(subject: int) -> Array:
	return _active.get(subject, [])


func causal_chain(subject: int) -> Array:
	return _chains.get(subject, [])


func entity_at(kind: String) -> EmergentEntity:
	var ids: Array = []
	for e in graph.all_entities():
		ids.append(int((e as EmergentEntity).id))
	ids.sort()
	for id in ids:
		var ent := graph.entity(int(id))
		if ent != null and ent.kind == kind:
			return ent
	return null


## Every behaviour currently active anywhere, with the subject it belongs to.
## What "this world is doing" means, in one query.
func active_behaviours() -> Array:
	var out: Array = []
	for subject in _active.keys():
		for a in _active[subject]:
			var d: Dictionary = a
			if bool(d.get("active", false)):
				out.append({"subject": int(subject),
					"behaviour": String(d["behaviour"]),
					"pattern": String(d.get("pattern", ""))})
	out.sort_custom(_by_behaviour)
	return out


## Sorted by behaviour name, then subject, so the list is identical on two
## machines. A total order, not an incidental one.
static func _by_behaviour(x: Dictionary, y: Dictionary) -> bool:
	var bx := String(x["behaviour"])
	var by := String(y["behaviour"])
	if bx != by:
		return bx < by
	return int(x["subject"]) < int(y["subject"])


func report() -> String:
	return EmergentDiagnostics.summarize(self)


func graph_text(limit := 64) -> String:
	return EmergentDiagnostics.graph_dump(graph, limit)


func inspect(subject: int) -> String:
	return EmergentDiagnostics.inspect(self, subject)


# --- gameplay helpers ------------------------------------------------------

## The player hit something. This is the "player swings the club" half of a
## golf hole, and it is a HOOK rather than a golf method: it reports an
## impulse against whatever is nearby, and a pattern decides that this means
## "struck".
##
## Returns what was struck, so the caller can report it.
func strike(origin: Vector3, direction: Vector3, power := 6.0,
		radius := 2.5) -> Array:
	var struck: Array = []
	for e in graph.entities_near(origin, radius):
		var ent: EmergentEntity = e
		if not ent.is_movable() or not ent.enabled:
			continue
		ent.velocity += direction.normalized() * power
		struck.append(ent)
		causal.emit_event("on_struck", ent.id, power)
	return struck


## Multiplayer. Every mutation a client asks for goes through the authority,
## which re-derives it server-side. The closure is what actually touches the
## world, and it runs only after every check has passed -- the same contract
## the engineering layer uses, for the same reason.
func submit(peer_id: int, command: Dictionary) -> Dictionary:
	if authority == null or not is_instance_valid(authority):
		return {"ok": false, "reason": "no authority attached",
			"result": null, "peer": peer_id}
	var apply := func(cmd: Dictionary) -> Variant:
		return _apply_command(cmd)
	return authority.submit(peer_id, command, apply)


## The mutation itself. Server-side only, and deliberately small: place an
## entity, remove one, add a rule. Anything that would need world knowledge
## belongs in the engineering layer, which already has an op for it.
##
## Every branch reports `ok` and a reason, because that is the contract
## `NetAuthority` uses to decide whether a command that was charged for
## actually happened: a handler that reports a bare `{"entity": 0}` cannot be
## told apart from one that refused, so a failed placement would keep the
## player's money.
func _apply_command(cmd: Dictionary) -> Variant:
	match String(cmd.get("op", "")):
		"emergent_place":
			var kind := String(cmd.get("kind", ""))
			if not EmergentEntity.has_kind(kind):
				return {"ok": false, "reason": "no entity kind '%s'" % kind}
			var eid := graph.add_entity(kind, cmd.get("position", Vector3.ZERO),
				int(cmd.get("node", 0)))
			if eid < 0:
				return {"ok": false, "reason": "'%s' could not be placed" % kind}
			return {"ok": true, "reason": "", "entity": eid}
		"emergent_remove":
			var id := int(cmd.get("entity", 0))
			if not graph.remove_entity(id):
				return {"ok": false, "reason": "no entity %d" % id}
			return {"ok": true, "reason": "", "removed": id}
		"emergent_rule":
			var r := EmergentRules.add_text(String(cmd.get("text", "")))
			var err := String(r.get("error", ""))
			if not err.is_empty():
				return {"ok": false, "reason": err}
			return {"ok": true, "reason": "", "id": int(r.get("id", 0))}
		_:
			return null


## What a client is told. Entities and rules only -- the relationships,
## patterns and behaviours are reconstructed on the receiving side rather
## than transmitted, so there is no derived data on the wire to disagree.
func snapshot_for(_peer_id: int, distance: float) -> Dictionary:
	var out: Array = []
	var ids: Array = []
	for e in graph.all_entities():
		ids.append(int((e as EmergentEntity).id))
	ids.sort()
	for id in ids:
		var e := graph.entity(int(id))
		if e == null:
			continue
		if distance > 0.0 and e.position.distance_to(observer_position) > distance:
			continue
		out.append(e.to_dict())
	return {"entities": out, "rules": EmergentRules.serialize()}


# --- persistence -----------------------------------------------------------

func serialize() -> Dictionary:
	return EmergentPersistence.capture(self)


func deserialize(data: Dictionary) -> Dictionary:
	return EmergentPersistence.restore(self, data)


func _release() -> void:
	if graph != null:
		graph.clear()
	if causal != null:
		causal.reset()
	_active.clear()
	_chains.clear()
	_dirty.clear()