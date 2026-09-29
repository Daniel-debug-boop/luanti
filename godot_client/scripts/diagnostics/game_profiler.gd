class_name GameProfiler
extends Node
## Real, on-hardware performance instrumentation for EMERGENT.
##
## The development environment has no GPU and no display server, so nothing
## here has ever been *rendered*. What this class provides is the missing half
## of that problem: the instrumentation that makes the numbers obtainable on
## the target machine. Run the game, press F3, and the overlay reports what the
## engine actually measured -- frame time, physics time, the GPU-side counters
## `RenderingServer` exposes, and a per-system breakdown of EMERGENT's own tick
## cost. `write_report()` dumps the same data as JSON.
##
## Design rules:
##   * Zero cost when disabled. `enabled` is checked at every entry point, so a
##     shipped build pays one boolean branch.
##   * No per-frame allocation in the hot path. Timings go into preallocated
##     PackedFloat64Arrays; percentiles are computed on demand.
##   * Sections are named strings resolved to indices once and cached in a
##     Dictionary, so `mark()` is a pair of array writes.
##
## Usage from any system you want measured:
##     profiler.mark("engineering")
##     ... work ...
##     profiler.unmark("engineering")

## Number of frames kept for the rolling statistics window.
const WINDOW := 600
## Seconds between automatic JSON snapshots while the overlay is open.
const AUTOSNAPSHOT_SECONDS := 120.0

var enabled := false
var overlay := false

## Per-section cumulative milliseconds for the current frame, keyed by name.
var _open := {}          # name -> true, for nesting
var _start_usec := {}    # name -> Time.get_ticks_usec() at begin()
var _accum := PackedFloat64Array()   # this frame, indexed by section id
var _total := PackedFloat64Array()   # all-time, indexed by section id
var _count := PackedInt64Array()     # call count, indexed by section id
var _ids := {}           # name -> section id
var _names: Array[String] = []

## Rolling frame-time window.
var _frame_ms := PackedFloat64Array()
var _frame_head := 0
var _frame_filled := 0
var _slow_frames := 0
var _worst_frame := 0.0

var _last_snapshot := 0.0
var _label: Label
var _panel: PanelContainer
var _report := {}


func _ready() -> void:
	ensure_ready()
	_build_overlay()
	set_process(true)
	set_process_input(false)
	# Default on in debug builds, off in release: nobody wants a profiler
	# eating their frame time in a shipped game.
	enabled = OS.is_debug_build()


# --- instrumentation API ----------------------------------------------------

## Open a timing section. Safe to call when disabled: one branch.
func begin(section: String) -> void:
	if not enabled:
		return
	_open[section] = true
	_start_usec[section] = Time.get_ticks_usec()


## Close a timing section. Accumulates into this frame's slot and the totals.
func unmark(section: String) -> void:
	if not enabled or not _open.has(section):
		return
	var id: int = _id_of(section)
	var dt := float(Time.get_ticks_usec() - int(_start_usec[section])) / 1000.0
	_accum[id] += dt
	_total[id] += dt
	_count[id] += 1
	_open.erase(section)
	_start_usec.erase(section)


## Measure one sample without keeping it open. `callable` is invoked between
## begin and unmark. Used for the tick probes so callers do not have to
## remember to pair the two calls.
func measure(section: String, callable: Callable) -> Variant:
	if not enabled:
		return callable.call()
	begin(section)
	var out: Variant = callable.call()
	unmark(section)
	return out


func _id_of(section: String) -> int:
	var id: int = _ids.get(section, -1)
	if id < 0:
		id = _names.size()
		_ids[section] = id
		_names.append(section)
		_accum.append(0.0)
		_total.append(0.0)
		_count.append(0)
	return id


# --- per-frame --------------------------------------------------------------

## Idempotent setup. `add_child` from a `SceneTree._init` defers `_ready`, so
## anything constructed before the tree is live has to be able to bring itself
## up -- the same rule every other class in this project follows.
func ensure_ready() -> void:
	if _frame_ms.size() == WINDOW:
		return
	_frame_ms.resize(WINDOW)
	_frame_head = 0
	_frame_filled = 0


## Push one frame time into the rolling window. Public so a soak test or a
## harness that runs faster than real time can drive the same statistics the
## live overlay reports, instead of a private copy of them.
func push_frame(ms: float) -> void:
	ensure_ready()
	_frame_ms[_frame_head] = ms
	_frame_head = (_frame_head + 1) % WINDOW
	if _frame_filled < WINDOW:
		_frame_filled += 1
	if ms > _worst_frame:
		_worst_frame = ms
	if ms > _slow_budget_ms:
		_slow_frames += 1


func _process(delta: float) -> void:
	if not enabled:
		if _panel != null and _panel.visible:
			_panel.visible = false
		return
	var ms := delta * 1000.0
	push_frame(ms)
	if overlay:
		_refresh_overlay()
		if Time.get_ticks_msec() / 1000.0 - _last_snapshot > AUTOSNAPSHOT_SECONDS:
			_last_snapshot = Time.get_ticks_msec() / 1000.0
			write_report()


var _slow_budget_ms := 33.4  # 30 fps


## Set the frame time above which a frame counts as "slow" for the report.
func set_slow_budget(ms: float) -> void:
	_slow_budget_ms = ms


