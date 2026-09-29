extends SceneTree
## World generator tests: biome variety, terrain integrity, water, features,
## and the Deeps dimension.

var failures := 0


func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: ", msg)


func _init() -> void:
	var gen := WorldGenerator.new(1337)

	# --- Biomes: sample a wide area and expect variety ---
	var seen := {}
	for x in range(-400, 400, 8):
		for z in range(-400, 400, 8):
			seen[gen.biome_at(x, z)] = true
	print("biomes found: ", seen.size(), " ", seen.keys())
	check(seen.size() >= 4, "expected at least 4 biomes in a wide sample")

	# --- Terrain integrity over the spawn area ---
	var gen_air := 0
	var solid := 0
	var bedrock := 0
	for bx in range(-2, 3):
		for bz in range(-2, 3):
			var b := gen.generate_block(Vector3i(bx, 0, bz))
			for i in 4096:
				var c: int = b.content[i]
				if c == ContentDB.AIR:
					gen_air += 1
				elif c == ContentDB.BEDROCK:
					bedrock += 1
				else:
					solid += 1
			check(b.content[MapNode.index(0, 0, 0)] == ContentDB.BEDROCK,
				"y=0 is not bedrock")
	print("voxels in 25 blocks: solid=%d air=%d bedrock=%d"
		% [solid, gen_air, bedrock])
	check(solid > 0, "no solid terrain generated")
	check(bedrock > 0, "no bedrock generated")

	# --- Some water exists somewhere in the sampled region ---
	var water := 0
	for bx in range(-8, 9, 4):
		for bz in range(-8, 9, 4):
			var b := gen.generate_block(Vector3i(bx, 0, bz))
			for i in 4096:
				if b.content[i] == ContentDB.WATER:
					water += 1
	print("water voxels sampled: ", water)
	check(water > 0, "no water found; oceans should exist")

	# --- Trees: sample forest columns until one has wood ---
	var wood := 0
	for bx in range(-10, 10):
		for bz in range(-10, 10):
			var b := gen.generate_block(Vector3i(bx, 1, bz))
			for i in 4096:
				if b.content[i] == ContentDB.WOOD \
						or b.content[i] == ContentDB.LEAVES:
					wood += 1
	print("tree voxels near spawn: ", wood)

	# --- The Deeps ---
	var d := gen.generate_deeps_block(Vector3i(0, -1, 0))
	var deepslate := 0
	var glow := 0
	var air := 0
	for i in 4096:
		var c: int = d.content[i]
		if c == ContentDB.DEEPSLATE or c == ContentDB.DEEPSLATE_DEEP \
				or c == ContentDB.VOID_ROCK:
			deepslate += 1
		elif c == ContentDB.GLOWSTONE:
			glow += 1
		else:
			air += 1
	print("deeps block: deepslate=%d glowstone=%d air=%d"
		% [deepslate, glow, air])
	check(deepslate > 0, "deeps has no deepslate")
	check(air > 0, "deeps has no cavern space")
	check(glow > 0, "deeps has no glowstone (lighting would be flat)")

	print("\nworldgen: %s" % ("PASS" if failures == 0
		else "%d FAILURES" % failures))
	quit(1 if failures > 0 else 0)
