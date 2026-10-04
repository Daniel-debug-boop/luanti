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
##   atomicity  a command that is charged for and then fails to happen leaves
##              a player who paid for nothing, which is worse than a refusal
##              because it is also unreportable.
##
## There is deliberately no flag that turns any of this off. A
## `validation_enabled` boolean is a switch a shipped build can be flipped
## with by a scene property, a stray script or a mistyped constant, and the
## mistake is invisible until somebody is exploited. Single player does not
## need one: the host is a peer like any other and goes through the same gate.
##
## Everything the server accepts is recorded in `log()`, so a disputed build can
## be replayed after the fact.

## Commands a client may issue: every request in `NetProtocol` except the
## handshake. Anything else is rejected by schema, which is what stops a client
## from reaching a method that was never meant to be networked.
##
## This used to be a list here *and* a table in `NetProtocol`, and they
## disagreed: `disconnect` wanted an `a` in one and an `edge` in the other, and
## the emergent ops existed in only one of them. The protocol table is now the
## only description of the wire and this reads out of it.
## The host player's own peer id. A single-player host is still a peer: it
## joins like one, is rate limited like one, and is refused like one. The
## only thing it does not have is a transport to send its commands over,
## which is why `submit_local` submits them directly instead of queuing.
const HOST_PEER := 1

## The closure that performs the host's commands once the gate has passed
## them. Installed once at start-up by the composition root.
var _local_apply: Callable = Callable()


## Install the closure the host's own commands are applied through. This is
## the one door into the world that is not the transport, and it is still a
## door through the gate: `GameApi.request` on the authoritative end calls
## `submit_local`, which calls `submit` -- the same path a remote command
## takes.
func set_local_applier(apply: Callable) -> void:
	_local_apply = apply


func has_local_applier() -> bool:
	return _local_apply.is_valid()


## Submit a command from this process's own host player. Returns the same
## `{"ok", "reason", "result", "peer"}` shape as `submit`.
func submit_local(op: String, payload: Dictionary) -> Dictionary:
	if not _local_apply.is_valid():
		_rejected += 1
		return {"ok": false, "reason": "no local applier is installed",
			"result": null, "peer": HOST_PEER}
	var cmd := payload.duplicate(true)
	cmd["op"] = op
	return submit(HOST_PEER, cmd, _local_apply)


static func allowed_ops() -> Array[String]:
	return NetProtocol.command_ops()


## Tokens refilled per second, and the bucket depth. Sized so a player doing
## a legitimate construction burst (a pump is ~9 placements) is never throttled,
## but a client sending 60 commands a second is.
const TOKENS_PER_SECOND := 12.0
const BUCKET_DEPTH := 24.0

## How much of the wire a single peer may spend on a refused command before
## the refusal rate itself is treated as an attack.
##
## A token bucket alone bounds the damage one command can do; it does not
## bound the cost of *being wrong*. A peer that sends a hundred malformed
## packets a second spends nothing, and on a server where validation is
## expensive -- a schema check, a reach check, an audit-log write -- that is a
## free denial of service. So a second, slower bucket runs alongside: the first
## costs the ordinary one, the second is refilled at `TOKENS_PER_SECOND` and
## drains on every command, accepted or not, so a flood converges on refusal.
const REFUSE_TOKENS_PER_SECOND := 6.0
const REFUSE_BUCKET_DEPTH := 32.0
## Above this share of refusals over a whole session, the peer is reported.
## Not a ban -- the server decides that -- but a number an operator can alert
## on instead of reading the log.
const GRIEF_THRESHOLD := 0.5

## Length limits. A 64 kB component name is not a bug that shows up as a
## crash; it is a 64 kB log line in every downstream error message.
const MAX_NAME := 64
const MAX_TEXT := 512
## How deep a payload may nest. A client is not supposed to be able to make
## the server recurse through its own checker; every level here is a stack
## frame the server did not choose to spend.
const MAX_DEPTH := 8
## How many items one command may be billed for, and how much of any one of
## them. Both exist because the number came from the client.
const MAX_COST_ITEMS := 32
const MAX_COST_PER_ITEM := 1000000
const MAX_ID := 100000000
const MAX_COUNT := 64

