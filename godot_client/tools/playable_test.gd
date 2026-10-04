extends SceneTree
## "Can this actually be played?"
##
## Every other suite proves a system works. This one proves a *player* can
## play, by driving the real `scenes/main.tscn` -- not a fixture, not a stub --
## through the loop the game advertises, using the same entry points the mouse
## and the keyboard reach:
##
##   look at the ground -> mine it -> the block enters the backpack ->
##   place a block -> place an engineering component -> F5 save -> F9 load
##   -> the world, the backpack and the assembly all come back
##
## It also checks the key table in ARCHITECTURE.md section 16 against
## main.gd, because a documented key that is not wired is indistinguishable
## from a key that does not work.
##
## Everything here runs headless. Nothing is rendered, so this suite proves the
## simulation a player drives, not the picture they see.

const CHUNK_DIR := "/tmp/testchunks"
## Only slot 3 is touched, so a failed run cannot clobber a slot-1 save.
const SAVE_SLOT := 3
## Every row of the ARCHITECTURE.md section 16 key table. One entry per
## documented key, because a range like "F1-F3" cannot be checked for a
## literal "F2" and a table nobody can check is a table nobody does.
##
## The third field is which file is expected to handle it. That matters: a key
## table that says "V toggles flight" is a claim about the *game*, and flight
## is the player controller's business while F5 is the composition root's. If
## a key moves between files the test is what notices.
const DOC_KEYS := [
	["F1", "render quality low", "main"], ["F2", "render quality medium", "main"],
	["F3", "render quality high", "main"], ["F4", "cycle texture mapping", "main"],
	["F5", "save", "main"], ["F9", "load", "main"],
	["F10", "developer tools", "main"], ["F11", "system health report", "main"],
	["F12", "performance overlay", "main"],
	["C", "crafting grid", "main"], ["E", "talk", "main"],
	["F", "use held tool", "main"],
	["R", "cycle interaction level", "main"], ["B", "engineering workshop", "main"],
	["G", "switch dimension", "main"], ["1", "hotbar", "main"], ["8", "hotbar", "main"],
	["Q", "stow the selected slot", "main"],
	["V", "toggle flight", "player"], ["Enter", "capture the mouse", "player"],
]

var failures := 0
## How far the player can reach, read from the interaction node so the test
## never drifts from the game's own value.
var interaction_reach := 6.0
## The interaction node, so helpers can reach it without threading it through
## every signature.
var _interaction: PlayerInteraction = null


func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: ", msg)
	else:
		print("  ok: ", msg)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	print("-- the documented keys are the wired keys --")
	_documented_keys_are_bound()

	print("-- the scene a player actually loads --")
	if not ChunkFiles.has_chunk(CHUNK_DIR, 0, 0, 0):
		printerr("no converted world at ", CHUNK_DIR)
		_finish()
		return
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	main.set("world_dir", CHUNK_DIR)
	main.set("view_radius", 3)
	main.set("day_night_enabled", false)
	main.set("save_slot", SAVE_SLOT)
	root.add_child(main)
	# Let it stream and settle, the way a real session does.
	for i in 120:
		_step()

	var world: VoxelWorld = main.get("world")
	var player: Player = main.get("player")
	var interaction: PlayerInteraction = main.get("interaction")
	var inventory: PlayerInventory = main.get("inventory")
	var engineering: EngEngineering = main.get("engineering")
	var persistence: Persistence = main.get("persistence")
	_interaction = interaction
	interaction_reach = interaction.reach
	check(world != null, "the world exists")
	check(player != null, "the player exists")
	check(interaction != null and inventory != null and engineering != null,
		"interaction, backpack and engineering are all present")
	check(persistence != null, "persistence is registered as a system")
	if world == null or player == null or interaction == null \
			or inventory == null or engineering == null or persistence == null:
		_finish()
		return

	_registry_drives_the_real_systems(main, persistence)

	_mine(world, player, interaction, inventory)
	_place(world, player, interaction, inventory)
	_engineering(player, engineering, inventory)
	_save_and_reload(main, world, player, engineering, inventory, persistence)

	_finish()


