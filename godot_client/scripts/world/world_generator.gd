class_name WorldGenerator
extends RefCounted
## Procedural overworld and dimension generation, producing VoxelBlocks
## directly in memory. Used when no converted world directory is present, and
## as the source of truth for block ids (see ContentDB).
##
## Biomes are chosen from two low-frequency noise fields (temperature and
## humidity), which is cheap and gives natural, non-repeating borders. Terrain
## height, surface blocks, and features (trees, cacti, boulders) follow the
## biome, so each one reads distinctly in-game.

const BS := 16

enum Biome { OCEAN, BEACH, PLAINS, FOREST, DESERT, TUNDRA }

## Sea level in node units.
const SEA_LEVEL := 12
## Terrain amplitude around the base height.
const TERRAIN_AMP := 9.0
const BASE_HEIGHT := 14.0

## Dimension ids, kept as plain ints so they can cross the chunk key hash.
const DIM_OVERWORLD := 0
const DIM_DEEPS := 1

var _temp_noise := FastNoiseLite.new()
var _humid_noise := FastNoiseLite.new()
var _terrain_noise := FastNoiseLite.new()
var _cave_noise := FastNoiseLite.new()
var _deeps_noise := FastNoiseLite.new()
## A dedicated field for ore veins, kept separate from the cave noise so
## retuning caves never reshuffles where the copper is.
var _ore_noise := FastNoiseLite.new()
var _rng := RandomNumberGenerator.new()
## One seeded, stream-safe roll: a fresh hash of the world seed and the
## absolute world coordinate, mapped to [0,1). Every per-column and
## per-feature decision MUST come through here instead of a shared mutable
## RNG, because a shared RNG makes a chunk's content depend on which chunks
## were generated before it -- invalid for streaming, unloading, reloading,
## multiplayer synchronization and deterministic saves.
static func _roll01(x: int, y: int, z: int) -> float:
	return float(hash(Vector3i(x, y, z)) & 0x7FFFFFFF) / 2147483648.0


func _init(seed_value: int = 1337) -> void:
	_rng.seed = seed_value
	_temp_noise.seed = seed_value + 1
	_temp_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_temp_noise.frequency = 0.004
	_humid_noise.seed = seed_value + 2
	_humid_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_humid_noise.frequency = 0.0045
	_terrain_noise.seed = seed_value + 3
	_terrain_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_terrain_noise.frequency = 0.018
	_cave_noise.seed = seed_value + 4
	_cave_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_cave_noise.frequency = 0.06
	_deeps_noise.seed = seed_value + 5
	_deeps_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_deeps_noise.frequency = 0.05
	# Low frequency, so a vein is a blob several blocks across rather than
	# isolated single cells a player would walk past.
	_ore_noise.seed = seed_value + 6
	_ore_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_ore_noise.frequency = 0.09


func biome_at(wx: int, wz: int) -> int:
	return _biome_from(wx, wz, _height_at(wx, wz))


## The biome decision, given the surface height already in hand so callers
## that need both do not sample the terrain noise twice.
func _biome_from(wx: int, wz: int, height: int) -> int:
	var t := _temp_noise.get_noise_2d(wx, wz)
	var h := _humid_noise.get_noise_2d(wx, wz)
	if height < SEA_LEVEL - 2:
		return Biome.OCEAN
	if height <= SEA_LEVEL + 1:
		return Biome.BEACH
	if t > 0.35 and h < 0.0:
		return Biome.DESERT
	if t < -0.35:
		return Biome.TUNDRA
	if h > 0.15:
		return Biome.FOREST
	return Biome.PLAINS


func biome_name(b: int) -> String:
	match b:
		Biome.OCEAN: return "Ocean"
		Biome.BEACH: return "Beach"
		Biome.FOREST: return "Forest"
		Biome.DESERT: return "Desert"
		Biome.TUNDRA: return "Tundra"
	return "Plains"


func _height_at(wx: int, wz: int) -> int:
	var n := _terrain_noise.get_noise_2d(wx, wz)
	# Ridged component gives occasional hills inside gentle terrain.
	var ridge := 1.0 - absf(_terrain_noise.get_noise_2d(wx * 2.7 + 900.0,
		wz * 2.7 - 400.0))
	return int(BASE_HEIGHT + n * TERRAIN_AMP + ridge * 3.0)


## Generate one overworld block.
func generate_block(pos: Vector3i) -> VoxelBlock:
	var block := VoxelBlock.new()
	block.origin = pos
	block.is_loaded = true
	block.is_generated = true

	for lx in BS:
		for lz in BS:
			var wx := pos.x * BS + lx
			var wz := pos.z * BS + lz
			var h := _height_at(wx, wz)
			var biome := biome_at(wx, wz)
			for ly in BS:
				var wy := pos.y * BS + ly
				var idx := MapNode.index(lx, ly, lz)
				var cid := _terrain_column(biome, wy, h, wx, wz)
				block.content[idx] = cid
				var day := _sky_light(wy, h)
				block.light[idx] = day | (day << 4)

	_add_features(block, pos)
	return block


