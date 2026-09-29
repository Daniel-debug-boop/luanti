class_name EngFastening
extends RefCounted
## Smart fastening: bolts that place themselves.
##
## The player's job is to hold two parts against each other and click. The
## game's job is to work out where a bolt can physically go, whether the
## materials will take one, and to make the hole it needs.
##
## Nothing here knows what a motor is. It knows that two structural parts
## overlap, that their shared face has an area, and that you can fit a
## bolt in a lattice across that area without hitting an edge. That is why
## bolting a housing to a motor and bolting a plank to a frame use the same
## code.

## Default search radius, in blocks.
const DEFAULT_RADIUS := 2.5
## How far off the contact plane a candidate may sit and still be believable.
const PLANE_TOLERANCE := 0.35
## Bolt spacing, in blocks, across the contact face.
const PITCH := 0.5
## Minimum bolt radius, so a bolt through a 4 cm part is still a bolt.
const MIN_RADIUS := 0.015


## Find fastening points near `position`.
##
## Returns an Array of candidates, best first, each:
##   { position, normal, a, b, radius, ok, reason, label }
##
## `ok` false candidates are returned too, and with a reason: the player
## needs to be able to see WHY a spot will not take a bolt, or they will just
## click at empty air and conclude the tool is broken.
static func candidates(graph: EngGraph, position: Vector3,
		radius := DEFAULT_RADIUS, bolt_id := "bolt") -> Array:
	var out: Array = []
	if graph == null:
		return out
	var near := graph.nodes_near(position, radius)
	if near.size() < 2:
		return out
	var bolt_material := _bolt_material(bolt_id)
	for i in near.size():
		for j in range(i + 1, near.size()):
			var a: EngGraph.EngNode = near[i]
			var b: EngGraph.EngNode = near[j]
			if a == null or b == null:
				continue
			var pair := _pair_candidates(graph, a, b, bolt_material)
			for c in pair:
				c["distance"] = (c["position"] as Vector3).distance_to(position)
				out.append(c)
	# Best first: legal before illegal, then nearest the aim, then stable by
	# position so the list does not shuffle between frames.
	out.sort_custom(func(x, y):
		var lx: bool = bool(x["ok"])
		var ly: bool = bool(y["ok"])
		if lx != ly:
			return lx
		if not is_equal_approx(float(x["distance"]), float(y["distance"])):
			return float(x["distance"]) < float(y["distance"])
		var px: Vector3 = x["position"]
		var py: Vector3 = y["position"]
		return px.x < py.x if not is_equal_approx(px.x, py.x) else px.y < py.y)
	return out


## Every bolt position that holds `a` and `b` together.
static func _pair_candidates(graph: EngGraph, a: EngGraph.EngNode, b: EngGraph.EngNode,
		bolt_material: String) -> Array:
	var out: Array = []
	# Parts only fasten to parts that offer a structural port, or to other
	# stock parts. A wire has nowhere to be bolted to.
	if not _fastenable(a) or not _fastenable(b):
		return out
	# The contact plane sits between the two centres, perpendicular to the
	# line joining them. That is the face the bolt has to cross.
	var delta := b.position - a.position
	var separation := delta.length()
	if separation < 0.0001 or separation > DEFAULT_RADIUS * 1.5:
		return out
	var normal := delta / separation
	# Both parts must be thick enough on that axis to be worth drilling.
	var reach_a := _half_thickness(a, normal)
	var reach_b := _half_thickness(b, normal)
	if reach_a < MIN_RADIUS or reach_b < MIN_RADIUS:
		return out
	var centre := (a.position + b.position) * 0.5
	var basis := _orthonormal(normal)
	var u: Vector3 = basis[0]
	var v: Vector3 = basis[1]
	# A lattice sized to the smaller of the two parts, so a bolt never
	# overhangs the plate it is supposed to be holding down.
	var span_a: Vector2 = _overlap(a, centre, u, v, normal)
	var span_b: Vector2 = _overlap(b, centre, u, v, normal)
	var span := Vector2(minf(span_a.x, span_b.x), minf(span_a.y, span_b.y))
	if span.x <= 0.0 or span.y <= 0.0:
		return out
	var steps_u := clampi(int(floorf(span.x / PITCH)) + 1, 1, 4)
	var steps_v := clampi(int(floorf(span.y / PITCH)) + 1, 1, 4)
	var radius := maxf(minf(reach_a, reach_b) * 0.4, MIN_RADIUS)
	for iu in steps_u:
		for iv in steps_v:
			var ou: float = 0.0 if steps_u == 1 else lerpf(-span.x * 0.5,
				span.x * 0.5, float(iu) / float(steps_u - 1))
			var ov: float = 0.0 if steps_v == 1 else lerpf(-span.y * 0.5,
				span.y * 0.5, float(iv) / float(steps_v - 1))
			var pos: Vector3 = centre + u * ou + v * ov
			var verdict := validate(a, b, radius, bolt_material)
			out.append({
				"position": pos,
				"normal": normal,
				"a": a.id,
				"b": b.id,
				"radius": radius,
				"separation": separation,
				"ok": bool(verdict["ok"]),
				"reason": String(verdict["reason"]),
				"label": "%s %s %s" % [a.component_id, verdict["label"], b.component_id],
			})
	# Deduplicate: two pairs can share a contact patch, and offering the same
	# bolt spot three times makes the candidate list feel broken.
	var seen := {}
	var unique: Array = []
	for c in out:
		var p: Vector3 = c["position"]
		var key := "%.2f_%.2f_%.2f" % [p.x, p.y, p.z]
		if seen.has(key):
			continue
		seen[key] = true
		unique.append(c)
	return unique


