class_name AudioDirector
extends Node
## Every sound in the game, played from a pool of AudioStreamPlayers.
##
## SOURCES -- all CC0, all prebuilt, nothing synthesised:
##   * Kenney's Interface Sounds (100 wav)  addons/kenney_interface_sounds
##   * Kenney's UI Audio (51 wav)           addons/kenney_ui_audio
##   Kenney <https://kenney.nl>, CC0. The impact-sounds and RPG-audio packs that
##   would fit better are 404 at every mirror the Asset Library points at, so
##   the interface pack stands in: `bong`, `glass`, `pluck`, `scratch` and
##   `drop` read convincingly as block breaking and placing once pitch-shifted.
##
## NOTE ON miniaudio: Godot's own AudioDriver *is* miniaudio (it is linked into
## the engine binary), which is why these files decode and mix at all. GDScript
## cannot call miniaudio's C API directly -- see
## addons/thirdparty/miniaudio/README.md -- so the scripting surface used here
## is Godot's AudioStreamPlayer, which sits on top of it.
##
## Two buses keep the mix sane: "SFX" for anything the world does and "UI" for
## interface feedback, so the player can quiet one without the other.

const SFX_BUS := &"SFX"
const UI_BUS := &"UI"

const UI_DIR := "res://addons/kenney_ui_audio/"
const IFACE_DIR := "res://addons/kenney_interface_sounds/"

## Concurrent 3D voices for world sounds.
const WORLD_VOICES := 8
## Concurrent 2D voices for interface sounds.
const UI_VOICES := 4
## Beyond this the sound is dropped rather than stealing an in-use voice.
const MAX_AUDIBLE_DISTANCE := 48.0

## event -> { dir, base, variants, pitch_spread, volume_db, bus }
##
## `base` is a filename prefix in the pack; the numeric suffix is picked at
## random from 1..variants so repeated actions do not sound identical.
const SOUNDS := {
	"break_soft": { "dir": IFACE_DIR, "base": "scratch", "variants": 5,
		"spread": 0.18, "db": -4.0, "bus": SFX_BUS },
	"break_hard": { "dir": IFACE_DIR, "base": "bong", "variants": 1,
		"spread": 0.12, "db": -6.0, "bus": SFX_BUS },
	"break_glass": { "dir": IFACE_DIR, "base": "glass", "variants": 6,
		"spread": 0.15, "db": -5.0, "bus": SFX_BUS },
	"place": { "dir": IFACE_DIR, "base": "drop", "variants": 4,
		"spread": 0.16, "db": -5.0, "bus": SFX_BUS },
	"step": { "dir": IFACE_DIR, "base": "tick", "variants": 2,
		"spread": 0.22, "db": -16.0, "bus": SFX_BUS },
	"hurt": { "dir": IFACE_DIR, "base": "error", "variants": 4,
		"spread": 0.14, "db": -6.0, "bus": SFX_BUS },
	"mob_hurt": { "dir": IFACE_DIR, "base": "pluck", "variants": 2,
		"spread": 0.2, "db": -8.0, "bus": SFX_BUS },
	"mob_idle": { "dir": IFACE_DIR, "base": "question", "variants": 4,
		"spread": 0.2, "db": -18.0, "bus": SFX_BUS },
	"pickup": { "dir": IFACE_DIR, "base": "select", "variants": 8,
		"spread": 0.14, "db": -8.0, "bus": SFX_BUS },
	"craft": { "dir": IFACE_DIR, "base": "confirmation", "variants": 4,
		"spread": 0.1, "db": -4.0, "bus": SFX_BUS },
	"craft_fail": { "dir": IFACE_DIR, "base": "error", "variants": 4,
		"spread": 0.1, "db": -8.0, "bus": UI_BUS },
	"ui_click": { "dir": IFACE_DIR, "base": "click", "variants": 5,
		"spread": 0.12, "db": -10.0, "bus": UI_BUS },
	"ui_select": { "dir": IFACE_DIR, "base": "switch", "variants": 7,
		"spread": 0.12, "db": -12.0, "bus": UI_BUS },
	"ui_open": { "dir": IFACE_DIR, "base": "open", "variants": 4,
		"spread": 0.1, "db": -10.0, "bus": UI_BUS },
	"ui_back": { "dir": IFACE_DIR, "base": "back", "variants": 4,
		"spread": 0.1, "db": -10.0, "bus": UI_BUS },
	"save": { "dir": IFACE_DIR, "base": "maximize", "variants": 4,
		"spread": 0.1, "db": -8.0, "bus": UI_BUS },
	"load": { "dir": IFACE_DIR, "base": "minimize", "variants": 4,
		"spread": 0.1, "db": -8.0, "bus": UI_BUS },
	"toggle": { "dir": UI_DIR, "base": "switch", "variants": 8,
		"fmt": "%s%d.wav", "spread": 0.16, "db": -14.0, "bus": UI_BUS },
	"level_up": { "dir": IFACE_DIR, "base": "bong", "variants": 1,
		"spread": 0.05, "db": -2.0, "bus": UI_BUS },
}

