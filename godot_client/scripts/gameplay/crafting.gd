class_name Crafting
extends RefCounted
## Crafting: shaped and shapeless recipes over ContentDB block ids.
##
## PREBUILT CHECK, as requested: the Godot Asset Library was searched for
## crafting addons compatible with Godot 4.4 (`filter=crafting`) and returned
## **zero results** -- the category does not exist. GLoot (used for the
## inventory) is a container library and has no recipe system. So this file is
## hand-written rather than vendored. It is deliberately small and testable
## rather than a general item-recipe framework.
##
## A recipe is a Dictionary:
##   {
##     "id":       String,             # stable id, used by tests and saves
##     "shapeless": Array[int],         # exact multiset of inputs
##     "pattern":   Array[String],      # 1-3 rows of ".", "X" and a key char
##     "keys":      {char: block_id},   # what each non-"." char means
##     "output":    block_id,
##     "count":     int,                # defaults to 1
##   }
## A recipe uses either "shapeless" or "pattern"+"keys", never both.
##
## The 3x3 crafting grid is a flat Array[int] of 9 block ids, 0 = empty.

const GRID_SIZE := 3
const EMPTY := 0

## Character meaning "must be empty" in a pattern.
const DOT := "."


## The stock recipe book. Content ids are ContentDB constants.
static func default_recipes() -> Array:
	return [
		# --- stone processing ---
		{
			"id": "stone_bricks",
			"pattern": ["XXX", "XXX", "XXX"],
			"keys": {"X": ContentDB.STONE},
			"output": ContentDB.DEEPSLATE,
			"count": 4,
		},
		{
			"id": "decompress_deepslate",
			"shapeless": [ContentDB.DEEPSLATE],
			"output": ContentDB.STONE,
		},
		{
			"id": "weather_stone",
			"shapeless": [ContentDB.STONE, ContentDB.STONE],
			"output": ContentDB.GRAVEL,
			"count": 4,
		},
		# --- surface blocks ---
		{
			"id": "strip_grass",
			"shapeless": [ContentDB.GRASS],
			"output": ContentDB.DIRT,
			"count": 4,
		},
		{
			"id": "freeze_water",
			"pattern": ["XX.", "XX."],
			"keys": {"X": ContentDB.SAND},
			"output": ContentDB.ICE,
		},
		{
			"id": "melt_ice",
			"shapeless": [ContentDB.ICE],
			"output": ContentDB.WATER,
		},
		{
			"id": "cover_with_snow",
			"shapeless": [ContentDB.DIRT],
			"output": ContentDB.SNOW,
		},
		# --- wood ---
		{
			"id": "grow_leaves",
			"shapeless": [ContentDB.WOOD],
			"output": ContentDB.LEAVES,
			"count": 4,
		},
		{
			"id": "compost_leaves",
			"shapeless": [ContentDB.LEAVES, ContentDB.LEAVES],
			"output": ContentDB.DIRT,
			"count": 2,
		},
		# --- light ---
		{
			"id": "crack_glowstone",
			"pattern": ["XXX", "X.X", "XXX"],
			"keys": {"X": ContentDB.GRAVEL},
			"output": ContentDB.GLOWSTONE,
		},
		{
			"id": "dim_glowstone",
			"shapeless": [ContentDB.GLOWSTONE, ContentDB.DEEPSLATE_DEEP],
			"output": ContentDB.DEEPSLATE,
		},
		# --- the Deeps ---
		{
			"id": "squeeze_deepslate",
			"shapeless": [ContentDB.DEEPSLATE_DEEP],
			"output": ContentDB.DEEPSLATE,
		},
		{
			"id": "hollow_void_rock",
			"pattern": ["XXX", "X.X", "X.X"],
			"keys": {"X": ContentDB.VOID_ROCK},
			"output": ContentDB.GLOWSTONE,
			"count": 2,
		},
	]


static func _validate(recipe: Dictionary) -> bool:
	if not recipe.has("id") or not recipe.has("output"):
		return false
	if recipe.has("shapeless"):
		return recipe["shapeless"] is Array
	if recipe.has("pattern") and recipe.has("keys"):
		var pat: Array = recipe["pattern"]
		if pat.is_empty() or pat.size() > GRID_SIZE:
			return false
		for row in pat:
			if String(row).length() > GRID_SIZE:
				return false
		return true
	return false


# --- matching ---------------------------------------------------------------

