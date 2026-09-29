class_name EngBlueprints
extends RefCounted
## Blueprint System: save a working assembly, put it back later, share it.
##
## A blueprint is the same data the graph already holds -- components,
## positions, dimensions, connections, machine state -- with the meshes left
## out, because the geometry is regenerated from the part data. A pump
## blueprint is a few hundred bytes, not a few megabytes, and reproducing one
## gives a pump with the same bore, the same holes and the same fluid ports
## rather than a generic prefab.
##
## Versioned and migratable from the first save, because a player who comes
## back to a world after an update must not lose their factory.

const DIR := "user://blueprints"
## Bumped when the on-disk shape changes. A blueprint from an older version
## goes through `migrate()` rather than being dropped.
const VERSION := 2
const FILE_PREFIX := "bp_"


## Capture a set of placed nodes as a blueprint. `nodes` may be the result of
## an assembly recognition, or any list of node ids the player selected.
static func capture(graph: EngGraph, node_ids: Array, title := "",
		author := "") -> Dictionary:
	if graph == null or node_ids.is_empty():
		return {}
	# Sort by id so capturing the same machine twice produces byte-identical
	# data. Without this every save differs from the last and diffs are
	# useless.
	var sorted: Array = node_ids.duplicate()
	sorted.sort()
	var inside := {}
	for nid in sorted:
		inside[int(nid)] = true

	# The origin is the average, so placing a blueprint puts it where the
	# player is standing rather than a thousand blocks from the origin.
	var centre := Vector3.ZERO
	for nid in sorted:
		centre += (graph.node(int(nid)) as EngGraph.EngNode).position
	centre /= float(sorted.size())

	var parts: Array = []
	var edges: Array = []
	for nid in sorted:
		var n: EngGraph.EngNode = graph.node(int(nid))
		if n == null:
			continue
		parts.append({
			"id": n.id,
			"component": n.component_id,
			"position": [(n.position - centre).x, (n.position - centre).y,
				(n.position - centre).z],
			"rotation_y": n.rotation_y,
			"enabled": n.enabled,
			"state": n.state.duplicate(true),
			"part": n.part.to_dict() if n.part != null else null,
		})
		for eid in graph.edges_of(n.id):
			var e: EngGraph.EngEdge = graph.edge(int(eid))
			if e == null:
				continue
			# Only edges wholly inside the blueprint, and only once.
			if not inside.has(e.a) or not inside.has(e.b):
				continue
			if e.a > e.b:
				continue
			edges.append({"a": e.a, "a_port": e.a_port, "b": e.b,
				"b_port": e.b_port, "kind": e.kind, "carries": e.carries})
	return {
		"version": VERSION,
		"name": title if title != "" else "untitled blueprint",
		"author": author,
		"nodes": parts,
		"edges": edges,
	}


## Reproduce a blueprint into `graph` at `origin`, rotated by `rotation_y`.
##
## Returns { ok, reason, nodes, edges }. Connections are re-established from
## the saved edges, which is the point: a reproduced pump is wired, not just
## stacked, so it works the moment it lands.
static func place(graph: EngGraph, bp: Dictionary, origin := Vector3.ZERO,
		rotation_y := 0.0) -> Dictionary:
	if graph == null or bp.is_empty():
		return {"ok": false, "reason": "empty blueprint", "nodes": [], "edges": 0}
	if int(bp.get("version", 0)) > VERSION:
		return {"ok": false, "reason": "blueprint is from a newer build",
			"nodes": [], "edges": 0}
	var migrated := migrate(bp)
	# Edges reference the node ids the blueprint was captured with, so the map
	# is keyed by that original id -- not by position in the list, which would
	# silently mis-wire any blueprint whose parts were not saved in id order.
	var id_map := {}
	var placed: Array = []
	for d0 in (migrated["nodes"] as Array):
		var d: Dictionary = d0
		var component := String(d.get("component", ""))
		if not EngPorts.has(component):
			continue
		var pos := _rotated(_vec3(d.get("position")), rotation_y) + origin
		var part: EngPart = null
		if d.get("part", null) is Dictionary:
			part = EngPart.from_dict(d["part"])
		var nid := graph.place(component, pos, float(d.get("rotation_y", 0.0)),
			part)
		if nid < 0:
			continue
		id_map[int(d.get("id", -1))] = nid
		var node_ref := graph.node(nid)
		node_ref.enabled = bool(d.get("enabled", true))
		var st = d.get("state", {})
		if st is Dictionary:
			node_ref.state = (st as Dictionary).duplicate(true)
		placed.append(nid)
	# Edges reference the OLD node ids, which are the indices into the saved
	# node list, so the map translates them.
	var wired := 0
	for e in (migrated["edges"] as Array):
		var ed: Dictionary = e
		var a := int(ed.get("a", -1))
		var b := int(ed.get("b", -1))
		if not id_map.has(a) or not id_map.has(b):
			continue
		var r := graph.link(int(id_map[a]), String(ed.get("a_port", "")),
			int(id_map[b]), String(ed.get("b_port", "")))
		if bool(r["ok"]):
			wired += 1
	graph.rebuild_networks()
	return {"ok": not placed.is_empty(), "reason": "",
		"nodes": placed, "edges": wired, "map": id_map}


