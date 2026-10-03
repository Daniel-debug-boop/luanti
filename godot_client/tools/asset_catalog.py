#!/usr/bin/env python3
"""The single declarative source of truth for every asset in EMERGENT.

Nothing in this repository is downloaded without an entry here. `acquire_assets`
reads this file to fetch, `process_textures` reads it to resample, `make_lods`
reads it to know which models exist, and `asset_report` reads it to write
`assets/THIRD_PARTY_ASSETS.md`. `tools/asset_test.gd` reads the generated
`source_manifest/manifest.json` and fails the build if the two disagree.

Adding an asset means adding an entry here first. That is the whole review
process: the art direction in `assets/ART_DIRECTION.md` is what the entry is
supposed to justify.

Licence position for the whole library: everything is CC0 1.0 Universal, either
from Poly Haven (https://polyhaven.com, CC0) or ambientCG
(https://ambientcg.com, CC0). CC0 imposes no attribution requirement. Both are
credited anyway in `THIRD_PARTY_ASSETS.md`, because provenance is worth
recording even when it is not required.
"""

# --- The resolution ladder -------------------------------------------------
#
# `tiers` is the list of runtime sizes actually written to
# assets/runtime/textures/<set>/<map>_<res>.<ext>. A tier is only ever written
# when it is smaller than the source, so nothing is ever upscaled; the test
# suite fails the build if a tier exceeds its source.

TIERS = [2048, 1024, 512]
"""Runtime resolution ladder, largest first. ULTRA picks the first, HIGH and
MEDIUM the second, LOW the third."""

DETAIL_TIER = 512
"""Detail overlays are surface breakup, not the focal surface, so they ship at
one size only. One texture instead of three for most of the library."""

SOURCE_PX = {"1k": 1024, "2k": 2048, "4k": 4096, "8k": 8192}

TIER_NAMES = {2048: "ULTRA", 1024: "HIGH", 512: "MEDIUM/LOW"}

# Maps requested from a provider, in pipeline order.
SURFACE_MAPS = ["diff", "nor_gl", "arm"]
"""diff = albedo, nor_gl = OpenGL-convention normal (green up), arm = the packed
ambient-occlusion/roughness/metallic map. arm is preferred over three separate
maps because it is one texture instead of three for the same three channels."""

LOD_TARGETS = [(1, 0.45), (2, 0.15)]
"""LOD1 and LOD2 as a fraction of LOD0's triangle count, produced by
`make_lods.py` with vertex-cluster decimation. LOD3 (impostor) is deliberately
not produced: see ART_DIRECTION.md."""

LOD_PROPS = [
    "Barrel_01", "wooden_barrels_01", "wine_barrel_01", "wooden_crate_01",
    "wooden_crate_02", "old_military_crate", "metal_tool_chest",
    "treasure_chest", "street_lamp_01", "Lantern_01", "wooden_lantern_01",
    "painted_wooden_bench", "painted_wooden_stool", "chinese_stool",
    "ceramic_pot", "planter_pot_clay", "potted_plant_01",
]
"""Static village props. These are the models that get LODs. The KayKit
characters in addons/ do not: they are skinned, and decimation of a skinned mesh
breaks at the joints."""


# --- Texture sets ----------------------------------------------------------
#
# `blocks` lists the ContentDB *names* the set is bound to. The GDScript
# validator cross-checks this against MaterialLibrary.texture_set_for(), so a
# set that is downloaded but never bound fails the build, and a block that
# names a set which is not in the manifest also fails the build.

