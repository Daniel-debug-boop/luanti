extends Node3D
## Assembles the world, player, mobs, village, sky, interaction and HUD, and
## drives streaming.

## Loaded by path: the Terrain3D layer must resolve in a build whose global
## class cache has not seen it yet, and an editor pass is not part of running
## the game.
const TerrainLayerScript := preload("res://scripts/world/terrain_layer.gd")

## Converted chunk directory. Empty = auto-detect; when absent, terrain is
## generated procedurally.
@export var world_dir := ""
@export var view_radius := 5
## Node coordinates. The player is dropped onto the surface at this column.
@export var spawn := Vector3(8.5, 40.0, 8.5)
## Turn the day/night clock off to hold the sun still.
@export var day_night_enabled := true
## RenderSettings.Quality: 0 low, 1 medium, 2 high (SSIL, SDFGI, volumetric fog),
## 3 ultra (adds parallax occlusion, which is ULTRA-only by POM_QUALITY).
@export_enum("Low", "Medium", "High", "Ultra") var render_quality := 2
## Hand the quality tier to the adaptive controller. Off means the tier stays
## whatever it was set to, which is what the render test and any measurement
## run needs: a benchmark that silently changes quality halfway through is
## measuring two different configurations and reporting one number.
@export var adaptive_quality := true
## How block textures are projected. Godot cannot combine triplanar mapping
## with parallax occlusion, so this picks one:
##   0 plain (box UVs) · 1 triplanar · 2 parallax occlusion (POM)
##   3 stochastic triplanar (vendored shader, breaks up texture tiling)
##   4 slope blending: 3, plus grass on level ground and rock on the walls for
##     the blocks that have a top/side pair. Blocks without one are unchanged.
## F4 cycles all five, and the list is driven by MaterialLibrary.mapping_name().
@export_enum("Plain", "Triplanar", "Parallax", "Stochastic", "Slope") var texture_mapping := 2

var world: VoxelWorld
## The Terrain3D ground layer, present only under `--terrain3d`. See
## `_setup_terrain_layer`.
var terrain_layer: Node3D = null
## Set once the terrain layer has reported what it built this session.
var _terrain_reported := false
var player: Player
var hud: WorldHud
## Developer diagnostics, off until F10. Never part of the player's view.
var debug_overlay: DebugOverlay
## The options menu, opened with O.
var options: SettingsMenu
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

## The emergent gameplay layer. It derives capabilities, relationships,
## patterns, behaviours and causal consequences from what the engineering
## layer already built, and it owns exactly one instance -- two would tick the
## same events and a golf hole would score twice.
var emergent: EmergentSystem = null

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

## `--render-test` state. The config is parsed before the scene is built so a
## bad flag fails immediately rather than after a minute of world generation.
var _render_test_config := {}
var _render_test_wanted := false