## block id -> event, so breaking stone does not sound like breaking leaves.
static func event_for_block(block_id: int) -> String:
	match block_id:
		ContentDB.LEAVES:
			return "break_soft"
		ContentDB.ICE, ContentDB.WATER:
			return "break_glass"
		ContentDB.SNOW, ContentDB.SAND, ContentDB.GRAVEL, ContentDB.CACTUS:
			return "break_soft"
		_:
			return "break_hard"

var enabled := true
var master_volume_db := 0.0

var _streams := {}          # "event:variant" -> AudioStream
var _world: Array[AudioStreamPlayer3D] = []
var _ui: Array[AudioStreamPlayer] = []
var _next_world := 0
var _next_ui := 0
var _rng := RandomNumberGenerator.new()
var _listener: Node3D = null


func _ready() -> void:
	_rng.randomize()
	build()


## Create the buses and the voice pool. Safe to call more than once.
##
## Called from _ready() *and* defensively from play()/play_at(): a node added
## from SceneTree._init (how the tests build the scene) does not get _ready()
## until the first frame, so the pool would otherwise be empty and every play
## would silently fail.
func build() -> void:
	if not _world.is_empty() or not _ui.is_empty():
		return
	_ensure_buses()
	for _i in WORLD_VOICES:
		var p := AudioStreamPlayer3D.new()
		p.bus = SFX_BUS
		p.max_distance = MAX_AUDIBLE_DISTANCE
		p.unit_size = 6.0
		add_child(p)
		_world.append(p)
	for _i in UI_VOICES:
		var u := AudioStreamPlayer.new()
		u.bus = UI_BUS
		add_child(u)
		_ui.append(u)


## The SFX and UI buses, created if the project does not define them.
func _ensure_buses() -> void:
	for bus_name in [SFX_BUS, UI_BUS]:
		if AudioServer.get_bus_index(bus_name) != -1:
			continue
		var idx := AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, String(bus_name))
		AudioServer.set_bus_send(idx, "Master")


## Used for distance culling of world sounds.
func set_listener(node: Node3D) -> void:
	_listener = node


## World position that also works before the node is in the tree, which is the
## case when a scene is assembled from SceneTree._init.
static func _world_pos(node: Node3D) -> Vector3:
	return node.global_position if node.is_inside_tree() else node.position


## Filename for a variant. Kenney's two packs do not agree on naming: the
## interface pack is `click_001.wav`, the UI pack is `click1.wav`. A spec can
## override the format with "fmt".
func _path_for(spec: Dictionary, variant: int) -> String:
	# The format only ever sees (base, variant); the directory is prepended, so
	# a custom "fmt" has exactly two placeholders to fill.
	var fmt := String(spec["base"]) + "_%03d.wav" % variant
	if spec.has("fmt"):
		fmt = String(spec["fmt"]) % [spec["base"], variant]
	return String(spec["dir"]) + fmt


