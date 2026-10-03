class_name Player
extends CharacterBody3D
## First-person controller with walk and fly modes.
##
## Collision is resolved against the voxel field directly (swept AABB per axis)
## rather than using Godot physics bodies, because the world is a flat hash of
## chunk data with no collision shapes generated for it.

const WIDTH := 0.6
const HEIGHT := 1.8
const EYE_HEIGHT := 1.62
const WALK_SPEED := 4.5
const SPRINT_SPEED := 7.5
const FLY_SPEED := 12.0
const JUMP_VELOCITY := 8.0
const GRAVITY := 24.0
## Terminal fall speed, so tunnelling through thin floors is impossible.
const MAX_FALL := 60.0

@export var world: VoxelWorld

var flying := true
## Health for the HUD. Damage sources are not wired up yet.
var max_health := 20.0
var health := 20.0
var _yaw := 0.0
var _pitch := 0.0
var _bob := 0.0


func _ready() -> void:
	# CharacterBody3D's own collision is unused; we resolve voxels manually.
	collision_layer = 0
	collision_mask = 0
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode \
			== Input.MOUSE_MODE_CAPTURED:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * 0.003
		_pitch = clampf(_pitch - mm.relative.y * 0.003, -1.5, 1.5)
	elif event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif (event as InputEventKey).keycode == KEY_V:
			# F is the engineering "use held tool" key (ARCHITECTURE.md
			# section 15). Flight used to be F as well: two nodes each with
			# their own _unhandled_input, so every attempt to place a part
			# also toggled flight. V is unbound and is a plausible thing to
			# reach for when you want to get off the ground.
			flying = not flying
			velocity.y = 0.0
		elif Input.mouse_mode == Input.MOUSE_MODE_VISIBLE \
				and (event as InputEventKey).keycode == KEY_ENTER:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	rotation.y = _yaw
	rotation.x = _pitch

	var input := Input.get_vector("move_left", "move_right",
		"move_forward", "move_back")
	# Camera-relative movement on the horizontal plane only.
	var basis_f := Vector3(-sin(_yaw), 0.0, -cos(_yaw))
	var basis_r := Vector3(cos(_yaw), 0.0, -sin(_yaw))
	var wish := (basis_f * -input.y + basis_r * input.x)
	if wish.length() > 1.0:
		wish = wish.normalized()

	var sprinting := Input.is_action_pressed("sprint")
	if flying:
		var up := 0.0
		if Input.is_action_pressed("move_jump"):
			up += 1.0
		if Input.is_action_pressed("move_down"):
			up -= 1.0
		var speed := FLY_SPEED * (2.0 if sprinting else 1.0)
		velocity = velocity.lerp(wish * speed + Vector3.UP * up * speed,
			clampf(delta * 12.0, 0.0, 1.0))
	else:
		var speed := SPRINT_SPEED if sprinting else WALK_SPEED
		velocity.x = wish.x * speed
		velocity.z = wish.z * speed
		if on_ground():
			if Input.is_action_pressed("move_jump"):
				velocity.y = JUMP_VELOCITY
			else:
				velocity.y = 0.0
		else:
			velocity.y = maxf(velocity.y - GRAVITY * delta, -MAX_FALL)

	_move_with_collision(delta)

	# Subtle view bob while walking, purely cosmetic.
	if not flying and Vector2(velocity.x, velocity.z).length() > 0.1:
		_bob += delta * 9.0
	else:
		_bob = lerpf(_bob, 0.0, delta * 8.0)


## Move along each axis independently, cancelling any step that would enter a
## solid voxel. Axis-separated resolution is what lets the player slide along
## walls instead of sticking to them.
func _move_with_collision(delta: float) -> void:
	var step := velocity * delta
	_try_move(Vector3(step.x, 0.0, 0.0))
	_try_move(Vector3(0.0, step.y, 0.0))
	_try_move(Vector3(0.0, 0.0, step.z))

	if on_ground() and velocity.y <= 0.0:
		velocity.y = 0.0


func _try_move(delta_v: Vector3) -> void:
	if delta_v == Vector3.ZERO:
		return
	var next := position + delta_v
	if _box_free(next):
		position = next
		return
	# Blocked: binary-search the largest safe fraction of the step so the
	# player ends up flush against the surface rather than a step away.
	var lo := 0.0
	var hi := 1.0
	for _i in 8:
		var mid := (lo + hi) * 0.5
		if _box_free(position + delta_v * mid):
			lo = mid
		else:
			hi = mid
	position += delta_v * lo
	# Kill velocity on the blocked axis so we do not accumulate force.
	if absf(delta_v.x) > 0.0:
		velocity.x = 0.0
	elif absf(delta_v.y) > 0.0:
		if delta_v.y < 0.0:
			_set_on_floor()
		velocity.y = 0.0
	else:
		velocity.z = 0.0


var _on_floor := false


func _set_on_floor() -> void:
	_on_floor = true


## Named distinctly from CharacterBody3D.is_on_floor(), which the engine
## calls itself and which we do not drive.
func on_ground() -> bool:
	return _on_floor


## True when the player's AABB at `pos` does not intersect any solid voxel.
func _box_free(pos: Vector3) -> bool:
	if world == null:
		return true
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
				if world.is_solid_at(Vector3i(x, y, z)):
					return false
	return true


func get_eye_position() -> Vector3:
	return position + Vector3.UP * EYE_HEIGHT \
		+ Vector3(0.0, sin(_bob) * 0.035, 0.0)


## Point the player along a world-space direction.
##
## This exists because `_yaw`/`_pitch` are private and `_physics_process`
## rewrites `rotation` from them every frame, so the only other way to aim is
## synthesised mouse motion -- which `_unhandled_input` ignores unless the
## mouse is captured. That guard is right for a player and wrong for anything
## that is not a person at a keyboard: a test, a cutscene camera, a spectator
## mode, a server-driven look-at. All of those are "point the player here", so
## that is one named operation rather than four workarounds.
func look_along(dir: Vector3) -> void:
	if dir.length_squared() < 0.000001:
		return
	var flat := Vector3(dir.x, 0.0, dir.z)
	# With yaw then pitch applied, a node's forward (-Z) is
	#   (-sin(yaw)*cos(pitch), sin(pitch), -cos(yaw)*cos(pitch)).
	# Matching that to `dir` gives yaw from the horizontal part and pitch
	# from the ratio of vertical to horizontal, with no sign guesswork:
	# sin(pitch) is dir.y, so a downward direction is a negative pitch.
	if flat.length_squared() > 0.000001:
		_yaw = atan2(-dir.x, -dir.z)
	_pitch = clampf(atan2(dir.y, maxf(flat.length(), 0.000001)), -1.5, 1.5)
	rotation.y = _yaw
	rotation.x = _pitch


func get_block_position() -> Vector3i:
	return Vector3i(
		int(floor(position.x)),
		int(floor(position.y + 0.5)),
		int(floor(position.z)))
