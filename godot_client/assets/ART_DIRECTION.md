# EMERGENT art direction

This is the decision document the asset pipeline is built against. It exists so
that "does this asset fit?" has an answer that is written down *before* a
download happens, instead of being argued about afterwards in a repository of a
thousand files.

`tools/asset_catalog.py` encodes these rules as data; `tools/asset_test.gd`
enforces the mechanical half of them (every set is bound to a block, no tier is
larger than its source, nothing is downloaded and unused).

## The world we are making

A **temperate post-industrial valley**. Northern-European rural landscape that
has been worked for two hundred years and is being worked again: pasture and
forest on the slopes, a river valley with gravel and sand, a village of brick
and timber, a quarry, and an industrial quarter of corrugated steel and
rusted plate. The player builds a workshop, and the workshop becomes a
factory, and the factory is made of the same stone and steel as the world
around it.

Everything in the game must look like it belongs to that one valley. The
engineering system is the subject of the game, so the industrial half of the
palette is not decoration: it is the gameplay reading on screen.

## Hard rules

| Axis | Rule |
| --- | --- |
| Material scale | One texture tile = one 1 m block face. Always. A 2 m brick reads as 2 bricks, not one stretched brick. |
| Object scale | 1 world unit = 1 metre. KayKit characters are fitted to 1.8 m; village props are fitted by their measured AABB, not by a guess. |
| Colour range | Desaturated, cool-leaning, mid-key. Albedo saturation stays under roughly 0.35. Nothing is a pure primary. |
| Roughness range | Natural surfaces 0.75–1.0. Metals 0.15–0.55. Water/ice below 0.1. Nothing in the world is a mirror. |
| Vegetation | Real scanned bark and leaf clusters on voxel blocks, not billboards. Trees are wood and leaves blocks, as they already are. |
| Architecture | Brick, cobble, sawn plank, cast concrete, asphalt. No stucco pastels, no sci-fi paneling. |
| Industrial | Corrugated and rusted steel, galvanised plate, concrete floors. Weathering is a given, not an effect. |
| Lighting | One sun, sky-driven ambient, warm point lights at night. This is why the material albedo is kept mid-key and the roughness high: it has to survive a full day/night cycle without blowing out or going muddy. |
| Weather | Rain is possible. Wet ground darkens and sharpens specular, so no surface may rely on being permanently dry-looking. |
| Terrain | Tiling, never a unique giant texture. One block face is one tile at every quality tier. |

## What gets rejected

* **Showroom PBR.** High-gloss, high-contrast, saturated metals that only look
  right in an HDRI studio. They read as fake next to a valley.
* **Style mismatch.** Photographic terrain next to low-poly props next to
  cartoon characters is already a deliberate mix (see below), but two
  *photographic* sets that were shot under different lighting and colour
  grading are not acceptable: the rock must look like it came out of the same
  ground as the dirt.
* **Duplicate material.** A second texture set that looks like one already in
  the library is dead VRAM. Derive it or reuse it instead.
* **Upscaled sources.** A runtime texture larger than the source it was made
  from is a lie about detail. The validator fails the build on this.
* **Anything not CC0.** No attribution we cannot satisfy, no unclear terms, no
  AI-generated art, no ripped commercial assets.

## The one deliberate style mix

Photographic PBR terrain and architecture, low-poly stylised characters and
props. This is intentional and it is why the characters are tinted at spawn
(`CreatureModels.spawn`) rather than left at their source colours: the tint is
the bridge. What is *not* acceptable is a third style, and in particular
photographic props among the low-poly ones.

## Hero assets

A small number of things get the most attention, and only these:

| Hero | Why |
| --- | --- |
| Grass, dirt, forest floor | Most pixels in the game by a wide margin. |
| Rock / deepslate | Every cliff, every cave, every quarry face. |
| Ores | The entire reason the engineering progression exists. Currently flat vertex colours; these become real PBR. |
| Refined metals (copper, iron, steel, brass) | The visible output of smelting and machining. |
| Oak planks, cobble, brick, concrete, asphalt, corrugated iron | Everything the player builds with. |

Everything else — a barrel, a stool, a lantern — is secondary and gets the
standard 1 K treatment with a 512 K low tier.

## Resolution ladder, and why it stops where it does

Source is always the highest resolution the provider offers *for that asset's
role*. Runtime is then the largest tier that is not larger than the source.

| Tier | Resolution | What it is for |
| --- | --- | --- |
| ULTRA | 2048 (hero terrain only) | 4K source, downsampled. |
| HIGH | 1024 | The default. Where the game should look. |
| MEDIUM / LOW | 512 | Half of everything, including every detail overlay. |

Sources:

* Poly Haven terrain and architecture: **4K** for the three terrain sets that
  fill the screen, **2K** for architecture.
* ambientCG metals: **1K**. Metals are used on one block face of a small
  object; a 2K source would be paid for in VRAM and never resolved.
* Poly Haven props: **1K** glTF bundles, as the provider packages them.

Detail overlays are a finer surface breakup, never the focal surface, so they
ship at 512 only. That is one texture instead of three for nine of the sets.

## What this costs, stated up front

Three decisions in this document exist to protect frame time, and each is a
deliberate rejection of a "better looking" option:

1. **No parallax occlusion by default.** POM ray-marches the height field
   with 8–16 layers per fragment on every terrain face, most of which are
   hidden or at grazing angles, in a world made of flat cube faces. The relief
   is real but it is relief on a surface that is by construction flat. It
   stays reachable at ULTRA and is off at HIGH and below.
2. **No 4K runtime textures.** The 4K sources exist so that 2048 is a genuine
   downsample with detail to spend, not an upscale. Shipping 4K to the GPU
   would cost roughly 2.5x the VRAM of the whole rest of the library for
   detail that is below one pixel on most blocks.
3. **No LODs on characters.** Villagers and mobs are skinned, animated meshes.
   Vertex-cluster decimation of a skinned mesh produces LODs that break at the
   joints, and a broken villager is worse than a 4,000-triangle one. Static
   props get real LODs; characters do not, and that is the correct call.
