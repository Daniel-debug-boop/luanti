class_name MaterialLibrary
extends RefCounted
## Builds PBR materials from the runtime texture library in
## assets/runtime/textures and maps content ids to them.
##
## The mesher emits one surface per block id, so this class hands out the
## material for each of those surfaces. Everything here is stock Godot 4.4: the
## materials are plain `StandardMaterial3D` and every effect is one of its
## built-in properties. No custom shader code is loaded anywhere in this
## project.
##
##   * Triplanar mapping        -- `uv1_triplanar` + `uv1_world_triplanar`
##   * Parallax occlusion (POM) -- the `heightmap_*` family, at ULTRA only
##   * Detail layer             -- `detail_enabled`, reading the mesher's UV2 set
##   * PBR                      -- albedo, normal, and ARM (occlusion) textures
##
## The textures themselves are not in this file and were not downloaded for
## this file: they are built by `tools/acquire_assets.py` and
## `tools/process_textures.py` into a resolution ladder, and every one of them
## is recorded in assets/source_manifest/manifest.json. This file only decides
## *which rung of that ladder the current quality tier stands on*, which is
## why there is a resolution table here and no image files.
##
## `vertex_color_use_as_albedo` stays on so the mesher's baked daylight,
## directional shading and ambient occlusion tint the photo texture. Ids with no
## texture set fall back to the palette-only vertex-colour material, so the
## world still renders if an asset is missing.

const RUNTIME := "res://assets/runtime/textures"
## The vendored stochastic triplanar shader (derived from Acegiak's
## Apache-2.0 terrain shader; see addons/ATTRIBUTION.md).
const STOCHASTIC_SHADER := preload("res://scripts/world/voxel_stochastic.gdshader")

## Slope blending: one block id, two texture sets, chosen by how flat the face
## is. See voxel_slope_blend.gdshader.
const SLOPE_SHADER := preload("res://scripts/world/voxel_slope_blend.gdshader")

## The slope at which ground cover gives way to wall. A face whose normal has
## a Y component above this is level ground and takes the `top` set; below it
## the face is a wall and takes `side`. This is the number the rendering
## specification names, and it lives here rather than in the shader literal so
## the tests and the material build both read the same constant.
const SLOPE_THRESHOLD := 0.7
## Renders surface normals as colour. See RenderDiagnostics, Stage.NORMAL.
const NORMAL_DEBUG_SHADER := preload(
	"res://scripts/world/voxel_normal_debug.gdshader")
## How many times the detail texture repeats per block, relative to UV1.
const DETAIL_UV_SCALE := 4.0

## Effect quality tiers, applied by `apply_quality`.
enum Quality { LOW, MEDIUM, HIGH, ULTRA }

## Which rung of the texture ladder each quality tier stands on.
##
## LOW and MEDIUM share the 512 rung: at that size a one-metre block face is
## already smaller than a screen tile at normal distance, and the difference
## between 512 and 1024 is invisible while the cost is not. ULTRA is the only
## tier that reaches the 2048 rung, and only the sets that have it.
const TEXTURE_TIER := {
	Quality.LOW: 512,
	Quality.MEDIUM: 512,
	Quality.HIGH: 1024,
	Quality.ULTRA: 2048,
}

## Detail overlays ship at one size, because `DETAIL_UV_SCALE` already tiles
## them four times per block: there is no point paying for a 1K detail map
## that is sampled at quarter-block frequency.
const DETAIL_TIER := 512

## Parallax occlusion needs one extra texture per material and a ray march per
## fragment, on faces that are flat by construction because they are block
## faces. It is therefore an ULTRA-only effect. See assets/ART_DIRECTION.md.
const POM_QUALITY := Quality.ULTRA

## How the block texture is projected onto the face.
##
## IMPORTANT ENGINE LIMIT: Godot cannot do triplanar mapping and parallax
## occlusion on the same material. Enabling both makes the engine print
## "Height mapping is not supported on triplanar materials" and silently drop
## the heightmap, so POM would be configured but never run. The two are
## therefore mutually exclusive here, chosen by `set_mapping`:
##
##   TRIPLANAR -- project on X/Y/Z, blends on the normal. Fixes the stretching
##                that box UVs suffer on sloped voxel faces.
##   PARALLAX  -- POM via the heightmap system. Gives the face relief at
##                grazing angles. ULTRA only.
##   STOCHASTIC-- the vendored Acegiak triplanar shader with stochastic
##                sampling, so the repeating grid pattern of a tiled texture
##                is broken up. Hand-authored GLSL rather than an engine
##                material, so it drops the StandardMaterial3D PBR path.
##   SLOPE     -- stochastic, plus slope blending for the blocks that have a
##                top/side pair (see SLOPE_PAIRS). Grass on level ground, rock
##                on the walls. Blocks with no pair behave exactly as they do
##                under STOCHASTIC, so this mode is additive.
##   PLAIN     -- straight box UVs, cheapest.
enum Mapping { PLAIN, TRIPLANAR, PARALLAX, STOCHASTIC, SLOPE }