static func _rotated(v: Vector3, angle: float) -> Vector3:
	if is_zero_approx(angle):
		return v
	return v.rotated(Vector3.UP, angle)


static func _vec3(v: Variant) -> Vector3:
	if v is Array and (v as Array).size() == 3:
		var a: Array = v
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO


## Bring an older blueprint up to the current shape. Every step is additive
## and defaults anything it cannot find, so a v1 blueprint from a world saved
## before gears existed still places.
static func migrate(bp: Dictionary) -> Dictionary:
	var out := bp.duplicate(true)
	var from := int(out.get("version", 1))
	if from >= VERSION:
		return out
	if from < 2:
		# v1 had no "enabled" flag; everything was on.
		for n in (out.get("nodes", []) as Array):
			if not (n as Dictionary).has("enabled"):
				(n as Dictionary)["enabled"] = true
		# v1 had no per-node state at all, so machines restart on load.
		for n in (out.get("nodes", []) as Array):
			if not (n as Dictionary).has("state"):
				(n as Dictionary)["state"] = {}
	out["version"] = VERSION
	out["migrated_from"] = from
	return out

# --- disk -------------------------------------------------------------------

static func _ensure_dir() -> void:
	if not DirAccess.dir_exists_absolute(DIR):
		DirAccess.make_dir_recursive_absolute(DIR)


## Write a blueprint to disk. The write is temp-file-plus-rename, the same
## scheme SaveGame uses, so a crash mid-write cannot leave a half blueprint
## that fails to parse on the next load.
static func save(bp: Dictionary, id := "") -> String:
	if bp.is_empty():
		return ""
	_ensure_dir()
	var key := id if id != "" else _id_for(String(bp.get("name", "untitled")))
	var path := "%s/%s%s.json" % [DIR, FILE_PREFIX, key]
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("[blueprints] cannot write %s" % tmp)
		return ""
	f.store_string(JSON.stringify(bp))
	f.close()
	var da := DirAccess.open(DIR)
	if da == null:
		return ""
	if da.file_exists(path):
		da.remove(path)
	var err := da.rename(tmp, path)
	if err != OK:
		DirAccess.remove_absolute(tmp)
		return ""
	return key


static func _id_for(name: String) -> String:
	return "%08x" % hash(name)


## Every saved blueprint, newest field first. Corrupt files are skipped with a
## warning rather than taking the whole list down.
static func list_all() -> Array:
	_ensure_dir()
	var out: Array = []
	var da := DirAccess.open(DIR)
	if da == null:
		return out
	for f in da.get_files():
		if not f.begins_with(FILE_PREFIX) or not f.ends_with(".json"):
			continue
		var path := "%s/%s" % [DIR, f]
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			continue
		var text := file.get_as_text()
		file.close()
		var parsed = JSON.parse_string(text)
		if not (parsed is Dictionary):
			push_warning("[blueprints] skipping unreadable %s" % f)
			continue
		var d: Dictionary = parsed
		d["id"] = f.trim_prefix(FILE_PREFIX).trim_suffix(".json")
		out.append(d)
	out.sort_custom(func(x, y):
		return String((x as Dictionary).get("name", "")) < String(
			(y as Dictionary).get("name", "")))
	return out


static func load_by_id(id: String) -> Dictionary:
	_ensure_dir()
	var path := "%s/%s%s.json" % [DIR, FILE_PREFIX, id]
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var text := file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {}
	return parsed as Dictionary


static func erase(id: String) -> bool:
	_ensure_dir()
	var path := "%s/%s%s.json" % [DIR, FILE_PREFIX, id]
	if not FileAccess.file_exists(path):
		return false
	return DirAccess.remove_absolute(path) == OK


## Copy a blueprint under a new id and a new name. Used for the "duplicate"
## action, and it is genuinely a copy rather than a reference, so the player
## can safely modify one of a pair.
static func duplicate(id: String, new_name := "") -> String:
	var bp := load_by_id(id)
	if bp.is_empty():
		return ""
	if new_name != "":
		bp["name"] = new_name
	return save(bp, "")


static func rename(id: String, new_name: String) -> bool:
	var bp := load_by_id(id)
	if bp.is_empty():
		return false
	bp["name"] = new_name
	return save(bp, id) != ""


## The blueprint as a compact, shareable string. This is the "export" path:
## a single token the player can paste to someone else, with no file involved.
static func export_text(bp: Dictionary) -> String:
	return Marshalls.utf8_to_base64(JSON.stringify(bp))


static func import_text(text: String) -> Dictionary:
	var raw := Marshalls.base64_to_raw(text.strip_edges())
	if raw.is_empty():
		return {}
	var parsed = JSON.parse_string(raw.get_string_from_utf8())
	return parsed as Dictionary if parsed is Dictionary else {}


## One line for the UI: how big is this, really.
static func size_bytes(bp: Dictionary) -> int:
	return JSON.stringify(bp).length()
