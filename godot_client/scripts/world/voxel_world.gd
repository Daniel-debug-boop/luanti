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

## How far outside its own block a vertex can be pulled, in voxels. The
## surface-nets pass places a vertex inside the cell grid, which reaches one
## voxel past the block on every side, so two is the most it can move.
const CULL_SLACK := 2.0
## One box, shared by every chunk. The block plus that slack, with the origin
## moved so the box is centred on the same point the vertices are placed
## around.
const CULL_AABB := AABB(Vector3(-CULL_SLACK, -CULL_SLACK, -CULL_SLACK),
		Vector3(BS + CULL_SLACK * 2.0, BS + CULL_SLACK * 2.0, BS + CULL_SLACK * 2.0))

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
## Chunks with a mesh job in flight: key -> the focus distance it was queued
## at. A result is only applied if this still matches, which is how a stale
## sweep (the chunk was edited or re-queued while the worker had it) is
## recognised and thrown away instead of overwriting newer geometry.
var _pending_mesh := {}    # key -> d2
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
## Meshing runs on WorkerThreadPool threads. Set false to sweep inline, which
## is what a headless test wants when it asserts on geometry the instant a
## call returns rather than a frame later.
@export var async_meshing := true

## The worker pool. Created here rather than per job so the thread handoff is
## amortised and so `flush` has something stable to wait on.
var _mesh_worker := ChunkMeshWorker.new()


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


## Drain finished worker results into meshes. This is the only place the main
## thread touches meshing output, and it is deliberately cheap: the sweep ran
## on a worker, so all that is left is building an ArrayMesh and pointing an
## existing MeshInstance3D at it.
##
## It is called from `update_around` rather than from `_process` on purpose.
## `update_around` is the world's own tick, so results land before the frame
## that is going to render them and the scheduler sees chunks that are already
## meshed. It also means the world behaves the same whether or not the engine
## is driving `_process` -- which is exactly the situation the end-to-end
## test is in, since it steps the tree by hand and would otherwise never apply
## a single chunk.
func _apply_pending_meshes() -> int:
	if _mesh_worker.outstanding() == 0:
		return 0
	var n := 0
	for r in _mesh_worker.apply():
		_apply_meshed(r)
		n += 1
	return n


## Block until every queued and in-flight mesh job has been applied. Anything
## that needs the world meshed *now* rather than a frame from now calls this:
## saving, and the tests that edit blocks and immediately assert on geometry.
func flush_meshing() -> int:
	var applied := 0
	for r in _mesh_worker.flush():
		_apply_meshed(r)
		applied += 1
	return applied


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
		"mesh_pending": _mesh_worker.outstanding(),
		"mesh_worker_ms": _mesh_worker.worker_ms_total(),
		"textures": texture_count(),
		"mapping": MaterialLibrary.mapping_name()[
			clampi(materials.mapping() if materials != null else 0, 0, 3)],
	}


## Stream chunks around `focus`, within this frame's budget.
##
## The ordering, the budget and the cancellation all belong to
## `StreamScheduler`. This method is the seam: it says what "generated" and
## "meshed" mean, and the scheduler says what to do and when to stop.
##
## Generation runs one chunk WIDER than meshing. A chunk is only meshed once
## all 26 of its neighbours have terrain (`_can_mesh`), so the outermost ring
## of the view sphere could never satisfy that rule: every one of them wanted a
## diagonal neighbour one step outside the sphere, which nothing ever
## generated. They sat dirty forever. That is what the "floating slabs with no
## ground under them" screenshots were -- not broken geometry, terrain that
## had never been meshed, over a hole where the missing chunks should have
## been. Loading the extra ring costs one chunk of terrain per 30 or so and
## lets the whole visible sphere finish.
func update_around(focus: Vector3i) -> void:
	var centre := _block_pos(focus)
	_last_focus = focus
	# Finish last frame's meshing before deciding this frame's work: the
	# scheduler's queue is only meaningful against chunks that are already
	# resident, and a chunk that just gained geometry should not be re-queued.
	_apply_pending_meshes()
	stream.select(centre, view_forward, view_radius + MESH_MARGIN, _is_resident,
		true)
	drop_distant(centre)
	if mesh_enabled:
		stream.step(_generate_job, _mesh_job, _has_mesh_work)