## Adaptive rendering. Owns the quality tier unless the player picks one.
var adaptive: AdaptiveQuality = null


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

	# `--render-test` is a mode, not a different game. The whole scene is
	# assembled exactly as it is below either way; the only differences are
	# that the world is seeded deterministically and a RenderTest is handed
	# the finished scene to drive. Reading the flag here rather than
	# branching around the scene means normal play cannot drift away from
	# what the benchmark measures.
	var rt := RenderTest.parse_args(_user_args())
	# parse_args returns {"error": ""} when the mode was not asked for, a
	# config with "enabled" when it was, and {"error": "..."} on a bad flag.
	# Three cases, so they are distinguished by shape rather than by guessing
	# at an empty string.
	if rt.has("error") and not str(rt.get("error", "")).is_empty():
		push_error("[main] --render-test: %s" % str(rt["error"]))
		get_tree().quit(RenderTest.ERR_USAGE)
		return
	if rt.has("enabled"):
		_render_test_config = rt
		_render_test_wanted = true

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
	_setup_terrain_layer()
	# The world is deterministic already (the generator is seeded with a
	# constant in VoxelWorld._ready), but the benchmark states the seed it
	# used and honours a caller-supplied one, so two runs on different
	# machines are comparable.
	if _render_test_wanted:
		world.generator = WorldGenerator.new(
			int(_render_test_config.get("seed", RenderTest.SEED)))

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

	# The emergent layer, pointed at the SAME engineering graph rather than
	# a second one. It has no component model of its own: a zone is an entity,
	# a motor is still the engineering layer's motor, and everything the
	# layer claims about a machine is derived from the graph that actually
	# simulates it.
	#
	# It is a `System`, not a Node, so it is registered rather than parented --
	# the same treatment the authority gets. It must not be a child of main,
	# because its tick order relative to the engineering simulation is
	# explicit (engineering first, then emergent) and a node child would put
	# it in Godot's process order instead of ours.
	emergent = EmergentSystem.new()
	emergent.world = world

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
	# The host is a peer like any other: it joins, and its own commands go
	# through the same gate a remote player's do. `GameApi.request` reaches
	# this through `submit_local`, so single player is an exemption from
	# nothing -- and a build that adds a UI verb cannot forget to wire it,
	# because the only entry point the API offers is already inside the gate.
	authority.join(NetAuthority.HOST_PEER, "host", Vector3.ZERO,
		float(Time.get_ticks_msec()) / 1000.0)
	authority.set_local_applier(func(cmd: Dictionary) -> Variant:
		return emergent.apply_host(cmd))

	audio = AudioDirector.new()
	audio.name = "Audio"
	add_child(audio)

	_drops = Node3D.new()
	_drops.name = "Drops"
	add_child(_drops)

	player = Player.new()
	player.name = "Player"
	player.world = world
	# The player's respawn point, so a fatal fall returns them to the same
	# place they started rather than to a hardcoded default that happens to
	# match today.
	player.spawn = spawn
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
	# The emergent layer, as a listener for what the player did. Interaction
	# still does not know what any of it means.
	interaction.emergent = emergent
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

	# Developer diagnostics live in their own overlay, off until F10. The
	# gameplay HUD carries nothing a player should not see.
	debug_overlay = DebugOverlay.new()
	debug_overlay.player = player
	debug_overlay.world = world
	debug_overlay.spawner = spawner
	debug_overlay.village = village
	debug_overlay.interaction = interaction
	debug_overlay.settings = settings
	hud.debug_overlay = debug_overlay

	# The options menu reads the live settings rather than keeping a copy, so
	# a function-key change and a menu change can never disagree.
	options = SettingsMenu.new()
	options.name = "SettingsMenu"
	options.quality_requested.connect(set_render_quality)
	options.mapping_requested.connect(set_texture_mapping)
	options.sync_from(render_quality, texture_mapping)

	crafting = CraftingPanel.new()
	crafting.name = "CraftingPanel"
	add_child(crafting)
	crafting.setup(inventory, audio)
	add_child(hud)
	add_child(options)

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
	print("[main] ", _version_string(), " ready in ", world.biome_name_at(
		Vector3i(int(spawn.x), int(spawn.y), int(spawn.z))), " biome")
	print("[main] render: ", settings.describe())
	_register_systems()
	devtools = DevTools.new()
	devtools.name = "DevTools"
	add_child(devtools)
	devtools.attach(self, api)
	# Adaptive rendering starts from whatever tier the project asks for and
	# takes over from there. The player can pin it at any time with F1-F3.
	adaptive = AdaptiveQuality.new()
	adaptive.tier = render_quality
	adaptive.enabled = adaptive_quality
	# Last, once every singleton exists: the structural invariants describe
	# the tree that was actually built, not the one we intended to build.
	_check_architecture()

	# Only now, with the whole scene assembled, does the render test take
	# over. It drives the same nodes the player would.
	if _render_test_wanted:
		# A benchmark must not have its configuration changed underneath it.
		adaptive_quality = false
		if adaptive != null:
			adaptive.enabled = false
		_start_render_test()


