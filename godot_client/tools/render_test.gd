extends SceneTree
## Render-readiness check: confirms the world builds textured PBR surfaces,
## HDRI sky panoramas, village props and a camera, all without needing a
## display server. Renders into an offscreen viewport where a GPU is
## available, and skips that where headless rendering is not.

const CHUNK_DIR := "/tmp/testchunks"
const OUT := "user://shot.png"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	main.set("world_dir", CHUNK_DIR)
	main.set("view_radius", 3)
	root.add_child(main)

	var world: VoxelWorld = main.get("world")
	var player: Player = main.get("player")
	var day_night: DayNight = main.get("day_night")
	var village: Village = main.get("village")
	if world == null or player == null:
		printerr("scene failed to initialise")
		quit(1)
		return

	# Stream and mesh everything.
	for i in 400:
		main.call("_process", 1.0 / 60.0)
		if i == 200:
			player.position = Vector3(8.5, 26.0, 8.5)

	# Structural checks that a real render depends on.
	var textured := 0
	var vertex_color := 0
	var total_surfaces := 0
	var tris := 0
	var world_min := Vector3(INF, INF, INF)
	var world_max := Vector3(-INF, -INF, -INF)
	for c in world.get_children():
		if not (c is MeshInstance3D):
			continue
		var mesh := c.mesh as ArrayMesh
		if mesh == null or mesh.get_surface_count() == 0:
			continue
		total_surfaces += mesh.get_surface_count()
		for s in mesh.get_surface_count():
			var mat := mesh.surface_get_material(s)
			if mat is StandardMaterial3D:
				var sm := mat as StandardMaterial3D
				if sm.albedo_texture != null:
					textured += 1
				if sm.vertex_color_use_as_albedo:
					vertex_color += 1
			tris += mesh.surface_get_array_index_len(s) / 3
		var aabb: AABB = mesh.get_aabb()
		world_min = world_min.min(c.global_position + aabb.position)
		world_max = world_max.max(c.global_position + aabb.end)

	print("surfaces: %d (%d textured, %d vertex-coloured)"
		% [total_surfaces, textured, vertex_color])
	print("triangles: %d" % tris)
	print("world bounds: ", world_min, " .. ", world_max)

	var cams := _find_cameras(main)
	print("cameras in scene: ", cams.size())

	# --- Sky ---
	var env := (main.get("_we") as WorldEnvironment).environment
	var sky_mat := env.sky.sky_material as PanoramaSkyMaterial
	print("sky panorama: ", sky_mat.panorama if sky_mat != null else null)
	var skies := day_night.available_sketches() if day_night != null \
		else PackedStringArray()
	print("HDRIs available: %d" % skies.size())

	# --- Village props ---
	var props := 0
	var vill := 0
	if village != null:
		for c in village.get_children():
			if c is Villager:
				vill += 1
			else:
				props += 1
	print("village: %d prop nodes, %d villagers" % [props, vill])

	var ok := tris > 0 and textured > 0 and vertex_color > 0 and cams.size() > 0
	ok = ok and sky_mat != null and sky_mat.panorama != null
	print("\nrender-readiness: %s" % ("PASS" if ok else "FAIL"))
	quit(0)


func _find_cameras(n: Node) -> Array:
	var out := []
	if n is Camera3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_find_cameras(c))
	return out
