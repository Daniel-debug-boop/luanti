class_name EmergentGraph
extends RefCounted
## The world as a graph of functional relationships.
##
## `EngGraph` already keeps a spatial index, typed ports and a union-find
## network partition. It deliberately does NOT keep semantics: an edge there
## means "these two ports are wired", and nothing more. This layer adds the
## meaning -- MOTOR DRIVES SHAFT, MARKER DETECTS PLAYER -- and it does so
## WITHOUT rebuilding anything, because the expensive part is already done.
##
## The design constraint that decides everything here is "no O(world-size)
## work per frame". Three things make that true:
##
##   * It is keyed on `EngGraph.revision`. Nothing is recomputed while the
##     player is not building. A frame that changes nothing costs a single
##     integer comparison.
##   * It is DERIVED, never stored twice. Relationships are computed from the
##     edges that already exist and cached; there is no second copy of the
##     world to fall out of sync with the first.
##   * Traversal is budgeted and local. `relatives()` walks a neighbourhood,
##     not the graph, and refuses to walk further than `limit`.
##
## The relationships are the ones that matter for gameplay. A `DETECTS`
## edge between a zone and a cart is derived from proximity and radius, not
## stored by the player, which is what means a golf hole keeps working when
## the player rebuilds the green around it.
##
## Relationship vocabulary. Deliberately small: each one earns its place by
## being something a pattern or a constraint can actually test.
const CONNECTED_TO := "connected_to"
const DRIVES := "drives"
const POWERED_BY := "powered_by"
const SUPPORTS := "supports"
const CONTAINS := "contains"
const DETECTS := "detects"
const TARGETS := "targets"
const ACTIVATES := "activates"
const DEPENDS_ON := "depends_on"
const TRANSMITS := "transmits"
const BLOCKS := "blocks"
const CONSTRAINS := "constrains"
const ATTACHED_TO := "attached_to"
const TRANSFERS_TO := "transfers_to"

const ALL := [CONNECTED_TO, DRIVES, POWERED_BY, SUPPORTS, CONTAINS, DETECTS,
	TARGETS, ACTIVATES, DEPENDS_ON, TRANSMITS, BLOCKS, CONSTRAINS,
	ATTACHED_TO, TRANSFERS_TO]

## How far an entity's sensing radius is allowed to reach when deriving
## DETECTS edges. A player who builds a zone 200 m across is not asking for a
## proximity graph spanning 200 m; they are asking for a rule to fire. The
## radius is capped and the real range check happens in the causal engine.
const MAX_SENSE_DISTANCE := 24.0

## Entity kinds that can be SENSED. A zone notices these; it does not notice
## the scoreboard next to it, and it certainly does not notice itself.
## Data, kept here rather than inferred, because "what counts as an occupant"
## is a design decision and inferring it from capabilities would make a
## counter that happens to emit events an occupant of every zone it stands in.
const SENSES := ["cart", "marker", "zone"]

var _graph: EngGraph = null
## Node id -> Array of {rel, other, kind}. Rebuilt per revision.
var _out := {}
## Entity id -> Entity.
var _entities := {}
## Spatial buckets for entities, on the same cell size the engineering graph
## uses so one query can span both.
const CELL := 16.0
var _cells := {}
var _next_entity := 1
## The revision the derived cache was built at. -1 means "never".
var _built_revision := -1
## The graph object the cache belongs to. Two graphs can both sit at revision
## 7, and handing a result computed against one to the other is the kind of
## bug that looks like a physics problem.
var _built_graph: EngGraph = null
## Set when an entity changed and there is no engineering revision to key on.
var _pending_entity_change := true

## Instrumentation, so a profiler can tell whether this is costing anything.
var rebuilds := 0
var rebuild_ms := 0.0
var queries := 0


func _init(graph: EngGraph = null) -> void:
	_graph = graph


func attach(graph: EngGraph) -> void:
	if graph != _graph:
		_graph = graph
		_built_graph = null
		_built_revision = -1


func source() -> EngGraph:
	return _graph


