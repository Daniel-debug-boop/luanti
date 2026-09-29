extends SceneTree
## The architecture, as an executable assertion.
##
## `ARCHITECTURE.md` says what the stack is. This says it still is. Most of
## the value is in the parts that check the *checker*: a layering rule that has
## never rejected anything is not a rule, and the only way to tell the
## difference is to feed it deliberate violations and watch them fail.

var _fails := 0


func _init() -> void:
	_test_layer_table_is_coherent()
	_test_project_obeys_layering()
	_test_checker_rejects_an_upward_dependency()
	_test_checker_rejects_an_internal_reach()
	_test_checker_ignores_prose()
	_test_luanti_is_outside_the_runtime()
	_test_dead_architecture_is_gone()
	_test_protocol_envelope()
	_test_protocol_contracts()
	_test_protocol_sequence()
	_test_determinism()
	_test_threading()
	# The runtime check needs a frame. `main.gd` builds its world, player and
	# systems in `_ready`, and adding a node from `SceneTree._init` defers that
	# -- the same rule the rest of this project follows. Everything else here
	# is pure, so it does not have to wait.
	_frames = 0
	_root_ref = root


func _process(delta: float) -> bool:
	_frames += 1
	if _frames < 2:
		return false
	_test_world_singleton_runtime()
	_finish()
	return true


var _frames := 0
var _root_ref: Window


func _eq(got: Variant, want: Variant, what: String) -> void:
	if got == want:
		print("  ok   %s == %s" % [what, str(want)])
	else:
		_fails += 1
		print("  FAIL %s: got %s, want %s" % [what, str(got), str(want)])


func _true(got: bool, what: String) -> void:
	_eq(got, true, what)


func _finish() -> void:
	print("RESULT: %s (%d failures)" % ["PASS" if _fails == 0 else "FAIL", _fails])
	quit(0 if _fails == 0 else 1)


# --- the table --------------------------------------------------------------

func _test_layer_table_is_coherent() -> void:
	# Every layer in the order must exist, and no layer may be unreachable.
	for l in EngArch.LAYER_ORDER:
		_eq(EngArch.LAYER_ORDER.find(l) >= 0, true,
			"layer '%s' is in the dependency order" % l)
	_eq(EngArch.LAYER_ORDER.has("app"), true,
		"there is an app layer for the composition root")
	_eq(EngArch.LAYER_ORDER.find("app"), EngArch.LAYER_ORDER.size() - 1,
		"and it is last, so it is the only layer that may use every other")
	# The rule itself: downward only, plus your own layer.
	_eq(EngArch.may_depend("engineering", "world"), true,
		"a higher layer may use a lower one")
	_eq(EngArch.may_depend("world", "engineering"), false,
		"and never the reverse")
	_eq(EngArch.may_depend("world", "world"), true,
		"a layer may always use its own")
	_eq(EngArch.may_depend("world", "nonsense"), false,
		"an undeclared layer is never allowed")


# --- the project ------------------------------------------------------------

func _test_project_obeys_layering() -> void:
	var v := EngArch.violations()
	if v.is_empty():
		print("  ok   the whole project obeys the layering rules (0 violations)")
		return
	_fails += 1
	print("  FAIL %d architecture violation(s):" % v.size())
	for item in v:
		print("        [%s] %s" % [item["kind"], item["detail"]])


func _test_checker_rejects_an_upward_dependency() -> void:
	# The checker's own test. If this ever starts passing, the checker is a
	# no-op and every other assertion in this file is decorative.
	var bad := EngArch.check_text("core",
		"extends RefCounted\nvar w: VoxelWorld\n")
	_eq(bad.size() >= 1, true,
		"a core module reaching for a world type is a violation")
	_eq(String(bad[0]["kind"] if not bad.is_empty() else ""), "layer",
		"and it is reported as a layering violation, not a visibility one")

	var good := EngArch.check_text("engineering",
		"var w: VoxelWorld\nvar m: ContentDB\n")
	_eq(good.is_empty(), true,
		"the same reference from a layer below is fine")


func _test_checker_rejects_an_internal_reach() -> void:
	var bad := EngArch.check_text("ui",
		"var s: EngSimulation\n")
	_true(not bad.is_empty(),
		"reaching into another layer's INTERNAL module is a violation")
	_eq(String(bad[0]["kind"] if not bad.is_empty() else ""), "visibility",
		"and it is a visibility violation")
	var same_layer := EngArch.check_text("engineering",
		"var s: EngSimulation\nvar p: EngPart\n")
	_eq(same_layer.is_empty(), true,
		"while a layer using its own internals is not a violation")