## The registry must drive the REAL system objects, not stand-ins for them.
##
## This is the check that would have caught the emergent layer being dead in
## the shipped game. `main.gd` builds its lifecycle handle from
## `_system(...)`, which used to wrap every owner in a brand-new `System` --
## including the two owners that are already `System`s. The wrapper carried
## the state, the registry happily reported it RUNNING, and the real
## `EmergentSystem` behind it was never `initialize()`d: `graph` and `causal`
## stayed null for the whole session. Every unit test that constructed the
## layer itself passed, the health report said everything was fine, and in
## play the first swing raised `entities_near in base 'Nil'` and the first
## save raised `serialize in base 'Nil'`.
##
## So the assertions are about identity and liveness, not about state: the
## object in the registry is the object main holds, it was actually
## initialized, it actually ticked during the 120 frames above, and it can
## produce a save payload without a null dereference.
func _registry_drives_the_real_systems(main: Node3D, persistence: Persistence) -> void:
	print("-- the registry drives the real systems --")
	var em: EmergentSystem = main.get("emergent")
	check(em != null, "the composition root built an emergent layer")
	if em == null:
		return
	check(SystemRegistry.get_system("emergent") == em,
		"the registered emergent system IS main's layer, not a stand-in")
	check(SystemRegistry.get_owner("emergent") == em,
		"and the registry resolves its owner back to that same object")
	check(em.state == System.State.RUNNING,
		"the real layer reached RUNNING (state %s)" % em._state_name())
	check(em.graph != null and em.causal != null,
		"initialize() really ran: graph and causal are both live")
	check(em.tick_count > 0,
		"and it ticked during the session (tick_count %d)" % em.tick_count)

	# The identity check is structural; this is the behaviour it protects. A
	# layer that is registered but never initialized serializes to a null
	# dereference, which is exactly what the first F5 used to do.
	var payload := em.serialize()
	check(payload.has("graph") and payload.has("rules"),
		"the live layer can be captured for a save")

	check(persistence != null, "the persistence layer exists")
	if persistence == null:
		return
	check(SystemRegistry.get_system("persistence") == persistence,
		"and the registered persistence system is the real one too")
	check(persistence.state == System.State.RUNNING,
		"so it reached RUNNING (state %s)" % persistence._state_name())

	# A layer that owns itself must not hold a RefCounted reference to itself:
	# that cycle never reaches zero and the process reports resources still in
	# use at exit. `owns_self` is the flag `get_owner` answers from instead.
	check(em.owns_self == true, "the emergent layer declares itself self-owned")
	check(em.owner_object == null,
		"and holds no self-reference, which would leak at exit")


## Step every node's own _process by hand, so the test is deterministic and
## does not depend on wall-clock timing.
##
## The whole tree, not just the scene's direct children. `main.tscn` is the
## only child of root, and the node that resolves the crosshair
## (`PlayerInteraction`) is its grandchild. Ticking only the root's children
## runs the composition root's frame and none of the systems it drives, which
## looks like a world bug and is not one.
func _step() -> void:
	_step_tree(root)


func _step_tree(node: Node) -> void:
	if node.has_method("_process"):
		node.call("_process", 1.0 / 60.0)
	# `_physics_process` too. It used to be skipped, which was invisible while
	# mining credited the inventory directly: the drops that fell out of reach
	# did not matter. Now that the drop is the only acquisition path, a player
	# who does not fall and land under gravity never reaches their own drops,
	# and the test walks the player in mid-air.
	if node.has_method("_physics_process"):
		node.call("_physics_process", 1.0 / 60.0)
	for child in node.get_children():
		_step_tree(child)


## Look at a specific block, the way a player aims the crosshair at it.
##
## Not by synthesising mouse motion: `Player._unhandled_input` ignores it
## unless the mouse is captured, and a headless run cannot capture. Nor by
## setting `player.rotation`, which the next physics frame overwrites from the
## private `_yaw`/`_pitch`. `look_along()` is the one supported way to aim,
## and it lands on the same orientation the mouse would have produced.
func _look_at(player: Player, target: Vector3) -> void:
	var from := player.get_eye_position()
	player.look_along(Vector3(target) + Vector3(0.5, 0.5, 0.5) - from)
	_step()
	_step()


## Look down at the ground.
func _look_down(player: Player) -> void:
	_look_at(player, Vector3(player.position) + Vector3(0, -1.5, 0))


