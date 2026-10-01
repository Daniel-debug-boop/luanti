class_name EngGraph
extends RefCounted
## Connection System: a generic graph of placed components and typed edges.
##
## This is the layer that makes "one motor, many machines" real. A graph does
## not know what a pump is. It knows that a rotation_output met a rotation_input,
## that both belong to the same mechanical network, and that a network has
## members. Everything else -- torque, pressure, whether the thing moves water
## -- falls out of the components sitting on that network.
##
## Design points that matter for performance and for save safety:
##
##  * Structural changes are rare and expensive; simulation is frequent and
##    cheap. So networks are recomputed with a union-find pass only when the
##    graph actually changes, and the simulation just reads the cached
##    membership. Editing a factory does not re-partition it every frame.
##  * A port carries at most one edge. That is how real machines are wired and
##    it makes "where does this shaft's output go?" answerable in O(1), so a
##    client cannot attach forty things to one port.
##  * Nodes are indexed by chunk so a query like "what is near the player" is
##    a hash lookup rather than a scan of the whole factory.

## One placed component instance in the world.
class EngNode:
	var id := 0
	var component_id := "steel_placeholder"
	## The manufactured part this instance represents, or null for stock
	## components. Carrying the part (not a mesh) is what lets a blueprint
	## regenerate the exact geometry later.
	var part: EngPart = null
	var position := Vector3.ZERO
	var rotation_y := 0.0
	## Which assembly this node was recognised into, or 0.
	var assembly_id := 0
	## Free-form per-instance state the machine layer owns (rpm, temperature,
	## stored fluid...). Kept out of the definition so one motor definition
	## serves a thousand motors.
	var state := {}
	## A disabled node is still in the graph but contributes no power or torque,
	## which is how a switch "off" and a disengaged clutch are expressed.
	var enabled := true

	func _init(p_id := 0, p_component := "", p_pos := Vector3.ZERO) -> void:
		id = p_id
		component_id = p_component
		position = p_pos

	func to_dict() -> Dictionary:
		return {
			"component": component_id,
			"position": [position.x, position.y, position.z],
			"rotation_y": rotation_y,
			"assembly": assembly_id,
			"enabled": enabled,
			"state": state.duplicate(true),
			"part": part.to_dict() if part != null else null,
		}


static func _node_from_dict(id: int, d: Dictionary) -> EngNode:
	var n := EngNode.new(id, String(d.get("component", "")), _vec3(d.get("position")))
	n.rotation_y = float(d.get("rotation_y", 0.0))
	n.assembly_id = int(d.get("assembly", 0))
	n.enabled = bool(d.get("enabled", true))
	var st = d.get("state", {})
	if st is Dictionary:
		n.state = (st as Dictionary).duplicate(true)
	var pd = d.get("part", null)
	if pd is Dictionary:
		n.part = EngPart.from_dict(pd as Dictionary)
	return n


static func _vec3(v: Variant) -> Vector3:
	if v is Array and (v as Array).size() == 3:
		var a: Array = v
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO


## A connection between two ports. Typed by construction: EngPorts refuses an
## incompatible pair before an edge is ever created.
class EngEdge:
	var id := 0
	var a := 0            # node id
	var a_port := ""
	var b := 0            # node id
	var b_port := ""
	var kind := 0         # EngPorts.Kind
	## What the edge carries, e.g. "water". Empty means anything.
	var carries := ""

	func to_dict() -> Dictionary:
		return {"a": a, "a_port": a_port, "b": b, "b_port": b_port,
			"kind": kind, "carries": carries}


static func _edge_from_dict(id: int, d: Dictionary) -> EngEdge:
	var e := EngEdge.new()
	e.id = id
	e.a = int(d.get("a", 0))
	e.a_port = String(d.get("a_port", ""))
	e.b = int(d.get("b", 0))
	e.b_port = String(d.get("b_port", ""))
	e.kind = int(d.get("kind", 0))
	e.carries = String(d.get("carries", ""))
	return e

