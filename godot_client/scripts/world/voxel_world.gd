class_name VoxelWorld
extends Node3D
## Loaded by path as well as by name: the terrain adapter must resolve in a
## headless run, where nothing has regenerated the global class cache.
const ArnisSource := preload("res://scripts/world/arnis_terrain_source.gd")
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

## Chunk occlusion culling is deliberately ABSENT, and there is no switch to
## turn it back on.
##
## A voxel chunk is not a solid object. It is a 16^3 lattice that is mostly
## air above the surface and riddled with caves, slopes and gaps below it, so
## the only shape that could stand in for the whole chunk was a BoxOccluder3D
## covering its entire 16x16x16 footprint. That box claims the empty sky above
## a hill blocks the view, and the renderer then discards terrain the player
## can plainly see. It never shows up as a crash or a missing triangle -- it
## shows up as ground that vanishes as you walk toward it, which is exactly
## what the hardware-GPU captures caught.
##
## Until an occluder can be derived from the chunk's actual geometry, the
## correct answer is no occluder. Godot's frustum culling, the explicit
## `CULL_AABB`, `extra_cull_margin` and `visibility_range_end` already do
## every culling step that is safe to do here, and one wrongly-culled chunk
## costs far more than all the draw calls a box would ever save.
@export var world_dir := ""
@export var view_radius := 5
@export var build_budget := 2
## Active dimension: WorldGenerator.DIM_OVERWORLD or WorldGenerator.DIM_DEEPS.
@export var dimension := 0
## How block textures are projected: 0 plain, 1 triplanar, 2 parallax (POM),
## 3 stochastic triplanar (vendored shader).
@export_enum("Plain", "Triplanar", "Parallax", "Stochastic", "Slope") var texture_mapping := 2

var generator: WorldGenerator
var materials: MaterialLibrary

var _blocks := {}          # "dim:x:y:z" -> VoxelBlock
var _meshes := {}          # "dim:x:y:z" -> MeshInstance3D
var _trans_nodes := {}     # "dim:x:y:z" -> MeshInstance3D
var _dirty := {}           # key -> true
## Monotonic counter that makes every mesh generation id unique across the
## whole session. Per-chunk ids are carved out of it, so an id handed out
## before a chunk was unloaded can never collide with one handed out after it
## was loaded again -- which is what stops a stale worker result from
## resurrecting geometry for a chunk that has since been regenerated.
var _gen_counter := 0
## The current mesh generation for each chunk: key -> generation id.
## Bumped whenever the chunk's data changes (dirty) and again whenever a job
## for it is submitted.
var _mesh_generation := {} # key -> int
## The generation of the job currently expected for a chunk: key -> id.
## Distance is scheduling priority only -- it is NOT identity, because two
## different mesh generations of the same chunk can sit at the exact same
## focus distance.
var _pending_mesh := {}    # key -> generation id
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

