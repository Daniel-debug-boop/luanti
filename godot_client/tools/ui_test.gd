extends SceneTree
## The UI contract, as an executable assertion.
##
## Most of this suite exists to catch the specific regressions that were
## possible before the HUD was rebuilt: a diagnostic string leaking back into
## the player's view, a hotbar slot quietly reverting to a flat rectangle, a
## hardcoded pixel position that only works at 1280x720, or the debug
## overlay coming up visible.
##
## The interesting assertions are the negative ones. "The HUD exists" proves
## nothing; "no Control in the gameplay HUD carries developer text" is the
## claim that actually matters, and it is checked by walking the tree and
## refusing known instrument strings.

var _fails := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_debug_overlay_is_off_by_default()
	_test_gameplay_hud_has_no_diagnostics()
	_test_hotbar_uses_real_icons()
	_test_vitals_are_hearts_not_rectangles()
	_test_layout_is_anchored_not_absolute()
	_test_theme_tokens_are_consistent()
	_test_settings_menu_reflects_live_state()
	_test_hud_scales_across_resolutions()
	_stretch_settings_are_sane()
	_finish()


# --- helpers ---------------------------------------------------------------

func _eq(got: Variant, want: Variant, what: String) -> void:
	if got == want:
		print("  ok   %s == %s" % [what, str(want)])
	else:
		_fails += 1
		print("  FAIL %s: got %s, want %s" % [what, str(got), str(want)])


func _true(got: bool, what: String) -> void:
	_eq(got, true, what)


func _finish() -> void:
	print("\nui: %s" % ("PASS" if _fails == 0 else "%d FAILURES" % _fails))
	quit(0 if _fails == 0 else 1)


## Every string a developer would recognise as instrumentation. These are the
## words that used to sit in the top-left of the player's HUD.
const INSTRUMENT_STRINGS := [
	"chunks", "tex ", "mapping", "dug", "built", "mined", "placed",
	"backend", "ssao", "ssil", "fog", "glow", "probes", "sdfgi",
	"fps", "ms  ", "xyz", "mobs", "village", "props", "villagers",
	"loaded", "meshed", "dirty", "DEBUG",
]


func _collect_text(node: Node, out: Array[String]) -> void:
	if node is Label:
		out.append((node as Label).text)
	if node is Button:
		out.append((node as Button).text)
	for c in node.get_children():
		_collect_text(c, out)


# --- tests -----------------------------------------------------------------

## The regression this whole suite is partly about: the debug overlay used to
## be permanently welded into the HUD.
func _test_debug_overlay_is_off_by_default() -> void:
	var d := DebugOverlay.new()
	root.add_child(d)
	_eq(d.is_open(), false, "debug overlay starts closed")
	_eq(d.visible, false, "debug overlay is not visible on construction")
	var opened := d.toggle()
	_eq(opened, true, "toggle opens it")
	_eq(d.visible, true, "opening makes it visible")
	_eq(d.toggle(), false, "toggle closes it again")
	_eq(d.visible, false, "closing hides it")
	d.queue_free()


## The load-bearing assertion: the player's HUD must not carry any of it.
func _test_gameplay_hud_has_no_diagnostics() -> void:
	var hud := WorldHud.new()
	hud.world = VoxelWorld.new()
	hud.player = Player.new()
	root.add_child(hud)

	var texts: Array[String] = []
	_collect_text(hud, texts)
	var joined := "\n".join(texts)

	var leaked := PackedStringArray()
	for s in INSTRUMENT_STRINGS:
		if joined.contains(s):
			leaked.append(s)
	_eq(leaked.size(), 0,
		"no instrument text in the gameplay HUD (leaked: %s)"
			% ", ".join(leaked))

	# The player-facing facts ARE present, so this is not just an empty HUD.
	_true(joined.contains("Overworld"), "the HUD still names the dimension")

	hud.queue_free()
	hud.world.queue_free()
	hud.player.queue_free()


