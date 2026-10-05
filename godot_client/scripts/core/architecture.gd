class_name EngArch
extends RefCounted
## The architecture, as data.
##
## `ARCHITECTURE.md` explains why the stack is shaped the way it is. This file
## is the part that fails when the code stops matching it. A document drifts;
## a check does not.
##
## Three things are checked:
##
##   1. **Layering.** Every class belongs to a layer, and a layer may only
##      depend downward. `engineering` may use `world`; `world` may not reach
##      into `engineering`. The old Voxel Tools world violated this in the
##      worst way -- it was a world that knew nothing about the game.
##
##   2. **Visibility.** A PUBLIC module is part of the API other layers use.
##      An INTERNAL one is a layer's own business, and reaching into it from
##      another layer is a finding even when the dependency direction is legal.
##      This is what stops a `private` helper quietly becoming load-bearing.
##
##   3. **Singletons.** There is one world, one inventory, one authority, one
##      profiler, one watchdog. `verify_runtime()` counts them in a live tree.
##
## Usage:
##     EngArch.verify_runtime(self)     # startup, cheap
##     EngArch.verify_source_tree()     # tests, reads every script

enum Layer {
	CORE,        # no dependencies on anything else
	WORLD,       # voxels, generation, content, rendering
	GAMEPLAY,    # player, mobs, villagers, inventory, crafting, persistence
	ENGINEERING, # the universal engineering system
	EMERGENT,    # capabilities, patterns, causal behaviour, player rules
	NET,         # authority, protocol
	UI,          # HUD, panels
	DIAGNOSTICS, # profiler, watchdog, determinism, threading
}

## Layer names, in dependency order. A module may use anything in a layer
## earlier in this list, and its own layer.
##
## `app` is last and is the composition root -- `main.gd` and nothing else.
## It is the one place allowed to know about every layer, because assembling
## the game is its entire job. Give it a second user and the layering is a
## fiction.
## `mob` was a separate layer once and was not one. Mobs need the player, the
## world and the inventory; a villager that cannot see a Player is not a
## villager. Splitting them produced six violations that said exactly that.
const LAYER_ORDER := [
	"core", "world", "gameplay", "engineering", "emergent", "net", "ui",
	"diagnostics", "app",
]

const PUBLIC := "public"
const INTERNAL := "internal"

