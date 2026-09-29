class_name VoxelBlock
extends RefCounted
## A deserialized Luanti MapBlock: three parallel per-voxel arrays.
##
## The block owns its own lighting, matching Luanti's per-block light model,
## so meshing never has to look outside the block for a face-cull decision.

var content_id: Vector3i = Vector3i.ZERO
## Block coordinate in the world (mapblock units, not voxels).
var origin: Vector3i = Vector3i.ZERO

## u16[4096] content ids. Stored wide regardless of the on-disk content_width,
## so the deserializer is the only place that has to care.
var content := PackedInt32Array()
## u8[4096] light: low nibble = day, high nibble = night.
var light := PackedByteArray()
## u8[4096] metadata / node-specific parameter.
var param2 := PackedByteArray()

## Block flags from the serialized header (see world_format.md).
var is_generated := true
var is_underground := false
var day_night_differs := false

## Set when the block is absent from the database (never written / not yet
## generated). Mesher treats unloaded neighbours as transparent.
var is_loaded := false


func _init() -> void:
	content.resize(MapNode.BLOCK_VOLUME)
	light.resize(MapNode.BLOCK_VOLUME)
	param2.resize(MapNode.BLOCK_VOLUME)


## Set every light byte to `v` (used by tests and by full-sun generation).
func fill(v: int) -> void:
	light.fill(v)


## Daylight value 0..15 for a local voxel index.
func get_day_light(idx: int) -> int:
	return light[idx] & 0x0F


## Nighttime light value 0..15 for a local voxel index.
func get_night_light(idx: int) -> int:
	return (light[idx] >> 4) & 0x0F


func get_content_idx(idx: int) -> int:
	return content[idx]


func get_content(x: int, y: int, z: int) -> int:
	return content[MapNode.index(x, y, z)]


func get_light(x: int, y: int, z: int) -> int:
	return light[MapNode.index(x, y, z)]


## True if this block and its 6 neighbours can be meshed without a seam.
## Unloaded blocks are never meshed (they'd tear against the sky), so a
## neighbour is required to have been read successfully.
func is_complete() -> bool:
	return is_loaded and is_generated
