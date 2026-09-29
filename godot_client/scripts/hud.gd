class_name WorldHud
extends CanvasLayer
## Modern HUD overlay: translucent panels, FPS graph, world state readout,
## clock, hearts, health bar, block hotbar with selection, mining progress and
## a damage vignette. Built entirely from Control nodes, so it inherits the
## project's theme scaling automatically.

const PANEL_BG := Color(0.08, 0.10, 0.14, 0.55)
const PANEL_BORDER := Color(0.45, 0.65, 1.0, 0.35)
const PANEL_BORDER_SEL := Color(0.85, 0.95, 1.0, 0.95)
const TEXT := Color(0.92, 0.95, 1.0)
const ACCENT := Color(0.45, 0.75, 1.0)
const HEART := Color(0.92, 0.24, 0.3)
const HEART_EMPTY := Color(0.3, 0.14, 0.18, 0.7)
const HOTBAR_COUNT := 8
## Hearts shown; health is 20 so each heart is worth 1.25.
const HEARTS := 10

@export var player: Player
@export var world: VoxelWorld
@export var spawner: MobSpawner
@export var village: Village
@export var interaction: PlayerInteraction
@export var day_night: DayNight
## Not @export: RenderSettings is a RefCounted, not a Resource, so the editor
## cannot serialise it as a node property.
var settings: RenderSettings

var _panel: PanelContainer
var _stats: Label
var _fps_label: Label
var _fps_graph: ColorRect
var _fps_fill: ColorRect
var _biome_label: Label
var _dim_label: Label
var _clock_label: Label
var _health_fill: ColorRect
var _health_text: Label
var _hearts: Array[ColorRect] = []
var _hotbar: HBoxContainer
var _hotbar_slots: Array[PanelContainer] = []
var _hotbar_names: Array[Label] = []
var _target_label: Label
var _progress_bg: PanelContainer
var _progress_fill: ColorRect
var _vignette: ColorRect
var _fps_history: PackedFloat32Array = []
var _fps_peak := 0.0
var _elapsed := 0.0


func _ready() -> void:
	layer = 10
	_build()


func _panel_style(border := PANEL_BORDER) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL_BG
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(10)
	return sb


func _label(text: String, size: int, col := TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", col)
	l.add_theme_font_size_override("font_size", size)
	return l


func _build() -> void:
	_build_vignette()
	_build_world_panel()
	_build_fps_panel()
	_build_target_panel()
	_build_bottom()
	_build_crosshair()


## Full-screen red wash that pulses when the player takes damage. Alpha is
## driven from PlayerInteraction.hurt_flash().
func _build_vignette() -> void:
	_vignette = ColorRect.new()
	_vignette.color = Color(0.7, 0.05, 0.08, 0.0)
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_vignette)


func _build_world_panel() -> void:
	_panel = PanelContainer.new()
	_panel.position = Vector2(12, 12)
	_panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(_panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	_panel.add_child(vb)

	_dim_label = _label("Overworld", 15, ACCENT)
	vb.add_child(_dim_label)

	_clock_label = _label("06:00", 13, ACCENT)
	vb.add_child(_clock_label)

	_biome_label = _label("", 13)
	vb.add_child(_biome_label)

	_stats = _label("", 12)
	vb.add_child(_stats)


func _build_fps_panel() -> void:
	var fps_panel := PanelContainer.new()
	fps_panel.add_theme_stylebox_override("panel", _panel_style())
	fps_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	fps_panel.position = Vector2(-176, 12)
	fps_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	add_child(fps_panel)

	var fvb := VBoxContainer.new()
	fps_panel.add_child(fvb)

	_fps_label = _label("", 12)
	_fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	fvb.add_child(_fps_label)

	_fps_graph = ColorRect.new()
	_fps_graph.custom_minimum_size = Vector2(150, 34)
	_fps_graph.color = Color(0, 0, 0, 0.35)
	fvb.add_child(_fps_graph)
	_fps_fill = ColorRect.new()
	_fps_fill.color = ACCENT
	_fps_fill.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_fps_graph.add_child(_fps_fill)


## What the crosshair is on, plus the mining progress bar underneath it.
func _build_target_panel() -> void:
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.anchor_left = 0.5
	box.anchor_right = 0.5
	box.anchor_top = 0.5
	box.anchor_bottom = 0.5
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.add_theme_constant_override("separation", 6)
	add_child(box)

	_target_label = _label("", 13, Color(0.85, 0.9, 1.0))
	_target_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_target_label)

	_progress_bg = PanelContainer.new()
	_progress_bg.add_theme_stylebox_override("panel", _panel_style())
	_progress_bg.custom_minimum_size = Vector2(160, 10)
	_progress_bg.visible = false
	box.add_child(_progress_bg)
	_progress_fill = ColorRect.new()
	_progress_fill.color = Color(0.95, 0.8, 0.35)
	_progress_fill.set_anchors_preset(Control.PRESET_FULL_RECT)
	_progress_bg.add_child(_progress_fill)


