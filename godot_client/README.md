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
`E` talk · `Esc` release mouse.

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

## Architecture

```
godot_client/
├── scenes/main.tscn           entry point
├── assets/raw/                downloaded Poly Haven HDRIs, textures, models
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
│       ├── greedy_mesher.gd   greedy meshing, per-id surfaces, AO, translucency
│       ├── material_library.gd  Poly Haven PBR materials, id -> texture set
│       ├── day_night.gd       HDRI sky, sun arc, 24h clock
│       └── mapnode.gd         voxel indexing and content-id semantics
└── tools/                     converter, worldgen, asset fetcher, test scripts
```

### Rendering

Chunks mesh only when all 26 neighbours exist, so border faces cull against
real data. Each block id becomes its own mesh surface with its own PBR
material. Face brightness combines directional shading (top bright, bottom
dark), stored daylight, emissive block light (glowstone), and per-vertex
ambient occlusion sampled from the voxel neighbourhood. Water and ice render
in a separate translucent pass. An all-air block skips meshing entirely,
which keeps streaming cheap across open sky.

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

Six suites run headless:

| Suite | Covers |
|---|---|
| `mesher_test` | 12-tri isolated block, greedy merge, per-id surfaces, tiled UVs, palette colors, AO, translucent pass, empty skip, PBR material binding |
| `world_test` | six biomes occur, bedrock floor, oceans, trees, Deeps content |
| `interaction_test` | DDA raycast hit/normal/place cell, break/place, bedrock immunity, edit replay across reload, mining to completion, HDRI set + clock, village props and villagers |
| `e2e_test` | real scene streams chunks, textured surfaces bound in the scene graph, collision reads terrain |
| `features_test` | village + clock + HDRI sky, dimension switch both ways, glowstone in loaded chunks, mobs spawn, mining through the scene |
| `render_test` | textured and vertex-coloured surfaces, world-space bounds, camera present, HDRI panorama bound |

## Honest limitations

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
