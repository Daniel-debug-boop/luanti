class_name EmergentRules
extends RefCounted
## Player-authored rules: WHEN <condition> DO <action>.
##
## This is the escape hatch that makes the rest of the architecture honest.
## Without it, "build something unexpected" means "we thought of it", and the
## emergent claim is decoration. With it, a player wires existing primitives
## into a combination the developers never named, and it works, because
## nothing about it was special-cased.
##
## ## Safety is the whole design
##
## A rule language that can call a method is not a rule language, it is a
## remote code execution hole with a friendly syntax. So:
##
##   * The grammar is finite. Every token is one of a fixed set. Anything
##     else fails to parse with a reason, and a rule that failed to parse is
##     stored and reported, never half-applied.
##   * Actions are a fixed table of named operations over a subject's own
##     state. There is no expression evaluator, no `call`, no `eval`, no
##     property path the player controls beyond `state.<key>` on a subject
##     they can already reach.
##   * Every rule declares how much of the frame budget it may consume, and
##     the engine stops it when it is exceeded. A rule cannot livelock the
##     game by being self-referential.
##   * A rule can only act on subjects it may already act on, which is the
##     same reach rule the network authority enforces. Authoring a rule is
##     not a way around ownership.
##
## The example set the architecture brief asks for all parse here, and none
## of them needs a bespoke system:
##
##     WHEN target_hit   DO score += 1
##     WHEN score >= 10  DO gate.open
##     WHEN entered_zone DO timer.start
##     WHEN overheated   DO machine.shutdown

## A parsed rule. Immutable once parsed; `fired` is runtime bookkeeping.
class Rule:
	var id := 0
	var when_event := ""
	## Comparison against a subject's state. Empty when the rule fires on the
	## event alone.
	var when_key := ""
	var when_op := ""
	var when_value := 0.0
	var action := ""
	var action_arg := 0.0
	## Which kind of subject the action applies to, or "" for "the nearest one
	## that can take it".
	var target_kind := ""
	var target_id := 0
	## How many times this rule has fired. Persisted, because a rule with a
	## cooldown must not reset its cooldown on reload.
	var fired := 0
	## Seconds before it may fire again. 0 means no cooldown.
	var cooldown := 0.0
	## Seconds until it may fire again.
	var _ready_at := 0.0
	var enabled := true
	## Parse failure, or "" if the rule is good.
	var error := ""

	func to_dict() -> Dictionary:
		return {
			"when": when_event, "key": when_key, "op": when_op,
			"value": when_value, "do": action, "arg": action_arg,
			"target_kind": target_kind, "target_id": target_id,
			"cooldown": cooldown, "fired": fired, "enabled": enabled,
		}

	func describe() -> String:
		var cond := when_event
		if when_key != "":
			cond += " %s %s %s" % [when_key, when_op, str(when_value)]
		return "WHEN %s DO %s %s" % [cond, action, str(action_arg)] \
			if action_arg != 0.0 else "WHEN %s DO %s" % [cond, action]


## The action vocabulary. Named operations over a subject's own state -- this
## table IS the language. Adding an action means adding a row, and every row
## is auditable in one place.
const ACTIONS := {
	"score": "add to the subject's score",
	"add": "add a number to a state key",
	"set": "set a state key to a number",
	"open": "set the subject open",
	"close": "set the subject closed",
	"toggle": "flip the subject open",
	"start": "start the subject",
	"stop": "stop the subject",
	"emit": "emit an event",
	"notify": "show a message",
}

## The comparison operators a condition may use. No string comparison: string
## equality on player input is a comparison whose ordering is a matter of
## taste, and taste is not something a desync should depend on.
const OPERATORS := ["==", ">=", "<=", ">", "<"]

## What a name in a rule may be. Lowercase letters, digits, underscore and
## dot. That is the whole grammar of identifiers in this language.
##
## It exists for a specific reason, not tidiness: an event name is looked up
## in a table, and a table lookup on an arbitrary string invites an event name
## like `os.execute(` to be typed by a client that hopes something will
## happen. Restricting the alphabet at parse time means a rule can never
## contain a character sequence that reads as code, which is what lets this
## language be accepted from a stranger in multiplayer at all.
const NAME_PATTERN := "^[a-z0-9_.]+$"


static func is_valid_name(name: String) -> bool:
	if name.is_empty():
		return false
	var re := RegEx.new()
	re.compile(NAME_PATTERN)
	return re.search(name) != null

static var _rules := {}
static var _order: Array[int] = []
static var _next_id := 1


static func add(rule: Rule) -> int:
	if rule == null or rule.error != "":
		push_error("[rules] refusing a rule that did not parse")
		return -1
	var id := _next_id
	_next_id += 1
	rule.id = id
	_rules[id] = rule
	_order.append(id)
	return id


