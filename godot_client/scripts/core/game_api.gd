class_name GameApi
extends RefCounted
## The one door between systems.
##
## The failure mode this exists to prevent:
##
##     NPC -> writes voxel data -> mutates the inventory -> triggers a save
##
## Each arrow is a private field on a class the NPC was never meant to know
## about, and the chain works until someone reorders the tick, or a save
## happens mid-write, or the NPC is on the client where none of it is
## authoritative. Then it is three bugs in three systems.
##
## The alternative is that a villager says what it wants and something else
## decides whether it happens. `GameApi` is that something. It is a facade, not
## a god object: it holds references to the owners and forwards to their
## **public** API, and every call that can fail returns a `Result` rather than
## raising. Systems never call each other; they call this.
##
## The rules it enforces, which is the actual value:
##
##   * **Authority.** `authoritative` is true on the server and false on a
##     client. A call that must be authoritative returns `Result.denied()` on
##     a client instead of pretending to work. This is the structural half of
##     "the client says *I want to*; the server decides *if*".
##   * **Reasoning.** Every refusal carries why. A refusal with no reason is
##     a bug report with no repro.
##   * **Accounting.** Every call is counted by system, so a profile can say
##     who is actually talking to the world rather than guessing.

## Set true on the server, false on a client. Everything that mutates the
## world routes through this flag.
var authoritative := true
## Systems the world cannot run without. A failure in one of these is fatal;
## in anything else, the game continues degraded.
const REQUIRED := ["world", "player", "persistence"]

## The registry is a process-wide singleton by design, so the facade reaches
## it statically rather than taking it as a constructor argument. Passing it in
## would be an invitation to build a second registry, which is the exact class
## of bug the registry exists to prevent.
var _counts := {}
var _reasons := {}


# --- results ----------------------------------------------------------------

## The outcome of an API call. GDScript has no exceptions, and inventing a
## silent `-1` is how a refused action becomes a mystery. Every fallible call
## returns one of these.
##
## `ok`, `reason` ("" when fine), and `value` for the answer.
class Result:
	var ok := false
	var reason := ""
	var value: Variant = null

	static func good(v: Variant = null) -> Result:
		var r := Result.new()
		r.ok = true
		r.value = v
		return r

	static func bad(reason: String) -> Result:
		var r := Result.new()
		r.reason = reason
		return r

	## Refused because this end is not allowed to decide. The client half of
	## every mutating call.
	static func denied(what: String) -> Result:
		return bad("'%s' requires the authoritative end" % what)

	## Refused because the owning system is missing or not running. Degradation
	## is explicit rather than a null dereference three frames later.
	static func unavailable(system: String) -> Result:
		return bad("system '%s' is not running" % system)

	func to_dict() -> Dictionary:
		return {"ok": ok, "reason": reason, "value": value}


func _count(caller: String) -> void:
	_counts[caller] = int(_counts.get(caller, 0)) + 1


func _remember(caller: String, reason: String) -> void:
	_reasons[caller] = reason
	SystemRegistry.report_failure("game_api", "%s: %s" % [caller, reason], false)


## Calls made per calling system. The profiler shows this; a villager that
## moved from 40 calls a second to 4000 is a real finding.
func call_counts() -> Dictionary:
	return _counts.duplicate()


# --- the world --------------------------------------------------------------

## Read a block. Always allowed: reading is not mutating, and a client must
## be able to see the world.
func block_at(caller: String, pos: Vector3i) -> Result:
	_count(caller)
	var w := _world()
	if w == null:
		return Result.unavailable("world")
	return Result.good(w.get_content_at(pos))


## Write a block. Authoritative ends only.
func set_block(caller: String, pos: Vector3i, id: int) -> Result:
	_count(caller)
	if not authoritative:
		return Result.denied("set_block")
	var w := _world()
	if w == null:
		return Result.unavailable("world")
	if not w.set_block(pos, id):
		return Result.bad("block at %s refused" % str(pos))
	return Result.good()


## Break a block and yield its drop. One call, because "break" and "give the
## player the thing" must not be two steps someone can do half of.
func break_block(caller: String, pos: Vector3i) -> Result:
	_count(caller)
	if not authoritative:
		return Result.denied("break_block")
	var w := _world()
	if w == null:
		return Result.unavailable("world")
	var id: int = w.get_content_at(pos)
	if id == 0:
		return Result.bad("nothing at %s" % str(pos))
	if not w.break_block(pos):
		return Result.bad("break refused at %s" % str(pos))
	return Result.good(id)


## Load terrain now rather than streaming it. Used on arrival, where a
## not-yet-generated chunk is a hole the player falls through.
func ensure_region(caller: String, focus: Vector3i, radius: int) -> Result:
	_count(caller)
	if not authoritative:
		return Result.denied("ensure_region")
	var w := _world()
	if w == null:
		return Result.unavailable("world")
	return Result.good(w.ensure_region(focus, radius))


# --- the player -------------------------------------------------------------

func player_position(caller: String) -> Result:
	_count(caller)
	var p := _node("player")
	if p == null:
		return Result.unavailable("player")
	return Result.good(p.position)


