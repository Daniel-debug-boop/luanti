class_name ChunkFiles
extends RefCounted
## Reads the flat chunk files produced by tools/convert_world.py.
##
## The binary layout is declared once, in `tools/chunk_format.py`, and mirrored
## by the constants below. It used to be declared here with
## `HEADER_SIZE := 9` while the writer packed `"<IHHBB"`, which is 4 + 2 + 2 +
## 1 + 1 = **10** bytes. Nothing caught it: a chunk file is still a readable
## file one byte out of step, so every chunk in every world was read shifted by
## one byte -- the `reserved` byte was consumed as the first content id, and
## the last param2 byte was read past the end of the payload. Every read has to
## come off `HEADER_SIZE`, never an assumed offset.
##
## File layout (little-endian):
##   offset  size  field
##   0       4     magic    u32, 'LVXC' (0x4358564C)
##   4       2     version  u16, 1
##   6       2     flags    u16 (bit0 underground, bit1 day/night,
##                          bit3 set means NOT generated)
##   8       1     cwidth   u8, 1 or 2 bytes per content id
##   9       1     reserved u8, skipped
##   10      var   content  cwidth * 4096 bytes, big-endian per id
##   ...     4096  light
##   ...     4096  param2

const MAGIC := 0x4358564C
const MANIFEST := "manifest.json"
const VERSION_SUPPORTED := 1
const BLOCK_VOLUME := 4096
## magic u32 + version u16 + flags u16 + cwidth u8 + reserved u8.
## `tools/chunk_format.py` asserts this is 10 and is the same number the
## writer uses; the two agreeing is what `asset_test` checks.
const HEADER_SIZE := 10

## The authoritative provenance fields. Kept here so tests can assert on them
## without importing the Python module, but the one source is
## `tools/chunk_format.py::authoritative_manifest()`.
const PIPELINE_NAME := "arnis"
const WORLD_FORMAT := "luanti-v29"


## The provenance fields an authoritative converted world carries. The one
## definition is `tools/chunk_format.py::authoritative_manifest()`; this is its
## GDScript view, so the reader and the writer can be checked against the same
## contract instead of against a copy that quietly drifts. A missing required
## field is a programming error, not a world to accept.
static func authoritative_manifest(pipeline: String = PIPELINE_NAME,
		pipeline_version: String = "unpinned",
		world_format: String = WORLD_FORMAT) -> Dictionary:
	assert(pipeline_version != "",
		"authoritative manifest needs a non-empty source_pipeline_version")
	assert(world_format != "",
		"authoritative manifest needs a non-empty world_format")
	return {
		"source_pipeline": pipeline,
		"source_pipeline_version": pipeline_version,
		"world_format": world_format,
	}


## Directory holding the converted chunks, or "" to search `user://world`.
static func resolve_dir(explicit: String = "") -> String:
	if explicit != "":
		return explicit
	for cand in ["user://world", "res://world", "/tmp/testchunks"]:
		if FileAccess.file_exists(cand.path_join(MANIFEST)):
			return cand
	return "user://world"

## The coordinate palette a converted world was built from, if the manifest
## recorded it. The client uses this only as documentation and for a runtime
## provenance check: a world created by an external generator carries its
## conversion origin here so the player and the dev tools can tell where the
## overworld came from rather than assuming it lines up with the procedural
## generator's seed.
static func bounds(dir: String) -> Dictionary:
	var m := load_manifest(dir)
	var b: Variant = m.get("bounds", null)
	return b if b is Dictionary else {}


static func load_manifest(dir: String) -> Dictionary:
	var path := dir.path_join(MANIFEST)
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}

## Whether this converted world declares itself authoritative for the overworld.
##
## A converted world that arrives with a `source_pipeline` field is the result
## of an upstream generator (here: Arnis). That world is the source of truth
## for its overworld -- the client loads what is on disk and falls back to the
## procedural generator only when a chunk is genuinely absent, never as a way
## to reinterpret absent data. Worlds that omit the field keep the older
## behaviour, where the procedural generator can fill gaps.
static func is_authoritative(dir: String) -> bool:
	var m := load_manifest(dir)
	if not m.has("source_pipeline"):
		return false
	var pipeline := String(m["source_pipeline"])
	if pipeline == "":
		return false
	if pipeline != PIPELINE_NAME:
		push_warning("ChunkFiles: %s declares an unrecognised "
			% dir + "source_pipeline '%s'" % pipeline)
		return false
	# An empty version is not a pinned provenance record, so it is refused for
	# the same reason `authoritative_manifest` refuses to build one: the whole
	# point of the field is to say which upstream run produced the world.
	if not m.has("source_pipeline_version") \
			or String(m["source_pipeline_version"]) == "":
		push_warning("ChunkFiles: %s is marked authoritative but has no "
			% dir + "source_pipeline_version")
		return false
	if not m.has("world_format"):
		push_warning("ChunkFiles: %s is marked authoritative but has no "
			% dir + "world_format")
		return false
	if String(m["world_format"]) != WORLD_FORMAT:
		push_warning("ChunkFiles: %s is marked authoritative but its "
			% dir + "world_format is '%s'" % String(m["world_format"]))
		return false
	return true

