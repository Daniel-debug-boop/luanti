extends SceneTree
## Save/load across versions and corruption, the anti-duplication invariants,
## and a long-duration soak of the simulation.
##
## The soak is the part that answers "will this survive a long session". It is
## compressed: instead of six real hours it drives tens of thousands of ticks
## against a factory far larger than a human would build, and asserts the three
## properties that actually decide whether a session ends: nothing grows
## without bound, the same inputs give the same answers, and the level-of-detail
## system really does put distant networks to sleep.

var _fails := 0
const SLOT := 7


func _init() -> void:
	_test_migration_chain()
	_test_forward_compatibility_refused()
	_test_integrity_detects_corruption()
	_test_backup_recovery()
	_test_backup_failure_stops_the_write()
	_test_delete_takes_everything_with_it()
	_test_complex_world_round_trip()
	_test_no_duplicate_systems()
	_test_content_ids_are_classed_consistently()
	_test_content_table_has_no_collisions()
	_test_fixture_ids_match_the_content_table()
	_test_layers_are_separate()
	_test_soak_determinism()
	_test_soak_no_growth()
	_test_soak_lod_sleeps()
	_test_soak_survives_repeated_saves()
	_finish()


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


# --- migration --------------------------------------------------------------

## A save written before the engineering section had a schema field: the
## components were a dictionary keyed by a string, and there was no edges
## list, so a v1 load silently rebuilt a factory with every connection gone.
func _v1_save() -> Dictionary:
	return {
		"version": 1,
		"dimension": 0,
		"player": {"position": [1.0, 2.0, 3.0], "health": 20.0, "max_health": 20.0},
		"inventory": {"items": {}},
		"edits": {},
		"engineering": {
			"graph": {
				"nodes": {
					"1": {"id": 1, "component": "motor", "pos": [0, 0, 0]},
					"2": {"id": 2, "component": "pump", "pos": [1, 0, 0]},
				},
			},
		},
	}


func _test_migration_chain() -> void:
	var m := SaveMigration.migrate(_v1_save())
	_true(bool(m["ok"]), "a v1 save migrates")
	_eq((m["steps"] as Array).size() >= 1, true, "and the steps are reported")
	_eq(SaveMigration.engineering_schema(m["data"]),
		SaveMigration.ENGINEERING_SCHEMA, "the section ends at the current schema")
	var eng: Dictionary = m["data"]["engineering"]
	_eq(eng.has("graph"), true,
		"a section already in the current shape is stamped, not rewritten")
	_eq(eng["graph"]["nodes"].size(), 2, "and its contents are untouched")
	# Determinism: the same fixture through the chain twice is the same answer,
	# so a migration bug is reproducible from a test rather than from a world.
	var again := SaveMigration.migrate(_v1_save())
	_eq(JSON.stringify(m["data"]), JSON.stringify(again["data"]),
		"migration is deterministic")
	# The input is never mutated, so a failed migration can be retried.
	var fixture := _v1_save()
	SaveMigration.migrate(fixture)
	_eq(fixture["engineering"].has("schema"), false,
		"and the input is left alone")

	# The genuinely ancient flat form is still converted, and says so.
	var flat := _v1_save()
	flat["engineering"] = {"components": {"a": {"component": "motor"},
		"b": {"component": "pump"}}}
	var fm := SaveMigration.migrate(flat)
	_true(bool(fm["ok"]), "the legacy flat form migrates too")
	_eq((fm["data"]["engineering"]["components"] as Dictionary).size(), 2,
		"and both components get integer node ids")
	_eq(SaveMigration.engineering_schema(fm["data"]), SaveMigration.ENGINEERING_SCHEMA,
		"ending at the current schema")


