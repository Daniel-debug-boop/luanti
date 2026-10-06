extends SceneTree
## Streaming tests: selection order, cancellation of work that left the view,
## the per-frame budget, chunk-cache lifetime, and the mesh deferral counters.
##
## These are the parts of streaming that never show up as a wrong block and
## almost never show up as a crash -- they show up as frame hitches (work
## built for a view the player already left) and as memory that grows while
## nobody is watching (a cache whose bookkeeping drifts from its contents).
## Both need assertions, because both are invisible otherwise.

var failures := 0


func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: ", msg)


func _init() -> void:
	_test_nearest_and_forward_first()
	_test_resident_chunks_not_queued()
	_test_jobs_outside_the_view_are_cancelled()
	_test_teleport_drops_the_backlog()
	_test_budget_bounds_one_step()
	_test_cache_take_removes()
	_test_cache_put_replaces_in_place()
	_test_cache_survives_churn()
	_test_force_load_consumes_the_cache()
	_test_mesh_deferral_accounting()
	_test_ensure_region_produces_geometry()
	_test_cancel_all()
	print("\nstreaming: %s" % ("PASS" if failures == 0
		else "%d FAILURES" % failures))
	quit(1 if failures > 0 else 0)


# --- selection --------------------------------------------------------------

func _no_resident() -> Callable:
	return func(_p: Vector3i) -> bool: return false


## Drain the queue with a generator that records every position it was asked
## to build, so a test can see exactly what would have been paid for.
func _drain(s: StreamScheduler) -> Array:
	var built: Array = []
	var gen := func(p: Vector3i) -> bool:
		built.append(p)
		return true
	var no_mesh := func() -> bool: return false
	while not s.is_empty():
		s.step(gen, no_mesh, no_mesh)
	return built


## How many chunks a radius-`r` sphere at the origin holds, computed rather
## than hardcoded, so changing the radius bound does not silently weaken the
## assertion.
func _sphere_count(r: int) -> int:
	var n := 0
	var r2 := r * r + r
	for dx in range(-r, r + 1):
		for dy in range(-r, r + 1):
			for dz in range(-r, r + 1):
				if dx * dx + dy * dy + dz * dz <= r2:
					n += 1
	return n


func _test_nearest_and_forward_first() -> void:
	var s := StreamScheduler.new()
	s.select(Vector3i.ZERO, Vector3.FORWARD, 3, _no_resident())
	check(s.queued() > 0, "select queues the view sphere")
	var n := s.queued()
	var built := _drain(s)
	check(built.size() == n, "every queued job runs exactly once")
	check(built.is_empty() == false, "and something was built")
	check(built[0] == Vector3i.ZERO, "the chunk under the player is built first")
	var front := built.find(Vector3i(0, 0, -1))
	var back := built.find(Vector3i(0, 0, 1))
	check(front >= 0 and back >= 0 and front < back,
		"a chunk in front of the camera beats one behind at the same distance")


func _test_resident_chunks_not_queued() -> void:
	var s := StreamScheduler.new()
	var all_resident := func(_p: Vector3i) -> bool: return true
	s.select(Vector3i.ZERO, Vector3.FORWARD, 3, all_resident)
	check(s.queued() == 0, "a view sphere that is already resident queues nothing")


func _test_jobs_outside_the_view_are_cancelled() -> void:
	var s := StreamScheduler.new()
	s.select(Vector3i.ZERO, Vector3.FORWARD, 3, _no_resident())
	var queued0 := s.queued()
	check(queued0 == _sphere_count(3), "the whole sphere is queued at first")
	# Walk ten chunks east: far out of the old view, well inside the
	# 48-chunk teleport threshold, so the backlog is expected to be pruned
	# rather than dropped wholesale.
	var dest := Vector3i(10, 0, 0)
	s.select(dest, Vector3.FORWARD, 3, _no_resident())
	check(int(s.stats["cancelled"]) >= queued0,
		"jobs that left the view are cancelled when the view moves")
	check(s.queued() == _sphere_count(3),
		"only the new view sphere remains queued")
	var built := _drain(s)
	check(built.size() == _sphere_count(3),
		"and exactly those jobs run")
	var stray := 0
	for p in built:
		var d: Vector3i = p - dest
		if d.x * d.x + d.y * d.y + d.z * d.z > 3 * 3 + 3:
			stray += 1
	check(stray == 0, "nothing outside the view is ever built")


func _test_teleport_drops_the_backlog() -> void:
	var s := StreamScheduler.new()
	s.select(Vector3i.ZERO, Vector3.FORWARD, 3, _no_resident())
	var n := s.queued()
	s.select(Vector3i(60, 0, 0), Vector3.FORWARD, 3, _no_resident())
	check(int(s.stats["teleports"]) == 1, "a 60-chunk jump is a teleport")
	check(int(s.stats["cancelled"]) >= n, "and the old backlog is dropped")
	check(s.queued() == _sphere_count(3),
		"while the destination is re-seeded in one pass")