## Every class in the project, and where it sits. Adding a class to the project
## without adding it here is itself a finding -- that is deliberate, so the
## table cannot quietly fall behind the code.
const MODULES := {
	# --- core: depends on nothing ---
	"EngArch":            {"layer": "core",        "visibility": INTERNAL},
	"WorldBackend":       {"layer": "core",        "visibility": PUBLIC},
	"Determinism":        {"layer": "core",        "visibility": PUBLIC},
	"Threading":          {"layer": "core",        "visibility": PUBLIC},
	"System":             {"layer": "core",        "visibility": PUBLIC},
	"SystemRegistry":     {"layer": "core",        "visibility": PUBLIC},
	"GameApi":            {"layer": "app",         "visibility": PUBLIC},

	# --- world: voxels, content, generation, rendering ---
	"ContentDB":          {"layer": "world",       "visibility": PUBLIC},
	"VoxelWorld":         {"layer": "world",       "visibility": PUBLIC},
	"VoxelBlock":         {"layer": "world",       "visibility": INTERNAL},
	"MapNode":            {"layer": "world",       "visibility": INTERNAL},
	"WorldGenerator":     {"layer": "world",       "visibility": PUBLIC},
	"ChunkFiles":         {"layer": "world",       "visibility": INTERNAL},
	"GreedyMesher":       {"layer": "world",       "visibility": INTERNAL},
	# The smoothing mesher. INTERNAL like GreedyMesher: it is consumed by
	# VoxelWorld, in the same layer, and nothing above needs to name it.
	"SurfaceNets":        {"layer": "world",       "visibility": INTERNAL},
	"ChunkMeshWorker":    {"layer": "world",       "visibility": INTERNAL},
	"MaterialLibrary":    {"layer": "world",       "visibility": PUBLIC},
	"RenderSettings":     {"layer": "world",       "visibility": PUBLIC},
	"VoxelPick":          {"layer": "world",       "visibility": PUBLIC},
	"StreamScheduler":    {"layer": "world",       "visibility": INTERNAL},
	"DayNight":           {"layer": "world",       "visibility": PUBLIC},

	# --- mob ---
	"Mob":                {"layer": "gameplay",         "visibility": PUBLIC},
	"Villager":           {"layer": "gameplay",         "visibility": PUBLIC},
	"Village":            {"layer": "gameplay",         "visibility": PUBLIC},
	"MobSpawner":         {"layer": "gameplay",         "visibility": PUBLIC},
	"Pathfinder":         {"layer": "gameplay",         "visibility": INTERNAL},
	"BlockDrop":          {"layer": "gameplay",         "visibility": INTERNAL},
	"CreatureAnimator":   {"layer": "gameplay",         "visibility": INTERNAL},
	"CreatureModels":     {"layer": "gameplay",         "visibility": INTERNAL},
	"AudioDirector":      {"layer": "gameplay",         "visibility": PUBLIC},

	# --- gameplay ---
	"Player":             {"layer": "gameplay",    "visibility": PUBLIC},
	"PlayerInteraction":  {"layer": "gameplay",    "visibility": PUBLIC},
	"PlayerInventory":    {"layer": "gameplay",    "visibility": PUBLIC},
	"Crafting":           {"layer": "gameplay",    "visibility": PUBLIC},
	"CraftingPanel":      {"layer": "gameplay",    "visibility": PUBLIC},
	"CraftingSlot":       {"layer": "gameplay",    "visibility": INTERNAL},
	"SaveGame":           {"layer": "gameplay",    "visibility": PUBLIC},
	"SaveMigration":      {"layer": "gameplay",    "visibility": PUBLIC},
	"Persistence":        {"layer": "gameplay",    "visibility": PUBLIC},

	# --- engineering ---
	"EngEngineering":     {"layer": "engineering", "visibility": PUBLIC},
	"EngHud":             {"layer": "engineering", "visibility": PUBLIC},
	"EngGraph":           {"layer": "engineering", "visibility": PUBLIC},
	"EngMaterials":       {"layer": "engineering", "visibility": PUBLIC},
	"EngPorts":           {"layer": "engineering", "visibility": PUBLIC},
	"EngPart":            {"layer": "engineering", "visibility": PUBLIC},
	"EngProcesses":       {"layer": "engineering", "visibility": PUBLIC},
	"EngAssembly":        {"layer": "engineering", "visibility": PUBLIC},
	"EngAssemblies":      {"layer": "engineering", "visibility": PUBLIC},
	"EngMachines":        {"layer": "engineering", "visibility": PUBLIC},
	"EngSimulation":      {"layer": "engineering", "visibility": INTERNAL},
	"EngCursor":          {"layer": "engineering", "visibility": INTERNAL},
	"EngFastening":       {"layer": "engineering", "visibility": INTERNAL},
	"EngGeometry":        {"layer": "engineering", "visibility": INTERNAL},
	"EngTools":           {"layer": "engineering", "visibility": PUBLIC},
	"EngItems":           {"layer": "engineering", "visibility": PUBLIC},
	"EngWorkshop":        {"layer": "engineering", "visibility": PUBLIC},
	"EngBlueprints":      {"layer": "engineering", "visibility": PUBLIC},
	"EngSociety":         {"layer": "engineering", "visibility": INTERNAL},
	"EngModding":         {"layer": "engineering", "visibility": PUBLIC},

	# --- emergent: the universal gameplay system ---
	#
	# Between engineering and net, because it reads the engineering graph
	# and submits through the authority, and both directions would be wrong.
	# The module boundary here is load-bearing and worth stating: the
	# emergent layer knows what a THING CAN DO and what it is RELATED to, and
	# nothing about voxels, rendering or transport.
	"EmergentSystem":      {"layer": "emergent",    "visibility": PUBLIC},
	"EmergentCaps":        {"layer": "emergent",    "visibility": PUBLIC},
	"EmergentPatterns":    {"layer": "emergent",    "visibility": PUBLIC},
	"EmergentMatcher":     {"layer": "emergent",    "visibility": PUBLIC},
	"EmergentEntity":      {"layer": "emergent",    "visibility": PUBLIC},
	"EmergentGraph":       {"layer": "emergent",    "visibility": PUBLIC},
	"EmergentConstraints": {"layer": "emergent",    "visibility": PUBLIC},
	"EmergentBehaviors":   {"layer": "emergent",    "visibility": PUBLIC},
	"EmergentCausal":      {"layer": "emergent",    "visibility": PUBLIC},
	"EmergentRules":       {"layer": "emergent",    "visibility": PUBLIC},
	"EmergentPersistence": {"layer": "emergent",    "visibility": INTERNAL},
	"EmergentDiagnostics": {"layer": "emergent",    "visibility": PUBLIC},

	# --- net ---
	"NetAuthority":       {"layer": "net",         "visibility": PUBLIC},
	"NetProtocol":        {"layer": "net",         "visibility": PUBLIC},

	# --- ui ---
	"WorldHud":           {"layer": "ui",          "visibility": PUBLIC},
	"UiTheme":            {"layer": "ui",          "visibility": PUBLIC},
	"BlockIcon":          {"layer": "ui",          "visibility": PUBLIC},
	"VitalsBar":          {"layer": "ui",          "visibility": PUBLIC},
	"SettingsMenu":       {"layer": "ui",          "visibility": PUBLIC},
	"DebugOverlay":       {"layer": "ui",          "visibility": PUBLIC},
	"DevTools":           {"layer": "app",         "visibility": PUBLIC},

	# --- diagnostics ---
	"GameProfiler":       {"layer": "diagnostics", "visibility": PUBLIC},
	"StabilityWatchdog":  {"layer": "diagnostics", "visibility": PUBLIC},
	"RenderTest":         {"layer": "diagnostics", "visibility": PUBLIC},
	"RenderDiagnostics":  {"layer": "diagnostics", "visibility": PUBLIC},
	"AdaptiveQuality":    {"layer": "diagnostics", "visibility": PUBLIC},
}

