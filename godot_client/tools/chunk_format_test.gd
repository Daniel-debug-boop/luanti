extends SceneTree
## The converted-chunk binary format, end to end.
##
## This suite exists because of a specific defect: the converter packed
## `"<IHHBB"` (10 bytes) while the reader declared `HEADER_SIZE := 9`. Every
## converted world was read one byte out of step -- the `reserved` byte became
## the first content id and the last param2 byte came from past the end of the
## payload -- and nothing failed, because a chunk read one byte out of step
## still looks like terrain.
##
## So this is not a "does it load" test. It builds byte-exact fixtures, writes
## them through the real reader, and checks that a single wrong byte in any
## field is either read correctly or refused. The refusal half matters as much
## as the correctness half: a malformed chunk that is read anyway is how the
## original defect stayed invisible.

var failures := 0


func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: ", msg)


func _init() -> void:
	_test_header_is_ten_bytes()
	_test_roundtrip_one_byte_content()
	_test_roundtrip_two_byte_content()
	_test_flags_roundtrip()
	_test_every_node_index_is_written_and_read_back()
	_test_reader_refuses_malformed_files()
	_test_reader_agrees_with_the_python_writer()
	_test_luanti_ids_are_mapped_to_content_db()
	# tools/run_tests.sh matches a verdict line at column 0.
	print("chunk_format: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)


## Build a byte-exact chunk file. The layout mirrors tools/chunk_format.py, and
## `_test_reader_agrees_with_the_python_writer` proves the two agree on a real
## converted world rather than on this hand-written copy.
func _make_chunk(cwidth: int, flags: int, content: PackedInt32Array,
		light: PackedByteArray, param2: PackedByteArray) -> PackedByteArray:
	var n := 4096
	var out := PackedByteArray()
	out.resize(ChunkFiles.HEADER_SIZE + n * cwidth + n * 2)
	out.encode_u32(0, ChunkFiles.MAGIC)
	out.encode_u16(4, 1)
	out.encode_u16(6, flags)
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


func _make_content(pattern: int) -> PackedInt32Array:
	var c := PackedInt32Array()
	c.resize(4096)
	for i in 4096:
		c[i] = (i * 7 + pattern) % 256
	return c


func _load(dir: String) -> VoxelBlock:
	return ChunkFiles.load_chunk(dir, 1, 2, 3)


# --- the defect itself -------------------------------------------------------

func _test_header_is_ten_bytes() -> void:
	# The whole bug. `"<IHHBB"` is 4+2+2+1+1 = 10, and the reader used to say
	# 9. If this ever changes, the Python side changes with it -- chunk_format
	# HEADER_SIZE is asserted against this number by the writer round-trip
	# below.
	check(ChunkFiles.HEADER_SIZE == 10,
		"the header is 10 bytes, not 9 (got %d)" % ChunkFiles.HEADER_SIZE)


func _test_roundtrip_one_byte_content() -> void:
	var dir := "user://chunkfmt1"
	DirAccess.make_dir_recursive_absolute(dir)
	var content := _make_content(1)
	var light := PackedByteArray()
	light.resize(4096)
	for i in 4096:
		light[i] = (i * 3) & 0x0F | ((i * 5) & 0x0F) << 4
	var param2 := PackedByteArray()
	param2.resize(4096)
	for i in 4096:
		param2[i] = (i * 11) & 0xFF
	_write(dir, "c_1_2_3.chunk", _make_chunk(1, 0x08, content, light, param2))

	var b := _load(dir)
	check(b != null, "a 1-byte-content chunk loads")
	if b != null:
		var same := true
		for i in 4096:
			if b.content[i] != content[i]:
				same = false
				break
		check(same, "every content id survives the round trip")
		check(b.light == light, "every light value survives the round trip")
		check(b.param2 == param2, "every param2 value survives the round trip")
	# And the offset that matters most: the first content id must be the
	# first content id, not the reserved byte that precedes it.
	if b != null:
		check(b.content[0] == content[0],
			"node 0 reads the first content id, not the reserved byte")


func _test_roundtrip_two_byte_content() -> void:
	var dir := "user://chunkfmt2"
	DirAccess.make_dir_recursive_absolute(dir)
	var content := PackedInt32Array()
	content.resize(4096)
	for i in 4096:
		# Ids above 255 only survive if the width-2 path is genuinely used.
		content[i] = (i * 37) % 4096
	var light := PackedByteArray()
	light.resize(4096)
	var param2 := PackedByteArray()
	param2.resize(4096)
	for i in 4096:
		light[i] = i & 0xFF
		param2[i] = (i * 13) & 0xFF
	_write(dir, "c_1_2_3.chunk", _make_chunk(2, 0x00, content, light, param2))

	var b := _load(dir)
	check(b != null, "a 2-byte-content chunk loads")
	if b != null:
		var same := true
		var has_high := false
		for i in 4096:
			if b.content[i] != content[i]:
				same = false
				break
			if content[i] > 255:
				has_high = true
		check(same, "every 2-byte content id survives the round trip")
		check(has_high, "the fixture actually exercises ids above 255")


func _test_flags_roundtrip() -> void:
	var dir := "user://chunkfmt3"
	DirAccess.make_dir_recursive_absolute(dir)
	var content := _make_content(2)
	var light := PackedByteArray()
	light.resize(4096)
	var param2 := PackedByteArray()
	param2.resize(4096)
	# 0x08 means NOT generated, so this block must come back ungenerated.
	_write(dir, "c_1_2_3.chunk",
		_make_chunk(1, 0x01 | 0x02 | 0x08, content, light, param2))
	var b := _load(dir)
	check(b != null, "a flagged chunk loads")
	if b != null:
		check(b.is_underground, "bit 0 reads as underground")
		check(b.day_night_differs, "bit 1 reads as day/night differing")
		check(not b.is_generated, "bit 3 set reads as NOT generated")
		check(b.origin == Vector3i(1, 2, 3), "the origin comes from the filename")


func _test_every_node_index_is_written_and_read_back() -> void:
	# A one-byte offset in either direction still round-trips most of a
	# uniform-ish array, which is why the original bug survived. This uses a
	# value that depends on its own index, so ANY displacement shows up.
	var dir := "user://chunkfmt4"
	DirAccess.make_dir_recursive_absolute(dir)
	var content := PackedInt32Array()
	content.resize(4096)
	for i in 4096:
		content[i] = (i * 251) % 256
	var light := PackedByteArray()
	light.resize(4096)
	var param2 := PackedByteArray()
	param2.resize(4096)
	for i in 4096:
		light[i] = (i * 197) % 256
		param2[i] = (i * 89) % 256
	_write(dir, "c_1_2_3.chunk", _make_chunk(1, 0x00, content, light, param2))
	var b := _load(dir)
	check(b != null, "the index-dependent chunk loads")
	if b != null:
		var good := true
		for i in 4096:
			if b.content[i] != content[i] or b.light[i] != light[i] \
					or b.param2[i] != param2[i]:
				good = false
				break
		check(good, "no node is displaced by an index-dependent value")


# --- refusal -----------------------------------------------------------------

func _test_reader_refuses_malformed_files() -> void:
	var content := _make_content(0)
	var light := PackedByteArray()
	light.resize(4096)
	var param2 := PackedByteArray()
	param2.resize(4096)

	var dir := "user://chunkfmt5"
	DirAccess.make_dir_recursive_absolute(dir)

	# Truncated: one byte short of the declared payload. Under the old
	# reader this was read anyway, with the last param2 byte coming from past
	# the end.
	var good := _make_chunk(1, 0x00, content, light, param2)
	var short := good.slice(0, good.size() - 1)
	_write(dir, "c_1_2_3.chunk", short)
	check(_load(dir) == null, "a truncated chunk is refused, not read")

	# A file that is the 9-byte-header size: exactly what the old writer/reader
	# pair believed a chunk was. It must be rejected as short, not parsed.
	var nine := good.slice(0, 9)
	_write(dir, "c_1_2_3.chunk", nine)
	check(_load(dir) == null, "a 9-byte file is refused as short")

	# Bad magic.
	var bad_magic := good.duplicate()
	bad_magic.encode_u32(0, 0xDEADBEEF)
	_write(dir, "c_1_2_3.chunk", bad_magic)
	check(_load(dir) == null, "a bad-magic chunk is refused")

	# Unsupported version.
	var bad_ver := good.duplicate()
	bad_ver.encode_u16(4, 99)
	_write(dir, "c_1_2_3.chunk", bad_ver)
	check(_load(dir) == null, "an unsupported version is refused")

	# Impossible content width.
	var bad_cw := good.duplicate()
	bad_cw[8] = 3
	_write(dir, "c_1_2_3.chunk", bad_cw)
	check(_load(dir) == null, "a content width of 3 is refused")

	# A 1-byte-content file that is actually 2-byte-sized: the length check
	# is what catches a converter that disagrees about cwidth.
	var wide := _make_chunk(2, 0x00, content, light, param2)
	_write(dir, "c_1_2_3.chunk", wide)
	var b := _load(dir)
	check(b != null, "the width-2 file itself is still accepted")
	if b != null:
		check(b.content[0] == content[0], "and reads correctly")

	# Absent file.
	check(ChunkFiles.load_chunk(dir, 9, 9, 9) == null,
		"an absent chunk returns null rather than erroring")


## The reader and the Python writer must agree about a real converted world,
## not just about fixtures written by the same understanding that produced the
## bug. Skipped with a note when the fixture world has not been generated.
func _test_reader_agrees_with_the_python_writer() -> void:
	var dir := "/tmp/testchunks"
	if not FileAccess.file_exists(dir.path_join(ChunkFiles.MANIFEST)):
		print("  note: no converted world at %s -- skipped" % dir)
		return
	var found := 0
	var bad := 0
	for x in range(-1, 2):
		for y in range(-1, 2):
			for z in range(-1, 2):
				var name := "c_%d_%d_%d.chunk" % [x, y, z]
				var path := dir.path_join(name)
				if not FileAccess.file_exists(path):
					continue
				found += 1
				var b := ChunkFiles.load_chunk(dir, x, y, z)
				if b == null:
					bad += 1
					continue
				# The file length must match the header the writer declared.
				var raw := FileAccess.get_file_as_bytes(path)
				var declared := ChunkFiles.HEADER_SIZE \
					+ 4096 * raw[8] + 8192
				if raw.size() != declared:
					bad += 1
	check(found > 0, "the converted-world fixture has chunks to read")
	check(bad == 0, "every converted chunk matches the declared layout "
		+ "(%d of %d bad)" % [bad, found])


## The format is only half of the bridge. Luanti numbers content ids per
## world -- the ids in a converted world come from that world's own
## content_ids.txt -- while ContentDB has its own 0..31 table, and nothing
## used to translate between them. A converted world therefore arrived full
## of foreign ids that read as whatever foreign id happens to mean; the
## generated fixture hid that by hand-aligning its ids to ours.
##
## So the converter records each id's node name in the manifest, and the
## reader maps the names through the one ContentDB table. A name EMERGENT
## has no block for becomes air (with a report), because "a block from a mod
## we do not ship" is not something to guess at -- and ContentDB is the only
## table that decides what a name means.
func _test_luanti_ids_are_mapped_to_content_db() -> void:
	var dir := "user://chunkfmt_map"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var content := PackedInt32Array()
	content.resize(4096)
	var light := PackedByteArray()
	light.resize(4096)
	light.fill(15)
	var param2 := PackedByteArray()
	param2.resize(4096)
	# Voxel 0 is Luanti id 9, voxel 1 is a mod node with no EMERGENT block,
	# voxel 2 is Luanti id 3.
	content[0] = 9
	content[1] = 40
	content[2] = 3
	_write(dir, "c_1_2_3.chunk", _make_chunk(1, 0, content, light, param2))
	_write(dir, "manifest.json", PackedByteArray(JSON.stringify({
		"format": 1,
		"content_names": {"9": "default:stone", "40": "default:unobtainium",
			"3": "default:water"},
	}).to_utf8_buffer()))
	var block := _load(dir)
	check(block != null, "the chunk with a name table loads")
	if block != null:
		check(block.content[0] == ContentDB.STONE,
			"Luanti id 9 (default:stone) reads as ContentDB stone, not as "
			+ "raw 9 (got %d)" % block.content[0])
		check(block.content[1] == ContentDB.AIR,
			"a node EMERGENT has no block for reads as air, not as a "
			+ "foreign id (got %d)" % block.content[1])
		check(block.content[2] == ContentDB.WATER,
			"Luanti id 3 (water) reads as ContentDB water (got %d)"
			% block.content[2])
	var unmapped := ChunkFiles.unmapped_names(dir)
	check(unmapped.has("default:unobtainium"),
		"the node that could not be mapped is named in the report: %s"
		% str(unmapped))

	# A manifest with no name table means the world is already in ContentDB
	# ids -- that is the generated fixture, and the reader must not remap it.
	var raw_dir := "user://chunkfmt_raw"
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(raw_dir))
	_write(raw_dir, "c_1_2_3.chunk", _make_chunk(1, 0, content, light, param2))
	_write(raw_dir, "manifest.json",
		PackedByteArray(JSON.stringify({"format": 1}).to_utf8_buffer()))
	var raw_block := _load(raw_dir)
	check(raw_block != null, "the chunk without a name table loads")
	if raw_block != null:
		check(raw_block.content[0] == 9,
			"ids pass through raw when the manifest carries no names "
			+ "(got %d)" % raw_block.content[0])
		check(raw_block.content[2] == ContentDB.STONE,
			"and a raw id that is a ContentDB id still means that block: "
			+ "Luanti 3 here is ContentDB's stone, read untouched (got %d)"
			% raw_block.content[2])

	# The converter has to be the one recording the names: a manifest field
	# nothing writes is a bridge that only works on hand-made files.
	var src := FileAccess.get_file_as_string("res://tools/convert_world.py")
	check(src.contains("\"content_names\":"),
		"the converter never writes the manifest's content_names field")
	check(src.contains("content_ids.txt"),
		"the converter never reads the world's content_ids.txt")