## Fields a client may send that name a check to skip. They are refused
## outright rather than ignored: a client that can *ask* to skip validation has
## learned that validation is optional, and the day some future field of the
## same name is honoured is the day that client is right.
const BYPASS_FIELDS := ["ignore_reach", "ignore_ownership", "ignore_rate",
	"ignore_cost", "bypass", "admin", "trusted", "no_check"]

## How far from a player's own position they may build, in metres. Precision
## mode does not extend it: if you can measure to a millimetre you still have to
## walk there.
const MAX_REACH := 12.0
## Hard cap, independent of any reach check, so a bug in a cursor cannot let
## someone build into unloaded space.
const MAX_WORLD_EXTENT := 100000.0
## The largest vertical excursion that survives the extent check.
const MAX_WORLD_HEIGHT := 4096.0
## Top speed the server will believe, in m/s. Faster than a sprint, slower
## than a vehicle nobody has built yet.
const MAX_SPEED := 40.0
## The longest tick a client may claim. The movement clamp is `MAX_SPEED * dt`,
## so an unclamped `dt` is a teleport: one packet claiming 1000 s of movement
## buys 40 km, and the reach check that depends on the server's belief about
## where a player is is worth nothing.
const MAX_TICK := 0.25

var _tokens := {}          # peer id -> float
var _last_refill := {}     # peer id -> seconds
## The second bucket: command budget spent on being wrong. See
## `REFUSE_TOKENS_PER_SECOND`.
var _refuse_tokens := {}   # peer id -> float
var _refuse_refill := {}   # peer id -> seconds
var _sessions := {}        # peer id -> {"name": String, "position": Vector3, "revoked": bool}
var _owned := {}           # node id -> peer id
var _ledger := {}          # peer id -> {item_id: int}
var _sequences := {}       # peer id -> NetProtocol.Sequence
var _log: Array[Dictionary] = []
var _now := 0.0
var _rejected := 0
var _accepted := 0
var _replays := 0
var _gaps := 0
## The server's own price list, if one has been installed. See `set_pricer`.
var _pricer: Callable = Callable()
## peer id -> {"sent": int, "refused": int}
var _tally := {}


func _init() -> void:
	pass


# --- session lifecycle ------------------------------------------------------

## A peer completed the handshake. Until this is called, `submit` rejects it.
##
## The name is truncated rather than rejected: it is cosmetic, it appears in
## the audit log, and refusing a 4 kB name teaches a client to find the limit
## rather than to keep it short.
func join(peer_id: int, name: String, position: Vector3, now: float) -> bool:
	_sessions[peer_id] = {
		"name": name.substr(0, MAX_NAME),
		"position": position,
		"revoked": false,
		"joined_at": now,
	}
	_tokens[peer_id] = BUCKET_DEPTH
	_last_refill[peer_id] = now
	_refuse_tokens[peer_id] = REFUSE_BUCKET_DEPTH
	_refuse_refill[peer_id] = now
	_sequences[peer_id] = NetProtocol.Sequence.new()
	_tally[peer_id] = {"sent": 0, "refused": 0}
	return true


func leave(peer_id: int) -> void:
	_sessions.erase(peer_id)
	_tokens.erase(peer_id)
	_last_refill.erase(peer_id)
	_refuse_tokens.erase(peer_id)
	_refuse_refill.erase(peer_id)
	# The sequence tracker goes with the session: a peer that leaves and comes
	# back starts a new stream, and replaying the old one across the gap is
	# not something the new session should inherit.
	_sequences.erase(peer_id)
	_tally.erase(peer_id)


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
	# MAX_SPEED is faster than a sprint and slower than a teleport cheat, so
	# legitimate movement passes untouched and a teleport is pulled back. The
	# tick is clamped first, because `dt` came from the same client as the
	# position and an unclamped one makes the speed limit meaningless.
	var step := clampf(dt, 0.0, MAX_TICK)
	var limit := MAX_SPEED * step + 0.5
	var moved := position - current
	var accepted := current
	if is_finite(moved.x) and is_finite(moved.y) and is_finite(moved.z) \
			and moved.length() <= limit:
		accepted = position
	accepted.x = clampf(accepted.x, -MAX_WORLD_EXTENT, MAX_WORLD_EXTENT)
	accepted.y = clampf(accepted.y, -MAX_WORLD_HEIGHT, MAX_WORLD_HEIGHT)
	accepted.z = clampf(accepted.z, -MAX_WORLD_EXTENT, MAX_WORLD_EXTENT)
	_sessions[peer_id]["position"] = accepted
	return accepted


