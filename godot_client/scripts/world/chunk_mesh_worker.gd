class_name ChunkMeshWorker
extends RefCounted
## Runs the expensive half of chunk meshing off the main thread.
##
## ## Why this exists
##
## Meshing a chunk was the single largest thing the world did per frame. Once
## the mesher itself was fixed (see `GreedyMesher`), one chunk cost ~4-5 ms --
## still three frames' worth at 60 Hz, paid in one spike, every time a chunk
## became ready. A player walking forward meets a fresh ring of them
## continuously, which is what "the world hitches when I move" is.
##
## Splitting the mesher in two is what makes threading safe. `GreedyMesher
## .geometry` only does arithmetic over packed arrays and returns `FaceBuffer`
## objects -- plain RefCounted data, no engine resources, no scene tree, no
## shared mutable state. `GreedyMesher.to_meshes` calls
## `add_surface_from_arrays`, which uploads to the rendering server and MUST
## stay on the main thread. So this class does the first and `VoxelWorld` does
## the second, and the expensive part never touches the frame.
##
## ## What crosses the thread boundary
##
## A job carries a *copy* of the block data it will read. `VoxelBlock` is
## mutable and owned by `VoxelWorld`, which edits blocks in place when the
## player mines -- so handing a worker a live reference would be a data race,
## and a race in a mesher is a corrupted mesh that may not show up for hours.
## Copying is cheap next to meshing: 4096 ints and 4096 bytes against a 4 ms
## sweep.
##
## Dictionaries are references, so a job and the worker's copy of it are the
## same object. That is how completion is reported: the worker sets `done` on
## the job the main thread is already holding, which cannot race with the main
## thread setting `id` just after `add_task` returns. A counter would have had
## exactly that race.
##
## ## Ordering and back-pressure
##
## Jobs finish in whatever order the pool completes them, so `apply()` sorts
## each batch nearest-first -- otherwise a far chunk can land before a near one
## and the world visibly fills in backwards. `submit` refuses once
## `MAX_QUEUED` are outstanding: an unbounded queue is a memory leak with extra
## steps, and meshing chunks the player has already walked past is work nobody
## will ever look at.

## Queued jobs waiting for a free worker thread.
var _pending: Array = []
## Jobs started but not yet finished. Each is the same Dictionary the worker
## holds; `done` is how the worker reports back.
var _inflight: Array = []
## Finished face buffers waiting for the main thread to turn into meshes.
var _results: Array = []
var _mutex := Mutex.new()
var _ms_total := 0.0

## Jobs allowed outstanding before `submit` starts refusing. Sized to keep
## every pool thread fed through a burst without letting the queue outrun the
## player.
const MAX_QUEUED := 48


## Queue one chunk. `block` and `neighbours` are the block and its loaded
## neighbours, already gathered by the caller: gathering reads the world
## dictionary, which must happen on the main thread. `d2` is the squared
## distance from the focus and is used only to order each batch. `gen` is the
## mesh generation the data was captured at -- it is NOT optional and NOT
## interchangeable with `d2`, because identity of a result is which generation
## of the chunk it describes, not where the player happened to be standing.
##
## Returns false when the pool is saturated. The caller should treat that as
## "keep it dirty and try again next frame", not as a failure.
func submit(key: String, pos: Vector3i, block: VoxelBlock,
		neighbours: Dictionary, d2: int, gen: int) -> bool:
	if outstanding() >= MAX_QUEUED:
		return false
	var job := {
		"key": key, "pos": pos, "d2": d2, "gen": gen, "done": false,
		"block": _copy_block(block),
		"neighbours": _copy_neighbours(neighbours),
	}
	_mutex.lock()
	_pending.append(job)
	_mutex.unlock()
	_pump()
	return true


## Queued, running, or finished-but-unapplied. The caller uses this to decide
## whether more work may be submitted.
func outstanding() -> int:
	_mutex.lock()
	var n := _pending.size() + _inflight.size() + _results.size()
	_mutex.unlock()
	return n


