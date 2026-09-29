class_name NetProtocol
extends RefCounted
## The client/server message contract.
##
## `NetAuthority` decides whether a command is *allowed*. This file defines what
## a message *is* -- the envelope, the directions, the field requirements, the
## ordering rules -- so that both ends are written against the same table
## rather than against each other's guesses.
##
## Three properties the envelope buys, each of which is a bug without it:
##
##   * **Version.** A client and a server from different builds must fail
##     loudly and specifically, not by misinterpreting a field. `version` is
##     the first thing checked and a mismatch is never retried.
##
##   * **Sequence numbers.** Every message carries a per-sender `seq`. A gap
##     means something was lost, and the receiver can say *what* rather than
##     silently simulating a world that never existed. Commands are not
##     reordered, because "place a motor" then "connect the wire" is not the
##     same as the reverse.
##
##   * **One direction of authority.** A client may only send CLIENT_TO_SERVER
##     messages, and only of the kinds listed as requests. There is no message
##     a client can send that means "the world is now this", because that is
##     the message that makes client-authoritative bugs possible. Server ->
##     client messages are *derived* from server state and are never echoed
##     back as instructions.

## Bump when a message's shape changes incompatibly. The handshake refuses a
## mismatch rather than negotiating, because a half-negotiated protocol is how
## you get a client that places a motor inside a wall.
const VERSION := 1

## Direction of travel. Enforced, not documentation.
const CLIENT_TO_SERVER := "c2s"
const SERVER_TO_CLIENT := "s2c"
const SERVER_BROADCAST := "broadcast"

## The envelope's required fields, in order. Every message carries all of them.
const ENVELOPE := ["v", "t", "from", "to", "seq", "op", "payload"]

# --- the message table ------------------------------------------------------

## Every message, what it may carry, and who may send it.
##
## `fields` are required inside `payload`. `optional` may be present. A client
## that sends an unknown field is fine -- adding one must not break an older
## server -- but a client that omits a required one is refused, which is what
## keeps a message from being half-understood.
const MESSAGES := {
	# --- client to server: requests ---
	"hello": {
		"dir": CLIENT_TO_SERVER, "kind": "request",
		"fields": ["name", "protocol"], "optional": ["position"],
		"doc": "handshake. The first thing a client sends, and the only thing "
			+ "it may send before the server has accepted it.",
	},
	"place": {
		"dir": CLIENT_TO_SERVER, "kind": "request",
		"fields": ["component", "position"],
		"optional": ["rotation_y", "cost", "interaction_level"],
		"doc": "place a component. The server re-derives reach and ownership.",
	},
	"remove": {
		"dir": CLIENT_TO_SERVER, "kind": "request",
		"fields": ["node"], "optional": [],
		"doc": "dismantle a component the sender owns.",
	},
	"connect": {
		"dir": CLIENT_TO_SERVER, "kind": "request",
		"fields": ["a", "a_port", "b", "b_port"], "optional": ["cost"],
		"doc": "join two ports. Both ends are ownership-checked.",
	},
	"disconnect": {
		"dir": CLIENT_TO_SERVER, "kind": "request",
		"fields": ["edge"], "optional": [],
		"doc": "break a connection.",
	},
	"manufacture": {
		"dir": CLIENT_TO_SERVER, "kind": "request",
		"fields": ["component"], "optional": ["cost", "count"],
		"doc": "manufacture a component. Charged from the server's ledger.",
	},
	"operate": {
		"dir": CLIENT_TO_SERVER, "kind": "request",
		"fields": ["node"], "optional": ["enabled"],
		"doc": "toggle or adjust a machine the sender owns.",
	},
	"capture_blueprint": {
		"dir": CLIENT_TO_SERVER, "kind": "request",
		"fields": ["name", "nodes"], "optional": [],
		"doc": "save a build the sender owns as a reusable blueprint.",
	},
	"place_blueprint": {
		"dir": CLIENT_TO_SERVER, "kind": "request",
		"fields": ["blueprint", "position"], "optional": ["rotation_y"],
		"doc": "rebuild a blueprint at a position the sender can reach.",
	},
	# --- server to client: derived state, never instructions ---
	"welcome": {
		"dir": SERVER_TO_CLIENT, "kind": "state",
		"fields": ["peer", "protocol", "world_version"], "optional": [],
		"doc": "handshake accepted. Carries the world version so the client "
			+ "can tell whether its cached snapshot is usable.",
	},
	"snapshot": {
		"dir": SERVER_TO_CLIENT, "kind": "state",
		"fields": ["nodes", "base_seq"], "optional": ["players"],
		"doc": "server-derived world state. The client renders it and does "
			+ "not modify it.",
	},
	"delta": {
		"dir": SERVER_TO_CLIENT, "kind": "state",
		"fields": ["changes", "base_seq"], "optional": [],
		"doc": "an incremental snapshot. Same rule: derived, not authoritative.",
	},
	"ack": {
		"dir": SERVER_TO_CLIENT, "kind": "state",
		"fields": ["seq", "accepted", "reason"], "optional": [],
		"doc": "the outcome of a request, keyed by its sequence number.",
	},
	"reject": {
		"dir": SERVER_TO_CLIENT, "kind": "state",
		"fields": ["seq", "reason", "rule"], "optional": [],
		"doc": "a refusal, naming the rule that refused it so a grief report "
			+ "and a bug report are distinguishable.",
	},
	"broadcast": {
		"dir": SERVER_BROADCAST, "kind": "state",
		"fields": ["text"], "optional": [],
		"doc": "chat and world events.",
	},
}


# --- encoding ----------------------------------------------------------------

