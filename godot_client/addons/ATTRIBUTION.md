# Third-party shaders

Both addons here are vendored verbatim from their upstream projects, with
their licences included alongside them. Nothing in either addon was modified.

---

## `terrain-shader/` — Triplanar terrain shader

* Upstream: <https://github.com/acegiak/Godot4TerrainShader>
* Licence: Apache License 2.0 (see `terrain-shader/LICENSE`)
* Files: `Terrain.gdshader`, `Triplanar.gdshader`, `TriplanarSplit.gdshader`,
  `StochasticTexture.gdshader`

Upstream's description: "Split texture, stochastic sampled, triplanar texture
shader for Godot4", itself based on /u/Rotoscope's stochastic sampling shader
for Unity and John Watson's split triplanar terrain shader for Godot 3.

This is the stochastic-sampling half of the surface work: Godot's built-in
triplanar projection fixes stretching but does nothing about the visible
repeating grid pattern, because the same texture lands at the same offset on
every block. Stochastic sampling jitters each block's sample position, which is
what breaks the repeat. `Terrain.gdshader` additionally splits the texture by
slope, so a cliff face and a flat top take different textures.

Note that upstream targets a heightmap terrain and expects a `ShaderMaterial`
with `top_tex` / `wall_tex` uniforms set per material. It is a hand-authored
shader, so it bypasses `StandardMaterial3D` entirely: the per-block albedo,
normal, and ARM maps configured in `scripts/world/material_library.gd` do not
apply to it. Select it with `MaterialLibrary.Mapping.SHADER_TRIPLANAR`.

---

## `voxel/` — GPU DDA voxel renderer

* Upstream: <https://github.com/viktor-ferenczi/godot-voxel>
* Licence: MIT, Copyright (c) 2023 Viktor Ferenczi (see `voxel/LICENSE`)
* Files: `Shaders/Opaque.gdshader`, `Shaders/Transparent.gdshader`,
  `Shaders/Shadow.gdshader`, `Shaders/DDA.gdshaderinc`,
  `Shaders/Config.gdshaderinc`, `Shaders/TexturedSampler.gdshaderinc`,
  `Shaders/VoxSampler.gdshaderinc`, `plugin.gd`

Upstream's description: "Voxel rendering for Godot 4.3+ (GPU, shader, DDA
algorithm) ... Based on an efficient 2-level DDA algorithm, implemented 100% on
the GPU as a fragment shader."

This is the GPU-raymarching option. It is a fundamentally different rendering
architecture from the one this project uses:

* It renders the entire voxel volume as a **single box mesh** (8 vertices, 12
  faces, front faces culled) and ray-marches inside it in the fragment shader,
  rather than greedy-meshing chunk geometry on the CPU.
* It needs two GPU resources built from the voxel data: a 16x256 `RGB8` cube
  map saying which voxel cubes are non-empty, and a 256x16xN `R8`
  `Texture2DArray` of voxel indices. Upstream's README is explicit that the
  import configuration for that texture array is critical and easy to get
  wrong.
* Because geometry comes from the ray march, it needs the voxel data uploaded
  as textures, not just present as `VoxelBlock` arrays.

Our renderer already greedy-meshes chunks on the CPU into per-block-id
surfaces with baked ambient occlusion, which is a different (and, for a
Luanti world being viewed, a more direct) pipeline. These shaders are vendored
so the alternative is available to switch to; they are not wired into the
default render path.

---

## Zylann's godot_voxel (Voxel Tools) — USED, via the official module build

* Upstream: <https://github.com/Zylann/godot_voxel>
* Licence: MIT
* Release used: **v1.4.0 — "Godot 4.4.stable.custom_build [4c311cbee]"**
* Fetched by: `tools/fetch_voxel_engine.sh` (downloads, unzips, verifies the build string)

### Correction to an earlier claim in this file

A previous revision of this file stated that Voxel Tools "cannot be loaded by
the stock Godot 4.4 binary this project targets". **That was wrong.** The
accurate picture:

* Every published `GodotVoxelExtension.zip` (v1.4.1x, v1.5x, v1.6x, v1.7x)
  declares `compatibility_minimum = "4.4.1"`. Stock `4.4-stable` reports
  itself as `4.4.0`, so Godot **silently skips** the extension — no error, just
  `ClassDB.class_exists("VoxelTerrain") == false`. Verified.
* The supported route is the **module build** the project publishes itself.
  Release `v1.4.0` is built from Godot commit `4c311cbee` — the *same* engine
  commit as stock `4.4-stable` — with Voxel Tools 1.4.0 compiled in. The
  project's GDScript is unchanged; only the binary differs.

### What this gives us, and what is verified

Verified headlessly on the custom build (`tools/zylann_test.gd`):

* `VoxelTerrain` infinite streaming — 64 data blocks generated in 300 frames
* `VoxelGeneratorScript` — our GDScript terrain generator runs on Voxel Tools'
  worker threads
* voxel read/write round-trip through `VoxelToolTerrain`
* `VoxelLodTerrain`, `VoxelInstancer`, `VoxelMesherBlocky`,
  `VoxelBlockyLibrary`, `VoxelStreamRegionFiles` / `VoxelStreamMemory` all
  construct and run

