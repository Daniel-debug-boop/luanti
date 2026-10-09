class_name TerrainLayer
extends Node3D
## The terrain representation layer: Terrain3D, fed from the Arnis world.
##
## ## Where this sits
##
##     Arnis  ->  converted chunks  ->  Launti (VoxelWorld, this repository)
##                                         |-> gameplay/voxel entities
##                                         `-> Terrain3D (this node)
##
## Arnis stays the authoritative source of geographic data. This node owns a
## Terrain3D instance and nothing else: it does not generate, it does not
## decide where terrain is, and it has no fallback of its own. Every height it
## writes comes from `ArnisTerrainSource`, which reads the converted chunk
## files Arnis produced. A column the world does not contain becomes a *hole*
## in Terrain3D -- visible absence, which is what authoritative absence
## means -- rather than a flat zero that would be an invented plane.
##
## ## Streaming
##
## Terrain3D stores data in *regions* of `region_size` samples (256 by
## default, so 256 m at a vertex spacing of 1 m). This layer keeps only the
## regions around the focus resident, builds at most `regions_per_update` of
## them per call, and removes the ones that fall outside `stream_radius`. It
## therefore never loads the whole converted world: a world of any size costs
## the same as the window the player can see, which is the same bargain the
## voxel streamer makes.
##
## ## Who draws the ground
##
## Terrain3D draws the *ground surface*; the voxel mesher keeps drawing
## everything else -- buildings, roads, water, vegetation, caves, and every
## block the player edits. To stop two renderers drawing the same surface,
## `VoxelWorld` asks `covers_chunk()` before it meshes a chunk, and skips the
## top faces of ground blocks it can hand over (`GreedyMesher.geometry`'s
## `hidden_tops`). The handoff is per chunk and only where the whole chunk is
## covered, so a partially-mapped chunk keeps its voxel ground and no hole
## can appear at a streaming edge.
##
## That is also why `enable_collision` defaults to **false**: the voxels are
## authoritative for physics, and a second collision surface under the player
## is a bug, not a feature. Turn it on only for a scene that has no voxel
## collision (foliage instancing, a terrain-only tech demo).

## Emitted when which chunks are covered by Terrain3D changes. `VoxelWorld`
## listens so it can re-mesh the chunks whose faces changed hands.
signal coverage_changed()

const ArnisTerrainSourceScript := preload(
	"res://scripts/world/arnis_terrain_source.gd")
const MaterialSet := preload("res://scripts/world/terrain3d_material_set.gd")

## Terrain3DRegion.MapType, named here because the enum lives on a class that
## may not be registered (see `configure`): TYPE_HEIGHT then TYPE_CONTROL.
const MAP_HEIGHT := 0
const MAP_CONTROL := 1
## Control-map bits, from Terrain3D's documented control map format:
## base texture id at bit 27, hole at bit 2.
const CONTROL_BASE_SHIFT := 27
const CONTROL_HOLE_SHIFT := 2

## Converted chunk directory. Empty means auto-detect, same as the world's.
@export var world_dir := ""
## How far around the focus, in metres, terrain regions are kept resident.
## Should exceed the voxel view distance (`view_radius * 16`) so the handoff
## always covers everything the voxel renderer would draw.
@export var stream_radius := 512.0
## Regions built per `update_around` call. One, like the voxel streamer's
## budget: a region is 65,536 columns of authoritative data to read, and
## reading them all in the frame the player crossed a boundary is a hitch.
@export var regions_per_update := 1
## Preferred texture resolution for terrain materials; the closest available
## rung at or below it is used.
@export var texture_tier := 1024
## Terrain3D's own LOD count. 7 is its default and is deliberately not
## replaced with a custom LOD scheme: the clipmap and its LODs are the feature
## this layer is here to use.
@export var mesh_lods := 7
## Samples per region edge. 0 keeps whatever Terrain3D is configured with
## (256 by default). A converted voxel world streams in 16 m chunks, so a
## smaller region -- 64 is Terrain3D's own smallest non-trivial size -- is a
## legitimate setting; the default is left alone because changing a tool's
## default to suit one caller is how two configurations quietly diverge.
@export var region_size_setting := 0
## Voxels own collision; see the class note.
@export var enable_collision := false
## Build Terrain3D texture assets from the project's CC0 sets.
@export var with_materials := true

