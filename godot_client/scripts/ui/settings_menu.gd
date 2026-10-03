class_name SettingsMenu
extends Control
## The options menu.
##
## Render quality and texture mapping were previously reachable only through
## F1-F3 and F4-F7, with no way to see what the settings currently were. That
## is fine for a developer with the source open and useless for a player who
## has to guess which of six function keys turns the fog off.
##
## This menu shows the current value of every setting, changes it on click,
## and is opened with O. The function keys still work and stay in sync --
## the menu reads the live setting rather than keeping its own copy, so the
## two can never disagree.
##
## The menu does not own the settings. It calls back into `main.gd` through
## the signals below, so there is exactly one place that applies a change.

signal quality_requested(level: int)
signal mapping_requested(mode: int)

const QUALITY_NAMES := ["Low", "Medium", "High"]
const MAPPING_NAMES := ["Plain", "Triplanar", "Parallax", "Stochastic"]

var current_quality: int = 2
var current_mapping: int = 2

var _root: PanelContainer
var _quality_buttons: Array[Button] = []
var _mapping_buttons: Array[Button] = []
var _hint: Label


func _init() -> void:
	name = "SettingsMenu"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false


func _ready() -> void:
	_build()
	_refresh()


func toggle() -> bool:
	if not visible:
		open()
	else:
		close()
	return visible


func open() -> void:
	visible = true
	_refresh()
	_focus_first()


func close() -> void:
	visible = false


func is_open() -> bool:
	return visible


## Adopt a change made by keyboard rather than by the menu, so pressing F2
## updates the menu rather than leaving it lying.
func sync_from(quality: int, mapping: int) -> void:
	current_quality = quality
	current_mapping = mapping
	if is_node_ready():
		_refresh()


func _focus_first() -> void:
	if not _quality_buttons.is_empty():
		_quality_buttons[0].grab_focus()


func _build() -> void:
	add_child(UiTheme.scrim())

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, UiTheme.SPACE_8)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(margin)

	var centre := CenterContainer.new()
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(centre)

	_root = PanelContainer.new()
	_root.add_theme_stylebox_override("panel", UiTheme.panel(
		UiTheme.BORDER_STRONG))
	_root.custom_minimum_size = Vector2(460, 0)
	centre.add_child(_root)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", UiTheme.SPACE_4)
	_root.add_child(col)

	var title := UiTheme.label("Options", UiTheme.Role.TITLE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(title)

	col.add_child(_section("Render quality"))
	col.add_child(_option_row("quality", QUALITY_NAMES,
		func(i: int) -> void: quality_requested.emit(i),
		_quality_buttons))

	col.add_child(_section("Texture mapping"))
	col.add_child(_option_row("mapping", MAPPING_NAMES,
		func(i: int) -> void: mapping_requested.emit(i),
		_mapping_buttons))

	col.add_child(_section("Controls"))
	for pair in [
			["Move", "W A S D"],
			["Jump / rise", "Space"],
			["Sprint", "Shift"],
			["Fly", "F"],
			["Mine / place", "Left / Right mouse"],
			["Select block", "1-8, scroll, or click"],
			["Talk / trade", "E"],
			["Crafting grid", "C"],
			["Save / load", "F5 / F9"],
			["Options", "O"],
			["Debug overlay", "F10"],
		]:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", UiTheme.SPACE_3)
		var name_label := UiTheme.label(String(pair[0]), UiTheme.Role.BODY,
			UiTheme.TEXT_MUTED)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_label)
		var keys := UiTheme.badge(String(pair[1]), UiTheme.TEXT)
		row.add_child(keys)
		col.add_child(row)

	_hint = UiTheme.label("Press O or Esc to close", UiTheme.Role.MICRO,
		UiTheme.TEXT_FAINT)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_hint)


## A section heading. Returns a container rather than the label so the
## heading can carry spacing without the caller having to wrap it.
func _section(text: String) -> VBoxContainer:
	var l := UiTheme.label(text.to_upper(), UiTheme.Role.MICRO,
		UiTheme.ACCENT)
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", UiTheme.SPACE_2)
	wrap.add_child(l)
	return wrap


## A segmented row of mutually exclusive options. Segmented rather than a
## dropdown because there are three or four of them and seeing the choices
## is the point.
func _option_row(id: String, names: Array,
		on_pick: Callable, sink: Array[Button]) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UiTheme.SPACE_2)
	for i in names.size():
		var b := Button.new()
		b.text = String(names[i])
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_ALL
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size = Vector2(0, 34)
		b.add_theme_stylebox_override("normal", UiTheme.button(0))
		b.add_theme_stylebox_override("hover", UiTheme.button(1))
		b.add_theme_stylebox_override("pressed", UiTheme.button(2))
		b.add_theme_stylebox_override("focus", UiTheme.button(1))
		b.add_theme_color_override("font_color", UiTheme.TEXT)
		b.add_theme_color_override("font_hover_color", Color.WHITE)
		b.add_theme_color_override("font_pressed_color", Color.WHITE)
		b.add_theme_font_size_override("font_size", UiTheme.SIZE_BODY)
		var idx := i
		b.pressed.connect(func() -> void: on_pick.call(idx))
		b.set_meta("group", id)
		row.add_child(b)
		sink.append(b)
	return row


## Push the live settings into the controls. Called on open and after any
## external change, so the menu is a view of the truth, not a second copy.
func _refresh() -> void:
	for i in _quality_buttons.size():
		_quality_buttons[i].button_pressed = i == current_quality
	for i in _mapping_buttons.size():
		_mapping_buttons[i].button_pressed = i == current_mapping


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and (event as InputEventKey).pressed \
			and not (event as InputEventKey).echo:
		match (event as InputEventKey).keycode:
			KEY_O, KEY_ESCAPE:
				close()
				get_viewport().set_input_as_handled()
