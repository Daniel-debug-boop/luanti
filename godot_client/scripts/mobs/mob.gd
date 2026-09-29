class_name Mob
extends Node3D
## A creature with wander/chase AI that collides against the voxel field.
##
## Movement is resolved per-axis against solid voxels, reusing the same rule
## as the player: a step is rejected if the mob's AABB would overlap a solid
## node. One-block steps are auto-jumped when walking into terrain.

const WIDTH := 0.7
const HEIGHT := 0.9
const SPEED_WANDER := 1.6
const SPEED_CHASE := 3.4
const JUMP := 7.0
const GRAVITY := 22.0

enum State { IDLE, WANDER, CHASE, FLEE }

@export var world: VoxelWorld
@export var mob_color := Color(0.85, 0.3, 0.25)
@export var max_health := 6.0

var state: int = State.IDLE
var velocity := Vector3.ZERO
var health := 6.0
var _target: Node3D
var _wander_dir := Vector3.ZERO
var _state_timer := 0.0
var _jump_cooldown := 0.0
var _mesh: MeshInstance3D
var _on_ground := false
## How long since the last hit, so the mesh can flash.
var _hurt_flash := 0.0


func _ready() -> void:
	add_to_group("mobs")
	health = max_health
	_mesh = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(WIDTH, HEIGHT, WIDTH)
	_mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = mob_color
	mat.roughness = 0.7
	_mesh.material_override = mat
	add_child(_mesh)

	# Simple eyes so facing direction reads at a glance.
	var eye_mesh := MeshInstance3D.new()
	var eye := SphereMesh.new()
	eye.radius = 0.07
	eye.height = 0.14
	eye_mesh.mesh = eye
	eye_mesh.position = Vector3(0, HEIGHT * 0.6, -WIDTH * 0.4)
	var em := StandardMaterial3D.new()
	em.albedo_color = Color(0.05, 0.05, 0.05)
	em.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	eye_mesh.material_override = em
	add_child(eye_mesh)


func _physics_process(delta: float) -> void:
	_state_timer -= delta
	_jump_cooldown -= delta
	_hurt_flash = maxf(0.0, _hurt_flash - delta)
	if _mesh != null and _hurt_flash > 0.0:
		_mesh.scale = Vector3.ONE * (1.0 + _hurt_flash * 0.4)

	_think(delta)
	_apply_gravity(delta)
	_integrate(delta)
	_update_visuals()


func _think(delta: float) -> void:
	if _state_timer <= 0.0:
		_pick_state()

	if _target != null and is_instance_valid(_target):
		var to_t := _target.global_position - global_position
		if to_t.length() > 14.0:
			_target = null
			state = State.WANDER

	match state:
		State.WANDER:
			velocity.x = _wander_dir.x * SPEED_WANDER
			velocity.z = _wander_dir.z * SPEED_WANDER
		State.CHASE:
			if _target != null and is_instance_valid(_target):
				var d := _target.global_position - global_position
				velocity.x = d.normalized().x * SPEED_CHASE
				velocity.z = d.normalized().z * SPEED_CHASE
			else:
				state = State.IDLE
		State.FLEE:
			if _target != null and is_instance_valid(_target):
				var d := global_position - _target.global_position
				velocity.x = d.normalized().x * SPEED_CHASE
				velocity.z = d.normalized().z * SPEED_CHASE
			else:
				state = State.WANDER
		_:
			velocity.x = 0.0
			velocity.z = 0.0


func _pick_state() -> void:
	_state_timer = _rng().randf_range(1.5, 4.0)
	var r := _rng().randf()
	if r < 0.35:
		state = State.IDLE
		velocity.x = 0.0
		velocity.z = 0.0
	elif r < 0.9:
		state = State.WANDER
		var a := _rng().randf_range(0.0, TAU)
		_wander_dir = Vector3(sin(a), 0.0, cos(a))
	else:
		state = State.WANDER


## Called by the player interacting with the mob.
func set_target(t: Node3D, chase := true) -> void:
	_target = t
	state = State.CHASE if chase else State.FLEE
	_state_timer = 4.0


func _apply_gravity(delta: float) -> void:
	velocity.y = maxf(velocity.y - GRAVITY * delta, -30.0)


func _integrate(delta: float) -> void:
	# Auto-jump when walking into a one-block step.
	if _on_ground and _blocked_ahead():
		if _jump_cooldown <= 0.0 and _can_stand_at(
				global_position + Vector3(0, 1.05, 0)):
			velocity.y = JUMP
			_jump_cooldown = 0.6

	var step := velocity * delta
	_on_ground = false
	_try_axis(Vector3(step.x, 0, 0))
	_try_axis(Vector3(0, step.y, 0))
	_try_axis(Vector3(0, 0, step.z))


func _blocked_ahead() -> bool:
	var dir := Vector3(velocity.x, 0, velocity.z)
	if dir.length() < 0.05:
		return false
	var probe := global_position + dir.normalized() * (WIDTH * 0.5 + 0.15)
	return _box_blocked(probe)


func _try_axis(delta_v: Vector3) -> void:
	if delta_v == Vector3.ZERO:
		return
	var next := global_position + delta_v
	if not _box_blocked(next):
		global_position = next
		return
	# Binary-search up to the contact point.
	var lo := 0.0
	var hi := 1.0
	for _i in 8:
		var mid := (lo + hi) * 0.5
		if not _box_blocked(global_position + delta_v * mid):
			lo = mid
		else:
			hi = mid
	global_position += delta_v * lo
	if absf(delta_v.x) > 0.0:
		velocity.x = 0.0
	elif delta_v.y < 0.0:
		_on_ground = true
		velocity.y = 0.0
	else:
		velocity.z = 0.0


## True when the mob's AABB at `pos` overlaps a solid voxel.
func _box_blocked(pos: Vector3) -> bool:
	if world == null:
		return false
	var half := WIDTH * 0.5
	var min_x := int(floor(pos.x - half))
	var max_x := int(floor(pos.x + half))
	var min_y := int(floor(pos.y))
	var max_y := int(floor(pos.y + HEIGHT))
	var min_z := int(floor(pos.z - half))
	var max_z := int(floor(pos.z + half))
	for x in range(min_x, max_x + 1):
		for y in range(min_y, max_y + 1):
			for z in range(min_z, max_z + 1):
				if world.solid_at(Vector3i(x, y, z)):
					return true
	return false


## True when the mob can stand with its feet at `pos.y`.
func _can_stand_at(pos: Vector3) -> bool:
	return not _box_blocked(pos + Vector3(0, HEIGHT * 0.5, 0))


func _update_visuals() -> void:
	if absf(velocity.x) + absf(velocity.z) > 0.1:
		rotation.y = atan2(velocity.x, velocity.z)


## Swap the body box for a different size and colour, used when a mob is
## spawned with a species-specific look.
func set_body_size(size: Vector3, col: Color) -> void:
	if _mesh == null:
		return
	var box := _mesh.mesh as BoxMesh
	if box != null:
		box.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = 0.7
	_mesh.material_override = mat


func apply_damage(n: float) -> void:
	health -= n
	_hurt_flash = 0.3
	if _mesh != null:
		_mesh.scale = Vector3.ONE * 1.12
	if health <= 0.0:
		queue_free()


func is_alive() -> bool:
	return health > 0.0


func _rng() -> RandomNumberGenerator:
	# Per-instance RNG, seeded once.
	if not has_meta("rng"):
		var r := RandomNumberGenerator.new()
		r.randomize()
		set_meta("rng", r)
	return get_meta("rng")
