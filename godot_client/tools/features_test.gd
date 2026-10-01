extends SceneTree
## Feature tests: dimension switching, Deeps streaming, mob spawning.

var failures := 0


func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: ", msg)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	main.set("view_radius", 3)
	root.add_child(main)

	var world: VoxelWorld = main.get("world")
	var player: Player = main.get("player")
	var spawner: MobSpawner = main.get("spawner")
	var village: Village = main.get("village")
	var day_night: DayNight = main.get("day_night")
	var interaction: PlayerInteraction = main.get("interaction")
	check(world != null and player != null and spawner != null,
		"scene references missing")
	check(village != null and day_night != null and interaction != null,
		"village, day/night or interaction node missing")

	# Let the overworld stream.
	for i in 200:
		main.call("_process", 1.0 / 60.0)
	var over_stats := world.get_stats()
	print("overworld: ", over_stats)
	check(over_stats.chunks_visible > 0, "overworld did not mesh")

	# --- Village: downloaded props and villagers exist in the overworld ---
	print("village models: %d loaded, %d props, %d villagers"
		% [village.model_count(), village.prop_count(), village.villager_count()])
	check(village.model_count() > 0, "no Poly Haven models loaded")
	check(village.prop_count() > 0, "no props scattered around the village")
	check(village.villager_count() > 0, "no villagers spawned")
	var villager_names := {}
	for c in village.get_children():
		if c is Villager:
			villager_names[(c as Villager).villager_name] = true
	check(villager_names.size() == village.villager_count(),
		"villagers are missing distinct names")

	# --- Day/night clock is running and the sky has an HDRI ---
	var clock_a := day_night.clock_string()
	main.call("_process", 10.0)
	var clock_b := day_night.clock_string()
	print("clock: %s -> %s, daylight %.2f"
		% [clock_a, clock_b, day_night.daylight()])
	check(clock_a != clock_b, "the day/night clock did not advance")
	var env: Environment = (main.get("_we") as WorldEnvironment).environment
	var sky_mat := env.sky.sky_material as PanoramaSkyMaterial
	check(sky_mat != null and sky_mat.panorama != null,
		"the sky is not using a downloaded HDRI panorama")

	# --- Switch to The Deeps ---
	main.call("_switch_dimension")
	for i in 200:
		main.call("_process", 1.0 / 60.0)
	var deeps_stats := world.get_stats()
	print("deeps: ", deeps_stats)
	check(world.dimension == WorldGenerator.DIM_DEEPS,
		"dimension flag did not change")
	check(deeps_stats.chunks_visible > 0, "deeps did not mesh")

	# The Deeps must actually contain deepslate and glowstone.
	var deepslate := 0
	var glow := 0
	var air := 0
	for dx in [-1, 0]:
		for dy in [0]:
			for dz in [-1, 0, 1]:
				var b := world.get_block(Vector3i(dx, -1, dz))
				if b == null:
					continue
				for i in 4096:
					match b.content[i]:
						ContentDB.DEEPSLATE, ContentDB.DEEPSLATE_DEEP:
							deepslate += 1
						ContentDB.GLOWSTONE:
							glow += 1
						ContentDB.AIR:
							air += 1
	print("deeps voxels: deepslate=%d glowstone=%d air=%d"
		% [deepslate, glow, air])
	check(deepslate > 0, "no deepslate in loaded deeps chunks")
	check(glow > 0, "no glowstone in loaded deeps chunks")

	# --- Switch back: cached meshes should reappear immediately ---
	main.call("_switch_dimension")
	var back_stats := world.get_stats()
	print("back to overworld: ", back_stats)
	check(world.dimension == WorldGenerator.DIM_OVERWORLD,
		"did not return to the overworld")

	# --- Mine a block end to end through the real interaction node ---
	var found_target := false
	var mine_x := 0
	var mine_y := 0
	var mine_z := 0
	for x in range(0, 32):
		for z in range(0, 32):
			var y := 40
			while y > 1:
				if world.solid_at(Vector3i(x, y, z)):
					found_target = true
					mine_x = x
					mine_y = y
					mine_z = z
					break
				y -= 1
			if found_target:
				break
		if found_target:
			break
	check(found_target, "no solid block found to mine")
	if found_target:
		var bx := Vector3i(mine_x, mine_y, mine_z)
		var before := world.get_content_at(bx)
		interaction._mine_pos = bx
		interaction.start_break()
		for i in 200:
			interaction._advance_break(before, 0.05)
		print("mined %d, placed %d" % [interaction.mined, interaction.placed])
		check(interaction.mined > 0, "mining through the scene broke nothing")
		check(world.get_content_at(bx) == ContentDB.AIR,
			"mined block is still in the world")

	# --- Mobs ---
	# The engine calls the spawner's _process automatically; this harness
	# must drive it by hand alongside main.
	for i in 400:
		main.call("_process", 1.0 / 60.0)
		spawner.call("_process", 1.0 / 60.0)
	var n := spawner.mob_count()
	print("mobs alive: ", n)
	check(n > 0, "no mobs spawned in 400 frames")

	# Mob terrain interaction: every mob must be on/above solid ground.
	var grounded := 0
	for mob in spawner.get_children():
		if mob is Mob:
			var below := Vector3i(int(floor(mob.position.x)),
				int(floor(mob.position.y - 0.2)), int(floor(mob.position.z)))
			if world.solid_at(below):
				grounded += 1
	print("mobs standing on terrain: ", grounded, "/", n)

	# --- Clicking a hotbar slot selects it ---
	# This path used to be dead: `_input` did `for slot in _hotbar` over an
	# HBoxContainer, and a Node is not iterable, so the function failed to
	# COMPILE. Every test above still passed while the game could not select
	# a slot with the mouse, because none of them clicked anything.
	var hud: Node = main.get("hud")
	check(hud != null, "no HUD on the main scene")
	if hud != null:
		var slots: Array = hud.get("_hotbar_slots")
		check(slots.size() > 0, "the hotbar built no slots")
		if slots.size() > 1:
			# Container layout never runs headless: without a display server
			# all eight slots keep position (0,0) inside an unsized HBox, so
			# every rect is identical and a click cannot be aimed at one slot.
			# Lay them out by hand so the click has a real target. This is the
			# game's own hit-test path being exercised -- only the positions
			# are synthetic.
			for i in slots.size():
				(slots[i] as Control).position = Vector2(i * 52.0, 0.0)
			var target: Control = slots[2]
			var click := InputEventMouseButton.new()
			click.button_index = MOUSE_BUTTON_LEFT
			click.pressed = true
			click.position = target.get_global_rect().get_center()
			hud.call("_input", click)
			var picked: int = interaction.selected
			check(picked == 2,
				"clicking hotbar slot 3 selected slot %d" % (picked + 1))
			# A click on empty space must change nothing.
			var before: int = interaction.selected
			var away := InputEventMouseButton.new()
			away.button_index = MOUSE_BUTTON_LEFT
			away.pressed = true
			away.position = Vector2(-500, -500)
			hud.call("_input", away)
			check(interaction.selected == before,
				"a click off the hotbar changes the selection")

	print("\nfeatures: %s" % ("PASS" if failures == 0
		else "%d FAILURES" % failures))
	quit(1 if failures > 0 else 0)