## The Terrain3D node. Untyped on purpose: naming a GDExtension class in a type
## annotation makes *this script* unparseable in a build where the extension is
## not registered, which would take the whole game down instead of refusing to
## draw terrain. The class is resolved by name and its absence is a runtime
## refusal with a message.
var terrain: Object = null
var source: ArnisTerrainSourceScript = ArnisTerrainSourceScript.new()
## Optional live voxel world. When set, a chunk that exists on disk but is
## currently resident is read from the world instead, so an edit -- a dug
## hole, a placed block -- is reflected in the terrain surface. Chunks that do
## *not* exist on disk are never read from it: procedural fill must not reach
## Terrain3D.
var world: Object = null

var stats := {
	"regions_built": 0,
	"regions_removed": 0,
	"columns_written": 0,
	"columns_hole": 0,
	"region_build_ms_total": 0.0,
	"materials": 0,
}

## Vector2i region location -> {"covered": {chunk key: true}, "chunks": int}.
var _resident := {}
## Region locations waiting to be built, nearest first.
var _queue: Array[Vector2i] = []
## Columns edited since the last `update_around`, as "x:z" -> Vector2i.
var _pending_columns := {}
var _region_size := 256
## Region size requested by `region_size_setting`, applied once Terrain3D's
## data object exists (`change_region_size` needs it).
var _wanted_region_size := 0
## Terrain3D texture assets, built in `configure` and attached on first use.
var _pending_assets: Object = null
## Set once the collision mode has been applied in the tree.
var _collision_applied := false
var _refusal := ""
var _configured := false


## Point the layer at a converted world and create the Terrain3D node.
##
## Returns "" on success or the reason it refused. A refusal is a message, not
## a crash: a build without the addon, or a scene pointed at a directory that
## is not a converted world, must run exactly as it did before this layer
## existed.
func configure(dir: String = "") -> String:
	if _configured:
		return _refusal
	_configured = true
	if not ClassDB.class_exists("Terrain3D"):
		_refusal = ("Terrain3D is not registered: addons/terrain_3d is missing, "
			+ "or the extension has not been loaded (.godot/extension_list.cfg)")
		push_warning("TerrainLayer: " + _refusal)
		return _refusal
	source.configure(world_dir if dir == "" else dir)
	if not source.is_ready():
		_refusal = "no converted world manifest under '%s'" % source.dir()
		push_warning("TerrainLayer: " + _refusal)
		return _refusal

	var t: Object = ClassDB.instantiate("Terrain3D")
	if t == null:
		_refusal = "Terrain3D could not be instantiated"
		push_warning("TerrainLayer: " + _refusal)
		return _refusal
	terrain = t
	terrain.set("name", "Terrain3D")
	# One height sample per node column, so a Launti node coordinate and a
	# Terrain3D sample coordinate are the same number. See the coordinate
	# table in docs/TERRAIN3D_INTEGRATION.md.
	terrain.call("set_vertex_spacing", 1.0)
	terrain.call("set_mesh_lods", mesh_lods)
	# `data_directory` is deliberately left at Terrain3D's own default, which
	# is empty: nothing here ever calls save, and a layer that quietly wrote
	# terrain files of its own would be a second source of truth on disk.
	# The test asserts the default is still empty.
	#
	# Collision is NOT set here. Terrain3D rebuilds its collision objects when
	# it enters the tree and takes its default mode (1, dynamic) over anything
	# set before that -- measured, not assumed: a pre-tree
	# `set_collision_mode(0)` read back as 1. It is applied in `_ensure_data`,
	# where the node is in the tree and the value sticks.
	add_child(terrain)
	# The data object exists once Terrain3D's `_ready` has run, which needs
	# this layer to be in the tree. Everything below therefore reads it
	# lazily (`_ensure_data`) rather than refusing here: a caller that
	# configures before parenting is following the obvious order, and it
	# should not be told the extension is broken.
	_region_size = int(terrain.call("get_region_size"))
	if _region_size <= 0:
		_region_size = 256
	_wanted_region_size = region_size_setting
	# The texture assets are *built* here but attached in `_ensure_data`: a
	# Terrain3DAssets assigned before the node is in the tree makes Terrain3D
	# resolve an empty resource path on entry (an engine-side load of "",
	# which prints an error and does nothing). Entering the tree first is free
	# and silent.
	if with_materials:
		_pending_assets = MaterialSet.build(texture_tier)
	return ""


