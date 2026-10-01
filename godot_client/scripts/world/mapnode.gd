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
## (stone=3, dirt=2, grass=1, water=4), so no numeric threshold can be used
## to detect them.
const CONTENT_AIR := 0
const CONTENT_IGNORE := 126
const CONTENT_IGNORE2 := 127

## Sunlight lives one above the normal light range (LIGHT_MAX+1).
const LIGHT_SUN := 15
const LIGHT_MAX := 14


## Linear index of a voxel inside a block. Luanti uses this ordering in
## serialized node arrays: `(z*16*16 + y*16 + x)`.
static func index(x: int, y: int, z: int) -> int:
	return z * MAP_BLOCKSIZE * MAP_BLOCKSIZE + y * MAP_BLOCKSIZE + x


## Inverse of `index()`: linear position -> Vector3i local voxel coords.
##
## Given `index = z*256 + y*16 + x`, the correct inverse reads x from the low
## bits, not the high ones. This previously did the reverse and returned
## Vector3i(z, y, x), which happened to agree with `index` only on the eight
## corners of the block -- x==z -- so a roundtrip test over all 4096 voxels
## caught what casual use could not.
static func unindex(idx: int) -> Vector3i:
	var x := idx % MAP_BLOCKSIZE
	var rest := idx / MAP_BLOCKSIZE
	var y := rest % MAP_BLOCKSIZE
	var z := rest / MAP_BLOCKSIZE
	return Vector3i(x, y, z)


## True when a content id should be treated as solid geometry.
##
## Delegates to ContentDB so there is exactly one definition of "solid".
## MapNode previously carried its own copy keyed on the ignore sentinels,
## and the two disagreed: ContentDB knows that water is translucent and
## leaves are cutouts, while a sentinel-only test cannot. Two definitions of
## opacity in a voxel renderer is not a latent risk, it is a live bug waiting
## for whichever call site happens to use the wrong one.
static func is_solid(content: int) -> bool:
	if content == CONTENT_IGNORE or content == CONTENT_IGNORE2:
		return false
	return ContentDB.is_solid(content)


## True when a content id fully occludes its neighbours' faces and blocks
## light. Opaque = solid, translucent, and not a cutout.
static func is_opaque(content: int) -> bool:
	return is_solid(content) and ContentDB.is_opaque(content)


## True when faces of this content belong in the transparent pass.
static func is_translucent(content: int) -> bool:
	return is_solid(content) and ContentDB.is_translucent(content)


## Should the face between `own_content` and `neighbour` be culled?
##
## An opaque neighbour always hides the face. Two translucent blocks of the
## same id hide each other's faces, so a body of water has no internal seams;
## translucent against anything else still draws, which is what lets you see
## the shoreline and the block under the water.
static func blocks_face(neighbour: int, own_content: int) -> bool:
	if is_opaque(neighbour):
		return true
	if neighbour == own_content and is_translucent(own_content):
		return true
	return false