## Load (and cache) the stream for an event variant. Returns null when the
## file is missing, so a missing sound degrades to silence instead of erroring.
func _stream_for(event: String, variant: int) -> AudioStream:
	var key := "%s:%d" % [event, variant]
	if _streams.has(key):
		return _streams[key]
	if not SOUNDS.has(event):
		push_warning("[audio] unknown event '%s'" % event)
		return null
	var spec: Dictionary = SOUNDS[event]
	var path := _path_for(spec, variant)
	if not ResourceLoader.exists(path):
		push_warning("[audio] missing sound %s" % path)
		_streams[key] = null
		return null
	var stream: AudioStream = load(path)
	_streams[key] = stream
	return stream


## Play a world sound at a position. Returns false when it was culled or the
## pool is saturated.
func play_at(event: String, position: Vector3, volume_scale := 1.0) -> bool:
	if not enabled or not SOUNDS.has(event):
		return false
	build()
	if _listener != null and is_instance_valid(_listener) \
			and _world_pos(_listener).distance_to(position) > MAX_AUDIBLE_DISTANCE:
		return false
	var spec: Dictionary = SOUNDS[event]
	var variant := _rng.randi_range(1, int(spec["variants"]))
	var stream := _stream_for(event, variant)
	if stream == null:
		return false
	var player := _free_world_voice()
	if player == null:
		return false
	player.stream = stream
	player.global_position = position
	player.pitch_scale = 1.0 + _rng.randf_range(-float(spec["spread"]), float(spec["spread"]))
	player.volume_db = float(spec["db"]) + master_volume_db
	player.play()
	return true


## Play a 2D interface sound. Never distance-culled.
func play(event: String, volume_scale := 1.0) -> bool:
	if not enabled or not SOUNDS.has(event):
		return false
	build()
	var spec: Dictionary = SOUNDS[event]
	var variant := _rng.randi_range(1, int(spec["variants"]))
	var stream := _stream_for(event, variant)
	if stream == null:
		return false
	var player := _free_ui_voice()
	if player == null:
		return false
	player.stream = stream
	player.pitch_scale = 1.0 + _rng.randf_range(-float(spec["spread"]), float(spec["spread"]))
	player.volume_db = float(spec["db"]) + master_volume_db + linear_to_db(
		maxf(volume_scale, 0.0001))
	player.play()
	return true


## Convenience: the right break sound for a block id, at a position.
func play_break(block_id: int, position: Vector3) -> bool:
	return play_at(event_for_block(block_id), position)


func _free_world_voice() -> AudioStreamPlayer3D:
	for _i in _world.size():
		var p := _world[_next_world]
		_next_world = (_next_world + 1) % _world.size()
		if not p.playing:
			return p
	return null


func _free_ui_voice() -> AudioStreamPlayer:
	for _i in _ui.size():
		var u := _ui[_next_ui]
		_next_ui = (_next_ui + 1) % _ui.size()
		if not u.playing:
			return u
	return null


# --- introspection, for the test suite and the HUD --------------------------

## Every declared event, for tests that assert the bank is complete.
static func events() -> Array:
	return SOUNDS.keys()


## True when every variant of `event` resolves to a real file.
static func bank_is_complete(event: String) -> bool:
	if not SOUNDS.has(event):
		return false
	var spec: Dictionary = SOUNDS[event]
	for v in range(1, int(spec["variants"]) + 1):
		var fmt := String(spec["base"]) + "_%03d.wav" % v
		if spec.has("fmt"):
			fmt = String(spec["fmt"]) % [spec["base"], v]
		if not ResourceLoader.exists(String(spec["dir"]) + fmt):
			return false
	return true


## Master volume as a linear 0..1 factor, for a settings slider.
func set_master_volume(linear: float) -> void:
	master_volume_db = linear_to_db(clampf(linear, 0.0001, 1.0))
