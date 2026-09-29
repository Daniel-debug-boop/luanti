class_name EngItems
extends RefCounted
## The bridge between the engineering system and the player's inventory.
##
## Every component, tool and refined material is an inventory item, in the
## SAME GLoot backpack the blocks are in. There is deliberately no second
## container: a second one would double the UI, double the save format and
## double the places a desync can hide, and the player would have to learn two
## rules about where things live.
##
## This file answers three questions and nothing else:
##   * what items exist
##   * what an item is worth (its bill of materials, for manufacturing)
##   * what an item costs when it is simply bought in a recipe

## Component ids the player can carry as items. Everything in the library is
## carried: a component you cannot hold is a component you cannot build with.
static var _extra := {}
static var _known := false


static func all_item_ids() -> Array[String]:
	_ensure()
	var out: Array[String] = []
	out.append_array(EngTools.all_ids())
	for id in EngPorts.all_ids():
		out.append(id)
	for id in _extra.keys():
		if not out.has(String(id)):
			out.append(String(id))
	out.sort()
	return out


static func has(item: String) -> bool:
	_ensure()
	return all_item_ids().has(item)


## Is this item a tool the player can equip?
static func is_tool(item: String) -> bool:
	return EngTools.get_tool(item) != null


## Is this item a component that can be placed in the world?
static func is_component(item: String) -> bool:
	return EngPorts.has(item)


## Display name, colour and category for the HUD and the hotbar.
static func info(item: String) -> Dictionary:
	_ensure()
	if _extra.has(item):
		return (_extra[item] as Dictionary).duplicate(true)
	if is_tool(item):
		var t := EngTools.get_tool(item)
		return {"name": t.name.capitalize(), "color": Color(0.7, 0.7, 0.75),
			"category": "tool", "process": t.process}
	if EngPorts.has(item):
		var c := EngPorts.get_def(item)
		return {"name": item.replace("_", " ").capitalize(),
			"color": EngMaterials.color_of(c.material),
			"category": c.category, "material": c.material}
	return {"name": item.capitalize(), "color": Color(0.6, 0.6, 0.6),
		"category": "item"}


## Register an extra item a mod wants carryable without it being a component
## or a tool -- a refined material, a consumable, a custom blueprint token.
static func register_item(item: String, info := {}) -> void:
	_ensure()
	if item == "":
		return
	_extra[item] = info.duplicate(true)
	_known = false


## The bill of materials for one component, as a list of item -> count.
##
## A motor is not "unlocked"; it is copper wire, an iron housing, a shaft and
## a bearing. This is the only place that says so, and it is expressed in
## components rather than raw blocks, so a player who has built a better
## workshop can substitute.
static func bill_for(component_id: String) -> Dictionary:
	if not EngPorts.has(component_id):
		return {}
	# The workbench is the exception that starts the game. Everything else is
	# built from components, which is the whole point -- but a component
	# needs a tool, and a tool needs a workbench, so the very first station
	# has to be something a player can nail together out of what they mined.
	if component_id == "workbench":
		return {"wood": 8}
	var c := EngPorts.get_def(component_id)
	var bill := {}
	match c.category:
		"fastening":
			bill["steel"] = 2
		"electrical":
			if c.material == "copper":
				bill["copper"] = 2
			else:
				bill["steel"] = 2
		"mechanical":
			bill[c.material] = 2
		"fluid":
			bill[c.material] = 2
		"machine":
			# A real machine is a real build: its own material, plus the
			# parts it is obviously made of. This is where the progression
			# is felt: a motor is copper, iron and a shaft, not a click.
			bill[c.material] = 4
			bill["shaft"] = 1
			if c.material != "steel":
				bill["steel"] = 2
		"workstation":
			# A station is built, not unlocked: enough stock to stand it up.
			bill["wood" if c.material == "wood" else "stone"] = 8
			bill["plate"] = 4
			bill["bolt"] = 4
			if c.material != "wood":
				bill["iron"] = 4
		_:
			bill[c.material] = 2
	# Drop anything the world cannot supply, so a modded material does not
	# silently become an unobtainable requirement.
	for k in bill.keys():
		if int(bill[k]) <= 0:
			bill.erase(k)
	return bill


## How much refined material one component consumes, in the abstract units the
## material system uses. This is what a machine draws from its input when it
## builds something itself.
static func material_cost_of(component_id: String) -> float:
	if not EngPorts.has(component_id):
		return 0.0
	return EngPorts.get_def(component_id).material_cost


## The material a component is made of, so the workshop knows what to feed in.
static func material_of(component_id: String) -> String:
	if EngPorts.has(component_id):
		return EngPorts.get_def(component_id).material
	return "steel"


## Can the player build this right now, from what they are carrying?
## Returns { ok, missing } so the UI can show the gap rather than a refusal.
static func can_build(inventory: PlayerInventory, component_id: String) -> Dictionary:
	var bill := bill_for(component_id)
	var missing := {}
	if inventory != null:
		for item in bill.keys():
			var need := int(bill[item])
			var have := inventory.count_bill_item(String(item))
			if have < need:
				missing[String(item)] = need - have
	return {"ok": missing.is_empty(), "missing": missing, "bill": bill}


## The refined stock a material name corresponds to as a world block, or "".
## Bills are written in material names; this is what turns "copper" into the
## block the player actually smelted and is carrying.
const STOCK_BLOCK := {
	"copper": "copper_block", "iron": "iron_block", "steel": "steel_block",
	"brass": "brass_block", "wood": "wood", "stone": "stone", "clay": "dirt",
}


## The ContentDB block name a material is carried as, or "". Bills are written
## in material names ("copper") and this is the bridge to the world block the
## player actually smelted, so the refined metal travels through the ordinary
## inventory rather than needing a parallel one.
static func stock_name(material: String) -> String:
	return String(STOCK_BLOCK.get(material, ""))


## Whether a material is something the voxel world can actually supply. A
## modded material with no block is still usable, but only by a player who
## already has a component made of it.
static func is_world_material(material: String) -> bool:
	return stock_name(material) != ""


## The ContentDB id a bill entry refers to, or -1. Resolution order matters:
## a component name wins over a material name, because "steel" is a stock the
## player carries and "shaft" is a thing they built.
static func block_id_for(item: String) -> int:
	if is_component(item) or is_tool(item):
		return -1
	return ContentDB.name_to_id(stock_name(item))


static func _ensure() -> void:
	if _known:
		return
	_known = true
	# Touch the tables so the item list is complete even if nothing else has
	# read them yet. The order matters: tools are built from the process
	# table, which is independent, and the component list is static.
	EngPorts.all_ids()
	EngTools.all_ids()
