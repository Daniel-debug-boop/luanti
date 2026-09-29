class_name SaveGame
extends RefCounted
## Save/load for the whole player state: position, vitals, inventory, world
## edits and which dimension they were standing in.
##
## PREBUILT CHECK, as requested: the Asset Library was searched for save/load
## addons for Godot 4.4. The hits are generic resource serialisers aimed at
## editor tooling (Game State Saver Plugin, Easy Save Lite, SaveState) rather
## than a runtime player-state store, and Voxel Tools' own
## `VoxelStreamRegionFiles` -- which IS used, for the Voxel Tools backend --
## only persists voxel blocks, not the player. So the game-state container is
## hand-written; it is ~150 lines of JSON and deliberately boring.
##
## Format: one JSON file per slot under `user://saves/slot_N.json`, written
## atomically (temp file + rename) so a crash mid-write cannot corrupt a save.

const SAVE_DIR := "user://saves"
const SLOT_PREFIX := "slot_"
const SLOT_SUFFIX := ".json"
const SAVE_VERSION := 1
const FIRST_SLOT := 1
const LAST_SLOT := 8

## Why the last save/load/delete call failed, or "" after a success. Static
## because every operation on this class is static.
static var last_error := ""


static func dimension_name(dimension: int) -> String:
	match dimension:
		WorldGenerator.DIM_DEEPS:
			return "The Deeps"
		_:
			return "Overworld"


static func slot_path(slot: int) -> String:
	return SAVE_DIR.path_join("%s%d%s" % [SLOT_PREFIX, slot, SLOT_SUFFIX])


static func has_slot(slot: int) -> bool:
	return FileAccess.file_exists(slot_path(slot))


## Slots that currently hold a save, ascending.
static func list_slots() -> Array[int]:
	var out: Array[int] = []
	for i in range(FIRST_SLOT, LAST_SLOT + 1):
		if has_slot(i):
			out.append(i)
	return out


static func delete_slot(slot: int) -> bool:
	last_error = ""
	if not has_slot(slot):
		last_error = "no save in slot %d" % slot
		return false
	var err := DirAccess.remove_absolute(ProjectSettings.globalize_path(slot_path(slot)))
	if err != OK:
		last_error = "could not delete slot %d (error %d)" % [slot, err]
		return false
	return true


## A one-line summary for the load menu, or "" when the slot is empty/unreadable.
static func describe_slot(slot: int) -> String:
	var data := load_slot(slot)
	if data.is_empty():
		return ""
	var player: Dictionary = data.get("player", {})
	var pos: Array = player.get("position", [0, 0, 0])
	return "v%d · %.0f, %.0f, %.0f · %s" % [
		int(data.get("version", 0)),
		float(pos[0]), float(pos[1]), float(pos[2]),
		dimension_name(int(data.get("dimension", 0))),
	]


# --- writing ----------------------------------------------------------------

## Gather the live game state into a saveable Dictionary.
static func capture(player: Player, inv: PlayerInventory, world: VoxelWorld,
		dimension: int, engineering: EngEngineering = null) -> Dictionary:
	var state := {
		"version": SAVE_VERSION,
		"dimension": dimension,
		"player": {},
		"inventory": {},
		"edits": {},
		"engineering": {},
	}
	if player != null and is_instance_valid(player):
		state["player"] = {
			"position": [player.position.x, player.position.y, player.position.z],
			"health": player.health,
			"max_health": player.max_health,
			"flying": player.flying,
		}
	if inv != null and is_instance_valid(inv):
		state["inventory"] = inv.serialize()
	if world != null and is_instance_valid(world):
		state["edits"] = world.edits_snapshot()
	# The engineering section is optional and additive: a save made before the
	# system existed simply has none, and loading it is not an error. The
	# section is versioned separately from the world save so a world format
	# change never invalidates a factory, or the other way round.
	if engineering != null and is_instance_valid(engineering):
		state["engineering"] = engineering.serialize()
	return state


