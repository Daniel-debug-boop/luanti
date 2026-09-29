class_name Threading
extends RefCounted
## The threading rules, and the check that keeps them.
##
## EMERGENT is single-threaded by decision, not by accident. Godot's scene tree,
## physics servers and rendering servers are all main-thread objects; touching
## one from a worker is undefined behaviour that usually manifests as a
## corrupted node three frames later, somewhere unrelated. The temptation with
## a voxel world and a 10 Hz network simulation is to move the simulation to a
## worker, and that is exactly the change this file exists to make hard.
##
## The rule:
##
##   * **The main thread owns the world.** `VoxelWorld`, `EngGraph`, the
##     scene tree, the physics server and every `Node` may be read and written
##     only from the main thread.
##
##   * **A worker may do pure computation.** Given immutable inputs, a worker
##     may return a value: a mesh's vertex buffer, a path, a hash, a chunk of
##     generated noise. That is the whole escape hatch, and it is enough.
##
##   * **A worker may not touch the scene tree to hand the result over.** It
##     returns the value; the main thread applies it on its own tick.
##
## `guard()` is called by the mutators that matter, records a typed violation
## when it is called from anywhere else, and costs one integer comparison when
## it is not. It does not crash the game: a violation during development
## should produce a report you can read, not a hard failure that loses the
## player's factory.

## Classes whose state may only be touched from the main thread. Enumerated
## rather than derived, because the point is to be a short list a reviewer can
## hold in their head.
const MAIN_THREAD_ONLY := [
	"VoxelWorld", "VoxelBlock", "WorldGenerator", "ChunkFiles",
	"EngGraph", "EngSimulation", "EngEngineering", "PlayerInventory",
	"SaveGame", "SaveMigration", "NetAuthority",
]

## Kinds of violation `guard()` can record.
const VIOLATION_MUTATION := "mutation"
const VIOLATION_SCENE_TREE := "scene_tree"

static var _violations: Array[Dictionary] = []
static var _enabled := true
static var _max_recorded := 64


static func main_thread_id() -> int:
	return OS.get_main_thread_id()


static func caller_id() -> int:
	return OS.get_thread_caller_id()


static func is_main_thread() -> bool:
	return caller_id() == main_thread_id()


## Turn the check off. Off in a shipped build where the cost of a false
## positive is higher than the value of the report.
static func set_enabled(on: bool) -> void:
	_enabled = on
	if not on:
		_violations.clear()


static func is_enabled() -> bool:
	return _enabled


## Check that the caller is allowed to do what it is about to do.
##
## `what` names the operation, for the report. `needs_main_thread` is false
## for the pure-computation escape hatch -- a worker computing a mesh buffer
## is doing this deliberately, and flagging it would teach people to ignore
## the report.
static func guard(what: String, needs_main_thread := true) -> bool:
	if not _enabled or not needs_main_thread:
		return true
	if is_main_thread():
		return true
	record(VIOLATION_MUTATION, what)
	return false


## Check that something about to happen is allowed to touch the scene tree.
static func guard_scene_tree(what: String) -> bool:
	if not _enabled:
		return true
	if is_main_thread():
		return true
	record(VIOLATION_SCENE_TREE, what)
	return false


static func record(kind: String, what: String) -> void:
	if _violations.size() < _max_recorded:
		_violations.append({
			"kind": kind,
			"what": what,
			"thread": caller_id(),
			"main": main_thread_id(),
		})


static func violations() -> Array[Dictionary]:
	return _violations


static func violation_count() -> int:
	return _violations.size()


static func clear() -> void:
	_violations.clear()


static func report() -> String:
	if _violations.is_empty():
		return "threading: OK (no off-thread mutations)"
	var lines := PackedStringArray()
	lines.append("threading: %d violation(s)" % _violations.size())
	for v in _violations:
		lines.append("  [%s] '%s' from thread %d (main is %d)" % [
			v["kind"], v["what"], int(v["thread"]), int(v["main"])])
	return "\n".join(lines)


## The rule, as the one sentence a code review can check against.
const RULE := (
	"The main thread owns the world. A worker may compute from immutable "
	+ "inputs and return a value; it may not touch the scene tree, the voxel "
	+ "world or the engineering graph to hand one over."
)
