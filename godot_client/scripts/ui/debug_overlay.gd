class_name DebugOverlay
extends Control
## Everything a developer needs and a player should never see.
##
## This used to be the top-left panel of the gameplay HUD, always on. Chunk
## counts, texture-set names, the active post-processing list, and counters
## for blocks dug and placed are instrumentation: they were on screen for
## every player at all times, mixed in with the clock and the biome, so the
## two could not be told apart.
##
## The split is the point. The HUD shows what the player needs to play.
## This shows what a developer needs to diagnose, and it is off until
## F10 is pressed.
##
## It deliberately does NOT use `UiTheme`'s player-facing tokens. A tool
## should look like a tool, and borrowing the game's card styling would
## blur the boundary this file exists to draw.

const F10_HINT := "F10"

## Developer-instrument colours, kept separate from the player palette.
const TOOL_BG := Color(0.02, 0.03, 0.02, 0.82)
const TOOL_BORDER := Color(0.35, 0.75, 0.45, 0.45)
const TOOL_TEXT := Color(0.72, 0.95, 0.78)
const TOOL_DIM := Color(0.45, 0.62, 0.50)
const TOOL_WARN := Color(0.95, 0.75, 0.35)
const TOOL_SIZE := 12

var player: Player = null
var world: VoxelWorld = null
var spawner: MobSpawner = null
var village: Village = null
var interaction: PlayerInteraction = null
var settings: RenderSettings = null

var _box: VBoxContainer
var _perf: Label
var _world: Label
var _counts: Label
var _effects: Label
var _fps_history: PackedFloat32Array = PackedFloat32Array()
var _fps_peak := 0.0
var _frame_ms := 0.0
var _elapsed := 0.0


func _init() -> void:
	name = "DebugOverlay"
	# Anchored to a corner, not given a pixel position, so it stays put at
	# any aspect ratio.
	set_anchors_preset(Control.PRESET_TOP_RIGHT)
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	grow_vertical = Control.GROW_DIRECTION_END
	offset_left = -260
	offset_top = UiTheme.SCREEN_MARGIN
	offset_right = -UiTheme.SCREEN_MARGIN
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false


func _ready() -> void:
	_build()


func toggle() -> bool:
	visible = not visible
	return visible


func is_open() -> bool:
	return visible


func _build() -> void:
	var card := PanelContainer.new()
	card.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	card.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	card.offset_left = -260
	card.offset_top = UiTheme.SCREEN_MARGIN
	card.offset_right = -UiTheme.SCREEN_MARGIN
	var sb := StyleBoxFlat.new()
	sb.bg_color = TOOL_BG
	sb.border_color = TOOL_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(8)
	card.add_theme_stylebox_override("panel", sb)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(card)

	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 3)
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(_box)

	var head := _tool_label("DEBUG  (%s to close)" % F10_HINT, TOOL_WARN)
	head.add_theme_font_size_override("font_size", TOOL_SIZE + 1)
	_box.add_child(head)
	var rule := ColorRect.new()
	rule.color = TOOL_BORDER
	rule.custom_minimum_size = Vector2(0, 1)
	_box.add_child(rule)

	_perf = _tool_label("", TOOL_TEXT)
	_world = _tool_label("", TOOL_TEXT)
	_counts = _tool_label("", TOOL_DIM)
	_effects = _tool_label("", TOOL_DIM)
	_box.add_child(_perf)
	_box.add_child(_world)
	_box.add_child(_counts)
	_box.add_child(_effects)


func _tool_label(text: String, colour: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", colour)
	l.add_theme_font_size_override("font_size", TOOL_SIZE)
	l.add_theme_constant_override("line_spacing", 0)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	return l


func _process(delta: float) -> void:
	if not visible:
		return
	_elapsed += delta
	_update_perf(delta)
	_update_world()
	_update_counts()
	_update_effects()


func _update_perf(_delta: float) -> void:
	var fps := Engine.get_frames_per_second()
	_fps_peak = maxf(_fps_peak * 0.995, float(fps))
	_frame_ms = 1000.0 / maxf(1.0, float(fps))
	_fps_history.append(float(fps))
	if _fps_history.size() > 120:
		_fps_history.remove_at(0)
	var avg := 0.0
	for f in _fps_history:
		avg += f
	avg /= maxf(1.0, float(_fps_history.size()))
	_perf.text = "perf  %d fps  %.1f ms  avg %.0f  peak %.0f" % [
		fps, _frame_ms, avg, _fps_peak]


func _update_world() -> void:
	if player == null or world == null:
		_world.text = "world  (not ready)"
		return
	var bp := player.get_block_position()
	var s := world.get_stats()
	_world.text = "\n".join([
		"pos   %d %d %d   in %s" % [bp.x, bp.y, bp.z,
			world.biome_name_at(bp)],
		"block %s" % ContentDB.name_of(world.get_content_at(bp)),
		"chunks %d loaded  %d meshed  %d dirty"
			% [s.chunks_loaded, s.chunks_visible, s.dirty],
		"tex    %d sets   mapping %s" % [s.textures, s.mapping],
		"dim    %d   backend %s" % [world.dimension, world.backend_name()],
	])


func _update_counts() -> void:
	var parts := PackedStringArray()
	if spawner != null:
		parts.append("mobs %d" % spawner.mob_count())
	if village != null:
		parts.append("village %d props  %d villagers"
			% [village.prop_count(), village.villager_count()])
	if interaction != null:
		parts.append("mined %d  placed %d"
			% [interaction.mined, interaction.placed])
	_counts.text = "  ".join(parts)


func _update_effects() -> void:
	if settings == null:
		_effects.text = ""
		return
	var fx := settings.active_effects()
	var on := PackedStringArray()
	for key in ["ssao", "ssil", "volumetric_fog", "glow", "bounce_probes"]:
		if bool(fx.get(key, false)):
			on.append(key)
	_effects.text = "fx    quality=%s  %s%s" % [
		settings.quality, " ".join(on),
		"  sdfgi*configured" if bool(fx.get("sdfgi_configured", false))
			else ""]
