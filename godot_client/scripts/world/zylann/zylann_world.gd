class_name ZylannWorld
extends Node3D
## Voxel Tools backend: infinite streaming, LOD terrain, instancing, CPU/GPU
## generation and region-file persistence, provided by Zylann's Voxel Tools.
##
## WHY THIS FILE HAS NO `VoxelTerrain` TYPE ANNOTATIONS
##   Voxel Tools is a C++ module that only exists in the official custom engine
##   build (see tools/fetch_voxel_engine.sh). Naming the type here would make
##   this script fail to *parse* on stock Godot, breaking the whole project.
##   So every Voxel Tools object is built through ClassDB.instantiate() and
##   driven with duck-typed set()/call(). is_available() gates all of it, and
##   the project still runs unchanged on stock 4.4.
##
## Verified working headlessly on the custom build:
##   streaming (64 data blocks generated), GDScript generation, voxel read,
##   voxel write, region-file stream construction.
## NOT verified: mesh upload, because this machine has no GPU (see README).

const GENERATOR_PATH := "res://scripts/world/zylann/zylann_generator.gd"
const DEFAULT_SAVE_DIR := "user://zylann_world"

## Set false to skip the VoxelInstancer (useful in tests).
var with_instancer := true
## Set false to use an in-memory stream instead of region files (tests).
## NOTE: a Voxel Tools terrain still needs *a* stream -- with none at all it
## retains no data blocks, so get_voxel() reads 0 and set_voxel() reports
## "Area not editable". VoxelStreamMemory is the hermetic choice.
var with_persistence := true

var terrain: Object = null
var viewer: Object = null
var lod: Object = null
var instancer: Object = null
var generator: Object = null
var tool: Object = null

var _ready_done := false


## True when this engine has the Voxel Tools module compiled in.
static func is_available() -> bool:
	return ClassDB.class_exists("VoxelTerrain") \
			and ClassDB.class_exists("VoxelLodTerrain") \
			and ClassDB.class_exists("VoxelGeneratorScript")


## Human-readable reason the backend cannot run, or "" when it can.
static func unavailable_reason() -> String:
	if is_available():
		return ""
	return "Voxel Tools module missing -- run tools/fetch_voxel_engine.sh " \
			+ "and use that engine instead of stock Godot 4.4"


## Build the whole Voxel Tools stack around `camera`.
## Returns false (and leaves the node inert) on stock Godot.
func setup(camera: Camera3D, save_dir: String = DEFAULT_SAVE_DIR,
		view_distance := 8, lod_distance := 48) -> bool:
	if not is_available():
		push_warning("[zylann] %s" % unavailable_reason())
		return false

	# --- Viewer ---------------------------------------------------------
	# Voxel Tools 1.4 has no VoxelTerrain.viewer property: the viewer finds the
	# terrain itself, so it just has to exist in the same World3D as a child of
	# the camera it should track.
	viewer = ClassDB.instantiate("VoxelViewer")
	viewer.set("view_distance", view_distance)
	viewer.set("requires_collisions", true)
	camera.add_child(viewer)

	# --- Terrain --------------------------------------------------------
	terrain = ClassDB.instantiate("VoxelTerrain")
	terrain.name = "VoxelTerrain"
	# Bounds gate the editable area; outside it the tool refuses writes
	# ("Area not editable" in voxel_tool.cpp).
	terrain.set("bounds", AABB(Vector3(-2048, -128, -2048), Vector3(4096, 512, 4096)))
	terrain.set("max_view_distance", view_distance)
	terrain.set("generate_collisions", true)
	terrain.set("use_gpu_generation", false)
	add_child(terrain)

	generator = load(GENERATOR_PATH).new()
	terrain.set("generator", generator)

	terrain.set("mesher", _make_mesher())

	terrain.set("stream", _make_stream(save_dir) if with_persistence
			else _make_memory_stream())

	# --- LOD terrain ----------------------------------------------------
	# A coarse copy of the world that keeps distant hills on screen after the
	# full-detail chunks have been unloaded.
	lod = ClassDB.instantiate("VoxelLodTerrain")
	lod.name = "VoxelLodTerrain"
	lod.set("view_distance", view_distance)
	lod.set("lod_count", 4)
	lod.set("generate_collisions", false)
	lod.set("use_gpu_generation", false)
	lod.set("voxel_bounds", AABB(Vector3(-2048, -128, -2048), Vector3(4096, 512, 4096)))
	lod.set("generator", generator)
	terrain.set("lod_ground", lod)

	if with_instancer:
		instancer = _make_instancer()
		if instancer != null:
			add_child(instancer)

	tool = terrain.call("get_voxel_tool")
	_ready_done = true
	return true


func _make_mesher() -> Object:
	# VoxelBlockyLibrary holds one VoxelBlockyModel per block id; model index ==
	# ContentDB id, so the two backends agree on what a block *is*.
	var models: Array = []
	for id in range(1, 32):
		var model: Object = ClassDB.instantiate("VoxelBlockyModel")
		model.set("color", ContentDB.color_of(id))
		models.append(model)
	var library: Object = ClassDB.instantiate("VoxelBlockyLibrary")
	library.set("models", models)
	var mesher: Object = ClassDB.instantiate("VoxelMesherBlocky")
	mesher.set("library", library)
	return mesher