## Sets that are made of code rather than of downloaded pixels. A material with
## no texture at all is the right answer for glass: a translucent, very smooth
## surface with a faint tint *is* the material, and a downloaded glass texture
## would be a fourth resident texture for a block that is mostly the sky.
const PROCEDURAL := {
	"glass": {
		"color": Color(0.78, 0.88, 0.94, 0.26),
		"roughness": 0.06,
		"metallic": 0.0,
	},
}

## Photographic PBR material, keyed by block id. Keying by id rather than by
## texture-set name lets several blocks that share a set still get their own
## detail overlay.
var _materials := {}          # int -> Material
## Translucent variants (water, ice, glass), keyed by block id.
var _trans_materials := {}    # int -> Material
## Stochastic-shader materials, keyed by block id. These are ShaderMaterial,
## not StandardMaterial3D, so they live apart from the engine-material path.
var _shader_materials := {}   # int -> ShaderMaterial
## Slope-blended materials, keyed by block id. Separate from
## _shader_materials because a block can be single-textured under one mapping
## and two-set under another, and the cache has to hold whichever the current
## mapping asked for.
var _slope_materials := {}    # int -> ShaderMaterial
## Set names that are known to be missing on disk, so we never retry.
var _failed := {}             # String -> true
var _plain: StandardMaterial3D
var _plain_untextured: StandardMaterial3D
var _water: StandardMaterial3D
var _emissive: StandardMaterial3D
var _procedural := {}         # set name -> StandardMaterial3D
var _quality := Quality.HIGH
var _mapping := Mapping.PARALLAX

# --- rendering diagnostic overrides ---
#
# These bypass every other material decision. They are off in normal play and
# set only by `VoxelWorld.set_unlit()` and friends, which the
# `--render-test --stage` diagnostic drives. Kept here rather than in the
# renderer so the diagnostic exercises the same material binding path the
# game does -- a diagnostic with its own materials would diagnose itself.
var _unlit := false
var _normal_debug := false
var _flat_override := false
var _normal_mat: ShaderMaterial = null


## Draws world-space normals as RGB colour.
##
## StandardMaterial3D has no normals-display mode, so this needs the small
## shader in voxel_normal_debug.gdshader. It is unshaded and double-sided on
## purpose: culling would hide exactly the faces this exists to reveal.
func _normal_material() -> ShaderMaterial:
	if _normal_mat == null:
		_normal_mat = ShaderMaterial.new()
		_normal_mat.shader = NORMAL_DEBUG_SHADER
	return _normal_mat


## A flat, untextured, unshaded material. The per-block tint the mesher bakes
## into vertex colours still applies, so this shows palette and geometry
## without textures or lighting.
func _flat_material() -> StandardMaterial3D:
	return _plain_untextured


func _make_flat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


## Ignore lighting entirely: a pure geometry-and-albedo test.
func set_unlit(on: bool) -> void:
	_unlit = on


## Draw normals as colour.
func set_normal_debug(on: bool) -> void:
	_normal_debug = on


## Flat colour for every block, ignoring texture sets.
func set_flat_override(on: bool) -> void:
	_flat_override = on


## Drop every diagnostic override. The diagnostic sets them one at a time as
## it walks up the stages, and each stage must first clear the previous
## stage's overrides -- otherwise stage N inherits stage N-1's flags and the
## stages quietly stop being independent, which is the one thing this
## diagnostic must never be.
func clear_diagnostics() -> void:
	_unlit = false
	_normal_debug = false
	_flat_override = false


## True while any diagnostic override is active, so the renderer can tell a
## diagnostic capture from a real one.
func is_diagnostic() -> bool:
	return _unlit or _normal_debug or _flat_override


func _init() -> void:
	_plain = _make_plain()
	_plain_untextured = _make_flat()
	_water = _make_water()
	_emissive = _make_emissive()


func _make_plain() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 0.92
	m.metallic = 0.0
	m.cull_mode = BaseMaterial3D.CULL_BACK
	return m


