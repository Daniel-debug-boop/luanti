class_name PlayerInventory
extends Node
## Player inventory and hotbar, built on the prebuilt **GLoot** addon
## (`addons/gloot`, MIT, v3.0.1, Godot 4.4).
##
## GLoot provides the container model, the protoset/prototype item database,
## capacity constraints, slots and item serialization. This file is only the
## glue: it turns ContentDB block ids into GLoot prototypes, keeps an 8-slot
## hotbar, and connects mining/placing to it.
##
## Two GLoot behaviours that shape this file, both verified against the addon
## source rather than assumed:
##   * A GLoot `ItemSlot` owns a *private* one-item container. `equip()` moves
##     the item out of the backpack into the slot. The hotbar is therefore a
##     set of single-item holders, not a view onto the backpack.
##   * An `InventoryConstraint` registers by being **parented** to an
##     `Inventory`; there is no `add_constraint()` method.
##
## Stacking is explicit: one GLoot item per block type carries a `count`
## property, rather than relying on GLoot's stack manager.

const GLootInventory := preload("res://addons/gloot/core/inventory.gd")
const GLootItemSlot := preload("res://addons/gloot/core/item_slot.gd")
const GLootItemCount := preload("res://addons/gloot/core/constraints/item_count_constraint.gd")

const HOTBAR_SIZE := 8
## Backpack capacity, in distinct item stacks.
const BACKPACK_CAPACITY := 32
## Ceiling on one block stack.
const MAX_STACK := 999
## Prefix for generated prototype ids, so they never collide with other sets.
const BLOCK_PREFIX := "block_"

## GLoot container holding everything not currently held in a hotbar slot.
var inventory: Inventory
## One GLoot ItemSlot per hotbar position.
var hotbar: Array[ItemSlot] = []
var protoset: JSON = null

var selected := 0
## Emitted with the new index whenever the hotbar selection moves.
signal selection_changed(index: int)
## Emitted with (block_id, new_total) whenever the player gains blocks.
signal item_gained(block_id: int, total: int)
## Emitted with the block id whenever the player places one.
signal item_used(block_id: int)


func _init() -> void:
	protoset = _build_protoset()

	inventory = GLootInventory.new()
	inventory.name = "Backpack"
	inventory.protoset = protoset
	var cap: ItemCountConstraint = GLootItemCount.new()
	cap.name = "Capacity"
	cap.capacity = BACKPACK_CAPACITY
	# Parenting is what registers the constraint.
	inventory.add_child(cap)
	add_child(inventory)

	for i in HOTBAR_SIZE:
		var slot: ItemSlot = GLootItemSlot.new()
		slot.name = "Hotbar%d" % i
		# protoset first: GLoot compares protoset identity in can_hold_item(),
		# and the inventory setter re-applies the protoset to the slot's own
		# container.
		slot.protoset = protoset
		add_child(slot)
		hotbar.append(slot)


## "block_3" for ContentDB id 3.
static func prototype_id(block_id: int) -> String:
	return BLOCK_PREFIX + str(block_id)


## ContentDB id for a prototype id, or -1.
static func block_id_of(proto_id: String) -> int:
	if not proto_id.begins_with(BLOCK_PREFIX):
		return -1
	return int(proto_id.substr(BLOCK_PREFIX.length()))


## One GLoot prototype per placeable block, carrying what the HUD and the drop
## entities need (name, colour, hardness, stack size).
func _build_protoset() -> JSON:
	var data := {}
	for id in range(1, 32):
		var entry := ContentDB.get_entry(id)
		if entry == null or entry.name == "air":
			continue
		var c := entry.color
		data[prototype_id(id)] = {
			"display_name": entry.name,
			# GLoot parses string property values with str_to_var(), so numbers
			# and colours have to travel in their var-encoded string form.
			"block_id": str(id),
			"color": "Color(%f, %f, %f, %f)" % [c.r, c.g, c.b, c.a],
			"hardness": "%.3f" % entry.hardness,
			"max_stack": str(MAX_STACK),
		}
	var j := JSON.new()
	j.data = data
	return j


# --- stacking helpers -------------------------------------------------------