## Hand the finished scene to the benchmark and let it drive.
## The build's own name, for the ready line and the dev panel. It comes from
## project.godot, which tools/build_release.sh stamps from the repository's
## VERSION_LUANTIVOXEL before exporting -- so the archive a player downloads
## and the version the game prints are the same string, and a bug report can
## name a build without anyone having to guess which one.
func _version_string() -> String:
	var v := String(ProjectSettings.get_setting(
		"application/config/version", ""))
	return "LuantiVoxel %s" % (v if v != "" else "dev")


func _start_render_test() -> void:
	var rt := RenderTest.new()
	rt.name = "RenderTest"
	add_child(rt)
	rt.world = world
	rt.player = player
	rt.hud = hud
	rt.debug_overlay = debug_overlay
	# The benchmark camera is not the player, so the fog volume and the
	# bounce probes -- which follow the player every frame -- have to be
	# re-anchored on the camera or the captures are shot through fog that
	# should not be there.
	rt.follow_volumes = _follow_volumes_at
	rt.apply_render_settings = set_render_settings
	rt.apply_stage = apply_render_stage
	# The player is a first-person body whose camera would fight the
	# benchmark's; the render test owns `current` for the duration.
	var pc := player.get_node_or_null("Camera") as Camera3D
	if pc != null:
		pc.current = false
	var code := rt.start(_render_test_config)
	if code != RenderTest.OK:
		get_tree().quit(code)


## Command-line arguments meant for the game.
##
## Godot splits `OS.get_cmdline_args()` (everything, including engine flags)
## from `OS.get_cmdline_user_args()` (only what follows a bare `--`). Both
## are read so the mode works whether or not the caller remembered the
## separator, and engine flags we do not own are filtered out.
func _user_args() -> PackedStringArray:
	var out := PackedStringArray()
	var known := [
		"--render-test", "--scene", "--resolution", "--frames",
		"--warmup-frames", "--output", "--camera", "--all-cameras",
		"--no-ui", "--capture-every", "--allow-software",
		"--no-gpu-validation", "--effects", "--stage"
	]
	for a in OS.get_cmdline_args():
		if a.begins_with("--") and (known.has(a) or _takes_value(a)):
			out.append(a)
	for a in OS.get_cmdline_user_args():
		out.append(a)
	return out


## True for the render-test options that consume the following argument.
func _takes_value(a: String) -> bool:
	return a in ["--scene", "--resolution", "--frames", "--warmup-frames",
		"--output", "--camera", "--capture-every", "--effects", "--stage"]


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


## Terrain3D ground rendering, for an authoritative converted world.
##
## Opt-in, with `--terrain3d` (or `-- --terrain3d`), and deliberately so:
## this mode changes who draws the ground surface. The voxel world is still
## the world -- collision, digging, caves, buildings and roads are all
## untouched -- but the ground the player walks on is drawn by Terrain3D with
## its own LOD and materials, fed from the same Arnis chunks, and the voxel
## mesher stops drawing the upward faces of ground blocks it has handed over.
## A refusal (no addon, no converted world, no manifest) leaves the game
## running exactly as it did without the flag.
func _setup_terrain_layer() -> void:
	var asked := OS.get_cmdline_args().has("--terrain3d") \
		or OS.get_cmdline_user_args().has("--terrain3d")
	if not asked:
		return
	var layer: Node3D = TerrainLayerScript.new()
	layer.name = "TerrainLayer"
	layer.world_dir = world_dir
	var refusal: String = layer.configure()
	if refusal != "":
		push_warning("[main] --terrain3d refused: %s" % refusal)
		layer.free()
		return
	add_child(layer)
	layer.attach_world(world)
	world.set_ground_layer(layer)
	terrain_layer = layer
	# One line of runtime evidence that the layer is live and what it is
	# drawing from, in the same spirit as the material report VoxelWorld
	# prints. A flag that silently did nothing would otherwise look identical
	# to a flag that worked.
	print("[main] terrain3d: ", layer.describe())


