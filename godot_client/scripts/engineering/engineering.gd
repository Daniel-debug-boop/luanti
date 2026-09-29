class_name EngEngineering
extends Node
## The engineering system, assembled.
##
## Every other engineering file is a layer with a clean API and no knowledge of
## the game. This one is the only place they meet: it owns the graph and the
## simulation, streams visuals, spends and returns items in the player's
## existing GLoot backpack, and serialises into the existing save file.
##
## It deliberately owns no new systems. There is no second inventory, no
## second world, no second physics and no second save. A motor the player
## builds is a node in the same graph the workshop reads, made of items from
## the same backpack that holds the stone they mined it with.

## The graph of everything the player has built.
var graph := EngGraph.new()
## The network simulation driving that graph.
var sim: EngSimulation = null

## The coupling between the player's machines and the village AI. Owned here
## because it needs the graph, but it is not part of the machine simulation:
## it never advances a network, it only reads them.
var society := EngSociety.new()

## Set by the owner. Both are optional, because the engineering system is
## fully usable -- and fully testable -- without either.
var world: VoxelWorld = null
var inventory: PlayerInventory = null

## Visual streaming root. Every placed component eventually gets a
## MeshInstance3D; none of them get a physics body, a process callback or a
## script.
var visuals: Node3D = null

## How far from a player a component keeps its visual. Beyond this the mesh is
## freed and regenerated on return, from the same cached geometry.
const VISUAL_RANGE := 96.0
## Hard ceiling on live visuals, so a player who bolts ten thousand things
## cannot make the renderer the bottleneck.
const MAX_VISUALS := 2048

## Simulation runs at a fixed rate, decoupled from the frame rate, so a slow
## machine does not change how fast the factory behaves.
const SIM_HZ := 10.0
const SIM_DT := 1.0 / SIM_HZ

var _acc := 0.0
var _sim_ticks := 0
## Node id -> MeshInstance3D currently in the scene.
var _visuals := {}
## Set when the graph changes, so the visual pass only does work on edits.
var _visuals_dirty := true
## Interaction level the player has chosen.
var cursor_level := EngCursor.Level.ASSISTED
## The last fastening candidates, for the player to move between.
var _candidates: Array = []
var _candidate_index := 0

signal assembly_recognised(node_id: int, label: String)
signal machine_changed(node_id: int)
signal notice(text: String)


func _init() -> void:
	sim = EngSimulation.new(graph)


func _ready() -> void:
	build()


## Idempotent setup. `_ready` is deferred when this node is created from a
## test's SceneTree._init, so anything that needs the tree calls build()
## explicitly.
func build() -> void:
	if visuals != null and is_instance_valid(visuals):
		return
	visuals = Node3D.new()
	visuals.name = "EngineeringVisuals"
	add_child(visuals)


## Attach to the game. Called by main.gd once the world and the backpack
## exist; a null argument is fine and simply means the system runs
## headless-ish with no world interaction.
func attach(p_world: VoxelWorld, p_inventory: PlayerInventory) -> void:
	world = p_world
	inventory = p_inventory


# --- time ------------------------------------------------------------------

## Advance the simulation. Called every frame; the fixed-rate accumulator
## inside is what keeps factory behaviour independent of frame rate.
func tick(delta: float, player_positions: Array = [], villagers: Array = []) -> void:
	_acc += delta
	var steps := 0
	while _acc >= SIM_DT and steps < 4:
		_acc -= SIM_DT
		steps += 1
		_sim_ticks += 1
		sim.step(player_positions)
	if graph.dirty:
		_visuals_dirty = true
	# Visual streaming is the one pass that walks the whole graph, so it runs
	# only when it can actually have changed: an edit happened, or the player
	# moved far enough that the streaming radius covers different components.
	# Re-scanning every frame is what makes a "streaming" system slower than
	# just keeping everything.
	_sim_ticks_since_visuals += 1
	var focus := Vector3.INF
	if not player_positions.is_empty():
		focus = player_positions[0] as Vector3
	var moved := _last_visual_anchor.distance_squared_to(focus) \
		> VISUAL_STEP * VISUAL_STEP
	if _visuals_dirty or (moved and _sim_ticks_since_visuals >= 2):
		_sim_ticks_since_visuals = 0
		_visuals_dirty = false
		_last_visual_anchor = focus
		_update_visuals(player_positions)
	if not villagers.is_empty():
		# The village reads the graph; the graph never reads the village. One
		# direction of authority is what keeps this from becoming a second
		# simulation running alongside the first.
		society.tick(delta, graph, villagers, player_positions)