## Files that are deliberately outside the module graph. `main.gd` declares no
## class -- it is the composition root -- and this file mentions every module
## name by definition, so both are skipped by the layer scan.
const UNSCANNED := ["res://scripts/main.gd", "res://scripts/core/architecture.gd"]

## Layers that may legitimately appear more than once, or not at all, in a
## running tree. Everything else is a singleton.
const SINGLETONS := {
	"VoxelWorld": 1,
	"PlayerInventory": 1,
	"GameProfiler": 1,
	"Player": 1,
}

## Singletons that are RefCounted rather than Nodes, so they are not in the
## tree and cannot be found by walking it. They are checked as properties of
## the composition root instead -- a server authority nobody holds is just as
## broken as two of them, and neither shows up in a tree walk.
const DETACHED := {"NetAuthority": "authority"}

## The `class_name` of this file's own table, which necessarily mentions every
## other module. Excluded from the scanner's own results.
const SELF := "EngArch"

const SCRIPTS_ROOT := "res://scripts"


# --- queries ----------------------------------------------------------------

static func layer_of(module_name: String) -> String:
	return String((MODULES.get(module_name, {}) as Dictionary).get("layer", ""))


static func is_public(module_name: String) -> bool:
	return String((MODULES.get(module_name, {}) as Dictionary).get("visibility", INTERNAL)) == PUBLIC


static func knows(module_name: String) -> bool:
	return MODULES.has(module_name)


## May a module in `from_layer` use one in `to_layer`? Only downward.
static func may_depend(from_layer: String, to_layer: String) -> bool:
	if from_layer == "" or to_layer == "":
		return false
	var a: int = LAYER_ORDER.find(from_layer)
	var b: int = LAYER_ORDER.find(to_layer)
	if a < 0 or b < 0:
		return false
	return b <= a


## The one entry point a layer is allowed to publish: the result of running the
## full check. `violations()` is what a test asserts on; `ok()` is the same
## thing as a bool.
static func violations() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	# 1. Every class in the tree is declared here.
	for path in _all_scripts():
		var declared := _declared_class_of(path)
		if declared != "" and not knows(declared):
			out.append({
				"kind": "undeclared",
				"detail": "%s declares class %s, which is not in EngArch.MODULES" \
					% [path, declared],
			})
	# 2. Layering and visibility.
	for path in _all_scripts():
		if UNSCANNED.has(path):
			continue
		var from_layer := _layer_of_path(path)
		if from_layer == "":
			continue
		out.append_array(check_text(_layer_of_path(path), _read(path), path))
	return out