## Can a bolt of this radius hold these two parts together? Returns
## { ok, reason, label }.
static func validate(a: EngGraph.EngNode, b: EngGraph.EngNode, radius: float,
		bolt_material := "steel") -> Dictionary:
	var ma := _material_of(a)
	var mb := _material_of(b)
	# What decides a bolt joint is toughness, and the threshold is a fraction
	# of the bolt's own rather than a strict inequality. A wooden frame
	# takes a steel bolt -- that is the commonest joint in the game -- while
	# glass and unfired clay cannot grip one, and the player is told which.
	var need := EngMaterials.get_prop(bolt_material, "toughness") * 0.3
	for m in [ma, mb]:
		if EngMaterials.get_prop(String(m), "toughness") < need:
			return {"ok": false, "reason": "%s is too brittle to take a %s bolt" % [
				String(m), bolt_material], "label": "will not hold"}
	# A bolt needs something to bite into on both sides.
	if EngMaterials.get_prop(ma, "hardness") < 0.1 and \
			EngMaterials.get_prop(mb, "hardness") < 0.1:
		return {"ok": false, "reason": "nothing solid to bolt into",
			"label": "no purchase"}
	return {"ok": true, "reason": "", "label": "bolted"}


## Place a bolt at `position`, creating the hole it needs and the structural
## connection that holds the two parts together.
##
## Returns { ok, reason, node, edge, part }. The hole is recorded on both
## parts, because that is what makes the joint real: a bolt through a
## pre-drilled hole is a different joint from a bolt forced through solid
## steel, and the mesh shows the difference.
static func place(graph: EngGraph, position: Vector3, radius := DEFAULT_RADIUS,
		bolt_id := "bolt") -> Dictionary:
	var cands := candidates(graph, position, radius, bolt_id)
	for c in cands:
		if not bool(c["ok"]):
			continue
		if float((c["position"] as Vector3).distance_to(position)) > radius:
			continue
		return _place_at(graph, c)
	return {"ok": false, "reason": "no valid fastening point here",
		"node": 0, "edge": 0, "part": null}


## Place at a specific candidate, which is what the click does when the player
## has already moved the cursor between candidates.
static func place_at(graph: EngGraph, candidate: Dictionary,
		bolt_id := "bolt") -> Dictionary:
	if not bool(candidate.get("ok", false)):
		return {"ok": false, "reason": String(candidate.get("reason", "")),
			"node": 0, "edge": 0, "part": null}
	return _place_at(graph, candidate)


static func _place_at(graph: EngGraph, c: Dictionary) -> Dictionary:
	var a: EngGraph.EngNode = graph.node(int(c["a"]))
	var b: EngGraph.EngNode = graph.node(int(c["b"]))
	var pos: Vector3 = c["position"]
	var normal: Vector3 = c["normal"]
	var bolt_radius := float(c["radius"])

	# The bolt is a real part, so the hole in the plate is real geometry and
	# the bolt is real mass the structural check can see.
	var part := EngPart.rod("steel", (c["separation"] as float) + bolt_radius * 2.0,
		bolt_radius * 2.0)
	part.component_id = String(c.get("component", "bolt"))
	part.label = "bolt"
	# A bolt is made WITH its hole rather than drilled afterwards: a drilled
	# rod is not a legal operation, and pretending otherwise would mean the
	# bolt's geometry disagreed with how the part system says holes arise.
	part.operations.append("drill")
	part.holes.append({"pos": Vector3(0, 0, 0), "radius": bolt_radius * 0.45,
		"depth": part.size.x})
	var node := graph.place(String(c.get("component", "bolt")), pos, 0.0, part)
	if node < 0:
		return {"ok": false, "reason": "unknown fastener", "node": 0, "edge": 0,
			"part": null}
	# The hole exists in both parts it passes through.
	_drill_hole(a, pos, bolt_radius)
	_drill_hole(b, pos, bolt_radius)
	# A bolt is a structural component: connecting it to both parts ties the
	# pair into one assembly, which is what makes the recognition walk reach
	# across the joint.
	var edge := 0
	for host in [a, b]:
		var r := graph.link(node, "a", host.id, _mount_port(host))
		if bool(r["ok"]):
			edge = int(r["edge"])
		elif edge == 0:
			var r2 := graph.link(node, "b", host.id, _mount_port(host))
			if bool(r2["ok"]):
				edge = int(r2["edge"])
	return {"ok": true, "reason": "", "node": node, "edge": edge, "part": part}