func _process(delta: float) -> void:
	if world == null or player == null:
		return
	_update_adaptive_quality(delta)
	profiler.begin("world")
	world.update_around(_player_chunk())
	if terrain_layer != null:
		terrain_layer.update_around(player.global_position)
		if not _terrain_reported:
			# Reported after the first streaming tick rather than at setup, so
			# the line shows what the layer actually built -- a setup-time
			# report of zero regions is indistinguishable from a layer that
			# never streams anything.
			_terrain_reported = true
			print("[main] terrain3d: ", terrain_layer.describe())
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
	if emergent != null:
		# Fed, not ticked. The player is what the layer can sense; it is
		# handed the position rather than searching the world for it, because
		# "what is alive in this world" is the game's question. The tick
		# itself belongs to the registry, below, so it happens exactly once.
		emergent.attach_to(engineering.graph)
		emergent.observe([player.position], player.position)
		emergent.authority = authority
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
			# mapping modes were already on their own key. A player-driven
			# switch pins the tier, so the adaptive controller stops
			# overriding the choice they just made.
			set_render_quality(3 if event.shift_pressed else 0, true)
		elif key == KEY_F2:
			set_render_quality(1, true)
		elif key == KEY_F3:
			set_render_quality(2, true)
		elif key == KEY_F4:
			# F4 cycles the block texture mapping rather than claiming a key
			# per mode. Four modes on four keys put a mode on F5, and F5 is
			# save -- one of them was silently unreachable.
			_cycle_texture_mapping(1 if event.shift_pressed else -1)
		elif key == KEY_F10:
			# Developer diagnostics: fps, coordinates, chunk and effect state.
			# Off by default and never part of the player's view.
			var dbg_on := false
			if debug_overlay != null:
				dbg_on = debug_overlay.toggle()
			if devtools != null:
				devtools.toggle()
			print("[main] debug overlay %s"
				% ("on" if dbg_on else "off"))
		elif key == KEY_O:
			if options != null:
				options.toggle()
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
	_follow_volumes_at(player.global_position)


## Move the fog volume and the bounce-probe ring to an arbitrary point.
## Split out from `_follow_volumes` so the render test can aim them at its
## own camera, which is somewhere the player never goes.
## Feed the frame time to the adaptive controller and apply any change it
## makes.
##
## Sampled on an interval rather than every frame: the controller's windows
## are seconds long, so sampling at frame rate would just burn CPU producing
## identical conclusions.
func _update_adaptive_quality(delta: float) -> void:
	if adaptive == null or not adaptive.enabled:
		return
	_adaptive_accum += delta
	if _adaptive_accum < ADAPTIVE_SAMPLE_SECONDS:
		return
	var elapsed := _adaptive_accum
	_adaptive_accum = 0.0
	# Wall-clock frames per second over the window rather than the last
	# frame's delta: one hitch is not a trend, and the controller needs the
	# trend. `delta` here is the process frame time, which excludes GPU work
	# the CPU waited on, so this is a CPU-side measure and is labelled as one
	# rather than being passed off as frame time.
	var frames := Engine.get_frames_drawn() - _adaptive_last_frame
	_adaptive_last_frame = Engine.get_frames_drawn()
	if frames <= 0:
		return
	var ms := (elapsed / float(frames)) * 1000.0
	var tier := adaptive.observe(ms, Time.get_ticks_msec() / 1000.0, elapsed)
	if tier < 0:
		return
	print("[adaptive] tier %d: %s (%.1f ms)" % [tier, adaptive.last_reason, ms])
	set_render_quality(tier)


## How often the adaptive controller is consulted. Well under its 4 s confirm
## window, so the sampling rate does not affect its decisions.
const ADAPTIVE_SAMPLE_SECONDS := 0.5
var _adaptive_accum := 0.0
var _adaptive_last_frame := 0