func _test_budget_bounds_one_step() -> void:
	var s := StreamScheduler.new()
	s.max_chunks_per_frame = 2
	s.select(Vector3i.ZERO, Vector3.FORWARD, 4, _no_resident())
	var built: Array = []
	var gen := func(p: Vector3i) -> bool:
		built.append(p)
		return true
	var no_mesh := func() -> bool: return false
	var out := s.step(gen, no_mesh, no_mesh)
	check(int(out["generated"]) <= 2,
		"one step never builds past the chunk-count ceiling")
	check(s.queued() > 0, "the rest waits for a later frame")
	# A budget below one chunk's cost still runs that chunk: the ceiling is
	# a ceiling, and the budget cannot refuse the first unit of work outright.
	var s2 := StreamScheduler.new()
	s2.generate_budget_ms = float(StreamScheduler.COST_GENERATE_MS) * 0.96
	s2.select(Vector3i.ZERO, Vector3.FORWARD, 4, _no_resident())
	var out2 := s2.step(gen, no_mesh, no_mesh)
	check(int(out2["generated"]) >= 1, "the first chunk always gets its turn")


# --- cache lifetime ---------------------------------------------------------

func _test_cache_take_removes() -> void:
	var s := StreamScheduler.new()
	s.cache_put("0:1:2:3", 42)
	check(s.cache_size() == 1, "a put lands in the cache")
	var got: Variant = s.cache_take("0:1:2:3")
	check(got == 42, "take returns the cached chunk")
	check(s.cache_has("0:1:2:3") == false,
		"and the cache no longer holds it -- take is an ownership transfer")
	check(s.cache_size() == 0, "so the entry is gone, not just hidden")
	check(s.cache_take("0:1:2:3") == null, "a second take is a miss")


func _test_cache_put_replaces_in_place() -> void:
	var s := StreamScheduler.new()
	s.cache_put("dup", 1)
	s.cache_put("dup", 2)
	check(s.cache_size() == 1, "re-caching a key does not duplicate the entry")
	check(s._cache_order.size() == s.cache_size(),
		"one cache entry means one order record -- no ghosts")
	check(s.cache_take("dup") == 2, "and it holds the newest value")
	check(s.cache_size() == 0, "with no ghost left behind")
	check(s._cache_order.size() == 0, "and no order record either")


func _test_cache_survives_churn() -> void:
	var s := StreamScheduler.new()
	# The poisoned case: the same key cached twice in a row used to leave two
	# order entries for one cache entry, after which every later eviction
	# alternated between a real eviction and a no-op -- and the no-op ones
	# silently dropped the chunk being offered.
	s.cache_put("dup", 1)
	s.cache_put("dup", 2)
	for i in StreamScheduler.CACHE_CHUNKS - 1:
		s.cache_put("fill%d" % i, i)
	check(s.cache_size() == StreamScheduler.CACHE_CHUNKS, "the cache fills")
	var dropped := 0
	for i in 2000:
		var k := "churn%d" % i
		s.cache_put(k, i)
		if not s.cache_has(k):
			dropped += 1
	check(dropped == 0,
		"every chunk offered to a full cache lands or evicts a real neighbour")
	check(s.cache_size() == StreamScheduler.CACHE_CHUNKS,
		"and the cache never grows past its bound")
	check(s._cache_order.size() == s.cache_size(),
		"with the order record exactly as long as the cache, still")
	check(int(s.stats["evicted"]) > 0, "evictions are actually happening")
	s.cache_put("null-block", null)
	check(s.cache_has("null-block") == false,
		"a null block is refused rather than poisoning an entry")


# --- VoxelWorld integration -------------------------------------------------

func _test_force_load_consumes_the_cache() -> void:
	var w := VoxelWorld.new()
	w.view_radius = 1
	w.generator = WorldGenerator.new(1337)
	w.materials = MaterialLibrary.new()
	root.add_child(w)
	var key := "0:0:0:0"
	var blk: VoxelBlock = w.generator.generate_block(Vector3i.ZERO)
	check(blk != null, "the generator produces a block to cache")
	w.stream.cache_put(key, blk)
	var loaded := w.ensure_region(Vector3i.ZERO, 0)
	check(loaded == 1, "the forced load reports one chunk")
	check(is_same(w.get_block(Vector3i.ZERO), blk),
		"a forced load reclaims the cached chunk instead of regenerating")
	check(w.stream.cache_has(key) == false,
		"and consumes the cache entry it took")
	# Loading it again with the chunk already resident is a no-op, not a
	# second cache hit or a regeneration.
	check(w.ensure_region(Vector3i.ZERO, 0) == 0,
		"loading an already-resident chunk does nothing")
	w.queue_free()


