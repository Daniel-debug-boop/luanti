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
##
## ## Why the padded lattice
##
## The first version asked for a voxel through a GDScript `Callable` on every
## single sample: the face sweep needed one neighbour per voxel per axis per
## direction (6 x 4096) and ambient occlusion needed three more per corner of
## every emitted quad. That is tens of thousands of interpreted call
## dispatches per chunk, and it measured at ~83 ms for one chunk -- a frame
## budget the streamer believed was 1.4 ms, so the world meshed two chunks a
## frame and never caught up. The player saw floating slabs of half-loaded
## terrain and a 130 ms frame time.
##
## Everything the mesher ever reads is within one voxel of the block, so
## `build()` now samples that 18^3 skirt ONCE into a flat `PackedInt32Array`
## and every inner loop indexes it arithmetically. Content predicates
## (`is_solid`, `is_opaque`, `is_translucent`) become byte lookups for the
## same reason: they walked a dictionary-backed table per voxel. The mesh that
## comes out is byte-identical; it is just produced without the interpreter
## in the inner loop.

const BS := 16
## The block plus one voxel of skirt on every side. Faces need one voxel of
## neighbour to decide whether they are interior, and ambient occlusion needs
## one voxel past the face plane in both tangent directions.
const PAD := BS + 2

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
##
## This is the convenient whole-pipeline entry point, and it touches the
## rendering server. The two halves are `geometry()` (pure arithmetic over
## packed arrays, safe on a worker thread) and `to_meshes()` (creates
## ArrayMeshes, main thread only), so background meshing can run the first and
## hand the second to the frame that presents the result.
static func build(block: VoxelBlock, neighbours: Dictionary) -> Array:
	return to_meshes(geometry(block, neighbours))


## The pure-CPU half: sweep the block and return
## [opaque_faces: Dictionary, trans_faces: Dictionary], each mapping block id
## -> FaceBuffer. Nothing here allocates an engine resource or reads global
## mutable state, so it is safe to call from a WorkerThreadPool thread.
static func geometry(block: VoxelBlock, neighbours: Dictionary) -> Array:
	# Fast path: an all-air block meshes to nothing. This keeps streaming
	# cheap over open sky, where most chunks are empty.
	var any_solid := false
	for c in block.content:
		if ContentDB.is_solid(c):
			any_solid = true
			break
	if not any_solid:
		return [{}, {}]

	var opaque := {}   # block id -> FaceBuffer
	var trans := {}

	var ids := _lattice(block, neighbours)
	var lut := _lut()

	for axis in 3:
		for dir in 2:
			_mesh_axis(block, ids, lut, axis, dir, opaque, trans)

	return [opaque, trans]


## The engine half: turn face buffers into meshes. Main thread only, because
## `add_surface_from_arrays` uploads to the rendering server.
static func to_meshes(faces: Array) -> Array:
	return [_to_mesh(faces[0]), _to_mesh(faces[1])]


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
##
## Kept as the readable definition of the cross-chunk sampling rule; the
## mesher itself reads its padded lattice, which is filled from the same
## rule by `_lattice`.
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
		var cand := _trusted(neighbours, bo)
		if cand == null:
			return MapNode.LIGHT_SUN if want_light else ContentDB.AIR
		b = cand
	var idx := MapNode.index(c.x, c.y, c.z)
	if want_light:
		return b.light[idx] & 0x0F
	return b.content[idx]


## The block plus its one-voxel skirt, as flat ids in an 18^3 array indexed by
## `PIDX(x, y, z)` for local coordinates in -1..16.
static func _lattice(block: VoxelBlock, neighbours: Dictionary) -> PackedInt32Array:
	var ids := PackedInt32Array()
	ids.resize(PAD * PAD * PAD)
	var content := block.content
	# Interior: 16 rows of 16, straight across.
	for z in BS:
		var pz := (z + 1) * PAD * PAD
		var src := z * BS * BS
		for y in BS:
			var row := pz + (y + 1) * PAD + 1
			var s := src + y * BS
			for x in BS:
				ids[row + x] = content[s + x]
	# Skirt: six 16x16 faces, each a direct read from one neighbour.
	#
	# These were 1736 individual `_sample` calls, each of which re-derived
	# which block a coordinate belongs to and re-did a dictionary lookup --
	# to fetch 1736 values that actually live in six flat planes. Copying the
	# planes took the lattice from 3.3 ms to well under 1.
	for axis in 3:
		for dir in 2:
			var bo := Vector3i.ZERO
			bo[axis] = 1 if dir == 0 else -1
			var nb := _trusted(neighbours, bo)
			if nb == null:
				# Absent or unfinished neighbour: leave the skirt as air,
				# which draws the faces rather than hiding a hole.
				continue
			var u := (axis + 1) % 3
			var v := (axis + 2) % 3
			var pu := _pad_stride(u)
			var pv := _pad_stride(v)
			# The skirt plane sits at local -1 (dir 1) or BS (dir 0), which
			# is the far edge of the neighbour: BS-1 or 0 in its own block.
			var dst_plane := (0 if dir == 1 else BS + 1) * _pad_stride(axis)
			var src_plane := (BS - 1 if dir == 1 else 0) * _block_stride(axis)
			var src_content := nb.content
			for j in BS:
				var dst := dst_plane + (j + 1) * pv
				var src := src_plane + j * _block_stride(v)
				for i in BS:
					ids[dst + (i + 1) * pu] = src_content[src + i * _block_stride(u)]
	return ids


