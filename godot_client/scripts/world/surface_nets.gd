class_name SurfaceNets
extends RefCounted
## Smooth (dual) voxel meshing: one vertex per boundary cell, placed where the
## density field crosses zero.
##
## ## Why smooth meshing, and why not transvoxel
##
## The brief asks for Transvoxel or Surface Nets "via godot_voxel". The
## vendored `addons/voxel` tree in this project is shaders only -- no mesher,
## no GDExtension -- so there is nothing to call, and `addons/terrain-shader` is
## a loose set of .gdshader files with no plugin registering them. Bringing in
## the upstream mesher means vendoring a C++ extension that has to be rebuilt
## per platform and shipped inside exported binaries, which is a far bigger
## change than the silhouette needs. So this is Surface Nets written directly:
## the same algorithm family the brief names, and it removes the stair-step.
##
## Between the two, Surface Nets is the better fit here. Transvoxel keeps a
## vertex at the corner shared by up to four cells and can preserve hard 90
## degree edges; Surface Nets puts one vertex in the middle of each boundary
## cell and averages the crossings around it, which rounds the surface. For
## grass and dirt that is the look being asked for, and it stays watertight
## without any per-corner case analysis.
##
## ## The algorithm
##
## Every solid voxel is density 1 and every air voxel density 0, sampled at
## voxel positions. Each cell is the unit cube spanned by eight of those
## voxels; a boundary cell (its corners disagree) gets exactly one vertex,
## placed at the mean of the midpoints of the twelve edges that straddle the
## boundary. Then for each cell and each axis, if the cell's edge along that
## axis straddles the boundary, one quad is emitted joining this cell's vertex
## to the three cells sharing that edge. Because the quad belongs to the edge
## rather than the cell, neighbouring chunks agree on it exactly: the mesh is
## watertight by construction, not by stitching.
##
## ## What this shares with GreedyMesher
##
## Both read the same one-voxel padded lattice (`GreedyMesher._lattice`) and
## the same byte tables. That is deliberate. The padded lattice is where the
## cross-chunk sampling rule lives, and sharing it means the two meshers cannot
## disagree about what a border voxel is, so a greedy chunk and a smooth chunk
## meet without a crack and the mode can be switched per world.
##
## ## Cost
##
## Vertex position, normal and occlusion all come out of the eight corner
## samples the cell pass already read. The normal is the trilinear gradient of
## the density field evaluated at the cell centre, which for a binary field is
## just the sum of the four corner differences per axis -- no extra lattice
## lookups at all. Central differences would be more accurate and cost six
## trilinear samples per vertex; at 17^3 cells that is the difference between
## a few milliseconds and tens, and at a vertex sitting inside its own cell the
## two agree closely.
##
## Analytic normals rather than face normals is what makes the surface read as
## smooth instead of as a field of flat quads, and it is also what the
## slope-based material blend keys off.

const BS := GreedyMesher.BS
## Padded lattice edge: the block plus one voxel of skirt on every side.
const PAD := GreedyMesher.PAD
## Cells per axis. Voxel positions run -1..BS inclusive, so BS+1 cells.
const N := BS + 1
## Cell corner offsets. A cell's corner k sits at voxel
## (cell.x + CORNER[k].x, ...), so the corner index doubles as a bitmask of
## which axes are set -- which is what makes the axis-edge lookup a one-liner.
const CORNER := [
	Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(1, 1, 0),
	Vector3i(0, 0, 1), Vector3i(1, 0, 1), Vector3i(0, 1, 1), Vector3i(1, 1, 1),
]
## The twelve edges of a cell as corner index pairs.
const EDGES := [
	[0, 1], [2, 3], [4, 5], [6, 7],
	[0, 2], [1, 3], [4, 6], [5, 7],
	[0, 4], [1, 5], [2, 6], [3, 7],
]
## Corner k's lattice stride, so a corner's lattice index is the cell
## origin's index plus this. Corner k sits at voxel offset
## (k & 1, k >> 1 & 1, k >> 2 & 1), which is exactly what these encode.
##
## Flat ints rather than `CORNER`'s Vector3i array because this is read eight
## times per cell, and the Variant round trip per read was most of pass one.
const COFF := [
	0, 1, PAD, PAD + 1,
	PAD * PAD, PAD * PAD + 1, PAD * PAD + PAD, PAD * PAD + PAD + 1,
]
## The cell edge along each axis, as its two corner bits: the edge along axis
## i runs from corner 0 to corner (1 << i). Flat, so `EDGE_BITS[axis * 2]` and
## `EDGE_BITS[axis * 2 + 1]` are the two ends.
const EDGE_BITS := [0, 1, 0, 2, 0, 4]
## Steps in cell-index space from a cell to its three partners across the
## edge along each axis, as (du, dv) in the two perpendicular axes.
const QSTEP := [N, N * N, N * N, 1, 1, N]