# --- state -----------------------------------------------------------------

var _nodes := {}            # node id -> EngNode
var _edges := {}            # edge id -> EngEdge
var _node_edges := {}       # node id -> Array[int]
var _port_link := {}        # "node:port" -> edge id
var _space := {}            # chunk key -> Array[int]
var _networks := {}         # network id -> Dictionary
var _node_net := {}         # "node:kind" -> network id, because a motor sits
                            # in one electrical network AND one mechanical one
var _net_kind := {}         # network id -> EngPorts.Kind
var _next_node := 1
var _next_edge := 1
var _next_net := 1
## Set whenever the topology changes, so the owner knows to re-save.
var dirty := true
## Monotonic counter, bumped on every structural change. Anything that is
## expensive and depends only on the shape of the world -- assembly
## recognition, visual streaming -- keys its cache on this instead of
## recomputing every frame. `dirty` says "something changed"; `revision` says
## "something changed, and here is which time".
var revision := 0


func _touch() -> void:
	dirty = true
	revision += 1

## Nodes are bucketed on a CHUNK grid purely for spatial queries. It is not the
## voxel chunk size: engineering components span multiple blocks, and this grid
## only needs to be fine enough that "near the player" is a handful of buckets.
const SPACE_CELL := 16.0


static func _cell_key(p: Vector3) -> String:
	return "%d_%d_%d" % [int(floorf(p.x / SPACE_CELL)),
		int(floorf(p.y / SPACE_CELL)), int(floorf(p.z / SPACE_CELL))]


# --- nodes -----------------------------------------------------------------

## Place a component. Returns the new node id, or -1 if the component is not
## in the library (a typo must not create an invisible ghost).
func place(component_id: String, pos: Vector3, rotation_y := 0.0,
		part: EngPart = null) -> int:
	if not EngPorts.has(component_id):
		return -1
	var n := EngNode.new(_next_node, component_id, pos)
	n.rotation_y = rotation_y
	n.part = part
	_next_node += 1
	_nodes[n.id] = n
	_node_edges[n.id] = []
	var key := _cell_key(pos)
	if not _space.has(key):
		_space[key] = []
	(_space[key] as Array).append(n.id)
	_touch()
	return n.id


## Remove a node and every edge touching it. Anything downstream that lost a
## power or torque source is now genuinely disconnected, so this is a
## topological change.
##
## The graph is re-partitioned before returning, because a stale "this node is
## on network N" answer after a deletion is exactly the kind of bug that shows
## up as a machine that keeps running with its fuel removed. Callers that are
## removing many nodes at once (world unload) pass rebuild = false and call
## rebuild_networks() once at the end.
func remove_node(node_id: int, rebuild := true) -> bool:
	if not _nodes.has(node_id):
		return false
	for eid in _edges_of(node_id).duplicate():
		disconnect_edge(eid)
	_space.erase(_cell_key((_nodes[node_id] as EngNode).position))
	_nodes.erase(node_id)
	_node_edges.erase(node_id)
	_touch()
	if rebuild:
		rebuild_networks()
	return true


func node(node_id: int) -> EngNode:
	return _nodes.get(node_id, null)


func has_node(node_id: int) -> bool:
	return _nodes.has(node_id)


func node_count() -> int:
	return _nodes.size()


## Switch a node on or off. Toggling a switch changes which nodes are
## electrically connected, so this is a topological change and forces a
## re-partition -- which is why it goes through the graph rather than
## poking `node.enabled` directly.
func set_enabled(node_id: int, on: bool) -> bool:
	var n: EngNode = _nodes.get(node_id, null)
	if n == null or n.enabled == on:
		return false
	n.enabled = on
	_touch()
	return true


func all_nodes() -> Array:
	return _nodes.values()