## The neighbour at block offset `bo`, or null when it must not be trusted --
## absent, null, or not both generated and loaded.
##
## VoxelWorld populates its block table as generation completes, so a
## neighbour can be present but not yet filled in; trusting it would read
## zeroed content, cull every face against it, and leave a hole that pops in
## once the data actually lands. An untrusted neighbour is treated as air,
## which draws the faces -- the safe direction, since a redundant face is
## hidden by the neighbour when it arrives and a missing face is a hole in
## the world.
static func _trusted(neighbours: Dictionary, bo: Vector3i) -> VoxelBlock:
	if not neighbours.has(bo):
		return null
	var cand: VoxelBlock = neighbours[bo]
	if cand == null or not cand.is_complete():
		return null
	return cand


## Content predicates as byte tables, one entry per registered id. The
## dictionary-backed lookups behind `is_solid`/`is_opaque`/`is_translucent`
## are the wrong shape for a loop that asks tens of thousands of times.
static func _lut() -> Dictionary:
	var solid := PackedByteArray()
	var opaque := PackedByteArray()
	var translucent := PackedByteArray()
	var n := ContentDB.MAX_ID + 1
	solid.resize(n)
	opaque.resize(n)
	translucent.resize(n)
	for id in n:
		solid[id] = 1 if ContentDB.is_solid(id) else 0
		opaque[id] = 1 if ContentDB.is_opaque(id) else 0
		translucent[id] = 1 if ContentDB.is_translucent(id) else 0
	return {"solid": solid, "opaque": opaque, "translucent": translucent}


## Stride between consecutive voxels along component `axis`, in both the
## padded lattice and the block's own arrays.
## Lattice index for a block-local voxel coordinate in -1..BS. The shared
## entry point for reading the padded lattice: `SurfaceNets` uses it too, so
## the two meshers cannot disagree about where a voxel lives.
static func _pidx(x: int, y: int, z: int) -> int:
	return (z + 1) * PAD * PAD + (y + 1) * PAD + (x + 1)


static func _pad_stride(axis: int) -> int:
	if axis == 0:
		return 1
	if axis == 1:
		return PAD
	return PAD * PAD


static func _block_stride(axis: int) -> int:
	if axis == 0:
		return 1
	if axis == 1:
		return BS
	return BS * BS


static func _buffer_for(store: Dictionary, id: int) -> FaceBuffer:
	if store.has(id):
		return store[id]
	var buf := FaceBuffer.new()
	buf.id = id
	store[id] = buf
	return buf


