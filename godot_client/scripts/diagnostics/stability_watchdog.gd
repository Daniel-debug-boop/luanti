class_name StabilityWatchdog
extends RefCounted
## Long-duration stability instrumentation.
##
## "Does the game survive six hours?" is not a question you answer by playing
## it once. It is a question about *growth*: a system that leaks shows up as a
## monotonic climb in node count, object count, or memory over thousands of
## ticks, long before it shows up as a crash. This class samples the engine's
## own counters on an interval, keeps the history, and answers the question
## numerically: is the slope of this counter positive, and does it stay
## positive when the world stops changing?
##
## It is deliberately a `RefCounted` with an injected clock rather than a Node
## with `_process`. Soak tests drive it with a synthetic clock and get the same
## verdicts the live game would produce, deterministically and in milliseconds.
##
## Two verdict kinds:
##   leak        the counter climbs and does not come back down after the
##               world is quiescent. This is the one that matters.
##   pressure    a single sample is past a hard ceiling. Worth knowing, not
##               necessarily a bug.

## Seconds between samples.
const SAMPLE_INTERVAL := 30.0
## How many samples to keep. At the default interval that is 2.5 hours.
const HISTORY := 300

## Hard ceilings, in the same units the counters are reported in. Exceeding one
## is a "pressure" finding, not an automatic failure: a machine with 2 GB of
## video memory is doing something the developer intended to know about.
const CEILINGS := {
	"object_node_count": 200000,
	"object_count": 400000,
	"static_memory_mb": 1024.0,
	"video_mem_mb": 2048.0,
}

## A counter is considered to be leaking if it rises by more than this over the
## window while the world is not changing. Absolute, not proportional: 3 nodes
## over an hour is noise, 3 nodes per tick is a catastrophe.
const LEAK_EPSILON := {
	"object_node_count": 64.0,
	"object_count": 128.0,
	"static_memory_mb": 24.0,
	"video_mem_mb": 96.0,
}

## Counters the watchdog follows.
const TRACKED := [
	"object_node_count",
	"object_count",
	"orphan_node_count",
	"static_memory_mb",
	"video_mem_mb",
	"texture_mem_mb",
]

var _samples: Array[Dictionary] = []
var _next_at := 0.0
var _enabled := true
var _quiescent := true
var _quiescent_since := 0.0
var _events: Array[Dictionary] = []


func _init() -> void:
	_reserve()


func _reserve() -> void:
	# resize + clear, not resize alone: resize pre-fills the array with empty
	# dictionaries, which every later pass would read as a sample of zero and
	# which would make the first real sample look like a 1000-node leak.
	_samples.resize(HISTORY)
	_samples.clear()


## Turn the watchdog off. A soak test that forgets to do this pays for a
## sampling pass every interval.
func set_enabled(on: bool) -> void:
	_enabled = on


func is_enabled() -> bool:
	return _enabled


## Declare that the world is currently static (player idle, no machines
## running, no chunks streaming). The leak test only counts samples taken
## while quiescent, because growth during a genuine content burst is expected.
func set_quiescent(on: bool, now: float) -> void:
	if on and not _quiescent:
		_quiescent_since = now
	_quiescent = on


func is_quiescent() -> bool:
	return _quiescent


## Feed a clock. Samples when due. Returns true if a sample was taken.
func tick(now: float, frame_ms: float = 0.0) -> bool:
	if not _enabled:
		return false
	if now < _next_at:
		return false
	_next_at = now + SAMPLE_INTERVAL
	_take(now, frame_ms)
	return true


## Force a sample regardless of the interval. Soak tests use this to run a
## compressed timeline without faking Time.
func sample_now(now: float, frame_ms: float = 0.0) -> void:
	if not _enabled:
		return
	_take(now, frame_ms)
	_next_at = now + SAMPLE_INTERVAL


func _take(now: float, frame_ms: float = 0.0) -> void:
	var s := counters()
	s["t"] = now
	s["frame_ms"] = frame_ms
	s["quiescent"] = _quiescent
	s["quiescent_for"] = now - _quiescent_since
	_samples.append(s)
	if _samples.size() > HISTORY:
		_samples.remove_at(0)


