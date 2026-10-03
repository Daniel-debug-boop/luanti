class_name VitalsBar
extends Control
## Health and air, drawn as shapes rather than as coloured rectangles.
##
## The old HUD drew ten `ColorRect`s in a row. Ten identical rectangles
## read as a progress bar chopped up, not as hearts, and at low health the
## only difference between full and empty was a tint. These are real heart
## outlines, filled or hollow, so the state is legible without a legend.
##
## The heart is sampled from the standard implicit heart curve
##     x = 16 sin^3 t,  y = 13 cos t - 5 cos 2t - 2 cos 3t - cos 4t
## which gives a symmetric shape without hand-placing points.

const HEART_COUNT := 10
const SAMPLES := 44

var max_health: float = 20.0
var health: float = 20.0
## Seconds of air left, or -1 when the player is not underwater.
var air: float = -1.0
var max_air: float = 10.0

var _outline: PackedVector2Array = PackedVector2Array()


func _init() -> void:
	custom_minimum_size = Vector2(0, 22)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_vitals(hp: float, hp_max: float, air_left: float,
		air_max: float) -> void:
	health = hp
	max_health = maxf(1.0, hp_max)
	air = air_left
	max_air = maxf(1.0, air_max)
	queue_redraw()


func _heart_points(centre: Vector2, radius: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var min_y := INF
	var max_y := -INF
	for i in SAMPLES:
		var t := TAU * float(i) / float(SAMPLES)
		var x := 16.0 * pow(sin(t), 3.0)
		var y := 13.0 * cos(t) - 5.0 * cos(2.0 * t) \
			- 2.0 * cos(3.0 * t) - cos(4.0 * t)
		min_y = minf(min_y, y)
		max_y = maxf(max_y, y)
	var span := maxf(0.001, max_y - min_y)
	# Normalise the sampled curve into a box of `radius`, centred.
	var k := radius * 2.0 / span
	for i in SAMPLES:
		var t := TAU * float(i) / float(SAMPLES)
		var x := 16.0 * pow(sin(t), 3.0)
		var y := 13.0 * cos(t) - 5.0 * cos(2.0 * t) \
			- 2.0 * cos(3.0 * t) - cos(4.0 * t)
		pts.append(centre + Vector2(x * k, (y - min_y) * k - radius))
	return pts


func _draw() -> void:
	if _outline.is_empty():
		_outline = _heart_points(Vector2(8, 8), 7.0)
	var frac := clampf(health / max_health, 0.0, 1.0)
	var per_heart := 1.0 / float(HEART_COUNT)
	var step := 18.0
	var x := 0.0
	for i in HEART_COUNT:
		# A heart is "full" while the health total still covers its slice, so
		# the bar loses exactly one heart at a time instead of dimming all at
		# once.
		var filled := frac > (float(i) * per_heart)
		var partial := clampf(
			(frac - float(i) * per_heart) / per_heart, 0.0, 1.0)
		var centre := Vector2(x + 8.0, size.y * 0.5)
		draw_colored_polygon(_heart_points(centre, 7.0), UiTheme.HEALTH_EMPTY)
		if filled:
			draw_colored_polygon(_heart_points(centre, 7.0), UiTheme.HEALTH)
		elif partial > 0.0:
			# A partly-lost heart is drawn short, rising from the bottom, so
			# the loss is visible before it costs a whole heart.
			var body := _heart_points(centre, 7.0)
			var keep := maxf(0.0, minf(1.0, partial))
			var shrunk := PackedVector2Array()
			for p in body:
				shrunk.append(Vector2(p.x, p.y + (1.0 - keep) * 14.0))
			if keep > 0.12:
				draw_colored_polygon(shrunk, UiTheme.HEALTH)
		x += step

	# Air, only while the player is underwater -- a permanent air pip would
	# be a permanent question the player has to learn to ignore.
	if air >= 0.0 and max_air > 0.0:
		var af := clampf(air / max_air, 0.0, 1.0)
		var bar := Rect2(Vector2(0, size.y - 3), Vector2(size.x * af, 3))
		draw_rect(bar, UiTheme.AIR if af > 0.25 else UiTheme.DANGER, true)


## Fraction of hearts currently showing as full, for tests.
func filled_fraction() -> float:
	var frac := clampf(health / max_health, 0.0, 1.0)
	return floor(frac * float(HEART_COUNT)) / float(HEART_COUNT)