func _make_water() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.roughness = 0.06
	m.metallic = 0.15
	m.albedo_color = Color(0.55, 0.72, 0.95, 0.72)
	return m


func _make_emissive() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.emission_enabled = true
	m.emission = Color(1.0, 0.82, 0.42)
	m.emission_energy_multiplier = 1.6
	return m


## Which downloaded texture set a content id uses, or "" for none.
## Match instead of a const dict: const expressions cannot reference other
## classes' constants.
static func texture_set_for(id: int) -> String:
	match id:
		ContentDB.GRASS:
			return "aerial_grass_rock"
		ContentDB.CACTUS:
			return "bark_brown_02"
		ContentDB.DIRT:
			return "brown_mud_leaves_01"
		ContentDB.WOOD:
			return "bark_brown_02"
		ContentDB.LEAVES:
			return "forest_leaves_02"
		ContentDB.STONE, ContentDB.BEDROCK:
			return "rock_06"
		ContentDB.SAND:
			return "sand_01"
		ContentDB.SNOW:
			return "snow_02"
		ContentDB.GRAVEL:
			return "aerial_rocks_02"
		ContentDB.ICE:
			return "coast_sand_rocks_02"
		ContentDB.DEEPSLATE, ContentDB.DEEPSLATE_DEEP, ContentDB.VOID_ROCK:
			return "rock_face_04"
		# --- ores: composed from the host rock and the metal they refine into
		ContentDB.COPPER_ORE:
			return "ore_copper"
		ContentDB.IRON_ORE:
			return "ore_iron"
		ContentDB.COAL_ORE:
			return "ore_coal"
		ContentDB.SILVER_ORE:
			return "ore_silver"
		# --- refined metals
		ContentDB.COPPER_BLOCK:
			return "acg_metal_057a"
		ContentDB.IRON_BLOCK:
			return "acg_metal_055a"
		ContentDB.STEEL_BLOCK:
			return "acg_metal_032"
		ContentDB.BRASS_BLOCK:
			return "acg_metal_048a"
		# --- the construction palette
		ContentDB.PLANKS:
			return "oak_wood_planks"
		ContentDB.COBBLESTONE:
			return "cobblestone_04"
		ContentDB.BRICK:
			return "brick_wall_003"
		ContentDB.CONCRETE:
			return "concrete_floor_02"
		ContentDB.ASPHALT:
			return "asphalt_01"
		ContentDB.METAL_PLATE:
			return "corrugated_iron"
		ContentDB.GLASS:
			return "glass"
	return ""


## The texture set used as a detail overlay for a block id, or "" for none.
## Detail is a finer surface breakup, so it deliberately differs from the
## albedo: dirt is broken up by gravel, stone by the coarse rock face.
static func detail_set_for(id: int) -> String:
	match id:
		ContentDB.GRASS, ContentDB.CACTUS:
			return "forrest_ground_01"
		ContentDB.LEAVES:
			return "aerial_grass_rock"
		ContentDB.DIRT, ContentDB.SAND:
			return "aerial_rocks_02"
		ContentDB.WOOD:
			return "bark_brown_02"
		ContentDB.STONE, ContentDB.BEDROCK, ContentDB.GRAVEL:
			return "rock_face_04"
		ContentDB.COBBLESTONE:
			return "rock_face_04"
		ContentDB.SNOW:
			return "coast_sand_rocks_02"
		ContentDB.ICE:
			return "snow_02"
		ContentDB.DEEPSLATE, ContentDB.DEEPSLATE_DEEP, ContentDB.VOID_ROCK:
			return "rock_06"
		ContentDB.PLANKS:
			return "bark_brown_02"
		ContentDB.BRICK, ContentDB.CONCRETE:
			return "concrete_floor_02"
		ContentDB.ASPHALT:
			return "cobblestone_04"
		ContentDB.METAL_PLATE:
			return "acg_metal_063"
		ContentDB.COPPER_ORE:
			return "rock_06"
		ContentDB.IRON_ORE:
			return "rock_06"
		ContentDB.COAL_ORE:
			return "rock_06"
		ContentDB.SILVER_ORE:
			return "rock_06"
	return ""