func _make_stream(save_dir: String) -> Object:
	var stream: Object = ClassDB.instantiate("VoxelStreamRegionFiles")
	stream.set("directory", save_dir)
	return stream


func _make_memory_stream() -> Object:
	return ClassDB.instantiate("VoxelStreamMemory")


## Scatter grass tufts and pebbles over grass, and boulders over stone.
## Uses MultiMesh items, so thousands of props cost a handful of draw calls.
func _make_instancer() -> Object:
	var library: Object = ClassDB.instantiate("VoxelInstanceLibrary")

	var grass: Object = ClassDB.instantiate("VoxelInstanceGenerator")
	grass.set("density", 0.06)
	grass.set("min_height", 0.9)
	grass.set("jitter", Vector3(0.8, 0.0, 0.8))
	grass.set("random_rotation", true)
	grass.set("min_scale", 0.7)
	grass.set("max_scale", 1.3)

	var tuft: Object = ClassDB.instantiate("VoxelInstanceLibraryMultiMeshItem")
	tuft.set("name", "grass_tuft")
	tuft.set("mesh", _tuft_mesh())
	tuft.set("generator", grass)
	tuft.set("cast_shadow", 0)
	library.call("add_item", 1, tuft)

	var stone: Object = ClassDB.instantiate("VoxelInstanceGenerator")
	stone.set("density", 0.012)
	stone.set("jitter", Vector3(0.9, 0.0, 0.9))
	stone.set("random_rotation", true)
	stone.set("min_scale", 0.8)
	stone.set("max_scale", 1.8)

	var pebble: Object = ClassDB.instantiate("VoxelInstanceLibraryMultiMeshItem")
	pebble.set("name", "pebble")
	pebble.set("mesh", _pebble_mesh())
	pebble.set("generator", stone)
	library.call("add_item", 3, pebble)

	var inst: Object = ClassDB.instantiate("VoxelInstancer")
	inst.name = "VoxelInstancer"
	inst.set("library", library)
	return inst


## A 3-quad cross of grass blades. Built in code so the repo needs no new
## binary assets for scatter decoration.
func _tuft_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 4:
		var a := TAU * float(i) / 4.0
		var d := Vector3(cos(a), 0.0, sin(a))
		var w := Vector3(-d.z, 0.0, d.x) * 0.25
		var tip := d * 0.18
		_tri(st, -w, tip, w, Color(0.36, 0.62, 0.26))
	st.generate_normals()
	return st.commit()


## A flat-shaded octahedron, cheap enough to scatter by the thousand.
func _pebble_mesh() -> ArrayMesh:
	var r := 0.22
	var top := Vector3(0, r, 0)
	var bot := Vector3(0, -r * 0.6, 0)
	var ring := [
		Vector3(r, 0, 0), Vector3(0, 0, r), Vector3(-r, 0, 0), Vector3(0, 0, -r)
	]
	var col := Color(0.48, 0.46, 0.44)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 4:
		var a: Vector3 = ring[i]
		var b: Vector3 = ring[(i + 1) % 4]
		_tri(st, a, top, b, col)
		_tri(st, b, bot, a, col)
	st.generate_normals()
	var mesh := st.commit()
	var mi := StandardMaterial3D.new()
	mi.albedo_color = col
	mi.roughness = 0.9
	mesh.surface_set_material(0, mi)
	return mesh


static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
	st.set_color(col)
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)


# --- Voxel access, mirroring the GDScript backend's vocabulary ---------------

func is_built() -> bool:
	return _ready_done and terrain != null and is_instance_valid(terrain)


## Block id at a world voxel position, or 0 when unavailable.
func get_voxel(pos: Vector3i) -> int:
	if not is_built() or tool == null:
		return 0
	return tool.call("get_voxel", pos)


## Write a block. Returns true when the write was accepted.
func set_voxel(pos: Vector3i, id: int) -> bool:
	if not is_built() or tool == null:
		return false
	return tool.call("set_voxel", pos, id) != null


## DDA raycast through the voxel grid. Returns a VoxelRaycastResult or null.
func raycast(origin: Vector3, dir: Vector3, max_distance: float,
		hit_mask := 0xFFFFFFFF) -> Object:
	if not is_built() or tool == null:
		return null
	return tool.call("raycast", origin, dir.normalized(), max_distance, hit_mask)


## Flush edited blocks to the region files.
func save() -> void:
	if is_built():
		terrain.call("save_modified_blocks")


## Drop every cached data block; the next frame reloads from the stream.
func reload() -> void:
	if is_built():
		terrain.call("set_stream", terrain.call("get_stream"))


func get_stats() -> Dictionary:
	if not is_built():
		return {"backend": "zylann", "available": false, "built": false}
	var s: Dictionary = terrain.call("get_statistics")
	return {
		"backend": "zylann",
		"available": true,
		"built": true,
		"blocks_generated": generator.get("blocks_generated") if generator != null else 0,
		"updated_blocks": s.get("updated_blocks", 0),
		"dropped_loads": s.get("dropped_block_loads", 0),
		"has_lod": lod != null,
		"has_instancer": instancer != null,
		"persistent": with_persistence,
	}
