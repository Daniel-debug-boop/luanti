extends SceneTree
## Mesher tests against ContentDB: geometry counts, greedy merging, palette
## colors, per-block-id surfaces, tiled UVs, ambient occlusion, translucent
## pass separation, and the all-air fast path.

var failures := 0


func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: ", msg)


func _init() -> void:
	_test_winding_matches_normal()
	_test_faces_land_on_their_own_voxel()
	_test_ao_colour_stays_with_its_corner()
	_test_geometry_invariants()
	_test_a_chunk_mesh_stays_under_its_budget()
	# --- Isolated block: exactly 12 triangles (6 faces x 2) ---
	var solo := VoxelBlock.new()
	solo.is_loaded = true
	solo.is_generated = true
	solo.content[MapNode.index(8, 8, 8)] = ContentDB.STONE
	# Real generated blocks carry daylight; without it every face would be
	# pitch black, which is not what the mesher should be judged on.
	solo.fill(MapNode.LIGHT_SUN | (MapNode.LIGHT_SUN << 4))
	var solo_meshes := GreedyMesher.build(solo, {})
	check(_tris(solo_meshes[0]) == 12,
		"isolated block should be 12 triangles, got %s" % _tris(solo_meshes[0]))

	# --- Isolated block colors come from the palette ---
	var cols: PackedColorArray = _colors(solo_meshes[0])
	check(cols.size() > 0, "opaque mesh has no vertex colors")
	if cols.size() > 0:
		# Face shading darkens it, so check hue family, not exact equality.
		check(cols[0].b > 0.2 and cols[0].r > 0.2,
			"stone color not applied (got %s)" % cols[0])

	# --- One surface per block id, named with the id ---
	check(solo_meshes[0].get_surface_count() == 1,
		"a single block should make one surface, got %d"
			% solo_meshes[0].get_surface_count())
	var ids := GreedyMesher.surface_ids(solo_meshes[0])
	check(ids.size() == 1 and ids[0] == ContentDB.STONE,
		"surface should be named with the block id, got %s" % [ids])

	# --- Flat slab: merges to 6 faces / 12 triangles ---
	var slab := VoxelBlock.new()
	slab.is_loaded = true
	slab.is_generated = true
	slab.fill(MapNode.LIGHT_SUN | (MapNode.LIGHT_SUN << 4))
	for x in 16:
		for z in 16:
			slab.content[MapNode.index(x, 0, z)] = ContentDB.STONE
	var slab_meshes := GreedyMesher.build(slab, {})
	check(_tris(slab_meshes[0]) == 12,
		"flat slab should merge to 12 triangles, got %s" % _tris(slab_meshes[0]))

	# --- UVs are in block units so a photo texture tiles per block ---
	var slab_uvs: PackedVector2Array = _uvs(slab_meshes[0])
	var max_u := 0.0
	var max_v := 0.0
	for uv in slab_uvs:
		max_u = maxf(max_u, uv.x)
		max_v = maxf(max_v, uv.y)
	print("slab uv extent: %.0f x %.0f blocks" % [max_u, max_v])
	check(max_u >= 15.0 and max_v >= 15.0,
		"merged 16x16 quad should span 16 uv tiles, got %.1f x %.1f"
			% [max_u, max_v])

	# --- Two different block ids make two surfaces ---
	var mixed := VoxelBlock.new()
	mixed.is_loaded = true
	mixed.is_generated = true
	mixed.fill(MapNode.LIGHT_SUN | (MapNode.LIGHT_SUN << 4))
	for x in 16:
		mixed.content[MapNode.index(x, 8, 8)] = ContentDB.STONE
		mixed.content[MapNode.index(x, 4, 8)] = ContentDB.DIRT
	var mixed_meshes := GreedyMesher.build(mixed, {})
	var mixed_ids := GreedyMesher.surface_ids(mixed_meshes[0])
	mixed_ids.sort()
	print("mixed-block surfaces: ", mixed_ids)
	check(mixed_meshes[0].get_surface_count() == 2,
		"two block ids should make two surfaces, got %d"
			% mixed_meshes[0].get_surface_count())
	check(mixed_ids.size() == 2 and mixed_ids[0] == ContentDB.DIRT
			and mixed_ids[1] == ContentDB.STONE,
		"surfaces should be named for each id, got %s" % [mixed_ids])

	# --- Emissive block is brighter than the same-shaded plain block ---
	var glow := VoxelBlock.new()
	glow.is_loaded = true
	glow.is_generated = true
	glow.fill(MapNode.LIGHT_SUN | (MapNode.LIGHT_SUN << 4))
	glow.content[MapNode.index(8, 8, 8)] = ContentDB.GLOWSTONE
	var gm: PackedColorArray = _colors(GreedyMesher.build(glow, {})[0])
	if cols.size() > 0 and gm.size() > 0:
		check(gm[0].r > cols[0].r + 0.3,
			"emissive block not brighter (%s vs %s)" % [gm[0], cols[0]])

	# --- Water lands in the translucent pass ---
	var pond := VoxelBlock.new()
	pond.is_loaded = true
	pond.is_generated = true
	pond.fill(MapNode.LIGHT_SUN | (MapNode.LIGHT_SUN << 4))
	for y in 4:
		for x in 16:
			for z in 16:
				pond.content[MapNode.index(x, y, z)] = ContentDB.WATER
	var pond_meshes := GreedyMesher.build(pond, {})
	check(pond_meshes[0] == null, "water should not be in the opaque pass")
	check(_tris(pond_meshes[1]) > 0, "water should be in the translucent pass")

	# --- All-air block skips meshing entirely ---
	var empty := VoxelBlock.new()
	empty.is_loaded = true
	empty.is_generated = true
	var empty_meshes := GreedyMesher.build(empty, {})
	check(empty_meshes[0] == null and empty_meshes[1] == null,
		"all-air block should produce no meshes")

	# --- Ambient occlusion darkens a face tucked into a corner ---
	check(_ao_darkens(), "ambient occlusion did not darken a tucked-in face")

	# --- Every block id resolves to a material with a texture when present ---
	var lib := MaterialLibrary.new()
	lib.prime()
	print("material library: ", lib.describe())
	check(lib.loaded_count() >= 5,
		"expected the downloaded texture sets to load, got %d"
			% lib.loaded_count())
	check(lib.material_for(ContentDB.GRASS).albedo_texture != null,
		"grass has no albedo texture")
	check(lib.material_for(ContentDB.GRASS).vertex_color_use_as_albedo,
		"textured material must keep vertex_color_use_as_albedo for AO tinting")
	check(lib.material_for(ContentDB.WATER).transparency
			!= BaseMaterial3D.TRANSPARENCY_DISABLED,
		"water material must be transparent")
	# Ids with no texture set fall back to the plain vertex-color material.
	check(lib.material_for(ContentDB.GLOWSTONE)
			== lib.material_for(ContentDB.GLOWSTONE),
		"glowstone material should be stable")
	check(MaterialLibrary.texture_set_for(ContentDB.GRAVEL) == "aerial_rocks_02",
		"gravel should map to a downloaded texture set")

	print("\nmesher: %s" % ("PASS" if failures == 0
		else "%d FAILURES" % failures))
	quit(1 if failures > 0 else 0)


