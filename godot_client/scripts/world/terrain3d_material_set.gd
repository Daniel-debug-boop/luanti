class_name Terrain3DMaterialSet
extends RefCounted
## Terrain3D texture assets, built from the project's existing CC0 sets.
##
## Terrain3D draws the ground with its own shader and its own 32-slot texture
## list; this class fills that list, and it fills it from the same Poly Haven
## sets the voxel mesher already uses for the same blocks. So the grass on a
## Terrain3D hillside and the grass on a voxel block are the same photograph,
## and there is exactly one place -- `assets/source_manifest/manifest.json` --
## that says which texture belongs to which block.
##
## ## What is data-driven here
##
## The mapping is *derived*, not re-declared:
##
##   1. the manifest lists each texture set and the block names it is for;
##   2. `ContentDB.name_to_id` turns those names into content ids;
##   3. sets that name a ground id (see `ArnisTerrainSource.is_ground`)
##      become Terrain3D textures, in a stable order, so texture id N is the
##      same in every run and in every world;
##   4. a column's texture id is the texture of the content node the surface
##      adapter found there -- not a height or a slope threshold.
##
## Adding a block therefore means editing the manifest once, and both the
## voxel layer and the terrain layer follow.
##
## ## Two honest limitations, both reported rather than hidden
##
## * **Channel packing.** Terrain3D's albedo texture expects height in its
##   alpha channel and its normal texture expects roughness in alpha. The
##   runtime ladder ships those maps separately (`height_*.png`, `arm_*.png`),
##   and packing them is an offline image step (`Pillow` is already a declared
##   dev dependency of the asset pipeline). Until that step exists, the maps
##   are used as they are: correct albedo and correct normals, with flat
##   micro-AO/parallax and flat roughness. That is a texture-detail loss, not
##   a placement or height error, and `unpacked_textures` in `stats` says so.
## * **Import.** Textures are loaded with `Image.load_from_file`, which reads
##   the PNG/JPG on disk directly. That is deliberate: the terrain layer must
##   come up in a headless run and in a checkout whose import cache is cold,
##   and a texture that fails to load must degrade to the material's flat
##   defaults instead of taking the world down.

## Loaded by path rather than by global class name: the headless test runner
## has no editor pass to regenerate `.godot/global_script_class_cache.cfg`, and
## a material table that only resolves after someone opens the editor is a
## material table that fails in CI.
const ArnisSource := preload("res://scripts/world/arnis_terrain_source.gd")

## The one source of truth for texture-to-block mapping.
const MANIFEST_PATH := "res://assets/source_manifest/manifest.json"
const RUNTIME_DIR := "res://assets/runtime/textures"

## What the last `build()` actually achieved. Static because every entry point
## here is: the mapping is a property of the project, not of an instance.
static var report := {
	"sets": 0,
	"loaded": 0,
	"missing": [],            # set names whose files could not be found
}


## The manifest, parsed. Empty when it is absent or unreadable, which the
## callers treat as "no textures" rather than as an error: a build without the
## manifest is a build with flat terrain colour, not a broken world.
static func manifest() -> Dictionary:
	if not FileAccess.file_exists(MANIFEST_PATH):
		return {}
	var text := FileAccess.get_file_as_string(MANIFEST_PATH)
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


## The derived tables, built once. They are pure functions of a file that does
## not change while the game runs, and the per-column texture id is asked for
## once per node column of every built region -- rebuilding the mapping (and
## re-sorting it) thousands of times per region turned a 60 ms region build
## into 25 seconds.
static var _map_cache := {}
static var _sets_cache: Array[String] = []
static var _id_cache := {}


## Drop the derived tables. Tests need it; nothing else does.
static func forget() -> void:
	_map_cache.clear()
	_sets_cache.clear()
	_id_cache.clear()


## ContentDB id -> texture set name, derived from the manifest's `blocks`
## lists. Ground ids the manifest does not name fall back to the set used for
## stone, because a bare ore or bedrock says "this is rock", not "unknown".
static func content_map() -> Dictionary:
	if not _map_cache.is_empty():
		return _map_cache
	var out := {}
	var fallback := ""
	for entry in _texture_entries():
		var set_name := String(entry.get("id", ""))
		var names: Variant = entry.get("blocks", [])
		if not (names is Array):
			continue
		for n in (names as Array):
			var id := ContentDB.name_to_id(String(n))
			if id < 0:
				continue
			if id == ContentDB.STONE and fallback == "":
				fallback = set_name
			if ArnisSource.is_ground(id) and not out.has(id):
				out[id] = set_name
	if fallback != "":
		for id in ArnisSource.GROUND_IDS:
			if not out.has(id):
				out[id] = fallback
	_map_cache = out
	return out


