extends SceneTree
## The 3x3 crafting grid panel and villager job production -- the two systems
## that existed as placeholders (a "craft from what you carry" shortcut, and
## trade goods handed out by the roster with nothing producing them).

var _fails := 0


func _init() -> void:
	_test_panel_construction()
	_test_grid_matching()
	_test_take_result()
	_test_drag_payloads()
	_test_villager_production()
	_finish()


# --- crafting panel ---------------------------------------------------------

func _make_panel() -> CraftingPanel:
	var inv := PlayerInventory.new()
	root.add_child(inv)
	inv.give_starting_kit()
	var p := CraftingPanel.new()
	root.add_child(p)
	p.setup(inv)
	return p


func _test_panel_construction() -> void:
	var p := _make_panel()
	_eq(p.grid.size(), 9, "the grid is 3x3")
	_eq(p.visible, false, "the panel starts closed")
	_eq(p.result_block(), ContentDB.AIR, "an empty grid has no result")
	_eq(p.current_recipe().is_empty(), true, "an empty grid matches no recipe")

	_eq(p.toggle(), true, "toggle opens the panel")
	_eq(p.visible, true, "the panel is visible after opening")
	_eq(p.toggle(), false, "toggle closes it again")

	# Out-of-range writes must be ignored, not crash.
	p.set_cell(-1, ContentDB.STONE)
	p.set_cell(99, ContentDB.STONE)
	_eq(p.get_cell(0), ContentDB.AIR, "out-of-range writes are ignored")
	_eq(p.get_cell(99), ContentDB.AIR, "out-of-range reads are ignored")
	p.queue_free()


func _test_grid_matching() -> void:
	var p := _make_panel()

	# Nine stone is the stone_bricks recipe: 3x3 shaped.
	for i in 9:
		p.set_cell(i, ContentDB.STONE)
	_eq(p.current_recipe().get("id", ""), "stone_bricks",
		"a filled 3x3 matches the shaped recipe")
	_eq(p.result_block(), ContentDB.DEEPSLATE, "the result slot shows the output")

	# Change one cell and the recipe must stop matching.
	p.set_cell(4, ContentDB.AIR)
	_eq(p.current_recipe().get("id", ""), "",
		"breaking the shape breaks the match")
	_eq(p.result_block(), ContentDB.AIR, "the result slot clears")

	# A 2x2 in a corner must trim and match freeze_water (sand).
	p.clear_grid()
	p.set_cell(0, ContentDB.SAND)
	p.set_cell(1, ContentDB.SAND)
	p.set_cell(3, ContentDB.SAND)
	p.set_cell(4, ContentDB.SAND)
	_eq(p.current_recipe().get("id", ""), "freeze_water",
		"a 2x2 in the top-left corner matches after trimming")

	# Shapeless: one grass, anywhere.
	p.clear_grid()
	p.set_cell(8, ContentDB.GRASS)
	_eq(p.current_recipe().get("id", ""), "strip_grass",
		"a shapeless recipe matches wherever the input sits")

	# fill_from_inventory is the quick path.
	p.clear_grid()
	p.fill_from_inventory()
	_ok("filled %d cells from the inventory" % p.grid.size())
	_eq(p.grid[0] != ContentDB.AIR, true, "fill_from_inventory placed a block")
	p.queue_free()


func _test_take_result() -> void:
	var p := _make_panel()
	var inv: PlayerInventory = p.inventory

	p.clear_grid()
	for i in 9:
		p.set_cell(i, ContentDB.STONE)
	# The recipe needs nine stone; the starting kit has one. A player who
	# cannot afford the inputs must not be able to cash the grid in.
	var stone_before := inv.count_of(ContentDB.STONE)
	_eq(stone_before < 9, true, "the test starts short of nine stone")
	_eq(p.take_result(), -1, "an unaffordable craft is refused")
	_eq(inv.count_of(ContentDB.STONE), stone_before, "a refused craft takes nothing")
	_eq(inv.count_of(ContentDB.DEEPSLATE), 0, "a refused craft produces nothing")

	# Stock up and the same grid now works.
	for _i in 12:
		inv.give_block(ContentDB.STONE)
	var slate_before := inv.count_of(ContentDB.DEEPSLATE)
	_eq(p.take_result(), ContentDB.DEEPSLATE, "the craft succeeds once affordable")
	_eq(inv.count_of(ContentDB.STONE), stone_before + 12 - 9, "nine stone consumed")
	_eq(inv.count_of(ContentDB.DEEPSLATE), slate_before + 4, "four deepslate produced")
	_eq(p.grid[0], ContentDB.AIR, "the grid is cleared after crafting")

	# A grid with no matching recipe cannot be taken.
	p.set_cell(0, ContentDB.STONE)
	p.set_cell(1, ContentDB.SAND)
	_eq(p.current_recipe().is_empty(), true, "stone and sand make nothing")
	_eq(p.take_result(), -1, "a grid with no result cannot be taken")

	# An empty result is refused rather than producing air.
	p.clear_grid()
	_eq(p.take_result(), -1, "an empty grid cannot be taken")
	_eq(p.current_recipe().is_empty(), true, "still no recipe")
	p.queue_free()


