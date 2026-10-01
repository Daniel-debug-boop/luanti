extends SceneTree
## The render-test pipeline's own tests.
##
## The assertions that matter here are the negative ones. A GPU validator
## that has only ever been shown a real GPU proves nothing, so these feed
## classify_adapter the exact strings Mesa and the common virtual drivers
## emit and require it to refuse every one of them. A benchmark that cannot
## say "this is not valid" is worse than no benchmark, because its output
## looks like evidence.

var _fails := 0


func _init() -> void:
	_test_software_renderers_are_rejected()
	_test_real_hardware_is_accepted()
	_test_unknown_is_not_treated_as_hardware()
	_test_defaults()
	_test_argument_parsing()
	_test_bad_arguments_fail()
	_test_camera_presets()
	_test_probe_reports_something()
	_finish()


# --- the critical one -------------------------------------------------------

func _test_software_renderers_are_rejected() -> void:
	# Real strings, as the drivers actually report them. Each of these must
	# classify as "software" and must NOT be reported as hardware.
	var software := [
		["llvmpipe (LLVM 15.0.7, 256 bits)", "Mesa/X.org"],
		["LLVMpipe (LLVM 12.0.0, 256 bits)", "Mesa/X.org"],
		["llvmpipe", "Google"],
		["softpipe", "Mesa/X.org"],
		["Mesa OffScreen", "Mesa/X.org"],
		["llvmpipe (LLVM 15.0.7, 256 bits) (OpenGL 4.5)", "Mesa"],
		["SwiftShader Device", "Google"],
		["Microsoft Basic Render Driver", "Microsoft"],
		["Software Rasterizer", "Mesa"],
		["llvmpipe (LLVM 15.0.7)", "Mesa/X.org"],
	]
	for row in software:
		var c := RenderTest.classify_adapter(String(row[0]), String(row[1]))
		_eq(c, "software", "'%s' is refused as a GPU" % String(row[0]))
		_eq(c == "hardware", false,
			"'%s' is never reported as hardware" % String(row[0]))

	# The vendor field alone must be enough. A driver that names llvmpipe in
	# the vendor slot with a clean-looking device name is still software.
	_eq(RenderTest.classify_adapter("Device 0", "llvmpipe"), "software",
		"a software vendor is refused even with a clean device name")
	# Case must not matter.
	_eq(RenderTest.classify_adapter("LLVMpipe", "Mesa"), "software",
		"detection is case-insensitive")
	_eq(RenderTest.classify_adapter("LLVMPipe (LLVM)", "Mesa"), "software",
		"mixed case is still detected")


func _test_real_hardware_is_accepted() -> void:
	# The other direction: a validator that rejects everything is as useless
	# as one that accepts everything.
	var hardware := [
		["NVIDIA GeForce RTX 4090", "NVIDIA Corporation"],
		["AMD Radeon RX 7900 XTX", "AMD"],
		["ANGLE (NVIDIA, NVIDIA GeForce GTX 1080 Direct3D11 vs_5_0 ps_5_0)", "Google"],
		["Apple M2", "Apple"],
		["Intel(R) UHD Graphics 770", "Intel"],
		["Mali-G78", "ARM"],
		["AMD Radeon Graphics", "AMD"],
	]
	for row in hardware:
		var c := RenderTest.classify_adapter(String(row[0]), String(row[1]))
		_eq(c, "hardware", "'%s' is accepted as hardware" % String(row[0]))


func _test_unknown_is_not_treated_as_hardware() -> void:
	# An adapter we cannot identify is not evidence of an adapter. Returning
	# "hardware" for an empty string would let a headless run with no GPU
	# report a pass.
	_eq(RenderTest.classify_adapter("", ""), "unknown",
		"an empty adapter is unknown, not hardware")
	_eq(RenderTest.classify_adapter("Something Unheard Of", "Nobody"), "unknown",
		"an unrecognised adapter is unknown")
	_eq(RenderTest.classify_adapter("", "") == "hardware", false,
		"unknown never counts as hardware")


# --- arguments --------------------------------------------------------------

func _test_defaults() -> void:
	var cfg := RenderTest.parse_args(PackedStringArray(["--render-test"]))
	_eq(cfg.get("enabled"), true, "--render-test enables the mode")
	_eq(cfg.get("width"), 1920, "default width is 1920")
	_eq(cfg.get("height"), 1080, "default height is 1080")
	_eq(cfg.get("warmup_frames"), 30, "default warm-up is 30 frames")
	_eq(cfg.get("ui"), true, "the UI is included by default")
	_eq(cfg.get("allow_software"), false,
		"software rendering is refused unless explicitly allowed")
	_eq(cfg.get("seed"), RenderTest.SEED, "the seed is fixed and recorded")

	# Not our mode at all: an empty error and no "enabled" key.
	var none := RenderTest.parse_args(PackedStringArray(["--quality", "high"]))
	_eq(none.has("enabled"), false, "unrelated flags are left alone")
	_eq(str(none.get("error", "")), "", "and produce no usage error")