## Nodes whose position falls inside `radius` of `centre`. Walks only the
## buckets that can contain one, so this stays cheap in a large factory.
func nodes_near(centre: Vector3, radius: float) -> Array:
	var out: Array = []
	var span := int(ceilf(radius / SPACE_CELL))
	var base := Vector3(floorf(centre.x / SPACE_CELL),
		floorf(centre.y / SPACE_CELL), floorf(centre.z / SPACE_CELL))
	for dx in range(-span, span + 1):
		for dy in range(-span, span + 1):
			for dz in range(-span, span + 1):
				var key := "%d_%d_%d" % [int(base.x) + dx, int(base.y) + dy,
					int(base.z) + dz]
				if not _space.has(key):
					continue
				for nid in _space[key]:
					var n: EngNode = _nodes.get(nid, null)
					if n == null:
						continue
					if n.position.distance_squared_to(centre) <= radius * radius:
						out.append(n)
	return out


# --- edges -----------------------------------------------------------------

## Connect two ports. Returns { "ok": bool, "reason": String } -- the same
## contract as EngPorts.check_connection, so a UI can show the reason verbatim.
func link(a: int, a_port: String, b: int, b_port: String) -> Dictionary:
	if a == b:
		return {"ok": false, "reason": "a component cannot connect to itself"}
	if not _nodes.has(a):
		return {"ok": false, "reason": "unknown node %d" % a}
	if not _nodes.has(b):
		return {"ok": false, "reason": "unknown node %d" % b}
	var ca: EngNode = _nodes[a]
	var cb: EngNode = _nodes[b]
	var reason := EngPorts.check_connection(ca.component_id, a_port,
		cb.component_id, b_port)
	if reason != "":
		return {"ok": false, "reason": reason}

	var ka := "%d:%s" % [a, a_port]
	var kb := "%d:%s" % [b, b_port]
	if _port_link.has(ka) or _port_link.has(kb):
		return {"ok": false, "reason": "that port is already connected"}

	var def_a := EngPorts.get_def(ca.component_id)
	var pa: EngPorts.Port = def_a.port(a_port)
	var pb: EngPorts.Port = EngPorts.get_def(cb.component_id).port(b_port)
	var e := EngEdge.new()
	e.id = _next_edge
	_next_edge += 1
	e.a = a
	e.a_port = a_port
	e.b = b
	e.b_port = b_port
	e.kind = pa.kind
	# An edge carries the more specific of the two port restrictions; a
	# generic port inherits whatever the specific one declares.
	e.carries = pa.carries if pa.carries != "" else pb.carries
	_edges[e.id] = e
	_port_link[ka] = e.id
	_port_link[kb] = e.id
	(_node_edges[a] as Array).append(e.id)
	(_node_edges[b] as Array).append(e.id)
	_touch()
	return {"ok": true, "reason": "", "edge": e.id}


## Connect by proximity, the way a player actually builds: find the two nearest
## facing ports within `radius` and wire them. This is the ergonomic half of
## the connection system; the rule checking above is unchanged.
func link_nearest(pos: Vector3, radius := 2.0) -> Dictionary:
	var near := nodes_near(pos, radius)
	var best: Array = []
	for n in near:
		var node_ref: EngNode = n
		var def := EngPorts.get_def(node_ref.component_id)
		if def == null:
			continue
		for p in def.ports:
			var port: EngPorts.Port = p
			if _port_link.has("%d:%s" % [node_ref.id, port.name]):
				continue
			best.append({"node": node_ref.id, "port": port.name,
				"d": node_ref.position.distance_to(pos)})
	best.sort_custom(func(x, y): return float(x["d"]) < float(y["d"]))
	for i in range(best.size()):
		for j in range(i + 1, best.size()):
			var x: Dictionary = best[i]
			var y: Dictionary = best[j]
			var r := link(int(x["node"]), String(x["port"]),
				int(y["node"]), String(y["port"]))
			if bool(r["ok"]):
				return r
	return {"ok": false, "reason": "no compatible pair of free ports nearby"}


