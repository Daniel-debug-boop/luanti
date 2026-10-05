extends SceneTree
## Background meshing: that splitting `GreedyMesher` in two lost nothing, that
## the worker really produces the same geometry as the inline path, and that
## the three ways async meshing can go wrong -- a stale result overwriting an
## edit, a result landing on a chunk that has been unloaded, and an unbounded
## queue -- are all actually handled.
##
## Each of these was reachable before being handled. A stale result is the
## nasty one: the player mines a block, the chunk is re-queued, and then the
## pre-edit sweep finishes and puts the block back. It looks like the game
## ignoring your input, intermittently, which is close to undebuggable.

var failures := 0


func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: ", msg)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_the_split_loses_nothing()
	_test_a_worker_produces_the_same_geometry()
	_test_back_pressure_refuses_rather_than_queueing()
	_test_an_edited_chunk_is_not_overwritten_by_a_stale_sweep()
	_test_a_result_for_an_unloaded_chunk_is_dropped()
	print("mesh_worker: %s" % ["PASS" if failures == 0
		else "%d FAILURES" % failures])
	quit(1 if failures > 0 else 0)


## A chunk with real terrain in it, and enough neighbours to mesh it.
func _world_block(cx: int, cz: int) -> VoxelBlock:
	var gen := WorldGenerator.new(4242)
	var b := gen.generate_block(Vector3i(cx, 0, cz))
	b.is_loaded = true
	b.is_generated = true
	return b


func _surface_hash(m: ArrayMesh) -> String:
	if m == null:
		return "null"
	var parts := PackedStringArray()
	for i in m.get_surface_count():
		var a := m.surface_get_arrays(i)
		for k in a.size():
			if a[k] == null:
				continue
			parts.append("%s:%s" % [m.surface_get_name(i), str(a[k]).sha256_text()])
	return "|".join(parts).sha256_text()


## `build` is now `geometry` + `to_meshes`. If those two halves are not the
## same call, every existing test that uses `build` is still testing something
## the game no longer does.
func _test_the_split_loses_nothing() -> void:
	for pair in [[0, 0], [1, 1], [-2, 3]]:
		var b := _world_block(int(pair[0]), int(pair[1]))
		var whole := GreedyMesher.build(b, {})
		var halves := GreedyMesher.to_meshes(GreedyMesher.geometry(b, {}))
		for pass_i in 2:
			check(_surface_hash(whole[pass_i]) == _surface_hash(halves[pass_i]),
				"split build changed the mesh for pass %d at chunk (%d,%d)"
				% [pass_i, int(pair[0]), int(pair[1])])


## The end-to-end contract: submit to the pool, flush, and the caller gets
## geometry identical to meshing inline.
func _test_a_worker_produces_the_same_geometry() -> void:
	var b := _world_block(0, 0)
	var inline := GreedyMesher.build(b, {})

	var w := ChunkMeshWorker.new()
	check(w.submit("k", Vector3i.ZERO, b, {}, 0), "submit on an idle pool refused")
	check(w.outstanding() == 1, "outstanding should be 1 right after submit")

	var batch := w.flush()
	check(batch.size() == 1, "flush should return exactly one result, got %d"
		% batch.size())
	check(w.outstanding() == 0, "pool still reports %d outstanding after flush"
		% w.outstanding())
	check(w.worker_ms_total() > 0.0,
		"worker reported no time spent, so nothing actually ran")

	var threaded := GreedyMesher.to_meshes(batch[0]["faces"])
	for pass_i in 2:
		check(_surface_hash(inline[pass_i]) == _surface_hash(threaded[pass_i]),
			"threaded mesh differs from inline mesh on pass %d" % pass_i)

	# The job must carry a snapshot, not a live reference.
	#
	# This is asserted on `_copy_block` directly rather than by racing the
	# worker, because on a single-CPU machine the pool runs the task inline
	# inside `add_task` -- there is no window in which to mutate the block
	# from under it, so a "submit, mutate, check" test would pass even if the
	# snapshot were removed entirely. Testing the copy is the only version of
	# this that is actually load-bearing here.
	var probe := _world_block(0, 0)
	var snapshot := ChunkMeshWorker._copy_block(probe)
	var before := _surface_hash(GreedyMesher.build(snapshot, {})[0])
	probe.content.fill(ContentDB.STONE)
	probe.light.fill(ContentDB.GRASS)
	probe.is_loaded = false
	probe.is_generated = false
	check(_surface_hash(GreedyMesher.build(snapshot, {})[0]) == before,
		"mutating the source block changed the copy: the snapshot shares "
		+ "storage with the original")
	check(snapshot.is_loaded and snapshot.is_generated,
		"the snapshot lost the completeness flags, so the mesher would "
		+ "treat it as an untrusted neighbour and draw faces that should be "
		+ "culled")


