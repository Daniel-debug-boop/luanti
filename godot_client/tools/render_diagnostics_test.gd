extends SceneTree
## Tests for the layered rendering diagnostic.
##
## The value of a layer-by-layer diagnostic is entirely in whether the layers
## are actually independent, so these tests check that: every stage must
## differ from its neighbour in the settings that matter, and no stage may
## leave an earlier stage's override in place.

var failures := 0


func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: ", msg)


func _init() -> void:
	_test_stage_names_are_ordered_and_complete()
	_test_parsing_accepts_names_and_indices()
	_test_parsing_rejects_nonsense()
	_test_baseline_has_no_atmosphere()
	_test_stages_add_capability_monotonically()
	_test_normal_stage_overrides_unlit()
	_test_clean_environment_has_nothing_left_on()
	_test_overrides_only_touch_named_properties()
	_test_material_overrides_take_effect()
	print("diagnostics: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)


func _test_stage_names_are_ordered_and_complete() -> void:
	check(RenderDiagnostics.STAGE_NAMES.size() == 7,
		"there should be 7 stages, got %d"
		% RenderDiagnostics.STAGE_NAMES.size())
	for i in RenderDiagnostics.Stage.values():
		check(i < RenderDiagnostics.STAGE_NAMES.size(),
			"stage %d has no name" % i)
	check(RenderDiagnostics.STAGE_NAMES[0] == "unlit",
		"stage 0 must be the unlit geometry baseline, got '%s'"
		% RenderDiagnostics.STAGE_NAMES[0])


func _test_parsing_accepts_names_and_indices() -> void:
	for i in RenderDiagnostics.STAGE_NAMES.size():
		check(RenderDiagnostics.parse_stage(
			RenderDiagnostics.STAGE_NAMES[i]) == i,
			"stage name '%s' should parse to %d"
			% [RenderDiagnostics.STAGE_NAMES[i], i])
		check(RenderDiagnostics.parse_stage(str(i)) == i,
			"stage index %d should parse to itself" % i)
	check(RenderDiagnostics.parse_stage("  NORMAL ") == RenderDiagnostics.Stage.NORMAL,
		"parsing should tolerate surrounding whitespace and case")
	check(RenderDiagnostics.parse_stage("Unlit") == 0,
		"parsing should be case-insensitive")


func _test_parsing_rejects_nonsense() -> void:
	for bad in ["", "ultra", "7", "-1", "lighting", "99"]:
		check(RenderDiagnostics.parse_stage(bad) == null,
			"'%s' should not parse as a stage" % bad)


func _test_baseline_has_no_atmosphere() -> void:
	var s := RenderDiagnostics.stage_settings(RenderDiagnostics.Stage.UNLIT)
	check(bool(s.get("unlit", false)),
		"the baseline must be unlit, or lighting is not actually removed")
	check(not bool(s.get("lights", true)),
		"the baseline must switch the lights off")
	check(not bool(s.get("world_environment", true)),
		"the baseline must switch the WorldEnvironment off")
	for k in ["env_over", "env_deeps"]:
		check((s[k] as Dictionary).is_empty(),
			"the baseline must leave no environment overrides to apply")


func _test_stages_add_capability_monotonically() -> void:
	# Each stage must be a strict superset of the previous one's effects:
	# the diagnostic is only useful if it isolates one variable at a time.
	var prev_lights := false
	var prev_we := false
	var prev_fog := false
	for i in range(1, RenderDiagnostics.STAGE_NAMES.size()):
		var s := RenderDiagnostics.stage_settings(i)
		var lights := bool(s.get("lights", true))
		var we := bool(s.get("world_environment", true))
		var fog := bool((s["env_over"] as Dictionary).get(
			"volumetric_fog_enabled", false))
		check(lights or not prev_lights,
			"stage %d switched the lights back off after enabling them" % i)
		check(we or not prev_we,
			"stage %d removed the environment after adding it" % i)
		check(fog or not prev_fog,
			"stage %d removed fog after adding it" % i)
		prev_lights = lights
		prev_we = we
		prev_fog = fog
	# The final stage must be the full stack.
	var last := RenderDiagnostics.stage_settings(RenderDiagnostics.Stage.POST)
	check((last["env_over"] as Dictionary).is_empty(),
		"the last stage must impose no overrides: it is the shipping stack")


func _test_normal_stage_overrides_unlit() -> void:
	# The NORMAL stage is also unlit, because a normals picture must not be
	# shaded -- so it depends on the normal-debug branch being tested FIRST
	# in material_for. This is the assertion that pins that ordering down;
	# with the branches the other way round, every stage from NORMAL onward
	# silently renders the same flat baseline.
	var s := RenderDiagnostics.stage_settings(RenderDiagnostics.Stage.NORMAL)
	check(bool(s.get("normal_debug", false)),
		"the NORMAL stage must enable normal_debug")
	check(bool(s.get("unlit", false)),
		"the NORMAL stage must also be unlit, or shading distorts the normals")
	var lib := MaterialLibrary.new()
	lib.set_unlit(true)
	lib.set_normal_debug(true)
	var m := lib.material_for(ContentDB.STONE)
	check(m is ShaderMaterial,
		"with both flags set, material_for must return the normals shader, "
		+ "not the flat unlit material (got %s)" % m.get_class())
	lib.clear_diagnostics()
	check(not lib.is_diagnostic(),
		"clear_diagnostics must drop every override")


func _test_clean_environment_has_nothing_left_on() -> void:
	var env := RenderDiagnostics.make_clean_environment(true)
	for prop in ["ssao_enabled", "ssil_enabled", "glow_enabled",
			"sdfgi_enabled", "volumetric_fog_enabled", "fog_enabled"]:
		check(not bool(env.get(prop)),
			"a clean environment must have %s off" % prop)
	check(env.tonemap_mode == Environment.TONE_MAPPER_LINEAR,
		"a clean environment must not tonemap: a filmic curve would make "
		+ "every layer a lie about contrast")


func _test_overrides_only_touch_named_properties() -> void:
	var env := RenderDiagnostics.make_clean_environment(true)
	var before := env.fog_light_color
	RenderDiagnostics.apply_overrides(env, {"fog_enabled": true})
	check(bool(env.fog_enabled), "the named property should be applied")
	check(env.fog_light_color == before,
		"an override must not disturb properties it did not name")
	# A null environment must not crash.
	RenderDiagnostics.apply_overrides(null, {"fog_enabled": true})
	check(true, "applying overrides to a null environment is a no-op")


func _test_material_overrides_take_effect() -> void:
	var lib := MaterialLibrary.new()
	var textured := lib.material_for(ContentDB.STONE)
	lib.set_unlit(true)
	var flat := lib.material_for(ContentDB.STONE)
	check(flat.get_class() == "StandardMaterial3D",
		"the unlit override returns a flat material")
	check((flat as StandardMaterial3D).shading_mode
		== BaseMaterial3D.SHADING_MODE_UNSHADED,
		"the unlit override must actually be unshaded")
	check(flat != textured or textured.get_class() == "StandardMaterial3D",
		"the override must change the material it hands out")
	lib.clear_diagnostics()
	check(not lib.is_diagnostic(), "overrides cleared")
	check(not lib.is_diagnostic(), "and stay cleared")