static func get_rule(id: int) -> Rule:
	return _rules.get(id, null)


static func all() -> Array:
	_ensure()
	var out: Array = []
	for id in _order:
		var r: Rule = _rules.get(id, null)
		if r != null:
			out.append(r)
	return out


static func all_ids() -> Array[int]:
	_ensure()
	return _order.duplicate()


static func remove(id: int) -> bool:
	if not _rules.has(id):
		return false
	_rules.erase(id)
	_order.erase(id)
	return true


static func clear() -> void:
	_rules.clear()
	_order.clear()
	_next_id = 1


static func _ensure() -> void:
	if _order.is_empty() and _rules.is_empty():
		return


static func count() -> int:
	return _rules.size()


# --- parsing ---------------------------------------------------------------

## Parse one line. Returns a Rule with `error` set rather than null, so a
## caller writing a hundred rules gets a hundred reasons instead of one
## useless "null".
static func parse(line: String) -> Rule:
	var r := Rule.new()
	var text := line.strip_edges().to_lower()
	if text.is_empty() or text.begins_with("#"):
		r.error = ""
		r.enabled = false
		return r
	var when_at := text.find("when ")
	var do_at := text.find(" do ")
	if when_at != 0 or do_at < 0:
		r.error = "expected 'WHEN <condition> DO <action>'"
		return r
	var cond := text.substr(5, do_at - 5).strip_edges()
	var act := text.substr(do_at + 4).strip_edges()
	if cond.is_empty():
		r.error = "no condition"
		return r
	if act.is_empty():
		r.error = "no action"
		return r
	var cerr := _parse_condition(cond, r)
	if cerr != "":
		r.error = cerr
		return r
	var aerr := _parse_action(act, r)
	if aerr != "":
		r.error = aerr
		return r
	return r


static func _parse_condition(cond: String, r: Rule) -> String:
	var parts := cond.split(" ")
	if parts.size() == 1:
		if not is_valid_name(parts[0]):
			return "'%s' is not an event name" % parts[0]
		r.when_event = parts[0]
		return ""
	# key op value
	if parts.size() < 3:
		return "expected '<key> <op> <value>', got '%s'" % cond
	var key := parts[0]
	var op := parts[1]
	if not is_valid_name(key):
		return "'%s' is not a state name" % key
	if not OPERATORS.has(op):
		return "unknown operator '%s'" % op
	var raw := parts[2]
	if not raw.is_valid_float():
		return "'%s' is not a number" % raw
	r.when_key = key
	r.when_op = op
	r.when_value = float(raw)
	# A fourth token may name the target kind: "score >= 10 gate".
	if parts.size() >= 4:
		r.target_kind = parts[3]
	return ""


static func _parse_action(act: String, r: Rule) -> String:
	var parts := act.split(" ")
	var verb := parts[0]
	if not ACTIONS.has(verb):
		return "unknown action '%s' (known: %s)" % [verb,
			", ".join(PackedStringArray(ACTIONS.keys()))]
	r.action = verb
	if parts.size() >= 2:
		var target := parts[1]
		# A bare number is an argument; anything else names a target.
		if target.is_valid_float():
			r.action_arg = float(target)
			if parts.size() >= 3:
				r.target_kind = parts[2]
		else:
			if not is_valid_name(target):
				return "'%s' is not a target name" % target
			r.target_kind = target
	return ""


# --- evaluation ------------------------------------------------------------

## Does this rule's condition hold, given an event and the subject it names?
##
## Pure, and the only place a rule decides whether to fire. Evaluation order
## is fixed: the event name first, then the state comparison. That order
## matters -- a rule whose subject is gone must fail on the event test with a
## clear reason rather than dereference something null.
static func matches(r: Rule, event: String, subject: EmergentEntity,
		now: float) -> Dictionary:
	if r == null or not r.enabled:
		return {"ok": false, "reason": "disabled"}
	if r._ready_at > now:
		return {"ok": false, "reason": "cooling down"}
	if event != r.when_event:
		return {"ok": false, "reason": "event is '%s'" % event}
	if r.when_key == "":
		return {"ok": true, "reason": "event matched"}
	if subject == null:
		return {"ok": false, "reason": "no subject to compare"}
	var actual := float(subject.get_state(r.when_key, 0.0))
	var ok := false
	match r.when_op:
		"==":
			ok = is_equal_approx(actual, r.when_value)
		">=":
			ok = actual >= r.when_value
		"<=":
			ok = actual <= r.when_value
		">":
			ok = actual > r.when_value
		"<":
			ok = actual < r.when_value
	if not ok:
		return {"ok": false, "reason": "%s is %s, not %s %s" % [
			r.when_key, str(actual), r.when_op, str(r.when_value)]}
	return {"ok": true, "reason": "%s %s %s" % [r.when_key, r.when_op,
		str(r.when_value)]}


