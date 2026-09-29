class_name SaveMigration
extends RefCounted
## Save/load that survives a complex, long-lived world.
##
## A world file that only the current build can read is not save-safe. This
## module is the thing that makes it save-safe, and it does four jobs:
##
## 1. **Versioning with a real chain.** Every format change appends a
##    migration step. `migrate()` walks a v1 save forward to HEAD one step at
##    a time. Nothing is ever rewritten in place: a migration is a pure
##    function from old Dictionary to new Dictionary, so a bug in a step is
##    reproducible from a fixture rather than from a lost world.
##
## 2. **Forward compatibility is refusal, not guessing.** A save from a
##    *newer* build is left alone and reported. Guessing at a future format is
##    how a "harmless" load turns into silent world damage.
##
## 3. **Integrity.** Each slot carries a checksum over its payload. A file
##    that parses as JSON but is internally inconsistent -- truncated by a
##    full disk, spliced by a bad shutdown -- is detected rather than applied
##    halfway.
##
## 4. **A backup that is actually written before anything is overwritten.**
##    `write_slot` renames the previous file to `.bak` before committing the
##    new one, so there is always a known-good previous state to fall back to.
##    `load_slot` falls back to it automatically, and says so.

## The engineering section's schema version. This is the number that actually
## churns: the outer save envelope is stable, but what goes in it changes.
const ENGINEERING_SCHEMA := 2

## The ordered migration chain, keyed by the schema version it upgrades FROM.
## Entry N turns a section written under schema N into schema N+1.
## Each step takes (data: Dictionary) -> Dictionary and MUST return a new
## dictionary rather than mutating its input, so the same fixture can be run
## through the chain twice and give the same answer.
const STEPS := {
	1: "_v1_to_v2",
}


## Bring a whole save forward. Returns
## `{"ok": bool, "data": Dictionary, "steps": Array[String], "reason": String}`.
##
## The outer envelope is checked for forward compatibility and refused if it
## came from a newer build. The engineering section is then walked up the
## chain independently, because a world can sit unopened for a dozen updates
## and the section that churns fastest is the one that must not lose data.
static func migrate(raw: Dictionary) -> Dictionary:
	var envelope := int(raw.get("version", 0))
	if envelope > SaveGame.SAVE_VERSION:
		return {
			"ok": false, "data": {}, "steps": [],
			"reason": "save is version %d, this build understands %d; refusing to guess" \
				% [envelope, SaveGame.SAVE_VERSION],
		}
	var data := raw.duplicate(true)
	var applied: Array[String] = []
	var eng: Variant = data.get("engineering", null)
	if eng is Dictionary and not (eng as Dictionary).is_empty():
		var v := int((eng as Dictionary).get("schema", 1))
		# Bounded by the chain length as well as the target version, so a
		# mis-written step that fails to bump the schema cannot spin forever.
		var guard := 0
		while v < ENGINEERING_SCHEMA and guard < 32:
			guard += 1
			if not STEPS.has(v):
				return {
					"ok": false, "data": {}, "steps": applied,
					"reason": "no engineering migration path from schema %d" % v,
				}
			var before := v
			data = _v1_to_v2(data)
			var moved: Variant = data.get("engineering", null)
			if not (moved is Dictionary):
				break
			v = int((moved as Dictionary).get("schema", before))
			if v <= before:
				# The step did not advance the schema. Treat that as a hard
				# error rather than looping on a broken chain.
				return {
					"ok": false, "data": {}, "steps": applied,
					"reason": "migration step %d did not advance the schema" % before,
				}
			applied.append("engineering %d->%d" % [before, v])
	return {"ok": true, "data": data, "steps": applied, "reason": ""}


## The schema version currently on disk, or 1 for a pre-versioned section.
static func engineering_schema(data: Dictionary) -> int:
	var eng: Variant = data.get("engineering", null)
	if not (eng is Dictionary) or (eng as Dictionary).is_empty():
		return ENGINEERING_SCHEMA
	return int((eng as Dictionary).get("schema", 1))


# --- migration steps --------------------------------------------------------

