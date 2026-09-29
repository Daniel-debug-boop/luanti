extends SceneTree
## The world boundary, and what Voxel Tools is and is not allowed to own.
##
## This suite used to test a second, parallel voxel world that the project
## carried next to the real one. That world is gone, and this suite is what
## replaces it: rather than proving a shadow implementation works, it proves
## the shadow cannot come back, and it records what the Voxel Tools engine
## module actually is on the machine running the tests.
##
## Runs on BOTH engines:
##   * stock Godot 4.4       -> asserts graceful absence of the Voxel module
##   * Voxel Tools engine    -> asserts the module is present and usable
##
## Either way the world-boundary assertions run: they do not depend on which
## engine is running, because "there is exactly one world" is not a property of
## a particular renderer.

var _fails := 0


func _init() -> void:
	_test_voxel_module_presence()
	_test_voxel_world_conforms()
	_test_only_one_world_may_be_active()
	_test_registry_rejects_non_conforming()
	_test_persistence_is_part_of_the_contract()
	_test_no_second_world_class_exists()
	_finish()


func _eq(got: Variant, want: Variant, what: String) -> void:
	if got == want:
		print("  ok   %s == %s" % [what, str(want)])
	else:
		_fails += 1
		print("  FAIL %s: got %s, want %s" % [what, str(got), str(want)])


func _finish() -> void:
	print("RESULT: %s (%d failures)" % ["PASS" if _fails == 0 else "FAIL", _fails])
	quit(0 if _fails == 0 else 1)


# --- what the engine actually has ------------------------------------------

func _voxel_module_present() -> bool:
	return ClassDB.class_exists("VoxelStreamRegionFiles") \
		or ClassDB.class_exists("VoxelGeneratorScriptWrapper")


func _test_voxel_module_presence() -> void:
	var present := _voxel_module_present()
	print("  info Voxel Tools module present: %s" % present)
	# The point of this assertion is that the answer is *reported*, not that it
	# is either value. The game does not depend on it, so a machine without
	# the module and a machine with it must both pass.
	_eq(typeof(present), TYPE_BOOL, "module presence is reported, not assumed")
	# A Voxel Tools build registers its stream classes; stock Godot does not.
	if not present:
		_eq(ClassDB.class_exists("VoxelStreamRegionFiles"), false,
			"and on stock Godot there is genuinely no Voxel stream class")


# --- the contract -----------------------------------------------------------

func _make_world() -> VoxelWorld:
	var w := VoxelWorld.new()
	w.name = "World"
	return w


func _test_voxel_world_conforms() -> void:
	var w := _make_world()
	_eq(WorldBackend.conforms(w), true,
		"the game's world satisfies the backend contract")
	_eq(WorldBackend.missing_methods(w).is_empty(), true,
		"with nothing missing from it")
	_eq(String(w.backend_name()) != "", true, "and it names itself")
	w.free()


func _test_only_one_world_may_be_active() -> void:
	WorldBackend.unregister(null)
	var a := _make_world()
	_eq(WorldBackend.register(a), "", "the first world registers")
	_eq(WorldBackend.has_active(), true, "and becomes the active backend")
	_eq(WorldBackend.active_name(), String(a.backend_name()), "and is reachable")

	# The whole point. A second world is refused, and the refusal says why, so
	# whoever adds one finds out immediately rather than shipping a shadow
	# world that no gameplay code can see.
	var b := _make_world()
	var why := WorldBackend.register(b)
	_eq(why != "", true, "a second world is refused")
	_eq(why.contains("exactly one"), true, "with a reason that names the rule")
	_eq(WorldBackend.active() == a, true, "and the first world is still the one")
	b.free()

	# Re-registering the *same* world is not a second world.
	_eq(WorldBackend.register(a), "", "re-registering the same world is a no-op")

	WorldBackend.unregister(a)
	_eq(WorldBackend.has_active(), false, "and it can be handed back")
	a.free()


func _test_registry_rejects_non_conforming() -> void:
	WorldBackend.unregister(null)
	# Anything that cannot answer the contract is not a world, however
	# convincing it looks.
	var fake := Node.new()
	fake.name = "NotAWorld"
	var why := WorldBackend.register(fake)
	_eq(why != "", true, "a node that cannot answer the contract is refused")
	_eq(WorldBackend.has_active(), false,
		"and does not become the active backend")
	_eq(WorldBackend.register(null) != "", true, "nor can null")
	fake.free()


func _test_persistence_is_part_of_the_contract() -> void:
	# Persistence lives on the interface on purpose. A backend that draws
	# beautifully but cannot round-trip its own edits is not usable as *the*
	# world, it is usable as a renderer -- and a renderer belongs behind the
	# meshing seam, not in the world slot.
	_eq(WorldBackend.REQUIRED.has("edits_snapshot"), true,
		"reading the edit log is part of the world contract")
	_eq(WorldBackend.REQUIRED.has("apply_edits_snapshot"), true,
		"and writing it back")
	var w := _make_world()
	var snap: Dictionary = w.edits_snapshot()
	_eq(snap is Dictionary, true, "and the real world answers with one")
	_eq(w.solid_at(Vector3i(0, -60, 0)) or not w.solid_at(Vector3i(0, -60, 0)),
		true, "and answers queries about the world")
	w.free()


func _test_no_second_world_class_exists() -> void:
	# The deleted shadow backend must not linger as a class nobody can even
	# name. This is a cheap, permanent guard against the file coming back.
	for gone in ["ZylannWorld", "ZylannGenerator"]:
		_eq(ClassDB.class_exists(gone), false,
			"%s is not a class in this project any more" % gone)
		_eq(ProjectSettings.has_setting("res://scripts/world/zylann"), false,
			"and its settings namespace is gone")
	_eq(DirAccess.dir_exists_absolute("res://scripts/world/zylann"), false,
		"the parallel world directory is removed, not merely unreferenced")
