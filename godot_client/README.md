# LuantiVoxel — Godot 4 migration

> **Architecture lives in [ARCHITECTURE.md](ARCHITECTURE.md).** It says what
> Luanti owns, what Godot owns, what Voxel Tools owns (nothing at runtime, and
> the promotion path if that changes), which layers may use which, where the
> server boundary is, and what is deterministic. It is not just prose: the same
> contract is data in `scripts/core/architecture.gd`, asserted by
> `architecture_test`, and runnable in game with **F11**.

A voxel sandbox client written in **Godot 4.4 / GDScript**, migrated from the
Luanti (Minetest) C++ codebase. It can load real Luanti worlds through an
offline converter, and it also generates its own procedural terrain with six
biomes, caves, two dimensions, HDRI skies, textured blocks, wandering mobs and
a populated village.

## Run it

From source, with Godot 4.4:

```sh
godot --path godot_client           # or open godot_client/ in the Godot editor
```

Or as a standalone build -- the player does not need Godot at all:

```sh
sh godot_client/tools/build_release.sh /path/to/godot
```

That writes `build/luantivoxel/luantivoxel-<version>-linux-x86_64.tar.gz` plus
a `.sha256`, and packs a README with the controls and requirements. The script
exports and then **smoke-tests the exported binary**, failing the build if it
does not reach a ready state or logs a script error -- so a package that starts
and then falls over cannot be published by accident.

Controls: `WASD` move · `Space` jump/up · `Shift` sprint · `F` toggle fly ·
`G` switch dimension · `LMB` mine · `RMB` place · `1`–`8`/scroll/click select
block · `E` talk/trade · `C` crafting grid · `F5` save · `F9` load · `F8`
toggle the Voxel Tools backend · `F1`–`F3` render quality · `F4`–`F7` texture
mapping · `F10` profiler · `F11` architecture overlay · `Esc` release mouse.

## Mobs, villagers and audio

Everything audible and everything alive is prebuilt CC0, not hand-made:

* **Models** — [KayKit](https://github.com/KayKit-Game-Assets) (Kay Lousberg,
  CC0). Mobs are KayKit skeletons, villagers are KayKit adventurers, picked
  deterministically per mob/villager so they keep the same body between frames
  and across saves. The old box bodies remain as a fallback if a model fails to
  load.