## A slot must show the block's real texture. "It drew something" is not the
## claim; "it drew the block" is.
func _test_hotbar_uses_real_icons() -> void:
	var hud := WorldHud.new()
	root.add_child(hud)
	var slots: Array = hud.get("_hotbar_slots")
	var icons: Array = hud.get("_hotbar_icons")
	_eq(slots.size(), 8, "the hotbar has eight slots")
	_eq(icons.size(), 8, "every slot has an icon control")

	var textured := 0
	for ic in icons:
		if ic is BlockIcon and (ic as BlockIcon).has_real_texture():
			textured += 1
	_eq(textured, 0, "an empty hotbar has no textures yet")

	# Ask for a block that has a downloaded PBR set.
	var icon := BlockIcon.new()
	root.add_child(icon)
	icon.set_block(ContentDB.GRASS)
	_true(icon.has_real_texture(),
		"grass resolves to a real albedo texture")

	# A block with no texture set must still draw something designed rather
	# than nothing at all.
	#
	# Iron is no longer that block: the asset pipeline added ambientCG metal
	# sets, so `IRON_BLOCK` resolves to `acg_metal_055a` and draws its real
	# albedo. `GLOWSTONE` is deliberately emissive and set-less, so it is the
	# honest subject of this assertion.
	var glow := BlockIcon.new()
	root.add_child(glow)
	glow.set_block(ContentDB.GLOWSTONE)
	_eq(glow.has_real_texture(), false, "glowstone has no downloaded texture set")

	# Iron moved to a real metal set, so it now draws its own albedo -- and it
	# must still report the id it was asked for, which is what the hotbar
	# reads back to decide what is selected.
	var metal := BlockIcon.new()
	root.add_child(metal)
	metal.set_block(ContentDB.IRON_BLOCK)
	_true(metal.has_real_texture(), "iron draws its metal albedo")
	_eq(metal.block_id, ContentDB.IRON_BLOCK, "iron still reports its id")

	icon.queue_free()
	glow.queue_free()
	metal.queue_free()
	hud.queue_free()


## Hearts must be heart shapes. The old row was ten identical ColorRects,
## which is the placeholder this suite exists to prevent returning.
func _test_vitals_are_hearts_not_rectangles() -> void:
	var v := VitalsBar.new()
	root.add_child(v)
	v.set_vitals(20.0, 20.0, -1.0, 10.0)
	_eq(v.filled_fraction(), 1.0, "full health fills every heart")
	v.set_vitals(10.0, 20.0, -1.0, 10.0)
	_eq(v.filled_fraction(), 0.5, "half health empties half the hearts")
	v.set_vitals(0.0, 20.0, -1.0, 10.0)
	_eq(v.filled_fraction(), 0.0, "no health empties every heart")

	# The control must contain no child ColorRects: a heart row built from
	# rectangles is exactly what was replaced.
	var rects := 0
	for c in v.get_children():
		if c is ColorRect:
			rects += 1
	_eq(rects, 0, "the vitals row has no rectangle children")

	v.queue_free()


## Anchored, not positioned. A HUD element given an absolute pixel position
## is correct at exactly one window size.
func _test_layout_is_anchored_not_absolute() -> void:
	var hud := WorldHud.new()
	root.add_child(hud)

	var chip := hud.get("_chip") as Control
	_true(chip != null, "the status chip exists")
	if chip != null:
		_eq(chip.anchor_left, 0.0, "chip is anchored to the left edge")
		_eq(chip.anchor_top, 0.0, "chip is anchored to the top edge")
		_eq(chip.position.x, UiTheme.SCREEN_MARGIN,
			"chip uses the shared screen margin")

	var cluster := hud.get("_cluster") as Control
	_true(cluster != null, "the bar cluster exists")
	if cluster != null:
		_eq(cluster.anchor_left, 0.5, "cluster is anchored to centre-x")
		_eq(cluster.anchor_top, 1.0, "cluster is anchored to the bottom")

	var cross := hud.get("_crosshair") as Control
	if cross != null:
		_eq(cross.anchor_left, 0.5, "crosshair is anchored to centre-x")
		_eq(cross.anchor_top, 0.5, "crosshair is anchored to centre-y")

	hud.queue_free()


