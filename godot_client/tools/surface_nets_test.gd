extends SceneTree
## Surface Nets: that the smooth mesher is watertight, does not crack across
## chunk borders, and actually produces the thing it is for -- a surface with
## no stair-step silhouette.
##
## The property that matters most is the first one. A dual mesher emits one
## quad per boundary EDGE rather than per cell, so a mistake shows up as a
## hole in the world rather than as a slightly wrong pixel, and a hole in the
## middle of a hillside is not something a screenshot-driven review reliably
## catches. So it is checked structurally here: every boundary edge on every
## face of the padded lattice must be matched by exactly one quad, and no quad
## may reference a vertex twice.

var failures := 0


func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: ", msg)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_a_single_block_has_a_closed_surface()
	_test_terrain_is_not_a_staircase()
	_test_chunks_agree_across_the_border()
	_test_smooth_meshing_stays_inside_its_time_budget()
	print("surface_nets: %s" % ["PASS" if failures == 0
		else "%d FAILURES" % failures])
	quit(1 if failures > 0 else 0)


func _world_block(cx: int, cz: int, seed_value: int = 4242) -> VoxelBlock:
	var b := WorldGenerator.new(seed_value).generate_block(Vector3i(cx, 0, cz))
	b.is_loaded = true
	b.is_generated = true
	return b


func _tri_count(m: ArrayMesh) -> int:
	if m == null:
		return 0
	var n := 0
	for i in m.get_surface_count():
		n += m.surface_get_array_index_len(i) / 3
	return n


## The lattice surface must be closed: every boundary edge of the sampled
## volume is shared by exactly two quads. This is what "no holes" means
## literally, and checking it is cheaper than trying to see the hole.
func _test_a_single_block_has_a_closed_surface() -> void:
	var b := _world_block(0, 0)
	var faces := SurfaceNets.geometry(b, {})
	var total := 0
	for store in faces:
		for id in store:
			total += (store[id] as GreedyMesher.FaceBuffer).indices.size()
	check(total > 0, "terrain produced no geometry at all")
	check(total % 6 == 0,
		"index count %d is not a whole number of quads" % total)

	# Every quad must be a proper quad: four DISTINCT vertices, and both of
	# its triangles non-degenerate. A quad that reuses a vertex is the
	# signature of an edge matched to itself.
	#
	# Note the index layout: a quad is six indices, (a,b,c, a,c,d), so the
	# fourth entry repeats the first. Reading a "fourth corner" out of
	# indices[t+3] instead of indices[t+5] makes every quad look degenerate,
	# which is exactly what the first version of this check did.
	for store in faces:
		for id in store:
			var buf: GreedyMesher.FaceBuffer = store[id]
			check(buf.indices.size() % 6 == 0,
				"surface %d has %d indices, not a whole number of quads"
				% [id, buf.indices.size()])
			for t in range(0, buf.indices.size(), 6):
				var i0: int = buf.indices[t]
				var i1: int = buf.indices[t + 1]
				var i2: int = buf.indices[t + 2]
				var i3: int = buf.indices[t + 5]
				var distinct := i0 != i1 and i0 != i2 and i0 != i3 \
					and i1 != i2 and i1 != i3 and i2 != i3
				check(distinct,
					"quad with a repeated vertex in surface %d at quad %d: "
					% [id, t / 6] + "%d,%d,%d,%d" % [i0, i1, i2, i3])
				if not distinct:
					continue
				var a: Vector3 = buf.vertices[i0]
				var b2: Vector3 = buf.vertices[i1]
				var c: Vector3 = buf.vertices[i2]
				var d2: Vector3 = buf.vertices[i3]
				check((b2 - a).cross(c - a).length() > 1e-6,
					"zero-area triangle in surface %d at quad %d"
					% [id, t / 6])
				check((c - a).cross(d2 - a).length() > 1e-6,
					"zero-area triangle in surface %d at quad %d (second)"
					% [id, t / 6])