# --- economy ----------------------------------------------------------------

## The server's own copy of a player's resources. Never the client's number.
func set_ledger(peer_id: int, items: Dictionary) -> void:
	_ledger[peer_id] = items.duplicate(true)


## A copy, not the ledger itself.
##
## `Dictionary` is a reference type in GDScript, so returning the stored
## dictionary hands the caller a handle on it: a snapshot taken before a
## charge was changed by that charge, and the refund below restored a ledger
## that had already been debited.
func ledger_of(peer_id: int) -> Dictionary:
	var l: Dictionary = _ledger.get(peer_id, {})
	return l.duplicate(true)


## What the peer actually has after a charge, for the server to compare a
## client prediction against.
##
## It re-checks what it is about to subtract rather than trusting the caller.
## `charge` is public, it is the one place a number becomes money, and the
## failure it has to refuse is the cheapest exploit in the file: a cost of -5
## is arithmetically a credit, so a server that only checked affordability
## would hand out resources to anyone who asked nicely.
func charge(peer_id: int, cost: Dictionary) -> bool:
	var l: Dictionary = _ledger.get(peer_id, {}).duplicate(true)
	for item in cost:
		if not _is_int(cost[item]) or int(cost[item]) <= 0:
			return false
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
## `ok == false` means the server changed nothing at all -- not the world, and
## not the ledger.
##
## `apply` is the closure that performs the real mutation against the server's
## own world. It is only ever called after every check has passed, and it
## reports failure the same way everything else here does: return a Dictionary
## with `"ok": false` and a reason. A handler that returns such a dictionary
## after having charged the player is rolled back, because a player who paid
## for a motor that was not built has no way to get the money back and no way
## to prove it happened.
func submit(peer_id: int, command: Variant, apply: Callable) -> Dictionary:
	var fail := func(reason: String) -> Dictionary:
		_rejected += 1
		_count_refusal(peer_id)
		_record(peer_id, command, false, reason)
		return {"ok": false, "reason": reason, "result": null, "peer": peer_id}

	# 0. the command itself
	if not (command is Dictionary):
		return fail.call("command is not a dictionary")
	var cmd: Dictionary = command
	var op := String(cmd.get("op", ""))
	for field in BYPASS_FIELDS:
		if cmd.has(field):
			# Refused, not ignored. A server that quietly drops the field has
			# taught the client that the field exists.
			return fail.call("'%s' is not something a client may ask for" % field)
	if not allowed_ops().has(op):
		return fail.call("unknown op '%s'" % op)

	# 1. session
	if not is_joined(peer_id):
		return fail.call("peer %d is not in a valid session" % peer_id)

	# 2. rate limiting, twice, and *before* the payload is looked at. The
	# ordinary bucket bounds how much a peer can build; the second one bounds
	# how much of the server's time it can spend on commands that are going to
	# be refused. Rate limiting after the schema check would be no rate limit at
	# all for the cheapest attack there is, which is the one where every packet
	# is malformed.
	_refill(peer_id)
	_refill_refuse(peer_id)
	if float(_tokens.get(peer_id, 0.0)) < 1.0:
		return fail.call("rate limited")
	if float(_refuse_tokens.get(peer_id, 0.0)) < 1.0:
		return fail.call("rate limited: too many refused commands")
	_tokens[peer_id] = float(_tokens[peer_id]) - 1.0
	_refuse_tokens[peer_id] = float(_refuse_tokens[peer_id]) - 1.0

	# 3. nesting depth, before anything walks the payload. A checker that
	# recurses is a stack the client chooses the depth of.
	if _depth(cmd, 0) > MAX_DEPTH:
		return fail.call("payload nests deeper than %d levels" % MAX_DEPTH)

	# 4. schema -- after the checks that do not read fields, and before every
	# check that does, because they read them as the types they should be.
	var shape := _check_shape(op, cmd)
	if not bool(shape["ok"]):
		return fail.call(String(shape["reason"]))

	# 5. economy. The price is the server's. When a pricer is installed its
	# figure replaces whatever the client claimed, and a client whose claim
	# disagrees is refused rather than quietly corrected -- a client that is
	# wrong about the price is a client running a different build, and that
	# is worth knowing about rather than papering over.
	var quoted: Dictionary = cmd.get("cost", {})
	var priced := _price(op, cmd)
	if not priced.is_empty():
		if not quoted.is_empty() and not _same_cost(quoted, priced):
			return fail.call("price mismatch: the server charges %s, the "
				% [JSON.stringify(priced)] + "client sent %s"
				% JSON.stringify(quoted))
		quoted = priced
	var cost: Dictionary = quoted
	if not cost.is_empty() and not can_afford(peer_id, cost):
		return fail.call("insufficient resources")

	# 6. ownership, for every node the op touches. Zero is a node like any
	# other; it used to be skipped on the assumption that it meant "none", which
	# meant `{"op":"remove","node":0}` never reached the ownership check.
	for field in ["node", "a", "b", "entity"]:
		if not cmd.has(field):
			continue
		var id := int(cmd[field])
		if not may_modify(peer_id, id):
			return fail.call("node %d belongs to peer %d" % [id, owner_of(id)])

	# 7. reach
	if cmd.has("position"):
		var p: Vector3 = cmd["position"]
		var origin := peer_position(peer_id)
		if origin.distance_to(p) > MAX_REACH:
			return fail.call("out of reach: %.1f m away (limit %.1f)" % [
				origin.distance_to(p), MAX_REACH])

	# 8. a handler, before the charge rather than after it. Without this a
	# command with a dead closure still succeeded: the player was billed, the
	# result was null, and `ok` was true. A server with no handler for an op
	# has a bug in it, and the fix is to say so rather than to take the money.
	if not apply.is_valid():
		return fail.call("no handler for op '%s'" % op)

	# Everything passed. Now, and only now, does the world change -- and the
	# charge and the mutation are one event or neither.
	var ledger_before: Dictionary = ledger_of(peer_id)
	if not cost.is_empty() and not charge(peer_id, cost):
		return fail.call("insufficient resources")
	var result: Variant = apply.call(cmd)
	var applied := _handler_succeeded(result)
	if not applied:
		if not cost.is_empty():
			# The mutation failed, so the payment did not happen. Restoring the
			# whole ledger rather than re-adding the cost keeps this correct even
			# if a handler moved something else out of it.
			set_ledger(peer_id, ledger_before)
		return fail.call(_handler_reason(result))
	_accepted += 1
	_count_sent(peer_id)
	_record(peer_id, command, true, "")
	return {"ok": true, "reason": "", "result": result, "peer": peer_id}


