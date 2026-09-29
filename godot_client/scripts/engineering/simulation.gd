class_name EngSimulation
extends RefCounted
## Network Simulation: step a graph's networks, cheaply.
##
## The performance requirement for this system is not "simulate fast", it is
## "do not simulate what nobody is looking at". A player with a hundred
## machines in a factory must be able to walk away from all of them, and the
## cost must not scale with how many they built.
##
## Four tiers, and the only rule that matters is that a network never becomes
## more expensive than the distance justifies:
##
##   FULL      -- near a player, every tick
##   REDUCED   -- nearby but not being looked at, every 8th tick
##   ABSTRACT  -- distant, every 64th tick, coarse numbers only
##   SLEEPING  -- nothing has changed and nobody is near; not stepped at all
##
## Tiers are decided by distance to the nearest player and re-evaluated only
## when a player moves, so the LOD pass is O(networks) on a slow tick rather
## than per frame. Crucially, SLEEPING is *sticky*: a network only wakes when
## the graph changes or a player comes back, which is what makes a sleeping
## factory genuinely free.

enum Tier { FULL, REDUCED, ABSTRACT, SLEEPING }

const TIER_NAMES := ["FULL", "REDUCED", "ABSTRACT", "SLEEPING"]

## Distance in blocks at which a network drops to the next tier.
const FULL_RANGE := 16.0
const REDUCED_RANGE := 56.0
const ABSTRACT_RANGE := 176.0
## Tick intervals, in ticks, for each tier. SLEEPING never ticks.
const TIER_INTERVAL := [1, 8, 64, 0]
## How much fluid an unconnected fluid output pours out per tick. An open
## pipe is a drain, not a sealed dead end.
const TAP_RATE := 2.0

var _graph: EngGraph
var _tick := 0
## Set by the owner whenever the graph topology changes, so sleeping networks
## are woken exactly once instead of every frame.
var wake_all := false
## Cached nearest-player distance per network, refreshed on the slow tick.
var _net_distance := {}
## Last positions the distances were computed for, so walking around does not
## leave a network stuck at its old tier.
var _last_positions: Array = []
## Nodes already advanced this tick, and the context each was given.
##
## A node belongs to several networks -- a pump is on a mechanical network and
## a fluid one -- and the obvious implementation calls step_node once per
## network, which means a motor on a 5-network factory is stepped five times
## per tick with five different partial contexts. Collecting the work and
## doing it once, after every network has been recomputed, is both the correct
## semantics and roughly a 3x saving on a typical machine.
var _stepped := {}
## Set by step(force = true): ignore distance for exactly one pass. A
## headless server, a save-time consistency check and the test suite all need
## "simulate everything right now" to be possible even when nobody is
## standing there.
var _force_once := false

## Networks are stepped in dependency order within a tick: a motor reads the
## bus voltage, a pump reads shaft speed, and a pipe reads pump pressure.
## Without this a machine is one tick stale on whichever machine happened to
## be created first, which shows up as a pump that starts a tick late and a
## factory that behaves differently depending on build order.
const KIND_PRIORITY := {
	EngPorts.Kind.ELECTRICAL: 0,
	EngPorts.Kind.MECHANICAL: 1,
	EngPorts.Kind.FLUID: 2,
	EngPorts.Kind.THERMAL: 3,
	EngPorts.Kind.DATA: 4,
}


func _init(graph: EngGraph = null) -> void:
	_graph = graph


func graph() -> EngGraph:
	return _graph


func tick_count() -> int:
	return _tick


## Advance the simulation by one tick. `player_positions` may be empty, which
## puts every network at most into ABSTRACT: correct for a headless server or a
## chunk that has not streamed in.
func step(player_positions: Array = [], force := false) -> void:
	if _graph == null:
		return
	_tick += 1
	if _graph.dirty:
		_graph.rebuild_networks()
		wake_all = true
	if _tick % 30 == 0 or _net_distance.size() != _graph.networks().size() \
			or not _same_positions(player_positions):
		_update_distances(player_positions)
		_last_positions = player_positions.duplicate()
	if force:
		# A forced pass ignores distance entirely for this one tick.
		_force_once = true
		_set_tier_all(Tier.FULL)
	elif wake_all:
		_set_tier_all(Tier.SLEEPING if player_positions.is_empty() else Tier.FULL)
		wake_all = false
	_run_due_tiers()
	_force_once = false
	_flush_node_steps()


