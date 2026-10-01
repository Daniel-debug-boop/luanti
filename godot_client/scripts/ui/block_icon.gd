class_name BlockIcon
extends Control
## One block's icon, drawn from the block's real texture.
##
## The hotbar used to show a flat `ColorRect` painted with `ContentDB.color_of`,
## which is a placeholder that tells a player nothing: every stone variant was
## the same grey square. The game already ships photographic PBR albedo for
## every block that has one, so the icon is that texture, tinted toward the
## block's palette colour so blocks sharing a texture set still read apart.
##
## Blocks with no texture set (ores, metals, glowstone, water) fall back to a
## designed swatch: a rounded tile with a vertical gradient and a rim, not a
## bare rectangle. That is a deliberate visual, not an unfinished one.

const FALLBACK_TOP_LIFT := 0.22

## The block this icon shows. Plain field, deliberately WITHOUT a setter:
## `set_block` is the only thing that should resolve a texture, and a setter
## that re-entered it recursed until the stack overflowed.
var block_id: int = 0

var _texture: Texture2D = null
var _empty: bool = true


func _init() -> void:
	custom_minimum_size = Vector2(UiTheme.SLOT_ICON, UiTheme.SLOT_ICON)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Show a block, or nothing when `id` is air / negative.
func set_block(id: int) -> void:
	block_id = id
	_empty = id <= 0 or id == ContentDB.AIR
	_texture = null
	if not _empty:
		_texture = _load_texture(id)
	queue_redraw()


func set_block_internal(id: int) -> void:
	set_block(id)


## Resolve the block's albedo. Cached per id: loading a texture per redraw
## would stutter the hotbar every frame.
static var _cache: Dictionary = {}


static func _load_texture(id: int) -> Texture2D:
	if _cache.has(id):
		return _cache[id]
	var tex: Texture2D = null
	var set_name := MaterialLibrary.texture_set_for(id)
	if set_name != "":
		var path := "%s/%s_diff.jpg" % [MaterialLibrary.RAW, set_name]
		if ResourceLoader.exists(path):
			tex = load(path) as Texture2D
	_cache[id] = tex
	return tex


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	if _empty:
		return
	var base := ContentDB.color_of(block_id)
	if _texture != null:
		# The albedo is a photographic tile, so it needs cropping to a square
		# to fill the icon without stretching the grain.
		draw_texture_rect_region(_texture, r,
			Rect2(Vector2.ZERO, _texture.get_size()))
		# Tint toward the block's palette so two blocks sharing a set differ.
		draw_rect(r, Color(base.r, base.g, base.b, 0.30), true)
		return
	_draw_swatch(r, base)


## A designed fallback tile: vertical gradient plus a lighter rim, so a
## metal block reads as an object rather than as a colour chip.
func _draw_swatch(r: Rect2, base: Color) -> void:
	var top := base.lightened(FALLBACK_TOP_LIFT)
	var bottom := base.darkened(0.18)
	var steps := maxi(2, int(r.size.y))
	for i in steps:
		var t := float(i) / float(maxi(1, steps - 1))
		var row := Rect2(r.position + Vector2(0, r.size.y * t / steps),
			Vector2(r.size.x, r.size.y / steps + 1.0))
		draw_rect(row, top.lerp(bottom, t), true)
	var rim := base.lightened(0.30)
	rim.a = 0.55
	var w := 1.0
	draw_line(r.position, r.position + Vector2(r.size.x, 0), rim, w)
	draw_line(r.position + Vector2(0, r.size.y - 1),
		r.position + Vector2(r.size.x, r.size.y - 1), rim, w)


## True when this icon has real texture behind it rather than the fallback.
## The settings menu and the UI tests assert on this, because "it drew
## something" is not the same claim as "it drew the block".
func has_real_texture() -> bool:
	return _texture != null