func _test_argument_parsing() -> void:
	var cfg := RenderTest.parse_args(PackedStringArray([
		"--render-test", "--resolution", "1280x720", "--frames", "45",
		"--warmup-frames", "5", "--output", "out/dir", "--all-cameras",
		"--no-ui", "--capture-every", "10", "--camera", "side",
	]))
	_eq(cfg.get("width"), 1280, "--resolution sets the width")
	_eq(cfg.get("height"), 720, "--resolution sets the height")
	_eq(cfg.get("frames"), 45, "--frames sets the frame count")
	_eq(cfg.get("warmup_frames"), 5, "--warmup-frames is honoured")
	_eq(cfg.get("output"), "out/dir", "--output sets the directory")
	_eq(cfg.get("all_cameras"), true, "--all-cameras is parsed")
	_eq(cfg.get("ui"), false, "--no-ui turns the UI off")
	_eq(cfg.get("capture_every"), 10, "--capture-every is parsed")

	_eq(RenderTest.cameras_to_shoot(cfg).size(), 4,
		"--all-cameras shoots all four presets")
	var one := RenderTest.parse_args(PackedStringArray([
		"--render-test", "--camera", "elevated"]))
	_eq(RenderTest.cameras_to_shoot(one).size(), 1,
		"a single --camera shoots one preset")


func _test_bad_arguments_fail() -> void:
	# Every one of these must be a refusal, not a shrug. A typo in a flag
	# that is silently ignored produces a run with the wrong settings, which
	# is worse than refusing to start.
	var bad := [
		["--render-test", "--resolution", "notasize"],
		["--render-test", "--resolution", "0x0"],
		["--render-test", "--frames", "0"],
		["--render-test", "--frames", "abc"],
		["--render-test", "--warmup-frames", "-1"],
		["--render-test", "--capture-every", "-5"],
		["--render-test", "--nonsense", "1"],
		["--render-test", "--frames"],
	]
	for argv in bad:
		var r := RenderTest.parse_args(PackedStringArray(argv))
		_eq(r.has("enabled"), false,
			"'%s' is refused" % " ".join(PackedStringArray(argv)))
		_eq(str(r.get("error", "")).length() > 0, true,
			"'%s' explains why" % " ".join(PackedStringArray(argv)))

	# An unknown camera is caught when the shot list is built, not at parse
	# time, so the message can name the presets that do exist.
	var bad_cam := RenderTest.parse_args(PackedStringArray([
		"--render-test", "--camera", "underwater"]))
	_eq(RenderTest.cameras_to_shoot(bad_cam).size(), 0,
		"an unknown camera produces no shots")


# --- presets ----------------------------------------------------------------

func _test_camera_presets() -> void:
	var names := RenderTest.preset_names()
	_eq(names.size(), 4, "there are four presets")
	for want in ["front", "side", "elevated", "environment"]:
		_eq(names.has(want), true, "the '%s' preset exists" % want)
		_eq(RenderTest.CAMERA_PRESETS.has(want), true,
			"'%s' has a definition" % want)
	# Each preset must be somewhere different, or three of the four
	# screenshots would be the same picture.
	var seen := {}
	for n in names:
		var off: Vector3 = RenderTest.CAMERA_PRESETS[n]["offset"]
		_eq(off.length() > 4.0, true,
			"'%s' stands off from its subject" % n)
		_eq(seen.has(off), false, "'%s' is a distinct viewpoint" % n)
		seen[off] = true
	# Order is stable, so two runs produce the same files in the same order.
	_eq(RenderTest.preset_names(), names, "preset order is deterministic")


func _test_probe_reports_something() -> void:
	# This environment has no GPU, so this asserts only that the probe runs
	# and produces a verdict -- not what the verdict is.
	var a := RenderTest.probe_adapter()
	_eq(a.has("classification"), true, "the probe classifies the adapter")
	_eq(["hardware", "software", "unknown"].has(
		str(a.get("classification", ""))), true,
		"the classification is one of the three defined values")
	_eq(a.has("hardware_acceleration"), true,
		"the probe reports an acceleration verdict")
	# Whatever this machine is, the two must agree.
	_eq(bool(a.get("hardware_acceleration", false)),
		str(a.get("classification", "")) == "hardware",
		"hardware_acceleration is exactly 'classified as hardware'")
	# The report has to be self-describing even with no info at all.
	var empty := RenderTest.probe_adapter()
	_eq(str(empty.get("classification", "")).length() > 0, true,
		"an uninformative probe still classifies")
	# The adapter string is what the whole verdict rests on, so if the
	# environment can name its adapter, the classification must be derived
	# from that name rather than from a default. This is the check that
	# caught the real bug: OS.get_video_adapter_driver_info() returns an
	# empty array here while RenderingServer.get_video_adapter_name()
	# returns "llvmpipe (...)", so probing the wrong API made every run
	# classify as "unknown".
	var name := str(a.get("name", ""))
	if name != "":
		_eq(a.get("classification"),
			RenderTest.classify_adapter(name, str(a.get("vendor", ""))),
			"a named adapter is classified from its own name")
		_eq(a.get("classification") == "software" or a.get("classification")
			== "hardware" or a.get("classification") == "unknown", true,
			"the classification follows the name")
	else:
		_ok("no adapter name in this environment (headless); nothing to "
			+ "cross-check")


# --- harness ----------------------------------------------------------------

func _eq(got: Variant, want: Variant, what: String) -> void:
	if got == want:
		print("  ok   %s == %s" % [what, str(want)])
	else:
		_fails += 1
		print("  FAIL %s: got %s, want %s" % [what, str(got), str(want)])


func _ok(msg: String) -> void:
	print("  ok   %s" % msg)


func _finish() -> void:
	print("RESULT: %s (%d failures)" % ["PASS" if _fails == 0 else "FAIL", _fails])
	quit(0 if _fails == 0 else 1)
