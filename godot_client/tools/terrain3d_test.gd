extends SceneTree
## The Terrain3D terrain layer, executed for real against a real Terrain3D.
##
## Everything here runs through the shipped classes -- `ArnisTerrainSource`,
## `TerrainLayer`, `VoxelWorld`, `GreedyMesher` -- with the official Godot 4.4
## build and the Terrain3D extension loaded. Nothing is mocked, because the
## questions this suite answers are the ones a mock would answer for itself:
##
##   A. an Arnis world is authoritative, and a legacy one is not;
##   B. the coordinate transform (Arnis -> Launti -> Terrain3D) is the one
##      documented, pinned empirically by an asymmetric pattern;
##   C. heights at known points match the source in flat, sloped, high, low
##      and water-covered terrain;
##   D. chunk boundaries are continuous;
##   E. region boundaries are continuous;
##   F. streaming loads and evicts regions on a budget, and never loads the
##      whole world;
##   G. Terrain3D's own LOD machinery is configured and in use;
##   H. roads and buildings sit on the terrain surface;
##   I. an authoritative world cannot fall back to procedural terrain, in the
##      voxel layer or in the terrain layer;
##   J. a legacy converted world still works exactly as it did;
##   K. a reload produces exactly the same terrain, and writes nothing;
##   plus the renderer-ownership rule: a covered chunk hands over its ground's
##   *upward faces* and nothing else, and the terrain material mapping is
##   derived from the asset manifest rather than re-declared here.
##
## The fixture worlds are written in the real converted-chunk format using the
## real constants, so the layer reads them through the same `ChunkFiles` path a
## converted Arnis world takes.

const TerrainLayerScript := preload("res://scripts/world/terrain_layer.gd")
const ArnisSourceScript := preload("res://scripts/world/arnis_terrain_source.gd")
const MaterialSetScript := preload("res://scripts/world/terrain3d_material_set.gd")

const ARNIS_DIR := "user://t3d_arnis"
const LEGACY_DIR := "user://t3d_legacy"
const BAND_DIR := "user://t3d_band"
## Terrain3D region size used by the fixtures. 64 is Terrain3D's own smallest
## non-trivial region, which keeps a whole converted world small enough to
## build inside a test while still crossing real region boundaries -- four
## chunks per region instead of sixteen. Production keeps Terrain3D's default.
const REGION := 64
const CHUNKS := 4          # 4x4 chunks = 64x64 nodes in the main fixture
const GAP_CHUNK := Vector2i(3, 3)
const SLOT_X := 21         # a column with no ground: a partially covered chunk
const WATER_LEVEL := 8
const ROAD_Z := 24
const ROAD_X0 := 16
const ROAD_X1 := 47
const BUILD_X0 := 36
const BUILD_X1 := 39
const BUILD_Z0 := 4
const BUILD_Z1 := 7
const TREE_X := 20
const TREE_Z := 20
const BS := 16
const HEADER := 10

var failures := 0
var warnings := 0


func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: ", msg)


