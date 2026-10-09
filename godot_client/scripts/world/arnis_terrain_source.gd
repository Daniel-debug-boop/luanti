class_name ArnisTerrainSource
extends RefCounted
## Arnis elevation, read from the authoritative converted world.
##
## This is the adapter between the two halves of the world pipeline:
##
##     OSM + elevation/DEM -> Arnis -> converted chunks (authoritative)
##                          -> Launti voxels (VoxelWorld, ChunkFiles)
##                          -> Terrain3D heightmap (this class feeds it)
##
## It does **not** generate anything. Every height it reports is read out of a
## chunk file that the Arnis conversion wrote, so a column with no chunk on
## disk stays absent -- there is no noise function here to fall back on, and
## no second world generator hiding behind a "smooth" API.
##
## ## What one height means
##
## A converted chunk is a 16x16x16 lattice of nodes. The authoritative
## elevation of a column is the **top face of the highest ground node** in
## that column: `y = top_node_y + 1`, in node units. That is the plane a
## player stands on, and it is exactly what Terrain3D needs, because a
## Terrain3D height is a Y value in metres and one node is one metre here.
##
## Only *ground* content counts. Trees, water, and everything the player
## built are deliberately **not** terrain: they are geography that stays in
## the Launti/voxel layers (see `docs/TERRAIN3D_INTEGRATION.md`). A road of
## asphalt laid on a hillside therefore reports the height of the hillside
## under it, which is what makes "the road sits on the terrain" true by
## construction instead of by luck.
##
## ## Coordinates
##
## Arnis/Luanti node (wx, wy, wz) -> Launti world (wx, wy, wz) -> Terrain3D
## (x, z) sample with the height as Y. No axis swap, no sign flip, no scale.
## The transform is documented in full in `docs/TERRAIN3D_INTEGRATION.md`,
## and pinned by tests that read asymmetric heights back out of Terrain3D.

## Nodes per chunk edge. The converted-world lattice is 16^3 nodes.
const BS := 16

## Reported for a column the authoritative world does not contain.
## `NAN` rather than 0.0 on purpose: 0 is a legal height (the world floor)
## and a missing column must not be indistinguishable from it.
const ABSENT := NAN

## Chunk blocks scanned above/below the manifest bounds when a world has no
## recorded bounds. The converter always writes `bounds`; this window only
## exists so a hand-assembled directory does not silently read as empty.
const FALLBACK_Y_BLOCKS := Vector2i(-1, 7)

## Chunk blocks whose content is held in memory. Bounded so a long walk
## cannot grow this without limit; the source is a *streaming* reader, not a
## world cache.
const CACHE_LIMIT := 128

## Content classes. `is_ground()` is the whole definition of "this node is
## terrain", and it is data rather than a chain of comparisons so the test
## suite can walk every registered ContentDB id and assert that each one is
## classified deliberately instead of by accident.
##
## Water and ice are hydrology, not ground: the waterline is a separate Launti
## layer and Terrain3D must not bake it into the landscape. Vegetation is a
## plant. The construction palette, the refined metals and glowstone are
## things players and villagers placed.
const GROUND_IDS := [
	ContentDB.GRASS, ContentDB.DIRT, ContentDB.STONE, ContentDB.SAND,
	ContentDB.SNOW, ContentDB.GRAVEL, ContentDB.DEEPSLATE,
	ContentDB.DEEPSLATE_DEEP, ContentDB.VOID_ROCK, ContentDB.BEDROCK,
	ContentDB.COPPER_ORE, ContentDB.IRON_ORE, ContentDB.COAL_ORE,
	ContentDB.SILVER_ORE,
]

## Deliberately not ground, named so a failure can report *why* an id is not
## terrain rather than only that it is not.
const WATER_IDS := [ContentDB.WATER, ContentDB.ICE]
const VEGETATION_IDS := [ContentDB.WOOD, ContentDB.LEAVES, ContentDB.CACTUS]
const BUILT_IDS := [
	ContentDB.PLANKS, ContentDB.COBBLESTONE, ContentDB.BRICK,
	ContentDB.CONCRETE, ContentDB.ASPHALT, ContentDB.GLASS,
	ContentDB.METAL_PLATE, ContentDB.COPPER_BLOCK, ContentDB.IRON_BLOCK,
	ContentDB.STEEL_BLOCK, ContentDB.BRASS_BLOCK, ContentDB.GLOWSTONE,
]

