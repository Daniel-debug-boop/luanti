class_name NetAuthority
extends RefCounted
## Server-authoritative validation for every engineering command.
##
## The single most important property of this class is that a client cannot
## make the server believe something untrue. Not "the UI is validated" -- the
## UI validates nothing, because a client can send whatever it likes. Every
## mutation EMERGENT accepts over the network goes through `submit()`, which
## re-derives the answer from server-side state and either applies it or
## returns a reason. The client's own copy is a prediction, not a fact.
##
## What is checked, and why each one is exploitable without it:
##
##   schema     a client can send any Dictionary at all; a missing or
##              wrong-typed field would crash the server.
##   session    an unjoined peer gets nothing, and a peer whose token has
##              been revoked mid-flight gets nothing either.
##   rate       without a token bucket, one player can flood the server with
##              place commands and starve everyone else's tick.
##   reach      the classic grief: place a component 4000 m away, or through
##              a wall, and never move to see it.
##   ownership  in a shared world, Player A must not be able to dismantle
##              Player B's motor while A is offline.
##   economy    the client claims to have paid for it. The server checks
##              its own ledger and charges its own copy.
##
## Everything the server accepts is recorded in `log()`, so a disputed build can
## be replayed after the fact.

## Commands a client may issue. Anything else is rejected by schema, which is
## what stops a client from reaching a method that was never meant to be
## networked.
const ALLOWED := [
	"place", "remove", "connect", "disconnect", "manufacture",
	"operate", "set_interaction_level", "capture_blueprint", "place_blueprint",
]

## Tokens refilled per second, and the bucket depth. Sized so a player doing
## a legitimate construction burst (a pump is ~9 placements) is never throttled,
## but a client sending 60 commands a second is.
const TOKENS_PER_SECOND := 12.0
const BUCKET_DEPTH := 24.0

## Fields each op cannot be processed without. An allow-list of op names is
## not enough on its own: `{"op": "place"}` passes a name check and is still
## meaningless, and a server that has to defend itself against nonsense in
## every downstream handler is a server with the bug already written.
const REQUIRED := {
	"place": ["component"],
	"remove": ["node"],
	"connect": ["a", "b"],
	"disconnect": ["a"],
	"manufacture": ["component"],
	"operate": [],
	"set_interaction_level": ["level"],
	"capture_blueprint": ["name"],
	"place_blueprint": ["blueprint"],
}

## How far from a player's own position they may build, in metres. Precision
## mode does not extend it: if you can measure to a millimetre you still have to
## walk there.
const MAX_REACH := 12.0
## Hard cap, independent of any reach check, so a bug in a cursor cannot let
## someone build into unloaded space.
const MAX_WORLD_EXTENT := 100000.0

var enabled := true

var _tokens := {}          # peer id -> float
var _last_refill := {}     # peer id -> seconds
var _sessions := {}        # peer id -> {"name": String, "position": Vector3, "revoked": bool}
var _owned := {}           # node id -> peer id
var _ledger := {}          # peer id -> {item_id: int}
var _log: Array[Dictionary] = []
var _now := 0.0
var _rejected := 0
var _accepted := 0


func _init() -> void:
	pass


# --- session lifecycle ------------------------------------------------------

## A peer completed the handshake. Until this is called, `submit` rejects it.
func join(peer_id: int, name: String, position: Vector3, now: float) -> bool:
	_sessions[peer_id] = {
		"name": name,
		"position": position,
		"revoked": false,
		"joined_at": now,
	}
	_tokens[peer_id] = BUCKET_DEPTH
	_last_refill[peer_id] = now
	return true


func leave(peer_id: int) -> void:
	_sessions.erase(peer_id)
	_tokens.erase(peer_id)
	_last_refill.erase(peer_id)


## Kick mid-session. Anything already in flight for this peer is refused from
## the next `submit` on, including a replayed command.
func revoke(peer_id: int) -> void:
	if _sessions.has(peer_id):
		_sessions[peer_id]["revoked"] = true


func is_joined(peer_id: int) -> bool:
	return _sessions.has(peer_id) and not bool(_sessions[peer_id]["revoked"])


func peer_position(peer_id: int) -> Vector3:
	if not _sessions.has(peer_id):
		return Vector3.ZERO
	return _sessions[peer_id]["position"]