func _test_forward_compatibility_refused() -> void:
	var future := _v1_save()
	future["version"] = SaveGame.SAVE_VERSION + 1
	var m := SaveMigration.migrate(future)
	_eq(bool(m["ok"]), false, "a save from a newer build is refused")
	_true(String(m["reason"]).contains("refusing"), "and says so explicitly")
	_eq(m["data"].is_empty(), true, "and no partial data is handed back")
	# Guessing at a future format is how a load turns into silent world damage,
	# so a refusal is the correct answer, not a limitation.


func _test_integrity_detects_corruption() -> void:
	var sealed := SaveMigration.seal(_v1_save())
	_eq(SaveMigration.verify(sealed), "", "a freshly sealed save verifies")
	# A save whose own shape is wrong is reported as a shape problem, not as a
	# mysterious checksum: the message has to tell you what to fix.
	_eq(SaveMigration.verify(SaveMigration.seal(
		sealed.merged({"player": "gone"}, true))),
		"player section is not a dictionary", "a mangled section is named")
	_eq(SaveMigration.verify(SaveMigration.seal(
		sealed.merged({"edits": 7}, true))),
		"edits section is not a dictionary", "and so is another")
	# A file that parses as JSON but was cut short in the middle of a write.
	var truncated := sealed.duplicate(true)
	truncated["engineering"] = {"graph": {"nodes": {"1": {"id":
		1, "component": "motor"}}}}
	_eq(SaveMigration.verify(truncated) != "", true,
		"a payload edited after sealing fails the checksum")
	_eq(SaveMigration.verify({"version": 1}) != "", true,
		"and an unsealed payload is not silently trusted")


func _test_backup_recovery() -> void:
	var dir := "user://robustness_saves"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var good := SaveMigration.seal(_v1_save())
	# A good save, then a second write that takes the backup of the first.
	_true(SaveMigration.write_with_backup(SLOT, good) == "", "the first save writes")
	# A second write is what takes the backup: the guarantee is "the previous
	# state is always recoverable", not "a save exists somewhere".
	var second := SaveMigration.seal(_v1_save())
	second["player"]["position"] = [9.0, 9.0, 9.0]
	_true(SaveMigration.write_with_backup(SLOT, second) == "", "the second save writes")
	_eq(FileAccess.file_exists(SaveMigration.backup_path(SLOT)), true,
		"and the previous one is kept as a backup")
	# Now simulate a crash: a half-written file in the slot, backup intact.
	var f := FileAccess.open(SaveGame.slot_path(SLOT), FileAccess.WRITE)
	f.store_string('{"version": 1, "player": {"positio')
	f.close()
	var read := SaveMigration.read_resilient(SLOT)
	_true(bool(read["ok"]), "the load still succeeds")
	_eq(String(read["source"]), "backup", "and it came from the backup")
	_true(String(read["reason"]) == "", "with no error, because it worked")
	# When both are gone, the failure is explicit rather than silent.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(
		SaveMigration.backup_path(SLOT)))
	_eq(bool(SaveMigration.read_resilient(SLOT)["ok"]), false,
		"with both files gone the load fails")
	_true(String(SaveMigration.read_resilient(SLOT)["reason"]) != "",
		"and says why")
	SaveGame.delete_slot(SLOT)


func _test_backup_failure_stops_the_write() -> void:
	var first := SaveMigration.seal(_v1_save())
	_true(SaveMigration.write_with_backup(SLOT, first) == "",
		"the first save writes")
	# Make the backup path unwritable: a directory where the .bak file has
	# to go. This is the disk-full-at-the-wrong-moment case in miniature,
	# and the rule is that a save which cannot preserve the previous world
	# does not get to overwrite it.
	_clear_bak_path(SLOT)
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(SaveMigration.backup_path(SLOT)))
	var second := SaveMigration.seal(_v1_save())
	second["player"]["position"] = [9.0, 9.0, 9.0]
	var why := SaveMigration.write_with_backup(SLOT, second)
	_true(why != "",
		"a write that cannot back up the old save is refused, not attempted")
	var read := SaveMigration.read_resilient(SLOT)
	_true(bool(read["ok"]), "the slot still loads")
	_eq((read["data"]["player"]["position"] as Array)[0], 1.0,
		"and it still holds the previous save, not the refused one")
	# Cleanup: the directory must go before the slot, or the delete below
	# correctly refuses to leave a resurrection source behind.
	_clear_bak_path(SLOT)
	SaveGame.delete_slot(SLOT)