## Hold the mouse until the crosshair's block is gone, and return what it was.
##
## The loop cannot wait on `break_progress`: breaking a block resets the
## progress bar, so a `while break_progress < 1.0` loop keeps running after
## the block it was waiting for is already in the backpack. Wait for the
## counter to move instead.
func _mine_what_is_under_the_crosshair(world: VoxelWorld, player: Player,
		interaction: PlayerInteraction) -> Dictionary:
	if not interaction.has_target:
		return {"hit": false, "block": Vector3i.ZERO, "id": ContentDB.AIR}
	var at: Vector3i = interaction.target
	var id: int = world.get_content_at(at)
	var mined_before := interaction.mined
	interaction.start_break()
	var guard := 0
	while interaction.mined == mined_before and guard < 600:
		_step()
		guard += 1
	interaction.stop_breaking()
	print("  broke %s (content %d) in %d frames" % [at, id, guard])
	return {"hit": true, "block": at, "id": id}


## Clear whatever stands between the player and `at`, then break it.
##
## Aiming at the middle of a log from outside a tree puts leaves in the way,
## and the crosshair hits the leaves -- correctly, they are nearer. A player
## clears the foliage; so does this, and the leaves it mines are real leaves
## that really land in the backpack.
func _mine_through(world: VoxelWorld, player: Player,
		interaction: PlayerInteraction, at: Vector3i, want: int) -> bool:
	for attempt in 24:
		_look_at(player, Vector3(at))
		var r := _mine_what_is_under_the_crosshair(world, player, interaction)
		if not bool(r["hit"]):
			return false
		if int(r["id"]) == want:
			return true
		# Something else was in the way. Give the drop a moment to be picked
		# up, so the tree does not vanish faster than the player can see it.
		for i in 120:
			_step()
	return false


## The nearest drop of `id` in the world, whatever its distance. Null if there
## is none.
func _nearest_drop(player: Player, id: int) -> BlockDrop:
	var best: BlockDrop = null
	var best_d := INF
	for n in get_nodes_in_group("drops"):
		var d := n as BlockDrop
		if d == null or not is_instance_valid(d) or d.block_id != id:
			continue
		var dist: float = d.world_position().distance_to(player.global_position)
		if dist < best_d:
			best_d = dist
			best = d
	return best


## Walk the player over to their drops until the count of `id` rises above
## `before`, or `max_frames` frames have passed. Returns whether it did.
##
## The drop is the only path a mined block has into the backpack, so this has
## to stand in for the player walking over to it. It genuinely has to: a
## player can chop a block most of a reach away, the item lands where the
## block was, and `BlockDrop.PICKUP_RADIUS` is a body and a half -- so the
## drop routinely settles outside it of whoever mined it. Waiting in place
## for the count to change is not a stricter version of this test, it is a
## different one that can never pass.
##
## Position is set the same way `_walk_to` sets it, and for the same reason:
## a headless run reads no key state, so the walk cannot be synthesised
## without measuring the synthesiser instead of the game.
func _gather_drops(player: Player, inventory: PlayerInventory, id: int,
		before: int, max_frames: int) -> bool:
	for _i in max_frames:
		_step()
		if inventory.count_of(id) > before:
			return true
		var d := _nearest_drop(player, id)
		if d == null:
			continue
		# Hover above it rather than at its height. The item settles on top of
		# whatever is below it, which may be a block face the player cannot
		# occupy, and where the player stands vertically is not what this is
		# testing.
		var p := d.world_position()
		player.position = Vector3(p.x, maxf(player.position.y, p.y), p.z)
	return false


## The nearest block of `id` within `max_dist` of the player, scanning a box
## around them.
func _nearest_block(world: VoxelWorld, player: Player, id: int,
		max_dist := 6.0) -> Vector3i:
	var best := Vector3i.ZERO
	var best_d := max_dist
	var p0 := player.get_block_position()
	for x in range(p0.x - 8, p0.x + 9):
		for y in range(p0.y - 8, p0.y + 9):
			for z in range(p0.z - 8, p0.z + 9):
				var p := Vector3i(x, y, z)
				if world.get_content_at(p) != id:
					continue
				# Distance to the block face the player would hit, not to
				# its centre: reach is measured from the eye along the ray.
				var d: float = (Vector3(p) + Vector3(0.5, 0.5, 0.5)) \
					.distance_to(player.get_eye_position())
				if d < best_d:
					best_d = d
					best = p
	return best