## A stone face with stone above and beside it must be darker than the same
## face in open air.
func _ao_darkens() -> bool:
	# A 3x3 pad of stone: the top face is one merged quad whose four corners
	# sit in open air, so all four shade identically.
	var open := VoxelBlock.new()
	open.is_loaded = true
	open.is_generated = true
	open.fill(MapNode.LIGHT_SUN | (MapNode.LIGHT_SUN << 4))
	for x in range(6, 9):
		for z in range(6, 9):
			open.content[MapNode.index(x, 8, z)] = ContentDB.STONE
	var open_mesh: ArrayMesh = GreedyMesher.build(open, {})[0]
	var open_top := _top_face_colors(open_mesh)
	if open_top.is_empty():
		print("AO: could not isolate the top face")
		return false

	# The same pad with a stone sitting diagonally on one corner: that corner
	# now has an occluder, the other three do not.
	var tucked := VoxelBlock.new()
	tucked.is_loaded = true
	tucked.is_generated = true
	tucked.fill(MapNode.LIGHT_SUN | (MapNode.LIGHT_SUN << 4))
	for x in range(6, 9):
		for z in range(6, 9):
			tucked.content[MapNode.index(x, 8, z)] = ContentDB.STONE
	tucked.content[MapNode.index(9, 9, 9)] = ContentDB.STONE
	var tucked_mesh: ArrayMesh = GreedyMesher.build(tucked, {})[0]
	var tucked_top := _top_face_colors(tucked_mesh)
	if tucked_top.is_empty():
		print("AO: could not isolate the tucked top face")
		return false

	var open_min := 1.0
	for c in open_top:
		open_min = minf(open_min, c.r)
	var tucked_min := 1.0
	for c in tucked_top:
		tucked_min = minf(tucked_min, c.r)
	print("AO: open top face darkest %.3f, tucked top face darkest %.3f"
		% [open_min, tucked_min])
	return tucked_min < open_min - 0.05


