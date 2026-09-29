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
## Hostile mobs close to melee range and hit; passive ones only flee.
@export var hostile := true
## Fraction of max_health below which a mob gives up and runs.
@export var flee_threshold := 0.3
## Seconds between melee swings.
@export var attack_cooldown := 1.2
## Damage per swing.
@export var attack_damage := 2.0
## Reach for a melee swing, in blocks.
@export var attack_reach := 1.6
## Optional AudioDirector for hurt/death sounds. Not required, so tests can
## build a mob without one.
var audio: AudioDirector = null
## Stable seed so a mob keeps the same model between frames and across saves.
@export var model_seed := 0

## Body model from the CC0 KayKit skeleton pack. Null falls back to the box.
var _model: Node3D = null
var _animator: CreatureAnimator = null
## Recomputed at most this often, because A* over a busy grid is not free.
const REPATH_INTERVAL := 0.6
var _repath_timer := 0.0
var _path: Array[Vector3i] = []
var _path_index := 0
## Plays the CC0 KayKit clips that ship inside the model.
var animator: CreatureAnimator = null
## When the mob will next be allowed to swing.
var _attack_timer := 0.0
var _ready_done := false
## How far a mob will look before it gives up on a ledge.
const LEDGE_LOOK := 2

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
	ensure_ready()


## Build the body and join the mobs group. Idempotent.
##
## Called from _ready() and available to callers, because a node added from
## SceneTree._init (how the tests assemble a scene) does not get _ready() until
## the first frame, which would leave a mob with no group membership and no
## model.
func ensure_ready() -> void:
	if _ready_done:
		return
	_ready_done = true
	add_to_group("mobs")
	health = max_health
	if model_seed == 0:
		model_seed = randi()
	_build_body()
	_animator = CreatureAnimator.new()
	_animator.attach(_model)
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
	_attack_timer = maxf(0.0, _attack_timer - delta)
	_hurt_flash = maxf(0.0, _hurt_flash - delta)
	_repath_timer = maxf(0.0, _repath_timer - delta)
	var target := _model if _model != null else _mesh
	if target != null and _hurt_flash > 0.0:
		target.scale = Vector3.ONE * (1.0 + _hurt_flash * 0.4)

	_think(delta)
	_apply_gravity(delta)
	_integrate(delta)
	_update_visuals()
	_update_animation(delta)
	_try_attack()


## Keep the walk cycle in step with how fast the mob is actually moving.
func _update_animation(delta: float) -> void:
	if _animator == null or not _animator.attached():
		return
	var planar := Vector2(velocity.x, velocity.z).length()
	_animator.update(delta, planar, SPEED_WANDER, SPEED_CHASE)


func _try_attack() -> void:
	if not hostile or _target == null or not is_instance_valid(_target):
		return
	if _attack_timer > 0.0:
		return
	if world_position().distance_to(_world_pos(_target)) > attack_reach:
		return
	_attack_timer = attack_cooldown
	if _animator != null:
		_animator.set_state(CreatureAnimator.State.ATTACK)
	if audio != null:
		audio.play_at("mob_idle", world_position())
	if _target.has_method("damage"):
		_target.damage(attack_damage, "a wanderer")


## Tree-safe world position of another node.
static func _world_pos(node: Node3D) -> Vector3:
	return node.global_position if node.is_inside_tree() else node.position


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
			# Steer away from an edge rather than walking off it.
			if _ledge_ahead():
				_wander_dir = -_wander_dir
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

	# Hurt and running out of health beats every other consideration: a mob
	# at 10% health should not calmly go back to wandering.
	if _target != null and is_instance_valid(_target) \
			and health < max_health * flee_threshold:
		state = State.FLEE
		return
	# A passive mob that has been hit also runs, whether or not it is healthy.
	if not hostile and _target != null and is_instance_valid(_target):
		state = State.FLEE
		return
	# Otherwise a mob with a live target keeps hunting. Re-rolling to IDLE or
	# WANDER here would make a chase give up every few seconds for no reason.
	if _target != null and is_instance_valid(_target):
		state = State.CHASE
		return

	var r := _rng().randf()
	if r < 0.35:
		state = State.IDLE
		velocity.x = 0.0
		velocity.z = 0.0
	else:
		state = State.WANDER
		var a := _rng().randf_range(0.0, TAU)
		_wander_dir = Vector3(sin(a), 0.0, cos(a))


## True when the ground ends within LEDGE_LOOK blocks ahead, so a mob steering
## into empty air turns around instead of marching off a cliff.
func _ledge_ahead() -> bool:
	if world == null or not is_instance_valid(world):
		return false
	var dir := Vector3(velocity.x, 0.0, velocity.z)
	if dir.length() < 0.05:
		dir = _wander_dir
	if dir.length() < 0.05:
		return false
	dir = dir.normalized()
	var here := world_position()
	for step in range(1, LEDGE_LOOK + 1):
		var p := here + dir * (float(step) * 0.7)
		var col := Vector3i(floori(p.x), floori(here.y), floori(p.z))
		# An unloaded chunk is unknown, not empty. Treating it as air makes
		# every mob refuse to walk towards the edge of the streamed region,
		# which reads as a mob stuck pacing a circle on flat ground.
		if not world.is_resident(col):
			continue
		if not world.solid_at(col - Vector3i(0, 1, 0)):
			return true
	return false


## World position that also works before the node is in the tree.
func world_position() -> Vector3:
	return global_position if is_inside_tree() else position


## Called by the player interacting with the mob.
func set_target(t: Node3D, chase := true) -> void:
	_target = t
	# A passive mob never switches to chasing just because it was hit.
	var want_chase := chase and hostile and health > max_health * flee_threshold
	state = State.CHASE if want_chase else State.FLEE
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
	if _animator != null and _animator.attached():
		_animator.set_state(CreatureAnimator.State.DEATH if health <= 0.0
			else CreatureAnimator.State.HURT)
	# Getting hit is enough to turn a mob on whoever did it, if it is still
	# standing -- that is what makes a fight escalate instead of ending.
	if health > 0.0 and _target == null:
		var tree := get_tree()
		if tree != null:
			var players := tree.get_nodes_in_group("players")
			if not players.is_empty():
				_target = players[0] as Node3D
				state = State.CHASE if hostile else State.FLEE
				_state_timer = 6.0
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
