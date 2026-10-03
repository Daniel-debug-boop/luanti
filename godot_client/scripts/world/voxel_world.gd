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

## Streaming lives here rather than in a loop inside `update_around`. The
## scheduler owns the queue, the priority, the per-frame budget, cancellation
## and the cache; this class owns what a chunk *is*. Splitting them means the
## ordering rules can be tested without a renderer and the chunk code can be
## read without a queue.
var stream := StreamScheduler.new()
## How far the player may be looking, in world space. Drives the streaming
## direction bias, so chunks ahead of the camera beat chunks behind it.
var view_forward := Vector3.FORWARD
## Set false to stream terrain only and skip meshing, which is what a
## dedicated server wants.
@export var mesh_enabled := true


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
## True only for a cell that is loaded *and* solid. See `is_resident` for why
## the two must not be conflated.
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


## Identity for the `WorldBackend` contract. A world must be able to say which
## backend it is, so a second one is refused by name rather than silently.
func backend_name() -> String:
	return "gdscript"


## Whether this world is currently registered as the single active backend.
func is_active_backend() -> bool:
	return WorldBackend.active() == self


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


## Stream chunks around `focus`, within this frame's budget.
##
## The ordering, the budget and the cancellation all belong to
## `StreamScheduler`. This method is the seam: it says what "generated" and
## "meshed" mean, and the scheduler says what to do and when to stop.
func update_around(focus: Vector3i) -> void:
	var centre := _block_pos(focus)
	_last_focus = focus
	stream.select(centre, view_forward, view_radius, _is_resident)
	drop_distant(centre)
	if mesh_enabled:
		stream.step(_generate_job, _mesh_job, _has_mesh_work)


func _is_resident(p: Vector3i) -> bool:
	return _blocks.has(_key(p))


## Is the chunk containing this cell loaded? An unloaded cell is *unknown*, not
## empty, and the difference matters: a mob that reads unloaded terrain as air
## sees a cliff at the edge of the loaded region and turns away from a
## perfectly flat plain, and a projectile test sees through the world. Anything
## asking "is this solid?" across the streaming boundary has to ask this
## first.
func is_resident(world_pos: Vector3i) -> bool:
	return _blocks.has(_key(_block_pos(world_pos)))


## Load every chunk in a sphere around `focus` **right now**, ignoring the
## frame budget.
##
## This is not a test hook; it is what "the world must exist here before the
## next line runs" looks like. Three callers need it and all three are real:
##
##   * Start-up and teleport arrival. A budgeted streamer fills in over a
##     second, and a player who arrives in that second falls through the world
##     and lands in The Deeps. Arrival is exactly the moment the budget does
##     not apply.
##   * A dedicated server, which has no renderer and no frame budget and needs
##     the answer to "what is at x" to be immediate.
##   * Anything that edits the world and needs its neighbours to exist first.
##
## The radius is deliberately small: a large sphere is the hitch the scheduler
## exists to avoid, and the caller that wants a big one wants the streamer.
func ensure_region(focus: Vector3i, radius: int) -> int:
	var centre := _block_pos(focus)
	var loaded := 0
	var r2 := radius * radius + radius
	for dx in range(-radius, radius + 1):
		for dy in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				if dx * dx + dy * dy + dz * dz > r2:
					continue
				var p := centre + Vector3i(dx, dy, dz)
				if _blocks.has(_key(p)):
					continue
				_load_chunk(p)
				loaded += 1
	return loaded


## Generate one chunk: the converted world if there is one, otherwise the
## generator. The only place in the world that decides where voxels come from.
func _generate_block(pos: Vector3i) -> VoxelBlock:
	# A converted Luanti world takes priority for the overworld.
	if dimension == WorldGenerator.DIM_OVERWORLD and world_dir != "" \
			and ChunkFiles.has_chunk(world_dir, pos.x, pos.y, pos.z):
		var converted: VoxelBlock = ChunkFiles.load_chunk(
			world_dir, pos.x, pos.y, pos.z) as VoxelBlock
		if converted != null:
			stream.stats["disk_hits"] = int(stream.stats["disk_hits"]) + 1
			return converted
	if dimension == WorldGenerator.DIM_OVERWORLD:
		return generator.generate_block(pos)
	return generator.generate_deeps_block(pos)


## The scheduler's generate callback. Returns false when the chunk could not
## be produced, which the scheduler counts as a cancellation.
func _generate_job(p: Vector3i) -> bool:
	var key := _key(p)
	if _blocks.has(key):
		return true
	var block: VoxelBlock = stream.cache_take(key) as VoxelBlock
	if block == null:
		block = _generate_block(p)
	if block == null:
		return false
	# A cached chunk still needs its player edits replayed.
	_apply_edits(block, p)
	_blocks[key] = block
	_mark_neighbours_dirty(p)
	chunk_loaded.emit(p)
	return true


## The scheduler's mesh callback: the nearest chunk that is ready to be meshed.
## Takes no argument -- the mesh queue is "which dirty chunk is nearest and
## ready", which is a question about the world, not about the job.
func _mesh_job() -> bool:
	var key := _nearest_meshable()
	if key == "":
		return false
	_mesh_chunk(_key_pos(key), key)
	_dirty.erase(key)
	return true


## The scheduler's "is there anything worth meshing" probe. A chunk waits
## until all 26 neighbours have terrain, because a mesh built against missing
## neighbours guesses which faces are interior -- and the guess is wrong, and
## the player sees through the world.
func _has_mesh_work() -> bool:
	return _nearest_meshable() != ""


