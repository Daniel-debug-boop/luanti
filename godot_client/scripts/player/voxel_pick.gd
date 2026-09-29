class_name VoxelPick
extends RefCounted
## Amanatides & Woo voxel traversal: the 3D-DDA used to find which block the
## player is looking at, without touching the physics server.
##
## Stepping one voxel at a time along the ray would be O(distance) and would
## miss nothing; the DDA visits only the voxels the ray actually passes through,
## which is both faster and exact at corner cases.

## Result of a pick: the block hit, the empty cell just before it (where a new
## block goes), the face normal, and the distance.
class Hit:
	var block := Vector3i.ZERO
	var place := Vector3i.ZERO
	var normal := Vector3i.ZERO
	var distance := 0.0
	var id := 0

	var hit := false


## Walk from `origin` along `dir` (which must be normalised) up to `max_dist`
## nodes and return the first solid voxel.
static func raycast(world: VoxelWorld, origin: Vector3, dir: Vector3,
		max_dist: float = 6.0) -> Hit:
	var out := Hit.new()
	if world == null or dir.length_squared() < 0.000001:
		return out
	dir = dir.normalized()

	var pos := Vector3i(int(floor(origin.x)), int(floor(origin.y)),
		int(floor(origin.z)))
	var step := Vector3i(
		1 if dir.x > 0.0 else (-1 if dir.x < 0.0 else 0),
		1 if dir.y > 0.0 else (-1 if dir.y < 0.0 else 0),
		1 if dir.z > 0.0 else (-1 if dir.z < 0.0 else 0))
	# Guard against a zero component producing a zero tMax.
	var delta := Vector3(
		absf(1.0 / dir.x) if absf(dir.x) > 0.000001 else INF,
		absf(1.0 / dir.y) if absf(dir.y) > 0.000001 else INF,
		absf(1.0 / dir.z) if absf(dir.z) > 0.000001 else INF)
	var t_max := Vector3(
		_step_to_boundary(origin.x, dir.x, pos.x),
		_step_to_boundary(origin.y, dir.y, pos.y),
		_step_to_boundary(origin.z, dir.z, pos.z))

	var t := 0.0
	var last := pos
	while t <= max_dist:
		var id := world.get_content_at(pos)
		if ContentDB.is_solid(id):
			out.hit = true
			out.block = pos
			out.place = last
			out.normal = last - pos
			out.distance = t
			out.id = id
			return out
		last = pos
		# Advance along whichever axis has the nearest upcoming boundary.
		if t_max.x <= t_max.y and t_max.x <= t_max.z:
			pos.x += step.x
			t = t_max.x
			t_max.x += delta.x
		elif t_max.y <= t_max.z:
			pos.y += step.y
			t = t_max.y
			t_max.y += delta.y
		else:
			pos.z += step.z
			t = t_max.z
			t_max.z += delta.z
		# A ray travelling along an axis that never steps would loop forever.
		if step == Vector3i.ZERO:
			break
	return out


## Distance from `origin` to the next voxel boundary along one axis.
static func _step_to_boundary(origin: float, dir: float, cell: int) -> float:
	if absf(dir) < 0.000001:
		return INF
	var frac := origin - float(cell)
	if dir > 0.0:
		return (1.0 - frac) / dir
	return -frac / dir
