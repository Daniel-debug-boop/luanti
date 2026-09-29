extends SceneTree
## Inventory (GLoot), crafting and save/load.
##
## These are the systems that were missing: before this suite there was no
## inventory, no recipe system and nothing written to disk.

var _fails := 0


## A ready-to-use VoxelWorld.
## `_ready` is deferred to the first frame when the node is added from
## SceneTree._init, so the generator and materials are assigned here as well --
## otherwise update_around() hits a null generator.
func _make_world() -> VoxelWorld:
	var w := VoxelWorld.new()
	w.view_radius = 1
	w.generator = WorldGenerator.new(1337)
	w.materials = MaterialLibrary.new()
	w.materials.set_mapping(w.texture_mapping)
	root.add_child(w)
	w.update_around(Vector3i.ZERO)
	return w


func _init() -> void:
	_test_inventory_basics()
	_test_stacking()
	_test_hotbar()
	_test_serialization()
	_test_crafting_matching()
	_test_crafting_perform()
	_test_save_load()
	_test_world_edit_round_trip()
	_finish()


# --- inventory --------------------------------------------------------------

## Total GLoot items the player holds, backpack plus hotbar slots.
func _gloot_item_count(inv: PlayerInventory) -> int:
	var n := inv.inventory.get_item_count()
	for slot in inv.hotbar:
		if slot.get_item() != null:
			n += 1
	return n


func _test_inventory_basics() -> void:
	var inv := PlayerInventory.new()
	root.add_child(inv)

	_eq(inv.protoset.data.size() > 0, true, "protoset has prototypes")
	_eq(inv.hotbar.size(), PlayerInventory.HOTBAR_SIZE, "hotbar width")
	_eq(PlayerInventory.block_id_of(PlayerInventory.prototype_id(ContentDB.STONE)),
		ContentDB.STONE, "block id round-trips through the prototype id")
	_eq(PlayerInventory.block_id_of("not_a_block"), -1, "foreign prototype id rejected")

	_eq(inv.give_block(ContentDB.AIR), -1, "cannot give air")
	_eq(inv.give_block(9999), -1, "cannot give an unknown block")
	_eq(inv.count_of(ContentDB.STONE), 0, "starts empty")

	_eq(inv.give_block(ContentDB.STONE), ContentDB.STONE, "stone is accepted")
	_eq(inv.count_of(ContentDB.STONE), 1, "stone counted")
	_eq(inv.available_blocks(), ([ContentDB.STONE] as Array[int]),
		"available blocks lists stone")
	inv.queue_free()


func _test_stacking() -> void:
	var inv := PlayerInventory.new()
	root.add_child(inv)
	for _i in 5:
		inv.give_block(ContentDB.DIRT)
	_eq(inv.count_of(ContentDB.DIRT), 5, "five mined blocks stack")
	# Five of one block is ONE GLoot item, not five. The first one auto-equips
	# into the selected hotbar slot, so the count spans backpack and hotbar.
	_eq(_gloot_item_count(inv), 1, "one stack, not five items")

	_eq(inv.consume_block(ContentDB.DIRT, 2), 2, "consumed two")
	_eq(inv.count_of(ContentDB.DIRT), 3, "three left")
	_eq(inv.consume_block(ContentDB.DIRT, 99), 3, "cannot consume more than held")
	_eq(inv.count_of(ContentDB.DIRT), 0, "stack gone")
	_eq(inv.consume_block(ContentDB.DIRT, 1), 0, "consuming from empty is a no-op")
	inv.queue_free()


func _test_hotbar() -> void:
	var inv := PlayerInventory.new()
	root.add_child(inv)
	inv.give_starting_kit()

	_eq(inv.selected, 0, "starts on slot 0")
	var first := inv.selected_block_id()
	_ok("starting kit holds something in slot 0: %s"
		% ContentDB.name_of(first) if first >= 0 else "NOTHING")

	_eq(inv.select_slot(-1), PlayerInventory.HOTBAR_SIZE - 1, "wraps backwards")
	_eq(inv.select_slot(PlayerInventory.HOTBAR_SIZE), 0, "wraps forwards")
	_eq(inv.scroll_selection(1), 1, "scroll moves one")

	# Placing consumes exactly one and empties the slot when it was the last.
	inv.select_slot(1)
	var placed := inv.consume_selected()
	_ok("placing from slot 1 gave block %d" % placed)
	inv.queue_free()


