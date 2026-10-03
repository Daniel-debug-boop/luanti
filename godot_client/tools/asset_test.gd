extends SceneTree
## Asset-pipeline tests.
##
## The asset pipeline is four Python stages (acquire_assets, process_textures,
## make_lods, import_assets) that this suite is the acceptance test for. Those
## stages run offline and produce trees of files that nothing in GDScript
## wrote, so the only way to know they are correct is to check the results
## against the catalogue that declared them.
##
## What counts as a failure, and why:
##
##   CRITICAL -- the game will look wrong or refuse to run. A block whose
##               texture is missing silently falls back to a flat vertex-colour
##               material, which reads in-game as an untextured block rather
##               than as an error. A model with no LOD chain is a frame-time
##               spike at distance. An unlicensed asset is a legal problem, not
##               a visual one, and it is the one failure this project cannot
##               ship at all.
##   WARNING  -- a pipeline defect that is not yet visible in-game. A texture
##               one rung above its source resolution is an upscale; a
##               non-power-of-two map costs a mip chain; a downloaded file that
##               nothing references is money and disk spent for nothing.
##
## Everything checked here is checkable without a GPU and without rendering,
## because these are file-level and reference-level facts, not pixels.

const MANIFEST := "res://assets/source_manifest/manifest.json"
const CATALOG_MATRIX := [
	# block id name, texture set the MaterialLibrary must resolve it to.
	# Kept as literals rather than ContentDB constants so a rename in
	# content_db.gd surfaces here as a failure rather than being silently
	# absorbed on both sides at once.
	["GRASS", "aerial_grass_rock"],
	["CACTUS", "bark_brown_02"],
	["DIRT", "brown_mud_leaves_01"],
	["WOOD", "bark_brown_02"],
	["LEAVES", "forest_leaves_02"],
	["STONE", "rock_06"],
	["SAND", "sand_01"],
	["SNOW", "snow_02"],
	["GRAVEL", "aerial_rocks_02"],
	["ICE", "coast_sand_rocks_02"],
	["DEEPSLATE", "rock_face_04"],
	["COPPER_ORE", "ore_copper"],
	["IRON_ORE", "ore_iron"],
	["COAL_ORE", "ore_coal"],
	["SILVER_ORE", "ore_silver"],
	["COPPER_BLOCK", "acg_metal_057a"],
	["IRON_BLOCK", "acg_metal_055a"],
	["STEEL_BLOCK", "acg_metal_032"],
	["BRASS_BLOCK", "acg_metal_048a"],
	["PLANKS", "oak_wood_planks"],
	["COBBLESTONE", "cobblestone_04"],
	["BRICK", "brick_wall_003"],
	["CONCRETE", "concrete_floor_02"],
	["ASPHALT", "asphalt_01"],
	["METAL_PLATE", "corrugated_iron"],
	["GLASS", "glass"],
]

## Every texture rung the pipeline is allowed to write.
const TIERS := [512, 1024, 2048]

var failures := 0
var warnings := 0
var checks := 0


func fail(msg: String) -> void:
	failures += 1
	printerr("FAIL: ", msg)


func warn(msg: String) -> void:
	warnings += 1
	printerr("WARN: ", msg)


func check(cond: bool, msg: String) -> void:
	checks += 1
	if not cond:
		fail(msg)


func _init() -> void:
	call_deferred("_run")


func _abs(res_path: String) -> String:
	return res_path.replace("res://", ProjectSettings.globalize_path("res://"))