## One overworld column, from bedrock up.
func _terrain_column(biome: int, wy: int, h: int, wx: int, wz: int) -> int:
	if wy == 0:
		return ContentDB.BEDROCK
	if wy > h:
		if wy <= SEA_LEVEL:
			return ContentDB.WATER
		return ContentDB.AIR

	# Caves: carve where the noise field crosses a shell.
	var cave := _cave_noise.get_noise_3d(wx, wy * 1.4, wz)
	if wy > 2 and wy < h - 2 and cave > 0.42:
		return ContentDB.AIR

	if wy == h:
		match biome:
			Biome.OCEAN: return ContentDB.SAND
			Biome.BEACH: return ContentDB.SAND
			Biome.DESERT: return ContentDB.SAND
			Biome.TUNDRA: return ContentDB.SNOW
			Biome.FOREST: return ContentDB.GRASS
			_: return ContentDB.GRASS
	if wy > h - 4:
		return ContentDB.DIRT if biome != Biome.DESERT else ContentDB.SAND
	# Deterministic from position alone: the roll is hashed from the absolute
	# world coordinate, never from a shared mutable RNG. A column's gravel
	# must not depend on how many columns were generated before it.
	if _roll01(wx, wy, wz) < 0.25:
		return ContentDB.GRAVEL
	# Ore veins. Deterministic from position alone, so a chunk regenerates
	# identically and a save/load cycle never moves a vein.
	var ore := _ore_at(wx, wy, wz, h)
	if ore != ContentDB.AIR:
		return ore
	return ContentDB.STONE


## Which ore, if any, occupies this cell. Veins are blobs of a low-frequency
## noise field, which gives clustered deposits the way real veins run rather
## than the confetti a per-cell random would give.
##
## Depth is what makes the progression work: copper is shallow and common,
## iron sits below it, and silver is deep and rare. That ordering is the
## reason a player goes digging, and it costs three lines of arithmetic.
func _ore_at(wx: int, wy: int, wz: int, surface: int) -> int:
	if wy < 1 or wy > surface - 5:
		return ContentDB.AIR
	var depth := surface - wy
	# Copper: shallow, generous.
	if depth < 26 and _ore_noise.get_noise_3d(wx, wy * 1.6, wz) > 0.46:
		return ContentDB.COPPER_ORE
	# Iron: below the copper band, a little rarer.
	if depth >= 14 and _ore_noise.get_noise_3d(wx + 91.0, wy * 1.6,
			wz - 41.0) > 0.48:
		return ContentDB.IRON_ORE
	# Coal: mid depth, the fuel that makes the furnaces worth building.
	if depth >= 8 and depth < 40 and _ore_noise.get_noise_3d(wx - 17.0,
			wy * 1.4, wz + 63.0) > 0.45:
		return ContentDB.COAL_ORE
	# Silver: deep and rare, the reward for digging properly.
	if depth >= 34 and _ore_noise.get_noise_3d(wx + 7.0, wy * 1.2,
			wz + 129.0) > 0.53:
		return ContentDB.SILVER_ORE
	return ContentDB.AIR


## Daylight value for the low nibble of the light byte.
func _sky_light(wy: int, h: int) -> int:
	if wy > h:
		return MapNode.LIGHT_SUN
	var depth := h - wy
	return clampi(MapNode.LIGHT_MAX - depth, 2, MapNode.LIGHT_MAX)


## Scatter biome features after terrain, so trees can poke above the surface.
##
## Features are WORLD-COORDINATE decisions, never clipped by chunk ownership.
## A tree planted by column wx,wz writes its trunk and canopy through a
## block-relative `set` that lands in THIS block where the voxel happens to
## be inside it -- and the neighbouring block's own feature pass re-derives
## the same tree from the same column and fills in the parts that fall in
## it. Because every input to the decision is a function of absolute world
## coordinates and nothing else, generating (A before B) and (B before A)
## produce exactly the same world: cross-chunk canopies and trunks can no
## longer be truncated at a block boundary.
func _add_features(block: VoxelBlock, pos: Vector3i) -> void:
	# A tree's canopy reaches 2 columns beyond its trunk, so scan columns
	# up to 2 outside this block: a boundary block gets the parts of a
	# neighbour's tree that overhang it. The `set` below drops voxels that
	# are still further outside.
	for wx in range(pos.x * BS - 2, pos.x * BS + BS + 2):
		for wz in range(pos.z * BS - 2, pos.z * BS + BS + 2):
			var h := _height_at(wx, wz)
			if h <= SEA_LEVEL:
				continue
			var biome := _biome_from(wx, wz, h)
			var r := _roll01(wx, 0, wz)
			var detected := false
			if biome == Biome.FOREST:
				detected = r < 0.02
			elif biome == Biome.PLAINS:
				detected = r < 0.004
			elif biome == Biome.DESERT:
				detected = r < 0.012
			elif biome == Biome.TUNDRA:
				detected = r < 0.01
			if not detected:
				continue
			var kind := 0 if (biome == Biome.FOREST or biome == Biome.PLAINS) \
				else (1 if biome == Biome.DESERT else 2)
			_place_feature(block, pos, wx, h + 1, wz, kind)


