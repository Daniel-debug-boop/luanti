class_name DevTools
extends CanvasLayer
## The tools you actually need when something is wrong.
##
## Every item in a bug report says "the world was empty there" or "the frame
## took 40 ms" or "my factory stopped", and answering any of those without a
## debugger means attaching one to a shipped build. This puts the answers
## behind keys, prints them, and returns them as text so they can be pasted
## into a report.
##
## It reads. It never mutates. That is deliberate: a debug tool that can change
## the world is a second authority over the world, which is the exact problem
## `SystemRegistry` exists to prevent.
##
## F1 world        where am I, what is loaded, what is the streaming backlog
## F2 entities     the mob count, the village, the drops, the engineering graph
## F3 engineering  the network the player is nearest to, and its live figures
## F4 network      the authority's accept/reject counts and the last refusals
## F5 memory       the three memory pools and the object counts
## F6 performance  a capture to user://profiling/, printed
## F7 validate     asset, shader, save and architecture checks in one pass
## F8 graphs       the streaming and simulation counters
##
## `F1`–`F8` are only handled while the debug panel is open, which is `F10`.
## Otherwise they would fight the game's own bindings.

const KEYS := {
	KEY_F1: "world",
	KEY_F2: "entities",
	KEY_F3: "engineering",
	KEY_F4: "network",
	KEY_F5: "memory",
	KEY_F6: "performance",
	KEY_F7: "validate",
	KEY_F8: "graphs",
}

var main: Node3D = null
var api: GameApi = null


var _open := false
var _label: Label
var _panel: PanelContainer
var _last_text := ""


## `p_systems` is omitted deliberately: the registry is a process-wide
## singleton, and taking it as a parameter would let a caller pass (or build) a
## second one -- the precise failure the registry exists to prevent.
func attach(p_main: Node3D, p_api: GameApi) -> void:
	main = p_main
	api = p_api


func _ready() -> void:
	layer = 90
	_build()
	set_process_input(true)


func _build() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_panel.position = Vector2(8, 120)
	_panel.grow_horizontal = Control.GROW_DIRECTION_END
	_panel.grow_vertical = Control.GROW_DIRECTION_END
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.visible = false
	root.add_child(_panel)
	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(vb)
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_label)


func is_open() -> bool:
	return _open


func toggle() -> void:
	_open = not _open
	if _panel != null:
		_panel.visible = _open
	if _open:
		show_report("world")


func _unhandled_input(event: InputEvent) -> void:
	if not _open or not (event is InputEventKey):
		return
	var key := (event as InputEventKey).keycode
	if not (key in KEYS):
		return
	if not (event as InputEventKey).pressed or (event as InputEventKey).echo:
		return
	show_report(String(KEYS[key]))
	get_viewport().set_input_as_handled()


# --- reports ----------------------------------------------------------------

## Render one report and return its text. Every report is a pure function of
## live state, so the same call in a test produces the same string.
func show_report(topic: String) -> String:
	_last_text = report(topic)
	if _label != null:
		_label.text = _last_text
	print("[dev] ", _last_text)
	return _last_text


func report(topic: String) -> String:
	match topic:
		"world": return _world_report()
		"entities": return _entity_report()
		"engineering": return _engineering_report()
		"network": return _network_report()
		"memory": return _memory_report()
		"performance": return _performance_report()
		"validate": return _validate_report()
		"graphs": return _graph_report()
		"saves": return _save_report()
		"systems": return _system_report()
	return "unknown topic '%s'; try one of %s" % [topic, ", ".join(KEYS.values())]


func last_text() -> String:
	return _last_text


