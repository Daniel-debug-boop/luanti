class_name EngAssemblies
extends RefCounted
## Assembly System: recognise what the player has built, from its structure.
##
## There is no pump recipe. A pump is recognised because there is a motor, an
## impeller and a housing, the impeller shares a mechanical network with the
## motor, and something is left over that can move fluid. Every one of those
## conditions is a line of data in a definition, and a mod can add a new one
## without touching this file.
##
## The equally important half of the design: recognition never *gates*
## anything. The simulation runs off component roles, so a player who wires
## six motors and three impellers into a shape nobody named still gets three
## working pumps. Recognition supplies a name, a boundary and a summary -- it
## never decides whether a thing works. That is what makes a strange
## construction a feature rather than a bug.

## One recognised assembly in the world.
class Assembly:
	var id := 0
	## Which definition matched, or "custom" when the structure is legal but
	## unnamed.
	var definition := "custom"
	var name := "custom assembly"
	var node_ids: Array = []
	## Free-form machine state the definition's behaviour owns.
	var state := {}

	func to_dict() -> Dictionary:
		return {"definition": definition, "name": name,
			"nodes": Array(node_ids), "state": state.duplicate(true)}


static func read(id: int, d: Dictionary) -> Assembly:
	var a := Assembly.new()
	a.id = id
	a.definition = String(d.get("definition", "custom"))
	a.name = String(d.get("name", "custom assembly"))
	a.node_ids.assign(d.get("nodes", []))
	var st = d.get("state", {})
	if st is Dictionary:
		a.state = (st as Dictionary).duplicate(true)
	return a

static var _defs := {}
static var _order: Array[String] = []
static var _built := false

## How close two parts must be, in blocks, to count as the same physical
## machine. Two blocks is "touching" in a voxel world, which is exactly the
## intent: a motor inside a housing, an impeller inside a pump body.
const CLUSTER_RADIUS := 2.0


## Register an assembly definition. Everything about the match is in `def`:
##
##   requires        {component_id: minimum count}
##   requires_roles  {EngMachines role: minimum count}
##   needs_network   an EngPorts.Kind every functional member must share
##   exposes         {port kind: minimum count} on ports left unconnected
##   name            what to call it
static func register_assembly(def: Dictionary) -> void:
	_build()
	var id := String(def.get("id", ""))
	if id == "":
		push_error("[assemblies] an assembly needs an id")
		return
	if not _defs.has(id):
		_order.append(id)
	_defs[id] = def.duplicate(true)


static func has(id: String) -> bool:
	_build()
	return _defs.has(id)


static func definition(id: String) -> Dictionary:
	_build()
	return _defs.get(id, {})


static func all_ids() -> Array[String]:
	_build()
	return _order.duplicate()


## Recognise an assembly around `root_id`.
##
## Returns { "id", "name", "recognized", "nodes", "complete", "hint",
## "missing" }.
##
## The two flags mean different things and conflating them would be a lie to
## the player. `complete` is whether the construction FUNCTIONS, and it is
## true for any connected group, because the simulation runs off component
## roles. `recognized` is whether a named definition matched exactly. When
## something is close but not quite -- a motor, a shaft and an impeller with
## no housing -- `hint` names it and `missing` lists what is absent, and the
## machine still works.
static var _cache := {}
static var _cache_revision := -1
## The graph the cache belongs to. Two graphs can each be at revision 7, and
## without this a recognition result from one would be handed back for the
## other -- silently, and with a perfectly plausible-looking answer.
static var _cache_graph: EngGraph = null

## Recognition is a breadth-first walk over the graph plus a spatial query per
## node, which is far too expensive to run every frame for a HUD readout. The
## result only changes when the graph's shape changes, so it is cached against
## the graph's revision counter. A player looking at a machine therefore pays
## for recognition once, on the frame they connect something.
static func recognize(graph: EngGraph, root_id: int,
		max_nodes := 64) -> Dictionary:
	_build()
	var key := "%d:%d" % [root_id, max_nodes]
	if _cache_graph == graph and _cache_revision == graph.revision \
			and _cache.has(key):
		return _cache[key]
	var result := _recognize_uncached(graph, root_id, max_nodes)
	if _cache_graph != graph or _cache_revision != graph.revision:
		_cache.clear()
		_cache_graph = graph
		_cache_revision = graph.revision
	_cache[key] = result
	return result


