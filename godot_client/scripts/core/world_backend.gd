class_name WorldBackend
extends RefCounted
## The boundary every voxel backend must sit behind.
##
## There is exactly one world in EMERGENT. Not "one world per backend you
## happen to have enabled" -- one. An earlier version of this project had a
## GDScript world and, alongside it, a Voxel Tools world that rendered into the
## same camera, stored its own voxels and saved to its own directory. Nothing
## read it. It was a second world with none of the game's rules attached to it,
## and the honest thing to do was to delete it rather than to document it.
##
## This class is the seam that makes that decision enforceable instead of
## aspirational. Anything that owns voxel state must expose this method set, and
## only one backend may be registered as active at a time. A future Voxel Tools
## mesher is a legitimate thing to add -- it would implement this interface and
## be swapped in at the meshing seam, not become a second world.
##
## The interface is the *storage and query* surface only. Rendering, lighting
## and streaming policy belong to the implementation, because a backend that
## cannot draw is still a valid headless backend for tests and for the
## server-side half of a multiplayer game.

## What a backend must provide. This list is the contract; it is checked
## mechanically by `conforms()` and asserted by `architecture_test`.
const REQUIRED := [
	# identity
	"backend_name",
	# voxel storage
	"get_content_at",       # (Vector3i) -> int
	"set_block",            # (Vector3i, int) -> bool
	"break_block",          # (Vector3i) -> bool
	"solid_at",             # (Vector3i) -> bool
	# streaming
	"update_around",        # (Vector3i) -> void
	"set_dimension",        # (int) -> void
	# persistence -- the server and the client must agree on what a save is
	"edits_snapshot",           # () -> Dictionary
	"apply_edits_snapshot",     # (Dictionary) -> void
]

## Method names every backend must expose, beyond the required set. Kept
## separate so the test can name them when it fails.
static func missing_methods(node: Object) -> Array[String]:
	var missing: Array[String] = []
	for m in REQUIRED:
		if not node.has_method(m):
			missing.append(String(m))
	return missing


static func conforms(node: Object) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	return missing_methods(node).is_empty()


## The one live backend. Set by `register`.
static var _active: Object = null


## Claim the world slot. Returns "" on success, or the reason it was refused.
##
## The refusal matters: it is the difference between "there is one world" as a
## convention and as a fact. `main.gd` registers the world it owns, and any
## later attempt to register a second one -- a debug overlay, a test fixture, a
## half-finished Voxel Tools port -- is rejected and says so, instead of
## silently producing a world that no gameplay code can see.
static func register(node: Object) -> String:
	if node == null:
		return "cannot register a null world"
	var missing := missing_methods(node)
	if not missing.is_empty():
		return "world backend is missing: %s" % ", ".join(missing)
	if _active != null and is_instance_valid(_active) and _active != node:
		return "a world is already registered ('%s'); there is exactly one" \
			% String(_active.backend_name())
	_active = node
	return ""


static func unregister(node: Object) -> void:
	if _active == node:
		_active = null


static func active() -> Object:
	if _active != null and not is_instance_valid(_active):
		_active = null
	return _active


static func active_name() -> String:
	var a := active()
	return "" if a == null else String(a.backend_name())


static func has_active() -> bool:
	return active() != null


## How many backends can be live at once. One. Stated as a constant so a test
## can assert the rule rather than infer it from behaviour.
const MAX_ACTIVE := 1