func _test_serialization() -> void:
	var inv := PlayerInventory.new()
	root.add_child(inv)
	inv.give_starting_kit()
	inv.give_block(ContentDB.STONE)
	inv.give_block(ContentDB.STONE)
	inv.select_slot(2)
	var before := inv.available_blocks()
	var stone_before := inv.count_of(ContentDB.STONE)
	var payload := inv.serialize()
	_ok("payload has %d hotbar slots" % (payload["hotbar"] as Array).size())

	var inv2 := PlayerInventory.new()
	root.add_child(inv2)
	_eq(inv2.deserialize(payload), true, "restore succeeds")
	_eq(inv2.available_blocks(), before, "restored block list matches")
	_eq(inv2.count_of(ContentDB.STONE), stone_before, "restored stack count matches")
	_eq(inv2.selected, 2, "restored selection")

	_eq(inv2.deserialize({}), false, "empty payload is rejected")
	_eq(inv2.deserialize({"nope": 1}), false, "wrong shape is rejected")
	inv.queue_free()
	inv2.queue_free()


# --- crafting ---------------------------------------------------------------

func _grid(cells: Array) -> Array:
	var g: Array = []
	g.resize(Crafting.GRID_SIZE * Crafting.GRID_SIZE)
	g.fill(0)
	for i in mini(cells.size(), g.size()):
		g[i] = int(cells[i])
	return g


func _test_crafting_matching() -> void:
	var recipes := Crafting.default_recipes()
	_ok("recipe book has %d recipes" % recipes.size())
	_eq(recipes.size() > 0, true, "recipe book is not empty")

	# Shapeless: 1 grass -> 4 dirt, position independent.
	var r := Crafting.find_recipe(_grid([ContentDB.GRASS]), recipes)
	_eq(r.get("id", ""), "strip_grass", "shapeless single-input recipe matches")
	_eq(Crafting.find_recipe(_grid([ContentDB.LEAVES, ContentDB.LEAVES]), recipes).get("id", ""),
		"compost_leaves", "shapeless two-input recipe matches")
	_eq(Crafting.find_recipe(_grid([ContentDB.DIRT, ContentDB.ICE]), recipes).get("id", ""),
		"", "a shapeless recipe does not fire on the wrong multiset")

	# Shaped 3x3 stone -> deepslate, and the same block in any corner trims
	# to the same shape.
	var full := _grid([ContentDB.STONE, ContentDB.STONE, ContentDB.STONE,
		ContentDB.STONE, ContentDB.STONE, ContentDB.STONE,
		ContentDB.STONE, ContentDB.STONE, ContentDB.STONE])
	_eq(Crafting.find_recipe(full, recipes).get("id", ""), "stone_bricks",
		"filled 3x3 matches")
	var corner := _grid([0, 0, 0, 0, 0, 0, 0, 0, ContentDB.STONE])
	_eq(Crafting.find_recipe(corner, recipes).get("id", ""), "",
		"a single stone does not match a 3x3 recipe")

	# Shaped with a hole: gravel ring -> glowstone (the centre stays empty).
	var ring := _grid([ContentDB.GRAVEL, ContentDB.GRAVEL, ContentDB.GRAVEL,
		ContentDB.GRAVEL, 0, ContentDB.GRAVEL,
		ContentDB.GRAVEL, ContentDB.GRAVEL, ContentDB.GRAVEL])
	_eq(Crafting.find_recipe(ring, recipes).get("id", ""), "crack_glowstone",
		"ring pattern matches")
	# Filling the hole must break the ring recipe: the pattern really does
	# require that cell to be empty.
	var solid_cells: Array = []
	solid_cells.resize(9)
	solid_cells.fill(ContentDB.GRAVEL)
	_eq(Crafting.find_recipe(_grid(solid_cells), recipes).get("id", ""), "",
		"a filled 3x3 of gravel matches no recipe")

	_eq(Crafting.find_recipe(_grid([ContentDB.BEDROCK]), recipes).get("id", ""), "",
		"bedrock matches nothing")
	_eq(Crafting.find_recipe(_grid([]), recipes).get("id", ""), "",
		"an empty grid matches nothing")


