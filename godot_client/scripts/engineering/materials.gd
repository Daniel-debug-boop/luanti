class_name EngMaterials
extends RefCounted
## Layer 1 of the engineering system: data-driven material definitions.
##
## Every property is a plain float so the tables stay data-driven: adding a
## material is a new dictionary entry, never new engine code. Values are
## simplified to produce believable gameplay rather than to mirror reality --
## "electrical_conductivity" is a 0..1 rating, not siemens per metre, because
## the simulation only needs relative ordering to feel right.
##
## Registration is open (see EngModding) so a mod can add a material without
## touching this file.

## Property names, in one place so typos surface immediately.
const PROPS := [
	"density",                  # kg/m3, scaled 0..1 for gameplay mass
	"hardness",                 # 0..1, resists cutting
	"strength",                 # 0..1, load before structural failure
	"toughness",                # 0..1, resists fracture
	"elasticity",               # 0..1, how much it springs back
	"electrical_conductivity",  # 0..1
	"thermal_conductivity",     # 0..1
	"heat_capacity",            # 0..1
	"melting_temperature",      # deg C, real-ish so smelting ordering is sane
	"corrosion_resistance",     # 0..1
	"friction",                 # 0..1
	"flammability",             # 0..1
	"manufacturing_difficulty", # 0..1, gates which processes can shape it
]

## Used for any property a definition omits, so every material is total.
const DEFAULTS := {
	"density": 0.5, "hardness": 0.5, "strength": 0.5, "toughness": 0.5,
	"elasticity": 0.2, "electrical_conductivity": 0.0,
	"thermal_conductivity": 0.2, "heat_capacity": 0.5,
	"melting_temperature": 1000.0, "corrosion_resistance": 0.3,
	"friction": 0.5, "flammability": 0.0, "manufacturing_difficulty": 0.1,
}

## id -> property dictionary (complete, defaults filled in).
static var _materials := {}
static var _order: Array[String] = []
## Re-entrancy guard: the stock table is registered through register_material,
## so without this the first call would recurse forever.
static var _building := false


static func _ensure_built() -> void:
	if _building or not _materials.is_empty():
		return
	_building = true
	# The stock families. Values are tuned for gameplay, not fidelity.
	var table := {
		"wood": {
			"density": 0.15, "hardness": 0.20, "strength": 0.35,
			"toughness": 0.25, "elasticity": 0.45, "friction": 0.6,
			"flammability": 0.9, "melting_temperature": 300.0,
			"manufacturing_difficulty": 0.0,
		},
		"stone": {
			"density": 0.85, "hardness": 0.55, "strength": 0.55,
			"toughness": 0.4, "friction": 0.7, "corrosion_resistance": 0.8,
			"melting_temperature": 1400.0, "manufacturing_difficulty": 0.15,
		},
		"clay": {
			"density": 0.6, "hardness": 0.2, "strength": 0.2,
			"toughness": 0.15,
			"melting_temperature": 900.0, "manufacturing_difficulty": 0.1,
		},
		"glass": {
			"density": 0.4, "hardness": 0.35, "strength": 0.25,
			"toughness": 0.05, "elasticity": 0.0, "corrosion_resistance": 0.9,
			"melting_temperature": 1500.0, "manufacturing_difficulty": 0.2,
		},
		"copper": {
			"density": 0.7, "hardness": 0.35, "strength": 0.5,
			"toughness": 0.45, "elasticity": 0.3,
			"electrical_conductivity": 0.98, "thermal_conductivity": 0.9,
			"heat_capacity": 0.4, "melting_temperature": 1085.0,
			"corrosion_resistance": 0.25, "friction": 0.3,
			"manufacturing_difficulty": 0.3,
		},
		"aluminum": {
			"density": 0.35, "hardness": 0.3, "strength": 0.45,
			"toughness": 0.35, "elasticity": 0.3,
			"electrical_conductivity": 0.85, "thermal_conductivity": 0.85,
			"heat_capacity": 0.5, "melting_temperature": 660.0,
			"corrosion_resistance": 0.6, "friction": 0.3,
			"manufacturing_difficulty": 0.3,
		},
		"iron": {
			"density": 0.8, "hardness": 0.6, "strength": 0.65,
			"toughness": 0.6, "elasticity": 0.2,
			"electrical_conductivity": 0.55, "thermal_conductivity": 0.6,
			"heat_capacity": 0.6, "melting_temperature": 1538.0,
			"corrosion_resistance": 0.3, "friction": 0.45,
			"manufacturing_difficulty": 0.4,
		},
		"steel": {
			"density": 0.78, "hardness": 0.7, "strength": 0.9,
			"toughness": 0.8, "elasticity": 0.15,
			"electrical_conductivity": 0.35, "thermal_conductivity": 0.45,
			"heat_capacity": 0.55, "melting_temperature": 1670.0,
			"corrosion_resistance": 0.55, "friction": 0.4,
			"manufacturing_difficulty": 0.5,
		},
		"stainless_steel": {
			"density": 0.8, "hardness": 0.75, "strength": 0.95,
			"toughness": 0.85, "elasticity": 0.12,
			"electrical_conductivity": 0.3, "thermal_conductivity": 0.4,
			"heat_capacity": 0.5, "melting_temperature": 1700.0,
			"corrosion_resistance": 0.95, "friction": 0.35,
			"manufacturing_difficulty": 0.6,
		},
		"rubber": {
			"density": 0.25, "hardness": 0.15, "strength": 0.25,
			"toughness": 0.5, "elasticity": 0.9, "friction": 0.95,
			"heat_capacity": 0.7, "melting_temperature": 200.0,
			"manufacturing_difficulty": 0.25,
		},
		"plastic": {
			"density": 0.2, "hardness": 0.2, "strength": 0.3,
			"toughness": 0.3, "elasticity": 0.4, "friction": 0.4,
			"heat_capacity": 0.6, "melting_temperature": 350.0,
			"manufacturing_difficulty": 0.2,
		},
		"carbon": {
			"density": 0.4, "hardness": 0.8, "strength": 0.85,
			"toughness": 0.6, "elasticity": 0.05,
			"electrical_conductivity": 0.5, "thermal_conductivity": 0.7,
			"heat_capacity": 0.3, "melting_temperature": 3600.0,
			"corrosion_resistance": 1.0, "manufacturing_difficulty": 0.7,
		},
		"silicon": {
			"density": 0.5, "hardness": 0.65, "strength": 0.4,
			"toughness": 0.3, "elasticity": 0.0,
			"electrical_conductivity": 0.1, "thermal_conductivity": 0.6,
			"heat_capacity": 0.4, "melting_temperature": 1414.0,
			"corrosion_resistance": 0.9, "manufacturing_difficulty": 0.75,
		},
	}
	for id in table:
		register_material(String(id), table[id])
	_building = false


