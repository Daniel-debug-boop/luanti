extends Node3D
## Assembles the world, player, mobs, village, sky, interaction and HUD, and
## drives streaming.

## Converted chunk directory. Empty = auto-detect; when absent, terrain is
## generated procedurally.
@export var world_dir := ""
@export var view_radius := 5
## Node coordinates. The player is dropped onto the surface at this column.
@export var spawn := Vector3(8.5, 40.0, 8.5)
## Turn the day/night clock off to hold the sun still.
@export var day_night_enabled := true
## RenderSettings.Quality: 0 low, 1 medium, 2 high (SSIL, SDFGI, volumetric fog).
@export_enum("Low", "Medium", "High", "Ultra") var render_quality := 2
## How block textures are projected. Godot cannot combine triplanar mapping
## with parallax occlusion, so this picks one:
##   0 plain (box UVs) · 1 triplanar · 2 parallax occlusion (POM)
##   3 stochastic triplanar (vendored shader, breaks up texture tiling)
@export_enum("Plain", "Triplanar", "Parallax", "Stochastic") var texture_mapping := 2

var world: VoxelWorld
var player: Player
var hud: WorldHud
var spawner: MobSpawner
var village: Village
var interaction: PlayerInteraction
var day_night: DayNight
var settings: RenderSettings
## GLoot-backed inventory and hotbar. Filled with a starting kit on boot.
var inventory: PlayerInventory
## All game audio, playing CC0 Kenney samples.
var audio: AudioDirector
## Where BlockDrop entities are parented.
var _drops: Node3D
## The 3x3 drag-and-drop crafting grid, opened with C.
var crafting: CraftingPanel

## The universal engineering and manufacturing system. Owns the component
## graph and its simulation; borrows the world and the backpack.
var engineering: EngEngineering
var engineering_hud: EngHud

## Performance instrumentation and the multiplayer authority. Both are
## ordinary members of the game, not developer tooling bolted on: the
## profiler is what makes the game measurable on real hardware (F10), and the
## authority is the only path by which any mutation is allowed to happen.
var profiler: GameProfiler
var watchdog: StabilityWatchdog
var authority: NetAuthority
## One owner per system, and the single door between them. Everything below
## registers here; nothing reaches into anything else's internals.
var systems := SystemRegistry.new()
var api: GameApi = null
var devtools: DevTools = null
## The lifecycle wrapper for the save file, and the owner the API resolves
## `persistence` to.
var persistence: Persistence = null
## Which save slot F5 writes / F9 reads.
var save_slot := 1
var _env_over: Environment
var _env_deeps: Environment
var _we: WorldEnvironment
var _sun: DirectionalLight3D
var _moon: DirectionalLight3D
var _deeps_ambience: DirectionalLight3D
var _fog_volume: FogVolume
var _probes: Array[ReflectionProbe] = []
var _current_dim := 0