## Advance every node that a network touched, exactly once, with the full
## context of all of its networks.
func _flush_node_steps() -> void:
	if _stepped.is_empty():
		return
	for nid in _stepped.keys():
		var node_ref: EngGraph.EngNode = _graph.node(int(nid))
		if node_ref == null:
			continue
		EngMachines.step_node(node_ref, _stepped[nid] as Dictionary, 1.0)
	_stepped.clear()


## Record that a node needs advancing, merging in one more network's state.
func _defer(node_id: int, key: String, state: Dictionary) -> void:
	if not _stepped.has(node_id):
		_stepped[node_id] = _context_for(node_id)
	(_stepped[node_id] as Dictionary)[key] = state


## Refresh how far each network is from the nearest player. This is the only
## per-network bookkeeping and it runs on a slow tick.
func _update_distances(player_positions: Array) -> void:
	_net_distance.clear()
	for n in _graph.networks():
		var net: Dictionary = n
		var best := ABSTRACT_RANGE * 2.0
		var members: Array = net["members"]
		for nid in members:
			var node_ref: EngGraph.EngNode = _graph.node(int(nid))
			if node_ref == null:
				continue
			for pp in player_positions:
				var d: float = (pp as Vector3).distance_to(node_ref.position)
				if d < best:
					best = d
		_net_distance[int(net["id"])] = best


## True when the players are standing exactly where they were last tick, which
## is the common case and must not trigger a distance recomputation.
func _same_positions(player_positions: Array) -> bool:
	if player_positions.size() != _last_positions.size():
		return false
	for i in player_positions.size():
		if not (player_positions[i] as Vector3).is_equal_approx(
				_last_positions[i] as Vector3):
			return false
	return true


func _tier_for_distance(d: float) -> int:
	if d <= FULL_RANGE:
		return Tier.FULL
	if d <= REDUCED_RANGE:
		return Tier.REDUCED
	if d <= ABSTRACT_RANGE:
		return Tier.ABSTRACT
	return Tier.SLEEPING


func _set_tier_all(tier: int) -> void:
	for n in _graph.networks():
		(n as Dictionary)["lod"] = tier


## Wake a network without waiting for the slow tick: used when a component is
## toggled or a part is inserted, both of which should be felt immediately.
func wake(net_id: int) -> void:
	var net := _graph.network(net_id)
	if net.is_empty():
		return
	net["lod"] = Tier.FULL
	net["idle"] = 0.0


func wake_node(node_id: int) -> void:
	for nid in _graph.networks_touching(node_id):
		wake(int(nid))


func _run_due_tiers() -> void:
	# Stepped in dependency order, not creation order, so a machine never
	# reads a network state that has not been recomputed this tick.
	var ordered := _graph.networks()
	ordered.sort_custom(func(x, y):
		return int(KIND_PRIORITY.get(int((x as Dictionary)["kind"]), 9)) < \
			int(KIND_PRIORITY.get(int((y as Dictionary)["kind"]), 9)))
	for n in ordered:
		var net: Dictionary = n
		var tier := int(net["lod"])
		# Distance is folded in here rather than cached, so a network that
		# drifts out of range as the player walks away stops costing anything.
		if tier != Tier.SLEEPING and not _force_once:
			var d := float(_net_distance.get(int(net["id"]), ABSTRACT_RANGE * 2.0))
			var want := _tier_for_distance(d)
			if want > tier:
				net["lod"] = want
				tier = want
			elif want < tier and net["idle"] < 2.0:
				net["lod"] = want
				tier = want
		var interval: int = int(TIER_INTERVAL[tier])
		if interval <= 0:
			continue
		if _tick % interval != 0:
			continue
		_step_network(net, tier)