# --- the id bridge ----------------------------------------------------------
#
# The binary format is only half of a converted world. Luanti numbers content
# ids per world -- they come from that world's own `content_ids.txt` -- while
# ContentDB has its own 0..31 table, and nothing used to translate between the
# two: a converted world arrived full of foreign ids that read as whatever
# foreign id happened to mean, and only the generated fixture (whose ids were
# aligned by hand) ever looked right.
#
# So the converter records each id's node name in the manifest and the reader
# maps the names through the one ContentDB table. A name EMERGENT has no block
# for becomes air, and is reported: a block from a mod we do not ship is not
# something to guess at, and "it disappeared" is only acceptable if the game
# says so. A manifest with no `content_names` means the world is already in
# ContentDB ids, and its ids pass through untouched.

## Built once per directory: dir -> (Luanti id -> ContentDB id).
static var _id_maps := {}
## dir -> the node names that had no ContentDB block.
static var _unmapped := {}


## Luanti content id -> ContentDB id for this converted world. Empty when the
## manifest carries no names (the ids are already ContentDB's).
static func content_map(dir: String) -> Dictionary:
	if _id_maps.has(dir):
		return _id_maps[dir]
	var map := {}
	var unmapped: Array[String] = []
	var names: Variant = load_manifest(dir).get("content_names", null)
	if names is Dictionary:
		for key in (names as Dictionary).keys():
			var name := String((names as Dictionary)[key])
			var mapped := _contentdb_id(name)
			if mapped >= 0:
				map[int(key)] = mapped
			else:
				unmapped.append(name)
		if not unmapped.is_empty():
			push_warning("ChunkFiles: %d node(s) in %s have no EMERGENT "
				% [unmapped.size(), dir]
				+ "block and read as air: %s" % ", ".join(unmapped))
	_id_maps[dir] = map
	_unmapped[dir] = unmapped
	return map


## The node names in this converted world that have no ContentDB block.
static func unmapped_names(dir: String) -> Array[String]:
	content_map(dir)
	return _unmapped.get(dir, [])


## ContentDB's id for a Luanti node name. Luanti names are namespaced
## ("default:stone") and ContentDB's are not, so the tail is what the one
## table can answer.
static func _contentdb_id(name: String) -> int:
	var direct := ContentDB.name_to_id(name)
	if direct >= 0:
		return direct
	var tail := name
	var colon := name.rfind(":")
	if colon >= 0:
		tail = name.substr(colon + 1)
	return ContentDB.name_to_id(tail)


## Forget a directory's cached mapping. Only the tests need this: a converted
## world is written once and then read for the life of the process.
static func forget(dir: String = "") -> void:
	if dir == "":
		_id_maps.clear()
		_unmapped.clear()
		return
	_id_maps.erase(dir)
	_unmapped.erase(dir)


## Load one chunk from disk. Returns null when absent or malformed.
##
## Every rejection here is loud on purpose. A truncated or mis-headed chunk
## used to be read anyway, at whatever offset the data happened to support,
## which is how a one-byte header disagreement turned into plausible-looking
## terrain instead of an error.
static func load_chunk(dir: String, bx: int, by: int, bz: int) -> VoxelBlock:
	var path := dir.path_join("c_%d_%d_%d.chunk" % [bx, by, bz])
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var data := f.get_buffer(f.get_length())
	f.close()
	if data.size() < HEADER_SIZE:
		push_warning("ChunkFiles: %s is %d bytes, shorter than its %d-byte "
			% [path, data.size(), HEADER_SIZE] + "header")
		return null
	if data.decode_u32(0) != MAGIC:
		push_warning("ChunkFiles: bad magic in %s" % path)
		return null
	var version := data.decode_u16(4)
	if version != VERSION_SUPPORTED:
		push_warning("ChunkFiles: %s is version %d, this build reads %d"
			% [path, version, VERSION_SUPPORTED])
		return null

	# flags and cwidth sit after the version, not at the offsets a 9-byte
	# header would imply.
	var flags := data.decode_u16(6)
	var cwidth := data[8]
	if cwidth != 1 and cwidth != 2:
		push_warning("ChunkFiles: %s has content width %d" % [path, cwidth])
		return null

	var n := MapNode.BLOCK_VOLUME
	var want := HEADER_SIZE + n * cwidth + 2 * n
	if data.size() != want:
		# Not a warning-and-continue: the payload is either truncated or was
		# written by a converter that disagrees about the header, and reading
		# it anyway is what turned a 9-vs-10 byte mismatch into wrong terrain.
		push_warning("ChunkFiles: %s is %d bytes, expected %d for content "
			% [path, data.size(), want] + "width %d" % cwidth)
		return null

	var block := VoxelBlock.new()
	block.origin = Vector3i(bx, by, bz)
	block.is_underground = (flags & 0x01) != 0
	block.day_night_differs = (flags & 0x02) != 0
	# Luanti sets 0x08 when the block is NOT generated.
	block.is_generated = (flags & 0x08) == 0
	block.is_loaded = true

	var p := HEADER_SIZE
	if cwidth == 1:
		for i in n:
			block.content[i] = data[p + i]
		p += n
	else:
		for i in n:
			block.content[i] = (data[p + i * 2] << 8) | data[p + i * 2 + 1]
		p += n * 2

	# Translate foreign content ids through the one ContentDB table, when
	# this world has names to translate them by.
	var id_map := content_map(dir)
	if not id_map.is_empty():
		for i in n:
			block.content[i] = int(id_map.get(block.content[i], ContentDB.AIR))

	for i in n:
		block.light[i] = data[p + i]
	p += n
	for i in n:
		block.param2[i] = data[p + i]
	return block


## True if a chunk file exists, without reading it.
static func has_chunk(dir: String, bx: int, by: int, bz: int) -> bool:
	return FileAccess.file_exists(
		dir.path_join("c_%d_%d_%d.chunk" % [bx, by, bz]))