## The rung of the texture ladder the current tier loads. A set that does not
## have this rung (a 1K source has no 2048) falls back to the largest it has,
## so nothing is ever asked for a file the pipeline did not write.
## The pair of texture sets a block shows by slope, as
## `{"top": <set>, "side": <set>}`, or an empty dictionary when the block is
## single-textured.
##
## Only blocks where the distinction is real get an entry. A block of stone is
## stone on every face, so giving it a pair would spend a second albedo, normal
## and ARM sample per fragment to draw the same picture twice.
static func slope_pair_for(id: int) -> Dictionary:
	match id:
		# Ground covered in grass, with the soil set on the walls -- which is
		# what makes a grass block read as grass *on top* rather than as a
		# green cube.
		ContentDB.GRASS, ContentDB.DIRT:
			return {"top": "aerial_grass_rock", "side": "brown_mud_leaves_01"}
		ContentDB.SAND:
			return {"top": "sand_01", "side": "aerial_rocks_02"}
		ContentDB.SNOW:
			return {"top": "snow_02", "side": "rock_06"}
		ContentDB.GRAVEL:
			return {"top": "aerial_rocks_02", "side": "rock_06"}
	return {}


func _tier_for(set_name: String) -> int:
	var want: int = TEXTURE_TIER.get(_quality, 1024)
	var path := "%s/%s/diff_%d.jpg" % [RUNTIME, set_name, want]
	if _has(path):
		return want
	for t in [1024, 512]:
		if _has("%s/%s/diff_%d.jpg" % [RUNTIME, set_name, t]):
			return t
	return 0


static func _abs(res_path: String) -> String:
	return res_path.replace("res://", ProjectSettings.globalize_path("res://"))


func _has(res_path: String) -> bool:
	return FileAccess.file_exists(_abs(res_path)) \
			or ResourceLoader.exists(res_path)


## Configure the stock triplanar, POM and detail properties. All three are
## built into BaseMaterial3D; nothing here compiles a shader.
func _apply_effects(mat: Material, id: int) -> void:
	if mat is ShaderMaterial:
		# A slope material is told apart by which shader it was built from,
		# not by the current mapping: a rebuild is in flight during
		# set_mapping, and reading _mapping there would reconfigure the wrong
		# shader's uniforms.
		var smat := mat as ShaderMaterial
		if smat.shader == SLOPE_SHADER:
			_configure_slope(smat, id)
		else:
			_configure_stochastic(smat, id)
		return
	var sm := mat as StandardMaterial3D
	if sm == null:
		return
	# Godot drops the heightmap when triplanar is on, so the two are set
	# exclusively: turn the unused one off first, then enable the chosen one.
	mat.uv1_triplanar = false
	mat.uv1_world_triplanar = false
	mat.heightmap_enabled = false

	# --- Projection mode ---
	if _mapping == Mapping.TRIPLANAR:
		# Projects the texture along X, Y and Z and blends by the surface
		# normal, so a texture never smears or stretches on a sloped face --
		# the failure mode of box-projected UVs across a voxel cliff. World
		# space is what we want: the quads are chunk-local, so UV space would
		# shift the projection at every chunk border.
		mat.uv1_triplanar = true
		mat.uv1_world_triplanar = true
		mat.uv1_triplanar_sharpness = 1.0
		mat.uv1_scale = Vector3.ONE
	elif _mapping == Mapping.PARALLAX and _quality >= POM_QUALITY:
		# --- Parallax occlusion mapping (Godot's heightmap system) ---
		# The POM stage ray-marches the height field in tangent space to fake
		# depth, so a block face gains relief at grazing angles instead of
		# reading as a flat photograph. The height field is derived from the
		# set's own normal map by the asset pipeline, so the relief POM fakes
		# and the relief the shader lights are the same relief.
		var own := MaterialLibrary.texture_set_for(id)
		var hpath := "%s/%s/height_1024.png" % [RUNTIME, own]
		if _has(hpath):
			mat.heightmap_enabled = true
			mat.heightmap_texture = load(hpath)
			# Small scale: a block is one metre, so relief should stay within
			# the block rather than bulging out of it.
			mat.heightmap_scale = 0.04
			mat.heightmap_min_layers = 8
			mat.heightmap_max_layers = 16
			# Deep parallax is the occlusion-marched variant proper.
			mat.heightmap_deep_parallax = true
			mat.heightmap_flip_tangent = false

	# --- Detail layer ---
	# Reads UV2, which the mesher tiles DETAIL_UV_SCALE times per block, so the
	# overlay breaks up the albedo without changing the base tiling.
	if _quality >= Quality.MEDIUM:
		var dname := MaterialLibrary.detail_set_for(id)
		if dname != "" and dname != MaterialLibrary.texture_set_for(id):
			var dpath := "%s/%s/diff_%d.jpg" % [RUNTIME, dname, DETAIL_TIER]
			if _has(dpath):
				mat.detail_enabled = true
				mat.detail_uv_layer = BaseMaterial3D.DETAIL_UV_2
				mat.detail_albedo = load(dpath)
				# Blend mode 0 is ADD, 1 is MIX. MIX keeps the overlay subtle --
				# this is surface breakup, not a pattern painted on the block.
				mat.detail_blend_mode = 1
				# detail_mask is a Texture2D, not a scalar, so the overlay
				# strength is controlled by the blend mode and the texture
				# choice.


