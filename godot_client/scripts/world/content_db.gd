class_name ContentDB
extends RefCounted
## Content registry: the Godot-side stand-in for Luanti's node definitions.
##
## Luanti derives every voxel behaviour from mods at runtime. This migration
## hard-codes the subset the client needs -- id, name, palette colour,
## translucency, emissive light, and hardness -- in one table that the mesher,
## the world generator, and the HUD all read.
##
## Ids are stable: 0 air, 1..N terrain. Keep in sync with tools/worldgen.py.

## One entry per registered content id.
class Entry:
	var id := 0
	var name := ""
	## Base albedo, in sRGB, used directly as the mesh vertex tint.
	var color := Color(1, 1, 1)
	## Rendered in the transparent pass when true.
	var translucent := false
	## 0..15: extra light this block contributes to its faces.
	var light := 0
	## Relative dig time, 1.0 = stone. Cosmetic for now.
	var hardness := 1.0
	## Not a solid cube: faces are always drawn (leaves, glass).
	var cutout := false

	func _init(p_id: int, p_name: String, p_color: Color,
			p_translucent := false, p_light := 0, p_hardness := 1.0,
			p_cutout := false) -> void:
		id = p_id
		name = p_name
		color = p_color
		translucent = p_translucent
		light = p_light
		hardness = p_hardness
		cutout = p_cutout


# --- Terrain (overworld) ---
const AIR := 0
const GRASS := 1
const DIRT := 2
const STONE := 3
const WATER := 4
const SAND := 5
const SNOW := 6
const ICE := 7
const CACTUS := 8
const WOOD := 9
const LEAVES := 10
const GRAVEL := 11

# --- The Deeps (second dimension) ---
const DEEPSLATE := 12
const DEEPSLATE_DEEP := 13
const GLOWSTONE := 14
const VOID_ROCK := 15

# --- Bedrock ---
const BEDROCK := 16


static var _entries: Array[Entry] = []


static func _table() -> Array[Entry]:
	if not _entries.is_empty():
		return _entries
	_entries = [
		Entry.new(AIR, "air", Color(0, 0, 0, 0)),
		Entry.new(GRASS, "grass", Color(0.42, 0.65, 0.30)),
		Entry.new(DIRT, "dirt", Color(0.48, 0.35, 0.24)),
		Entry.new(STONE, "stone", Color(0.52, 0.52, 0.54)),
		Entry.new(WATER, "water", Color(0.25, 0.45, 0.85, 0.62), true),
		Entry.new(SAND, "sand", Color(0.83, 0.77, 0.55)),
		Entry.new(SNOW, "snow", Color(0.94, 0.95, 0.98)),
		Entry.new(ICE, "ice", Color(0.65, 0.82, 0.95, 0.75), true),
		Entry.new(CACTUS, "cactus", Color(0.28, 0.52, 0.26)),
		Entry.new(WOOD, "wood", Color(0.55, 0.40, 0.25)),
		Entry.new(LEAVES, "leaves", Color(0.30, 0.55, 0.24), false, 0, 0.4,
			true),
		Entry.new(GRAVEL, "gravel", Color(0.45, 0.43, 0.42)),
		Entry.new(DEEPSLATE, "deepslate", Color(0.22, 0.22, 0.25)),
		Entry.new(DEEPSLATE_DEEP, "deepslate_deep", Color(0.12, 0.12, 0.14)),
		Entry.new(GLOWSTONE, "glowstone", Color(1.0, 0.85, 0.45), false, 15),
		Entry.new(VOID_ROCK, "void_rock", Color(0.07, 0.06, 0.09)),
		Entry.new(BEDROCK, "bedrock", Color(0.18, 0.18, 0.18), false, 0, 100.0),
	]
	return _entries


static func get_entry(id: int) -> Entry:
	var t := _table()
	if id >= 0 and id < t.size():
		return t[id]
	return t[0]


static func name_of(id: int) -> String:
	return get_entry(id).name


static func color_of(id: int) -> Color:
	return get_entry(id).color


static func is_translucent(id: int) -> bool:
	return get_entry(id).translucent


## Emitted light of a block, 0..15.
static func light_of(id: int) -> int:
	return get_entry(id).light


static func is_solid(id: int) -> bool:
	return id != AIR


## Blocks with real content (used to skip meshing all-air blocks).
static func is_opaque(id: int) -> bool:
	return is_solid(id) and not get_entry(id).translucent \
		and not get_entry(id).cutout
