class_name Village
extends Node3D
## Scatters the downloaded Poly Haven props (crates, barrels, lamps, benches,
## planters) around a village site and populates it with villagers.
##
## Villages are deterministic: the site, the prop layout and the villager
## roster all come from a seed, so revisiting the same spot shows the same
## town. Each village occupies one chunk-sized district; the nearest district
## is rebuilt whenever the player moves to a new one, which keeps the prop
## count bounded no matter how far the player travels.

const MODEL_DIR := "res://assets/raw/models"

## Prop models used for the settlement, with their real-world scale.
const PROP_KINDS := [
	{"model": "wooden_crate_01", "scale": 0.9, "weight": 3.0},
	{"model": "wooden_crate_02", "scale": 0.9, "weight": 3.0},
	{"model": "Barrel_01", "scale": 0.85, "weight": 3.0},
	{"model": "wine_barrel_01", "scale": 0.85, "weight": 2.0},
	{"model": "wooden_barrels_01", "scale": 0.85, "weight": 2.0},
	{"model": "metal_tool_chest", "scale": 0.9, "weight": 1.5},
	{"model": "old_military_crate", "scale": 0.9, "weight": 1.5},
	{"model": "treasure_chest", "scale": 0.9, "weight": 1.0},
	{"model": "street_lamp_01", "scale": 1.0, "weight": 1.0},
	{"model": "Lantern_01", "scale": 1.0, "weight": 1.0},
	{"model": "wooden_lantern_01", "scale": 1.0, "weight": 1.0},
	{"model": "painted_wooden_bench", "scale": 1.0, "weight": 2.0},
	{"model": "painted_wooden_stool", "scale": 1.0, "weight": 2.0},
	{"model": "chinese_stool", "scale": 1.0, "weight": 1.0},
	{"model": "ceramic_pot", "scale": 1.0, "weight": 2.0},
	{"model": "planter_pot_clay", "scale": 1.0, "weight": 2.0},
	{"model": "potted_plant_01", "scale": 1.0, "weight": 2.0},
]

## Villager roster: name, job, skin, tunic.
const ROSTER := [
	{"name": "Ada", "job": "Blacksmith",
		"skin": Color(0.72, 0.55, 0.42), "tunic": Color(0.4, 0.32, 0.3)},
	{"name": "Bram", "job": "Farmer",
		"skin": Color(0.85, 0.68, 0.53), "tunic": Color(0.35, 0.45, 0.7)},
	{"name": "Cleo", "job": "Baker",
		"skin": Color(0.9, 0.75, 0.62), "tunic": Color(0.8, 0.6, 0.35)},
	{"name": "Doran", "job": "Miner",
		"skin": Color(0.6, 0.45, 0.35), "tunic": Color(0.3, 0.3, 0.35)},
	{"name": "Elin", "job": "Healer",
		"skin": Color(0.88, 0.72, 0.6), "tunic": Color(0.75, 0.78, 0.85)},
	{"name": "Fenn", "job": "Woodcutter",
		"skin": Color(0.78, 0.6, 0.45), "tunic": Color(0.3, 0.42, 0.3)},
	{"name": "Gisla", "job": "Trader",
		"skin": Color(0.86, 0.7, 0.6), "tunic": Color(0.6, 0.35, 0.5)},
	{"name": "Hale", "job": "Guard",
		"skin": Color(0.7, 0.52, 0.4), "tunic": Color(0.45, 0.45, 0.5)},
]

@export var world: VoxelWorld
@export var player: Player
## How many props to place in a district.
@export var props_per_district := 26
@export var villagers_per_district := 4

var _scenes := {}          # model name -> PackedScene (or null when missing)
var _loaded := {}          # model name -> PackedScene
var _district := Vector3i(9999, 9999, 9999)
var _prop_count := 0
var _villager_count := 0
var _missing := PackedStringArray()


func _ready() -> void:
	for kind in PROP_KINDS:
		var name: String = kind["model"]
		_scenes[name] = _load_model(name)


## Load a downloaded glTF bundle. Returns null when the model is not present,
## so the village degrades to whatever props did import.
func _load_model(name: String) -> PackedScene:
	var path := "%s/%s/%s_1k.gltf" % [MODEL_DIR, name, name]
	if not ResourceLoader.exists(path):
		_missing.append(name)
		return null
	var ps: PackedScene = load(path)
	if ps != null:
		_loaded[name] = ps
	return ps


## How many prop models imported successfully.
func model_count() -> int:
	return _loaded.size()


func missing_models() -> PackedStringArray:
	return _missing


func prop_count() -> int:
	return _prop_count


func villager_count() -> int:
	return _villager_count


## Rebuild the settlement when the player crosses into a new district.
func update(player_pos: Vector3) -> void:
	if world == null or player_pos == null:
		return
	var d := Vector3i(int(floor(player_pos.x / 48.0)), 0,
		int(floor(player_pos.z / 48.0)))
	if d == _district:
		return
	_district = d
	_rebuild(d)


