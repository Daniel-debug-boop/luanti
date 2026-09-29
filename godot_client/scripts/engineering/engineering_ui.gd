class_name EngHud
extends CanvasLayer
## The engineering interface.
##
## The design rule this file follows is the one the whole system rests on: the
## player spends their time looking at the world, not at menus. So the default
## state of this UI is almost nothing -- a target readout beside the crosshair
## and a thin status strip along the bottom. Everything else appears only when
## the player is actively doing something, and disappears when they stop.
##
## What that buys, concretely:
##   * No material browser. The material is whatever the part is made of.
##   * No recipe tree. The workshop is standing in the world, not in a menu.
##   * No spreadsheet. Exact numbers appear only at the higher interaction
##     levels, where the player asked for them.
##
## Two panels exist. The build panel is a small strip that says what the held
## tool will do and whether it can. The workshop panel, behind one key, is the
## only place with a list in it, and it lists what is standing and what is
## missing -- not what is available.

const MARGIN := 18.0
const PANEL_WIDTH := 360.0
const TARGET_WIDTH := 300.0

var engineering: EngEngineering = null

var _target_title: Label = null
var _target_body: Label = null
var _target_exact: Label = null
var _status: PanelContainer = null
var _status_label: Label = null
var _build: PanelContainer = null
var _build_label: Label = null
var _workshop: PanelContainer = null
var _workshop_label: Label = null
var _toast: Label = null
var _toast_time := 0.0
var _target_node := -1
var _tool_preview := ""
var _workshop_open := false
## Small caps section heading style, used consistently across both panels.
var _heading_font_size := 12
var _body_font_size := 13


func _ready() -> void:
	layer = 4
	_make_target()
	_make_status()
	_make_build_panel()
	_make_workshop_panel()
	_make_toast()
	engineering = get_parent().get_node_or_null("Engineering") as EngEngineering
	_connect_signals()


func attach(eng: EngEngineering) -> void:
	engineering = eng
	_connect_signals()


func _connect_signals() -> void:
	if engineering == null or engineering.assembly_recognised.is_connected(_on_recognised):
		return
	engineering.assembly_recognised.connect(_on_recognised)
	engineering.notice.connect(show_toast)

# --- construction ----------------------------------------------------------

## A panel with the game's own look: a dark translucent card, a hairline
## border, and a margin. Built from stock theme overrides so it matches the
## rest of the interface without a theme resource.
func _card() -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.07, 0.09, 0.86)
	style.border_color = Color(0.35, 0.42, 0.52, 0.55)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return panel


func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 4)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


func _make_target() -> void:
	# Anchored to the top right: beside the crosshair, clear of the hotbar and
	# of anything the inventory panel opens on the left.
	var box := VBoxContainer.new()
	box.name = "TargetReadout"
	box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	box.offset_left = -TARGET_WIDTH - MARGIN
	box.offset_right = -MARGIN
	box.offset_top = MARGIN
	box.add_theme_constant_override("separation", 1)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.visible = false

	_target_title = _label("", 15, Color(0.98, 0.86, 0.45))
	_target_body = _label("", _body_font_size, Color(0.86, 0.90, 0.96))
	_target_exact = _label("", 11, Color(0.55, 0.80, 1.0))
	_target_exact.visible = false
	box.add_child(_target_title)
	box.add_child(_target_body)
	box.add_child(_target_exact)
	add_child(box)
	_target_readout = box


var _target_readout: VBoxContainer = null


func _make_status() -> void:
	# A single thin strip along the bottom: what the player is holding, and
	# which interaction level the cursor is in. Two facts, always visible,
	# never a menu.
	_status = _card()
	_status.name = "StatusBar"
	_status.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_status.offset_left = 0
	_status.offset_right = 0
	_status.offset_top = -30
	_status.offset_bottom = 0
	_status.add_theme_stylebox_override("panel", _status_style())
	_status_label = _label("", 12, Color(0.72, 0.78, 0.86))
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_child(_status_label)
	add_child(_status)


func _status_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.06, 0.08, 0.72)
	style.border_color = Color(0.30, 0.36, 0.45, 0.5)
	style.border_width_top = 1
	style.content_margin_top = 5
	style.content_margin_bottom = 5
	return style


func _make_build_panel() -> void:
	# Above the status bar, on the left, so it never covers the crosshair.
	_build = _card()
	_build.name = "BuildPanel"
	_build.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_build.offset_left = MARGIN
	_build.offset_top = -108
	_build.offset_bottom = -40
	_build.custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	_build_label = _label("", _body_font_size, Color(0.92, 0.94, 0.98))
	_build.add_child(_build_label)
	_build.visible = false
	add_child(_build)


func _make_workshop_panel() -> void:
	# The one panel with a list in it, and it opens on a key press rather than
	# being a screen the game drops you into.
	_workshop = _card()
	_workshop.name = "WorkshopPanel"
	_workshop.set_anchors_preset(Control.PRESET_CENTER)
	_workshop.offset_left = -PANEL_WIDTH * 0.5
	_workshop.offset_right = PANEL_WIDTH * 0.5
	_workshop.offset_top = -220
	_workshop.offset_bottom = 220
	_workshop_label = _label("", _body_font_size, Color(0.90, 0.93, 0.97))
	_workshop.add_child(_workshop_label)
	_workshop.visible = false
	add_child(_workshop)


