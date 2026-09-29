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
	world.update_around(_player_chunk())
	# Keep the probe and fog volumes on the player: SDFGI traces through the
	# volume, so a volume left behind would bake probes for terrain the player
	# can no longer see.
	_follow_volumes()
	_collect_drops()
	if day_night_enabled and _current_dim == WorldGenerator.DIM_OVERWORLD:
		day_night.advance(delta)
	if _current_dim == WorldGenerator.DIM_OVERWORLD:
		village.update(player.position)
		# Respawn the player at their spawn point when they die outright.
		if not interaction.is_alive():
			player.health = player.max_health
			_place_on_surface()


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
			_do_craft()
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
func _talk_nearby() -> void:
	for node in get_tree().get_nodes_in_group("villagers"):
		var v := node as Villager
		if v != null and is_instance_valid(v) \
				and v.global_position.distance_to(player.global_position) < 4.0:
			print("[main] ", v.greet("Traveller"))
			audio.play_at("mob_idle", v.global_position)
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
func _do_save() -> void:
	if SaveGame.save_game(save_slot, player, inventory, world, _current_dim):
		audio.play("save")
		print("[main] saved to slot %d: %s" % [save_slot,
			SaveGame.describe_slot(save_slot)])
	else:
		print("[main] save failed: ", SaveGame.last_error)


## Restore from `save_slot`, including which dimension the player was in.
func _do_load() -> void:
	var data := SaveGame.load_slot(save_slot)
	if data.is_empty():
		print("[main] load failed: ", SaveGame.last_error)
		return
	var dim := SaveGame.dimension_of(data)
	if dim != _current_dim:
		_switch_dimension_to(dim)
	if not SaveGame.apply(data, player, inventory, world):
		print("[main] load incomplete: ", SaveGame.last_error)
		return
	interaction.refresh_hotbar()
	audio.play("load")
	print("[main] loaded slot %d: %s" % [save_slot, SaveGame.describe_slot(save_slot)])


## Craft the first recipe the player's own inventory can afford. The grid is
## their carried blocks, so this is a "craft from what I hold" shortcut; a real
## 3x3 grid UI is still missing.
func _do_craft() -> void:
	var doable := Crafting.available(inventory)
	if doable.is_empty():
		audio.play("craft_fail")
		print("[main] nothing craftable")
		return
	var recipe: Dictionary = doable[0]
	if Crafting.craft(inventory, recipe):
		audio.play("craft")
		interaction.refresh_hotbar()
		print("[main] crafted %s x%d" % [recipe["id"],
			int(recipe.get("count", 1))])
	else:
		audio.play("craft_fail")


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
