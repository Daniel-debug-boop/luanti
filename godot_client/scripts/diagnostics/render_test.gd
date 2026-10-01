class_name RenderTest
extends Node
## Automated visual validation: drive the real game from fixed camera
## positions at a fixed resolution, capture the real framebuffer, and write
## out the metadata needed to judge the result.
##
## This is a *mode*, not a second renderer. It drives the same world, the
## same materials, the same shaders, the same lighting and the same
## post-processing stack the game uses. The only things it changes are where
## the camera is and when we stop. There is deliberately no second code path
## for "just for the screenshot" -- a benchmark that renders through anything
## other than the shipping renderer measures the benchmark, not the game.
##
## The one thing this file is genuinely strict about is the hardware. A
## software rasteriser produces a perfectly plausible image of a voxel
## landscape, and that image is worthless as evidence of what the game looks
## like on a GPU. So an adapter that identifies as llvmpipe / swrast / any
## software rasteriser is a hard failure, not a warning.

## Fixed seed. The world generator, the village and the mob spawner all draw
## from it, so the same seed gives the same terrain on every machine and
## every run. This is recorded in the output; two runs that disagree are a
## bug, not a slow machine.
const SEED := 173927

## Exit codes. Distinct per failure so a CI job can tell "the build is
## broken" from "there is no GPU" without parsing a log.
const OK := 0
const ERR_USAGE := 2
const ERR_NO_GPU := 3
const ERR_SOFTWARE := 4
const ERR_RENDERER := 5
const ERR_CAPTURE := 6
const ERR_SCENE := 7

## Adapter names that mean "a CPU drew this". Matched case-insensitively as
## substrings because vendors word it differently: Mesa says "llvmpipe",
## "softpipe" and "swrast"; Apple's software path and some virtualised
## drivers say "software".
const SOFTWARE_MARKERS := [
	"llvmpipe", "softpipe", "swrast", "swiftshader", "mesa offscreen",
	"software rasterizer", "software rasteriser", "software renderer",
	"cpu rasterizer", "cpu rasteriser", "microsoft basic render",
]

## Options that are flags rather than settings: they take no value, so the
## parser must not swallow the argument after them. `--no-ui 10` means
## "no UI, capture every 10 frames", not "no UI, set the UI to 10".
const BOOLEAN_OPTIONS := [
	"--render-test", "--all-cameras", "--no-ui", "--allow-software",
	"--no-gpu-validation",
]


# --- adapter classification --------------------------------------------------

## Decide whether a graphics adapter is real hardware.
##
## Pure and static so it can be tested directly: feeding it the exact strings
## Mesa and the common virtual drivers emit is the only way to be sure the
## rejection actually happens, and a detector that has never rejected
## anything is indistinguishable from one that always passes.
##
## Returns "hardware", "software" or "unknown". "unknown" is treated as a
## failure by the caller -- an adapter we cannot positively identify as
## hardware is not evidence of hardware.
static func classify_adapter(renderer: String, vendor: String) -> String:
	var haystack := (renderer + " " + vendor).to_lower()
	for marker in SOFTWARE_MARKERS:
		if haystack.contains(String(marker).to_lower()):
			return "software"
	# Positive confirmation. Anything named after a real vendor, or a
	# recognisable device, is hardware; we do not guess beyond that.
	for good in ["nvidia", "geforce", "quadro", "amd", "radeon", "intel",
			"apple m", "mali", "adreno", "powervr", "vulkan", "metal",
			"arc ", "iris", "etnaviv"]:
		if haystack.contains(good):
			return "hardware"
	return "unknown"


