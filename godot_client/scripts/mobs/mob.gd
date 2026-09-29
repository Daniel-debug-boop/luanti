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
## Optional AudioDirector for hurt/death sounds. Not required, so tests can
## build a mob without one.
var audio: AudioDirector = null
## Stable seed so a mob keeps the same model between frames and across saves.
@export var model_seed := 0

## Body model from the CC0 KayKit skeleton pack. Null falls back to the box.
var _model: Node3D = null
## Recomputed at most this often, because A* over a busy grid is not free.
const REPATH_INTERVAL := 0.6
var _repath_timer := 0.0
var _path: Array[Vector3i] = []
var _path_index := 0

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
	if model_seed == 0:
		model_seed = randi()
	_build_body()
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
	eye_mesh.visible = _model == null
	add_child(eye_mesh)


## Attach a CC0 KayKit skeleton. Falls back to the primitive box body when the
## model is missing, so the mob is never invisible.
func _build_body() -> void:
	var path := CreatureModels.pick(CreatureModels.MOB_MODELS, model_seed)
	_model = CreatureModels.spawn(path, HEIGHT * 1.15, mob_color)
	if _model != null:
		add_child(_model)


func _physics_process(delta: float) -> void:
	_state_timer -= delta
	_jump_cooldown -= delta
	_hurt_flash = maxf(0.0, _hurt_flash - delta)
	_repath_timer = maxf(0.0, _repath_timer - delta)
	var target := _model if _model != null else _mesh
	if target != null and _hurt_flash > 0.0:
		target.scale = Vector3.ONE * (1.0 + _hurt_flash * 0.4)

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
				var d := _follow_path(delta, _target.global_position)
				velocity.x = d.x * SPEED_CHASE
				velocity.z = d.z * SPEED_CHASE
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


## Steer toward `goal_pos` using A* when possible, and fall back to a straight
## line when no route is found. Returns a unit XZ direction.
func _follow_path(delta: float, goal_pos: Vector3) -> Vector3:
	var here := Vector3i(floori(global_position.x), floori(global_position.y),
		floori(global_position.z))
	var goal := Vector3i(floori(goal_pos.x), floori(goal_pos.y), floori(goal_pos.z))

	if _repath_timer <= 0.0 or _path.is_empty():
		_repath_timer = REPATH_INTERVAL
		_path = Pathfinder.find_path(world, here, goal, 2)
		_path_index = 0

	var direct := Vector3(goal_pos.x - global_position.x, 0.0,
		goal_pos.z - global_position.z)
	# Close enough to just walk at it; repathing every frame would be wasteful.
	if direct.length() < 2.0:
		return direct.normalized() if direct.length() > 0.001 else Vector3.ZERO

	if _path_index < _path.size():
		var node := _path[_path_index]
		var to_node := Vector3(float(node.x) + 0.5 - global_position.x, 0.0,
			float(node.z) + 0.5 - global_position.z)
		if to_node.length() < 0.6:
			_path_index += 1
		elif to_node.length() > 0.001:
			return to_node.normalized()
	return direct.normalized() if direct.length() > 0.001 else Vector3.ZERO


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
	var body := _model if _model != null else _mesh
	if body != null:
		body.scale = Vector3.ONE * 1.12
	if audio != null:
		audio.play_at("mob_hurt" if is_alive() else "pickup", global_position)
	if health <= 0.0:
		_drop_loot()
		queue_free()


## Drop a couple of blocks where the mob died, so killing something is worth
## something. Deterministic per mob, so a mob always drops the same thing.
func _drop_loot() -> void:
	if world == null or not is_instance_valid(world):
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = model_seed
	var block_id := ContentDB.get_entry(
		1 + rng.randi_range(0, 3)).id
	for _i in 2:
		BlockDrop.spawn(_drops_parent(), world, block_id,
			global_position + Vector3(rng.randf_range(-0.4, 0.4), 0.4,
				rng.randf_range(-0.4, 0.4)))


## Where BlockDrops should be parented. The spawner passes a dedicated node so
## drops do not inherit the mob's transform; without one, fall back to the
## mob's own parent.
func _drops_parent() -> Node:
	if has_meta("drops_parent"):
		var p = get_meta("drops_parent")
		if p != null and is_instance_valid(p):
			return p
	return get_parent()


func is_alive() -> bool:
	return health > 0.0


func _rng() -> RandomNumberGenerator:
	# Per-instance RNG, seeded once.
	if not has_meta("rng"):
		var r := RandomNumberGenerator.new()
		r.randomize()
		set_meta("rng", r)
	return get_meta("rng")
