extends SceneTree
## The worldstream GDExtension, through Godot, end to end.
##
## What this suite proves is the *chain*: a tile goes in as bytes, H3 answers
## where it belongs, features come out, geometry comes out of the features, and
## that geometry becomes an ArrayMesh. Every seam in that chain is a place
## where the native and scripted halves can disagree, and a suite that only
## checked `ClassDB.class_exists` would pass with all of them broken.
##
## The tile bytes are the same hand-encoded fixture the native suite uses --
## printed by worldstream/tools/worldstream_test.cpp, pasted here verbatim, so
## there is one encoder and two consumers rather than two fixtures that drift.
##
## Two runs are legitimate and both must be green:
##   * module built       -> the native assertions run
##   * module not built   -> the suite reports the absence and still passes,
##                           because an unbuilt optional module is a state a
##                           fresh checkout is allowed to be in

var _fails := 0
var _checks := 0

## Vector tile fixture: extent 4096, two buildings (levels=3, height=12), one
## landuse triangle, one road, one POI point in a layer the client ignores.
## Encoded by worldstream/tools/worldstream_test.cpp:make_fixture_tile().
const FIXTURE_BASE64 := "GncKCWJ1aWxkaW5nc3gCKIAgGg9idWlsZGluZzpsZXZlbHMaBmhlaWdodCIDCgEzIgQKAjEyEhoIARICAAAYAyIQCcgByAEa2AQAANgE1wQADxIaCAISAgEBGAMiEAnQD9APGugHAADoB+cHAA8SCQgDGAEiAwkOEhohCgdsYW5kdXNleAIogCASEQgEGAMiCwkAABLQDwAA0A8PGh0KB2hpZ2h3YXl4AiiAIBINCAUYAiIHCQAACoBAABoXCgNwb2l4AiiAIBILCAYYASIFCcgBkAM="


func _init() -> void:
	_test_native_presence()

	if ClassDB.class_exists("WorldStreamNative"):
		_test_facade_shape()
		_test_h3_queries()
		_test_parse_fixture()
		_test_meshlets()
		_test_failure_paths()
	_test_report()


func _test_report() -> void:
	if _fails == 0:
		# tools/run_tests.sh matches a verdict line at column 0.
		print("worldstream: %d checks, 0 FAILURES" % _checks)
	else:
		print("worldstream: %d checks, %d FAILURES" % [_checks, _fails])
	quit(0 if _fails == 0 else 1)


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		printerr("FAIL: ", what)


func _eq(got: Variant, want: Variant, what: String) -> void:
	_check(got == want, "%s (got %s, want %s)" % [what, str(got), str(want)])


func _near(a: float, b: float, what: String, eps := 0.01) -> void:
	_check(absf(a - b) <= eps, "%s (got %f, want %f)" % [what, a, b])


# --- presence ---------------------------------------------------------------

func _test_native_presence() -> void:
	# The point of this assertion is that the answer is *reported*, not that it
	# is either value: an unbuilt module and a built one are both valid states.
	var present := ClassDB.class_exists("WorldStreamNative")
	print("  info native module present: %s" % present)
	_check(typeof(present) == TYPE_BOOL, "module presence is reported, not assumed")

	var ws := WorldStream.new()
	_eq(ws.available, present, "the facade agrees with ClassDB about availability")
	if not present:
		print("  note module not built: %s" % ws.reason)
		_check(ws.reason != "", "the facade explains why it is unavailable")
		_check(ws.cells_around(0.0, 0.0).is_empty(),
			"and its queries degrade to empty rather than failing")
		var parsed: Dictionary = ws.parse_tile(PackedByteArray(), 0, 9, 1000.0)
		_eq(parsed["ok"], false, "as does parse_tile")
	else:
		_check(ws.reason == "", "an available facade has no reason to report")
		_check(ws.describe().contains("version"),
			"and describes the interface version it speaks")


# --- facade shape -----------------------------------------------------------

