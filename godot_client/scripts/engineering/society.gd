class_name EngSociety
extends RefCounted
## Where the village and the engineering system meet.
##
## Everything else in `scripts/engineering` is about the player's machines, and
## everything in `scripts/mobs` is about villagers. Without this file the two
## run in parallel and neither knows the other exists: a villager works at the
## same rate whether the player has built a power plant next to them or not.
##
## The coupling is deliberately small and entirely in one direction of
## authority -- the *graph* is the source of truth, and the village reads it.
## A villager standing near a live electrical network draws from it. An
## unpowered villager still works, just slower. That single rule is enough to
## make the player's first generator matter to a system they did not build it
## for, and it costs one pass over the villagers per tick rather than a second
## simulation.
##
## The reverse direction exists too, and is the reason this is a shared
## economy rather than a donation: a network that supplies the village earns
## `wage` into a pool the player collects, scaled by how much power was
## actually delivered. Building for yourself pays; building for the village
## pays differently.

## A villager must be within this many metres of a node on a live network to
## be powered by it. Generous enough that you power a street, not a single
## lamp, but short enough that a village at the other end of the map is not
## secretly running on your generator.
const SUPPLY_RADIUS := 18.0
## Work rate of a villager with no power: they are not standing still, they
## are just slower. Nothing in this system stops a player playing solo.
const UNPOWERED_EFFICIENCY := 0.55
## Watts one powered villager is assumed to consume. One number, honest about
## being an assumption: the point is that a small network serves a few and a
## large one serves a street, not that the figure is measured from a real lamp.
const WATTS_PER_VILLAGER := 45.0
## Fraction of delivered power the village pays back into the wage pool.
const WAGE_RATE := 0.15
## Upper bound on the wage pool, so a server full of power does not pay out
## an unbounded number.
const WAGE_CAP := 100000.0

var wage_pool := 0.0
var total_delivered := 0.0
var powered := 0
var unpowered := 0
var serving_network := 0

var _last_t := 0.0


## Called every frame by the engineering root. `villagers` is the live array of
## Villager nodes; anything that is not a Node3D with a `position` is skipped,
## so a caller can pass a filtered list without pre-cleaning it.
func tick(delta: float, graph: EngGraph, villagers: Array,
		player_positions: Array = []) -> void:
	_last_t += delta
	var live := _live_networks(graph, player_positions)
	powered = 0
	unpowered = 0
	serving_network = 0
	var available := 0.0
	for entry in live:
		available += float(entry["surplus"])
		if int(entry["network"]) != 0:
			serving_network = int(entry["network"])

	for v in villagers:
		if not (v is Node3D):
			continue
		var node: Node3D = v
		var efficiency := _efficiency_for(node.position, live)
		_apply_efficiency(v, efficiency)
		if efficiency >= 1.0:
			powered += 1
		else:
			unpowered += 1

	# Only what was actually spare gets paid for. A village on a generator
	# that is already at its current limit earns nothing, which is what makes
	# over-building a real decision.
	var demand := float(powered) * WATTS_PER_VILLAGER
	var delivered := minf(demand, available)
	total_delivered += delivered
	if delivered > 0.0:
		wage_pool = minf(WAGE_CAP, wage_pool + delivered * WAGE_RATE)


## A villager is powered if any live network has both a node near them and
## enough headroom to actually supply the whole village. Checking headroom once
## per network rather than once per villager is the difference between O(n*m)
## and O(n+m) each tick.
func _live_networks(graph: EngGraph, player_positions: Array) -> Array:
	var out: Array = []
	if graph == null:
		return out
	for entry in graph.networks():
		var spec: Dictionary = entry
		var net := int(spec["id"])
		var members: Array = spec.get("members", [])
		if members.is_empty():
			continue
		# A SLEEPING network is not being simulated, so its power figures are
		# whatever they were when it went to sleep. Serving the village from a
		# stale number is exactly the sort of "works offline" bug that makes a
		# grid feel fake.
		if int(spec.get("lod", 0)) >= 3:
			continue
		var st := graph.network_state(net)
		var positions := _positions(graph, members)
		# Networks far from every player are out of scope. With no player
		# positions at all -- a soak test, a dedicated server tick -- nothing is
		# out of scope, because there is no observer to be out of scope from.
		if not player_positions.is_empty():
			var nearest := INF
			for p in player_positions:
				var focus: Vector3 = p
				for q in positions:
					nearest = minf(nearest, focus.distance_to(q as Vector3))
			if nearest > SUPPLY_RADIUS * 8.0:
				continue
		var supply := float(st.get("supply", 0.0))
		var demand := float(st.get("demand", 0.0))
		out.append({
			"network": net,
			"voltage": float(st.get("voltage", 0.0)),
			# Headroom is what the network can still give, not what it is
			# making. A grid already at its limit powers nobody extra.
			"surplus": maxf(0.0, supply - demand),
			"positions": positions,
		})
	return out


func _positions(graph: EngGraph, members: Array) -> Array:
	var out: Array = []
	for m in members:
		var n: EngGraph.EngNode = graph.node(int(m))
		if n != null:
			out.append(n.position)
	return out


func _efficiency_for(where: Vector3, live: Array) -> float:
	for entry in live:
		for p in entry["positions"]:
			if (p as Vector3).distance_to(where) <= SUPPLY_RADIUS:
				return 1.0
	return UNPOWERED_EFFICIENCY


## The villager side of the contract: a `power_efficiency` field and a work
## rate derived from it. Written through `_set` so a villager from a future
## build without these properties is skipped rather than crashing the tick.
func _apply_efficiency(v: Variant, efficiency: float) -> void:
	v.set("power_efficiency", efficiency)
	var base := float(v.get("base_produce_interval"))
	if base <= 0.0:
		base = float(v.get("produce_interval"))
		if base <= 0.0:
			return
		v.set("base_produce_interval", base)
	# Power makes a villager faster, not a villager who produces more: the
	# stock cap still limits total output, so this is a rate change and the
	# economy stays balanced against an unpowered villager.
	v.set("produce_interval", base / maxf(efficiency, 0.05))


## Take the accumulated wage. Returns the amount and zeroes the pool, so a
## payout cannot be collected twice.
func collect_wage() -> float:
	var out := wage_pool
	wage_pool = 0.0
	return out


func summary() -> String:
	return "village: %d powered, %d unpowered, %.0f W drawn, wage pool %.0f" % [
		powered, unpowered, float(powered) * WATTS_PER_VILLAGER, wage_pool]


func serialize() -> Dictionary:
	return {
		"wage_pool": wage_pool,
		"total_delivered": total_delivered,
		"powered": powered,
		"unpowered": unpowered,
		"serving_network": serving_network,
	}


func deserialize(d: Dictionary) -> void:
	wage_pool = float(d.get("wage_pool", 0.0))
	total_delivered = float(d.get("total_delivered", 0.0))
	powered = int(d.get("powered", 0))
	unpowered = int(d.get("unpowered", 0))
	serving_network = int(d.get("serving_network", 0))