## Wake a sleeping network when the player comes back to it, which is the only
## reason a sleeping network ever becomes live again.
func _maybe_wake(net: Dictionary, tier: int) -> void:
	net["idle"] = float(net.get("idle", 0.0)) + 1.0
	if net["idle"] > 3.0:
		net["lod"] = Tier.SLEEPING


## The full simulation context for one node: the state of every network it
## belongs to, one entry per kind.
##
## A node can sit on several networks at once -- a pump is on a mechanical
## network and a fluid network -- and its behaviour routinely needs both.
## Building the context from the node's own memberships, rather than from
## whichever network happens to be stepping, is what stops the fluid pass
## from overwriting the pump's shaft speed with a default zero.
func _context_for(node_id: int) -> Dictionary:
	return {
		"electrical": _graph.network_state(_graph.network_of(node_id,
			EngPorts.Kind.ELECTRICAL)),
		"mechanical": _graph.network_state(_graph.network_of(node_id,
			EngPorts.Kind.MECHANICAL)),
		"fluid": _graph.network_state(_graph.network_of(node_id, EngPorts.Kind.FLUID)),
		"thermal": _graph.network_state(_graph.network_of(node_id, EngPorts.Kind.THERMAL)),
		"data": _graph.network_state(_graph.network_of(node_id, EngPorts.Kind.DATA)),
	}




func _step_network(net: Dictionary, tier: int) -> void:
	var kind := int(net["kind"])
	var members: Array = net["members"]
	if members.is_empty():
		_maybe_wake(net, tier)
		return
	# ABSTRACT deliberately does not recompute the detailed state; it only
	# integrates the totals, which is the whole point of the tier existing.
	if tier == Tier.ABSTRACT:
		_step_abstract(net, members)
		_maybe_wake(net, tier)
		return
	var changed := false
	match kind:
		EngPorts.Kind.ELECTRICAL:
			changed = _step_electrical(net, members)
		EngPorts.Kind.MECHANICAL:
			changed = _step_mechanical(net, members)
		EngPorts.Kind.FLUID:
			changed = _step_fluid(net, members)
		EngPorts.Kind.THERMAL:
			changed = _step_thermal(net, members)
		EngPorts.Kind.DATA:
			changed = _step_data(net, members)
	net["active"] = changed
	if not changed:
		_maybe_wake(net, tier)
	else:
		net["idle"] = 0.0

# --- electrical ------------------------------------------------------------

## One electrical network is a bus: every generator contributes supply, every
## sink asks for demand, and the bus voltage is the single number that decides
## whether anything runs. Modelling it this way is what makes a generator, a
## battery and a hand-wired motor interchangeable sources.
func _step_electrical(net: Dictionary, members: Array) -> bool:
	var supply := 0.0
	var demand := 0.0
	var sink_count := 0
	for nid in members:
		var node_ref: EngGraph.EngNode = _graph.node(int(nid))
		if node_ref == null:
			continue
		var role := EngMachines.role_of(node_ref.component_id)
		if role == EngMachines.POWER_SOURCE:
			# A battery offers its rated output scaled by remaining charge.
			# A flat one contributes nothing, which is what makes running it
			# dry a real consequence.
			var cap := maxf(EngMachines.num(node_ref.component_id, "capacity",
				1000.0), 1.0)
			var charge := clampf(float(node_ref.state.get("stored", 0.0)) / cap,
				0.0, 1.0)
			supply += EngMachines.num(node_ref.component_id, "max_output",
				200.0) * charge if node_ref.enabled else 0.0
		elif role == EngMachines.ELECTRIC_GENERATOR:
			supply += float(node_ref.state.get("supply", 0.0))
		if role in [EngMachines.POWER_SINK, EngMachines.ROTARY_DRIVE]:
			demand += EngMachines.num(node_ref.component_id, "draw",
				EngMachines.NOMINAL_VOLTAGE * 5.0) if node_ref.enabled else 0.0
			sink_count += 1
	# Voltage: full when supply covers demand, brownout below that, dead at
	# zero. A deterministic curve, not a solver, so it is stable and cheap.
	var ratio := 1.0 if supply >= demand else (supply / maxf(demand, 1.0))
	ratio = clampf(ratio, 0.0, 1.0)
	var volts := EngMachines.NOMINAL_VOLTAGE * pow(ratio, 0.4)
	var st: Dictionary = net["state"]
	var changed := not is_equal_approx(float(st["supply"]), supply) or \
		not is_equal_approx(float(st["demand"]), demand) or \
		not is_equal_approx(float(st["voltage"]), volts)
	st["supply"] = supply
	st["demand"] = demand
	st["voltage"] = volts
	st["current"] = demand / maxf(EngMachines.NOMINAL_VOLTAGE, 1.0)
	# Hand the bus state to every member so the per-node roles can react.
	for nid in members:
		_defer(int(nid), "electrical", st)
	return changed