## Stand next to `target`, the way a player walks over to a tree before
## chopping it.
##
## This moves the player rather than waiting for them to walk, because a
## headless run has no input-driven movement: `Input.get_vector` reads real
## key state, and synthesising it would make the test measure the synthesiser.
## What is being tested starts after the walk, so positioning the player is
## the honest way to reach that state.
func _walk_to(player: Player, target: Vector3i) -> void:
	var face: Vector3 = (player.get_block_position() - target)
	face.y = 0.0
	if face.length_squared() < 0.001:
		face = Vector3.FORWARD
	face = face.normalized()
	player.position = Vector3(target) + Vector3(0.5, 0.0, 0.5) + face * 2.2
	_step()
	_step()


func _mine(world: VoxelWorld, player: Player, interaction: PlayerInteraction,
		inventory: PlayerInventory) -> void:
	print("-- mine --")
	# Mine wood, because that is what the progression actually needs: a
	# workbench costs 8 wood and the starting kit holds 1. Chopping a tree is
	# the first thing the game asks a player to do, so it is the right thing
	# to prove. Search wider than arm's length, then walk to what is found --
	# the spawn point is not guaranteed to be beside a tree.
	var tree := _nearest_block(world, player, ContentDB.WOOD, 24.0)
	check(tree != Vector3i.ZERO,
		"there is a tree near spawn (nearest wood %s)" % str(tree))
	if tree == Vector3i.ZERO:
		return
	_walk_to(player, tree)
	check(player.get_block_position().distance_to(tree) < 8,
		"the player can walk to the tree")
	# The baseline is whatever the starting kit holds, so the assertion is
	# "the count went up by the time the player has walked over the drop",
	# not "the count is at least one".
	var wood_before := inventory.count_of(ContentDB.WOOD)
	var got := _mine_through(world, player, interaction, tree, ContentDB.WOOD)
	check(got, "the player can break the wood at %s" % str(tree))
	check(interaction.mined > 0, "holding the mouse mines blocks")

	# The drop is the only way a mined block reaches the backpack, so both
	# halves have to hold: the block became an item lying in the world, and
	# that item is what the player picks up.
	check(_nearest_drop(player, ContentDB.WOOD) != null,
		"the broken block is lying in the world as an item")
	var collected := _gather_drops(player, inventory, ContentDB.WOOD,
		wood_before, 900)
	check(collected, "the chopped wood reaches the backpack")

	# Chop the rest of what the workbench needs, so the next stage is reached
	# by playing rather than by handing the player materials.
	var chopped := 0
	# Every iteration counts, including the ones that only move the player.
	# The bound used to be `chopped`, which the "walk to the next trunk" branch
	# reached with `continue` and so never incremented: a player who could
	# see wood but never reach it looped forever.
	while EngItems.count_bill_item(inventory, "wood") < 8 and chopped < 32:
		chopped += 1
		var more := _nearest_block(world, player, ContentDB.WOOD, 6.0)
		if more == Vector3i.ZERO:
			# Out of arm's reach: walk to the next trunk and carry on.
			var far := _nearest_block(world, player, ContentDB.WOOD, 24.0)
			if far == Vector3i.ZERO or far == tree:
				break
			tree = far
			_walk_to(player, far)
			continue
		var had := EngItems.count_bill_item(inventory, "wood")
		_mine_through(world, player, interaction, more, ContentDB.WOOD)
		_gather_drops(player, inventory, ContentDB.WOOD, had, 400)
	print("  wood now: ", EngItems.count_bill_item(inventory, "wood"),
		" after ", chopped, " attempts")


## Drop the player onto the surface below them, which is what
## `main._place_on_surface()` does on arrival. Inlined here because the test
## should not reach into a private method of the scene to do it.
func _settle_on_surface(player: Player, world: VoxelWorld) -> void:
	var x := int(floor(player.position.x))
	var z := int(floor(player.position.z))
	var y := int(floor(player.position.y))
	while y > 2 and not world.solid_at(Vector3i(x, y, z)):
		y -= 1
	player.position = Vector3(player.position.x, float(y) + 1.6, player.position.z)
	_step()
	_step()


