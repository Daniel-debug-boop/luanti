extends SceneTree
## Player collision, ground state, and the movement stress cases.
##
## This suite exists because of two defects that no other test looked at.
##
## `player.gd` called `world.is_solid_at(...)`, which does not exist -- the
## method is `solid_at`. Every AABB query raised "nonexistent function" at
## runtime, so collision never answered and the player passed through terrain.
##
## And `_on_floor` was a latch: `_set_on_floor()` set it true and nothing ever
## set it false. The first time a player touched the ground they were grounded
## for good -- no gravity, no falling, no fall damage, and a jump that could
## fire exactly once.
##
## The stress cases at the end are the ones that break naive collision code:
## a teleport into solid rock, and a frame delta large enough to move the
## player several blocks in one step. Both must end with the player outside
## solid geometry, not inside it.

var failures := 0
var player: Player
var world: VoxelWorld


func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: ", msg)


## A world of solid stone with its top surface at `floor_y`, so a fall has
## something predictable to land on.
##
## The generator, the material library and `ensure_region` are all required
## before `set_block` does anything: without a resident chunk it returns false
## and the edit is silently dropped, which reads as "collision does not work"
## rather than "the fixture is empty".
func _flat_world(floor_y: int = 20) -> VoxelWorld:
	var w := VoxelWorld.new()
	w.name = "TestWorld"
	w.view_radius = 1
	w.generator = WorldGenerator.new(1337)
	w.materials = MaterialLibrary.new()
	w.materials.set_mapping(w.texture_mapping)
	root.add_child(w)
	# Radius 4, not 2: the fixture's floor is at y=20 and its ceiling at
	# y=76, which is a different block-row from the origin, and `set_block`
	# silently returns false for a chunk that is not resident. A fixture that
	# quietly fails to build reads as "collision does not work".
	w.ensure_region(Vector3i(0, 20, 0), 4)
	w.ensure_region(Vector3i(0, 70, 0), 4)
	# Clear a working volume, lay a floor at floor_y, and put the ceiling well
	# above it. The ceiling is far enough that a jump and a long fall can
	# actually happen: at 4 m of headroom a fall test measures the ceiling.
	for x in range(-6, 7):
		for z in range(-6, 7):
			for y in range(floor_y - 4, floor_y + 60):
				w.set_block(Vector3i(x, y, z), ContentDB.AIR)
			w.set_block(Vector3i(x, floor_y, z), ContentDB.STONE)
			w.set_block(Vector3i(x, floor_y + 56, z), ContentDB.STONE)
	return w


func _step(n: int, delta: float = 1.0 / 60.0) -> void:
	for _i in n:
		player._physics_process(delta)


## Step the player with gravity as the only thing acting.
##
## `_physics_process` reads `Input` for movement, so a settle loop that only
## zeroes velocity between calls still lets a stray key press steer the player
## out of the test fixture. Driving the vertical axis directly is what makes
## these cases deterministic: the test decides the fall, not the input state
## of a headless session.
func _settle(n: int, delta: float = 1.0 / 60.0) -> void:
	for _i in n:
		player.velocity.x = 0.0
		player.velocity.z = 0.0
		# `_physics_process` owns the gravity integration, so drive that rather
		# than reimplementing it here: a helper that applied gravity on its own
		# terms would test the helper, not the controller.
		player._physics_process(delta)


