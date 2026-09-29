class_name EngWorkshop
extends RefCounted
## Workshop System: progression the player physically builds.
##
## There is no tech tree to click through. A workbench is a thing the player
## assembles out of parts and puts down in the world; once it exists, the
## processes it enables become available. The same is true of the forge, the
## lathe and the machine shop. The player builds the table that builds the
## machine that builds the next table, and every step of that is a real
## object made of real components.
##
## A tier is therefore not "unlocked" but "standing". That also means the
## system has no hidden state: demolish the forge and the forging stops
## working, which is both obvious and satisfying.

## One workshop tier.
class Tier:
	var id: String
	var name: String
	## The workstation component that must exist in the world.
	var station: String
	## Material tier this station can shape. Gates manufacturing outright.
	var difficulty: float
	## Tool ids this station makes available.
	var tools: Array[String] = []
	## Processes this station makes available.
	var processes: Array[String] = []
	## Component ids this station makes buildable.
	var components: Array[String] = []

	func to_dict() -> Dictionary:
		return {"id": id, "name": name, "station": station,
			"difficulty": difficulty, "tools": Array(tools),
			"processes": Array(processes), "components": Array(components)}

	func _init(p_id := "", p_name := "", p_station := "") -> void:
		id = p_id
		name = p_name
		station = p_station


static var _tiers := {}
static var _order: Array[String] = []
static var _built := false


static func register_tier(t: Tier) -> void:
	_build()
	if t.id == "" or t.station == "":
		push_error("[workshop] a tier needs an id and a station component")
		return
	if not _tiers.has(t.id):
		_order.append(t.id)
	_tiers[t.id] = t


static func tier_of(station: String) -> Tier:
	_build()
	for id in _order:
		var t: Tier = _tiers[id]
		if t.station == station:
			return t
	return null


static func all_ids() -> Array[String]:
	_build()
	return _order.duplicate()


static func get_tier(id: String) -> Tier:
	_build()
	return _tiers.get(id, null)

# --- what the player currently has -----------------------------------------

## Which stations exist in `graph` right now, and therefore what the player
## can actually do. This is the whole progression system: a query.
static func standing(graph: EngGraph) -> Dictionary:
	_build()
	var standing_ids := {}
	for n in _tiers.keys():
		if _station_present(graph, (_tiers[n] as Tier).station):
			standing_ids[String(n)] = true
	return standing_ids


static func _station_present(graph: EngGraph, station: String) -> bool:
	if graph == null:
		return false
	for n in graph.all_nodes():
		if (n as EngGraph.EngNode).component_id == station:
			return true
	return false


## The best material difficulty the player can currently shape: the standing
## station with the highest tier. Zero before any station exists, which is
## why a bare-handed player can cut wood and nothing else.
static func best_difficulty(graph: EngGraph) -> float:
	_build()
	var best := 0.0
	for id in _order:
		var t: Tier = _tiers[id]
		if _station_present(graph, t.station):
			best = maxf(best, t.difficulty)
	return best


static func available_tools(graph: EngGraph) -> Array[String]:
	_build()
	var out: Array[String] = []
	for t in _tiers.values():
		if _station_present(graph, (t as Tier).station):
			for tool in (t as Tier).tools:
				if not out.has(tool):
					out.append(tool)
	# Hand tools exist before any station does. That is the whole point of
	# starting with nothing.
	for tool in EngTools.all_ids():
		var t2 := EngTools.get_tool(tool)
		if t2 != null and t2.difficulty <= 0.2 and not out.has(tool):
			out.append(tool)
	out.sort()
	return out


static func available_processes(graph: EngGraph) -> Array[String]:
	_build()
	var out: Array[String] = []
	for id in _order:
		var t: Tier = _tiers[id]
		if not _station_present(graph, t.station):
			continue
		for p in t.processes:
			if not out.has(p):
				out.append(p)
	return out


static func can_component(graph: EngGraph, component_id: String) -> bool:
	return _can_component(graph, component_id, 0)