## Pop everything finished, nearest first, for the caller to build meshes from.
## Main thread only. Returns an Array of result dictionaries; empty when the
## workers have not finished anything yet.
func apply() -> Array:
	_prune()
	_mutex.lock()
	var batch := _results
	_results = []
	_mutex.unlock()
	if batch.is_empty():
		return []
	batch.sort_custom(func(a, b): return int(a["d2"]) < int(b["d2"]))
	return batch


## Wait for every queued and running job and return them all, in apply order.
## For tests, saves and shutdown: anywhere "is the world meshed yet" has to
## mean yes rather than "probably, in a few frames".
func flush() -> Array:
	var done: Array = []
	while true:
		done.append_array(apply())
		var busy: Array = []
		_mutex.lock()
		for j in _inflight:
			if not bool(j["done"]):
				busy.append(j)
		_mutex.unlock()
		if busy.is_empty():
			_pump()
			# Re-check: pumping may have started the last pending job.
			_mutex.lock()
			var still := _pending.size() + _inflight.size()
			_mutex.unlock()
			if still == 0:
				return done
			continue
		for j in busy:
			if j.has("id"):
				WorkerThreadPool.wait_for_task_completion(int(j["id"]))
			else:
				# `add_task` has not returned its id yet; the job object is
				# shared, so spin on `done` rather than guess.
				while not bool(j["done"]):
					OS.delay_msec(1)
	return done


## Discard queued work. For shutdown and dimension changes: those chunks are
## about to be regenerated or hidden, and meshing them is wasted. In-flight
## tasks are not cancelled -- there is no way to stop one partway through a
## sweep without leaving a half-built mesh -- so their results still come back
## and the caller checks the chunk is still wanted before using them.
func cancel_queued() -> void:
	_mutex.lock()
	_pending.clear()
	_mutex.unlock()


## Wall time the workers spent sweeping, in milliseconds. The main thread now
## pays only for the mesh upload, which is why the perf overlay reports this
## separately from the scheduler's own mesh timing.
func worker_ms_total() -> float:
	_mutex.lock()
	var t := _ms_total
	_mutex.unlock()
	return t


## How many worker threads this machine gives us. One is the sandbox/CI case,
## where the pool runs the task inline; that is still correct, just not
## concurrent.
static func max_workers() -> int:
	return maxi(1, OS.get_processor_count() - 1)


## Hand queued jobs to the pool, up to its useful width.
func _pump() -> void:
	while true:
		_prune()
		_mutex.lock()
		if _pending.is_empty() or _inflight.size() >= max_workers():
			_mutex.unlock()
			return
		var job: Dictionary = _pending.pop_front()
		# Registered before the task starts, so a worker that finishes
		# immediately still has somewhere to be found.
		_inflight.append(job)
		_mutex.unlock()
		var id := WorkerThreadPool.add_task(_work.bind(job))
		job["id"] = id


## Forget jobs whose task has reported in.
func _prune() -> void:
	_mutex.lock()
	var keep: Array = []
	for j in _inflight:
		if not bool(j["done"]):
			keep.append(j)
	_inflight = keep
	_mutex.unlock()


## Worker thread body. Runs the pure-CPU half of the mesher and posts the face
## buffers back. Never touches the scene tree or the rendering server.
func _work(job: Dictionary) -> void:
	var t0 := Time.get_ticks_usec()
	var faces := GreedyMesher.geometry(job["block"], job["neighbours"])
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	_mutex.lock()
	_results.append({
		"key": job["key"], "pos": job["pos"], "d2": job["d2"],
		"gen": job["gen"],
		"faces": faces, "ms": ms,
	})
	_ms_total += ms
	job["done"] = true
	_mutex.unlock()


## A detached copy of one block: the only two arrays the mesher reads.
static func _copy_block(b: VoxelBlock) -> VoxelBlock:
	var out := VoxelBlock.new()
	out.origin = b.origin
	out.is_loaded = b.is_loaded
	out.is_generated = b.is_generated
	out.is_underground = b.is_underground
	out.content = b.content.duplicate()
	out.light = b.light.duplicate()
	return out


static func _copy_neighbours(nbs: Dictionary) -> Dictionary:
	var out := {}
	for k in nbs:
		out[k] = _copy_block(nbs[k])
	return out