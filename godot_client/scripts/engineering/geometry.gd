class_name EngGeometry
extends RefCounted
## Geometry: turn a part's DATA into a mesh, cheaply.
##
## There is no "shaft.glb" in this project and there never will be. A part is
## a base shape, three dimensions, a material and a list of holes, and this
## file turns that into triangles. That is what makes "cut a custom wooden
## piece" expressible at all: the player cuts a plank twice and the result is
## a shorter plank, not a selection from a list of chair legs.
##
## Two things keep this from destroying performance, which is the real
## constraint on procedural geometry:
##
##  * Holes are cut by skipping quads, not by booleaning solid geometry, so a
##    drilled plate costs a few dozen triangles rather than a mesh operation.
##  * Meshes are cached by their full parameter set. Two plates of the same
##    size in the same material with the same holes are the same mesh, and a
##    factory full of identical bolts instantiates one.
##
## Stock StandardMaterial3D only. No custom shaders anywhere: a voxel game
## that needs a shader to draw a drilled plate has already lost.

## Above this many cached meshes the least recently used are dropped. Sized so
## a typical factory stays well inside it while a player who really does
## custom-cut five hundred different sizes does not grow without bound.
const CACHE_LIMIT := 512

static var _cache := {}
static var _cache_order: Array[String] = []
## Bumped whenever the generation algorithm changes, so old cached meshes
## built by an earlier version are never reused.
const MESH_VERSION := 3

## Resolution of a cylinder. Twelve sides is enough to read as round at voxel
## scale and is a third of what a naive implementation would use.
const SIDES := 12


## Build (or fetch from cache) the mesh for a part.
static func mesh_for(part: EngPart) -> ArrayMesh:
	if part == null:
		return null
	var key := cache_key(part)
	if _cache.has(key):
		var hit: ArrayMesh = _cache[key]
		_cache_order.erase(key)
		_cache_order.append(key)
		return hit
	var mesh := _build(part)
	_cache[key] = mesh
	_cache_order.append(key)
	while _cache_order.size() > CACHE_LIMIT:
		_drop_oldest()
	return mesh


## A stable key over everything that affects the generated geometry. Anything
## that changes a triangle has to change this string, or the cache will serve
## the wrong mesh -- which is the classic way a procedural geometry system
## produces "impossible" artefacts.
static func cache_key(part: EngPart) -> String:
	var parts := PackedStringArray()
	parts.append("v%d" % MESH_VERSION)
	parts.append(str(part.shape))
	parts.append("%.4f,%.4f,%.4f" % [part.size.x, part.size.y, part.size.z])
	parts.append(part.material)
	# Holes, rounded so a hole 0.001 to one side reuses the same mesh.
	for h in part.holes:
		var hd: Dictionary = h
		var p: Vector3 = hd.get("pos", Vector3.ZERO)
		parts.append("%.3f,%.3f,%.3f,%.3f,%.3f" % [p.x, p.y, p.z,
			float(hd.get("radius", 0.05)), float(hd.get("depth", part.size.y))])
	return "|".join(parts)


static func _drop_oldest() -> void:
	if _cache_order.is_empty():
		return
	var oldest: String = _cache_order.pop_front()
	_cache.erase(oldest)


static func cache_size() -> int:
	return _cache.size()


static func clear_cache() -> void:
	_cache.clear()
	_cache_order.clear()


## A stock material for a part, tinted by the engineering material's colour.
## Roughness and metallic come from the material's own properties, so copper
## looks like copper and rubber looks like rubber without a single shader.
static func material_for(part: EngPart) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = EngMaterials.color_of(part.material)
	m.metallic = clampf(EngMaterials.get_prop(part.material,
		"electrical_conductivity") * 0.85, 0.0, 1.0)
	m.roughness = clampf(1.0 - EngMaterials.get_prop(part.material, "hardness")
		* 0.5 - part.surface_finish * 0.4, 0.05, 1.0)
	return m


