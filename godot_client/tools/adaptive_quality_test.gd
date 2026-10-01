extends SceneTree
## Tests for the adaptive quality controller.
##
## The negative tests matter more than the positive ones here. A controller
## that has only been shown a healthy machine is indistinguishable from one
## that never adapts, and the failure mode that actually reaches players --
## visible oscillation -- is invisible to any test that only checks "does the
## tier go down when frames are slow".

var failures := 0


func check(cond: bool, msg: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: ", msg)


## Feed the controller a steady frame time for `seconds`, sampling at 30 Hz.
static func _hold(c: AdaptiveQuality, ms: float, seconds: float,
		start_t: float) -> Array:
	var now := start_t
	var changes := []
	while now < start_t + seconds:
		now += 1.0 / 30.0
		var got := c.observe(ms, now, 1.0 / 30.0)
		if got >= 0:
			changes.append([now, got])
	return changes


func _init() -> void:
	_test_slow_frames_degrade_after_confirmation()
	_test_a_single_slow_frame_does_nothing()
	_test_hysteresis_prevents_oscillation()
	_test_recovery_needs_sustained_headroom()
	_test_pinned_never_adapts()
	_test_unpin_resumes()
	_test_tier_never_leaves_range()
	_test_bad_measurements_are_ignored()
	_test_cooldown_rate_limits()
	print("adaptive_quality: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)


func _test_slow_frames_degrade_after_confirmation() -> void:
	var c := AdaptiveQuality.new()
	c.tier = AdaptiveQuality.TIER_HIGH
	# Comfortably above the 30 ms budget for a long time.
	var ch := _hold(c, 90.0, 10.0, 0.0)
	check(not ch.is_empty(),
		"ten seconds of 90 ms frames must degrade the tier")
	check(c.tier == AdaptiveQuality.TIER_MEDIUM,
		"after one sustained excursion the tier should be MEDIUM, got %d"
		% c.tier)


func _test_a_single_slow_frame_does_nothing() -> void:
	var c := AdaptiveQuality.new()
	c.tier = AdaptiveQuality.TIER_HIGH
	var now := 0.0
	# One 500 ms hitch, then perfectly healthy frames.
	now += 1.0 / 30.0
	var got := c.observe(500.0, now, 1.0 / 30.0)
	check(got == -1,
		"a single slow frame must not change the tier (got %d)" % got)
	for i in 60:
		now += 1.0 / 30.0
		c.observe(8.0, now, 1.0 / 30.0)
	check(c.tier == AdaptiveQuality.TIER_HIGH,
		"the tier must still be HIGH after one hitch, got %d" % c.tier)


func _test_hysteresis_prevents_oscillation() -> void:
	# The pathological case: frame time hovering right at the budget, which
	# is what a marginally overloaded machine looks like. Without hysteresis
	# the tier flips forever.
	var c := AdaptiveQuality.new()
	c.tier = AdaptiveQuality.TIER_HIGH
	var flips := 0
	var now := 0.0
	var last := c.tier
	for i in 1800:          # 60 seconds at 30 Hz
		now += 1.0 / 30.0
		# Alternates just above and just below the 33.4 ms budget.
		var ms := 34.5 if i % 2 == 0 else 32.5
		c.observe(ms, now, 1.0 / 30.0)
		if c.tier != last:
			flips += 1
			last = c.tier
	check(flips <= 1,
		"frame time oscillating around the budget must not make the tier "
		+ "oscillate; saw %d flips in 60 s" % flips)


func _test_recovery_needs_sustained_headroom() -> void:
	var c := AdaptiveQuality.new()
	c.tier = AdaptiveQuality.TIER_LOW
	# Comfortably fast for a long time: should climb back.
	_hold(c, 8.0, 30.0, 0.0)
	check(c.tier > AdaptiveQuality.TIER_LOW,
		"sustained headroom must restore quality, tier is %d" % c.tier)
	check(c.tier <= AdaptiveQuality.TIER_HIGH,
		"recovery must not exceed HIGH")


func _test_pinned_never_adapts() -> void:
	var c := AdaptiveQuality.new()
	c.pin(AdaptiveQuality.TIER_HIGH)
	var ch := _hold(c, 200.0, 30.0, 0.0)
	check(ch.is_empty(),
		"a pinned tier must not change however bad the frame time gets "
		+ "(saw %d changes)" % ch.size())
	check(c.tier == AdaptiveQuality.TIER_HIGH,
		"the pinned tier must be respected, got %d" % c.tier)


func _test_unpin_resumes() -> void:
	var c := AdaptiveQuality.new()
	c.pin(AdaptiveQuality.TIER_HIGH)
	_hold(c, 200.0, 5.0, 0.0)
	c.unpin()
	check(c.enabled and not c.user_pinned,
		"unpin must return control to the controller")
	_hold(c, 200.0, 20.0, 20.0)
	check(c.tier < AdaptiveQuality.TIER_HIGH,
		"after unpinning, sustained slowness must degrade again (tier %d)"
		% c.tier)


func _test_tier_never_leaves_range() -> void:
	var c := AdaptiveQuality.new()
	var now := 0.0
	for i in 3000:
		now += 1.0 / 30.0
		c.observe(400.0, now, 1.0 / 30.0)
		check(c.tier >= AdaptiveQuality.TIER_LOW and c.tier <= AdaptiveQuality.TIER_HIGH,
			"tier %d left the range" % c.tier)
		if c.tier < AdaptiveQuality.TIER_LOW:
			break
		if c.tier > AdaptiveQuality.TIER_HIGH:
			break
	check(c.tier == AdaptiveQuality.TIER_LOW,
		"indefinite slowness must settle at LOW, not below it (tier %d)"
		% c.tier)


func _test_bad_measurements_are_ignored() -> void:
	var c := AdaptiveQuality.new()
	c.tier = AdaptiveQuality.TIER_HIGH
	var before := c.tier
	# A division by zero upstream, a NaN, a negative clock: none of these are
	# evidence about performance and none may move the tier.
	for bad in [0.0, -1.0, NAN, INF]:
		var got := c.observe(bad, 1.0, 1.0 / 30.0)
		check(got == -1, "a %s measurement must not change the tier" % bad)
	check(c.tier == before,
		"nonsensical measurements must leave the tier alone (got %d)"
		% c.tier)


func _test_cooldown_rate_limits() -> void:
	# Even with the timer forced forward, the tier may only move every
	# COOLDOWN_SECONDS. This is what stops a long unplayable session from
	# spending its first seconds stair-stepping down through every tier.
	var c := AdaptiveQuality.new()
	c.tier = AdaptiveQuality.TIER_HIGH
	var now := 0.0
	var times := []
	for i in 400:
		now += 1.0 / 30.0
		var got := c.observe(300.0, now, 1.0 / 30.0)
		if got >= 0:
			times.append(now)
	check(times.size() >= 1, "the tier must come down at all")
	for i in range(1, times.size()):
		var gap: float = times[i] - times[i - 1]
		check(gap >= AdaptiveQuality.COOLDOWN_SECONDS - 0.05,
			"tier changes must be %0.1f s apart, saw %0.2f s"
			% [AdaptiveQuality.COOLDOWN_SECONDS, gap])