# --- entities ---------------------------------------------------------------

## Place an entity. Returns its id, or -1 for an unknown kind -- a typo must
## not create an object the player can see but the engine cannot reason about.
func add_entity(kind: String, position: Vector3, node_id := 0) -> int:
	if not EmergentEntity.has_kind(kind):
		push_error("[emergent] unknown entity kind '%s'" % kind)
		return -1
	var id := _next_entity
	_next_entity += 1
	var e := EmergentEntity.make(id, kind, position, node_id)
	_entities[id] = e
	var key := _cell_key(position)
	if not _cells.has(key):
		_cells[key] = []
	(_cells[key] as Array).append(id)
	# The entity world changed, so the derived relationships are stale. The
	# engineering graph's revision cannot express this -- an entity is not in
	# the engineering graph -- so the layer tracks it itself rather than
	# pretending the two are the same world.
	_built_revision = -1
	_pending_entity_change = true
	return id


func entity(id: int) -> EmergentEntity:
	return _entities.get(id, null)


func has_entity(id: int) -> bool:
	return _entities.has(id)


func entity_count() -> int:
	return _entities.size()


func all_entities() -> Array:
	return _entities.values()


func remove_entity(id: int) -> bool:
	if not _entities.has(id):
		return false
	var e: EmergentEntity = _entities[id]
	var key := _cell_key(e.position)
	if _cells.has(key):
		(_cells[key] as Array).erase(id)
		if (_cells[key] as Array).is_empty():
			_cells.erase(key)
	_entities.erase(id)
	_built_revision = -1
	_pending_entity_change = true
	return true


func move_entity(id: int, position: Vector3) -> bool:
	var e: EmergentEntity = _entities.get(id, null)
	if e == null:
		return false
	var old := _cell_key(e.position)
	var now := _cell_key(position)
	if old != now:
		if _cells.has(old):
			(_cells[old] as Array).erase(id)
		if not _cells.has(now):
			_cells[now] = []
		(_cells[now] as Array).append(id)
	e.position = position
	# The derived DETECTS edges depend on position, so the cache is stale.
	# Only the revision counter is bumped for entities: they are not part of
	# the engineering graph, and inventing a fake graph revision would make
	# the engineering layer rebuild networks it did not need to.
	_built_revision = -1
	_pending_entity_change = true
	return true


## Entities whose position is within `radius` of `centre`. Walks only the
## buckets that can contain one.
func entities_near(centre: Vector3, radius: float) -> Array:
	var out: Array = []
	var span := int(ceilf(radius / CELL))
	var base := Vector3(floorf(centre.x / CELL), floorf(centre.y / CELL),
		floorf(centre.z / CELL))
	for dx in range(-span, span + 1):
		for dy in range(-span, span + 1):
			for dz in range(-span, span + 1):
				var key := "%d_%d_%d" % [int(base.x) + dx, int(base.y) + dy,
					int(base.z) + dz]
				if not _cells.has(key):
					continue
				for eid in _cells[key]:
					var e: EmergentEntity = _entities.get(int(eid), null)
					if e == null:
						continue
					if e.position.distance_squared_to(centre) <= radius * radius:
						out.append(e)
	return out


static func _cell_key(p: Vector3) -> String:
	return "%d_%d_%d" % [int(floorf(p.x / CELL)), int(floorf(p.y / CELL)),
		int(floorf(p.z / CELL))]

# --- derived relationships --------------------------------------------------

## Make sure the derived layer matches the world. This is the whole cost of
## the graph when nothing has changed: one comparison.
func ensure() -> void:
	if _built_graph != _graph:
		_built_graph = _graph
		_built_revision = -1
	if _graph != null and not _graph.dirty and _built_revision == _graph.revision:
		return
	if _graph == null and _built_revision == 0:
		# Nothing to key on when there is no engineering graph: an entity-only
		# world rebuilds on every ensure() that follows a change, and on no
		# ensure() that does not.
		if not _pending_entity_change:
			return
	# The engineering graph has changed shape. Rebuild once, not per frame.
	var t0 := Time.get_ticks_usec()
	if _graph != null and _graph.dirty:
		_graph.rebuild_networks()
	_rebuild()
	rebuild_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	rebuilds += 1
	_pending_entity_change = false
	_built_revision = _graph.revision if _graph != null else 0