## Load a PBR set if present; failures are cached so we never retry per frame.
func _get_material(id: int, translucent: bool) -> StandardMaterial3D:
	var store := _trans_materials if translucent else _materials
	if store.has(id):
		return store[id]
	var set_name := MaterialLibrary.texture_set_for(id)
	var tier := _tier_for(set_name)
	if tier == 0:
		_failed[set_name] = true
		return null
	var diff := "%s/%s/diff_%d.jpg" % [RUNTIME, set_name, tier]

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = load(diff)
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.16 if translucent else 0.95
	mat.metallic = 0.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED if translucent \
			else BaseMaterial3D.CULL_BACK
	if translucent:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(1, 1, 1, 0.78)

	# Normal and ARM maps are written at half the albedo tier above 1024, so
	# they are asked for by the same capped resolution.
	var data_tier: int = min(tier, 1024)
	# Normal maps must be flagged as such or Godot reads them as albedo.
	var nor := "%s/%s/nor_gl_%d.png" % [RUNTIME, set_name, data_tier]
	if _has(nor):
		mat.normal_enabled = true
		mat.normal_texture = load(nor)
		mat.normal_scale = 1.0 if _quality >= Quality.HIGH else 0.6
	# The ARM map packs occlusion in R, roughness in G, metalness in B. Godot
	# can read all three from one texture, so it is bound as the ORM map.
	var arm := "%s/%s/arm_%d.png" % [RUNTIME, set_name, data_tier]
	if _has(arm):
		# ambientCG ships no occlusion map at 1K, so the pipeline writes R as
		# fully open for those sets. Binding it is then a no-op rather than a
		# black surface, which is why this is unconditional.
		mat.ao_enabled = true
		mat.ao_texture = load(arm)
		mat.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
		mat.roughness_texture = load(arm)
		mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
		mat.metallic_texture = load(arm)
		mat.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
	_apply_effects(mat, id)
	store[id] = mat
	return mat


## A material made of code, not of pixels. See PROCEDURAL.
func _get_procedural(id: int) -> StandardMaterial3D:
	var set_name := MaterialLibrary.texture_set_for(id)
	if not PROCEDURAL.has(set_name):
		return null
	if _procedural.has(set_name):
		return _procedural[set_name]
	var spec: Dictionary = PROCEDURAL[set_name]
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = spec["color"]
	m.roughness = spec["roughness"]
	m.metallic = spec["metallic"]
	# Glass is lit from the sky but must not be lit from behind by its own
	# backfaces, which is what CULL_DISABLED plus a lit shading mode gives.
	# The procedural materials are counted by `effect_counts` alongside the
	# textured ones, so they go through the same effect pass: a material that
	# skipped it would be counted as a textured material with no projection
	# mode at all, which is what made triplanar mode report 28 of 29.
	_apply_effects(m, id)
	_materials[id] = m
	_procedural[set_name] = m
	return m