TEXTURES = [
    # --- terrain: the highest screen coverage in the game -------------------
    {
        "id": "aerial_grass_rock", "provider": "polyhaven",
        "source_id": "aerial_grass_rock", "source_res": "4k",
        "hero": True, "category": "terrain",
        "blocks": ["grass"],
        "note": "Grass block albedo. 4K source so ULTRA's 2048 is a real "
                "downsample. The old forrest_ground_01 was a flat top-down "
                "photograph with visible mowing stripes.",
    },
    {
        "id": "forest_leaves_02", "provider": "polyhaven",
        "source_id": "forest_leaves_02", "source_res": "4k",
        "hero": True, "category": "vegetation",
        "blocks": ["leaves"],
        "note": "Leaf clusters for the canopy. Replaces brown_mud_leaves_01, "
                "which is a ground texture and read as mud on a tree.",
    },
    {
        "id": "bark_brown_02", "provider": "polyhaven",
        "source_id": "bark_brown_02", "source_res": "4k",
        "hero": True, "category": "vegetation",
        "blocks": ["wood", "cactus"],
        "note": "Trunks and branches. Replaces brown_mud_leaves_01 for wood, "
                "so a tree stopped being made of the same texture as the "
                "ground under it.",
    },
    # --- terrain carried over from the previous library ---------------------
    {
        "id": "forrest_ground_01", "provider": "polyhaven",
        "source_id": "forrest_ground_01", "source_res": "1k",
        "hero": False, "category": "terrain", "role": "detail",
        "blocks": ["grass"],
        "note": "Forest-floor detail overlay under the grass albedo.",
    },
    {
        "id": "brown_mud_leaves_01", "provider": "polyhaven",
        "source_id": "brown_mud_leaves_01", "source_res": "1k",
        "hero": False, "category": "terrain",
        "blocks": ["dirt"],
        "note": "Dirt. The name says leaves, the scan is forest duff; it is "
                "the right brown and the right roughness for turned earth.",
    },
    {
        "id": "rock_06", "provider": "polyhaven",
        "source_id": "rock_06", "source_res": "1k",
        "hero": False, "category": "terrain",
        "blocks": ["stone", "bedrock", "cobblestone"],
        "note": "Stone, bedrock, and the cobble detail overlay.",
    },
    {
        "id": "rock_face_04", "provider": "polyhaven",
        "source_id": "rock_face_04", "source_res": "1k",
        "hero": False, "category": "terrain",
        "blocks": ["deepslate", "deepslate_deep", "void_rock"],
        "note": "The Deeps. Also the stone detail overlay.",
    },
    {
        "id": "aerial_rocks_02", "provider": "polyhaven",
        "source_id": "aerial_rocks_02", "source_res": "1k",
        "hero": False, "category": "terrain",
        "blocks": ["gravel"],
        "note": "Gravel, and the detail overlay for dirt and sand.",
    },
    {
        "id": "sand_01", "provider": "polyhaven",
        "source_id": "sand_01", "source_res": "1k",
        "hero": False, "category": "terrain",
        "blocks": ["sand"],
        "note": "Beach sand.",
    },
    {
        "id": "snow_02", "provider": "polyhaven",
        "source_id": "snow_02", "source_res": "1k",
        "hero": False, "category": "terrain",
        "blocks": ["snow"],
        "note": "Tundra snow.",
    },
    {
        "id": "coast_sand_rocks_02", "provider": "polyhaven",
        "source_id": "coast_sand_rocks_02", "source_res": "1k",
        "hero": False, "category": "terrain",
        "blocks": ["ice"],
        "note": "Ice and the snow detail overlay. Ice is mostly a translucent "
                "tint over this, so the set is deliberately low-priority.",
    },
    # --- architecture: what the player builds ------------------------------
    {
        "id": "oak_wood_planks", "provider": "polyhaven",
        "source_id": "oak_wood_planks", "source_res": "2k",
        "hero": True, "category": "architecture",
        "blocks": ["planks"],
        "note": "Sawn oak: walls, floors, ceilings, roofs, doors, stairs, "
                "fences. The single most used building material in the game.",
    },
    {
        "id": "cobblestone_04", "provider": "polyhaven",
        "source_id": "cobblestone_04", "source_res": "2k",
        "hero": True, "category": "architecture",
        "blocks": ["cobblestone"],
        "note": "Foundations, walls, gates, bridges. 2K source: 2048 is "
                "already the ULTRA tier, so no 4K download is needed.",
    },
    {
        "id": "brick_wall_003", "provider": "polyhaven",
        "source_id": "brick_wall_003", "source_res": "2k",
        "hero": True, "category": "architecture",
        "blocks": ["brick"],
        "note": "Village and warehouse walls.",
    },
    {
        "id": "concrete_floor_02", "provider": "polyhaven",
        "source_id": "concrete_floor_02", "source_res": "2k",
        "hero": True, "category": "architecture",
        "blocks": ["concrete"],
        "note": "Workshop and warehouse floors, foundations, industrial decks.",
    },
    {
        "id": "asphalt_01", "provider": "polyhaven",
        "source_id": "asphalt_01", "source_res": "2k",
        "hero": True, "category": "architecture",
        "blocks": ["asphalt"],
        "note": "Roads and hardstanding. The quarry road to the workshop.",
    },
    {
        "id": "corrugated_iron", "provider": "polyhaven",
        "source_id": "corrugated_iron", "source_res": "2k",
        "hero": True, "category": "industrial",
        "blocks": ["metal_plate"],
        "note": "Industrial walls, roofs and machine skins. The corrugated "
                "silhouette is what makes a workshop read as a workshop.",
    },
    # --- metals: the engineering progression, previously flat vertex colours -
    {
        "id": "acg_metal_057a", "provider": "ambientcg",
        "source_id": "Metal057A", "source_res": "1k",
        "hero": True, "category": "industrial",
        "blocks": ["copper_block", "copper_ore"],
        "note": "Clean copper. 1K source from ambientCG: it is the only CC0 "
                "source in this library that has a copper, and a copper block "
                "is one face of a one-metre block.",
    },
    {
        "id": "acg_metal_055a", "provider": "ambientcg",
        "source_id": "Metal055A", "source_res": "1k",
        "hero": True, "category": "industrial",
        "blocks": ["iron_block", "iron_ore"],
        "note": "Wrought iron.",
    },
    {
        "id": "acg_metal_032", "provider": "ambientcg",
        "source_id": "Metal032", "source_res": "1k",
        "hero": True, "category": "industrial",
        "blocks": ["steel_block"],
        "note": "Grey rolled steel for the refined steel block.",
    },
    {
        "id": "acg_metal_048a", "provider": "ambientcg",
        "source_id": "Metal048A", "source_res": "1k",
        "hero": True, "category": "industrial",
        "blocks": ["brass_block"],
        "note": "Brass alloy for the brass block.",
    },
    {
        "id": "acg_metal_063", "provider": "ambientcg",
        "source_id": "Metal063", "source_res": "1k",
        "hero": False, "category": "industrial", "role": "detail",
        "blocks": ["metal_plate"],
        "note": "Oxidised steel detail overlay on corrugated iron, which is "
                "what stops a metal wall reading as new sheet metal.",
    },
]