var _sim_ticks_since_visuals := 0
## Last position the visual streaming pass ran from.
var _last_visual_anchor := Vector3.INF


## True when something is actually changing: a machine is running, a
## manufacturing job is in progress, or the world was just edited. The
## stability watchdog uses this to tell a real leak from a legitimate burst.
func is_busy() -> bool:
	if graph.dirty or _visuals_dirty:
		return true
	for nid in graph.node_ids():
		var n: EngGraph.EngNode = graph.node(int(nid))
		if n != null and n.state.has("job_progress") and float(n.state["job_progress"]) > 0.0:
			return true
	return false
## How far the player must walk before the visual pass is worth repeating.
const VISUAL_STEP := 12.0

# --- placing ---------------------------------------------------------------

## Place a component, spending one from the player's backpack.
##
## The bill is charged before the node is created, and refunded if creation
## fails, so a full inventory can never eat a motor.
func place(component_id: String, position: Vector3, rotation_y := 0.0,
		part: EngPart = null) -> Dictionary:
	if not EngPorts.has(component_id):
		return {"ok": false, "reason": "unknown component", "node": 0}
	if inventory != null and not _can_build(component_id):
		var check := EngItems.can_build(inventory, component_id)
		return {"ok": false, "reason": "missing %s" % str(
			check["missing"]), "node": 0}
	if inventory != null and inventory.consume_eng(component_id, 1) == 0:
		return {"ok": false, "reason": "none in the pack", "node": 0}
	var node := graph.place(component_id, position, rotation_y, part)
	if node < 0:
		if inventory != null:
			inventory.give_eng(component_id, 1)
		return {"ok": false, "reason": "could not place", "node": 0}
	_visuals_dirty = true
	_recognise(node)
	return {"ok": true, "reason": "", "node": node}


## Place without charging anything, for world generation, a blueprint, a test
## or a server-authoritative build that has already been paid for.
func place_free(component_id: String, position: Vector3, rotation_y := 0.0,
		part: EngPart = null) -> int:
	var node := graph.place(component_id, position, rotation_y, part)
	if node >= 0:
		_visuals_dirty = true
	return node


## Remove a component and return it to the pack, edge by edge.
func remove(node_id: int) -> Dictionary:
	var n := graph.node(node_id)
	if n == null:
		return {"ok": false, "reason": "nothing there"}
	var component := n.component_id
	if not graph.remove_node(node_id):
		return {"ok": false, "reason": "could not remove"}
	_drop_visual(node_id)
	_visuals_dirty = true
	if inventory != null:
		inventory.give_eng(component, 1)
	return {"ok": true, "reason": "", "component": component}


func _can_build(component_id: String) -> bool:
	if inventory == null:
		return true
	# A station is what unlocks a component, and a component is what the
	# station is made of -- so a station in progress is exempt.
	if not EngWorkshop.can_component(graph, component_id):
		return false
	var bill := EngItems.bill_for(component_id)
	return inventory.can_afford_eng(bill)

# --- building the world ----------------------------------------------------

## Fasten two nearby parts together at the cursor. This is the whole
## interaction: aim, click, bolt appears where it can actually go.
func fasten(position: Vector3, radius := EngFastening.DEFAULT_RADIUS) -> Dictionary:
	var r := EngFastening.place(graph, position, radius)
	if bool(r["ok"]):
		_visuals_dirty = true
		_recognise(int(r["node"]))
		if inventory != null and inventory.consume_eng("bolt", 1) == 0:
			pass   # the bolt is consumed from stock, not from the pack
	else:
		_candidates = EngFastening.candidates(graph, position, radius)
		_candidate_index = 0
	return r


## Cycle the fastening preview to the next candidate point, so the player can
## move between the places a bolt would go without aiming precisely.
func next_fastening_candidate(position: Vector3) -> Dictionary:
	if _candidates.is_empty():
		_candidates = EngFastening.candidates(graph, position)
		_candidate_index = 0
	if _candidates.is_empty():
		return {}
	_candidate_index = (_candidate_index + 1) % _candidates.size()
	return _candidates[_candidate_index]