## Smooth-mesh `block` with `neighbours` (Vector3i offset -> VoxelBlock).
## Returns [opaque: ArrayMesh, trans: ArrayMesh], either null when empty.
##
## Pure arithmetic plus ArrayMesh construction, exactly like `GreedyMesher`, so
## this is safe to call from a worker thread.
static func build(block: VoxelBlock, neighbours: Dictionary) -> Array:
	return GreedyMesher.to_meshes(geometry(block, neighbours))


## The pure-CPU half for the background mesher: face buffers only, no engine
## resources.
static func geometry(block: VoxelBlock, neighbours: Dictionary) -> Array:
	var ids := GreedyMesher._lattice(block, neighbours)
	var lut := GreedyMesher._lut()
	var solid: PackedByteArray = lut["solid"]
	var translucent: PackedByteArray = lut["translucent"]
	var max_id := ContentDB.MAX_ID

	# Where a cell's vertex sits, which way it faces and how dark it is, as
	# three tables indexed by the cell's mask. All three depend on nothing but
	# the eight corner flags, so building them once per chunk replaces work
	# that used to run per boundary cell -- twelve edge tests, twenty-four bit
	# reads and eight dot products each.
	var toff := PackedVector3Array()
	var tnrm := PackedVector3Array()
	var tao := PackedFloat32Array()
	_tables(toff, tnrm, tao)

	# --- pass one: boundary cells, their vertices, normals and occlusion ---
	var corners := PackedByteArray()      # per boundary cell: 8 solid flags
	corners.resize(N * N * N * 8)
	var vpos := PackedVector3Array()     # compact: one per boundary cell
	var vnorm := PackedVector3Array()    # compact: analytic normal
	var vao := PackedFloat32Array()      # compact: occlusion multiplier
	var vidx := PackedInt32Array()       # per cell: index into those, or -1
	vidx.resize(N * N * N)
	# Per-cell results of pass one that pass two would otherwise recompute.
	# Pass two asks for each once per vertex of every quad -- four times per
	# quad -- so caching them here is the difference between a few
	# milliseconds and over a hundred.
	var mask_of_cell := PackedByteArray()
	mask_of_cell.resize(N * N * N)
	var id_of_cell := PackedInt32Array()
	id_of_cell.resize(N * N * N)
	for i in vidx.size():
		vidx[i] = -1

	var any := false
	# Lattice strides, and the scratch counters `_dominant_id` counts into:
	# sized once for the whole chunk instead of a Dictionary per cell.
	var lz := PAD * PAD
	var ly := PAD
	# Packed, so the loop below reads a typed int per corner instead of a
	# Variant out of the const Array. Same table, one conversion per chunk.
	var coff := PackedInt32Array(COFF)
	var cnt := PackedInt32Array()
	cnt.resize(max_id + 1)
	for cz in N:
		for cy in N:
			for cx in N:
				var ci := _cidx(cx, cy, cz)
				# Cell (cx, cy, cz) spans voxel cx-1 and cx, because the
				# lattice holds one voxel of skirt below zero. Getting this off
				# by one samples voxel BS+1, which is past the end of the
				# lattice -- an out-of-bounds read rather than a wrong answer,
				# which is at least a loud one.
				#
				# That also means the origin's lattice index is the cell's own
				# coordinate under the lattice's stride: `_pidx` adds one back
				# to every component, and the cell origin is one below in each.
				# One multiply here instead of a `_pidx` call per corner, which
				# is 39 000 calls per chunk.
				var base := cz * lz + cy * ly + cx
				var mask := 0
				for k in 8:
					if solid[ids[base + coff[k]]] != 0:
						mask |= 1 << k
				if mask == 0 or mask == 255:
					continue
				any = true
				vidx[ci] = vpos.size()
				mask_of_cell[ci] = mask
				id_of_cell[ci] = _dominant_id(ids, base, mask, coff, cnt)
				for k in 8:
					corners[ci * 8 + k] = (mask >> k) & 1
				var off := toff[mask]
				vpos.append(Vector3(cx - 1 + off.x, cy - 1 + off.y,
					cz - 1 + off.z))
				vnorm.append(tnrm[mask])
				vao.append(tao[mask])
	if not any:
		return [{}, {}]

	# --- pass two: one quad per boundary edge ---
	var opaque := {}   # block id -> FaceBuffer
	var trans := {}
	# Per-surface map of cell -> slot in that surface's vertex arrays, so a
	# vertex shared by several quads is stored once and its normal, occlusion
	# and brightness stay consistent across all of them.
	var slots := {}
	var light := block.light
	# Scratch for a quad's four corners and its six indices, reused by every
	# quad in the chunk: these were two fresh Arrays per quad, and a chunk
	# has thousands of quads.
	var qs := [0, 0, 0, 0]
	var idx4 := [0, 0, 0, 0]

	for cz in N:
		for cy in N:
			for cx in N:
				var ci := _cidx(cx, cy, cz)
				if vidx[ci] < 0:
					continue
				var mask := int(mask_of_cell[ci])
				# Every quad belongs to the one cell whose corner 0 is the low end
				# of its edge, and every world cell belongs to exactly one chunk:
				# the one whose own 16^3 voxels contain it. In this grid that is
				# the cells with index >= 1 on every axis -- cell 0 spans the last
				# voxel of the neighbouring chunk, so it is theirs to emit.
				#
				# Getting this wrong in either direction is visible: emitting
				# those cells here duplicates the quad against the neighbour, and
				# the previous rule (skipping a cell on the outer layer of the
				# two axes its quad spans) did something worse -- it dropped quads
				# that no other chunk was left to draw, leaving a ring of holes
				# around every seam. Cell indices at or above 1 keep every partner
				# inside the grid, so the four cells are always present.
				if cx == 0 or cy == 0 or cz == 0:
					continue
				for axis in 3:
					var bit0: int = EDGE_BITS[axis * 2]
					var bit1: int = EDGE_BITS[axis * 2 + 1]
					var ca: int = (mask >> bit0) & 1
					var cb: int = (mask >> bit1) & 1
					if ca == cb:
						continue
					var du: int = QSTEP[axis * 2]
					var dv: int = QSTEP[axis * 2 + 1]
					var a := ci
					var b := ci - du
					var c := ci - dv
					var d := ci - du - dv
					if vidx[a] < 0 or vidx[b] < 0 or vidx[c] < 0 or vidx[d] < 0:
						continue
					# Corner 0 of the axis edge is solid means the surface
					# faces along +axis, and the quad winds the other way.
					qs[0] = a
					if ca != 0:
						qs[1] = d
						qs[2] = c
						qs[3] = b
					else:
						qs[1] = b
						qs[2] = c
						qs[3] = d
					_emit_quad(light, translucent, opaque, trans, slots,
						vpos, vnorm, vao, vidx, id_of_cell, qs, idx4,
						axis, 0 if ca != 0 else 1)
	return [opaque, trans]