func _build_bottom() -> void:
	var bottom := VBoxContainer.new()
	bottom.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	bottom.anchor_left = 0.5
	bottom.anchor_right = 0.5
	bottom.offset_top = -104
	bottom.grow_horizontal = Control.GROW_DIRECTION_BOTH
	add_child(bottom)

	# --- Hearts ---
	var hearts_row := HBoxContainer.new()
	hearts_row.alignment = BoxContainer.ALIGNMENT_CENTER
	hearts_row.add_theme_constant_override("separation", 3)
	bottom.add_child(hearts_row)
	for i in HEARTS:
		var h := ColorRect.new()
		h.custom_minimum_size = Vector2(15, 14)
		h.color = HEART
		h.set_anchors_preset(Control.PRESET_FULL_RECT)
		hearts_row.add_child(h)
		_hearts.append(h)

	# --- Health bar with numeric readout ---
	var health_bg := PanelContainer.new()
	health_bg.add_theme_stylebox_override("panel", _panel_style())
	health_bg.custom_minimum_size = Vector2(250, 20)
	bottom.add_child(health_bg)
	_health_fill = ColorRect.new()
	_health_fill.color = Color(0.9, 0.25, 0.3)
	_health_fill.set_anchors_preset(Control.PRESET_FULL_RECT)
	health_bg.add_child(_health_fill)
	_health_text = _label("20 / 20", 12)
	_health_text.set_anchors_preset(Control.PRESET_FULL_RECT)
	_health_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_health_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	health_bg.add_child(_health_text)

	# --- Hotbar ---
	_hotbar = HBoxContainer.new()
	_hotbar.add_theme_constant_override("separation", 6)
	_hotbar.alignment = BoxContainer.ALIGNMENT_CENTER
	bottom.add_child(_hotbar)
	for i in HOTBAR_COUNT:
		var slot := PanelContainer.new()
		slot.custom_minimum_size = Vector2(46, 52)
		slot.add_theme_stylebox_override("panel", _panel_style())
		var vb := VBoxContainer.new()
		vb.add_theme_constant_override("separation", 0)
		slot.add_child(vb)
		var swatch := ColorRect.new()
		swatch.custom_minimum_size = Vector2(26, 26)
		swatch.set_anchors_preset(Control.PRESET_FULL_RECT)
		vb.add_child(swatch)
		var num := _label(str(i + 1), 10, Color(0.7, 0.78, 0.9))
		num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vb.add_child(num)
		var nm := _label("", 8, Color(0.75, 0.82, 0.95))
		nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vb.add_child(nm)
		_hotbar.add_child(slot)
		_hotbar_slots.append(slot)
		_hotbar_names.append(nm)
		var swatch_ref := swatch
		slot.set_meta("swatch", swatch_ref)
		slot.set_meta("index", i)

	# --- Hint line ---
	var hint := _label(
		"WASD move · Space jump · Shift sprint · F fly · G dimension · "
		+ "LMB mine · RMB place · 1-8 select · E talk · F1-3 quality · F4-6 mapping",
		12, Color(0.75, 0.8, 0.9))
	hint.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	hint.position = Vector2(12, -28)
	add_child(hint)


func _build_crosshair() -> void:
	var cross_v := ColorRect.new()
	cross_v.color = Color(1, 1, 1, 0.8)
	cross_v.custom_minimum_size = Vector2(2, 14)
	cross_v.set_anchors_preset(Control.PRESET_CENTER)
	cross_v.offset_left = -1
	cross_v.offset_top = -7
	cross_v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(cross_v)
	var cross_h := ColorRect.new()
	cross_h.color = Color(1, 1, 1, 0.8)
	cross_h.custom_minimum_size = Vector2(14, 2)
	cross_h.set_anchors_preset(Control.PRESET_CENTER)
	cross_h.offset_left = -7
	cross_h.offset_top = -1
	cross_h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(cross_h)


func _process(delta: float) -> void:
	_elapsed += delta
	if player == null or world == null:
		return

	_update_fps()
	_update_world()
	_update_target()
	_update_vitals()

	var flash := interaction.hurt_flash() if interaction != null else 0.0
	_vignette.color.a = clampf(flash * 0.55, 0.0, 0.55)