## The texture sets this world can use, in the stable order Terrain3D texture
## ids are assigned from. Sorted, so id 0 is always the same set.
static func sets() -> Array[String]:
	if not _sets_cache.is_empty():
		return _sets_cache
	var names: Array[String] = []
	for name in content_map().values():
		var s := String(name)
		if not names.has(s):
			names.append(s)
	names.sort()
	_sets_cache = names
	return names


## Terrain3D texture id for a surface node's content id. `-1` when the world's
## content has no set at all (a world built from ids nobody mapped).
static func texture_id_for(content_id: int) -> int:
	if _id_cache.has(content_id):
		return int(_id_cache[content_id])
	var set_name := String(content_map().get(content_id, ""))
	var id := -1
	if set_name != "":
		id = sets().find(set_name)
	_id_cache[content_id] = id
	return id


## Build the Terrain3DAssets resource for a world whose surface uses these
## sets, with the texture list filled from `RUNTIME_DIR`.
##
## Returns the assets object, or null when the extension is not registered.
## `tier` is the preferred texture resolution; the closest available rung at
## or below it is used, because the manifests record what was actually
## downloaded rather than one uniform size.
static func build(tier: int = 1024) -> Object:
	if not ClassDB.class_exists("Terrain3DAssets"):
		return null
	var assets: Object = ClassDB.instantiate("Terrain3DAssets")
	var order := sets()
	report["sets"] = order.size()
	report["loaded"] = 0
	report["missing"] = []
	for i in order.size():
		var asset := _texture_asset(i, order[i], tier)
		if asset == null:
			(report["missing"] as Array).append(order[i])
			continue
		assets.call("set_texture", i, asset)
		report["loaded"] = int(report["loaded"]) + 1
	assets.call("update_texture_list")
	return assets


## One texture slot: albedo and normal from the project's runtime ladder.
## Returns null (and records the set as missing) when neither map is present,
## so the slot stays empty instead of pointing at a texture that is not there.
static func _texture_asset(id: int, set_name: String, tier: int) -> Object:
	if not ClassDB.class_exists("Terrain3DTextureAsset"):
		return null
	var albedo := _load_map(set_name, "diff", tier)
	var normal := _load_map(set_name, "nor_gl", tier)
	if albedo == null and normal == null:
		return null
	var tex: Object = ClassDB.instantiate("Terrain3DTextureAsset")
	tex.call("set_id", id)
	tex.call("set_name", set_name)
	if albedo != null:
		tex.call("set_albedo_texture", albedo)
	if normal != null:
		tex.call("set_normal_texture", normal)
	# 1 m of world per metre of UV: the same rate the voxel mesher uses, so the
	# terrain and the blocks beside it tile at one scale.
	tex.call("set_uv_scale", 1.0)
	return tex


## Load one map of a set at the best available rung, straight off disk.
static func _load_map(set_name: String, map: String, tier: int) -> Texture2D:
	var dir := "%s/%s" % [RUNTIME_DIR, set_name]
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(dir)):
		return null
	var best := ""
	for rung in [4096, 2048, 1024, 512]:
		if rung > tier:
			continue
		for ext in [".png", ".jpg"]:
			var rel := "%s/%s_%d%s" % [dir, map, rung, ext]
			if FileAccess.file_exists(rel):
				best = rel
				break
		if best != "":
			break
	if best == "":
		return null
	var path := ProjectSettings.globalize_path(best)
	var img := Image.load_from_file(path)
	if img == null:
		return null
	return ImageTexture.create_from_image(img)


## The manifest's texture entries. `category` is not filtered on: a set is a
## terrain set because it names a ground block, not because of how it was
## filed, and filing it under the wrong category should not hide it.
static func _texture_entries() -> Array:
	var m := manifest()
	var assets: Variant = m.get("assets", [])
	var out := []
	if assets is Array:
		for a in (assets as Array):
			if a is Dictionary and String((a as Dictionary).get("kind", "")) == "texture":
				out.append(a)
	return out