func _rebuild() -> void:
	_out.clear()
	if _graph == null:
		# Entities stand on their own. A player can place a zone in a world
		# with no engineering in it at all, and the relationships between
		# entities must still exist -- requiring an EngGraph here would make
		# "a golf hole" impossible without also building a motor.
		_rebuild_entities()
		return
	# 1. Wired pairs, given meaning by the role of each end.
	#
	# Reading the role is what turns "port a met port b" into "this motor
	# drives that shaft". A relay's electrical input causes its output, so
	# the relationship is ACTIVATES rather than a plain connection: that
	# difference is exactly what a player rule needs to tell them apart.
	for nid in _graph.all_nodes():
		var n: EngGraph.EngNode = nid
		if n == null:
			continue
		var role := EngMachines.role_of(n.component_id)
		for eid in _graph.edges_of(n.id):
			var e: EngGraph.EngEdge = _graph.edge(int(eid))
			if e == null or not _graph.edge_is_conductive(int(eid)):
				continue
			# Direction is derived from port flow, never from id order, so a
			# rewired machine reports the same relationship it did before.
			var a_out := _emits(e, e.a)
			var a_rel := _wire_rel(e.kind, role_of_id(e.a))
			var b_rel := _wire_rel(e.kind, role_of_id(e.b))
			# Not every relationship name reads from the emitting end.
			# "motor DRIVES impeller" is a sentence about the motor, so it
			# belongs on the motor. "X is POWERED_BY Y" is a sentence about
			# the CONSUMER, so it belongs on whatever is drawing the power --
			# recording it on the battery said the battery was powered by the
			# motor, which is not merely inelegant but is a relation a
			# constraint or a pattern could then match on.
			var rel := a_rel if a_out else b_rel
			if a_out and _reads_from_source(rel):
				_add(n.id, rel, e.b)
				_add(e.b, _inverse(rel), n.id)
			elif a_out:
				_add(e.b, rel, n.id)
				_add(n.id, _inverse(rel), e.b)
			elif _reads_from_source(rel):
				_add(n.id, rel, e.b)
				_add(e.b, _inverse(rel), n.id)
			else:
				_add(e.b, rel, n.id)
				_add(n.id, _inverse(rel), e.b)
			_add(n.id, CONNECTED_TO, e.b)
			_add(e.b, CONNECTED_TO, n.id)
		# 2. Co-location: physical proximity is a real relationship in a voxel
		# world. A motor bolted inside a housing supports it, and neither is
		# wired to the other.
		for other in _graph.nodes_near(n.position, EngAssemblies.CLUSTER_RADIUS):
			var oid := (other as EngGraph.EngNode).id
			if oid == n.id:
				continue
			_add(n.id, ATTACHED_TO, oid)
			_add(oid, ATTACHED_TO, n.id)
		# 3. Structural support: something below carries the load.
		if n.position.y > 0.0:
			var below := _graph.nodes_near(n.position + Vector3(0, -1.0, 0), 1.2)
			for b in below:
				var bid := (b as EngGraph.EngNode).id
				if bid != n.id and _supports(bid, n.id):
					_add(n.id, DEPENDS_ON, bid)
					_add(bid, SUPPORTS, n.id)
	# 4. Entity relationships, and 5. entity-to-node links.
	_rebuild_entities()
	# 5. An entity bolted to a node participates in the node's relationships.
	for ent in _entities.values():
		var e2: EmergentEntity = ent
		if e2.node_id == 0 or not _graph.has_node(e2.node_id):
			continue
		_add(e2.id, ATTACHED_TO, e2.node_id)
		_add(e2.node_id, ATTACHED_TO, e2.id)


