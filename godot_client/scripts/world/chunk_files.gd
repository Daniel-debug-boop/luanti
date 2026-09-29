class_name ChunkFiles
extends RefCounted
## Reads the flat chunk files produced by tools/convert_world.py.
##
## File layout (little-endian), written by `write_chunk` in the converter:
##   magic    u32  'LVXC' (0x4358564C)
##   version  u16  1
##   flags    u16  block flags (bit0 underground, bit1 day/night, bit3 generated)
##   cwidth   u8   1 or 2 bytes per content id
##   reserved u8
##   content  cwidth * 4096
##   light    4096
##   param2   4096

const MAGIC := 0x4358564C
const MANIFEST := "manifest.json"
## magic u32 + version u16 + flags u16 + cwidth u8 + reserved u8
const HEADER_SIZE := 9


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
		return null
	if data.decode_u32(0) != MAGIC:
		push_warning("ChunkFiles: bad magic in %s" % path)
		return null

	var block := VoxelBlock.new()
	block.origin = Vector3i(bx, by, bz)
	var flags := data.decode_u16(4)
	var cwidth := data[8]
	block.is_underground = (flags & 0x01) != 0
	block.day_night_differs = (flags & 0x02) != 0
	# Luanti sets 0x08 when the block is NOT generated.
	block.is_generated = (flags & 0x08) == 0
	block.is_loaded = true

	var n := MapNode.BLOCK_VOLUME
	var p := HEADER_SIZE
	if cwidth == 1:
		if p + n > data.size():
			return null
		for i in n:
			block.content[i] = data[p + i]
		p += n
	elif cwidth == 2:
		if p + n * 2 > data.size():
			return null
		for i in n:
			block.content[i] = (data[p + i * 2] << 8) | data[p + i * 2 + 1]
		p += n * 2
	else:
		return null

	if p + n * 2 > data.size():
		return null
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