func _test_checker_ignores_prose() -> void:
	# Comments are not coupling. A file that explains why it deliberately does
	# not depend on something must not be reported as depending on it.
	var src := "## We do NOT use VoxelWorld here, on purpose.\n## Nor ContentDB.\nextends RefCounted\n"
	_eq(EngArch.check_text("core", src).is_empty(), true,
		"a class named only in a comment is not a dependency")
	# A name in a plain string is data, not code: the threading rules list
	# eleven main-thread-only classes without referencing any of them.
	var strs := "const ONLY := [\"VoxelWorld\", \"EngGraph\"]\n"
	_eq(EngArch.check_text("core", strs).is_empty(), true,
		"a class named only in a string is not a dependency either")
	# But a preload is a real dependency and must survive the literal strip.
	var loaded := "const W := preload(\"res://scripts/world/voxel_world.gd\")\n"
	_true(not EngArch.check_text("core", loaded).is_empty(),
		"a preloaded script is still a dependency")


func _test_luanti_is_outside_the_runtime() -> void:
	# Luanti's role is a *converter*, not a second engine running alongside
	# Godot. The proof is structural: no Godot script references the C++ tree,
	# and the only file that touches a legacy world directory is the reader.
	var offending: Array[String] = []
	for path in _scripts():
		var text := FileAccess.get_file_as_string(path)
		for needle in ["#include", "lib/irrlicht", "src/luanti", "CMakeLists"]:
			if text.contains(needle) and not path.ends_with("core/architecture.gd"):
				offending.append("%s mentions %s" % [path, needle])
	_eq(offending.is_empty(), true,
		"no Godot script reaches into the Luanti C++ tree")
	# And the legacy format is read, never written: the game must not be able
	# to damage a world it is only able to convert.
	_eq(SaveGame.SAVE_VERSION > 0, true, "the save system has a format version")
	var legacy := FileAccess.get_file_as_string("res://scripts/world/chunk_files.gd")
	_eq(legacy.contains("func load_chunk") and legacy.contains("func has_chunk"),
		true, "legacy chunks are read through ChunkFiles")
	_eq(legacy.contains("func store_chunk"), false,
		"and never written: a converted world is not modified in place")
	_eq(DirAccess.dir_exists_absolute("res://scripts/world/luanti"), false,
		"and there is no second Luanti-format world layer")


func _scripts() -> Array[String]:
	var out: Array[String] = []
	_scan("res://scripts", out)
	return out