func _test_drag_payloads() -> void:
	var p := _make_panel()

	# A filled grid cell is a drag source; an empty one is not.
	p.set_cell(0, ContentDB.STONE)
	var filled := p._cells[0]
	var payload: Variant = filled.call("_get_drag_data", Vector2.ZERO)
	_eq(payload is Dictionary, true, "a filled cell produces a drag payload")
	if payload is Dictionary:
		_eq(int((payload as Dictionary)["block_id"]), ContentDB.STONE,
			"the payload carries the block id")
	_eq(p._cells[1].call("_get_drag_data", Vector2.ZERO), null,
		"an empty cell is not a drag source")

	# Dropping onto a grid cell sets it.
	p.clear_grid()
	p._cells[3].call("_drop_data", Vector2.ZERO, payload)
	_eq(p.get_cell(3), ContentDB.STONE, "dropping onto a cell fills it")

	# A grid cell accepts a block payload and rejects anything else.
	_eq(p._cells[2].call("_can_drop_data", Vector2.ZERO, payload), true,
		"a grid cell accepts a block payload")
	_eq(p._cells[2].call("_can_drop_data", Vector2.ZERO, {"kind": "junk"}), false,
		"a grid cell rejects a foreign payload")
	_eq(p._cells[2].call("_can_drop_data", Vector2.ZERO, "not a dict"), false,
		"a grid cell rejects a non-dictionary")

	# The result slot is a drop target that collects the craft.
	p.clear_grid()
	for i in 9:
		p.set_cell(i, ContentDB.STONE)
	var result_ok: bool = p._result_slot.call("_can_drop_data", Vector2.ZERO, payload)
	_eq(result_ok, true, "the result slot accepts a drop")
	_eq(p._result_slot.call("_get_drag_data", Vector2.ZERO), null,
		"the result slot is not itself a drag source")

	# Strip slots are read-only palette entries.
	if not p._strip.is_empty():
		var strip: Control = p._strip[0]
		_eq(strip.call("_can_drop_data", Vector2.ZERO, payload), false,
			"a palette slot does not accept drops")
	p.queue_free()


# --- villager job production ------------------------------------------------

func _test_villager_production() -> void:
	var w := VoxelWorld.new()
	w.view_radius = 1
	w.generator = WorldGenerator.new(1337)
	w.materials = MaterialLibrary.new()
	w.materials.set_mapping(w.texture_mapping)
	root.add_child(w)
	w.update_around(Vector3i.ZERO)
	# A flat stone platform at y=20 to work on.
	for x in range(-6, 7):
		for z in range(-6, 7):
			for y in range(18, 26):
				w.set_block(Vector3i(x, y, z), ContentDB.AIR)
			w.set_block(Vector3i(x, 19, z), ContentDB.STONE)

	var v := Villager.new()
	v.world = w
	v.job = "Miner"
	v.trade_block = ContentDB.GRAVEL
	v.trade_price = 1
	v.trade_stock = 0
	v.max_stock = 3
	v.resource_block = ContentDB.STONE
	v.produce_interval = 1.0
	v.work_site = Vector3(0.5, 20.0, 0.5)
	v.position = v.work_site
	v.ensure_ready()
	root.add_child(v)
	# Put the villager on shift; production only runs during the Work phase.
	v.update_schedule(0.5)
	_eq(v.activity, "Work", "midday puts the villager on shift")

	_eq(v.trade_stock, 0, "a villager starts with no stock")
	_eq(v.has_resource(), false, "the resource has not been scanned yet")

	# On the stone floor, the Miner's resource is present.
	_eq(v.refresh_resource(), true, "stone underfoot satisfies the Miner")
	_eq(v.has_resource(), true, "the resource scan reports true")

	# Working at the site with a resource produces stock.
	_eq(v.is_working(), true, "standing on the work site counts as working")
	v._work(1.5)
	_eq(v.trade_stock, 1, "working produced one unit")
	_ok("stock after 3s: %d" % v.trade_stock)

	# Moving away from the site stops production.
	v.position = v.work_site + Vector3(20.0, 0.0, 0.0)
	_eq(v.is_working(), false, "away from the site is not working")
	var held := v.trade_stock
	v._work(5.0)
	_eq(v.trade_stock, held, "an idle villager produces nothing")

	# Going off shift stops production too.
	v.position = v.work_site
	v.update_schedule(0.05)
	_eq(v.is_working(), false, "a sleeping villager is not working")
	v._work(5.0)
	_eq(v.trade_stock, held, "a sleeping villager produces nothing")
	v.update_schedule(0.5)

	# Stock is capped.
	v._work(20.0)
	_eq(v.trade_stock, v.max_stock, "production stops at max_stock")
	_eq(v.produce_one(), false, "a full villager cannot store more")

	# A job whose resource is missing produces nothing, ever.
	v.position = v.work_site
	for x in range(-6, 7):
		for z in range(-6, 7):
			w.set_block(Vector3i(x, 19, z), ContentDB.AIR)
	v.refresh_resource()
	_eq(v.has_resource(), false, "a missing resource is detected")
	v.trade_stock = 0
	v._work(10.0)
	_eq(v.trade_stock, 0, "no resource means no production")

	# A job with no resource requirement always works.
	v.resource_block = -1
	_eq(v.refresh_resource(), true, "a resource-free job always qualifies")

	# Trading now draws on produced stock.
	v.trade_stock = 2
	v.trade_price = 1
	var inv := PlayerInventory.new()
	root.add_child(inv)
	inv.give_block(ContentDB.STONE)
	_eq(v.trade(inv), "gravel x1", "trading sells produced goods")
	_eq(v.trade_stock, 1, "trading draws down the stock")

	inv.queue_free()
	v.queue_free()
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
	print("--- crafting_ui_test ---")
	if _fails == 0:
		print("RESULT: PASS")
	else:
		print("RESULT: FAIL (%d)" % _fails)
	quit(1 if _fails > 0 else 0)
