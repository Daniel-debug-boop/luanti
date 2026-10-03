class_name CraftingPanel
extends Control
## A real 3x3 crafting grid, replacing the "craft from what you carry" shortcut.
##
## Drag a block from the inventory strip into one of the nine cells and the
## result slot updates live through Crafting.find_recipe(). Take the result to
## collect it. This uses Godot's built-in Control drag-and-drop
## (_get_drag_data / _can_drop_data / _drop_data) rather than a bespoke input
## system.
##
## The grid holds ContentDB block ids, 0 = empty. Slots show the block's
## palette colour, which is consistent with the rest of the HUD and means the
## panel needs no texture assets.

const CELLS := 9
const CELL := 56
const GAP := 6
const STRIP_MAX := 27

const SLOT_SCRIPT := preload("res://scripts/gameplay/crafting_slot.gd")

const SLOT_BG := Color(0.10, 0.11, 0.14, 0.92)
const SLOT_BG_FILLED := Color(0.20, 0.22, 0.27, 0.96)
const SLOT_BORDER := Color(0.36, 0.39, 0.45)
const SLOT_BORDER_RESULT := Color(0.85, 0.72, 0.32)
const TEXT_DIM := Color(0.72, 0.75, 0.80)

var inventory: PlayerInventory = null
var audio: AudioDirector = null
## The 3x3 grid as a flat array of block ids.
var grid := PackedInt32Array()

var _cells: Array[Control] = []
var _strip: Array[Control] = []
var _result_slot: Control
var _result_id := 0
var _recipe: Dictionary = {}
var _title: Label
var _hint: Label
var _strip_grid: GridContainer
var _built := false


func _ready() -> void:
	build()
	if inventory != null:
		inventory.selection_changed.connect(_on_selection_changed)


## Attach after construction. Kept separate from _ready so a test can build the
## panel and inject the inventory without the scene wiring.
func setup(inv: PlayerInventory, audio_ref: AudioDirector = null) -> void:
	inventory = inv
	audio = audio_ref
	build()
	_rebuild_strip()
	_update_result()


## Create the widgets. Idempotent, and called from both _ready() and setup():
## a Control added from SceneTree._init does not get _ready() until the first
## frame, so building only in _ready() would leave the panel empty in tests.
func build() -> void:
	if _built:
		return
	_built = true
	set_anchors_preset(Control.PRESET_CENTER)
	visible = false
	grid.resize(CELLS)
	grid.fill(0)
	_strip_grid = GridContainer.new()
	_build_ui()


func toggle() -> bool:
	visible = not visible
	if visible:
		_rebuild_strip()
		_update_result()
		if audio != null:
			audio.play("ui_open")
	else:
		if audio != null:
			audio.play("ui_back")
	return visible


# --- construction -----------------------------------------------------------

func _build_ui() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.position = Vector2(-180, -210)
	panel.custom_minimum_size = Vector2(360, 420)
	panel.add_theme_stylebox_override("panel", _style(SLOT_BG, SLOT_BORDER, 2))
	add_child(panel)

	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(String(side), 14)
	panel.add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	margin.add_child(col)

	_title = Label.new()
	_title.text = "Crafting"
	col.add_child(_title)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", GAP * 2)
	col.add_child(row)

	# --- the 3x3 grid ---
	var grid_box := GridContainer.new()
	grid_box.columns = 3
	grid_box.add_theme_constant_override("h_separation", GAP)
	grid_box.add_theme_constant_override("v_separation", GAP)
	row.add_child(grid_box)
	for i in CELLS:
		var c := _make_slot(CELL)
		c.set_meta("kind", "grid")
		c.set_meta("index", i)
		grid_box.add_child(c)
		_cells.append(c)

	# --- arrow + result ---
	var mid := VBoxContainer.new()
	mid.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(mid)
	var arrow := Label.new()
	arrow.text = "→"
	mid.add_child(arrow)
	_result_slot = _make_slot(CELL * 1.5)
	_result_slot.set_meta("kind", "result")
	mid.add_child(_result_slot)

	# --- inventory strip ---
	_strip_grid = GridContainer.new()
	_strip_grid.columns = 9
	_strip_grid.add_theme_constant_override("h_separation", 4)
	_strip_grid.add_theme_constant_override("v_separation", 4)
	col.add_child(_strip_grid)

	_hint = Label.new()
	_hint.text = "Drag blocks into the grid. Drag the result out to collect it."
	_hint.add_theme_color_override("font_color", TEXT_DIM)
	col.add_child(_hint)

	# A click anywhere outside the panel closes it.
	var catcher := Control.new()
	catcher.set_anchors_preset(Control.PRESET_FULL_RECT)
	catcher.mouse_filter = Control.MOUSE_FILTER_STOP
	catcher.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed:
			toggle())
	add_child(catcher)
	move_child(catcher, 0)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP

	_title.add_theme_font_size_override("font_size", 20)
	_hint.add_theme_font_size_override("font_size", 12)