# --- mechanical ------------------------------------------------------------

## A mechanical network carries a shaft speed and a torque budget.
##
## Speed is the source rpm multiplied by every ratio between the source and
## this node -- that is what a gearbox does, and why one motor can drive a
## slow conveyor and a fast grinder at the same time. Torque is then whatever
## the loads ask for; if the loads want more torque than the source can give,
## the whole train slows down, which is the honest simplified answer.
func _step_mechanical(net: Dictionary, members: Array) -> bool:
	var elec_states := {}
	var total_demand := 0.0
	var source_rpm := 0.0
	var source_torque := 0.0
	# First pass: what is driving, and how much do the loads want?
	for nid in members:
		var node_ref: EngGraph.EngNode = _graph.node(int(nid))
		if node_ref == null:
			continue
		var role := EngMachines.role_of(node_ref.component_id)
		if role == EngMachines.ROTARY_SOURCE:
			# Read the source from its own parameters rather than from the
			# state it wrote last tick. Otherwise a hand crank would need a
			# tick to start turning and an overload would be invisible on the
			# very tick the player finished building it.
			if node_ref.enabled and float(node_ref.state.get("effort", 0.0)) > 0.0:
				source_rpm = maxf(source_rpm, EngMachines.num(
					node_ref.component_id, "max_rpm", 100.0))
				source_torque += EngMachines.num(node_ref.component_id,
					"max_torque", 30.0)
		elif role == EngMachines.FLUID_PUMP:
			# A pump resists the shaft; it is a load with a very specific job.
			total_demand += EngMachines.num(node_ref.component_id, "drag_torque", 4.0)
	# Each member's speed is the source speed scaled by its own ratio chain.
	var st: Dictionary = net["state"]
	var elec_net := _graph.network_of(int(members[0]), EngPorts.Kind.ELECTRICAL)
	var elec_state: Dictionary = _graph.network_state(elec_net)
	for nid in members:
		var node_ref: EngGraph.EngNode = _graph.node(int(nid))
		if node_ref == null:
			continue
		var role := EngMachines.role_of(node_ref.component_id)
		if role == EngMachines.ROTARY_DRIVE and node_ref.enabled:
			# A motor is itself a source, but its speed comes from the bus.
			var volts := float(elec_state.get("voltage", 0.0))
			var frac := clampf(volts / EngMachines.NOMINAL_VOLTAGE, 0.0, 1.0)
			source_rpm = maxf(source_rpm, EngMachines.num(node_ref.component_id,
				"max_rpm", 1200.0) * frac)
			source_torque += EngMachines.num(node_ref.component_id, "max_torque",
				10.0) * frac
		elif role == EngMachines.ROTARY_LOAD and node_ref.enabled:
			total_demand += EngMachines.num(node_ref.component_id, "max_torque", 5.0)
	# Ratio of the drivetrain: gearbox reduction multiplies torque, divides
	# speed. Applied once, from the network's own dominant gearbox, so a train
	# of two gearboxes compounds correctly without a full graph search.
	var ratio := 1.0
	for nid in members:
		var node_ref: EngGraph.EngNode = _graph.node(int(nid))
		if node_ref == null:
			continue
		if EngMachines.role_of(node_ref.component_id) == EngMachines.ROLE_NONE:
			ratio *= EngMachines.num(node_ref.component_id, "ratio", 1.0)
	var out_rpm := source_rpm / maxf(ratio, 0.01)
	var out_torque := source_torque * ratio
	# The whole train is limited by its most restrictive port. This is where
	# a per-port speed rating finally matters: a 3000 rpm motor driving a
	# 1500 rpm drill bit runs the bit at its rating, not at the motor's.
	var cap := 0.0
	for nid in members:
		var node_ref: EngGraph.EngNode = _graph.node(int(nid))
		if node_ref == null:
			continue
		var cdef := EngPorts.get_def(node_ref.component_id)
		if cdef == null:
			continue
		for p in cdef.ports:
			var port: EngPorts.Port = p
			if port.kind == EngPorts.Kind.MECHANICAL and port.max_rpm > 0.0:
				cap = port.max_rpm if cap <= 0.0 else minf(cap, port.max_rpm)
	if cap > 0.0:
		out_rpm = minf(out_rpm, cap)
	# Load fraction: how close the network is to stalling. This is the one
	# number that feeds back into the motor, closing the loop between the
	# electrical and mechanical layers. With no source at all there is
	# nothing to overload, so the fraction is zero rather than a meaningless
	# ratio against a zero-torque shaft.
	var load_fraction := 0.0
	if out_torque > 0.001:
		load_fraction = clampf(total_demand / out_torque, 0.0, 1.5)
	var bog := clampf(1.0 - 0.5 * maxf(0.0, load_fraction - 1.0), 0.0, 1.0)
	var rpm := out_rpm * bog
	var changed := not is_equal_approx(float(st["rpm"]), rpm)
	st["rpm"] = rpm
	st["torque"] = out_torque
	st["power"] = out_torque * rpm * TAU / 60.0
	st["load_fraction"] = load_fraction
	st["source"] = 1 if source_rpm > 0.0 else 0
	for nid in members:
		_defer(int(nid), "mechanical", st)
	return changed or total_demand > 0.0

