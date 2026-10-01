class_name Persistence
extends System
## The owner of the save file and the backpack.
##
## `SaveGame` is a set of static functions and `SaveMigration` is a set of
## static functions, which between them are a perfectly good implementation
## with no *owner*: nothing knows which slot is current, nothing can be
## suspended when a save is in progress, and nothing can say whether a
## failure was survivable. This is the object that holds that state, and it is
## the thing every other system is allowed to ask "is the world saved?".
##
## The interesting part is not the writing, it is the **interruption**. A save
## is the one operation where being killed half way is most likely -- the
## player closed the game, the process was OOM-killed, the disk filled. The
## sequence is: seal the payload, copy the current slot to `.bak`, write to a
## temp file, rename over the slot. A crash at any point leaves either the old
## save or the new one, never half of each. `SaveMigration.write_with_backup`
## is what makes that true; the reason it is only reachable from here is that
## one place owns the policy.

## The slot F5 writes and F9 reads.
@export var slot := 1
## How many autosaves have been written this session, for the dev panel.
var autosaves := 0
## Set while a write is in progress, so a second request cannot interleave.
var busy := false

var inventory: PlayerInventory = null
var _last_result := {}


func _initialize() -> bool:
	if inventory == null or not is_instance_valid(inventory):
		# A persistence layer with no inventory still works for the world and
		# the player; it just cannot restore the backpack, and saying so is
		# better than a null dereference inside `deserialize`.
		last_error = "no inventory attached; the backpack will not be saved"
	return true


func describes() -> String:
	return "slot %d, %d autosave(s)" % [slot, autosaves]


# --- save -------------------------------------------------------------------

## Write the whole player state. Returns `{"ok": bool, "reason": String}` --
## a Result-shaped dictionary rather than a bool, because "the disk is full"
## and "the slot is out of range" are different problems and a caller that
## wants to react differently must be able to.
func save_to(p_slot := -1, player: Player = null, p_world: VoxelWorld = null,
		p_dimension := 0, engineering: Object = null) -> Dictionary:
	if busy:
		return {"ok": false, "reason": "a save is already in progress",
			"source": "", "slot": slot, "bytes": 0}
	busy = true
	var result: Dictionary = _write(p_slot, player, p_world, p_dimension, engineering)
	# GDScript has no `finally`, so the flag is cleared on the single exit
	# path. A save that left `busy` set would refuse every later save for the
	# rest of the session, which is the kind of bug that costs a player their
	# progress days later.
	busy = false
	_last_result = result
	return result


func _write(p_slot: int, player: Player, p_world: VoxelWorld,
		p_dimension: int, engineering: Object) -> Dictionary:
	# p_slot is an override, not a fallback: -1 means "the current slot".
	# Written the other way round, `save_to(6)` quietly overwrote slot 1 and
	# reported success -- the worst kind of save bug, because it looks fine.
	var target: int = slot if p_slot < 0 else p_slot
	var state := SaveGame.capture(player, inventory, p_world,
		p_dimension, engineering)
	state["version"] = SaveGame.SAVE_VERSION
	# A save without an engine version cannot be checked against the binary
	# that wrote it, and a world that silently half-loads is worse than a
	# world that refuses.
	state["engine"] = Engine.get_version_info().get("string", "")
	var why := SaveMigration.write_with_backup(target,
		SaveMigration.seal(state))
	if why != "":
		return {"ok": false, "reason": why, "source": "", "slot": target,
			"bytes": 0}
	slot = target
	autosaves += 1
	return {"ok": true, "reason": "", "slot": target,
		"bytes": JSON.stringify(state).length()}


## Restore. Returns the same shape, and reports which file it used -- reading
## the backup after a damaged slot is a recovery, and the player should be
## told their world came back.
func load_from(p_slot := -1, player: Player = null, p_world: VoxelWorld = null,
		engineering: Object = null) -> Dictionary:
	var target := slot if p_slot < 0 else p_slot
	# Every path returns the same keys. A caller that reads `source` to learn
	# whether the world came back from a backup must not get a KeyError when
	# the load failed instead -- that is the moment the answer matters most.
	var result := {"ok": false, "reason": "", "source": "", "migrated": []}
	var read := SaveMigration.read_resilient(target)
	if not bool(read["ok"]):
		result["reason"] = String(read["reason"])
		_last_result = result
		return _last_result
	var migrated := SaveMigration.migrate(read["data"])
	if not bool(migrated["ok"]):
		result["reason"] = String(migrated["reason"])
		_last_result = result
		return _last_result
	var applied := SaveGame.apply(migrated["data"], player, inventory,
		p_world, engineering)
	result["ok"] = applied
	result["reason"] = "" if applied else SaveGame.last_error
	result["source"] = String(read["source"])
	result["migrated"] = migrated["steps"]
	_last_result = result
	return _last_result


func last_result() -> Dictionary:
	return _last_result.duplicate()


## What is on disk right now, for the dev panel and for a bug report. Reads
## only metadata; it does not parse the whole world.
func slots() -> Array:
	var out: Array = []
	for i in range(SaveGame.FIRST_SLOT, SaveGame.LAST_SLOT + 1):
		out.append({
			"slot": i,
			"present": SaveGame.has_slot(i),
			"description": SaveGame.describe_slot(i),
			"current": i == slot,
		})
	return out