## A candidate is dirty, resident, inside the view sphere, and has all 26
## neighbours.
func _nearest_meshable() -> String:
	if _dirty.is_empty():
		return ""
	var centre := _block_pos(_last_focus)
	var best := ""
	var best_d := 1 << 60
	for key in _dirty.keys():
		if not _blocks.has(key):
			continue
		var p := _key_pos(key)
		var d := p - centre
		var d2 := d.x * d.x + d.y * d.y + d.z * d.z
		if d2 > view_radius * view_radius + view_radius:
			continue
		if not _can_mesh(p):
			continue
		if d2 < best_d:
			best_d = d2
			best = String(key)
	return best


## The focus the streaming decisions are relative to, kept so the mesh probe
## does not have to be handed the camera position every call.
var _last_focus := Vector3i.ZERO


func _rehydrate(block: VoxelBlock, pos: Vector3i) -> VoxelBlock:
	# A cached chunk still needs its player edits replayed, or walking back
	# over a hole you dug undoes it.
	_apply_edits(block, pos)
	return block


func _mark_neighbours_dirty(pos: Vector3i) -> void:
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				if dx == 0 and dy == 0 and dz == 0:
					continue
				var n := pos + Vector3i(dx, dy, dz)
				var nk := _key(n)
				if _blocks.has(nk):
					_dirty[nk] = true
	_dirty[_key(pos)] = true


## Unload chunks that left the view, into the cache rather than into the void,
## and with hysteresis so a chunk on the boundary does not thrash.
func drop_distant(centre: Vector3i) -> void:
	var lim := view_radius + 2
	var lim2 := lim * lim
	for key in _blocks.keys().duplicate():
		var parts: PackedStringArray = String(key).split(":")
		if int(parts[0]) != dimension:
			continue
		var p := Vector3i(int(parts[1]), int(parts[2]), int(parts[3]))
		var dd := p - centre
		if dd.x * dd.x + dd.y * dd.y + dd.z * dd.z > lim2:
			_unload_chunk(p, String(key))


## Force a chunk resident, outside the scheduler. Used by the tests and by
## anything that needs a specific chunk *now* rather than in queue order.
func _load_chunk(pos: Vector3i) -> void:
	if _blocks.has(_key(pos)):
		return
	var block := _generate_block(pos)
	if block == null:
		return
	_apply_edits(block, pos)
	_blocks[_key(pos)] = block
	_mark_neighbours_dirty(pos)
	chunk_loaded.emit(pos)


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
	# The terrain goes to the cache, not into the void: walking back three
	# chunks should not regenerate the world.
	stream.cache_put(key, _blocks.get(key))
	_blocks.erase(key)
	_dirty.erase(key)
	chunk_unloaded.emit(pos)


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
## Every player edit as {"dim:x:y:z:vx:vy:vz": id}, for the save file.
## The edit log -- not the chunk cache -- is the part of the world that is not
## reproducible from the generator, so this is what has to survive a restart.
func edits_snapshot() -> Dictionary:
	var out := {}
	for k in _edits.keys():
		out[str(k)] = int(_edits[k])
	return out


## Replace the edit log with one loaded from disk, then replay it onto every
## chunk that is currently resident. Chunks loaded later pick the edits up in
## _apply_edits(), so this works whether the player is standing in the saved
## area or a thousand blocks away.
func apply_edits_snapshot(edits: Dictionary) -> void:
	_edits.clear()
	for k in edits.keys():
		var key := String(k)
		var parts := key.split(":")
		if parts.size() != 7:
			continue
		_edits[key] = int(edits[k])
	# _blocks is keyed by the string from _key(), not by Vector3i, so the
	# position has to be parsed back out to rebuild the edit prefix.
	for k in _blocks.keys():
		var block_key := String(k)
		var parts := block_key.split(":")
		if parts.size() != 4:
			continue
		var pos := Vector3i(int(parts[1]), int(parts[2]), int(parts[3]))
		var block: VoxelBlock = _blocks[block_key]
		_apply_edits(block, pos)
		_dirty[block_key] = true


func set_texture_mapping(m: int) -> void:
	texture_mapping = m
	if materials == null:
		return
	materials.set_mapping(m)
	rebind_materials()


## Render the world with lighting ignored, so a capture shows geometry and
## albedo alone. This is the baseline stage of the rendering diagnostic: if
## the world looks wrong unshaded, no amount of lighting or post-processing
## tuning is going to help, and that is worth knowing before touching any of
## them.
func set_unlit(on: bool) -> void:
	if materials == null:
		return
	materials.set_unlit(on)
	_rebind_all()
	rebind_materials()


## Draw surface normals as colour. A back-face culled or mis-wound face shows
## up here as a missing or mismatched colour region, which is otherwise very
## hard to attribute.
func set_normal_debug(on: bool) -> void:
	if materials == null:
		return
	materials.set_normal_debug(on)
	# Chunks meshed after this point must pick the override up too, so record
	# it and let _bind_surfaces ask the library rather than assuming the
	# material chosen at mesh time is still right.
	_rebind_all()
	rebind_materials()


## Force every live surface back through material_for() right now.
func _rebind_all() -> void:
	for store in [_meshes, _trans_nodes]:
		for key in store.keys():
			var mi: MeshInstance3D = store[key]
			if mi == null or not is_instance_valid(mi) or mi.mesh == null:
				continue
			_bind_surfaces(mi, mi.mesh)


## Force every surface onto a flat, untextured material. Separates "the
## texture set for this block is wrong" from "the geometry for this block is
## wrong", which look identical in a textured capture.
func set_material_override(on: bool) -> void:
	if materials == null:
		return
	materials.set_flat_override(on)
	_rebind_all()
	rebind_materials()