## Read edited chunks from the live voxel world, so a dug hole reaches the
## terrain surface. Only chunks that exist on disk are read from it: the
## layer's heights stay Arnis-derived even when the game is running.
func attach_world(w: Object) -> void:
	world = w
	source.set_live_world(w)


## Why the layer is not drawing, or "" when it is.
func refusal() -> String:
	return _refusal


func is_active() -> bool:
	return terrain != null and _refusal == "" and _ensure_data()


## A one-line status for the runtime log: what the layer is reading, what it
## has written, and how much of the world is currently resident. Reported from
## the live objects rather than from configuration, so it cannot describe a
## layer that failed to attach.
func describe() -> String:
	if terrain == null:
		return "inactive (%s)" % ("no Terrain3D" if _refusal == "" else _refusal)
	if not is_active():
		return "configured, waiting for the tree (dir=%s)" % source.dir()
	return ("dir=%s region=%d resident=%d chunks=%d columns=%d holes=%d "
		% [source.dir(), region_size(), _resident.size(), _covered_chunk_count(),
			int(stats["columns_written"]), int(stats["columns_hole"])]
		+ "materials=%d lods=%d vspacing=%.1f build=%.1fms/region"
			% [int(stats["materials"]), mesh_lods,
				float(terrain.call("get_vertex_spacing")),
				float(stats["region_build_ms_total"]) / maxf(
					float(int(stats["regions_built"])), 1.0)])


## How many whole chunks the currently built regions cover. Counted from the
## region records, which is the same data `covers_chunk` consults.
func _covered_chunk_count() -> int:
	var n := 0
	for loc in _resident:
		n += int((_resident[loc] as Dictionary).get("covered", {}).size())
	return n


## Does Terrain3D have its data object yet? True once the terrain node has
## entered the tree.
func _ensure_data() -> bool:
	if terrain == null:
		return false
	if terrain.call("get_data") == null:
		return false
	# The region size can only be changed once the data object exists, so a
	# caller that asked for a non-default size gets it the first time the
	# terrain is actually usable, however the layer was configured and parented.
	if _wanted_region_size > 0 and _wanted_region_size != _region_size:
		terrain.set("region_size", _wanted_region_size)
		_region_size = int(terrain.call("get_region_size"))
	if not _collision_applied:
		_collision_applied = true
		if not enable_collision:
			# Terrain3DCollision.DISABLED is 0. Read from the class when it is
			# registered so the name, not the number, is what this file records;
			# the literal is the fallback for a build where it is not exposed.
			var disabled := 0
			if ClassDB.class_has_integer_constant("Terrain3DCollision", "DISABLED"):
				disabled = ClassDB.class_get_integer_constant("Terrain3DCollision",
					"DISABLED")
			terrain.call("set_collision_mode", disabled)
	if _pending_assets != null:
		terrain.call("set_assets", _pending_assets)
		stats["materials"] = int(_pending_assets.call("get_texture_count"))
		_pending_assets = null
	return true


func data() -> Object:
	return null if terrain == null else terrain.call("get_data")


## The number of samples per region edge, as Terrain3D reports it.
func region_size() -> int:
	_ensure_data()
	return _region_size


func resident_regions() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for loc in _resident.keys():
		out.append(loc as Vector2i)
	return out