func _follow_volumes_at(p: Vector3) -> void:
	if _fog_volume != null:
		_fog_volume.position = p
	settings.place_probes(p)


## Isolate one layer of the rendering pipeline, for `--render-test --stage`.
##
## This deliberately reuses the live Environment objects and lights rather
## than building parallel ones: a diagnostic that renders through different
## objects than the game would tell you about the diagnostic. The baseline
## stages strip every effect off the same environments the game uses, so what
## is left is geometry and materials alone.
func apply_render_stage(s: int) -> void:
	var want := RenderDiagnostics.stage_settings(s)
	# Each stage is independent, so the previous stage's overrides must go
	# first. Without this, walking 0 -> 1 -> 2 leaves the unlit flag from
	# stage 0 set, and every later stage silently renders the baseline.
	world.materials.clear_diagnostics()
	# Environment first: an effect left on will contaminate the stages that
	# are supposed to be clean even if the lights are switched off.
	RenderDiagnostics.apply_overrides(_env_over,
		want.get("env_over", {}) as Dictionary)
	RenderDiagnostics.apply_overrides(_env_deeps,
		want.get("env_deeps", {}) as Dictionary)
	var want_we := bool(want.get("world_environment", true))
	# WorldEnvironment has no `visible` property -- a Node3D does, but this is
	# a plain Node. The way to remove its influence is to hand it a neutral
	# environment rather than to hide it.
	if _we != null:
		_we.environment = _env_over if want_we \
			else RenderDiagnostics.make_clean_environment(true)
	var want_lights := bool(want.get("lights", true))
	for l in [_sun, _moon, _deeps_ambience]:
		var light := l as Node
		if light != null:
			light.set("visible", want_lights and light == _sun)
	# The fog volume and probes are atmosphere, so they only exist from the
	# environment stage onward.
	var atmo := s >= RenderDiagnostics.Stage.ENVIRONMENT
	if _fog_volume != null:
		_fog_volume.visible = atmo
	for p in _probes:
		var probe := p as Node
		if probe != null:
			probe.set("visible", atmo)
	# Order matters here. The mapping switch reconfigures the shared
	# materials, and the diagnostic overrides configure the same object, so
	# the overrides have to be applied AFTER the mapping switch. Applied
	# before, set_texture_mapping's own override calls silently undo them and
	# every stage renders the baseline instead of itself.
	_apply_stage_materials(int(want.get("material_mode", 0)))
	# An unlit material ignores lights entirely, which is what makes stage 0
	# a pure geometry test.
	world.set_unlit(bool(want.get("unlit", false)))
	world.set_normal_debug(bool(want.get("normal_debug", false)))
	# "flat colour, no texture" is the difference between stage 0 and stage 1:
	# stage 0 must show geometry alone, stage 1 the real albedo on it.
	world.set_material_override(
		int(want.get("material_mode", 0)) == 0 and s == RenderDiagnostics.Stage.ALBEDO)
	# DayNight writes the sun every frame; it has to stand down or it will
	# undo the light switching above on the next tick.
	if day_night != null:
		day_night.set_process(false)
		if _sun != null and want_lights:
			_sun.rotation_degrees = Vector3(-55.0, -35.0, 0.0)


## material_mode: 0 flat untextured, 1 the real textured material,
## 2 POM/stochastic mapping, 3 whatever the quality tier picked.
##
## Only the mapping is decided here. The diagnostic overrides are applied by
## the caller afterwards, because this function reconfigures the same
## materials and would otherwise clear them.
func _apply_stage_materials(mode: int) -> void:
	match mode:
		0:
			world.set_texture_mapping(0)
		1:
			world.set_texture_mapping(0)
		2:
			world.set_texture_mapping(2)
		_:
			world.set_texture_mapping(texture_mapping)


