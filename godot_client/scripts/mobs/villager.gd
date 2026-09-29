class_name Villager
extends Node3D
## A humanoid townsperson that paces a small home area and reacts to the
## player. Built from primitives rather than a downloaded model, because the
## Poly Haven props in assets/raw are furniture, not people.
##
## Villagers share the Mob voxel-collision rules but never chase: they walk a
## bounded loop inside their village, turn to face a nearby player, and show a
## greeting when talked to.

const WIDTH := 0.6
const HEIGHT := 1.8
const SPEED := 1.35
const TURN_SPEED := 6.0

## The villager's name, the job label shown on interaction, and colours.
@export var villager_name := "Villager"
@export var job := "Farmer"
@export var skin := Color(0.85, 0.68, 0.53)
@export var tunic := Color(0.35, 0.45, 0.7)
@export var trousers := Color(0.28, 0.26, 0.24)

@export var world: VoxelWorld

## Centre of the wander loop, in world coordinates.
var home := Vector3.ZERO
## How far from `home` this villager is allowed to roam.
var roam_radius := 6.0

var _target := Vector3.ZERO
var _wait := 0.0
var _facing := 0.0
var _greeting := ""
var _greeting_time := 0.0
var _body: Node3D
var _on_ground := false


func _ready() -> void:
	add_to_group("villagers")
	home = global_position
	_target = home
	_build_visual()


## Assemble the villager from boxes: legs, torso, arms, head, and a nose so the
## facing direction is readable at a distance.
func _build_visual() -> void:
	_body = Node3D.new()
	add_child(_body)

	var leg_h := 0.78
	_add_box(_body, Vector3(0.0, leg_h * 0.5, -0.11),
		Vector3(0.22, leg_h, 0.22), trousers)
	_add_box(_body, Vector3(0.0, leg_h * 0.5, 0.11),
		Vector3(0.22, leg_h, 0.22), trousers)
	var torso := _add_box(_body, Vector3(0.0, leg_h + 0.34, 0.0),
		Vector3(0.52, 0.68, 0.28), tunic)
	torso.name = "Torso"
	_add_box(_body, Vector3(-0.33, leg_h + 0.36, 0.0),
		Vector3(0.16, 0.6, 0.2), tunic.darkened(0.15))
	_add_box(_body, Vector3(0.33, leg_h + 0.36, 0.0),
		Vector3(0.16, 0.6, 0.2), tunic.darkened(0.15))
	_add_box(_body, Vector3(0.0, leg_h + 0.86, 0.0),
		Vector3(0.44, 0.44, 0.42), skin)
	_add_box(_body, Vector3(0.0, leg_h + 0.84, -0.24),
		Vector3(0.1, 0.1, 0.08), skin.darkened(0.2))
	# Eyes.
	var eye := Color(0.08, 0.08, 0.1)
	_add_box(_body, Vector3(-0.1, leg_h + 0.92, -0.215),
		Vector3(0.07, 0.07, 0.04), eye)
	_add_box(_body, Vector3(0.1, leg_h + 0.92, -0.215),
		Vector3(0.07, 0.07, 0.04), eye)


func _add_box(parent: Node3D, pos: Vector3, size: Vector3,
		col: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = 0.85
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


func _process(delta: float) -> void:
	_greeting_time = maxf(0.0, _greeting_time - delta)
	_wait -= delta
	if _wait <= 0.0:
		_pick_target()

	# Turn toward the player when they are close, otherwise face travel.
	var want := _facing
	var player := _nearest_player()
	if player != null:
		var to := player.global_position - global_position
		to.y = 0.0
		if to.length() < 6.0:
			want = atan2(to.x, to.z)
		else:
			_move_towards(_target, delta)
	else:
		_move_towards(_target, delta)
	_face(want, delta)


func _face(want: float, delta: float) -> void:
	var diff := wrapf(want - _facing, -PI, PI)
	_facing += diff * minf(1.0, TURN_SPEED * delta)
	if _body != null:
		_body.rotation.y = _facing


func _move_towards(target: Vector3, delta: float) -> void:
	var to := target - global_position
	to.y = 0.0
	if to.length() < 0.4:
		return
	var step := to.normalized() * SPEED * delta
	var next := global_position + step
	# Stay inside the roam radius, and refuse to walk into terrain.
	if Vector2(next.x - home.x, next.z - home.z).length() > roam_radius:
		return
	if _box_blocked(next):
		# Step up one block if that clears it, so villagers can climb the
		# one-block terrain steps the generator produces.
		if _on_ground and not _box_blocked(next + Vector3(0.0, 1.05, 0.0)):
			next += Vector3(0.0, 1.0, 0.0)
		else:
			_wait = 0.4
			return
	global_position = next
	_on_ground = false


func _pick_target() -> void:
	# Two out of three choices walk somewhere new; the rest stand and talk.
	if randf() < 0.34:
		_wait = randf_range(1.5, 4.0)
		return
	var a := randf() * TAU
	var r := randf() * roam_radius
	_target = home + Vector3(sin(a) * r, 0.0, cos(a) * r)
	_wait = randf_range(2.0, 5.0)


func _nearest_player() -> Node3D:
	var tree := get_tree()
	if tree == null:
		return null
	var players := tree.get_nodes_in_group("players")
	if players.is_empty():
		return null
	var best: Node3D = null
	var best_d := 12.0
	for p in players:
		if not (p is Node3D):
			continue
		var d: float = (p as Node3D).global_position.distance_to(
			global_position)
		if d < best_d:
			best_d = d
			best = p
	return best


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


## Called by the player's interact action. Returns a line for the HUD.
func greet(player_name: String) -> String:
	_greeting = "%s the %s tips their hat." % [villager_name, job]
	_greeting_time = 4.0
	return _greeting


func greeting() -> String:
	return _greeting


## Drop the villager onto the terrain surface at their column.
func place_on_ground(world_ref: VoxelWorld) -> void:
	if world_ref == null:
		return
	world = world_ref
	var bx := int(floor(global_position.x))
	var bz := int(floor(global_position.z))
	var y := 64
	while y > 1 and not world_ref.solid_at(Vector3i(bx, y, bz)):
		y -= 1
	global_position = Vector3(float(bx) + 0.5, float(y) + 1.0, float(bz) + 0.5)
	home = global_position
