class_name UiTheme
extends RefCounted
## The design system. Every player-facing surface draws its numbers from
## here, so spacing, type size and colour stay consistent instead of each
## panel inventing its own.
##
## Everything is authored against a 1280x720 design viewport and the project
## uses `canvas_items` stretch, so these values scale with the window
## automatically. Sizes are therefore "design pixels", not screen pixels, and
## nothing here should be multiplied by a resolution factor.
##
## Player-facing surfaces use these tokens. Developer diagnostics do NOT --
## see `DebugOverlay`, which is deliberately allowed to look like a tool.

# --- Colour ---------------------------------------------------------------
## Surfaces. Two depths: a floating card, and the sunken well a slot sits in.
const SURFACE := Color(0.055, 0.065, 0.086, 0.88)
const SURFACE_RAISED := Color(0.094, 0.110, 0.145, 0.94)
const SURFACE_SUNKEN := Color(0.031, 0.037, 0.051, 0.92)

## Hairlines. Quiet by default; they carry state, not decoration.
const BORDER := Color(0.42, 0.48, 0.58, 0.30)
const BORDER_STRONG := Color(0.60, 0.68, 0.80, 0.55)

## Type. Four steps, used for four jobs. No ad-hoc sizes.
const TEXT := Color(0.94, 0.96, 0.99)
const TEXT_MUTED := Color(0.68, 0.73, 0.82)
const TEXT_FAINT := Color(0.50, 0.55, 0.64)

## One accent, used only for what is selected, focused or actionable.
const ACCENT := Color(0.42, 0.74, 1.00)
const ACCENT_DIM := Color(0.26, 0.44, 0.62)

## Semantic.
const HEALTH := Color(0.91, 0.27, 0.33)
const HEALTH_EMPTY := Color(0.26, 0.13, 0.16, 0.85)
const HUNGER := Color(0.95, 0.72, 0.30)
const AIR := Color(0.45, 0.78, 0.95)
const DANGER := Color(0.95, 0.42, 0.38)
const GOOD := Color(0.44, 0.85, 0.52)

# --- Spacing --------------------------------------------------------------
## A 4px grid. Every margin, gap and inset is one of these, or a sum of them.
const SPACE_1 := 4
const SPACE_2 := 8
const SPACE_3 := 12
const SPACE_4 := 16
const SPACE_6 := 24
const SPACE_8 := 32

## Distance from a screen edge to any anchored panel.
const SCREEN_MARGIN := 20

# --- Type scale -----------------------------------------------------------
## micro: keycaps, counts. body: default. subtitle: panel headings.
## title: the one number a player should notice first.
const SIZE_MICRO := 11
const SIZE_BODY := 14
const SIZE_SUBTITLE := 17
const SIZE_TITLE := 22

# --- Metrics --------------------------------------------------------------
const RADIUS := 6
const RADIUS_SMALL := 4
const BORDER_WIDTH := 1
const SLOT_SIZE := 52
## The hotbar is the densest element on screen, but its gap is still a token
## off the shared scale rather than a number tuned by eye.
const SLOT_GAP := SPACE_2
const SLOT_ICON := 34


## A card: the default container for a floating group of readouts.
static func panel(border := BORDER, radius := RADIUS) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = SURFACE
	sb.border_color = border
	sb.set_border_width_all(BORDER_WIDTH)
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(SPACE_3)
	return sb


## The well a slot or swatch sits in, so icons read against a recess rather
## than floating on the card.
static func sunken(border := BORDER) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = SURFACE_SUNKEN
	sb.border_color = border
	sb.set_border_width_all(BORDER_WIDTH)
	sb.set_corner_radius_all(RADIUS_SMALL)
	return sb


## A slot in its three real states. Selection is carried by the border and a
## lift, not by a colour flood, so the item icon stays readable.
static func slot(state: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	match state:
		SlotState.SELECTED:
			sb.bg_color = SURFACE_RAISED
			sb.border_color = ACCENT
			sb.set_border_width_all(2)
		SlotState.HOVER:
			sb.bg_color = SURFACE_RAISED
			sb.border_color = BORDER_STRONG
			sb.set_border_width_all(2)
		_:
			sb.bg_color = SURFACE_SUNKEN
			sb.border_color = BORDER
			sb.set_border_width_all(BORDER_WIDTH)
	sb.set_corner_radius_all(RADIUS_SMALL)
	return sb


enum SlotState { IDLE, HOVER, SELECTED }


## A button in its states. Godot's default button art is a grey box; this is
## a real control with a hover, a pressed state and a disabled one.
static func button(state: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	match state:
		ButtonState.PRESSED:
			sb.bg_color = ACCENT_DIM
			sb.border_color = ACCENT
		ButtonState.HOVER:
			sb.bg_color = SURFACE_RAISED
			sb.border_color = BORDER_STRONG
		ButtonState.DISABLED:
			sb.bg_color = SURFACE
			sb.border_color = Color(BORDER.r, BORDER.g, BORDER.b, 0.15)
		_:
			sb.bg_color = SURFACE
			sb.border_color = BORDER
	sb.set_border_width_all(BORDER_WIDTH)
	sb.set_corner_radius_all(RADIUS_SMALL)
	sb.set_content_margin_all(SPACE_2)
	return sb


enum ButtonState { NORMAL, HOVER, PRESSED, DISABLED }


## Build a label already styled to the scale, so callers never pass a raw
## font size and the hierarchy cannot drift.
static func label(text: String, role: int = 0,
		colour := TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", colour)
	match role:
		Role.TITLE:
			l.add_theme_font_size_override("font_size", SIZE_TITLE)
		Role.SUBTITLE:
			l.add_theme_font_size_override("font_size", SIZE_SUBTITLE)
		Role.MICRO:
			l.add_theme_font_size_override("font_size", SIZE_MICRO)
		_:
			l.add_theme_font_size_override("font_size", SIZE_BODY)
	return l


enum Role { BODY, TITLE, SUBTITLE, MICRO }


## A small pill for a keycap or a count. Used for hotkey numbers, stack
## counts and the "E" in a prompt.
static func badge(text: String, colour := TEXT_MUTED) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.45)
	sb.border_color = Color(border_colour_of(colour).r,
		border_colour_of(colour).g, border_colour_of(colour).b, 0.5)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(3)
	sb.set_content_margin_all(2)
	p.add_theme_stylebox_override("panel", sb)
	var l := label(text, Role.MICRO, colour)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	p.add_child(l)
	return p


static func border_colour_of(c: Color) -> Color:
	return Color(c.r, c.g, c.b, 1.0)


## A full-screen dimmer behind a modal, so a menu reads as modal rather than
## as a panel that happens to be on screen.
static func scrim() -> ColorRect:
	var r := ColorRect.new()
	r.color = Color(0.02, 0.025, 0.035, 0.72)
	r.set_anchors_preset(Control.PRESET_FULL_RECT)
	r.mouse_filter = Control.MOUSE_FILTER_STOP
	return r