## Find an item carrying `block_id` anywhere: hotbar first, then backpack.
func _find_item(block_id: int) -> InventoryItem:
	var proto := prototype_id(block_id)
	for slot in hotbar:
		var held := slot.get_item()
		if held != null and held.get_prototype().get_id() == proto:
			return held
	for item in inventory.get_items():
		if item.get_prototype().get_id() == proto:
			return item
	return null


# --- mining / placing -------------------------------------------------------

## Called when a block is mined. Adds it to the backpack, stacking onto an
## existing pile, and holds it if the selected hotbar slot is empty.
## Returns the block id gained, or -1 when it could not be stored.
func give_block(block_id: int) -> int:
	if block_id == ContentDB.AIR:
		return -1
	if not protoset.data.has(prototype_id(block_id)):
		return -1

	var existing := _find_item(block_id)
	if existing != null:
		var n := int(existing.get_property("count", 1))
		if n < MAX_STACK:
			existing.set_property("count", n + 1)
			item_gained.emit(block_id, n + 1)
			return block_id
		return -1   # that stack is full; refuse rather than lose the block

	var item: InventoryItem = inventory.create_and_add_item(prototype_id(block_id))
	if item == null:
		return -1
	item.set_property("count", 1)
	var slot := get_selected_slot()
	if slot != null and slot.get_item() == null:
		slot.equip(item)
	item_gained.emit(block_id, 1)
	return block_id


## Called when a block is placed. Consumes one from the selected slot.
## Returns the block id placed, or -1 when the slot is empty.
func consume_selected() -> int:
	var slot := get_selected_slot()
	if slot == null:
		return -1
	var item := slot.get_item()
	if item == null:
		return -1
	var block_id := block_id_of(item.get_prototype().get_id())
	if block_id < 0:
		slot.clear()
		return -1
	var stack: int = int(item.get_property("count", 1))
	if stack <= 1:
		slot.clear()
	else:
		item.set_property("count", stack - 1)
	item_used.emit(block_id)
	return block_id


## Consume `n` of a specific block from anywhere it is held (hotbar first,
## then backpack). Returns how many were actually removed, so a caller can
## check a partial result instead of silently losing items.
func consume_block(block_id: int, n: int = 1) -> int:
	var removed := 0
	while removed < n:
		var item := _find_item(block_id)
		if item == null:
			break
		var stack: int = int(item.get_property("count", 1))
		if stack > 1:
			item.set_property("count", stack - 1)
			removed += 1
			continue
		# Last of the stack: drop the whole item.
		var owner_slot: ItemSlot = null
		for slot in hotbar:
			if slot.get_item() == item:
				owner_slot = slot
				break
		if owner_slot != null:
			owner_slot.clear()
		else:
			inventory.remove_item(item)
		removed += 1
	return removed


## How many of a block the player is carrying, hotbar and backpack together.
func count_of(block_id: int) -> int:
	var item := _find_item(block_id)
	if item == null:
		return 0
	return int(item.get_property("count", 1))


## Distinct block ids the player is carrying, ascending.
func available_blocks() -> Array[int]:
	var seen := {}
	var out: Array[int] = []
	for item in inventory.get_items():
		var bid := block_id_of(item.get_prototype().get_id())
		if bid >= 0 and not seen.has(bid):
			seen[bid] = true
			out.append(bid)
	for slot in hotbar:
		var held := slot.get_item()
		if held == null:
			continue
		var bid := block_id_of(held.get_prototype().get_id())
		if bid >= 0 and not seen.has(bid):
			seen[bid] = true
			out.append(bid)
	out.sort()
	return out


# --- hotbar -----------------------------------------------------------------

func get_selected_slot() -> ItemSlot:
	if selected < 0 or selected >= hotbar.size():
		return null
	return hotbar[selected]


## Select a hotbar slot, wrapping around. Returns the new index.
func select_slot(index: int) -> int:
	var n := hotbar.size()
	if n == 0:
		return 0
	selected = posmod(index, n)
	selection_changed.emit(selected)
	return selected


## Scroll the hotbar by `delta` positions.
func scroll_selection(delta: int) -> int:
	return select_slot(selected + delta)


## Block id in the selected slot, or -1 when it is empty.
func selected_block_id() -> int:
	var slot := get_selected_slot()
	if slot == null:
		return -1
	var item := slot.get_item()
	if item == null:
		return -1
	return block_id_of(item.get_prototype().get_id())