func _rebuild(district: Vector3i) -> void:
	for c in get_children():
		c.queue_free()
	_prop_count = 0
	_villager_count = 0

	if world.dimension != WorldGenerator.DIM_OVERWORLD:
		return
	# Settlements stand on flat, dry ground: search outward for a site whose
	# columns are all solid, level, and above the waterline.
	var origin := _find_site(district)
	if origin == Vector3i.ZERO:
		return

	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector2i(origin.x, origin.z))

	# --- Props: crates and barrels stacked into a loose market square ---
	var weights := PackedFloat32Array()
	var total := 0.0
	for kind in PROP_KINDS:
		total += float(kind["weight"])
		weights.append(total)

	var placed := 0
	var attempts := 0
	while placed < props_per_district and attempts < props_per_district * 12:
		attempts += 1
		var pick := rng.randf() * total
		var chosen := 0
		for i in weights.size():
			if pick <= weights[i]:
				chosen = i
				break
		var kind: Dictionary = PROP_KINDS[chosen]
		var name: String = kind["model"]
		var scene: PackedScene = _scenes.get(name, null)
		if scene == null:
			continue
		var spot := _scatter_point(rng, origin, 13.0)
		if spot == Vector3i.ZERO:
			continue
		var node := _place_prop(scene, spot, float(kind["scale"]), rng)
		if node != null:
			placed += 1

	# --- Villagers ---
	var count := mini(villagers_per_district, ROSTER.size())
	for i in count:
		var who: Dictionary = ROSTER[(i + int(abs(origin.x))) % ROSTER.size()]
		var spot := _scatter_point(rng, origin, 8.0)
		if spot == Vector3i.ZERO:
			continue
		var v := Villager.new()
		v.name = str(who["name"])
		v.villager_name = who["name"]
		v.job = who["job"]
		v.skin = who["skin"]
		v.tunic = who["tunic"]
		v.world = world
		v.position = Vector3(spot.x + 0.5, float(spot.y), spot.z + 0.5)
		add_child(v)
		v.place_on_ground(world)
		v.roam_radius = 7.0
		_villager_count += 1

	print("[Village] district %s: %d props, %d villagers"
		% [_district, _prop_count, _villager_count])


## Search outward from the district centre for a flat, dry column to build on.
func _find_site(district: Vector3i) -> Vector3i:
	var cx := district.x * 48 + 24
	var cz := district.z * 48 + 24
	var best := Vector3i.ZERO
	var best_score := -1.0
	for radius in [0, 12, 24]:
		for a in 6:
			var ang := float(a) / 6.0 * TAU
			var cx2 := cx + int(cos(ang) * float(radius))
			var cz2 := cz + int(sin(ang) * float(radius))
			var ground := _surface_y(Vector3i(cx2, 0, cz2))
			if ground <= WorldGenerator.SEA_LEVEL:
				continue
			# Prefer flat ground: sample a 5x5 patch and score the flatness.
			var score := 0.0
			var samples := 0
			for dx in range(-2, 3):
				for dz in range(-2, 3):
					var y := _surface_y(Vector3i(cx2 + dx, 0, cz2 + dz))
					if y <= WorldGenerator.SEA_LEVEL:
						score -= 4.0
						continue
					score -= absf(float(y - ground)) * 0.5
					samples += 1
			score /= maxf(1.0, float(samples))
			if score > best_score:
				best_score = score
				best = Vector3i(cx2, ground + 1, cz2)
	return best


## First air column above solid ground, or 0 when there is none.
func _surface_y(pos: Vector3i) -> int:
	if world == null:
		return 0
	var y := 64
	while y > 1:
		if world.solid_at(Vector3i(pos.x, y, pos.z)) \
				and not world.solid_at(Vector3i(pos.x, y + 1, pos.z)):
			return y + 1
		y -= 1
	return 0


## A random loaded, unobstructed surface point within `radius` of `origin`.
func _scatter_point(rng: RandomNumberGenerator, origin: Vector3i,
		radius: float) -> Vector3i:
	for _i in 10:
		var x := origin.x + int(rng.randf_range(-radius, radius))
		var z := origin.z + int(rng.randf_range(-radius, radius))
		var y := _surface_y(Vector3i(x, 0, z))
		if y <= WorldGenerator.SEA_LEVEL:
			continue
		if not world.solid_at(Vector3i(x, y - 1, z)):
			continue
		# Two blocks of headroom so props do not intersect terrain.
		if world.solid_at(Vector3i(x, y, z)) \
				or world.solid_at(Vector3i(x, y + 1, z)):
			continue
		return Vector3i(x, y, z)
	return Vector3i.ZERO


func _place_prop(scene: PackedScene, spot: Vector3i, scale: float,
		rng: RandomNumberGenerator) -> Node3D:
	var node := scene.instantiate()
	if node == null:
		return null
	node.scale = Vector3(scale, scale, scale)
	# Poly Haven props are modelled in metres with their origin at the base, so
	# the instance sits directly on the block face.
	node.position = Vector3(spot.x + 0.5, float(spot.y), spot.z + 0.5)
	node.rotation.y = rng.randf_range(0.0, TAU)
	add_child(node)
	_prop_count += 1
	return node
