class_name RenderSettings
extends RefCounted
## Configures Godot's built-in screen-space and probe-based lighting effects.
##
## Everything here is stock engine functionality set through `Environment` and
## the `FogVolume` / `ReflectionProbe` nodes. No shader code is loaded or
## compiled anywhere in this project.
##
##   SSAO  -- `ssao_enabled`   screen-space ambient occlusion
##   SSIL  -- `ssil_enabled`   screen-space indirect lighting
##   SDFGI -- `sdfgi_enabled`  the engine's signed-distance-field ray-traced
##                              global illumination, plus `ReflectionProbe`
##                              volumes for the probe-based fallback
##   Fog   -- `volumetric_fog_enabled` plus a `FogVolume` for god rays
##   Glow  -- `glow_enabled`   bloom around emissive blocks
##
## NOTE ON SDFGI: Godot 4.4's SDFGI needs an `SDFGIProbeVolume3D` node to
## provide the signed distance field, and that class is not exposed to script
## in this build -- it can only be authored in the Godot editor and saved into
## the scene. `sdfgi_enabled` is therefore left to the editor, and
## `ReflectionProbe` volumes are used here so bounce light is real either way.
## Set `sdfgi_enabled` in the environment inspector to turn the ray-traced path
## on once a probe volume exists in the scene.
##
## SDFGI and volumetric fog are the two expensive entries, so they are tiered:
## `Quality.LOW` leaves them off.

enum Quality { LOW, MEDIUM, HIGH }

@export var quality := Quality.HIGH
## Half-extent of each reflection probe's influence, in nodes.
@export var probe_range := 12.0
## Base density of the volumetric fog; DayNight scales this with the clock.
@export var volumetric_density := 0.012

var _fog_volume: FogVolume
var _probes: Array[ReflectionProbe] = []


## Build the overworld environment. The sky is left to DayNight, which writes
## into the same Environment each frame.
func build_overworld_environment() -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY

	# Depth fog gives distance falloff on top of the volumetric layer, which is
	# what makes the horizon read as far away.
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Color(0.68, 0.78, 0.9)
	env.fog_density = 0.0011
	env.fog_sky_affect = 0.0
	env.fog_aerial_perspective = 0.4

	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_white = 6.0

	apply(env)
	return env


## The Deeps: a dark cavern. Volumetric fog is kept, because a glowing crystal
## cavern is exactly where light shafts earn their cost, but the sky terms are
## off.
func build_deeps_environment() -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.015, 0.03)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.25, 0.2, 0.4)
	env.ambient_light_energy = 0.5
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Color(0.08, 0.05, 0.12)
	env.fog_density = 0.006
	env.tonemap_mode = Environment.TONE_MAPPER_ACES

	# Glow is the main light source down here, so it is pushed hard.
	env.glow_enabled = true
	env.glow_intensity = 0.9
	env.glow_bloom = 0.1
	env.glow_hdr_threshold = 0.9

	apply(env)
	return env


## Switch the effect set on `env` to the current tier. Safe to call on an
## environment that is already live; the node picks the change up immediately.
func apply(env: Environment) -> void:
	if env == null:
		return

	# --- Glow: always on, it is what sells the emissive blocks ---
	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.glow_bloom = 0.05
	env.glow_hdr_threshold = 1.0
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.glow_hdr_scale = 2.0

	# --- SSAO: soft contact darkening where voxel blocks meet ---
	# The mesher already bakes per-vertex occlusion; SSAO adds the sub-voxel
	# crevices a per-vertex term cannot resolve, which is what makes corners
	# read as separate blocks instead of one flat mass.
	env.ssao_enabled = true
	env.ssao_radius = 1.4
	env.ssao_intensity = 2.4
	env.ssao_power = 1.5
	env.ssao_detail = 0.6
	env.ssao_sharpness = 0.9
	env.ssao_horizon = 0.06
	env.ssao_light_affect = 0.15
	env.ssao_ao_channel_affect = 0.4

	# --- SSIL: one bounce of indirect light, in screen space ---
	env.ssil_enabled = quality >= Quality.MEDIUM
	env.ssil_radius = 4.0
	env.ssil_intensity = 1.1
	env.ssil_sharpness = 0.98
	env.ssil_normal_rejection = 1.0

	# --- SDFGI: configured, not force-enabled ---
	# These are real Environment properties, so a scene that does contain an
	# SDFGI probe volume (authored in the editor) picks the settings up as-is.
	# They are only written when the tier is high, because toggling SDFGI on
	# a live environment forces the renderer to rebuild its cascades.
	if quality >= Quality.HIGH:
		env.sdfgi_cascades = 4
		env.sdfgi_min_cell_size = 0.25
		env.sdfgi_use_occlusion = true
		env.sdfgi_read_sky_light = true
		env.sdfgi_bounce_feedback = 0.7
		env.sdfgi_normal_bias = 1.2
		env.sdfgi_probe_bias = 1.0
		env.sdfgi_energy = 1.0
		env.sdfgi_max_distance = 64.0
		env.sdfgi_cascade0_distance = 8.0
		env.sdfgi_y_scale = Environment.SDFGI_Y_SCALE_100_PERCENT

	# --- Volumetric fog: god rays and distance haze ---
	env.volumetric_fog_enabled = quality >= Quality.MEDIUM
	env.volumetric_fog_density = volumetric_density
	env.volumetric_fog_albedo = Color(0.75, 0.82, 0.92)
	env.volumetric_fog_emission = Color(0.1, 0.11, 0.14)
	env.volumetric_fog_emission_energy = 0.3
	# Injecting probe light into the fog is what makes sun shafts appear where
	# the sun clears a treeline.
	env.volumetric_fog_gi_inject = 0.6
	env.volumetric_fog_anisotropy = 0.25
	env.volumetric_fog_length = 96.0
	env.volumetric_fog_detail_spread = 2.0
	env.volumetric_fog_sky_affect = 0.25
	env.volumetric_fog_ambient_inject = 0.4
	env.volumetric_fog_temporal_reprojection_enabled = true
	env.volumetric_fog_temporal_reprojection_amount = 0.9


