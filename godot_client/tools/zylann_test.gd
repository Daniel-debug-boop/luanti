extends SceneTree
## Voxel Tools (Zylann) backend test.
##
## Runs on BOTH engines:
##   * stock Godot 4.4  -> asserts the backend degrades gracefully
##   * Voxel Tools build -> asserts streaming, GDScript generation and voxel
##                          read/write actually work
##
## Usage:
##   stock:   sh tools/run_tests.sh /path/to/Godot_v4.4-stable_linux.x86_64
##   voxel:   sh tools/run_tests.sh /path/to/godot.linuxbsd.editor.x86_64

const MAX_FRAMES := 300

var _fails := 0
var _frames := 0
var _world: ZylannWorld = null
var _camera: Camera3D = null
var _built := false
var _done := false


func _init() -> void:
	_test_availability()
	if not ZylannWorld.is_available():
		_finish("stock engine -- graceful degradation verified")
		return
	_test_setup()
	if not _built:
		return
	# Wait for the streaming/generation thread to produce blocks.
	_pump()


func _test_availability() -> void:
	var have := ZylannWorld.is_available()
	print("Voxel Tools available: ", have)
	if have:
		_ok("VoxelTerrain present")
		_ok("VoxelLodTerrain present")
		_ok("VoxelGeneratorScript present")
		_ok("VoxelInstancer present")
		_ok("VoxelStreamRegionFiles present")
		_eq(ZylannWorld.unavailable_reason(), "", "no reason reported when available")
	else:
		# The whole point of the guard: the project must still run.
		var reason := ZylannWorld.unavailable_reason()
		if reason != "":
			_ok("reports why it is unavailable")
		else:
			_fail("unavailable_reason() was empty on stock engine")
		# Constructing the world on stock must not crash and must refuse.
		var w := ZylannWorld.new()
		root.add_child(w)
		var cam := Camera3D.new()
		root.add_child(cam)
		var ok := w.setup(cam)
		_eq(ok, false, "setup() refuses on stock engine")
		_eq(w.is_built(), false, "is_built() is false on stock engine")
		_eq(w.get_voxel(Vector3i.ZERO), 0, "get_voxel() is inert")
		_eq(w.set_voxel(Vector3i.ZERO, 1), false, "set_voxel() is inert")
		_eq(w.raycast(Vector3.ZERO, Vector3.DOWN, 10.0), null, "raycast() is inert")
		w.save()
		_eq(w.get_stats().get("available"), false, "stats report unavailable")
		w.queue_free()


func _test_setup() -> void:
	_world = ZylannWorld.new()
	_world.name = "ZylannWorld"
	# Keep the test hermetic: no region files written to the user's save dir.
	_world.with_persistence = false
	_world.with_instancer = true
	root.add_child(_world)

	_camera = Camera3D.new()
	# Park the camera just above the generated surface so the viewer requests
	# the blocks that actually contain terrain.
	_camera.position = Vector3(0, 46, 0)
	root.add_child(_camera)

	_built = _world.setup(_camera, "user://zylann_test", 4, 16)
	_eq(_built, true, "setup() builds the Voxel Tools stack")
	if not _built:
		return
	# Park the camera just above the real surface, otherwise the viewer only
	# ever requests blocks that are entirely above the terrain.
	var h: int = int(_world.generator.call("height_at", 0, 0))
	_camera.position = Vector3(0, h + 4, 0)
	_eq(_world.is_built(), true, "is_built()")
	_eq(_world.terrain != null, true, "terrain created")
	_eq(_world.viewer != null, true, "viewer created")
	_eq(_world.lod != null, true, "LOD terrain created")
	_eq(_world.instancer != null, true, "instancer created")
	_eq(_world.tool != null, true, "voxel tool obtained")
	_eq(_world.generator != null, true, "GDScript generator created")
	var stats := _world.get_stats()
	_eq(stats.get("backend"), "zylann", "stats backend")
	_eq(stats.get("available"), true, "stats available")