func player_health(caller: String) -> Result:
	_count(caller)
	var p := _node("player")
	if p == null:
		return Result.unavailable("player")
	return Result.good(float(p.health))


## Give the player an engineering item. Routed through the one inventory, and
## refused when the player has no room rather than silently dropped.
func give_item(caller: String, item: String, n: int = 1) -> Result:
	_count(caller)
	if not authoritative:
		return Result.denied("give_item")
	var inv := _inventory()
	if inv == null:
		return Result.unavailable("persistence")
	if EngItems.has(item):
		var got: int = inv.give_eng(item, n)
		if got <= 0:
			return Result.bad("no room for %d x %s" % [n, item])
		return Result.good(got)
	var bid: int = EngItems.block_id_for(item)
	if bid < 0:
		return Result.bad("unknown item '%s'" % item)
	# `give_block` takes one unit at a time, which is the right shape for a
	# stack-limited container: a request for 400 into 32 slots has to fail
	# partway or not at all, and this is the "not at all" path.
	var placed := 0
	for i in n:
		if int(inv.give_block(bid)) <= 0:
			break
		placed += 1
	if placed <= 0:
		return Result.bad("no room for %d x %s" % [n, item])
	return Result.good(placed)


func take_item(caller: String, item: String, n: int = 1) -> Result:
	_count(caller)
	if not authoritative:
		return Result.denied("take_item")
	var inv := _inventory()
	if inv == null:
		return Result.unavailable("persistence")
	if EngItems.has(item):
		return Result.good(inv.consume_eng(item, n))
	var bid := EngItems.block_id_for(item)
	if bid < 0:
		return Result.bad("unknown item '%s'" % item)
	return Result.good(inv.consume_block(bid, n))


func count_item(caller: String, item: String) -> Result:
	_count(caller)
	var inv := _inventory()
	if inv == null:
		return Result.unavailable("persistence")
	if EngItems.has(item):
		return Result.good(inv.count_eng(item))
	var bid := EngItems.block_id_for(item)
	return Result.good(0 if bid < 0 else inv.count_of(bid))


# --- engineering ------------------------------------------------------------

## Manufacture a component and hand it to the player. One call: the charge
## and the grant cannot be separated, or a failure between them eats a
## player's copper and produces nothing.
func manufacture(caller: String, component: String) -> Result:
	_count(caller)
	if not authoritative:
		return Result.denied("manufacture")
	var eng: Object = SystemRegistry.get_owner("engineering")
	if eng == null:
		return Result.unavailable("engineering")
	if not eng.has_method("manufacture"):
		return Result.bad("engineering has no manufacture()")
	var r: Variant = eng.call("manufacture", component)
	if r is Dictionary and not bool((r as Dictionary).get("ok", false)):
		return Result.bad(String((r as Dictionary).get("reason", "refused")))
	return Result.good(r)


## Read a network's live figures, for a HUD or a tool overlay.
func network_state(caller: String, net: int) -> Result:
	_count(caller)
	var eng: Object = SystemRegistry.get_owner("engineering")
	if eng == null:
		return Result.unavailable("engineering")
	var g: Variant = eng.get("graph")
	if g == null:
		return Result.unavailable("engineering")
	return Result.good((g as Object).call("network_state", net))


# --- persistence ------------------------------------------------------------

## Save. Returns a Result rather than a bool, so "the disk is full" and
## "the slot is out of range" are different problems.
func save(caller: String, slot: int) -> Result:
	_count(caller)
	if not authoritative:
		return Result.denied("save")
	var p: Object = SystemRegistry.get_owner("persistence")
	if p == null:
		return Result.unavailable("persistence")
	if not p.has_method("save_to"):
		return Result.bad("persistence has no save_to()")
	var r: Variant = p.call("save_to", slot)
	if r is Dictionary and not bool((r as Dictionary).get("ok", false)):
		_remember(caller, String((r as Dictionary).get("reason", "save failed")))
		return Result.bad(String((r as Dictionary).get("reason", "save failed")))
	return Result.good()


# --- authority --------------------------------------------------------------

## Ask the server to perform something. On a client this is a *request*, not
## an action: the call returns "sent" and the world changes only when the
## server agrees. This is the whole multiplayer contract in one method.
func request(caller: String, op: String, payload: Dictionary) -> Result:
	_count(caller)
	if not authoritative:
		# A client never acts locally. It asks, and the outcome arrives later
		# as an ack. Returning ok here would be the bug this whole class
		# exists to prevent.
		return Result.bad("'%s' queued as a request; awaiting the server" % op)
	var net: Object = SystemRegistry.get_owner("net")
	if net == null:
		return Result.unavailable("net")
	if not net.has_method("submit_local"):
		return Result.bad("net has no submit_local()")
	return Result.good(net.call("submit_local", op, payload))


# --- resolution -------------------------------------------------------------

func _world() -> Object:
	return SystemRegistry.get_owner("world")


func _inventory() -> Object:
	var p: Object = SystemRegistry.get_owner("persistence")
	return p.get("inventory") if p != null else null


func _node(system: String) -> Object:
	return SystemRegistry.get_owner(system)


func last_reasons() -> Dictionary:
	return _reasons.duplicate()