## Vertex colours of the upward-facing quads in a mesh, across all surfaces.
func _top_face_colors(mesh: ArrayMesh) -> PackedColorArray:
	var out := PackedColorArray()
	if mesh == null:
		return out
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		if verts.is_empty():
			continue
		for i in verts.size():
			if norms[i].y > 0.9:
				out.append(cols[i])
	return out


## Every emitted triangle must be wound so that its geometric normal agrees
## with the normal stored on its vertices. When they disagree the face is
## inside out and the GPU back-face culls it, so the block is simply not
## there -- the world gets holes and the camera sees through the ground.
##
## This was broken for the -X, -Y and -Z faces (6 of 12 triangles on an
## isolated block) and nothing caught it, because every other test here
## counts triangles and a culled triangle is still a triangle. It was found
## by running the render test on a real GPU and looking at the picture.
func _test_winding_matches_normal() -> void:
	var b := VoxelBlock.new()
	for i in b.content.size():
		b.content[i] = ContentDB.AIR
	b.content[MapNode.index(8, 8, 8)] = ContentDB.STONE
	b.is_loaded = true
	b.is_generated = true
	b.fill(MapNode.LIGHT_SUN | (MapNode.LIGHT_SUN << 4))
	var meshes: Array = GreedyMesher.build(b, {})
	var m: ArrayMesh = meshes[0]
	var arrays := m.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var bad := 0
	var detail := ""
	for t in range(0, idx.size(), 3):
		var geo := (verts[idx[t + 1]] - verts[idx[t]]) \
			.cross(verts[idx[t + 2]] - verts[idx[t]]).normalized()
		var stored: Vector3 = norms[idx[t]]
		if geo.dot(stored) < 0.0:
			bad += 1
			if detail == "":
				detail = " (first: stored %s, geometric %s)" % [stored, geo]
	check(bad == 0, "%d/%d triangles wound against their own normal%s"
		% [bad, idx.size() / 3, detail])

	# And the specific case that was broken: all six directions must produce
	# exactly two triangles, so no face is lost to culling.
	var dirs := {}
	for t in range(0, idx.size(), 3):
		var n: Vector3 = norms[idx[t]]
		var key := "%.0f,%.0f,%.0f" % [n.x, n.y, n.z]
		dirs[key] = int(dirs.get(key, 0)) + 1
	check(dirs.size() == 6,
		"an isolated block should expose all 6 face directions, got %d"
		% dirs.size())
	for axis_name in dirs:
		check(int(dirs[axis_name]) == 2,
			"direction %s should have 2 triangles, got %d"
			% [axis_name, int(dirs[axis_name])])


