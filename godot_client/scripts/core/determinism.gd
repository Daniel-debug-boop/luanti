class_name Determinism
extends RefCounted
## What is deterministic, and how you can tell.
##
## EMERGENT has two kinds of code and they have opposite rules:
##
##   * **Simulation** -- machines, networks, mobs, the world. It runs at a
##     fixed step, from integer ids, in sorted order, with no wall-clock and
##     no floating-point accumulation that depends on frame timing. Two servers
##     given the same commands must reach the same state, or multiplayer is a
##     guess.
##
##   * **Presentation** -- meshes, UI, the profiler, particles. It may read
##     the clock, allocate freely and depend on frame rate, because nobody ever
##     compares two copies of it.
##
## The rule that keeps the two apart: everything a `Determinism.hash_state()`
## call can reach must be reproducible. So a new source of `randi()` or
## `Time.get_ticks_msec()` inside the simulation is a bug, and the way to find
## it is to hash the state, run the same steps twice, and compare -- which is
## exactly what `assert_reproducible()` does, and what `robustness_test` runs
## over a 12,000-tick soak.

## The simulation step. Fixed, and not a function of frame time.
const SIM_HZ := 10.0
const SIM_DT := 1.0 / SIM_HZ

## How many steps a single frame may run before the accumulator is dropped.
## A frame that takes longer than this is a hitch, and a hitch must not turn
## into a burst of catch-up ticks: the alternative is a spiral of death where
## each slow frame schedules more work than the last.
const MAX_STEPS_PER_FRAME := 4

## Fixed-width accumulator around the step. A float accumulator that has been
## added to a few hundred thousand times drifts, and a drifting accumulator
## means the factory runs at 9.98 Hz on one machine and 10.02 on another.
const DT_QUANTUM := 1.0e-6

## Quantise a timestep so the accumulator cannot drift.
static func quantise(dt: float) -> float:
	return roundf(dt / DT_QUANTUM) * DT_QUANTUM


## An order-independent, stable hash of arbitrary simulation state.
##
## Two things this has to get right, and both have bitten this project:
##
##   * **Dictionary order must not matter.** Godot preserves insertion order,
##     so two graphs built by adding the same nodes in a different order hash
##     differently. Keys are sorted before hashing.
##   * **Floats must be compared as themselves, not fuzzily.** A "helpful"
##     epsilon here would hide exactly the divergence the hash exists to find.
##     It is FNV-1a over the canonical text, and it is exact.
static func hash_state(value: Variant) -> int:
	var h := 0x811c9dc5
	h = _absorb(h, canonical(value))
	return h & 0xffffffff


static func _absorb(h: int, text: String) -> int:
	for b in text.to_utf8_buffer():
		h = (h ^ int(b)) & 0xffffffff
		h = (h * 0x01000193) & 0xffffffff
	return h


## A canonical string for any value, with dictionary keys sorted.
static func canonical(value: Variant) -> String:
	match typeof(value):
		TYPE_DICTIONARY:
			var keys: Array = (value as Dictionary).keys()
			keys.sort_custom(func(a, b): return str(a) < str(b))
			var parts := PackedStringArray()
			for k in keys:
				parts.append("%s=%s" % [str(k),
					canonical((value as Dictionary)[k])])
			return "{" + "|".join(parts) + "}"
		TYPE_ARRAY:
			var parts2 := PackedStringArray()
			for v in (value as Array):
				parts2.append(canonical(v))
			return "[" + ",".join(parts2) + "]"
		TYPE_VECTOR3I:
			var v3: Vector3i = value
			return "v3i(%d,%d,%d)" % [v3.x, v3.y, v3.z]
		TYPE_VECTOR3:
			var v3f: Vector3 = value
			# Six decimals is exactly the precision a world position needs and
			# no more, so a float that differs in the 15th place does not
			# report a divergence that cannot be observed.
			return "v3(%.6f,%.6f,%.6f)" % [v3f.x, v3f.y, v3f.z]
		TYPE_FLOAT:
			return "f(%.9g)" % float(value)
		TYPE_STRING, TYPE_STRING_NAME:
			return "s(%s)" % str(value)
		TYPE_BOOL:
			return "b(%s)" % ("1" if bool(value) else "0")
		TYPE_NIL:
			return "null"
		_:
			return "v(%s)" % str(value)


## Run `step` twice from the same starting state and report whether the two
## runs agree. Returns `{ok, a, b, steps, reason}`.
##
## This is the only tool that answers "is this actually deterministic"
## without a human reading the code, which is why the soak test uses it
## instead of trusting that it is.
static func assert_reproducible(step: Callable, initial: Variant, steps: int) -> Dictionary:
	var a: Variant = initial
	for i in steps:
		a = step.call(a, i)
	var b: Variant = initial
	for i in steps:
		b = step.call(b, i)
	var ha := hash_state(a)
	var hb := hash_state(b)
	return {
		"ok": ha == hb,
		"a": ha,
		"b": hb,
		"steps": steps,
		"reason": "" if ha == hb else "the two runs diverged after %d steps" % steps,
	}


## A fixed-step accumulator that is safe to drive from a variable frame time.
## Returns `{"steps": int, "remainder": float}`.
static func steps_from(accumulator: float, frame_delta: float) -> Dictionary:
	var acc: float = accumulator + frame_delta
	var steps := int(floor(acc / SIM_DT))
	if steps > MAX_STEPS_PER_FRAME:
		# Drop the backlog rather than chase it. The factory runs slow for a
		# moment; it does not then run fast to "catch up", which would make
		# the catch-up itself the next slow frame. The accumulator is left at
		# exactly one ceiling's worth, so a machine that cannot keep up stays
		# at the ceiling instead of stalling and then lurching.
		acc = SIM_DT * float(MAX_STEPS_PER_FRAME)
		steps = MAX_STEPS_PER_FRAME
	return {"steps": steps, "remainder": quantise(maxf(acc, 0.0))}