## The nearest solid block with an open top that is not the cell the player
## is standing in, or Vector3i.ZERO. That is precisely the set of blocks a
## player can build on right here.
func _legal_placement(world: VoxelWorld, player: Player) -> Vector3i:
	var p0 := player.get_block_position()
	var eye := player.get_eye_position()
	for r in range(1, 5):
		for dx in range(-r, r + 1):
			for dz in range(-r, r + 1):
				for level in [-1, -2]:
					var p: Vector3i = p0 + Vector3i(dx, level, dz)
					if not world.solid_at(p):
						continue
					var above: Vector3i = p + Vector3i(0, 1, 0)
					if world.get_content_at(above) != ContentDB.AIR:
						continue
					if above == p0:
						continue
					# Keep clear of the player's body box, not just the cell
					# they occupy: the box spans more than one column.
					if absi(above.x - p0.x) + absi(above.z - p0.z) < 2:
						continue
					# And within arm's reach, or aiming at it hits nothing.
					var d: float = (Vector3(p) + Vector3(0.5, 0.5, 0.5)) \
						.distance_to(eye)
					if d > interaction_reach:
						continue
					return p
	# Nothing within a body-length. Open ground is a few steps away, and a
	# player would simply walk to it.
	player.position += Vector3(1.5, 0.0, 1.5)
	return Vector3i.ZERO
	return Vector3i.ZERO


func _place(world: VoxelWorld, player: Player, interaction: PlayerInteraction,
		inventory: PlayerInventory) -> void:
	print("-- place --")
	# Chopping left the player standing in a hole they made in a tree, which
	# is a fine place to be and a poor place to test placing. Walk back to the
	# spawn column, which is open ground, and stand on it.
	player.position = Vector3(8.5, 40.0, 8.5)
	_settle_on_surface(player, world)
	var ids := inventory.available_blocks()
	check(ids.size() > 0, "the player starts with something to place")
	if ids.is_empty():
		return
	# Walk the hotbar the way 1-8 does, and stop on the first real block.
	for i in inventory.hotbar.size():
		interaction.select_slot(i)
		if ids.has(inventory.selected_block_id()):
			break
	interaction.refresh_hotbar()
	var block_id: int = interaction.selected_block()
	check(block_id >= 0, "a carried block is selected (id %d)" % block_id)

	# Find somewhere a block can actually go: a solid block whose top face is
	# open and is not the cell the player is standing in. `place()` refuses a
	# cell that intersects the player, and it is right to -- so the test has
	# to find a legal spot rather than assert on an illegal one.
	var spot := _legal_placement(world, player)
	check(spot != Vector3i.ZERO, "there is somewhere legal to place a block")
	if spot == Vector3i.ZERO:
		return
	_look_at(player, Vector3(spot))
	if not interaction.has_target:
		check(false, "the crosshair finds the spot")
		return
	var placed := interaction.place()
	print("  place() -> ", placed, " against ", interaction.target)
	check(placed and interaction.placed > 0, "right click places a block")

	# And the refusal the player would hit: a block cannot go inside them.
	var before_refusals := interaction.placed
	_look_down(player)
	interaction.place()
	check(interaction.placed == before_refusals,
		"a block cannot be placed inside the player's own body")


func _engineering(player: Player, engineering: EngEngineering,
		inventory: PlayerInventory) -> void:
	print("-- engineering --")
	# The real progression, in order: a workbench is the one station you can
	# make out of what you have already mined, and it is the only component
	# whose bill is a single material. Skipping straight to "place a motor"
	# would test a door the player cannot yet open.
	var wood := EngItems.count_bill_item(inventory, "wood")
	print("  wood carried: ", wood)
	check(wood >= 8, "the player has the wood to start (has %d, needs 8)" % wood)
	if wood < 8:
		return

	var nodes_before := engineering.graph.node_count()
	var bench_at: Vector3 = player.position + Vector3(0, -1.0, -1.5)
	var bench := engineering.manufacture("workbench", bench_at)
	check(bool(bench["ok"]), "the workbench is manufactured: %s"
		% String(bench["reason"]))
	check(engineering.graph.node_count() > nodes_before,
		"the workbench is really in the graph")
	print("  workbench -> %d nodes" % [engineering.graph.node_count()])

	# Now that a station exists, F has something to do. `manufacture` puts the
	# finished part in the backpack, but the player still has to hold it, and
	# "held" means a hotbar slot. The starting kit filled all eight, so this is
	# the step that needs Q: put a block away, and the part comes up.
	var held := _hold_anything(inventory, _interaction)
	check(held != "", "the player can hold the part they made")
	if held == "":
		return
	var pos: Vector3 = player.position + Vector3(0, -1.0, -2.5)
	var r := engineering.place(held, pos)
	check(bool(r["ok"]), "F places an engineering component: %s"
		% String(r.get("reason", "ok")))
	print("  placed %s -> %d nodes"
		% [held, engineering.graph.node_count()])