# --- ordering and replay ----------------------------------------------------

## Submit a command that arrived from the wire, with the sequence number the
## client put on it.
##
## `submit` is the trusted in-process entry point: the host, or a caller that
## has already sequenced the command. This one is what a peer on a socket goes
## through, and it adds the rule that makes ordering mean anything -- a
## sequence number that is not newer than the last one this peer got through
## is a replay, not a command.
##
## A *gap* is refused rather than tolerated. `NetProtocol.Sequence` alone
## reports a gap and carries on, which is right for a stream of observations;
## it is wrong for a stream of mutations. "Place a motor" and "connect the wire
## to it" only mean anything in order, so a lost command in the middle means
## the server and the client no longer agree about the world, and the honest
## response is to say so and let the next snapshot resynchronise them. The
## tracker still advances, so one gap does not wedge the peer's stream
## forever.
func submit_sequenced(peer_id: int, seq: int, command: Variant,
		apply: Callable) -> Dictionary:
	var tracker: NetProtocol.Sequence = _sequences.get(peer_id, null)
	if tracker == null:
		tracker = NetProtocol.Sequence.new()
		_sequences[peer_id] = tracker
	var fail := func(reason: String) -> Dictionary:
		_rejected += 1
		_count_refusal(peer_id)
		_record(peer_id, command, false, reason)
		return {"ok": false, "reason": reason, "result": null, "peer": peer_id}

	if seq < 0:
		return fail.call("negative sequence number")
	if seq <= tracker.last_seen:
		_replays += 1
		return fail.call("replayed: sequence %d is not newer than %d"
			% [seq, tracker.last_seen])
	var gap := seq - tracker.last_seen - 1
	if gap > 0:
		_gaps += gap
		# Advance so the peer is not permanently wedged, but do not run the
		# command: the world state it assumed may never have been built.
		tracker.last_seen = seq
		return fail.call("sequence gap: %d message(s) lost before %d"
			% [gap, seq])
	var r := submit(peer_id, command, apply)
	if bool(r["ok"]):
		tracker.last_seen = seq
		tracker.accepted += 1
	else:
		# A refused command still consumed its slot on the wire. Not counting
		# it would let a peer re-send a refused command under a fresh number
		# for ever, which is what the second token bucket is for but not what
		# it should have to be relied on for.
		tracker.last_seen = seq
		tracker.rejected += 1
	return r