## Keep the terrain around `focus` up to date: build the nearest missing
## regions within the budget, drop the ones that fell behind, and re-apply any
## edited columns. Returns how many regions were built.
func update_around(focus: Vector3) -> int:
	if not is_active():
		return 0
	var built := 0
	_apply_pending_edits()
	var centre := _region_of(focus)
	_refresh_queue(centre)
	var n := 0
	while n < regions_per_update and not _queue.is_empty():
		var loc: Vector2i = _queue.pop_front()
		if _resident.has(loc) or not _within_radius(loc, centre):
			continue
		var t0 := Time.get_ticks_usec()
		_build_region(loc)
		stats["region_build_ms_total"] = float(stats["region_build_ms_total"]) \
			+ float(Time.get_ticks_usec() - t0) / 1000.0
		stats["regions_built"] = int(stats["regions_built"]) + 1
		built += 1
		n += 1
	built += _drop_distant(centre)
	if built > 0:
		_refresh_maps()
		coverage_changed.emit()
	return built


## Does Terrain3D have every column of this chunk? Only then may the voxel
## mesher hand the ground over; a chunk with even one hole keeps drawing its
## own surface, because the renderer with all the data must win.
func covers_chunk(pos: Vector3i) -> bool:
	if not is_active():
		return false
	var loc := _region_of(Vector3(float(pos.x * 16), 0.0, float(pos.z * 16)))
	var entry: Variant = _resident.get(loc, null)
	if entry == null:
		return false
	return (entry as Dictionary)["covered"].has(_chunk_key(pos))


## The area Terrain3D currently covers, in region locations.
func covered_region_rect() -> Rect2i:
	if _resident.is_empty():
		return Rect2i()
	var minx := 1 << 30
	var minz := 1 << 30
	var maxx := -(1 << 30)
	var maxz := -(1 << 30)
	for loc in _resident.keys():
		var l: Vector2i = loc
		minx = mini(minx, l.x)
		maxx = maxi(maxx, l.x)
		minz = mini(minz, l.y)
		maxz = maxi(maxz, l.y)
	return Rect2i(minx, minz, maxx - minx + 1, maxz - minz + 1)


## Record that a voxel changed, so the terrain surface above it is re-read.
## Called by `VoxelWorld` for every edit. Cheap: one dictionary insert, and
## the work happens in `update_around`, coalesced -- a villager that digs a
## hundred blocks in a frame costs one column, not a hundred map rebuilds.
func notify_block_changed(world_pos: Vector3i) -> void:
	if not is_active():
		return
	_pending_columns["%d:%d" % [world_pos.x, world_pos.z]] \
		= Vector2i(world_pos.x, world_pos.z)


## Forget everything: cached world reads, built regions, queued work. For a
## world switch and for tests.
func forget() -> void:
	var d := data()
	if d != null:
		for loc in _resident.keys():
			if not bool((_resident[loc] as Dictionary)["empty"]):
				d.call("remove_regionl", loc, false)
		d.call("update_maps", 3, true)
	_resident.clear()
	_queue.clear()
	_pending_columns.clear()
	source.forget_cache()


## Terrain3D's own height sample at a world position: NAN over a hole or
## outside every region. Thin wrapper so callers (and tests) do not have to
## know which object owns it.
func height_at(x: float, z: float) -> float:
	var d := data()
	if d == null:
		return NAN
	return float(d.call("get_height", Vector3(x, 0.0, z)))


## Terrain3D's own raymarch against the terrain it built, straight down onto a
## column. Returns the hit position, or a vector with a huge Y when nothing
## was hit. This goes through Terrain3D's sampling rather than through the
## values this layer wrote, which is what makes it evidence.
func probe_down(x: float, z: float) -> Vector3:
	if terrain == null:
		return Vector3(0, 1.0e39, 0)
	return terrain.call("get_intersection",
		Vector3(x, 4096.0, z), Vector3.DOWN) as Vector3


## A real mesh built by Terrain3D from its heightmap, at one of its LODs.
func bake(lod: int = 4) -> Mesh:
	if terrain == null:
		return null
	return terrain.call("bake_mesh", lod) as Mesh


# --- internals --------------------------------------------------------------

func _region_of(focus: Vector3) -> Vector2i:
	var span := float(_region_size) * float(terrain.call("get_vertex_spacing"))
	return Vector2i(int(floor(focus.x / span)), int(floor(focus.z / span)))