## Select whichever hotbar slot holds an engineering item, freeing one first
## if every slot is full. Returns the item now held, or "" if there is none.
func _hold_anything(inventory: PlayerInventory,
		interaction: PlayerInteraction) -> String:
	for i in inventory.hotbar.size():
		if inventory.selected_eng_item() != "":
			return inventory.selected_eng_item()
		inventory.select_slot(i)
		interaction.select_slot(i)
	# Every slot is full of something. Put the selected one away (Q) and look
	# again -- this is the only way a player can get a part into their hand.
	for _attempt in inventory.hotbar.size():
		if not interaction.stow_selected():
			break
		inventory.fill_hotbar_from_inventory()
		interaction.refresh_hotbar()
		for i in inventory.hotbar.size():
			inventory.select_slot(i)
			interaction.select_slot(i)
			if inventory.selected_eng_item() != "":
				return inventory.selected_eng_item()
	return ""


## Mirror the inventory's selection onto the interaction node, which is what
## pressing 1-8 does in the real game.
func interaction_select(inventory: PlayerInventory) -> void:
	if _interaction != null:
		_interaction.select_slot(inventory.selected)
		_interaction.refresh_hotbar()


func _save_and_reload(main: Node3D, world: VoxelWorld, player: Player,
		engineering: EngEngineering, inventory: PlayerInventory,
		persistence: Persistence) -> void:
	print("-- save and reload --")
	var nodes_before := engineering.graph.node_count()
	# Pick a real carried thing to spend, rather than assuming one exists: a
	# reload test that undoes a change that never happened proves nothing.
	# Blocks are the fallback, because the starting kit always has them and a
	# player who has just spent their last part still has stone.
	var probe := ""
	var probe_block := -1
	for id in inventory.available_eng():
		if inventory.count_eng(id) > 0:
			probe = id
			break
	if probe == "":
		for bid in inventory.available_blocks():
			if inventory.count_of(bid) > 1:
				probe_block = bid
				break
	var probe_before := inventory.count_eng(probe) if probe != "" \
		else inventory.count_of(probe_block)

	# F5, through the same private entry point the key reaches.
	main.call("_do_save")
	check(SaveGame.has_slot(SAVE_SLOT), "F5 writes the save slot")
	print("  ", SaveGame.describe_slot(SAVE_SLOT))
	var res := persistence.last_result()
	check(bool(res["ok"]), "the save reported success: %s"
		% String(res.get("reason", "")))

	# Change the world, the backpack and the assembly, so the reload has real
	# damage to undo. A reload test that loads what it just saved proves
	# nothing about restoring state.
	var wrecked := Vector3i(3, 60, 3)
	var wrecked_id := world.get_content_at(wrecked)
	world.set_block(wrecked, ContentDB.AIR)
	engineering.graph.clear()
	check(engineering.graph.node_count() == 0, "the assembly was cleared first")
	if probe != "":
		inventory.consume_eng(probe, 1)
		check(inventory.count_eng(probe) == probe_before - 1,
			"one %s was spent before reloading" % probe)
	elif probe_block >= 0:
		inventory.consume_block(probe_block, 1)
		check(inventory.count_of(probe_block) == probe_before - 1,
			"one %s was spent before reloading"
			% ContentDB.name_of(probe_block))
	else:
		check(false, "the player has something to spend before reloading")

	main.call("_do_load")
	_step()
	var res2 := persistence.last_result()
	check(bool(res2["ok"]), "F9 reads the save back: %s" % String(res2["reason"]))
	check(engineering.graph.node_count() == nodes_before,
		"the assembly came back with %d nodes" % engineering.graph.node_count())
	if probe != "":
		check(inventory.count_eng(probe) == probe_before,
			"the spent %s came back (%d)" % [probe, inventory.count_eng(probe)])
	elif probe_block >= 0:
		check(inventory.count_of(probe_block) == probe_before,
			"the spent %s came back (%d)"
			% [ContentDB.name_of(probe_block),
				inventory.count_of(probe_block)])
	if wrecked_id != ContentDB.AIR:
		check(world.get_content_at(wrecked) == wrecked_id,
			"the destroyed block came back")
	print("  reloaded: ", res2)
	print("  player at ", player.position)


