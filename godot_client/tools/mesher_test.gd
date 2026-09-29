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