## Optional terrain layer (a `TerrainLayer`) that draws the *ground surface*
## with Terrain3D. Null by default, and that default is not a configuration
## detail: with no layer this class meshes exactly what it always meshed.
##
## The handoff is one-directional and narrow. Terrain3D never generates,
## never decides where terrain is, and never touches voxel data; the voxels
## stay authoritative for gameplay, collision, caves and every edit. All the
## layer gets is permission to draw the *upward faces of ground blocks* in a
## chunk it has complete authoritative coverage of -- and this class takes
## that permission back the moment coverage is lost, because the renderer
## holding all the data must be the one that draws.
var ground_layer: Object = null
## Chunk key -> whether its ground is currently handed to `ground_layer`.
## Kept per resident chunk so a coverage change re-meshes only the chunks
## whose status actually changed rather than the whole view.
var _ground_handoff := {}


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
			clampi(materials.mapping() if materials != null else 0, 0,
				MaterialLibrary.mapping_name().size() - 1)],
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
	# Phase 1 -- the region the caller actually asked for.
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

	if not mesh_enabled:
		return loaded

	# Phase 2 -- the neighbours those chunks need in order to be meshed at all.
	#
	# A chunk is meshed only when all 26 neighbours exist, so the outer ring of
	# the requested sphere can never be meshed from the sphere alone: every one
	# of them wants a diagonal neighbour one step outside it. Without this ring
	# `ensure_region` returned a region that was loaded and had no geometry,
	# which is the exact bug being fixed -- so the ring is every neighbour of
	# every chunk in the region, and nothing wider.
	var need := {}
	for dx in range(-radius, radius + 1):
		for dy in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				if dx * dx + dy * dy + dz * dz > r2:
					continue
				var p := centre + Vector3i(dx, dy, dz)
				for ox in [-1, 0, 1]:
					for oy in [-1, 0, 1]:
						for oz in [-1, 0, 1]:
							need[p + Vector3i(ox, oy, oz)] = true
	for np in need.keys():
		if not _blocks.has(_key(np)):
			_load_chunk(np)

	# Phase 3 -- sweep every chunk of the region and APPLY the results.
	#
	# `_load_chunk` only marks things dirty; the budgeted scheduler is not
	# running here, so nothing else would ever submit them. The loop stops
	# when no chunk of the region is both dirty and meshable, or when it stops
	# making progress -- saturation is cleared by the flush at the end of each
	# pass, so a pass that submitted nothing still advances the state.
	var keys := []
	for dx in range(-radius, radius + 1):
		for dy in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				if dx * dx + dy * dy + dz * dz > r2:
					continue
				keys.append(_key(centre + Vector3i(dx, dy, dz)))
	for _attempt in range(keys.size() + 4):
		var pending := 0
		for k in keys:
			if _dirty.has(k) and _blocks.has(k) \
					and _can_mesh(_key_pos(String(k))):
					pending += 1
		if pending == 0:
			break
		for k in keys:
			var key := String(k)
			if not _dirty.has(key) or not _blocks.has(key):
				continue
			if not _can_mesh(_key_pos(key)):
				continue
			_submit_mesh(key)
		flush_meshing()

	# Phase 4 -- verify. The contract is "loaded AND meshed", so a chunk that
	# should have geometry but does not is reported rather than silently
	# returned to a caller that is about to walk onto it.
	var unmeshed := 0
	for k in keys:
		var key := String(k)
		if not _blocks.has(key):
			continue
		if not _can_mesh(_key_pos(key)):
			continue
		var mi: MeshInstance3D = _meshes.get(key, null)
		if mi == null or _dirty.has(key) or _pending_mesh.has(key):
			unmeshed += 1
	if unmeshed > 0:
		push_warning(("ensure_region: %d chunk(s) in the region still have no "
			+ "applied mesh") % unmeshed)
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
	# An authoritative converted world must not be reinterpreted by the
	# procedural generator. If the chunk is absent from an authoritative world,
	# the correct answer is the chunk is genuinely missing, not "generate it
	# procedurally".
	if dimension == WorldGenerator.DIM_OVERWORLD \
			and world_dir != "" and ChunkFiles.is_authoritative(world_dir):
		return null
	if dimension == WorldGenerator.DIM_OVERWORLD:
		return generator.generate_block(pos)
	return generator.generate_deeps_block(pos)


## The scheduler's generate callback. Returns false when the chunk could not
## be produced, which the scheduler counts as a cancellation.
func _generate_job(p: Vector3i) -> bool:
	if _blocks.has(_key(p)):
		return true
	return _load_chunk(p)


## Hand the ground over to a terrain layer, or take it back with `null`.
##
## `set_ground_layer(null)` is a supported, tested state: everything goes back
## to the voxel mesher, which is what the terrain layer does at a streaming
## boundary and what a build without the addon always does.
func set_ground_layer(layer: Object) -> void:
	if ground_layer == layer:
		return
	if ground_layer != null and is_instance_valid(ground_layer) \
			and ground_layer.has_signal("coverage_changed") \
			and ground_layer.coverage_changed.is_connected(_on_ground_coverage_changed):
		ground_layer.coverage_changed.disconnect(_on_ground_coverage_changed)
	ground_layer = layer
	if ground_layer != null and is_instance_valid(ground_layer) \
			and ground_layer.has_signal("coverage_changed"):
		ground_layer.coverage_changed.connect(_on_ground_coverage_changed)
	_refresh_ground_handoff(true)


## The layer's coverage moved: re-decide every resident chunk and re-mesh the
## ones that changed hands. A chunk that starts or stops being covered has a
## different set of faces to draw, and no other event would ever tell this
## class that.
func _on_ground_coverage_changed() -> void:
	_refresh_ground_handoff(false)