## A face must sit on the boundary of ITS OWN voxel, not on the chunk edge.
##
## This was the single worst bug in the renderer. The sweep passed one shared
## `plane` value (0 or 16) to every face, so every face in every chunk was
## placed on that chunk's boundary: a block at (8,8,8) emitted its six faces
## at x=0 and x=16 rather than x=8 and x=9. The whole world collapsed into
## thin sheets at chunk edges -- haze and floating fragments with no ground.
##
## It survived because every previous assertion was about counts (twelve
## triangles, six faces, one surface) or about orientation (does the normal
## match the winding). Both were true. Nobody asked WHERE the geometry was.
func _test_faces_land_on_their_own_voxel() -> void:
	# A single block, far from any boundary, so there is no ambiguity.
	var b := _block_with([[8, 8, 8]], ContentDB.STONE)

	# Every face plane must be 8 or 9: the two boundaries of voxel 8.
	var got := _face_planes(GreedyMesher.build(b, {})[0])
	var expected := ["0@8.0", "0@9.0", "1@8.0", "1@9.0", "2@8.0", "2@9.0"]
	var want := {}
	for e in expected:
		want[e] = true
	var unexpected := PackedStringArray()
	for g in got:
		if not want.has(g):
			unexpected.append(g)
	check(unexpected.is_empty(),
		"faces of a block at (8,8,8) must lie on planes 8 and 9 of each "
		+ "axis; found unexpected planes %s (all: %s)"
		% [unexpected, got])
	check(got.size() == 6,
		"an isolated block has 6 face planes, got %d" % got.size())

	# And a block in a corner, to catch an off-by-one at 0 and 15.
	var c := _block_with([[0, 0, 0]], ContentDB.STONE)
	var got2 := _face_planes(GreedyMesher.build(c, {})[0])
	var want2 := {}
	for e in ["0@0.0", "0@1.0", "1@0.0", "1@1.0", "2@0.0", "2@1.0"]:
		want2[e] = true
	var unexpected2 := PackedStringArray()
	for g in got2:
		if not want2.has(g):
			unexpected2.append(g)
	check(unexpected2.is_empty(),
		"faces of a block at (0,0,0) must lie on planes 0 and 1 of each "
		+ "axis; found unexpected planes %s (all: %s)"
		% [unexpected2, got2])

	# A whole slab spanning the block in x and z sits at y=3, so its top and
	# bottom faces are at y=3 and y=4 while its sides are on the block's own
	# edges at x=0/16 and z=0/16.
	var slab := VoxelBlock.new()
	slab.is_loaded = true
	slab.is_generated = true
	slab.fill(MapNode.LIGHT_SUN | (MapNode.LIGHT_SUN << 4))
	for x in 16:
		for z in 16:
			slab.content[MapNode.index(x, 3, z)] = ContentDB.STONE
	var slab_planes := _face_planes(GreedyMesher.build(slab, {})[0])
	for p in ["1@3.0", "1@4.0", "0@0.0", "0@16.0", "2@0.0", "2@16.0"]:
		check(slab_planes.has(p),
			"a slab at y=3 is missing face plane %s (got %s)" % [p, slab_planes])
	check(slab_planes.size() == 6,
		"a slab at y=3 must have exactly 6 face planes, got %d: %s"
		% [slab_planes.size(), slab_planes])


## The set of distinct face planes in a mesh, as "axis@coordinate" strings.
static func _face_planes(mesh: ArrayMesh) -> PackedStringArray:
	var out := {}
	if mesh == null:
		return PackedStringArray()
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for t in range(0, idx.size(), 3):
			for k in 3:
				var i: int = idx[t + k]
				var n: Vector3 = norms[i]
				var axis := 0
				if absf(n.y) > 0.5:
					axis = 1
				elif absf(n.z) > 0.5:
					axis = 2
				var v: Vector3 = verts[i]
				var c := v.x
				if axis == 1:
					c = v.y
				elif axis == 2:
					c = v.z
				out["%d@%s" % [axis, str(c)]] = true
	var keys := out.keys()
	keys.sort()
	return PackedStringArray(keys)


