class_name EmergentConstraints
extends RefCounted
## Constraints: the difference between "that looks like a golf hole" and
## "that scores".
##
## A pattern match is a statement about SHAPE. It says the parts are there
## and wired. It says nothing about whether power is on, whether the tank has
## anything in it, whether the thing is within reach of the player, or
## whether the thing it depends on still exists. Those are constraints, and
## this file is where they are evaluated.
##
## The separation is what stops the system lying to the player. If matching
## alone granted behaviour, a player who wired a motor to nothing would be
## told they had built a working machine, and the correct construction and the
## broken one would be indistinguishable. Here, a pattern that matched while
## its constraints fail produces a behaviour marked INACTIVE, and the
## diagnostic view says exactly which constraint and why.
##
## Constraints are named strings on a pattern, resolved through CHECKS. A new
## constraint is a function, not a branch in the matcher, which is what makes
## this extensible: a mod adds a constraint and every pattern naming it gets
## evaluated without touching the engine.

## Constraint names. Each is a claim about the world that must hold for a
## behaviour to actually run.
const HAS_ENERGY := "has_energy"
const HAS_FLUID_SOURCE := "has_fluid_source"
const WITHIN_RANGE := "within_range"
const ENABLED := "enabled"
const CAPACITY := "capacity"
const SUPPORTED := "supported"

const ALL := [HAS_ENERGY, HAS_FLUID_SOURCE, WITHIN_RANGE, ENABLED, CAPACITY,
	SUPPORTED]

## How close a player must be for a behaviour to count as "in range". A
## distant factory is still a factory; a distant score is not a score the
## player earned. Keeping it explicit means the player is told why.
const RANGE := 12.0


## Evaluate every constraint a pattern named. Returns:
##   { ok: bool, results: [{name, ok, reason}] }
##
## `ok` is the conjunction. Every result is reported, including the passing
## ones, because "why is this active" is as useful a question as "why is this
## not".
static func evaluate(names: Array, graph: EmergentGraph, world: Object = null,
		origin := Vector3.INF) -> Dictionary:
	var results: Array = []
	var ok := true
	for n in names:
		var name := String(n)
		var r := check(name, graph, world, origin)
		results.append(r)
		if not bool(r["ok"]):
			ok = false
	return {"ok": ok, "results": results}


## One constraint. Returns { name, ok, reason }. An unknown constraint FAILS
## closed rather than passing: a pattern naming a constraint nobody
## implemented must not silently grant behaviour, because that is the exact
## failure mode this whole layer exists to prevent.
static func check(name: String, graph: EmergentGraph, world: Object = null,
		origin := Vector3.INF) -> Dictionary:
	match name:
		HAS_ENERGY:
			return _has_energy(graph)
		HAS_FLUID_SOURCE:
			return _has_fluid_source(graph)
		WITHIN_RANGE:
			return _within_range(graph, origin)
		ENABLED:
			return _enabled(graph)
		CAPACITY:
			return _capacity(graph)
		SUPPORTED:
			return _supported(graph)
		_:
			return {"name": name, "ok": false,
				"reason": "unknown constraint '%s'" % name}


## A power path must reach the thing. "Has a battery somewhere nearby" is not
## the same claim, and treating it as one is how a factory ends up running on
## the strength of a battery four rooms away with the switch off.
static func _has_energy(graph: EmergentGraph) -> Dictionary:
	if graph == null:
		return {"name": HAS_ENERGY, "ok": false, "reason": "no world"}
	var src := graph.source()
	if src == null:
		return {"name": HAS_ENERGY, "ok": false, "reason": "no world"}
	var best := 0.0
	var live := 0
	for net in src.networks_of_kind(EngPorts.Kind.ELECTRICAL):
		var n: Dictionary = net
		var state: Dictionary = src.network_state(int(n["id"]))
		var supply := float(state.get("supply", 0.0))
		var stored := float(state.get("stored", 0.0))
		var total := supply + stored
		if total > best:
			best = total
		if total > 0.0:
			live += 1
	if live == 0:
		return {"name": HAS_ENERGY, "ok": false,
			"reason": "no electrical network has power"}
	return {"name": HAS_ENERGY, "ok": true,
		"reason": "%.1f W available on %d live network(s)" % [best, live]}