func _refresh_ground_handoff(force: bool) -> void:
	for key in _blocks.keys():
		var pos := _key_pos(String(key))
		var covered := _ground_covered(pos)
		var had: bool = bool(_ground_handoff.get(key, false))
		if covered == had and not force:
			continue
		_ground_handoff[key] = covered
		if covered != had:
			_mark_dirty(String(key))


## Can the terrain layer draw every upward ground face of this chunk? Only
## when it has complete authoritative coverage of it, so a chunk with even one
## hole in the layer keeps its own surface and no hole is ever visible.
func _ground_covered(pos: Vector3i) -> bool:
	if ground_layer == null or not is_instance_valid(ground_layer):
		return false
	if dimension != WorldGenerator.DIM_OVERWORLD:
		return false
	return bool(ground_layer.covers_chunk(pos))


## The mask `GreedyMesher` takes: one byte per voxel, set when the voxel is
## terrain whose upward face the terrain layer is drawing.
func _hidden_tops(pos: Vector3i, key: String) -> PackedByteArray:
	if not bool(_ground_handoff.get(key, false)):
		return PackedByteArray()
	var block: VoxelBlock = _blocks.get(key, null)
	if block == null:
		return PackedByteArray()
	var lut := ArnisSource.ground_lut()
	var mask := PackedByteArray()
	mask.resize(MapNode.BLOCK_VOLUME)
	var content: PackedInt32Array = block.content
	for i in MapNode.BLOCK_VOLUME:
		var cid: int = content[i]
		if cid >= 0 and cid < lut.size():
			mask[i] = lut[cid]
	return mask


## Next mesh generation id. One global counter, so an id handed out before a
## chunk was unloaded can never be reused once it is loaded again -- which is
## what stops a stale worker result from resurrecting geometry for a chunk
## that has since been regenerated.
func _next_generation() -> int:
	_gen_counter += 1
	return _gen_counter


## Publish a fresh generation for a chunk. Called when its data changes and
## again when a job for it is submitted; a result computed from an older
## generation is stale by definition and is discarded on arrival.
func _bump_generation(key: String) -> int:
	var gen := _next_generation()
	_mesh_generation[key] = gen
	return gen


## Mark a chunk dirty, retiring whatever generation its in-flight sweep was
## reading. This is the whole point of the scheme: an edit that lands while a
## worker holds a copy of the old data invalidates that copy the instant the
## edit happens, not when the result comes back.
func _mark_dirty(key: String) -> void:
	_dirty[key] = true
	_bump_generation(key)


## The scheduler's mesh callback: the nearest chunk that is ready to be meshed.
## Takes no argument -- the mesh queue is "which dirty chunk is nearest and
## ready", which is a question about the world, not about the job.
##
## This only *submits*. The sweep runs on a worker thread and the resulting
## ArrayMesh is built in `_process`, so the frame pays for a dictionary push
## rather than for meshing.
#### With `async_meshing` off the whole thing runs inline instead, and the chunk
## is meshed before this returns. Both paths share the gather, the staleness
## check and the scene-graph update; the only difference is which thread the
## sweep runs on, so the geometry a test sees is the same either way.
func _mesh_job() -> bool:
	var key := _nearest_meshable()
	if key == "":
		return false
	# Accepted-but-saturated still returns true: something WAS ready, so the
	# scheduler must not record it as "deferred waiting on a neighbour".
	_submit_mesh(key)
	return true


## Sweep one specific chunk: gather, reserve its generation, then either mesh
## it inline or hand it to the worker. Returns false only when the pool is
## saturated -- the chunk stays dirty and the caller retries after a flush.
func _submit_mesh(key: String) -> bool:
	if not _blocks.has(key):
		return false
	var pos := _key_pos(key)
	var data := _gather_neighbours(pos, key)
	var d2 := _focus_dist2(pos)
	# The generation is reserved before the data is copied, so the worker
	# result carries the identity of the exact state it was computed from.
	var gen := _bump_generation(key)
	var hidden := _hidden_tops(pos, key)
	if not async_meshing:
		var meshes := GreedyMesher.to_meshes(
			GreedyMesher.geometry(data["block"], data["neighbours"], hidden))
		_mesh_chunk(pos, key, meshes[0], meshes[1])
		_dirty.erase(key)
		_pending_mesh.erase(key)
		return true
	if not _mesh_worker.submit(key, pos, data["block"], data["neighbours"], d2,
			gen, hidden):
		# Saturated: leave it dirty so the next frame tries again. This is
		# back-pressure, not a cancellation, so it must not read as failure.
		# The generation was reserved but never published to the worker, so
		# the next attempt simply takes a new one.
		return false
	_pending_mesh[key] = gen
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
	_mesh_generation.clear()