## Everything we can learn about the graphics device, in one Dictionary.
## Only values the engine actually reported are included -- there is no
## default vendor string and no made-up VRAM figure anywhere in this file.
static func probe_adapter() -> Dictionary:
	var out := {}
	out["display_server"] = DisplayServer.get_name()
	out["video_driver"] = ProjectSettings.get_setting(
		"rendering/renderer/rendering_method", "unknown")
	out["rendering_driver"] = ProjectSettings.get_setting(
		"rendering/renderer/rendering_method.mobile", "unknown")
	# The authoritative source is RenderingServer, not OS. On this project
	# OS.get_video_adapter_driver_info() comes back as an EMPTY array even
	# when the adapter is perfectly queryable, while
	# RenderingServer.get_video_adapter_name() returns the real device string
	# ("llvmpipe (LLVM 15.0.7, 256 bits)"). Reading the wrong one first is how
	# a software rasteriser ends up classified "unknown" and slips past a
	# check that would otherwise have caught it.
	out["name"] = str(RenderingServer.get_video_adapter_name())
	out["vendor"] = str(RenderingServer.get_video_adapter_vendor())
	out["api_version"] = str(RenderingServer.get_video_adapter_api_version())
	# OS and DisplayServer are kept as supplementary detail only, and are
	# handled as Variant because the two disagree on shape.
	var raw: Variant = null
	if OS.has_method("get_video_adapter_driver_info"):
		raw = OS.call("get_video_adapter_driver_info")
	if raw is Dictionary:
		var d: Dictionary = raw
		if str(out["vendor"]).is_empty():
			out["vendor"] = str(d.get("vendor", ""))
		if str(out["name"]).is_empty():
			out["name"] = str(d.get("name", ""))
		if str(d.get("version", "")) != "":
			out["driver_version"] = str(d.get("version", ""))
	elif raw is PackedStringArray:
		var arr: PackedStringArray = raw
		if arr.size() > 0 and str(out["driver_version"]).is_empty():
			out["driver_version"] = str(arr[0])
		if arr.size() > 2 and str(out["name"]).is_empty():
			out["name"] = str(arr[2])
	# A RenderingDevice only exists on the Vulkan/Metal/D3D backends. Its
	# absence is informative, not an error: the OpenGL3 backend has none.
	var rd := RenderingServer.get_rendering_device()
	if rd != null:
		out["rendering_device"] = rd.get_device_name()
	else:
		out["rendering_device"] = "none (compatibility renderer)"
	# The single string that decides software vs hardware.
	var renderer := str(out.get("name", ""))
	if renderer == "" and rd != null:
		renderer = str(out.get("rendering_device", ""))
	var vendor := str(out.get("vendor", ""))
	out["classification"] = classify_adapter(renderer, vendor)
	out["hardware_acceleration"] = out["classification"] == "hardware"
	return out


# --- argument parsing -------------------------------------------------------

## Parse `--render-test` and friends. Returns a config Dictionary, or
## {"error": String} with a message meant for a human.
##
## Unknown options are an error rather than a shrug: a typo in a flag name
## would otherwise silently produce a run with the wrong settings, which is
## worse than refusing to start.
static func parse_args(argv: PackedStringArray) -> Dictionary:
	var cfg := {
		"enabled": false,
		"scene": "benchmark",
		"width": 1920,
		"height": 1080,
		"frames": 120,
		"warmup_frames": 30,
		"output": "render-test-results",
		"camera": "front",
		"all_cameras": false,
		"ui": true,
		"capture_every": 0,
		"benchmark": true,
		"allow_software": false,
		"gpu_validation": true,
		"seed": SEED,
	}
	# Only this mode's flags are validated. The game is launched with engine
	# flags and unrelated settings too, and a parser that claimed those as
	# unknown options would refuse to start on a perfectly good command
	# line. So: is this our mode at all?
	if not argv.has("--render-test"):
		return {"error": ""}
	var i := 0
	var seen_flag := false
	while i < argv.size():
		var a := argv[i]
		if not a.begins_with("--"):
			i += 1
			continue
		if a == "--render-test":
			cfg["enabled"] = true
			seen_flag = true
			i += 1
			continue
		# Boolean flags take no value; they are set by being present.
		if BOOLEAN_OPTIONS.has(a):
			match a:
				"--all-cameras": cfg["all_cameras"] = true
				"--no-ui": cfg["ui"] = false
				"--allow-software": cfg["allow_software"] = true
				"--no-gpu-validation": cfg["gpu_validation"] = false
			i += 1
			continue
		# Every other option takes one value.
		if i + 1 >= argv.size():
			return {"error": "option %s needs a value" % a}
		var v := argv[i + 1]
		match a:
			"--scene": cfg["scene"] = v
			"--output": cfg["output"] = v
			"--camera": cfg["camera"] = v
			"--resolution":
				var parts := v.to_lower().split("x")
				if parts.size() != 2 or not parts[0].is_valid_int() \
						or not parts[1].is_valid_int():
					return {"error": "--resolution wants WIDTHxHEIGHT, got '%s'" % v}
				var w := int(parts[0])
				var h := int(parts[1])
				if w < 16 or h < 16 or w > 16384 or h > 16384:
					return {"error": "--resolution out of range: %s" % v}
				cfg["width"] = w
				cfg["height"] = h
			"--frames":
				if not v.is_valid_int() or int(v) < 1:
					return {"error": "--frames wants a positive integer"}
				cfg["frames"] = int(v)
			"--warmup-frames":
				if not v.is_valid_int() or int(v) < 0:
					return {"error": "--warmup-frames wants a non-negative integer"}
				cfg["warmup_frames"] = int(v)
			"--capture-every":
				if not v.is_valid_int() or int(v) < 0:
					return {"error": "--capture-every wants a non-negative integer"}
				cfg["capture_every"] = int(v)
			"--all-cameras": cfg["all_cameras"] = true
			"--no-ui": cfg["ui"] = false
			"--allow-software":
				# Exists so the pipeline itself can be exercised on a machine
				# with no GPU. It is named "allow", it is documented, and the
				# output it writes still says SOFTWARE everywhere.
				cfg["allow_software"] = true
			"--no-gpu-validation": cfg["gpu_validation"] = false
			_:
				return {"error": "unknown option %s" % a}
		i += 2
	if not seen_flag:
		return {"error": ""}   # not our mode; the caller carries on
	return cfg