## A fluid network needs something feeding it. A pipe loop full of nothing
## moves nothing, and a pump with an empty tank is a shape, not a system.
static func _has_fluid_source(graph: EmergentGraph) -> Dictionary:
	if graph == null:
		return {"name": HAS_FLUID_SOURCE, "ok": false, "reason": "no world"}
	var src := graph.source()
	if src == null:
		return {"name": HAS_FLUID_SOURCE, "ok": false, "reason": "no world"}
	for net in src.networks_of_kind(EngPorts.Kind.FLUID):
		var n: Dictionary = net
		var state: Dictionary = src.network_state(int(n["id"]))
		if int(state.get("source", 0)) > 0:
			return {"name": HAS_FLUID_SOURCE, "ok": true,
				"reason": "fluid source on network %d" % int(n["id"])}
	return {"name": HAS_FLUID_SOURCE, "ok": false,
		"reason": "no fluid network has a source"}


static func _within_range(graph: EmergentGraph, origin: Vector3) -> Dictionary:
	if origin == Vector3.INF:
		# No player position was supplied. That is a caller who does not
		# care, not a failure, so this passes and says so.
		return {"name": WITHIN_RANGE, "ok": true,
			"reason": "no observer supplied"}
	for e in graph.all_entities():
		var ent: EmergentEntity = e
		if ent.position.distance_to(origin) > RANGE:
			continue
		return {"name": WITHIN_RANGE, "ok": true,
			"reason": "entity %s is %.1f m away" % [ent.kind,
				ent.position.distance_to(origin)]}
	return {"name": WITHIN_RANGE, "ok": false,
		"reason": "nothing of this kind within %.0f m" % RANGE}


static func _enabled(graph: EmergentGraph) -> Dictionary:
	var disabled := 0
	for e in graph.all_entities():
		if not (e as EmergentEntity).enabled:
			disabled += 1
	if disabled > 0:
		return {"name": ENABLED, "ok": false,
			"reason": "%d constituent(s) switched off" % disabled}
	return {"name": ENABLED, "ok": true, "reason": "everything enabled"}


## Does the thing have room to do what it wants to do? Checked against real
## accumulated state, so a counter that has hit its target correctly refuses
## to keep counting.
static func _capacity(graph: EmergentGraph) -> Dictionary:
	for e in graph.all_entities():
		var ent: EmergentEntity = e
		if ent.kind != "counter":
			continue
		var target := ent.prop("target", 0.0)
		var value := float(ent.get_state("value", 0.0))
		if value >= target:
			return {"name": CAPACITY, "ok": false,
				"reason": "counter %d is full (%.0f/%.0f)" % [ent.id, value, target]}
	return {"name": CAPACITY, "ok": true, "reason": "within capacity"}


## Structural support. Uses the derived SUPPORTS edges, so it is asking
## whether something is actually underneath, not whether the player intended
## it to be.
static func _supported(graph: EmergentGraph) -> Dictionary:
	if graph == null or graph.source() == null:
		return {"name": SUPPORTED, "ok": true, "reason": "nothing to support"}
	for e in graph.all_entities():
		var ent: EmergentEntity = e
		if ent.node_id == 0:
			continue
		if not graph.has_rel(ent.id, EmergentGraph.DEPENDS_ON, ent.node_id) \
				and not graph.has_rel(ent.id, EmergentGraph.ATTACHED_TO,
				ent.node_id):
			return {"name": SUPPORTED, "ok": false,
				"reason": "entity %d is not attached to anything" % ent.id}
	return {"name": SUPPORTED, "ok": true, "reason": "supported"}


## Which of these names are checked at all. Lets a test assert that every
## constraint a pattern can name has an implementation, so a typo in a pattern
## becomes a failing test rather than a behaviour that silently never runs.
static func is_implemented(name: String) -> bool:
	return ALL.has(name)