func _make_toast() -> void:
	_toast = _label("", 16, Color(0.60, 1.00, 0.72))
	_toast.name = "Toast"
	_toast.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toast.offset_left = -260
	_toast.offset_right = 260
	_toast.offset_top = 84
	_toast.offset_bottom = 124
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.modulate.a = 0.0
	add_child(_toast)

# --- per-frame -------------------------------------------------------------

func _process(delta: float) -> void:
	if _toast_time > 0.0:
		_toast_time -= delta
		# Fade out over the last third rather than snapping off.
		_toast.modulate.a = clampf(_toast_time / 0.8, 0.0, 1.0)
	_update_target()
	_update_status()
	_update_build_panel()


## Tell the UI what the player is looking at. -1 for nothing.
func set_target(node_id: int) -> void:
	_target_node = node_id


## Tell the UI what the held tool would do, and whether it can.
func set_tool_preview(text: String) -> void:
	_tool_preview = text


func _update_target() -> void:
	if engineering == null or _target_node < 0 or not engineering.graph.has_node(_target_node):
		_target_readout.visible = false
		return
	var readout := engineering.describe_target(_target_node)
	if readout == "":
		_target_readout.visible = false
		return
	var lines := readout.split("\n")
	_target_title.text = lines[0] if not lines.is_empty() else ""
	_target_body.text = "\n".join(PackedStringArray(lines).slice(1))
	# The exact figures are only worth the space at the higher two interaction
	# levels. A beginner gets words; an engineer gets numbers.
	_target_exact.visible = engineering.cursor_level != EngCursor.Level.ASSISTED
	if _target_exact.visible:
		_target_exact.text = engineering.exact_for(_target_node)
	_target_readout.visible = true


func _update_status() -> void:
	var held := ""
	if engineering != null and engineering.inventory != null:
		held = engineering.inventory.selected_eng_item()
		var block := engineering.inventory.selected_block_id()
		if held == "" and block >= 0:
			held = ContentDB.name_of(block)
	var levels := ["assisted", "standard", "precision"]
	var level := "assisted"
	if engineering != null:
		level = levels[clampi(engineering.cursor_level, 0, 2)]
	_status_label.text = "%s      %s      [F] use   [R] %s   [B] workshop" % [
		("holding " + held) if held != "" else "hands",
		level,
		levels[(levels.find(level) + 1) % 3]]


func _update_build_panel() -> void:
	if _tool_preview == "":
		_build.visible = false
		return
	_build_label.text = _tool_preview
	_build.visible = true

# --- workshop panel --------------------------------------------------------

func toggle_workshop() -> void:
	_workshop_open = not _workshop_open
	_refresh_workshop()


func _refresh_workshop() -> void:
	_workshop.visible = _workshop_open
	if not _workshop_open or engineering == null:
		return
	var lines := PackedStringArray()
	lines.append("WORKSHOP")
	lines.append("")
	var standing := EngWorkshop.standing(engineering.graph)
	for id in EngWorkshop.all_ids():
		var t := EngWorkshop.get_tier(id)
		if t == null:
			continue
		var mark := "x" if standing.has(id) else " "
		var line := "  [%s] %s" % [mark, t.name.capitalize()]
		if not standing.has(id):
			line += "   (tier %.2f)" % t.difficulty
		lines.append(line)
	lines.append("")
	lines.append("BEST TIER  %.2f" % EngWorkshop.best_difficulty(engineering.graph))
	var goal := EngWorkshop.next_goal(engineering.graph)
	if not goal.is_empty():
		var needs := PackedStringArray()
		for k in (goal["needs"] as Dictionary).keys():
			needs.append(String(k))
		lines.append("NEXT  %s needs %s" % [String(goal["name"]),
			", ".join(needs)])
	lines.append("")
	lines.append("MADE  %d components" % engineering.graph.node_count())
	lines.append("PACK  %s" % ", ".join(PackedStringArray(
		engineering.inventory.available_eng()) if engineering.inventory != null
		else PackedStringArray()))
	_workshop_label.text = "\n".join(lines)

# --- toast -----------------------------------------------------------------

## A named assembly appeared in front of the player. Recognition is
## informative, not modal, so it is a toast and not a dialog.
func _on_recognised(_node_id: int, label: String) -> void:
	show_toast("built: %s" % label)


func show_toast(text: String) -> void:
	_toast.text = text
	_toast.modulate.a = 1.0
	_toast_time = 2.4


## A short line the caller can print anywhere: what the player could build
## next, and why they cannot yet.
func workshop_hint() -> String:
	if engineering == null:
		return ""
	var goal := EngWorkshop.next_goal(engineering.graph)
	if goal.is_empty():
		return "workshop complete"
	return "next: %s" % String(goal["name"])