## Solid-flag bitmask of a cell, rebuilt from the eight stored flags.
static func mask_of(corners: PackedByteArray, ci: int) -> int:
	var m := 0
	for k in 8:
		if corners[ci * 8 + k] != 0:
			m |= 1 << k
	return m


## One vertex per boundary cell: the mean of the midpoints of the twelve edges
## that straddle the boundary. On a binary field every crossing is the edge
## midpoint, so no interpolation is needed. `ox, oy, oz` is the cell's origin
## in voxel space, which for a cell spanning voxels (cx-1, cx) is cx-1.
static func _vertex(ox: int, oy: int, oz: int, mask: int) -> Vector3:
	# Accumulated as scalars rather than Vector3s: this runs twelve times per
	# boundary cell and the Vector3 arithmetic allocates, which was most of
	# the mesher's cost before it was flattened.
	var sx := 0.0
	var sy := 0.0
	var sz := 0.0
	var count := 0
	for e in EDGES.size():
		var pair: Array = EDGES[e]
		var a := (mask >> int(pair[0])) & 1
		var b := (mask >> int(pair[1])) & 1
		if a == b:
			continue
		var ca: Vector3i = CORNER[pair[0]]
		var cb: Vector3i = CORNER[pair[1]]
		sx += float(ca.x + cb.x) * 0.5
		sy += float(ca.y + cb.y) * 0.5
		sz += float(ca.z + cb.z) * 0.5
		count += 1
	if count == 0:
		return Vector3(ox, oy, oz)
	var inv := 1.0 / float(count)
	return Vector3(ox + sx * inv, oy + sy * inv, oz + sz * inv)