func current_candidate() -> Dictionary:
	if _candidate_index < 0 or _candidate_index >= _candidates.size():
		return {}
	return _candidates[_candidate_index]

# --- using tools -----------------------------------------------------------

## Use the held tool on a component. `context` carries the cursor's read of
## the world, which is what turns "aim at a plank with a saw" into a cut at
## the right place.
func use_tool(tool_id: String, node_id: int, context := {}) -> Dictionary:
	var n := graph.node(node_id)
	if n == null:
		return {"ok": false, "reason": "nothing there"}
	if not EngWorkshop.available_tools(graph).has(tool_id):
		return {"ok": false, "reason": "you have not built a station for that"}
	if n.part == null:
		n.part = _stock_part(n.component_id)
	var p := EngTools.preview(tool_id, n.part, context)
	if not bool(p["ok"]):
		return p
	if String(p["process"]) == EngTools.PLACE:
		# A placement tool spawns a new component at the cursor instead.
		var placed := place_free(String((p["params"] as Dictionary)["component"]),
			n.position + Vector3(0, 0.5, 0))
		return {"ok": placed >= 0, "reason": "", "node": placed,
			"process": EngTools.PLACE}
	var used := EngTools.use(tool_id, n.part, context)
	if bool(used["ok"]):
		_visuals_dirty = true
		machine_changed.emit(node_id)
	return used


## A part for a stock component, so the first operation on a motor housing has
## something to cut. Sized from the component's material cost.
func _stock_part(component_id: String) -> EngPart:
	var def := EngPorts.get_def(component_id)
	var ext: float = maxf(pow(def.material_cost, 1.0 / 3.0), 0.08)
	return EngPart.block(def.material, ext)

# --- smelting ---------------------------------------------------------------

## Turn a mined ore into refined metal. This is the step that connects the
## voxel world to the engineering system: copper ore in the ground becomes
## copper in the pack, which becomes wire, which becomes a motor.
static func smelt(block_id: int) -> Dictionary:
	var material := ContentDB.material_of(block_id)
	if material == "":
		return {"ok": false, "reason": "that does not smelt"}
	if not SMELTING.has(material):
		return {"ok": false, "reason": "no recipe for %s" % material}
	var recipe: Dictionary = SMELTING[material]
	return {"ok": true, "reason": "", "material": String(material),
		"block": int(recipe["block"]), "count": int(recipe.get("count", 1)),
		"fuel": int(recipe.get("fuel", 1))}


## Ore -> refined metal, keyed by the engineering material the ore contains.
## The product is a real ContentDB block, so the refined metal travels through
## the existing mine/place/inventory/save path with no special handling.
const SMELTING := {
	"copper": {"block": 21, "count": 1, "fuel": 1},
	"iron": {"block": 22, "count": 1, "fuel": 1},
	"silver": {"block": 24, "count": 1, "fuel": 2},
}


## Smelt whatever the player is holding, if it is ore and they have a furnace.
## Returns what was produced, so the caller can report it.
func smelt_held() -> Dictionary:
	if inventory == null:
		return {"ok": false, "reason": "no pack"}
	if not _has_station("furnace"):
		return {"ok": false, "reason": "build a furnace first"}
	var held := inventory.selected_block_id()
	if held < 0:
		return {"ok": false, "reason": "hold some ore"}
	var r := smelt(held)
	if not bool(r["ok"]):
		return r
	inventory.consume_block(held, 1)
	inventory.give_block(int(r["block"]))
	notice.emit("smelted %s" % ContentDB.name_of(int(r["block"])))
	return r