## What this peer's stream looks like: how far it has got, how much was lost,
## how much was replayed.
func sequence_stats(peer_id: int) -> Dictionary:
	var tracker: NetProtocol.Sequence = _sequences.get(peer_id, null)
	var out := {"last_seen": -1, "gaps": 0, "accepted": 0, "rejected": 0,
		"in_order": true, "replays": _replays}
	if tracker != null:
		var s := tracker.stats()
		for k in s:
			out[k] = s[k]
	out["gaps"] = int(out["gaps"]) + _gaps
	out["in_order"] = int(out["gaps"]) == 0
	return out


func replay_count() -> int:
	return _replays


func gap_count() -> int:
	return _gaps


## The refuse-side token bucket. See `REFUSE_TOKENS_PER_SECOND`.
func _refill_refuse(peer_id: int) -> void:
	var t := float(_refuse_refill.get(peer_id, _now))
	if _now > t:
		_refuse_tokens[peer_id] = minf(REFUSE_BUCKET_DEPTH,
			float(_refuse_tokens.get(peer_id, REFUSE_BUCKET_DEPTH))
			+ (_now - t) * REFUSE_TOKENS_PER_SECOND)
		_refuse_refill[peer_id] = _now


func _count_sent(peer_id: int) -> void:
	var t: Dictionary = _tally.get(peer_id, {"sent": 0, "refused": 0})
	t["sent"] = int(t["sent"]) + 1
	_tally[peer_id] = t


func _count_refusal(peer_id: int) -> void:
	var t: Dictionary = _tally.get(peer_id, {"sent": 0, "refused": 0})
	t["refused"] = int(t["refused"]) + 1
	_tally[peer_id] = t


## What this peer has sent, and how much of it was refused.
##
## A peer above `GRIEF_THRESHOLD` is not banned -- that is the operator's
## call -- but the number is here so an operator can be told rather than left
## to read a log.
func grief_report() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for peer in _tally:
		var t: Dictionary = _tally[peer]
		var sent := int(t["sent"]) + int(t["refused"])
		if sent == 0:
			continue
		var share := float(t["refused"]) / float(sent)
		if share < GRIEF_THRESHOLD:
			continue
		out.append({"peer": int(peer), "sent": sent,
			"refused": int(t["refused"]), "refusal_share": share})
	return out


