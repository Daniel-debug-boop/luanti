class_name GreedyMesher
extends RefCounted
## Turns a 16x16x16 VoxelBlock plus its neighbours into triangle meshes.
##
## Greedy meshing collapses flat regions to single quads. Faces are grouped
## into one buffer per block id, so each id becomes its own surface and can
## carry its own textured material; quad UVs are in block units so a photo
## texture tiles once per block instead of stretching across a merged run.
##
## Per-vertex brightness combines directional shading, stored daylight,
## emissive block light and ambient occlusion. Opaque and translucent geometry
## (water, ice) is returned as two separate meshes so the caller can order the
## transparent pass after the opaque one.

const BS := 16

## Directional face shading indexed by axis*2+dir: 0=+X 1=-X 2=+Y 3=-Y 4=+Z 5=-Z
const FACE_SHADE := [0.86, 0.86, 1.0, 0.5, 0.72, 0.72]
## Ambient occlusion levels by occluder count (0..3).
const AO_LEVELS := [0.42, 0.62, 0.81, 1.0]


## One id's worth of quads, later becoming one mesh surface.
class FaceBuffer:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	## Second UV set, tiled finer, for StandardMaterial3D's detail layer.
	var uv2s := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var id := 0

	func add_quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3,
			n: Vector3, uv_w: float, uv_h: float,
			detail_scale: float,
			cols: PackedColorArray) -> void:
		var base := vertices.size()
		var pts := [a, b, c, d]
		# UVs are in block units: a merged 4x3 quad spans 4x3 texture tiles.
		var uvs4 := [Vector2(0, 0), Vector2(uv_w, 0),
			Vector2(uv_w, uv_h), Vector2(0, uv_h)]
		for i in 4:
			vertices.append(pts[i])
			normals.append(n)
			uvs.append(uvs4[i])
			# The detail layer reads UV2, so it can repeat at a different rate
			# from the albedo without a second material.
			uv2s.append(uvs4[i] * detail_scale)
			colors.append(cols[i])
		indices.append_array([base, base + 1, base + 2,
			base, base + 2, base + 3])


## Greedy-mesh `block` with `neighbours` (Vector3i offset -> VoxelBlock) for
## cross-chunk culling. Returns [opaque: ArrayMesh, trans: ArrayMesh], either
## of which may be null when that pass is empty.
static func build(block: VoxelBlock, neighbours: Dictionary) -> Array:
	# Fast path: an all-air block meshes to nothing. This keeps streaming
	# cheap over open sky, where most chunks are empty.
	var any_solid := false
	for c in block.content:
		if ContentDB.is_solid(c):
			any_solid = true
			break
	if not any_solid:
		return [null, null]

	var opaque := {}   # block id -> FaceBuffer
	var trans := {}

	var get_content := func(local: Vector3i) -> int:
		return _sample(block, neighbours, local, false)
	var get_light := func(local: Vector3i) -> int:
		return _sample(block, neighbours, local, true)

	for axis in 3:
		for dir in 2:
			_mesh_axis(block, get_content, get_light, axis, dir, opaque, trans)

	return [_to_mesh(opaque), _to_mesh(trans)]


## Which surface ids a mesh pass contains, for tests and material binding.
static func surface_ids(mesh: ArrayMesh) -> PackedInt32Array:
	var out := PackedInt32Array()
	if mesh == null:
		return out
	for i in mesh.get_surface_count():
		out.append(int(mesh.surface_get_name(i)))
	return out


## Read a voxel (or its daylight) at a block-local coordinate, following into
## neighbouring blocks when the coordinate falls outside this one.
static func _sample(block: VoxelBlock, neighbours: Dictionary,
		local: Vector3i, want_light: bool) -> int:
	var b := block
	var c := local
	while c.x < 0 or c.x >= BS or c.y < 0 or c.y >= BS \
			or c.z < 0 or c.z >= BS:
		var bo := Vector3i(
			int(floor(float(c.x) / BS)),
			int(floor(float(c.y) / BS)),
			int(floor(float(c.z) / BS)))
		c = c - bo * BS
		if not neighbours.has(bo):
			return MapNode.LIGHT_SUN if want_light else ContentDB.AIR
		b = neighbours[bo]
	var idx := MapNode.index(c.x, c.y, c.z)
	if want_light:
		return b.light[idx] & 0x0F
	return b.content[idx]