## Write a state Dictionary to a slot. Returns false on any I/O failure.
static func write_slot(slot: int, state: Dictionary) -> bool:
	last_error = ""
	if slot < FIRST_SLOT or slot > LAST_SLOT:
		last_error = "slot %d out of range %d..%d" % [slot, FIRST_SLOT, LAST_SLOT]
		return false
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(SAVE_DIR)):
		var mk := DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path(SAVE_DIR))
		if mk != OK:
			last_error = "could not create %s (error %d)" % [SAVE_DIR, mk]
			return false
	var final_path := slot_path(slot)
	var tmp_path := final_path + ".tmp"
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		last_error = "could not open %s for writing (error %d)" \
			% [tmp_path, FileAccess.get_open_error()]
		return false
	f.store_string(JSON.stringify(state, "\t"))
	f.close()
	# Rename over the old save so a partial write never lands in the real slot.
	var err := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(tmp_path),
		ProjectSettings.globalize_path(final_path))
	if err != OK:
		last_error = "could not commit slot %d (error %d)" % [slot, err]
		return false
	return true


## Capture and write in one step.
static func save_game(slot: int, player: Player, inv: PlayerInventory,
		world: VoxelWorld, dimension: int,
		engineering: EngEngineering = null) -> bool:
	return write_slot(slot, capture(player, inv, world, dimension, engineering))


# --- reading ----------------------------------------------------------------

## Read a slot. Returns {} when the slot is empty, unreadable, not JSON, or
## from a newer version than this build understands.
static func load_slot(slot: int) -> Dictionary:
	last_error = ""
	var path := slot_path(slot)
	if not FileAccess.file_exists(path):
		last_error = "slot %d is empty" % slot
		return {}
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		last_error = "slot %d is empty on disk" % slot
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		last_error = "slot %d is not valid JSON" % slot
		return {}
	var data: Dictionary = parsed
	var version := int(data.get("version", 0))
	if version > SAVE_VERSION:
		last_error = "slot %d was written by a newer version (%d > %d)" \
			% [slot, version, SAVE_VERSION]
		return {}
	return data


## Apply a loaded state back onto the live objects. Returns false when the
## payload is too malformed to apply; individual sections that fail to apply
## are skipped rather than aborting the whole load, so one bad subsystem cannot
## cost the player everything else.
static func apply(data: Dictionary, player: Player, inv: PlayerInventory,
		world: VoxelWorld, engineering: EngEngineering = null) -> bool:
	last_error = ""
	if data.is_empty():
		last_error = "nothing to load"
		return false
	var applied := 0

	if world != null and is_instance_valid(world) and typeof(data.get("edits")) == TYPE_DICTIONARY:
		world.apply_edits_snapshot(data["edits"])
		applied += 1

	if inv != null and is_instance_valid(inv) and typeof(data.get("inventory")) == TYPE_DICTIONARY:
		if inv.deserialize(data["inventory"]):
			applied += 1
		else:
			last_error += "inventory could not be restored; "

	if player != null and is_instance_valid(player) and typeof(data.get("player")) == TYPE_DICTIONARY:
		var p: Dictionary = data["player"]
		if p.get("position") is Array and (p["position"] as Array).size() == 3:
			var a: Array = p["position"]
			player.position = Vector3(float(a[0]), float(a[1]), float(a[2]))
		player.max_health = float(p.get("max_health", player.max_health))
		player.health = clampf(float(p.get("health", player.max_health)),
			0.0, player.max_health)
		player.flying = bool(p.get("flying", player.flying))
		applied += 1

	# Engineering state is restored last, and is never counted as a failure on
	# its own: a world with no engineering section is a perfectly good world.
	if engineering != null and is_instance_valid(engineering) \
			and typeof(data.get("engineering")) == TYPE_DICTIONARY \
			and not (data["engineering"] as Dictionary).is_empty():
		engineering.deserialize(data["engineering"])
		applied += 1

	if applied == 0:
		last_error += "no section could be applied"
		return false
	return true


## Load a slot and apply it.
static func load_game(slot: int, player: Player, inv: PlayerInventory,
		world: VoxelWorld, engineering: EngEngineering = null) -> bool:
	var data := load_slot(slot)
	if data.is_empty():
		return false
	return apply(data, player, inv, world, engineering)


static func dimension_of(data: Dictionary) -> int:
	return int(data.get("dimension", WorldGenerator.DIM_OVERWORLD))