func _block_with(cells: Array, id: int) -> VoxelBlock:
	var b := VoxelBlock.new()
	for i in b.content.size():
		b.content[i] = ContentDB.AIR
	for cell in cells:
		b.content[MapNode.index(cell[0], cell[1], cell[2])] = id
	b.is_loaded = true
	b.is_generated = true
	b.fill(MapNode.LIGHT_SUN | (MapNode.LIGHT_SUN << 4))
	return b


## Each vertex's ambient-occlusion colour must describe ITS OWN corner.
##
## Flipping the winding to face a -axis direction also permutes the corners,
## so the colours have to be permuted to match. Rotating them instead pairs
## every corner with its neighbour's occlusion, which is wrong shading on
## every block corner in the world and completely invisible to a count-based
## test.
func _test_ao_colour_stays_with_its_corner() -> void:
	# A flat stone floor with a single deepslate block standing on one corner of
	# it. The occluder is a DIFFERENT block id on purpose: quads are grouped
	# per id into one surface, and a same-id occluder would contribute its
	# own faces to the same surface and blur the audit.
	#
	# The assertion is mapping-agnostic on purpose: rather than hard-coding
	# which axis is u and which is v for the surface being audited, the
	# nearest vertex to the occluder must simply be darker than the farthest.
	var b := _block_with([], ContentDB.AIR)
	for x in 16:
		for z in 16:
			b.content[MapNode.index(x, 4, z)] = ContentDB.STONE
	b.content[MapNode.index(2, 5, 2)] = ContentDB.DEEPSLATE
	var mesh: ArrayMesh = GreedyMesher.build(b, {})[0]

	# Audit only upward-facing stone at the floor's top plane.
	var occluder := Vector3(2.5, 5.0, 2.5)
	var nearest := -1.0
	var nearest_d := INF
	var farthest := -1.0
	var farthest_d := -INF
	var audited := 0
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if mesh.surface_get_name(s) != str(ContentDB.STONE):
			continue
		for t in range(0, idx.size(), 3):
			for k in 3:
				var i: int = idx[t + k]
				if not (norms[i].y > 0.5 and verts[i].y > 4.5 \
						and verts[i].y < 5.5):
					continue
				audited += 1
				var l := cols[i].get_luminance()
				var d := Vector2(verts[i].x - occluder.x,
						verts[i].z - occluder.z).length()
				if d < nearest_d:
					nearest_d = d
					nearest = l
				if d > farthest_d:
					farthest_d = d
					farthest = l
	check(audited > 0, "the floor's top face produced no vertices to audit")
	if audited > 0 and nearest >= 0.0 and farthest >= 0.0:
		check(nearest < farthest,
			"the vertex nearest the occluder (%.4f at distance %.2f) must be "
			% [nearest, nearest_d]
			+ "darker than the farthest (%.4f at distance %.2f); if AO "
			% [farthest, farthest_d]
			+ "colours were rotated instead of permuted, every corner would "
			+ "carry its neighbour's occlusion")
		# And the far corner must sit at the unoccluded level: palette tint
		# x +Y face shade x full daylight.
		var expect := ContentDB.color_of(ContentDB.STONE).get_luminance() \
			* GreedyMesher.FACE_SHADE[2]
		check(absf(farthest - expect) < 0.02,
			"an unoccluded top-face vertex should be at %.4f, got %.4f"
			% [expect, farthest])

	# Repeat on the -Y direction. This is the half of the world that takes
	# the reversed winding, and therefore the half where a mis-permuted AO
	# colour would actually show. Testing only the top face would leave the
	# bug completely invisible, which is exactly how it got there.
	var under := _block_with([], ContentDB.AIR)
	for x in 16:
		for z in 16:
			under.content[MapNode.index(x, 4, z)] = ContentDB.STONE
	under.content[MapNode.index(2, 3, 2)] = ContentDB.DEEPSLATE
	var um: ArrayMesh = GreedyMesher.build(under, {})[0]
	var u_near := -1.0
	var u_near_d := INF
	var u_far := -1.0
	var u_far_d := -INF
	var u_audited := 0
	for s in um.get_surface_count():
		if um.surface_get_name(s) != str(ContentDB.STONE):
			continue
		var arrays := um.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for t in range(0, idx.size(), 3):
			for k in 3:
				var i: int = idx[t + k]
				if not (norms[i].y < -0.5 and verts[i].y > 3.5 \
						and verts[i].y < 4.5):
					continue
				u_audited += 1
				var l := cols[i].get_luminance()
				var d := Vector2(verts[i].x - occluder.x,
						verts[i].z - occluder.z).length()
				if d < u_near_d:
					u_near_d = d
					u_near = l
				if d > u_far_d:
					u_far_d = d
					u_far = l
	check(u_audited > 0, "the floor's underside produced no vertices to audit")
	if u_audited > 0 and u_near >= 0.0 and u_far >= 0.0:
		check(u_near < u_far,
			"on the reversed-winding (-Y) face the vertex nearest the "
			+ "occluder (%.4f) must be darker than the farthest (%.4f)"
			% [u_near, u_far])
		var expect_u := ContentDB.color_of(ContentDB.STONE).get_luminance() \
			* GreedyMesher.FACE_SHADE[3]
		check(absf(u_far - expect_u) < 0.02,
			"an unoccluded underside vertex should be at %.4f, got %.4f"
			% [expect_u, u_far])