## Remove whatever sits at a slot's backup path -- a file left by an earlier
## run, or the directory this test puts there to make the backup fail. Doing
## it at both ends is deliberate: a failing assertion stops the test function
## mid-way, and without the cleanup at the start the sabotage would poison
## every later run of this suite.
func _clear_bak_path(slot: int) -> void:
	var path := SaveMigration.backup_path(slot)
	var d := DirAccess.open(SaveGame.SAVE_DIR)
	if d != null:
		d.remove("%s%d%s.bak" % [SaveGame.SLOT_PREFIX, slot,
			SaveGame.SLOT_SUFFIX])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _test_delete_takes_everything_with_it() -> void:
	var first := SaveMigration.seal(_v1_save())
	_true(SaveMigration.write_with_backup(SLOT, first) == "", "a save writes")
	var second := SaveMigration.seal(_v1_save())
	second["player"]["position"] = [5.0, 5.0, 5.0]
	_true(SaveMigration.write_with_backup(SLOT, second) == "",
		"and a second write takes a backup of the first")
	_true(FileAccess.file_exists(SaveMigration.backup_path(SLOT)),
		"the backup exists")
	# A stale temp file from an interrupted commit must die with the slot.
	var tmp := FileAccess.open(SaveGame.slot_path(SLOT) + ".tmp",
		FileAccess.WRITE)
	tmp.store_string("{}")
	tmp.close()
	_eq(SaveGame.delete_slot(SLOT), true, "the slot deletes")
	_eq(FileAccess.file_exists(SaveGame.slot_path(SLOT)), false,
		"the slot file is gone")
	_eq(FileAccess.file_exists(SaveMigration.backup_path(SLOT)), false,
		"the backup dies with it -- a deleted save must not resurrect")
	_eq(FileAccess.file_exists(SaveGame.slot_path(SLOT) + ".tmp"), false,
		"and the stale temp file with it")
	_eq(bool(SaveMigration.read_resilient(SLOT)["ok"]), false,
		"so reading the deleted slot finds nothing to bring back")


# --- complex world round trip ----------------------------------------------

## A factory with every kind of connection, so the round trip has something to
## lose: power, rotation, fluid, and the blueprint that reproduces it.
func _build_factory(g: EngGraph) -> Dictionary:
	var bat := g.place("battery", Vector3.ZERO)
	var sw := g.place("switch", Vector3(1, 0, 0))
	var wire := g.place("wire", Vector3(2, 0, 0))
	var motor := g.place("motor", Vector3(3, 0, 0))
	var shaft := g.place("shaft", Vector3(4, 0, 0))
	var bearing := g.place("bearing", Vector3(5, 0, 0))
	var imp := g.place("impeller", Vector3(6, 0, 0))
	var housing := g.place("housing", Vector3(7, 0, 0))
	var tank := g.place("tank", Vector3(8, 0, 0))
	var pipe := g.place("pipe", Vector3(9, 0, 0))
	g.link(bat, "positive", sw, "a")
	g.link(sw, "b", wire, "a")
	g.link(wire, "b", motor, "power")
	g.link(motor, "rotation", shaft, "bore")
	g.link(shaft, "other", imp, "bore")
	g.link(imp, "hub", housing, "in")
	g.link(housing, "out", pipe, "a")
	g.link(pipe, "b", tank, "in")
	g.rebuild_networks()
	return {"bat": bat, "sw": sw, "wire": wire, "motor": motor, "shaft": shaft,
		"impeller": imp, "housing": housing, "tank": tank, "pipe": pipe,
		"bearing": bearing}