* **Audio** — [Kenney](https://kenney.nl) (CC0), 151 samples across Interface
  Sounds and UI Audio, played through a voice pool on two buses (`SFX` and
  `UI`) so you can quiet one without the other. Breaking a block picks a sound
  by material, so stone does not sound like leaves.

Custom code, because no prebuilt addon covers it: **A\* pathfinding** over the
voxel grid (`scripts/mobs/pathfinder.gd`) so mobs walk around obstacles
instead of into them, and **block drops** — mining leaves a physical item that
falls, settles, bobs and is collected by walking over it, and mobs drop loot
when killed.

### Animation

**No animation files were downloaded.** Every KayKit character GLB already
contains 76–95 clips (Idle, Walking_A, Running_A, attacks, Hit_A, Death_A,
Jump_*, Cheer, Taunt, Sit_*, Spellcasting). `scripts/mobs/creature_animator.gd`
finds the `AnimationPlayer` in an instantiated model and drives it: the caller
states intent (`IDLE`, `MOVE`, `RUN`, `ATTACK`, `HURT`, `DEATH`), the animator
picks a clip, crossfades, and scales the walk cycle to the mob's real speed.
One-shot states (`ATTACK`, `HURT`) release back to locomotion; `DEATH` is
terminal.

### Smarter mobs and villagers

Mobs now: sense ledges and turn around instead of walking off cliffs, keep
hunting across decision re-rolls (this was a bug — they used to forget their
target every few seconds), flee below 30% health, swing at the player in
melee range on a cooldown, turn on whoever hit them, and never chase if they
are passive. Mobs come in hostile and passive flavours.

Villagers now run a **daily schedule** — work by day, rest in the late
afternoon, sleep at night, with a shorter wander radius when off shift — and
**actually produce what they sell**. Each job has a work site in the district
and a resource that must be nearby for it to function: a Woodcutter whose site
has no trees stands there all day producing nothing, and a Miner's site needs
stone underfoot. Production is per-unit over time, capped by a per-villager
stock ceiling, and only accrues while the villager is on shift and standing at
their site. What they sell follows from the job: Farmer → sand, Baker → snow,
Miner → gravel, Woodcutter → wood, Blacksmith → stone, Healer → glowstone,
traded for stone.

The Healer's reagent is glowstone, which only exists in The Deeps, so a
surface Healer works slowly rather than never — the intent is a reason to go
underground, not a dead villager.

## Crafting grid

`C` opens a real 3x3 drag-and-drop grid. Drag blocks from the inventory strip
into the nine cells and the result slot updates live; drop anything on the
result to collect the craft. The panel uses Godot's built-in Control
drag-and-drop (`_get_drag_data` / `_can_drop_data` / `_drop_data`) and the same
`Crafting.find_recipe()` matcher as everything else, so shaped recipes still
trim their empty border (a 2x2 works in any corner) and shapeless recipes
ignore position.

This replaced the earlier `C`-key "craft from what you carry" shortcut. A craft
is refused unless the player is carrying *enough of every input* — a single
stone cannot be stretched into a 3x3 recipe.

Note on miniaudio: Godot's own `AudioDriver` *is* miniaudio, which is why these
files decode and mix at all. GDScript cannot call miniaudio's C API directly, so
the scripting surface is Godot's `AudioStreamPlayer`, which sits on top of it.

## Inventory and crafting

Mining now yields a real item and placing consumes one, instead of picking
from a fixed block list. The container is the prebuilt **GLoot** addon
(`addons/gloot`, MIT, v3.0.1) — the inventory, hotbar, item protoset, capacity
constraint and item serialization are all GLoot's;
`scripts/gameplay/player_inventory.gd` is only the glue that maps ContentDB
block ids onto GLoot prototypes.

Crafting (`C`) is hand-written: the Asset Library has **no** crafting addons
for Godot 4.4 — the category returns zero results — and GLoot has no recipe
system. It supports shaped recipes (with empty-border trimming, so a 2x2 works
in any corner of a 3x3 grid) and shapeless recipes. The 3x3 grid is currently
implicit: `C` crafts the first recipe your carried blocks can afford, rather
than a real drag-and-drop grid UI.

## Saving

`F5` writes a slot, `F9` loads it. Saves go to `user://saves/slot_N.json`
(8 slots) and hold the player's position, health and fly state, the whole GLoot
inventory, and the world's edit log — the part of the world the generator
cannot reproduce. Writes are atomic (temp file + rename) so a crash mid-write
cannot corrupt a slot.

For the Voxel Tools backend, voxel data persists through its own
`VoxelStreamRegionFiles` instead.

## Voxel Tools backend (Zylann)

A second world backend built on [Zylann's Voxel Tools](https://github.com/Zylann/godot_voxel)
(MIT): infinite streaming, LOD terrain, MultiMesh instancing, GDScript
generation, and region-file persistence.

```sh
sh godot_client/tools/fetch_voxel_engine.sh   # prints the binary path
sh godot_client/tools/run_tests.sh <that path>
```

**Why a separate engine.** Voxel Tools is a C++ module. Its published
GDExtension packages all require Godot 4.4.1 and are *silently* skipped by
stock 4.4-stable. The supported route is the project's own module build:
release `v1.4.0` is Godot commit `4c311cbee` — the same engine commit as stock
4.4-stable — with Voxel Tools 1.4.0 compiled in. The project's GDScript is
identical; only the binary differs.

The project **still runs on stock Godot 4.4**. `ZylannWorld` checks
`ClassDB.class_exists("VoxelTerrain")` and degrades to an inert node, so both
engines pass the full test suite.

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

## Systems, ownership and the one door

Every major system has exactly one owner, registered in `SystemRegistry` at
start-up; a second registration of the same name is refused with a reason.
Systems never call each other — they call `GameApi`, which returns a
`Result` (`ok`, `reason`, `value`) for every fallible call and refuses
mutations outright on a non-authoritative end. `System` gives each one an
explicit lifecycle and accounts for every node, timer, thread, resource and
signal connection it acquires, so "leaked" is a number rather than a surprise.
See `ARCHITECTURE.md` §§4–7.

## Measuring and surviving a long session

Three pieces of instrumentation, because "it runs on my machine" is not a
performance claim.

**`scripts/diagnostics/game_profiler.gd`** — per-system frame timing plus the
engine's own counters: fps, process and physics time, draw calls, objects and
primitives in frame, static/video/texture memory, and the video adapter name.
Press **F10** in game for the overlay; it auto-writes a JSON report every two
minutes while open, and `GameProfiler.snapshot()` returns the same data for a
script. Cost when disabled is one boolean branch per entry point.

**`scripts/diagnostics/stability_watchdog.gd`** — samples node count, object
count, orphan nodes and the three memory counters on an interval and keeps two
and a half hours of history. Its verdict separates **leak** (a counter climbs
and does not come back while the world is static) from **pressure** (a single
sample past a ceiling, which is a different problem with a different fix).
`main.gd` declares the world quiescent when nothing is being built or run, so
deliberately growing the world is not mistaken for a leak.

**`scripts/net/authority.gd`** — the server's side of multiplayer. Every
mutation arrives as a command and passes an allow-list of ops, a required-field
check, a session check, a per-peer token bucket, a server-side economy charge,
an ownership check on every node the command touches, and a reach check against
*the server's own belief* about where that player is (movement is clamped, so a
teleport cannot defeat reach). The apply closure is only ever called after all
of it passes, so a rejected command cannot leave a partial mutation. Accepted
commands are replicated back as a server-derived snapshot; there is no field in
the protocol a client fills in.

**Save safety** — `scripts/gameplay/save_migration.gd` adds a version chain, a
checksum, and a backup taken *before* each write. `F9` recovers automatically
from the backup when the slot is truncated or spliced, and a save from a newer
build is refused rather than guessed at. The checksum canonicalises through one
JSON round trip, because JSON has a single number type and a raw hash over the
serialisation would make every file fail its own check.

**Village ⇄ engineering** — `scripts/engineering/society.gd` is the one place
the AI and the machines meet. Villagers near a live electrical network are
powered and work at full rate; unpowered, they still work, just slower. The
network reads the graph and the village is written back to — one direction of
authority, so there is no second simulation.

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
│   ├── engineering/           the universal engineering system (18 files)
│   ├── diagnostics/           profiler + long-run stability watchdog
│   └── net/authority.gd       server-authoritative command validation
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

The script is self-sufficient: it runs the asset import pass first (without it
every suite that touches a texture or a sound fails with a setup error rather
than a real one) and generates the converted-world fixture `e2e_test` needs.
It also matches each suite's verdict line at column 0, so a suite that crashes
before printing one is reported as a failure rather than passing on an
incidental "PASS" somewhere in its output.

All nineteen suites run headless and pass on a clean checkout
(verified against Godot 4.4.stable.official, linux/x86_64):

| Suite | Covers |
|---|---|
| `zylann_test` | Voxel Tools presence, graceful degradation on stock Godot, streaming + GDScript generation + voxel read/write on the custom build |
| `gameplay_test` | GLoot protoset/stacking/hotbar/serialization, shaped + shapeless recipe matching, craft consumes-and-produces, save/load round-trip including world edits, malformed-payload rejection |
| `creature_test` | every declared sound resolves to a real CC0 file, playback and distance culling, KayKit models load and are deterministic, the 76+ shipped clips drive every animator state, mobs flee/attack/avoid ledges, villager schedules and trading, **every job actually changes the world** (Farmer tills, Miner cuts stone, Woodcutter fells; a job with no edit stays honestly idle; an asleep villager touches nothing; a villager with no world does not crash), A\* routes around a wall without tunnelling and gives up when sealed, drops spawn/settle/collect |
| `crafting_ui_test` | 3x3 grid construction, shaped and shapeless matching through the panel, drag payload source/target rules, an unaffordable craft is refused and consumes nothing, villager production requires shift + work site + nearby resource, stock caps, and production draws down on trade |
| `mesher_test` | 12-tri isolated block, greedy merge, per-id surfaces, tiled UVs, palette colors, AO, translucent pass, empty skip, PBR material binding |
| `world_test` | six biomes occur, bedrock floor, oceans, trees, Deeps content |
| `interaction_test` | DDA raycast hit/normal/place cell, break/place, bedrock immunity, edit replay across reload, mining to completion, HDRI set + clock, village props and villagers |
| `render_settings_test` | triplanar/POM mutual exclusion, all four mapping modes, stochastic shader compiles and samples in world space, SSAO/SSIL/volumetric fog/glow on, quality tiers, live scene surfaces |
| `e2e_test` | real scene streams chunks, textured surfaces bound in the scene graph, collision reads terrain |
| `features_test` | village + clock + HDRI sky, dimension switch both ways, glowstone in loaded chunks, mobs spawn, mining through the scene, **clicking a hotbar slot selects it and clicking off it does not** |
| `render_test` | textured and vertex-coloured surfaces, world-space bounds, camera present, HDRI panorama bound |
| `engineering_test` | material properties and serialization, component/port registration, port compatibility both ways, part geometry and mass, operation accept/reject leaving the part untouched, thermal gating |
| `engineering_sim_test` | connection graph, network formation and destruction, mechanical/electrical/fluid networks, overload bogs down rather than cheating, assembly recognition including unusual builds, LOD tiers, graph serialization |
| `engineering_world_test` | the full vertical slice: mine → smelt → workbench → manufacture → motor → wire → switch → pump → water, plus blueprint round trip, save/load, performance budgets |
| `diagnostics_test` | profiler sections and percentiles, JSON report, watchdog sampling, leak vs burst vs pressure classification, village power coupling on/off, wage payout, sleeping networks supply nobody |
| `multiplayer_test` | every exploit: unknown op, missing field, unjoined peer, rate-limit flood, out-of-reach build, ownership violation, forged economy, teleport, mid-session revoke, distance-filtered replication, audit log |
| `robustness_test` | save migration chain and forward-refusal, checksum integrity, backup recovery from a truncated file, complex factory round trip byte-identical, anti-duplication invariants, 12 000-tick soak for determinism / no growth / LOD sleeping / 60 successive autosaves |
| `systems_test` | one owner per system (a second world is refused), the lifecycle state machine including misuse-vs-failure, idempotent teardown, signal disconnection, run order and reverse teardown, a failed system not taking the frame with it, the API facade returning results instead of crashing, a client being denied every mutating call, and interrupted saves recovering from the backup |
| `architecture_test` | layer and visibility rules over the whole source tree, **tests of the checker itself** (a checker that never rejects anything is not a checker), exactly one world / inventory / profiler / player in `main.tscn`, the message envelope and direction rules, sequence ordering, determinism hashing and the fixed step, the threading rule, and the absence of the removed dead architecture |

## Honest limitations

* **No real GPU profiling has been done, because this environment has no GPU.**
  The instrumentation for it now exists and is wired to **F10** — fps, frame
  percentiles, process/physics time, draw calls, objects and primitives in
  frame, the three memory pools, and the video adapter name, with a JSON report
  written to `user://profiling/` every two minutes while the overlay is open.
  What that buys is that the numbers are now *obtainable* on real hardware in
  one keystroke. It does not mean anyone has run it on a GPU yet, and the
  regression suite cannot assert frame times headless, so it asserts the
  structural budgets (mesh cap, sleeping networks, no counter growth) instead.
* **Multiplayer is authority-only, not a transport.** `NetAuthority` is the
  complete server-side validation and the replication-shape logic, and it is
  tested against fourteen distinct attacks. It is not wired to a real
  `MultiplayerAPI` peer transport, because a loopback host/client pair cannot
  be stood up in a headless sandbox to prove the handshake. Everything above
  the transport is done; the socket layer is not.
* ~~**The HUD/crafting swatch metadata logs an error headless.**~~ **Fixed.**
  The cause was a Godot 4.4 behaviour, not a bug in the call sites:
  `get_meta(name, default)` still logs `The object does not have any 'meta'
  values with the key ...` when the key is absent, even though it correctly
  returns the default. Verified directly against 4.4.stable. Both call sites
  (`scripts/hud.gd`, `scripts/gameplay/crafting_panel.gd`) now guard with
  `has_meta` first, and start-up is clean.

* **Mouse hotbar selection was dead, and every suite passed anyway.** `_input`
  in `scripts/hud.gd` did `for slot in _hotbar`, where `_hotbar` is an
  `HBoxContainer`. A `Node` is not iterable in GDScript, so this was a *compile*
  error — the function never ran, and clicking a hotbar slot did nothing. It
  survived because no test clicked anything, and because a script that fails to
  compile fails *silently at the call site* in a headless run. Fixed to
  `get_children()`, and `features_test` now drives a real
  `InputEventMouseButton` through `hud._input` and asserts the selection
  changed — verified to fail when the fix is reverted.
* **Nothing has ever been rendered.** This environment has no GPU, no X11 and
  no Wayland. Every check is structural — properties exist and are enabled,
  shaders compile, voxels read back the right ids. No frame has been displayed,
  and `is_area_meshed()` stays false headless. Treat all visual claims here as
  unverified. What *has* been verified is that a standalone build exports,
  unpacks, checksum-matches and boots to a ready state with no script errors —
  but that is a start-up check, not a picture.
* **SDFGI is configured but not running** — it needs an `SDFGIProbeVolume3D`
  node, which cannot be created from script in Godot 4.4. Add one in the
  editor and the settings already in `RenderSettings` take effect. Bounce
  light currently comes from reflection probes.
* **SDFGI and SSIL and volumetric fog were not visually verified** — this
  environment has no GPU or display server, so every check is structural
  (the properties are real and enabled), not visual.
* **Inventory, crafting and saving exist but are shallow.** The container is
  GLoot and the save system is real and tested. The 3x3 crafting grid *is*
  fully drag-and-drop: `scripts/gameplay/crafting_slot.gd` implements
  `_get_drag_data`/`_can_drop_data`/`_drop_data` for grid cells, the result slot
  and the inventory strip, with source/target rules asserted by
  `crafting_ui_test` — an earlier version of this file wrongly said there was
  no drag-and-drop grid. What is genuinely still missing: there is no furnace
  or smelting, no tool tiers, no item durability, the recipe book is a small
  hand-written set rather than a scrolling book, and only the GDScript
  backend's edit log is saved — a converted Luanti world is read but never
  written back.
* **Villagers work and trade, but there is no dialogue** — no conversation
  tree and no reputation. The jobs are now real rather than decorative: each
  job has an entry in `Villager.JOB_WORK` giving it a verb and a clip, and
  every work cycle performs the matching world edit — the Farmer tills grass
  into soil underfoot, the Miner cuts stone out of the ground below the site,
  the Woodcutter fells nearby wood — while facing the work rather than the
  walk. A job with no world edit (a Guard) is honestly idle rather than
  falsely busy, and an off-shift or asleep villager touches nothing. Still
  missing: production is a timer gated on a resource being nearby, not a full
  simulation; there is no dialogue, no reputation, and Mobs have no breeding,
  hunger or taming. Note that the Miner and Woodcutter *deplete* what they
  work, so a village left running unattended will slowly strip its own stone
  and trees — regrowth is not implemented yet.
* **The crafting grid is a single screen** — one 3x3 recipe at a time, with no
  furnace, no smelting, no tool tiers, no durability and no recipe book to
  scroll. The 12-recipe book is a placeholder.
* Kenney's Impact Sounds and RPG Audio packs (the ones that would suit a voxel
  game best) are 404 at every mirror, so the interface pack is doubling as the
  effects bank.
* miniaudio is vendored (`addons/thirdparty/miniaudio/`, public domain / MIT-0)
  but **not compiled** — GDScript cannot call C. Godot's own `AudioDriver`
  already *is* miniaudio; it is just not exposed to scripting.
* **The Voxel Tools backend is new and only partly wired up.** Streaming,
  generation, voxel read/write, LOD terrain, the instancer and the stream
  objects are constructed and verified, and `F8` builds it at runtime. But
  mining/placing still goes through the GDScript world only: the two backends
  are not yet interchangeable in play, and nothing has rendered them.
* **Legacy Luanti worlds** load for the overworld only; The Deeps is always
  procedural.
* **Format versions below 27** decompress but skip legacy sections (node
  metadata, node timers) rather than parsing them fully.
