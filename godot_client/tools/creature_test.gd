extends SceneTree
## Audio (CC0 Kenney), CC0 KayKit creature models, A* pathfinding and block
## drops -- the systems added after inventory/crafting/saving.

var _fails := 0


func _init() -> void:
	_test_sound_bank()
	_test_audio_playback()
	_test_creature_models()
	_test_pathfinding()
	_test_block_drops()
	_finish()


# --- audio ------------------------------------------------------------------

func _test_sound_bank() -> void:
	var events := AudioDirector.events()
	_ok("sound bank declares %d events" % events.size())
	_eq(events.size() >= 15, true, "bank covers the game events")

	# Every declared variant must resolve to a real file, or an action would be
	# silently mute in the shipped game.
	var missing: Array[String] = []
	for e in events:
		if not AudioDirector.bank_is_complete(e):
			missing.append(String(e))
	_eq(missing, ([] as Array[String]),
		"every event resolves to real CC0 wav files")

	# Event names used by the wiring must all exist.
	for required in ["break_hard", "break_soft", "break_glass", "place",
			"hurt", "mob_hurt", "pickup", "craft", "craft_fail", "save", "load"]:
		_eq(events.has(required), true, "event '%s' is declared" % required)

	# Break sounds should vary by material, not all be the same sample.
	_eq(AudioDirector.event_for_block(ContentDB.LEAVES), "break_soft",
		"leaves break softly")
	_eq(AudioDirector.event_for_block(ContentDB.ICE), "break_glass",
		"ice breaks like glass")
	_eq(AudioDirector.event_for_block(ContentDB.STONE), "break_hard",
		"stone breaks hard")


func _test_audio_playback() -> void:
	var audio := AudioDirector.new()
	root.add_child(audio)
	audio.set_listener(null)
	_ok("audio director entered the tree")

	# Headless has a dummy audio device, but the players still exist and the
	# streams still load, which is what can actually be checked here.
	_eq(audio.play("ui_click"), true, "a UI sound plays")
	_eq(audio.play_at("break_hard", Vector3(1, 2, 3)), true,
		"a world sound plays at a position")
	_eq(audio.play("no_such_event"), false, "an unknown event is refused")

	# Distance culling only applies when there is a listener.
	var listener := Node3D.new()
	listener.position = Vector3(1000, 0, 1000)
	root.add_child(listener)
	audio.set_listener(listener)
	_eq(audio.play_at("break_hard", Vector3.ZERO), false,
		"a sound 1400 units away is culled")
	listener.position = Vector3.ZERO
	_eq(audio.play_at("break_hard", Vector3(0.5, 0.5, 0.5)), true,
		"a nearby sound is not culled")

	audio.set_master_volume(0.5)
	_ok("master volume set")
	audio.queue_free()


# --- models -----------------------------------------------------------------

func _test_creature_models() -> void:
	_eq(CreatureModels.MOB_MODELS.size() >= 2, true, "mob models available")
	_eq(CreatureModels.VILLAGER_MODELS.size() >= 3, true, "villager models available")

	for path in CreatureModels.MOB_MODELS + CreatureModels.VILLAGER_MODELS:
		_eq(ResourceLoader.exists(path), true, "model exists: %s" % path.get_file())

	# Deterministic selection: the same seed always picks the same body.
	var a := CreatureModels.pick(CreatureModels.VILLAGER_MODELS, 42)
	var b := CreatureModels.pick(CreatureModels.VILLAGER_MODELS, 42)
	_eq(a, b, "model choice is deterministic for a seed")
	_eq(CreatureModels.pick([], 1), "", "an empty model list is handled")

	var node := CreatureModels.spawn(a, 1.8, Color(0.5, 0.6, 0.9))
	_eq(node != null, true, "a villager model instantiates")
	if node != null:
		_ok("model scale after fit: %s" % str(node.scale))
		_eq(node.scale.y > 0.0, true, "model is scaled to a positive size")
		node.free()

	_eq(CreatureModels.spawn("res://nope.glb", 1.0, Color.WHITE), null,
		"a missing model returns null rather than crashing")


# --- pathfinding ------------------------------------------------------------