## Trilinear density gradient at the cell centre, as the sum of the four
## corner differences per axis. Density rises into the solid, so the outward
## normal is the negated gradient.
static func _gradient(mask: int) -> Vector3:
	var g := Vector3(
		_bit(mask, 1) - _bit(mask, 0)
			+ _bit(mask, 3) - _bit(mask, 2)
			+ _bit(mask, 5) - _bit(mask, 4)
			+ _bit(mask, 7) - _bit(mask, 6),
		_bit(mask, 2) - _bit(mask, 0)
			+ _bit(mask, 3) - _bit(mask, 1)
			+ _bit(mask, 6) - _bit(mask, 4)
			+ _bit(mask, 7) - _bit(mask, 5),
		_bit(mask, 4) - _bit(mask, 0)
			+ _bit(mask, 5) - _bit(mask, 1)
			+ _bit(mask, 6) - _bit(mask, 2)
			+ _bit(mask, 7) - _bit(mask, 3))
	if g.length_squared() < 1e-9:
		# Flat cell (which a boundary cell never is, but a degenerate one
		# could be): fall back to the axis with the most solid corners.
		return Vector3.UP
	return -g.normalized()


static func _bit(mask: int, k: int) -> float:
	return float((mask >> k) & 1)


## Occlusion from the eight voxels around the vertex, counting only those on
## the far side of the surface -- the ones actually between it and the sky.
## Same curve as the greedy mesher's, so lighting matches between modes.
static func _occlusion(ox: int, oy: int, oz: int, mask: int,
		n: Vector3) -> float:
	var occ := 0
	for k in 8:
		# Is this corner on the far side of the surface? The cell origin is a
		# constant offset for all eight corners and drops out of the sign
		# test, so the corner offset against the normal is the whole question.
		var c: Vector3i = CORNER[k]
		var side := float(c.x) * n.x + float(c.y) * n.y + float(c.z) * n.z
		if side <= 0.0:
			continue
		if ((mask >> k) & 1) != 0:
			occ += 1
	return GreedyMesher.AO_LEVELS[3 - mini(3, occ)]


## Append one quad, reusing a vertex when this surface already has it.
##
## `qs` and `idx4` are scratch the caller owns and reuses for every quad in
## the chunk. They used to be allocated here: two Arrays per quad, times
## thousands of quads, was a measurable share of pass two.
static func _emit_quad(light: PackedByteArray,
		translucent: PackedByteArray,
		opaque: Dictionary, trans: Dictionary, slots: Dictionary,
		vpos: PackedVector3Array, vnorm: PackedVector3Array,
		vao: PackedFloat32Array, vidx: PackedInt32Array,
		id_of_cell: PackedInt32Array, qs: Array, idx4: Array, axis: int,
		dir: int) -> void:
	var id: int = id_of_cell[qs[0]]
	if id <= 0:
		return
	var store := trans if translucent[id] != 0 else opaque
	var buf: GreedyMesher.FaceBuffer = GreedyMesher._buffer_for(store, id)
	if not slots.has(id):
		slots[id] = {}
	var surf: Dictionary = slots[id]

	var shade: float = GreedyMesher.FACE_SHADE[axis * 2 + dir]
	var pal := ContentDB.color_of(id)
	var emit := float(ContentDB.light_of(id)) / 15.0
	# Collect all four slots FIRST, then emit the indices.
	#
	# Appending the indices from a `base` captured before the loop was wrong
	# the moment two of the four vertices already existed in this surface: the
	# quad's indices would point at a run that started before them, producing
	# zero-area triangles and, past the end of the array, reads that fault.
	# This is why the degenerate-quad check in surface_nets_test is worth
	# having -- the failure is not a wrong colour, it is a corrupt index.
	for k in 4:
		var c: int = qs[k]
		if surf.has(c):
			idx4[k] = int(surf[c])
			continue
		var vi: int = vidx[c]
		var p := vpos[vi]
		var slot: int = buf.vertices.size()
		surf[c] = slot
		idx4[k] = slot
		buf.vertices.append(p)
		buf.normals.append(vnorm[vi])
		var uv := _uv(p, axis)
		buf.uvs.append(uv)
		buf.uv2s.append(uv * 0.25)
		var ao: float = vao[vi]
		var day := _daylight(light, p)
		var bright := clampf(shade * (0.25 + 0.75 * day) * ao + emit * 0.9,
			0.08, 1.0)
		buf.colors.append(Color(pal.r * bright, pal.g * bright,
			pal.b * bright, 1.0))
	buf.indices.append(idx4[0])
	buf.indices.append(idx4[1])
	buf.indices.append(idx4[2])
	buf.indices.append(idx4[0])
	buf.indices.append(idx4[2])
	buf.indices.append(idx4[3])


