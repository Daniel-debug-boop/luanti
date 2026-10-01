class_name SystemRegistry
extends RefCounted
## Exactly one owner per system, and a place to ask what the game is doing.
##
## "Who owns the world?" should be a lookup, not an archaeology project. Every
## system registers here when `main.gd` composes it, and a second registration
## of the same name is refused with a message that says why. That is the
## difference between one authority and one *stated* authority.
##
## The registry is also the place a failure is reported, which is what makes
## item 6 of the brief -- graceful degradation rather than a crash -- a
## mechanism rather than an intention. A system that throws during its tick
## is marked FAILED with the reason; the rest of the game keeps running. A
## system that is *required* (the world, the player) takes the game down with
## a clear message, because continuing without it produces a worse bug later.
##
## Ordering is explicit. `run_order()` returns the systems in the order they
## should tick, and it is data: input, then simulation, then gameplay, then
## presentation. Nothing reads another's internals to work out when to run.

## System name -> the System that owns it.
## Ticking order, and it is explicit rather than incidental.
##
## `emergent` sits immediately after `engineering` because it derives its
## relationships from the machine graph the engineering layer rebuilds each
## frame. Tick it first and it would read the previous frame's wiring -- which
## looks correct on a still world and is a desync on a moving one.
const ORDER := [
	"world", "player", "village", "engineering", "emergent", "net",
	"persistence", "audio", "profiler", "hud",
]

static var _systems := {}
static var _order := []
static var _failures := []


static func register(system: System, owner_object: Object = null,
		name_override := "") -> String:
	var key := name_override if name_override != "" else system.system_name
	if owner_object != null:
		system.owner_object = owner_object
	if key == "":
		system.last_error = "a system must have a name"
		return system.last_error
	if _systems.has(key) and is_instance_valid(_systems[key]):
		return "'%s' already has an owner (%s); there is exactly one" % [
			key, (_systems[key] as System).describe()]
	_systems[key] = system
	if not _order.has(key):
		_order.append(key)
	return ""


## The object a system owns, or null. This is what callers want: the world,
## not the wrapper around the world.
static func get_owner(key: String) -> Object:
	var s := get_system(key)
	return null if s == null else s.owner_object


static func get_system(key: String) -> System:
	var s: Variant = _systems.get(key, null)
	if s == null or not is_instance_valid(s):
		_systems.erase(key)
		return null
	return s


static func has_system(key: String) -> bool:
	return get_system(key) != null


## Systems in the order they must tick. Anything not named in ORDER runs last,
## which is the right default for a presenter.
static func run_order() -> Array[String]:
	var out: Array[String] = []
	for key in ORDER:
		if _systems.has(key):
			out.append(key)
	for key in _order:
		if not out.has(key):
			out.append(key)
	return out


## Initialize, then run, every system in order. Returns the failures; a
## non-empty list means the game is running degraded, and `healthy()` says so.
static func start_all() -> Array[Dictionary]:
	var failures: Array[Dictionary] = []
	for key in run_order():
		var s := get_system(key)
		if s == null:
			continue
		if not s.initialize():
			failures.append({"system": key, "stage": "initialize",
				"reason": s.last_error})
		elif not s.run():
			failures.append({"system": key, "stage": "run",
				"reason": s.last_error})
	return failures


static func tick_all(dt: float) -> void:
	for key in run_order():
		var s := get_system(key)
		# A failed system is not ticked, and a missing one is skipped: a
		# subsystem that could not start must not take the frame with it.
		if s == null or s.state != System.State.RUNNING:
			continue
		s.tick(dt)


## Suspend everything, for a menu or a lost focus.
static func suspend_all() -> void:
	for key in run_order():
		var s := get_system(key)
		if s != null:
			s.suspend()


static func resume_all() -> void:
	for key in run_order():
		var s := get_system(key)
		if s != null and s.state == System.State.SUSPENDED:
			s.resume()


## Tear everything down, in reverse run order, so a system that depends on
## another is released first. Idempotent per system and in total.
static func shutdown_all() -> void:
	var keys := run_order()
	keys.reverse()
	for key in keys:
		var s := get_system(key)
		if s != null:
			s.teardown()
	_systems.clear()
	_order.clear()
	_failures.clear()


## Report a recoverable failure. Recorded rather than printed, so a test can
## assert that a system failed *gracefully* instead of taking the game with it.
static func report_failure(key: String, reason: String,
		required := false) -> Dictionary:
	var entry := {"system": key, "reason": reason, "required": required}
	_failures.append(entry)
	var s := get_system(key)
	if s != null:
		s.last_error = reason
		if required:
			s.fail(reason)
	return entry


static func failures() -> Array[Dictionary]:
	return _failures


static func healthy() -> bool:
	for f in _failures:
		if bool(f["required"]):
			return false
	return true


## One line per system, for the dev panel and for a bug report.
static func health_report() -> String:
	var lines := PackedStringArray()
	for key in run_order():
		var s := get_system(key)
		if s == null:
			lines.append("  %-14s MISSING" % key)
			continue
		lines.append("  %-14s %-11s leaked=%d %s" % [
			key, s._state_name(), s.leaked(), s.last_error])
	if not _failures.is_empty():
		lines.append("  %d failure(s):" % _failures.size())
		for f in _failures:
			lines.append("    [%s] %s" % [
				"required" if bool(f["required"]) else "degraded", f["reason"]])
	return "\n".join(lines)


static func clear() -> void:
	_systems.clear()
	_order.clear()
	_failures.clear()