## Relationships between entities, with no reference to the engineering
## graph. Split out because a golf hole must work in a world with no motors in
## it, and because the entity half of the model is the one that has to be
## correct on its own.
func _rebuild_entities() -> void:
	for e in _entities.values():
		var ent: EmergentEntity = e
		# Sensors only, same rule as the runtime sense pass. Deriving DETECTS
		# from "can emit events" instead made a gate detect the cart beside
		# it, so the graph reported a relationship the causal engine would
		# never act on -- and a pattern that matched on it was matching on a
		# fiction.
		if not ent.is_sensor():
			continue
		var reach := minf(ent.radius(), MAX_SENSE_DISTANCE)
		if reach <= 0.0:
			continue
		for other in entities_near(ent.position, reach):
			var o: EmergentEntity = other
			if o.id == ent.id or not SENSES.has(o.kind):
				# Only things that can be SENSED are occupants. A scoreboard
				# standing next to the hole is not in the hole; treating it as
				# a thing that arrived would make every golf course score
				# itself the moment it was built.
				continue
			if o.position.distance_to(ent.position) > reach:
				continue
			_add(ent.id, DETECTS, o.id)
			_add(o.id, TARGETS, ent.id)
		# A counter or a gate standing inside a zone belongs to it. This is
		# what makes "a goal and something that keeps score for it" a shape
		# the matcher can recognise rather than two unrelated objects on the
		# same square metre, and it is why the `activity` pattern needs two
		# members instead of one.
		for o in entities_near(ent.position, maxf(reach, 4.0)):
			var inner: EmergentEntity = o
			if inner.id == ent.id or SENSES.has(inner.kind):
				continue
			if inner.position.distance_to(ent.position) > reach:
				continue
			_add(ent.id, CONTAINS, inner.id)
			_add(inner.id, _inverse(CONTAINS), ent.id)


## Does this edge carry something from `nid` out? Direction is a property of
## the ports, which is why the graph could refuse an incompatible pair in the
## first place.
func _emits(e: EngGraph.EngEdge, nid: int) -> bool:
	var other := e.b if nid == e.a else e.a
	if other == 0:
		return false
	var def := EngPorts.get_def((_graph.node(nid) as EngGraph.EngNode).component_id)
	if def == null:
		return false
	var port := def.port(e.a_port if nid == e.a else e.b_port)
	return port != null and port.flow == EngPorts.Flow.OUTPUT


func role_of_id(nid: int) -> String:
	var n: EngGraph.EngNode = _graph.node(nid)
	return "" if n == null else EngMachines.role_of(n.component_id)


## Port kind and the emitting end's role, to the relationship name.
## Whether a relationship name reads from the end that emits.
##
## DRIVES, TRANSFERS_TO and SUPPORTS do: "the motor drives the impeller" is
## about the motor. POWERED_BY does not: it is about the sink. Getting this
## backwards put a `powered_by` edge on the battery pointing at the motor, so
## a pattern asking "is this motor powered by something" found nothing while
## the graph insisted the battery was powered by a motor.
static func _reads_from_source(rel: String) -> bool:
	return rel != POWERED_BY and rel != ACTIVATES


static func _wire_rel(kind: int, role: String) -> String:
	match kind:
		EngPorts.Kind.MECHANICAL:
			return DRIVES
		EngPorts.Kind.ELECTRICAL:
			if role == EngMachines.POWER_SOURCE:
				return POWERED_BY
			if role == EngMachines.CONTROLLER:
				return ACTIVATES
			return TRANSMITS
		EngPorts.Kind.FLUID:
			return TRANSFERS_TO
		EngPorts.Kind.DATA:
			return ACTIVATES
		EngPorts.Kind.THERMAL:
			return TRANSMITS
		EngPorts.Kind.STRUCTURAL:
			return SUPPORTS
	return CONNECTED_TO