## Flat world with a wall, used to prove the path goes around.
func _flat_world() -> VoxelWorld:
	var w := VoxelWorld.new()
	w.view_radius = 1
	w.generator = WorldGenerator.new(1337)
	w.materials = MaterialLibrary.new()
	w.materials.set_mapping(w.texture_mapping)
	root.add_child(w)
	w.update_around(Vector3i.ZERO)
	# Level everything to y=20, then wall off x=0 for z in -4..4.
	for x in range(-8, 9):
		for z in range(-8, 9):
			for y in range(16, 28):
				w.set_block(Vector3i(x, y, z), ContentDB.AIR)
			w.set_block(Vector3i(x, 19, z), ContentDB.STONE)
	for z in range(-4, 5):
		for y in range(20, 23):
			w.set_block(Vector3i(0, y, z), ContentDB.STONE)
	return w


func _test_pathfinding() -> void:
	var w := _flat_world()
	var path := Pathfinder.find_path(w, Vector3i(-5, 20, 0), Vector3i(5, 20, 0), 2)
	_ok("path length: %d" % path.size())
	_eq(path.size() > 0, true, "a route exists around the wall")
	if path.size() > 0:
		# Every step must be adjacent: no teleporting through the wall.
		var prev := Vector3i(-5, 20, 0)
		var max_step := 0
		for node in path:
			var d: int = maxi(absi(node.x - prev.x), maxi(absi(node.y - prev.y), absi(node.z - prev.z)))
			max_step = maxi(max_step, d)
			prev = node
		_eq(max_step, 1, "every path step is to an adjacent cell")
		_eq(path[path.size() - 1], Vector3i(5, 20, 0), "path reaches the goal")
		# It must not tunnel through the wall at x=0, z in -4..4, y>=20.
		var through := 0
		for node in path:
			if node.x == 0 and absi(node.z) <= 4 and node.y >= 20:
				through += 1
		_eq(through, 0, "path does not pass through the wall")

	_eq(Pathfinder.find_path(w, Vector3i(3, 20, 3), Vector3i(3, 20, 3), 2).size(), 0,
		"start == goal gives an empty path")
	_eq(Pathfinder.find_path(null, Vector3i.ZERO, Vector3i.ONE, 2).size(), 0,
		"a null world gives an empty path")

	# A fully buried target has no standable cell anywhere near it, so the
	# ground search cannot rescue it and the search must give up.
	for y in range(20, 32):
		for z in range(-1, 2):
			for x in range(1, 4):
				w.set_block(Vector3i(x, y, z), ContentDB.STONE)
	var sealed := Pathfinder.find_path(w, Vector3i(0, 20, 0), Vector3i(2, 20, 0), 2)
	_eq(sealed.size(), 0, "a sealed target is unreachable")
	w.queue_free()


# --- block drops ------------------------------------------------------------

func _test_block_drops() -> void:
	var w := _flat_world()
	var inv := PlayerInventory.new()
	root.add_child(inv)

	var d := BlockDrop.spawn(root, w, ContentDB.STONE, Vector3(0.5, 22.0, 0.5))
	_eq(d != null, true, "a drop spawns")
	_eq(d.block_id, ContentDB.STONE, "the drop carries its block id")
	_eq(d.is_in_group("drops"), true, "the drop joins the drops group")
	_eq(d.get_child_count() > 0, true, "the drop has a visual")

	# Too far away: not collected.
	_eq(d.try_collect(Vector3(40, 40, 40), inv), false, "out of reach is not collected")
	_eq(inv.count_of(ContentDB.STONE), 0, "nothing was added")

	# In reach: collected, and the inventory gains exactly one.
	_eq(d.try_collect(Vector3(0.5, 22.0, 0.5), inv), true, "a drop in reach is collected")
	_eq(inv.count_of(ContentDB.STONE), 1, "the block went into the inventory")
	_eq(d.age(), 0.0, "age starts at zero")

	_eq(BlockDrop.spawn(root, w, ContentDB.AIR, Vector3.ZERO), null,
		"air never drops")
	_eq(BlockDrop.spawn(null, w, ContentDB.STONE, Vector3.ZERO), null,
		"a null parent is handled")

	var d2 := BlockDrop.spawn(root, w, ContentDB.DIRT, Vector3(0.5, 22.0, 0.5))
	_eq(d2.try_collect(Vector3(0.5, 22.0, 0.5), null), false,
		"a null inventory means no pickup")
	inv.queue_free()
	w.queue_free()


# --- helpers ----------------------------------------------------------------

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


func _finish() -> void:
	print("--- creature_test ---")
	if _fails == 0:
		print("RESULT: PASS")
	else:
		print("RESULT: FAIL (%d)" % _fails)
	quit(1 if _fails > 0 else 0)
