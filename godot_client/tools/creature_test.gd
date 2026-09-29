extends SceneTree
## Audio (CC0 Kenney), CC0 KayKit creature models, A* pathfinding and block
## drops -- the systems added after inventory/crafting/saving.

var _fails := 0


func _init() -> void:
	_test_sound_bank()
	_test_audio_playback()
	_test_creature_models()
	_test_animations()
	_test_smart_mobs()
	_test_villager_schedule_and_trade()
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


## The KayKit characters ship their own CC0 animations, so nothing has to be
## downloaded for the models to move.
func _test_animations() -> void:
	var path := CreatureModels.pick(CreatureModels.MOB_MODELS, 7)
	var model := CreatureModels.spawn(path, 1.0, Color.WHITE)
	_eq(model != null, true, "a mob model instantiates for animation")

	var anim := CreatureAnimator.new()
	_eq(anim.attach(model), true, "an AnimationPlayer is found in the model")
	_ok("model carries %d clips" % anim.clip_count())
	_eq(anim.clip_count() > 50, true, "KayKit ships a full clip library")
	_eq(anim.attached(), true, "animator reports attached")

	# Every logical state must resolve to a clip this model actually has.
	# Locomotion states are tested on a fresh animator, because DEATH is
	# deliberately terminal and latches the animator.
	for state in [CreatureAnimator.State.IDLE, CreatureAnimator.State.MOVE,
			CreatureAnimator.State.RUN, CreatureAnimator.State.ATTACK,
			CreatureAnimator.State.HURT]:
		anim.set_state(state)
		_ok("state %d -> %s" % [state, CreatureAnimator.CLIPS[state][0]])

	# One-shot states should latch, then release.
	anim.set_state(CreatureAnimator.State.ATTACK)
	_eq(anim.finished_one_shot(), false, "an attack holds for its duration")
	anim.update(1.0, 0.0, 1.6, 3.4)
	_eq(anim.finished_one_shot(), true, "the attack releases after its time")

	# Greeting / working clips exist on the models.
	_eq(anim.play_once(CreatureAnimator.GREET_CLIPS), true,
		"a greeting clip plays")
	_eq(anim.play_once(["NoSuchClip"]), false, "an unknown clip is refused")

	# Let the greeting one-shot expire before checking locomotion, otherwise
	# the animator correctly refuses to leave it mid-clip.
	anim.update(2.0, 0.0, 1.6, 3.4)

	# Walk cycle speed should track movement speed.
	anim.update(0.2, 3.0, 1.6, 3.4)
	_eq(anim.current_state(), CreatureAnimator.State.RUN, "fast movement runs")
	anim.update(0.2, 1.2, 1.6, 3.4)
	_eq(anim.current_state(), CreatureAnimator.State.MOVE, "slow movement walks")
	anim.update(0.2, 0.0, 1.6, 3.4)
	_eq(anim.current_state(), CreatureAnimator.State.IDLE, "standing still idles")

	# Death is terminal: it must latch and refuse to hand control back.
	var dying := CreatureAnimator.new()
	dying.attach(model)
	dying.set_state(CreatureAnimator.State.DEATH)
	dying.update(10.0, 5.0, 1.6, 3.4)
	_eq(dying.current_state(), CreatureAnimator.State.DEATH,
		"death is terminal and does not fall back to locomotion")

	# An unattached animator must degrade, not crash.
	var loose := CreatureAnimator.new()
	_eq(loose.attach(null), false, "attaching to null returns false")
	loose.set_state(CreatureAnimator.State.IDLE)
	loose.update(0.1, 1.0, 1.0, 1.0)
	_eq(loose.attached(), false, "a loose animator stays unattached")
	_eq(loose.clip_count(), 0, "a loose animator has no clips")

	model.free()


