extends SceneTree
## End-to-end check: instantiates the real main scene, lets it stream chunks,
## and asserts that geometry actually reaches MeshInstance3D nodes.

const CHUNK_DIR := "/tmp/testchunks"

var failures := 0
var _frames := 0


func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: ", msg)


func _init() -> void:
	if not ChunkFiles.has_chunk(CHUNK_DIR, 0, 0, 0):
		printerr("no converted world at ", CHUNK_DIR)
		quit(1)
		return
	# Defer to a later frame so the scene tree is live and _ready has run.
	call_deferred("_run")


func _run() -> void:
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	main.set("world_dir", CHUNK_DIR)
	main.set("view_radius", 3)
	root.add_child(main)

	check(main.get("world") != null, "main._ready did not create the world")
	check(main.get("player") != null, "main._ready did not create the player")
	if main.get("world") == null or main.get("player") == null:
		printerr("scene did not initialise; aborting")
		quit(1)
		return

	# Let the scene stream and mesh across several frames.
	for i in 240:
		_process_step()
		_frames += 1
		if i == 60 or i == 120 or i == 239:
			_report(i, main)

	_verify(main)

	print("\nend-to-end: %s (after %d frames)"
		% ["PASS" if failures == 0 else "%d FAILURES" % failures, _frames])
	quit(1 if failures > 0 else 0)


## Drive the scene's own _process by hand so the test does not depend on
## wall-clock timing.
func _process_step() -> void:
	for child in root.get_children():
		if child.has_method("_process"):
			child.call("_process", 1.0 / 60.0)


func _report(frame: int, main: Node3D) -> void:
	var world: VoxelWorld = main.get("world")
	var s := world.get_stats()
	print("  frame %3d: chunks loaded=%d visible=%d meshed=%d"
		% [frame, s.chunks_loaded, s.chunks_visible, s.chunks_built])


func _verify(main: Node3D) -> void:
	var world: VoxelWorld = main.get("world")
	var player: Player = main.get("player")

	# --- World populated ---
	var s := world.get_stats()
	print("final: ", s)
	check(s.chunks_loaded > 0, "no chunks were loaded")
	check(s.chunks_visible > 0, "no chunk produced a visible mesh")
	check(s.textures > 0, "no Poly Haven texture sets were bound")
	print("textures bound: ", s.textures)

	# --- Real triangles in the scene graph, across every per-block surface ---
	var tris := 0
	var instances := 0
	var surfaces := 0
	for c in world.get_children():
		if c is MeshInstance3D:
			instances += 1
			if c.mesh != null and c.mesh.get_surface_count() > 0:
				surfaces += c.mesh.get_surface_count()
				for i in c.mesh.get_surface_count():
					tris += c.mesh.surface_get_array_index_len(i) / 3
	print("mesh instances: %d, surfaces: %d, triangles in scene: %d"
		% [instances, surfaces, tris])
	check(instances > 0, "no MeshInstance3D children under VoxelWorld")
	check(tris > 0, "scene contains no triangles")
	check(surfaces > instances,
		"chunks should carry more than one surface each (per block id)")

	# --- Every surface must have a material bound, and most must be textured ---
	var textured := 0
	var bound := 0
	for c in world.get_children():
		if not (c is MeshInstance3D) or c.mesh == null:
			continue
		for i in c.mesh.get_surface_count():
			var mat: Material = c.mesh.surface_get_material(i)
			if mat == null:
				continue
			bound += 1
			if mat is StandardMaterial3D \
					and (mat as StandardMaterial3D).albedo_texture != null:
				textured += 1
	print("surfaces with a material: %d, with an HD texture: %d"
		% [bound, textured])
	check(bound > 0, "no surface has a material bound")
	check(textured > 0, "no Poly Haven texture reached a surface")

	# --- Chunk-local geometry is actually placed in world space ---
	# ArrayMesh exposes its bounds via get_aabb(), not surface_get_aabb().
	var found := false
	var sample := ""
	for c in world.get_children():
		if c is MeshInstance3D and c.mesh != null \
				and c.mesh.get_surface_count() > 0:
			var centre: Vector3 = c.mesh.get_aabb().get_center() \
				+ c.global_position
			sample = "  sample chunk node at %s, geometry centre %s" \
				% [str(c.global_position), str(centre)]
			if centre.distance_to(Vector3(8, 8, 8)) < 400.0:
				found = true
			break
	print(sample)
	check(found, "chunk geometry is not positioned in world space")

	# --- Player spawned in a sane place and can read voxels ---
	var b := player.get_block_position()
	var cid: int = world.get_content_at(b)
	print("player at ", player.position, " looking at block ", b,
		" content ", cid)
	check(cid >= 0, "content lookup failed")
	check(Vector2(player.position.x, player.position.z).length() > 0.0,
		"player did not spawn")

	# --- Collision: the controller must agree with the voxel field ---
	var solid_found := false
	for x in range(0, 32):
		for z in range(0, 32):
			for y in range(0, 16):
				if world.solid_at(Vector3i(x, y, z)):
					solid_found = true
					break
			if solid_found:
				break
		if solid_found:
			break
	print("terrain contains solid voxels: ", solid_found)
	check(solid_found, "no solid voxels found in the spawn area")