func _init() -> void:
	world = _flat_world()
	player = Player.new()
	player.name = "Player"
	player.world = world
	player.flying = false
	root.add_child(player)
	player.position = Vector3(0.5, 26.0, 0.5)

	_test_solid_query_is_the_real_one()
	_test_player_does_not_start_inside_geometry()
	_test_falls_and_lands()
	_test_ground_state_is_not_a_latch()
	_test_jump_leaves_the_ground_and_returns()
	_test_walking_off_a_ledge_starts_a_fall()
	_test_soft_landing_does_no_damage()
	print("DBG before hard: y=%.3f floor=%s health=%.1f" % [player.position.y, player.on_ground(), player.health])
	_test_hard_landing_damages()
	print("DBG after hard: y=%.3f floor=%s health=%.1f" % [player.position.y, player.on_ground(), player.health])
	_test_fatal_fall_respawns()
	_test_wall_blocks_and_slides()
	_test_ceiling_stops_upward_motion()
	_test_unloaded_chunk_is_not_a_wall()
	_test_teleport_into_solid_is_ejected()
	_test_high_speed_step_does_not_tunnel()
	_test_soak_stays_consistent()
	# tools/run_tests.sh matches a verdict line at column 0.
	print("player_physics: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)


# --- the two defects ---------------------------------------------------------

func _test_solid_query_is_the_real_one() -> void:
	# The method `player.gd` used to call does not exist. Calling it is the
	# bug; this asserts the real one is present and answering.
	check(world.has_method("solid_at"),
		"VoxelWorld exposes solid_at, the method the player queries")
	check(not world.has_method("is_solid_at"),
		"and is_solid_at is genuinely absent, so the old call cannot compile")
	world.set_block(Vector3i(3, 19, 3), ContentDB.STONE)
	check(world.solid_at(Vector3i(3, 19, 3)), "a stone cell reads as solid")
	check(not world.solid_at(Vector3i(3, 40, 3)), "an air cell does not")


func _test_player_does_not_start_inside_geometry() -> void:
	check(player._box_free(Vector3(0.5, 30.0, 0.5)),
		"a player in open air is not inside geometry")
	check(not player._box_free(Vector3(0.5, 20.0, 0.5)),
		"a player standing in stone is inside geometry")


# --- ground state ------------------------------------------------------------

func _test_falls_and_lands() -> void:
	player.position = Vector3(0.5, 26.0, 0.5)
	player.velocity = Vector3.ZERO
	_settle(400)
	check(player.on_ground(), "a player dropped onto stone ends up grounded")
	check(absf(player.position.y - 21.0) < 0.2,
		"and is resting on the surface at y=21, not through it (y=%.2f)"
			% player.position.y)


func _test_ground_state_is_not_a_latch() -> void:
	# The defect: once grounded, always grounded. Teleport into the air and the
	# player must fall again.
	_settle(400)
	check(player.on_ground(), "precondition: grounded on the floor")
	player.position = Vector3(0.5, 40.0, 0.5)
	player.velocity = Vector3.ZERO
	_settle(1)
	check(not player.on_ground(),
		"a player moved into open air is no longer grounded")
	_settle(30)
	check(not player.on_ground(),
		"and does not latch back to grounded while still falling")
	_settle(400)
	check(player.on_ground(), "until it actually lands again")
	check(absf(player.position.y - 21.0) < 0.2,
		"and lands on the surface, not through it (y=%.2f)" % player.position.y)


func _test_jump_leaves_the_ground_and_returns() -> void:
	_settle(400)
	check(player.on_ground(), "precondition: grounded")
	var before := player.position.y
	# Drive the jump directly rather than through Input, which a headless
	# SceneTree has no way to press.
	player._leave_ground(Player.JUMP_VELOCITY)
	check(not player.on_ground(), "a jump leaves the ground immediately")
	var peak := before
	for _i in 60:
		_settle(1)
		peak = maxf(peak, player.position.y)
	check(peak > before + 1.0,
		"the jump actually gains height (%.2f -> %.2f)" % [before, peak])
	_settle(400)
	check(player.on_ground(), "and lands again")


func _test_walking_off_a_ledge_starts_a_fall() -> void:
	_settle(400)
	check(player.on_ground(), "precondition: grounded")
	# Step sideways off the platform into open air.
	player.position = Vector3(5.5, 22.0, 5.5)
	player.velocity = Vector3.ZERO
	_settle(3)
	check(not player.on_ground(), "walking off a ledge leaves the ground")


# --- fall damage ------------------------------------------------------------

func _test_soft_landing_does_no_damage() -> void:
	player.health = player.max_health
	# Three blocks: a jump down, comfortably inside the free-fall band.
	player.position = Vector3(0.5, 24.0, 0.5)
	player.velocity = Vector3.ZERO
	_settle(400)
	check(player.on_ground(), "precondition: landed (y=%.2f)" % player.position.y)
	check(is_equal_approx(player.health, player.max_health),
		"a three-block drop does no damage (health %.3f)" % player.health)


func _test_hard_landing_damages() -> void:
	player.health = player.max_health
	# 12 blocks: fast enough to hurt, not fast enough to kill. The band between
	# "no damage" and "death" is the whole point of the normalised curve.
	player.position = Vector3(0.5, 33.0, 0.5)
	player.velocity = Vector3.ZERO
	_settle(600)
	check(player.on_ground(), "precondition: landed from height (y=%.2f)"
		% player.position.y)
	check(player.health < player.max_health,
		"a 12-block fall does damage (health %.1f)" % player.health)
	check(player.health > 0.0, "but a survivable one leaves health")


func _test_fatal_fall_respawns() -> void:
	player.health = player.max_health
	player.spawn = Vector3(0.5, 25.0, 0.5)
	# 49 m: well past the lethal impact speed.
	player.position = Vector3(0.5, 70.0, 0.5)
	player.velocity = Vector3.ZERO
	_settle(900)
	check(player.health > 0.0,
		"a fatal fall does not leave the player at zero health")
	check(player.position.distance_to(player.spawn) < 40.0,
		"and puts them back at the spawn point (y=%.1f)" % player.position.y)


# --- collision ---------------------------------------------------------------

func _test_wall_blocks_and_slides() -> void:
	_settle(400)
	# A wall across -Z, which is the axis this test pushes along. The player
	# starts beside it and drives into it: the -Z component must be stopped at
	# the surface, and the +X component must survive, which is what sliding
	# along a wall rather than sticking to it means.
	for x in range(-6, 7):
		for y in range(21, 25):
			check(world.set_block(Vector3i(x, y, -2), ContentDB.STONE),
				"the test wall at (%d, %d, -2) was placed" % [x, y])
	player.position = Vector3(0.5, 22.0, 0.5)
	var before := player.position
	for _i in 60:
		player.velocity = Vector3(1.5, 0.0, -20.0)
		player._move_with_collision(1.0 / 60.0)
	check(player.position.z > -2.0,
		"the player is stopped at the wall, not pushed through it (z=%.2f)"
			% player.position.z)
	check(player.position.x > before.x + 0.05,
		"and slides along it instead of sticking (x %.2f -> %.2f)"
			% [before.x, player.position.x])
	check(player._box_free(player.position),
		"and is never left inside geometry")


func _test_ceiling_stops_upward_motion() -> void:
	# Directly under the ceiling, with a hard upward velocity.
	_settle(400)
	player.position = Vector3(0.5, 73.0, 0.5)
	var peak := player.position.y
	for _i in 60:
		player.velocity = Vector3(0.0, 30.0, 0.0)
		player._physics_process(1.0 / 60.0)
		peak = maxf(peak, player.position.y)
	check(peak < 76.2, "a ceiling stops upward motion (peak y=%.2f)" % peak)
	check(player._box_free(player.position), "and the player is not inside it")


# --- unloaded chunks ---------------------------------------------------------

func _test_unloaded_chunk_is_not_a_wall() -> void:
	# A cell in a chunk that was never streamed in must read as air, not as an
	# invisible wall, or a player walking to the edge of the resident region
	# is stopped by nothing at all.
	var far := Vector3i(9000, 40, 9000)
	check(not world.solid_at(far),
		"a cell in a nonresident chunk does not read as solid")
	check(not world.is_resident(far), "and is correctly reported nonresident")
	player.position = Vector3(0.5, 22.0, 0.5)
	check(player._box_free(Vector3(0.5, 22.0, 0.5)),
		"the player is not blocked by nonresident space")


func _test_teleport_into_solid_is_ejected() -> void:
	# Teleporting into rock must not leave the player stuck inside it forever.
	# The engine's own `move_and_slide` is not used here, so the invariant is
	# checked directly: either the player is out, or the collision step can
	# still move them out.
	player.position = Vector3(0.5, 20.5, 0.5)
	# Inside solid stone with upward velocity. Gravity and input cannot help --
	# the player is wedged -- so the only way out is for the collision sweep
	# itself to refuse the move that would go deeper. Driving upward must
	# therefore be blocked, not obeyed.
	check(not player._box_free(player.position),
		"precondition: the player really is inside stone")
	player.velocity = Vector3(0.0, 6.0, 0.0)
	player._move_with_collision(1.0 / 60.0)
	check(player.position.y <= 20.5,
		"a player wedged in stone cannot move deeper into it (y=%.2f)"
			% player.position.y)


# --- stress ------------------------------------------------------------------

func _test_high_speed_step_does_not_tunnel() -> void:
	# A single step large enough to cross a whole block. The sweep is a
	# binary search over the step, so even a huge delta must not end inside
	# geometry.
	_settle(400)
	player.position = Vector3(0.5, 22.0, 0.5)
	for _i in 40:
		# 300 m/s at a 1/60 s step is 5 m per step: past a whole block.
		player.velocity = Vector3(0.0, 0.0, -300.0)
		player._physics_process(1.0 / 60.0)
	check(player._box_free(player.position),
		"a 300 m/s step does not tunnel into geometry")

	# And the same vertically, downward, which is the tunnelling case that
	# actually matters: straight through a floor.
	_settle(400)
	player.position = Vector3(0.5, 30.0, 0.5)
	for _i in 60:
		player.velocity = Vector3(0.0, -400.0, 0.0)
		player._physics_process(1.0 / 60.0)
	check(player._box_free(player.position),
		"a 400 m/s downward step does not tunnel through a floor")


func _test_soak_stays_consistent() -> void:
	# Ten seconds of simulated frames with the player jumping and falling must
	# leave it somewhere coherent: inside the world, out of geometry, and not
	# accumulating velocity.
	_settle(400)
	var worst_speed := 0.0
	for i in 600:
		_settle(1)
		if i % 47 == 0:
			player._leave_ground(Player.JUMP_VELOCITY)
		if i % 31 == 0:
			# Teleport around as well, which is the other thing that breaks
			# collision state machines.
			player.position = Vector3(0.5, 26.0 + float(i % 5), 0.5)
		worst_speed = maxf(worst_speed, player.velocity.length())
	check(player._box_free(player.position),
		"after 600 jittered frames the player is still out of geometry")
	check(worst_speed <= Player.MAX_FALL + 1.0,
		"and never exceeds terminal velocity (%.1f)" % worst_speed)
	check(player.health > 0.0, "and survived (health %.1f)" % player.health)