func disconnect_edge(edge_id: int) -> bool:
	if not _edges.has(edge_id):
		return false
	var e: EngEdge = _edges[edge_id]
	_port_link.erase("%d:%s" % [e.a, e.a_port])
	_port_link.erase("%d:%s" % [e.b, e.b_port])
	if _node_edges.has(e.a):
		(_node_edges[e.a] as Array).erase(edge_id)
	if _node_edges.has(e.b):
		(_node_edges[e.b] as Array).erase(edge_id)
	_edges.erase(edge_id)
	_touch()
	return true


func unlink(a: int, a_port: String) -> bool:
	var key := "%d:%s" % [a, a_port]
	if not _port_link.has(key):
		return false
	return disconnect_edge(int(_port_link[key]))


func edge(edge_id: int) -> EngEdge:
	return _edges.get(edge_id, null)


func edge_count() -> int:
	return _edges.size()


func is_linked(node_id: int, port_name: String) -> bool:
	return _port_link.has("%d:%s" % [node_id, port_name])


## The edge on a port, or -1.
func edge_on(node_id: int, port_name: String) -> int:
	return int(_port_link.get("%d:%s" % [node_id, port_name], -1))


func _edges_of(node_id: int) -> Array:
	return _node_edges.get(node_id, [])


func edges_of(node_id: int) -> Array:
	return _edges_of(node_id).duplicate()


## The other end of an edge, from the perspective of one of its nodes.
func other_end(edge_id: int, node_id: int) -> int:
	var e: EngEdge = _edges.get(edge_id, null)
	if e == null:
		return -1
	return e.b if e.a == node_id else e.a


## Is this edge currently conducting? False when a switch on either end is
## open, which is how a disconnected circuit is expressed.
##
## Named for the answer it gives rather than for the switch. The previous name,
## `edge_is_open`, read as the opposite of what it returned, and a caller that
## trusted the name inverted the meaning of the whole graph: it would have
## derived relationships only for BROKEN edges. Nothing else used it, so
## renaming it here is cheaper than leaving the trap in the API.
func edge_is_conductive(edge_id: int) -> bool:
	var e: EngEdge = _edges.get(edge_id, null)
	return e == null or not _edge_is_broken(e)


## Free ports on a node, for the connection preview.
func free_ports(node_id: int) -> Array:
	var out: Array = []
	var n: EngNode = _nodes.get(node_id, null)
	if n == null:
		return out
	var def := EngPorts.get_def(n.component_id)
	if def == null:
		return out
	for p in def.ports:
		var port: EngPorts.Port = p
		if not _port_link.has("%d:%s" % [node_id, port.name]):
			out.append(port)
	return out

# --- network partitioning --------------------------------------------------

## Recompute which nodes belong to which network, per kind.
##
## Union-find over the edges of one kind. Called only when `dirty` is set, so
## the cost is paid by edits rather than by frames. The result is a set of
## networks, each of which the simulation layer can treat as one object: that
## is what makes a hundred motors on one bus one bus and not a hundred
## independent ticking simulations.
func rebuild_networks() -> void:
	_networks.clear()
	_node_net.clear()
	_net_kind.clear()
	if _edges.is_empty():
		dirty = false
		return
	var parent := {}
	for nid in _nodes.keys():
		parent[nid] = nid
	for eid in _edges.keys():
		var e: EngEdge = _edges[eid]
		if _edge_is_broken(e):
			continue
		_union(parent, e.a, e.b)

	# Group nodes by their root, then by kind. A node that touches both an
	# electrical and a mechanical edge lands in two networks, which is
	# correct: the motor is a member of the power bus and of the shaft train.
	var groups := {}
	for nid in _nodes.keys():
		var root: int = _find(parent, nid)
		if not groups.has(root):
			groups[root] = []
		(groups[root] as Array).append(nid)

	# Deterministic network numbering. Networks are created in a stable order
	# -- sorted by the lowest member id, then by kind -- so re-partitioning
	# the same graph twice produces the same ids. That matters because a UI
	# selection, a save file and a network readout all refer to them, and a
	# number that changes every time the player adds a wire is unusable.
	var roots: Array = groups.keys()
	roots.sort()
	var net_id := 1
	for root in roots:
		var members: Array = groups[root]
		members.sort()
		var kinds: Array = _kinds_in(members)
		kinds.sort()
		for k in kinds:
			var net := {
				"id": net_id,
				"kind": int(k),
				"members": members.duplicate(),
				"state": _fresh_network_state(int(k)),
				# Start live: a freshly placed machine must work on the first
				# tick, before the LOD pass has had a chance to sleep
				# anything. EngSimulation demotes it immediately when the
				# player is nowhere near it.
				"lod": 0,
				"idle": 0.0,
				"active": false,
			}
			_networks[net_id] = net
			_net_kind[net_id] = int(k)
			for nid in members:
				_node_net["%d:%d" % [nid, int(k)]] = net_id
			net_id += 1
	_next_net = net_id
	dirty = false
	revision += 1