func _test_mesh_deferral_accounting() -> void:
	var w := VoxelWorld.new()
	# View radius 2, region radius 1: the region's own chunks are meshed by
	# `ensure_region`, while the neighbour ring it loaded sits at distance
	# 1..sqrt(6) -- inside the view, dirty, and still missing THEIR outer
	# neighbours. That is the real deferral case: work is wanted, nothing is
	# ready.
	w.view_radius = 2
	w.generator = WorldGenerator.new(1337)
	w.materials = MaterialLibrary.new()
	root.add_child(w)
	var s := w.stream
	# An idle world: nothing dirty, nothing meshable. This frame is not
	# "waiting for neighbours" -- it is waiting for the player.
	var before := int(s.stats["deferred"])
	s.step(w._generate_job, w._mesh_job, w._has_mesh_work)
	check(int(s.stats["deferred"]) == before,
		"an idle frame is not counted as a deferral")
	# Now load a small region. Its neighbour ring is resident but not fully
	# surrounded, so meshing really is blocked on generation.
	w.ensure_region(Vector3i.ZERO, 1)
	check(w.get_stats()["dirty"] > 0, "loading marks chunks dirty")
	var mid := int(s.stats["deferred"])
	s.step(w._generate_job, w._mesh_job, w._has_mesh_work)
	check(int(s.stats["deferred"]) > mid,
		"a dirty chunk with missing neighbours is deferred")
	w.queue_free()


## The contract of `ensure_region` itself: "loaded AND meshed".
##
## Before, it loaded blocks and flushed a queue nothing had submitted, so it
## returned with chunks resident, every one of them dirty, and no geometry at
## all -- which reads as success to the caller and as a hole in the world to
## the player. This queries the region the instant the call returns.
func _test_ensure_region_produces_geometry() -> void:
	var w := VoxelWorld.new()
	w.view_radius = 2
	w.generator = WorldGenerator.new(1337)
	w.materials = MaterialLibrary.new()
	root.add_child(w)
	w.ensure_region(Vector3i.ZERO, 2)

	var checked := 0
	var missing := []
	var centre := Vector3i.ZERO
	var r2 := 2 * 2 + 2
	for dx in range(-2, 3):
		for dy in range(-2, 3):
			for dz in range(-2, 3):
				if dx * dx + dy * dy + dz * dz > r2:
					continue
				var p := centre + Vector3i(dx, dy, dz)
				var key := w._key(p)
				if not w._blocks.has(key):
					continue
				# Only chunks with all 26 neighbours can be meshed at all.
				if not w._can_mesh(p):
					continue
				checked += 1
				var mi: MeshInstance3D = w._meshes.get(key, null)
				# The geometry the world installed must be exactly what the mesher
				# produces from the same neighbour data now. An EMPTY result is
				# legitimate -- a chunk fully enclosed by solid rock has no
				# visible surface -- so emptiness alone is not a failure; a mesh
				# that does not match the sweep, or a chunk left dirty or in
				# flight, is.
				var direct := GreedyMesher.build(w._blocks[key],
					w._gather_neighbours(p, key)["neighbours"])
				var want := 0
				if direct[0] != null:
					want = direct[0].get_surface_count()
				var got := 0
				if mi != null and mi.mesh != null:
					got = mi.mesh.get_surface_count()
				if got != want or w._dirty.has(key) or w._pending_mesh.has(key):
					missing.append("%s (installed %d, mesher %d)" % [str(p), got, want])
	check(checked > 0, "the region produced no meshable chunks to verify")
	check(missing.is_empty(),
		("ensure_region left %d of %d chunk(s) without the geometry it "
		+ "should have: %s")
		% [missing.size(), checked, ", ".join(PackedStringArray(missing))])

	# And the region really produced terrain, so the check above is not
	# vacuous: an all-null region would pass it chunk by chunk.
	var with_geometry := 0
	for key in w._meshes.keys():
		var mi: MeshInstance3D = w._meshes[key]
		if mi != null and mi.mesh != null and mi.mesh.get_surface_count() > 0:
			with_geometry += 1
	check(with_geometry > 0, "the region produced no geometry at all")
	w.queue_free()


func _test_cancel_all() -> void:
	var s := StreamScheduler.new()
	s.select(Vector3i.ZERO, Vector3.FORWARD, 3, _no_resident())
	var n := s.queued()
	var dropped := s.cancel_all()
	check(dropped == n, "cancel_all reports what it dropped")
	check(s.queued() == 0, "and the queue is empty afterwards")
	check(s.is_empty(), "and agrees it is empty")