## The engine's own counters, sampled. Split out so a soak test can also drive
## the watchdog against a synthetic world (see `ingest`).
func counters() -> Dictionary:
	return {
		"object_node_count": float(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"object_count": float(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"orphan_node_count": Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
		"static_memory_mb": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		"video_mem_mb": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		"texture_mem_mb": Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0,
	}


## Push a synthetic sample. Lets a soak test prove the leak detector works
## against a *known* leak without actually leaking memory in the test process.
func ingest(now: float, values: Dictionary) -> void:
	var s := values.duplicate()
	s["t"] = now
	s["quiescent"] = _quiescent
	s["quiescent_since"] = _quiescent_since
	s["quiescent_for"] = now - _quiescent_since
	_samples.append(s)
	if _samples.size() > HISTORY:
		_samples.remove_at(0)


func sample_count() -> int:
	return _samples.size()


func history() -> Array[Dictionary]:
	return _samples


func first_sample() -> Dictionary:
	return _samples[0] if _samples.size() > 0 else {}


func last_sample() -> Dictionary:
	return _samples[_samples.size() - 1] if _samples.size() > 0 else {}


## Total change of a counter across the window, ignoring non-quiescent
## samples at both ends so a save/load or a big build does not skew it.
func drift(key: String) -> float:
	if _samples.size() < 2:
		return 0.0
	var first := 0.0
	var got_first := false
	var last := 0.0
	for s in _samples:
		if not bool(s.get("quiescent", true)):
			continue
		if not got_first:
			first = float(s.get(key, 0.0))
			got_first = true
		last = float(s.get(key, 0.0))
	return last - first if got_first else 0.0


func min_of(key: String) -> float:
	var m := INF
	for s in _samples:
		m = minf(m, float(s.get(key, 0.0)))
	return m if m < INF else 0.0


func max_of(key: String) -> float:
	var m := -INF
	for s in _samples:
		m = maxf(m, float(s.get(key, 0.0)))
	return m if m > -INF else 0.0


func peak_time(key: String) -> float:
	var m := -INF
	for s in _samples:
		m = maxf(m, float(s.get(key, 0.0)))
	return m if m > -INF else 0.0


# --- verdicts ---------------------------------------------------------------

## The findings. Each is a Dictionary with `kind`, `counter`, `drift`,
## `ceiling` and a human-readable `message`.
func findings() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for key in TRACKED:
		var d := drift(key)
		var eps: float = LEAK_EPSILON.get(key, 1.0)
		if d > eps:
			out.append({
				"kind": "leak",
				"counter": key,
				"drift": d,
				"epsilon": eps,
				"message": "%s grew by %.1f while the world was static (limit %.1f)" \
					% [key, d, eps],
			})
		var ceil_v: float = CEILINGS.get(key, INF)
		var peak := max_of(key)
		if peak > ceil_v:
			out.append({
				"kind": "pressure",
				"counter": key,
				"peak": peak,
				"ceiling": ceil_v,
				"message": "%s peaked at %.1f, past the %.1f ceiling" \
					% [key, peak, ceil_v],
			})
	return out


func has_leak() -> bool:
	for f in findings():
		if String(f["kind"]) == "leak":
			return true
	return false


## One-paragraph summary, suitable for a CI log or a commit trailer.
func report() -> String:
	var lines := PackedStringArray()
	lines.append("stability: %d samples over %.0f s" % [
		_samples.size(), _span()])
	lines.append("  mean frame %.2f ms, p95 %.2f ms, worst %.2f ms" % [
		_mean("frame_ms"), _percentile("frame_ms", 0.95), _max("frame_ms")])
	for key in TRACKED:
		lines.append("  %-20s drift %+10.2f   peak %10.2f" % [
			key, drift(key), max_of(key)])
	var fs := findings()
	if fs.is_empty():
		lines.append("  no findings")
	else:
		for f in fs:
			lines.append("  [%s] %s" % [f["kind"], f["message"]])
	return "\n".join(lines)


func _span() -> float:
	if _samples.size() < 2:
		return 0.0
	return float(_samples[_samples.size() - 1]["t"]) - float(_samples[0]["t"])


func _max(key: String) -> float:
	return max_of(key)


func _mean(key: String) -> float:
	var s := 0.0
	var n := 0
	for v in _samples:
		s += float(v.get(key, 0.0))
		n += 1
	return s / float(n) if n > 0 else 0.0


func _percentile(key: String, p: float) -> float:
	var arr := PackedFloat64Array()
	for v in _samples:
		arr.append(float(v.get(key, 0.0)))
	if arr.is_empty():
		return 0.0
	arr.sort()
	var i := clampi(int(round(p * float(arr.size() - 1))), 0, arr.size() - 1)
	return arr[i]


func clear() -> void:
	_samples.clear()
	_reserve()
	_events.clear()
	_next_at = 0.0