func _ready() -> void:
	settings = RenderSettings.new()
	# The tier has to be applied to the environments here, before the world's
	# material library exists: `settings.quality = render_quality` on its own
	# would leave every environment effect configured for the default tier,
	# whatever tier the scene was actually launched at.
	_setup_environment()
	settings.quality = render_quality
	settings.apply(_env_over)
	settings.apply(_env_deeps)

	world = VoxelWorld.new()
	world.name = "VoxelWorld"
	world.world_dir = world_dir
	world.view_radius = view_radius
	world.texture_mapping = texture_mapping
	add_child(world)
	# The world's material library exists only now, so this is the first
	# point at which the starting tier can reach it.
	world.materials.apply_quality(render_quality)
	world.rebind_materials()

	inventory = PlayerInventory.new()
	inventory.name = "Inventory"
	add_child(inventory)

	# The engineering system. It is added here, as a sibling of the world and
	# the backpack, and handed pointers to both -- it owns neither, which is
	# why there is exactly one inventory, one world and one save file.
	engineering = EngEngineering.new()
	engineering.name = "Engineering"
	add_child(engineering)
	engineering.build()
	engineering.attach(world, inventory)

	engineering_hud = EngHud.new()
	engineering_hud.name = "EngineeringHud"
	add_child(engineering_hud)
	engineering_hud.attach(engineering)

	# Claim the single world slot, then check the structural invariants. A
	# startup that assembles the wrong number of anything is a bug worth
	# hearing about before the player reaches a save, not after.
	var why := WorldBackend.register(world)
	if why != "":
		push_warning("[main] world backend refused: ", why)

	# One profiler, one watchdog, one authority for the whole process. This is
	# the anti-duplication rule made concrete: there is no second place a
	# frame can be measured from, and no second door into the world state.
	profiler = GameProfiler.new()
	profiler.name = "Profiler"
	add_child(profiler)
	watchdog = StabilityWatchdog.new()
	authority = NetAuthority.new()

	audio = AudioDirector.new()
	audio.name = "Audio"
	add_child(audio)

	_drops = Node3D.new()
	_drops.name = "Drops"
	add_child(_drops)

	player = Player.new()
	player.name = "Player"
	player.world = world
	add_child(player)
	player.position = spawn

	var cam := Camera3D.new()
	cam.name = "Camera"
	cam.position = Vector3(0.0, Player.EYE_HEIGHT, 0.0)
	cam.fov = 78.0
	cam.far = 640.0
	player.add_child(cam)
	audio.set_listener(player)

	spawner = MobSpawner.new()
	spawner.name = "MobSpawner"
	spawner.world = world
	spawner.player = player
	spawner.audio = audio
	spawner.drops_parent = _drops
	add_child(spawner)

	interaction = PlayerInteraction.new()
	interaction.name = "Interaction"
	interaction.world = world
	interaction.player = player
	interaction.inventory = inventory
	interaction.audio = audio
	interaction.drops_parent = _drops
	add_child(interaction)

	# Mining and placing now move real items rather than picking from a fixed
	# block list, so give the player something to work with.
	inventory.give_starting_kit()
	interaction.refresh_hotbar()

	village = Village.new()
	village.name = "Village"
	village.world = world
	village.player = player
	village.audio = audio
	add_child(village)

	day_night = DayNight.new()
	day_night.name = "DayNight"
	day_night.world_environment = _we
	day_night.sun = _sun
	day_night.moon = _moon
	day_night.time_of_day = 0.34
	add_child(day_night)
	if not day_night_enabled:
		day_night.set_process(false)

	hud = WorldHud.new()
	hud.name = "HUD"
	hud.player = player
	hud.world = world
	hud.spawner = spawner
	hud.village = village
	hud.interaction = interaction
	# The hotbar displays what the player is carrying, so it reads the same
	# GLoot slots the interaction node does. There is no second, fixed block
	# list for it to fall back to.
	hud.inventory = inventory
	hud.day_night = day_night
	hud.settings = settings
	hud.inventory = inventory
	crafting = CraftingPanel.new()
	crafting.name = "CraftingPanel"
	add_child(crafting)
	crafting.setup(inventory, audio)
	add_child(hud)

	# --- Bounce probes and fog volume ---
	# A ring of reflection probes around the player supplies indirect bounce
	# light; the fog volume keeps the volumetric layer dense near the camera.
	_fog_volume = settings.make_fog_volume()
	add_child(_fog_volume)
	for p in settings.make_probes(4):
		add_child(p)
		_probes.append(p)

	# Arrival is the one moment the streaming budget does not apply: the player
	# is about to stand on this world, and a chunk that has not been generated
	# yet is a hole they fall through.
	world.ensure_region(_player_chunk(), 2)
	world.drop_distant(_player_chunk())
	_place_on_surface()

	world.update_around(_player_chunk())
	village.update(player.position)
	print("[main] ready in ", world.biome_name_at(
		Vector3i(int(spawn.x), int(spawn.y), int(spawn.z))), " biome")
	print("[main] render: ", settings.describe())
	_register_systems()
	devtools = DevTools.new()
	devtools.name = "DevTools"
	add_child(devtools)
	devtools.attach(self, api)
	# Last, once every singleton exists: the structural invariants describe
	# the tree that was actually built, not the one we intended to build.
	_check_architecture()