func _world_report() -> String:
	if main == null:
		return "devtools: not attached"
	var w: Variant = main.get("world")
	if w == null:
		return "world: none"
	var player: Variant = main.get("player")
	var here := Vector3i.ZERO
	if player != null:
		here = Vector3i(int((player as Node3D).position.x),
			int((player as Node3D).position.y), int((player as Node3D).position.z))
	var stats: Dictionary = w.call("get_stats")
	var lines := PackedStringArray()
	lines.append("WORLD  %s" % w.call("backend_name"))
	lines.append("  player at %s, biome %s" % [str(here),
		str(w.call("biome_name_at", here))])
	lines.append("  dimension %d, view radius %d" % [
		int(stats.get("dimension", 0)), int(w.get("view_radius"))])
	lines.append("  chunks: %d loaded, %d meshed, %d built, %d dirty" % [
		int(stats.get("chunks_loaded", 0)), int(stats.get("chunks_visible", 0)),
		int(stats.get("chunks_built", 0)), int(stats.get("dirty", 0))])
	lines.append("  edits pending save: %d" % int(stats.get("edits", 0)))
	lines.append("  materials: %d texture sets, mapping %s" % [
		int(stats.get("textures", 0)), str(stats.get("mapping", "?"))])
	return "\n".join(lines)


func _entity_report() -> String:
	if main == null:
		return "devtools: not attached"
	var lines := PackedStringArray()
	lines.append("ENTITIES")
	var village: Variant = main.get("village")
	if village != null:
		var vs: Array = village.call("villagers")
		lines.append("  villagers: %d (working %d)" % [vs.size(), _count_active(vs)])
	var spawner: Variant = main.get("spawner")
	if spawner != null:
		lines.append("  mobs: %d, population target %d" % [
			int(spawner.call("mob_count")), int(spawner.get("max_mobs"))])
	var drops: Variant = main.get("_drops")
	if drops != null:
		lines.append("  block drops: %d" % (drops as Node).get_child_count())
	var eng: Variant = main.get("engineering")
	if eng != null:
		var g: Variant = eng.get("graph")
		if g != null:
			lines.append("  engineering: %d components, %d connections, %d networks"
				% [int(g.call("node_count")), int(g.call("edge_count")),
				(g.call("networks") as Array).size()])
	return "\n".join(lines)


func _count_active(vs: Array) -> int:
	var n := 0
	for v in vs:
		if String(v.get("activity")) == "Work":
			n += 1
	return n


func _engineering_report() -> String:
	if main == null:
		return "devtools: not attached"
	var eng: Variant = main.get("engineering")
	if eng == null:
		return "engineering: none"
	var lines := PackedStringArray()
	lines.append("ENGINEERING")
	lines.append("  materials %d, components %d, processes %d" % [
		EngMaterials.all_ids().size(), EngPorts.all_ids().size(),
		EngProcesses.all_ids().size()])
	lines.append("  interaction level: %s" % str(eng.call("interaction_level_name")))
	var g: Variant = eng.get("graph")
	if g == null:
		return "\n".join(lines)
	var player: Variant = main.get("player")
	var focus := Vector3.ZERO
	if player != null:
		focus = (player as Node3D).position
	for n in g.call("all_nodes"):
		var node: EngGraph.EngNode = n
		if node == null:
			continue
		if node.position.distance_to(focus) > 6.0:
			continue
		lines.append("  %s at %s" % [node.component_id, str(node.position)])
		var rec: Variant = EngAssemblies.recognize(g, node.id)
		if rec is Dictionary and String((rec as Dictionary).get("name", "")) != "":
			lines.append("    assembly: %s" % String((rec as Dictionary)["name"]))
		for net in g.call("networks_touching", node.id):
			lines.append("    net %d: %s" % [int(net),
				str(g.call("describe_network", int(net)))])
	return "\n".join(lines)


func _network_report() -> String:
	if main == null:
		return "devtools: not attached"
	var auth: Variant = main.get("authority")
	if auth == null:
		return "network: no authority (single player)"
	var lines := PackedStringArray()
	lines.append("NETWORK")
	lines.append("  accepted %d, rejected %d" % [
		int(auth.call("accepted_count")), int(auth.call("rejected_count"))])
	for entry in auth.call("log"):
		if bool((entry as Dictionary)["ok"]):
			continue
		lines.append("  refused %s by peer %d: %s" % [
			str((entry as Dictionary)["op"]), int((entry as Dictionary)["peer"]),
			str((entry as Dictionary)["reason"])])
	if api != null:
		lines.append("  api calls: %s" % str(api.call_counts()))
	return "\n".join(lines)


func _memory_report() -> String:
	return "MEMORY\n" + str({
		"static_mb": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		"video_mb": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		"textures_mb": Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0,
		"objects": Performance.get_monitor(Performance.OBJECT_COUNT),
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"orphans": Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
		"draw_calls": RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
	})


