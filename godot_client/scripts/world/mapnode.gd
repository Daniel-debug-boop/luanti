class_name MapNode
extends RefCounted
## Port of Luanti's `src/mapnode.h` — a single voxel.
##
## A MapNode packs three u8 values (param0/param1/param2) per voxel. Content
## ids >255 require a u16 param0, which is why serialization carries a
## `content_width` byte. See doc/world_format.md "Node Data".

## A block is 16x16x16 voxels.
const MAP_BLOCKSIZE := 16
## 16*16*16 voxels per block.
const BLOCK_VOLUME := 4096

## Node ids that carry no mesh. Mirrors CONTENT_AIR / CONTENT_IGNORE /
## CONTENT_IGNORE2 in Luanti's mapnode.h. These are the *only* ids that mean
## "no geometry": real registered content ids are small positive numbers
## (stone=3, dirt=2, grass=1, water=9), so no numeric threshold can be used
## to detect them.
const CONTENT_AIR := 0
const CONTENT_IGNORE := 126
const CONTENT_IGNORE2 := 127

## Sunlight lives one above the normal light range (LIGHT_MAX+1).
const LIGHT_SUN := 15
const LIGHT_MAX := 14

## Voxel behaviour is data-driven in Luanti (loaded from mods), so until a
## content database is wired up we treat every solid id as opaque. The
## threshold is set above any real content id, which means the transparent
## pass stays empty until a content database is loaded.
const TRANSLUCENT_THRESHOLD := 0x7FFF


## Linear index of a voxel inside a block. Luanti uses this ordering in
## serialized node arrays: `(z*16*16 + y*16 + x)`.
static func index(x: int, y: int, z: int) -> int:
	return z * MAP_BLOCKSIZE * MAP_BLOCKSIZE + y * MAP_BLOCKSIZE + x


## Inverse of `index()`: linear position -> Vector3i local voxel coords.
static func unindex(idx: int) -> Vector3i:
	var y := idx % MAP_BLOCKSIZE
	var rest := idx / MAP_BLOCKSIZE
	var z := rest % MAP_BLOCKSIZE
	var x := rest / MAP_BLOCKSIZE
	return Vector3i(x, y, z)


## True when a content id should be treated as solid geometry.
## Only air and the two "ignore" sentinels are empty; every other id is a
## registered content block and renders.
static func is_solid(content: int) -> bool:
	return content != CONTENT_AIR and content != CONTENT_IGNORE \
		and content != CONTENT_IGNORE2


## True when a content id occludes neighbouring faces / blocks light.
static func is_opaque(content: int) -> bool:
	return is_solid(content)


## True when faces of this content belong in the transparent pass.
static func is_translucent(content: int) -> bool:
	return is_solid(content) and content >= TRANSLUCENT_THRESHOLD


## Is the surface texture fully opaque (used to decide face culling)?
static func blocks_face(neighbour: int, own_content: int) -> bool:
	# An opaque neighbour always hides this face. A translucent neighbour only
	# hides the face of another translucent block, so glass against glass
	# still draws a seam and water against glass is culled.
	if is_opaque(neighbour):
		return true
	if is_translucent(neighbour) and is_translucent(own_content):
		return true
	return false
