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


## Directory holding the converted chunks, or "" to search `user://world`.
static func resolve_dir(explicit: String = "") -> String:
	if explicit != "":
		return explicit
	for cand in ["user://world", "res://world", "/tmp/testchunks"]:
		if FileAccess.file_exists(cand.path_join(MANIFEST)):
			return cand
	return "user://world"


static func load_manifest(dir: String) -> Dictionary:
	var path := dir.path_join(MANIFEST)
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


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