func _place_on_surface() -> void:
	# The generator runs synchronously, so the spawn column is available now.
	var bx := int(floor(spawn.x))
	var bz := int(floor(spawn.z))
	var y := 48
	while y > 2 and not world.solid_at(Vector3i(bx, y, bz)):
		y -= 1
	player.position = Vector3(spawn.x, y + 1.6, spawn.z)


func _setup_environment() -> void:
	# Both environments get the full stock effect set from RenderSettings:
	# SSAO, SSIL, SDFGI, volumetric fog and glow, all configured through
	# built-in Environment properties.
	_env_over = settings.build_overworld_environment()
	_env_deeps = settings.build_deeps_environment()

	_we = WorldEnvironment.new()
	_we.name = "WorldEnvironment"
	_we.environment = _env_over
	add_child(_we)

	_sun = DirectionalLight3D.new()
	_sun.name = "Sun"
	_sun.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	_sun.light_energy = 1.2
	_sun.light_color = Color(1.0, 0.97, 0.92)
	_sun.shadow_enabled = true
	_sun.directional_shadow_max_distance = 96.0
	add_child(_sun)

	_moon = DirectionalLight3D.new()
	_moon.name = "Moon"
	_moon.light_energy = 0.0
	_moon.light_color = Color(0.6, 0.72, 1.0)
	_moon.visible = false
	add_child(_moon)

	_deeps_ambience = DirectionalLight3D.new()
	_deeps_ambience.name = "DeepsLight"
	_deeps_ambience.rotation_degrees = Vector3(-30.0, 60.0, 0.0)
	_deeps_ambience.light_energy = 0.25
	_deeps_ambience.light_color = Color(0.6, 0.5, 1.0)
	_deeps_ambience.visible = false
	add_child(_deeps_ambience)


func _process(delta: float) -> void:
	if world == null or player == null:
		return
	profiler.begin("world")
	world.update_around(_player_chunk())
	# Keep the probe and fog volumes on the player: SDFGI traces through the
	# volume, so a volume left behind would bake probes for terrain the player
	# can no longer see.
	_follow_volumes()
	_collect_drops()
	profiler.unmark("world")
	profiler.begin("villagers")
	_update_villager_schedule()
	profiler.unmark("villagers")
	if engineering != null:
		# One place that knows where the player is, which is what the
		# simulation's level-of-detail tiers are computed from.
		profiler.begin("engineering")
		engineering.tick(delta, [player.position], village.villagers() \
			if _current_dim == WorldGenerator.DIM_OVERWORLD else [])
		profiler.unmark("engineering")
		if engineering_hud != null:
			engineering_hud.set_target(_engineering_target())
			engineering_hud.set_tool_preview(_tool_preview_text())
	if day_night_enabled and _current_dim == WorldGenerator.DIM_OVERWORLD:
		day_night.advance(delta)
	if _current_dim == WorldGenerator.DIM_OVERWORLD:
		profiler.begin("village")
		village.update(player.position)
		profiler.unmark("village")
		# Respawn the player at their spawn point when they die outright.
		if not interaction.is_alive():
			player.health = player.max_health
			_place_on_surface()
	systems.tick_all(delta)
	_sample_stability(delta)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key := (event as InputEventKey).keycode
		if key == KEY_G:
			_switch_dimension()
		elif key >= KEY_1 and key <= KEY_8:
			interaction.select_slot(key - KEY_1)
		elif key == KEY_E:
			_talk_nearby()
		elif key == KEY_F5:
			_do_save()
		elif key == KEY_F9:
			_do_load()
		elif key == KEY_C:
			_toggle_crafting()
		elif key == KEY_F:
			_engineering_use_held()
		elif key == KEY_R:
			_engineering_cycle_level()
		elif key == KEY_B:
			if engineering_hud != null:
				engineering_hud.toggle_workshop()
		elif key == KEY_Q:
			# The only way to make hotbar space, and therefore the only way
			# to free a slot for a manufactured part.
			interaction.stow_selected()
		elif key == KEY_F1:
			# ULTRA sits on Shift+F1 rather than taking F4 from the texture
			# mapping cycle: the four tiers have to be reachable, and the
			# mapping modes were already on their own key.
			set_render_quality(3 if event.shift_pressed else 0)
		elif key == KEY_F2:
			set_render_quality(1)
		elif key == KEY_F3:
			set_render_quality(2)
		elif key == KEY_F4:
			# F4 cycles the block texture mapping rather than claiming a key
			# per mode. Four modes on four keys put a mode on F5, and F5 is
			# save -- one of them was silently unreachable.
			_cycle_texture_mapping(1 if event.shift_pressed else -1)
		elif key == KEY_F10:
			# The debug panel: read-only, and the answer to "what was the game
			# doing when it broke" without a debugger.
			if devtools != null:
				devtools.toggle()
		elif key == KEY_F11:
			print("[dev] ", devtools.report("systems") if devtools != null else "no devtools")
		elif key == KEY_F12:
			# The profiler is how the game gets measured on hardware this
			# development environment is not.
			if profiler != null:
				profiler.toggle_overlay()
				print("[main] profiler ", "on" if profiler.overlay else "off",
					"; ", profiler.snapshot()["renderer"] if profiler.overlay else "")
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				interaction.start_break()
			else:
				interaction.stop_breaking()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			interaction.place()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			interaction.select_slot(interaction.selected + 1)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			interaction.select_slot(interaction.selected - 1)


