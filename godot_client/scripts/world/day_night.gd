class_name DayNight
extends Node3D
## Drives the sky from the downloaded Poly Haven HDRIs and moves the sun.
##
## A full game day is DAY_LENGTH seconds. The clock picks one of the daytime
## panoramas for the day and one of the night panoramas after dusk, blending
## ambient energy and light colour across the transitions so the change reads
## as a sunrise rather than a cut. The Deeps ignore the clock and keep their
## own dark environment.

## Seconds per full 24h cycle.
const DAY_LENGTH := 480.0
## Clock hours at which the panorama swaps.
const DUSK := 18.5
const DAWN := 6.0

const DAY_SKIES := [
	"quarry_01_puresky", "kloofendal_48d_partly_cloudy_puresky",
	"autumn_field_puresky", "farm_field_puresky",
]
## Used around dusk and dawn, when the sun sits near the horizon.
const DUSK_SKIES := ["belfast_sunset_puresky", "venice_sunset"]
const NIGHT_SKIES := ["dikhololo_night", "moonless_golf", "clarens_night_01"]

const HDRI_DIR := "res://assets/raw/hdri"

@export var world_environment: WorldEnvironment
@export var sun: DirectionalLight3D
@export var moon: DirectionalLight3D
## 0.0 = midnight, 0.25 = sunrise, 0.5 = noon.
@export var time_of_day := 0.32

var _sky := Sky.new()
var _panorama := PanoramaSkyMaterial.new()
var _current_sky := ""
var _overworld_env: Environment


func _ready() -> void:
	_panorama.panorama = null
	_sky.sky_material = _panorama
	if world_environment != null:
		_overworld_env = world_environment.environment
		_overworld_env.background_mode = Environment.BG_SKY
		_overworld_env.sky = _sky
		_overworld_env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		# HDRIs carry their own exposure; keep the ambient contribution mild so
		# surfaces are not washed out by the panorama.
		_overworld_env.ambient_light_sky_contribution = 0.55
	_apply()


func advance(delta: float) -> void:
	time_of_day = fmod(time_of_day + delta / DAY_LENGTH, 1.0)
	_apply()


func clock_string() -> String:
	var total := time_of_day * 24.0
	var h := int(total) % 24
	var m := int((total - floor(total)) * 60.0)
	return "%02d:%02d" % [h, m]


## 0 at night, 1 in full day, with smooth dawn/dusk shoulders.
func daylight() -> float:
	var dawn := DAWN / 24.0
	var dusk := DUSK / 24.0
	if time_of_day >= dawn and time_of_day < dusk:
		# Sunrise ramps in over the first fifth of the day.
		return smoothstep(0.0, 0.2, (time_of_day - dawn) / (dusk - dawn))
	if time_of_day >= dusk:
		# Sunset ramps out over the next sixth of the night.
		return 1.0 - smoothstep(0.0, 0.16,
			(time_of_day - dusk) / (1.0 - dusk))
	# Before dawn: the tail of the previous night.
	return smoothstep(0.84, 1.0, time_of_day / dawn)


func is_night() -> bool:
	return daylight() < 0.35


func _apply() -> void:
	var d := daylight()
	_swap_panorama(d)

	if sun != null:
		# Sun travels a tilted arc: azimuth sweeps a full turn per day.
		var ang := (time_of_day - 0.25) * TAU
		sun.rotation_degrees = Vector3(-cos(ang) * 62.0,
			-rad_to_deg(ang) + 35.0, 0.0)
		sun.light_energy = lerpf(0.05, 1.25, d)
		# Warm at the horizon, neutral at noon.
		var warmth := clampf(1.0 - d, 0.0, 1.0)
		sun.light_color = Color(1.0, 1.0, 1.0).lerp(
			Color(1.0, 0.62, 0.36), warmth * 0.85)
		sun.visible = d > 0.02
	if moon != null:
		moon.rotation_degrees = Vector3(sun.rotation_degrees.x + 180.0,
			sun.rotation_degrees.y, 0.0)
		moon.light_energy = lerpf(0.16, 0.0, d)
		moon.visible = d < 0.6
	if _overworld_env != null:
		_overworld_env.ambient_light_energy = lerpf(0.12, 1.0, d)
		_overworld_env.fog_light_color = Color(0.05, 0.06, 0.12).lerp(
			Color(0.68, 0.78, 0.9), d)
		_overworld_env.fog_density = lerpf(0.0018, 0.0011, d)


## Load the panorama for the current half of the day, choosing a fixed set per
## cycle so the sky is stable rather than flickering between variants.
func _swap_panorama(d: float) -> void:
	var pool: Array = NIGHT_SKIES
	if d >= 0.5:
		pool = DAY_SKIES
	elif d >= 0.12:
		# Low sun: the sunset panoramas read better than a full-day sky.
		pool = DUSK_SKIES
	# Two slots per panorama so the index changes slowly through the day.
	var idx := int(fmod(time_of_day * float(pool.size()) * 2.0, 2.0))
	var wanted := "%s/%s.hdr" % [HDRI_DIR, pool[idx]]
	if wanted == _current_sky:
		return
	if not ResourceLoader.exists(wanted):
		return
	var tex: Texture2D = load(wanted)
	if tex == null:
		return
	_panorama.panorama = tex
	_panorama.energy_multiplier = lerpf(0.35, 1.0, d)
	_current_sky = wanted


## Which HDRIs are actually available (HUD/test reporting).
func available_sketches() -> PackedStringArray:
	var out := PackedStringArray()
	for group in [DAY_SKIES, DUSK_SKIES, NIGHT_SKIES]:
		for n in group:
			if ResourceLoader.exists("%s/%s.hdr" % [HDRI_DIR, n]):
				out.append(n)
	return out