## Converted-world directory this source reads. Empty means auto-detect.
var world_dir := ""

## Optional live voxel world (anything with `get_block(Vector3i)`), consulted
## for chunks that *exist on disk* and are currently resident, so a player's
## edit reaches the terrain surface. A chunk that is not on disk is never read
## from the world: procedural fill must not become terrain.
var live_world: Object = null

var stats := {
	"chunk_reads": 0,        # chunk files actually read from disk
	"chunk_refusals": 0,     # files present but malformed
	"columns_present": 0,
	"columns_absent": 0,
	"derived_chunks": 0,
}

var _manifest := {}
var _bounds := {}
var _authoritative := false
var _ready := false
## Chunk key -> VoxelBlock, or `null` for "the file is not there". Caching the
## absence matters as much as caching the data: the scan for a surface walks
## down through empty blocks, and re-stat()ing the same missing file hundreds
## of times per chunk column is the difference between streaming a region in
## half a second and in ten. `has()` distinguishes the two cases, so no
## sentinel value is needed.
var _cache := {}
var _order: Array[String] = []
## Chunk column (x, z) -> the derived surface of its 256 columns. Deriving
## this once per chunk column is what keeps a region fill to an indexed read
## per node column instead of a second vertical scan.
var _derived := {}


func _init(dir: String = "") -> void:
	configure(dir)


## Read edited chunks from the live world instead of the file they were
## written to. See `live_world`.
func set_live_world(w: Object) -> void:
	live_world = w


## Point the source at a converted-world directory. Re-reads the manifest,
## which is where authority is decided (see `ChunkFiles.is_authoritative`).
func configure(dir: String) -> void:
	var resolved := dir if dir != "" else ChunkFiles.resolve_dir("")
	if resolved == world_dir and _ready:
		return
	world_dir = resolved
	_manifest = ChunkFiles.load_manifest(world_dir)
	_bounds = ChunkFiles.bounds(world_dir)
	_authoritative = ChunkFiles.is_authoritative(world_dir)
	_ready = not _manifest.is_empty()
	forget_cache()


## True when a converted world was found. A world with no manifest is not a
## world: without it there is no provenance and no bounds, and inventing a
## height range is exactly the guess this class exists not to make.
func is_ready() -> bool:
	return _ready


func dir() -> String:
	return world_dir


## Whether this converted world declares itself authoritative for the
## overworld. Absence already means absence here, so nothing in this class
## branches on the answer -- but it *is* part of the contract the terrain
## layer publishes, and the tests pin it.
func is_authoritative() -> bool:
	return _authoritative


## Block-coordinate extents recorded by the converter, or {} when the world
## records none.
func bounds() -> Dictionary:
	return _bounds


## The block-coordinate Y range this source scans, inclusive.
func y_block_range() -> Vector2i:
	var b: Variant = _bounds.get("y", null)
	if b is Array and (b as Array).size() == 2:
		return Vector2i(int((b as Array)[0]), int((b as Array)[1]))
	return FALLBACK_Y_BLOCKS


## Is this node column inside the recorded world extents? A column outside
## them is absent without touching the disk.
func in_bounds(wx: int, wz: int) -> bool:
	if _bounds.is_empty():
		return true
	var bx: Variant = _bounds.get("x", null)
	var bz: Variant = _bounds.get("z", null)
	if bx is Array and (bx as Array).size() == 2:
		if wx < int((bx as Array)[0]) * BS \
				or wx > (int((bx as Array)[1]) + 1) * BS - 1:
			return false
	if bz is Array and (bz as Array).size() == 2:
		if wz < int((bz as Array)[0]) * BS \
				or wz > (int((bz as Array)[1]) + 1) * BS - 1:
			return false
	return true


