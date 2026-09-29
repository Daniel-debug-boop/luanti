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

var world: VoxelWorld
var player: Player
var hud: WorldHud
var spawner: MobSpawner
var village: Village
var interaction: PlayerInteraction
var day_night: DayNight
var _env_over: Environment
var _env_deeps: Environment
var _we: WorldEnvironment
var _sun: DirectionalLight3D
var _moon: DirectionalLight3D
var _deeps_ambience: DirectionalLight3D
var _current_dim := 0


func _ready() -> void:
	_setup_environment()

	world = VoxelWorld.new()
	world.name = "VoxelWorld"
	world.world_dir = world_dir
	world.view_radius = view_radius
	add_child(world)

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

	spawner = MobSpawner.new()
	spawner.name = "MobSpawner"
	spawner.world = world
	spawner.player = player
	add_child(spawner)

	interaction = PlayerInteraction.new()
	interaction.name = "Interaction"
	interaction.world = world
	interaction.player = player
	add_child(interaction)

	village = Village.new()
	village.name = "Village"
	village.world = world
	village.player = player
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
	add_child(hud)

	# Drop the player onto the terrain surface once the spawn chunk exists.
	_place_on_surface()

	world.update_around(_player_chunk())
	village.update(player.position)
	print("[main] ready in ", world.biome_name_at(
		Vector3i(int(spawn.x), int(spawn.y), int(spawn.z))), " biome")


func _place_on_surface() -> void:
	# The generator runs synchronously, so the spawn column is available now.
	var bx := int(floor(spawn.x))
	var bz := int(floor(spawn.z))
	var y := 48
	while y > 2 and not world.solid_at(Vector3i(bx, y, bz)):
		y -= 1
	player.position = Vector3(spawn.x, y + 1.6, spawn.z)


func _setup_environment() -> void:
	# --- Overworld: the DayNight node installs the HDRI sky onto this. ---
	_env_over = Environment.new()
	_env_over.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	_env_over.sky = sky
	_env_over.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	_env_over.ambient_light_energy = 1.0
	_env_over.fog_enabled = true
	_env_over.fog_density = 0.0012
	_env_over.fog_light_color = Color(0.65, 0.75, 0.88)
	_env_over.tonemap_mode = Environment.TONE_MAPPER_ACES
	_env_over.tonemap_white = 6.0
	_env_over.glow_enabled = true
	_env_over.glow_intensity = 0.35
	# SSAO makes the baked per-vertex occlusion read at chunk borders.
	_env_over.ssao_enabled = true
	_env_over.ssao_radius = 1.4
	_env_over.ssao_intensity = 1.6

	# --- The Deeps: dark cavern ambience ---
	_env_deeps = Environment.new()
	_env_deeps.background_mode = Environment.BG_COLOR
	_env_deeps.background_color = Color(0.02, 0.015, 0.03)
	_env_deeps.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env_deeps.ambient_light_color = Color(0.25, 0.2, 0.4)
	_env_deeps.ambient_light_energy = 0.5
	_env_deeps.fog_enabled = true
	_env_deeps.fog_density = 0.006
	_env_deeps.fog_light_color = Color(0.08, 0.05, 0.12)
	_env_deeps.tonemap_mode = Environment.TONE_MAPPER_ACES
	_env_deeps.glow_enabled = true
	_env_deeps.glow_intensity = 0.9
	_env_deeps.glow_bloom = 0.1

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


func _player_chunk() -> Vector3i:
	var p := player.position if player != null else spawn
	return Vector3i(
		int(floor(p.x / VoxelWorld.BS)),
		int(floor(p.y / VoxelWorld.BS)),
		int(floor(p.z / VoxelWorld.BS)))