## Manufacture a component.
##
## This is the core progression verb, and it is deliberately NOT a recipe
## unlock. The player needs standing workshop stations, the station's tier has
## to be high enough to shape the component's material, and they have to be
## carrying the bill. Change any of those and it stops working -- which is
## what makes a workshop the player built matter.
func manufacture(component_id: String, at := Vector3.INF) -> Dictionary:
	if not EngPorts.has(component_id):
		return {"ok": false, "reason": "unknown component", "node": 0}
	if not EngWorkshop.can_component(graph, component_id):
		return {"ok": false, "reason": "your workshop cannot shape %s yet" % (
			EngItems.material_of(component_id)), "node": 0}
	if inventory == null:
		return {"ok": false, "reason": "no pack", "node": 0}
	var bill := EngItems.bill_for(component_id)
	if not inventory.can_afford_bill(bill):
		var missing := {}
		for item in bill.keys():
			var need := int(bill[item]) - inventory.count_bill_item(String(item))
			if need > 0:
				missing[String(item)] = need
		return {"ok": false, "reason": "missing %s" % str(missing), "node": 0}
	if inventory.consume_eng(component_id, 1) != 0:
		# Already carrying one, so nothing is paid and nothing is produced.
		return {"ok": false, "reason": "already have one", "node": 0}
	# The part is made, not just the item: it gets a shape, a material and a
	# starting quality derived from how well the station can work it.
	var part := _manufactured_part(component_id)
	if not inventory.pay_bill(bill):
		return {"ok": false, "reason": "could not pay for it", "node": 0}
	var pos: Vector3 = at if at != Vector3.INF else _nearest_station_position()
	inventory.give_eng(component_id, 1)
	var node := graph.place(component_id, pos, 0.0, part)
	if node >= 0:
		_visuals_dirty = true
		_recognise(node)
		notice.emit("made %s" % component_id)
	return {"ok": true, "reason": "", "node": node, "part": part}


## A freshly manufactured part: the component's own material, sized from what
## it costs, and a starting quality set by the station that made it. A better
## workshop literally makes better parts.
func _manufactured_part(component_id: String) -> EngPart:
	var c := EngPorts.get_def(component_id)
	var ext: float = maxf(pow(c.material_cost, 1.0 / 3.0), 0.06)
	var p := EngPart.block(c.material, ext)
	p.component_id = component_id
	p.label = component_id.replace("_", " ")
	# Quality tracks the station tier: a lathe beats a workbench.
	var tier := EngWorkshop.best_difficulty(graph)
	p.quality = clampf(0.35 + tier * 0.6, 0.0, 1.0)
	return p


## Where a newly made thing appears: at the best standing station, so it is
## put down where the player's technology actually is.
func _nearest_station_position() -> Vector3:
	var best := ""
	var best_difficulty := -1.0
	for id in EngWorkshop.all_ids():
		var t := EngWorkshop.get_tier(id)
		if t == null or t.difficulty <= best_difficulty:
			continue
		if _has_station(t.station):
			best = t.station
			best_difficulty = t.difficulty
	if best == "":
		return Vector3.ZERO
	for n in graph.all_nodes():
		if (n as EngGraph.EngNode).component_id == best:
			return (n as EngGraph.EngNode).position + Vector3(0, 0.6, 0)
	return Vector3.ZERO


## Whether any workshop station exists at all. Used by the build prompt to
## distinguish "you have no station for that" from "aim at something".
func has_station_tools() -> bool:
	return _has_station("workbench")


func _has_station(station: String) -> bool:
	for n in graph.all_nodes():
		if (n as EngGraph.EngNode).component_id == station:
			return true
	return false

# --- recognition and readout ----------------------------------------------

func _recognise(node_id: int) -> void:
	var r := EngAssemblies.recognize(graph, node_id)
	(graph.node(node_id) as EngGraph.EngNode).assembly_id = 0
	if bool(r["recognized"]):
		assembly_recognised.emit(node_id, String(r["name"]))
		notice.emit("recognised: %s" % String(r["name"]))


## The in-world readout for whatever the player is looking at. This is the
## primary engineering UI: one function, a couple of lines, shown next to the
## crosshair rather than behind a menu.
func describe_target(node_id: int) -> String:
	var n := graph.node(node_id)
	if n == null:
		return ""
	var lines := PackedStringArray()
	var r := EngAssemblies.recognize(graph, node_id)
	var label := n.component_id
	if bool(r["recognized"]):
		label = String(r["name"])
	elif String(r["hint"]) != "":
		label = String(r["hint"])
	lines.append(label)
	if n.part != null:
		lines.append("%s %s  %.0fx%.0fx%.0f mm  q%.2f" % [n.part.material,
			EngPart.SHAPE_NAMES.get(n.part.shape, "?"),
			n.part.size.x * 1000.0, n.part.size.y * 1000.0,
			n.part.size.z * 1000.0, n.part.quality])
		if n.part.temperature > 60.0:
			lines.append("%.0f C" % n.part.temperature)
	for kind in [EngPorts.Kind.ELECTRICAL, EngPorts.Kind.MECHANICAL,
			EngPorts.Kind.FLUID]:
		var net := graph.network_of(node_id, kind)
		if net == 0:
			continue
		lines.append(sim.describe_network(net))
	return "\n".join(lines)