static func _drill_hole(host: EngGraph.EngNode, at: Vector3, radius: float) -> void:
	if host == null:
		return
	if host.part == null:
		# Stock components without a manufactured part still record the hole
		# as part data, so a save reproduces it and the count is available.
		var p := EngPart.block(EngPorts.get_def(host.component_id).material, 0.1)
		host.part = p
	if host.part.holes.is_empty():
		host.part.operations.append("drill")
	host.part.holes.append({"pos": at - host.position, "radius": radius,
		"depth": 0.1})


## A structural port on a component, if it has one. A bolt needs somewhere to
## attach, and "somewhere structural" is the whole rule.
static func _mount_port(node: EngGraph.EngNode) -> String:
	var def := EngPorts.get_def(node.component_id)
	if def == null:
		return ""
	for p in def.ports:
		var port: EngPorts.Port = p
		if port.kind == EngPorts.Kind.STRUCTURAL:
			return port.name
	return def.port_names()[0] if not def.port_names().is_empty() else ""


static func _fastenable(n: EngGraph.EngNode) -> bool:
	if n == null:
		return false
	var def := EngPorts.get_def(n.component_id)
	if def == null:
		return false
	# Anything with a structural port, or any stock structural part, can be
	# bolted. A wire cannot: there is nothing to grip.
	if _mount_port(n) == "":
		return false
	return true


static func _bolt_material(bolt_id: String) -> String:
	if not EngPorts.has(bolt_id):
		return "steel"
	return EngPorts.get_def(bolt_id).material


static func _material_of(n: EngGraph.EngNode) -> String:
	if n.part != null:
		return n.part.material
	var def := EngPorts.get_def(n.component_id)
	return def.material if def != null else "steel"


## Half the part's extent along `axis`, from its manufactured part when it has
## one and from the component's material cost when it does not.
static func _half_thickness(n: EngGraph.EngNode, axis: Vector3) -> float:
	if n.part != null:
		var d := n.part.size[0] if absf(axis.x) > 0.5 else (
			n.part.size[1] if absf(axis.y) > 0.5 else n.part.size[2])
		return maxf(d * 0.5, 0.0)
	var def := EngPorts.get_def(n.component_id)
	if def == null:
		return 0.0
	# Stock components are sized from their material cost, which is already in
	# cubic blocks, so a bolt through a housing lands in a plausible place.
	return maxf(pow(def.material_cost, 1.0 / 3.0), 0.05)


## The extent of `n`'s footprint on the contact plane, as (u, v) half-spans.
static func _overlap(n: EngGraph.EngNode, centre: Vector3, u: Vector3,
		v: Vector3, normal: Vector3) -> Vector2:
	var half := _half_thickness(n, normal)
	var ext := Vector3(0.2, 0.2, 0.2)
	if n.part != null:
		ext = n.part.half_extent()
	else:
		var e := maxf(pow(EngPorts.get_def(n.component_id).material_cost,
			1.0 / 3.0), 0.05)
		ext = Vector3(e, e, e)
	# Projected onto the contact plane. A box's footprint is its full extent
	# in the two in-plane axes; the extent along the normal is what makes it
	# reach the other part, not what shrinks its face.
	var du := absf(u.x) * ext.x + absf(u.y) * ext.y + absf(u.z) * ext.z
	var dv := absf(v.x) * ext.x + absf(v.y) * ext.y + absf(v.z) * ext.z
	return Vector2(maxf(du, 0.0), maxf(dv, 0.0))


## Two axes perpendicular to `normal`.
static func _orthonormal(normal: Vector3) -> Array:
	var seed := Vector3.UP if absf(normal.y) < 0.9 else Vector3.RIGHT
	var u := normal.cross(seed).normalized()
	var v := normal.cross(u).normalized()
	return [u, v]