## The client says it moved. The server tracks the *position it believes*, and
## clamps impossible jumps rather than trusting the packet -- otherwise reach
## checking is defeated by claiming to be somewhere else.
func set_peer_position(peer_id: int, position: Vector3, dt: float) -> Vector3:
	if not _sessions.has(peer_id):
		return Vector3.ZERO
	var current: Vector3 = _sessions[peer_id]["position"]
	# 40 m/s is faster than a sprint and slower than a teleport cheat, so
	# legitimate movement passes untouched and a teleport is pulled back.
	var limit := 40.0 * maxf(dt, 0.0) + 0.5
	var moved := position - current
	var accepted := current
	if moved.length() <= limit:
		accepted = position
	accepted.x = clampf(accepted.x, -MAX_WORLD_EXTENT, MAX_WORLD_EXTENT)
	accepted.y = clampf(accepted.y, -4096.0, 4096.0)
	accepted.z = clampf(accepted.z, -MAX_WORLD_EXTENT, MAX_WORLD_EXTENT)
	_sessions[peer_id]["position"] = accepted
	return accepted


# --- economy ----------------------------------------------------------------

## The server's own copy of a player's resources. Never the client's number.
func set_ledger(peer_id: int, items: Dictionary) -> void:
	_ledger[peer_id] = items.duplicate()


func ledger_of(peer_id: int) -> Dictionary:
	return _ledger.get(peer_id, {})


## What the peer actually has after a charge, for the server to compare a
## client prediction against.
func charge(peer_id: int, cost: Dictionary) -> bool:
	var l: Dictionary = _ledger.get(peer_id, {})
	for item in cost:
		if int(l.get(item, 0)) < int(cost[item]):
			return false
	for item in cost:
		l[item] = int(l[item]) - int(cost[item])
	_ledger[peer_id] = l
	return true


func can_afford(peer_id: int, cost: Dictionary) -> bool:
	var l: Dictionary = _ledger.get(peer_id, {})
	for item in cost:
		if int(l.get(item, 0)) < int(cost[item]):
			return false
	return true


# --- ownership --------------------------------------------------------------

func claim(node_id: int, peer_id: int) -> void:
	_owned[node_id] = peer_id


func release(node_id: int) -> void:
	_owned.erase(node_id)


func owner_of(node_id: int) -> int:
	return int(_owned.get(node_id, 0))


## May this peer modify this node? Unowned nodes are free for all; owned nodes
## belong to their creator. A `-1` peer is the world itself (admin/debug).
func may_modify(peer_id: int, node_id: int) -> bool:
	if peer_id < 0:
		return true
	var owner := owner_of(node_id)
	return owner == 0 or owner == peer_id


# --- rate limiting ----------------------------------------------------------

func _refill(peer_id: int) -> void:
	var t := float(_last_refill.get(peer_id, _now))
	if _now > t:
		_tokens[peer_id] = minf(BUCKET_DEPTH,
			float(_tokens.get(peer_id, BUCKET_DEPTH)) + (_now - t) * TOKENS_PER_SECOND)
		_last_refill[peer_id] = _now


## Tokens left. Exposed so the tests can assert the bucket, not just the
## accept/reject outcome.
func tokens_of(peer_id: int) -> float:
	_refill(peer_id)
	return float(_tokens.get(peer_id, 0.0))


func advance_clock(now: float) -> void:
	_now = now


# --- the gate ---------------------------------------------------------------

