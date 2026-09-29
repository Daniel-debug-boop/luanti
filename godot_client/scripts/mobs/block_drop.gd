class_name BlockDrop
extends Node3D
## A mined block lying in the world, waiting to be picked up.
##
## This is what makes mining mean something: the block leaves the world as an
## item, falls under gravity, settles on the terrain, bobs so it is easy to
## spot, and merges into the player's GLoot inventory when they walk near it.
##
## Drops are visual-only cubes tinted with the block's ContentDB colour rather
## than textured meshes: at this size and count the PBR material set is far
## more expensive than it is worth, and the colour already matches what the
## block looked like in the world.

const PICKUP_RADIUS := 1.4
## Seconds before an uncollected drop despawns, so a world does not fill up.
const LIFETIME := 180.0
const GRAVITY := 20.0
const BOB_HEIGHT := 0.18
const BOB_SPEED := 2.4
const SPIN := 1.1

var block_id := 0
var world: VoxelWorld = null

var _velocity := Vector3.ZERO
var _age := 0.0
var _base_y := 0.0
var _settled := false
var _mesh: MeshInstance3D
var _rng := RandomNumberGenerator.new()
var _built := false


static func spawn(parent: Node, world_ref: VoxelWorld, id: int,
		at: Vector3) -> BlockDrop:
	if parent == null or id == ContentDB.AIR:
		return null
	var d := BlockDrop.new()
	d.world = world_ref
	d.block_id = id
	d.position = at
	parent.add_child(d)
	# _ready() is deferred when a node is added from SceneTree._init (which is
	# how the tests build the scene), so build explicitly here as well. _build
	# is idempotent, so whichever runs first wins.
	d.build()
	d._init_motion()
	return d


func _ready() -> void:
	build()


## Create the visual and join the drops group. Safe to call more than once.
func build() -> void:
	if _built:
		return
	_built = true
	if not is_in_group("drops"):
		add_to_group("drops")
	_rng.randomize()
	_mesh = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.28, 0.28, 0.28)
	_mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = ContentDB.color_of(block_id)
	mat.roughness = 0.8
	if ContentDB.get_entry(block_id).translucent:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mesh.material_override = mat
	add_child(_mesh)


func _init_motion() -> void:
	_base_y = position.y
	_velocity = Vector3(_rng.randf_range(-1.0, 1.0), 2.6, _rng.randf_range(-1.0, 1.0))


## Position in world space, tolerant of not being in the tree yet.
func world_position() -> Vector3:
	return global_position if is_inside_tree() else position


func _process(delta: float) -> void:
	_age += delta
	if _age >= LIFETIME:
		queue_free()
		return
	if not _settled:
		_velocity.y -= GRAVITY * delta
		position += _velocity * delta
		# Settle on the first solid block below.
		if world != null and is_instance_valid(world) and _velocity.y < 0.0:
			var below := Vector3i(floori(position.x), floori(position.y) - 1,
				floori(position.z))
			if world.solid_at(below) or position.y < 1.0:
				_settled = true
				_base_y = floorf(position.y)
				position.y = maxf(position.y, _base_y + 0.15)
		if position.y < 0.0:
			_settled = true
			_base_y = 0.0
	if _mesh != null:
		_mesh.rotation.y += SPIN * delta
		_mesh.position.y = sin(_age * BOB_SPEED) * BOB_HEIGHT
	# Rotate the whole drop to lie flat-ish is not wanted; keep the spin above.


## Called by the player when within reach. Returns true when collected.
func try_collect(player_pos: Vector3, inv: PlayerInventory) -> bool:
	if inv == null or not is_instance_valid(inv):
		return false
	if world_position().distance_to(player_pos) > PICKUP_RADIUS:
		return false
	if inv.give_block(block_id) < 0:
		return false
	queue_free()
	return true


func age() -> float:
	return _age
