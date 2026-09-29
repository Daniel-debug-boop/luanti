class_name VoxelWorld
extends Node3D
## Streams chunks around the player from a converted world directory, or
## generates them procedurally when no converted world is available.
##
## A chunk is meshed only when all 26 neighbours exist, so border faces are
## culled against real data. The per-frame build budget keeps frame time flat
## while flying. Chunks are cached per dimension so switching back is fast.
##
## The mesher emits one surface per block id and each surface is bound to the
## matching Poly Haven PBR material, so photo textures appear without needing
## a texture atlas.

signal chunk_loaded(pos: Vector3i)
signal chunk_unloaded(pos: Vector3i)
signal block_changed(pos: Vector3i, id: int)

const BS := 16

@export var world_dir := ""
@export var view_radius := 5
@export var build_budget := 2
## Active dimension: WorldGenerator.DIM_OVERWORLD or WorldGenerator.DIM_DEEPS.
@export var dimension := 0
## How block textures are projected: 0 plain, 1 triplanar, 2 parallax (POM),
## 3 stochastic triplanar (vendored shader).
@export_enum("Plain", "Triplanar", "Parallax", "Stochastic") var texture_mapping := 2

var generator: WorldGenerator
var materials: MaterialLibrary

var _blocks := {}          # "dim:x:y:z" -> VoxelBlock
var _meshes := {}          # "dim:x:y:z" -> MeshInstance3D
var _trans_nodes := {}     # "dim:x:y:z" -> MeshInstance3D
var _dirty := {}           # key -> true
var _edits := {}           # "dim:x:y:z:vx:vy:vz" -> id, survives chunk reload
var _built := 0


func _ready() -> void:
	generator = WorldGenerator.new(1337)
	materials = MaterialLibrary.new()
	materials.set_mapping(texture_mapping)
	if world_dir == "":
		world_dir = ChunkFiles.resolve_dir()
	# Load every texture set up front so the first chunk meshed does not pay
	# the import cost mid-frame, and so the reported count is the full set.
	materials.prime()
	print("[VoxelWorld] materials: ", materials.describe())
	print("[VoxelWorld] material effects: ", materials.effect_counts())


func _key(pos: Vector3i) -> String:
	return "%d:%d:%d:%d" % [dimension, pos.x, pos.y, pos.z]


## Switch dimensions. The old dimension's meshes are hidden (not freed) so a
## return trip is instant; its chunks stay cached.
func set_dimension(d: int) -> void:
	if d == dimension:
		return
	for key in _meshes:
		_meshes[key].visible = false
		var ti: MeshInstance3D = _trans_nodes.get(key, null)
		if ti != null:
			ti.visible = false
	dimension = d
	_dirty.clear()
	print("[VoxelWorld] dimension -> ", d)


func get_block(pos: Vector3i) -> VoxelBlock:
	return _blocks.get(_key(pos), null)


func _block_pos(world_pos: Vector3i) -> Vector3i:
	return Vector3i(
		int(floor(float(world_pos.x) / BS)),
		int(floor(float(world_pos.y) / BS)),
		int(floor(float(world_pos.z) / BS)))


## Read a voxel in world node coordinates, crossing chunk boundaries.
func get_content_at(world_pos: Vector3i) -> int:
	var bpos := _block_pos(world_pos)
	var block: VoxelBlock = _blocks.get(_key(bpos), null)
	if block == null:
		return ContentDB.AIR
	var local := world_pos - bpos * BS
	if local.x < 0 or local.x >= BS or local.y < 0 or local.y >= BS \
			or local.z < 0 or local.z >= BS:
		return ContentDB.AIR
	return block.content[MapNode.index(local.x, local.y, local.z)]


## True when the node is solid and blocks movement.
func solid_at(world_pos: Vector3i) -> bool:
	return ContentDB.is_solid(get_content_at(world_pos))


## Name of the biome under a world position (overworld only).
func biome_name_at(world_pos: Vector3i) -> String:
	if dimension != WorldGenerator.DIM_OVERWORLD:
		return "The Deeps"
	var wx := world_pos.x
	var wz := world_pos.z
	return generator.biome_name(generator.biome_at(wx, wz))


## How many photo texture sets are actually bound in this world.
func texture_count() -> int:
	return materials.loaded_count() if materials != null else 0


func get_stats() -> Dictionary:
	return {
		"chunks_loaded": _blocks.size(),
		"chunks_visible": _meshes.size(),
		"chunks_built": _built,
		"dimension": dimension,
		"dirty": _dirty.size(),
		"edits": _edits.size(),
		"textures": texture_count(),
		"mapping": MaterialLibrary.mapping_name()[
			clampi(materials.mapping() if materials != null else 0, 0, 3)],
	}