static func clear_cache() -> void:
	_cache.clear()
	_cache_revision = -1
	_cache_graph = null


static func _recognize_uncached(graph: EngGraph, root_id: int,
		max_nodes := 64) -> Dictionary:
	var root := graph.node(root_id)
	if root == null:
		return _custom([], 0)
	# The candidate set is everything reachable from the root over edges of
	# any kind, plus anything physically co-located with it. Reachability,
	# not radius, is the right neighbourhood: a shaft five components long is
	# one machine, and a motor sitting inside a housing is one machine even
	# though nothing connects them by wire.
	# Recognition reads network membership, so it must never run against a
	# stale partition: a player who connects a pipe and immediately looks at
	# the pump would otherwise be told the plumbing is not attached.
	if graph.dirty:
		graph.rebuild_networks()
	var group := _reachable(graph, root_id, max_nodes)
	var best := _custom(group, root_id)
	var have_named := false
	for id in _order:
		var def: Dictionary = _defs[id]
		var result := _matches(graph, def, group, root_id)
		if bool(result["complete"]):
			# Definitions are ordered most specific first, so the first
			# complete match wins and a broad one never steals a precise name.
			return result
		if not have_named and _worth_hinting(result):
			# Keep the first near-miss only, so the player is told about the
			# closest thing this could become rather than the last one tried.
			# The hint never renames or disables anything: the assembly stays
			# a working custom assembly with an annotation attached.
			have_named = true
			best["hint"] = String(result.get("name", ""))
			best["missing"] = (result.get("missing", []) as Array).duplicate()
	return best


## Whether a partial match is close enough to be worth telling the player
## about. A bare motor should not be told it "needs an impeller and a
## housing": that is noise, not help. A motor with a shaft and an impeller in
## it but no housing is exactly the situation a hint exists for.
static func _worth_hinting(result: Dictionary) -> bool:
	var total := int(result.get("required_total", 0))
	if total <= 0:
		return false
	return int(result.get("required_met", 0)) * 2 >= total


static func _custom(group: Array, root_id: int) -> Dictionary:
	return {"id": "custom", "name": "custom assembly", "recognized": false,
		"nodes": group, "complete": true, "hint": "", "missing": [],
		"root": root_id}


## Everything reachable from `root_id`, following edges AND physical
## co-location. A
## bounded breadth-first walk: the bound is what stops a sprawling factory
## from being pulled into one "assembly" and re-scanned every time.
##
## The proximity step matters as much as the edge step. A motor sits *inside*
## a housing; nothing pipes or wires the two together, and a bolt is what
## holds them. In a voxel game "is this part physically in the same machine"
## is a real question, and the spatial index already answers it cheaply.
static func _reachable(graph: EngGraph, root_id: int, max_nodes: int,
		radius := CLUSTER_RADIUS) -> Array:
	var seen := {root_id: true}
	var out: Array = [root_id]
	var queue: Array = [root_id]
	while not queue.is_empty() and out.size() < max_nodes:
		var cur: int = int(queue.pop_front())
		var cur_node := graph.node(cur)
		for eid in graph.edges_of(cur):
			var e: EngGraph.EngEdge = graph.edge(int(eid))
			if e == null:
				continue
			for nid in [e.a, e.b]:
				var other: int = int(nid)
				if seen.has(other) or not graph.has_node(other):
					continue
				seen[other] = true
				out.append(other)
				queue.append(other)
		if cur_node == null:
			continue
		for n in graph.nodes_near(cur_node.position, radius):
			var other: int = int((n as EngGraph.EngNode).id)
			if seen.has(other) or not graph.has_node(other):
				continue
			seen[other] = true
			out.append(other)
			queue.append(other)
	return out