## The layering and visibility rules, applied to one unit of source.
##
## Public so the test suite can feed it deliberately bad input. A checker that
## has never been shown a violation is indistinguishable from a checker that
## always passes, and the second kind gets trusted.
static func check_text(from_layer: String, raw: String, label := "<test>") -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var text := _strip_comments(raw)
	for module_name in MODULES:
		if module_name == SELF:
			continue
		if not _mentions(text, module_name):
			continue
		var to_layer := layer_of(module_name)
		if to_layer == from_layer:
			continue
		if not may_depend(from_layer, to_layer):
			out.append({
				"kind": "layer",
				"detail": "%s (layer %s) uses %s (layer %s); dependencies go "
					% [label, from_layer, module_name, to_layer]
					+ "downward only",
			})
		elif not is_public(module_name):
			out.append({
				"kind": "visibility",
				"detail": "%s (layer %s) reaches into %s, which is INTERNAL to "
					% [label, from_layer, module_name]
					+ "layer %s" % to_layer,
			})
	return out


static func ok() -> bool:
	return violations().is_empty()


## A human-readable summary, for the console and for a failing assertion.
static func report() -> String:
	var v := violations()
	if v.is_empty():
		return "architecture: OK (%d modules, %d layers, no violations)" % [
			MODULES.size(), LAYER_ORDER.size()]
	var lines := PackedStringArray()
	lines.append("architecture: %d violations" % v.size())
	for item in v:
		lines.append("  [%s] %s" % [item["kind"], item["detail"]])
	return "\n".join(lines)


# --- runtime check ----------------------------------------------------------

## Count the singletons in a live tree. Cheap: one recursive walk, no file I/O,
## which is why it is the one that runs at startup.
static func verify_runtime(root_node: Node) -> Array[String]:
	var problems: Array[String] = []
	var counts := {}
	_walk(root_node, counts)
	for key in SINGLETONS:
		var want: int = int(SINGLETONS[key])
		var got: int = int(counts.get(key, 0))
		if got != want:
			problems.append("%s: expected %d instance(s) in the tree, found %d" \
				% [key, want, got])
	# class name -> the property on the composition root that holds it.
	for cls in DETACHED:
		var prop := String(DETACHED[cls])
		var held: Variant = root_node.get(prop)
		if held == null or not is_instance_valid(held):
			problems.append("%s: the composition root holds no instance "
				% cls + "(property '%s')" % prop)
	if WorldBackend.has_active():
		var active := WorldBackend.active()
		if not is_instance_valid(active) or not is_ancestor_of(root_node, active):
			problems.append("the registered world backend is not in this tree")
	return problems


static func _walk(node: Node, counts: Dictionary) -> void:
	var script: Script = node.get_script()
	if script != null and script.resource_path != "":
		var c := _declared_class_of(script.resource_path)
		if c != "" and MODULES.has(c):
			counts[c] = int(counts.get(c, 0)) + 1
	for child in node.get_children():
		_walk(child, counts)


static func is_ancestor_of(root_node: Node, candidate: Node) -> bool:
	if root_node == candidate:
		return true
	for child in root_node.get_children():
		if is_ancestor_of(child, candidate):
			return true
	return false


# --- source scanning --------------------------------------------------------

static var _own_path := {}
static var _scripts_cache: Array[String] = []
static var _text_cache := {}
static var _raw_cache := {}


static func _all_scripts() -> Array[String]:
	if not _scripts_cache.is_empty():
		return _scripts_cache
	var out: Array[String] = []
	_scan_dir(SCRIPTS_ROOT, out)
	_scripts_cache = out
	for p in out:
		var c := _declared_class_of(p)
		if c != "":
			_own_path[c] = p
	return out


