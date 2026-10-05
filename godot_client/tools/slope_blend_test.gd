extends SceneTree
## Slope-based material blending (Phase 2.2): grass on level ground, rock on
## the walls, chosen from the face normal rather than from the block id.
##
## The interesting failure here is not "does it blend" but "does it blend the
## right thing on the right block". Two ways this goes quietly wrong:
##
##   * The uniform names in GDScript and in the shader drift apart. Godot does
##     not fail a build for that -- it logs and leaves the parameter unset, so
##     the block renders with a null texture and nobody notices until someone
##     looks at a hill. The names are therefore read back OUT OF THE SHADER
##     SOURCE and checked against what the library sets.
##
##   * A block that has no top/side distinction gets a pair anyway, which costs
##     a second albedo, normal and ARM sample per fragment to draw the same
##     picture twice. Stone must come back single-textured.

var failures := 0


func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: ", msg)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_the_threshold_is_the_specified_one()
	_test_the_pair_table_names_real_sets()
	_test_a_grass_block_blends_grass_into_rock()
	_test_a_block_without_a_pair_is_left_alone()
	_test_a_translucent_block_keeps_its_own_path()
	_test_every_uniform_the_library_sets_exists_in_the_shader()
	_test_the_mapping_survives_the_round_trip()
	print("slope_blend: %s" % ["PASS" if failures == 0
		else "%d FAILURES" % failures])
	quit(1 if failures > 0 else 0)


## The specification names 0.7. It lives on the library, not as a shader
## literal, so this reads the constant the material build actually uses.
func _test_the_threshold_is_the_specified_one() -> void:
	check(is_equal_approx(MaterialLibrary.SLOPE_THRESHOLD, 0.7),
		"slope threshold is %s, expected 0.7" % MaterialLibrary.SLOPE_THRESHOLD)

	# A mode nothing can select is dead code. `_cycle_texture_mapping` walks
	# `mapping_name()`, so the name list is what makes SLOPE reachable -- and
	# the enum value has to line up with the index in that list.
	var names := MaterialLibrary.mapping_name()
	check(names.size() > MaterialLibrary.Mapping.SLOPE,
		"the mapping list has %d names, so SLOPE (%d) is unreachable"
		% [names.size(), MaterialLibrary.Mapping.SLOPE])
	check(names[MaterialLibrary.Mapping.SLOPE] == "slope",
		"SLOPE maps to '%s' in the name list, so the cycle reports the wrong mode"
		% names[MaterialLibrary.Mapping.SLOPE])


func _test_the_pair_table_names_real_sets() -> void:
	var grass := MaterialLibrary.slope_pair_for(ContentDB.GRASS)
	check(not grass.is_empty(), "grass has no slope pair at all")
	if not grass.is_empty():
		check(grass["top"] != grass["side"],
			"grass pairs a set with itself, so the blend draws one texture")
		# A pair naming a set that does not ship would build a material with
		# a null albedo, which reads as a black block.
		for end in ["top", "side"]:
			var set_name: String = grass[end]
			check(MaterialLibrary.texture_set_for(ContentDB.GRASS) != "" \
					or set_name != "",
				"grass %s names an empty set" % end)
			check(ResourceLoader.exists("res://assets/runtime/textures/%s/diff_1024.jpg"
					% set_name)
				or ResourceLoader.exists("res://assets/runtime/textures/%s/diff_512.jpg"
					% set_name),
				"the %s set '%s' has no albedo on disk" % [end, set_name])

	check(MaterialLibrary.slope_pair_for(ContentDB.STONE).is_empty(),
		"stone was given a slope pair, but stone is stone on every face")


func _test_a_grass_block_blends_grass_into_rock() -> void:
	var lib := MaterialLibrary.new()
	lib.set_mapping(MaterialLibrary.Mapping.SLOPE)

	var mat := lib.material_for(ContentDB.GRASS)
	check(mat is ShaderMaterial, "a grass block is not a shader material")
	if not (mat is ShaderMaterial):
		return
	var m := mat as ShaderMaterial
	check(m.shader == MaterialLibrary.SLOPE_SHADER,
		"a grass block did not take the slope shader")

	# The rule itself, as the material will hand it to the GPU.
	check(is_equal_approx(float(m.get_shader_parameter("slope_threshold")), 0.7),
		"the material's slope threshold is %s, expected 0.7"
		% m.get_shader_parameter("slope_threshold"))

	# Both ends must be bound, and must be different pictures, or the blend
	# has nothing to blend between.
	var top: Texture2D = m.get_shader_parameter("top_albedo_tex")
	var side: Texture2D = m.get_shader_parameter("side_albedo_tex")
	check(top != null, "the top (ground) albedo was never bound")
	check(side != null, "the side (wall) albedo was never bound")
	check(top != side, "both ends of the blend are the same texture")
	for end in ["top", "side"]:
		check(m.get_shader_parameter(end + "_normal_tex") != null,
			"the %s normal map was never bound" % end)
		check(m.get_shader_parameter(end + "_arm_tex") != null,
			"the %s ARM map was never bound" % end)

	lib.set_mapping(MaterialLibrary.Mapping.SLOPE)
	var counts := lib.effect_counts()
	check(int(counts["slope"]) > 0,
		"the library built no slope materials at all")
	check(String(counts["mapping"]) == "slope",
		"effect_counts reports the mapping as '%s'" % counts["mapping"])


