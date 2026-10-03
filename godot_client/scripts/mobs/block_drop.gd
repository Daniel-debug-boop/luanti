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
## Set the moment this drop is credited to an inventory, so it can only ever be
## collected once. See `try_collect`.
var _taken := false
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
		#
		# This checks the single cell under the drop's *current* position, and
		# only after it has already moved there. A drop that is falling fast
		# moves several blocks in one frame, so it steps clean over the surface
		# that should have caught it and keeps going: mining a tree trunk left
		# the drop falling through the world 20 m past the player who mined it,
		# and since the drop is the authoritative acquisition path the block was
		# simply gone. The column from the drop down to the world floor is
		# searched instead, and the drop is placed on the topmost solid cell.
		if world != null and is_instance_valid(world) and _velocity.y < 0.0:
			var cx := floori(position.x)
			var cz := floori(position.z)
			var found := -2147483648
			# Bounded so a drop in unloaded space does not scan to y = -2^31.
			var scan_from := clampi(floori(position.y), -64, 512)
			for y in range(scan_from, -64, -1):
				if world.solid_at(Vector3i(cx, y, cz)):
					found = y
					break
			if found > -2147483647 or position.y < 1.0:
				_settled = true
				_base_y = float(found) if found > -2147483647 else 0.0
				position.y = _base_y + 0.85
		if position.y < 0.0:
			_settled = true
			_base_y = 0.0
	if _mesh != null:
		_mesh.rotation.y += SPIN * delta
		_mesh.position.y = sin(_age * BOB_SPEED) * BOB_HEIGHT
	# Rotate the whole drop to lie flat-ish is not wanted; keep the spin above.


## Called by the player when within reach. Returns true when collected.
##
## The `_taken` latch is the whole point. `queue_free()` is deferred to the end
## of the frame, so without it a second collection in the same frame -- a
## player standing still in a pickup radius while the game checks twice, or
## two systems both noticing the same drop -- credits the inventory again and
## the drop is duplicated. It is set before the give, not after, so even a
## re-entrant call cannot slip past it.
func try_collect(player_pos: Vector3, inv: PlayerInventory) -> bool:
	if _taken:
		return false
	if inv == null or not is_instance_valid(inv):
		return false
	if world_position().distance_to(player_pos) > PICKUP_RADIUS:
		return false
	_taken = true
	if inv.give_block(block_id) < 0:
		# The inventory was full. Un-latch, so the drop survives to be picked
		# up once there is room, rather than vanishing along with the item.
		_taken = false
		return false
	queue_free()
	return true


func age() -> float:
	return _age