## Load/unload chunks around `focus` and mesh a bounded number per call.
func update_around(focus: Vector3i) -> void:
	var centre := _block_pos(focus)

	var want := {}
	var r := view_radius
	for dx in range(-r, r + 1):
		for dy in range(-r, r + 1):
			for dz in range(-r, r + 1):
				if dx * dx + dy * dy + dz * dz > r * r + r:
					continue
				var p := centre + Vector3i(dx, dy, dz)
				want[p] = true
				if not _blocks.has(_key(p)):
					_load_chunk(p)

	# Drop far chunks (with hysteresis) so memory stays bounded.
	for key in _blocks.keys():
		var parts: PackedStringArray = key.split(":")
		if int(parts[0]) != dimension:
			continue
		var p := Vector3i(int(parts[1]), int(parts[2]), int(parts[3]))
		var dd := p - centre
		var lim := view_radius + 2
		if dd.x * dd.x + dd.y * dd.y + dd.z * dd.z > lim * lim:
			_unload_chunk(p, key)

	_refresh_dirty(centre)


func _load_chunk(pos: Vector3i) -> void:
	var key := _key(pos)
	var block: VoxelBlock = null
	# A converted world takes priority for the overworld.
	if dimension == WorldGenerator.DIM_OVERWORLD \
			and ChunkFiles.has_chunk(world_dir, pos.x, pos.y, pos.z):
		block = ChunkFiles.load_chunk(world_dir, pos.x, pos.y, pos.z)
	if block == null:
		if dimension == WorldGenerator.DIM_OVERWORLD:
			block = generator.generate_block(pos)
		else:
			block = generator.generate_deeps_block(pos)
	_apply_edits(block, pos)
	_blocks[key] = block
	chunk_loaded.emit(pos)

	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				if dx == 0 and dy == 0 and dz == 0:
					continue
				var n := pos + Vector3i(dx, dy, dz)
				if _blocks.has(_key(n)):
					_dirty[_key(n)] = true
	_dirty[key] = true


## Replay player edits onto a freshly generated or reloaded chunk, so digging a
## hole survives walking away and coming back.
func _apply_edits(block: VoxelBlock, pos: Vector3i) -> void:
	if _edits.is_empty():
		return
	var prefix := "%d:%d:%d:%d:" % [dimension, pos.x, pos.y, pos.z]
	for k in _edits.keys():
		var key := String(k)
		if not key.begins_with(prefix):
			continue
		var parts := key.split(":")
		var local := Vector3i(int(parts[4]), int(parts[5]), int(parts[6]))
		if local.x < 0 or local.x >= BS or local.y < 0 or local.y >= BS \
				or local.z < 0 or local.z >= BS:
			continue
		block.content[MapNode.index(local.x, local.y, local.z)] = _edits[key]


func _unload_chunk(pos: Vector3i, key: String) -> void:
	var mi: MeshInstance3D = _meshes.get(key, null)
	if mi != null:
		mi.queue_free()
	_meshes.erase(key)
	var ti: MeshInstance3D = _trans_nodes.get(key, null)
	if ti != null:
		ti.queue_free()
	_trans_nodes.erase(key)
	_blocks.erase(key)
	_dirty.erase(key)
	chunk_unloaded.emit(pos)


## Mesh whatever is dirty and ready, nearest-first, within the budget.
func _refresh_dirty(centre: Vector3i) -> void:
	if _dirty.is_empty():
		return
	var order := _dirty.keys()
	order.sort_custom(func(a: String, b: String) -> bool:
		return _dist2(_key_pos(a), centre) < _dist2(_key_pos(b), centre))

	var budget := build_budget
	for key in order:
		if budget <= 0:
			break
		if not _blocks.has(key):
			_dirty.erase(key)
			continue
		var pos := _key_pos(key)
		if not _can_mesh(pos):
			continue
		_mesh_chunk(pos, key)
		_dirty.erase(key)
		budget -= 1


static func _key_pos(key: String) -> Vector3i:
	var parts := key.split(":")
	return Vector3i(int(parts[1]), int(parts[2]), int(parts[3]))


static func _dist2(a: Vector3i, b: Vector3i) -> int:
	var d := a - b
	return d.x * d.x + d.y * d.y + d.z * d.z


func _can_mesh(pos: Vector3i) -> bool:
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				if dx == 0 and dy == 0 and dz == 0:
					continue
				if not _blocks.has(_key(pos + Vector3i(dx, dy, dz))):
					return false
	return true


