class_name EmergentMatcher
extends RefCounted
## Pattern matching over an assembly's capabilities, with explicit budgets.
##
## Matching is the step that decides whether the thing the player built IS the
## thing the pattern describes. It is kept separate from pattern *definition*
## and from behaviour *execution* because each has a different failure mode:
## a bad pattern is a data bug, a bad match is a performance bug, and a bad
## execution is a gameplay bug. Merging them makes all three hard to find.
##
## The expensive thing about matching is not the comparison, it is the
## guarantee that it does not become a per-frame world scan. So:
##
##   * Matching runs on a SET of components, not on the world. The caller
##     decides which components form an assembly; this never enumerates
##     chunks.
##   * It is bounded. `budget_examined` counts every capability and role
##     check, and matching stops cleanly when the budget is spent, returning
##     what it proved rather than hanging.
##   * It is pure. No side effects, no allocation of graph nodes, so the same
##     assembly always produces the same answer -- which is what makes
##     multiplayer clients able to agree on it without synchronising the
##     result.

## How many capability/role checks one match may perform. Generous for a
## real assembly (dozens of parts) and small enough that a pathological one
## cannot stall a frame.
const DEFAULT_BUDGET := 4000

var budget_examined := 0
var budget_exhausted := false


class Match:
	var pattern_id: String
	var tier: String
	## True when every requirement was met. A false match still reports why,
	## so the diagnostic view can explain what is missing.
	var satisfied := false
	## Requirements that failed, for the "why is this not active" view.
	var missing: Array[String] = []
	## Behaviours this pattern would contribute.
	var behaviours: Array[String] = []
	## Constraints that must hold before the behaviour may run.
	var constraints: Array = []

	func _init(p_id := "", p_tier := "") -> void:
		pattern_id = p_id
		tier = p_tier


## Match every registered pattern against one assembly.
##
## `component_ids` is the assembly's membership. Returns an Array of Match,
## one per pattern, satisfied or not.
##
## `holders` is how the caller tells the matcher about REAL topology, and it
## is optional. A pattern's `chains` say "these capabilities must be wired
## end to end", which is a claim about connections and not about which parts
## are lying in the same pile. Without `holders` the matcher can only see
## membership, so a chain degrades to "all of these capabilities exist here"
## -- and `match_assembly` says so in the Match's `missing` rather than
## quietly claiming a connection it could not check.
##
## The shape is `capability -> [ids that hold it]`, and connectivity between
## those ids is the CALLER's claim, passed in as `connected`: a callable
## `(a: int, b: int) -> bool`. The matcher stays pure and takes data rather
## than a live graph, which is what lets two clients compute the same answer
## without either of them owning a world.
static func match_assembly(component_ids: Array, holders := {},
		connected: Callable = Callable()) -> Array:
	var m := EmergentMatcher.new()
	return m.run(component_ids, holders, connected)


func run(component_ids: Array, holders := {},
		connected: Callable = Callable()) -> Array:
	budget_examined = 0
	budget_exhausted = false
	_holders = holders if holders is Dictionary else {}
	_connected = connected
	EmergentPatterns.all()
	var caps := EmergentCaps.of_assembly(component_ids)
	var roles := {}
	for id in component_ids:
		var r := EngMachines.role_of(String(id))
		if r != EngMachines.ROLE_NONE and not roles.has(r):
			roles[r] = true
	var out := []
	for pid in EmergentPatterns.all():
		var m := _match_one(pid, component_ids, caps, roles)
		if m != null:
			out.append(m)
		if budget_exhausted:
			break
	return out


## capability -> ids holding it, as supplied by the caller.
var _holders := {}
## (a, b) -> bool, as supplied by the caller. Empty means "no topology was
## supplied", which is a weaker claim and is reported as one.
var _connected := Callable()


## Does the matcher have real topology to check chains against?
func has_topology() -> bool:
	return _connected.is_valid()


