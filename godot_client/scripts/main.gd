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
@export_enum("Low", "Medium", "High") var render_quality := 2
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
## Optional Voxel Tools backend. Null unless F8 successfully builds it, which
## only happens on the Voxel Tools engine build.
var zylann: ZylannWorld = null
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
	settings.quality = render_quality
	_setup_environment()

	world = VoxelWorld.new()
	world.name = "VoxelWorld"
	world.world_dir = world_dir
	world.view_radius = view_radius
	world.texture_mapping = texture_mapping
	add_child(world)

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

	# Drop the player onto the terrain surface once the spawn chunk exists.
	_place_on_surface()

	world.update_around(_player_chunk())
	village.update(player.position)
	print("[main] ready in ", world.biome_name_at(
		Vector3i(int(spawn.x), int(spawn.y), int(spawn.z))), " biome")
	print("[main] render: ", settings.describe())


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
		elif key == KEY_F8:
			_toggle_zylann()
		elif key == KEY_F1:
			set_render_quality(0)
		elif key == KEY_F2:
			set_render_quality(1)
		elif key == KEY_F3:
			set_render_quality(2)
		elif key == KEY_F4:
			set_texture_mapping(0)
		elif key == KEY_F5:
			set_texture_mapping(1)
		elif key == KEY_F6:
			set_texture_mapping(2)
		elif key == KEY_F7:
			set_texture_mapping(3)
		elif key == KEY_F10:
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


## Switch the render tier at runtime (0 low, 1 medium, 2 high).
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
	texture_mapping = m
	world.set_texture_mapping(m)
	print("[main] texture mapping: ",
		MaterialLibrary.mapping_name()[clampi(m, 0, 3)])


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
	# Sealed with a checksum and written over a backup, so a crash mid-save
	# costs at most the last save, never the world.
	var state := SaveGame.capture(player, inventory, world, _current_dim, engineering)
	state["version"] = SaveGame.SAVE_VERSION
	var why := SaveMigration.write_with_backup(save_slot, SaveMigration.seal(state))
	if why == "":
		audio.play("save")
		print("[main] saved to slot %d: %s" % [save_slot,
			SaveGame.describe_slot(save_slot)])
	else:
		print("[main] save failed: ", why)


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


## Restore from `save_slot`, including which dimension the player was in.
func _do_load() -> void:
	# The resilient reader falls back to the previous save when the current
	# one is truncated or spliced, and says which file it actually used.
	var read := SaveMigration.read_resilient(save_slot)
	if not bool(read["ok"]):
		print("[main] load failed: ", read["reason"])
		return
	var data: Dictionary = read["data"]
	if String(read["source"]) == "backup":
		print("[main] slot %d was damaged; recovered from its backup" % save_slot)
	var migrated := SaveMigration.migrate(data)
	if not bool(migrated["ok"]):
		print("[main] load refused: ", migrated["reason"])
		return
	data = migrated["data"]
	if not (migrated["steps"] as Array).is_empty():
		print("[main] migrated: ", ", ".join(migrated["steps"]))
	var dim := SaveGame.dimension_of(data)
	if dim != _current_dim:
		_switch_dimension_to(dim)
	if not SaveGame.apply(data, player, inventory, world, engineering):
		print("[main] load incomplete: ", SaveGame.last_error)
		return
	interaction.refresh_hotbar()
	audio.play("load")
	print("[main] loaded slot %d: %s" % [save_slot, SaveGame.describe_slot(save_slot)])


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


## Build (or tear down) the Voxel Tools backend. Only the official Voxel Tools
## engine build has the module, so this reports why and does nothing otherwise.
func _toggle_zylann() -> void:
	if zylann != null and is_instance_valid(zylann):
		zylann.save()
		zylann.queue_free()
		zylann = null
		audio.play("ui_back")
		print("[main] Voxel Tools backend off")
		return
	if not ZylannWorld.is_available():
		audio.play("craft_fail")
		print("[main] ", ZylannWorld.unavailable_reason())
		return
	var z := ZylannWorld.new()
	z.name = "ZylannWorld"
	add_child(z)
	var cam := get_node_or_null("Player/Camera") as Camera3D
	if cam == null or not z.setup(cam):
		z.queue_free()
		print("[main] ", ZylannWorld.unavailable_reason())
		return
	zylann = z
	audio.play("level_up")
	print("[main] Voxel Tools backend on: ", z.get_stats())


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
