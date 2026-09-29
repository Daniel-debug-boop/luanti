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
	var t := _temp_noise.get_noise_2d(wx, wz)
	var h := _humid_noise.get_noise_2d(wx, wz)
	var height := _height_at(wx, wz)
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
	if wy > h - 6 and _rng.randf() < 0.25:
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
func _add_features(block: VoxelBlock, pos: Vector3i) -> void:
	# Deterministic per-block feature pass.
	var frng := RandomNumberGenerator.new()
	frng.seed = hash(Vector3i(pos.x, 0, pos.z))

	for lx in range(2, BS - 2):
		for lz in range(2, BS - 2):
			var wx := pos.x * BS + lx
			var wz := pos.z * BS + lz
			var h := _height_at(wx, wz)
			if h <= SEA_LEVEL:
				continue
			var biome := biome_at(wx, wz)
			var r := frng.randf()
			match biome:
				Biome.FOREST:
					if r < 0.02:
						_place_tree(block, pos, lx, h + 1, lz, frng)
				Biome.PLAINS:
					if r < 0.004:
						_place_tree(block, pos, lx, h + 1, lz, frng, 3)
				Biome.DESERT:
					if r < 0.012:
						_place_cactus(block, pos, lx, h + 1, lz)
				Biome.TUNDRA:
					if r < 0.01:
						_place_boulder(block, pos, lx, h + 1, lz)


func _place_tree(block: VoxelBlock, pos: Vector3i, lx: int, ly: int,
		lz: int, frng: RandomNumberGenerator, max_h := 6) -> void:
	var trunk := frng.randi_range(4, max_h)
	for i in trunk:
		if not _set_local(block, pos, lx, ly + i, lz, ContentDB.WOOD):
			return
	# Leaf canopy: two shrunken layers plus a cap.
	for dy in [-1, 0]:
		var ry: int = ly + trunk - 1 + dy
		for dx in range(-2, 3):
			for dz in range(-2, 3):
				if absi(dx) == 2 and absi(dz) == 2:
					continue
				_set_local(block, pos, lx + dx, ry, lz + dz, ContentDB.LEAVES)
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			if absi(dx) + absi(dz) > 1:
				continue
			_set_local(block, pos, lx + dx, ly + trunk + 1, lz + dz,
				ContentDB.LEAVES)


func _place_cactus(block: VoxelBlock, pos: Vector3i, lx: int, ly: int,
		lz: int) -> void:
	var n := 2 + int(hash(Vector3i(pos.x, lx, lz)) % 3)
	for i in n:
		_set_local(block, pos, lx, ly + i, lz, ContentDB.CACTUS)


func _place_boulder(block: VoxelBlock, pos: Vector3i, lx: int, ly: int,
		lz: int) -> void:
	_set_local(block, pos, lx, ly, lz, ContentDB.STONE)
	if hash(Vector3i(lx, ly, lz)) % 2 == 0:
		_set_local(block, pos, lx, ly + 1, lz, ContentDB.STONE)


## Write a voxel if it exists in this block. Trees can cross block borders;
## those voxels are simply dropped, which the neighbours' own feature pass
## mostly compensates for.
func _set_local(block: VoxelBlock, pos: Vector3i, lx: int, ly: int,
		lz: int, cid: int) -> bool:
	if lx < 0 or lx >= BS or ly < 0 or ly >= BS or lz < 0 or lz >= BS:
		return false
	var idx := MapNode.index(lx, ly, lz)
	# Features never overwrite terrain, only fill air.
	if block.content[idx] == ContentDB.AIR \
			or block.content[idx] == ContentDB.WATER:
		block.content[idx] = cid
		var day := _sky_light(ly, _height_at(pos.x * BS + lx, pos.z * BS + lz))
		block.light[idx] = day | (day << 4)
	return true


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