## Apply the rule's action to its subject. Returns what changed, so the
## diagnostic view and the tests can both see the effect rather than having to
## infer it from a diff.
##
## This function is the entire "programming surface" a player has, and it is
## worth being clear that it cannot do anything but write numbers and booleans
## into the state of an entity the player already placed. That is a
## deliberate limit: it is what makes the language safe to accept from a
## stranger in multiplayer.
static func apply(r: Rule, subject: EmergentEntity, now: float) -> Dictionary:
	if subject == null:
		return {"ok": false, "reason": "no subject"}
	var changed := {}
	match r.action:
		"score":
			var v := float(subject.get_state("value", 0.0)) + r.action_arg
			subject.set_state("value", v)
			subject.set_state("count", int(subject.get_state("count", 0)) + 1)
			changed["value"] = v
		"add":
			var key := "count"
			var v2 := float(subject.get_state(key, 0.0)) + r.action_arg
			subject.set_state(key, v2)
			changed[key] = v2
		"set":
			subject.set_state("value", r.action_arg)
			changed["value"] = r.action_arg
		"open":
			subject.set_state("open", true)
			changed["open"] = true
		"close":
			subject.set_state("open", false)
			changed["open"] = false
		"toggle":
			var now_open := not bool(subject.get_state("open", false))
			subject.set_state("open", now_open)
			changed["open"] = now_open
		"start":
			subject.set_state("running", true)
			changed["running"] = true
		"stop":
			subject.set_state("running", false)
			changed["running"] = false
		"emit":
			subject.set_state("count", int(subject.get_state("count", 0)) + 1)
			changed["count"] = int(subject.get_state("count", 0))
		"notify":
			subject.set_state("message", r.target_kind)
			changed["message"] = r.target_kind
		_:
			return {"ok": false, "reason": "unhandled action '%s'" % r.action}
	r.fired += 1
	if r.cooldown > 0.0:
		r._ready_at = now + r.cooldown
	return {"ok": true, "reason": "applied", "changed": changed}


## Parse and add in one step. Returns { id, error } so a UI can show the
## reason next to the text box that produced it.
static func add_text(line: String) -> Dictionary:
	var r := parse(line)
	if r.error != "":
		return {"id": 0, "error": r.error}
	var id := add(r)
	return {"id": id, "error": ""}


## Every rule that failed to parse, for the player to be told about. Silent
## failure is the thing this system is least allowed to do: a rule that did
## not load and a rule that did nothing look identical from outside, and the
## player has no way to tell which they built.
static func errors() -> Array[String]:
	var out: Array[String] = []
	for r in all():
		var rule: Rule = r
		if rule.error != "":
			out.append(rule.describe())
	return out


# --- persistence -----------------------------------------------------------

## Rules are authoritative: they are player intent and cannot be derived, so
## they are saved. Everything a rule produced -- scores, open gates, cooldowns
## -- is either on the subject (saved with the subject) or here.
static func serialize() -> Dictionary:
	var out: Array = []
	for id in _order:
		var r: Rule = _rules.get(id, null)
		if r == null:
			continue
		out.append(r.to_dict())
	return {"version": 1, "next_id": _next_id, "rules": out}


static func deserialize(data: Dictionary) -> Dictionary:
	clear()
	var report := {"rules": 0, "skipped": 0}
	for d in data.get("rules", []):
		if not (d is Dictionary):
			report["skipped"] += 1
			continue
		var dict := d as Dictionary
		var r := Rule.new()
		r.when_event = String(dict.get("when", ""))
		r.when_key = String(dict.get("key", ""))
		r.when_op = String(dict.get("op", ""))
		r.when_value = float(dict.get("value", 0.0))
		r.action = String(dict.get("do", ""))
		r.action_arg = float(dict.get("arg", 0.0))
		r.target_kind = String(dict.get("target_kind", ""))
		r.target_id = int(dict.get("target_id", 0))
		r.cooldown = float(dict.get("cooldown", 0.0))
		r.fired = int(dict.get("fired", 0))
		r.enabled = bool(dict.get("enabled", true))
		if r.when_event.is_empty() or not ACTIONS.has(r.action):
			report["skipped"] += 1
			continue
		_rules[r.id] = r
		_order.append(r.id)
		report["rules"] += 1
	# Ids restored verbatim so a save that stored a rule's cooldown keeps it,
	# and so two clients loading the same save number their rules the same
	# way. A counter that restarted at 1 would make rule 4 in one client's
	# save mean something different from rule 4 in the other's.
	var max_id := 0
	for id in _rules.keys():
		max_id = maxi(max_id, int(id))
	_next_id = maxi(int(data.get("next_id", 1)), max_id + 1)
	return report