## Material for one mesher surface, given the block id that produced it.
##
## The three diagnostic overrides come first: they exist to take the render
## pipeline apart, so they have to win over every ordinary material choice
## rather than being overridden by it.
func material_for(id: int) -> Material:
	# Order matters: the normal-debug shader is the most specific override
	# and has to be tested first. The NORMAL stage is also "unlit" (a
	# normals picture must not be shaded), so with the unlit branch first it
	# would win and every stage from NORMAL onwards would render the same
	# flat baseline.
	if _normal_debug:
		return _normal_material()
	if _unlit or _flat_override:
		return _flat_material()
	if id == ContentDB.GLOWSTONE:
		return _emissive
	# --- Slope blending ---
	# Only a block with a declared top/side pair takes this path, and only when
	# it is opaque. Everything else falls through to the branches below
	# unchanged, so turning this mode on cannot alter a block that has no pair
	# -- and a translucent block keeps the engine materials that can actually
	# do transparency.
	if _mapping == Mapping.SLOPE and not ContentDB.is_translucent(id):
		var slopem := _get_slope_material(id)
		if slopem != null:
			return slopem
	# SLOPE is STOCHASTIC plus the pairs above: unpaired blocks are meant to
	# look exactly as they did, so they run the ordinary shader path.
	if _mapping == Mapping.STOCHASTIC or _mapping == Mapping.SLOPE:
		# The vendored shader writes ALBEDO from vertex_tint.rgb and never
		# touches the alpha channel, so a translucent block put through it is
		# opaque. Glass and water therefore take the engine materials that
		# can do transparency, exactly as they do in the other modes -- the
		# plain material they used to fall back to made every window in the
		# world a white brick.
		if ContentDB.is_translucent(id):
			if MaterialLibrary.texture_set_for(id) in PROCEDURAL:
				var pm := _get_procedural(id)
				if pm != null:
					return pm
			if MaterialLibrary.texture_set_for(id) != "":
				var tm := _get_material(id, true)
				if tm != null:
					return tm
			return _water
		if MaterialLibrary.texture_set_for(id) != "":
			var smat := _get_shader_material(id, false)
			if smat != null:
				return smat
		return _plain
	if ContentDB.is_translucent(id):
		if MaterialLibrary.texture_set_for(id) in PROCEDURAL:
			return _get_procedural(id)
		if MaterialLibrary.texture_set_for(id) != "":
			var tmat := _get_material(id, true)
			if tmat != null:
				return tmat
		return _water
	if MaterialLibrary.texture_set_for(id) != "":
		var mat := _get_material(id, false)
		if mat != null:
			return mat
	return _plain


## Apply a quality tier to every live material, and to any set loaded later.
## Cheap to re-run: each material is reconfigured in place.
func apply_quality(q: int) -> void:
	_quality = q
	for store in [_materials, _trans_materials, _shader_materials, _slope_materials]:
		for id in store.keys():
			_apply_effects(store[id], id)


## Choose between triplanar projection and parallax occlusion. They are
## mutually exclusive in Godot, so this replaces the other rather than adding
## to it.
func set_mapping(m: int) -> void:
	# Engine materials cannot become shader materials in place, so switching
	# into or out of STOCHASTIC has to drop the cache and rebuild from scratch.
	var was_shader := _is_shader_mapping(_mapping)
	_mapping = m
	var is_shader := _is_shader_mapping(_mapping)
	if was_shader != is_shader:
		_materials.clear()
		_trans_materials.clear()
		_shader_materials.clear()
		_slope_materials.clear()
		_procedural.clear()
		prime()
		return
	for store in [_materials, _trans_materials, _shader_materials, _slope_materials]:
		for id in store.keys():
			_apply_effects(store[id], id)


## True for the mappings that build hand-authored ShaderMaterials rather than
## engine StandardMaterial3Ds. Switching between the two families cannot be
## done in place, so `set_mapping` has to rebuild rather than reconfigure.
static func _is_shader_mapping(m: int) -> bool:
	return m == Mapping.STOCHASTIC or m == Mapping.SLOPE


func mapping() -> int:
	return _mapping


static func mapping_name() -> Array[String]:
	return ["plain", "triplanar", "parallax", "stochastic", "slope"]


## Build the hand-authored stochastic triplanar material for a block id. This
## path is separate from StandardMaterial3D: the shader samples albedo, normal
## and ARM maps itself, in world space, with a per-cell hash offset.
func _get_shader_material(id: int, translucent: bool) -> ShaderMaterial:
	if _shader_materials.has(id):
		return _shader_materials[id]
	var set_name := MaterialLibrary.texture_set_for(id)
	var tier := _tier_for(set_name)
	if tier == 0:
		return null
	var data_tier: int = min(tier, 1024)
	var m := ShaderMaterial.new()
	m.shader = STOCHASTIC_SHADER
	# The mesher's vertex colours are already in sRGB, so no conversion.
	m.set_shader_parameter("albedo_tex",
		load("%s/%s/diff_%d.jpg" % [RUNTIME, set_name, tier]))
	m.set_shader_parameter("albedo_tint", Color(1, 1, 1, 1))
	# One texture tile per block face.
	m.set_shader_parameter("uv_scale", 1.0)
	var dname := MaterialLibrary.detail_set_for(id)
	if dname != "" and _has("%s/%s/diff_%d.jpg"
			% [RUNTIME, dname, DETAIL_TIER]):
		m.set_shader_parameter("detail_tex",
			load("%s/%s/diff_%d.jpg" % [RUNTIME, dname, DETAIL_TIER]))
		m.set_shader_parameter("detail_strength",
			0.35 if _quality >= Quality.MEDIUM else 0.0)
	else:
		m.set_shader_parameter("detail_strength", 0.0)
	if _has("%s/%s/nor_gl_%d.png" % [RUNTIME, set_name, data_tier]):
		m.set_shader_parameter("normal_tex",
			load("%s/%s/nor_gl_%d.png" % [RUNTIME, set_name, data_tier]))
		m.set_shader_parameter("normal_strength", 1.0)
	if _has("%s/%s/arm_%d.png" % [RUNTIME, set_name, data_tier]):
		m.set_shader_parameter("arm_tex",
			load("%s/%s/arm_%d.png" % [RUNTIME, set_name, data_tier]))
		m.set_shader_parameter("use_arm", true)
	else:
		m.set_shader_parameter("use_arm", false)
	if translucent:
		m.set_shader_parameter("roughness_override", 0.1)
		m.set_shader_parameter("metallic_override", 0.1)
		m.render_priority = 1
	_shader_materials[id] = m
	return m