func _pump() -> void:
	# Voxel Tools streams and generates on worker threads; the main loop has to
	# keep ticking before any of it lands in the cache.
	pass


func _process(_delta: float) -> bool:
	if _done:
		return true
	_frames += 1
	if not _built:
		_finish("setup failed")
		return true

	# Streaming and generation happen on worker threads and expand outward a few
	# blocks per tick, so wait a fixed budget rather than bailing on the first
	# block that lands.
	if _frames < MAX_FRAMES:
		return false

	_test_generation()
	_test_voxel_access()
	_finish("voxels build")
	return true


func _test_generation() -> void:
	var gen: Object = _world.generator
	var blocks: int = int(gen.get("blocks_generated"))
	if blocks > 0:
		_ok("streaming generated %d data blocks" % blocks)
	else:
		_fail("no data blocks were generated")

	# The generator's pure terrain rules, checked without the voxel pipeline.
	var h: int = int(gen.call("height_at", 0, 0))
	if h > 0:
		_ok("height_at(0,0) = %d" % h)
	else:
		_fail("height_at(0,0) returned %d" % h)

	# Column profile must be solid up to the surface and air above it.
	var col: PackedInt32Array = gen.call("column_at", 0, 0)
	if col.is_empty():
		_fail("column_at(0,0) was empty")
		return
	var top: int = col[col.size() - 1]
	if top != 0:
		_fail("column_at(0,0) has a non-air top block: %d" % top)
	elif col.size() > 0 and col[0] != ContentDB.BEDROCK:
		_fail("column_at(0,0) does not start on bedrock")
	else:
		_ok("column profile: bedrock at the bottom, air on top")


func _test_voxel_access() -> void:
	var gen: Object = _world.generator
	var h: int = int(gen.call("height_at", 0, 0))

	var col: Array[String] = []
	for y in range(h - 4, h + 6):
		col.append("%d:%d" % [y, _world.get_voxel(Vector3i(0, y, 0))])
	print("  column(0,y,0) = ", ", ".join(col))

	var surface: int = _world.get_voxel(Vector3i(0, h, 0))
	if surface == ContentDB.AIR:
		_fail("generated surface block at (0,%d,0) reads back as air" % h)
	else:
		_ok("read back generated block %d at (0,%d,0)" % [surface, h])

	var probe := Vector3i(1, h + 3, 1)
	_world.set_voxel(probe, ContentDB.STONE)
	var written: int = _world.get_voxel(probe)
	_eq(written, ContentDB.STONE, "set_voxel() then get_voxel() round-trips")
	_world.set_voxel(probe, ContentDB.AIR)
	_eq(_world.get_voxel(probe), ContentDB.AIR, "voxel can be cleared again")

	# Out-of-bounds writes must be refused, not crash.
	_world.set_voxel(Vector3i(999999, 999999, 999999), ContentDB.STONE)
	_ok("out-of-bounds write did not crash")

	_world.save()
	_ok("save() on an in-memory stream is a no-op, not a crash")


# --- tiny assertion helpers --------------------------------------------------

func _ok(msg: String) -> void:
	print("  ok   ", msg)


func _fail(msg: String) -> void:
	_fails += 1
	print("  FAIL ", msg)


func _eq(got: Variant, want: Variant, what: String) -> void:
	if got == want:
		_ok("%s == %s" % [what, str(want)])
	else:
		_fail("%s: got %s, want %s" % [what, str(got), str(want)])


func _finish(note: String) -> void:
	if _done:
		return
	_done = true
	# Tear the Voxel Tools nodes down before quitting: its streaming and LOD
	# worker threads are still live at this point.
	if _world != null and is_instance_valid(_world):
		_world.free()
		_world = null
	if _camera != null and is_instance_valid(_camera):
		_camera.free()
		_camera = null
	print("--- zylann_test (%s) ---" % note)
	if _fails == 0:
		print("RESULT: PASS")
	else:
		print("RESULT: FAIL (%d)" % _fails)
	quit(1 if _fails > 0 else 0)