## Is `id` terrain? The one definition; the mesher handoff and the terrain
## material table both ask this instead of carrying their own list.
static func is_ground(id: int) -> bool:
	return id in GROUND_IDS


## `is_ground()` as a table, indexed by content id: 1 for terrain, 0 for
## everything else. The voxel mesher builds its per-chunk handoff mask once
## per chunk, and a linear search through fourteen ids for each of 4096
## voxels is 57k comparisons for an answer a byte lookup already has.
static var _ground_lut := PackedByteArray()


static func ground_lut() -> PackedByteArray:
	if _ground_lut.is_empty():
		_ground_lut.resize(ContentDB.MAX_ID + 1)
		for id in GROUND_IDS:
			_ground_lut[id] = 1
	return _ground_lut


## How this id is classified, for diagnostics and tests.
static func classify(id: int) -> String:
	if id == ContentDB.AIR:
		return "air"
	if is_ground(id):
		return "ground"
	if id in WATER_IDS:
		return "water"
	if id in VEGETATION_IDS:
		return "vegetation"
	if id in BUILT_IDS:
		return "built"
	return "unknown"


## Walk one node column from the top of the world down.
##
## Returns `{present, y, content}`: the top face height of the highest ground
## node and that node's content id. `present == false` means the column has
## no authoritative ground -- a hole in the world, not a flat zero.
func surface(wx: int, wz: int) -> Dictionary:
	if not _ready or not in_bounds(wx, wz):
		stats["columns_absent"] = int(stats["columns_absent"]) + 1
		return {"present": false, "y": 0, "content": ContentDB.AIR}
	var key := _column_key(wx, wz)
	if not _derived.has(key):
		_derive_column_chunk(key)
	var d: Dictionary = _derived[key]
	var i := _column_index(wx, wz)
	if (d["present"] as PackedByteArray)[i] == 0:
		stats["columns_absent"] = int(stats["columns_absent"]) + 1
		return {"present": false, "y": 0, "content": ContentDB.AIR}
	stats["columns_present"] = int(stats["columns_present"]) + 1
	return {"present": true, "y": (d["y"] as PackedInt32Array)[i],
		"content": (d["content"] as PackedInt32Array)[i]}


## The walkable surface height of a column in Launti world units (one node =
## one metre), or `ABSENT` when the authoritative world has no ground there.
## This is the value Terrain3D is fed.
func surface_y(wx: int, wz: int) -> float:
	var s := surface(wx, wz)
	return float(s["y"]) if bool(s["present"]) else ABSENT


## The ContentDB id of the surface node, or `ContentDB.AIR` when absent.
## Used to pick a Terrain3D texture id per column, so materials come from the
## terrain the world actually has rather than from a height threshold.
func surface_content(wx: int, wz: int) -> int:
	return int(surface(wx, wz)["content"])


## Bulk-fill a square block of node columns, row-major (z outer, x inner).
##
## Returns `{heights, present, contents}`: `heights` is metres with `ABSENT`
## (NAN) for a column the world does not have, `present` is one byte per
## column, and `contents` is the ContentDB id per column.
##
## Written as one call because the caller is filling a Terrain3D region of
## thousands of samples and a per-column function call is the whole cost.
func fill_columns(origin_x: int, origin_z: int, size: int) -> Dictionary:
	var heights := PackedFloat32Array()
	var present := PackedByteArray()
	var contents := PackedInt32Array()
	heights.resize(size * size)
	present.resize(size * size)
	contents.resize(size * size)
	for j in size:
		for i in size:
			var idx := j * size + i
			var s := surface(origin_x + i, origin_z + j)
			var there := bool(s["present"])
			heights[idx] = float(s["y"]) if there else ABSENT
			present[idx] = 1 if there else 0
			contents[idx] = int(s["content"])
	return {"heights": heights, "present": present, "contents": contents}


## Forget the cached surface of one column, so the next read re-derives it.
## The terrain layer calls this for a column whose voxels changed: the world
## is read first (when it has the chunk resident), so an edit reaches the
## terrain surface without any of the derivation being duplicated.
func invalidate_column(wx: int, wz: int) -> void:
	_derived.erase(_column_key(wx, wz))