## Which port kinds appear among `members`, from their edges.
func _kinds_in(members: Array) -> Array:
	var kinds := {}
	for nid in members:
		for eid in _edges_of(int(nid)):
			kinds[(_edges[eid] as EngEdge).kind] = true
	var out: Array = kinds.keys()
	return out


## An edge conducts only when both of its endpoints do. That single rule is
## what makes an open switch, a blown fuse and a disengaged clutch all work
## without any of them being special-cased anywhere: the graph simply does not
## union across the broken edge, and the network splits.
##
## Named `_edge_is_broken` because that is what it returns. It was previously
## called `_edge_is_open` and returned the opposite of its own name, which is
## how `edge_is_open()` ended up answering "is this edge working?" for a
## caller that read it as "is this edge open?".
func _edge_is_broken(e: EngEdge) -> bool:
	for nid in [e.a, e.b]:
		var n: EngNode = _nodes.get(int(nid), null)
		if n != null and not n.enabled and EngMachines.breaks_circuit(n.component_id):
			return true
	return false


static func _fresh_network_state(kind: int) -> Dictionary:
	match kind:
		EngPorts.Kind.MECHANICAL:
			return {"rpm": 0.0, "torque": 0.0, "power": 0.0, "source": 0,
				"stiff": false}
		EngPorts.Kind.ELECTRICAL:
			return {"supply": 0.0, "demand": 0.0, "voltage": 0.0, "current": 0.0,
				"stored": 0.0}
		EngPorts.Kind.FLUID:
			return {"stored": 0.0, "pressure": 0.0, "flow": 0.0, "fluid": "",
				"source": 0, "sink": 0}
		EngPorts.Kind.THERMAL:
			return {"temperature": 20.0, "generated": 0.0, "dissipated": 0.0}
		EngPorts.Kind.DATA:
			return {"signal": 0.0, "carriers": []}
		_:
			return {}


static func _find(parent: Dictionary, x: int) -> int:
	var root: int = x
	while int(parent[root]) != root:
		root = int(parent[root])
	# Path compression: without it a long chain of wires degenerates into a
	# linked list and re-partitioning costs O(n^2).
	var cur: int = x
	while int(parent[cur]) != root:
		var nxt: int = int(parent[cur])
		parent[cur] = root
		cur = nxt
	return root


static func _union(parent: Dictionary, a: int, b: int) -> void:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra == rb:
		return
	# Keep the lower id as the root so partitioning is deterministic and a
	# save/reload cycle produces the same network numbering.
	if ra < rb:
		parent[rb] = ra
	else:
		parent[ra] = rb

# --- network access --------------------------------------------------------

func networks() -> Array:
	return _networks.values()


func networks_of_kind(kind: int) -> Array:
	var out: Array = []
	for n in _networks.values():
		if int((n as Dictionary)["kind"]) == kind:
			out.append(n)
	return out