## Fill the per-mask tables: vertex offset from the cell origin, outward
## normal, and occlusion multiplier. Each entry is a pure function of the
## eight corner flags, so the same cell shape always maps to the same vertex,
## the same normal and the same shadow wherever it appears in the chunk.
static func _tables(toff: PackedVector3Array, tnrm: PackedVector3Array,
		tao: PackedFloat32Array) -> void:
	toff.resize(256)
	tnrm.resize(256)
	tao.resize(256)
	for mask in 256:
		var nrm := _gradient(mask)
		tnrm[mask] = nrm
		# The cell origin cancels out of `_vertex`'s result, so the table
		# holds the offset from it and pass one adds the origin back.
		toff[mask] = _vertex(0, 0, 0, mask)
		tao[mask] = _occlusion(0, 0, 0, mask, nrm)


## Block id of the most common solid corner of a cell. Picking the dominant id
## rather than the first one keeps a vertex where dirt meets stone on the
## surface that dominates instead of on whichever was visited first.
##
## Counted into the caller's scratch array rather than a Dictionary: this runs
## once per boundary cell, and a fresh Dictionary each time cost several
## microseconds. Ties still go to the id that appears first, which needs the
## counts to be final before anything is compared -- hence the second pass over
## the corners, and the third that clears what this cell touched.
static func _dominant_id(ids: PackedInt32Array, base: int, mask: int,
		coff: PackedInt32Array, cnt: PackedInt32Array) -> int:
	for k in 8:
		if (mask >> k) & 1 == 0:
			continue
		var id := ids[base + coff[k]]
		if id > 0 and id < cnt.size():
			cnt[id] += 1
	var best := 0
	var best_n := 0
	for k in 8:
		if (mask >> k) & 1 == 0:
			continue
		var id := ids[base + coff[k]]
		if id <= 0 or id >= cnt.size():
			continue
		if cnt[id] > best_n:
			best_n = cnt[id]
			best = id
	for k in 8:
		if (mask >> k) & 1 == 0:
			continue
		var id := ids[base + coff[k]]
		if id > 0 and id < cnt.size():
			cnt[id] = 0
	return best


## Daylight at the voxel a mesh-space point falls in.
static func _daylight(light: PackedByteArray, p: Vector3) -> float:
	var x := clampi(floori(p.x), 0, BS - 1)
	var y := clampi(floori(p.y), 0, BS - 1)
	var z := clampi(floori(p.z), 0, BS - 1)
	# The day light is the low nibble -- the nibble every other reader in the
	# codebase takes (`VoxelBlock.get_day_light`, the AO term in the greedy
	# mesher). Masking 0x3F and dividing by 4 pulled in two bits of the other
	# nibble and left the top two out, so the result could exceed 1.0 and the
	# surface was shaded by a number that was not a light level at all.
	return clampf(float(light[MapNode.index(x, y, z)] & 0x0F)
		/ float(MapNode.LIGHT_SUN), 0.0, 1.0)


## UVs in block units, projected on the plane the quad faces.
static func _uv(p: Vector3, axis: int) -> Vector2:
	if axis == 0:
		return Vector2(p.z, p.y)
	if axis == 1:
		return Vector2(p.x, p.z)
	return Vector2(p.x, p.y)


## Index step between consecutive cells along one axis.
static func _istep(axis: int) -> int:
	if axis == 0:
		return 1
	if axis == 1:
		return N
	return N * N


## Cell index for a cell coordinate in 0..BS.
static func _cidx(x: int, y: int, z: int) -> int:
	return z * N * N + y * N + x


## One component of a cell's coordinate, recovered from its flat index.
static func _cell_axis(ci: int, axis: int) -> int:
	if axis == 0:
		return ci % N
	if axis == 1:
		return (ci / N) % N
	return ci / (N * N)