## Drop every cached chunk and derived surface. Tests need it; a world switch
## needs it; nothing else does, because a converted world is written once and
## then read for the life of the process.
func forget_cache() -> void:
	_cache.clear()
	_order.clear()
	_derived.clear()


# --- internals --------------------------------------------------------------

func _column_key(wx: int, wz: int) -> String:
	return "%d:%d" % [_floor_div(wx, BS), _floor_div(wz, BS)]


## Column slot inside a chunk's derived surface. The derived arrays hold one
## entry per column of the chunk -- 256 of them -- so this is *not*
## `MapNode.index()` (that indexes a 16^3 voxel block) and mixing the two is
## how a 256-entry array gets indexed with a coordinate up to 4095.
func _column_index(wx: int, wz: int) -> int:
	var lx := wx - _floor_div(wx, BS) * BS
	var lz := wz - _floor_div(wz, BS) * BS
	return lz * BS + lx


## Derive the 256 surfaces of one chunk column, top down, reading only the
## chunk files that column actually occupies.
func _derive_column_chunk(key: String) -> void:
	var parts := key.split(":")
	var cx := int(parts[0])
	var cz := int(parts[1])
	var present := PackedByteArray()
	var heights := PackedInt32Array()
	var contents := PackedInt32Array()
	present.resize(BS * BS)
	heights.resize(BS * BS)
	contents.resize(BS * BS)
	var outstanding := BS * BS
	var yr := y_block_range()
	for by in range(yr.y, yr.x - 1, -1):
		if outstanding == 0:
			break
		var block := _load_block(cx, by, cz)
		if block == null:
			continue
		var content: PackedInt32Array = block.content
		for lz in BS:
			for lx in BS:
				var i := lz * BS + lx
				if present[i] != 0:
					continue
				for ly in range(BS - 1, -1, -1):
					var cid: int = content[MapNode.index(lx, ly, lz)]
					# Not ground -> keep descending: a tree over a hill reports
					# the hill, and a road reports what it is laid on.
					if not is_ground(cid):
						continue
					present[i] = 1
					heights[i] = by * BS + ly + 1
					contents[i] = cid
					outstanding -= 1
					break
	_derived[key] = {"present": present, "y": heights, "content": contents}
	stats["derived_chunks"] = int(stats["derived_chunks"]) + 1


func _load_block(cx: int, by: int, cz: int) -> VoxelBlock:
	var key := "%d:%d:%d" % [cx, by, cz]
	if _cache.has(key):
		var cached := _cache[key] as VoxelBlock
		# `null` is a cached "the file is not there": returned as-is, never
		# substituted from the live world.
		if cached == null:
			return null
		return _live(cx, by, cz, cached)
	var block: VoxelBlock = null
	if ChunkFiles.has_chunk(world_dir, cx, by, cz):
		block = ChunkFiles.load_chunk(world_dir, cx, by, cz)
		stats["chunk_reads"] = int(stats["chunk_reads"]) + 1
		if block == null:
			# Present on disk and unreadable: a refusal, counted separately so
			# a malformed world cannot look like an empty one.
			stats["chunk_refusals"] = int(stats["chunk_refusals"]) + 1
	_cache[key] = block
	_order.append(key)
	while _order.size() > CACHE_LIMIT:
		_cache.erase(_order.pop_front())
	return null if block == null else _live(cx, by, cz, block)


## The live block for a chunk that is on disk, or the one that was read.
func _live(cx: int, by: int, cz: int, disk: VoxelBlock) -> VoxelBlock:
	if live_world == null or not is_instance_valid(live_world):
		return disk
	var wb: Variant = live_world.call("get_block", Vector3i(cx, by, cz))
	return disk if wb == null else (wb as VoxelBlock)


static func _floor_div(a: int, b: int) -> int:
	var q := a / b
	if (a % b) != 0 and ((a < 0) != (b < 0)):
		q -= 1
	return q