## A ready-to-add MeshInstance3D for a part, positioned and rotated.
static func instance_for(part: EngPart, position := Vector3.ZERO,
		rotation_y := 0.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "EngPart"
	mi.mesh = mesh_for(part)
	mi.material_override = material_for(part)
	mi.position = position
	mi.rotation.y = rotation_y
	return mi

# --- generation ------------------------------------------------------------

static func _build(part: EngPart) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	match part.shape:
		EngPart.Shape.ROD:
			_cylinder(st, part.size, 0.0)
		EngPart.Shape.TUBE:
			_cylinder(st, part.size, _inner_radius(part))
		EngPart.Shape.RING:
			_ring(st, part.size)
		EngPart.Shape.WEDGE:
			_wedge(st, part.size)
		_:
			# PLANK, PLATE and BLOCK are all boxes; they differ only in the
			# proportions the player gave them.
			_holed_box(st, part)
	st.generate_normals()
	return st.commit()


## Which axis a hole runs along, inferred from where it sits relative to the
## part. A hole drilled into a plate runs through the thin axis; drilled into
## a block it runs through the shortest one, which is what a drill does.
static func _hole_axis(part: EngPart) -> int:
	var smallest := 0
	if part.size.y < part.size.x:
		smallest = 1
	if part.size.z < part.size[smallest]:
		smallest = 2
	return smallest


static func _inner_radius(part: EngPart) -> float:
	var axis := _hole_axis(part)
	var others := [part.size.x, part.size.y, part.size.z]
	var outer: float = maxf(maxf(others[0], others[1]), others[2]) * 0.5
	var holes := part.holes
	if not holes.is_empty():
		outer = minf(outer, float((holes[0] as Dictionary).get("radius", 0.05)) * 2.0)
	return maxf(outer * 0.6, 0.005)


## A box with holes punched through it.
##
## The trick is that a pierced face is emitted as a grid of small quads and
## the quads inside a hole are simply not emitted. No booleans, no re-mesh,
## and the result is a genuine opening you can see through -- which matters,
## because the whole point of drilling a hole is that a bolt goes through it
## later.
##
## Grid resolution is derived from the hole radius rather than the part size,
## so a 2 mm hole in a 40 cm plate is still a visible opening instead of a
## sub-triangle. It is capped, because a hole is a circle approximated by
## squares and a player does not need a 200-sided polygon to recognise one.
const MAX_CELLS := 16


static func _holed_box(st: SurfaceTool, part: EngPart) -> void:
	var axis := _hole_axis(part)
	for entry in FACES:
		var f: Dictionary = entry
		var normal: Vector3 = f["n"]
		var u: Vector3 = f["u"]
		var v: Vector3 = f["v"]
		var sn: float = part.size[_axis_of(normal)]
		var su: float = part.size[_axis_of(u)]
		var sv: float = part.size[_axis_of(v)]
		# Only the two faces the hole axis points at are pierced.
		var pierced: bool = _axis_of(normal) == axis
		var res := 1
		if pierced:
			for hole in part.holes:
				var r: float = maxf(float((hole as Dictionary).get("radius", 0.05)),
					0.002)
				res = maxi(res, clampi(int(roundf(maxf(su, sv) / maxf(r * 0.5,
					0.002))), 1, MAX_CELLS))
		var base := normal * (sn * 0.5)
		for iu in res:
			for iv in res:
				var u0 := -su * 0.5 + su * float(iu) / float(res)
				var u1 := -su * 0.5 + su * float(iu + 1) / float(res)
				var v0 := -sv * 0.5 + sv * float(iv) / float(res)
				var v1 := -sv * 0.5 + sv * float(iv + 1) / float(res)
				if pierced:
					var centre := base + u * ((u0 + u1) * 0.5) + v * ((v0 + v1) * 0.5)
					if _inside_any_hole(part, centre, axis):
						continue
				_quad(st, base + u * u0 + v * v0, base + u * u1 + v * v0,
					base + u * u1 + v * v1, base + u * u0 + v * v1)


## The six box faces, each as an outward normal plus two in-plane axes chosen
## so that u cross v equals n. Getting that handedness right is what makes
## every face lit correctly without a single per-face special case.
const FACES := [
	{"n": Vector3(1, 0, 0), "u": Vector3(0, 0, -1), "v": Vector3(0, 1, 0)},
	{"n": Vector3(-1, 0, 0), "u": Vector3(0, 0, 1), "v": Vector3(0, 1, 0)},
	{"n": Vector3(0, 1, 0), "u": Vector3(1, 0, 0), "v": Vector3(0, 0, -1)},
	{"n": Vector3(0, -1, 0), "u": Vector3(1, 0, 0), "v": Vector3(0, 0, 1)},
	{"n": Vector3(0, 0, 1), "u": Vector3(1, 0, 0), "v": Vector3(0, 1, 0)},
	{"n": Vector3(0, 0, -1), "u": Vector3(-1, 0, 0), "v": Vector3(0, 1, 0)},
]


static func _axis_of(v: Vector3) -> int:
	return 0 if absf(v.x) > 0.5 else (1 if absf(v.y) > 0.5 else 2)


static func _inside_any_hole(part: EngPart, at: Vector3, axis: int) -> bool:
	for hole in part.holes:
		var hd: Dictionary = hole
		var hp: Vector3 = hd.get("pos", Vector3.ZERO)
		var r: float = float(hd.get("radius", 0.05))
		var perp := Vector3(hp.x, hp.y, hp.z)
		perp[axis] = 0.0
		var delta := Vector3(at.x, at.y, at.z)
		delta[axis] = 0.0
		if perp.distance_to(delta) <= r:
			return true
	return false


static func _cylinder(st: SurfaceTool, size: Vector3, inner: float) -> void:
	var r: float = maxf(size.x, size.z) * 0.5
	var half := size.y * 0.5
	var outer := []
	var inner_pts := []
	for i in SIDES:
		var a := TAU * float(i) / float(SIDES)
		outer.append(Vector3(cos(a) * r, 0.0, sin(a) * r))
		if inner > 0.0:
			inner_pts.append(Vector3(cos(a) * inner, 0.0, sin(a) * inner))
	for i in SIDES:
		var j := (i + 1) % SIDES
		var p0: Vector3 = outer[i]
		var p1: Vector3 = outer[j]
		# side
		_quad(st, Vector3(p0.x, -half, p0.z), Vector3(p1.x, -half, p1.z),
			Vector3(p1.x, half, p1.z), Vector3(p0.x, half, p0.z))
		# caps
		_tri(st, Vector3(0, -half, 0), Vector3(p0.x, -half, p0.z),
			Vector3(p1.x, -half, p1.z))
		if inner <= 0.0:
			_tri(st, Vector3(0, half, 0), Vector3(p1.x, half, p1.z),
				Vector3(p0.x, half, p0.z))
	for i in SIDES:
		var j := (i + 1) % SIDES
		if inner > 0.0:
			var a0: Vector3 = inner_pts[i]
			var a1: Vector3 = inner_pts[j]
			_quad(st, Vector3(a1.x, -half, a1.z), Vector3(a0.x, -half, a0.z),
				Vector3(a0.x, half, a0.z), Vector3(a1.x, half, a1.z))
			# annular end rings
			_ring_quad(st, outer[i], outer[j], inner_pts[j], inner_pts[i], -half)
			_ring_quad(st, inner_pts[i], inner_pts[j], outer[j], outer[i], half)


static func _ring(st: SurfaceTool, size: Vector3) -> void:
	var r: float = maxf(size.x, size.z) * 0.5
	var thickness: float = maxf(size.y, 0.01)
	var half := thickness * 0.5
	var inner: float = maxf(r - maxf(size.y, 0.02) * 0.5, r * 0.25)
	for i in SIDES:
		var a := TAU * float(i) / float(SIDES)
		var b := TAU * float(i + 1) / float(SIDES)
		var o0 := Vector3(cos(a) * r, 0.0, sin(a) * r)
		var o1 := Vector3(cos(b) * r, 0.0, sin(b) * r)
		var i0 := Vector3(cos(a) * inner, 0.0, sin(a) * inner)
		var i1 := Vector3(cos(b) * inner, 0.0, sin(b) * inner)
		_ring_quad(st, o0, o1, i1, i0, -half)
		_ring_quad(st, i0, i1, o1, o0, half)


static func _ring_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
		d: Vector3, y: float) -> void:
	_quad(st, Vector3(a.x, y, a.z), Vector3(b.x, y, b.z), Vector3(c.x, y, c.z),
		Vector3(d.x, y, d.z))