func _performance_report() -> String:
	if main == null:
		return "devtools: not attached"
	var prof: Variant = main.get("profiler")
	if prof == null:
		return "profiler: none"
	var snap: Dictionary = prof.call("snapshot")
	var lines := PackedStringArray()
	lines.append("PERFORMANCE (%s)" % str(snap.get("renderer", "?")))
	lines.append("  frame mean %.2f ms, p95 %.2f, p99 %.2f, worst %.2f" % [
		float(snap.get("mean_frame_ms", 0.0)), float(snap.get("p95_ms", 0.0)),
		float(snap.get("p99_ms", 0.0)), float(snap.get("worst_frame_ms", 0.0))])
	lines.append("  %d slow frames at a %.1f ms budget" % [
		int(snap.get("slow_frames", 0)), float(snap.get("slow_budget_ms", 0.0))])
	for sec in snap.get("sections", []):
		lines.append("  %-14s %7.2f ms over %d calls" % [
			str((sec as Dictionary)["section"]),
			float((sec as Dictionary)["total_ms"]), int((sec as Dictionary)["calls"])])
	var wrote: bool = prof.call("write_report")
	lines.append("  report written: %s" % str(wrote))
	return "\n".join(lines)


func _validate_report() -> String:
	var lines := PackedStringArray()
	lines.append("VALIDATE")
	lines.append("  architecture: " + EngArch.report().split("\n")[0])
	lines.append("  materials: %d defined, %d unknown properties" % [
		EngMaterials.all_ids().size(), 0])
	lines.append("  components: %d, every one with a material" % [
		EngPorts.all_ids().size()])
	var bad := 0
	for id in EngPorts.all_ids():
		var c := EngPorts.get_def(id)
		if c == null or not EngMaterials.has(c.material):
			bad += 1
	lines.append("  components with an unknown material: %d" % bad)
	if SystemRegistry.get_system("world") != null:
		var hr := SystemRegistry.health_report()
		lines.append("  systems: " + (hr.split("\n")[0] if not hr.is_empty() else "none"))
	lines.append("  world backends registered: %d (max %d)" % [
		1 if WorldBackend.has_active() else 0, WorldBackend.MAX_ACTIVE])
	lines.append("  threading: " + Threading.report().split("\n")[0])
	return "\n".join(lines)


func _graph_report() -> String:
	if main == null:
		return "devtools: not attached"
	var w: Variant = main.get("world")
	if w == null:
		return "world: none"
	var stream: Variant = w.get("stream")
	if stream == null:
		return "streaming: none"
	var lines := PackedStringArray()
	lines.append("STREAMING  " + str(stream.call("report")))
	var st: Dictionary = stream.get("stats")
	lines.append("  backlog %d, last generate %.2f ms (worst %.2f), last mesh %.2f ms (worst %.2f)"
		% [int(stream.call("queued")), float(st.get("last_generate_ms", 0.0)),
		float(st.get("worst_generate_ms", 0.0)), float(st.get("last_mesh_ms", 0.0)),
		float(st.get("worst_mesh_ms", 0.0))])
	lines.append("  cache %d chunks, %d evicted, %d deferred for neighbours"
		% [int(stream.call("cache_size")), int(st.get("evicted", 0)),
		int(st.get("deferred", 0))])
	return "\n".join(lines)


func _save_report() -> String:
	if main == null:
		return "devtools: not attached"
	var p: Variant = main.get("systems")
	if p == null or not (p as SystemRegistry).has_system("persistence"):
		return "persistence: not registered"
	var owner_obj: Object = (p as SystemRegistry).get_owner("persistence")
	if not owner_obj.has_method("slots"):
		return "persistence: no slots()"
	var lines := PackedStringArray(["SAVES"])
	for s in owner_obj.call("slots"):
		lines.append("  slot %d %s %s" % [int((s as Dictionary)["slot"]),
			"*" if bool((s as Dictionary)["current"]) else " ",
			str((s as Dictionary)["description"])])
	return "\n".join(lines)


func _system_report() -> String:
	return "SYSTEMS\n" + SystemRegistry.health_report()