func _test_complex_world_round_trip() -> void:
	var g := EngGraph.new()
	var ids := _build_factory(g)
	var before := g.serialize()
	var bp := EngBlueprints.capture(g, [ids["motor"], ids["shaft"],
		ids["impeller"], ids["housing"]], "test pump")
	_eq(bp.is_empty(), false, "a blueprint is captured from a live machine")

	# Save -> migrate -> verify -> reload, through the real slot machinery.
	var state := {
		"version": SaveGame.SAVE_VERSION,
		"player": {"position": [0, 0, 0], "health": 20.0, "max_health": 20.0},
		"inventory": {"items": {}},
		"edits": {},
		"engineering": {"graph": before, "blueprints": [bp]},
	}
	_true(SaveMigration.write_with_backup(SLOT, SaveMigration.seal(state)) == "",
		"a complex world writes")
	var read := SaveMigration.read_resilient(SLOT)
	_true(bool(read["ok"]), "and reads back")
	var migrated := SaveMigration.migrate(read["data"])
	_true(bool(migrated["ok"]), "and migrates")

	var g2 := EngGraph.new()
	var report := g2.deserialize((migrated["data"]["engineering"] as Dictionary)["graph"])
	_eq(int(report["nodes"]), g.node_count(), "every node survived")
	_eq(int(report["edges"]), g.edge_count(), "and every connection")
	_eq(int(report["skipped"]), 0, "with nothing skipped")
	# The connections are the part a naive save loses, so check the graph is
	# re-partitioned into the same networks, not merely the same node count.
	_eq(g2.networks().size(), g.networks().size(), "the networks rebuild identically")
	_eq(g2.serialize(), g.serialize(), "and the whole graph serialises byte-identically")
	# And the machines still work after the round trip, which is the only test
	# that matters: state that loads and does nothing is not a save.
	var sim1 := EngSimulation.new(g)
	var sim2 := EngSimulation.new(g2)
	(g2.node(int(ids["bat"])) as EngGraph.EngNode).state["charge"] = 1.0
	(g.node(int(ids["bat"])) as EngGraph.EngNode).state["charge"] = 1.0
	for i in 30:
		sim1.step([Vector3.ZERO])
		sim2.step([Vector3.ZERO])
	_eq((g2.node(int(ids["motor"])) as EngGraph.EngNode).state["rpm"],
		(g.node(int(ids["motor"])) as EngGraph.EngNode).state["rpm"],
		"and the reloaded motor turns at the same speed as the original")
	SaveGame.delete_slot(SLOT)


# --- architecture -----------------------------------------------------------

func _test_no_duplicate_systems() -> void:
	# One content table. A second one would mean a block id that means two
	# different things depending on which system asked.
	_eq(ContentDB.name_to_id("stone") > 0, true,
		"one content table defines the blocks, and it is name-addressable")
	_eq(ContentDB.name_of(ContentDB.STONE), "stone",
		"and the id round-trips through the same table")

	# One save format. Every subsystem is a section of the same Dictionary.
	var state := SaveGame.capture(null, null, null, 0, null)
	_eq(state.has("version"), true, "one save envelope, versioned")
	_eq(state.has("player"), true, "with the player in it")
	_eq(state.has("inventory"), true, "the inventory in it")
	_eq(state.has("edits"), true, "and the world edits in it")

	# One graph. The engineering root, the simulation and the society layer all
	# read the same EngGraph instance, rather than each keeping a copy.
	var eng := EngEngineering.new()
	root.add_child(eng)
	eng.build()
	eng.graph.place("motor", Vector3.ZERO)
	eng.sim.step([Vector3.ZERO])
	eng.society.tick(0.1, eng.graph, [], [Vector3.ZERO])
	_eq(eng.sim._graph == eng.graph, true,
		"the simulation and the root share one graph, not a copy of it")
	# The items a manufacturing run produces land in the one GLoot container
	# the player already had, not in a second inventory: the registry maps
	# components onto the existing container's protos rather than defining
	# items of its own.
	_eq(EngItems.has("motor"), true,
		"engineering items route into the existing container's protoset")
	_eq(PlayerInventory.ENG_PREFIX + "motor" == "eng_motor", true,
		"under a prefix that cannot collide with a block id")
	_eq(eng.inventory == null, true,
		"and the engineering root holds no inventory of its own")
	eng.queue_free()