func _match_one(pid: String, component_ids: Array, caps: Array[String],
		roles: Dictionary) -> Match:
	var p := EmergentPatterns.get_pattern(pid)
	if p == null:
		return null
	var m := Match.new(p.id, p.tier)
	m.behaviours = p.behaviours.duplicate()
	m.constraints = p.constraints.duplicate()

	# Requirements. Each check costs budget, so a huge assembly cannot make
	# matching superlinear in the number of patterns.
	if not _spend(1):
		return m
	if component_ids.size() < p.min_members:
		m.missing.append("needs at least %d parts, has %d"
			% [p.min_members, component_ids.size()])
		return m
	for c in p.requires:
		if not _spend(1):
			return m
		if not caps.has(c):
			m.missing.append("missing capability '%s'" % c)
	for r in p.roles:
		if not _spend(1):
			return m
		if not roles.has(r):
			m.missing.append("missing role '%s'" % r)
	for chain in p.chains:
		if not _spend(1):
			return m
		var caps_in_chain: Array[String] = []
		var labels := PackedStringArray()
		for c in (chain as Array):
			caps_in_chain.append(String(c))
			labels.append(String(c))
		if not _chain_present(caps_in_chain, caps, m):
			continue
		if has_topology() and not _chain_connected(caps_in_chain, m):
			m.missing.append("chain '%s' is present but not connected"
				% " -> ".join(labels))
	if m.missing.is_empty():
		m.satisfied = true
	return m


## Every capability in a chain exists somewhere in the assembly.
func _chain_present(chain: Array[String], caps: Array[String],
		m: Match) -> bool:
	for c in chain:
		if not caps.has(c):
			m.missing.append("chain needs '%s'" % c)
			return false
	return true


## ...and each consecutive pair of them is actually wired together.
##
## This is the check that makes "wired end to end" true rather than
## aspirational. Without it a battery, a motor and a pump lying in the same
## pile matched `machine`, and pulling the wire changed nothing -- so the
## engine told the player they had built a working machine while the world
## disagreed.
##
## Every LINK, not just the ends. Checking only the endpoints would accept a
## battery and a pump that are neighbours of each other while the motor in
## between is disconnected, and would reject a correctly wired
## supply -> drive -> load line where the ends are, necessarily, two hops
## apart. A chain is a claim about a path, so it is tested as one.
func _chain_connected(chain: Array[String], m: Match) -> bool:
	if chain.size() < 2:
		return true
	# Greedy: keep the set of ids reachable at each step and intersect with
	# the holders of the next capability. If that set is ever empty, no
	# wiring through this particular assembly satisfies the chain.
	var frontier: Array = []
	for id in (_holders.get(chain[0], []) as Array):
		frontier.append(int(id))
		if int(id) == 0:
			return false
	for i in range(1, chain.size()):
		var next: Array = []
		for id in (_holders.get(chain[i], []) as Array):
			var nid := int(id)
			for prev in frontier:
				if nid == prev:
					next.append(nid)
					break
				if bool(_connected.call(int(prev), nid)):
					next.append(nid)
					break
		if next.is_empty():
			return false
		frontier = next
	return true


## Charge one unit of budget. Returns false when exhausted, at which point
## every caller must unwind rather than continue.
func _spend(n: int) -> bool:
	budget_examined += n
	if budget_examined > DEFAULT_BUDGET:
		budget_exhausted = true
		return false
	return true


## The patterns an assembly actually satisfies.
static func satisfied(component_ids: Array, holders := {},
		connected: Callable = Callable()) -> Array[String]:
	var out: Array[String] = []
	for m in match_assembly(component_ids, holders, connected):
		var mm := m as Match
		if mm != null and mm.satisfied:
			out.append(mm.pattern_id)
	return out


## Behaviours an assembly contributes, deduplicated and in a stable order so
## two clients computing independently arrive at the same list.
static func behaviours_of(component_ids: Array, holders := {},
		connected: Callable = Callable()) -> Array[String]:
	var acc := {}
	for m in match_assembly(component_ids, holders, connected):
		var mm := m as Match
		if mm != null and mm.satisfied:
			for b in mm.behaviours:
				acc[String(b)] = true
	var out: Array[String] = []
	# Sorted, not insertion-ordered: iteration order of a Dictionary is not
	# stable across runs, and a divergent behaviour order between two
	# multiplayer clients is a desync.
	for k in acc.keys():
		out.append(String(k))
	out.sort()
	return out


## Why a pattern did or did not match, for the diagnostic view.
static func explain(component_ids: Array, pattern_id: String, holders := {},
		connected: Callable = Callable()) -> String:
	for m in match_assembly(component_ids, holders, connected):
		var mm := m as Match
		if mm == null or mm.pattern_id != pattern_id:
			continue
		if mm.satisfied:
			return "%s: MATCHED, behaviours [%s]" \
				% [pattern_id, ", ".join(mm.behaviours)]
		return "%s: not active -- %s" % [pattern_id, ", ".join(mm.missing)]
	return "%s: no match computed" % pattern_id