# --- Derived sets ----------------------------------------------------------
#
# There is no CC0 "copper ore vein in rock" texture in either source library, and
# the honest options are to leave the four ore blocks as flat vertex colours
# (which is where they started) or to compose one. They are composed here, from
# the CC0 rock host and the CC0 metal that the same ore refines into, so the
# ore and the ingot are visibly the same material.

DERIVED = [
    {
        "id": "ore_copper", "host": "rock_06", "metal": "acg_metal_057a",
        "category": "terrain", "blocks": ["copper_ore"],
        "note": "Copper vein in host rock.",
    },
    {
        "id": "ore_iron", "host": "rock_06", "metal": "acg_metal_055a",
        "category": "terrain", "blocks": ["iron_ore"],
        "note": "Iron vein in host rock.",
    },
    {
        "id": "ore_silver", "host": "rock_06", "metal": "acg_metal_032",
        "category": "terrain", "blocks": ["silver_ore"],
        "note": "Silver vein in the same host rock, at a brighter inclusion "
                "threshold so it reads as rarer than copper.",
    },
    {
        "id": "ore_coal", "host": "rock_06", "metal": None,
        "category": "terrain", "blocks": ["coal_ore"],
        "note": "Coal seam: host rock with the inclusion value crushed down "
                "instead of replaced by a metal, because coal is not metal.",
    },
]


# --- Procedural sets -------------------------------------------------------
#
# Declared, not downloaded. Glass needs no texture: a translucent, low-roughness
# surface with a faint edge tint is the whole material, and a downloaded glass
# texture would be a fourth texture for a block whose albedo is 92% the sky.

PROCEDURAL = [
    {
        "id": "glass", "category": "architecture", "blocks": ["glass"],
        "note": "Translucent StandardMaterial3D, roughness 0.08, alpha 0.28, "
                "no texture. Windows and display cases.",
    },
]


# --- Models ----------------------------------------------------------------
#
# The prop bundles are Poly Haven glTF distributions. They were vendored before
# this pipeline existed; their provenance is recorded here so the manifest
# covers the whole library rather than only the new downloads.

MODELS = [
    {"id": m, "provider": "polyhaven", "source_id": m, "source_res": "1k",
     "category": "props", "format": "gltf",
     "note": "Village prop, 1K glTF bundle (container + .bin + external "
             "textures). Static, so it gets LOD1/LOD2."}
    for m in LOD_PROPS
]

# Props that were modelled at a size that would be wrong standing in the
# world. The scale is baked into the runtime mesh by make_lods.py rather than
# applied as a node scale in game code, so the model on disk is already the
# size it is supposed to be.
BAKE_HEIGHT = {
    # 0.29 m in the source: a table lantern. On the ground at 0.29 m it reads
    # as a candle; at 0.5 m it reads as the village lighting it is placed as.
    "Lantern_01": 0.50,
}
for _m in MODELS:
    _m["bake_height_m"] = BAKE_HEIGHT.get(_m["id"])