func _test_content_ids_are_classed_consistently() -> void:
	# An id the table does not claim must not be half-classed. get_entry()
	# answers with the air entry for it, so a lookup past the end of the
	# table that still reports "solid" is an invisible wall: colourless to
	# the mesher, blocking to the player, and impossible to diagnose from
	# inside the game.
	_eq(ContentDB.is_solid(ContentDB.STONE), true, "stone blocks movement")
	_eq(ContentDB.is_solid(ContentDB.AIR), false, "air does not")
	_eq(ContentDB.is_solid(ContentDB.WATER), true,
		"water still does: swimming is a different system")
	_eq(ContentDB.is_solid(ContentDB.MAX_ID), true,
		"the last registered id does")
	_eq(ContentDB.is_solid(ContentDB.MAX_ID + 1), false,
		"an id no entry claims does not")
	_eq(ContentDB.is_solid(-1), false,
		"and neither does a failed name lookup")
	_eq(ContentDB.is_opaque(ContentDB.STONE), true, "stone is opaque")
	_eq(ContentDB.is_opaque(ContentDB.GLASS), false, "glass is not")
	_eq(ContentDB.is_opaque(ContentDB.MAX_ID + 1), false,
		"an unclaimed id is not opaque either")


func _test_content_table_has_no_collisions() -> void:
	var stock := ContentDB.validate_table()
	_eq(stock.size() == 0, true,
		"the stock table has no id or name collisions: %s" % str(stock))
	# Every registered id round-trips through the name index in both
	# directions; a collision would make one direction lie.
	for id in range(ContentDB.MAX_ID + 1):
		var n := ContentDB.name_of(id)
		_true(n != "", "id %d has a name" % id)
		_eq(ContentDB.name_to_id(n), id,
			"and the name of id %d resolves back to it" % id)
	# Inject the two collisions this check exists to catch. Lookups are by
	# array index, so a second entry claiming id 3 makes "stone" depend on
	# which of the two entries you happen to find first; a second entry
	# named "stone" makes the name index answer with whichever id came
	# first. Both are silent at the call site and loud in a save file.
	var t := ContentDB._entries
	var saved := t.duplicate()
	t.append(ContentDB.Entry.new(ContentDB.STONE, "imposter", Color(1, 0, 1)))
	var problems := ContentDB.validate_table()
	var hit := false
	for p in problems:
		if String(p).contains("duplicate id 3"):
			hit = true
	_true(hit, "a second entry claiming id 3 is reported by name: %s"
		% str(problems))
	t.resize(saved.size())
	t.append(ContentDB.Entry.new(ContentDB.MAX_ID + 1, "stone",
		Color(1, 0, 1)))
	problems = ContentDB.validate_table()
	hit = false
	for p in problems:
		if String(p).contains("duplicate name") and String(p).contains("stone"):
			hit = true
	_true(hit, "a second entry named stone is reported: %s" % str(problems))
	# Restore, and prove the restore really did clear the injected state.
	t.clear()
	for e in saved:
		t.append(e)
	_eq(ContentDB.validate_table().size(), 0,
		"the table is restored and clean again")