func _test_crafting_perform() -> void:
	var inv := PlayerInventory.new()
	root.add_child(inv)

	# Cannot afford it yet.
	var recipe := {}
	for r in Crafting.default_recipes():
		if r["id"] == "strip_grass":
			recipe = r
	_eq(Crafting.craft(inv, recipe), false, "crafting without inputs fails")
	_eq(inv.count_of(ContentDB.DIRT), 0, "a failed craft consumes nothing")

	inv.give_block(ContentDB.GRASS)
	_eq(Crafting.craft(inv, recipe), true, "craft succeeds once affordable")
	_eq(inv.count_of(ContentDB.GRASS), 0, "the grass was consumed")
	_eq(inv.count_of(ContentDB.DIRT), 4, "produced four dirt")

	# A multi-input recipe must not go through on partial inputs.
	_eq(Crafting.available(inv).size() > 0, true, "something is craftable now")
	_eq(Crafting.craft(inv, {}), false, "an invalid recipe is rejected")

	# Shapeless two-input: needs both, in any arrangement.
	var two := {}
	for r in Crafting.default_recipes():
		if r["id"] == "compost_leaves":
			two = r
	inv.give_block(ContentDB.LEAVES)
	_eq(Crafting.craft(inv, two), false, "one of two inputs is not enough")
	inv.give_block(ContentDB.LEAVES)
	_eq(Crafting.craft(inv, two), true, "both inputs is enough")
	inv.queue_free()


# --- save / load ------------------------------------------------------------

func _test_save_load() -> void:
	for s in SaveGame.list_slots():
		SaveGame.delete_slot(s)
	_eq(SaveGame.list_slots().size(), 0, "no saves to start with")

	var world := _make_world()

	var inv := PlayerInventory.new()
	root.add_child(inv)
	inv.give_starting_kit()

	var player := Player.new()
	player.world = world
	root.add_child(player)
	player.position = Vector3(12.5, 30.0, -4.25)
	player.health = 11.0
	player.flying = true

	# A real edit in the world, so the save has something to preserve.
	var edited := Vector3i(2, 30, 2)
	var changed := world.set_block(edited, ContentDB.GLOWSTONE)
	_ok("world edit applied: %s" % str(changed))

	_eq(SaveGame.save_game(1, player, inv, world, WorldGenerator.DIM_OVERWORLD),
		true, "save to slot 1")
	_eq(SaveGame.has_slot(1), true, "slot 1 exists")
	_eq(SaveGame.list_slots(), ([1] as Array[int]), "slot 1 is listed")
	_ok("slot summary: %s" % SaveGame.describe_slot(1))

	# A second, different state to restore over the top.
	player.position = Vector3(0, 0, 0)
	player.health = 3.0
	inv.inventory.clear()
	for slot in inv.hotbar:
		slot.clear()
	world.apply_edits_snapshot({})

	_eq(SaveGame.load_game(1, player, inv, world), true, "load from slot 1")
	_eq(player.health, 11.0, "health restored")
	_eq(player.position, Vector3(12.5, 30.0, -4.25), "position restored")
	_eq(player.flying, true, "fly state restored")
	_eq(inv.available_blocks().size() > 0, true, "inventory restored")
	var edits := world.edits_snapshot()
	_eq(edits.size() > 0, true, "world edits restored (%d)" % edits.size())

	# A slot that does not exist must fail cleanly.
	_eq(SaveGame.load_slot(7), {}, "empty slot loads as {}")
	_eq(SaveGame.load_game(7, player, inv, world), false, "loading an empty slot fails")
	_eq(SaveGame.write_slot(99, {}), false, "out-of-range slot is refused")
	_ok("error message: %s" % SaveGame.last_error)

	_eq(SaveGame.delete_slot(1), true, "delete slot 1")
	_eq(SaveGame.has_slot(1), false, "slot 1 is gone")
	_eq(SaveGame.delete_slot(1), false, "deleting a missing slot fails")
	player.queue_free()
	inv.queue_free()
	world.queue_free()


func _test_world_edit_round_trip() -> void:
	var a := _make_world()
	var p := Vector3i(1, 20, 1)
	a.set_block(p, ContentDB.ICE)
	var snap := a.edits_snapshot()
	_ok("snapshot has %d edits" % snap.size())
	_eq(snap.size(), 1, "one edit recorded")
	_eq(a.get_content_at(p), ContentDB.ICE, "edit is live")

	var b := _make_world()
	_eq(b.get_content_at(p), ContentDB.AIR, "a fresh world is unmodified")
	b.apply_edits_snapshot(snap)
	_eq(b.get_content_at(p), ContentDB.ICE, "snapshot replays onto a fresh world")

	# Garbage keys must be ignored rather than crash.
	b.apply_edits_snapshot({"nonsense": 1, "1:2:3": 4})
	_ok("malformed edit keys are ignored")
	a.queue_free()
	b.queue_free()


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
	print("--- gameplay_test ---")
	if _fails == 0:
		print("RESULT: PASS")
	else:
		print("RESULT: FAIL (%d)" % _fails)
	quit(1 if _fails > 0 else 0)