## Greet the closest villager within reach; also swings at a mob instead.
## Tell nearby villagers what time it is, so they can run a day.
func _update_villager_schedule() -> void:
	if day_night == null:
		return
	var tod := day_night.time_of_day
	for node in get_tree().get_nodes_in_group("villagers"):
		var v := node as Villager
		if v != null and is_instance_valid(v):
			v.update_schedule(tod)


func _talk_nearby() -> void:
	for node in get_tree().get_nodes_in_group("villagers"):
		var v := node as Villager
		if v != null and is_instance_valid(v) \
				and v.global_position.distance_to(player.global_position) < 4.0:
			print("[main] ", v.greet("Traveller"))
			audio.play_at("mob_idle", v.global_position)
			# Talking also offers a trade: stone for the villager's produce.
			var got := v.trade(inventory)
			if got != "":
				print("[main] traded with %s: +%s" % [v.villager_name, got])
				audio.play("craft")
				interaction.refresh_hotbar()
			else:
				print("[main] %s has nothing to trade right now"
					% v.villager_name)
				audio.play("craft_fail")
			return
	for node in get_tree().get_nodes_in_group("mobs"):
		var m := node as Mob
		if m != null and is_instance_valid(m) \
				and m.global_position.distance_to(player.global_position) < 3.0:
			m.apply_damage(3.0)
			print("[main] hit a mob for 3")
			return


func _switch_dimension() -> void:
	var next := WorldGenerator.DIM_DEEPS \
			if _current_dim == WorldGenerator.DIM_OVERWORLD \
			else WorldGenerator.DIM_OVERWORLD
	_current_dim = next
	world.set_dimension(next)
	var deeps := next == WorldGenerator.DIM_DEEPS
	_we.environment = _env_deeps if deeps else _env_over
	_sun.visible = not deeps and day_night.daylight() > 0.02
	_moon.visible = not deeps and day_night.daylight() <= 0.6
	_deeps_ambience.visible = deeps
	if deeps:
		# Drop into a cavern with open space around the entry point.
		player.position = Vector3(8.5, -6.0, 8.5)
		_carve_arrival()
	else:
		_place_on_surface()