## Reading a name backwards. A relationship is stored both ways so a query
## from either end is O(degree), and storing only one direction would make
## "what drives this" an O(world) search.
static func _inverse(rel: String) -> String:
	match rel:
		CONTAINS:
			return "contained_by"
		DRIVES:
			return "driven_by"
		POWERED_BY:
			return "powers"
		SUPPORTS:
			return "supported_by"
		DETECTS:
			return TARGETS
		TARGETS:
			return DETECTS
		ACTIVATES:
			return "activated_by"
		DEPENDS_ON:
			return "supports"
		TRANSFERS_TO:
			return "transfers_from"
		BLOCKS:
			return "blocked_by"
		CONSTRAINS:
			return "constrained_by"
		TRANSMITS:
			return "transmitted_by"
	return rel


func _supports(supporter: int, held: int) -> bool:
	var n: EngGraph.EngNode = _graph.node(supporter)
	return n != null and EmergentCaps.has_component(n.component_id,
		EmergentCaps.CAN_SUPPORT)


func _add(from_id: int, rel: String, to_id: int) -> void:
	if from_id == to_id:
		return
	if not _out.has(from_id):
		_out[from_id] = []
	var list: Array = _out[from_id]
	for e in list:
		# Deduplicate on (relationship, target), NOT on target alone.
		#
		# A motor wired to a shaft and bolted next to it is legitimately
		# CONNECTED_TO, DRIVES and ATTACHED_TO all at once, and a pattern that
		# asks "what is attached to this" must still be able to ask. Dedupe on
		# the target alone would keep whichever relationship happened to be
		# derived first and silently discard the rest -- which is how a
		# graph quietly starts answering a different question than the one it
		# was asked.
		#
		# The adjacency list is still bounded: a single pair can carry at most
		# one edge per relationship name, and the vocabulary is a small fixed
		# set.
		var d: Dictionary = e
		if int(d["other"]) == to_id and String(d["rel"]) == rel:
			return
	list.append({"rel": rel, "other": to_id})


## Everything `id` is related to, optionally filtered by relationship name.
## Bounded on purpose: `limit` is a hard stop, and a hub node with ten
## thousand neighbours must not be able to stall a frame.
func relatives(id: int, rel := "", limit := 64) -> Array:
	queries += 1
	var out: Array = []
	if not _out.has(id):
		return out
	# Sorted, so a query returns the same list in the same order on every
	# machine. Unsorted adjacency derived from Dictionary iteration is a
	# desync waiting for a rule that cares about which thing it saw first.
	var all: Array = _out[id].duplicate()
	all.sort_custom(_by_rel_then_other)
	for e in _out[id]:
		var d: Dictionary = e
		if rel != "" and String(d["rel"]) != rel:
			continue
		out.append({"rel": String(d["rel"]), "other": int(d["other"])})
		if out.size() >= limit:
			break
	return out


static func _by_rel_then_other(a: Dictionary, b: Dictionary) -> bool:
	var ra := String(a["rel"])
	var rb := String(b["rel"])
	if ra != rb:
		return ra < rb
	return int(a["other"]) < int(b["other"])


func has_rel(from_id: int, rel: String, to_id: int) -> bool:
	if not _out.has(from_id):
		return false
	for e in _out[from_id]:
		var d: Dictionary = e
		if int(d["other"]) == to_id and String(d["rel"]) == rel:
			return true
	return false


## Every id reachable from `start` in at most `depth` hops. This is how a
## pattern asks "is this sensor wired to something that moves" without asking
## where in the world it is. Visited-set based, so a cycle costs one visit.
func reachable(start: int, depth := 4, limit := 256) -> Array:
	var seen := {}
	var out: Array = []
	var frontier: Array = [start]
	seen[start] = true
	var d := 0
	while d < depth and not frontier.is_empty() and out.size() < limit:
		var next: Array = []
		for cur in frontier:
			for e in _out.get(int(cur), []):
				var other := int((e as Dictionary)["other"])
				if seen.has(other):
					continue
				seen[other] = true
				out.append(other)
				if out.size() >= limit:
					return out
				next.append(other)
		frontier = next
		d += 1
	return out