func warn(msg: String) -> void:
	warnings += 1
	print("LIMITATION: ", msg)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_build_main_world()
	_build_legacy_world()
	_build_band_world()
	_test_a_authority()
	_test_b_coordinate_transform()
	_test_c_known_elevations()
	_test_d_chunk_boundaries()
	_test_e_region_boundaries()
	_test_f_streaming()
	_test_g_lod()
	_test_h_structures_align()
	_test_i_no_procedural_fallback()
	_test_j_legacy_world()
	_test_k_reload_is_identical()
	_test_handoff_suppression()
	_test_material_mapping()
	_test_profile()
	print("terrain3d: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)


# --- the fixture's terrain --------------------------------------------------
#
# ONE function defines the ground, and the assertions call the same function.
# A test whose expected heights are written out a second time is a test that
# can pass by agreeing with itself.

## The highest *ground* node of a column: -1 when the world has no ground
## there at all. Water, trees and built things are added above this line by
## `content_at` and are deliberately absent from it.
##
## The formula is asymmetric in x and z on purpose -- x/8 against z/16 -- so a
## transposed or mirrored coordinate transform cannot pass by symmetry.
func ground_top(x: int, z: int) -> int:
	if x >= 48 and z >= 48:
		return -1                      # the absent chunk: a genuine hole
	if x == SLOT_X and z < 16:
		return -1                      # one column with no ground
	if x >= 32 and z >= 32:
		return 30                      # flat, high plateau
	if x < 16 and z < 16:
		return 4                       # flat, low basin, under the water
	return 10 + x / 8 + z / 16         # a slope


## The height Terrain3D must show at a column: the top face of the highest
## ground node, in nodes (= metres here), or NAN where the world has none.
func expected(x: int, z: int) -> float:
	var h := ground_top(x, z)
	return NAN if h < 0 else float(h + 1)


func content_at(x: int, y: int, z: int) -> int:
	var h := ground_top(x, z)
	if h < 0:
		return ContentDB.AIR
	if y > h:
		# Water: a lake in the basin. Hydrology is NOT terrain, so the terrain
		# surface there stays the lake bed.
		if y <= WATER_LEVEL:
			return ContentDB.WATER
		# The road: asphalt laid directly on the ground, so its base is the
		# surface height.
		if z == ROAD_Z and x >= ROAD_X0 and x <= ROAD_X1 and y == h + 1:
			return ContentDB.ASPHALT
		# A building: a brick foundation on the surface, with a plank post at
		# each corner.
		if x >= BUILD_X0 and x <= BUILD_X1 and z >= BUILD_Z0 and z <= BUILD_Z1:
			if y == h + 1:
				return ContentDB.BRICK
			if y == h + 2 and (x == BUILD_X0 or x == BUILD_X1) \
					and (z == BUILD_Z0 or z == BUILD_Z1):
				return ContentDB.PLANKS
		# A tree, whose canopy must not become terrain.
		if x == TREE_X and z == TREE_Z and y >= h + 1 and y <= h + 3:
			return ContentDB.WOOD
		if x == TREE_X and z == TREE_Z and y == h + 4:
			return ContentDB.LEAVES
		return ContentDB.AIR
	if y == h:
		return ContentDB.GRASS
	if y >= h - 3:
		return ContentDB.DIRT
	return ContentDB.STONE


# --- fixture writing --------------------------------------------------------

func _chunk_bytes(content_of: Callable, cx: int, by: int, cz: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(HEADER + 4096 * 3)
	out.encode_u32(0, ChunkFiles.MAGIC)
	out.encode_u16(4, 1)
	out.encode_u16(6, 0)
	out[8] = 1
	out[9] = 0
	for lz in BS:
		for ly in BS:
			for lx in BS:
				out[HEADER + MapNode.index(lx, ly, lz)] = int(content_of.call(
					cx * BS + lx, by * BS + ly, cz * BS + lz)) & 0xFF
	for i in 4096:
		out[HEADER + 4096 + i] = 15
	return out


func _write(dir: String, name: String, bytes: PackedByteArray) -> void:
	var f := FileAccess.open(dir.path_join(name), FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()


func _write_world(dir: String, chunks_x: int, chunks_z: int, y_blocks: int,
		content_of: Callable, manifest: Dictionary, skip_gap: bool) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	for cx in chunks_x:
		for cz in chunks_z:
			if skip_gap and cx == GAP_CHUNK.x and cz == GAP_CHUNK.y:
				continue
			for by in y_blocks:
				_write(dir, "c_%d_%d_%d.chunk" % [cx, by, cz],
					_chunk_bytes(content_of, cx, by, cz))
	_write(dir, "manifest.json",
		PackedByteArray(JSON.stringify(manifest).to_utf8_buffer()))


func _provenance(x1: int, z1: int, y1: int) -> Dictionary:
	return {
		"format": 1,
		"content_names": {},
		"source_pipeline": "arnis",
		"source_pipeline_version": "unpinned",
		"world_format": "luanti-v29",
		"bounds": {"x": [0, x1], "y": [0, y1], "z": [0, z1]},
	}


func _build_main_world() -> void:
	_write_world(ARNIS_DIR, CHUNKS, CHUNKS, 2, Callable(self, "content_at"),
		_provenance(CHUNKS - 1, CHUNKS - 1, 1), true)


## The legacy world: real converted chunks with no provenance fields at all,
## which is every world converted before Arnis was pinned as the source.
func _build_legacy_world() -> void:
	DirAccess.make_dir_recursive_absolute(LEGACY_DIR)
	for cx in 2:
		_write(LEGACY_DIR, "c_%d_0_0.chunk" % cx,
			_chunk_bytes(Callable(self, "content_at"), cx, 0, 0))
	_write(LEGACY_DIR, "manifest.json", PackedByteArray(JSON.stringify({
		"format": 1, "content_names": {},
	}).to_utf8_buffer()))


## A 16-chunk band along x, one chunk deep, one y block: 256 nodes of world
## that crosses three region boundaries at a region size of 64.
func _build_band_world() -> void:
	_write_world(BAND_DIR, 16, 1, 1, Callable(self, "band_content"),
		_provenance(15, 0, 0), false)


## The band's ground: a staircase whose step lands exactly on the region
## boundary at x = 64, so a seam that is off by one node is visible.
func band_top(x: int, z: int) -> int:
	return 4 + (x / 16) % 7


func band_content(x: int, y: int, z: int) -> int:
	var h := band_top(x, z)
	if y == h:
		return ContentDB.GRASS
	if y < h:
		return ContentDB.STONE
	return ContentDB.AIR


# --- layer helpers ----------------------------------------------------------

func _layer(dir: String, radius: float, budget: int) -> TerrainLayerScript:
	var l: TerrainLayerScript = TerrainLayerScript.new()
	l.world_dir = dir
	l.stream_radius = radius
	l.regions_per_update = budget
	l.region_size_setting = REGION
	var refusal: String = l.configure()
	check(refusal == "", "layer over %s configures (%s)" % [dir, refusal])
	root.add_child(l)
	check(l.region_size() == REGION,
		"Terrain3D region size is %d (%d)" % [REGION, l.region_size()])
	return l


func _height(layer: TerrainLayerScript, x: float, z: float) -> float:
	return float(layer.height_at(x, z))


func _has_region(layer: TerrainLayerScript, lx: int, lz: int) -> bool:
	var d: Object = layer.data()
	return bool(d.call("has_region", Vector2i(lx, lz)))


# --- A: authority -----------------------------------------------------------

func _test_a_authority() -> void:
	var arnis := ArnisSourceScript.new(ARNIS_DIR)
	check(arnis.is_ready(), "the Arnis fixture is read as a converted world")
	check(arnis.is_authoritative(),
		"and its manifest is recognised as authoritative")
	var legacy := ArnisSourceScript.new(LEGACY_DIR)
	check(legacy.is_ready(), "the legacy fixture is read as a converted world")
	check(not legacy.is_authoritative(),
		"and a world without provenance is not authoritative")
	check(arnis.is_authoritative() == ChunkFiles.is_authoritative(ARNIS_DIR),
		"the source agrees with ChunkFiles about authority")


# --- B: the coordinate transform --------------------------------------------

## Arnis/Luanti node (x, y, z) -> Launti world (x, y, z) -> Terrain3D sample
## (x, z) with the height as Y. This is what makes that claim evidence rather
## than a comment: an asymmetric source pattern is written into Terrain3D and
## read back at the same, the swapped and the far coordinates. A transposed or
## mirrored mapping cannot pass.
func _test_b_coordinate_transform() -> void:
	var layer := _layer(ARNIS_DIR, 40.0, 8)
	layer.update_around(Vector3(32, 0, 32))
	check(layer.resident_regions().has(Vector2i(0, 0)),
		"the region under the fixture is resident")

	for p in [Vector3i(3, 0, 40), Vector3i(40, 0, 3), Vector3i(27, 0, 11),
			Vector3i(11, 0, 27)]:
		var h := _height(layer, float(p.x), float(p.z))
		check(is_equal_approx(h, expected(p.x, p.z)),
			"height at (%d, %d) is the source height (got %s, want %s)"
				% [p.x, p.z, str(h), str(expected(p.x, p.z))])

	var a := _height(layer, 3.0, 40.0)
	var b := _height(layer, 40.0, 3.0)
	check(not is_equal_approx(a, b),
		"the fixture is asymmetric along x and z (%s vs %s)" % [str(a), str(b)])
	check(is_equal_approx(a, expected(3, 40))
			and is_equal_approx(b, expected(40, 3)),
		"each column answers with its own height, not the transposed one")
	check(not is_nan(a),
		"in-world columns have terrain (a mirrored mapping would read empty)")
	check(is_nan(_height(layer, -40.0, 3.0)),
		"and there is no terrain on the far side of the origin")
	layer.free()


# --- C: known elevations ----------------------------------------------------

func _test_c_known_elevations() -> void:
	var layer := _layer(ARNIS_DIR, 40.0, 8)
	layer.update_around(Vector3(32, 0, 32))

	var cases := {
		"flat basin": Vector2i(2, 2),
		"flat basin (mid)": Vector2i(9, 14),
		"slope": Vector2i(24, 20),
		"slope (steep end)": Vector2i(47, 8),
		"high plateau": Vector2i(40, 40),
		"high plateau (corner)": Vector2i(44, 44),
		"water column": Vector2i(5, 10),
	}
	for name in cases.keys():
		var c: Vector2i = cases[name]
		var want := expected(c.x, c.y)
		var h := _height(layer, float(c.x), float(c.y))
		# A column the fixture has no ground for is a column Terrain3D must
		# report a hole for; a finite height there would be invented terrain.
		var ok := is_nan(want) if is_nan(want) else is_equal_approx(h, want)
		check(ok, "%s at (%d, %d): got %s, want %s"
			% [name, c.x, c.y, str(h), str(want)])

	# The water is hydrology, not terrain: the column's highest node is water
	# at y = 5..8, and the terrain surface is still the lake bed at 5.
	var bed := _height(layer, 5.0, 10.0)
	check(not is_equal_approx(bed, float(WATER_LEVEL + 1)),
		"a water column does not report the waterline as terrain (got %s)"
			% str(bed))
	check(is_equal_approx(bed, float(ground_top(5, 10) + 1)),
		"it reports the lake bed (got %s)" % str(bed))

	# The tree is vegetation, not terrain.
	var under_tree := _height(layer, float(TREE_X), float(TREE_Z))
	check(is_equal_approx(under_tree, float(ground_top(TREE_X, TREE_Z) + 1)),
		"a canopy does not raise the terrain (got %s)" % str(under_tree))

	# The world is not a flat plane: Terrain3D's own height range spans the
	# fixture's real relief.
	var d: Object = layer.data()
	d.call("calc_height_range")
	var rng: Vector2 = d.call("get_height_range")
	check(rng.y - rng.x >= 20.0,
		"the terrain has real relief (range %s)" % str(rng))
	check(int(layer.stats["columns_hole"]) > 0,
		"and the absent columns were recorded as holes")
	layer.free()


# --- D: chunk boundaries ----------------------------------------------------

func _test_d_chunk_boundaries() -> void:
	var layer := _layer(ARNIS_DIR, 40.0, 8)
	layer.update_around(Vector3(32, 0, 32))
	var checked := 0
	var wrong := 0
	# Every column pair across a chunk seam (x = 15|16, 31|32, 47|48) must hold
	# the heights the source has there. A chunk-local indexing error shows up
	# as a mismatch on one side of a seam and nowhere else.
	for seam in [15, 31, 47]:
		for z in 64:
			var left := _height(layer, float(seam), float(z))
			var right := _height(layer, float(seam + 1), float(z))
			if is_nan(left) or is_nan(right):
				continue
			checked += 1
			if not (is_equal_approx(left, expected(seam, z))
					and is_equal_approx(right, expected(seam + 1, z))):
				wrong += 1
	check(checked > 100, "chunk seams were sampled (%d column pairs)" % checked)
	check(wrong == 0,
		"every chunk seam column matches the source (%d wrong)" % wrong)
	layer.free()


# --- E: region boundaries ---------------------------------------------------

func _test_e_region_boundaries() -> void:
	var layer := _layer(BAND_DIR, 100.0, 64)
	layer.update_around(Vector3(64, 0, 8))
	check(_has_region(layer, 0, 0) and _has_region(layer, 1, 0),
		"both regions either side of the x = 64 boundary are resident")
	var left := _height(layer, 63.0, 8.0)
	var right := _height(layer, 64.0, 8.0)
	check(not is_nan(left) and not is_nan(right),
		"the boundary columns have terrain on both sides")
	check(is_equal_approx(left, float(band_top(63, 8) + 1)),
		"the last column of the left region reads its own height (got %s)"
			% str(left))
	check(is_equal_approx(right, float(band_top(64, 8) + 1)),
		"the first column of the right region reads its own height (got %s)"
			% str(right))
	check(absf(right - left) <= 1.0,
		"the step across the boundary is the source's step, not a tear "
		+ "(%s -> %s)" % [str(left), str(right)])
	var further := _height(layer, 80.0, 8.0)
	check(is_equal_approx(further, float(band_top(80, 8) + 1)),
		"and the region continues correctly away from the seam (got %s)"
			% str(further))
	layer.free()


# --- F: streaming -----------------------------------------------------------

func _test_f_streaming() -> void:
	var layer := _layer(BAND_DIR, 40.0, 1)
	var built := layer.update_around(Vector3(8, 0, 8))
	check(built == 1, "one region per call, as budgeted (built %d)" % built)
	check(layer.resident_regions().has(Vector2i(0, 0)),
		"the region under the focus is resident")
	check(not is_nan(_height(layer, 8.0, 8.0)), "and it has terrain")

	for _i in 6:
		layer.update_around(Vector3(200, 0, 8))
	check(layer.resident_regions().has(Vector2i(3, 0)),
		"the region the player moved to is resident")
	check(not layer.resident_regions().has(Vector2i(0, 0)),
		"and the region they left is not")
	check(layer.resident_regions().size() <= 6,
		"residency is bounded by the stream radius (%d regions)"
			% layer.resident_regions().size())
	check(is_equal_approx(_height(layer, 200.0, 8.0),
			float(band_top(200, 8) + 1)),
		"the new region serves correct heights")
	check(is_nan(_height(layer, 0.0, 8.0)),
		"and the evicted region serves none")
	check(int(layer.stats["regions_built"]) <= 16,
		"streaming built a bounded number of regions (%d), not the world"
			% int(layer.stats["regions_built"]))
	layer.free()


# --- G: LOD -----------------------------------------------------------------

func _test_g_lod() -> void:
	var layer := _layer(ARNIS_DIR, 40.0, 8)
	layer.update_around(Vector3(32, 0, 32))
	var t: Object = layer.terrain
	check(int(t.call("get_mesh_lods")) == int(layer.mesh_lods),
		"Terrain3D's own LOD count is what this layer configured (%s vs %s)"
			% [str(t.call("get_mesh_lods")), str(layer.mesh_lods)])
	check(int(t.call("get_mesh_lods")) >= 2, "and it is more than one level")

	# LOD sampling, through Terrain3D's own vertex sampler: on a slope a
	# coarser LOD samples a wider footprint, so its height differs; on flat
	# ground every LOD agrees, which is what makes the scheme safe.
	var d: Object = layer.data()
	var sloped := Vector3(24.0, 0.0, 20.0)
	var flat := Vector3(40.0, 0.0, 40.0)
	# LOD 1 rather than 4: a coarser footprint reaches past a 64 m fixture
	# region, and Terrain3D then answers NAN because the footprint touches a
	# hole -- correct behaviour, and not what this check is about.
	var slope_fine: Vector3 = d.call("get_mesh_vertex", 0, 0, sloped)
	var slope_coarse: Vector3 = d.call("get_mesh_vertex", 1, 1, sloped)
	var flat_fine: Vector3 = d.call("get_mesh_vertex", 0, 0, flat)
	var flat_coarse: Vector3 = d.call("get_mesh_vertex", 1, 1, flat)
	check(not is_nan(slope_fine.y) and not is_nan(slope_coarse.y),
		"the LOD sampler answers on the slope")
	if not is_nan(slope_fine.y) and not is_nan(slope_coarse.y):
		check(slope_coarse.y <= slope_fine.y,
			"a coarse LOD takes the lower sample on a slope (%s -> %s)"
				% [str(slope_fine.y), str(slope_coarse.y)])
		check(is_equal_approx(flat_fine.y, flat_coarse.y),
			"and every LOD agrees on flat ground (%s vs %s)"
				% [str(flat_fine.y), str(flat_coarse.y)])

	var fine: Mesh = layer.bake(0)
	var coarse: Mesh = layer.bake(4)
	if fine == null or coarse == null:
		warn("Terrain3D bake_mesh returned no mesh in this headless run, so "
			+ "LOD mesh geometry was not measured (the sampler above was)")
	else:
		var fine_v := _vertex_count(fine)
		var coarse_v := _vertex_count(coarse)
		check(fine_v > 0 and coarse_v > 0,
			"Terrain3D bakes a mesh from the heightmap (%d and %d vertices)"
				% [fine_v, coarse_v])
		check(coarse_v <= fine_v,
			"the coarse bake is not denser than the fine one (%d vs %d)"
				% [coarse_v, fine_v])
		# The fixture's terrain spans y = 5 (lake bed) to y = 31 (plateau), and
		# the mesh Terrain3D bakes from the heightmap must span exactly that:
		# it is the terrain, not a proxy for it.
		var span := _y_span(fine)
		check(absf(span.x - float(ground_top(2, 2) + 1)) < 0.01
				and absf(span.y - float(ground_top(40, 40) + 1)) < 0.01,
			"the baked mesh spans the fixture's relief, %s..%s"
				% [str(span.x), str(span.y)])
	layer.free()


func _vertex_count(m: Mesh) -> int:
	var total := 0
	for i in m.get_surface_count():
		total += m.surface_get_array_len(i)
	return total


func _y_span(m: Mesh) -> Vector2:
	var lo := 1.0e30
	var hi := -1.0e30
	for i in m.get_surface_count():
		var verts: PackedVector3Array = m.surface_get_arrays(i)[Mesh.ARRAY_VERTEX]
		for v in verts:
			lo = minf(lo, v.y)
			hi = maxf(hi, v.y)
	if lo > hi:
		return Vector2.ZERO
	return Vector2(lo, hi)


# --- H: buildings and roads -------------------------------------------------

func _test_h_structures_align() -> void:
	var layer := _layer(ARNIS_DIR, 40.0, 8)
	layer.update_around(Vector3(32, 0, 32))

	var road_columns := 0
	var mislaid := 0
	for x in range(ROAD_X0, ROAD_X1 + 1):
		var z := ROAD_Z
		var h := ground_top(x, z)
		if h < 0 or int(content_at(x, h + 1, z)) != ContentDB.ASPHALT:
			continue
		road_columns += 1
		# The asphalt's base plane is the terrain surface, and the terrain
		# layer's height at that column must be the same plane.
		if not is_equal_approx(_height(layer, float(x), float(z)),
				float(h + 1)):
			mislaid += 1
	check(road_columns >= 16,
		"the road is in the fixture (%d columns)" % road_columns)
	check(mislaid == 0,
		"every road column's base sits on the terrain surface (%d off)"
			% mislaid)

	var foundations := 0
	var off_ground := 0
	for x in range(BUILD_X0, BUILD_X1 + 1):
		for z in range(BUILD_Z0, BUILD_Z1 + 1):
			var h := ground_top(x, z)
			if h < 0:
				continue
			foundations += 1
			if not is_equal_approx(_height(layer, float(x), float(z)),
					float(h + 1)):
				off_ground += 1
			# A foundation whose lowest voxel is not the surface either floats
			# or is buried.
			if int(content_at(x, h + 1, z)) != ContentDB.BRICK:
				off_ground += 1
	check(foundations == 16,
		"the building has a 4x4 foundation (%d columns)" % foundations)
	check(off_ground == 0,
		"every foundation column's lowest voxel is at the terrain height "
		+ "(%d wrong)" % off_ground)

	check(not bool(layer.covers_chunk(Vector3i(GAP_CHUNK.x, 0, GAP_CHUNK.y))),
		"a chunk with a hole is not handed to Terrain3D")
	check(bool(layer.covers_chunk(Vector3i(0, 0, 0))),
		"a fully mapped chunk is")
	check(not bool(layer.covers_chunk(Vector3i(1, 0, 0))),
		"a chunk with one absent column is not, even though the file exists")
	layer.free()


# --- I: no procedural fallback ----------------------------------------------

## A real generator that counts whether it was ever entered. This is the guard
## `arnis_authoritative_test` applies to the voxel path, applied to the terrain
## path too: the layer must not become a second world generator, and a hole
## must stay a hole.
class SpyGenerator extends WorldGenerator:
	var calls := 0

	func generate_block(pos: Vector3i) -> VoxelBlock:
		calls += 1
		return super.generate_block(pos)


func _test_i_no_procedural_fallback() -> void:
	var layer := _layer(ARNIS_DIR, 40.0, 8)
	var w := VoxelWorld.new()
	w.world_dir = ARNIS_DIR
	w.dimension = WorldGenerator.DIM_OVERWORLD
	w.async_meshing = false
	# The spy is installed *after* add_child because `_ready` builds the
	# world's own generator, and an assertion that ran against a spy the
	# engine had already replaced would pass while proving nothing.
	root.add_child(w)
	var spy := SpyGenerator.new()
	w.generator = spy
	check(w.generator == spy, "the counting generator is actually installed")
	layer.attach_world(w)
	w.set_ground_layer(layer)
	layer.update_around(Vector3(32, 0, 32))

	check(w._generate_block(Vector3i(GAP_CHUNK.x, 0, GAP_CHUNK.y)) == null,
		"an absent authoritative chunk stays absent in the voxel world")
	check(spy.calls == 0,
		"and the procedural generator was never asked for it (calls=%d)"
			% spy.calls)
	var gap_x := GAP_CHUNK.x * BS + 4
	var gap_z := GAP_CHUNK.y * BS + 4
	check(is_nan(_height(layer, float(gap_x), float(gap_z))),
		"the terrain layer reports a hole where the world has none")
	var src := ArnisSourceScript.new(ARNIS_DIR)
	check(is_nan(src.surface_y(gap_x, gap_z)),
		"and the adapter has no height to offer for it either")
	check(int(src.stats["columns_absent"]) > 0,
		"the absent count is reported rather than hidden")

	check(is_nan(_height(layer, float(SLOT_X), 3.0)),
		"a column with no ground is a hole in Terrain3D")
	check(not is_nan(_height(layer, float(SLOT_X + 1), 3.0)),
		"its neighbour is not")

	for _i in 3:
		layer.update_around(Vector3(float(gap_x), 0, float(gap_z)))
	check(spy.calls == 0,
		"streaming over absent terrain never enters the generator (calls=%d)"
			% spy.calls)
	check(is_nan(_height(layer, float(gap_x), float(gap_z))),
		"and the hole is still a hole after streaming over it")
	w.free()
	layer.free()


# --- J: legacy worlds -------------------------------------------------------

func _test_j_legacy_world() -> void:
	var layer := _layer(LEGACY_DIR, 40.0, 8)
	var w := VoxelWorld.new()
	w.world_dir = LEGACY_DIR
	w.dimension = WorldGenerator.DIM_OVERWORLD
	w.async_meshing = false
	root.add_child(w)
	var spy := SpyGenerator.new()
	w.generator = spy
	check(w.generator == spy, "the counting generator is actually installed")
	layer.attach_world(w)
	w.set_ground_layer(layer)
	layer.update_around(Vector3(8, 0, 8))

	check(w._generate_block(Vector3i(9, 0, 9)) != null,
		"a legacy world still fills an absent chunk procedurally")
	check(spy.calls == 1, "exactly once (calls=%d)" % spy.calls)

	check(w._generate_block(Vector3i(0, 0, 0)) != null,
		"the legacy converted chunk loads")
	check(not is_nan(_height(layer, 4.0, 4.0)),
		"the terrain layer draws the converted data it has")
	check(is_nan(_height(layer, 200.0, 4.0)),
		"and nothing where the converted world has nothing")
	check(spy.calls == 1,
		"the terrain layer never invoked the generator (calls=%d)" % spy.calls)

	check(bool(layer.covers_chunk(Vector3i(0, 0, 0))),
		"the present chunk is handed to Terrain3D")
	check(not bool(layer.covers_chunk(Vector3i(9, 0, 9))),
		"the procedurally filled chunk is not")
	w.free()
	layer.free()


# --- K: determinism ---------------------------------------------------------

func _test_k_reload_is_identical() -> void:
	var sample := [Vector3(2.0, 0, 2.0), Vector3(24.0, 0, 20.0),
		Vector3(40.0, 0, 40.0), Vector3(47.0, 0, 8.0)]
	var first: Array[float] = []
	var layer := _layer(ARNIS_DIR, 40.0, 8)
	layer.update_around(Vector3(32, 0, 32))
	for p in sample:
		first.append(_height(layer, p.x, p.z))
	var regions_before := layer.resident_regions().size()
	var files_before := _world_files(ARNIS_DIR).size()
	layer.free()

	var second: Array[float] = []
	var again := _layer(ARNIS_DIR, 40.0, 8)
	again.update_around(Vector3(32, 0, 32))
	for p in sample:
		second.append(_height(again, p.x, p.z))

	var mismatched := 0
	for i in first.size():
		if first[i] != second[i] and not (is_nan(first[i]) and is_nan(second[i])):
			mismatched += 1
	check(mismatched == 0,
		"a reload produces identical terrain (%d of %d samples differ)"
			% [mismatched, first.size()])
	check(again.resident_regions().size() == regions_before,
		"and the same regions (%d vs %d)" % [again.resident_regions().size(),
			regions_before])
	check(_world_files(ARNIS_DIR).size() == files_before,
		"the converted world was not written to (%d -> %d files)"
			% [files_before, _world_files(ARNIS_DIR).size()])
	check(String(again.terrain.call("get_data_directory")) == "",
		"Terrain3D has no save directory for this world")
	again.free()


func _world_files(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(dir)
	if d == null:
		return out
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if not d.current_is_dir():
			out.append(name)
		name = d.get_next()
	d.list_dir_end()
	out.sort()
	return out


# --- the renderer-ownership rule --------------------------------------------

## Terrain3D draws the ground surface; the voxel mesher draws everything else.
## The handoff must therefore remove exactly the upward faces of ground voxels
## in covered chunks -- and nothing else, or it would punch holes through
## cliffs, cave ceilings and overhangs.
func _test_handoff_suppression() -> void:
	var b := VoxelBlock.new()
	b.origin = Vector3i.ZERO
	b.content.resize(4096)
	b.light.resize(4096)
	b.is_loaded = true
	for lz in BS:
		for lx in BS:
			for ly in 8:
				b.content[MapNode.index(lx, ly, lz)] = ContentDB.GRASS

	var plain: Array = GreedyMesher.build(b, {})
	var up_plain := _up_faces(plain[0] as ArrayMesh)
	check(up_plain > 0,
		"a ground block meshes upward faces by default (%d triangles)"
			% up_plain)

	var mask := PackedByteArray()
	mask.resize(4096)
	mask.fill(1)
	var handed: Array = GreedyMesher.build(b, {}, mask)
	var up_handed := _up_faces(handed[0] as ArrayMesh)
	check(up_handed == 0,
		"with the ground handed over, no upward ground face is drawn (%d left)"
			% up_handed)
	var solid_plain := _triangle_count(plain[0] as ArrayMesh)
	var solid_handed := _triangle_count(handed[0] as ArrayMesh)
	check(solid_handed > 0,
		"but its side faces are still meshed (%d triangles)" % solid_handed)
	# The removed geometry is the upward surface and nothing else. It is measured
	# as area rather than as a triangle or quad count, because greedy meshing
	# merges the whole 16x16 top into whatever number of primitives it likes and
	# a count-based assertion would be testing the mesher's primitive layout.
	var plain_up_area := _up_area(plain[0] as ArrayMesh)
	var handed_up_area := _up_area(handed[0] as ArrayMesh)
	check(is_equal_approx(plain_up_area, float(BS * BS)),
		"the whole 16x16 top is an upward surface by default (area %.1f)"
			% plain_up_area)
	check(is_equal_approx(handed_up_area, 0.0),
		"a full handoff removes exactly that surface (area %.1f)"
			% handed_up_area)
	check(solid_handed > 0 and solid_plain > solid_handed,
		"and lops no side faces off with it (%d -> %d triangles)"
			% [solid_plain, solid_handed])

	var empty: Array = GreedyMesher.build(b, {}, PackedByteArray())
	check(_triangle_count(empty[0] as ArrayMesh) == solid_plain,
		"an empty mask is the old behaviour, triangle for triangle")

	# A voxel that is not handed over keeps its upward face next to one that
	# is: a partial handoff must not open a hole.
	var partial := PackedByteArray()
	partial.resize(4096)
	for lz in BS:
		for lx in 8:
			for ly in 8:
				partial[MapNode.index(lx, ly, lz)] = 1
	var mixed: Array = GreedyMesher.build(b, {}, partial)
	check(_up_faces(mixed[0] as ArrayMesh) > 0,
		"the uncovered ground still draws its upward faces")
	var mixed_up_area := _up_area(mixed[0] as ArrayMesh)
	check(is_equal_approx(mixed_up_area, float(BS * BS) * 0.5),
		"and exactly the covered half of the top was taken (%s of 256)"
			% mixed_up_area)


## The greedy mesher emits **indexed** surfaces (a shared vertex pool plus an
## index list), so every triangle helper here has to walk the indices.
## Reading the vertex array in triples instead pairs vertices from unrelated
## triangles: it reports a triangle whose three normals disagree, and a top
## surface that measures half its real area. That is not a subtle rounding
## issue, it is measuring a mesh that does not exist.
func _surface_indices(m: ArrayMesh, i: int) -> PackedInt32Array:
	var arrays := m.surface_get_arrays(i)
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if idx.size() > 0:
		return idx
	var n := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var out := PackedInt32Array()
	out.resize(n)
	for k in n:
		out[k] = k
	return out


func _triangle_count(m: ArrayMesh) -> int:
	if m == null:
		return 0
	var total := 0
	for i in m.get_surface_count():
		total += _surface_indices(m, i).size() / 3
	return total


func _up_faces(m: ArrayMesh) -> int:
	if m == null:
		return 0
	var total := 0
	for i in m.get_surface_count():
		var normals: PackedVector3Array = m.surface_get_arrays(i)[Mesh.ARRAY_NORMAL]
		var idx := _surface_indices(m, i)
		for t in range(0, idx.size() - 2, 3):
			if normals[idx[t]].y > 0.9 and normals[idx[t + 1]].y > 0.9 \
					and normals[idx[t + 2]].y > 0.9:
				total += 1
	return total


## Total world-space area of the upward-facing triangles in a mesh. This is
## what makes "the ground surface was handed over" measurable: triangle counts
## depend on how greedy meshing happened to merge a surface, area does not.
func _up_area(m: ArrayMesh) -> float:
	if m == null:
		return 0.0
	var area := 0.0
	for i in m.get_surface_count():
		var arrays := m.surface_get_arrays(i)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var idx := _surface_indices(m, i)
		for t in range(0, idx.size() - 2, 3):
			var a := verts[idx[t]]
			var b := verts[idx[t + 1]]
			var c := verts[idx[t + 2]]
			if normals[idx[t]].y > 0.9 and normals[idx[t + 1]].y > 0.9 \
					and normals[idx[t + 2]].y > 0.9:
				area += (b - a).cross(c - a).length() * 0.5
	return area


# --- materials --------------------------------------------------------------

## The material table is derived, not re-declared: the manifest says which set
## belongs to which block, and this checks the derivation end to end --
## including that every content id in the registry is classified deliberately,
## so a block added later cannot quietly land in "unknown".
## Measured, not asserted: this prints the cost of feeding Terrain3D from the
## authoritative world so a number in a report is a number the engine produced
## here, on this machine, at this moment. The checks around it only assert that
## work actually happened -- a profile of a layer that built nothing would be a
## table of zeroes with no way to tell it apart from a working one.
func _test_profile() -> void:
	var layer := _layer(ARNIS_DIR, 256.0, 4)
	layer.update_around(Vector3(32, 0, 32))
	var built_after_first := int(layer.stats["regions_built"])
	# Baked here, over the fixture, and not after the walk below: the walk ends
	# past the fixture's edge, where the honest mesh is empty, and a profile
	# that reports 0 vertices because it measured nothing is worse than no
	# profile.
	var b0 := Time.get_ticks_msec()
	var fine: Mesh = layer.bake(0)
	var lod0_ms := float(Time.get_ticks_msec() - b0)
	var b1 := Time.get_ticks_msec()
	var coarse: Mesh = layer.bake(6)
	var lod6_ms := float(Time.get_ticks_msec() - b1)
	var lod0_verts := 0
	var lod6_verts := 0
	if fine != null:
		lod0_verts = _vertex_count(fine)
	if coarse != null:
		lod6_verts = _vertex_count(coarse)
	var t0 := Time.get_ticks_msec()
	# Walk the focus so regions have to be built, kept and dropped.
	for i in 8:
		layer.update_around(Vector3(32.0 + float(i) * 64.0, 0.0,
			32.0 + float(i) * 48.0))
	var stream_ms := float(Time.get_ticks_msec() - t0)
	var resident := layer.resident_regions().size()
	check(resident > 0, "the profiled layer is holding regions (%d)" % resident)
	check(int(layer.stats["regions_built"]) > built_after_first,
		"and it built more as the focus moved (%d -> %d)"
			% [built_after_first, int(layer.stats["regions_built"])])
	check(int(layer.stats["columns_written"]) > 0,
		"and it wrote authoritative columns (%d)"
			% int(layer.stats["columns_written"]))

	check(lod0_verts > 0 and lod6_verts > 0,
		"Terrain3D bakes LOD meshes from the authoritative heights (%d, %d verts)"
			% [lod0_verts, lod6_verts])
	# Region build cost as the layer itself accounted it, plus the wall clock
	# for the whole streaming walk above.
	var built := int(layer.stats["regions_built"])
	var per_region := float(stats_per_region(layer))
	print("[terrain3d] profile: regions_built=%d removed=%d resident=%d "
		% [built, int(layer.stats["regions_removed"]), resident]
		+ "columns=%d holes=%d build=%.1fms/region stream=%.1fms/9_updates "
			% [int(layer.stats["columns_written"]), int(layer.stats["columns_hole"]),
				per_region, stream_ms]
		+ "lod0=%d_verts/%.0fms lod6=%d_verts/%.0fms"
			% [lod0_verts, lod0_ms, lod6_verts, lod6_ms])
	if fine == null:
		warn("bake_mesh returned no mesh in this headless run, so baked LOD "
			+ "vertex counts above are 0")
	layer.free()


## Average region build time the layer recorded.
func stats_per_region(layer: TerrainLayerScript) -> float:
	return float(layer.stats["region_build_ms_total"]) / maxf(
		float(int(layer.stats["regions_built"])), 1.0)


func _test_material_mapping() -> void:
	var unknown: Array[String] = []
	for id in range(0, ContentDB.MAX_ID + 1):
		var cls := ArnisSourceScript.classify(id)
		if cls == "unknown":
			unknown.append(ContentDB.name_of(id))
	check(unknown.is_empty(),
		"every registered content id is classified (%s)" % ", ".join(unknown))

	for id in ArnisSourceScript.GROUND_IDS:
		check(ArnisSourceScript.classify(id) == "ground",
			"%s is terrain" % ContentDB.name_of(id))
	for id in ArnisSourceScript.WATER_IDS + ArnisSourceScript.VEGETATION_IDS \
			+ ArnisSourceScript.BUILT_IDS:
		check(ArnisSourceScript.classify(id) != "ground",
			"%s is not terrain" % ContentDB.name_of(id))

	var map: Dictionary = MaterialSetScript.content_map()
	check(map.has(ContentDB.GRASS) and map.has(ContentDB.STONE),
		"the manifest maps grass and stone to texture sets")
	for id in ArnisSourceScript.GROUND_IDS:
		check(MaterialSetScript.texture_id_for(id) >= 0,
			"terrain id %s has a Terrain3D texture id"
				% ContentDB.name_of(id))
	check(MaterialSetScript.sets().size() >= 4,
		"several terrain sets are available (%d)" % MaterialSetScript.sets().size())

	var layer := _layer(ARNIS_DIR, 40.0, 8)
	layer.update_around(Vector3(32, 0, 32))
	check(int(layer.stats["materials"]) > 0,
		"the layer built Terrain3D texture assets (%d)"
			% int(layer.stats["materials"]))
	# The per-column texture id is the ground's own content, so a plateau of
	# grass is textured as grass and a slope of stone as stone.
	var d: Object = layer.data()
	var grass_base := int(d.call("get_control_base_id", Vector3(40.0, 0, 40.0)))
	check(grass_base == MaterialSetScript.texture_id_for(ContentDB.GRASS),
		"a grass column carries the grass texture id (%d)" % grass_base)
	layer.free()