func _test_facade_shape() -> void:
	var ws := WorldStream.new()
	_check(ws.available, "the facade is available when the module is")

	# Explicitly typed: ClassDB.instantiate() returns Variant, and inferring a
	# type from it is a warning this project treats as an error.
	var native: Object = ClassDB.instantiate("WorldStreamNative")
	_check(native != null, "the native class instantiates from ClassDB")
	_eq(int(native.module_version()), WorldStream.EXPECTED_MODULE_VERSION,
		"the module speaks the version the facade expects")

	# A version-mismatched module must be refused, not reinterpreted. This is
	# checked by construction here (the constant is the contract), so the
	# assertion that matters is that the constant has not silently changed.
	_eq(WorldStream.EXPECTED_MODULE_VERSION, 1, "the facade's version constant")


# --- H3 ---------------------------------------------------------------------

func _test_h3_queries() -> void:
	var ws := WorldStream.new()
	const LAT := 37.8715
	const LON := -122.2730

	var centre := ws.cells_around(LAT, LON, 9, 0)
	_eq(centre.size(), 1, "radius 0 is the centre cell alone")

	var ring1 := ws.cells_around(LAT, LON, 9, 1)
	_eq(ring1.size(), 7, "radius 1 is 1 + 6 cells")

	var ring2 := ws.cells_around(LAT, LON, 9, 2)
	_eq(ring2.size(), 19, "radius 2 is 1 + 6 + 12 cells")
	_eq(ring2[0], centre[0], "the disk's first cell is the centre cell")

	# The streaming resolutions are a band, not a suggestion.
	_eq(ws.cells_around(LAT, LON, 4, 1).size(), 0,
		"a coarse resolution outside the band is refused")
	_eq(ws.cells_around(LAT, LON, 14, 1).size(), 0,
		"as is one finer than the band")

	var c := ws.cell_center(ring1[0])
	_eq(c.size(), 2, "a cell has a centre")
	_near(c[0], LAT, "and it is at the requested latitude", 0.01)
	_near(c[1], LON, "and longitude", 0.01)

	_eq(ws.cell_center(0).size(), 0, "index 0 is not a cell")
	_eq(ws.cell_center(-1).size(), 0, "and neither is a negative index")


# --- parsing ----------------------------------------------------------------

func _test_parse_fixture() -> void:
	var ws := WorldStream.new()
	var bytes := Marshalls.base64_to_raw(FIXTURE_BASE64)
	_check(bytes.size() > 0, "the fixture decoded")

	var cells := ws.cells_around(37.8715, -122.2730, 9, 0)
	var result := ws.parse_tile(bytes, cells[0], 9, 1000.0)
	_eq(result["ok"], true, "the fixture parses end to end")

	var batch: Object = result["batch"]
	_check(batch != null, "a successful parse hands back a batch")
	if batch == null:
		return

	_eq(batch.footprint_count(), 3, "two buildings and one landuse polygon")
	_eq(batch.spline_count(), 1, "one road")

	var stats: Dictionary = result["stats"]
	_eq(stats["buildings"], 2, "building stat")
	_eq(stats["landuse"], 1, "landuse stat")
	_eq(stats["highways"], 1, "highway stat")
	_check(int(stats["total_points"]) >= 12, "point stat counts decoded vertices")

	var f0: Dictionary = batch.footprint(0)
	_eq(f0["levels"], 3, "levels are read from the tile's tags")
	_near(f0["height_m"], 9.6, "and become a height")
	var ring: PackedVector2Array = f0["ring"]
	_check(ring.size() >= 4, "the ring has its vertices")
	_near(ring[0].x, -500.0 + 24.4140625, "tile-local metres are centred", 0.001)

	var f1: Dictionary = batch.footprint(1)
	_near(f1["height_m"], 12.0, "an explicit height tag wins over levels")

	var road: Dictionary = batch.spline(0)
	var points: PackedVector2Array = road["points"]
	_eq(points.size(), 2, "the road has two points")
	_near(points[1].x, 500.0, "and spans the tile", 0.001)

	# "No data here" is not an error; garbage is.
	var empty := ws.parse_tile(PackedByteArray(), cells[0], 9, 1000.0)
	_eq(empty["ok"], true, "an empty tile parses as empty, not as a failure")
	_eq(empty["batch"].footprint_count(), 0, "with no footprints")

	var garbage := PackedByteArray()
	garbage.resize(32)
	for i in 32:
		garbage[i] = (i * 37 + 11) & 0xFF
	var bad := ws.parse_tile(garbage, cells[0], 9, 1000.0)
	_eq(bad["ok"], false, "garbage bytes are refused")
	_check(String(bad["error"]) != "", "with a reason")


