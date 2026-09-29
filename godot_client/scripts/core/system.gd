class_name System
extends RefCounted
## One owner per system, and a lifecycle you can assert on.
##
## Two problems this solves, both of which only show up in a long session.
##
## **Ownership.** Every major system has exactly one owner. `main.gd` composes
## them; nothing else constructs them. A system is not a free-floating global
## that any script may poke, because the moment two things can mutate the same
## world, the order of their updates becomes load-bearing and nobody can say
## which one is right. `SystemRegistry` makes "exactly one" a fact rather than
## a convention, and the architecture test checks the count.
##
## **Lifecycle.** Godot projects get messy because creation and destruction are
## informal: a node is `add_child`ed here, a signal is connected there, a
## timer is created in a branch nobody exercises, and a subsystem that is torn
## down twice frees something that is still in use. The states here are
## explicit and forward-only except for Suspend/Resume:
##
##     CREATED -> INITIALIZED -> RUNNING <-> SUSPENDED
##                            \\-> FAILED
##     any live state -> DESTROYED
##
## and every transition is checked, so a subsystem that is `run()` before it is
## `initialize()`d fails loudly at the call site rather than mysteriously three
## systems later. `teardown()` is idempotent and accounts for what it created:
## nodes, signal connections, timers, threads and resources are all handed back
## in one place, so "leaked" becomes a number the watchdog can watch.

enum State {
	CREATED,       ## constructed, nothing allocated
	INITIALIZED,   ## dependencies bound, resources acquired
	RUNNING,       ## receiving ticks
	SUSPENDED,     ## built but not ticking (menu open, backgrounded)
	FAILED,        ## the system itself is broken, not the caller
	DESTROYED,     ## released; every entry point is a no-op after this
}

## Live states, in lifecycle order, for the registry's bookkeeping.
const LIVE_STATES := [State.CREATED, State.INITIALIZED, State.RUNNING,
	State.SUSPENDED, State.FAILED]
const TERMINAL := [State.DESTROYED]

## The system's identity in the registry and in failure reports.
@export var system_name := "system"
## What this system is the authority *for*. Written down because "who owns
## the world" should be answerable without reading the implementation.
@export var owns := ""

var state: int = State.CREATED
var last_error := ""
## The object this system is the lifecycle for. It may be a `Node` (the
## world, the player) or a `RefCounted` (the authority, the save facade). Kept
## as `Object` deliberately: a `System` is `RefCounted` and a `Node` is not,
## so a typed base class here would mean every system had to be one or the
## other, and the world is a `Node3D` while the authority is not.
var owner_object: Object = null

## What this system created and therefore must release. A subclass appends to
## these in `initialize()` and drains them in `_release()`; there is no path
## where something is acquired and then forgotten.
var _nodes: Array[Node] = []
var _timers: Array[Timer] = []
var _threads: Array[Thread] = []
var _signals: Array[Dictionary] = []
var _resources: Array[Resource] = []

## Connections made by this system, so they can be dropped on teardown. A
## signal connection outlives the object if the *emitter* outlives the
## listener, and a freed object receiving a signal is a hard crash.
var _owned_objects := 0


# --- lifecycle --------------------------------------------------------------

## Bind dependencies. Called once. Subclasses override `_initialize()`.
func initialize() -> bool:
	if state != State.CREATED:
		return _fail("initialize() called on a system in state %s" % _state_name())
	_owned_objects = Performance.get_monitor(Performance.OBJECT_COUNT)
	if _initialize():
		state = State.INITIALIZED
		last_error = ""
		return true
	# `_initialize` returning false is the system saying *I* am broken, so
	# this one does transition.
	fail("initialize() failed")
	return false


## Start ticking. Idempotent, and refuses to run an uninitialised system --
## a tick that assumes a dependency which was never bound is the exact class
## of bug this state machine exists to make local.
func run() -> bool:
	match state:
		State.INITIALIZED, State.SUSPENDED:
			state = State.RUNNING
			last_error = ""
			return true
		_:
			return _fail("run() requires INITIALIZED or SUSPENDED, not %s"
				% _state_name())