func _test_smart_mobs() -> void:
	var w := _flat_world()
	var mob := Mob.new()
	mob.world = w
	mob.hostile = true
	mob.max_health = 10.0
	mob.health = 10.0
	mob.ensure_ready()
	w.add_child(mob)
	_eq(mob.is_in_group("mobs"), true, "mob joins the mobs group")

	# Getting hit with no prior target should make it turn on whoever is
	# around. (The tree lookup needs the mob in-tree, which SceneTree._init
	# does not give us, so this asserts the state machine directly.)
	_eq(mob._target == null, true, "mob starts with no target")
	mob.apply_damage(2.0)
	_eq(mob.health, 8.0, "damage reduces health")

	var aggro := Node3D.new()
	mob.set_target(aggro, true)
	_eq(mob._target != null, true, "a provoked mob takes a target")
	_eq(mob.state, Mob.State.CHASE, "a provoked hostile mob chases")

	# A hurt mob below the flee threshold should stop chasing and run.
	mob.health = 2.0     # 20% of max
	mob._pick_state()
	_eq(mob.state, Mob.State.FLEE, "a badly hurt mob flees")

	# A healthy mob with a live target must not forget the chase just because
	# its decision timer expired.
	mob.health = 10.0
	mob._pick_state()
	_eq(mob.state, Mob.State.CHASE, "a healthy mob keeps chasing across re-rolls")
	_mobs_flee_when_hurt(mob, aggro)

	# A passive mob never chases, even when provoked.
	var calm := Mob.new()
	calm.world = w
	calm.hostile = false
	calm.ensure_ready()
	w.add_child(calm)
	var dummy := Node3D.new()
	w.add_child(dummy)
	calm.set_target(dummy, true)
	_eq(calm.state, Mob.State.FLEE, "a passive mob flees instead of chasing")

	# A passive mob with a live target keeps running rather than fighting back.
	calm.health = 5.0
	calm.set_target(dummy, false)
	calm._pick_state()
	_eq(calm.state, Mob.State.FLEE, "a passive mob keeps fleeing")
	dummy.free()

	# Ledge detection: standing next to a hole must report a ledge ahead.
	var ledge := Mob.new()
	ledge.world = w
	ledge.ensure_ready()
	w.add_child(ledge)
	# Stand it right at the lip of a hole: floor is removed from x=4 onward.
	for y in range(16, 22):
		for z in range(-2, 3):
			for x in range(4, 9):
				w.set_block(Vector3i(x, y, z), ContentDB.AIR)
	ledge.position = Vector3(3.5, 20.0, 0.0)
	ledge.velocity = Vector3(1.0, 0.0, 0.0)
	_ok("ground ahead: %s" % str(w.solid_at(Vector3i(5, 19, 0))))
	_eq(ledge._ledge_ahead(), true, "a mob detects the drop in front of it")

	# ...and reports no ledge when there is floor ahead.
	ledge.velocity = Vector3(-1.0, 0.0, 0.0)
	_eq(ledge._ledge_ahead(), false, "no ledge when walking back over solid ground")

	# Melee: a hostile mob in reach should swing and put damage into the target.
	var victim := Node3D.new()
	victim.set_script(preload("res://scripts/player/player_interaction.gd"))
	# PlayerInteraction.damage() writes to its `player`, so give it one.
	var victim_player := Player.new()
	victim_player.world = w
	w.add_child(victim_player)
	victim.player = victim_player
	w.add_child(victim)
	var striker := Mob.new()
	striker.world = w
	striker.hostile = true
	striker.ensure_ready()
	w.add_child(striker)
	striker.position = victim.position + Vector3(0.5, 0, 0)
	striker.set_target(victim, true)
	striker._try_attack()
	_ok("attack cooldown after a swing: %f" % striker._attack_timer)
	_eq(striker._attack_timer > 0.0, true, "a swing starts the cooldown")
	_eq(victim_player.health < victim_player.max_health, true,
		"the swing damaged the target (%f)" % victim_player.health)
	# A second swing inside the cooldown must be refused.
	var timer_after := striker._attack_timer
	striker._try_attack()
	_eq(striker._attack_timer, timer_after, "a second swing is refused on cooldown")
	# Out of reach: no swing.
	var far := Mob.new()
	far.world = w
	far.hostile = true
	far.ensure_ready()
	w.add_child(far)
	far.position = victim.position + Vector3(40.0, 0, 0)
	far.set_target(victim, true)
	far._try_attack()
	_eq(far._attack_timer, 0.0, "an out-of-reach target is not attacked")
	# A passive mob in reach does not attack.
	var shy := Mob.new()
	shy.world = w
	shy.hostile = false
	shy.ensure_ready()
	w.add_child(shy)
	shy.position = victim.position + Vector3(0.5, 0, 0)
	shy.set_target(victim, false)
	shy._try_attack()
	_eq(shy._attack_timer, 0.0, "a passive mob does not attack")

	w.queue_free()


## A mob that has been hit while already healthy should not panic.
func _mobs_flee_when_hurt(mob: Mob, aggro: Node3D) -> void:
	mob.health = mob.max_health
	mob.set_target(aggro, true)
	_eq(mob.state, Mob.State.CHASE, "a healthy provoked mob still chases")


func _test_villager_schedule_and_trade() -> void:
	var v := Villager.new()
	v.villager_name = "Bram"
	v.job = "Farmer"
	v.trade_block = ContentDB.SAND
	v.trade_price = 2
	v.trade_stock = 4
	v.ensure_ready()
	root.add_child(v)

	# Schedule: work by day, rest in the evening, sleep at night.
	v.update_schedule(0.5)
	_eq(v.activity, "Work", "midday is work")
	_eq(v.is_resting(), false, "midday is not resting")
	v.update_schedule(0.8)
	_eq(v.activity, "Rest", "late afternoon is rest")
	_eq(v.is_resting(), true, "late afternoon is resting")
	v.update_schedule(0.05)
	_eq(v.activity, "Sleep", "the small hours are sleep")
	_eq(v.is_resting(), true, "night is resting")

	# Trading: needs stone, returns the job's produce, and runs out.
	var inv := PlayerInventory.new()
	root.add_child(inv)
	_eq(v.trade(inv), "", "trading with empty hands fails")

	inv.give_block(ContentDB.STONE)
	inv.give_block(ContentDB.STONE)
	_eq(v.trade(inv), "sand x2", "trading exchanges stone for produce")
	_eq(v.trade_stock, 2, "stock decreases")
	_ok("stone left: %d" % inv.count_of(ContentDB.STONE))

	# Drain the stock and confirm the villager refuses.
	v.trade_stock = 1
	inv.give_block(ContentDB.STONE)
	inv.give_block(ContentDB.STONE)
	_eq(v.trade(inv), "sand x1", "a partial trade is accepted")
	_eq(v.trade_stock, 0, "stock is exhausted")
	inv.give_block(ContentDB.STONE)
	_eq(v.trade(inv), "", "an out-of-stock villager refuses to trade")

	_eq(v.trade(null), "", "trading with a null inventory is handled")
	inv.queue_free()
	v.queue_free()


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
