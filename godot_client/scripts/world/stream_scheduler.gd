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

## Fallback cost estimates for one chunk, in milliseconds, used only for a
## job whose duration was too small for the clock to resolve (sub-100 us).
##
## These are NOT what the budget spends. They used to be, and that is how a
## 130 ms frame hid behind a scheduler that believed the frame cost 1.4 ms
## per chunk and 6 ms of generation: the accounting charged a constant per
## job while the mesher actually took 83 ms, so the budget never ran out and
## the streamer happily ate the whole frame. The budget is now charged the
## clock's own answer -- see `step()`.
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
## "x:y:z" -> the same job Dictionary that is in `_queue`.
##
## Dictionaries are references, so this is an index into the queue rather
## than a copy of it: writing `score` here writes the queue's job. It exists
## because rescoring used to walk the whole queue once per already-queued
## chunk, which is quadratic in the size of the view sphere -- 739 chunks at
## radius 5 meant ~273,000 string comparisons every single frame, and
## `select` measured 47 ms on its own.
var _by_key := {}
var _cache := {}             # "x:y:z" -> {block}
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
##
## `cubic` selects a CUBE of half-width `radius` instead of a sphere. The
## caller needs the cube when the radius has to cover something measured in
## Chebyshev distance: a chunk is only meshable once all 26 of its neighbours
## have terrain, and meshing the whole visible sphere therefore requires
## terrain out to `view_radius + 1` in EVERY direction -- including the
## diagonals, which a sphere of that radius does not reach. Selecting a
## sphere there left the corners of the view permanently unmeshed.
func select(centre: Vector3i, forward: Vector3, radius: int,
		resident: Callable, cubic := false) -> void:
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
		_by_key.clear()
		stats["cancelled"] = int(stats["cancelled"]) + dropped
	_last_centre = centre
	_seeded = true

	var candidates: Array[Dictionary] = []
	var r2 := radius * radius + radius
	var span := range(-radius, radius + 1)
	# Cancellation is enforced here, not downstream. The queue is re-seeded
	# every frame, so a job still on it from an earlier frame is work the
	# player has since walked away from -- and the decision cannot be left to
	# the generator, because a generator says yes to any chunk it is able to
	# produce. A queued chunk that became resident while it waited (a forced
	# load beat the queue) is dropped for the same reason: there is nothing
	# left to do, and spending a budget slot to rediscover that is waste.
	var pruned := 0
	var kept: Array[Dictionary] = []
	for job in _queue:
		var qp: Vector3i = job["pos"]
		var d := qp - centre
		var outside := _outside(d, r2, cubic)
		if outside or bool(resident.call(qp)):
			var dead := String(job["key"])
			_queued.erase(dead)
			_by_key.erase(dead)
			pruned += 1
			continue
		kept.append(job)
	if pruned > 0:
		_queue = kept
		stats["cancelled"] = int(stats["cancelled"]) + pruned
	for dx in span:
		for dy in span:
			for dz in span:
				# A cube has no corners to trim, so the sphere test is
				# skipped entirely rather than evaluated and ignored.
				if not cubic and dx * dx + dy * dy + dz * dz > r2:
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
					_by_key[key]["score"] = score
					continue
				var job := {"pos": p, "key": key, "score": score,
					"kind": "generate"}
				candidates.append(job)
				_queued[key] = true
				_by_key[key] = job
	_queue.append_array(candidates)
	_queue.sort_custom(func(a, b): return float(a["score"]) < float(b["score"]))


## Is chunk offset `d` outside the selected region?
static func _outside(d: Vector3i, r2: int, cubic: bool) -> bool:
	if cubic:
		var m := maxi(absi(d.x), maxi(absi(d.y), absi(d.z)))
		return m * m + m > r2
	return d.x * d.x + d.y * d.y + d.z * d.z > r2


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
	# Kept for the tests' benefit; the hot path writes through `_by_key`.
	var job: Variant = _by_key.get(key, null)
	if job != null:
		job["score"] = score


# --- the frame's work -------------------------------------------------------