func _update_fps() -> void:
	var fps := Engine.get_frames_per_second()
	_fps_peak = maxf(_fps_peak * 0.995, float(fps))
	_fps_history.append(float(fps))
	if _fps_history.size() > 150:
		_fps_history.remove_at(0)
	_fps_label.text = "%d fps · %.1f ms" % [fps, 1000.0 / maxf(1.0, float(fps))]
	var frac := clampf(float(fps) / maxf(60.0, _fps_peak), 0.0, 1.0)
	_fps_fill.size = Vector2(150, 34 * frac)


func _update_world() -> void:
	var bp := player.get_block_position()
	var s := world.get_stats()
	_dim_label.text = "The Deeps" if world.dimension \
		== WorldGenerator.DIM_DEEPS else "Overworld"
	if day_night != null:
		_clock_label.text = "%s %s" % [day_night.clock_string(),
			"☾" if day_night.is_night() else "☀"]
	_biome_label.text = world.biome_name_at(bp)

	var lines := [
		"xyz   %d %d %d" % [bp.x, bp.y, bp.z],
		"block %s" % ContentDB.name_of(world.get_content_at(bp)),
		"chunks %d loaded · %d meshed · %d dirty"
			% [s.chunks_loaded, s.chunks_visible, s.dirty],
		"tex    %d sets · %s" % [s.textures, s.mapping],
		"mobs   %d" % (spawner.mob_count() if spawner != null else 0),
	]
	if village != null:
		lines.append("town   %d props · %d villagers"
			% [village.prop_count(), village.villager_count()])
	if interaction != null:
		lines.append("dug %d · built %d" % [interaction.mined,
			interaction.placed])
	if settings != null:
		var fx := settings.active_effects()
		var on := PackedStringArray()
		if fx.ssao:
			on.append("ssao")
		if fx.ssil:
			on.append("ssil")
		if fx.volumetric_fog:
			on.append("fog")
		on.append("glow")
		on.append("probes")
		if fx.sdfgi_configured:
			on.append("sdfgi*")
		lines.append("light  %s" % " ".join(on))
	_stats.text = "\n".join(lines)


func _update_target() -> void:
	if interaction == null or not interaction.has_target:
		_target_label.text = ""
		_progress_bg.visible = false
		return
	var id := interaction.target_id
	var left := interaction.break_time_left()
	if left > 0.0:
		_target_label.text = "%s   %.1fs" % [ContentDB.name_of(id), left]
	else:
		_target_label.text = ContentDB.name_of(id)
	var p: float = interaction.break_progress
	_progress_bg.visible = p > 0.001
	if p > 0.001:
		_progress_fill.anchor_right = clampf(p, 0.0, 1.0)
		_progress_fill.offset_right = 0.0


func _update_vitals() -> void:
	var hp: float = player.health
	var frac := clampf(hp / maxf(1.0, player.max_health), 0.0, 1.0)
	_health_fill.anchor_right = frac
	_health_fill.offset_right = 0.0
	_health_text.text = "%d / %d" % [int(ceil(hp)), int(player.max_health)]
	# Each heart covers max_health / HEARTS points.
	var per_heart := player.max_health / float(HEARTS)
	for i in _hearts.size():
		_hearts[i].color = HEART if hp > float(i) * per_heart else HEART_EMPTY
	if interaction != null:
		var breath := interaction.breath()
		if breath < 9.9:
			_health_text.text += "   air %ds" % int(ceil(maxf(0.0, breath)))
	_update_hotbar()


## Paint each slot with its block's palette colour and mark the selected one.
func _update_hotbar() -> void:
	var bar: Array = interaction.hotbar if interaction != null else []
	var sel: int = interaction.selected if interaction != null else -1
	for i in _hotbar_slots.size():
		var slot := _hotbar_slots[i]
		var swatch := slot.get_meta("swatch") as ColorRect
		if i < bar.size():
			var id := int(bar[i])
			swatch.color = ContentDB.color_of(id)
			slot.modulate = Color(1, 1, 1, 1)
			_hotbar_names[i].text = ContentDB.name_of(id)
		else:
			swatch.color = Color(0, 0, 0, 0)
			slot.modulate = Color(1, 1, 1, 0.4)
			_hotbar_names[i].text = ""
		var border := PANEL_BORDER_SEL if i == sel else PANEL_BORDER
		slot.add_theme_stylebox_override("panel", _panel_style(border))


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		for slot in _hotbar:
			if slot.get_global_rect().has_point(mb.position) \
					and slot.has_meta("index"):
				select_slot(int(slot.get_meta("index")))
				return


## Called by main when a number key is pressed.
func select_slot(i: int) -> void:
	if interaction != null:
		interaction.select_slot(i)
