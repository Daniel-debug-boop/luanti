extends SceneTree
## The Arnis authoritative-world intake path, executed for real.
##
## This suite exists because the seam it covers is the one where "it typechecks"
## and "it does the right thing" came apart. A converted world may arrive from
## an upstream generator -- Arnis -- and when it does, what is on disk is the
## source of truth for the overworld. The failure mode being guarded against is
## quiet: the client notices no converted chunk at some coordinate, shrugs, and
## runs the procedural generator instead, so the player sees *terrain* where
## they should see a hole, and nothing anywhere reports a problem.
##
## So the procedural generator here is a spy that counts its own calls. The
## assertions do not ask "did we get a plausible block"; they ask whether the
## generator was entered at all for an authoritative world. Falling back is
## still correct for a legacy world, and that half is asserted too, through the
## same code path, so the guard cannot pass by breaking the fallback.
##
## Everything runs through `VoxelWorld._generate_block`, which is the single
## place in the world that decides where voxels come from.

var failures := 0


## A procedural generator that records whether it was ever asked for terrain.
## Extending the real one means the fallback half of the test still produces
## genuine terrain rather than a stub that could disagree with the game.
class SpyGenerator extends WorldGenerator:
	var calls := 0
	var deep_calls := 0

	func generate_block(pos: Vector3i) -> VoxelBlock:
		calls += 1
		return super.generate_block(pos)

	func generate_deeps_block(pos: Vector3i) -> VoxelBlock:
		deep_calls += 1
		return super.generate_deeps_block(pos)


func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: ", msg)