static func _scan_dir(path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if dir.current_is_dir():
			if not name.begins_with("."):
				_scan_dir(path + "/" + name, out)
		elif name.ends_with(".gd"):
			out.append(path + "/" + name)
		name = dir.get_next()
	dir.list_dir_end()


## File contents with comments and doc-strings removed.
##
## Without this the scanner reports prose as a dependency: the word
## "EngEngineering" in a sentence explaining why the save system deliberately
## does not depend on it would be counted as depending on it. Comments are not
## coupling, and a check that cannot tell the difference gets switched off.
static func _read(path: String) -> String:
	if _text_cache.has(path):
		return String(_text_cache[path])
	_text_cache[path] = _strip_comments(_raw(path))
	return String(_text_cache[path])


## Unprocessed file contents, cached separately so `_declared_class_of` can
## read a script without recursing through the comment stripper.
static func _raw(path: String) -> String:
	if _raw_cache.has(path):
		return String(_raw_cache[path])
	var text := ""
	if FileAccess.file_exists(path):
		text = FileAccess.get_file_as_string(path)
	_raw_cache[path] = text
	return text


## Marks a `preload()` path once the surrounding string literal is removed, so
## a loaded script still counts as a dependency after its name is gone.
const PRELOAD_MARK := "@PRELOAD:%s@"


static func _strip_comments(text: String) -> String:
	var out := text
	# 1. Comments are not coupling.
	var comments := RegEx.new()
	comments.compile("(?s)##.*?(\\n|$)|#[^\\n]*")
	out = comments.sub(out, "", true)
	# 2. Remember which scripts are loaded, before the literals vanish.
	var loaded := {}
	var loads := RegEx.new()
	loads.compile(LOAD_PATTERN)
	for hit in loads.search_all(out):
		# Group 1 is the optional "pre" prefix; group 2 is the path.
		var path := String(hit.get_string(2))
		var cls := _declared_class_of(path)
		if cls != "":
			loaded[cls] = true
	# 3. A class name inside a string literal is data, not a dependency.
	#    `Threading.MAIN_THREAD_ONLY` names eleven classes precisely so that it
	#    does not have to reference any of them, and a scanner that cannot tell
	#    the difference reports the rule as the violation.
	var literals := RegEx.new()
	literals.compile(LITERAL_PATTERN)
	out = literals.sub(out, '"', true)
	# 4. A preload path *is* a dependency, so mark it back in.
	for cls in loaded:
		out += "\n" + (PRELOAD_MARK % String(cls))
	return out


## Matches `preload("res://...")` and `load("res://...")`. Capture group 1 is
## the optional "pre" prefix and group 2 is the path.
const LOAD_PATTERN := '(pre)?load\\(\\s*"([^"]+)"'
## Matches a double-quoted GDScript string literal.
const LITERAL_PATTERN := '"(?:[^"\\\\]|\\\\.)*"'


## The `class_name X` declared by a script, or "".
##
## Reads the file raw, through `_raw()`. Going through `_read()` would recurse
## without end: `_read` strips comments, which resolves preload paths, which
## calls this function, which calls `_read`.
static func _declared_class_of(path: String) -> String:
	var re := RegEx.new()
	re.compile("^class_name\\s+([A-Za-z_][A-Za-z0-9_]*)", true)
	var m := re.search(_raw(path))
	return "" if m == null else m.get_string(1)


## Which layer a file belongs to, taken from its directory. The first path
## segment under `scripts/` is the layer; anything directly under `scripts/`
## is core.
## A file's layer is the layer of the class it declares, not its directory.
## Directories are an organisational convenience; the class is the unit, and a
## class that moved folders did not change its responsibilities.
static func _layer_of_path(path: String) -> String:
	return layer_of(_declared_class_of(path))


## Whole-word mention, so `Mob` does not match `MobSpawner` and `Crafting`
## does not match `CraftingPanel`.
static func _mentions(text: String, name: String) -> bool:
	if text.contains(PRELOAD_MARK % name):
		return true
	if _text_cache.has("__re_" + name):
		var cached: RegEx = _text_cache["__re_" + name]
		return cached.search(text) != null
	var re := RegEx.new()
	re.compile("\\b%s\\b" % name)
	_text_cache["__re_" + name] = re
	return re.search(text) != null