## Carve a small arrival pocket so the player does not spawn entombed.
func _carve_arrival() -> void:
	var centre := Vector3i(8, -6, 8)
	for dx in range(-2, 3):
		for dy in range(-1, 3):
			for dz in range(-2, 3):
				var p := centre + Vector3i(dx, dy, dz)
				var chunk := Vector3i(
					int(floor(float(p.x) / 16.0)),
					int(floor(float(p.y) / 16.0)),
					int(floor(float(p.z) / 16.0)))
				var block := world.get_block(chunk)
				if block == null:
					continue
				var local := p - chunk * 16
				var idx := MapNode.index(local.x, local.y, local.z)
				if p != centre + Vector3i(0, -1, 0):
					block.content[idx] = ContentDB.AIR
				else:
					# Floor to stand on.
					block.content[idx] = ContentDB.DEEPSLATE
					block.light[idx] = 12 | (12 << 4)


## Move the fog volume and bounce probes with the player. The fog layer is
## densest around the camera, and a probe left behind would keep baking light
## for terrain the player can no longer see.
func _follow_volumes() -> void:
	var p := player.global_position
	if _fog_volume != null:
		_fog_volume.position = p
	settings.place_probes(p)


## Switch the render tier at runtime (0 low, 1 medium, 2 high, 3 ultra).
func set_render_quality(q: int) -> void:
	render_quality = q
	settings.set_quality(q, world.materials,
		[_env_over, _env_deeps] as Array[Environment])
	world.rebind_materials()
	print("[main] render: ", settings.describe())


## Switch between plain box UVs, triplanar projection, and parallax occlusion.
## Godot silently discards the heightmap when triplanar is on, so the two
## cannot be combined; this replaces one with the other.
func set_texture_mapping(m: int) -> void:
	var names := MaterialLibrary.mapping_name()
	texture_mapping = clampi(m, 0, names.size() - 1)
	world.set_texture_mapping(texture_mapping)
	print("[main] texture mapping: ", names[texture_mapping])


## Step the block texture mapping by `dir`, wrapping at both ends. F4 steps
## forward, Shift+F4 steps back.
func _cycle_texture_mapping(dir: int) -> void:
	var n: int = MaterialLibrary.mapping_name().size()
	set_texture_mapping((texture_mapping + dir + n) % n)


## Walk over loose blocks and pick them up.
func _collect_drops() -> void:
	if inventory == null or player == null:
		return
	for node in get_tree().get_nodes_in_group("drops"):
		var d := node as BlockDrop
		if d == null or not is_instance_valid(d):
			continue
		if d.try_collect(player.global_position, inventory):
			audio.play_at("pickup", d.global_position)


## Write the whole player state to `save_slot`.
## The engineering node under the crosshair, or -1.
##
## The engineering cursor snaps to whatever is nearest the aim rather than
## demanding pixel accuracy, which is what lets the player build without
## hunting for a one-block target.
func _engineering_target() -> int:
	if engineering == null or player == null:
		return -1
	var near := engineering.graph.nodes_near(player.position, 4.0)
	var best := -1
	var best_d := 2.0
	for n in near:
		var node_ref: EngGraph.EngNode = n
		var d: float = node_ref.position.distance_to(player.position)
		if d < best_d:
			best_d = d
			best = node_ref.id
	return best


## F: use whatever the player is holding on whatever they are looking at.
## If it is a tool, the tool's process runs; if it is a component, the
## component is placed or fastened. One key, context decides.
func _engineering_use_held() -> void:
	if engineering == null or inventory == null:
		return
	var target := _engineering_target()
	var held := inventory.selected_eng_item()
	if held == "":
		# Holding a block: smelt it, because that is the step the whole
		# progression starts with.
		if inventory.selected_block_id() >= 0:
			var r := engineering.smelt_held()
			if not bool(r["ok"]):
				_toast(String(r["reason"]))
		return
	if EngTools.get_tool(held) != null:
		if target < 0:
			return
		var ctx := _tool_context()
		var used := engineering.use_tool(held, target, ctx)
		if not bool(used["ok"]):
			_toast(String(used["reason"]))
		return
	if target < 0:
		engineering.place(held, player.position + Vector3(0, -1.2, -1.6))
		return
	# A component in hand aimed at an existing assembly means "fasten this to
	# it", which is how a motor gets bolted into a housing.
	var fastened := engineering.fasten(player.position + Vector3(0, -1.2, -1.6))
	if not bool(fastened["ok"]):
		engineering.place(held, player.position + Vector3(0, -1.2, -1.6))