## Add or replace a material. Only the keys present in `def` are overridden;
## everything else falls back to DEFAULTS, so a definition can be one line.
static func register_material(id: String, def: Dictionary) -> void:
	_ensure_built()
	var merged := DEFAULTS.duplicate()
	for k in def.keys():
		# "color" is the one non-numeric field, so it is copied verbatim.
		if k == "color":
			merged[k] = def[k]
			continue
		# An unknown key is a typo, not a new property: reject it loudly.
		if not DEFAULTS.has(k):
			push_warning("[materials] unknown property '%s' on '%s'" % [k, id])
			continue
		merged[k] = float(def[k])
	merged["id"] = id
	if def.has("color"):
		merged["color"] = def["color"]
	else:
		merged["color"] = Color(0.6, 0.6, 0.6)
	if not _materials.has(id):
		_order.append(id)
	_materials[id] = merged


static func has(id: String) -> bool:
	_ensure_built()
	return _materials.has(id)


## A property of a material, or the default when it is unknown.
static func get_prop(id: String, prop: String) -> float:
	_ensure_built()
	if not _materials.has(id):
		return float(DEFAULTS.get(prop, 0.0))
	return float(_materials[id].get(prop, DEFAULTS.get(prop, 0.0)))


## Every property as a Dictionary. The caller's copy is independent.
static func props_of(id: String) -> Dictionary:
	_ensure_built()
	if not _materials.has(id):
		return DEFAULTS.duplicate()
	return _materials[id].duplicate()


static func all_ids() -> Array[String]:
	_ensure_built()
	return _order.duplicate()


static func color_of(id: String) -> Color:
	_ensure_built()
	if not _materials.has(id):
		return Color(0.6, 0.6, 0.6)
	return _materials[id].get("color", Color(0.6, 0.6, 0.6))


## Mass of a part in arbitrary gameplay units, from material density and
## volume in cubic blocks.
static func mass_of(id: String, volume: float) -> float:
	return get_prop(id, "density") * maxf(volume, 0.0)


## A material can be shaped by a process only if it is not too hard or too
## brittle for the tool. Drives manufacturing_difficulty checks.
static func is_machinable(id: String, tool_difficulty: float) -> bool:
	return get_prop(id, "manufacturing_difficulty") <= tool_difficulty + 0.001


## Serializable form, so the whole table can live in a save file and be
## restored (and migrated) later.
static func serialize() -> Dictionary:
	_ensure_built()
	var out := {}
	for id in _materials.keys():
		var d: Dictionary = _materials[id].duplicate()
		d.erase("id")
		out[id] = d
	return {"version": 1, "materials": out}


## Restore a serialized table, keeping any material the save does not know
## about (forward compatibility) and reporting unknown ones.
static func deserialize(data: Dictionary) -> Dictionary:
	_ensure_built()
	var report := {"restored": 0, "unknown": []}
	if not data.has("materials"):
		return report
	var saved: Dictionary = data["materials"]
	for id in saved.keys():
		if not _materials.has(String(id)):
			(report["unknown"] as Array).append(String(id))
			continue
		# Merge property by property so a save from an older version that
		# omitted a newly added property still restores cleanly.
		var merged: Dictionary = _materials[id].duplicate()
		var src: Dictionary = saved[id]
		for k in src.keys():
			if k == "color":
				merged[k] = src[k]
			elif DEFAULTS.has(k):
				merged[k] = float(src[k])
		_materials[id] = merged
		report["restored"] = int(report["restored"]) + 1
	return report