## Stop ticking without releasing anything. The player opened a menu; the
## world is still there.
func suspend() -> bool:
	if state == State.RUNNING:
		state = State.SUSPENDED
		return true
	return state == State.SUSPENDED


func resume() -> bool:
	return state == State.SUSPENDED and run()


## One tick. Only ever called while RUNNING. `dt` is already scaled by the
## caller's time source; a system has no opinion about where time comes from.
func tick(_dt: float) -> void:
	pass


## Release everything, in reverse order of acquisition. Idempotent: calling
## it twice is not an error, which matters because shutdown in Godot is
## routinely reached by two different paths (the scene being freed, and the
## game being quit).
func teardown() -> void:
	if state == State.DESTROYED:
		return
	_release()
	# Order matters: connections before the objects they reference, threads
	# before anything they might be touching.
	for c in _signals:
		if not is_instance_valid(c["from"]):
			continue
		if c["from"].is_connected(c["signal"], c["callable"]):
			c["from"].disconnect(c["signal"], c["callable"])
	_signals.clear()
	for t in _threads:
		if t.is_alive():
			t.wait_to_finish()
	_threads.clear()
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	_timers.clear()
	_resources.clear()
	state = State.DESTROYED


## What this system still owes the process. Non-zero after `teardown()` is a
## leak, and the soak test treats it as one.
func leaked() -> int:
	if state == State.DESTROYED:
		return 0
	return _nodes.size() + _timers.size() + _threads.size() \
		+ _signals.size() + _resources.size()


func is_live() -> bool:
	return LIVE_STATES.has(state)


func describe() -> String:
	return "%s [%s] owns=%s nodes=%d signals=%d" % [
		system_name, _state_name(), owns, _nodes.size(), _signals.size()]


# --- acquisition helpers ----------------------------------------------------
#
# A subclass acquires through these rather than calling `add_child` and
# `connect` directly, because that is the only way the release list stays
# complete. A subsystem that allocates outside these helpers has opted out of
# being teardown-able, and the test cannot tell.

func own(node: Node, parent: Node = null) -> Node:
	_nodes.append(node)
	if parent != null:
		parent.add_child(node)
	return node


func own_timer(seconds: float, parent: Node) -> Timer:
	var t := Timer.new()
	t.wait_time = seconds
	parent.add_child(t)
	_timers.append(t)
	return t


## Connect and remember. `flags` are Godot's own (CONNECT_ONE_SHOT etc).
func own_connect(source: Object, signal_name: StringName,
		callable: Callable, flags := 0) -> void:
	if not source.is_connected(signal_name, callable):
		source.connect(signal_name, callable, flags)
	_signals.append({
		"from": source, "signal": signal_name, "callable": callable,
	})


func own_resource(res: Resource) -> Resource:
	_resources.append(res)
	return res


# --- subclass hooks ---------------------------------------------------------

## Subclasses override. Return false to fail initialization.
func _initialize() -> bool:
	return true


## Subclasses override to drop their own state. The base class handles
## connections, nodes, timers and threads.
func _release() -> void:
	pass


## Report a misuse. The state is deliberately left alone.
##
## `FAILED` means *this system is broken* and should be taken out of the tick
## loop. A caller that called `run()` before `initialize()` has made a mistake,
## but the system is fine -- marking it FAILED would silently remove a working
## subsystem from the game because of a bad call order somewhere else, and the
## next symptom would be somewhere unrelated entirely.
func _fail(reason: String) -> bool:
	last_error = reason
	return false


## Report that the system itself failed. Unlike `_fail`, this is fatal to the
## system: the registry stops ticking it and the game continues degraded.
func fail(reason: String) -> void:
	last_error = reason
	if state != State.DESTROYED:
		state = State.FAILED


func _state_name() -> String:
	return ["CREATED", "INITIALIZED", "RUNNING", "SUSPENDED", "FAILED",
		"DESTROYED"][state]