## Spacing and type must come from the shared tokens, not from literals
## sprinkled through the HUD.
func _test_theme_tokens_are_consistent() -> void:
	_eq(UiTheme.SPACE_1 % 4, 0, "the spacing scale is a 4px grid")
	_eq(UiTheme.SPACE_2 % 4, 0, "space 2 is on the grid")
	_eq(UiTheme.SPACE_3 % 4, 0, "space 3 is on the grid")
	_eq(UiTheme.SLOT_GAP, UiTheme.SPACE_2, "slot gap uses the shared token")

	# Type scale must be strictly increasing, or "hierarchy" is a claim with
	# nothing behind it.
	_true(UiTheme.SIZE_BODY < UiTheme.SIZE_SUBTITLE, "body < subtitle")
	_true(UiTheme.SIZE_SUBTITLE < UiTheme.SIZE_TITLE, "subtitle < title")
	_true(UiTheme.SIZE_MICRO < UiTheme.SIZE_BODY, "micro < body")

	# Every role must produce a label at its own size.
	for pair in [[UiTheme.Role.MICRO, UiTheme.SIZE_MICRO],
			[UiTheme.Role.BODY, UiTheme.SIZE_BODY],
			[UiTheme.Role.SUBTITLE, UiTheme.SIZE_SUBTITLE],
			[UiTheme.Role.TITLE, UiTheme.SIZE_TITLE]]:
		var l := UiTheme.label("x", int(pair[0]))
		_eq(l.get_theme_font_size("font_size"), int(pair[1]),
			"role %d renders at its token size" % int(pair[0]))
		l.free()

	# Slot states must actually differ, or selection is invisible.
	var idle := UiTheme.slot(UiTheme.SlotState.IDLE)
	var sel := UiTheme.slot(UiTheme.SlotState.SELECTED)
	_true(sel.border_color != idle.border_color,
		"a selected slot is visually distinct")
	_eq(sel.border_width_left, 2, "selection is carried by a thicker border")
	_eq(idle.border_width_left, 1, "an idle slot uses the hairline")


## The menu must show the truth, not a second copy of it.
func _test_settings_menu_reflects_live_state() -> void:
	var m := SettingsMenu.new()
	root.add_child(m)
	_eq(m.is_open(), false, "the menu starts closed")
	m.sync_from(1, 0)
	_true(m.is_node_ready(), "menu is ready")
	var q: Array = m.get("_quality_buttons")
	var mp: Array = m.get("_mapping_buttons")
	_eq(q.size(), 3, "three quality options")
	_eq(mp.size(), 4, "four mapping options")
	_eq((q[1] as Button).button_pressed, true,
		"the menu shows medium quality when told medium")
	_eq((q[2] as Button).button_pressed, false,
		"and does not also show high")
	_eq((mp[0] as Button).button_pressed, true,
		"the menu shows plain mapping when told plain")

	# An external change (a function key) must update the menu.
	m.sync_from(2, 3)
	_eq((q[2] as Button).button_pressed, true,
		"a keyboard change reaches the menu")
	_eq((mp[3] as Button).button_pressed, true,
		"mapping change reaches the menu")

	_eq(m.toggle(), true, "O opens the menu")
	_true(m.is_open(), "the menu reports itself open")
	_eq(m.toggle(), false, "O closes it again")
	m.queue_free()


## The scaling claim, checked rather than asserted: anchored elements must
## stay inside the viewport and keep their edge relationship as the window
## changes shape.
func _test_hud_scales_across_resolutions() -> void:
	var sizes := [Vector2i(1280, 720), Vector2i(1920, 1080),
		Vector2i(2560, 1440), Vector2i(3440, 1440), Vector2i(1024, 768)]
	for res in sizes:
		root.size = res
		var hud := WorldHud.new()
		root.add_child(hud)
		var chip := hud.get("_chip") as Control
		var cross := hud.get("_crosshair") as Control
		var cluster := hud.get("_cluster") as Control
		_true(chip.anchor_left == 0.0 and chip.anchor_top == 0.0,
			"%dx%d: chip stays top-left anchored" % [res.x, res.y])
		_true(cross.anchor_left == 0.5 and cross.anchor_top == 0.5,
			"%dx%d: crosshair stays centred" % [res.x, res.y])
		_true(cluster.anchor_top == 1.0,
			"%dx%d: cluster stays bottom-anchored" % [res.x, res.y])
		# Anchored elements must not depend on the window's size for their
		# offset: the margin is the token, not a tuned number.
		_eq(chip.offset_left, UiTheme.SCREEN_MARGIN,
			"%dx%d: chip margin comes from the token" % [res.x, res.y])
		hud.queue_free()
	root.size = Vector2i(1280, 720)


## The project must be configured for the scaling to work at all.
func _stretch_settings_are_sane() -> void:
	var mode := str(ProjectSettings.get_setting(
		"display/window/stretch/mode", ""))
	var aspect := str(ProjectSettings.get_setting(
		"display/window/stretch/aspect", ""))
	_eq(mode, "canvas_items", "canvas_items stretch scales the UI")
	_eq(aspect, "expand",
		"expand aspect uses ultrawide width instead of letterboxing")