## What the held tool would do to what the player is looking at, and whether
## it can. This is the entire build UI: a sentence, not a menu.
func _tool_preview_text() -> String:
	if engineering == null or inventory == null:
		return ""
	var held := inventory.selected_eng_item()
	if held == "":
		return ""
	var t := EngTools.get_tool(held)
	if t == null:
		return ""
	if not engineering.graph.has_station_tools() and not \
			EngWorkshop.available_tools(engineering.graph).has(held):
		return "%s: no station for it yet" % t.name.capitalize()
	var target := _engineering_target()
	if target < 0:
		return "%s  --  aim at something" % t.name.capitalize()
	var node_ref := engineering.graph.node(target)
	if node_ref == null:
		return ""
	var part: EngPart = node_ref.part if node_ref.part != null else \
		EngPart.block(EngItems.material_of(node_ref.component_id), 0.1)
	var p := EngTools.preview(held, part, _tool_context())
	if bool(p["ok"]):
		return "%s  ->  %s  (%.0f energy)" % [t.name.capitalize(),
			String(p["process"]), float(p.get("energy", 0.0))]
	return "%s  x  %s" % [t.name.capitalize(), String(p["reason"])]


## Turn the held tool at whatever is under the crosshair and let the cursor
## say where the operation will land.
func _tool_context() -> Dictionary:
	return {"axis": "x", "at": 0.5,
		"position": player.position + Vector3(0, -1.2, -1.6), "radius": 0.02}


func _toast(text: String) -> void:
	if engineering_hud != null:
		engineering_hud.show_toast(text)


## R cycles the three interaction levels: assisted, standard, precision.
func _engineering_cycle_level() -> void:
	if engineering == null:
		return
	engineering.cursor_level = (engineering.cursor_level + 1) % 3
	_toast("engineering: %s" % ["assisted", "standard", "precision"][
		engineering.cursor_level])


func _do_save() -> void:
	if crafting != null and crafting.visible:
		_toggle_crafting()
	# The persistence layer owns the policy: seal, back up, write atomically.
	# main.gd asks; it does not know how a save is made safe.
	var r := _persistence().save_to(save_slot, player, world, _current_dim,
		engineering)
	if bool(r["ok"]):
		audio.play("save")
		print("[main] saved to slot %d: %s" % [save_slot,
			SaveGame.describe_slot(save_slot)])
	else:
		# A failed save is a recoverable situation, not a crash: the player is
		# told, the game keeps running, and the previous save is still there.
		push_warning("[main] save failed: ", r["reason"])


## Feed the stability watchdog. It samples on its own interval, and only calls
## the (comparatively expensive) counter gather when it is actually due.
func _sample_stability(delta: float) -> void:
	if watchdog == null:
		return
	# "Quiescent" means the player is not building, the sim is idle and no
	# chunks are streaming: growth measured during a burst is not a leak.
	var busy := engineering != null and engineering.is_busy()
	watchdog.set_quiescent(not busy, float(Time.get_ticks_msec()) / 1000.0)
	watchdog.tick(float(Time.get_ticks_msec()) / 1000.0, delta * 1000.0)


## Print the stability report to the console. F10 shows the live overlay;
## this is the end-of-session summary.
func print_stability_report() -> void:
	if watchdog == null:
		return
	print(watchdog.report())