func _within_radius(loc: Vector2i, centre: Vector2i) -> bool:
	var span := float(_region_size) * float(terrain.call("get_vertex_spacing"))
	# Region centres, so the radius is compared centre to centre.
	var dx := (float(loc.x - centre.x) + 0.5) * span
	var dz := (float(loc.y - centre.y) + 0.5) * span
	var r := stream_radius + span * 0.5
	return dx * dx + dz * dz <= r * r


func _refresh_queue(centre: Vector2i) -> void:
	var span := float(_region_size) * float(terrain.call("get_vertex_spacing"))
	var reach := int(ceil((stream_radius + span) / span))
	var wanted: Array[Vector2i] = []
	for dz in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var loc := centre + Vector2i(dx, dz)
			if _resident.has(loc) or not _within_radius(loc, centre):
				continue
			wanted.append(loc)
	wanted.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (a - centre).length_squared() < (b - centre).length_squared())
	_queue = wanted


func _drop_distant(centre: Vector2i) -> int:
	var removed := 0
	var span := float(_region_size) * float(terrain.call("get_vertex_spacing"))
	var r := stream_radius + span * 1.5
	var r2 := r * r
	var d := data()
	for loc in _resident.keys().duplicate():
		var l: Vector2i = loc
		var dx := (float(l.x - centre.x) + 0.5) * span
		var dz := (float(l.y - centre.y) + 0.5) * span
		if dx * dx + dz * dz <= r2:
			continue
		if d != null and not bool((_resident[l] as Dictionary)["empty"]):
			d.call("remove_regionl", l, false)
		_resident.erase(l)
		stats["regions_removed"] = int(stats["regions_removed"]) + 1
		removed += 1
	return removed


func _refresh_maps() -> void:
	var d := data()
	if d == null:
		return
	d.call("update_maps", 3, true)
	d.call("calc_height_range")


## Build one region: authoritative heights, one texture id per column, and a
## hole where the world has nothing.
func _build_region(loc: Vector2i) -> void:
	var d := data()
	if d == null:
		return
	var ox := loc.x * _region_size
	var oz := loc.y * _region_size
	var filled: Dictionary = source.fill_columns(ox, oz, _region_size)
	var heights: PackedFloat32Array = filled["heights"]
	var present: PackedByteArray = filled["present"]
	var contents: PackedInt32Array = filled["contents"]

	# Absent columns are written as height 0 and marked as *holes*. NAN in the
	# height map would be honest and would also poison `calc_height_range()`
	# and the terrain AABB, and a hole is not rendered anyway -- the control
	# map is the mechanism Terrain3D provides for "there is no terrain here".
	var control := PackedByteArray()
	control.resize(_region_size * _region_size * 4)
	var holes := 0
	var written := 0
	for i in heights.size():
		var h := 0.0
		var value := 0
		if present[i] != 0:
			h = heights[i]
			written += 1
			var tid := MaterialSet.texture_id_for(contents[i])
			if tid >= 0:
				value |= (tid & 0x1F) << CONTROL_BASE_SHIFT
		else:
			holes += 1
			value |= 1 << CONTROL_HOLE_SHIFT
		heights[i] = h
		control.encode_u32(i * 4, value)
	stats["columns_written"] = int(stats["columns_written"]) + written
	stats["columns_hole"] = int(stats["columns_hole"]) + holes

	var height_img := Image.create_from_data(_region_size, _region_size, false,
		Image.FORMAT_RF, heights.to_byte_array())
	var control_img := Image.create_from_data(_region_size, _region_size, false,
		Image.FORMAT_RF, control)

	# A region with no authoritative terrain in it is not added to Terrain3D at
	# all. It would be 4096 holes, a wasted map allocation, and -- measured, not
	# assumed -- an inverted height range that Godot's HeightMapShape3D refuses
	# with "min_height > max_height". Terrain3D receives only the terrain data
	# the world actually has. The location is still recorded, so the queue does
	# not retry it every frame and `covers_chunk` correctly says no.
	if written == 0:
		_resident[loc] = {"covered": {}, "holes": holes, "written": 0,
			"empty": true}
		return

	var region: Object = d.call("add_region_blank", loc, false)
	if region == null:
		return
	region.call("set_map", MAP_HEIGHT, height_img)
	region.call("set_map", MAP_CONTROL, control_img)
	region.call("set_modified", false)

	# Which chunks of this region can hand their ground to Terrain3D: all 256
	# of their columns present.
	var covered := {}
	if holes == 0:
		_for_each_chunk_in_region(loc, func(chunk: Vector3i) -> void:
			covered[_chunk_key(chunk)] = true)
	else:
		_for_each_chunk_in_region(loc, func(chunk: Vector3i) -> void:
			if _chunk_fully_present(ox, oz, present, chunk):
				covered[_chunk_key(chunk)] = true)
	_resident[loc] = {"covered": covered, "holes": holes, "written": written,
		"empty": false}