# --- camera presets ---------------------------------------------------------

## Fixed viewpoints, as {name: {offset, look_at, label}}. They are expressed
## relative to the spawn point rather than as absolute coordinates so they
## frame whatever the generator produced instead of a landscape that only
## exists for one seed.
##
## Each one is chosen to point at world content from outside it: a preset
## whose camera ends up inside stone produces a black rectangle that looks
## like a renderer bug and is not one.
const CAMERA_PRESETS := {
	"front": {
		"offset": Vector3(0.0, 14.0, 34.0),
		"label": "front",
	},
	"side": {
		"offset": Vector3(38.0, 16.0, 6.0),
		"label": "side",
	},
	"elevated": {
		"offset": Vector3(18.0, 46.0, 30.0),
		"label": "elevated",
	},
	"environment": {
		"offset": Vector3(-26.0, 8.0, 26.0),
		"label": "environment",
	},
}

## The preset names in a stable order, so a run produces the same files in
## the same order every time.
static func preset_names() -> PackedStringArray:
	return PackedStringArray(["front", "side", "elevated", "environment"])


static func cameras_to_shoot(cfg: Dictionary) -> PackedStringArray:
	if bool(cfg.get("all_cameras", false)):
		return preset_names()
	var one := str(cfg.get("camera", "front"))
	if not CAMERA_PRESETS.has(one):
		return PackedStringArray()
	return PackedStringArray([one])


# --- the run ----------------------------------------------------------------

## Set by the composition root before start(). Held as plain Nodes rather than
## concrete types so this file names no other module and therefore cannot
## violate the layering rules it is supposed to help verify.
var world: Node = null
var player: Node = null
var hud: Node = null
var debug_overlay: Node = null

var cfg := {}
var adapter := {}
var _camera: Camera3D = null
var _out_dir := ""
var _captures := PackedStringArray()
var _frame_times := PackedFloat64Array()
var _frame_count := 0
var _warmup_left := 0
var _log := PackedStringArray()
var _finished := false