static func _wedge(st: SurfaceTool, size: Vector3) -> void:
	var x := size.x * 0.5
	var y := size.y * 0.5
	var z := size.z * 0.5
	var p000 := Vector3(-x, -y, -z)
	var p100 := Vector3(x, -y, -z)
	var p101 := Vector3(x, -y, z)
	var p001 := Vector3(-x, -y, z)
	# The top edge collapses to a line along Z at x = -x, which is what makes
	# this a wedge rather than a box.
	var top := Vector3(-x, y, 0.0)
	# bottom
	_quad(st, p000, p001, p101, p100)
	# back and front
	_tri(st, p000, p100, top)
	_tri(st, p001, top, p101)
	# left slope
	_tri(st, p000, top, p001)
	# right face
	_quad(st, p100, p101, p101, p100)


static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
		d: Vector3) -> void:
	_tri(st, a, b, c)
	_tri(st, a, c, d)


static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	# Degenerate triangles (two coincident corners) would produce a zero
	# normal, which lights as black. Give them the previous normal instead of
	# letting NaNs into the buffer.
	var n := (b - a).cross(c - a)
	if n.length_squared() < 1e-12:
		st.add_vertex(a)
		st.add_vertex(b)
		st.add_vertex(c)
		return
	st.set_normal(n.normalized())
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)
