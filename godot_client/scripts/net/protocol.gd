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
## `required` and `optional` map each payload field to the kind of value it
## must be. A client that sends an unknown field is fine -- adding one must not
## break an older server -- but a client that omits a required one, or sends a
## required one with the wrong type, is refused: a message that is
## half-understood is worse than one that never arrived.
##
## This table is the *only* description of the wire. `NetAuthority` reads its
## op allow-list and its field checks out of here rather than keeping a second
## copy, because two copies of a schema disagree: `disconnect` wanted an `a`
## in one and an `edge` in the other, and the emergent ops existed in only one
## of them, so a client could send a command the server had never heard of.
##
## The kinds are `name`, `text`, `id`, `count`, `flag`, `vector`, `angle`,
## `level`, `cost` and `int` -- see `NetAuthority._check_value`, which is what
## enforces them.
const MESSAGES := {
	# --- client to server: requests ---
	"hello": {
		"dir": CLIENT_TO_SERVER, "kind": "request", "pre_session": true,
		"required": {"name": "name", "protocol": "int"},
		"optional": {"position": "vector"},
		"doc": "handshake. The first thing a client sends, and the only thing "
			+ "it may send before the server has accepted it. Marked "
			+ "pre_session because it is what creates the session, so it "
			+ "cannot itself pass the session check.",
	},
	"place": {
		"dir": CLIENT_TO_SERVER, "kind": "request",
		"required": {"component": "name", "position": "vector"},
		"optional": {"rotation_y": "angle", "cost": "cost",
			"interaction_level": "level"},
		"doc": "place a component. The server re-derives reach and ownership.",
	},
	"remove": {
		"dir": CLIENT_TO_SERVER, "kind": "request",
		"required": {"node": "id"}, "optional": {},
		"doc": "dismantle a component the sender owns.",
	},
	"connect": {
		"dir": CLIENT_TO_SERVER, "kind": "request",
		"required": {"a": "id", "b": "id"},
		"optional": {"a_port": "name", "b_port": "name", "cost": "cost"},
		"doc": "join two ports. Both ends are ownership-checked.",
	},
	"disconnect": {
		"dir": CLIENT_TO_SERVER, "kind": "request",
		"required": {"a": "id"}, "optional": {},
		"doc": "break a connection by its id.",
	},
	"manufacture": {
		"dir": CLIENT_TO_SERVER, "kind": "request",
		"required": {"component": "name"},
		"optional": {"cost": "cost", "count": "count"},
		"doc": "manufacture a component. Priced by the server, charged from "
			+ "the server's ledger.",
	},
	"operate": {
		"dir": CLIENT_TO_SERVER, "kind": "request",
		"required": {"node": "id"},
		"optional": {"enabled": "flag"},
		"doc": "toggle or adjust a machine the sender owns.",
	},
	"set_interaction_level": {
		"dir": CLIENT_TO_SERVER, "kind": "request",
		"required": {"level": "level"}, "optional": {},
		"doc": "choose how much help the cursor gives. Presentation only: "
			+ "precision mode does not extend reach.",
	},
	"capture_blueprint": {
		"dir": CLIENT_TO_SERVER, "kind": "request",
		"required": {"name": "name"}, "optional": {"nodes": "count"},
		"doc": "save a build the sender owns as a reusable blueprint.",
	},
	"place_blueprint": {
		"dir": CLIENT_TO_SERVER, "kind": "request",
		"required": {"blueprint": "name", "position": "vector"},
		"optional": {"rotation_y": "angle", "cost": "cost"},
		"doc": "rebuild a blueprint at a position the sender can reach.",
	},
	# The emergent layer's own mutations. They are on the wire rather than
	# bypassing the authority because a client that could place an entity
	# without a reach check could place one anywhere on the map, and a client
	# that could author a rule without a session check could author one the
	# server never agreed to. Same door as everything else.
	"emergent_place": {
		"dir": CLIENT_TO_SERVER, "kind": "request",
		"required": {"kind": "name", "position": "vector"},
		"optional": {"node": "id"},
		"doc": "place an entity the player can reach.",
	},
	"emergent_remove": {
		"dir": CLIENT_TO_SERVER, "kind": "request",
		"required": {"entity": "id"}, "optional": {},
		"doc": "remove an entity.",
	},
	"emergent_rule": {
		"dir": CLIENT_TO_SERVER, "kind": "request",
		"required": {"text": "text"}, "optional": {},
		"doc": "author a behaviour rule. Parsed and refused on the server if "
			+ "it does not compile.",
	},
	# --- server to client: derived state, never instructions ---
	"welcome": {
		"dir": SERVER_TO_CLIENT, "kind": "state",
		"required": {"peer": "id", "protocol": "int", "world_version": "id"},
		"optional": {},
		"doc": "handshake accepted. Carries the world version so the client "
			+ "can tell whether its cached snapshot is usable.",
	},
	"snapshot": {
		"dir": SERVER_TO_CLIENT, "kind": "state",
		"required": {"nodes": "count", "base_seq": "id"},
		"optional": {"players": "count"},
		"doc": "server-derived world state. The client renders it and does "
			+ "not modify it.",
	},
	"delta": {
		"dir": SERVER_TO_CLIENT, "kind": "state",
		"required": {"changes": "count", "base_seq": "id"}, "optional": {},
		"doc": "an incremental snapshot. Same rule: derived, not authoritative.",
	},
	"ack": {
		"dir": SERVER_TO_CLIENT, "kind": "state",
		"required": {"seq": "id", "accepted": "flag", "reason": "text"},
		"optional": {},
		"doc": "the outcome of a request, keyed by its sequence number.",
	},
	"reject": {
		"dir": SERVER_TO_CLIENT, "kind": "state",
		"required": {"seq": "id", "reason": "text", "rule": "text"},
		"optional": {},
		"doc": "a refusal, naming the rule that refused it so a grief report "
			+ "and a bug report are distinguishable.",
	},
	"broadcast": {
		"dir": SERVER_BROADCAST, "kind": "state",
		"required": {"text": "text"}, "optional": {},
		"doc": "chat and world events.",
	},
}