func _mark_neighbours_dirty(pos: Vector3i) -> void:
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				if dx == 0 and dy == 0 and dz == 0:
					continue
				var n := pos + Vector3i(dx, dy, dz)
				var nk := _key(n)
				if _blocks.has(nk):
					_mark_dirty(nk)
	_mark_dirty(_key(pos))


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
	# A chunk that arrives inside the terrain layer's coverage starts out
	# handed over, so walking back into an area does not briefly draw the
	# ground twice.
	_ground_handoff[key] = _ground_covered(pos)
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
	_ground_handoff.erase(key)
	_blocks.erase(key)
	_dirty.erase(key)
	# Forget any in-flight job for it, and drop its generation id. The result
	# will still arrive if a worker already had the block, and `_apply_meshed`
	# drops it because `_blocks` no longer has the key -- and even if the chunk
	# is loaded again before the result lands, the reloaded chunk is handed a
	# NEW id from the global counter, so the old result can never match.
	_pending_mesh.erase(key)
	_mesh_generation.erase(key)
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
	# pre-edit data, so its result is stale. `_mark_dirty` retires that sweep's
	# generation the instant the edit lands, `_apply_meshed` sees the
	# generation no longer matches and throws the result away instead of
	# installing it, and the next `_mesh_job` re-queues the chunk. The flag is
	# therefore never cleared while a job is outstanding.
	_mark_dirty(key)
	for axis in 3:
		for step in [-1, 1]:
			var off := Vector3i.ZERO
			off[axis] = step
			var nkey := _key(bpos + off)
			if _blocks.has(nkey):
				_mark_dirty(nkey)
	# The terrain surface is derived from these voxels, so an edit is also a
	# change to the terrain layer's height at that column. The layer coalesces
	# these into one map update per frame; nothing here rebuilds anything.
	if ground_layer != null and is_instance_valid(ground_layer):
		ground_layer.notify_block_changed(world_pos)
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
## Staleness is decided by the mesh GENERATION id, never by focus distance.
## Distance is not identity: two different mesh generations of the same chunk
## can sit at exactly the same distance from the player, so a distance check
## accepts an old result that happens to have been queued from where the
## player now stands. The generation id is reserved when the job is submitted,
## carried through the worker, and compared on arrival against the chunk's
## current generation -- they must be equal or the result is discarded.
##
## That is what makes async meshing safe: a player who mines a block while its
## chunk is being swept gets the edit re-meshed instead of watching it vanish
## until something else happened to dirty the chunk, and a generation-1 result
## arriving after a generation-2 result can never overwrite it.
func _apply_meshed(result: Dictionary) -> void:
	var key := String(result["key"])
	var pos: Vector3i = result["pos"]
	var qgen: int = result["gen"]
	var was_pending: int = int(_pending_mesh.get(key, -1))
	var current: int = int(_mesh_generation.get(key, -1))
	# Only the result that IS the awaited generation may clear the slot. A
	# stale result arriving first must not erase the newer job's record, or
	# the newer result would then find nothing waiting and discard itself.
	if qgen == was_pending:
		_pending_mesh.erase(key)
	# The chunk may have been unloaded, or the dimension switched, while the
	# worker had it. Its mesh is about to be hidden or rebuilt.
	if not _blocks.has(key):
		return
	# A newer job was queued for this chunk after this one, or its data
	# changed since: this result describes superseded geometry. Drop it and
	# let the newer generation win, whichever order the two arrive in.
	if qgen != current or qgen != was_pending:
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


## Chunk occlusion culling is intentionally disabled -- see the note on
## `dimension` at the top of this file. There is no `_update_occluder` and no
## `set_occluders` any more: the full-chunk BoxOccluder3D they built is the
## thing that hid visible terrain, and leaving a disabled switch behind would
## only invite the same bug back in. Frustum culling, `CULL_AABB`,
## `extra_cull_margin` and `visibility_range_end` cover the safe cases.


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
		_mark_dirty(block_key)


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
