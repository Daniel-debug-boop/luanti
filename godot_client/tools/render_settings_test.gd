extends SceneTree
## Render-settings tests: assert that the stock Godot material and
## environment effects are actually switched on, at every quality tier.
##
## Nothing here loads a shader. The point of the suite is that every effect
## claimed in the README is a real, enabled property on a real
## StandardMaterial3D or Environment.

var failures := 0


func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: ", msg)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	# --- Materials: triplanar, POM (heightmap), detail ---
	# POM is an ULTRA-only effect (assets/ART_DIRECTION.md): it costs a ray
	# march per fragment on faces that are flat by construction, so paying
	# for it below ULTRA buys relief nobody can see at the frame rate the
	# lower tiers are there to hold. The default library is HIGH, so POM is
	# expected to be OFF here and is asserted at ULTRA further down.
	var lib := MaterialLibrary.new()
	lib.prime()
	print("materials: ", lib.describe())
	var fx := lib.effect_counts()
	print("material effects: ", fx)

	check(fx.materials > 0, "no textured materials were built")
	check(fx.pom == 0,
		"POM is on for %d materials at the default tier; it is ULTRA-only"
			% int(fx.pom))
	check(fx.detail > 0, "the detail layer is on for no materials")
	# Godot silently discards the heightmap on a triplanar material, so POM
	# and triplanar must never be on the same material at the same time.
	check(fx.pom == 0 or fx.triplanar == 0,
		"a material has both triplanar and POM on (%d/%d); Godot will drop the "
			% [fx.triplanar, fx.pom] + "heightmap and the POM will not run")
	check(fx.mapping == "parallax",
		"expected the default mapping to be parallax, got %s" % fx.mapping)

	var grass := lib.material_for(ContentDB.GRASS) as StandardMaterial3D
	check(grass != null, "grass has no material")
	if grass == null:
		print("\nrender-settings: FAILURES (no grass material)")
		quit(1)
		return
	check(grass.albedo_texture != null,
		"grass has no albedo texture, so it is rendering as flat vertex colour")
	check(not grass.heightmap_enabled,
		"grass has a heightmap at the default tier; POM is ULTRA-only")
	check(grass.detail_enabled, "grass has no detail layer")
	check(grass.detail_albedo != null, "grass detail layer has no texture")
	# The detail layer reads UV2, which the mesher must be emitting.
	check(grass.detail_uv_layer == BaseMaterial3D.DETAIL_UV_2,
		"the detail layer is not reading UV2")

	# --- ULTRA is where POM lives ---
	var ultra := MaterialLibrary.new()
	ultra.apply_quality(MaterialLibrary.Quality.ULTRA)
	ultra.prime()
	var ultra_fx := ultra.effect_counts()
	print("ultra material effects: ", ultra_fx)
	check(int(ultra_fx.pom) > 0,
		"POM is on for no materials at ULTRA, so the only tier that pays "
			+ "for it does not get it")
	check(ultra.texture_tier() == 2048,
		"ULTRA is not standing on the 2048 rung (%d)"
			% ultra.texture_tier())
	var ugrass := ultra.material_for(ContentDB.GRASS) as StandardMaterial3D
	check(ugrass != null, "grass has no material at ULTRA")
	if ugrass != null:
		check(ugrass.heightmap_enabled,
			"grass has no heightmap at ULTRA, so no parallax occlusion")
		check(ugrass.heightmap_texture != null,
			"grass heightmap has no displacement texture bound")
		check(ugrass.heightmap_deep_parallax,
			"grass is not using the occlusion-marched POM variant")
		check(not ugrass.uv1_triplanar,
			"grass has both POM and triplanar on at once")

	# --- Switching to triplanar turns the heightmap off, not on alongside it ---
	var tri := MaterialLibrary.new()
	tri.set_mapping(MaterialLibrary.Mapping.TRIPLANAR)
	tri.prime()
	var tri_fx := tri.effect_counts()
	print("triplanar mode: ", tri_fx)
	check(tri_fx.triplanar == tri_fx.materials,
		"triplanar is on for %d/%d materials"
			% [tri_fx.triplanar, tri_fx.materials])
	check(tri_fx.pom == 0, "POM is still on after switching to triplanar")
	var tg := tri.material_for(ContentDB.GRASS) as StandardMaterial3D
	check(tg != null, "grass has no material in triplanar mode")
	if tg != null:
		check(tg.uv1_triplanar, "grass is not triplanar in triplanar mode")
		# World-space, because the mesher emits chunk-local quads: UV-space
		# triplanar would shift the projection at every chunk border.
		check(tg.uv1_world_triplanar, "triplanar is not world-space")

	# --- Stochastic mode uses the vendored shader instead ---
	var stoch := MaterialLibrary.new()
	stoch.set_mapping(MaterialLibrary.Mapping.STOCHASTIC)
	stoch.prime()
	var stoch_fx := stoch.effect_counts()
	print("stochastic mode: ", stoch_fx)
	check(stoch_fx.stochastic > 0, "no stochastic shader materials built")
	check(stoch_fx.triplanar == 0 and stoch_fx.pom == 0,
		"stochastic mode is mixing in the engine-material effects")
	var sg := stoch.material_for(ContentDB.GRASS) as ShaderMaterial
	check(sg != null, "grass has no stochastic material")
	if sg != null:
		check(sg.shader != null, "the stochastic material has no shader")
		check(sg.get_shader_parameter("albedo_tex") != null,
			"the stochastic material has no albedo texture")
		check(sg.get_shader_parameter("arm_tex") != null,
			"the stochastic material has no ARM map")
		check(sg.get_shader_parameter("normal_tex") != null,
			"the stochastic material has no normal map")
		# The shader's own code must contain the stochastic hash, or the
		# tiling-repeat problem it exists to solve is not actually addressed.
		var code := sg.shader.code
		check(code.contains("stochastic_sample"),
			"the vendored shader has no stochastic sampling function")
		check(code.contains("hash("),
			"the vendored shader has no per-cell hash offset")
		check(code.contains("MODEL_MATRIX"),
			"the vendored shader does not sample in world space, so the "
				+ "texture will reset at every chunk border")
		# Our own derivative, and the upstream licence notice, must survive.
		check(code.contains("Apache License"),
			"the Apache-2.0 attribution notice was dropped from the shader")
		check(code.contains("acegiak"),
			"the upstream attribution was dropped from the shader")

	# Glass and water have to stay glass and water in every mode. The
	# vendored shader carries no alpha -- it writes ALBEDO from
	# vertex_tint.rgb and never touches the alpha channel -- so
	# translucent blocks cannot go through it at all, and the fallback
	# has to be the translucent material rather than the plain opaque
	# one that turned every window in the world into a white brick.
	var sglass := stoch.material_for(ContentDB.GLASS)
	check(sglass is StandardMaterial3D,
		"glass is not a StandardMaterial3D fallback in stochastic mode")
	if sglass is StandardMaterial3D:
		check((sglass as StandardMaterial3D).transparency \
			== BaseMaterial3D.TRANSPARENCY_ALPHA,
			"glass renders opaque in stochastic mode")
	var snow_mat := stoch.material_for(ContentDB.SNOW)
	check(sglass != snow_mat,
		"glass shares stone's plain material, so the fallback is the plain one")
	# The mode's textures are shader parameters, not StandardMaterial3D
	# properties, so a VRAM estimate that only walks the engine materials
	# reports 0 MB for a world that has every texture set bound.
	check(stoch.texture_vram_mb() > 0.0,
		"stochastic mode reports 0 MB of texture VRAM: the estimate counts "
		+ "only the engine materials")

	# --- The stochastic shader needs POM off, which is now the default ---
	# POM is ULTRA-only and the stochastic path is a ShaderMaterial that
	# samples its own maps, so a ULTRA stochastic material must not also be
	# carrying a heightmap property that would never be read.
	var stoch_ultra := MaterialLibrary.new()
	stoch_ultra.apply_quality(MaterialLibrary.Quality.ULTRA)
	stoch_ultra.set_mapping(MaterialLibrary.Mapping.STOCHASTIC)
	stoch_ultra.prime()
	var su := stoch_ultra.material_for(ContentDB.GRASS)
	check(su is ShaderMaterial,
		"grass is not a stochastic ShaderMaterial at ULTRA")

	# The mesher has to actually produce that UV2 set.
	var block := VoxelBlock.new()
	block.is_loaded = true
	block.is_generated = true
	block.fill(MapNode.LIGHT_SUN | (MapNode.LIGHT_SUN << 4))
	for x in 16:
		for z in 16:
			block.content[MapNode.index(x, 8, z)] = ContentDB.STONE
	var mesh: ArrayMesh = GreedyMesher.build(block, {})[0]
	var arrays := mesh.surface_get_arrays(0)
	var uv1: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var uv2: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	print("mesher UV1 count=%d UV2 count=%d" % [uv1.size(), uv2.size()])
	check(uv1.size() > 0, "the mesher emits no UV1")
	check(uv2.size() == uv1.size(),
		"the mesher emits no UV2 for the detail layer")
	if uv1.size() > 0:
		# UV2 must tile finer than UV1, or the detail layer is invisible.
		check(uv2[0].x * MaterialLibrary.DETAIL_UV_SCALE == uv1[0].x
				or absf(uv2[0].x - uv1[0].x * MaterialLibrary.DETAIL_UV_SCALE)
					< 0.001,
			"UV2 is not scaled by DETAIL_UV_SCALE (%s vs %s)"
				% [uv2[0], uv1[0]])

	# --- Quality tiers switch the expensive effects off ---
	var low := MaterialLibrary.new()
	low.apply_quality(MaterialLibrary.Quality.LOW)
	low.prime()
	var low_fx := low.effect_counts()
	print("low tier material effects: ", low_fx)
	check(low_fx.pom == 0, "POM is still on at the low tier")
	check(low_fx.detail == 0, "the detail layer is still on at the low tier")
	check(low.texture_tier() == 512,
		"the low tier is not on the 512 rung (%d)" % low.texture_tier())

	# HIGH must stand on a higher rung than LOW or the ladder does nothing.
	var high := MaterialLibrary.new()
	high.apply_quality(MaterialLibrary.Quality.HIGH)
	high.prime()
	check(high.texture_tier() > low.texture_tier(),
		"HIGH (%d) and LOW (%d) stand on the same rung; the ladder is flat"
			% [high.texture_tier(), low.texture_tier()])
	check(high.texture_vram_mb() > 0.0,
		"HIGH reports 0 MB of texture VRAM, so nothing was bound")

	# --- Environment: SSAO, SSIL, volumetric fog, glow ---
	var settings := RenderSettings.new()
	settings.quality = RenderSettings.Quality.HIGH
	var env := settings.build_overworld_environment()
	print("effects: ", settings.describe())

	check(env.ssao_enabled, "SSAO is off")
	check(env.ssao_radius > 0.0, "SSAO has no radius")
	check(env.ssao_intensity > 0.0, "SSAO has no intensity")
	check(env.ssil_enabled, "SSIL is off at the high tier")
	check(env.ssil_radius > 0.0, "SSIL has no radius")
	check(env.volumetric_fog_enabled, "volumetric fog is off at the high tier")
	check(env.volumetric_fog_density > 0.0, "volumetric fog has no density")
	check(env.volumetric_fog_gi_inject > 0.0,
		"volumetric fog is not receiving light injection, so no god rays")
	check(env.volumetric_fog_temporal_reprojection_enabled,
		"volumetric fog has no temporal reprojection, so it will shimmer")
	check(env.glow_enabled, "glow is off")

	# SDFGI settings must be written at the high tier, even though the probe
	# volume itself has to be authored in the editor.
	check(env.sdfgi_cascades == 4, "SDFGI cascades not configured")
	check(env.sdfgi_min_cell_size > 0.0, "SDFGI min cell size not configured")
	check(env.sdfgi_use_occlusion, "SDFGI occlusion not configured")

	# --- The Deeps keeps fog and glow, which is where they earn their cost ---
	var deeps := settings.build_deeps_environment()
	check(deeps.volumetric_fog_enabled, "the Deeps has no volumetric fog")
	check(deeps.glow_enabled, "the Deeps has no glow")
	check(deeps.ssao_enabled, "the Deeps has no SSAO")
	check(deeps.background_mode == Environment.BG_COLOR,
		"the Deeps should not be showing a sky")

	# --- Tier switching actually changes the environment ---
	settings.quality = RenderSettings.Quality.LOW
	settings.apply(env)
	print("low tier effects: ", settings.describe())
	check(not env.ssil_enabled, "SSIL is still on at the low tier")
	check(not env.volumetric_fog_enabled,
		"volumetric fog is still on at the low tier")
	check(env.ssao_enabled, "SSAO should stay on even at the low tier")
	check(env.glow_enabled, "glow should stay on even at the low tier")

	settings.quality = RenderSettings.Quality.MEDIUM
	settings.apply(env)
	check(env.ssil_enabled, "SSIL did not come back at the medium tier")
	check(env.volumetric_fog_enabled,
		"volumetric fog did not come back at the medium tier")

	# --- Bounce probes and the fog volume are real nodes ---
	var fog := settings.make_fog_volume()
	check(fog is FogVolume, "the fog volume is not a FogVolume")
	check((fog as FogVolume).size.x > 0.0, "the fog volume has no size")
	var probes := settings.make_probes(4)
	check(probes.size() == 4, "expected 4 bounce probes, got %d" % probes.size())
	check(probes[0] is ReflectionProbe, "bounce probes are not ReflectionProbe")
	# place_probes must distribute them around the centre, not stack them.
	settings.place_probes(Vector3.ZERO)
	var p0: Vector3 = probes[0].position
	var p1: Vector3 = probes[1].position
	print("probe 0 at %s, probe 1 at %s" % [p0, p1])
	check(p0.distance_to(p1) > 1.0,
		"bounce probes are stacked on the same point")

	# --- The full scene wires it all up ---
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	main.set("world_dir", "/tmp/testchunks")
	main.set("view_radius", 2)
	# ULTRA, not HIGH: POM is an ULTRA-only effect (the same contract asserted
	# above), so a scene driven at HIGH can never have a heightmap on a live
	# surface. Driving it at ULTRA is what makes the POM assertions below
	# end-to-end -- they check the materials the real scene actually built,
	# not a library primed in isolation.
	main.set("render_quality", 3)
	root.add_child(main)

	var scene_settings: RenderSettings = main.get("settings")
	check(scene_settings != null, "main did not create RenderSettings")
	var scene_env: Environment = (main.get("_we") as WorldEnvironment).environment
	check(scene_env != null, "the scene has no environment")
	check(scene_env.ssao_enabled, "the scene environment has no SSAO")
	check(scene_env.ssil_enabled, "the scene environment has no SSIL")
	check(scene_env.volumetric_fog_enabled,
		"the scene environment has no volumetric fog")
	var fog_nodes := 0
	var probe_nodes := 0
	for c in main.get_children():
		if c is FogVolume:
			fog_nodes += 1
		elif c is ReflectionProbe:
			probe_nodes += 1
	print("scene fog volumes: %d, bounce probes: %d"
		% [fog_nodes, probe_nodes])
	check(fog_nodes == 1, "the scene has no FogVolume")
	check(probe_nodes == 4, "the scene has no bounce probe ring")

	# The chunk materials in the live scene must be the configured ones.
	var world: VoxelWorld = main.get("world")
	for i in 60:
		main.call("_process", 1.0 / 60.0)
	var textured := 0
	var pom := 0
	for c in world.get_children():
		if not (c is MeshInstance3D) or c.mesh == null:
			continue
		for s in c.mesh.get_surface_count():
			var mat := c.mesh.surface_get_material(s) as StandardMaterial3D
			if mat == null:
				continue
			if mat.albedo_texture != null:
				textured += 1
			if mat.heightmap_enabled:
				pom += 1
			# Never both: Godot drops the heightmap when triplanar is set.
			if mat.uv1_triplanar and mat.heightmap_enabled:
				check(false, "a live surface has triplanar and POM both on")
	print("live surfaces: %d textured, %d with POM" % [textured, pom])
	check(textured > 0, "no live surface has a texture")
	check(pom > 0, "no live surface has parallax occlusion")

	print("\nrender-settings: %s" % ("PASS" if failures == 0
		else "%d FAILURES" % failures))
	quit(1 if failures > 0 else 0)
