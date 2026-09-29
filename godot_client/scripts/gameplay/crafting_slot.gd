extends PanelContainer
## Drag-and-drop behaviour for one crafting slot.
##
## Attached to every slot in CraftingPanel (the 9 grid cells, the result slot
## and the inventory strip). Godot's Control drag-and-drop needs the three
## _get_drag_data / _can_drop_data / _drop_data virtuals, and they have to
## live on the node that is actually dragged, so they are factored out here
## rather than written three times in the panel.
##
## Slot roles are read from metadata set by CraftingPanel:
##   "grid"   -- a cell of the 3x3 grid; drops set the cell
##   "result" -- the output; drops on it collect the craft
##   "strip"  -- the inventory palette; drops on it are ignored

var panel: CraftingPanel = null


func _ready() -> void:
	# A slot created by the panel is given its panel immediately; a slot
	# created by hand in a test finds it by walking up the tree.
	if panel == null:
		var p := get_parent()
		while p != null and not (p is CraftingPanel):
			p = p.get_parent()
		panel = p as CraftingPanel


func _block_id() -> int:
	return int(get_meta("block_id", ContentDB.AIR))


func _get_drag_data(_at_position: Vector2) -> Variant:
	# The result slot is a drop target only: dropping a block on it collects
	# the craft. It is not a drag source, so the output cannot be picked up
	# and accidentally dumped somewhere with no meaning.
	if str(get_meta("kind", "grid")) == "result":
		return null
	var id := _block_id()
	if id == ContentDB.AIR or panel == null:
		return null
	var preview := ColorRect.new()
	preview.color = ContentDB.color_of(id)
	preview.custom_minimum_size = Vector2(32, 32)
	preview.size = Vector2(32, 32)
	var holder := Control.new()
	holder.add_child(preview)
	preview.position = Vector2(-16, -16)
	set_drag_preview(holder)

	# The payload is just the block id; the receiving slot decides what it
	# means, which keeps the three slot roles from needing their own payloads.
	return {"kind": "crafting_block", "block_id": id}


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if panel == null or not (data is Dictionary):
		return false
	var d: Dictionary = data
	if str(d.get("kind", "")) != "crafting_block":
		return false
	match str(get_meta("kind", "grid")):
		"grid", "result":
			return true
		_:
			return false


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if panel == null or not (data is Dictionary):
		return
	var d: Dictionary = data
	var id := int(d.get("block_id", ContentDB.AIR))
	if id == ContentDB.AIR:
		return
	var kind := str(get_meta("kind", "grid"))
	if kind == "grid":
		panel.set_cell(int(get_meta("index", 0)), id)
	elif kind == "result":
		panel.take_result()