## Invariants every emitted mesh must satisfy, checked over a real generated
## world rather than a hand-built fixture: indices in range, finite vertex
## data, unit normals, non-degenerate triangles, and winding that agrees with
## the stored normal.
func _test_geometry_invariants() -> void:
	var gen := WorldGenerator.new(4242)
	for cx in 2:
		for cz in 2:
			# Real terrain, taken from the generator rather than synthesised:
			# this test is about the invariants real chunks hold to.
			#
			# It used to call `WorldGenerator.generate_node`, which does not
			# exist. The call raised a script error on the first iteration,
			# which aborted the whole test body -- so the "invariants over a
			# real generated world" had been checking nothing at all and
			# still reporting PASS.
			var block := VoxelBlock.new()
			block.is_loaded = true
			block.is_generated = true
			block.fill(MapNode.LIGHT_SUN | (MapNode.LIGHT_SUN << 4))
			for cy in 2:
				var src := gen.generate_block(Vector3i(cx, cy, cz))
				for lx in GreedyMesher.BS:
					for ly in GreedyMesher.BS:
						for lz in GreedyMesher.BS:
							var idx := MapNode.index(lx, ly, lz)
							block.content[idx] = src.content[idx]
			var meshes := GreedyMesher.build(block, {})
			for pass_i in 2:
				var m: ArrayMesh = meshes[pass_i]
				if m == null:
					continue
				for s in m.get_surface_count():
					var arrays := m.surface_get_arrays(s)
					var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
					var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
					var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
					var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
					var where := "chunk(%d,%d) pass%d surface%d" \
						% [cx, cz, pass_i, s]
					check(idx.size() % 3 == 0,
						"%s: index count %d is not a multiple of 3"
						% [where, idx.size()])
					check(verts.size() == norms.size() and verts.size() == uvs.size(),
						"%s: array sizes disagree (v=%d n=%d uv=%d)"
						% [where, verts.size(), norms.size(), uvs.size()])
					var bad_idx := 0
					var non_finite := 0
					var bad_normal := 0
					var degenerate := 0
					var backwards := 0
					for i in idx:
						if i < 0 or i >= verts.size():
							bad_idx += 1
					for i in verts.size():
						if not is_finite(verts[i].x) or not is_finite(verts[i].y) \
								or not is_finite(verts[i].z):
							non_finite += 1
						if absf(norms[i].length() - 1.0) > 0.001:
							bad_normal += 1
					for t in range(0, idx.size(), 3):
						var a: Vector3 = verts[idx[t]]
						var b: Vector3 = verts[idx[t + 1]]
						var c: Vector3 = verts[idx[t + 2]]
						var cross := (b - a).cross(c - a)
						if cross.length() < 0.000001:
							degenerate += 1
						elif cross.normalized().dot(norms[idx[t]]) < 0.0:
							backwards += 1
					check(bad_idx == 0, "%s: %d index/indices out of range"
						% [where, bad_idx])
					check(non_finite == 0, "%s: %d non-finite position(s)"
						% [where, non_finite])
					check(bad_normal == 0, "%s: %d normal(s) not unit length"
						% [where, bad_normal])
					check(degenerate == 0, "%s: %d degenerate triangle(s)"
						% [where, degenerate])
					check(backwards == 0,
						"%s: %d triangle(s) wound against their own normal"
						% [where, backwards])