static func _mesh_axis(block: VoxelBlock, ids: PackedInt32Array,
		lut: Dictionary, axis: int, dir: int,
		opaque: Dictionary, trans: Dictionary) -> void:
	var u := (axis + 1) % 3
	var v := (axis + 2) % 3
	var du := Vector3i.ZERO
	du[u] = 1
	var dv := Vector3i.ZERO
	dv[v] = 1
	var normal := Vector3i.ZERO
	normal[axis] = 1 if dir == 0 else -1

	# Padded strides for this axis' (u, v, axis) basis, plus the constant
	# offset that shifts a local -1..16 coordinate into its 0..17 slot.
	var pu := _pad_stride(u)
	var pv := _pad_stride(v)
	var pa := _pad_stride(axis)
	var pbase := pu + pv + pa
	# One step along the face normal, in lattice units.
	var pstep := pa if dir == 0 else -pa
	var max_id := ContentDB.MAX_ID
	var solid: PackedByteArray = lut["solid"]
	var opaque_lut: PackedByteArray = lut["opaque"]
	var translucent: PackedByteArray = lut["translucent"]

	var cells := BS * BS * BS
	var present := PackedByteArray()
	present.resize(cells)
	var mask := PackedInt32Array()
	mask.resize(cells)
	var self_ids := PackedInt32Array()
	self_ids.resize(cells)
	# Which d-slices produced any face at all. The sweep below walks all
	# 4096 cells of a slice to merge faces, so a slice with no faces in it
	# is 4096 iterations of nothing -- and in terrain that is most of them:
	# a chunk is mostly air above its surface and mostly buried below it.
	var slice_used := PackedByteArray()
	slice_used.resize(BS)

	# Face detection: a solid voxel gets a face where the neighbour on the far
	# side of that face does not occlude it. Same-id translucent neighbours
	# cull against each other so water surfaces stay clean.
	for d in BS:
		var plane := pbase + d * pa
		for x in BS:
			var row := plane + x * pu
			for y in BS:
				var li := row + y * pv
				var own: int = ids[li]
				# `is_solid`: a registered id above air.
				if own <= 0 or own > max_id or solid[own] == 0:
					continue
				var nb: int = ids[li + pstep]
				# `is_opaque`: solid, and neither translucent nor a cutout.
				if nb > 0 and nb <= max_id and opaque_lut[nb] != 0:
					continue
				if nb == own and translucent[own] == 0:
					continue
				var idx := d * BS * BS + y * BS + x
				present[idx] = 1
				mask[idx] = nb
				self_ids[idx] = own
				slice_used[d] = 1

	# Greedy sweep: merge maximal rectangles of identical faces per slice.
	for d in BS:
		if slice_used[d] == 0:
			continue
		var x := 0
		while x < BS:
			var y := 0
			# `row_w` is declared out here rather than inside the loop: it is
			# read AFTER the loop, and it is the only thing that carries a
			# column with no faces at all. Such a column never runs the body,
			# so `row_w` is still the 0 it starts as and `x` advances by one.
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

				_emit_face(block, ids, opaque_lut, axis, dir, u, v,
					du, dv, d, x, y, row_w, hh, normal, sid,
					pbase, pu, pv, pa, pstep,
					opaque, trans)
				y += hh
			if row_w > 0:
				x += row_w
			else:
				x += 1