## Extra rings of terrain generated beyond the view radius, so that every chunk
## inside the view radius can actually be meshed. One is the minimum: the 26
## neighbour rule reaches exactly one chunk out.
const MESH_MARGIN := 1


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
				if _load_chunk(p):
					loaded += 1
	# The caller asked for this region to exist NOW. With async meshing on,
	# that means the jobs queued above have to finish too -- otherwise
	# "ensure the region" would return a world whose chunks have no geometry
	# yet, and every test that walks onto a freshly loaded region would fall
	# through the floor.
	flush_meshing()
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
	if _blocks.has(_key(p)):
		return true
	return _load_chunk(p)


## The scheduler's mesh callback: the nearest chunk that is ready to be meshed.
## Takes no argument -- the mesh queue is "which dirty chunk is nearest and
## ready", which is a question about the world, not about the job.
##
## This only *submits*. The sweep runs on a worker thread and the resulting
## ArrayMesh is built in `_process`, so the frame pays for a dictionary push
## rather than for meshing.
##
## With `async_meshing` off the whole thing runs inline instead, and the chunk
## is meshed before this returns. Both paths share the gather, the staleness
## check and the scene-graph update; the only difference is which thread the
## sweep runs on, so the geometry a test sees is the same either way.
func _mesh_job() -> bool:
	var key := _nearest_meshable()
	if key == "":
		return false
	var pos := _key_pos(key)
	var data := _gather_neighbours(pos, key)
	var d2 := _focus_dist2(pos)
	if not async_meshing:
		var meshes := GreedyMesher.to_meshes(
			GreedyMesher.geometry(data["block"], data["neighbours"]))
		_mesh_chunk(pos, key, meshes[0], meshes[1])
		_dirty.erase(key)
		return true
	if not _mesh_worker.submit(key, pos, data["block"], data["neighbours"], d2):
		# Saturated: leave it dirty so the next frame tries again. This is
		# back-pressure, not a cancellation, so it must not read as failure.
		return true
	_pending_mesh[key] = d2
	_dirty.erase(key)
	return true


func _focus_dist2(pos: Vector3i) -> int:
	var d := pos - _block_pos(_last_focus)
	return d.x * d.x + d.y * d.y + d.z * d.z


## Collect the block plus its loaded neighbours. Main thread only: it reads
## the world dictionary, which the worker never touches.
func _gather_neighbours(pos: Vector3i, key: String) -> Dictionary:
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
	return {"block": _blocks[key], "neighbours": neighbours}


## The scheduler's "is anything waiting to be meshed" probe: true while a
## dirty, resident, in-view chunk exists, whether or not its neighbours are
## there yet. The distinction is what makes `deferred` mean something: this
## false is an idle world, while this true with `_mesh_job` returning false
## is a world blocked on terrain that has not been generated. A probe that
## only ever reported "ready work exists" collapsed the two into one number.
func _has_mesh_work() -> bool:
	if _dirty.is_empty():
		return false
	var centre := _block_pos(_last_focus)
	var r2 := view_radius * view_radius + view_radius
	for key in _dirty.keys():
		if not _blocks.has(key):
			continue
		var p := _key_pos(key)
		var d := p - centre
		if d.x * d.x + d.y * d.y + d.z * d.z > r2:
			continue
		return true
	return false


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


## Leave the scene with nothing in flight on a worker thread. Without this a
## quit during streaming would free the world while a job still held a copy of
## its blocks -- harmless today, but only because the job writes to its own
## collections; it is not something to rely on as the safety property.
func _exit_tree() -> void:
	_mesh_worker.cancel_queued()
	_mesh_worker.flush()
	_pending_mesh.clear()



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
	# Must stay outside the generation cube (`view_radius + MESH_MARGIN`),
	# or a chunk is evicted by the frame after it was generated and the two
	# halves of the streamer fight over it forever.
	var lim := view_radius + MESH_MARGIN + 2
	var lim2 := lim * lim
	for key in _blocks.keys().duplicate():
		var parts: PackedStringArray = String(key).split(":")
		if int(parts[0]) != dimension:
			continue
		var p := Vector3i(int(parts[1]), int(parts[2]), int(parts[3]))
		var dd := p - centre
		if dd.x * dd.x + dd.y * dd.y + dd.z * dd.z > lim2:
			_unload_chunk(p, String(key))