static func _buffer_for(store: Dictionary, id: int) -> FaceBuffer:
	if store.has(id):
		return store[id]
	var buf := FaceBuffer.new()
	buf.id = id
	store[id] = buf
	return buf


static func _mesh_axis(block: VoxelBlock, get_content: Callable,
		get_light: Callable, axis: int, dir: int,
		opaque: Dictionary, trans: Dictionary) -> void:
	var u := (axis + 1) % 3
	var v := (axis + 2) % 3
	var du := Vector3i.ZERO
	du[u] = 1
	var dv := Vector3i.ZERO
	dv[v] = 1
	var normal := Vector3i.ZERO
	normal[axis] = 1 if dir == 0 else -1

	var cells := BS * BS * BS
	var present := PackedByteArray()
	present.resize(cells)
	var mask := PackedInt32Array()
	mask.resize(cells)
	var self_ids := PackedInt32Array()
	self_ids.resize(cells)

	# Face detection: a solid voxel gets a face where the neighbour on the far
	# side of that face does not occlude it. Same-id translucent neighbours
	# cull against each other so water surfaces stay clean.
	for d in BS:
		for x in BS:
			for y in BS:
				var p := Vector3i.ZERO
				p[u] = x
				p[v] = y
				p[axis] = d
				var own: int = block.content[MapNode.index(p.x, p.y, p.z)]
				if not ContentDB.is_solid(own):
					continue
				var q := p
				q[axis] = d + (1 if dir == 0 else -1)
				var nb: int = get_content.call(q)
				if ContentDB.is_opaque(nb):
					continue
				if nb == own and not ContentDB.is_translucent(own):
					continue
				var idx := d * BS * BS + y * BS + x
				present[idx] = 1
				mask[idx] = nb
				self_ids[idx] = own

	# Greedy sweep: merge maximal rectangles of identical faces per slice.
	var plane := BS if dir == 0 else 0
	for d in BS:
		var x := 0
		while x < BS:
			var y := 0
			var row_w := 0
			while y < BS:
				var idx := d * BS * BS + y * BS + x
				if present[idx] == 0:
					y += 1
					continue
				var m := mask[idx]
				var sid := self_ids[idx]

				# Run length along u.
				row_w = 1
				while x + row_w < BS:
					var j := d * BS * BS + y * BS + x + row_w
					if present[j] == 0 or mask[j] != m \
							or self_ids[j] != sid:
						break
					row_w += 1

				# Run depth along v, only across an identical u-run.
				var hh := 1
				while y + hh < BS:
					var ok := true
					for i in row_w:
						var j2 := d * BS * BS + (y + hh) * BS + x + i
						if present[j2] == 0 or mask[j2] != m \
								or self_ids[j2] != sid:
							ok = false
							break
					if not ok:
						break
					hh += 1

				_emit_face(block, get_content, get_light, axis, dir, u, v,
					du, dv, d, x, y, row_w, hh, normal, plane, sid, m,
					opaque, trans)
				y += hh
			if row_w > 0:
				x += row_w
			else:
				x += 1


