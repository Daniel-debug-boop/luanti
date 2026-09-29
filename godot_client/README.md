# LuantiVoxel — Godot 4 migration

A voxel sandbox client written in **Godot 4.4 / GDScript**, migrated from the
Luanti (Minetest) C++ codebase. It can load real Luanti worlds through an
offline converter, and it also generates its own procedural terrain with six
biomes, caves, two dimensions, HDRI skies, textured blocks, wandering mobs and
a populated village.

## Run it

```sh
godot --path godot_client           # or open godot_client/ in the Godot editor
```

Controls: `WASD` move · `Space` jump/up · `Shift` sprint · `F` toggle fly ·
`G` switch dimension · `LMB` mine · `RMB` place · `1`–`8`/scroll select block ·
`E` talk · `F1`–`F3` render quality · `F4`–`F7` texture mapping · `Esc` release
mouse.

## Loading a real Luanti world

Godot 4.4 exposes no zstd binding and no SQLite, so map format 29 (zstd) is
decompressed offline. Python 3 with `zstandard` is required:

```sh
pip install zstandard
python3 godot_client/tools/convert_world.py <world_dir> godot_client/world
```

That reads `map.sqlite`, inflates every MapBlock (formats 22–29), and writes
one flat `c_<x>_<y>_<z>.chunk` file per block plus a `manifest.json`. The
client prefers those files when present, and falls back to procedural
generation everywhere else.

To verify the loader without a real world:

```sh
python3 godot_client/tools/make_test_world.py /tmp/testworld
python3 godot_client/tools/convert_world.py /tmp/testworld /tmp/testchunks
```

## Art assets

All art is free HD material from **Poly Haven** (CC0), downloaded directly
into `godot_client/assets/raw/` and committed to the repo:

```sh
python3 godot_client/tools/fetch_assets.py    # re-download (needs network)
```

| Kind | Count | Used for |
|---|---|---|
| HDRIs | 9 | the sky, day and night |
| PBR texture sets | 8 (32 maps) | block surfaces: albedo, normal, AO/roughness/metalness |
| glTF models | 17 | village props: crates, barrels, lamps, benches, pots, plants |

Godot imports these on first editor open (`--editor --quit` does the same
headlessly), so no manual import step is needed.

* **Blocks** — the greedy mesher emits one surface per block id, and each
  surface is bound to the PBR material for that id. UVs are in block units, so
  a texture tiles once per block instead of stretching across a merged run.
  Ambient occlusion, daylight and directional shading are baked into vertex
  colors and multiplied over the photo albedo.
* **Sky** — `DayNight` runs a 24-hour clock, rotates the sun, warms the light
  at dawn and dusk, and swaps between the daytime, sunset and night panoramas.
* **Props** — `Village` places the glTF models on flat, dry ground near the
  player and populates the site with named villagers who walk around, turn to
  face you, and greet you when you press `E`.

## Rendering

Everything here is stock Godot. No hand-written shader is required for the
default look.

**Texture projection** (`F4`–`F7`, or `MaterialLibrary.Mapping`). Godot cannot
apply triplanar mapping and parallax occlusion to the same material — it
prints *"Height mapping is not supported on triplanar materials"* and silently
discards the heightmap — so exactly one is active at a time:

| Mode | What it does |
|---|---|
| `plain` | box UVs, cheapest |
| `triplanar` | projects on X/Y/Z, blends by normal; fixes stretching on sloped faces |
| `parallax` (default) | Godot 4's POM, via the `heightmap_*` family, ray-marching each set's `disp` map |
| `stochastic` | vendored Acegiak triplanar shader with per-cell hash sampling, which also breaks up the repeating tile pattern |

**Environment effects** (`F1`–`F3` for the quality tier):

* **SSAO** — sub-voxel contact darkening on top of the mesher's baked
  per-vertex occlusion, so corners read as separate blocks.
* **SSIL** — one bounce of screen-space indirect light.
* **SDFGI** — the engine's ray-traced global illumination. See the caveat
  below; bounce light is currently supplied by reflection probes.