## Move one held block from the selected slot back into the backpack.
func stow_selected() -> bool:
	var slot := get_selected_slot()
	if slot == null:
		return false
	var item := slot.get_item()
	if item == null:
		return false
	var n := int(item.get_property("count", 1))
	slot.clear()
	if n > 1:
		# put the remainder back as its own stack
		var bid := block_id_of(item.get_prototype().get_id())
		var back: InventoryItem = inventory.create_item(prototype_id(bid))
		if back != null:
			back.set_property("count", n - 1)
	return true


## Fill empty hotbar slots with carried blocks that are not already held.
## Without the "already held" filter a block that give_block() already auto-
## equipped (it fills the selected slot first) is picked again here and
## crowds out the block that would otherwise have taken the last free slot.
func fill_hotbar_from_inventory() -> void:
	var held := {}
	for slot in hotbar:
		var item := slot.get_item()
		if item != null:
			held[item.get_prototype().get_id()] = true
	# Filter *before* consuming, so a block that is already held neither takes
	# a slot nor shifts every later block one slot to the left.
	var pending: Array[int] = []
	for bid in available_blocks():
		if not held.has(prototype_id(bid)):
			pending.append(bid)
	for i in hotbar.size():
		if pending.is_empty():
			return
		if hotbar[i].get_item() != null:
			continue
		var item: InventoryItem = inventory.create_item(prototype_id(pending.pop_front()))
		if item != null:
			hotbar[i].equip(item)


## One of every placeable block. Starting kit and test fixture.
func give_starting_kit() -> void:
	for id in [ContentDB.GRASS, ContentDB.DIRT, ContentDB.STONE, ContentDB.SAND,
			ContentDB.WOOD, ContentDB.LEAVES, ContentDB.GLOWSTONE, ContentDB.ICE]:
		give_block(id)
	fill_hotbar_from_inventory()


# --- persistence -----------------------------------------------------------

## GLoot serializes the container, the protoset and every item's overrides.
func serialize() -> Dictionary:
	var slots: Array = []
	for slot in hotbar:
		var item := slot.get_item()
		slots.append(item.serialize() if item != null else null)
	return {
		"selected": selected,
		"backpack": inventory.serialize(),
		"hotbar": slots,
	}


## Restores a serialize() payload. Returns false when the shape is wrong.
func deserialize(data: Dictionary) -> bool:
	if typeof(data.get("backpack")) != TYPE_DICTIONARY:
		return false
	if not inventory.deserialize(data["backpack"]):
		return false
	# deserialize() rebuilds from scratch, so re-apply the protoset and clear
	# the slots before reading them back.
	inventory.protoset = protoset
	for slot in hotbar:
		slot.protoset = protoset
		slot.clear()

	if data.get("hotbar") is Array:
		var slots: Array = data["hotbar"]
		for i in mini(slots.size(), hotbar.size()):
			if typeof(slots[i]) != TYPE_DICTIONARY:
				continue
			var d: Dictionary = slots[i]
			var pid := str(d.get("prototype_id", ""))
			if pid == "" or not protoset.data.has(pid):
				continue
			var item: InventoryItem = inventory.create_item(pid)
			if item == null:
				continue
			hotbar[i].equip(item)
			# Read `count` straight out of the payload rather than calling
			# InventoryItem.deserialize(): that rebuilds the item's protoset
			# from the serialized string, and GLoot's can_hold_item() compares
			# protosets by identity, so a swapped-in protoset breaks every
			# later equip on that slot.
			var n := _count_from_serialized(d)
			if n != 1:
				item.set_property("count", n)
	select_slot(int(data.get("selected", 0)))
	return true


## Pull the `count` override out of a GLoot item payload.
## Properties are stored as {"type": TYPE_INT, "value": "<var_to_str>"} so the
## save file stays JSON-safe.
func _count_from_serialized(d: Dictionary) -> int:
	if typeof(d.get("properties")) != TYPE_DICTIONARY:
		return 1
	var props: Dictionary = d["properties"]
	if typeof(props.get("count")) != TYPE_DICTIONARY:
		return 1
	var entry: Dictionary = props["count"]
	var raw := str(entry.get("value", ""))
	if raw == "":
		return 1
	var parsed: Variant = str_to_var(raw)
	return int(parsed) if parsed != null else 1
