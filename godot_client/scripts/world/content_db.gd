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

# --- Ores and refined metals (the engineering vertical slice) ---
#
# Ids 17..24 exist so the progression has a real starting point: you mine
# ore, you smelt it, and the refined block is what the manufacturing system
# consumes. The refined metals are separate blocks rather than an inventory
# concept so that the existing mine/place/inventory/save path carries them
# with no special cases.
const COPPER_ORE := 17
const IRON_ORE := 18
const COAL_ORE := 19
const SILVER_ORE := 20
const COPPER_BLOCK := 21
const IRON_BLOCK := 22
const STEEL_BLOCK := 23
const BRASS_BLOCK := 24

# --- Construction palette -------------------------------------------------
#
# Ids 25..31 are the materials a player builds *with*. They were added when the
# art pipeline replaced the flat vertex colours: before this, the only things
# you could place were terrain and ore, so there was nothing to build a village,
# a road or a workshop out of, and the architecture half of the world had no
# visual language at all.
#
# They are ordinary blocks: the same ContentDB entry, the same mesher surface,
# the same inventory, the same save file. Nothing about the voxel systems knows
# they exist, which is the point.

const PLANKS := 25
const COBBLESTONE := 26
const BRICK := 27
const CONCRETE := 28
const ASPHALT := 29
const GLASS := 30
const METAL_PLATE := 31

## One past the highest registered id. Loops over content use this rather than
## a literal, so adding a block cannot silently fall out of the range.
const MAX_ID := 31

## Blocks that are refined metal rather than natural terrain, and so have a
## matching engineering material id. Everything else returns "".
const METAL_OF := {
	COPPER_ORE: "copper",
	IRON_ORE: "iron",
	COPPER_BLOCK: "copper",
	IRON_BLOCK: "iron",
	STEEL_BLOCK: "steel",
	BRASS_BLOCK: "brass",
}


## The engineering material a content id is made of, or "".
static func material_of(id: int) -> String:
	return String(METAL_OF.get(id, ""))


## ContentDB id for a block name, or -1. The engineering system writes bills in
## material names, and this is where those meet the world.
static func name_to_id(block_name: String) -> int:
	if block_name == "":
		return -1
	_table()
	for id in _entries.size():
		if _entries[id] != null and _entries[id].name == block_name:
			return id
	return -1


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
		Entry.new(COPPER_ORE, "copper_ore", Color(0.62, 0.36, 0.24), false, 0, 2.2),
		Entry.new(IRON_ORE, "iron_ore", Color(0.60, 0.50, 0.42), false, 0, 2.6),
		Entry.new(COAL_ORE, "coal_ore", Color(0.16, 0.16, 0.17), false, 0, 2.0),
		Entry.new(SILVER_ORE, "silver_ore", Color(0.72, 0.74, 0.78), false, 0, 3.0),
		Entry.new(COPPER_BLOCK, "copper_block", Color(0.72, 0.45, 0.28), false, 0, 2.0),
		Entry.new(IRON_BLOCK, "iron_block", Color(0.78, 0.78, 0.80), false, 0, 2.5),
		Entry.new(STEEL_BLOCK, "steel_block", Color(0.56, 0.58, 0.62), false, 0, 3.0),
		Entry.new(BRASS_BLOCK, "brass_block", Color(0.80, 0.68, 0.32), false, 0, 2.4),
		# --- construction palette ---
		Entry.new(PLANKS, "planks", Color(0.62, 0.47, 0.30), false, 0, 1.1),
		Entry.new(COBBLESTONE, "cobblestone", Color(0.47, 0.46, 0.45), false, 0, 2.0),
		Entry.new(BRICK, "brick", Color(0.55, 0.33, 0.26), false, 0, 2.2),
		Entry.new(CONCRETE, "concrete", Color(0.60, 0.60, 0.59), false, 0, 2.4),
		Entry.new(ASPHALT, "asphalt", Color(0.22, 0.22, 0.24), false, 0, 2.0),
		Entry.new(GLASS, "glass", Color(0.72, 0.84, 0.90, 0.28), true, 0, 0.4),
		Entry.new(METAL_PLATE, "metal_plate", Color(0.50, 0.53, 0.56), false, 0, 2.6),
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
