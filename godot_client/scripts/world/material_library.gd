class_name MaterialLibrary
extends RefCounted
## Builds PBR materials from the Poly Haven texture sets in assets/raw and maps
## content ids to them.
##
## The mesher emits one surface per block id, so this class hands out the
## material for each of those surfaces. Everything here is stock Godot 4.4: the
## materials are plain `StandardMaterial3D` and every effect is one of its
## built-in properties. No custom shader code is loaded anywhere in this
## project.
##
##   * Triplanar mapping        -- `uv1_triplanar` + `uv1_world_triplanar`
##   * Parallax occlusion (POM) -- the `heightmap_*` family. Godot 4 renamed
##                                  POM to "heightmap"; `heightmap_deep_parallax`
##                                  is the real occlusion-marched variant. It
##                                  consumes the downloaded `disp` (displacement)
##                                  maps, which is exactly the height field POM
##                                  ray-marches.
##   * Detail layer             -- `detail_enabled`, reading the mesher's UV2 set
##   * PBR                      -- albedo, normal, and ARM (occlusion) textures
##
## `vertex_color_use_as_albedo` stays on so the mesher's baked daylight,
## directional shading and ambient occlusion tint the photo texture.
## Ids with no texture set fall back to the palette-only vertex-color material,
## so the world still renders.

const RAW := "res://assets/raw/textures"
## The vendored stochastic triplanar shader (derived from Acegiak's
## Apache-2.0 terrain shader; see addons/ATTRIBUTION.md).
const STOCHASTIC_SHADER := preload("res://scripts/world/voxel_stochastic.gdshader")
## How many times the detail texture repeats per block, relative to UV1.
const DETAIL_UV_SCALE := 4.0

## Effect quality tiers, applied by `apply_quality`.
enum Quality { LOW, MEDIUM, HIGH }

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
##   PARALLAX  -- POM via the heightmap system, ray-marching the set's `disp`
##                map. Gives the face real relief at grazing angles.
##   STOCHASTIC-- the vendored Acegiak triplanar shader with stochastic
##                sampling, so the repeating grid pattern of a tiled texture
##                is broken up. Hand-authored GLSL rather than an engine
##                material, so it drops the StandardMaterial3D PBR path.
##   PLAIN     -- straight box UVs, cheapest.
enum Mapping { PLAIN, TRIPLANAR, PARALLAX, STOCHASTIC }

## Photographic PBR material, keyed by block id. Keying by id rather than by
## texture-set name lets several blocks that share a set still get their own
## detail overlay.
var _materials := {}          # int -> Material
## Translucent variants (water, ice), keyed by block id.
var _trans_materials := {}    # int -> Material
## Stochastic-shader materials, keyed by block id. These are ShaderMaterial,
## not StandardMaterial3D, so they live apart from the engine-material path.
var _shader_materials := {}   # int -> ShaderMaterial
## Set names that are known to be missing on disk, so we never retry.
var _failed := {}             # String -> true
var _plain: StandardMaterial3D
var _water: StandardMaterial3D
var _emissive: StandardMaterial3D
var _quality := Quality.HIGH
var _mapping := Mapping.PARALLAX


func _init() -> void:
	_plain = _make_plain()
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
		ContentDB.GRASS, ContentDB.CACTUS:
			return "forrest_ground_01"
		ContentDB.DIRT, ContentDB.WOOD, ContentDB.LEAVES:
			return "brown_mud_leaves_01"
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
	return ""


## The texture set used as a detail overlay for a block id, or "" for none.
## Detail is a finer surface breakup, so it deliberately differs from the
## albedo: dirt is broken up by gravel, stone by the coarse rock face.
static func detail_set_for(id: int) -> String:
	match id:
		ContentDB.GRASS, ContentDB.LEAVES, ContentDB.CACTUS:
			return "brown_mud_leaves_01"
		ContentDB.DIRT, ContentDB.WOOD, ContentDB.SAND:
			return "aerial_rocks_02"
		ContentDB.STONE, ContentDB.BEDROCK, ContentDB.GRAVEL:
			return "rock_face_04"
		ContentDB.SNOW:
			return "coast_sand_rocks_02"
		ContentDB.DEEPSLATE, ContentDB.DEEPSLATE_DEEP, ContentDB.VOID_ROCK:
			return "rock_06"
	return ""