## v1 -> v2. The engineering section gets an explicit schema stamp.
##
## The trap this step exists to avoid: a migration that *rewrites* the payload
## to whatever the newest shape happens to be will silently destroy any save
## whose data is already in a richer shape than the step understands. So the
## step is additive. A section that already carries the current graph is
## stamped and left exactly as it is; only the genuinely ancient flat form --
## a components Dictionary keyed by string, with no edges at all -- is
## converted, and that conversion is the only place a v1 factory could have
## lost its connections, which is why it is explicit about them.
static func _v1_to_v2(data: Dictionary) -> Dictionary:
	var out := data.duplicate(true)
	var eng: Dictionary = {}
	if out.get("engineering", null) is Dictionary:
		eng = (out["engineering"] as Dictionary).duplicate(true)
	if eng.is_empty():
		return out
	if eng.has("graph"):
		# Already the current shape. Stamp it and change nothing else.
		eng["schema"] = 2
		out["engineering"] = eng
		return out
	# The legacy flat form: components by string id, connections implied.
	var comps: Dictionary = {}
	var src: Dictionary = eng.get("components", {}) if eng.get("components", null) is Dictionary else {}
	var next_id := 1
	for key in src:
		var c: Dictionary = (src[key] as Dictionary).duplicate(true) if src[key] is Dictionary else {}
		if not c.has("node"):
			c["node"] = next_id
		next_id = maxi(next_id, int(c["node"]) + 1)
		c["label"] = String(c.get("label", c.get("component", "")))
		comps[str(c["node"])] = c
	var converted: Dictionary = eng.duplicate(true)
	converted["schema"] = 2
	converted["components"] = comps
	var edges: Variant = eng.get("connections", [])
	converted["connections"] = edges if edges is Array else []
	converted.set("revision", int(eng.get("revision", 0)))
	var bps: Variant = eng.get("blueprints", [])
	converted.set("blueprints", bps if bps is Array else [])
	converted.set("interaction_level", int(eng.get("interaction_level", 1)))
	out["engineering"] = converted
	return out


# --- integrity --------------------------------------------------------------

## A stable checksum over the payload. Not cryptographic -- it exists to catch
## a half-written or spliced file, not an attacker, and a cheap FNV-1a over
## canonical JSON is the right size for that job.
##
## The canonicalisation matters more than the hash. JSON has exactly one number
## type, so a payload written from a Godot Dictionary comes back from the parser
## with every integer as a float, and re-serialising it writes "0.0" where the
## file said "0". Hashing the raw serialisation would make every save fail its
## own integrity check. So the text is put through one JSON round trip first,
## which puts the in-memory and the on-disk forms into the same shape.
static func checksum(data: Dictionary) -> int:
	var copy := data.duplicate(true)
	copy.erase("checksum")
	var text := JSON.stringify(copy, "", true)
	var canonical: Variant = JSON.parse_string(text)
	if canonical is Dictionary:
		text = JSON.stringify(canonical, "", true)
	var h := 0x811c9dc5
	for b in text.to_utf8_buffer():
		h = (h ^ int(b)) & 0xffffffff
		h = (h * 0x01000193) & 0xffffffff
	return h


static func seal(data: Dictionary) -> Dictionary:
	var out := data.duplicate(true)
	# Stored as a string, not a number. JSON has one number type, so a 32-bit
	# hash comes back from the parser as a float and its re-serialisation
	# ("2598537386.0") no longer matches the bytes it was hashed from -- every
	# sealed file would fail its own integrity check. A string round-trips.
	out["checksum"] = str(checksum(out))
	return out


## "" when the payload is intact, otherwise why not.
static func verify(data: Dictionary) -> String:
	if not data.has("version"):
		return "no version field"
	if not data.has("checksum"):
		return "no checksum (pre-v2 write)"
	if String(data["checksum"]) != str(checksum(data)):
		return "checksum mismatch: the file is truncated or spliced"
	if not (data.get("player", {}) is Dictionary):
		return "player section is not a dictionary"
	if not (data.get("edits", {}) is Dictionary):
		return "edits section is not a dictionary"
	return ""


# --- slot files -------------------------------------------------------------

static func backup_path(slot: int) -> String:
	return SaveGame.slot_path(slot) + ".bak"


## Write with a backup of the previous contents taken first. Returns a reason
## string on failure, "" on success. The caller is expected to seal() before
## passing the data in.
static func write_with_backup(slot: int, sealed: Dictionary) -> String:
	var final_path := SaveGame.slot_path(slot)
	if FileAccess.file_exists(final_path):
		var prev := FileAccess.get_file_as_string(final_path)
		if not prev.is_empty():
			var b := FileAccess.open(backup_path(slot), FileAccess.WRITE)
			if b != null:
				b.store_string(prev)
				b.close()
	return "" if SaveGame.write_slot(slot, sealed) else SaveGame.last_error


## Read the newest readable file for a slot: the slot, else the backup. Returns
## `{"ok": bool, "data": Dictionary, "source": String, "reason": String}`.
## `source` is "slot" or "backup" so the caller can tell the player.
static func read_resilient(slot: int) -> Dictionary:
	for attempt in 2:
		var path := SaveGame.slot_path(slot) if attempt == 0 else backup_path(slot)
		if not FileAccess.file_exists(path):
			continue
		var text := FileAccess.get_file_as_string(path)
		if text.is_empty():
			continue
		var parsed: Variant = JSON.parse_string(text)
		if not (parsed is Dictionary):
			continue
		var data: Dictionary = parsed
		var why := verify(data)
		if why != "":
			continue
		return {"ok": true, "data": data,
			"source": "slot" if attempt == 0 else "backup", "reason": ""}
	return {"ok": false, "data": {},
		"source": "",
		"reason": "slot %d and its backup are both unreadable" % slot}