func _init() -> void:
	_test_authoritative_detection()
	_test_authoritative_chunk_is_loaded_from_disk()
	_test_procedural_generator_is_not_run_for_an_arnis_world()
	_test_legacy_world_keeps_its_fallback()
	_test_coordinate_provenance()
	_test_region_boundary_continuity()
	print("arnis_authoritative: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)


# --- fixtures ---------------------------------------------------------------

const ARNIS_DIR := "user://arnis_world"
const LEGACY_DIR := "user://legacy_world"


## The same layout `tools/chunk_format.py` declares and `ChunkFiles` reads:
## 10-byte header, then content, then light, then param2.
func _make_chunk(cwidth: int, content: PackedInt32Array,
		light: PackedByteArray, param2: PackedByteArray) -> PackedByteArray:
	var n := 4096
	var out := PackedByteArray()
	out.resize(ChunkFiles.HEADER_SIZE + n * cwidth + n * 2)
	out.encode_u32(0, ChunkFiles.MAGIC)
	out.encode_u16(4, 1)
	out.encode_u16(6, 0)
	out[8] = cwidth
	out[9] = 0
	var p := ChunkFiles.HEADER_SIZE
	if cwidth == 1:
		for i in n:
			out[p + i] = content[i] & 0xFF
		p += n
	else:
		for i in n:
			out[p + i * 2] = (content[i] >> 8) & 0xFF
			out[p + i * 2 + 1] = content[i] & 0xFF
		p += n * 2
	for i in n:
		out[p + i] = light[i]
	p += n
	for i in n:
		out[p + i] = param2[i]
	return out


func _write(dir: String, name: String, bytes: PackedByteArray) -> void:
	var f := FileAccess.open(dir.path_join(name), FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()


func _write_manifest(dir: String, data: Dictionary) -> void:
	_write(dir, "manifest.json", PackedByteArray(JSON.stringify(data).to_utf8_buffer()))


## x fastest, then y, then z -- a fixed, invertible ordering so the boundary
## plane of one chunk can be named in the other.
func _idx(x: int, y: int, z: int) -> int:
	return x + 16 * y + 256 * z


func _uniform(value: int) -> PackedInt32Array:
	var c := PackedInt32Array()
	c.resize(4096)
	c.fill(value)
	return c


func _full_light() -> PackedByteArray:
	var l := PackedByteArray()
	l.resize(4096)
	l.fill(15)
	return l


func _zeros() -> PackedByteArray:
	var p := PackedByteArray()
	p.resize(4096)
	return p


## Build one authoritative (Arnis) world and one legacy converted world, each
## carrying a single chunk at the origin.
func _build_worlds() -> void:
	for d in [ARNIS_DIR, LEGACY_DIR]:
		DirAccess.make_dir_recursive_absolute(d)

	# The authoritative world: same binary chunk, plus the provenance fields
	# the intake path keys on, plus the coordinate bounds the converter records.
	_write(ARNIS_DIR, "c_0_0_0.chunk",
		_make_chunk(1, _uniform(5), _full_light(), _zeros()))
	_write(ARNIS_DIR, "c_1_0_0.chunk",
		_make_chunk(1, _uniform(6), _full_light(), _zeros()))
	_write_manifest(ARNIS_DIR, {
		"format": 1,
		"content_names": {},
		"source_pipeline": "arnis",
		"source_pipeline_version": "unpinned",
		"world_format": "luanti-v29",
		"bounds": {"x": [0, 1], "y": [0, 0], "z": [0, 0]},
	})

	# The legacy converted world: no provenance fields at all, which is every
	# world converted before Arnis was pinned as the source.
	_write(LEGACY_DIR, "c_0_0_0.chunk",
		_make_chunk(1, _uniform(9), _full_light(), _zeros()))
	_write_manifest(LEGACY_DIR, {"format": 1, "content_names": {}})


## A world with the spy generator wired in and nothing else touched. `_ready`
## is deliberately never run: this exercises `_generate_block` itself, not the
## material/meshing setup around it.
func _world(dir: String) -> Array:
	var w := VoxelWorld.new()
	w.world_dir = dir
	w.dimension = WorldGenerator.DIM_OVERWORLD
	var spy := SpyGenerator.new()
	w.generator = spy
	return [w, spy]


# --- the path ---------------------------------------------------------------

func _test_authoritative_detection() -> void:
	_build_worlds()
	ChunkFiles.forget()
	check(ChunkFiles.is_authoritative(ARNIS_DIR),
		"an Arnis manifest is recognised as authoritative")
	check(not ChunkFiles.is_authoritative(LEGACY_DIR),
		"a legacy converted world is not authoritative")


func _test_authoritative_chunk_is_loaded_from_disk() -> void:
	ChunkFiles.forget()
	var pair := _world(ARNIS_DIR)
	var w: VoxelWorld = pair[0]
	var spy: SpyGenerator = pair[1]
	var before := int(w.stream.stats["disk_hits"])
	var b := w._generate_block(Vector3i(0, 0, 0))
	check(b != null, "the converted chunk at the origin is produced")
	if b != null:
		check(b.content[0] == 5,
			"and it holds the converted data, not generated terrain (got %d)"
			% b.content[0])
	check(int(w.stream.stats["disk_hits"]) == before + 1,
		"loading it counted as a disk hit")
	w.free()


## The regression this suite is named for. If someone reorders `_generate_block`
## so the generator is consulted before (or instead of) the authoritative
## refusal, the counter moves and this fails -- which is the point: the bug
## would otherwise ship as terrain filling in over an Arnis world.
func _test_procedural_generator_is_not_run_for_an_arnis_world() -> void:
	ChunkFiles.forget()
	var pair := _world(ARNIS_DIR)
	var w: VoxelWorld = pair[0]
	var spy: SpyGenerator = pair[1]

	# A chunk that is present loads without the generator being entered.
	var present := w._generate_block(Vector3i(0, 0, 0))
	check(present != null, "the present authoritative chunk loads")
	check(spy.calls == 0,
		"the procedural generator is not run for a present Arnis chunk "
		+ "(calls=%d)" % spy.calls)

	# A chunk that is absent from an authoritative world must stay absent.
	# This is the assertion that fails if the generator executes.
	var missing := w._generate_block(Vector3i(50, 0, 50))
	check(missing == null,
		"an absent chunk in an Arnis world is not invented")
	check(spy.calls == 0,
		"and the procedural generator was not executed to invent it "
		+ "(calls=%d)" % spy.calls)
	check(spy.deep_calls == 0,
		"nor the deeps generator (deep_calls=%d)" % spy.deep_calls)
	w.free()


## The other half of the guard: breaking the fallback must be a visible
## failure, so a legacy world still fills its gaps procedurally.
func _test_legacy_world_keeps_its_fallback() -> void:
	ChunkFiles.forget()
	var pair := _world(LEGACY_DIR)
	var w: VoxelWorld = pair[0]
	var spy: SpyGenerator = pair[1]

	var present := w._generate_block(Vector3i(0, 0, 0))
	check(present != null, "the legacy converted chunk loads")
	if present != null:
		check(present.content[0] == 9,
			"and holds its converted data (got %d)" % present.content[0])
	check(spy.calls == 0,
		"a converted chunk is never overridden by the generator")

	var missing := w._generate_block(Vector3i(50, 0, 50))
	check(missing != null,
		"a legacy world still fills an absent chunk procedurally")
	check(spy.calls == 1,
		"which is exactly one procedural call (calls=%d)" % spy.calls)
	w.free()


# --- coordinate provenance --------------------------------------------------

func _test_coordinate_provenance() -> void:
	ChunkFiles.forget()
	var b := ChunkFiles.bounds(ARNIS_DIR)
	check(b.has("x") and b.has("y") and b.has("z"),
		"the authoritative manifest exposes its coordinate bounds")
	# JSON numbers arrive as floats, so compare numerically: the contract is
	# the values, not whether the parser handed back an int or a float.
	if b.has("x"):
		check(b["x"].size() == 2 and float(b["x"][0]) == 0.0
				and float(b["x"][1]) == 1.0,
			"the recorded x extent survives (got %s)" % str(b["x"]))
		check(float(b["y"][0]) == 0.0 and float(b["y"][1]) == 0.0,
			"the recorded y extent survives (got %s)" % str(b["y"]))
		check(float(b["z"][0]) == 0.0 and float(b["z"][1]) == 0.0,
			"the recorded z extent survives (got %s)" % str(b["z"]))

	# Provenance travels with the world, not with a global default: the legacy
	# world must not inherit the authoritative world's bounds.
	check(ChunkFiles.bounds(LEGACY_DIR) == {},
		"a world without bounds answers empty rather than borrowing one")


# --- region boundary continuity ---------------------------------------------

## Two adjacent chunks share a plane. Write a value that depends on the
## coordinate, read both back through the real reader, and require the shared
## plane to agree on both sides. A one-byte displacement -- the class of defect
## the format was rebuilt to prevent -- moves the plane and fails here.
func _test_region_boundary_continuity() -> void:
	var dir := "user://arnis_seam"
	DirAccess.make_dir_recursive_absolute(dir)
	ChunkFiles.forget(dir)

	var seam := func(y: int, z: int) -> int:
		return 100 + y * 4 + z

	var a := PackedInt32Array()
	a.resize(4096)
	var c := PackedInt32Array()
	c.resize(4096)
	for y in 16:
		for z in 16:
			var v: int = seam.call(y, z)
			# chunk A: its x=15 plane is the seam
			a[_idx(15, y, z)] = v
			# chunk B: its x=0 plane is the same seam
			c[_idx(0, y, z)] = v
			a[_idx(0, y, z)] = 1
			c[_idx(15, y, z)] = 2
	_write(dir, "c_0_0_0.chunk", _make_chunk(1, a, _full_light(), _zeros()))
	_write(dir, "c_1_0_0.chunk", _make_chunk(1, c, _full_light(), _zeros()))

	var block_a := ChunkFiles.load_chunk(dir, 0, 0, 0)
	var block_c := ChunkFiles.load_chunk(dir, 1, 0, 0)
	check(block_a != null and block_c != null, "both seam chunks load")
	if block_a == null or block_c == null:
		return

	var mismatched := 0
	for y in 16:
		for z in 16:
			if block_a.content[_idx(15, y, z)] != block_c.content[_idx(0, y, z)]:
				mismatched += 1
	check(mismatched == 0,
		"the shared plane agrees across the region boundary (%d of 256 "
		% mismatched + "node pairs disagree)")

	# And the planes are what they should be, not merely equal to each other.
	check(block_a.content[_idx(15, 3, 5)] == 117,
		"chunk A's boundary column reads at the coordinate it was written to "
		+ "(got %d)" % block_a.content[_idx(15, 3, 5)])
	check(block_a.content[_idx(0, 0, 0)] == 1,
		"and the interior is untouched by the boundary")
	check(block_c.content[_idx(0, 3, 5)] == 117,
		"chunk B's boundary column agrees (got %d)"
		% block_c.content[_idx(0, 3, 5)])