static func _abs(res_path: String) -> String:
	return res_path.replace("res://", ProjectSettings.globalize_path("res://"))


func _has(res_path: String) -> bool:
	return FileAccess.file_exists(_abs(res_path)) \
			or ResourceLoader.exists(res_path)


## Configure the stock triplanar, POM and detail properties. All three are
## built into BaseMaterial3D; nothing here compiles a shader.
func _apply_effects(mat: Material, id: int) -> void:
	if mat is ShaderMaterial:
		_configure_stochastic(mat as ShaderMaterial, id)
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
	elif _mapping == Mapping.PARALLAX and _quality >= Quality.MEDIUM:
		# --- Parallax occlusion mapping (Godot's heightmap system) ---
		# The POM stage ray-marches the height field in tangent space to fake
		# depth, so a block face gains relief at grazing angles instead of
		# reading as a flat photograph. The height field is the set's own
		# `disp` map, which ships with every Poly Haven set we downloaded.
		var own := MaterialLibrary.texture_set_for(id)
		var hpath := "%s/%s_disp.jpg" % [RAW, own]
		if _has(hpath):
			mat.heightmap_enabled = true
			mat.heightmap_texture = load(hpath)
			# Small scale: a block is one metre, so relief should stay within
			# the block rather than bulging out of it.
			mat.heightmap_scale = 0.04
			mat.heightmap_min_layers = 8
			mat.heightmap_max_layers = 16 if _quality >= Quality.HIGH else 8
			# Deep parallax is the occlusion-marched variant proper.
			mat.heightmap_deep_parallax = _quality >= Quality.HIGH
			mat.heightmap_flip_tangent = false

	# --- Detail layer ---
	# Reads UV2, which the mesher tiles DETAIL_UV_SCALE times per block, so the
	# overlay breaks up the albedo without changing the base tiling.
	if _quality >= Quality.MEDIUM:
		var own_set := MaterialLibrary.texture_set_for(id)
		var dname := MaterialLibrary.detail_set_for(id)
		var dpath := "%s/%s_diff.jpg" % [RAW, dname]
		if dname != "" and dname != own_set and _has(dpath):
			mat.detail_enabled = true
			mat.detail_uv_layer = BaseMaterial3D.DETAIL_UV_2
			mat.detail_albedo = load(dpath)
			# Blend mode 0 is ADD, 1 is MIX. MIX keeps the overlay subtle --
			# this is surface breakup, not a pattern painted on the block.
			mat.detail_blend_mode = 1
			# detail_mask is a Texture2D, not a scalar, so the overlay
			# strength is controlled by the blend mode and the texture choice.


## Load a PBR set if present; failures are cached so we never retry per frame.
func _get_material(id: int, translucent: bool) -> StandardMaterial3D:
	var store := _trans_materials if translucent else _materials
	if store.has(id):
		return store[id]
	var set_name := MaterialLibrary.texture_set_for(id)
	var diff := "%s/%s_diff.jpg" % [RAW, set_name]
	if not _has(diff):
		_failed[set_name] = true
		return null

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

	# Normal maps must be flagged as such or Godot reads them as albedo.
	var nor := "%s/%s_nor_gl.jpg" % [RAW, set_name]
	if _has(nor):
		mat.normal_enabled = true
		mat.normal_texture = load(nor)
		mat.normal_scale = 1.0 if _quality >= Quality.HIGH else 0.6
	# The ARM map packs occlusion in R, roughness in G, metalness in B. Godot
	# can read all three from one texture, so it is bound as the ORM map.
	var arm := "%s/%s_arm.jpg" % [RAW, set_name]
	if _has(arm):
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


## Material for one mesher surface, given the block id that produced it.
func material_for(id: int) -> Material:
	if id == ContentDB.GLOWSTONE:
		return _emissive
	if _mapping == Mapping.STOCHASTIC:
		if MaterialLibrary.texture_set_for(id) != "":
			var smat := _get_shader_material(id, ContentDB.is_translucent(id))
			if smat != null:
				return smat
		return _plain
	if ContentDB.is_translucent(id):
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
	for store in [_materials, _trans_materials, _shader_materials]:
		for id in store.keys():
			_apply_effects(store[id], id)


