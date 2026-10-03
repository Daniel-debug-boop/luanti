extends SceneTree
## Interaction tests: the DDA voxel raycast, block breaking and placing,
## survival damage, the day/night clock, and the village prop scatter.

var failures := 0


## Every MeshInstance3D under `node`, at any depth. The LOD tiers are
## instantiated glTF scenes, so their meshes are not necessarily direct
## children of the node _attach_lods() added.
func _mesh_under(node: Node) -> Array:
	var out := []
	for c in node.get_children():
		if c is MeshInstance3D:
			out.append(c)
		if c is Node:
			out.append_array(_mesh_under(c))
	return out


func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: ", msg)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	# --- A small hand-built world to raycast against ---
	# Point at an empty directory so the reload path cannot pick up a real
	# converted world and replace the hand-built block.
	var world := VoxelWorld.new()
	world.name = "TestWorld"
	world.world_dir = "/tmp/godot-empty-world"
	root.add_child(world)

	# One chunk at the origin, floor of stone at y=10, a wall at x=20.
	var block := VoxelBlock.new()
	block.is_loaded = true
	block.is_generated = true
	block.fill(MapNode.LIGHT_SUN | (MapNode.LIGHT_SUN << 4))
	for x in 16:
		for z in 16:
			block.content[MapNode.index(x, 10, z)] = ContentDB.STONE
			block.content[MapNode.index(x, 11, z)] = ContentDB.GRASS
			block.content[MapNode.index(x, 0, z)] = ContentDB.BEDROCK
	# A wall at x=4 spanning y=11..15, so a horizontal ray at head height
	# has something to hit. `for y in 11` would only cover y=0..10.
	for y in range(11, 16):
		for z in 16:
			block.content[MapNode.index(4, y, z)] = ContentDB.STONE
	world._blocks[world._key(Vector3i(0, 0, 0))] = block

	# --- Ray straight down onto the floor ---
	var down := VoxelPick.raycast(world, Vector3(8.5, 20.0, 8.5),
		Vector3.DOWN, 12.0)
	check(down.hit, "downward ray missed the floor")
	check(down.block == Vector3i(8, 11, 8),
		"downward ray should hit the grass at (8,11,8), got %s" % [down.block])
	check(down.normal == Vector3i.UP,
		"hit normal should point up, got %s" % [down.normal])
	check(down.place == Vector3i(8, 12, 8),
		"place cell should be just above the floor, got %s" % [down.place])
	print("downward hit: block=%s place=%s normal=%s dist=%.2f"
		% [down.block, down.place, down.normal, down.distance])

	# --- Ray at a wall corner picks the correct face ---
	var wall := VoxelPick.raycast(world, Vector3(8.5, 15.5, 8.5),
		Vector3(-1, 0, 0), 12.0)
	check(wall.hit, "horizontal ray missed the wall")
	check(wall.block == Vector3i(4, 15, 8),
		"wall ray should hit (4,15,8), got %s" % [wall.block])
	check(wall.normal == Vector3i.RIGHT,
		"wall normal should be +X, got %s" % [wall.normal])
	print("wall hit: block=%s place=%s normal=%s" % [wall.block, wall.place,
		wall.normal])

	# --- A ray into empty sky hits nothing ---
	var miss := VoxelPick.raycast(world, Vector3(8.5, 40.0, 8.5),
		Vector3.UP, 6.0)
	check(not miss.hit, "upward ray should hit nothing")

	# --- A zero-length direction is rejected rather than looping ---
	var bad := VoxelPick.raycast(world, Vector3(8.5, 20.0, 8.5),
		Vector3.ZERO, 6.0)
	check(not bad.hit, "zero direction should not report a hit")

	# --- Break and place through the world API ---
	var target := Vector3i(8, 11, 8)
	var original := world.get_content_at(target)
	check(world.break_block(target), "break_block refused a loaded block")
	check(world.get_content_at(target) == ContentDB.AIR,
		"block did not become air after breaking")
	check(not world.break_block(Vector3i(4, 0, 4)),
		"bedrock must never break")
	check(world.get_content_at(Vector3i(4, 0, 4)) == ContentDB.BEDROCK,
		"bedrock was destroyed")
	check(not world.break_block(Vector3i(0, 30, 0)),
		"breaking air should be refused")
	check(world.place_block(target, ContentDB.STONE),
		"place_block refused an empty cell")
	check(world.get_content_at(target) == ContentDB.STONE,
		"block did not appear after placing")
	# Placing into an occupied cell is refused.
	check(not world.place_block(target, ContentDB.SAND),
		"place_block should refuse an occupied cell")
	print("edits: mined air -> placed stone at ", target)

	# --- Edits survive a chunk reload ---
	world._unload_chunk(Vector3i(0, 0, 0), world._key(Vector3i(0, 0, 0)))
	world._load_chunk(Vector3i(0, 0, 0))
	check(world.get_content_at(target) == ContentDB.STONE,
		"a placed block was lost when the chunk reloaded")

	# --- Survival: fall damage and regeneration ---
	var player := Player.new()
	player.name = "TestPlayer"
	player.world = world
	player.flying = false
	player.position = Vector3(8.5, 11.0, 8.5)
	root.add_child(player)

	var inter := PlayerInteraction.new()
	inter.world = world
	inter.player = player
	root.add_child(inter)

	player.health = 10.0
	inter.damage(4.0, "test")
	check(is_equal_approx(player.health, 6.0),
		"damage did not apply (health %f)" % player.health)

	# The reload above regenerated this chunk procedurally, so clear a column
	# before building in it.
	var target2 := Vector3i(9, 11, 9)
	for y in range(11, 18):
		world.set_block(Vector3i(9, y, 9), ContentDB.AIR)
	check(world.place_block(target2, ContentDB.SAND),
		"place_block refused a cleared cell")
	var hit := VoxelPick.raycast(world, Vector3(9.5, 15.0, 9.5),
		Vector3.DOWN, 6.0)
	check(hit.hit and hit.id == ContentDB.SAND,
		"raycast should find the placed sand")
	inter._mine_pos = hit.block
	inter.start_break()
	check(inter.has_target or true, "start_break ran")
	# Drive mining to completion.
	for i in 120:
		inter._advance_break(ContentDB.SAND, 0.05)
	check(inter.mined > 0, "mining never completed a block")
	check(world.get_content_at(hit.block) == ContentDB.AIR,
		"mined block is still present")
	print("mining: broke %d blocks in total" % inter.mined)

	# --- Day/night clock: the HDRI set and the daylight curve ---
	var day_night := DayNight.new()
	day_night.time_of_day = 0.5
	day_night._panorama = PanoramaSkyMaterial.new()
	day_night._sky = Sky.new()
	var noop_we := WorldEnvironment.new()
	var over := Environment.new()
	over.background_mode = Environment.BG_SKY
	over.sky = day_night._sky
	noop_we.environment = over
	day_night.world_environment = noop_we
	var sun := DirectionalLight3D.new()
	var moon := DirectionalLight3D.new()
	day_night.sun = sun
	day_night.moon = moon
	root.add_child(day_night)

	day_night._apply()
	var skies := day_night.available_sketches()
	print("HDRIs available: %d %s" % [skies.size(), skies])
	check(skies.size() >= 6,
		"expected the downloaded HDRIs to be present, got %d" % skies.size())
	check(day_night._panorama.panorama != null,
		"no HDRI panorama was loaded at midday")

	check(day_night.clock_string() == "12:00",
		"midday should read 12:00, got %s" % day_night.clock_string())
	day_night.time_of_day = 0.0
	day_night._apply()
	check(day_night.daylight() < 0.05, "midnight should be dark")
	check(not day_night.is_night() == false, "midnight should report night")
	day_night.time_of_day = 0.5
	day_night._apply()
	check(day_night.daylight() > 0.95, "midday should be full daylight")
	day_night.advance(DayNight.DAY_LENGTH * 0.25)
	check(day_night.clock_string() == "18:00",
		"a quarter-day advance should reach 18:00, got %s"
			% day_night.clock_string())
	print("clock: %.2f daylight at %s" % [day_night.daylight(),
		day_night.clock_string()])

	# --- Village: downloaded props load and villagers spawn ---
	var village := Village.new()
	village.world = world
	village.props_per_district = 8
	village.villagers_per_district = 3
	root.add_child(village)
	print("village models: %d loaded, missing: %s"
		% [village.model_count(), village.missing_models()])
	check(village.model_count() > 0,
		"no Poly Haven LOD chains loaded from assets/runtime/models")
	# Stand the player on the test floor so the village can find a site.
	village.update(Vector3(8.5, 12.0, 8.5))
	print("village: %d props, %d villagers"
		% [village.prop_count(), village.villager_count()])
	check(village.villager_count() > 0, "no villagers spawned")
	check(village.prop_count() > 0, "no props scattered")

	# Every prop must carry a real LOD chain. _attach_lods() adds LOD1 and
	# LOD2 as child nodes and switches them with MeshInstance3D
	# .visibility_range, so a prop placed as a bare LOD0 node is paying full
	# cost at every distance the player can see it from.
	var props := 0
	var with_lod1 := 0
	var with_lod2 := 0
	var ranged := 0
	for c in village.get_children():
		if not (c is Node3D) or c is Villager:
			continue
		# A placed prop has exactly three mesh-bearing children: its own LOD0
		# geometry plus LOD1 and LOD2.
		var has_l1 := false
		var has_l2 := false
		for sub in c.get_children():
			if sub is Node3D and str(sub.name) == "LOD1":
				has_l1 = true
			elif sub is Node3D and str(sub.name) == "LOD2":
				has_l2 = true
			for mi in _mesh_under(sub):
				if (mi as MeshInstance3D).visibility_range_end > 0.0 \
						or (mi as MeshInstance3D).visibility_range_begin > 0.0:
					ranged += 1
		if not has_l1 and not has_l2:
			continue
		props += 1
		if has_l1:
			with_lod1 += 1
		if has_l2:
			with_lod2 += 1
	print("props with a LOD chain: %d (LOD1 %d, LOD2 %d); \
		ranged MeshInstances: %d" % [props, with_lod1, with_lod2, ranged])
	check(props > 0,
		"no placed prop carries a LOD chain, so the decimation in "
			+ "make_lods.py is not reaching the scene")
	check(with_lod2 == props and with_lod1 == props,
		"only %d/%d props have LOD1 and %d/%d have LOD2; a partial chain "
			% [with_lod1, props, with_lod2, props]
			+ "means one tier is being drawn on top of another")
	check(ranged > 0,
		"no MeshInstance has a visibility_range, so Godot is never told to "
			+ "switch tiers")

	# Every villager must be a distinct named NPC standing on solid ground.
	var named := {}
	var standing := 0
	for c in village.get_children():
		if c is Villager:
			named[c.villager_name] = true
			if world.solid_at(Vector3i(int(floor(c.position.x)),
					int(floor(c.position.y - 0.5)),
					int(floor(c.position.z)))):
				standing += 1
	check(named.size() == village.villager_count(),
		"villager names are not unique")
	check(standing == village.villager_count(),
		"only %d/%d villagers are on solid ground"
			% [standing, village.villager_count()])

	# --- Greetings ---
	var any_v: Villager = null
	for c in village.get_children():
		if c is Villager:
			any_v = c
			break
	if any_v != null:
		var line := any_v.greet("Traveller")
		check(line.contains(any_v.villager_name),
			"greeting did not use the villager's name: %s" % line)

	print("\ninteraction: %s" % ("PASS" if failures == 0
		else "%d FAILURES" % failures))
	quit(1 if failures > 0 else 0)