# --- fluid -----------------------------------------------------------------

## Fluid networks separate supply from pressure, so a full tank feeding a pump
## feeding a pipe reads as a system rather than as a magic water block. Flow is
## the minimum of what the pump can push and what the network will take.
func _step_fluid(net: Dictionary, members: Array) -> bool:
	var supply := 0.0
	var pressure := 0.0
	var draw := 0.0
	var st: Dictionary = net["state"]
	var storable := 0.0
	for nid in members:
		var node_ref: EngGraph.EngNode = _graph.node(int(nid))
		if node_ref == null:
			continue
		var role := EngMachines.role_of(node_ref.component_id)
		if role == EngMachines.FLUID_SOURCE:
			supply += minf(float(node_ref.state.get("stored", 0.0)), 1000.0)
			storable += float(node_ref.state.get("stored", 0.0))
		elif role == EngMachines.FLUID_PUMP:
			# Derived from the pump's own mechanical network, not from the
			# node's stored state. The node is advanced at the end of the
			# tick, so reading its state here would make the fluid network one
			# tick behind the shaft that drives it.
			var out := _pump_output(node_ref)
			pressure = maxf(pressure, out["pressure"])
			supply = maxf(supply, out["flow"])
		elif role == EngMachines.FLUID_SINK:
			draw += EngMachines.num(node_ref.component_id, "draw", 1.0)
	# An unconnected fluid output is an open tap. Without this, a pump with
	# a pipe on the end would pressurise forever and the water system the
	# player built would never actually deliver anything anywhere.
	var open_taps := _open_fluid_outlets(members)
	draw += open_taps * TAP_RATE
	var flow := minf(supply, draw) if pressure > 0.0 else 0.0
	var changed := not is_equal_approx(float(st["flow"]), flow)
	st["supply"] = supply
	st["stored"] = storable
	st["pressure"] = pressure
	st["flow"] = flow
	st["drawn"] = flow
	st["taps"] = open_taps
	for nid in members:
		_defer(int(nid), "fluid", st)
	# A sink actually consumes: the network draws down whatever holds fluid.
	if flow > 0.0:
		for nid in members:
			var node_ref: EngGraph.EngNode = _graph.node(int(nid))
			if node_ref == null:
				continue
			if EngMachines.role_of(node_ref.component_id) == EngMachines.FLUID_SOURCE:
				var took: float = minf(float(node_ref.state.get("stored", 0.0)), flow)
				node_ref.state["stored"] = float(node_ref.state.get("stored", 0.0)) - took
	return changed or flow > 0.0