## A component is buildable when the player's best station can shape its
## material AND every component in its bill is itself buildable.
##
## The second half is the one that matters. It is why a motor needs the
## station that makes shafts, not merely the station that can work copper: the
## dependency is expressed in the bill, and the bill is data. The depth guard
## stops a mod from defining a bill that refers to itself.
static func _can_component(graph: EngGraph, component_id: String,
		depth: int) -> bool:
	_build()
	if depth > 3 or not EngPorts.has(component_id):
		return false
	if EngMaterials.get_prop(EngItems.material_of(component_id),
			"manufacturing_difficulty") > best_difficulty(graph) + 0.001:
		return false
	for item in EngItems.bill_for(component_id).keys():
		var name := String(item)
		# A bill entry that is a raw material rather than a component just
		# has to be something the world can supply.
		if EngPorts.has(name) and not _can_component(graph, name, depth + 1):
			return false
	return true


## The next thing worth building, as a hint for the HUD. Ordered, so the
## player is never left guessing what the world is for.
static func next_goal(graph: EngGraph) -> Dictionary:
	_build()
	for id in _order:
		var t: Tier = _tiers[id]
		if _station_present(graph, t.station):
			continue
		var missing := {}
		for cid in t.components:
			if not EngPorts.has(cid):
				continue
			missing[cid] = 1
		return {"tier": id, "name": t.name, "station": t.station,
			"needs": missing, "difficulty": t.difficulty}
	return {}

# --- stock progression ------------------------------------------------------

static func _build() -> void:
	if _built:
		return
	_built = true

	# Tier 0: hands and a stump. A workbench is the first real object, and it
	# is built out of wood, not granted.
	var bench := Tier.new()
	bench.id = "workbench"
	bench.name = "workbench"
	bench.station = "workbench"
	bench.difficulty = 0.50
	bench.tools = ["hand_saw", "stone_axe", "hand_drill", "hammer", "file",
		"polishing_block", "tongs", "assembly_hammer"]
	bench.processes = ["cut", "drill", "mill", "grind", "polish", "assemble",
		"disassemble"]
	bench.components = ["plate", "beam", "shaft", "bolt", "bearing", "housing",
		"frame", "bracket"]
	register_tier(bench)

	# Tier 1: heat. A furnace turns ore into material, which is the step that
	# makes every metal in the game reachable.
	var furnace := Tier.new()
	furnace.id = "furnace"
	furnace.name = "furnace"
	furnace.station = "furnace"
	furnace.difficulty = 0.50
	furnace.tools = ["crucible", "soldering_iron"]
	furnace.processes = ["heat", "melt", "cast"]
	furnace.components = ["pipe", "valve", "tank", "impeller"]
	register_tier(furnace)

	# Tier 2: shaping metal properly. The forge is what turns a cast lump
	# into something with a grain.
	var forge := Tier.new()
	forge.id = "forge"
	forge.name = "forge"
	forge.station = "forge"
	forge.difficulty = 0.55
	forge.tools = ["grinder", "bandsaw"]
	forge.processes = ["forge", "heat_treat", "bend", "press"]
	forge.components = ["gear", "gearbox", "coupling", "pulley", "flywheel",
		"wire", "cable", "battery", "switch", "motor"]
	register_tier(forge)

	# Tier 3: precision. This is where the player stops making parts and
	# starts making parts that are good.
	var press := Tier.new()
	press.id = "press"
	press.name = "press and lathe"
	press.station = "press"
	press.difficulty = 0.65
	press.tools = ["press_tool", "dropper"]
	press.processes = ["extrude", "mill", "weld"]
	press.components = ["hand_crank", "generator", "pump", "conveyor_belt",
		"fan", "drill_bit", "grinder_wheel", "winch_drum", "chain_drive"]
	register_tier(press)

	# Tier 4: powered tooling. A drill press or lathe takes a motor.
	var machine := Tier.new()
	machine.id = "machine_shop"
	machine.name = "machine shop"
	machine.station = "machine_shop"
	machine.difficulty = 0.75
	machine.processes = ["weld", "extrude"]
	machine.components = ["relay", "fuse", "transformer", "terminal",
		"brake", "lead_screw"]
	register_tier(machine)

	# Tier 5: electronics. The last thing in the game.
	var lab := Tier.new()
	lab.id = "electronics_lab"
	lab.name = "electronics laboratory"
	lab.station = "electronics_lab"
	lab.difficulty = 0.95
	lab.tools = ["engraver", "laser_cutter"]
	lab.processes = ["solder", "mill"]
	lab.components = ["sensor", "controller"]
	register_tier(lab)