## Kick the run off. Returns the exit code the process should end with.
##
## Everything that can fail before the first frame -- bad arguments, no
## hardware GPU, a renderer that will not start -- fails here, so the caller
## gets a non-zero exit code and a reason instead of an empty folder of
## black rectangles.
func start(config: Dictionary) -> int:
	cfg = config
	adapter = probe_adapter()
	# The output directory is created FIRST, before anything that can fail.
	# A run that is refused for want of a GPU is exactly the run whose reason
	# someone needs to read afterwards, so the refusal has to land on disk
	# too -- not just in the console scrollback nobody kept.
	_out_dir = str(cfg.get("output", "render-test-results"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(
		_resolve(_out_dir)))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(
		_resolve(_out_dir + "/captures")))
	note("adapter: vendor=%s name=%s class=%s"
		% [adapter.get("vendor", "?"), adapter.get("name", "?"),
			adapter.get("classification", "?")])

	if bool(cfg.get("gpu_validation", true)):
		var c := str(adapter.get("classification", "unknown"))
		if c == "software" and not bool(cfg.get("allow_software", false)):
			return _fail(ERR_SOFTWARE,
				"SOFTWARE_RENDERING_DETECTED: %s is a CPU rasteriser."
					% adapter.get("name", "the adapter")
					+ " A software render is not a valid visual validation.")
		if c == "unknown":
			return _fail(ERR_NO_GPU,
				"GPU_NOT_FOUND: could not identify '%s' (%s) as hardware."
					% [adapter.get("name", "?"), adapter.get("vendor", "?")])
	if DisplayServer.get_name() == "headless":
		note("display server is 'headless': rendering is offscreen, which is "
			+ "fine, but nothing will be shown on a monitor.")

	_out_dir = str(cfg.get("output", "render-test-results"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(
		_resolve(_out_dir)))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(
		_resolve(_out_dir + "/captures")))

	_warmup_left = int(cfg.get("warmup_frames", 30))
	_camera = Camera3D.new()
	_camera.name = "RenderTestCamera"
	_camera.fov = 70.0
	_camera.far = 800.0
	_camera.current = true
	add_child(_camera)
	_apply_resolution()
	_apply_ui(bool(cfg.get("ui", true)))
	_run()
	return OK


func _apply_resolution() -> void:
	var w := int(cfg.get("width", 1920))
	var h := int(cfg.get("height", 1080))
	var win := get_window()
	if win != null:
		win.size = Vector2i(w, h)
	# A SubViewport of the same size is what actually gets rendered from when
	# there is no window, so set it too rather than assuming the window path.
	var vp := get_viewport()
	if vp != null and vp.size != Vector2i(w, h):
		vp.size = Vector2i(w, h)


## The clean/UI split. The player-facing HUD is a CanvasLayer; developer
## diagnostics are a separate one, and the two are switched independently so
## a clean shot is genuinely clean.
func _apply_ui(show_ui: bool) -> void:
	# Set through `set()` rather than a typed cast: the HUD is a CanvasLayer,
	# which is a Node and NOT a CanvasItem, so `(hud as CanvasItem)` yields
	# null and the assignment silently does nothing -- a --no-ui capture that
	# still contains the HUD looks like the flag was ignored.
	if hud != null and is_instance_valid(hud):
		hud.set("visible", show_ui)
	if debug_overlay != null and is_instance_valid(debug_overlay):
		debug_overlay.set("visible", false)


func _run() -> void:
	await _settle()
	var shots := cameras_to_shoot(cfg)
	if shots.is_empty():
		_fail(ERR_USAGE, "MISSING_SCENE: no camera preset matched '%s'"
			% str(cfg.get("camera", "")))
		return
	# Warm-up frames are rendered and thrown away: the first frames after a
	# world is generated are spent on shader compilation and first-use
	# pipeline creation, and timing those would say nothing about the frame
	# cost.
	while _warmup_left > 0:
		_warmup_left -= 1
		await _frame()
	for shot in shots:
		await _shoot(shot)
	if bool(cfg.get("benchmark", true)):
		_write_performance()
	_write_metadata()
	_finish(OK)


## Place the camera for one preset, framed on the world rather than on a
## coordinate that only exists for one seed.
func _shoot(shot: String) -> void:
	var preset: Dictionary = CAMERA_PRESETS[shot]
	var focus := _focus_point()
	_camera.global_position = focus + Vector3(preset["offset"])
	# Look at the terrain, a little above it, so the horizon sits in frame
	# rather than the camera staring at its own feet.
	_camera.look_at(focus + Vector3(0.0, 4.0, 0.0), Vector3.UP)

	var frames := int(cfg.get("frames", 120))
	var every := int(cfg.get("capture_every", 0))
	var t0 := Time.get_ticks_usec()
	for f in frames:
		_frame_times.append(float(Time.get_ticks_usec() - t0) / 1000.0)
		t0 = Time.get_ticks_usec()
		_frame_count += 1
		await _frame()
		if every > 0 and (f + 1) % every == 0 and f + 1 < frames:
			await _capture("%s_f%03d" % [shot, f + 1])
	var path := await _capture(shot)
	if path != "":
		_captures.append(path)


