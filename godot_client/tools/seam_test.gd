extends SceneTree
## Chunk seam correctness.
##
## A chunk is meshed from its own block plus whichever neighbours are
## currently resident. If neighbour sampling is wrong, the result is a world
## with visible cracks along chunk borders -- and it is invisible to any test
## that only meshes one block in isolation, which is what every previous
## meshing test did.
##
## The invariant: meshing a block together with its neighbours must produce
## exactly the same geometry as meshing the same voxels as one large region.
## Faces that get culled against a neighbour must not be culled when that
## neighbour is absent, and faces that survive must not appear twice.

var failures := 0


func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: ", msg)


func _init() -> void:
	_test_neighbour_sampling_follows_into_adjacent_blocks()
	_test_faces_are_not_double_emitted_across_a_seam()
	_test_seam_with_a_fully_solid_neighbour()
	_test_faces_are_not_left_open_across_a_seam()
	_test_all_six_directions_and_negative_coordinates()
	_test_corners_and_edges()
	_test_unloaded_neighbour_is_treated_as_air()
	_test_index_roundtrip()
	# tools/run_tests.sh matches a verdict line at column 0, the same
	# convention every other suite follows.
	print("seams: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)


# --- helpers ---------------------------------------------------------------

func _empty() -> VoxelBlock:
	var b := VoxelBlock.new()
	b.is_loaded = true
	b.is_generated = true
	return b


func _lit(b: VoxelBlock) -> VoxelBlock:
	b.fill(MapNode.LIGHT_SUN | (MapNode.LIGHT_SUN << 4))
	return b


## Total triangles across both passes.
static func _tri_count(meshes: Array) -> int:
	var n := 0
	for m in meshes:
		if m == null:
			continue
		n += _mesh_tris(m)
	return n


static func _mesh_tris(m: ArrayMesh) -> int:
	var n := 0
	for s in m.get_surface_count():
		var idx: PackedInt32Array = m.surface_get_arrays(s)[Mesh.ARRAY_INDEX]
		n += idx.size() / 3
	return n


## Every vertex of a mesh, for cross-pass comparisons.
static func _verts(m: ArrayMesh) -> PackedVector3Array:
	var out := PackedVector3Array()
	if m == null:
		return out
	for s in m.get_surface_count():
		out.append_array(m.surface_get_arrays(s)[Mesh.ARRAY_VERTEX])
	return out


func _at(b: VoxelBlock, x: int, y: int, z: int) -> int:
	return b.content[MapNode.index(x, y, z)]


# --- tests -----------------------------------------------------------------

## `_sample` must follow into a neighbouring block when the coordinate leaves
## the current one, and must land on the right voxel once it does.
func _test_neighbour_sampling_follows_into_adjacent_blocks() -> void:
	# The centre voxel must sit against the face being tested, so for a +axis
	# neighbour it goes at local 15 and the neighbour's voxel at local 0.
	# Placing both at local 8 samples empty space inside the centre block and
	# correctly culls nothing -- which is what an earlier draft of this test
	# did, and it passed for the wrong reason.
	for axis in 3:
		for dir in [1, -1]:
			var centre := _lit(_empty())
			var own := Vector3i(8, 8, 8)
			own[axis] = 15 if dir == 1 else 0
			centre.content[MapNode.index(own.x, own.y, own.z)] = \
				ContentDB.STONE
			var nb := _lit(_empty())
			var other := Vector3i(8, 8, 8)
			other[axis] = 0 if dir == 1 else 15
			nb.content[MapNode.index(other.x, other.y, other.z)] = \
				ContentDB.DEEPSLATE
			var nbo := Vector3i.ZERO
			nbo[axis] = dir
			var alone := _tri_count(GreedyMesher.build(centre, {}))
			var withn := _tri_count(GreedyMesher.build(centre, {nbo: nb}))
			check(alone - withn == 2,
				"axis %d dir %d: a solid neighbour must cull exactly one "
				% [axis, dir]
				+ "quad (2 tris); alone %d, with neighbour %d"
				% [alone, withn])


## Faces along one axis, as a multiset of plane coordinates.
static func _faces_on_axis(verts: PackedVector3Array, axis: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for v in verts:
		var c := v.x
		if axis == 1:
			c = v.y
		elif axis == 2:
			c = v.z
		out.append(c)
	out.sort()
	return out


static func _count_on(vals: PackedFloat32Array, at: float) -> int:
	var n := 0
	for v in vals:
		if absf(v - at) < 0.001:
			n += 1
	return n


## Two blocks side by side must produce no coincident faces: one face per
## shared boundary, not two, and not zero.
func _test_faces_are_not_double_emitted_across_a_seam() -> void:
	var left := _lit(_empty())
	var right := _lit(_empty())
	# A full 16x16 wall split across the seam at x=15/16.
	for y in 16:
		for z in 16:
			left.content[MapNode.index(15, y, z)] = ContentDB.STONE
			right.content[MapNode.index(0, y, z)] = ContentDB.STONE
	var neighbours := {Vector3i(1, 0, 0): right}
	var tris := _tri_count(GreedyMesher.build(left, neighbours))
	# A 16x16x1 slab has 6 faces = 12 triangles on its own. Loading the
	# neighbour fills the +X seam, so that one quad must go.
	check(tris == 10,
		"a 16x16x1 slab should mesh to 10 triangles with the seam filled, "
		+ "got %d" % tris)
	var alone := _tri_count(GreedyMesher.build(left, {}))
	check(alone == 12,
		"without the neighbour the seam face must appear: 12 triangles "
		+ "expected, got %d" % alone)


## The same in reverse: a seam face must not be dropped when the neighbour is
## merely missing rather than empty.
func _test_faces_are_not_left_open_across_a_seam() -> void:
	var b := _lit(_empty())
	for y in 16:
		for z in 16:
			b.content[MapNode.index(15, y, z)] = ContentDB.STONE
	var with_air := _tri_count(GreedyMesher.build(b, {}))
	var with_stone := _tri_count(GreedyMesher.build(
		b, {Vector3i(1, 0, 0): _lit(_full(ContentDB.STONE))}))
	check(with_air - with_stone == 2,
		"a solid neighbour should remove exactly one quad (2 triangles): "
		+ "air %d, solid %d" % [with_air, with_stone])


## A full solid neighbour must cull exactly one quad: the +X face.
func _test_seam_with_a_fully_solid_neighbour() -> void:
	var b := _lit(_empty())
	for y in 16:
		for z in 16:
			b.content[MapNode.index(15, y, z)] = ContentDB.STONE
	var air := _tri_count(GreedyMesher.build(b, {Vector3i(1, 0, 0): _air()}))
	var solid := _tri_count(GreedyMesher.build(
		b, {Vector3i(1, 0, 0): _lit(_full(ContentDB.STONE))}))
	check(air - solid == 2,
		"a solid neighbour should remove exactly one quad (2 triangles): "
		+ "air %d, solid %d" % [air, solid])
	# With the seam filled, no FACE may lie on the shared plane. Vertices can
	# legitimately sit there -- the slab's top and bottom quads span the full
	# width and end at x=16 -- so this checks the face normals, not positions.
	var mesh: ArrayMesh = GreedyMesher.build(
		b, {Vector3i(1, 0, 0): _lit(_full(ContentDB.STONE))})[0]
	var on_seam := 0
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for t in range(0, idx.size(), 3):
			var n: Vector3 = norms[idx[t]]
			if absf(n.x) < 0.5:
				continue
			var p: Vector3 = verts[idx[t]]
			if absf(p.x - 16.0) < 0.001:
				on_seam += 1
	check(on_seam == 0,
		"with a solid +X neighbour no face may lie on the shared plane, "
		+ "found %d" % on_seam)
	# And the -X face at x=15 must still be there, or the slab would be
	# invisible from one side.
	var minus_x := 0
	for s in mesh.get_surface_count():
		var arrays2 := mesh.surface_get_arrays(s)
		var v2: PackedVector3Array = arrays2[Mesh.ARRAY_VERTEX]
		var n2: PackedVector3Array = arrays2[Mesh.ARRAY_NORMAL]
		var i2: PackedInt32Array = arrays2[Mesh.ARRAY_INDEX]
		for t in range(0, i2.size(), 3):
			if absf(n2[i2[t]].x) < 0.5:
				continue
			if absf(v2[i2[t]].x - 15.0) < 0.001:
				minus_x += 1
	check(minus_x > 0, "the -X face at x=15 disappeared; the slab would be "
		+ "see-through from one side")


func _air() -> VoxelBlock:
	var b := VoxelBlock.new()
	for i in b.content.size():
		b.content[i] = ContentDB.AIR
	b.is_loaded = true
	b.is_generated = true
	return b


func _full(id: int) -> VoxelBlock:
	var b := VoxelBlock.new()
	for i in b.content.size():
		b.content[i] = id
	# `is_loaded` defaults to false, and the mesher now (correctly) refuses to
	# sample an incomplete neighbour, so a fixture that wants to be trusted
	# has to say it is ready.
	b.is_loaded = true
	b.is_generated = true
	return b


## All six directions, and the same thing in negative chunk coordinates where
## the floor()/int() conversions in `_sample` are easy to get wrong.
func _test_all_six_directions_and_negative_coordinates() -> void:
	var dirs := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
		Vector3i(0, 1, 0), Vector3i(0, -1, 0),
		Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
	for d in dirs:
		var axis := 0
		if d.y != 0:
			axis = 1
		elif d.z != 0:
			axis = 2
		# The centre voxel hugs the tested face; the neighbour's voxel is the
		# mirror image of it in its own block.
		var centre := _lit(_empty())
		var own := Vector3i(8, 8, 8)
		own[axis] = 15 if d[axis] > 0 else 0
		centre.content[MapNode.index(own.x, own.y, own.z)] = ContentDB.STONE
		var nb := _lit(_empty())
		var other := Vector3i(8, 8, 8)
		other[axis] = 0 if d[axis] > 0 else 15
		nb.content[MapNode.index(other.x, other.y, other.z)] = \
			ContentDB.DEEPSLATE
		var alone := _tri_count(GreedyMesher.build(centre, {}))
		var withn := _tri_count(GreedyMesher.build(centre, {d: nb}))
		check(alone - withn == 2,
			"direction %s: a solid neighbour must remove exactly one quad "
			% d + "(2 tris); alone %d, with %d" % [alone, withn])


## Diagonal neighbours: only the six face-adjacent ones affect culling, so a
## purely diagonal neighbour must change nothing.
func _test_corners_and_edges() -> void:
	var b := _lit(_empty())
	b.content[MapNode.index(8, 8, 8)] = ContentDB.STONE
	var alone := _tri_count(GreedyMesher.build(b, {}))
	var diagonals := [
		Vector3i(1, 1, 0), Vector3i(1, -1, 0), Vector3i(1, 0, 1),
		Vector3i(1, 0, -1), Vector3i(0, 1, 1), Vector3i(0, 1, -1),
		Vector3i(1, 1, 1), Vector3i(1, 1, -1), Vector3i(1, -1, 1),
		Vector3i(-1, 1, 1),
	]
	for d in diagonals:
		var nb := _lit(_empty())
		# Fill the touching corner of the diagonal block.
		var nlocal := Vector3i(15, 15, 15)
		if d.x > 0:
			nlocal.x = 0
		if d.y > 0:
			nlocal.y = 0
		if d.z > 0:
			nlocal.z = 0
		nb.content[MapNode.index(nlocal.x, nlocal.y, nlocal.z)] = \
			ContentDB.DEEPSLATE
		var withn := _tri_count(GreedyMesher.build(b, {d: nb}))
		check(alone == withn,
			"a purely diagonal neighbour at %s must not cull any face "
			% d + "(alone %d, with %d)" % [alone, withn])


## A neighbour that has not streamed in yet must be treated as air, never as
## solid: treating it as solid would leave holes that pop in as it loads.
func _test_unloaded_neighbour_is_treated_as_air() -> void:
	var b := _lit(_empty())
	for y in 16:
		for z in 16:
			b.content[MapNode.index(15, y, z)] = ContentDB.STONE
	var no_neighbour := _tri_count(GreedyMesher.build(b, {}))
	# A GENERATED-but-not-loaded block must be ignored too, so a half-loaded
	# world never culls faces against data it is not allowed to trust.
	var ghost := _full(ContentDB.STONE)
	ghost.is_loaded = false
	ghost.is_generated = true
	var with_ghost := _tri_count(GreedyMesher.build(
		b, {Vector3i(1, 0, 0): ghost}))
	check(no_neighbour == with_ghost,
		"an unloaded neighbour must not cull faces (absent %d, ghost %d)"
		% [no_neighbour, with_ghost])
	# And it must equal the all-air neighbour case.
	var air := _full(ContentDB.AIR)
	air.is_loaded = true
	air.is_generated = true
	var with_air := _tri_count(GreedyMesher.build(b, {Vector3i(1, 0, 0): air}))
	check(no_neighbour == with_air,
		"an absent neighbour and an all-air neighbour must agree "
		+ "(%d vs %d)" % [no_neighbour, with_air])


## index() and unindex() must be exact inverses over the whole block, which
## is the assumption every other formula in the mesher rests on.
func _test_index_roundtrip() -> void:
	var bad := 0
	for z in 16:
		for y in 16:
			for x in 16:
				var idx := MapNode.index(x, y, z)
				if idx < 0 or idx >= MapNode.BLOCK_VOLUME:
					bad += 1
					continue
				if MapNode.unindex(idx) != Vector3i(x, y, z):
					bad += 1
	check(bad == 0, "%d index/unindex roundtrip(s) failed" % bad)
	# The formula must be the documented one, so the layout stays compatible
	# with the serialized format.
	var mismatch := 0
	for z in 16:
		for y in 16:
			for x in 16:
				if MapNode.index(x, y, z) != z * 256 + y * 16 + x:
					mismatch += 1
	check(mismatch == 0,
		"MapNode.index must be z*256 + y*16 + x (%d mismatches)" % mismatch)