## Wrap a payload in the envelope. `seq` is assigned by the sender.
static func encode(op: String, from_peer: int, to_peer: int, seq: int,
		payload: Dictionary, dir := CLIENT_TO_SERVER) -> Dictionary:
	return {
		"v": VERSION,
		"t": dir,
		"from": from_peer,
		"to": to_peer,
		"seq": seq,
		"op": op,
		"payload": payload.duplicate(true),
	}


## Validate a message. Returns `{"ok": bool, "reason": String, "rule": String}`.
## `rule` names the check that failed, so the rejection the client sees can say
## *why* rather than just *no*.
##
## `expect_dir` is what the receiver is: a server passes CLIENT_TO_SERVER, so
## a client trying to send a state message is refused before anything looks at
## the payload.
static func validate(message: Variant, expect_dir: String) -> Dictionary:
	var fail := func(rule: String, reason: String) -> Dictionary:
		return {"ok": false, "reason": reason, "rule": rule}

	if not (message is Dictionary):
		return {"ok": false, "reason": "not a dictionary", "rule": "envelope"}
	var m: Dictionary = message
	for field in ENVELOPE:
		if not m.has(field):
			return {"ok": false,
				"reason": "missing envelope field '%s'" % field,
				"rule": "envelope"}
	if int(m["v"]) != VERSION:
		# Never retried, never negotiated. A protocol mismatch is a
		# configuration problem and pretending otherwise hides it.
		return {"ok": false,
			"reason": "protocol version %d, this end speaks %d" \
				% [int(m["v"]), VERSION],
			"rule": "version"}
	var op := String(m["op"])
	if not MESSAGES.has(op):
		return {"ok": false, "reason": "unknown op '%s'" % op, "rule": "op"}
	var spec: Dictionary = MESSAGES[op]
	var dir := String(m["t"])
	if dir != String(spec["dir"]):
		return {"ok": false,
			"reason": "op '%s' travels %s, not %s" % [op, spec["dir"], dir],
			"rule": "direction"}
	if dir != expect_dir:
		return {"ok": false,
			"reason": "a %s does not accept %s" % [expect_dir, dir],
			"rule": "direction"}
	if int(m["seq"]) < 0:
		return {"ok": false, "reason": "negative sequence number",
			"rule": "ordering"}
	var payload: Variant = m["payload"]
	if not (payload is Dictionary):
		return {"ok": false, "reason": "payload is not a dictionary",
			"rule": "envelope"}
	for field in spec["fields"]:
		if not (payload as Dictionary).has(field) \
				or (payload as Dictionary)[field] == null:
			return {"ok": false,
				"reason": "op '%s' requires payload field '%s'" % [op, field],
				"rule": "schema"}
	# Optional fields that are present must still be the right shape. A
	# message with `"cost": "free"` is not a message with a free cost.
	var cost: Variant = (payload as Dictionary).get("cost", null)
	if cost != null and not (cost is Dictionary):
		return {"ok": false, "reason": "cost must be a dictionary",
			"rule": "schema"}
	return {"ok": true, "reason": "", "rule": ""}


## Per-sender sequence tracking. One instance per peer per end.
##
## The rule this enforces: a client may have any number of requests in flight,
## but they are applied in the order they were sent. Without a per-sender
## counter there is no way to tell a reordered delivery from a lost one, and
## the only safe response to both is to drop the connection.
class Sequence:
	var last_seen := -1
	var gaps := 0
	var accepted := 0
	var rejected := 0

	## Record an incoming sequence number. Returns `{"ok": bool, "gap": int,
	## "reason": String}`. A gap is reported, not fatal: UDP can reorder one
	## packet and the next one arriving intact is normal.
	func accept(seq: int) -> Dictionary:
		if seq <= last_seen:
			return {"ok": false, "gap": 0,
				"reason": "sequence %d is not newer than %d" % [seq, last_seen]}
		var gap := seq - last_seen - 1
		if gap > 0:
			gaps += gap
		last_seen = seq
		return {"ok": true, "gap": gap, "reason": ""}

	func stats() -> Dictionary:
		return {"last_seen": last_seen, "gaps": gaps,
			"accepted": accepted, "rejected": rejected, "in_order": gaps == 0}


# --- documentation helpers ---------------------------------------------------

## Every op, for the docs and for a UI that lists what a client can do.
static func ops() -> Array[String]:
	var out: Array[String] = []
	for k in MESSAGES:
		out.append(String(k))
	out.sort()
	return out


static func ops_in_direction(dir: String) -> Array[String]:
	var out: Array[String] = []
	for k in MESSAGES:
		if String((MESSAGES[k] as Dictionary)["dir"]) == dir:
			out.append(String(k))
	out.sort()
	return out


static func spec_of(op: String) -> Dictionary:
	return MESSAGES.get(op, {})


## The table rendered as text, for ARCHITECTURE.md and for a `--dump-protocol`
## style debug flag. Keeping it generated means the document cannot describe a
## protocol the code does not speak.
static func describe() -> String:
	var lines := PackedStringArray()
	lines.append("NetProtocol v%d" % VERSION)
	lines.append("envelope: %s" % ", ".join(ENVELOPE))
	for op in ops():
		var spec: Dictionary = MESSAGES[op]
		lines.append("")
		lines.append("  %-18s %s/%s" % [op, spec["dir"], spec["kind"]])
		lines.append("    required: %s" % ", ".join(spec["fields"]))
		var opt: Array = spec["optional"]
		if not opt.is_empty():
			lines.append("    optional: %s" % ", ".join(opt))
		lines.append("    %s" % spec["doc"])
	return "\n".join(lines)
