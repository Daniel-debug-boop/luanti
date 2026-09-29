class_name MobSpawner
extends Node3D
## Keeps a small population of mobs alive around the player.
##
## Spawns choose a random point on solid ground within the ring at radius
## 18..28 nodes from the player, despawn beyond 40, and respect a hard cap.
## The Deeps gets its own (glowing) palette.

const MOB_SCENE := preload("res://scripts/mobs/mob.gd")

@export var world: VoxelWorld
@export var player: Player
@export var max_mobs := 10
@export var spawn_interval := 2.5
## Optional: gives new mobs their sounds and a place to drop loot.
var audio: AudioDirector = null
var drops_parent: Node = null

var _timer := 0.0
var _mobs: Array[Mob] = []


func _ready() -> void:
	_timer = spawn_interval


func _process(delta: float) -> void:
	if world == null or player == null:
		return
	_timer -= delta
	if _timer <= 0.0:
		_timer = spawn_interval
		_try_spawn()

	# Despawn far or dead mobs.
	var i := _mobs.size() - 1
	while i >= 0:
		var m := _mobs[i]
		if not is_instance_valid(m) or not m.is_alive() \
				or m.global_position.distance_to(player.global_position) > 40.0:
			if is_instance_valid(m):
				m.queue_free()
			_mobs.remove_at(i)
		i -= 1


func _try_spawn() -> void:
	if _mobs.size() >= max_mobs:
		return
	var rng := RandomNumberGenerator.new()
	rng.randomize()

	# Pick a random surface point in a ring around the player.
	var angle := rng.randf_range(0.0, TAU)
	var dist := rng.randf_range(18.0, 28.0)
	var bx := int(floor(player.global_position.x + sin(angle) * dist))
	var bz := int(floor(player.global_position.z + cos(angle) * dist))

	# Find ground: scan down for the first solid block with air above.
	var y := 48
	while y > 2:
		if world.solid_at(Vector3i(bx, y, bz)) \
				and not world.solid_at(Vector3i(bx, y + 1, bz)) \
				and not world.solid_at(Vector3i(bx, y + 2, bz)):
			break
		y -= 1
	if y <= 2:
		return

	var mob := Mob.new()
	mob.world = world
	if world.dimension == WorldGenerator.DIM_DEEPS:
		mob.mob_color = Color(0.55, 0.35, 0.9)
		mob.max_health = 10.0
	else:
		# Overworld: a small natural palette.
		var palette := [
			Color(0.85, 0.62, 0.4),   # boar-ish
			Color(0.6, 0.62, 0.66),   # wolf-ish
			Color(0.75, 0.75, 0.7),   # sheep-ish
		]
		mob.mob_color = palette[rng.randi() % palette.size()]
		mob.max_health = 6.0
	mob.position = Vector3(bx + 0.5, y + 1.05, bz + 0.5)
	mob.audio = audio
	mob.model_seed = rng.randi()
	if drops_parent != null:
		mob.set_meta("drops_parent", drops_parent)
	add_child(mob)
	_mobs.append(mob)


func mob_count() -> int:
	return _mobs.size()