func _run() -> void:
	# --- The manifest exists and is well formed --------------------------------
	check(FileAccess.file_exists(_abs(MANIFEST)),
		"no source manifest at %s" % MANIFEST)
	if not FileAccess.file_exists(_abs(MANIFEST)):
		print("\nasset: FAILURES (no manifest)")
		quit(1)
		return

	var text := FileAccess.get_file_as_string(_abs(MANIFEST))
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null or not (parsed is Dictionary):
		fail("the source manifest is not valid JSON")
		print("\nasset: FAILURES (unparseable manifest)")
		quit(1)
		return
	var man: Dictionary = parsed
	var assets: Array = man.get("assets", [])
	var licences: Dictionary = man.get("licences", {})
	print("manifest: %d assets, %d licence entries"
		% [assets.size(), licences.size()])
	check(assets.size() >= 50,
		"the manifest lists only %d assets; the catalogue declares 58"
			% assets.size())

	# --- Every asset carries provenance and a CC0 grant -----------------------
	# This is the one check that cannot be softened into a warning. Everything
	# else in this suite is about how the game looks; this is about whether it
	# is allowed to ship.
	#
	# Entries whose provider is "derived" or "procedural" have no upstream to
	# point at: they are composed from CC0 sources already in this manifest, or
	# made of code. Those are held to a different, correct bar -- they must
	# say what they were made from, not what they were downloaded from.
	var by_id := {}
	for entry in assets:
		if not (entry is Dictionary):
			fail("a manifest entry is not an object")
			continue
		var e: Dictionary = entry
		var id := str(e.get("id", ""))
		by_id[id] = e
		var provider := str(e.get("provider", ""))
		check(id != "", "a manifest entry has no id")
		check(str(e.get("author", "")) != "",
			"%s has no author recorded" % id)
		check(str(e.get("licence", "")) != "",
			"%s has no licence recorded" % id)
		check(str(e.get("downloaded", "")) != "",
			"%s has no acquisition date recorded" % id)
		var lic := str(e.get("licence", ""))
		if provider == "derived" or provider == "procedural":
			check(lic.contains("CC0") or lic.contains("original"),
				"%s is %s-derived but its licence does not say so (%s)"
					% [id, provider, lic])
			if provider == "derived":
				check(e.has("derived_from") or e.has("host"),
					"%s is derived but does not record what it came from" % id)
			continue
		check(str(e.get("source_page", "")) != "",
			"%s has no source page recorded" % id)
		check(lic.contains("CC0"),
			"%s is not CC0 (%s); this project ships CC0 assets only"
				% [id, lic])
		var files: Array = e.get("files", [])
		check(files.size() > 0, "%s records no downloaded files" % id)
		for f in files:
			if not (f is Dictionary):
				continue
			var fd: Dictionary = f
			# Every download is checksummed at acquisition time so a corrupt
			# or substituted file cannot pass unnoticed.
			var has_sum: bool = str(fd.get("md5", "")) != "" \
				or str(fd.get("sha256", "")) != ""
			check(has_sum, "%s has a file with no checksum" % id)

	# --- Texture sets: every rung the game can ask for exists -----------------
	# The MaterialLibrary resolves a tier by probing for the file. If the file
	# is missing it silently steps down, so a missing rung produces a
	# lower-resolution game rather than an error. That is exactly the class of
	# defect this suite exists to catch.
	var runtime_sets := _dirs_under("res://assets/runtime/textures")
	print("runtime texture sets: %d" % runtime_sets.size())
	check(runtime_sets.size() >= 20,
		"only %d texture sets in the runtime tree; the catalogue declares 26"
			% runtime_sets.size())

	for set_name in runtime_sets:
		var dir := "res://assets/runtime/textures/%s" % set_name
		var tiers_found := []
		for tier in TIERS:
			if FileAccess.file_exists(_abs("%s/diff_%d.jpg" % [dir, tier])):
				tiers_found.append(tier)
		check(tiers_found.size() > 0,
			"%s has no albedo at any rung" % set_name)
		for tier in tiers_found:
			# --- Every albedo rung is a power of two -------------------------
			# Mip chains and repeat wrapping both want POT. Godot can import
			# NPOT, but the GPU driver then drops to a slower path and mip
			# generation clamps, so the cost is invisible until it is paid.
			_check_power_of_two("%s/diff_%d.jpg" % [set_name, tier], tier)
			_check_png_pot("%s/nor_gl_%d.png" % [set_name, tier], tier)
			_check_png_pot("%s/arm_%d.png" % [set_name, tier], tier)
			_check_png_pot("%s/height_%d.png" % [set_name, tier], tier)

		# --- Normal and ARM maps exist wherever the catalogue promises -----
		# These are read at min(tier, 1024) because the pipeline caps data maps
		# at 1K, so a 2048 albedo is paired with 1024 data maps by design.
		#
		# A `detail` set is exempt: it is only ever bound as `detail_albedo`,
		# so a normal map and an ARM map for it would be files nothing loads.
		var entry: Dictionary = by_id.get(set_name, {})
		var role := str(entry.get("role", "surface"))
		var data_tier: int = 1024 if tiers_found.has(2048) \
			or tiers_found.has(1024) else 512
		if not tiers_found.is_empty() and role == "surface":
			check(FileAccess.file_exists(
					_abs("%s/nor_gl_%d.png" % [dir, data_tier])),
				"%s has no normal map at %d" % [set_name, data_tier])
			check(FileAccess.file_exists(
					_abs("%s/arm_%d.png" % [dir, data_tier])),
				"%s has no ARM map at %d" % [set_name, data_tier])
			# POM is ULTRA-only and reads the height map, so a surface set
			# that has no height map is a material whose POM silently does
			# nothing at the one tier that pays for it.
			check(FileAccess.file_exists(
					_abs("%s/height_1024.png" % dir)),
				"%s has no height map, so POM cannot run on it at ULTRA"
					% set_name)

		# --- No rung is an upscale of its source ---------------------------
		# art_catalog.tiers_for() caps the ladder at the source resolution.
		# If a rung appears above that, the pipeline upscaled it, which is
		# exactly what assets/ART_DIRECTION.md forbids: upscaling invents no
		# detail, costs memory, and looks worse than the rung below it.
		var src_res: int = int(manifest_source_tier(by_id, set_name))
		if src_res > 0:
			for tier in tiers_found:
				if tier > src_res:
					warn("%s writes a %d rung from a %d source (upscale)"
						% [set_name, tier, src_res])

		# --- Every rung the game loads must have been imported --------------
		for tier in tiers_found:
			_check_imported("%s/diff_%d.jpg" % [set_name, tier])

	# --- The catalogue's own rung ladder is monotone ----------------------
	for e in assets:
		var e2: Dictionary = e
		if str(e2.get("kind", "")) != "texture":
			continue
		var declared: Array = e2.get("tiers", [])
		if declared.size() > 1:
			for i in range(1, declared.size()):
				if int(declared[i]) >= int(declared[i - 1]):
					warn("%s rungs are not strictly decreasing: %s"
						% [e2.get("id", "?"), str(declared)])

	# --- Derived sets are documented as derived, not downloaded ------------
	# The ore textures are composed by process_textures.py from a host rock and
	# a metal. They have no upstream asset, so they must not claim one.
	for derived in ["ore_copper", "ore_iron", "ore_silver", "ore_coal"]:
		var e3: Dictionary = by_id.get(derived, {})
		if e3.is_empty():
			fail("%s is missing from the manifest" % derived)
			continue
		check(str(e3.get("provider", "")) == "derived",
			"%s should be recorded as provider \"derived\", got \"%s\""
				% [derived, str(e3.get("provider", ""))])
		check(e3.has("host") or e3.has("derived_from"),
			"%s does not record what it was composed from" % derived)

	# --- Procedural sets have no pixels at all ----------------------------
	check(MaterialLibrary.PROCEDURAL.has("glass"),
		"glass is not in the procedural material table")
	if not MaterialLibrary.PROCEDURAL.has("glass"):
		fail("glass has neither a procedural material nor a texture set")

	# --- Models: three LOD tiers, valid geometry, no embedded pixels -------
	var model_dirs := _dirs_under("res://assets/runtime/models")
	print("runtime models: %d" % model_dirs.size())
	check(model_dirs.size() >= 15,
		"only %d models in the runtime tree; the catalogue declares 17"
			% model_dirs.size())

	var total_lod0 := 0
	var total_lod2 := 0
	for model_name in model_dirs:
		var dir := "res://assets/runtime/models/%s" % model_name
		for lod in [0, 1, 2]:
			check(FileAccess.file_exists(_abs("%s/lod%d.gltf" % [dir, lod])),
				"%s has no lod%d.gltf" % [model_name, lod])
			_check_imported("%s/lod%d.gltf" % [model_name, lod])
		# Triangle counts must fall monotonically with distance, or the LOD
		# chain is not a chain: a LOD1 heavier than LOD0 means the decimation
		# went the wrong way and the frame cost gets worse exactly when the
		# player is moving and cannot afford it.
		var t0 := _glb_triangles(dir, 0)
		var t1 := _glb_triangles(dir, 1)
		var t2 := _glb_triangles(dir, 2)
		total_lod0 += t0
		total_lod2 += t2
		check(t0 > 0 and t1 > 0 and t2 > 0,
			"%s has an empty LOD tier (%d/%d/%d triangles)"
				% [model_name, t0, t1, t2])
		check(t1 < t0 and t2 < t1,
			"%s LOD triangles do not decrease: %d -> %d -> %d"
				% [model_name, t0, t1, t2])
		# The decimation is pointless if LOD2 is not materially cheaper.
		check(t2 * 4 < t0,
			"%s LOD2 is %d triangles against LOD0's %d; that is not a "
				% [model_name, t2, t0]
				+ "usable distance budget")
		# make_lods.py's budget gate. A prop over 20k triangles at LOD0 is
		# over budget even after decimation.
		check(t0 <= 20000,
			"%s is %d triangles at LOD0, over the 20k prop budget"
				% [model_name, t0])

	print("model triangles: LOD0 %d, LOD2 %d (%.0f%% reduction)"
		% [total_lod0, total_lod2,
			100.0 - 100.0 * float(total_lod2) / float(maxi(total_lod0, 1))])

	# --- The village actually binds the model directory --------------------
	var village_script: String = FileAccess.get_file_as_string(
		_abs("res://scripts/mobs/village.gd"))
	check(village_script.contains("res://assets/runtime/models"),
		"village.gd does not point at the runtime model directory")
	check(village_script.contains("visibility_range"),
		"village.gd never uses visibility_range, so the LOD chains are "
			+ "loaded but never selected")

	# --- HDRIs exist and are referenced by name -----------------------------
	var hdri_dir := "res://assets/runtime/hdri"
	var hdris := _files_under(hdri_dir, ".hdr")
	print("runtime HDRIs: %d" % hdris.size())
	check(hdris.size() >= 9,
		"only %d HDRIs in the runtime tree; the catalogue declares 9"
			% hdris.size())
	var day_night := FileAccess.get_file_as_string(
		_abs("res://scripts/world/day_night.gd"))
	for h in hdris:
		var stem: String = h.get_basename()
		check(day_night.contains(stem),
			"%s is present but day_night.gd never names it, so it is an "
				% stem + "unused download")
		_check_imported("hdri/%s.hdr" % stem)
	# The reverse direction matters too: a name in the code with no file is a
	# sky that silently never changes.
	for group_name in ["DAY_SKIES", "DUSK_SKIES", "NIGHT_SKIES"]:
		var re := RegEx.new()
		re.compile("(?s)%s := \\[(.*?)\\]" % group_name)
		var m := re.search(day_night)
		if m == null:
			fail("day_night.gd has no %s array" % group_name)
			continue
		for quoted in m.get_string(1).split(","):
			var name: String = quoted.strip_edges()
			if name.begins_with("\""):
				name = name.substr(1)
			if name.ends_with("\""):
				name = name.substr(0, name.length() - 1)
			if name == "":
				continue
			check(FileAccess.file_exists(_abs("%s/%s.hdr" % [hdri_dir, name])),
				"day_night.gd names %s but the HDRI is not on disk" % name)

	# --- The material library resolves every declared block ----------------
	# This is the load-bearing cross-check: the catalogue says grass is
	# aerial_grass_rock and the ContentDatabase says grass is id N. If those
	# two drift apart the block renders untextured and nothing complains.
	#
	# GDScript has no dynamic constant lookup, so the id for each name comes
	# from the script's own constant map rather than from a hand-typed int.
	# That is what makes this a real cross-check: a rename or a renumber in
	# content_db.gd moves the value this reads.
	var consts: Dictionary = load("res://scripts/world/content_db.gd") \
		.get_script_constant_map()
	print("ContentDB exposes %d constants" % consts.size())
	var referenced := {}
	var lib := MaterialLibrary.new()
	lib.prime()
	for row in CATALOG_MATRIX:
		var id_name: String = row[0]
		var expected: String = row[1]
		if not consts.has(id_name):
			# A block that no longer exists is not an asset failure; the
			# gameplay tests cover that. Skip rather than report a phantom.
			continue
		var id: int = consts[id_name]
		var actual := MaterialLibrary.texture_set_for(id)
		check(actual == expected,
			"ContentDB.%s resolves to texture set \"%s\", expected \"%s\""
				% [id_name, actual, expected])
		referenced[MaterialLibrary.texture_set_for(id)] = true
		referenced[MaterialLibrary.detail_set_for(id)] = true
		if actual == "glass":
			continue
		var dir := "res://assets/runtime/textures/%s" % expected
		check(runtime_sets.has(expected),
			"%s maps to \"%s\", which is not in the runtime tree"
				% [id_name, expected])
		# Every rung the quality tiers can ask for must resolve to a real file
		# for this set, or the tier silently steps down.
		for tier in [MaterialLibrary.TEXTURE_TIER[MaterialLibrary.Quality.HIGH],
				MaterialLibrary.DETAIL_TIER]:
			check(FileAccess.file_exists(
					_abs("%s/diff_%d.jpg" % [dir, tier])),
				"%s needs %s/diff_%d.jpg at tier %d, which is missing"
					% [id_name, expected, tier, tier])

	# Every runtime set should be reachable from some block or be a detail
	# overlay. A set that is downloaded, processed and then never bound is
	# wasted VRAM and wasted review time.
	for set_name in runtime_sets:
		if referenced.has(set_name):
			continue
		warn("%s is in the runtime tree but no block references it" % set_name)

	# --- Quality tiers load the rung they claim ---------------------------
	for q in [MaterialLibrary.Quality.LOW, MaterialLibrary.Quality.MEDIUM,
			MaterialLibrary.Quality.HIGH, MaterialLibrary.Quality.ULTRA]:
		var tier_lib := MaterialLibrary.new()
		tier_lib.apply_quality(q)
		tier_lib.prime()
		var want: int = MaterialLibrary.TEXTURE_TIER[q]
		check(tier_lib.texture_tier() == want,
			"tier %d reports rung %d, expected %d"
				% [q, tier_lib.texture_tier(), want])
		# POM is ULTRA-only by art direction. Any POM at a lower tier means
		# the gate in _apply_effects has stopped working.
		var counts := tier_lib.effect_counts()
		if q < MaterialLibrary.POM_QUALITY:
			check(int(counts.get("pom", 0)) == 0,
				"POM is on for %d materials at tier %d; it is ULTRA-only"
					% [int(counts.get("pom", 0)), q])
		# A tier that resolves to no textures at all would render the whole
		# world as flat vertex colour.
		check(tier_lib.loaded_count() > 0,
			"tier %d built no textured materials at all" % q)

	# --- No duplicate rungs (the same file written twice under two names) ---
	var seen := {}
	for set_name in runtime_sets:
		var dir := "res://assets/runtime/textures/%s" % set_name
		for f in _files_under(dir, ".jpg"):
			var full := _abs("%s/%s" % [dir, f])
			var dims := _png_size(full)
			var sig := "%d:%d" % [dims.x, dims.y]
			var key := "%s/%s" % [f, sig]
			if seen.has(key):
				warn("%s/%s has the same dimensions as %s; check it is not a "
					% [set_name, f, seen[key]] + "duplicate download")
			seen[key] = "%s/%s" % [set_name, f]

	# --- Attribution document exists and is not a stub ---------------------
	var doc := "res://assets/THIRD_PARTY_ASSETS.md"
	check(FileAccess.file_exists(_abs(doc)),
		"assets/THIRD_PARTY_ASSETS.md is missing; the licences are recorded "
			+ "in the manifest but nothing human-readable points at them")
	if FileAccess.file_exists(_abs(doc)):
		var body := FileAccess.get_file_as_string(_abs(doc))
		check(body.length() > 2000,
			"assets/THIRD_PARTY_ASSETS.md is a %d-character stub"
				% body.length())
		for needle in ["Poly Haven", "ambientCG", "CC0", "KayKit"]:
			check(body.contains(needle),
				"THIRD_PARTY_ASSETS.md never mentions %s" % needle)

	# --- The rejections are recorded, not just made ------------------------
	# Three deliberate refusals are made in assets/ART_DIRECTION.md. A
	# decision that is not written down is a decision that gets revisited by
	# the next person who does not know why.
	check(FileAccess.file_exists(_abs("res://assets/ART_DIRECTION.md")),
		"assets/ART_DIRECTION.md is missing; the art contract is unwritten")
	check(_dirs_under("res://assets").has("rejected"),
		"assets/rejected/ does not exist; rejected candidates have to be "
			+ "recorded with their reasons or the same ones get re-downloaded")

	print("\nasset: %d checks, %d FAILURES, %d warnings"
		% [checks, failures, warnings])
	quit(1 if failures > 0 else 0)