static func _matches(graph: EngGraph, def: Dictionary, group: Array,
		root: int) -> Dictionary:
	var missing: Array = []
	var counts := {}
	var role_counts := {}
	for nid in group:
		var n := graph.node(int(nid))
		if n == null:
			continue
		counts[n.component_id] = int(counts.get(n.component_id, 0)) + 1
		var r := EngMachines.role_of(n.component_id)
		if r != EngMachines.ROLE_NONE:
			role_counts[r] = int(role_counts.get(r, 0)) + 1

	var requires: Dictionary = def.get("requires", {})
	for cid in requires.keys():
		var want := int(requires[cid])
		var have := int(counts.get(String(cid), 0))
		if have < want:
			missing.append("%s x%d" % [String(cid), want - have])
	var requires_roles: Dictionary = def.get("requires_roles", {})
	for r in requires_roles.keys():
		var want := int(requires_roles[r])
		var have := int(role_counts.get(String(r), 0))
		if have < want:
			missing.append("%s x%d" % [String(r), want - have])
	var total := requires.size() + requires_roles.size()
	# Only the distinctive components count toward the hint threshold. A role
	# requirement is satisfied by any motor, so counting it would mean every
	# bare motor on the map was told it was "almost a fan".
	var met := 0
	for cid in requires.keys():
		if int(counts.get(String(cid), 0)) >= int(requires[cid]):
			met += 1
	if not missing.is_empty():
		return {"id": String(def.get("id", "")), "name": String(def.get("name", "")),
			"nodes": group, "complete": false, "missing": missing, "root": root,
			"required_total": requires.size(), "required_met": met}

	# The "it has to actually be connected" test. This is what stops a motor
	# merely standing next to a pump from counting as one, and it is the
	# reason recognition can never be satisfied by proximity alone.
	#
	# The rule is "at least one functioning member is on a network of this
	# kind, and all of the ones that are share the same one". It is not
	# "every member is", because a real machine legitimately spans networks:
	# a motor is on a power bus and a shaft train, and only one of those is
	# the fluid network a pump needs to be recognised.
	if def.has("needs_network"):
		var need_kind := int(def["needs_network"])
		if not _shares_network(graph, group, need_kind):
			missing.append("a shared %s network" % EngPorts.kind_name(need_kind))
	if not missing.is_empty():
		return {"id": String(def.get("id", "")), "name": String(def.get("name", "")),
			"nodes": group, "complete": false, "missing": missing, "root": root,
			"required_total": requires.size(), "required_met": met}

	# "touches": the assembly must reach into a network of one of these
	# kinds through at least one of its parts. This is how a pump is
	# distinguished from a fan: the shaft is the same either way, but only
	# one of them has plumbing attached.
	var touches: Array = def.get("touches", [])
	if not touches.is_empty():
		var found := false
		for k in touches:
			if _shares_network(graph, group, int(k), true):
				found = true
				break
		if not found:
			var names := PackedStringArray()
			for k in touches:
				names.append(EngPorts.kind_name(int(k)))
			missing.append("something on the %s network" % " or ".join(names))
	if not missing.is_empty():
		return {"id": String(def.get("id", "")), "name": String(def.get("name", "")),
			"nodes": group, "complete": false, "missing": missing, "root": root,
			"required_total": requires.size(), "required_met": requires.size()}

	return {"id": String(def.get("id", "")), "name": String(def.get("name", "")),
		"recognized": true, "nodes": group, "complete": true, "hint": "",
		"missing": [], "root": root}


## Whether the group has a functioning member on a network of `kind`, and
## every such member shares that one network. `any_member` also counts parts
## with no role, which is what lets a length of pipe attached to a pump count
## as the pump having plumbing.
static func _shares_network(graph: EngGraph, group: Array, kind: int,
		any_member := false) -> bool:
	if kind < 0:
		return true
	var reference := 0
	for nid in group:
		var n := graph.node(int(nid))
		if n == null:
			continue
		if not any_member and EngMachines.role_of(n.component_id) == \
				EngMachines.ROLE_NONE:
			continue
		var net := graph.network_of(int(nid), kind)
		if net == 0:
			continue
		if reference == 0:
			reference = net
		elif net != reference:
			return false
	return reference != 0


