# Rejected assets and rejected options

Everything here was either downloaded and then refused, or considered and
refused before downloading. The point of recording refusals is that a decision
nobody wrote down gets revisited by the next person who does not know why, and
the same 200 MB gets downloaded again.

The rule that covers most of this file: **CC0 and prebuilt only.** No
AI-generated assets, nothing ripped from a commercial game, nothing
"temporarily" borrowed.

---

## Rejected options

### Parallax occlusion mapping by default — REJECTED

The previous pipeline had POM enabled at every quality tier.

POM ray-marches a height field in tangent space to fake depth at grazing
angles. A voxel block face is flat by construction: its geometry is a quad.
There is no relief on it for the ray march to reveal, so what POM actually
buys here is relief from the *normal map*, paid for with a per-fragment march
and an extra resident texture per material.

Moved to `MaterialLibrary.POM_QUALITY = Quality.ULTRA`. At ULTRA the player has
asked for maximum quality and is paying for it knowingly; below that it is
pure cost.

**Also blocked by an engine limit, independently of cost.** Godot cannot do
triplanar mapping and POM on the same material. Enabling both makes the engine
print *"Height mapping is not supported on triplanar materials"* and silently
drop the heightmap, so POM would be configured and never run. The two are
mutually exclusive by `MaterialLibrary.Mapping`.

### 4K runtime textures — REJECTED

Considered and declined: shipping 4096² albedos for hero blocks.

The player is typically 1–3 m from a one-metre block face. A 2048 albedo across
that face is already finer than the display resolves; 4096 costs 4× the VRAM
and 4× the import time for detail that is never visible. The ceiling is 2048,
and only for sets whose *source* is 4K or 2K — `asset_catalog.tiers_for()`
caps each set's ladder at its source resolution so a 1K texture is never
upscaled to look like it has more detail than it does.

### LODs on skinned characters — REJECTED

`make_lods.py` decimates by vertex clustering, which merges vertices and
recomputes their attributes. On a skinned mesh those attributes include bone
influence weights. Clustered vertices take averaged weights, so limbs bend in
ways the animation never asked for.

The KayKit characters (`kaykit_knight`, `kaykit_mage`, `kaykit_barbarian`,
`kaykit_skeleton_warrior`, `kaykit_skeleton_minion`) therefore ship without
LOD chains. The frame cost is accepted instead. A rig-aware decimator that
respects skinning weights would be the correct fix and is not in scope.

### Ambient occlusion baked into albedo — REJECTED

ambientCG 1K metal sets ship no AO map. The naive fill is to multiply the
occlusion into the albedo, which looks right in a still and wrong in motion:
AO darkens corners that the *lighting* should darken, and once it is in the
albedo it stops responding to the sun moving.

`process_textures.py` writes R = 255 (fully open) into the ARM map for those
sets instead. Godot binds it as the ORM map unconditionally, which makes it a
correct no-op rather than a black surface.

---

## Rejected assets

### `forrest_ground_01` as the grass albedo — REJECTED as albedo, KEPT as detail

A flat top-down photograph of grass with visible mowing stripes — parallel
lines running across the texture that read as a lawnmower pattern the moment
the block repeats across a hillside.

Demoted to a 512 detail overlay, where the stripes are broken up by the base
albedo's own variation, and replaced as the grass albedo by
`aerial_grass_rock`, which is shot at a natural angle and has no directional
stripes.

Note the misspelling in the name is the upstream Poly Haven asset ID, kept
verbatim so the manifest URL resolves.

### `potted_plant_01` at source resolution — REJECTED

176,226 triangles. It was the single most expensive prop in the set by an order
of magnitude — more than the next three combined.

Decimated to 19,963 triangles against the 20k `MAX_TRIS` budget rather than
dropped, because a leafy pot reads acceptably at that density once it is more
than a few metres from the camera, and village planting is exactly the case
where many of them are on screen at once.

Other props reduced to budget for the same reason: `treasure_chest`
103,330 → 4,887, `street_lamp_01` 30,610 → 599, `Lantern_01` 33,902 → 5,287,
`wooden_barrels_01` 33,142 → 17,578.

### Per-model `scale` fudge factors in the village script — REJECTED as an approach

`village.gd` previously carried a hand-tuned `scale` per prop kind, so that a
lantern was multiplied by 0.5 at the `Node3D` to make it look right, and a
barrel by some other number nobody had written down.

This puts the model's real size in a place that has nothing to do with the
model, breaks LOD consistency (the LOD chain and the scaled node disagree about
world size), and means a prop added later defaults to 1.0 and is silently
wrong.

Replaced by baking scale into the glTF geometry in `make_lods.py`, driven by
`BAKE_HEIGHT` in `asset_catalog.py`. `Lantern_01` is baked ×1.7007 to reach
0.50 m. The village script now places every prop with `Vector3.ONE` scale.

### Duplicate texture sets across providers — REJECTED

Both Poly Haven and ambientCG carry usable metal and stone sets. Taking both
would mean two art directions in one game: ambientCG's are studio-lit product
shots with clean, even albedo; Poly Haven's are environmental captures with
weathering baked in.

ambientCG is used for exactly the four refined-metal blocks and one detail
overlay, where "clean and even" is the point — a freshly smelted ingot should
not look weathered. Everything else is Poly Haven, so the world reads as one
place.