## Did the mutation this command describes actually happen?
##
## A handler that returns a Dictionary saying `ok: false` did not. Anything
## else -- a plain result, a Dictionary with no `ok`, null for an op that has
## nothing to return -- counts as done, because the authority validates the
## command, not the handler's opinion of itself.
func _handler_succeeded(result: Variant) -> bool:
	if result is Dictionary:
		var d: Dictionary = result
		if d.has("ok"):
			return bool(d["ok"])
	return true


func _handler_reason(result: Variant) -> String:
	if result is Dictionary:
		var d: Dictionary = result
		if d.has("ok") and not bool(d["ok"]):
			var why := String(d.get("reason", ""))
			if not why.is_empty():
				return why
	return "the world refused the change"


## Every field the op knows about, present and well-typed.
##
## Returns `{"ok": bool, "reason": String}`. Required fields must be present;
## optional ones must be absent or correct. A present-but-unknown field is
## accepted: adding one must not break an older server.
func _check_shape(op: String, cmd: Dictionary) -> Dictionary:
	var spec: Dictionary = NetProtocol.MESSAGES[op]
	var required: Dictionary = spec["required"]
	var optional: Dictionary = spec["optional"]
	for field in required:
		if not cmd.has(field) or cmd[field] == null:
			return {"ok": false,
				"reason": "op '%s' requires '%s'" % [op, field]}
		var bad := _check_value(field, cmd[field], String(required[field]))
		if not bad.is_empty():
			return {"ok": false,
				"reason": "op '%s' field '%s' %s" % [op, field, bad]}
	for field in optional:
		if not cmd.has(field) or cmd[field] == null:
			continue
		var bad2 := _check_value(field, cmd[field], String(optional[field]))
		if not bad2.is_empty():
			return {"ok": false,
				"reason": "op '%s' field '%s' %s" % [op, field, bad2]}
	return {"ok": true, "reason": ""}


## A complaint about one value, or "" if it is fine.
func _check_value(field: String, value: Variant, kind: String) -> String:
	match kind:
		"name", "text":
			var cap := MAX_NAME if kind == "name" else MAX_TEXT
			if not (value is String or value is StringName):
				return "must be a string"
			var s := String(value)
			if s.is_empty():
				return "must not be empty"
			if s.length() > cap:
				return "must be at most %d characters" % cap
		"id", "int":
			if not _is_int(value):
				return "must be an integer"
			var n := int(value)
			if n < 0 or n > MAX_ID:
				return "must be between 0 and %d" % MAX_ID
		"count":
			if not _is_int(value):
				return "must be an integer"
			if int(value) < 1 or int(value) > MAX_COUNT:
				return "must be between 1 and %d" % MAX_COUNT
		"flag":
			if not (value is bool):
				return "must be true or false"
		"vector":
			if not (value is Vector3):
				return "must be a position"
			var p: Vector3 = value
			if not (is_finite(p.x) and is_finite(p.y) and is_finite(p.z)):
				return "must be a finite position"
			if absf(p.x) > MAX_WORLD_EXTENT or absf(p.z) > MAX_WORLD_EXTENT \
					or absf(p.y) > MAX_WORLD_HEIGHT:
				return "is outside the world"
		"angle":
			if not (value is int or value is float):
				return "must be a number"
			if not is_finite(float(value)):
				return "must be a finite number"
			if absf(float(value)) > TAU * 8.0:
				return "is not a rotation"
		"level":
			if _is_int(value):
				if int(value) < 0 or int(value) > 3:
					return "must be between 0 and 3"
			elif not (value is String or value is StringName):
				return "must be a level"
			elif String(value).is_empty():
				return "must not be empty"
		"cost":
			var complaint := _check_cost(value)
			if not complaint.is_empty():
				return complaint
		_:
			return "is a field this op does not define"
	return ""