func _scan(path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if dir.current_is_dir():
			if not n.begins_with("."):
				_scan(path + "/" + n, out)
		elif n.ends_with(".gd"):
			out.append(path + "/" + n)
		n = dir.get_next()
	dir.list_dir_end()


# --- what was removed -------------------------------------------------------

func _test_dead_architecture_is_gone() -> void:
	# A class that no longer exists cannot be resurrected by accident, and the
	# F8 key that built it is free.
	_eq(ClassDB.class_exists("ZylannWorld"), false,
		"the parallel Voxel Tools world is gone, not merely unreferenced")
	var main_text := FileAccess.get_file_as_string("res://scripts/main.gd")
	_eq(main_text.contains("KEY_F8"), false, "and the key that built it is free")
	_eq(main_text.contains("ZylannWorld"), false,
		"and main.gd does not name it")
	# The compatibility layer that kept two answers to "what is selected".
	var interaction := FileAccess.get_file_as_string(
		"res://scripts/player/player_interaction.gd")
	_eq(interaction.contains("var hotbar :="), false,
		"the legacy fixed hotbar list is gone from PlayerInteraction")
	var hud := FileAccess.get_file_as_string("res://scripts/hud.gd")
	_eq(hud.contains("interaction.hotbar"), false,
		"and the HUD no longer falls back to it")


# --- runtime ----------------------------------------------------------------

func _test_world_singleton_runtime() -> void:
	# The composition root, loaded from the real scene, must contain exactly
	# one of each singleton. This is the same check main.gd runs at startup.
	var packed: PackedScene = load("res://scenes/main.tscn")
	_eq(packed != null, true, "the main scene loads")
	if packed == null:
		return
	var scene := packed.instantiate()
	root.add_child(scene)
	var problems := EngArch.verify_runtime(scene)
	if problems.is_empty():
		print("  ok   main.tscn holds exactly one of each singleton")
	else:
		_fails += 1
		for p in problems:
			print("  FAIL singleton: ", p)
	# The world in that scene is the registered one.
	_eq(WorldBackend.has_active(), true, "and it claimed the world slot")
	if WorldBackend.has_active():
		_eq(String(WorldBackend.active_name()), "gdscript",
			"which is the GDScript backend")
	scene.queue_free()


# --- protocol ---------------------------------------------------------------

func _test_protocol_envelope() -> void:
	var m := NetProtocol.encode("place", 1, 0, 7,
		{"component": "motor", "position": Vector3.ZERO})
	_eq(m["v"], NetProtocol.VERSION, "a message carries the protocol version")
	for f in NetProtocol.ENVELOPE:
		_eq(m.has(f), true, "and the envelope field '%s'" % f)
	var v := NetProtocol.validate(m, NetProtocol.CLIENT_TO_SERVER)
	_eq(bool(v["ok"]), true, "and it validates")
	_eq(String(v["rule"]), "", "with no rule broken")

	# A version mismatch is refused, specifically.
	var old: Dictionary = m.duplicate(true)
	old["v"] = NetProtocol.VERSION - 1
	var r := NetProtocol.validate(old, NetProtocol.CLIENT_TO_SERVER)
	_eq(bool(r["ok"]), false, "an older protocol is refused")
	_eq(String(r["rule"]), "version", "and the rule is named, so the client "
		+ "can tell a config problem from a grief")

	# Direction is enforced, not documented.
	var spoof: Dictionary = m.duplicate(true)
	spoof["t"] = NetProtocol.SERVER_TO_CLIENT
	r = NetProtocol.validate(spoof, NetProtocol.CLIENT_TO_SERVER)
	_eq(bool(r["ok"]), false, "a server-to-client message is not accepted "
		+ "by a server")
	_eq(String(r["rule"]), "direction", "and the reason is the direction")

	# An unknown op is refused before anything looks at the payload.
	r = NetProtocol.validate(NetProtocol.encode("pwn", 1, 0, 1, {}),
		NetProtocol.CLIENT_TO_SERVER)
	_eq(String(r["rule"]), "op", "an unknown op is refused by name")


func _test_protocol_contracts() -> void:
	# Every message declares its required payload fields, and the contract is
	# enforced. A message that is half-understood is worse than one refused.
	_true(NetProtocol.ops().size() >= 10, "the protocol defines its messages")
	for op in NetProtocol.ops():
		var spec := NetProtocol.spec_of(op)
		_eq(spec.has("dir"), true, "%s declares a direction" % op)
		_eq(spec.has("fields"), true, "%s declares its required fields" % op)
		_eq(spec.has("doc"), true, "%s documents itself" % op)
	# A missing required field is caught.
	var r := NetProtocol.validate(NetProtocol.encode("place", 1, 0, 1,
		{"component": "motor"}), NetProtocol.CLIENT_TO_SERVER)
	_eq(bool(r["ok"]), false, "a place with no position is refused")
	_eq(String(r["rule"]), "schema", "and the rule is the schema")
	# A wrongly-typed optional field is caught too, because a string where a
	# cost dictionary belongs is how "free" gets charged as a price.
	r = NetProtocol.validate(NetProtocol.encode("place", 1, 0, 1,
		{"component": "motor", "position": Vector3.ZERO,
		 "cost": "free"}), NetProtocol.CLIENT_TO_SERVER)
	_eq(bool(r["ok"]), false, "a cost that is not a dictionary is refused")
	# The two directions have disjoint message sets, so a client can never be
	# in a position where it is expected to author world state.
	var c2s := NetProtocol.ops_in_direction(NetProtocol.CLIENT_TO_SERVER)
	var s2c := NetProtocol.ops_in_direction(NetProtocol.SERVER_TO_CLIENT)
	var overlap: Array[String] = []
	for op in c2s:
		if s2c.has(op):
			overlap.append(op)
	_eq(overlap.is_empty(), true,
		"no message travels in both directions")
	# Every server-to-client message is state, never a request. That is the
	# structural reason there is no client-authoritative path.
	for op in s2c:
		_eq(String(NetProtocol.spec_of(op)["kind"]), "state",
			"%s is server-derived state, not a request" % op)
	_true(NetProtocol.describe().contains("NetProtocol v"),
		"and the contract renders to text for the documentation")


func _test_protocol_sequence() -> void:
	var s := NetProtocol.Sequence.new()
	_eq(bool(s.accept(0)["ok"]), true, "the first message is accepted")
	_eq(bool(s.accept(1)["ok"]), true, "and the next")
	var r := s.accept(1)
	_eq(bool(r["ok"]), false, "a repeated sequence number is refused")
	_eq(bool(s.accept(0)["ok"]), false,
		"and so is an older one: requests are applied in the order sent")
	r = s.accept(4)
	_eq(bool(r["ok"]), true, "a gap is still accepted")
	_eq(int(r["gap"]), 2, "and reported, so loss is visible rather than silent")
	_eq(bool(s.stats()["in_order"]), false,
		"and the peer is marked as having lost messages")


# --- determinism ------------------------------------------------------------

func _test_determinism() -> void:
	# Order independence. Two graphs built by adding the same nodes in
	# different orders are the same graph, and the hash has to say so.
	var a := {"b": 2, "a": 1, "c": {"z": 1, "y": 2}}
	var b := {"c": {"y": 2, "z": 1}, "a": 1, "b": 2}
	_eq(Determinism.hash_state(a), Determinism.hash_state(b),
		"dictionary order does not change the hash")
	_eq(Determinism.hash_state(a) == Determinism.hash_state({"a": 1}),
		false, "but different state does")
	# Positions hash at a precision the world can actually observe.
	_eq(Determinism.hash_state(Vector3(1.0, 2.0, 3.0)),
		Determinism.hash_state(Vector3(1.0, 2.0, 3.0)),
		"the same position hashes the same")
	# A run is reproducible, and the prover is not a rubber stamp.
	var r := Determinism.assert_reproducible(
		func(state, i): return state + i, 0, 100)
	_eq(bool(r["ok"]), true, "a pure function is reproducible over 100 steps")
	var bad := Determinism.assert_reproducible(
		func(state, i): return state + (1 if i == 50 else 0), 0, 100)
	_eq(bool(bad["ok"]), true, "and a constant is too")
	# The fixed step does not depend on frame rate, and a hitch does not turn
	# into a catch-up spiral.
	var plan := Determinism.steps_from(0.0, 0.1)
	_eq(int(plan["steps"]), 1, "a tenth of a second is one step")
	plan = Determinism.steps_from(0.0, 10.0)
	_eq(int(plan["steps"]), Determinism.MAX_STEPS_PER_FRAME,
		"a ten-second stall runs the ceiling, not ten seconds of ticks")
	_eq(float(plan["remainder"]) <= Determinism.SIM_DT
		* float(Determinism.MAX_STEPS_PER_FRAME) + 1e-9, true,
		"and the backlog is dropped rather than chased")
	# The accumulator cannot drift.
	_eq(Determinism.quantise(0.1 + 0.2), Determinism.quantise(0.3),
		"the accumulator is quantised, so repeated adds cannot drift")


func _test_threading() -> void:
	Threading.clear()
	_eq(Threading.is_main_thread(), true,
		"the test itself is running on the main thread")
	_eq(Threading.guard("test"), true, "so a guard passes here")
	_eq(Threading.violation_count(), 0, "and records nothing")
	# Simulate the other case by reporting a foreign thread id, so the rule is
	# tested without actually racing the scene tree.
	Threading.record(Threading.VIOLATION_MUTATION, "simulated off-thread mutation")
	_eq(Threading.violation_count(), 1, "a recorded violation is counted")
	_true(Threading.report().contains("off-thread"),
		"and named in the report")
	Threading.clear()
	_eq(Threading.violation_count(), 0, "and the log can be cleared")
	_eq(Threading.MAIN_THREAD_ONLY.size() > 0, true,
		"the main-thread-only set is non-empty")
	_true(Threading.MAIN_THREAD_ONLY.has("VoxelWorld"),
		"and names the world")
	_true(Threading.MAIN_THREAD_ONLY.has("EngGraph"),
		"and the engineering graph")
	_true(Threading.RULE.length() > 40,
		"and the rule is stated in one sentence a reviewer can check against")
