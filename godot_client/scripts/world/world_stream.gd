class_name WorldStream
extends RefCounted
## The GDScript face of the worldstream GDExtension.
##
## Everything here is optional by construction. The module is a native library
## that may not be built, may be built for a different API version, or may
## simply be missing on a fresh checkout, and none of those cases may take the
## game down: `available` says whether the native path exists, `reason` says
## why not, and every method degrades to an empty result.
##
## What this class is NOT: a second world. It does not create a terrain, does
## not own voxels, and does not enter the world registry -- it turns vector
## tiles into arrays a caller can draw. The voxel world remains the one world;
## this is a source of geometry that could be placed into it.
##
## Usage:
##   var ws := WorldStream.new()
##   if ws.available:
##       var cells := ws.cells_around(37.8715, -122.2730, 9, 2)
##       var parsed := ws.parse_tile(bytes, cells[0], 9, 1000.0)
##       var mesh_data := ws.build_meshlets(parsed["batch"])
##       var mesh := ws.mesh_from_meshlets(mesh_data)

## The native module's interface version this script is written against. A
## mismatch is refused rather than reinterpreted: the dictionaries the native
## side returns are positional contracts, and guessing at a shape is how a
## missing array turns into a silently flat city.
const EXPECTED_MODULE_VERSION := 1

## Resolutions the streamer's resident set is defined for, mirrored from
## ws::kMinStreamingResolution/kMaxStreamingResolution.
const MIN_RESOLUTION := 8
const MAX_RESOLUTION := 10

## True when the native module is present and speaks this script's version.
var available := false
## Human-readable reason `available` is false; empty when it is true.
var reason := ""

var _native: Object = null


func _init() -> void:
	if not ClassDB.class_exists("WorldStreamNative"):
		reason = ("worldstream is not built: run `sh ws_build/build.sh` "
				+ "(godot_client/ws_build/bin/libworldstream.*.so is missing)")
		return
	_native = ClassDB.instantiate("WorldStreamNative")
	if _native == null:
		reason = "WorldStreamNative is registered but could not be instantiated"
		return
	var version := int(_native.module_version())
	if version != EXPECTED_MODULE_VERSION:
		reason = ("worldstream module version %d does not match the %d this "
				% [version, EXPECTED_MODULE_VERSION]
				+ "script expects; rebuild or update the caller")
		_native = null
		return
	available = true


## One line describing the module, for the debug overlay and for tests.
func describe() -> String:
	if available:
		return "worldstream native, version %d" % EXPECTED_MODULE_VERSION
	return "worldstream unavailable (%s)" % reason


## The H3 cells resident around a position: the centre cell plus `radius`
## rings. Empty when the request is outside the streaming resolutions or the
## position does not project onto a cell.
func cells_around(lat: float, lon: float, resolution := MAX_RESOLUTION,
		radius := 2) -> PackedInt64Array:
	if not available:
		return PackedInt64Array()
	return _native.cells_around(lat, lon, resolution, radius)


## [lat, lon] of a cell, in degrees. Empty when `h3_index` is not a cell.
func cell_center(h3_index: int) -> PackedFloat64Array:
	if not available:
		return PackedFloat64Array()
	return _native.cell_center(h3_index)


## Parse one Mapbox vector tile into a batch. Returns the native dictionary:
## {ok, error, batch, stats}. `tile_size_m` is the tile's width in metres.
func parse_tile(bytes: PackedByteArray, h3_index: int, resolution: int,
		tile_size_m: float) -> Dictionary:
	if not available:
		return {"ok": false, "error": reason, "stats": {}}
	return _native.parse_tile(bytes, h3_index, resolution, tile_size_m)


## Mesh a parsed batch into GPU-ready arrays. Returns the native dictionary:
## {ok, error, positions, normals, materials, ao, indices, meshlet_vertices,
##  meshlet_triangles, meshlets, bounds_min, bounds_max, triangles}.
func build_meshlets(batch: Object, road_width_m := 3.0,
		road_lift_m := 0.05) -> Dictionary:
	if not available:
		return {"ok": false, "error": reason}
	return _native.build_meshlets(batch, road_width_m, road_lift_m)


## Turn the meshlet output into an ArrayMesh.
##
## This is the proof that the native output is not merely well-formed but
## usable: a mesh built here is directly renderable, and a test that builds one
## and checks its surface count is checking the contract the renderer needs,
## not just that an array came back.
##
## Meshlets are a GPU-side split; the vertex and index arrays are what a Mesh
## consumes, so the mesh is built from those and the meshlet arrays stay
## available for a caller that wants them.
func mesh_from_meshlets(mesh_data: Dictionary) -> ArrayMesh:
	if not bool(mesh_data.get("ok", false)):
		return null
	var positions: PackedVector3Array = mesh_data["positions"]
	var normals: PackedVector3Array = mesh_data["normals"]
	var indices: PackedInt32Array = mesh_data["indices"]
	if positions.is_empty() or indices.is_empty():
		return null

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