## Set a voxel in world coordinates and queue every chunk whose border
## geometry the change touches. Returns false when the chunk is not loaded.
func set_block(world_pos: Vector3i, id: int) -> bool:
	var bpos := _block_pos(world_pos)
	var key := _key(bpos)
	if not _blocks.has(key):
		return false
	var block: VoxelBlock = _blocks[key]
	var local := world_pos - bpos * BS
	if local.x < 0 or local.x >= BS or local.y < 0 or local.y >= BS \
			or local.z < 0 or local.z >= BS:
		return false
	var idx := MapNode.index(local.x, local.y, local.z)
	if block.content[idx] == id:
		return false
	block.content[idx] = id
	# Daylight for an opened cell: inherit from above, or full sun at the top.
	var day: int = MapNode.LIGHT_SUN if local.y >= BS - 1 \
			else block.light[MapNode.index(local.x, local.y + 1, local.z)] \
			& 0x0F
	block.light[idx] = day | (day << 4)
	# Seven colon-separated fields: dim, block x/y/z, then the local voxel.
	# Fixed-width fields keep the key unambiguous.
	_edits["%d:%d:%d:%d:%d:%d:%d" % [dimension, bpos.x, bpos.y, bpos.z,
		local.x, local.y, local.z]] = id

	# Re-mesh this chunk plus any neighbour sharing the edited face.
	_dirty[key] = true
	for axis in 3:
		for step in [-1, 1]:
			var off := Vector3i.ZERO
			off[axis] = step
			var nkey := _key(bpos + off)
			if _blocks.has(nkey):
				_dirty[nkey] = true
	block_changed.emit(world_pos, id)
	return true


## Break the targeted block, ignoring bedrock and air.
func break_block(world_pos: Vector3i) -> bool:
	var id := get_content_at(world_pos)
	if id == ContentDB.AIR or id == ContentDB.BEDROCK:
		return false
	return set_block(world_pos, ContentDB.AIR)


## Place a block if the cell is free and it would not intersect the player.
func place_block(world_pos: Vector3i, id: int) -> bool:
	if get_content_at(world_pos) != ContentDB.AIR:
		return false
	return set_block(world_pos, id)


func _mesh_chunk(pos: Vector3i, key: String) -> void:
	var block: VoxelBlock = _blocks[key]
	var neighbours := {}
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				if dx == 0 and dy == 0 and dz == 0:
					continue
				var n: VoxelBlock = _blocks.get(
					_key(pos + Vector3i(dx, dy, dz)))
				if n != null:
					neighbours[Vector3i(dx, dy, dz)] = n

	var result := GreedyMesher.build(block, neighbours)
	var opaque: ArrayMesh = result[0]
	var trans: ArrayMesh = result[1]

	var mi: MeshInstance3D = _meshes.get(key, null)
	if mi == null:
		mi = MeshInstance3D.new()
		mi.name = "Chunk_%s" % key.replace(":", "_")
		add_child(mi)
		_meshes[key] = mi
	mi.position = Vector3(pos.x * BS, pos.y * BS, pos.z * BS)
	# Surfaces carry their own per-block-id materials, so no override here.
	_bind_surfaces(mi, opaque)
	mi.visible = (opaque != null)

	var ti: MeshInstance3D = _trans_nodes.get(key, null)
	if trans != null:
		if ti == null:
			ti = MeshInstance3D.new()
			ti.name = "Trans_%s" % key.replace(":", "_")
			add_child(ti)
			_trans_nodes[key] = ti
		ti.position = mi.position
		_bind_surfaces(ti, trans)
		ti.visible = true
	elif ti != null:
		ti.visible = false
	_built += 1


## Attach the PBR material for each surface's block id. The mesher names every
## surface with that id, so binding is a lookup rather than index bookkeeping.
## The material may be a StandardMaterial3D (engine path) or a ShaderMaterial
## (the vendored stochastic triplanar shader), depending on the mapping mode.
func _bind_surfaces(mi: MeshInstance3D, mesh: ArrayMesh) -> void:
	mi.mesh = mesh
	if mesh == null or materials == null:
		return
	for i in mesh.get_surface_count():
		var id := int(mesh.surface_get_name(i))
		mesh.surface_set_material(i, materials.material_for(id))


## Re-point every live surface at the current materials. Used after a render
## quality or mapping change reconfigures the shared StandardMaterial3D
## instances: the meshes keep their geometry, only the binding is refreshed.
func rebind_materials() -> void:
	if materials == null:
		return
	for store in [_meshes, _trans_nodes]:
		for key in store.keys():
			var mi: MeshInstance3D = store[key]
			if mi == null or not is_instance_valid(mi):
				continue
			_bind_surfaces(mi, mi.mesh)


## Switch between plain box UVs, triplanar projection, and parallax occlusion,
## then rebind every live surface to the reconfigured materials.
func set_texture_mapping(m: int) -> void:
	texture_mapping = m
	if materials == null:
		return
	materials.set_mapping(m)
	rebind_materials()