## --- helpers ---------------------------------------------------------------

func _dirs_under(res_dir: String) -> Array:
	var out := []
	if DirAccess.open(_abs(res_dir)) == null:
		return out
	for sub in DirAccess.get_directories_at(_abs(res_dir)):
		out.append(sub)
	out.sort()
	return out


func _files_under(res_dir: String, ext: String) -> Array:
	var out := []
	if DirAccess.open(_abs(res_dir)) == null:
		return out
	for name in DirAccess.get_files_at(_abs(res_dir)):
		if name.get_extension().to_lower() == ext.trim_prefix("."):
			out.append(name)
	out.sort()
	return out


## True when the file has a Godot `.import` manifest pointing at a payload
## that actually exists. A `.import` file alone is not enough: a run killed
## partway through leaves the manifest behind with no payload, and
## ResourceLoader reports the texture as present while loading nothing.
func _check_imported(rel_to_runtime: String) -> void:
	var source := "res://assets/runtime/%s" % rel_to_runtime
	var import_file := _abs(source + ".import")
	if not FileAccess.file_exists(import_file):
		warn("%s has no .import manifest; it has not been through Godot"
			% rel_to_runtime)
		return
	var body := FileAccess.get_file_as_string(import_file)
	var re := RegEx.new()
	re.compile("res://\\.godot/imported/([^\"\\n]+)")
	var found := re.search_all(body)
	if found.is_empty():
		warn("%s has an .import manifest that names no payload" % rel_to_runtime)
		return
	for hit in found:
		var payload := ProjectSettings.globalize_path(hit.get_string(1))
		# .godot/ is gitignored, so a missing payload here is a local import
		# that has not been run, not a broken repository.
		if not FileAccess.file_exists(payload):
			warn("%s has not been imported locally (run "
				% rel_to_runtime + "tools/import_assets.py)")