## Find the first recipe the 9-cell grid satisfies, or {} when nothing matches.
static func find_recipe(grid: Array, recipes: Array = []) -> Dictionary:
	var book := recipes if not recipes.is_empty() else default_recipes()
	for r in book:
		var recipe: Dictionary = r
		if not _validate(recipe):
			continue
		if recipe.has("shapeless"):
			if _matches_shapeless(grid, recipe["shapeless"]):
				return recipe
		elif _matches_shaped(grid, recipe):
			return recipe
	return {}


## Multiset equality, ignoring position and ignoring the cells that are empty
## on either side (so a 1-item recipe matches a grid with eight other blocks --
## that is how a real crafting grid behaves only if it is otherwise empty, so
## callers pass a grid they have already validated).
static func _matches_shapeless(grid: Array, inputs: Array) -> bool:
	var have := {}
	for v in grid:
		var id := int(v)
		if id == EMPTY:
			continue
		have[id] = int(have.get(id, 0)) + 1
	var want := {}
	for v in inputs:
		var id := int(v)
		if id == EMPTY:
			continue
		want[id] = int(want.get(id, 0)) + 1
	if have.size() != want.size():
		return false
	for id in want.keys():
		if int(have.get(id, 0)) != int(want[id]):
			return false
	return true


## Trim the empty border off the grid, then compare the remaining cells with
## the pattern row by row. Trimming is what lets a 2x2 recipe be crafted in
## any corner of a 3x3 grid.
static func _trimmed(grid: Array) -> Array:
	var cells: Array = []
	for v in grid:
		cells.append(int(v))
	var min_x := GRID_SIZE
	var max_x := -1
	var min_y := GRID_SIZE
	var max_y := -1
	for y in GRID_SIZE:
		for x in GRID_SIZE:
			if cells[y * GRID_SIZE + x] == EMPTY:
				continue
			min_x = mini(min_x, x)
			max_x = maxi(max_x, x)
			min_y = mini(min_y, y)
			max_y = maxi(max_y, y)
	if max_x < 0:
		return []
	var out: Array = []
	for y in range(min_y, max_y + 1):
		for x in range(min_x, max_x + 1):
			out.append(cells[y * GRID_SIZE + x])
	return out


static func _pattern_cells(recipe: Dictionary) -> Array:
	var out: Array = []
	for row in recipe["pattern"]:
		for ch in String(row):
			if ch == DOT:
				out.append(EMPTY)
			else:
				out.append(int(recipe["keys"].get(ch, 0)))
	return out


static func _matches_shaped(grid: Array, recipe: Dictionary) -> bool:
	var have := _trimmed(grid)
	var want := _pattern_cells(recipe)
	if have.size() != want.size():
		return false
	for i in have.size():
		if int(have[i]) != int(want[i]):
			return false
	return true


# --- performing a craft ----------------------------------------------------

## Remove one of each input the recipe needs from `inv`, then hand over the
## output. Returns false (and consumes nothing) when the inputs are missing.
static func craft(inv: PlayerInventory, recipe: Dictionary,
		recipes: Array = []) -> bool:
	if inv == null or not _validate(recipe):
		return false
	# Re-check against a grid built from what the player actually has, so a
	# caller cannot hand us a recipe the player cannot afford.
	var needed := _input_multiset(recipe)
	for block_id in needed.keys():
		if inv.count_of(int(block_id)) < int(needed[block_id]):
			return false
	for block_id in needed.keys():
		for _i in int(needed[block_id]):
			inv.consume_block(int(block_id))
	var out_id := int(recipe["output"])
	var count := int(recipe.get("count", 1))
	for _i in count:
		inv.give_block(out_id)
	return true


## What a recipe consumes, as {block_id: count}.
static func _input_multiset(recipe: Dictionary) -> Dictionary:
	var out := {}
	if recipe.has("shapeless"):
		for v in recipe["shapeless"]:
			var id := int(v)
			out[id] = int(out.get(id, 0)) + 1
	else:
		for id in _pattern_cells(recipe):
			if id != EMPTY:
				out[id] = int(out.get(id, 0)) + 1
	return out


## Recipes whose output the player could make right now, for the HUD.
static func available(inv: PlayerInventory, recipes: Array = []) -> Array:
	var out: Array = []
	for r in (recipes if not recipes.is_empty() else default_recipes()):
		var recipe: Dictionary = r
		if not _validate(recipe):
			continue
		var ok := true
		for block_id in _input_multiset(recipe).keys():
			if inv.count_of(int(block_id)) < int(_input_multiset(recipe)[block_id]):
				ok = false
				break
		if ok:
			out.append(recipe)
	return out