## Set the render tier and the texture mapping together, then rebind the
## materials. The render test uses this to pick its effect preset; it is the
## same path the F1 key and the settings menu go through, so a baseline
## capture exercises the shipping configuration code rather than a
## benchmark-only one.
func set_render_settings(quality: int, mapping: int) -> void:
	render_quality = clampi(quality, 0, 2)
	# Bound by the mapping table, not by a literal. A hard 0..3 here silently
	# rewrote the slope mapping to stochastic, so a caller asking for slope got
	# a different material and no indication that it had been overruled.
	texture_mapping = clampi(mapping, 0,
			MaterialLibrary.mapping_name().size() - 1)
	settings.set_quality(render_quality, world.materials,
		[_env_over, _env_deeps] as Array[Environment])
	world.set_texture_mapping(texture_mapping)
	world.rebind_materials()
	if options != null:
		options.sync_from(render_quality, texture_mapping)


## Switch the render tier at runtime (0 low, 1 medium, 2 high, 3 ultra).
##
## `by_player` marks a deliberate choice, which pins the tier and stops the
## adaptive controller from overriding it. Without that, pressing F3 and
## then having the machine drop back to LOW a few seconds later looks like
## the game ignoring the player.
func set_render_quality(q: int, by_player := false) -> void:
	if by_player and adaptive != null:
		adaptive.pin(q)
	render_quality = q
	settings.set_quality(q, world.materials,
		[_env_over, _env_deeps] as Array[Environment])
	world.rebind_materials()
	if options != null:
		options.sync_from(render_quality, texture_mapping)
	print("[main] render: ", settings.describe())


## Switch between plain box UVs, triplanar projection, and parallax occlusion.
## Godot silently discards the heightmap when triplanar is on, so the two
## cannot be combined; this replaces one with the other.
func set_texture_mapping(m: int) -> void:
	var names := MaterialLibrary.mapping_name()
	# Clamped rather than assigned directly: `world.set_texture_mapping` would
	# index the mode table with an out-of-range value from a caller that
	# computed it by hand, and F4's wrap is the only thing that should produce
	# a value outside 0..3.
	texture_mapping = clampi(m, 0, names.size() - 1)
	world.set_texture_mapping(texture_mapping)
	if options != null:
		options.sync_from(render_quality, texture_mapping)
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
		engineering, emergent)
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
	# Registered, not parented, and ticked by the registry rather than by hand
	# below. It was previously ticked explicitly AND registered, which meant
	# two ticks a frame -- the emergent layer's own rule is that a golf hole
	# scoring twice is a bug, and the composition root was committing it.
	# `emergent` ordering places it after engineering in `run_order`, which is
	# the dependency that matters: relationships are derived from a machine
	# graph the engineering layer has already rebuilt this frame.
	systems.register(_system("emergent",
		"capabilities, patterns and causal rules over that world", emergent),
		emergent)
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


## The lifecycle handle for something `main.gd` already owns, ready to register.
##
## If the owner IS a `System` -- the emergent layer and the persistence layer
## both are -- it registers as itself, so the registry drives the real object's
## `initialize()`, `run()` and `tick()` and tears down the real object's
## resources. It used to be wrapped unconditionally, which was invisible and
## total: the wrapper carried the state while the layer behind it was never
## initialized and never ticked. `EmergentSystem.graph` and `.causal` stayed
## null for the whole session, so a player's first swing hit
## `entities_near in base 'Nil'` and the first save hit `serialize in base
## 'Nil'` -- and the entire emergent layer, the golf holes and causal rules the
## architecture document is built around, silently did nothing in the shipped
## game while every test that constructed the layer itself passed.
##
## A node that is not a `System` (the world, the player, the village) still
## gets a wrapper: there is nothing else for the registry to drive, and the
## wrapper carries the state, the error and the teardown accounting without
## taking ownership -- `main.gd` still frees the node.
func _system(key: String, owns: String, owner_object: Object) -> System:
	var s: System
	if owner_object is System:
		s = owner_object as System
	else:
		s = System.new()
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
	var r := _persistence().load_from(save_slot, player, world, engineering,
		emergent)
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
