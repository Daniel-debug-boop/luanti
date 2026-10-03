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
## Impact speed below which a landing does no damage, in m/s. With GRAVITY 24
## this is a drop of about 3.4 m, so stepping down, jumping off a ledge and
## riding an elevator of blocks are all free. Below this the player is not
## choosing to fall hard; they are just going down.
const FALL_DAMAGE_THRESHOLD := 12.8
## How far below the feet to look for support when deciding grounded state, in
## metres. Small enough that standing on a block edge does not read as falling,
## large enough to survive float error in the position.
const GROUND_PROBE := 0.02
## Impact speed at which fall damage equals a full health bar, in m/s.
## With GRAVITY 24 this is a drop of about 21 m, roughly seven storeys. Below
## it a fall hurts in proportion; above it a fall kills. The band matters: an
## 8 m/s lethal threshold makes an ordinary jump down a cliff lethal, which
## reads as the game being broken rather than as the player being careless.
const FALL_LETHAL := 32.0

## Where a fatal fall puts the player back. Exported so `main.gd` can set it to
## the world's own spawn rather than inventing a second one.
@export var spawn := Vector3(8.5, 40.0, 8.5)

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
		# Grounded state has to mean "there is floor under me", not "I was
		# grounded last frame". A teleport, a respawn or a debug move leaves
		# the previous frame's answer stale, and a stale true suppresses
		# gravity for exactly as long as the player hangs in the air.
		if _on_floor and not _box_free(position + Vector3.DOWN * GROUND_PROBE):
			_on_floor = false
		if on_ground():
			_coyote = COYOTE_TIME
			if Input.is_action_pressed("move_jump"):
				_leave_ground(JUMP_VELOCITY)
			else:
				velocity.y = 0.0
		else:
			_coyote = maxf(0.0, _coyote - delta)
			# A jump within the coyote window after walking off an edge is
			# allowed, and cancels the fall it was part of.
			if _coyote > 0.0 and Input.is_action_pressed("move_jump"):
				_leave_ground(JUMP_VELOCITY)
			else:
				velocity.y = maxf(velocity.y - GRAVITY * delta, -MAX_FALL)
				if velocity.y < _fall_peak:
					_fall_peak = -velocity.y

	_move_with_collision(delta)

	# Subtle view bob while walking, purely cosmetic.
	if not flying and Vector2(velocity.x, velocity.z).length() > 0.1:
		_bob += delta * 9.0
	else:
		_bob = lerpf(_bob, 0.0, delta * 8.0)


## Move along each axis independently, cancelling any step that would enter a
## solid voxel. Axis-separated resolution is what lets the player slide along
## walls instead of sticking to them.
##
## Grounded state is recomputed from scratch every frame. It used to be a latch:
## `_set_on_floor()` set it true and nothing ever set it false, so the first
## time the player touched the ground they were grounded forever -- no falling,
## no gravity, no fall damage, and a jump that could only ever fire once.
func _move_with_collision(delta: float) -> void:
	var was_on_floor := _on_floor
	# Clear before the moves, so the vertical step below can set it again if
	# and only if it actually lands this frame.
	_on_floor = false

	# Track the peak here rather than in `_physics_process`. This is the only
	# place that runs for every step of a fall, including one driven by a
	# caller that set the velocity directly, so the impact speed cannot be
	# missed by a fall that never passed through the input path.
	if not _on_floor and velocity.y < 0.0 and -velocity.y > _fall_peak:
		_fall_peak = -velocity.y

	var step := velocity * delta
	_try_move(Vector3(step.x, 0.0, 0.0))
	_try_move(Vector3(0.0, step.y, 0.0))
	_try_move(Vector3(0.0, 0.0, step.z))

	# A player standing still makes no downward move, so the sweep above never
	# gets the chance to detect the floor and `on_ground()` would flicker
	# every frame -- grounded, airborne, grounded. Probe for support instead:
	# a hair below the feet is the test, because the feet are exactly on the
	# surface when resting and the surface cell itself is what blocked the
	# previous frame's move.
	if not _on_floor and velocity.y <= 0.0 and not flying:
		if not _box_free(position + Vector3.DOWN * GROUND_PROBE):
			_on_floor = true

	if _on_floor and velocity.y <= 0.0:
		# The velocity is captured before it is zeroed. Zeroing first and then
		# landing would charge the fall damage with the resting speed of 0 and
		# a player who bounced would be charged for the bounce rather than for
		# the drop that caused it.
		var impact_speed := -velocity.y
		velocity.y = 0.0
		if not was_on_floor:
			_land(impact_speed)


