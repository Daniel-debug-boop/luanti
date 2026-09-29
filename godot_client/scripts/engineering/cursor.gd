class_name EngCursor
extends RefCounted
## The Engineering Cursor: where a part will actually go.
##
## This is deliberately not a CAD interface. The player never types a
## coordinate; the cursor works out a sensible position from what they are
## looking at, and the three interaction levels change only how much it
## second-guesses them.
##
## Snap priority, highest first:
##
##   connection  an existing port that wants this part
##   center      the middle of a block, or of the thing being copied
##   edge        the edge of the face being looked at
##   surface     flat against the face being looked at
##   grid        a fixed lattice
##   angle       a fixed rotation step
##
## At the ASSISTED level the cursor snaps hard and explains itself. At PRECISION
## it barely snaps and reports exact numbers. Both use the same code; only the
## thresholds differ, so a beginner and an engineer are using the same system.

enum Mode { FREE, SURFACE, EDGE, CENTER, GRID, CONNECTION, ANGLE }
enum Level { ASSISTED, STANDARD, PRECISION }

## Half a block: parts are placed against faces, not floating at cell corners.
const BLOCK := 0.5
## How close a port has to be before connection snapping takes over.
const PORT_SNAP_RANGE := 1.6
## How close the ray has to pass to an edge before edge snapping engages.
const EDGE_SNAP_RANGE := 0.28

const MODE_NAMES := ["free", "surface", "edge", "center", "grid", "connection",
	"angle"]


static func mode_name(mode: int) -> String:
	return String(MODE_NAMES[mode]) if mode >= 0 and mode < MODE_NAMES.size() \
		else "free"


## Resolve where a part should go.
##
## `hit`     { position, normal } from the world's raycast
## `part`    the EngPart being placed, or null
## `graph`   the connection graph, or null when nothing has been built yet
## `opts`    { level, grid, angle_step, thickness, connect, ignore_node }
##
## Returns { position, rotation, normal, snapped, mode, label, exact } where
## `label` is what the player sees floating next to the cursor, and `exact` is
## the numeric readout the PRECISION level shows.
static func resolve(hit: Dictionary, part: EngPart, graph: EngGraph,
		opts := {}) -> Dictionary:
	var level := int(opts.get("level", Level.ASSISTED))
	var grid := float(opts.get("grid", 0.25))
	var angle_step := deg_to_rad(float(opts.get("angle_step", 15.0)))
	var thickness: float = _thickness(part)
	var raw: Vector3 = hit.get("position", Vector3.ZERO)
	var normal: Vector3 = hit.get("normal", Vector3.UP)
	if normal.length_squared() < 0.001:
		normal = Vector3.UP
	normal = normal.normalized()

	var out := {
		"position": raw,
		"rotation": 0.0,
		"normal": normal,
		"snapped": "free",
		"mode": Mode.FREE,
		"label": "",
		"exact": "",
	}

	# -- connection snapping: the most useful kind, so it wins outright ------
	# An existing node with a free port nearby is almost always what the
	# player meant, whether or not they were aiming at it.
	if graph != null and bool(opts.get("connect", true)):
		var con := nearest_port(graph, raw, _ignore(opts),
			held_port_kind(String(opts.get("held", ""))))
		if not con.is_empty():
			var host: EngGraph.EngNode = graph.node(int(con["node"]))
			out["position"] = host.position
			out["rotation"] = host.rotation_y
			out["snapped"] = "port:%s" % String(con["port"])
			out["mode"] = Mode.CONNECTION
			out["label"] = "connect to %s.%s" % [host.component_id,
				String(con["port"])]
			_finish(out, part, level, angle_step)
			return out

	# -- surface snapping ---------------------------------------------------
	# Push the part out of the face it is against, so it rests on the surface
	# rather than half-buried in it.
	if level != Level.PRECISION:
		out["position"] = raw + normal * (thickness * 0.5)
		out["snapped"] = "surface"
		out["mode"] = Mode.SURFACE

	# -- edge snapping ------------------------------------------------------
	# Landing near the edge of the block face being looked at is a strong
	# signal that the player wants a part that overhangs, which is how a
	# bracket or a shelf gets built.
	if hit.has("block") and _is_near_block_edge(raw, hit["block"], normal):
		var centred := _on_block_edge(raw, hit["block"], normal)
		if level == Level.ASSISTED or level == Level.STANDARD:
			out["position"] = centred
			out["snapped"] = "edge"
			out["mode"] = Mode.EDGE

	# -- centre snapping ----------------------------------------------------
	# Snapping the rotation to a quarter turn is the single most useful
	# default in a voxel world: it is the difference between a part that
	# lines up with the grid and one that looks accidental.
	#
	# It only *claims* the label when nothing better already happened.
	# Reporting "center" for a part that is actually resting on a face is a
	# small lie, and a player who catches the readout being wrong once stops
	# trusting every other word on it.
	if level == Level.ASSISTED:
		var r := _snap_angle(out["rotation"], deg_to_rad(90.0))
		out["rotation"] = r
		if absf(r) < 0.001 and String(out["snapped"]) == "free":
			out["snapped"] = "center"
			out["mode"] = Mode.CENTER

	# -- grid snapping ------------------------------------------------------
	if grid > 0.0 and level != Level.PRECISION:
		var snapped_pos := Vector3(roundf(out["position"].x / grid) * grid,
			roundf(out["position"].y / grid) * grid,
			roundf(out["position"].z / grid) * grid)
		if snapped_pos != out["position"]:
			out["position"] = snapped_pos
			if out["snapped"] == "free":
				out["snapped"] = "grid"
				out["mode"] = Mode.GRID

	# -- angle snapping -----------------------------------------------------
	if angle_step > 0.0 and level != Level.PRECISION:
		out["rotation"] = _snap_angle(out["rotation"], angle_step)

	_finish(out, part, level, angle_step)
	return out