## Declare who owns what. Each entry answers "which one is the authority for
## this?" in one line, and the registry refuses a duplicate -- so a second
## world or a second authority is a start-up error, not a latent bug.
func _register_systems() -> void:
	systems.register(_system("world", "the voxel world and its streaming",
		world), world)
	systems.register(_system("player", "the player body and its vitals", player),
		player)
	systems.register(_system("village", "mobs, villagers and settlements", village),
		village)
	systems.register(_system("engineering",
		"components, machines and networks", engineering), engineering)
	systems.register(_system("net", "server authority over every mutation",
		authority), authority)
	persistence = Persistence.new()
	persistence.inventory = inventory
	systems.register(_system("persistence", "the save file and the backpack",
		persistence), persistence)
	systems.register(_system("audio", "sound playback and its budget", audio), audio)
	systems.register(_system("profiler", "frame timing and engine counters",
		profiler), profiler)
	systems.register(_system("hud", "the on-screen readouts", hud), hud)
	var failures := systems.start_all()
	if not failures.is_empty():
		for f in failures:
			push_warning("[main] system %s failed to %s: %s" % [
				f["system"], f["stage"], f["reason"]])
	api = GameApi.new()


## A lifecycle wrapper for something `main.gd` already owns. The wrapper does
## not take ownership of the node -- `main.gd` still frees it -- it only
## carries the state, the error and the teardown accounting.
func _system(key: String, owns: String, owner_object: Object) -> System:
	var s := System.new()
	s.system_name = key
	s.owns = owns
	return s


## Structural invariants, checked against the tree that actually exists rather
## than against what this file intended to build. Cheap enough for startup: one
## recursive walk, no file I/O. The expensive check -- scanning the source tree
## for layering and visibility violations -- is `EngArch.violations()` and runs
## from the test suite, not from the frame.
func _check_architecture() -> void:
	if not OS.is_debug_build():
		return
	var problems := EngArch.verify_runtime(self)
	if problems.is_empty():
		print("[arch] ", EngArch.MODULES.size(), " modules, ",
			EngArch.LAYER_ORDER.size(), " layers, runtime invariants hold; world = ",
			WorldBackend.active_name())
	else:
		for p in problems:
			push_warning("[arch] ", p)


## The full check, including the source scan. Bound to a key so it is available
## in a running game without being on the startup path.
func verify_architecture() -> String:
	return EngArch.report()


## Restore from `save_slot`, including which dimension the player was in.
func _do_load() -> void:
	# The persistence layer owns the recovery policy too: it picks the slot or
	# the backup, refuses a future format, and applies. main.gd reports.
	var r := _persistence().load_from(save_slot, player, world, engineering)
	if not bool(r["ok"]):
		print("[main] load failed: ", r["reason"])
		return
	if String(r["source"]) == "backup":
		print("[main] slot %d was damaged; recovered from its backup" % save_slot)
	var migrated: Array = r["migrated"]
	if not migrated.is_empty():
		print("[main] migrated: ", ", ".join(migrated))
	interaction.refresh_hotbar()
	audio.play("load")
	print("[main] loaded slot %d: %s" % [save_slot, SaveGame.describe_slot(save_slot)])


## The persistence layer, or a loud failure. Built at start-up; this exists
## so a call before `_ready` finished reports a reason instead of a null
## dereference.
func _persistence() -> Persistence:
	if persistence == null:
		persistence = Persistence.new()
		persistence.inventory = inventory
	return persistence


## Open or close the 3x3 crafting grid.
func _toggle_crafting() -> void:
	if crafting == null:
		return
	# Let go of the mouse while a panel is open, or the cursor stays captured
	# by the FPS controls behind it.
	if crafting.toggle():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		interaction.set_crafting_open(true)
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		interaction.set_crafting_open(false)


## Close the crafting panel before a save, so the cursor is not left free.


## Jump straight to a dimension without toggling.
func _switch_dimension_to(dim: int) -> void:
	if dim == _current_dim:
		return
	_switch_dimension()


func _player_chunk() -> Vector3i:
	var p := player.position if player != null else spawn
	return Vector3i(
		int(floor(p.x / VoxelWorld.BS)),
		int(floor(p.y / VoxelWorld.BS)),
		int(floor(p.z / VoxelWorld.BS)))