## Do up to one frame's worth of work. `gen` and `mesh` are the callables that
## do the real thing; the scheduler only decides what to call and when to stop.
##
## `gen(pos) -> bool` must return true if the chunk is now resident.
##
## `mesh_ready() -> bool` answers "is anything waiting to be meshed", ready
## or not; false means the world has no pending mesh work at all. `mesh() ->
## bool` meshes one ready chunk and returns true, or returns false when every
## candidate is still waiting on a neighbour's terrain -- which is how holes
## are prevented rather than hidden, and is the only thing counted as a
## deferral. The two probes are separate so that an idle frame and a blocked
## frame are different numbers: a counter that counts both is a counter you
## cannot tune against.
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
		_by_key.erase(key)
		var gt := Time.get_ticks_usec()
		var ok := bool(gen.call(job["pos"]))
		# Charge what the job actually cost, not what the schedule assumed
		# it would cost. Anything the clock could not resolve falls back to
		# the estimate, so a fast job still counts as something.
		spent += maxf(float(Time.get_ticks_usec() - gt) / 1000.0, \
			COST_GENERATE_MS * 0.01)
		if ok:
			done += 1
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
			# Nothing wants a mesh: an idle frame is not a deferral.
			break
		var mt := Time.get_ticks_usec()
		if not bool(mesh.call()):
			# Something wants a mesh but nothing is ready -- every candidate
			# is waiting on a neighbour. That is what "deferred" means.
			stats["deferred"] = int(stats["deferred"]) + 1
			break
		mdone += 1
		# Same rule as generation: the budget is spent in real milliseconds.
		mspent += maxf(float(Time.get_ticks_usec() - mt) / 1000.0, \
			COST_MESH_MS * 0.01)
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

## Offer an unloaded chunk to the cache. Evicts the least recently cached
## chunk when over budget, so walking in a circle is instant and walking in a
## spiral is bounded.
##
## The bookkeeping rule is one cache entry, one order record, always. A
## second record for the same key turns every later eviction into a lottery
## between a real eviction and a no-op -- and the no-ops leave the cache
## reporting itself full while silently dropping the chunk being offered.
func cache_put(key: String, block: Variant) -> void:
	if block == null:
		return
	if _cache.has(key):
		# Replace in place: re-offer the key rather than growing a ghost.
		_cache_order.erase(key)
	elif _cache.size() >= CACHE_CHUNKS:
		_evict_oldest()
		if _cache.size() >= CACHE_CHUNKS:
			return
	_cache[key] = {"block": block}
	_cache_order.append(key)


## The cached block for `key`, or null, counting the hit. Taking transfers
## ownership out of the cache: a chunk that is resident again is no longer
## the cache's to hold, and keeping a second reference would mean two copies
## of the same chunk -- one being edited and one silently going stale.
func cache_take(key: String) -> Variant:
	var entry: Variant = _cache.get(key, null)
	if entry == null:
		return null
	_cache.erase(key)
	_cache_order.erase(key)
	stats["cached_hits"] = int(stats["cached_hits"]) + 1
	return entry["block"]


## The cached block without counting a hit.
func cache_peek(key: String) -> Variant:
	var entry: Dictionary = _cache.get(key, {})
	return entry["block"] if entry.has("block") else null


func cache_has(key: String) -> bool:
	return _cache.has(key)


func cache_size() -> int:
	return _cache.size()


func _evict_oldest() -> void:
	# Skip stale records instead of pretending an eviction happened: a no-op
	# eviction leaves the cache full, and the caller's only reaction to a
	# full cache is to drop the chunk it came to store.
	while not _cache_order.is_empty():
		var oldest: String = _cache_order.pop_front()
		if _cache.erase(oldest):
			stats["evicted"] = int(stats["evicted"]) + 1
			return


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
	_by_key.clear()
	stats["cancelled"] = int(stats["cancelled"]) + n
	return n


static func _key(p: Vector3i) -> String:
	return "%d:%d:%d" % [p.x, p.y, p.z]


func report() -> String:
	return "stream: %d generated, %d meshed, %d cancelled, %d cached, %d queued" % [
		int(stats["generated"]), int(stats["meshed"]), int(stats["cancelled"]),
		_cache.size(), _queue.size()]