static func _emit_face(block: VoxelBlock, get_content: Callable,
		get_light: Callable, axis: int, dir: int, u: int, v: int,
		du: Vector3i, dv: Vector3i, d: int, x: int, y: int, w: int, h: int,
		normal: Vector3i, plane: int, own_content: int, _neighbour_id: int,
		opaque: Dictionary, trans: Dictionary) -> void:
	var store := trans if ContentDB.is_translucent(own_content) else opaque
	var buf := _buffer_for(store, own_content)

	var base := Vector3i.ZERO
	base[u] = x
	base[v] = y
	base[axis] = plane
	var nrm := Vector3(float(normal.x), float(normal.y), float(normal.z))

	var p0 := Vector3(base)
	var p1 := p0 + Vector3(du) * float(w)
	var p2 := p1 + Vector3(dv) * float(h)
	var p3 := p0 + Vector3(dv) * float(h)

	# Brightness: directional shade x daylight, plus an emissive bonus for
	# light-emitting blocks so glowstone faces read as bright.
	var face_idx := axis * 2 + (0 if dir == 0 else 1)
	var shade: float = FACE_SHADE[face_idx]
	var lsum := 0
	for cx in [x, x + w - 1]:
		for cy in [y, y + h - 1]:
			var c := Vector3i.ZERO
			c[u] = cx
			c[v] = cy
			c[axis] = d
			lsum += int(get_light.call(c))
	var day := float(lsum) / 4.0 / float(MapNode.LIGHT_SUN)
	var emit := float(ContentDB.light_of(own_content)) / 15.0

	# Ambient occlusion, sampled per corner so merged quads still darken
	# where the surface meets an obstruction.
	var cols := PackedColorArray()
	var pal := ContentDB.color_of(own_content)
	for corner in 4:
		var cu := x if corner == 0 or corner == 3 else x + w - 1
		var cv := y if corner == 0 or corner == 1 else y + h - 1
		var su := -1 if cu == x else 1
		var sv := -1 if cv == y else 1
		var ao := _ao(get_content, axis, dir, u, v, du, dv, d, cu, cv, su, sv)
		var bright := clampf(shade * (0.25 + 0.75 * day) * ao + emit * 0.9,
			0.08, 1.0)
		cols.append(Color(pal.r * bright, pal.g * bright, pal.b * bright,
			pal.a))

	buf.add_quad(p0, p1, p2, p3, nrm, float(w), float(h),
		MaterialLibrary.DETAIL_UV_SCALE, cols)


## Standard voxel ambient occlusion for one quad corner: look at the two edge
## neighbours and the diagonal in the layer in front of the face.
static func _ao(get_content: Callable, axis: int, dir: int, u: int, v: int,
		du: Vector3i, dv: Vector3i, d: int, cu: int, cv: int,
		su: int, sv: int) -> float:
	var cell := Vector3i.ZERO
	cell[u] = cu
	cell[v] = cv
	cell[axis] = d + (1 if dir == 0 else -1)

	var p1 := cell + du * su
	var p2 := cell + dv * sv
	var p3 := cell + du * su + dv * sv
	var s1 := 1 if ContentDB.is_opaque(get_content.call(p1)) else 0
	var s2 := 1 if ContentDB.is_opaque(get_content.call(p2)) else 0
	var sc := 1 if ContentDB.is_opaque(get_content.call(p3)) else 0
	# Two touching edges mean the corner is fully enclosed; the diagonal is
	# ignored in that case, which is what removes the harsh "X" artefact.
	if s1 == 1 and s2 == 1:
		return AO_LEVELS[0]
	return AO_LEVELS[3 - (s1 + s2 + sc)]


## Build an ArrayMesh with one surface per block id, named with that id so the
## material binding and the tests can read it back. Null when empty.
static func _to_mesh(store: Dictionary) -> ArrayMesh:
	if store.is_empty():
		return null
	var ids := store.keys()
	ids.sort()
	var mesh := ArrayMesh.new()
	for id in ids:
		var buf: FaceBuffer = store[id]
		if buf.indices.is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = buf.vertices
		arrays[Mesh.ARRAY_NORMAL] = buf.normals
		arrays[Mesh.ARRAY_TEX_UV] = buf.uvs
		arrays[Mesh.ARRAY_TEX_UV2] = buf.uv2s
		arrays[Mesh.ARRAY_COLOR] = buf.colors
		arrays[Mesh.ARRAY_INDEX] = buf.indices
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		# The surface name carries the block id for material binding.
		mesh.surface_set_name(mesh.get_surface_count() - 1, str(id))
	return mesh if mesh.get_surface_count() > 0 else null