## Walk the region's chunks (16 of them per side at the default sizes).
func _for_each_chunk_in_region(loc: Vector2i, cb: Callable) -> void:
	var chunks := _region_size / 16
	for cz in chunks:
		for cx in chunks:
			var wx := loc.x * _region_size + cx * 16
			var wz := loc.y * _region_size + cz * 16
			cb.call(Vector3i(wx / 16, 0, wz / 16))


func _chunk_fully_present(ox: int, oz: int, present: PackedByteArray,
		chunk: Vector3i) -> bool:
	var base_x := chunk.x * 16 - ox
	var base_z := chunk.z * 16 - oz
	if base_x < 0 or base_z < 0 or base_x + 15 >= _region_size \
			or base_z + 15 >= _region_size:
		return false
	for j in 16:
		for i in 16:
			if present[(base_z + j) * _region_size + base_x + i] == 0:
				return false
	return true


func _chunk_key(pos: Vector3i) -> String:
	return "%d:%d" % [pos.x, pos.z]


## Re-read the columns whose voxels changed and write them back into the
## height map. At most `regions_per_update` regions are rebuilt per call, so
## this is bounded too.
func _apply_pending_edits() -> void:
	if _pending_columns.is_empty():
		return
	var d := data()
	if d == null:
		_pending_columns.clear()
		return
	var touched := {}
	for key in _pending_columns.keys():
		var col: Vector2i = _pending_columns[key]
		source.invalidate_column(col.x, col.y)
		var loc := _region_of(Vector3(float(col.x), 0.0, float(col.y)))
		if not _resident.has(loc):
			continue
		var s := source.surface(col.x, col.y)
		var rloc: Vector2i = loc
		var lx := col.x - rloc.x * _region_size
		var lz := col.y - rloc.y * _region_size
		if lx < 0 or lz < 0 or lx >= _region_size or lz >= _region_size:
			continue
		var region: Object = d.call("get_region", rloc)
		if region == null:
			continue
		var himg: Image = region.call("get_map", MAP_HEIGHT)
		if himg != null:
			# A FORMAT_RF image takes its value from the colour's red channel.
			var h := float(s["y"]) if bool(s["present"]) else 0.0
			himg.set_pixel(lx, lz, Color(h, 0.0, 0.0, 1.0))
		d.call("set_control_hole", Vector3(float(col.x), 0.0, float(col.y)),
			not bool(s["present"]))
		region.call("set_edited", true)
		touched[rloc] = true
		if not bool(s["present"]):
			var entry: Dictionary = _resident[rloc]
			(entry["covered"] as Dictionary).erase(_chunk_key(
				Vector3i(_floor_div(col.x, 16), 0, _floor_div(col.y, 16))))
	_pending_columns.clear()
	if touched.is_empty():
		return
	d.call("update_maps", MAP_CONTROL + 1, false)
	for loc in touched.keys():
		var region: Object = d.call("get_region", loc)
		if region != null:
			region.call("set_edited", false)
	coverage_changed.emit()


static func _floor_div(a: int, b: int) -> int:
	var q := a / b
	if (a % b) != 0 and ((a < 0) != (b < 0)):
		q -= 1
	return q