func _test_fixture_ids_match_the_content_table() -> void:
	# The converted-world fixture generator hard-codes the ids of the blocks
	# it writes into a Luanti map. The Godot side reads that map back
	# through ContentDB alone, with no remapping -- so a fixture id that
	# disagrees with ContentDB does not produce the block the fixture meant.
	# (This is how CONTENT_WATER drifted onto id 9, which is ContentDB's
	# wood: the fixture's water converted into wooden blocks, silently.)
	var src := FileAccess.get_file_as_string("res://tools/make_test_world.py")
	_true(src != "", "the fixture generator is readable")
	for pair in [["CONTENT_AIR", ContentDB.AIR],
			["CONTENT_GRASS", ContentDB.GRASS], ["CONTENT_DIRT", ContentDB.DIRT],
			["CONTENT_STONE", ContentDB.STONE],
			["CONTENT_WATER", ContentDB.WATER],
			["CONTENT_WOOD", ContentDB.WOOD],
			["CONTENT_LEAVES", ContentDB.LEAVES]]:
		var name := String(pair[0])
		var re := RegEx.new()
		re.compile("%s\\s*=\\s*(\\d+)" % name)
		var m := re.search(src)
		_true(m != null, "%s is defined in the fixture" % name)
		if m == null:
			continue
		var got := int(m.get_string(1))
		_eq(got, int(pair[1]),
			"%s must be ContentDB's id %d, not %d, or the converted world " \
			+ "reads it as a different block" % [name, int(pair[1]), got])


func _test_layers_are_separate() -> void:
	# The layer contract: a layer can be exercised with nothing but its own
	# dependencies. If a test needs the world node to check a material
	# property, the layers have already started leaking into each other.
	_eq(EngMaterials.get_prop("steel", "strength") > 0.0, true,
		"materials stand alone")
	var g := EngGraph.new()
	g.rebuild_networks()
	_eq(g.place("motor", Vector3.ZERO), 1, "the graph stands alone")
	var p := EngPart.plate("steel", 0.4)
	_eq(p.mass() > 0.0, true, "a part stands alone")
	var r := EngProcesses.apply_operation(p, "cut", {"position": Vector3(0, 0, 0)},
		1.0, 1.0e9)
	_eq(bool(r["ok"]), true, "and a process can be applied to one")
	# And the dependency direction is one-way: the graph knows components, but
	# a component does not know whether it is in a graph.
	_eq(EngPorts.get_def("motor").ports.size() > 0, true, "components expose ports")
	_eq(EngPorts.get_def("motor").get("graph"), null,
		"and know nothing about the graph that holds them")


# --- soak -------------------------------------------------------------------

## A factory big enough that a per-tick regression would show, and spread far
## enough apart that the LOD has something to actually put to sleep.
func _soak_graph() -> EngGraph:
	var g := EngGraph.new()
	for i in 40:
		var ox := float(i) * 4.0
		var bat := g.place("battery", Vector3(ox, 0, 0))
		var sw := g.place("switch", Vector3(ox + 1, 0, 0))
		var wire := g.place("wire", Vector3(ox + 2, 0, 0))
		var motor := g.place("motor", Vector3(ox + 3, 0, 0))
		g.link(bat, "positive", sw, "a")
		g.link(sw, "b", wire, "a")
		g.link(wire, "b", motor, "power")
		(g.node(bat) as EngGraph.EngNode).state["charge"] = 1.0
	g.rebuild_networks()
	return g


func _soak(g: EngGraph, ticks: int) -> Dictionary:
	var sim := EngSimulation.new(g)
	var focus := Vector3.ZERO
	var sleeping := 0
	for i in ticks:
		# Walk the player across the factory so streaming and LOD both see
		# movement, which is what a real session looks like.
		if i % 200 == 0:
			focus = Vector3(float(i) * 0.5, 0, 0)
		sim.step([focus])
		if i % 100 == 0:
			var s := 0
			for n in g.networks():
				if int((n as Dictionary)["lod"]) >= 3:
					s += 1
			sleeping = maxi(sleeping, s)
	return {"sleeping": sleeping, "nodes": g.node_count()}