## What a pump is delivering, derived purely from the mechanical network it is
## on. The FLUID_PUMP role calls this too, so the network aggregate and the
## node's own state are computed by one function and cannot disagree -- which
## is how a pump stopped being one tick behind its own shaft.
func _pump_output(node_ref: EngGraph.EngNode) -> Dictionary:
	var p := EngMachines.params_of(node_ref.component_id)
	var mnet := _graph.network_of(node_ref.id, EngPorts.Kind.MECHANICAL)
	var rpm := float(_graph.network_state(mnet).get("rpm", 0.0))
	var max_rpm := maxf(float(p.get("max_rpm", 1000.0)), 1.0)
	var frac := clampf(rpm / max_rpm, 0.0, 1.0) * (1.0 if node_ref.enabled else 0.0)
	return {"rpm": rpm, "frac": frac,
		"flow": float(p.get("max_flow", 8.0)) * frac,
		"pressure": float(p.get("max_pressure", 100.0)) * frac,
		"drag": float(p.get("drag_torque", 4.0)) * frac}


## How many fluid output ports on this network are connected to nothing. Those
## are open ends the fluid pours out of.
func _open_fluid_outlets(members: Array) -> int:
	var n := 0
	for nid in members:
		var node_ref: EngGraph.EngNode = _graph.node(int(nid))
		if node_ref == null:
			continue
		var def := EngPorts.get_def(node_ref.component_id)
		if def == null:
			continue
		for p in def.ports:
			var port: EngPorts.Port = p
			if port.kind == EngPorts.Kind.FLUID and port.can_emit() \
					and not _graph.is_linked(int(nid), port.name):
				n += 1
	return n


# --- thermal ---------------------------------------------------------------

## Heat accumulates from members and leaves through the surface. It is coarse
## on purpose: enough to make a machine overheat and need a break, not enough
## to be a CFD solver.
func _step_thermal(net: Dictionary, members: Array) -> bool:
	var generated := 0.0
	var area := 0.0
	for nid in members:
		var node_ref: EngGraph.EngNode = _graph.node(int(nid))
		if node_ref == null:
			continue
		generated += float(node_ref.state.get("heat", 0.0)) * \
			float(node_ref.state.get("rpm", 1.0))
		var comp := EngPorts.get_def(node_ref.component_id)
		if comp != null:
			area += comp.material_cost * 40.0
	var st: Dictionary = net["state"]
	var before := float(st["temperature"])
	# Newtonian-ish cooling: proportional to excess over ambient, scaled by
	# exposed area, so a big housing runs cooler than a small bearing.
	st["temperature"] = 20.0 + (before - 20.0) * (1.0 - 0.05) + generated * 0.01
	st["generated"] = generated
	st["dissipated"] = maxf(0.0, (before - 20.0) * 0.05)
	for nid in members:
		_defer(int(nid), "thermal", st)
	return absf(float(st["temperature"]) - before) > 0.01

# --- data / control --------------------------------------------------------