## A chunk mesh is the single most expensive thing the world does per frame,
## so its cost gets a test rather than a comment.
##
## The mesher used to take 45-85 ms per chunk because every voxel lookup went
## through a GDScript `Callable`, and the streamer believed a chunk cost 1.4
## ms -- it meshed two chunks a frame and fell further behind every frame, at
## a measured 130 ms. It now measures ~4-5 ms on the same input. This test
## exists so that going back to tens of milliseconds is a red suite rather
## than a stutter somebody notices in a screenshot.
##
## The ceiling is deliberately loose relative to the 5 ms it actually takes:
## it has to hold on a cold CI runner, a debug build, and under the Voxel
## Tools binary, all of which are slower than this machine. It is a backstop
## against an order-of-magnitude regression, not a benchmark.
const MESH_BUDGET_US := 25000


func _test_a_chunk_mesh_stays_under_its_budget() -> void:
	# The pathological case for this mesher: a solid block. Nothing merges,
	# so every one of the 4096 voxels is examined for all six directions.
	var solid := VoxelBlock.new()
	solid.is_loaded = true
	solid.is_generated = true
	solid.content.fill(ContentDB.STONE)
	solid.fill(MapNode.LIGHT_SUN | (MapNode.LIGHT_SUN << 4))
	# Discard the first call: it pays for the surface/material caches.
	GreedyMesher.build(solid, {})
	var samples: Array[float] = []
	for i in 5:
		var t := Time.get_ticks_usec()
		GreedyMesher.build(solid, {})
		samples.append(float(Time.get_ticks_usec() - t))
	samples.sort()
	var worst: float = samples[samples.size() - 1]
	check(worst < float(MESH_BUDGET_US),
		"a solid chunk meshed in %.0f us, budget is %d us (all samples: %s)"
		% [worst, MESH_BUDGET_US, str(samples)])


func _tris(mesh: ArrayMesh) -> int:
	if mesh == null or mesh.get_surface_count() == 0:
		return 0
	return mesh.surface_get_array_index_len(0) / 3


func _colors(mesh: ArrayMesh) -> PackedColorArray:
	if mesh == null or mesh.get_surface_count() == 0:
		return PackedColorArray()
	var arrays := mesh.surface_get_arrays(0)
	return arrays[Mesh.ARRAY_COLOR]


func _uvs(mesh: ArrayMesh) -> PackedVector2Array:
	if mesh == null or mesh.get_surface_count() == 0:
		return PackedVector2Array()
	var arrays := mesh.surface_get_arrays(0)
	return arrays[Mesh.ARRAY_TEX_UV]