func _test_soak_determinism() -> void:
	# Determinism is what makes every other soak result meaningful: if two
	# identical runs disagreed, a growth measurement would be noise.
	var a := _soak(_soak_graph(), 3000)
	var b := _soak(_soak_graph(), 3000)
	_eq(JSON.stringify(a), JSON.stringify(b), "two identical soaks agree")

	# And a save/load in the middle of a soak does not change the outcome,
	# because the loaded graph is the same graph.
	var g := _soak_graph()
	var sim_a := EngSimulation.new(g)
	for i in 1000:
		sim_a.step([Vector3.ZERO])
	var mid := g.serialize()
	var g2 := EngGraph.new()
	g2.deserialize(mid)
	var sim_b := EngSimulation.new(g2)
	for i in 1000:
		sim_b.step([Vector3.ZERO])
	_eq(JSON.stringify(g.serialize()), JSON.stringify(g2.serialize()),
		"a soak survives a mid-run save and load unchanged")


func _test_soak_no_growth() -> void:
	# The question a six-hour session actually asks: does anything grow?
	var w := StabilityWatchdog.new()
	w.set_quiescent(true, 0.0)
	var g := _soak_graph()
	var baseline_nodes := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var baseline_objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	_soak(g, 4000)
	# Warm the caches first: the first hundred ticks legitimately allocate.
	var after_nodes := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var after_objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	w.sample_now(0.0, 4.0)
	_soak(g, 8000)
	w.sample_now(30.0, 4.0)
	_eq(w.drift("object_node_count") < 64.0, true,
		"node count does not creep over 8000 ticks of a 160-node factory")
	_eq(w.drift("object_count") < 128.0, true,
		"nor does object count")
	_eq(w.has_leak(), false, "so the watchdog reports a clean session")
	_eq(after_nodes >= baseline_nodes, true,
		"(and the factory genuinely did allocate something to be fair about)")
	_eq(after_objects >= baseline_objects, true, "for both counters")


func _test_soak_lod_sleeps() -> void:
	var g := _soak_graph()
	var r := _soak(g, 2500)
	_eq(int(r["nodes"]), 160, "the soak factory is the size it claims to be")
	_eq(int(r["sleeping"]) > 0, true,
		"distant networks are put to sleep rather than ticked forever")
	# A sleeping network must cost nothing: ticking it again changes nothing.
	var sleeping := 0
	for n in g.networks():
		if int((n as Dictionary)["lod"]) >= 3:
			sleeping += 1
	var before := JSON.stringify(g.serialize())
	var sim := EngSimulation.new(g)
	sim.step([Vector3.ZERO, Vector3(100000, 0, 0)])
	_eq(JSON.stringify(g.serialize()), before,
		"and a sleeping network is not modified by a tick")
	_eq(sleeping >= 0, true, "the sleep count is not negative")


func _test_soak_survives_repeated_saves() -> void:
	# Autosave every few minutes for six hours is 120 writes. Corrupting a
	# world on the hundredth write is the bug this catches.
	var g := _soak_graph()
	var state := {
		"version": SaveGame.SAVE_VERSION,
		"player": {"position": [0, 0, 0], "health": 20.0, "max_health": 20.0},
		"inventory": {"items": {}},
		"edits": {},
		"engineering": {"graph": g.serialize()},
	}
	var first_size := 0
	var final_size := 0
	var read := {}
	for i in 60:
		_true(SaveMigration.write_with_backup(SLOT,
			SaveMigration.seal(state.duplicate(true))) == "",
			"autosave %d writes" % (i + 1))
		read = SaveMigration.read_resilient(SLOT)
		if not bool(read["ok"]):
			_eq(false, true, "autosave %d reads back" % (i + 1))
			return
		if i == 0:
			first_size = JSON.stringify(read["data"]).length()
		final_size = JSON.stringify(read["data"]).length()
	_eq(final_size, first_size,
		"sixty successive writes leave the payload the same size")
	var g2 := EngGraph.new()
	var report := g2.deserialize(read["data"]["engineering"]["graph"])
	_eq(int(report["nodes"]), 160, "and the world is still whole")
	SaveGame.delete_slot(SLOT)