* **Volumetric fog** — with `volumetric_fog_gi_inject` and temporal
  reprojection, plus a `FogVolume` that follows the camera.
* **Glow** — bloom around emissive blocks.
* **Bounce probes** — a ring of four `ReflectionProbe`s around the player
  supplies the colour bleed (green grass onto neighbouring stone) that
  probe-based GI gives you.

### Two honest caveats

**SDFGI needs an editor-authored probe volume.** Godot 4.4 exposes
`sdfgi_enabled` and the full `sdfgi_*` settings on `Environment`, and
`RenderSettings` configures all of them, but the signed distance field itself
comes from an `SDFGIProbeVolume3D` node — and that class is *not exposed to
script* in this build (`ClassDB.class_exists("SDFGIProbeVolume3D")` is
`false`). It can only be added in the Godot editor and saved into the scene.
So SDFGI settings are written and the HUD reports it as `sdfgi*`, but the
ray-traced path stays off until such a volume exists. The reflection probes
cover the same visual goal meanwhile.

**Triplanar and POM are mutually exclusive**, as described above. If you want
both the anti-stretching of triplanar *and* the relief of POM, use the
`stochastic` mode: it is a hand-authored shader, so it can do triplanar
projection and still sample normal/ARM maps itself.

## Third-party shaders

`addons/` contains two vendored projects, unmodified, with their licences and
an `ATTRIBUTION.md` explaining what each is and how it differs from what this
project uses:

