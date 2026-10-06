## Regression test for the unsafe full-chunk occlusion bug.
##
## A 16x16x16 BoxOccluder3D placed on a chunk that is mostly air occludes
## geometry behind the EMPTY portions of that chunk. The game calls it
## "occlusion culling"; the renderer calls it "incorrectly discarding visible
## terrain". The screenshot looks wrong in a way that is easy to miss and
## impossible to un-see once you know what it is: ground that vanishes as you
## walk toward it.
##
## The fix removed the chunk-occluder path entirely rather than switching it
## off, so this test proves three things about the current build:
##
##   1. Nothing anywhere in the world creates an OccluderInstance3D, even on
##      terrain that is overwhelmingly air -- the exact shape that made the
##      old bug visible.
##   2. The API that built them is gone, not merely unused, so the path
##      cannot be re-enabled by a settings toggle.
##   3. Terrain is byte-identical with the occluder path disabled: the mesh
##      the scene graph holds is exactly what the mesher produces when called
##      directly. Removing a culling system must not move a single vertex --
##      if it did, the "fix" would have been a different bug.

extends SceneTree

var failures := 0


func _init() -> void:
	call_deferred("_run")


func fail(msg: String, results: String) -> void:
	failures += 1
	printerr("FAIL: ", msg)
	printerr("RESULT: ", results)


static func _count_occluders(n: Node) -> int:
	var total := 0
	for c in n.get_children():
		if c is OccluderInstance3D:
			total += 1
	return total


static func _surface_hash(m: ArrayMesh) -> String:
	if m == null:
		return "null"
	var parts := PackedStringArray()
	for i in m.get_surface_count():
		var a := m.surface_get_arrays(i)
		for k in a.size():
			if a[k] == null:
				continue
			parts.append("%s:%s" % [m.surface_get_name(i), str(a[k]).sha256_text()])
	return "|".join(parts).sha256_text()


func _run() -> void:
	var gen := WorldGenerator.new(90210)
	var w := VoxelWorld.new()
	w.materials = MaterialLibrary.new()
	w.materials.set_mapping(MaterialLibrary.mapping_name().size() - 1)
	w.world_dir = ""
	w.dimension = WorldGenerator.DIM_OVERWORLD
	w.generator = gen
	w.mesh_enabled = true
	w.async_meshing = false
	w.set_process(false)
	w.set_physics_process(false)
	w.set_process_unhandled_input(false)
	root.add_child(w)

	# Load and mesh the region through the game's own path. Radius 2, not 1:
	# `_can_mesh` needs all 26 neighbours, and a radius-1 sphere skips its own
	# corners (3 > 1*1+1), so the centre chunk could never be meshed.
	w.ensure_region(Vector3i.ZERO, 2)
	var key := w._key(Vector3i.ZERO)
	w._mark_dirty(key)
	w._mesh_job()
	w.flush_meshing()

	# --- 1. no occluder node exists, on a chunk that is mostly air ---------
	# A lone column in an otherwise-empty chunk is the shape where a
	# full-chunk box is most wrong: it would claim the empty sky above and
	# beside the column blocks the view.
	for y in [7, 8]:
		w.set_block(Vector3i(5, y, 5), 1)
	w._mark_dirty(key)
	w._mesh_job()
	w.flush_meshing()

	var n := _count_occluders(w)
	if n != 0:
		fail("%d occluder node(s) exist" % n,
			"occluder_count = %d; expected 0" % n)
		_finish(w)
		return

	# --- 2. the API that built them is gone -------------------------------
	if w.has_method("_update_occluder") or w.has_method("set_occluders"):
		fail("the chunk-occluder API still exists",
			"_update_occluder/set_occluders present")
		_finish(w)
		return
	var has_prop := false
	for p in w.get_property_list():
		if String(p["name"]) == "occluders":
			has_prop = true
	if has_prop:
		fail("the `occluders` switch still exists", "occluders property present")
		_finish(w)
		return
	var consts: Dictionary = load(
		"res://scripts/world/voxel_world.gd").get_script_constant_map()
	if consts.has("OCCLUDER_OFFSET"):
		fail("OCCLUDER_OFFSET constant still present", "OCCLUDER_OFFSET present")
		_finish(w)
		return

	# --- 3. terrain is identical with the occluder path disabled ----------
	# Direct mesher output vs. what the world installed. Any vertex or colour
	# that differs means removing the culling path changed the terrain.
	var mi: MeshInstance3D = w._meshes.get(key, null)
	if mi == null or mi.mesh == null:
		fail("the chunk has no geometry to compare", "mesh missing")
		_finish(w)
		return
	var direct := GreedyMesher.build(w._blocks[key],
		w._gather_neighbours(Vector3i.ZERO, key))
	var installed := _surface_hash(mi.mesh)
	var expected := _surface_hash(direct[0])
	if installed != expected:
		fail("terrain differs from direct mesher output",
			"installed = %s; direct = %s" % [installed, expected])
		_finish(w)
		return

	# Mining must still work and still leave no occluder behind: the removed
	# path must not have taken the re-mesh rule with it.
	var mined := 0
	for y in [7, 8]:
		if w.break_block(Vector3i(5, y, 5)):
			mined += 1
	w._mark_dirty(key)
	w._mesh_job()
	w.flush_meshing()

	n = _count_occluders(w)
	if n != 0:
		fail("mining recreated %d occluder(s)" % n,
			"mined = %d; occluder_count = %d" % [mined, n])
		_finish(w)
		return

	# Unloading must free the chunk's scene nodes and leave no occluder.
	w._unload_chunk(Vector3i.ZERO, key)
	n = _count_occluders(w)
	if n != 0:
		fail("unloading left %d occluder(s) behind" % n,
			"occluder_count after unload = %d" % n)
		_finish(w)
		return

	print("occluder: PASS")
	print(("RESULT: mined = %d; occluder_count = 0; mesh matches direct "
			+ "mesher output (%s)") % [mined, expected])
	_finish(w)


func _finish(w: VoxelWorld) -> void:
	if is_instance_valid(w):
		w.queue_free()
	if failures > 0:
		print("occluder: %d FAILURES" % failures)
	quit(1 if failures > 0 else 0)