## A block with no pair must be untouched by this mode: same single-textured
## stochastic material it gets in STOCHASTIC mode.
func _test_a_block_without_a_pair_is_left_alone() -> void:
	var lib := MaterialLibrary.new()
	lib.set_mapping(MaterialLibrary.Mapping.SLOPE)

	var mat := lib.material_for(ContentDB.STONE)
	check(mat != null, "stone produced no material at all under slope mapping")
	if mat is ShaderMaterial:
		check((mat as ShaderMaterial).shader != MaterialLibrary.SLOPE_SHADER,
			"stone was given the slope shader despite having no pair")
		check((mat as ShaderMaterial).get_shader_parameter("top_albedo_tex") == null,
			"stone's material has a top/side pair it should not have")

	# And it must not have been counted as slope-blended.
	var counts := lib.effect_counts()
	check(int(counts["slope"]) < int(counts["materials"]),
		"every material was counted as slope-blended")


func _test_a_translucent_block_keeps_its_own_path() -> void:
	var lib := MaterialLibrary.new()
	lib.set_mapping(MaterialLibrary.Mapping.SLOPE)
	var mat := lib.material_for(ContentDB.GLASS)
	if mat is ShaderMaterial:
		check((mat as ShaderMaterial).shader != MaterialLibrary.SLOPE_SHADER,
			"glass took the slope shader, which cannot do transparency")


## The clamp that used to eat this mode.
##
## The code that hands a mapping down to the world bounded it with a literal
## 0..3, so SLOPE was silently rewritten to stochastic: the caller asked for
## one material and got another, with nothing in the log to say it had been
## overruled. Anything that bounds a mapping has to bound it by the table, so
## adding a mode cannot require remembering every clamp that mentions it.
func _test_the_mapping_survives_the_round_trip() -> void:
	var w := VoxelWorld.new()
	w.materials = MaterialLibrary.new()
	root.add_child(w)

	w.set_texture_mapping(MaterialLibrary.Mapping.SLOPE)
	check(w.texture_mapping == MaterialLibrary.Mapping.SLOPE,
		"set_texture_mapping turned slope into mode %d" % w.texture_mapping)
	var reported := String(w.get_stats()["mapping"])
	check(reported == "slope",
		"a world in slope mode reports its mapping as '%s'" % reported)
	w.queue_free()


## The check that earns its keep. Godot does not fail when GDScript sets a
## uniform the shader does not declare -- it logs and moves on -- so the names
## are read back out of the shader source and compared against what the library
## binds. A rename on either side breaks this test instead of silently
## rendering a block with no texture.
func _test_every_uniform_the_library_sets_exists_in_the_shader() -> void:
	var src := FileAccess.get_file_as_string(
		"res://scripts/world/voxel_slope_blend.gdshader")
	check(src != "", "the slope shader source could not be read")

	var declared := {}
	for line in src.split("\n"):
		var t := line.strip_edges()
		if not t.begins_with("uniform "):
			continue
		# `uniform <type> <name> : hint = default` -- take the token after the
		# type, stripped of any hint or default.
		var rest := t.substr("uniform ".length())
		var parts := rest.split(" ")
		if parts.size() < 2:
			continue
		declared[parts[1].split(":")[0].strip_edges()] = true

	check(not declared.is_empty(), "no uniforms were parsed out of the shader")

	# Every parameter the library sets on a slope material, by name.
	var expected := [
		"albedo_tint", "uv_scale", "slope_threshold", "use_arm",
		"top_albedo_tex", "side_albedo_tex",
		"top_normal_tex", "side_normal_tex",
		"top_arm_tex", "side_arm_tex",
		"top_detail_tex", "side_detail_tex",
		"detail_strength", "normal_strength",
	]
	for name in expected:
		check(declared.has(name),
			"the library sets '%s' but the slope shader does not declare it" % name)

	# And the rule the specification asks for is actually in the shader.
	check(src.contains("slope_threshold + slope_blend") \
			and src.contains("NORMAL.y"),
		"the shader does not blend on the face normal's Y against the threshold")
	check(not src.contains("abs(NORMAL).y") and not src.contains("abs(NORMAL.y)"),
		"the slope test takes the absolute normal, which would put grass on "
		+ "cave ceilings")