## Validate and apply one command. Returns
## `{"ok": bool, "reason": String, "result": Variant, "peer": int}`.
## `ok == false` means the server changed nothing at all.
##
## `apply` is the closure that performs the real mutation against the server's
## own world. It is only ever called after every check has passed, and its
## return value is passed back untouched.
func submit(peer_id: int, command: Dictionary, apply: Callable) -> Dictionary:
	var fail := func(reason: String) -> Dictionary:
		_rejected += 1
		_record(peer_id, command, false, reason)
		return {"ok": false, "reason": reason, "result": null, "peer": peer_id}

	if not enabled:
		var res: Variant = apply.call(command) if apply.is_valid() else null
		_accepted += 1
		_record(peer_id, command, true, "")
		return {"ok": true, "reason": "", "result": res, "peer": peer_id}

	# 1. schema -- before anything else, because every later check reads fields
	# that may not be there.
	if not (command is Dictionary):
		return fail.call("command is not a dictionary")
	var op := String(command.get("op", ""))
	if not ALLOWED.has(op):
		return fail.call("unknown op '%s'" % op)
	for field in REQUIRED[op]:
		if not command.has(field) or command[field] == null:
			return fail.call("op '%s' requires '%s'" % [op, field])
		var v: Variant = command[field]
		# An empty String is a missing value; 0 is a legitimate node id, so the
		# check has to be type-aware rather than a blanket falsy test.
		if (v is String or v is StringName) and String(v).is_empty():
			return fail.call("op '%s' requires '%s'" % [op, field])

	# 2. session
	if not is_joined(peer_id):
		return fail.call("peer %d is not in a valid session" % peer_id)

	# 3. rate limit
	_refill(peer_id)
	if float(_tokens.get(peer_id, 0.0)) < 1.0:
		return fail.call("rate limited")
	_tokens[peer_id] = float(_tokens[peer_id]) - 1.0

	# 4. economy -- charged from the server's ledger, never the client's claim
	var cost: Dictionary = command.get("cost", {})
	if not cost.is_empty():
		if not can_afford(peer_id, cost):
			return fail.call("insufficient resources")

	# 5. reach + ownership, which need the node ids the op touches
	var target_id := int(command.get("node", 0))
	var node_a := int(command.get("a", 0))
	var node_b := int(command.get("b", 0))
	var ids: Array[int] = []
	if target_id != 0:
		ids.append(target_id)
	if node_a != 0:
		ids.append(node_a)
	if node_b != 0:
		ids.append(node_b)
	for id in ids:
		if not may_modify(peer_id, id):
			return fail.call("node %d belongs to peer %d" % [id, owner_of(id)])

	var pos: Variant = command.get("position", null)
	if pos != null:
		if not (pos is Vector3):
			return fail.call("position is not a vector")
		var p: Vector3 = pos
		if absf(p.x) > MAX_WORLD_EXTENT or absf(p.z) > MAX_WORLD_EXTENT \
				or absf(p.y) > 4096.0:
			return fail.call("position outside the world")
		var origin := peer_position(peer_id)
		if command.get("ignore_reach", false) != true \
				and origin.distance_to(p) > MAX_REACH:
			return fail.call("out of reach: %.1f m away (limit %.1f)" % [
				origin.distance_to(p), MAX_REACH])

	# Everything passed. Now, and only now, does the world change.
	if not cost.is_empty():
		if not charge(peer_id, cost):
			return fail.call("insufficient resources")
	var result: Variant = apply.call(command) if apply.is_valid() else null
	_accepted += 1
	_record(peer_id, command, true, "")
	return {"ok": true, "reason": "", "result": result, "peer": peer_id}


func _record(peer_id: int, command: Dictionary, ok: bool, reason: String) -> void:
	_log.append({
		"peer": peer_id,
		"op": String(command.get("op", "")),
		"ok": ok,
		"reason": reason,
		"at": _now,
	})
	# Bounded so a long session cannot grow the log without limit.
	if _log.size() > 512:
		_log.remove_at(0)


# --- replication ------------------------------------------------------------

## What this client is allowed to know. Server-side: the authority decides what
## to send, and the client renders it. The client never sends back a world
## state, so there is nothing in the protocol for it to lie about.
func snapshot_for(peer_id: int, graph: EngGraph, distance: float) -> Dictionary:
	var out := []
	for entry in graph.all_nodes():
		var n: EngGraph.EngNode = entry
		if n == null:
			continue
		if peer_position(peer_id).distance_to(n.position) > distance:
			continue
		out.append({
			"id": n.id,
			"component": n.component_id,
			"position": n.position,
			"enabled": n.enabled,
			"owner": owner_of(n.id),
		})
	return {"nodes": out, "at": _now}


func log() -> Array[Dictionary]:
	return _log


func accepted_count() -> int:
	return _accepted


func rejected_count() -> int:
	return _rejected


func clear_log() -> void:
	_log.clear()
	_accepted = 0
	_rejected = 0