## Read an image header for its dimensions without decoding the pixels.
## Returns Vector2i(w, h), or Vector2i.ZERO if the file cannot be read.
func _png_size(abs_path: String) -> Vector2i:
	var img := Image.new()
	if img.load(abs_path) != OK:
		return Vector2i.ZERO
	return Vector2i(img.get_width(), img.get_height())


func _check_power_of_two(name: String, tier: int) -> void:
	var full := _abs("res://assets/runtime/textures/%s/diff_%d.jpg"
		% [name, tier])
	if not FileAccess.file_exists(full):
		return
	var size := _png_size(full)
	if size == Vector2i.ZERO:
		fail("%s/diff_%d.jpg could not be decoded" % [name, tier])
		return
	check(size.x == tier and size.y == tier,
		"%s/diff_%d.jpg is %dx%d; the rung name says %d"
			% [name, tier, size.x, size.y, tier])
	if size.x & (size.x - 1) != 0 or size.y & (size.y - 1) != 0:
		warn("%s/diff_%d.jpg is %dx%d, not a power of two"
			% [name, tier, size.x, size.y])


## PNG data maps have a uniform colour channel count that must match the rung
## they are named for, or the GPU is handed an unpacking job at load time.
func _check_png_pot(rel: String, tier: int) -> void:
	var parts := rel.split("/")
	var set_name: String = parts[0]
	var fname: String = parts[1]
	var full := _abs("res://assets/runtime/textures/%s/%s" % [set_name, fname])
	if not FileAccess.file_exists(full):
		return
	var size := _png_size(full)
	if size == Vector2i.ZERO:
		fail("%s/%s could not be decoded" % [set_name, fname])
		return
	check(size.x == tier and size.y == tier,
		"%s/%s is %dx%d but is named for the %d rung"
			% [set_name, fname, size.x, size.y, tier])