## Count ports of `kind` on the group's boundary: ports that exist but are not
## consumed by another member of the same group. Those are the assembly's
## external interface.
static func _free_boundary_ports(graph: EngGraph, group: Array, kind: int) -> int:
	var inside := {}
	for nid in group:
		inside[int(nid)] = true
	var n := 0
	for nid in group:
		var node_ref := graph.node(int(nid))
		if node_ref == null:
			continue
		var def := EngPorts.get_def(node_ref.component_id)
		if def == null:
			continue
		for p in def.ports:
			var port: EngPorts.Port = p
			if port.kind != kind:
				continue
			var eid := graph.edge_on(int(nid), port.name)
			if eid < 0:
				n += 1
				continue
			var e := graph.edge(int(eid))
			if e == null:
				n += 1
				continue
			var other: int = e.a if int(e.b) == int(nid) else int(e.b)
			if not inside.has(other):
				n += 1
	return n


## Human-readable summary of what is missing, for the in-world prompt. Not a
## crafting recipe: it is an inspection result, and it only ever appears as a
## hint alongside something that already works.
static func describe_missing(result: Dictionary) -> String:
	var missing: Array = result.get("missing", [])
	if missing.is_empty():
		return ""
	return "needs %s" % ", ".join(PackedStringArray(missing))


## A label for the in-world readout of any node.
static func label_for(graph: EngGraph, node_id: int) -> String:
	var r := recognize(graph, node_id)
	if bool(r["complete"]) and String(r["id"]) != "custom":
		return String(r["name"])
	return EngPorts.get_def((graph.node(node_id) as EngGraph.EngNode).component_id).id

# --- stock definitions -----------------------------------------------------

static func _build() -> void:
	if _built:
		return
	_built = true
	# Ordered most-specific first: recognition stops at the first complete
	# match, so a "high pressure pump" would be tested before a "pump".
	for def in _default_assemblies():
		register_assembly(def)


static func _default_assemblies() -> Array:
	return [
		# A stock pump component. A motor turns a shaft that turns a body
		# with fluid ports on it, and that is a pump.
		{"id": "pump", "name": "pump",
			"requires_roles": {EngMachines.ROTARY_DRIVE: 1, EngMachines.FLUID_PUMP: 1},
			"needs_network": EngPorts.Kind.FLUID},

		# The same function, reached by building the parts instead of using
		# the component: a motor, something to spin, a housing, and a way for
		# water to get in and out. Two routes to one function, because a
		# definition is a pattern and a pattern can be expressed more than
		# one way. Neither says "pump" to the motor.
		{"id": "pump_from_parts", "name": "pump",
			"requires": {"impeller": 1, "housing": 1},
			"requires_roles": {EngMachines.ROTARY_DRIVE: 1},
			"needs_network": EngPorts.Kind.MECHANICAL,
			"touches": [EngPorts.Kind.FLUID]},

		{"id": "fan", "name": "fan assembly",
			"requires": {"fan": 1},
			"requires_roles": {EngMachines.ROTARY_DRIVE: 1},
			"needs_network": EngPorts.Kind.MECHANICAL},

		{"id": "conveyor", "name": "conveyor drive",
			"requires": {"conveyor_belt": 1},
			"requires_roles": {EngMachines.ROTARY_DRIVE: 1},
			"needs_network": EngPorts.Kind.MECHANICAL},

		{"id": "drill", "name": "drill unit",
			"requires": {"drill_bit": 1, "bearing": 1},
			"requires_roles": {EngMachines.ROTARY_DRIVE: 1},
			"needs_network": EngPorts.Kind.MECHANICAL},

		{"id": "grinder", "name": "grinder",
			"requires": {"grinder_wheel": 1, "bearing": 1},
			"requires_roles": {EngMachines.ROTARY_DRIVE: 1},
			"needs_network": EngPorts.Kind.MECHANICAL},

		{"id": "winch", "name": "winch",
			"requires": {"winch_drum": 1},
			"requires_roles": {EngMachines.ROTARY_DRIVE: 1},
			"needs_network": EngPorts.Kind.MECHANICAL},

		{"id": "generator_set", "name": "generator set",
			"requires": {"generator": 1, "battery": 1, "switch": 1},
			"needs_network": EngPorts.Kind.ELECTRICAL},

		{"id": "powered_station", "name": "powered station",
			"requires": {"furnace": 1},
			"requires_roles": {EngMachines.POWER_SOURCE: 1},
			"needs_network": EngPorts.Kind.ELECTRICAL},
	]