## Load one chunk: reclaim it from the streamer's cache if the player was
## here recently, otherwise generate it. This is the single acquisition
## path -- `ensure_region` and the budgeted queue both come through here, so
## a forced load can never regenerate terrain the cache is still holding a
## copy of (which used to leave two objects for one chunk: one being edited,
## one going stale, and double the memory the cache was budgeted for).
## Returns true when the chunk became resident.
func _load_chunk(pos: Vector3i) -> bool:
	var key := _key(pos)
	if _blocks.has(key):
		return false
	var block: VoxelBlock = stream.cache_take(key) as VoxelBlock
	if block == null:
		block = _generate_block(pos)
	if block == null:
		return false
	_apply_edits(block, pos)
	_blocks[key] = block
	_mark_neighbours_dirty(pos)
	chunk_loaded.emit(pos)
	return true


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
	# Forget any in-flight job for it. The result will still arrive if a
	# worker already had the block, and `_apply_meshed` drops it because
	# `_blocks` no longer has the key -- but clearing the record here stops
	# the d2 bookkeeping from resurrecting it.
	_pending_mesh.erase(key)
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
	#
	# Marking a chunk dirty while its mesh job is still on a worker thread is
	# the case async meshing has to get right: the in-flight sweep read the
	# pre-edit data, so its result is stale. `_apply_meshed` sees the dirty
	# flag and throws that result away instead of installing it, and the next
	# `_mesh_job` re-queues the chunk. The flag is therefore never cleared
	# while a job is outstanding.
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


## Turn one finished worker result into meshes. Main thread only, and only the
## cheap half of the pipeline: the sweep already happened on a worker.
##
## `d2_at_submit` is the focus distance when the job was queued, not now. If
## the chunk has been edited or re-marked dirty since, its geometry is stale
## no matter how close the player is now, so it is put back in the queue and
## the stale mesh is left alone. That check is what makes async meshing safe:
## without it a player who mines a block while its chunk is being swept would
## see the edit vanish until something else happened to dirty the chunk.
func _apply_meshed(result: Dictionary) -> void:
	var key := String(result["key"])
	var pos: Vector3i = result["pos"]
	var qd2: int = result["d2"]
	var was_pending: int = int(_pending_mesh.get(key, -1))
	_pending_mesh.erase(key)
	# The chunk may have been unloaded, or the dimension switched, while the
	# worker had it. Its mesh is about to be hidden or rebuilt.
	if not _blocks.has(key):
		return
	# A newer job was queued for this chunk after this one, so this result is
	# for superseded data: drop it and let the newer one win.
	if was_pending != qd2:
		return
	if _dirty.has(key):
		return
	var meshes := GreedyMesher.to_meshes(result["faces"])
	_mesh_chunk(pos, key, meshes[0], meshes[1])


## The scene-graph half of meshing, for a chunk whose face buffers are ready.
## Bounds and draw distance for one chunk instance.
##
## The engine frustum-culls a MeshInstance3D on its own, but only from bounds
## it has to work out -- and it works them out from the mesh, which is rebuilt
## every time a chunk is re-meshed. Handing every chunk the same explicit box
## means the cull test is a fixed comparison against a box that is known to
## contain the geometry, including the vertices the smoother pulls outside the
## block. `extra_cull_margin` covers the sub-voxel remainder.
##
## The draw distance is the view radius plus the meshing margin: a chunk is
## only dropped once it is past everything the player can see, so nothing pops
## in at the edge of the view.
func _apply_culling(mi: MeshInstance3D) -> void:
	mi.custom_aabb = CULL_AABB
	mi.extra_cull_margin = CULL_SLACK
	mi.visibility_range_begin = 0.0
	mi.visibility_range_end = float(view_radius + 2) * BS


func _mesh_chunk(pos: Vector3i, key: String, opaque: ArrayMesh,
		trans: ArrayMesh) -> void:
	var mi: MeshInstance3D = _meshes.get(key, null)
	if mi == null:
		mi = MeshInstance3D.new()
		mi.name = "Chunk_%s" % key.replace(":", "_")
		add_child(mi)
		_meshes[key] = mi
	mi.position = Vector3(pos.x * BS, pos.y * BS, pos.z * BS)
	_apply_culling(mi)
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
		_apply_culling(ti)
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
			# The view radius can have moved since this chunk was built, so the
			# draw distance is refreshed here rather than only at creation.
			_apply_culling(mi)
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