func _physics_process(_d: float) -> void:
	pass


# --- counters ---------------------------------------------------------------

## Pull the engine's own counters. Separated from the per-frame path because
## these calls are not free and the overlay only needs them a few times a
## second.
func counters() -> Dictionary:
	var c := {
		"fps": Performance.get_monitor(Performance.TIME_FPS),
		"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		"static_memory_mb": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		"object_count": Performance.get_monitor(Performance.OBJECT_COUNT),
		"object_node_count": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"orphan_node_count": Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
		"draw_calls": float(RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)),
		"objects_in_frame": float(RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)),
		"primitives_in_frame": float(RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)),
		"video_mem_mb": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		"texture_mem_mb": Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0,
		"viewport": str(get_viewport().get_visible_rect().size) \
			if get_viewport() != null else "headless",
	}
	return c


# --- statistics -------------------------------------------------------------

## Percentile of the rolling frame-time window. Sorts a copy, so it allocates;
## call it from UI, never from the tick.
func frame_percentile(p: float) -> float:
	var n := _frame_filled
	if n <= 0:
		return 0.0
	var copy := _frame_ms.slice(0, n) if n < WINDOW else _frame_ms.duplicate()
	copy.sort()
	var i := clampi(int(round(clampf(p, 0.0, 1.0) * float(n - 1))), 0, n - 1)
	return copy[i]


func mean_frame_ms() -> float:
	var n := _frame_filled
	if n <= 0:
		return 0.0
	var s := 0.0
	for i in n:
		s += _frame_ms[i]
	return s / float(n)


func reset() -> void:
	for i in _total.size():
		_total[i] = 0.0
		_count[i] = 0
	_frame_head = 0
	_frame_filled = 0
	_slow_frames = 0
	_worst_frame = 0.0
	_open.clear()
	_start_usec.clear()


func section_name(id: int) -> String:
	return _names[id] if id < _names.size() else "?"


func section_total_ms(id: int) -> float:
	return _total[id] if id < _total.size() else 0.0


func section_calls(id: int) -> int:
	return _count[id] if id < _count.size() else 0


# --- report -----------------------------------------------------------------

## A machine-readable snapshot of everything measured so far. This is the
## artefact you attach to a bug report or commit when you say "it is slow on
## target hardware".
func snapshot() -> Dictionary:
	var sections := []
	for id in _names.size():
		sections.append({
			"section": _names[id],
			"total_ms": _total[id],
			"calls": _count[id],
		})
	sections.sort_custom(func(a, b): return float(a["total_ms"]) > float(b["total_ms"]))
	return {
		"frames_sampled": _frame_filled,
		"mean_frame_ms": mean_frame_ms(),
		"p50_ms": frame_percentile(0.50),
		"p95_ms": frame_percentile(0.95),
		"p99_ms": frame_percentile(0.99),
		"worst_frame_ms": _worst_frame,
		"slow_budget_ms": _slow_budget_ms,
		"slow_frames": _slow_frames,
		"sections": sections,
		"counters": counters(),
		"renderer": RenderingServer.get_video_adapter_name(),
	}


func write_report(dir_path: String = "user://profiling") -> bool:
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(dir_path)):
		var mk := DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path(dir_path))
		if mk != OK:
			return false
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := "%s/report-%s.json" % [dir_path, stamp]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(snapshot(), "\t"))
	f.close()
	_report = {"path": path}
	return true


# --- overlay ----------------------------------------------------------------

func _build_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.name = "ProfilerLayer"
	layer.layer = 100
	add_child(layer)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_panel.position = Vector2(8, 8)
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


func toggle_overlay() -> void:
	overlay = not overlay
	if _panel != null:
		_panel.visible = overlay
	enabled = enabled or overlay


func _refresh_overlay() -> void:
	if _label == null:
		return
	var c := counters()
	var lines := PackedStringArray()
	lines.append("EMERGENT profiler   %s" % RenderingServer.get_video_adapter_name())
	lines.append("fps %5.1f  frame %5.2f ms (p95 %5.2f)" % [
		float(c["fps"]), mean_frame_ms(), frame_percentile(0.95)])
	lines.append("process %5.2f ms   physics %5.2f ms" % [
		float(c["process_ms"]), float(c["physics_ms"])])
	lines.append("draws %d  objects %d  prims %d" % [
		int(c["draw_calls"]), int(c["objects_in_frame"]), int(c["primitives_in_frame"])])
	lines.append("mem static %5.1f MB  video %5.1f MB  textures %5.1f MB" % [
		float(c["static_memory_mb"]), float(c["video_mem_mb"]), float(c["texture_mem_mb"])])
	lines.append("nodes %d  objects %d  resources %d" % [
		int(c["object_node_count"]), int(c["object_count"]), int(c["orphan_node_count"])])
	lines.append("slow frames %d / %d at %.1f ms" % [
		_slow_frames, maxi(_frame_filled, 1), _slow_budget_ms])
	var top := 0
	for id in mini(_names.size(), 6):
		if _count[id] > 0:
			lines.append("  %-14s %7.2f ms total  %d calls" % [
				_names[id], _total[id], _count[id]])
			top += 1
		if top >= 5:
			break
	_label.text = "\n".join(lines)