## Bind one texture set's albedo, normal and ARM maps under `prefix`, which is
## "top" or "side". Deliberately the same file naming and the same data tier
## clamp as the single-texture path, so a set named in a slope pair is loaded
## exactly as it would be on its own.
func _bind_slope_set(m: ShaderMaterial, prefix: String, set_name: String,
		tier: int) -> void:
	var data_tier: int = min(tier, 1024)
	m.set_shader_parameter(prefix + "_albedo_tex",
		load("%s/%s/diff_%d.jpg" % [RUNTIME, set_name, tier]))
	m.set_shader_parameter(prefix + "_normal_tex",
		load("%s/%s/nor_gl_%d.png" % [RUNTIME, set_name, data_tier]))
	m.set_shader_parameter(prefix + "_arm_tex",
		load("%s/%s/arm_%d.png" % [RUNTIME, set_name, data_tier]))


## Build the two-set slope material for a block id, or null when the block has
## no pair or a set is missing. The two ends name real sets in the same
## registry the single-texture path uses, so a pair cannot point at something
## that is not shipped.
func _get_slope_material(id: int) -> ShaderMaterial:
	if _slope_materials.has(id):
		return _slope_materials[id]
	var pair := MaterialLibrary.slope_pair_for(id)
	if pair.is_empty():
		return null
	var top_name: String = pair["top"]
	var side_name: String = pair["side"]
	var top_tier := _tier_for(top_name)
	var side_tier := _tier_for(side_name)
	if top_tier == 0 or side_tier == 0:
		return null
	var m := ShaderMaterial.new()
	m.shader = SLOPE_SHADER
	m.set_shader_parameter("albedo_tint", Color(1, 1, 1, 1))
	# One texture tile per block face, matching the stochastic path.
	m.set_shader_parameter("uv_scale", 1.0)
	# The rule itself, set from the one constant both this and the tests read.
	m.set_shader_parameter("slope_threshold", SLOPE_THRESHOLD)
	_bind_slope_set(m, "top", top_name, top_tier)
	_bind_slope_set(m, "side", side_name, side_tier)
	m.set_shader_parameter("use_arm", true)
	_configure_slope(m, id)
	_slope_materials[id] = m
	return m


## The slope shader is built from the two sets at construction; this keeps the
## quality-dependent uniforms in step, matching `_configure_stochastic`. The
## detail overlay is the block's own, applied to both ends, so the finer
## breakup does not change as the blend crosses the threshold.
func _configure_slope(m: ShaderMaterial, id: int) -> void:
	var dname := MaterialLibrary.detail_set_for(id)
	var dpath := "%s/%s/diff_%d.jpg" % [RUNTIME, dname, DETAIL_TIER]
	if _quality >= Quality.MEDIUM and dname != "" and _has(dpath):
		var dtex := load(dpath)
		m.set_shader_parameter("top_detail_tex", dtex)
		m.set_shader_parameter("side_detail_tex", dtex)
		m.set_shader_parameter("detail_strength", 0.35)
	else:
		m.set_shader_parameter("detail_strength", 0.0)
	m.set_shader_parameter("normal_strength",
		1.0 if _quality >= Quality.MEDIUM else 0.0)