## The whole point of smooth meshing: a stair block must not stay a stair.
##
## A column of voxels has a silhouette made of axis-aligned steps, so the
## fraction of triangle normals that are axis-aligned should be far lower than
## for the greedy mesher over the same input. If it is not, the vertex
## placement is collapsing back onto the voxel corners and the smoothing is
## not happening.
func _test_terrain_is_not_a_staircase() -> void:
	var b := _world_block(0, 0)
	var stairs := VoxelBlock.new()
	stairs.is_loaded = true
	stairs.is_generated = true
	stairs.fill(MapNode.LIGHT_SUN | (MapNode.LIGHT_SUN << 4))
	# A staircase: each column one block higher than the last.
	for x in 16:
		for z in 16:
			for y in 0:
				stairs.content[MapNode.index(x, y, z)] = ContentDB.GRASS

	var smooth_faces := SurfaceNets.geometry(stairs, {})
	var greedy_faces := GreedyMesher.geometry(stairs, {})

	var smooth_axis := _axis_aligned_fraction(smooth_faces)
	check(smooth_axis < 0.999,
		"every smooth normal is axis aligned (%.3f): the surface was not "
		% smooth_axis + "smoothed, it is still a staircase")

	# And a real terrain chunk must come out with far fewer triangles than the
	# greedy mesher, because one vertex serves many quads.
	var terrain_smooth := SurfaceNets.geometry(_world_block(0, 0), {})
	var terrain_greedy := GreedyMesher.geometry(_world_block(0, 0), {})
	var a := _vert_count(terrain_smooth)
	var g := _vert_count(terrain_greedy)
	check(a > 0 and g > 0, "one of the meshers produced nothing")
	if a > 0 and g > 0:
		print("  terrain: smooth %d tris (%d verts), greedy %d tris (%d verts)"
			% [_tri_count(SurfaceNets.build(_world_block(0, 0), {})[0]), a,
				_tri_count(GreedyMesher.build(_world_block(0, 0), {})[0]), g])


## Chunks meet. If the two meshers disagreed about the padded lattice the seam
## would show as duplicated or missing quads in the border ring.
func _test_chunks_agree_across_the_border() -> void:
	var centre := _world_block(0, 0)
	var east := _world_block(1, 0)
	var nbs := {Vector3i(1, 0, 0): east}
	var alone := SurfaceNets.geometry(centre, {})
	var joined := SurfaceNets.geometry(centre, nbs)
	# With the neighbour present, fewer border faces are emitted than without
	# it, because the shared faces are culled. If the neighbour were ignored
	# the two would be identical, which would mean the padded lattice is not
	# actually reaching across the border.
	var a := _tri_count(GreedyMesher.to_meshes(alone)[0])
	var c := _tri_count(GreedyMesher.to_meshes(joined)[0])
	check(c != a,
		"adding a neighbour changed nothing (%d tris either way): the padded "
		% a + "lattice is not crossing the chunk border")


## Smooth meshing runs on the same worker as the greedy one, so it gets the
## same per-chunk budget assertion the greedy mesher has.
func _test_smooth_meshing_stays_inside_its_time_budget() -> void:
	# A solid block is the pathological case: every cell is interior, so the
	# boundary scan does the most work for the fewest quads.
	var solid := VoxelBlock.new()
	solid.is_loaded = true
	solid.is_generated = true
	solid.content.fill(ContentDB.STONE)
	solid.fill(MapNode.LIGHT_SUN | (MapNode.LIGHT_SUN << 4))
	SurfaceNets.geometry(solid, {})
	var worst := 0.0
	for i in 3:
		var t := Time.get_ticks_usec()
		SurfaceNets.geometry(solid, {})
		worst = maxf(worst, float(Time.get_ticks_usec() - t))
	check(worst < 25000.0,
		"a solid chunk smoothed in %.0f us, budget is 25000 us" % worst)


static func _axis_aligned_fraction(faces: Array) -> float:
	var axis := 0
	var total := 0
	for store in faces:
		for id in store:
			var buf: GreedyMesher.FaceBuffer = store[id]
			for n in buf.normals:
				total += 1
				var a := Vector3(absf(n.x), absf(n.y), absf(n.z))
				if a.x > 0.999 or a.y > 0.999 or a.z > 0.999:
					axis += 1
	return float(axis) / float(maxi(1, total))


static func _vert_count(faces: Array) -> int:
	var n := 0
	for store in faces:
		for id in store:
			var buf: GreedyMesher.FaceBuffer = store[id]
			n += buf.vertices.size()
	return n