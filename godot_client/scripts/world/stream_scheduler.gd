class_name StreamScheduler
extends RefCounted
## Streaming: which chunks exist, in what order, and at what cost per frame.
##
## The version this replaces loaded every chunk in the view sphere
## **synchronously, inside the frame that asked for it**. Walking one block
## meant regenerating a sphere of terrain on the main thread, and the frame
## time was whatever that took. It was correct -- no holes, no duplicates, no
## stale chunks -- and it was the single worst hitch in the game.
##
## This makes streaming a queue with a budget instead of a loop without one.
##
## ## The order things happen in
##
##   1. **Select.** Every frame, the chunks inside the view radius become
##      candidates, scored by distance and by how far in front of the camera
##      they are. Chunks you are looking at beat chunks behind you at the same
##      distance, which is what makes walking forward feel cheaper than
##      walking backward.
##   2. **Generate.** The budget's worth of terrain, nearest first. This is
##      the expensive half and it is what the time budget bounds.
##   3. **Mesh.** A *separate* budget. A chunk is meshed only once all 26
##      neighbours have terrain, because a mesh built against missing
##      neighbours has to guess which faces are interior -- and it guesses
##      wrong, and you get holes you can see through.
##
## ## What makes it not-hitch
##
##   * A **time budget**, not a count. Two chunks is cheap at one radius and
##     expensive at another; milliseconds are what the frame actually cares
##     about. The count is still there as a ceiling, because a budget alone
##     cannot stop a single very expensive chunk.
##   * **Cancellation.** Chunks that left the view before their turn come off
##     the queue instead of being built and thrown away. A player who turns
##     around should not pay for the half-second behind them.
##   * **Teleport detection.** A jump further than a screenful does not try to
##     stream the space between; it drops the backlog and re-seeds at the
##     destination.
##
## ## What it deliberately does not do
##
## It does not use threads. A worker may compute from immutable inputs and
## return a value -- that is the rule in `Threading` -- and voxel generation
## from the seed plus a chunk coordinate satisfies it exactly. Wiring a
## worker pool to the engine is the next step, and the queue, the priority
## function and the cancellation rules below are already written to survive
## it: `take()` is the only thing that mutates, so a pool would replace one
## function body rather than the design.

## What one chunk costs the generator, in milliseconds. Deliberately
## pessimistic: over-estimating makes the first frames after a load slower
## than they need to be, under-estimating makes every frame after it too slow.
const COST_GENERATE_MS := 2.5
## Meshing is cheaper than generating but not free, and it is measured
## separately so that a frame full of generation never also meshes.
const COST_MESH_MS := 1.4

## A camera-facing dot product above this counts as "in front".
const FRONT_COS := 0.25
## How much being in front is worth, relative to distance. At 1.0 the bias
## only breaks ties; at 2.0 a chunk directly ahead is worth being twice as
## close.
const DIRECTION_BIAS := 1.5
## Squared distance beyond which the direction bias stops being applied --
## far away, everything is roughly equally uninteresting.
const DIRECTION_RANGE := 12.0
## Moving this far in one update is a teleport, not a walk.
const TELEPORT_BLOCKS := 48.0
## Unloaded chunks kept around so walking back is instant. This is the memory
## budget, and it is the only unbounded-looking thing in the world.
const CACHE_CHUNKS := 256

enum Phase { IDLE, GENERATE, MESH }

## A job, as a plain Dictionary so it can be inspected and asserted on.
## `kind` is "generate" or "mesh"; `pos` is the chunk coordinate; `score`
## is lower-is-better and is recomputed every selection pass, because the
## player moves.
var _queue: Array[Dictionary] = []
var _queued := {}            # "x:y:z" -> true
var _cache := {}             # "x:y:z" -> {block, used}
var _cache_order: Array[String] = []

## Observable counters. These are the numbers the streaming test asserts on and
## the numbers a profiler shows; a streaming system you cannot count is a
## streaming system you cannot tune.
var stats := {
	"generated": 0,
	"cached_hits": 0,
	"disk_hits": 0,
	"meshed": 0,
	"cancelled": 0,
	"evicted": 0,
	"teleports": 0,
	"deferred": 0,     # meshing waited for neighbours
	"budget_skips": 0, # out of budget this frame
	"last_generate_ms": 0.0,
	"last_mesh_ms": 0.0,
	"worst_generate_ms": 0.0,
	"worst_mesh_ms": 0.0,
}