**Not verified:** mesh upload and rendering. This machine has no GPU, no X11
and no Wayland, so nothing has ever been displayed. `is_area_meshed()` stays
false headless, which is consistent with the dummy renderer rather than with a
runtime fault, but that is inference, not proof.

### Engine requirement

The project still runs on stock Godot 4.4 — `ZylannWorld` checks
`ClassDB.class_exists("VoxelTerrain")` and degrades to inert. The Voxel Tools
features are opt-in.

---

## GLoot (Universal Inventory System) — USED

* Upstream: <https://github.com/peter-kish/gloot>
* Licence: MIT
* Version: v3.0.1, Godot 4.4, installed unmodified from the Asset Library
  release `c687406b7b2b21e8967d60e1dc7303216a5f6fe2`

The player inventory, hotbar, item protoset, capacity constraint and item
serialization are all GLoot. `scripts/gameplay/player_inventory.gd` is only
glue that maps ContentDB block ids onto GLoot prototypes. It has no
dependencies outside `addons/gloot`.

Two GLoot behaviours the glue has to work around, both read from the addon
source rather than guessed:

* an `ItemSlot` owns a *private* one-item container, and `equip()` moves the
  item out of the backpack into it;
* an `InventoryConstraint` registers by being **parented** to an `Inventory` --
  there is no `add_constraint()`.

---

## KayKit character models (CC0) — USED

* Upstream: <https://github.com/KayKit-Game-Assets> — Kay Lousberg
* Licence: **CC0** (public domain dedication)
* Packs: Character Pack Adventures (`2129`), Character Pack Skeletons (`2566`)

Mobs and villagers are now real character models instead of coloured boxes.
Kept, unmodified:

| File | Used for |
|---|---|
| `kaykit_character_pack_adventures/.../Knight.glb` | villager body |
| `.../Mage.glb` | villager body |
| `.../Barbarian.glb` | villager body |
| `kaykit_character_pack_skeletons/.../Skeleton_Warrior.glb` | mob body |
| `.../Skeleton_Minion.glb` | mob body |

Two unused GLBs (Rogue, Rogue_Hooded, Skeleton_Mage, Skeleton_Rogue) were
**deleted**: each is 3.5 MB because KayKit embeds a 1024x1024 PNG, and the
game only needed five. `scripts/mobs/creature_models.gd` only rescales and
tints them.

**The animations came with the models.** No animation asset was downloaded or
added: each GLB already contains 76-95 clips (76 for the adventurers, 95 for
the skeletons) — Idle, Walking_A/B/C, Running_A/B/C, melee and ranged attacks,
Hit_A/B, Death_A/B, Jump_*, Dodge_*, Sit_*, Lie_*, Cheer, Taunt, Interact,
Throw, Use_Item and the Spellcasting set. `scripts/mobs/creature_animator.gd`
drives the `AnimationPlayer` already present in each model.

Measured clip counts are asserted in `tools/creature_test.gd`, so deleting
these models would fail the suite rather than silently stop the creatures
moving.

## Kenney audio (CC0) — USED

* Upstream: <https://kenney.nl> — Kenney
* Licence: **CC0**
* Packs: Interface Sounds (`794`), UI Audio (`796`)

151 CC0 `.wav` files, used unmodified, driving every sound in the game through
`scripts/audio/audio_director.gd`.

The packs that would have fit better -- Kenney's Impact Sounds and RPG Audio --
are **404 at every mirror** the Asset Library points at, and kenney.nl serves
its download links in a way that does not appear in the page HTML. The
interface pack stands in: `bong`, `glass`, `pluck`, `scratch` and `drop` read
convincingly as block breaking and placing once pitch-shifted, which is what
`AudioDirector` does.

Note the two packs do not agree on file naming -- the interface pack is
`click_001.wav`, the UI pack is `click1.wav` -- so the director carries a
per-event `fmt` override.

---

## Searched for and NOT found: crafting

The Asset Library was queried for Godot 4.4 crafting addons
(`filter=crafting`). **Zero results** -- there is no such category. GLoot is a
container library with no recipe system, and neither do the inventory addons
that were reviewed. So `scripts/gameplay/crafting.gd` is hand-written.

## Searched for and NOT used: generic save/load addons

The Asset Library was also queried for save/load addons (`filter=save`). The
results are generic resource serialisers aimed at editor tooling (Game State
Saver Plugin, Easy Save Lite, SaveState, Locker) rather than a runtime
player-state store. Voxel Tools' own `VoxelStreamRegionFiles` *is* used, for
the Voxel Tools backend, but it only persists voxel blocks -- not the player,
the vitals or the inventory. `scripts/gameplay/save_game.gd` is therefore
hand-written.

---

## miniaudio — vendored, NOT compiled

* Upstream: <https://github.com/mackron/miniaudio>
* Version: v0.11.25, single-header amalgamation, unmodified
* Licence: public domain **or** MIT-0 (dual licensed)

Vendored because it was asked for and it costs nothing to keep licensed and on
disk. **It is not compiled and nothing calls it.** GDScript cannot call C;
reaching miniaudio needs a GDExtension or a custom engine build. Note that
Godot's own `AudioDriver` is already miniaudio, so the binary contains it —
just not exposed to scripting. See `addons/thirdparty/miniaudio/README.md`.
