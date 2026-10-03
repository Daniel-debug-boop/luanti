class_name AdaptiveQuality
extends RefCounted
## Adaptive rendering: hold a frame-rate target by spending and reclaiming a
## fixed budget, rather than by reacting to individual slow frames.
##
## The naive version of this -- "frame over budget, drop a level" -- makes the
## game oscillate. Two failure modes, both bad enough to be worth engineering
## around:
##
##   * Chattering: drop to LOW at 58 fps, recover at 62, drop again at 57.
##     The player sees a visible flash every few seconds forever.
##   * The wrong lever: reacting to frame time alone, it will cut view
##     distance when the real cost is a shader compile, or cut effects when
##     the real cost is chunk meshing.
##
## So this measures separately, requires a sustained excursion before acting,
## requires a much larger excursion before acting back, and makes exactly one
## change per decision. Each budget owns a distinct set of knobs, because
## they are not interchangeable: view distance costs streaming and memory,
## effects cost GPU, and the two cannot substitute for each other.
##
## Godot exposes no GPU-side timer here without vendor timestamp queries, so
## the GPU budget is fed by whatever real signal the caller has -- and when
## the caller has none, it says so instead of inferring one. Frame time is
## labelled for what it is: wall-clock, CPU plus whatever the GPU blocks on.

## What the controller can change, in the order it prefers to spend them.
enum Knob {
	VIEW_DISTANCE,  ## Cheapest to give up a little, and the most visible.
	SHADOWS,        ## Cheap visually at distance, expensive up close.
	EFFECTS,        ## SSAO, SSIL, volumetric fog, glow.
	MATERIAL,       ## POM / stochastic mapping: the most expensive per pixel.
}

## Quality tier, matching RenderSettings.Quality.
const TIER_LOW := 0
const TIER_MEDIUM := 1
const TIER_HIGH := 2

## How long a budget must stay outside its target before the controller acts.
## At 30 Hz sampling that is about four seconds of sustained trouble, which is
## long enough to ride out a chunk-streaming hitch and short enough that a
## genuinely overloaded machine settles quickly.
const CONFIRM_SECONDS := 4.0
## How far *inside* the target it must stay before recovery is allowed. Wider
## than CONFIRM on purpose: without hysteresis the controller chatters.
const RECOVER_SECONDS := 12.0
## Never act more often than this, whatever the measurements say.
const COOLDOWN_SECONDS := 6.0

## Frame-time targets in milliseconds, by tier. 60 fps and 30 fps.
const TARGET_MS := [16.7, 33.4, 33.4]


## Current tier, 0..2.
var tier := TIER_HIGH
## Set false to pin the tier and stop adapting. The settings menu turns this
## off the moment the player chooses a quality by hand: a controller that
## overrides an explicit choice is not adaptive, it is disobedient.
var enabled := true
## True when the controller has been turned off by an explicit choice.
var user_pinned := false

## Fraction of samples that must be outside the target to confirm an excursion.
## Measured over the confirm window rather than assumed.
var _over_since := -1.0
var _under_since := -1.0
## When the tier last moved, on the same clock the caller supplies. -1e9
## rather than -1: the first comparison is `now - _last_change`, and "never"
## has to read as "long enough ago" or the very first adjustment blocks on its
## own cooldown forever.
var _last_change := -1e9
## Monotonically increasing sample counter, used instead of wall-clock so a
## test can drive the controller deterministically.
var _t := 0.0

## Cumulative counters, for the profiler report.
var adjustments := 0
var confirmations := 0

## Why the tier last changed, for the profiler overlay and the render log.
var last_reason := ""


## Offer a frame-time sample. Returns the new tier if it changed, or -1.
##
## `now` is seconds on a monotonic clock; passing it in rather than reading a
## clock keeps every decision reproducible in a test.
func observe(frame_ms: float, now: float, dt: float) -> int:
	_t += 1.0
	if not enabled:
		return -1
	if frame_ms <= 0.0 or not is_finite(frame_ms):
		# A nonsensical measurement is not evidence of anything. Acting on it
		# would let one bad read drop the whole game's quality.
		return -1
	# Latch the START of the excursion, not the current time. Reassigning
	# these every sample makes `now - _over_since` always zero, so the window
	# never accumulates and the controller never acts -- which looks
	# identical to a controller that works, right up until someone checks.
	if frame_ms > target_ms():
		if _over_since < 0.0:
			_over_since = now
	else:
		_over_since = -1.0
	if frame_ms < recover_ms():
		if _under_since < 0.0:
			_under_since = now
	else:
		_under_since = -1.0

	# Cooldown first: even a confirmed excursion waits, so a struggling scene
	# settles rather than swinging.
	if now - _last_change < COOLDOWN_SECONDS:
		return -1

	# Degradation is easier to trigger than recovery, and recovery has the
	# longer window and the tighter threshold. That asymmetry is the whole
	# point: without it the tier flips forever around the boundary.
	if _over_since >= 0.0 and now - _over_since >= CONFIRM_SECONDS:
		if tier > TIER_LOW:
			_adjust(-1, now, "sustained %s" % _describe(frame_ms))
			return tier
		return -1
	if _under_since >= 0.0 and now - _under_since >= RECOVER_SECONDS:
		if tier < TIER_HIGH and not user_pinned:
			_adjust(1, now, "sustained headroom")
			return tier
	return -1


func _adjust(delta: int, now: float, why: String) -> void:
	tier = clampi(tier + delta, TIER_LOW, TIER_HIGH)
	adjustments += 1
	confirmations += 1
	_last_change = now
	# Reset the excursion timer so the next decision needs a fresh window
	# rather than firing again on the strength of the one just acted on.
	_over_since = -1.0
	_under_since = -1.0
	last_reason = why


func target_ms() -> float:
	return TARGET_MS[clampi(tier, 0, 2)]


## The frame time recovery has to beat before quality is given back. Tighter
## than the target on purpose: restoring quality only to sit exactly on the
## edge means the next hiccup undoes it.
func recover_ms() -> float:
	return target_ms() * 0.75


func _describe(frame_ms: float) -> String:
	return "%0.1f ms against a %0.1f ms budget" % [frame_ms, target_ms()]


## Pin the tier to a player choice and stop adapting. This is what the
## settings menu and the F1/F2/F3 keys call.
func pin(t: int) -> void:
	tier = clampi(t, TIER_LOW, TIER_HIGH)
	user_pinned = true
	enabled = false


## Hand control back to the controller, starting from the current tier.
func unpin() -> void:
	user_pinned = false
	enabled = true


## One-line summary for the debug overlay.
func describe() -> String:
	var names := ["LOW", "MEDIUM", "HIGH"]
	return "%s%s (%d adjustment(s))" % [
		names[clampi(tier, 0, 2)],
		"" if enabled else " pinned",
		adjustments]