func _style(bg: Color, border: Color, width: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(width)
	s.set_corner_radius_all(4)
	return s


func _make_slot(size: int) -> Control:
	var slot := PanelContainer.new()
	slot.custom_minimum_size = Vector2(size, size)
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	slot.add_theme_stylebox_override("panel", _style(SLOT_BG, SLOT_BORDER, 2))
	# The drag-and-drop virtuals have to live on the dragged node itself, so
	# the behaviour is a script. `panel` is assigned explicitly rather than
	# found in _ready(), because set_script() on an already-created node does
	# not re-run _ready().
	slot.set_script(SLOT_SCRIPT)
	slot.set("panel", self)
	return slot


# --- grid state -------------------------------------------------------------

func set_cell(index: int, block_id: int) -> void:
	if index < 0 or index >= CELLS:
		return
	grid[index] = block_id
	_paint_cell(index)
	_update_result()


func get_cell(index: int) -> int:
	if index < 0 or index >= CELLS:
		return 0
	return grid[index]


func clear_grid() -> void:
	for i in CELLS:
		set_cell(i, ContentDB.AIR)


## Put one of each of the player's carried blocks into the grid, which is a
## quick way to try a recipe without dragging nine times.
func fill_from_inventory() -> void:
	clear_grid()
	if inventory == null:
		return
	var blocks := inventory.available_blocks()
	for i in mini(blocks.size(), CELLS):
		set_cell(i, blocks[i])


func _paint_cell(index: int) -> void:
	var id := grid[index]
	var slot := _cells[index]
	slot.set_meta("block_id", id)
	var swatch := _swatch(slot)
	if id == ContentDB.AIR:
		swatch.color = Color(0, 0, 0, 0)
		slot.add_theme_stylebox_override("panel", _style(SLOT_BG, SLOT_BORDER, 2))
	else:
		swatch.color = ContentDB.color_of(id)
		slot.add_theme_stylebox_override("panel", _style(SLOT_BG_FILLED,
			SLOT_BORDER, 2))


func _swatch(slot: Control) -> ColorRect:
	# Guard with has_meta rather than relying on get_meta's default argument:
	# Godot 4.4 prints an error for a missing key even when a default is given,
	# which put nine spurious errors in the log during start-up.
	var s: ColorRect = null
	if slot.has_meta("swatch"):
		s = slot.get_meta("swatch") as ColorRect
	if s == null:
		s = ColorRect.new()
		s.set_anchors_preset(Control.PRESET_FULL_RECT)
		s.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(s)
		slot.set_meta("swatch", s)
	return s


func _update_result() -> void:
	_recipe = Crafting.find_recipe(_grid_array())
	_result_id = ContentDB.AIR if _recipe.is_empty() \
		else int(_recipe.get("output", ContentDB.AIR))
	var swatch := _swatch(_result_slot)
	if _result_id == ContentDB.AIR:
		swatch.color = Color(0, 0, 0, 0)
		_result_slot.add_theme_stylebox_override("panel", _style(SLOT_BG,
			SLOT_BORDER, 2))
	else:
		swatch.color = ContentDB.color_of(_result_id)
		_result_slot.add_theme_stylebox_override("panel", _style(SLOT_BG_FILLED,
			SLOT_BORDER_RESULT, 3))
	_result_slot.set_meta("block_id", _result_id)
	_result_slot.set_meta("count", 0 if _recipe.is_empty()
		else int(_recipe.get("count", 1)))


func _grid_array() -> Array:
	var out: Array = []
	out.resize(CELLS)
	for i in CELLS:
		out[i] = grid[i]
	return out


## The recipe the grid currently satisfies, or {}.
func current_recipe() -> Dictionary:
	return _recipe


func result_block() -> int:
	return _result_id


# --- inventory strip -------------------------------------------------------

func _rebuild_strip() -> void:
	for c in _strip_grid.get_children():
		c.queue_free()
	_strip.clear()
	if inventory == null:
		return
	# One entry per distinct block carried, so the strip is a palette rather
	# than a mirror of the GLoot container.
	for bid in inventory.available_blocks():
		var slot := _make_slot(38)
		slot.set_meta("kind", "strip")
		slot.set_meta("block_id", bid)
		_strip_grid.add_child(slot)
		var swatch := _swatch(slot)
		swatch.color = ContentDB.color_of(bid)
		slot.add_theme_stylebox_override("panel", _style(SLOT_BG_FILLED,
			SLOT_BORDER, 2))
		_strip.append(slot)
		if _strip.size() >= STRIP_MAX:
			break


func _on_selection_changed(_index: int) -> void:
	# Nothing visual depends on the hotbar selection, but keeping the
	# connection makes the panel react if that changes.
	pass


## Take the result: consume the grid's inputs and hand over the output.
## Returns the block id crafted, or -1.
func take_result() -> int:
	if _recipe.is_empty() or inventory == null:
		if audio != null:
			audio.play("craft_fail")
		return -1
	var wanted: Array[int] = []
	for id in _grid_array():
		var b := int(id)
		if b != ContentDB.AIR:
			wanted.append(b)
	# Refuse unless the player is carrying *enough of every input* -- not just
	# one of each. Checking per cell rather than per block id would let a
	# player with a single stone "craft" a 3x3 stone recipe into four deepslate.
	var needed := {}
	for b in wanted:
		needed[b] = int(needed.get(b, 0)) + 1
	for b in needed.keys():
		if inventory.count_of(int(b)) < int(needed[b]):
			if audio != null:
				audio.play("craft_fail")
			return -1
	for b in needed.keys():
		inventory.consume_block(int(b), int(needed[b]))
	var out_id := int(_recipe["output"])
	for _i in int(_recipe.get("count", 1)):
		inventory.give_block(out_id)
	if audio != null:
		audio.play("craft")
	clear_grid()
	_rebuild_strip()
	return out_id