## The transition out of grounded state: begin (or cancel) a fall.
func _leave_ground(vy: float) -> void:
	velocity.y = vy
	_on_floor = false
	_coyote = 0.0
	_fall_peak = maxf(-vy, 0.0)
	_fall_unloaded = not _below_is_resident()


## The transition into grounded state, and the only place fall damage is
## applied.
func _land(impact_speed: float = -1.0) -> void:
	# The peak tracked over the whole fall, or the speed at the instant of
	# contact when the caller has one -- which is the larger of the two, since
	# the peak is sampled before the sweep zeroes the velocity.
	var impact := _fall_peak
	if impact_speed > impact:
		impact = impact_speed
	_fall_peak = 0.0
	var unloaded := _fall_unloaded
	_fall_unloaded = false
	if unloaded or impact <= FALL_DAMAGE_THRESHOLD:
		return
	# Damage is quadratic in the excess impact speed, normalised so that
	# FALL_LETHAL impact removes a whole bar. That gives a survivable band
	# rather than a cliff: an 8-block drop hurts, a 2-block drop does not, and
	# the numbers are in one place instead of tuned against each other.
	var over := impact - FALL_DAMAGE_THRESHOLD
	var span := maxf(FALL_LETHAL - FALL_DAMAGE_THRESHOLD, 0.001)
	var frac := clampf(over / span, 0.0, 1.0)
	health = maxf(0.0, health - max_health * frac * frac)
	if health <= 0.0:
		_die()


func _die() -> void:
	# Respawn at the spawn point with a full bar. There is no death screen yet;
	# what matters is that a fatal fall ends the fall rather than leaving a
	# player at zero health falling forever.
	position = spawn
	health = max_health
	velocity = Vector3.ZERO
	_on_floor = false
	_fall_peak = 0.0


## True when there is a loaded chunk under the player's feet.
func _below_is_resident() -> bool:
	if world == null:
		return true
	return world.is_resident(Vector3i(floori(position.x),
		floori(position.y) - 1, floori(position.z)))


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
## Peak downward speed of the current fall, in m/s. Zero when grounded, and the
## value fall damage is computed from. Tracked per fall rather than sampled from
## `velocity` at the moment of landing, because the landing frame is exactly the
## frame on which `_try_move` has already zeroed the vertical velocity.
var _fall_peak := 0.0
## True when the fall started over a chunk that is not resident. Such a fall
## never damages: the player did not jump, the world simply was not there yet.
var _fall_unloaded := false
## How long after walking off an edge the player may still jump. Without it,
## jumping is frame-perfect -- a player who presses jump a few milliseconds
## before landing gets nothing, which reads as the game dropping the input.
const COYOTE_TIME := 0.12
var _coyote := 0.0


func _set_on_floor() -> void:
	_on_floor = true


## Named distinctly from CharacterBody3D.is_on_floor(), which the engine
## calls itself and which we do not drive.
func on_ground() -> bool:
	return _on_floor


## True when the player's AABB at `pos` does not intersect any solid voxel.
##
## The call is `solid_at`, on `VoxelWorld`. It used to be `is_solid_at`, which
## does not exist: every AABB query raised "nonexistent function" at runtime,
## so collision never actually answered and the player passed through terrain.
##
## An unloaded chunk reads as air rather than as solid. That is the right
## default -- a chunk that has not streamed in yet must not be an invisible
## wall -- but it means a player who walks off the edge of the resident region
## falls until the chunk arrives. `_try_move` therefore treats "was solid, now
## not resident" as a suspension rather than letting the fall continue, so the
## player never takes fall damage for terrain the game had not loaded.
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
				if world.solid_at(Vector3i(x, y, z)):
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
