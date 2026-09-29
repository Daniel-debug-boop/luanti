class_name CreatureAnimator
extends RefCounted
## Drives the skeletal animations that ship *inside* the CC0 KayKit models.
##
## No animation files were downloaded: every KayKit character GLB already
## contains 76-95 clips (Idle, Walking_A, Running_A, attacks, Hit_A, Death_A,
## Jump_*, Cheer, Taunt, Sit_*, Spellcasting). This file just finds the
## AnimationPlayer in an instantiated model, picks the right clip for a logical
## state, and crossfades between them.
##
## Design: the caller states *intent* -- IDLE, MOVE, RUN, ATTACK, HURT, DEATH
## -- and this class picks a clip. One-shot states (ATTACK, HURT, DEATH) play
## once and hand control back to the locomotion state, so a mob that is hit
## while running staggers and then resumes running rather than freezing.

## Logical states the caller asks for.
enum State { IDLE, MOVE, RUN, ATTACK, HURT, DEATH }

## state -> candidate clip names, tried in order. The first one the model
## actually has wins, which is what lets one table drive both the skeletons
## (95 clips) and the adventurers (76 clips).
const CLIPS := {
	State.IDLE: ["Idle", "Unarmed_Idle", "Idle_B", "Idle_Combat"],
	State.MOVE: ["Walking_A", "Walking_B", "Walking_C", "Walking_Backwards"],
	State.RUN: ["Running_A", "Running_B", "Running_C"],
	State.ATTACK: ["Unarmed_Melee_Attack_Punch_A",
		"Unarmed_Melee_Attack_Kick", "1H_Melee_Attack_Chop",
		"2H_Melee_Attack_Chop"],
	State.HURT: ["Hit_A", "Hit_B", "Block_Hit"],
	State.DEATH: ["Death_A", "Death_B", "Death_A_Pose"],
}

## Special states the caller triggers explicitly rather than by locomotion.
const GREET_CLIPS := ["Cheer", "Taunt", "Taunt_Longer"]
const WORK_CLIPS := ["Use_Item", "Spellcasting", "Interact", "Throw"]

## Crossfade time when switching locomotion clips.
const BLEND := 0.22
## Seconds an ATTACK/HURT clip is allowed to hold before locomotion resumes.
const ONE_SHOT_TIME := 0.6

var _player: AnimationPlayer = null
var _library: Dictionary = {}     # State -> clip name actually in use
var _current: int = State.IDLE
var _one_shot := 0.0


## Attach to an instantiated model. Returns false when it has no animations,
## in which case the caller should carry on with the static body.
func attach(model: Node) -> bool:
	_player = _find_player(model)
	if _player == null:
		return false
	# Make sure a base clip is playing so the rest is not in a T-pose.
	for state in CLIPS:
		var clip := _pick(state)
		if clip != "":
			_library[state] = clip
			break
	return not _library.is_empty()


static func _find_player(node: Node) -> AnimationPlayer:
	if node == null:
		return null
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for c in node.get_children():
		var found := _find_player(c)
		if found != null:
			return found
	return null


func _pick(state: int) -> String:
	if _player == null or _player.has_animation_library("") == false:
		# Older-style GLTF import still exposes a library, but be defensive.
		if _player == null:
			return ""
	for candidate in CLIPS.get(state, []):
		var name := String(candidate)
		if _player.has_animation(name):
			return name
	return ""


func has_animation(name: String) -> bool:
	return _player != null and _player.has_animation(name)


## Request a state. One-shot states (ATTACK/HURT/DEATH) are honoured and then
## release back to whatever the caller asks for next.
func set_state(state: int) -> void:
	if _player == null or _library.is_empty():
		return
	if state == _current and _one_shot <= 0.0:
		return
	_current = state
	if state in [State.ATTACK, State.HURT, State.DEATH]:
		_one_shot = ONE_SHOT_TIME
		if state == State.DEATH:
			_one_shot = 999.0     # death holds until the node is freed
	var clip := _clip_for(state)
	if clip != "":
		_player.play(clip, BLEND)


## Play a one-off clip by name or from a candidate list. Returns false when
## the model has none of them.
func play_once(candidates: Array) -> bool:
	if _player == null:
		return false
	for c in candidates:
		var name := String(c)
		if _player.has_animation(name):
			_player.play(name, 0.12)
			_one_shot = ONE_SHOT_TIME
			return true
	return false


func _clip_for(state: int) -> String:
	var known: String = String(_library.get(state, ""))
	if known != "":
		return known
	var picked := _pick(state)
	if picked != "":
		_library[state] = picked
	return picked


## Match the walk cycle to how fast the creature is actually moving, so a
## wandering mob and a charging one do not share the same leg speed.
## `planar_speed` is the horizontal speed in blocks/second.
func update(delta: float, planar_speed: float, walk_speed: float,
		run_speed: float) -> void:
	if _player == null:
		return
	if _one_shot > 0.0:
		if _current != State.DEATH:
			_one_shot = maxf(0.0, _one_shot - delta)
		return
	if planar_speed <= 0.05:
		# Standing still: fall back to idle from whatever we were doing.
		if _current != State.IDLE:
			_current = State.IDLE
			var idle := _clip_for(State.IDLE)
			if idle != "":
				_player.play(idle, BLEND)
		if _current == State.IDLE:
			_player.speed_scale = 1.0
		return

	var running := planar_speed > (walk_speed + run_speed) * 0.5
	var want := State.RUN if running else State.MOVE
	if want != _current:
		_current = want
		var clip := _clip_for(want)
		if clip != "":
			_player.play(clip, BLEND)

	# 0.6x at a walk, 1.0x at a run, clamped so a sprinting mob does not
	# look like it is on a treadmill.
	var base := maxf(walk_speed, 0.5)
	var t := clampf(planar_speed / base, 0.6, 1.8)
	_player.speed_scale = lerpf(_player.speed_scale, t, clampf(delta * 8.0, 0.0, 1.0))


## True once a one-shot clip has run its course.
func finished_one_shot() -> bool:
	return _one_shot <= 0.0


func current_state() -> int:
	return _current


func attached() -> bool:
	return _player != null and not _library.is_empty()


## How many clips the attached model actually has, for the HUD and tests.
func clip_count() -> int:
	return _player.get_animation_list().size() if _player != null else 0
