class_name RenderDiagnostics
extends RefCounted
## Layer-by-layer rendering diagnostics.
##
## When a capture looks wrong, the useful question is not "is it broken" but
## "which stage broke it". The hardware-GPU run that motivated this produced
## bright haze: that single image is consistent with broken geometry, with
## lighting, with fog, with the material shader, or with the post-processing
## stack, and nothing in it distinguishes those. Guessing wastes days;
## rendering one layer at a time answers it in one run.
##
## Each stage is cumulative -- `stage(N)` is everything up to N -- so the
## first stage whose output breaks tells you where the fault is. `stage(-1)`
## is the unlit baseline: no light, no environment, no post. If the world is
## wrong there, no amount of lighting tuning will help.

## Ordered from bare geometry to the full shipping look. The order is the
## dependency order: you cannot judge lighting before geometry, and you
## cannot judge post-processing before you can see what it is processing.
enum Stage {
	UNLIT,        ## Albedo only. No light, no environment, no post. Geometry test.
	ALBEDO,       ## Unlit + vertex colour and texture. Material-assignment test.
	NORMAL,       ## Normals as colour. Catches bad normals and winding.
	PBR,          ## Real materials with a directional light. Lighting test.
	ADVANCED,     ## PBR + POM / stochastic mapping. Shader-complexity test.
	ENVIRONMENT,  ## + sky, ambient, fog. Atmosphere test.
	POST,         ## + SSAO, SSIL, volumetric fog, glow. Full shipping stack.
}

## Human-readable names, in order.
const STAGE_NAMES := ["unlit", "albedo", "normal", "pbr", "advanced",
	"environment", "post"]

## Environment properties switched off in `UNLIT`, so the baseline cannot be
## contaminated by anything the renderer adds on its own.
const _ENV_OFF := [
	"ssao_enabled", "ssil_enabled", "glow_enabled", "sdfgi_enabled",
	"volumetric_fog_enabled", "fog_enabled", "adjustment_enabled",
	"tonemap_mode",
]


## Parse a stage name or index. Returns null when unrecognised, so the caller
## can produce a usage error instead of silently defaulting.
static func parse_stage(text: String) -> Variant:
	if text == "":
		return null
	var lower := text.strip_edges().to_lower()
	if lower.is_valid_int():
		var i := int(lower)
		return i if i >= 0 and i <= Stage.POST else null
	for i in STAGE_NAMES.size():
		if STAGE_NAMES[i] == lower:
			return i
	return null


## The name of a stage, for logs and metadata.
static func stage_name(s: int) -> String:
	return STAGE_NAMES[clampi(s, 0, Stage.POST)]


## Everything a stage implies, so the caller does not have to switch on the
## enum itself. `null` for a property means "leave it alone".
##
## Returned as a dictionary of settings rather than applied here, because the
## objects live in the composition root (main.gd) and this class must not
## reach into them -- which is also what the layering test enforces.
static func stage_settings(s: int) -> Dictionary:
	match clampi(s, 0, Stage.POST):
		Stage.UNLIT:
			return {
				"unlit": true,
				"env_over": {},
				"env_deeps": {},
				"lights": false,
				"material_mode": 0,
				"world_environment": false,
			}
		Stage.ALBEDO:
			return {
				"unlit": true,
				"env_over": {},
				"env_deeps": {},
				"lights": false,
				"material_mode": 1,
				"world_environment": false,
			}
		Stage.NORMAL:
			return {
				"unlit": true,
				"normal_debug": true,
				"env_over": {},
				"env_deeps": {},
				"lights": false,
				"material_mode": 0,
				"world_environment": false,
			}
		Stage.PBR:
			return {
				"unlit": false,
				"env_over": {"ssao_enabled": false, "ssil_enabled": false,
					"glow_enabled": false, "sdfgi_enabled": false,
					"volumetric_fog_enabled": false, "fog_enabled": false},
				"env_deeps": {},
				"lights": true,
				"material_mode": 1,
				"world_environment": true,
			}
		Stage.ADVANCED:
			return {
				"unlit": false,
				"env_over": {"ssao_enabled": false, "ssil_enabled": false,
					"glow_enabled": false, "sdfgi_enabled": false,
					"volumetric_fog_enabled": false, "fog_enabled": false},
				"env_deeps": {},
				"lights": true,
				"material_mode": 2,
				"world_environment": true,
			}
		Stage.ENVIRONMENT:
			return {
				"unlit": false,
				"env_over": {"ssao_enabled": false, "ssil_enabled": false,
					"glow_enabled": false, "sdfgi_enabled": false,
					"volumetric_fog_enabled": false, "fog_enabled": true},
				"env_deeps": {},
				"lights": true,
				"material_mode": 2,
				"world_environment": true,
			}
		_:
			# The full shipping stack: no overrides, take the live values.
			return {
				"unlit": false,
				"env_over": {},
				"env_deeps": {},
				"lights": true,
				"material_mode": 3,
				"world_environment": true,
			}


## A clean environment with every atmospheric and post effect off. Used for
## the baseline stages, where any of them would contaminate the result.
static func make_clean_environment(sky: bool) -> Environment:
	var env := Environment.new()
	if sky:
		env.background_mode = Environment.BG_SKY
		var s := Sky.new()
		s.sky_material = ProceduralSkyMaterial.new()
		env.sky = s
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	else:
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.05, 0.05, 0.07)
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color.WHITE
		env.ambient_light_energy = 1.0
	for prop in _ENV_OFF:
		env.set(prop, null)
	# Linear tonemapping at 1.0 so nothing rescales the values being
	# inspected. A filmic curve would make every one of these stages a lie
	# about contrast, which is exactly the thing being measured.
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	env.tonemap_white = 1.0
	return env


## Apply an override dictionary from `stage_settings` to an Environment.
## Only the named properties are touched, so the rest of the environment --
## sky, ambient, tonemap -- keeps whatever it already had.
static func apply_overrides(env: Environment, overrides: Dictionary) -> void:
	if env == null:
		return
	for k in overrides:
		env.set(String(k), overrides[k])


## One line describing a stage, for logs and for capture-content.txt.
static func describe(s: int) -> String:
	var name := stage_name(s)
	match clampi(s, 0, Stage.POST):
		Stage.UNLIT:
			return "unlit baseline: no light, no environment, no post"
		Stage.ALBEDO:
			return "albedo: unlit + vertex colour, no lighting"
		Stage.NORMAL:
			return "normals as colour: catches bad normals and winding"
		Stage.PBR:
			return "PBR: real materials, one directional light, no effects"
		Stage.ADVANCED:
			return "advanced materials: POM / stochastic mapping, no effects"
		Stage.ENVIRONMENT:
			return "environment: sky, ambient and depth fog, no post"
		_:
			return "post: the full shipping stack"