## A cost is the client saying what it expects to be charged. It cannot be
## allowed to be a shape that charges something other than what it says.
##
## The two exploits a bounds check alone does not catch: a negative amount,
## which `charge` happily applies as a *credit* -- `{"cost": {"iron": -5}}`
## is a money printer -- and an empty cost, which is simply "build it for
## free". The second one is what `set_pricer` exists to close: until the
## server knows what things cost, the client's own figure is the only one
## there is, and the honest thing is to say so rather than to check it
## carefully and believe it anyway.
func _check_cost(value: Variant) -> String:
	if not (value is Dictionary):
		return "must be a dictionary"
	var d: Dictionary = value
	if d.size() > MAX_COST_ITEMS:
		return "names too many items"
	for item in d:
		if not (item is String or item is StringName):
			return "must be named by strings"
		var name := String(item)
		if name.is_empty() or name.length() > MAX_NAME:
			return "names an unusable item"
		var amount: Variant = d[item]
		if not _is_int(amount):
			return "must be whole numbers"
		if int(amount) <= 0:
			# A negative cost is not a discount; `charge` would subtract it.
			return "must be positive"
		if int(amount) > MAX_COST_PER_ITEM:
			return "is implausibly large"
	return ""


# --- pricing ----------------------------------------------------------------

## Install the server's own price list: `pricer(op: String, command:
## Dictionary) -> {item: count}`. Returns what the command costs here, or an
## empty Dictionary for something free.
##
## This is the difference between a server that trusts a client's arithmetic
## and a server that has arithmetic of its own. Before it existed the only
## number in the system came from the client, so `{"cost": {}}` built a motor
## for nothing: the ledger was authoritative about *whether* the player could
## pay, and not at all about *how much* it was.
##
## With a pricer installed the client's figure is a claim to be checked rather
## than a figure to be charged. A client that sends the right price is never
## penalised for it, and one that sends the wrong one is refused -- which is
## also how a build mismatch shows up.
func set_pricer(pricer: Callable) -> void:
	_pricer = pricer


func has_pricer() -> bool:
	return _pricer.is_valid()


func _price(op: String, cmd: Dictionary) -> Dictionary:
	if not _pricer.is_valid():
		return {}
	var v: Variant = _pricer.call(op, cmd)
	if not (v is Dictionary):
		# A pricer that answers with something else is a bug in the server,
		# and it must not be read as "free".
		push_error("[net] pricer for '%s' did not return a dictionary" % op)
		return {}
	var priced: Dictionary = v
	if priced.is_empty():
		return {}
	var complaint := _check_cost(priced)
	if not complaint.is_empty():
		push_error("[net] pricer for '%s' returned an unusable cost: %s"
			% [op, complaint])
		return {}
	return priced


## Do two bills say the same thing?
##
## Compared key by key rather than with `==`: `Dictionary` equality in
## GDScript is structural but its exact behaviour across engine versions is
## not something a security check should be resting on.
func _same_cost(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for item in a:
		if not b.has(item):
			return false
		if int(a[item]) != int(b[item]):
			return false
	return true


## How deeply a payload nests, so the checkers do not have to trust it.
func _depth(value: Variant, level: int) -> int:
	if level > 64:
		# A cycle, or a structure deep enough that counting further is
		# pointless. Either way this is not a command.
		return level
	if value is Dictionary:
		var deepest := level
		for k in value:
			deepest = maxi(deepest, _depth(value[k], level + 1))
			if deepest > 4096:
				return deepest
		return deepest
	if value is Array:
		var deepest2 := level
		for v in value:
			deepest2 = maxi(deepest2, _depth(v, level + 1))
			if deepest2 > 4096:
				return deepest2
		return deepest2
	return level


## An integer, or a float that is exactly an integer.
##
## JSON has one number type, so a peer that encodes `{"node": 5}` as `5.0`
## is not attacking anything -- but `5.5`, and `NaN`, and a String, are, and
## `int()` alone tells them apart only by accident.
func _is_int(value: Variant) -> bool:
	if value is int:
		return true
	if value is float:
		var f := float(value)
		return is_finite(f) and is_equal_approx(f, roundf(f)) \
			and absf(f) < 9.0e15
	return false


func _record(peer_id: int, command: Variant, ok: bool, reason: String) -> void:
	_log.append({
		"peer": peer_id,
		"op": String(command.get("op", "")) if command is Dictionary else "?",
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