static func _thickness(part: EngPart) -> float:
	if part == null:
		return 0.1
	# The thinnest axis is what a part rests on its face.
	return maxf(minf(minf(part.size.x, part.size.y), part.size.z), 0.01)


static func _ignore(opts: Dictionary) -> int:
	return int(opts.get("ignore_node", 0))


## The closest free port to `from`, within PORT_SNAP_RANGE. `held_kind` is the
## port kind the held component can mate with (EngPorts.Kind), or -1 to accept
## anything. Filtering by kind is what makes the cursor feel intelligent rather
## than merely sticky: aiming anywhere near a motor snaps you to its power port,
## not to the heat port two centimetres away.
static func nearest_port(graph: EngGraph, from: Vector3, ignore_node := 0,
		held_kind := -1) -> Dictionary:
	var best := {}
	var best_d := PORT_SNAP_RANGE * PORT_SNAP_RANGE
	for n in graph.nodes_near(from, PORT_SNAP_RANGE):
		var node_ref: EngGraph.EngNode = n
		if node_ref.id == ignore_node:
			continue
		for port in graph.free_ports(node_ref.id):
			var p: EngPorts.Port = port
			if held_kind >= 0 and p.kind != held_kind:
				continue
			var d: float = node_ref.position.distance_squared_to(from)
			if d < best_d:
				best_d = d
				best = {"node": node_ref.id, "port": p.name,
					"component": node_ref.component_id, "kind": p.kind}
	return best


## The port kind the held component most wants to connect, so the cursor can
## filter. A shaft wants mechanical; a wire wants electrical. -1 means the
## cursor should not filter.
static func held_port_kind(held_component: String) -> int:
	if held_component == "" or not EngPorts.has(held_component):
		return -1
	var def := EngPorts.get_def(held_component)
	if def == null or def.ports.is_empty():
		return -1
	# Prefer an output, since that is what most held parts are offering.
	for p in def.ports:
		var port: EngPorts.Port = p
		if port.can_emit():
			return port.kind
	var first: EngPorts.Port = def.ports[0]
	return first.kind


static func _is_near_block_edge(point: Vector3, block: Variant, normal: Vector3) -> bool:
	if not (block is Vector3i):
		return false
	var b: Vector3i = block
	var centre := Vector3(b) + Vector3(BLOCK, BLOCK, BLOCK)
	var local := point - centre
	# Only the two axes lying in the face can have an edge.
	var best := INF
	for axis in 3:
		if absf(normal[axis]) > 0.5:
			continue
		var d := absf(absf(local[axis]) - BLOCK)
		best = minf(best, d)
	return best < EDGE_SNAP_RANGE


static func _on_block_edge(point: Vector3, block: Variant, normal: Vector3) -> Vector3:
	var b: Vector3i = block
	var out := point
	var centre := Vector3(b) + Vector3(BLOCK, BLOCK, BLOCK)
	for axis in 3:
		if absf(normal[axis]) > 0.5:
			continue
		var d := absf(local_axis(point - centre, axis)) - BLOCK
		if absf(d) < EDGE_SNAP_RANGE:
			out[axis] = centre[axis] + signf(d) * BLOCK
	return out


static func local_axis(v: Vector3, axis: int) -> float:
	return v.x if axis == 0 else (v.y if axis == 1 else v.z)


static func _snap_angle(angle: float, step: float) -> float:
	if step <= 0.0:
		return angle
	return snappedf(angle, step)


## Fill in the readout the player actually sees. ASSISTED gets a word,
## STANDARD gets a word and a number, PRECISION gets exact millimetre figures.
static func _finish(out: Dictionary, part: EngPart, level: int,
		_angle_step: float) -> void:
	var pos: Vector3 = out["position"]
	var rot := float(out["rotation"])
	if part == null:
		out["label"] = "%s" % mode_name(int(out["mode"]))
		out["exact"] = "x %.3f  y %.3f  z %.3f" % [pos.x, pos.y, pos.z]
		return
	if out["label"] == "":
		out["label"] = "%s %s" % [part.label, mode_name(int(out["mode"]))]
	if level == Level.ASSISTED:
		return
	out["exact"] = "%.0f x %.0f x %.0f mm   %.0f deg" % [
		part.size.x * 1000.0, part.size.y * 1000.0, part.size.z * 1000.0,
		rad_to_deg(rot)]
	if level == Level.PRECISION:
		out["exact"] += "   q %.2f   %s" % [part.quality, part.material]
