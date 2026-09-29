class_name EngPart
extends RefCounted
## Layer 3 of the engineering system: the procedural part representation.
##
## A manufactured object is DATA, not an asset. There is no mesh file per part
## and no "shaft.glb": a part is a base shape plus dimensions, material, the
## list of manufacturing operations applied to it, and the surface state those
## operations left behind. The visual is generated from that data, and because
## the data is small it serializes into a blueprint without dragging meshes
## along.
##
## This is what makes "cut a custom wooden piece" expressible: you do not pick
## from a list of chair legs, you start from a plank and apply cut, cut, drill.

## Base shapes the geometry generator knows how to build.
enum Shape { PLANK, ROD, PLATE, TUBE, BLOCK, RING, WEDGE }

const SHAPE_NAMES := {
	Shape.PLANK: "plank", Shape.ROD: "rod", Shape.PLATE: "plate",
	Shape.TUBE: "tube", Shape.BLOCK: "block", Shape.RING: "ring",
	Shape.WEDGE: "wedge",
}

## A placed, manufacturable thing.
var shape: int = Shape.PLANK
## Extent in blocks. A plank is long and thin; a plate is wide and thin.
var size := Vector3(1.0, 0.1, 0.1)
var material := "wood"
## Ordered list of applied manufacturing operation ids, for display and for
## re-deriving surface properties after a save.
var operations: Array[String] = []
## 0..1. Derived from the operations, stored so a save does not have to replay
## the whole manufacturing history to know how good the part is.
var quality := 0.5
## Holes, countersinks, threads and slots, as {x, y, z, radius, depth}.
var holes: Array = []
## 0..1 per surface axis, from finishing operations.
var surface_finish := 0.0
## What this part is, once recognised: a component id, or "" if it is stock.
var component_id := ""
## Where the part came from, for provenance and for the UI.
var label := ""
## Player-authored geometry, the one thing that must be remembered verbatim.
var custom_dimensions := false
## Degrees C. Starts at ambient and is only changed by thermal processes
## (EngProcesses.heat / cool), which is what the needs_heat gate reads. A cold
## part cannot be forged; that is the whole point of having furnaces.
var temperature := 20.0


static func shape_from_name(n: String) -> int:
	for k in SHAPE_NAMES.keys():
		if String(SHAPE_NAMES[k]) == n:
			return int(k)
	return Shape.PLANK


func volume() -> float:
	return maxf(size.x * size.y * size.z, 0.0)


func mass() -> float:
	return EngMaterials.mass_of(material, volume())


## Bounding half-extent, used for collision and snapping.
func half_extent() -> Vector3:
	return size * 0.5


## Surface finish improves with each finishing operation applied.
func apply_finish(amount: float) -> void:
	surface_finish = clampf(surface_finish + amount, 0.0, 1.0)


## Recompute quality from the operation history. Deterministic, so a part
## restored from a save has the same quality it had before.
func recompute_quality() -> void:
	var q := 0.5
	for op in operations:
		var def: Dictionary = EngProcesses.operation(op)
		if def.is_empty():
			continue
		# Each operation nudges quality; bad ones (melt, press) lower it
		# slightly, precise ones (polish, drill, grind) raise it.
		q += float(def.get("quality_delta", 0.0))
	q = clampf(q, 0.0, 1.0)
	quality = q


## Record that a manufacturing operation was applied, updating the geometry and
## the quality. Does not validate -- that is EngProcesses.apply_operation's job.
func record_operation(op_id: String, params := {}) -> void:
	operations.append(op_id)
	match op_id:
		"cut":
			# A cut shortens the part along the axis it was made from.
			var axis := String(params.get("axis", "x"))
			var at := float(params.get("at", 0.5))
			_apply_cut(axis, at)
		"heat":
			temperature = maxf(temperature,
				float(params.get("to", temperature)))
		"drill":
			holes.append({
				"pos": params.get("pos", Vector3(size.x * 0.5, size.y * 0.5,
					size.z * 0.5)),
				"radius": float(params.get("radius", 0.05)),
				"depth": float(params.get("depth", size.y)),
			})
		"polish":
			apply_finish(0.2)
		"grind":
			apply_finish(0.1)
		"heat_treat":
			# Quenching after a soak resets the work-hardening, and the part
			# is left hot: it still has to cool before it is handled safely.
			temperature = 60.0
		"cast", "forge":
			# Shaping from a melt loses a little precision.
			quality = clampf(quality - 0.05, 0.0, 1.0)
	recompute_quality()


func _apply_cut(axis: String, at: float) -> void:
	var a := clampf(at, 0.05, 0.95)
	match axis:
		"x": size.x *= a
		"y": size.y *= a
		"z": size.z *= a


func to_dict() -> Dictionary:
	return {
		"shape": shape, "size": [size.x, size.y, size.z], "material": material,
		"operations": Array(operations), "quality": quality, "holes": holes,
		"surface_finish": surface_finish, "component_id": component_id,
		"label": label, "custom_dimensions": custom_dimensions,
		"temperature": temperature,
	}


static func from_dict(d: Dictionary) -> EngPart:
	var p := EngPart.new()
	p.shape = int(d.get("shape", Shape.PLANK))
	var s: Array = d.get("size", [1.0, 0.1, 0.1])
	if s.size() == 3:
		p.size = Vector3(float(s[0]), float(s[1]), float(s[2]))
	p.material = String(d.get("material", "wood"))
	p.operations.assign(d.get("operations", []))
	p.quality = float(d.get("quality", 0.5))
	p.holes.assign(d.get("holes", []))
	p.surface_finish = float(d.get("surface_finish", 0.0))
	p.component_id = String(d.get("component_id", ""))
	p.label = String(d.get("label", ""))
	p.custom_dimensions = bool(d.get("custom_dimensions", false))
	p.temperature = float(d.get("temperature", 20.0))
	return p


## Factories for the shapes the manufacturing system starts from.
static func plank(material_id: String, length := 1.2) -> EngPart:
	var p := EngPart.new()
	p.shape = Shape.PLANK
	p.material = material_id
	p.size = Vector3(length, 0.12, 0.12)
	p.label = "%s plank" % material_id
	p.recompute_quality()
	return p


static func plate(material_id: String, side := 0.4) -> EngPart:
	var p := EngPart.new()
	p.shape = Shape.PLATE
	p.material = material_id
	p.size = Vector3(side, side, 0.03)
	p.label = "%s plate" % material_id
	p.recompute_quality()
	return p


static func rod(material_id: String, length := 0.6, diameter := 0.06) -> EngPart:
	var p := EngPart.new()
	p.shape = Shape.ROD
	p.material = material_id
	p.size = Vector3(length, diameter, diameter)
	p.label = "%s rod" % material_id
	p.recompute_quality()
	return p


static func block(material_id: String, ext := 0.1) -> EngPart:
	var p := EngPart.new()
	p.shape = Shape.BLOCK
	p.material = material_id
	p.size = Vector3(ext, ext, ext)
	p.label = "%s block" % material_id
	p.recompute_quality()
	return p