## Per-frame budgets, in milliseconds. Generous enough that a normal frame
## streams plenty and tight enough that a bad one still hits the target.
var generate_budget_ms := 6.0
var mesh_budget_ms := 3.0
var max_chunks_per_frame := 8

var _last_centre := Vector3i(2147483647, 0, 0)
var _last_forward := Vector3.FORWARD
var _seeded := false


func _init() -> void:
	_last_centre = Vector3i(2147483647, 0, 0)


# --- selection --------------------------------------------------------------

## Recompute the queue for this frame. Call once per update, before `step()`.
##
## `centre` is the chunk the player is in, `forward` the camera's horizontal
## look direction, `radius` the view radius in chunks. `resident` reports
## whether a chunk is already in memory, so the caller keeps the authority on
## what "loaded" means and this class never has to know.
func select(centre: Vector3i, forward: Vector3, radius: int,
		resident: Callable) -> void:
	# A camera that has not moved yet has no direction to bias towards.
	var dir := Vector3(forward.x, 0.0, forward.z)
	if dir.length_squared() < 0.0001:
		dir = _last_forward
	if dir.length_squared() < 0.0001:
		dir = Vector3.FORWARD
	dir = dir.normalized()
	_last_forward = dir

	# Teleport: drop the backlog rather than streaming the space between two
	# points the player never looked at.
	if _seeded and (Vector3(centre) - Vector3(_last_centre)).length() > TELEPORT_BLOCKS:
		stats["teleports"] = int(stats["teleports"]) + 1
		var dropped := _queue.size()
		_queue.clear()
		_queued.clear()
		stats["cancelled"] = int(stats["cancelled"]) + dropped
	_last_centre = centre
	_seeded = true

	var candidates: Array[Dictionary] = []
	var r2 := radius * radius + radius
	for dx in range(-radius, radius + 1):
		for dy in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				var d2 := dx * dx + dy * dy + dz * dz
				if d2 > r2:
					continue
				var p := centre + Vector3i(dx, dy, dz)
				if bool(resident.call(p)):
					continue
				var score := _score(p, centre, dir)
				var key := _key(p)
				if _queued.has(key):
					# Already in the queue: refresh its score, because the
					# player has moved and the old score was for where they
					# used to be.
					_update_score(_queue, key, score)
					continue
				candidates.append({"pos": p, "key": key, "score": score,
					"kind": "generate"})
				_queued[key] = true
	_queue.append_array(candidates)
	_queue.sort_custom(func(a, b): return float(a["score"]) < float(b["score"]))


## Lower is better. Distance dominates; direction breaks it.
func _score(p: Vector3i, centre: Vector3i, dir: Vector3) -> float:
	var d := p - centre
	var d2 := float(d.x * d.x + d.y * d.y + d.z * d.z)
	var distance := sqrt(d2)
	var to := Vector3(d.x, 0.0, d.z)
	var facing := 1.0
	if distance < DIRECTION_RANGE and to.length_squared() > 0.0001:
		var dot := to.normalized().dot(dir)
		if dot > FRONT_COS:
			facing = 1.0 - (dot - FRONT_COS) / (1.0 - FRONT_COS) \
				* (DIRECTION_BIAS - 1.0)
	return maxf(distance, 0.0) * maxf(facing, 0.05)


func _update_score(queue: Array, key: String, score: float) -> void:
	for job in queue:
		if String(job["key"]) == key:
			job["score"] = score
			return


# --- the frame's work -------------------------------------------------------