## One rendered frame, with the draw actually flushed. `frame_post_draw` is
## the only signal that says the pixels exist; returning from `_process`
## would hand us a framebuffer the GPU has not finished with.
func _frame() -> void:
	await RenderingServer.frame_post_draw


## Let the world stream in before anything is measured or captured.
func _settle() -> void:
	if world != null and is_instance_valid(world) \
			and world.has_method("ensure_region"):
		world.call("ensure_region", Vector3i(0, 0, 0), 4)
	await _frame()
	await _frame()


## A point guaranteed to be above the terrain, derived from the world rather
## than hard-coded, so the presets frame real content on any seed.
func _focus_point() -> Vector3:
	var base := Vector3(8.5, 0.0, 8.5)
	if world == null or not is_instance_valid(world) \
			or not world.has_method("solid_at"):
		return base + Vector3(0.0, 24.0, 0.0)
	for y in range(60, 1, -1):
		if bool(world.call("solid_at", Vector3i(8, y, 8))):
			return Vector3(8.5, float(y) + 1.0, 8.5)
	return base + Vector3(0.0, 24.0, 0.0)


## Grab the real framebuffer and write it as a PNG. Returns the path written,
## or "" on failure. The width and height are verified against what was asked
## for, because a capture that quietly comes back at a different size is
## exactly the kind of thing that makes a benchmark worthless.
func _capture(label: String) -> String:
	var vp := get_viewport()
	if vp == null:
		return ""
	await RenderingServer.frame_post_draw
	var tex := vp.get_texture()
	if tex == null:
		return ""
	var img := tex.get_image()
	if img == null:
		return ""
	var want := Vector2i(int(cfg.get("width", 1920)), int(cfg.get("height", 1080)))
	if img.get_size() != want:
		note("WARNING: %s captured at %s, expected %s"
			% [label, img.get_size(), want])
	var rel := "%s/captures/%s.png" % [_out_dir, label]
	var abs := ProjectSettings.globalize_path(_resolve(rel))
	DirAccess.make_dir_recursive_absolute(abs.get_base_dir())
	var err := img.save_png(abs)
	if err != OK:
		note("SCREENSHOT_CAPTURE_FAILURE: %s (error %d)" % [label, err])
		return ""
	return rel


## Turn a user-supplied path into something FileAccess can open. Absolute OS
## paths are honoured as written -- a benchmark run from a shell expects
## `--output /tmp/x` to mean /tmp/x, not res://tmp/x.
func _resolve(p: String) -> String:
	if p.begins_with("res://") or p.begins_with("user://"):
		return p
	if p.begins_with("/"):
		return p
	return "res://" + p.lstrip("/")


# --- output -----------------------------------------------------------------

func _write_metadata() -> void:
	var m := {
		"tool": "LuantiVoxel render-test",
		"resolution": "%dx%d" % [int(cfg.get("width", 1920)),
			int(cfg.get("height", 1080))],
		"seed": int(cfg.get("seed", SEED)),
		"scene": str(cfg.get("scene", "benchmark")),
		"ui_included": bool(cfg.get("ui", true)),
		"frames": _frame_count,
		"warmup_frames": int(cfg.get("warmup_frames", 30)),
		"captures": Array(_captures),
		# Flattened adapter fields so a consumer does not have to know the
		# shape of the nested probe.
		"gpu_vendor": str(adapter.get("vendor", "")),
		"gpu_name": str(adapter.get("name", "")),
		"gpu_api_version": str(adapter.get("api_version", "")),
		"gpu_driver_version": str(adapter.get("driver_version", "")),
		"rendering_device": str(adapter.get("rendering_device", "")),
		"graphics_api": str(adapter.get("video_driver", "")),
		"display_server": str(adapter.get("display_server", "")),
		"classification": str(adapter.get("classification", "unknown")),
		"hardware_acceleration": bool(adapter.get("hardware_acceleration", false)),
	}
	_write(_out_dir + "/metadata.json", JSON.stringify(m, "  ") + "\n")
	_write(_out_dir + "/gpu-info.txt", _gpu_report())
	_write(_out_dir + "/render-log.txt", "\n".join(_log) + "\n")