## Stamp one world-column feature into `block`. Every voxel written has the
## same value no matter which block is doing the stamping, so two blocks
## sharing a feature produce complementary, non-conflicting halves.
func _place_feature(block: VoxelBlock, pos: Vector3i, wx: int, wy: int,
		wz: int, kind: int) -> void:
	if kind == 0:
		var max_h := 6 if _biome_from(wx, wz, wy - 1) == Biome.FOREST else 3
		var trunk := 4 + int(_roll01(wx, 1, wz) * float(max_h - 3))
		for i in trunk:
			_stamp(block, pos, wx, wy + i, wz, ContentDB.WOOD)
		# Leaf canopy: two shrunken layers plus a cap.
		for dy in [-1, 0]:
			var ry: int = wy + trunk - 1 + dy
			for dx in range(-2, 3):
				for dz in range(-2, 3):
					if absi(dx) == 2 and absi(dz) == 2:
						continue
					_stamp(block, pos, wx + dx, ry, wz + dz,
						ContentDB.LEAVES)
			for dx in range(-1, 2):
				for dz in range(-1, 2):
					if absi(dx) + absi(dz) > 1:
						continue
					_stamp(block, pos, wx + dx, wy + trunk + 1,
						wz + dz, ContentDB.LEAVES)
	elif kind == 1:
		var n := 2 + int(_roll01(wx, 2, wz) * 3.0) % 3
		for i in n:
			_stamp(block, pos, wx, wy + i, wz, ContentDB.CACTUS)
	else:
		_stamp(block, pos, wx, wy, wz, ContentDB.STONE)
		if _roll01(wx, 3, wz) < 0.5:
			_stamp(block, pos, wx, wy + 1, wz, ContentDB.STONE)


## Write one world voxel into `block` if that voxel is inside it. Features
## never overwrite terrain, only fill air or water -- so a canopy stamping
## from one side cannot out-vote terrain stamped from the other.
##
## This replaces `_set_local` and the dropped-voxel behaviour: the caller
## re-derives the feature for the columns that reach into this block, so a
## boundary block no longer silently truncates a tree.
func _stamp(block: VoxelBlock, pos: Vector3i, wx: int, wy: int, wz: int,
		cid: int) -> void:
	var lx := wx - pos.x * BS
	var ly := wy - pos.y * BS
	var lz := wz - pos.z * BS
	if lx < 0 or lx >= BS or ly < 0 or ly >= BS or lz < 0 or lz >= BS:
		return
	var idx := MapNode.index(lx, ly, lz)
	if block.content[idx] == ContentDB.AIR \
			or block.content[idx] == ContentDB.WATER:
		block.content[idx] = cid
		var day := _sky_light(wy - pos.y * BS,
			_height_at(wx, wz) - pos.y * BS)
		block.light[idx] = day | (day << 4)


## Generate one block of The Deeps: a dark cavern dimension with deepslate
## strata, glowstone clusters, and carved tunnels.
func generate_deeps_block(pos: Vector3i) -> VoxelBlock:
	var block := VoxelBlock.new()
	block.origin = pos
	block.is_loaded = true
	block.is_generated = true

	for lx in BS:
		for ly in BS:
			for lz in BS:
				var wx := pos.x * BS + lx
				var wy := pos.y * BS + ly
				var wz := pos.z * BS + lz
				var idx := MapNode.index(lx, ly, lz)

				if wy >= 14 or wy <= -20:
					block.content[idx] = ContentDB.VOID_ROCK
					block.light[idx] = 0
					continue

				# Shell of the cavern: solid deepslate, carved into tunnels.
				var n := _deeps_noise.get_noise_3d(wx, wy, wz)
				var tunnel := absf(_deeps_noise.get_noise_3d(
					wx * 1.9 + 55.0, wy * 1.9, wz * 1.9 - 33.0))
				var solid := n > -0.12 or tunnel < 0.08
				if solid:
					var cid := ContentDB.DEEPSLATE
					if wy < -8:
						cid = ContentDB.DEEPSLATE_DEEP
					block.content[idx] = cid
					block.light[idx] = 0
				else:
					block.content[idx] = ContentDB.AIR
					# Glowstone studs on tunnel ceilings and walls: a separate
					# high-frequency field picks spots in open cavern cells.
					var glow := _deeps_noise.get_noise_3d(
						wx * 3.3 - 17.0, wy * 3.3, wz * 3.3 + 71.0)
					if glow > 0.55:
						block.content[idx] = ContentDB.GLOWSTONE
						block.light[idx] = ContentDB.light_of(
							ContentDB.GLOWSTONE)

	return block