static func _emit_face(block: VoxelBlock, ids: PackedInt32Array,
		opaque_lut: PackedByteArray, axis: int, dir: int, u: int, v: int,
		du: Vector3i, dv: Vector3i, d: int, x: int, y: int, w: int, h: int,
		normal: Vector3i, own_content: int,
		pbase: int, pu: int, pv: int, pa: int, pstep: int,
		opaque: Dictionary, trans: Dictionary) -> void:
	var store := trans if ContentDB.is_translucent(own_content) else opaque
	var buf := _buffer_for(store, own_content)

	var base := Vector3i.ZERO
	base[u] = x
	base[v] = y
	# The face plane is the boundary this face sits ON, which is derived from
	# the voxel's own coordinate `d` -- not from the direction of travel.
	#
	# This used to be a single `plane` value (0 or BS) shared by every face in
	# the sweep, which placed every face of every chunk on the chunk's own
	# boundary. A block at (8,8,8) therefore emitted its six faces at x=0 and
	# x=16 instead of x=8 and x=9: the entire world collapsed into thin
	# sheets on the chunk edges, which is exactly what the hardware-GPU
	# captures showed -- haze, floating fragments and no solid ground. The
	# winding test could not see it because it never checked where a face
	# was, and the triangle-count tests could not see it because the
	# triangles were all there, just in the wrong place.
	#
	# A +axis face lies between voxel d and d+1, so it sits at d+1; a -axis
	# face lies between voxel d and d-1, so it sits at d.
	base[axis] = d + (1 if dir == 0 else 0)
	var nrm := Vector3(float(normal.x), float(normal.y), float(normal.z))

	var p0 := Vector3(base)
	var p1 := p0 + Vector3(du) * float(w)
	var p2 := p1 + Vector3(dv) * float(h)
	var p3 := p0 + Vector3(dv) * float(h)

	# Brightness: directional shade x daylight, plus an emissive bonus for
	# light-emitting blocks so glowstone faces read as bright.
	#
	# The four sampled voxels are all inside this block, so daylight is read
	# straight out of `block.light` -- no neighbour lookup was ever needed
	# here, and the Callable round-trip hid that.
	var face_idx := axis * 2 + (0 if dir == 0 else 1)
	var shade: float = FACE_SHADE[face_idx]
	var light := block.light
	var bu := _block_stride(u)
	var bv := _block_stride(v)
	var ba := d * _block_stride(axis)
	var x0 := x * bu
	var x1 := (x + w - 1) * bu
	var y0 := y * bv
	var y1 := (y + h - 1) * bv
	# Daylight is the LOW nibble of the packed byte (`MapNode` stores the sun
	# channel there and mirrors it in the high nibble). Masking a whole byte
	# with 0x3F only works while high nibble == day<<4 exactly; reading the
	# per-cell 0..15 channel and averaging is stable under any packer.
	var lsum := (int(light[ba + x0 + y0]) & 0x0F)
	lsum += int(light[ba + x1 + y0]) & 0x0F
	lsum += int(light[ba + x0 + y1]) & 0x0F
	lsum += int(light[ba + x1 + y1]) & 0x0F
	var day := float(lsum) / 60.0
	var emit := float(ContentDB.light_of(own_content)) / 15.0

	# Ambient occlusion, sampled per corner so merged quads still darken
	# where the surface meets an obstruction. Each corner's cell sits one
	# voxel in front of the face plane, and its two edge neighbours and the
	# diagonal are one lattice stride away.
	var cols := PackedColorArray()
	var pal := ContentDB.color_of(own_content)
	var cell_base := pbase + d * pa + pstep
	var max_id := ContentDB.MAX_ID
	for corner in 4:
		var cu := x if corner == 0 or corner == 3 else x + w - 1
		var cv := y if corner == 0 or corner == 1 else y + h - 1
		var su := -1 if cu == x else 1
		var sv := -1 if cv == y else 1
		var ao := _ao(ids, opaque_lut, cell_base + cu * pu + cv * pv,
			pu * su, pv * sv, max_id)
		var bright := clampf(shade * (0.25 + 0.75 * day) * ao + emit * 0.9,
			0.08, 1.0)
		cols.append(Color(pal.r * bright, pal.g * bright, pal.b * bright,
			pal.a))

	# Winding. `du x dv` is the POSITIVE axis direction for all three axes,
	# because u=(axis+1)%3 and v=(axis+2)%3 form a right-handed pair with the
	# axis. So the quad as built above always faces +axis, which is correct
	# for dir==0 and exactly backwards for dir==1: the -X, -Y and -Z faces
	# were emitted inside out and silently back-face culled. The mesher tests
	# only counted triangles, so nothing caught it -- the symptom was a
	# world with holes in it and a camera that could see through the ground.
	#
	# Reversing the corner order flips the triangle winding. Each corner's
	# ambient-occlusion colour has to travel WITH that corner, so the colours
	# are permuted to match the new order: position 0 keeps its own colour,
	# position 1 now holds p3 and so needs c3, and so on. The previous code
	# rotated the colours instead ([c3,c2,c1,c0]), which attached each
	# corner's shading to its neighbour -- subtle in a flat quad, and wrong
	# shading on every block corner in the world.
	var pts := [p0, p1, p2, p3]
	if dir == 1:
		pts = [p0, p3, p2, p1]
		cols = PackedColorArray([cols[0], cols[3], cols[2], cols[1]])

	buf.add_quad(pts[0], pts[1], pts[2], pts[3], nrm, float(w), float(h),
		MaterialLibrary.DETAIL_UV_SCALE, cols)


## Standard voxel ambient occlusion for one quad corner: look at the two edge
## neighbours and the diagonal in the layer in front of the face.
##
## `cell` is the corner's padded-lattice index in the layer in front of the
## face; `ou` and `ov` are the signed lattice strides to its edge neighbours.
static func _ao(ids: PackedInt32Array, opaque_lut: PackedByteArray,
		cell: int, ou: int, ov: int, max_id: int) -> float:
	var a1: int = ids[cell + ou]
	var a2: int = ids[cell + ov]
	var a3: int = ids[cell + ou + ov]
	var s1 := 1 if (a1 > 0 and a1 <= max_id and opaque_lut[a1] != 0) else 0
	var s2 := 1 if (a2 > 0 and a2 <= max_id and opaque_lut[a2] != 0) else 0
	var sc := 1 if (a3 > 0 and a3 <= max_id and opaque_lut[a3] != 0) else 0
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