# --- meshing ----------------------------------------------------------------

func _test_meshlets() -> void:
	var ws := WorldStream.new()
	var bytes := Marshalls.base64_to_raw(FIXTURE_BASE64)
	var cells := ws.cells_around(37.8715, -122.2730, 9, 0)
	var parsed := ws.parse_tile(bytes, cells[0], 9, 1000.0)
	var data := ws.build_meshlets(parsed["batch"])
	_eq(data["ok"], true, "the tile meshes")

	var positions: PackedVector3Array = data["positions"]
	var normals: PackedVector3Array = data["normals"]
	var indices: PackedInt32Array = data["indices"]
	var meshlets: Array = data["meshlets"]
	_check(positions.size() > 0, "with vertices")
	_eq(normals.size(), positions.size(), "normals for every vertex")
	_eq(int(data["triangles"]), indices.size() / 3, "and whole triangles")
	_check(meshlets.size() > 0, "split into meshlets")
	_eq(indices.size() % 3, 0, "the index buffer is whole triangles")

	# The 64/126 meshlet limits are the contract with the mesh shader; a
	# meshlet that exceeds them renders wrongly, not slowly.
	var mv: PackedInt32Array = data["meshlet_vertices"]
	var mt: PackedByteArray = data["meshlet_triangles"]
	var in_range := true
	var max_index := 0
	for i in indices:
		max_index = maxi(max_index, i)
	_check(max_index < positions.size(), "every index addresses a vertex")
	for m in meshlets:
		if int(m["vertex_count"]) > 64 or int(m["triangle_count"]) > 126:
			in_range = false
		if int(m["vertex_count"]) == 0 or int(m["triangle_count"]) == 0:
			in_range = false
		for t in int(m["triangle_count"]) * 3:
			if mt[int(m["triangle_offset"]) + t] >= int(m["vertex_count"]):
				in_range = false
		for v in int(m["vertex_count"]):
			if mv[int(m["vertex_offset"]) + v] >= positions.size():
				in_range = false
	_check(in_range, "every meshlet respects its limits and its own window")

	# Geometry truth: the buildings stand 9.6 m and 12 m above ground.
	var top := -1e9
	var bottom := 1e9
	for p in positions:
		top = maxf(top, p.y)
		bottom = minf(bottom, p.y)
	_near(top, 12.0, "the tallest roof is the height-tagged one", 0.02)
	_near(bottom, 0.0, "walls reach the ground plane", 0.02)
	var bmax: Vector3 = data["bounds_max"]
	var bmin: Vector3 = data["bounds_min"]
	_near(bmax.y, top, "bounds track the geometry")
	_check(bmax.x > bmin.x, "and the horizontal bounds are non-degenerate")

	# The output must be *usable*, which is what building a real mesh
	# checks and a shape check does not.
	var mesh := ws.mesh_from_meshlets(data)
	_check(mesh != null, "the arrays build an ArrayMesh")
	if mesh != null:
		_eq(mesh.get_surface_count(), 1, "with one surface")
		_check(mesh.surface_get_array_len(0) == positions.size(),
			"holding every vertex")

	# Determinism: a tile re-fetched after eviction must mesh to the same
	# bytes as the one it replaced.
	var again := ws.build_meshlets(parsed["batch"])
	_check(again["indices"] == indices and again["positions"] == positions,
		"meshing the same tile twice is byte-identical")

	# The facade's degradation path must not be able to produce a mesh.
	_check(ws.mesh_from_meshlets({"ok": false}) == null,
		"a failed mesh result yields no mesh")


# --- failure paths ----------------------------------------------------------

func _test_failure_paths() -> void:
	var ws := WorldStream.new()
	_check(ws.build_meshlets(null)["ok"] == false, "meshing nothing is refused")
	_check(String(ws.build_meshlets(null)["error"]) != "", "with a reason")

	var cells := ws.cells_around(37.8715, -122.2730, 9, 0)
	# A tile whose bytes are not a tile must not poison the batch it would
	# have filled: the failure is reported, and nothing is handed back.
	var result := ws.parse_tile(PackedByteArray([1, 2, 3, 4]), cells[0], 9, 1000.0)
	_eq(result["ok"], false, "a short invalid buffer is refused")
	_check(result.get("batch", null) == null,
		"and no batch is handed back for it")