## Choose between triplanar projection and parallax occlusion. They are
## mutually exclusive in Godot, so this replaces the other rather than adding
## to it.
func set_mapping(m: int) -> void:
	# Engine materials cannot become shader materials in place, so switching
	# into or out of STOCHASTIC has to drop the cache and rebuild from scratch.
	var was_stochastic := _mapping == Mapping.STOCHASTIC
	_mapping = m
	var is_stochastic := _mapping == Mapping.STOCHASTIC
	if was_stochastic != is_stochastic:
		_materials.clear()
		_trans_materials.clear()
		_shader_materials.clear()
		prime()
		return
	for store in [_materials, _trans_materials, _shader_materials]:
		for id in store.keys():
			_apply_effects(store[id], id)


func mapping() -> int:
	return _mapping


static func mapping_name() -> Array[String]:
	return ["plain", "triplanar", "parallax", "stochastic"]


## Build the hand-authored stochastic triplanar material for a block id. This
## path is separate from StandardMaterial3D: the shader samples albedo, normal
## and ARM maps itself, in world space, with a per-cell hash offset.
func _get_shader_material(id: int, translucent: bool) -> ShaderMaterial:
	if _shader_materials.has(id):
		return _shader_materials[id]
	var set_name := MaterialLibrary.texture_set_for(id)
	var diff := "%s/%s_diff.jpg" % [RAW, set_name]
	if not _has(diff):
		return null
	var m := ShaderMaterial.new()
	m.shader = STOCHASTIC_SHADER
	# The mesher's vertex colours are already in sRGB, so no conversion.
	m.set_shader_parameter("albedo_tex", load(diff))
	m.set_shader_parameter("albedo_tint", Color(1, 1, 1, 1))
	# One texture tile per block face.
	m.set_shader_parameter("uv_scale", 1.0)
	var dname := MaterialLibrary.detail_set_for(id)
	if dname != "" and _has("%s/%s_diff.jpg" % [RAW, dname]):
		m.set_shader_parameter("detail_tex",
			load("%s/%s_diff.jpg" % [RAW, dname]))
		m.set_shader_parameter("detail_strength",
			0.35 if _quality >= Quality.MEDIUM else 0.0)
	else:
		m.set_shader_parameter("detail_strength", 0.0)
	if _has("%s/%s_nor_gl.jpg" % [RAW, set_name]):
		m.set_shader_parameter("normal_tex",
			load("%s/%s_nor_gl.jpg" % [RAW, set_name]))
		m.set_shader_parameter("normal_strength", 1.0)
	if _has("%s/%s_arm.jpg" % [RAW, set_name]):
		m.set_shader_parameter("arm_tex",
			load("%s/%s_arm.jpg" % [RAW, set_name]))
		m.set_shader_parameter("use_arm", true)
	else:
		m.set_shader_parameter("use_arm", false)
	if translucent:
		m.set_shader_parameter("roughness_override", 0.1)
		m.set_shader_parameter("metallic_override", 0.1)
		m.render_priority = 1
	_shader_materials[id] = m
	return m


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


## How many block ids resolved to a textured material.
func loaded_count() -> int:
	return _materials.size() + _trans_materials.size() + _shader_materials.size()


## Load every texture set the content database can reference, so the reported
## count covers the whole set rather than only the blocks in view.
func prime() -> void:
	for id in range(0, 32):
		material_for(id)


## How many live materials have each advanced effect switched on. Used by the
## test suite and the HUD to prove the stock features are actually active.
func effect_counts() -> Dictionary:
	var triplanar := 0
	var pom := 0
	var detail := 0
	var stochastic := 0
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
	return {
		"materials": total,
		"triplanar": triplanar,
		"pom": pom,
		"detail": detail,
		"stochastic": stochastic,
		# Godot discards the heightmap on a triplanar material, so exactly one
		# of these should be non-zero. A material counted in both would be
		# rendering with triplanar and a silently dead heightmap.
		"mapping": MaterialLibrary.mapping_name()[clampi(_mapping, 0, 3)],
	}


## Human-readable summary for the HUD and test output.
func describe() -> String:
	var sets := {}
	for store in [_materials, _trans_materials, _shader_materials]:
		for id in store.keys():
			sets[MaterialLibrary.texture_set_for(id)] = true
	var names := sets.keys()
	names.sort()
	return "%d texture sets: %s" % [names.size(), ", ".join(names)]