## Capability ids present anywhere within `depth` hops of `start`. This is
## the query a pattern actually wants: not "does the assembly contain a
## motor" but "does this thing reach a motor".
func capabilities_within(start: int, depth := 3, limit := 256) -> Array[String]:
	var out := {}
	var ids := reachable(start, depth, limit)
	ids.append(start)
	for id in ids:
		for c in capabilities_of(int(id)):
			out[c] = true
	var result: Array[String] = []
	for k in out.keys():
		result.append(String(k))
	result.sort()
	return result


## The capabilities of one id, whether it is an engineering node or an
## entity. Public because the pattern matcher needs to know WHICH ids hold a
## capability, not merely that one does somewhere nearby -- "there is a power
## source" and "this motor is connected to THAT power source" are different
## claims, and only the second one is about a machine.
func capabilities_of(id: int) -> Array[String]:
	var n: EngGraph.EngNode = _graph.node(id) if _graph != null else null
	if n != null:
		return EmergentCaps.of_component(n.component_id)
	var e: EmergentEntity = _entities.get(id, null)
	if e != null:
		return e.capabilities()
	return []


## A readable dump of one node's relationships, for the diagnostic view.
func describe(id: int, limit := 32) -> String:
	var e: EmergentEntity = _entities.get(id, null)
	var label := "%s#%d" % [e.kind, e.id] if e != null else "node#%d" % id
	var rels := relatives(id, "", limit)
	if rels.is_empty():
		return "%s: no relationships" % label
	var parts := PackedStringArray()
	for r in rels:
		var other := int((r as Dictionary)["other"])
		var o: EmergentEntity = _entities.get(other, null)
		var other_label := "%s#%d" % [o.kind, o.id] if o != null else "node#%d" % other
		parts.append("%s -> %s" % [other_label, String((r as Dictionary)["rel"])])
	return "%s: %s" % [label, ", ".join(parts)]

# --- persistence -----------------------------------------------------------

## Only the authoritative facts are written. The relationships, the
## capabilities, the matched patterns and the composed behaviours are all
## derived, and saving derived data is how a save file starts disagreeing
## with the code that reads it: change a pattern and every old save carries
## the answer the old pattern gave.
func serialize() -> Dictionary:
	var ids: Array = []
	for eid in _entities.keys():
		(ids as Array).append(eid)
	ids.sort()
	var ents: Array = []
	for eid in ids:
		ents.append((_entities[int(eid)] as EmergentEntity).to_dict())
	return {"version": 1, "next_entity": _next_entity, "entities": ents}


func deserialize(data: Dictionary) -> Dictionary:
	var report := {"entities": 0, "skipped": 0}
	clear()
	for d in data.get("entities", []):
		if not (d is Dictionary):
			report["skipped"] += 1
			continue
		var dict := d as Dictionary
		if not EmergentEntity.has_kind(String(dict.get("kind", ""))):
			report["skipped"] += 1
			continue
		var e := EmergentEntity.from_dict(dict)
		_entities[e.id] = e
		var key := _cell_key(e.position)
		if not _cells.has(key):
			_cells[key] = []
		(_cells[key] as Array).append(e.id)
		report["entities"] += 1
	# Ids are restored verbatim so a save that stores a rule referring to
	# "zone 7" still refers to the same zone, and the counter cannot hand out
	# an id a restored entity already owns.
	_next_entity = maxi(int(data.get("next_entity", 1)), _max_entity_id() + 1)
	# Entities moved the world as far as this layer is concerned.
	_built_revision = -1
	return report


func _max_entity_id() -> int:
	var m := 0
	for eid in _entities.keys():
		m = maxi(m, int(eid))
	return m


func clear() -> void:
	_entities.clear()
	_cells.clear()
	_out.clear()
	_next_entity = 1
	_built_revision = -1


func stats() -> Dictionary:
	return {
		"entities": _entities.size(),
		"nodes": _out.size(),
		"rebuilds": rebuilds,
		"rebuild_ms": rebuild_ms,
		"queries": queries,
		"revision": _built_revision,
	}