func _test_back_pressure_refuses_rather_than_queueing() -> void:
	var w := ChunkMeshWorker.new()
	var b := _world_block(0, 0)
	var accepted := 0
	# Ask for far more than the cap. The point is not that every one is
	# accepted -- the pool is allowed to start draining -- but that the queue
	# is bounded, and that a refusal is a plain false rather than an error.
	for i in ChunkMeshWorker.MAX_QUEUED * 3:
		if w.submit("k%d" % i, Vector3i.ZERO, b, {}, i):
			accepted += 1
	check(accepted <= ChunkMeshWorker.MAX_QUEUED,
		"accepted %d jobs against a cap of %d: the queue is unbounded"
		% [accepted, ChunkMeshWorker.MAX_QUEUED])
	check(w.outstanding() <= ChunkMeshWorker.MAX_QUEUED,
		"outstanding %d exceeds the cap %d"
		% [w.outstanding(), ChunkMeshWorker.MAX_QUEUED])
	w.flush()
	w.cancel_queued()


## The staleness rule, on a real world: mine a block while its chunk is being
## swept, and the pre-edit geometry must never be installed.
func _test_an_edited_chunk_is_not_overwritten_by_a_stale_sweep() -> void:
	var w := VoxelWorld.new()
	w.view_radius = 1
	w.async_meshing = true
	w.generator = WorldGenerator.new(1337)
	w.materials = MaterialLibrary.new()
	root.add_child(w)
	w.ensure_region(Vector3i.ZERO, 2)

	var key := w._key(Vector3i.ZERO)
	check(w._blocks.has(key), "test setup: chunk was not loaded")

	# Queue a sweep, then edit before it can be applied.
	w._dirty[key] = true
	var submitted := w._mesh_job()
	check(submitted, "the chunk should have been queued for meshing")

	var found := Vector3i(-1, -1, -1)
	for x in range(16):
		for z in range(16):
			for y in range(16):
				if w.get_content_at(Vector3i(x, y, z)) == ContentDB.STONE:
					found = Vector3i(x, y, z)
					break
			if found.x >= 0:
				break
		if found.x >= 0:
			break
	check(found.x >= 0, "test setup: no stone to mine")

	check(w.break_block(found), "break_block should have changed the block")

	# Apply the sweep that was already in flight when the edit happened.
	for r in w._mesh_worker.flush():
		w._apply_meshed(r)

	# The invariant is not "the block is still air" -- that is unaffected by
	# which mesh is installed. It is that the stale result was thrown away
	# WITHOUT consuming the dirty flag, so the chunk is still queued for a
	# fresh sweep. Consuming it is the bug: the chunk looks clean, keeps its
	# pre-edit mesh, and nothing ever re-meshes it.
	check(w._dirty.has(key),
		"the stale sweep was applied and cleared the dirty flag: this chunk "
		+ "will keep its pre-edit geometry forever")

	# And convergence: the mesh that ends up installed must be the mesh the
	# edited block actually produces, not merely "some" mesh.
	for i in 8:
		w.update_around(Vector3i.ZERO)
		w.flush_meshing()
	var mi: MeshInstance3D = w._meshes.get(key, null)
	check(mi != null, "the chunk never got a mesh at all")
	if mi != null:
		var expected := GreedyMesher.build(w._blocks[key],
			w._gather_neighbours(Vector3i.ZERO, key))
		check(_surface_hash(mi.mesh) == _surface_hash(expected[0]),
			"the installed mesh is not the mesh the edited block produces")
	w.queue_free()


## A chunk unloaded while its sweep is in flight must not get a node put back
## into a world it has left.
func _test_a_result_for_an_unloaded_chunk_is_dropped() -> void:
	var w := VoxelWorld.new()
	w.view_radius = 1
	w.async_meshing = true
	w.generator = WorldGenerator.new(1337)
	w.materials = MaterialLibrary.new()
	root.add_child(w)
	w.ensure_region(Vector3i.ZERO, 2)

	var key := w._key(Vector3i.ZERO)
	w._dirty[key] = true
	w._mesh_job()
	w._unload_chunk(Vector3i.ZERO, key)
	var meshes_before := w._meshes.size()
	for r in w._mesh_worker.flush():
		w._apply_meshed(r)
	check(w._meshes.size() == meshes_before,
		"a result for an unloaded chunk installed a mesh anyway (%d -> %d)"
		% [meshes_before, w._meshes.size()])
	check(not w._pending_mesh.has(key),
		"the pending record for an unloaded chunk was left behind")
	w.queue_free()