## Every request a joined client may issue: the protocol's request ops, minus
## the handshake. The handshake is excluded because it is what *creates* the
## session -- asking it to pass a session check is asking it to have already
## arrived.
static func command_ops() -> Array[String]:
	var out: Array[String] = []
	for k in MESSAGES:
		var spec: Dictionary = MESSAGES[k]
		if String(spec["kind"]) != "request":
			continue
		if bool(spec.get("pre_session", false)):
			continue
		out.append(String(k))
	out.sort()
	return out


## The field list, in table order. Derived rather than stored, so the array
## consumers have always read cannot drift from the table they came from.
static func field_names(op: String, group := "required") -> Array[String]:
	var spec: Dictionary = MESSAGES.get(op, {})
	var out: Array[String] = []
	for field in spec.get(group, {}):
		out.append(String(field))
	return out


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
	var p: Dictionary = payload
	for field in spec["required"]:
		if not p.has(field) or p[field] == null:
			return {"ok": false,
				"reason": "op '%s' requires payload field '%s'" % [op, field],
				"rule": "schema"}
	# Optional fields that are present must still be the right shape. A
	# message with `"cost": "free"` is not a message with a free cost.
	#
	# Only the shape is checked here -- "is this a dictionary" -- and not the
	# value, because value checks are the authority's job and it has the
	# world. Two layers that each do one thing is better than one that does
	# half of each.
	for field in spec["optional"]:
		if not p.has(field) or p[field] == null:
			continue
		if String(spec["optional"][field]) == "cost" \
				and not (p[field] is Dictionary):
			return {"ok": false,
				"reason": "op '%s' field '%s' must be a dictionary"
					% [op, field],
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
	var spec: Dictionary = MESSAGES.get(op, {})
	if spec.is_empty():
		return {}
	# The stored form is the two maps; the derived `fields`/`optional` arrays
	# are what callers have always read. Handing back one dictionary with both
	# shapes keeps the table single-sourced without changing what the docs and
	# the tests consume.
	var out := spec.duplicate(true)
	out["fields"] = field_names(op, "required")
	out["optional"] = field_names(op, "optional")
	return out


## The table rendered as text, for ARCHITECTURE.md and for a `--dump-protocol`
## style debug flag. Keeping it generated means the document cannot describe a
## protocol the code does not speak.
static func describe() -> String:
	var lines := PackedStringArray()
	lines.append("NetProtocol v%d" % VERSION)
	lines.append("envelope: %s" % ", ".join(ENVELOPE))
	for op in ops():
		var spec: Dictionary = spec_of(op)
		lines.append("")
		lines.append("  %-22s %s/%s" % [op, spec["dir"], spec["kind"]])
		lines.append("    required: %s" % ", ".join(spec["fields"]))
		var opt: Array = spec["optional"]
		if not opt.is_empty():
			lines.append("    optional: %s" % ", ".join(opt))
		lines.append("    %s" % spec["doc"])
	return "\n".join(lines)