## The numeric readout for whatever the player is looking at: exact
## dimensions, quality, temperature and the tolerance-relevant state. Shown
## only above the ASSISTED interaction level, because a beginner does not need
## it and an engineer cannot do without it.
func exact_for(node_id: int) -> String:
	var n := graph.node(node_id)
	if n == null:
		return ""
	var lines := PackedStringArray()
	if n.part != null:
		lines.append("%.0f x %.0f x %.0f mm" % [n.part.size.x * 1000.0,
			n.part.size.y * 1000.0, n.part.size.z * 1000.0])
		lines.append("q %.2f   %s   %.0f C" % [n.part.quality, n.part.material,
			n.part.temperature])
	lines.append("mass %.3f   ops %d" % [n.part.mass() if n.part != null else 0.0,
		n.part.operations.size() if n.part != null else 0])
	return "\n".join(lines)


# --- visuals ---------------------------------------------------------------

## Stream visuals. Components near a player get a mesh built from their part
## data; distant ones give theirs back. Nothing here ever creates a physics
## body, which is the rule that keeps ten thousand bolts affordable.
func _update_visuals(player_positions: Array) -> void:
	if visuals == null or not is_instance_valid(visuals):
		return
	var live := {}
	var budget := MAX_VISUALS
	for n in graph.all_nodes():
		var node_ref: EngGraph.EngNode = n
		if not _near(node_ref.position, player_positions, VISUAL_RANGE):
			continue
		live[node_ref.id] = true
		if _visuals.has(node_ref.id):
			continue
		if budget <= 0:
			break
		budget -= 1
		var part: EngPart = node_ref.part
		if part == null:
			part = _stock_part(node_ref.component_id)
		var mi := EngGeometry.instance_for(part, node_ref.position,
			node_ref.rotation_y)
		visuals.add_child(mi)
		_visuals[node_ref.id] = mi
	# Anything out of range gives its mesh back to the cache.
	for id in _visuals.keys():
		if not live.has(id):
			_drop_visual(int(id))


func _near(pos: Vector3, players: Array, radius: float) -> bool:
	if players.is_empty():
		return false
	for p in players:
		if (p as Vector3).distance_to(pos) <= radius:
			return true
	return false


func _drop_visual(node_id: int) -> void:
	if not _visuals.has(node_id):
		return
	var mi = _visuals[node_id]
	if mi != null and is_instance_valid(mi):
		mi.queue_free()
	_visuals.erase(node_id)


func visual_count() -> int:
	return _visuals.size()

# --- persistence -----------------------------------------------------------

func serialize() -> Dictionary:
	return {
		"version": 1,
		"graph": graph.serialize(),
		"cursor_level": cursor_level,
		"society": society.serialize(),
	}


## Restore from a save. A world saved before the engineering system existed
## simply has no section, and that is not an error.
func deserialize(data: Dictionary) -> Dictionary:
	var report := {"nodes": 0, "edges": 0, "skipped": 0}
	if not data.has("graph"):
		return report
	cursor_level = int(data.get("cursor_level", cursor_level))
	var r := graph.deserialize(data["graph"])
	report["nodes"] = int(r["nodes"])
	report["edges"] = int(r["edges"])
	report["skipped"] = int(r["skipped"])
	for id in _visuals.keys():
		_drop_visual(int(id))
	_visuals_dirty = true
	if data.get("society", null) is Dictionary:
		society.deserialize(data["society"])
	return report


## Drop everything. Used when switching dimension, so the Deeps does not carry
## the overworld's factory in memory.
func clear() -> void:
	for id in _visuals.keys():
		_drop_visual(int(id))
	_visuals.clear()
	graph.clear()
	_visuals_dirty = true
