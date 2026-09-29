class_name PlayerInteraction
extends Node3D
## Block breaking and placing, plus the survival rules that hang off them.
##
## Holding the left mouse button on a block mines it: progress accumulates at a
## rate scaled by the block's hardness, and the block only disappears when the
## progress bar fills. The right mouse button places the selected hotbar block
## against the face that was hit, as long as the cell is free and the player's
## own body does not intersect it.
##
## Survival is intentionally small and legible: fall damage above a safe
## threshold, slow regeneration while unhurt, drowning damage underwater, and
## damage from a mob that has closed to melee range.

signal block_broken(pos: Vector3i, id: int)
signal block_placed(pos: Vector3i, id: int)

## How far the player can reach.
@export var reach := 6.0
## Seconds of continuous mining to break a hardness-1 block.
@export var base_break_time := 0.45
## Blocks the player can carry, selected with the number keys.
@export var hotbar := [
	ContentDB.GRASS, ContentDB.DIRT, ContentDB.STONE,
	ContentDB.SAND, ContentDB.WOOD, ContentDB.SNOW,
]

@export var world: VoxelWorld
@export var player: Player

## Blocks the player has mined, for the HUD statistic.
var mined := 0
## Blocks the player has placed.
var placed := 0

var selected := 0
## 0..1 progress on the block currently being mined.
var break_progress := 0.0
## Block currently under the crosshair, or Vector3i.ZERO.
var target := Vector3i.ZERO
var target_id := 0
var has_target := false

var _mining := false
var _mine_pos := Vector3i.ZERO
var _fall_from := INF
var _regen_delay := 0.0
var _breath := 10.0
var _melee_cooldown := 0.0
var _hurt_flash := 0.0


func _ready() -> void:
	if player != null and not player.is_in_group("players"):
		player.add_to_group("players")


func _process(delta: float) -> void:
	if world == null or player == null:
		return
	_hurt_flash = maxf(0.0, _hurt_flash - delta)
	_melee_cooldown = maxf(0.0, _melee_cooldown - delta)

	var cam := player.get_node_or_null("Camera") as Camera3D
	var origin := player.get_eye_position()
	var dir := -player.global_transform.basis.z
	if cam != null:
		dir = -cam.global_transform.basis.z
	var hit := VoxelPick.raycast(world, origin, dir, reach)
	has_target = hit.hit
	target = hit.block
	target_id = hit.id

	if _mining and hit.hit and hit.block == _mine_pos:
		_advance_break(hit.id, delta)
	elif _mining:
		_stop_break()

	_survival(delta)


func _advance_break(id: int, delta: float) -> void:
	var hardness: float = maxf(0.05, ContentDB.get_entry(id).hardness)
	break_progress += delta / (base_break_time * hardness)
	if break_progress >= 1.0:
		if world.break_block(_mine_pos):
			mined += 1
			block_broken.emit(_mine_pos, id)
		_stop_break()


func _stop_break() -> void:
	_mining = false
	break_progress = 0.0


## Seconds remaining to break the targeted block, or -1 when nothing is targeted.
func break_time_left() -> float:
	if not has_target:
		return -1.0
	var hardness: float = maxf(0.05, ContentDB.get_entry(target_id).hardness)
	return maxf(0.0, (1.0 - break_progress) * base_break_time * hardness)


## Left mouse held: start or continue mining the targeted block.
func start_break() -> void:
	if not has_target:
		_stop_break()
		return
	if target == _mine_pos and _mining:
		return
	_mine_pos = target
	_mining = true
	break_progress = 0.0


## Left mouse released.
func stop_breaking() -> void:
	_stop_break()


## Right mouse: place the selected hotbar block against the hit face.
func place() -> bool:
	if not has_target:
		return false
	var hit := VoxelPick.raycast(world, player.get_eye_position(),
		-player.global_transform.basis.z, reach)
	if not hit.hit:
		return false
	if _player_intersects(hit.place):
		return false
	if world.place_block(hit.place, selected_block()):
		placed += 1
		block_placed.emit(hit.place, selected_block())
		return true
	return false


func selected_block() -> int:
	if hotbar.is_empty():
		return ContentDB.STONE
	return int(hotbar[clampi(selected, 0, hotbar.size() - 1)])


func select_slot(i: int) -> void:
	selected = clampi(i, 0, hotbar.size() - 1)


## True when placing at `pos` would put a block inside the player's own box.
func _player_intersects(pos: Vector3i) -> bool:
	var p := player.position
	var half := Player.WIDTH * 0.5
	return p.x + half > float(pos.x) and p.x - half < float(pos.x) + 1.0 \
		and p.y + Player.HEIGHT > float(pos.y) \
		and p.y < float(pos.y) + 1.0 \
		and p.z + half > float(pos.z) and p.z - half < float(pos.z) + 1.0


# --- Survival ---------------------------------------------------------------

func _survival(delta: float) -> void:
	if player.flying:
		_fall_from = INF
		_regen_delay = maxf(0.0, _regen_delay - delta)
		_maybe_regen(delta)
		return

	# Fall damage: remember the highest point of the current descent.
	if not player.on_ground():
		if player.velocity.y > 0.0:
			_fall_from = INF
		elif _fall_from == INF:
			_fall_from = player.position.y
	elif _fall_from != INF:
		var drop := _fall_from - player.position.y
		_fall_from = INF
		if drop > 3.5:
			damage((drop - 3.5) * 1.6, "the fall")

	# Drowning.
	var head := Vector3i(int(floor(player.position.x)),
		int(floor(player.position.y + Player.EYE_HEIGHT)),
		int(floor(player.position.z)))
	if world.get_content_at(head) == ContentDB.WATER:
		_breath -= delta
		if _breath < 0.0:
			damage(4.0 * delta, "drowning")
	else:
		_breath = minf(10.0, _breath + delta * 3.0)

	_regen_delay = maxf(0.0, _regen_delay - delta)
	_maybe_regen(delta)
	_mob_melee()


func _maybe_regen(delta: float) -> void:
	if _regen_delay > 0.0:
		return
	if player.health >= player.max_health:
		return
	player.health = minf(player.max_health, player.health + 1.6 * delta)


## Damage a mob that is close enough to swing at the player.
func _mob_melee() -> void:
	if _melee_cooldown > 0.0:
		return
	for node in get_tree().get_nodes_in_group("mobs"):
		if not (node is Mob):
			continue
		var mob := node as Mob
		if not mob.is_alive():
			continue
		if mob.global_position.distance_to(player.global_position) > 1.8:
			continue
		_melee_cooldown = 1.1
		damage(2.5, "a %s" % ("wanderer" if world.dimension
			== WorldGenerator.DIM_OVERWORLD else "deep lurker"))
		mob.set_target(player)
		return


## Apply damage, clamped to a single hit per source window, and emit a signal
## the HUD flashes on.
func damage(amount: float, _cause: String) -> void:
	if amount <= 0.0 or player.health <= 0.0:
		return
	player.health = maxf(0.0, player.health - amount)
	_hurt_flash = 0.35
	_regen_delay = 5.0


func breath() -> float:
	return _breath


func hurt_flash() -> float:
	return _hurt_flash


func is_alive() -> bool:
	return player != null and player.health > 0.0