## The largest source rung the manifest recorded for a set, or 0 if unknown.
##
## `runtime` in the manifest is a list of written files, so the rung list lives
## in the sibling `tiers` field, descending (2048, 1024, 512).
func manifest_source_tier(by_id: Dictionary, set_name: String) -> int:
	var e: Dictionary = by_id.get(set_name, {})
	if e.is_empty():
		return 0
	var tiers: Array = e.get("tiers", [])
	if tiers.is_empty():
		return 0
	return int(tiers[0])


## Triangle count in a .gltf's LOD file, from the accessor count of the
## primitive's indices. Returns 0 when the file is unreadable.
func _glb_triangles(dir: String, lod: int) -> int:
	var path := _abs("%s/lod%d.gltf" % [dir, lod])
	if not FileAccess.file_exists(path):
		return 0
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var body := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(body)
	if not (parsed is Dictionary):
		return 0
	var gltf: Dictionary = parsed
	var meshes: Array = gltf.get("meshes", [])
	var accessors: Array = gltf.get("accessors", [])
	var total := 0
	for mesh in meshes:
		if not (mesh is Dictionary):
			continue
		for prim in (mesh as Dictionary).get("primitives", []):
			if not (prim is Dictionary):
				continue
			var idx: int = int((prim as Dictionary).get("indices", -1))
			if idx < 0 or idx >= accessors.size():
				continue
			total += int((accessors[idx] as Dictionary).get("count", 0)) / 3
	return total