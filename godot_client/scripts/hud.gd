class_name WorldHud
extends CanvasLayer
## The player-facing HUD.
##
## SCOPE. This shows what a player needs in order to play: what they are
## carrying, how healthy they are, what they are looking at, where they
## are, and what they can do here. It shows nothing else.
##
## Everything diagnostic used to live here too -- chunk counts, texture-set
## names, the active post-processing list, counters for blocks dug and
## placed, and a permanent fps readout. Those are instruments, and mixing
## them into the player's view meant the two could not be told apart: a
## player could not tell "Plains" from the chunk counter next to it. They
## now live in `DebugOverlay`, behind F10.
##
## LAYOUT. Every element is anchored to a screen edge rather than given a
## pixel position, so the HUD holds its shape from 720p to ultrawide. The
## three regions are: a status chip top-left, a context prompt and crosshair
## at centre, and the bar cluster (vitals, hotbar) bottom-centre.
##
## All numbers come from `UiTheme`, so spacing and type stay consistent with
## the crafting panel and the options menu.

const HOTBAR_COUNT := 8
## Shown on the hotbar, bottom-left, until the player has used the controls.
const HINT_TEXT := "WASD move · Space jump · E talk · C craft · O options"

@export var player: Player
@export var world: VoxelWorld
@export var spawner: MobSpawner
@export var village: Village
@export var interaction: PlayerInteraction
@export var day_night: DayNight

## RenderSettings is a RefCounted rather than a Resource, so the editor
## cannot serialise it as a node property. Held directly.
var settings: RenderSettings = null
## The GLoot container whose hotbar is displayed. When null the hotbar is
## empty rather than showing a second, invented item list.
var inventory: PlayerInventory = null
## Diagnostics. Never on unless the player asks for them.
var debug_overlay: DebugOverlay = null

# --- status chip (top-left) ---
var _chip: PanelContainer
var _place_label: Label
var _clock_label: Label
var _biome_label: Label

# --- crosshair + context prompt (centre) ---
var _crosshair: Control
var _prompt: PanelContainer
var _prompt_label: Label
var _key_badge: PanelContainer
var _progress_bg: PanelContainer
var _progress_fill: ColorRect

# --- bar cluster (bottom-centre) ---
var _cluster: VBoxContainer
var _vitals: VitalsBar
var _hotbar: HBoxContainer
var _hotbar_slots: Array[PanelContainer] = []
var _hotbar_icons: Array[BlockIcon] = []
var _hotbar_counts: Array[Label] = []
var _hint: Label

var _vignette: ColorRect
var _hovered_slot := -1
var _hint_timer := 0.0


func _ready() -> void:
	layer = 10
	_build()


# --- construction ---------------------------------------------------------

func _build() -> void:
	_build_vignette()
	_build_status_chip()
	_build_crosshair()
	_build_prompt()
	_build_cluster()
	_build_hint()
	if debug_overlay != null:
		add_child(debug_overlay)


## Full-screen red wash that pulses when the player takes damage.
func _build_vignette() -> void:
	_vignette = ColorRect.new()
	_vignette.color = Color(0.7, 0.05, 0.08, 0.0)
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_vignette)


## Where you are: dimension, clock, biome. Three lines, because they answer
## three different questions and none of them implies another.
func _build_status_chip() -> void:
	_chip = PanelContainer.new()
	_chip.add_theme_stylebox_override("panel", UiTheme.panel())
	_chip.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_chip.offset_left = UiTheme.SCREEN_MARGIN
	_chip.offset_top = UiTheme.SCREEN_MARGIN
	_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_chip)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chip.add_child(col)

	_place_label = UiTheme.label("Overworld", UiTheme.Role.SUBTITLE,
		UiTheme.ACCENT)
	_place_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_place_label)

	_clock_label = UiTheme.label("", UiTheme.Role.BODY, UiTheme.TEXT_MUTED)
	_clock_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_clock_label)

	_biome_label = UiTheme.label("", UiTheme.Role.BODY)
	_biome_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_biome_label)


## Four short strokes around a gap, so the centre stays readable. Drawn as
## one control with an explicit gap rather than two overlapping rectangles.
func _build_crosshair() -> void:
	_crosshair = Control.new()
	_crosshair.set_anchors_preset(Control.PRESET_CENTER)
	_crosshair.custom_minimum_size = Vector2(18, 18)
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_crosshair.draw.connect(_draw_crosshair)
	add_child(_crosshair)


## The contextual action line, above the crosshair: what you are looking at
## and what pressing a key would do about it.
func _build_prompt() -> void:
	_prompt = PanelContainer.new()
	_prompt.add_theme_stylebox_override("panel", UiTheme.panel())
	_prompt.set_anchors_preset(Control.PRESET_CENTER)
	_prompt.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_prompt.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_prompt.offset_bottom = -34
	_prompt.visible = false
	add_child(_prompt)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UiTheme.SPACE_2)
	_prompt.add_child(row)

	_key_badge = UiTheme.badge("E", UiTheme.ACCENT)
	_key_badge.visible = false
	row.add_child(_key_badge)

	_prompt_label = UiTheme.label("", UiTheme.Role.BODY, UiTheme.TEXT)
	row.add_child(_prompt_label)