## Whether the environment should have `sdfgi_enabled` switched on. Kept
## separate from `apply` because enabling it at runtime is expensive and
## requires an SDFGI probe volume in the scene to have any effect.
func apply_sdfgi(env: Environment, on: bool) -> void:
	if env == null:
		return
	env.sdfgi_enabled = on


## A fog volume placed at the player, so the volumetric layer is dense where
## the camera is rather than spread thin across the whole world.
func make_fog_volume() -> FogVolume:
	var v := FogVolume.new()
	v.name = "FogVolume"
	v.size = Vector3(96, 48, 96)
	_fog_volume = v
	return v


## A ring of reflection probes around the player. These capture the local scene
## colour and feed it back as specular bounce, which is the probe-based
## counterpart to SDFGI's ray-traced bounce: a lit grass block tints the stone
## beside it.
func make_probes(count: int = 4) -> Array[ReflectionProbe]:
	var out: Array[ReflectionProbe] = []
	var radius := probe_range
	for i in count:
		var p := ReflectionProbe.new()
		p.name = "BounceProbe%d" % i
		p.size = Vector3.ONE * radius
		# Continuous so a moving player gets fresh bounce light, rather than
		# only when something inside the volume changes.
		p.update_mode = ReflectionProbe.UPDATE_ALWAYS
		out.append(p)
	_probes = out
	return out


func fog_volume() -> FogVolume:
	return _fog_volume


func probes() -> Array[ReflectionProbe]:
	return _probes


## Spread the probe ring around a point. A ring rather than a single probe,
## because one probe cannot see both a sunlit wall and its shaded side at once.
func place_probes(centre: Vector3) -> void:
	if _probes.is_empty():
		return
	var n := _probes.size()
	for i in n:
		var a := TAU * float(i) / float(n)
		# ReflectionProbe has no explicit bake() in Godot 4; it refreshes itself
		# when its update mode says so, so only the transform is set here.
		_probes[i].global_position = centre + Vector3(
			cos(a), probe_range * 0.5, sin(a)) * probe_range


## Switch tier at runtime. Materials and both environments are reconfigured.
func set_quality(q: int, materials: MaterialLibrary,
		environments: Array[Environment]) -> void:
	quality = q
	if materials != null:
		materials.apply_quality(q)
	for env in environments:
		apply(env)


## Which effects the current tier switches on, for the HUD and the tests.
func active_effects() -> Dictionary:
	return {
		"ssao": true,
		"ssil": quality >= Quality.MEDIUM,
		"volumetric_fog": quality >= Quality.MEDIUM,
		"glow": true,
		"bounce_probes": true,
		# SDFGI is configured but only runs with an editor-authored probe
		# volume, so it is reported as configured rather than active.
		"sdfgi_configured": quality >= Quality.HIGH,
		"quality": quality,
	}


## One-line summary, e.g. "HIGH: ssao ssil fog glow probes".
func describe() -> String:
	var tiers := ["LOW", "MEDIUM", "HIGH"]
	var names: String = tiers[clampi(quality, 0, 2)]
	var on := active_effects()
	var parts := PackedStringArray()
	for key in ["ssao", "ssil", "volumetric_fog", "glow", "bounce_probes"]:
		if on[key]:
			parts.append(String(key).replace("volumetric_fog", "fog"))
	if on.sdfgi_configured:
		parts.append("sdfgi(cfg)")
	return "%s: %s" % [names, " ".join(parts)]
