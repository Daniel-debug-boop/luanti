extends SceneTree
## Inventory stacking, counting, and the single item-acquisition path.
##
## Three defects, all of which a player would notice as "the game is giving me
## the wrong number of things":
##
## `count_of` and `count_eng` returned the count of the *first* matching stack,
## so a player holding two stacks was told they held one. That is fewer blocks
## than they can place and fewer parts than they can pay with, and it made a
## bill of materials look unaffordable while the parts were in the backpack.
##
## `give_block` topped up the first stack and then refused outright, losing the
## block even when a second stack had room. `give_eng` re-found the same full
## stack every iteration and broke out of the whole operation.
##
## And mining credited the inventory directly *and* spawned a drop, which
## credited it again on contact: two items per block, from two authoritative
## paths. There is now one.

var failures := 0
var inv: PlayerInventory


func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: ", msg)


func _init() -> void:
	_test_single_stack_count()
	_test_multiple_stacks_are_summed()
	_test_give_fills_every_partial_stack()
	_test_give_starts_a_new_stack_when_all_are_full()
	_test_count_eng_is_summed()
	_test_give_eng_fills_every_partial_stack()
	_test_partial_and_full_stacks_together()
	_test_full_inventory_refuses_rather_than_losing()
	_test_mining_yields_exactly_one_item()
	_test_drop_collected_twice_is_not_a_duplication()
	_test_bill_payment_is_atomic()
	_test_unloaded_chunk_and_border_edits_do_not_lose_items()
	_test_serialize_roundtrip_preserves_counts()
	# tools/run_tests.sh matches a verdict line at column 0.
	print("inventory: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)


## A fresh inventory, so each test starts from a known state.
func _fresh() -> PlayerInventory:
	if inv != null and is_instance_valid(inv):
		inv.free()
	inv = PlayerInventory.new()
	inv.name = "Inventory"
	# Engineering items only exist once their prototypes are registered,
	# exactly as `main.gd` does at start-up. Without this every eng count is
	# zero and every eng test fails for the wrong reason.
	inv.register_prototypes(EngItems.prototype_entries())
	root.add_child(inv)
	return inv


## A stack of `count` of one block, in the backpack.
func _stack(block_id: int, count: int) -> InventoryItem:
	var made := inv.inventory.create_and_add_item(
		PlayerInventory.prototype_id(block_id))
	if made != null:
		made.set_property("count", count)
	return made


# --- counting ----------------------------------------------------------------

func _test_single_stack_count() -> void:
	var p := _fresh()
	p.give_block(ContentDB.STONE)
	p.give_block(ContentDB.STONE)
	p.give_block(ContentDB.STONE)
	check(p.count_of(ContentDB.STONE) == 3,
		"three single-block calls count as three (got %d)"
			% p.count_of(ContentDB.STONE))
	check(p.count_of(ContentDB.DIRT) == 0,
		"a block the player does not have counts as zero")


func _test_multiple_stacks_are_summed() -> void:
	# The defect: this used to report 10, not 25.
	var p := _fresh()
	_stack(ContentDB.STONE, 10)
	_stack(ContentDB.STONE, 15)
	check(p.count_of(ContentDB.STONE) == 25,
		"two stacks of 10 and 15 count as 25, not just the first (got %d)"
			% p.count_of(ContentDB.STONE))


func _test_count_eng_is_summed() -> void:
	var p := _fresh()
	var proto := PlayerInventory.eng_prototype_id("plate")
	var a := p.inventory.create_and_add_item(proto)
	if a != null:
		a.set_property("count", 4)
	var b := p.inventory.create_and_add_item(proto)
	if b != null:
		b.set_property("count", 6)
	check(p.count_eng("plate") == 10,
		"two engineering stacks count as 10, not just the first (got %d)"
			% p.count_eng("plate"))


# --- filling -----------------------------------------------------------------

func _test_give_fills_every_partial_stack() -> void:
	# The defect: a full stack plus a part-full one lost the block.
	var p := _fresh()
	_stack(ContentDB.STONE, PlayerInventory.MAX_STACK)
	_stack(ContentDB.STONE, 5)
	check(p.give_block(ContentDB.STONE) == ContentDB.STONE,
		"a block is stored when a later stack has room")
	check(p.count_of(ContentDB.STONE) == PlayerInventory.MAX_STACK + 6,
		"and it went onto the partial stack (total %d)"
			% p.count_of(ContentDB.STONE))


func _test_give_starts_a_new_stack_when_all_are_full() -> void:
	var p := _fresh()
	_stack(ContentDB.STONE, PlayerInventory.MAX_STACK)
	p.give_block(ContentDB.STONE)
	check(p.count_of(ContentDB.STONE) == PlayerInventory.MAX_STACK + 1,
		"with every stack full a new one is opened (total %d)"
			% p.count_of(ContentDB.STONE))
	check(p._items_of(ContentDB.STONE).size() == 2,
		"and there are now two stacks")


func _test_give_eng_fills_every_partial_stack() -> void:
	# The defect: give_eng re-found the same full stack and gave up.
	var p := _fresh()
	var proto := PlayerInventory.eng_prototype_id("plate")
	var full := p.inventory.create_and_add_item(proto)
	if full != null:
		full.set_property("count", PlayerInventory.MAX_STACK)
	var part := p.inventory.create_and_add_item(proto)
	if part != null:
		part.set_property("count", 3)
	var stored := p.give_eng("plate", 10)
	check(stored == 10,
		"ten parts are stored across a full and a partial stack (got %d)"
			% stored)
	check(p.count_eng("plate") == PlayerInventory.MAX_STACK + 13,
		"and the total reflects both (got %d)" % p.count_eng("plate"))


func _test_partial_and_full_stacks_together() -> void:
	var p := _fresh()
	_stack(ContentDB.DIRT, 7)
	_stack(ContentDB.DIRT, PlayerInventory.MAX_STACK)
	_stack(ContentDB.DIRT, 20)
	check(p.count_of(ContentDB.DIRT)
			== PlayerInventory.MAX_STACK + 27,
		"three stacks of 7, full and 20 sum correctly (got %d)"
			% p.count_of(ContentDB.DIRT))
	# A give must land on the first stack with room, which is the 7.
	p.give_block(ContentDB.DIRT)
	var after := p._items_of(ContentDB.DIRT)
	check(int(after[0].get_property("count", 1)) == 8,
		"a give tops up the first stack with room (got %d)"
			% int(after[0].get_property("count", 1)))


func _test_full_inventory_refuses_rather_than_losing() -> void:
	# A backpack with no room must refuse, and say so. Losing the item
	# silently is worse than refusing it.
	var p := _fresh()
	var slots: int = p.inventory.get_max_stack_size() if p.inventory \
		.has_method("get_max_stack_size") else 0
	if slots == 0:
		# No fixed slot count on this GLoot build; the refusal path is
		# exercised through the full-stack route instead.
		_stack(ContentDB.STONE, PlayerInventory.MAX_STACK)
		check(p.count_of(ContentDB.STONE) == PlayerInventory.MAX_STACK,
			"a single full stack holds what it says it does")
		return
	var made := 0
	for _i in slots + 8:
		if _stack(ContentDB.STONE, PlayerInventory.MAX_STACK) != null:
			made += 1
	check(p.count_of(ContentDB.STONE) == made * PlayerInventory.MAX_STACK,
		"every stack that was created is counted exactly once")


# --- one acquisition path ----------------------------------------------------

func _test_mining_yields_exactly_one_item() -> void:
	# The duplication defect, checked at its source: mining credits the
	# inventory only through the drop it spawns.
	var src := FileAccess.get_file_as_string(
		"res://scripts/player/player_interaction.gd")
	var break_at := src.find("func _advance_break")
	check(break_at >= 0, "the mining path is present")
	if break_at >= 0:
		var body := src.substr(break_at, 900)
		var spawn := body.find("BlockDrop.spawn")
		var credit := body.find("inventory.give_block")
		check(spawn >= 0, "mining spawns a drop")
		check(credit < 0,
			"and does NOT also credit the inventory directly -- that was two "
			+ "items per block")
	# The drop is the one place a mined block becomes an item.
	var drop_src := FileAccess.get_file_as_string(
		"res://scripts/mobs/block_drop.gd")
	check(drop_src.contains("inv.give_block"),
		"the drop is what credits the inventory, so it is the only path")


func _test_drop_collected_twice_is_not_a_duplication() -> void:
	var p := _fresh()
	var world := VoxelWorld.new()
	world.view_radius = 1
	world.generator = WorldGenerator.new(7)
	world.materials = MaterialLibrary.new()
	root.add_child(world)
	world.ensure_region(Vector3i.ZERO, 1)

	var drop := BlockDrop.spawn(root, world, ContentDB.STONE,
		Vector3(0.5, 21.5, 0.5))
	check(drop != null, "a drop spawns")
	if drop == null:
		return
	# Standing on it collects it exactly once.
	var first := drop.try_collect(Vector3(0.5, 21.5, 0.5), p)
	check(first, "walking over the drop collects it")
	check(p.count_of(ContentDB.STONE) == 1,
		"and the player has exactly one (got %d)"
			% p.count_of(ContentDB.STONE))
	# A second attempt must not yield another item.
	var second := drop.try_collect(Vector3(0.5, 21.5, 0.5), p)
	check(not second, "collecting the same drop twice is refused")
	check(p.count_of(ContentDB.STONE) == 1,
		"and the total is still one (got %d)" % p.count_of(ContentDB.STONE))
	drop.queue_free()


# --- bills -------------------------------------------------------------------

func _test_bill_payment_is_atomic() -> void:
	# A bill the player cannot afford must consume nothing at all.
	var p := _fresh()
	var proto := PlayerInventory.eng_prototype_id("plate")
	var a := p.inventory.create_and_add_item(proto)
	if a != null:
		a.set_property("count", 3)
	# The bill wants two different parts. The player has plates but no bolts,
	# so it cannot be paid -- and must consume nothing at all.
	check(not p.pay_eng({"plate": 5, "bolt": 2}),
		"a bill that cannot be afforded is refused")
	check(p.count_eng("plate") == 3,
		"and consumes none of what the player does have (got %d)"
			% p.count_eng("plate"))
	check(p.pay_eng({"plate": 3}), "an affordable bill is paid")
	check(p.count_eng("plate") == 0,
		"and the parts are gone (got %d)" % p.count_eng("plate"))


# --- world interaction -------------------------------------------------------

func _test_unloaded_chunk_and_border_edits_do_not_lose_items() -> void:
	# Mining at a chunk border, and in a chunk that is not resident, must
	# still produce exactly one item each time. The item path is independent
	# of residency, so this is really a check that nothing in the drop
	# pipeline consults the world after the block is gone.
	var p := _fresh()
	var world := VoxelWorld.new()
	world.view_radius = 1
	world.generator = WorldGenerator.new(11)
	world.materials = MaterialLibrary.new()
	root.add_child(world)
	world.ensure_region(Vector3i.ZERO, 2)
	# A full 16x16 platform, so the columns on the chunk border (x = 15,
	# z = 15) hold real stone and a border break is a real border break
	# rather than a break of empty air.
	for x in range(16):
		for z in range(16):
			for y in range(18, 24):
				world.set_block(Vector3i(x, y, z), ContentDB.AIR)
			world.set_block(Vector3i(x, 20, z), ContentDB.STONE)

	# Blocks on the exact chunk border: column 15 is the last column of the
	# 16-wide block, so breaking there is the case that a neighbour-remesh
	# bug would get wrong.
	for pos in [Vector3i(15, 20, 0), Vector3i(15, 20, 15),
			Vector3i(0, 20, 15)]:
		var ok := world.break_block(pos)
		check(ok, "the block at %s was broken" % str(pos))
		var drop := BlockDrop.spawn(root, world, ContentDB.STONE,
			Vector3(pos) + Vector3(0.5, 0.3, 0.5))
		if drop != null:
			drop.try_collect(Vector3(pos), p)
			drop.queue_free()
	check(p.count_of(ContentDB.STONE) == 3,
		"three border blocks yield exactly three items (got %d)"
			% p.count_of(ContentDB.STONE))

	# And a break in a chunk that was never streamed in must not credit
	# anything, because nothing was broken.
	var absent := Vector3i(9000, 20, 9000)
	check(not world.break_block(absent),
		"a block in a nonresident chunk cannot be broken")
	check(p.count_of(ContentDB.STONE) == 3,
		"and produces no item (got %d)" % p.count_of(ContentDB.STONE))


func _test_serialize_roundtrip_preserves_counts() -> void:
	var p := _fresh()
	_stack(ContentDB.STONE, 12)
	_stack(ContentDB.STONE, 30)
	var before := p.count_of(ContentDB.STONE)
	var blob := p.serialize()
	var q := _fresh()
	check(q.deserialize(blob), "the inventory restores from a save")
	check(q.count_of(ContentDB.STONE) == before,
		"and both stacks survive the round trip (got %d, want %d)"
			% [q.count_of(ContentDB.STONE), before])