## Vitals above the hotbar, both bottom-centre, in one column so they stay
## visually attached to the bar they belong to.
func _build_cluster() -> void:
	_cluster = VBoxContainer.new()
	_cluster.add_theme_constant_override("separation", UiTheme.SPACE_2)
	_cluster.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_cluster.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_cluster.grow_vertical = Control.GROW_DIRECTION_BEGIN
	# Anchored to the bottom edge with a margin, rather than a fixed offset,
	# so the cluster cannot drift off-screen when its contents change height.
	_cluster.offset_top = -(UiTheme.SLOT_SIZE + UiTheme.SPACE_4)
	_cluster.offset_bottom = -UiTheme.SCREEN_MARGIN
	add_child(_cluster)

	_vitals = VitalsBar.new()
	_vitals.custom_minimum_size = Vector2(
		UiTheme.SLOT_SIZE * 0 + float(HOTBAR_COUNT) * 18.0, 22)
	_cluster.add_child(_vitals)

	_hotbar = HBoxContainer.new()
	_hotbar.add_theme_constant_override("separation", UiTheme.SLOT_GAP)
	_hotbar.alignment = BoxContainer.ALIGNMENT_CENTER
	_cluster.add_child(_hotbar)

	for i in HOTBAR_COUNT:
		_hotbar.add_child(_make_slot(i))


func _make_slot(index: int) -> PanelContainer:
	var slot := PanelContainer.new()
	slot.custom_minimum_size = Vector2(UiTheme.SLOT_SIZE, UiTheme.SLOT_SIZE)
	slot.add_theme_stylebox_override("panel", UiTheme.slot(UiTheme.SlotState.IDLE))
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	slot.set_meta("index", index)
	slot.mouse_entered.connect(func() -> void: _set_hover(index))
	slot.mouse_exited.connect(func() -> void: _set_hover(-1))

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	slot.add_child(col)

	var icon := BlockIcon.new()
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(icon)

	# The hotkey sits in the corner as a keycap, not as a line of text under
	# the icon, so it cannot be mistaken for the item's name.
	var key := UiTheme.badge(str(index + 1), UiTheme.TEXT_FAINT)
	key.set_anchors_preset(Control.PRESET_TOP_LEFT)
	key.offset_left = 2
	key.offset_top = 2
	key.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(key)

	var count := UiTheme.label("", UiTheme.Role.MICRO, UiTheme.TEXT)
	count.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	count.offset_left = -26
	count.offset_top = -16
	count.offset_right = -3
	count.offset_bottom = -2
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(count)

	_hotbar_slots.append(slot)
	_hotbar_icons.append(icon)
	_hotbar_counts.append(count)
	return slot


## Control hints, shown briefly at the start and then out of the way.
func _build_hint() -> void:
	_hint = UiTheme.label(HINT_TEXT, UiTheme.Role.MICRO, UiTheme.TEXT_FAINT)
	_hint.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_hint.offset_left = UiTheme.SCREEN_MARGIN
	_hint.offset_top = -UiTheme.SCREEN_MARGIN - 18
	_hint.offset_bottom = -UiTheme.SCREEN_MARGIN
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint_timer = 12.0
	add_child(_hint)


# --- per-frame -----------------------------------------------------------

func _process(delta: float) -> void:
	if _hint_timer > 0.0:
		_hint_timer -= delta
		_hint.modulate.a = clampf(_hint_timer / 2.0, 0.0, 1.0)
		if _hint_timer <= 0.0:
			_hint.visible = false

	if player == null or world == null:
		return

	_update_place()
	_update_prompt()
	_update_vitals()
	_update_hotbar()

	var flash := interaction.hurt_flash() if interaction != null else 0.0
	_vignette.color.a = clampf(flash * 0.55, 0.0, 0.55)


func _update_place() -> void:
	var bp := player.get_block_position()
	_place_label.text = "The Deeps" if world.dimension \
		== WorldGenerator.DIM_DEEPS else "Overworld"
	if day_night != null:
		_clock_label.text = "%s  %s" % [day_night.clock_string(),
			"☾" if day_night.is_night() else "☀"]
	_biome_label.text = world.biome_name_at(bp)


## One line, and only when there is something to say. The mining progress bar
## replaces the prompt while a block is being broken, because that is the
## more urgent fact at that moment.
func _update_prompt() -> void:
	if interaction == null:
		_prompt.visible = false
		return
	var progress: float = interaction.break_progress
	if progress > 0.001:
		_prompt.visible = false
		_update_progress(progress)
		return
	_progress_bg.visible = false
	if not interaction.has_target:
		_prompt.visible = false
		return
	_prompt.visible = true
	_key_badge.visible = false
	_prompt_label.text = ContentDB.name_of(interaction.target_id)