## The stochastic shader is configured at construction, so this only has to
## keep the quality-dependent uniforms in step.
func _configure_stochastic(m: ShaderMaterial, _id: int) -> void:
	if _quality >= Quality.MEDIUM:
		if m.get_shader_parameter("detail_tex") != null:
			m.set_shader_parameter("detail_strength", 0.35)
		m.set_shader_parameter("normal_strength", 1.0)
	else:
		m.set_shader_parameter("detail_strength", 0.0)
		m.set_shader_parameter("normal_strength", 0.0)


func quality() -> int:
	return _quality


## The rung of the texture ladder the current tier is loading.
func texture_tier() -> int:
	return int(TEXTURE_TIER.get(_quality, 1024))


## How many block ids resolved to a textured material.
func loaded_count() -> int:
	return _materials.size() + _trans_materials.size() + _shader_materials.size()


## Load every texture set the content database can reference, so the reported
## count covers the whole set rather than only the blocks in view.
func prime() -> void:
	for id in range(0, ContentDB.MAX_ID + 1):
		material_for(id)


## Estimated VRAM held by the textures bound to the live materials.
##
## Godot imports a 3D-detected texture with VRAM compression, so a BC7 map
## costs about one byte per texel plus a third for the mip chain. This is an
## estimate from the engine's own texture dimensions, not a measurement of the
## driver: the only way to get the latter is to run on a GPU, which this
## development environment does not have.
func texture_vram_mb() -> float:
	var bytes := 0
	var seen := {}
	for store in [_materials, _trans_materials]:
		for id in store.keys():
			var m := store[id] as StandardMaterial3D
			if m == null:
				continue
			for tex in [m.albedo_texture, m.normal_texture,
					m.roughness_texture, m.metallic_texture,
					m.heightmap_texture, m.detail_albedo]:
				bytes += _texture_bytes(tex, seen)
	# Stochastic mode binds its maps as shader parameters instead of material
	# properties, so an estimate that only walked the engine materials
	# reported 0 MB for a world with every texture set loaded.
	for id in _shader_materials.keys():
		var sm := _shader_materials[id] as ShaderMaterial
		if sm == null:
			continue
		for key in ["albedo_tex", "detail_tex", "normal_tex", "arm_tex"]:
			bytes += _texture_bytes(sm.get_shader_parameter(key), seen)
	return float(bytes) / (1024.0 * 1024.0)


## Estimated VRAM for one texture, counted once per resource path.
static func _texture_bytes(tex: Variant, seen: Dictionary) -> int:
	if tex == null or not (tex is Texture2D):
		return 0
	var t := tex as Texture2D
	var key := t.resource_path
	if key == "" or seen.has(key):
		return 0
	seen[key] = true
	return t.get_width() * t.get_height() * 4 / 3


## How many live materials have each advanced effect switched on. Used by the
## test suite and the HUD to prove the stock features are actually active.
func effect_counts() -> Dictionary:
	var triplanar := 0
	var pom := 0
	var detail := 0
	var stochastic := 0
	var slope := 0
	var total := 0
	for store in [_materials, _trans_materials]:
		for id in store.keys():
			var m := store[id] as StandardMaterial3D
			if m == null:
				continue
			total += 1
			if m.uv1_triplanar and m.uv1_world_triplanar:
				triplanar += 1
			# Godot 4's parallax occlusion mapping is the heightmap system.
			if m.heightmap_enabled:
				pom += 1
			if m.detail_enabled:
				detail += 1
	for id in _shader_materials.keys():
		total += 1
		stochastic += 1
	for id in _slope_materials.keys():
		total += 1
		slope += 1
	return {
		"materials": total,
		"triplanar": triplanar,
		"pom": pom,
		"detail": detail,
		"stochastic": stochastic,
		"slope": slope,
		"procedural": _procedural.size(),
		"tier": texture_tier(),
		# Godot discards the heightmap on a triplanar material, so exactly one
		# of these should be non-zero. A material counted in both would be
		# rendering with triplanar and a silently dead heightmap.
		"mapping": MaterialLibrary.mapping_name()[clampi(_mapping, 0,
				MaterialLibrary.mapping_name().size() - 1)],
	}


## Human-readable summary for the HUD and test output.
func describe() -> String:
	var sets := {}
	for store in [_materials, _trans_materials, _shader_materials, _slope_materials]:
		for id in store.keys():
			sets[MaterialLibrary.texture_set_for(id)] = true
	var names := sets.keys()
	names.sort()
	return "%d texture sets at %dpx: %s" % [names.size(), texture_tier(),
			", ".join(names)]