func network(net_id: int) -> Dictionary:
	return _networks.get(net_id, {})


func network_state(net_id: int) -> Dictionary:
	var n: Dictionary = _networks.get(net_id, {})
	return n.get("state", {})


## The network a node participates in for a given kind, or 0. A motor is in one
## electrical network and one mechanical network, so this is asked per kind.
func network_of(node_id: int, kind: int) -> int:
	var nid := int(_node_net.get("%d:%d" % [node_id, kind], 0))
	return nid if _networks.has(nid) else 0


## Iterate the networks that actually touch a node, across every kind. Used by
## assembly recognition, which cares that a motor's rotation port and the
## pump's rotation port are in the *same* mechanical network.
func networks_touching(node_id: int) -> Array:
	var out: Array = []
	var seen := {}
	for eid in _edges_of(node_id):
		var e: EngEdge = _edges[eid]
		for nid in [e.a, e.b]:
			var k := "%d:%d" % [nid, e.kind]
			if seen.has(k):
				continue
			seen[k] = true
			var net := network_of(nid, e.kind)
			if net != 0 and not out.has(net):
				out.append(net)
	return out

# --- persistence -----------------------------------------------------------

func serialize() -> Dictionary:
	var nodes := {}
	for nid in _nodes.keys():
		nodes[str(nid)] = (_nodes[nid] as EngNode).to_dict()
	var edges := {}
	for eid in _edges.keys():
		edges[str(eid)] = (_edges[eid] as EngEdge).to_dict()
	# Node and edge ids are saved so a blueprint reproduces the exact graph,
	# and so a client that reconnects to a server sees the same identifiers.
	return {"version": 1, "next_node": _next_node, "next_edge": _next_edge,
		"next_net": _next_net, "nodes": nodes, "edges": edges}


## Rebuild a graph from a save. Ids are restored verbatim, so anything holding
## a node id (a machine, an assembly, a UI selection) survives a reload.
func deserialize(data: Dictionary) -> Dictionary:
	clear()
	var report := {"nodes": 0, "edges": 0, "skipped": 0}
	var nodes: Dictionary = data.get("nodes", {})
	for key in nodes.keys():
		var n := _node_from_dict(int(key), nodes[key])
		if not EngPorts.has(n.component_id):
			report["skipped"] += 1
			continue
		_nodes[n.id] = n
		_node_edges[n.id] = []
		var ck := _cell_key(n.position)
		if not _space.has(ck):
			_space[ck] = []
		(_space[ck] as Array).append(n.id)
		report["nodes"] += 1
	_next_node = maxi(int(data.get("next_node", 1)), _max_id(_nodes.keys()) + 1)
	var edges: Dictionary = data.get("edges", {})
	for key in edges.keys():
		var e := _edge_from_dict(int(key), edges[key])
		if not _nodes.has(e.a) or not _nodes.has(e.b):
			report["skipped"] += 1
			continue
		_edges[e.id] = e
		_port_link["%d:%s" % [e.a, e.a_port]] = e.id
		_port_link["%d:%s" % [e.b, e.b_port]] = e.id
		(_node_edges[e.a] as Array).append(e.id)
		(_node_edges[e.b] as Array).append(e.id)
		report["edges"] += 1
	_next_edge = maxi(int(data.get("next_edge", 1)), _max_id(_edges.keys()) + 1)
	_next_net = int(data.get("next_net", 1))
	dirty = true
	rebuild_networks()
	return report


static func _max_id(keys: Array) -> int:
	var m := 0
	for k in keys:
		m = maxi(m, int(k))
	return m


func clear() -> void:
	_nodes.clear()
	_edges.clear()
	_node_edges.clear()
	_port_link.clear()
	_space.clear()
	_networks.clear()
	_node_net.clear()
	_net_kind.clear()
	_next_node = 1
	_next_edge = 1
	_next_net = 1
	_touch()