func _update_progress(p: float) -> void:
	if _progress_bg == null:
		_progress_bg = PanelContainer.new()
		_progress_bg.add_theme_stylebox_override("panel",
			UiTheme.sunken())
		_progress_bg.custom_minimum_size = Vector2(180, 8)
		_progress_bg.set_anchors_preset(Control.PRESET_CENTER)
		_progress_bg.grow_horizontal = Control.GROW_DIRECTION_BOTH
		_progress_bg.grow_vertical = Control.GROW_DIRECTION_BOTH
		_progress_bg.offset_top = 22
		_progress_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_progress_bg)
		_progress_fill = ColorRect.new()
		_progress_fill.set_anchors_preset(Control.PRESET_FULL_RECT)
		_progress_bg.add_child(_progress_fill)
	_progress_bg.visible = true
	_progress_fill.anchor_right = clampf(p, 0.0, 1.0)
	_progress_fill.offset_right = 0.0
	_progress_fill.color = UiTheme.HUNGER


func _update_vitals() -> void:
	var hp: float = player.health
	var breath := interaction.breath() if interaction != null else -1.0
	_vitals.set_vitals(hp, player.max_health, breath, 10.0)


## Paint each slot with the block's real icon and mark the selected one.
## Reads the GLoot hotbar, so what is on screen is what the player is
## carrying; there is no second, invented item list to fall back to.
func _update_hotbar() -> void:
	var sel := -1
	if inventory != null and is_instance_valid(inventory):
		sel = inventory.selected
	for i in _hotbar_slots.size():
		var id := -1
		if inventory != null and is_instance_valid(inventory) \
				and i < inventory.hotbar.size():
			var held := inventory.hotbar[i].get_item()
			if held != null:
				id = PlayerInventory.block_id_of(
					held.get_prototype().get_id())
		var icon := _hotbar_icons[i]
		icon.set_block_internal(id)
		var slot := _hotbar_slots[i]
		if id <= 0:
			slot.modulate = Color(1, 1, 1, 1)
			_hotbar_counts[i].text = ""
		else:
			var n := inventory.count_of(id) if inventory != null else 1
			_hotbar_counts[i].text = str(n) if n > 1 else ""
		_style_slot(i, i == sel)


func _style_slot(index: int, selected: bool) -> void:
	var state := UiTheme.SlotState.IDLE
	if selected:
		state = UiTheme.SlotState.SELECTED
	elif index == _hovered_slot:
		state = UiTheme.SlotState.HOVER
	_hotbar_slots[index].add_theme_stylebox_override("panel",
		UiTheme.slot(state))
	# The selected slot lifts, so selection is readable without relying on a
	# colour difference alone.
	_hotbar_slots[index].position.y = -2.0 if selected else 0.0


func _set_hover(index: int) -> void:
	if _hovered_slot == index:
		return
	var sel := inventory.selected if inventory != null \
		and is_instance_valid(inventory) else -1
	if _hovered_slot >= 0:
		_style_slot(_hovered_slot, _hovered_slot == sel)
	_hovered_slot = index
	if index >= 0:
		_style_slot(index, index == sel)


func _draw_crosshair() -> void:
	# Drawn on the crosshair Control, not on this CanvasLayer, so the size
	# comes from the node that is actually painting.
	var c := _crosshair.size * 0.5
	var arm := 7.0
	var thick := 1.6
	var gap := 3.0
	var col := Color(1, 1, 1, 0.82)
	_crosshair.draw_line(c + Vector2(-arm, 0), c + Vector2(-gap, 0), col, thick)
	_crosshair.draw_line(c + Vector2(gap, 0), c + Vector2(arm, 0), col, thick)
	_crosshair.draw_line(c + Vector2(0, -arm), c + Vector2(0, -gap), col, thick)
	_crosshair.draw_line(c + Vector2(0, gap), c + Vector2(0, arm), col, thick)


# --- input ----------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		var mb := event as InputEventMouseButton
		# Iterate the hotbar's CHILDREN. `_hotbar` is an HBoxContainer, and a
		# Node is not iterable in GDScript -- `for slot in _hotbar` is a
		# compile error ("Unable to iterate on object of type
		# HBoxContainer"), not a silent no-op, so this whole function failed
		# to compile and mouse hotbar selection did nothing.
		for slot in _hotbar.get_children():
			if slot is Control and (slot as Control).get_global_rect() \
					.has_point(mb.position) and slot.has_meta("index"):
				select_slot(int(slot.get_meta("index")))
				return


## Called by main when a number key is pressed, and by a hotbar click.
func select_slot(i: int) -> void:
	if interaction != null:
		interaction.select_slot(i)


## Show the action prompt, e.g. "Talk to Bram the Farmer". Returns false if
## there is nobody to talk to.
func show_action_prompt(key: String, text: String) -> bool:
	if text == "":
		_prompt.visible = false
		return false
	_prompt.visible = true
	_key_badge.visible = true
	(_key_badge.get_child(0) as Label).text = key
	_prompt_label.text = text
	return true


func clear_action_prompt() -> void:
	if _key_badge.visible:
		_prompt.visible = false
		_key_badge.visible = false