func _gpu_report() -> String:
	var lines := PackedStringArray()
	lines.append("HARDWARE GPU: %s" % ("PASS" if bool(
		adapter.get("hardware_acceleration", false)) else "FAIL"))
	for k in ["classification", "vendor", "name", "api_version",
			"driver_version", "rendering_device", "video_driver",
			"display_server"]:
		lines.append("%-18s %s" % [k, str(adapter.get(k, ""))])
	return "\n".join(lines) + "\n"


func _write_performance() -> void:
	var p := {
		"frames_measured": _frame_times.size(),
		"warmup_frames": int(cfg.get("warmup_frames", 30)),
		"resolution": "%dx%d" % [int(cfg.get("width", 1920)),
			int(cfg.get("height", 1080))],
	}
	if _frame_times.is_empty():
		p["average_frame_ms"] = null
		p["min_frame_ms"] = null
		p["max_frame_ms"] = null
		p["average_fps"] = null
		p["gpu_frame_ms"] = null
		p["note"] = "no frames were measured"
	else:
		var total := 0.0
		var lo := INF
		var hi := -INF
		for t in _frame_times:
			total += t
			lo = minf(lo, t)
			hi = maxf(hi, t)
		var avg := total / float(_frame_times.size())
		p["average_frame_ms"] = avg
		p["min_frame_ms"] = lo
		p["max_frame_ms"] = hi
		p["average_fps"] = 1000.0 / avg if avg > 0.0 else null
		# Godot exposes no GPU-side timer without vendor timestamp queries,
		# which are not enabled here. "unavailable" is the honest value; a
		# number copied from the CPU time would be a fabrication.
		p["gpu_frame_ms"] = null
	_write(_out_dir + "/performance.json", JSON.stringify(p, "  ") + "\n")

	var t := PackedStringArray()
	t.append("resolution:      %s" % str(p["resolution"]))
	t.append("frames measured: %d (after %d warm-up)"
		% [int(p["frames_measured"]), int(p["warmup_frames"])])
	if p["average_frame_ms"] == null:
		t.append("average frame:   unavailable")
		t.append("average fps:     unavailable")
	else:
		t.append("average frame:   %.2f ms" % float(p["average_frame_ms"]))
		t.append("min frame:       %.2f ms" % float(p["min_frame_ms"]))
		t.append("max frame:       %.2f ms" % float(p["max_frame_ms"]))
		t.append("average fps:     %.2f" % float(p["average_fps"]))
	t.append("gpu frame time:  unavailable (no vendor timestamp query)")
	t.append("")
	t.append("These are CPU-side frame times. They include everything the")
	t.append("renderer did, and they say nothing about how long the GPU took.")
	_write(_out_dir + "/performance.txt", "\n".join(t) + "\n")


func _write(rel: String, text: String) -> void:
	var abs := ProjectSettings.globalize_path(_resolve(rel))
	DirAccess.make_dir_recursive_absolute(abs.get_base_dir())
	var f := FileAccess.open(abs, FileAccess.WRITE)
	if f == null:
		note("could not write %s (error %d)" % [rel, FileAccess.get_open_error()])
		return
	f.store_string(text)
	f.close()


func note(line: String) -> void:
	_log.append(line)
	print("[render-test] ", line)


## Record the failure in the output as well as on the console, so a run that
## produced no screenshots still explains itself.
func _fail(code: int, message: String) -> int:
	note(message)
	_write_metadata()
	_write(_out_dir + "/FAILURE.txt",
		"%s\nexit code: %d\n\n%s\n" % [message, code, "\n".join(_log)])
	return code


func _finish(code: int) -> void:
	if _finished:
		return
	_finished = true
	note("done: %d frame(s), %d capture(s), exit %d"
		% [_frame_count, _captures.size(), code])
	if _camera != null and is_instance_valid(_camera):
		_camera.queue_free()
	get_tree().quit(code)