# KayKit characters: vendored in addons/, used by CreatureModels, deliberately
# not given LODs. Listed so the validator can prove they are referenced.
CHARACTERS = [
    {"id": "kaykit_knight", "provider": "kaykit", "source_id": "Knight",
     "source_res": "n/a", "category": "characters", "format": "glb",
     "note": "Villager body. Skinned + animated, so no LODs; see "
             "ART_DIRECTION.md. CC0."},
    {"id": "kaykit_mage", "provider": "kaykit", "source_id": "Mage",
     "source_res": "n/a", "category": "characters", "format": "glb",
     "note": "Villager body. CC0."},
    {"id": "kaykit_barbarian", "provider": "kaykit", "source_id": "Barbarian",
     "source_res": "n/a", "category": "characters", "format": "glb",
     "note": "Villager body. CC0."},
    {"id": "kaykit_skeleton_warrior", "provider": "kaykit",
     "source_id": "Skeleton_Warrior", "source_res": "n/a",
     "category": "characters", "format": "glb", "note": "Mob body. CC0."},
    {"id": "kaykit_skeleton_minion", "provider": "kaykit",
     "source_id": "Skeleton_Minion", "source_res": "n/a",
     "category": "characters", "format": "glb", "note": "Mob body. CC0."},
]

# The HDRI sky set. DayNight picks one per time of day; the full-size files are
# kept because a skybox is the one place where a large texture is genuinely
# resolved.
HDRIS = [
    {"id": "kloofendal_48d_partly_cloudy_puresky", "category": "sky"},
    {"id": "quarry_01_puresky", "category": "sky"},
    {"id": "autumn_field_puresky", "category": "sky"},
    {"id": "farm_field_puresky", "category": "sky"},
    {"id": "dikhololo_night", "category": "sky"},
    {"id": "moonless_golf", "category": "sky"},
    {"id": "clarens_night_01", "category": "sky"},
    {"id": "belfast_sunset_puresky", "category": "sky"},
    {"id": "venice_sunset", "category": "sky"},
]
for _h in HDRIS:
    _h.update({"provider": "polyhaven", "source_id": _h["id"],
               "source_res": "1k", "format": "hdr",
               "note": "Sky/environment probe for the day/night cycle."})


# --- Derived helpers -------------------------------------------------------

LICENCE = {
    "polyhaven": "CC0 1.0 Universal (public domain dedication)",
    "ambientcg": "CC0 1.0 Universal (public domain dedication)",
    "kaykit": "CC0 1.0 Universal (public domain dedication)",
    "derived": "CC0 1.0 Universal, derived from CC0 sources in this manifest",
    "procedural": "Project original, no third-party content",
}
AUTHORS = {
    "polyhaven": "Poly Haven (https://polyhaven.com)",
    "ambientcg": "ambientCG (https://ambientcg.com)",
    "kaykit": "Kay Lousberg (https://kaylousberg.itch.io/kaykit)",
    "derived": "EMERGENT asset pipeline (tools/process_textures.py)",
    "procedural": "EMERGENT",
}
SOURCE_PAGE = {
    "polyhaven": "https://polyhaven.com/a/",
    "ambientcg": "https://ambientcg.com/view?id=",
    "kaykit": "https://kaylousberg.itch.io/kaykit",
    "derived": "",
    "procedural": "",
}


def all_texture_sets():
    """Every set id that ends up as a directory in assets/runtime/textures."""
    out = [t["id"] for t in TEXTURES]
    out += [d["id"] for d in DERIVED]
    out += [p["id"] for p in PROCEDURAL]
    return out


def source_px(entry):
    return SOURCE_PX[entry["source_res"]]


def tiers_for(entry):
    """Runtime tiers for a set: the ladder, capped at the source resolution.

    Capping is what makes "no upscaling" a property of the pipeline rather than
    a promise. A 1K source gets 1024 and 512; a 4K source additionally gets
    2048. Nothing ever gets a tier larger than the pixels it came from.
    """
    cap = min(source_px(entry), TIERS[0])
    return [t for t in TIERS if t <= cap]


def main():
    import json
    print(json.dumps({
        "textures": len(TEXTURES),
        "derived": len(DERIVED),
        "procedural": len(PROCEDURAL),
        "models": len(MODELS),
        "characters": len(CHARACTERS),
        "hdris": len(HDRIS),
    }, indent=2))


if __name__ == "__main__":
    main()