## Every key in the ARCHITECTURE.md section 16 table must be handled by
## main.gd. A key documented but not bound is a broken promise; a key bound but
## not documented is a secret.
func _documented_keys_are_bound() -> void:
	var sources := {
		"main": FileAccess.get_file_as_string("res://scripts/main.gd"),
		"player": FileAccess.get_file_as_string("res://scripts/player.gd"),
	}
	check(not (sources["main"] as String).is_empty(), "main.gd is readable")
	check(not (sources["player"] as String).is_empty(), "player.gd is readable")
	var doc := FileAccess.get_file_as_string("res://ARCHITECTURE.md")
	check(not doc.is_empty(), "ARCHITECTURE.md is readable")
	for row in DOC_KEYS:
		var key: String = row[0]
		var what: String = row[1]
		var where: String = row[2]
		if not _doc_mentions(doc, key):
			check(false, "%s appears in the key table" % key)
			continue
		# "Enter" is spelled differently in the table and in the code, so map
		# the human name onto the constant rather than guessing.
		var token := key.to_upper() if key != "Enter" else "ENTER"
		check((sources[where] as String).contains("KEY_" + token),
			"%s (%s) is bound in %s.gd" % [key, what, where])

	# F is the documented "use held tool" key, and it is handled in main.gd.
	# Flight is a different node's key now: two nodes with their own
	# _unhandled_input both run, so a shared key fires both actions. This is
	# the cross-file case -- a duplicate scan of main.gd alone finds nothing.
	var player_src := FileAccess.get_file_as_string("res://scripts/player.gd")
	check(_player_claims(player_src, "KEY_F") == false,
		"the player controller no longer claims F (flight is V)")
	check((sources["main"] as String).contains("KEY_F:"),
		"F is handled in main.gd")
	check(_player_claims(player_src, "KEY_V"),
		"the player controller claims V for flight")

	# A key may only be claimed once. Only the first matching branch in an
	# if/elif chain runs, so a second branch is dead code that the
	# documentation still advertises. That is how F5 came to be both save and
	# the triplanar mapping, with the mapping unreachable.
	var src: String = sources["main"]
	var dupes := _duplicate_key_bindings(src)
	check(dupes.is_empty(), "no key is bound twice in main.gd (found: %s)"
		% (", ".join(dupes) if not dupes.is_empty() else "none"))
	# F5 is save, and F5 is only save.
	check(src.contains("elif key == KEY_F5:\n\t\t\t_do_save()"),
		"F5 is bound to save")


## Does the player controller bind this key in its own _unhandled_input?
func _player_claims(player_src: String, token: String) -> bool:
	var re := RegEx.new()
	re.compile("keycode == " + token + "\\b")
	return re.search(player_src) != null


## Does the document name this key, either alone or inside a range like
## "F1-F3"? Matching on a bare substring would let "F1" satisfy "F11".
func _doc_mentions(doc: String, key: String) -> bool:
	var re := RegEx.new()
	re.compile("(?<![A-Z0-9])" + key + "(?![A-Z0-9])")
	return re.search(doc) != null


## Every `key == KEY_X` branch, with anything already counted reported once.
func _duplicate_key_bindings(src: String) -> Array[String]:
	var seen := {}
	var dupes: Array[String] = []
	var re := RegEx.new()
	re.compile("key == (KEY_[A-Z0-9_]+)")
	for m in re.search_all(src):
		var token: String = m.get_string(1)
		if seen.has(token):
			if not dupes.has(token):
				dupes.append(token)
		else:
			seen[token] = true
	return dupes


func _finish() -> void:
	print("\nplayable: %s"
		% ["PASS" if failures == 0 else "%d FAILURES" % failures])
	quit(1 if failures > 0 else 0)
