extends VoxelGeneratorScript
## Luanti-style terrain generator running inside Voxel Tools' block pipeline.
##
## This file extends `VoxelGeneratorScript`, a class that only exists in the
## official Voxel Tools engine build. It is therefore never loaded on stock
## Godot -- `ZylannWorld` guards every load with ClassDB.class_exists().
## See tools/fetch_voxel_engine.sh.
##
## Voxel Tools calls _generate_block() once per 16x16x16 data block, on its own
## worker threads, so this must be thread-safe: it touches no shared state and
## allocates nothing per voxel.
##
## Block ids come from ContentDB so the Zylann backend and the GDScript greedy-
## mesher backend describe the world identically.

## Vertical extent. Below BEDROCK_Y is unbreakable, SEA_LEVEL fills with water.
const BEDROCK_Y := 0
const SEA_LEVEL := 40
const WORLD_BOTTOM := -24
const WORLD_TOP := 96

## Peak-to-valley relief, in voxels.
const RELIEF := 26

## Blocks generated per call; reported so tests can assert work actually ran.
var blocks_generated := 0

var _height := FastNoiseLite.new()
var _temperature := FastNoiseLite.new()
var _humidity := FastNoiseLite.new()


func _init() -> void:
	_height.seed = 1337
	_height.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_height.frequency = 0.004
	_height.fractal_type = FastNoiseLite.FRACTAL_FBM
	_height.fractal_octaves = 5

	_temperature.seed = 8081
	_temperature.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_temperature.frequency = 0.0016

	_humidity.seed = 4242
	_humidity.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_humidity.frequency = 0.0021


## Surface height (the y of the topmost solid block) for a world column.
func height_at(x: int, z: int) -> int:
	var base := SEA_LEVEL + int(round(_height.get_noise_2d(x, z) * float(RELIEF)))
	return clampi(base, WORLD_BOTTOM + 4, WORLD_TOP - 8)


## Climate sample, both in -1..1. Drives the surface block choice.
func climate_at(x: int, z: int) -> Vector2:
	return Vector2(_temperature.get_noise_2d(x, z), _humidity.get_noise_2d(x, z))


## Which surface block caps this column, given its climate and altitude.
func surface_block(x: int, z: int, h: int) -> int:
	var c := climate_at(x, z)
	if h <= SEA_LEVEL + 1:
		return ContentDB.SAND          # beaches and sea floor
	if c.x < -0.45:
		return ContentDB.SNOW          # cold
	if c.x < -0.2 and c.y > 0.25:
		return ContentDB.ICE           # frozen coast
	if c.y < -0.4:
		return ContentDB.SAND          # arid
	return ContentDB.GRASS


## Full column profile, top block first. Kept separate from _generate_block so
## tests can exercise the terrain rules without a running Voxel Tools pipeline.
func column_at(x: int, z: int) -> PackedInt32Array:
	var h := height_at(x, z)
	var out := PackedInt32Array()
	out.resize(h - WORLD_BOTTOM + 2)
	for y in range(WORLD_BOTTOM, h + 1):
		var wy := y - WORLD_BOTTOM
		if y <= BEDROCK_Y:
			out[wy] = ContentDB.BEDROCK
		elif y == h:
			out[wy] = surface_block(x, z, h)
		elif y >= h - 3:
			out[wy] = ContentDB.DIRT
		elif y < SEA_LEVEL - 6 and y % 17 == 0:
			out[wy] = ContentDB.GLOWSTONE   # rare cavern light
		else:
			out[wy] = ContentDB.STONE
	return out


func _generate_block(buffer: VoxelBuffer, origin: Vector3i, channel: int) -> void:
	blocks_generated += 1
	var y0 := origin.y
	var y1 := y0 + 16
	for lx in 16:
		var wx := origin.x + lx
		for lz in 16:
			var wz := origin.z + lz
			var h := height_at(wx, wz)
			var surf := surface_block(wx, wz, h)
			for ly in 16:
				var wy := y0 + ly
				if wy < WORLD_BOTTOM or wy > h:
					continue
				var v := ContentDB.STONE
				if wy <= BEDROCK_Y:
					v = ContentDB.BEDROCK
				elif wy == h:
					v = surf
				elif wy >= h - 3:
					v = ContentDB.DIRT
				elif wy < SEA_LEVEL - 6 and wy % 17 == 0:
					v = ContentDB.GLOWSTONE
				# Water is filled by a second pass so it also covers the
				# air above the terrain inside the block.
				buffer.set_voxel(v, lx, ly, lz, channel)
			# Sea fill, only where the column actually reaches sea level.
			if h < SEA_LEVEL:
				for ly in 16:
					var wy2 := y0 + ly
					if wy2 > h and wy2 <= SEA_LEVEL:
						buffer.set_voxel(ContentDB.WATER, lx, ly, lz, channel)
