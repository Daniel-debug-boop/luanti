class_name CreatureModels
extends RefCounted
## Loads the CC0 KayKit character models and fits them to a mob or villager.
##
## SOURCE: Kay Lousberg's KayKit, CC0 (public domain dedication).
##   * addons/kaykit_character_pack_adventures  (Knight, Mage, Barbarian)
##   * addons/kaykit_character_pack_skeletons   (Skeleton_Warrior, Skeleton_Minion)
## The GLBs are used unmodified; only the node scale and the tint are ours.
##
## These replace the coloured boxes the mobs and villagers used to be, which
## was the single most obviously unfinished thing about them.

const ADV := "res://addons/kaykit_character_pack_adventures/Characters/gltf/"
const SKE := "res://addons/kaykit_character_pack_skeletons/Characters/gltf/"

const VILLAGER_MODELS := [
	ADV + "Knight.glb",
	ADV + "Mage.glb",
	ADV + "Barbarian.glb",
]
const MOB_MODELS := [
	SKE + "Skeleton_Warrior.glb",
	SKE + "Skeleton_Minion.glb",
]

static var _cache := {}


static func _load_scene(path: String) -> PackedScene:
	if _cache.has(path):
		return _cache[path]
	if not ResourceLoader.exists(path):
		push_warning("[models] missing %s" % path)
		_cache[path] = null
		return null
	var scene: PackedScene = load(path)
	_cache[path] = scene
	return scene


## Pick a model path deterministically from a seed, so a given villager or mob
## keeps the same body between frames and between save/load.
static func pick(paths: Array, seed_value: int) -> String:
	if paths.is_empty():
		return ""
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return String(paths[rng.randi_range(0, paths.size() - 1)])


## Instantiate a character fitted to `target_height` and tinted `tint`.
## Returns null when the model is missing, so callers can fall back to the old
## primitive body rather than crashing.
static func spawn(path: String, target_height: float,
		tint := Color(1, 1, 1)) -> Node3D:
	var scene := _load_scene(path)
	if scene == null:
		return null
	var node: Node3D = scene.instantiate()

	# KayKit characters are modelled at roughly 1.7 units; measure the actual
	# instance and scale to fit rather than hard-coding a guess.
	var aabb := _combined_aabb(node)
	if aabb.size.y <= 0.001:
		node.scale = Vector3.ONE * (target_height / 1.7)
	else:
		var s := target_height / aabb.size.y
		node.scale = Vector3.ONE * s

	# Stand them on the origin, and face along -Z (Godot's forward) so the
	# existing look-at logic works unchanged.
	var offset := Vector3(0, -aabb.position.y * node.scale.y, 0)
	for child in node.get_children():
		if child is Node3D:
			(child as Node3D).position += offset

	if tint != Color(1, 1, 1):
		_apply_tint(node, tint)
	return node


static func _combined_aabb(root: Node) -> AABB:
	var out := AABB()
	var first := true
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		# MeshInstance3D.get_aabb() already folds in the node transform, which
		# is what we want: the result is in the model's own space.
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			if mi.mesh == null:
				continue
			var box := mi.get_aabb()
			if first:
				out = box
				first = false
			else:
				out = out.merge(box)
	return out


static func _apply_tint(root: Node, tint: Color) -> void:
	for c in root.get_children():
		if c is GeometryInstance3D:
			var g := c as GeometryInstance3D
			var mat := g.material_override
			if mat == null:
				mat = StandardMaterial3D.new()
			# Duplicate so tinting one mob does not tint the shared resource.
			mat = mat.duplicate()
			if mat is StandardMaterial3D:
				(mat as StandardMaterial3D).albedo_color = \
					(mat as StandardMaterial3D).albedo_color * tint
			g.material_override = mat
		_apply_tint(c, tint)