* `terrain-shader/` — [acegiak/Godot4TerrainShader](https://github.com/acegiak/Godot4TerrainShader), Apache-2.0. The stochastic triplanar sampling.
* `voxel/` — [viktor-ferenczi/godot-voxel](https://github.com/viktor-ferenczi/godot-voxel), MIT. A 100%-GPU DDA raymarching voxel renderer. Vendored as the alternative architecture, **not** wired into the default path: it renders the whole volume as one box mesh and needs the voxel data uploaded as a cube map plus a `Texture2DArray`, which is a different pipeline from this project's CPU greedy mesher.

Zylann's `godot_voxel` is **not** vendored. It is a C++ GDExtension module
requiring a custom Godot build (its releases target a specific branch), so the
stock 4.4 binary this project targets cannot load it, and it would replace the
voxel renderer rather than provide a shader.

## Architecture

```
godot_client/
├── scenes/main.tscn           entry point
├── assets/raw/                downloaded Poly Haven HDRIs, textures, models
├── addons/                    vendored third-party shaders (see ATTRIBUTION.md)
├── scripts/
│   ├── main.gd                assembly: world, player, mobs, village, sky, HUD
│   ├── player.gd              walk/fly controller, swept-AABB voxel collision
│   ├── hud.gd                 panels, FPS graph, clock, hearts, hotbar, mining bar
│   ├── mobs/
│   │   ├── mob.gd             wander/chase AI, terrain-aware pathing
│   │   ├── mob_spawner.gd     population control, despawn, dimension palettes
│   │   ├── villager.gd        humanoid NPC: wander, face the player, greet
│   │   └── village.gd         deterministic prop scatter + villager roster
│   ├── player/
│   │   ├── voxel_pick.gd      Amanatides-Woo DDA raycast against the voxel field
│   │   └── player_interaction.gd  mine/place, fall damage, regen, drowning, melee
│   └── world/
│       ├── content_db.gd      block registry: palette, translucency, light, hardness
│       ├── world_generator.gd six biomes, caves, trees, The Deeps dimension
│       ├── voxel_world.gd     chunk streaming, meshing budget, dimensions, edits
│       ├── voxelblock.gd      16³ container: content, light, param2
│       ├── chunk_files.gd     reader for converted .chunk files
│       ├── greedy_mesher.gd   greedy meshing, per-id surfaces, AO, UV1+UV2
│       ├── material_library.gd  PBR materials, triplanar/POM/detail, id -> set
│       ├── voxel_stochastic.gdshader  vendored stochastic triplanar (derived)
│       ├── render_settings.gd SSAO, SSIL, SDFGI config, volumetric fog, probes
│       ├── day_night.gd       HDRI sky, sun arc, 24h clock
│       └── mapnode.gd         voxel indexing and content-id semantics
└── tools/                     converter, worldgen, asset fetcher, test scripts
```

### Meshing

Chunks mesh only when all 26 neighbours exist, so border faces cull against
real data. Each block id becomes its own mesh surface with its own PBR
material. Face brightness combines directional shading (top bright, bottom
dark), stored daylight, emissive block light (glowstone), and per-vertex
ambient occlusion sampled from the voxel neighbourhood. The mesher also emits
a second UV set, tiled `DETAIL_UV_SCALE` times per block, which feeds the
detail layer. Water and ice render in a separate translucent pass. An all-air
block skips meshing entirely, which keeps streaming cheap across open sky.

### Editing and survival

`PlayerInteraction` raycasts from the eye each frame with a 3D-DDA. Holding the
left button accumulates mining progress at a rate scaled by the block's
hardness; the block disappears when the bar fills. The right button places the
selected hotbar block against the face that was hit, refusing cells occupied
by the player's own body. Edits are recorded per voxel and replayed when a
chunk is regenerated, so digging a hole survives walking away and back.

Survival rules: fall damage above a 3.5-block drop, slow regeneration five
seconds after taking a hit, drowning damage underwater with a breath meter,
and damage from a mob that closes to melee range.

### Dimensions

`G` toggles between the overworld and **The Deeps**, a dark cavern dimension
of deepslate strata and glowstone studs. Each dimension has its own
environment preset (sky, fog, glow), sun, ambience, and mob palette. Chunks
stay cached per dimension, so switching back is instant.

## Tests

```sh
sh godot_client/tools/run_tests.sh <path-to-godot>
```

Seven suites run headless:

| Suite | Covers |
|---|---|
| `mesher_test` | 12-tri isolated block, greedy merge, per-id surfaces, tiled UVs, palette colors, AO, translucent pass, empty skip, PBR material binding |
| `world_test` | six biomes occur, bedrock floor, oceans, trees, Deeps content |
| `interaction_test` | DDA raycast hit/normal/place cell, break/place, bedrock immunity, edit replay across reload, mining to completion, HDRI set + clock, village props and villagers |
| `render_settings_test` | triplanar/POM mutual exclusion, all four mapping modes, stochastic shader compiles and samples in world space, SSAO/SSIL/volumetric fog/glow on, quality tiers, live scene surfaces |
| `e2e_test` | real scene streams chunks, textured surfaces bound in the scene graph, collision reads terrain |
| `features_test` | village + clock + HDRI sky, dimension switch both ways, glowstone in loaded chunks, mobs spawn, mining through the scene |
| `render_test` | textured and vertex-coloured surfaces, world-space bounds, camera present, HDRI panorama bound |

## Honest limitations

* **SDFGI is configured but not running** — it needs an `SDFGIProbeVolume3D`
  node, which cannot be created from script in Godot 4.4. Add one in the
  editor and the settings already in `RenderSettings` take effect. Bounce
  light currently comes from reflection probes.
* **SDFGI and SSIL and volumetric fog were not visually verified** — this
  environment has no GPU or display server, so every check is structural
  (the properties are real and enabled), not visual.
* **No inventory or crafting** — the hotbar is a fixed block list, not a
  container, and there is no recipe system.
* **No saving to disk** — edits live in memory for the session. A converted
  world on disk is never written back.
* **Mobs have no pathfinding** — they wander, chase, auto-jump one block, and
  melee, but do not navigate around obstacles.
* **Villagers are built from primitives**, not downloaded character models;
  the Poly Haven prop set is furniture rather than people.
* **No audio**, and no block-drop entities when something is mined.
* **Legacy Luanti worlds** load for the overworld only; The Deeps is always
  procedural.
* **Format versions below 27** decompress but skip legacy sections (node
  metadata, node timers) rather than parsing them fully.