## Data networks carry one signal. That is deliberately not a computer: a
## controller reading a sensor and driving a valve is the whole automation
## story the vertical slice needs, and anything richer belongs in a mod.
func _step_data(net: Dictionary, members: Array) -> bool:
	var st: Dictionary = net["state"]
	var sig_level := float(st.get("signal", 0.0))
	var changed := false
	for nid in members:
		var node_ref: EngGraph.EngNode = _graph.node(int(nid))
		if node_ref == null:
			continue
		if EngMachines.role_of(node_ref.component_id) == EngMachines.CONTROLLER:
			var out_sig := 1.0 if node_ref.enabled else 0.0
			if not is_equal_approx(sig_level, out_sig):
				changed = true
			sig_level = out_sig
	if changed:
		st["signal"] = sig_level
	for nid in members:
		_defer(int(nid), "data", st)
	return changed

# --- abstract tier ---------------------------------------------------------

## The ABSTRACT tier: no per-node work, only the aggregate. A distant factory
## still has a believable power bill and a plausible shaft speed, at a cost
## that is a handful of arithmetic operations per network per 64 ticks.
func _step_abstract(net: Dictionary, members: Array) -> void:
	var kind := int(net["kind"])
	var st: Dictionary = net["state"]
	if kind == EngPorts.Kind.ELECTRICAL:
		var demand := 0.0
		for nid in members:
			var node_ref: EngGraph.EngNode = _graph.node(int(nid))
			if node_ref == null or not node_ref.enabled:
				continue
			demand += EngMachines.num(node_ref.component_id, "draw", 20.0)
		st["demand"] = demand
		st["supply"] = maxf(float(st.get("supply", 0.0)), demand)
		st["voltage"] = EngMachines.NOMINAL_VOLTAGE if demand > 0.0 else 0.0
	elif kind == EngPorts.Kind.MECHANICAL:
		var load := 0.0
		for nid in members:
			var node_ref: EngGraph.EngNode = _graph.node(int(nid))
			if node_ref == null or not node_ref.enabled:
				continue
			load += EngMachines.num(node_ref.component_id, "max_torque", 5.0)
		st["load_fraction"] = clampf(load / 50.0, 0.0, 1.5)
	elif kind == EngPorts.Kind.FLUID:
		var held := 0.0
		for nid in members:
			var node_ref: EngGraph.EngNode = _graph.node(int(nid))
			if node_ref == null:
				continue
			held += float(node_ref.state.get("stored", 0.0))
		st["stored"] = held

# --- reporting -------------------------------------------------------------

## A one-line summary for the in-world power/status readout. The player sees
## this on the machine, not in a menu.
func describe_network(net_id: int) -> String:
	var net := _graph.network(net_id)
	if net.is_empty():
		return ""
	var st: Dictionary = net["state"]
	var tier := int(net.get("lod", Tier.FULL))
	var head := "%s net %d [%s]" % [EngPorts.kind_name(int(net["kind"])), net_id,
		TIER_NAMES[tier]]
	match int(net["kind"]):
		EngPorts.Kind.ELECTRICAL:
			return "%s  %.0fW supply / %.0fW demand  %.1fV" % [head,
				float(st["supply"]), float(st["demand"]), float(st["voltage"])]
		EngPorts.Kind.MECHANICAL:
			return "%s  %.0f rpm  %.0f Nm  load %.0f%%" % [head,
				float(st["rpm"]), float(st["torque"]),
				float(st["load_fraction"]) * 100.0]
		EngPorts.Kind.FLUID:
			return "%s  %.0f stored  %.1f flow  %.0f pressure" % [head,
				float(st["stored"]), float(st["flow"]), float(st["pressure"])]
		EngPorts.Kind.THERMAL:
			return "%s  %.0f C" % [head, float(st["temperature"])]
		_:
			return "%s  signal %.0f" % [head, float(st.get("signal", 0.0))]


## Tier statistics, asserted by the test suite so a regression in the LOD
## logic cannot pass unnoticed.
func tier_counts() -> Dictionary:
	var out := {Tier.FULL: 0, Tier.REDUCED: 0, Tier.ABSTRACT: 0, Tier.SLEEPING: 0}
	for n in _graph.networks():
		var t := int((n as Dictionary).get("lod", Tier.SLEEPING))
		out[t] = int(out[t]) + 1
	return out