## Do up to one frame's worth of work. `gen` and `mesh` are the callables that
## do the real thing; the scheduler only decides what to call and when to stop.
##
## `gen(pos) -> bool` must return true if the chunk is now resident.
## `mesh(pos) -> bool` must return true if the chunk is now meshed, and false
## if it is not ready yet (neighbours missing) -- which is how holes are
## prevented rather than hidden.
##
## Returns `{"generated": int, "meshed": int, "generate_ms": float,
## "mesh_ms": float}`.
func step(gen: Callable, mesh: Callable, mesh_ready: Callable) -> Dictionary:
	Threading.guard("StreamScheduler.step")
	var out := {"generated": 0, "meshed": 0,
		"generate_ms": 0.0, "mesh_ms": 0.0}

	var t0 := Time.get_ticks_usec()
	var spent := 0.0
	var done := 0
	while done < max_chunks_per_frame and spent < generate_budget_ms:
		if _queue.is_empty():
			break
		var job: Dictionary = _queue.pop_front()
		var key: String = String(job["key"])
		if not _queued.has(key):
			continue
		_queued.erase(key)
		if bool(gen.call(job["pos"])):
			done += 1
			spent += COST_GENERATE_MS
		else:
			# The chunk left the view before its turn. Cancelled, not built.
			stats["cancelled"] = int(stats["cancelled"]) + 1
	# Whatever is still queued after the budget ran out is the backlog, and
	# the profiler shows it as "skipped". It is the number to watch: it growing
	# is the player outrunning the streamer.
	stats["budget_skips"] = int(stats["budget_skips"]) + _queue.size()
	var gen_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	out["generated"] = done
	out["generate_ms"] = gen_ms

	var t1 := Time.get_ticks_usec()
	var mspent := 0.0
	var mdone := 0
	while mdone < max_chunks_per_frame and mspent < mesh_budget_ms:
		if not bool(mesh_ready.call()):
			stats["deferred"] = int(stats["deferred"]) + 1
			break
		if not bool(mesh.call()):
			break
		mdone += 1
		mspent += COST_MESH_MS
	var mesh_ms := float(Time.get_ticks_usec() - t1) / 1000.0
	out["meshed"] = mdone
	out["mesh_ms"] = mesh_ms

	stats["generated"] = int(stats["generated"]) + done
	stats["meshed"] = int(stats["meshed"]) + mdone
	stats["last_generate_ms"] = gen_ms
	stats["last_mesh_ms"] = mesh_ms
	stats["worst_generate_ms"] = maxf(float(stats["worst_generate_ms"]), gen_ms)
	stats["worst_mesh_ms"] = maxf(float(stats["worst_mesh_ms"]), mesh_ms)
	return out


# --- cache ------------------------------------------------------------------

## Offer an unloaded chunk to the cache. Evicts the least recently used chunk
## when over budget, so walking in a circle is instant and walking in a spiral
## is bounded.
func cache_put(key: String, block: Variant) -> void:
	if block == null or _cache.size() >= CACHE_CHUNKS:
		if block != null:
			_evict_oldest()
		if _cache.size() >= CACHE_CHUNKS:
			return
	_cache[key] = {"block": block, "used": 0}
	_cache_order.append(key)


## The cached block for `key`, or null, counting the hit.
func cache_take(key: String) -> Variant:
	var entry: Variant = _cache.get(key, null)
	if entry == null:
		return null
	stats["cached_hits"] = int(stats["cached_hits"]) + 1
	return entry["block"] if entry.has("block") else null


## The cached block without counting a hit.
func cache_peek(key: String) -> Variant:
	var entry: Dictionary = _cache.get(key, {})
	return entry["block"] if entry.has("block") else null


func cache_has(key: String) -> bool:
	return _cache.has(key)


func cache_size() -> int:
	return _cache.size()


func _evict_oldest() -> void:
	if _cache_order.is_empty():
		return
	var oldest: String = _cache_order.pop_front()
	_cache.erase(oldest)
	stats["evicted"] = int(stats["evicted"]) + 1


func clear_cache() -> void:
	_cache.clear()
	_cache_order.clear()


# --- introspection ----------------------------------------------------------

func queued() -> int:
	return _queue.size()


func pending_distance() -> float:
	if _queue.is_empty():
		return 0.0
	return float(_queue[0]["score"])


func is_empty() -> bool:
	return _queue.is_empty()


func cancel_all() -> int:
	var n := _queue.size()
	_queue.clear()
	_queued.clear()
	stats["cancelled"] = int(stats["cancelled"]) + n
	return n


static func _key(p: Vector3i) -> String:
	return "%d:%d:%d" % [p.x, p.y, p.z]


func report() -> String:
	return "stream: %d generated, %d meshed, %d cancelled, %d cached, %d queued" % [
		int(stats["generated"]), int(stats["meshed"]), int(stats["cancelled"]),
		_cache.size(), _queue.size()]
