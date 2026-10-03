# EMERGENT architecture

This is the document a senior developer reads first. It is short because most
of what it says is *checked*: `scripts/core/architecture.gd` is the same
contract as data, `architecture_test` asserts it, and `F11` runs the full
check inside the game. If the code and this document disagree, the code is
wrong and the test will say so.

Read the sections in order. Section 1 is the one that changed everything.

---

## 1. What each engine owns

Three engines are in this repository. For a long time it was not clear which
of them was running, and the answer was "two of them, half-connected". It is
now unambiguous.

### Luanti owns: the legacy world format, and nothing else

The C++ tree (`src/`, `builtin/`, `irr/`, `games/`, `mods/`, `client/`,
`doc/`) is upstream Luanti 5.18.0, carried unmodified. In EMERGENT its role is
**a converter**, not a runtime:

* It owns the on-disk format of a legacy world: the `map.sqlite` block
  database, the node metadata tables, the format version negotiation.
* Godot reads those worlds through `scripts/world/chunk_files.gd` and
  converts them into the game's own format.
* Godot **never writes them back**. `ChunkFiles` has `load_chunk` and
  `has_chunk`; it deliberately has no `store_chunk`. A converted world is not
  modified in place, because a migration that can damage the thing it is
  migrating is a migration nobody will run.
* The Luanti mod API (`doc/lua_api.md`) is the *source of truth for original
  content definitions* — what copper ore is, how it smelts, what a villager
  does. EMERGENT's own systems re-implement that logic in GDScript; they do not
  call into it.
* `godot_client/` is outside the Luanti build entirely. It is not in
  `CMakeLists.txt`, not in any CI workflow, and no Luanti target depends on
  it. Building Luanti and building the game are two separate commands.

There is no IPC between them, no shared process, and no shared memory. If you
find yourself wanting one, the answer is to move the logic into the Godot
client, not to build a bridge.

### Godot owns: the running game

Everything the player actually experiences. `godot_client/` is the game, and
`scenes/main.tscn` is the only scene. Godot owns simulation, rendering, input,
UI, entities, persistence, the engineering system, the physics that the player
feels, and the server authority for multiplayer.

### Zylann Voxel Tools owns: nothing at runtime. Yet.

This is the change, and it deserves its own paragraph.

The project previously carried a second world. `scripts/world/zylann/
zylann_world.gd` built a Voxel Tools terrain that rendered into the same camera
as the real one, stored its own voxels in its own directory, and could be
toggled on and off with `F8`. **Nothing read it.** Mining went through
`VoxelWorld`. Physics went through `VoxelWorld`. Mobs, the village, the player
and the engineering system all went through `VoxelWorld`. The Voxel Tools
world was a second world with none of the game's rules attached to it, and it
was not saved with the game.

It has been deleted, along with its generator and its key binding.

The Voxel Tools *engine module* is still a legitimate thing to want: a
GPU-driven mesher and LOD would be a real win for a large voxel world. What is
not legitimate is it becoming a second world. The promotion path is therefore
written down rather than left to chance:

> A Voxel Tools integration must implement `WorldBackend` and be **swapped in
> at the meshing seam inside `VoxelWorld`**. It does not become a second
> world, and `WorldBackend.MAX_ACTIVE` is 1 so a second one is refused by
> name at registration rather than discovered by a player.

`tools/zylann_test.gd` is now a test of that boundary. It still reports
whether the engine module is present on the machine, because that is worth
knowing, but it no longer tests a shadow implementation.

---

## 2. The layer map

Eight layers, dependencies strictly downward. `main.gd` is the only thing in
the `app` layer, and it is the only place allowed to know about every other
layer, because assembling the game is its entire job.

```
                    ┌─────────────┐
                    │     app     │  main.gd — composition root, nothing else
                    └──────┬──────┘
        ┌────────────┬──────┴───┬────────────┬──────────┐
        │            │          │            │          │
   ┌────┴────┐  ┌────┴────┐  ┌──┴────────┐ ┌─┴───────┐ ┌┴──────────────┐
   │    ui   │  │   net   │  │engineering│ │diagnos- │ │               │
   │ WorldHud│  │Authority│  │ 19 modules│ │  tics   │ │               │
   │         │  │Protocol │  │           │ │profiler │ │               │
   └────┬────┘  └────┬────┘  └─────┬─────┘ │watchdog │ │               │
        │           │             │       │determ.  │ │               │
        │           │             │       │threading│ │               │
        │           │             │       └──────────┘ │               │
        └───────────┴──────┬──────┴──────────────────┘│               │
                           │                           │               │
                     ┌─────┴───────┐                   │               │
                     │  gameplay   │  player, mobs, villagers,           │
                     │             │  inventory, crafting, save          │
                     └──────┬──────┘                                      │
                            │                                             │
                       ┌────┴─────┐                                       │
                       │  world   │  voxels, generation, content,        │
                       │          │  meshing, rendering                   │
                       └────┬─────┘                                      │
                            │                                            │
                       ┌────┴─────┐                                      │
                       │   core   │  WorldBackend, EngArch,              │
                       │          │  Determinism, Threading              │
                       └──────────┘                                      │
                                                                        │
   (outside the game entirely)  Luanti C++ ──────────────────────────────┘
   read-only: the legacy world format
```

The rule, in one line: **a layer may use anything above it in this list and
its own layer, and nothing below.**

`mob` used to be a separate layer. It was not one: mobs need the player, the
world and the inventory, and a villager that cannot see a `Player` is not a
villager. Splitting them produced six violations that said exactly that, so
they were merged.

### What each layer owns

| Layer | Modules | May use |
|---|---|---|
| `core` | `WorldBackend`, `EngArch`, `Determinism`, `Threading` | nothing |
| `world` | `VoxelWorld`, `ContentDB`, `WorldGenerator`, `ChunkFiles`, `GreedyMesher`, `MaterialLibrary`, `RenderSettings`, `VoxelPick`, `DayNight`, `VoxelBlock`, `MapNode` | `core` |
| `gameplay` | `Player`, `PlayerInteraction`, `PlayerInventory`, `Crafting*`, `SaveGame`, `SaveMigration`, `Mob`, `Villager`, `Village`, `MobSpawner`, `Pathfinder`, `BlockDrop`, `Creature*`, `AudioDirector` | `core`, `world` |
| `engineering` | `EngEngineering`, `EngGraph`, `EngMaterials`, `EngPorts`, `EngPart`, `EngProcesses`, `EngAssembl*`, `EngMachines`, `EngSimulation`, `EngCursor`, `EngFastening`, `EngGeometry`, `EngTools`, `EngItems`, `EngWorkshop`, `EngBlueprints`, `EngSociety`, `EngModding`, `EngHud` | everything above |
| `net` | `NetAuthority`, `NetProtocol` | everything above |
| `ui` | `WorldHud` | everything above |
| `diagnostics` | `GameProfiler`, `StabilityWatchdog` | everything above |
| `app` | `main.gd` | everything |

---

## 3. Public and internal APIs

Every class in the project is declared in `EngArch.MODULES` with a layer and a
visibility. Adding a class without adding it there is itself a test failure,
which is deliberate: the table cannot quietly fall behind the code.

* **PUBLIC** — part of the API other layers use. Call it.
* **INTERNAL** — that layer's own business. Reaching in from another layer is
  a finding, *even when the dependency direction is legal*. This is what stops
  a helper quietly becoming load-bearing.

Examples of an INTERNAL module being reached into, and why it is wrong:
`EngSimulation` is the engineering layer's tick loop; the HUD wanting to
"just call `sim.step()` to check something" would make the HUD a participant
in the simulation, with a second entry point into the state the player can
mutate.

The scanner ignores class names that appear only in comments or string
literals, because prose is not coupling. It does *not* ignore `preload()`,
because a loaded script is a real dependency. A checker that cannot tell the
difference gets switched off, so this distinction is load-bearing.

---

## 4. One owner per system, and one door between them

`main.gd` is the only thing that constructs anything. Every major system
registers its authority in `SystemRegistry`, and a second registration of the
same name is **refused with a reason**:

| System | Owns | Registered as |
|---|---|---|
| World | the voxel world, its streaming and its edit log | `world` |
| Player | the body, its vitals, its collision | `player` |
| Village | mobs, villagers, settlements, job production | `village` |
| Engineering | components, machines, networks, blueprints | `engineering` |
| Net | authority over every mutation | `net` |
| Persistence | the save file, the slot, the backpack | `persistence` |
| Audio | sound playback and its per-frame budget | `audio` |
| Profiler | frame timing and engine counters | `profiler` |
| HUD | the on-screen readouts | `hud` |

`SystemRegistry.run_order()` is data: input, world, player, village,
engineering, net, persistence, audio, profiler, HUD. Anything not named runs
last, which is the right default for a presenter. `shutdown_all()` is its
exact **reverse**, so a system is always released before the thing it read.

### The door

Systems do not call each other. They call `GameApi`, which holds the owners
and forwards to their public API:

```
villager ──► GameApi ──► VoxelWorld / PlayerInventory / EngGraph / NetAuthority
```

Every fallible call returns a `GameApi.Result` — `ok`, `reason`, `value`.
GDScript has no exceptions, and a silent `-1` is how a refused action becomes
a mystery three systems later. Three properties the facade enforces:

* **Authority.** `api.authoritative` is true on the server. On a client,
  `set_block`, `give_item`, `manufacture` and `save` return
  `Result.denied()` instead of pretending to work. This is the structural
  half of *"the client says I want to; the server decides if"*.
* **Reasoning.** Every refusal says why, and the reason names a rule
  (`version`, `ownership`, `reach`, `not running`, `no room`).
* **Accounting.** `api.call_counts()` is per calling system, so a villager
  that went from 40 calls a second to 4000 is visible in a profile rather
  than guessed at.

## 5. Lifecycle

`System` is the base for anything with a lifetime. States are explicit and
forward-only except Suspend/Resume:

```
CREATED ──► INITIALIZED ──► RUNNING ◄──► SUSPENDED
                            │
                            └──► FAILED          DESTROYED
```

Resources, nodes, timers, threads and signal connections are acquired through
`own*()` helpers, never directly, because that is the only way the release
list stays complete. `teardown()` drains them in reverse order of acquisition
— connections before the objects they reference, threads before anything they
might be touching — and is **idempotent**, because shutdown in Godot is
routinely reached by two paths. `leaked()` returns what the system still owes
the process, and a non-zero value after teardown is a leak the soak test
watches.

One distinction matters and cost a rewrite to get right:

* `FAILED` means *the system is broken*. The registry stops ticking it and the
  game continues degraded.
* A **misuse** — `run()` before `initialize()`, `initialize()` twice — records
  the reason and changes **nothing**. Marking a working subsystem FAILED
  because of a bad call order somewhere else removes it from the game, and the
  next symptom is somewhere unrelated entirely.

## 6. Failure handling

Failure is a return value, not an exception and not a crash.

| Failure | Where it is caught | What happens |
|---|---|---|
| Missing system | `GameApi` returns `Result.unavailable` | the call is refused; the frame continues |
| System init failed | `SystemRegistry.start_all` | recorded; other systems run |
| Non-authoritative write | `GameApi.authoritative == false` | refused with the rule named |
| Invalid port/op/field | `NetProtocol.validate` | refused, `rule` says which check |
| Out of reach / not owned | `NetAuthority.submit` | refused, apply never called |
| Billed for a change that then failed | `NetAuthority.submit` | the ledger is restored before the refusal is returned |
| Truncated or spliced save | `SaveMigration.read_resilient` | recovered from `.bak`, and says so |
| Save from a newer build | `SaveMigration.migrate` | refused rather than guessed at |
| Corrupt network state | `EngAssemblies.recognize` | a hint, never a failure |
| Chunk generation failed | `StreamScheduler.step` | the job is cancelled, not fatal |
| Mod registered an unknown material | `EngMaterials.deserialize` | reported, the rest of the save applies |

`SystemRegistry.healthy()` is false only when a **required** system (world,
player, persistence) failed. Everything else is degradation, and
`health_report()` says what.

## 7. The one world

`WorldBackend` is the interface every voxel backend must satisfy:

```
backend_name, get_content_at, set_block, break_block, solid_at,
update_around, set_dimension, edits_snapshot, apply_edits_snapshot
```

Persistence is on the interface on purpose. A backend that draws beautifully
but cannot round-trip its own edits is not usable as *the* world — it is usable
as a renderer, and a renderer belongs behind the meshing seam.

`WorldBackend.register()` holds at most one active backend
(`MAX_ACTIVE == 1`) and refuses a second with a message naming the rule. A
second world is not something you discover by playing; it is something you
find out about the moment you try to add one.

### Singletons

Checked at every startup (`main.gd` → `EngArch.verify_runtime`) and by
`architecture_test` against the real `main.tscn`:

| | Count | How it is found |
|---|---|---|
| `VoxelWorld` | 1 | tree walk |
| `PlayerInventory` | 1 | tree walk |
| `GameProfiler` | 1 | tree walk |
| `Player` | 1 | tree walk |
| `NetAuthority` | 1 | a property of the composition root (it is a `RefCounted`, so it is not in the tree) |

---

## 8. Server boundaries and the message contract

Two files, two jobs:

* `NetAuthority` — **is this allowed?** Op allow-list, per-field schema,
  session check, per-peer token bucket, server-side economy charge, ownership
  on every node the command touches, and reach against the server's own
  clamped belief about where the player is. Charging and mutating are one
  event: a handler that reports failure is rolled back before the refusal is
  returned. There is no flag that disables any of it — a client that sends a
  field naming a check to skip (`ignore_reach` and friends) is refused, not
  obeyed.
* `NetProtocol` — **what is a message?** The envelope, the directions, the
  field requirements, the ordering rules.

### The envelope

```
{ v, t, from, to, seq, op, payload }
```

| Field | Meaning |
|---|---|
| `v` | protocol version. A mismatch is **refused, never negotiated and never retried** — a half-negotiated protocol is how a client ends up placing a motor inside a wall. |
| `t` | direction: `c2s`, `s2c`, `broadcast`. Enforced, not documentation. |
| `seq` | per-sender sequence number. A gap is *reported*, not fatal; a repeat or a regression is refused. |
| `op` | one of the declared messages. |
| `payload` | the fields that message declares as required. |

### Directions

| Direction | Messages | Kind |
|---|---|---|
| `c2s` | `hello`, `place`, `remove`, `connect`, `disconnect`, `manufacture`, `operate`, `capture_blueprint`, `place_blueprint` | request |
| `s2c` | `welcome`, `snapshot`, `delta`, `ack`, `reject` | state |
| `broadcast` | `broadcast` | state |

The two sets are **disjoint**, and every `s2c` message is `kind = "state"`.
That is the structural reason there is no client-authoritative path: there is
no message a client can send that means "the world is now this". Client
messages are requests; server messages are derived state that the client
renders and does not modify.

`reject` carries a `rule` field naming which check refused it
(`version`, `direction`, `schema`, `ownership`, `reach`, `rate`, …), so a
grief report and a bug report are distinguishable without a debugger.

### What is not done

`NetProtocol` and `NetAuthority` are the complete server side above the
transport. They are **not wired to a `MultiplayerAPI` peer transport** — a
loopback host/client pair cannot be stood up in a headless sandbox to prove
the handshake, and shipping an untested handshake would be worse than an
honest gap. Everything the handshake would call is done and tested.

---

## 9. Determinism

Two kinds of code, with opposite rules.

* **Simulation** — machines, networks, mobs, the world. Fixed step, integer
  ids, sorted iteration, no wall clock, no frame-timing-dependent float
  accumulation. Two servers given the same commands must reach the same
  state, or multiplayer is a guess.
* **Presentation** — meshes, UI, the profiler. May read the clock, allocate
  freely, depend on frame rate. Nobody compares two copies of it.

The boundary is enforced by `Determinism`:

* `SIM_HZ` / `SIM_DT` — one definition, used by the simulation and by the
  tests that assert on it, so they cannot drift apart.
* `quantise()` — the accumulator is snapped to a 1 µs grid, so adding to it a
  few hundred thousand times does not drift. A drifting accumulator means the
  factory runs at 9.98 Hz on one machine and 10.02 on another.
* `steps_from()` — at most `MAX_STEPS_PER_FRAME` (4) steps per frame. A hitch
  makes the factory run slow; it does not then run fast to catch up, because
  the catch-up would be the next slow frame.
* `hash_state()` — FNV-1a over canonical text, with dictionary keys sorted so
  insertion order does not change the answer, and no epsilon anywhere so a
  real divergence cannot hide.
* `assert_reproducible()` — runs a step function twice and compares hashes.
  `robustness_test` runs it over a 12,000-tick soak.

The rule of thumb: **anything a `hash_state()` call can reach must be
reproducible.** A new `randi()` or `Time.get_ticks_msec()` inside the
simulation is a bug, and the way to find it is to hash, run twice, compare.

---

## 10. Threading

EMERGENT is single-threaded **by decision**. Godot's scene tree, physics
servers and rendering servers are main-thread objects; touching one from a
worker is undefined behaviour that surfaces three frames later, somewhere
unrelated. The temptation with a voxel world and a 10 Hz network simulation is
to move the simulation to a worker, and that is exactly the change
`Threading` exists to make hard.

> The main thread owns the world. A worker may compute from immutable inputs
> and return a value; it may not touch the scene tree, the voxel world or the
> engineering graph to hand one over.

The escape hatch is deliberately narrow and sufficient: computing a mesh
buffer, a path, a chunk of noise, or a hash on a worker, and applying the
result on the main thread's own tick.

`Threading.guard()` is called by the mutators that matter. It costs one integer
comparison, records a *typed* violation rather than crashing — a violation
during development should produce a report you can read, not a hard failure
that costs the player their factory.

`Threading.MAIN_THREAD_ONLY` names the classes that are main-thread-only. It
names them **as strings** and references none of them, so that the core layer
can state the rule without depending on the layers the rule is about.

---

## 11. Ownership and lifetime of world entities

**Who owns a node.** `main.gd` owns everything. It creates the world, the
player, the inventory, the engineering root, the HUD, the profiler and the
authority, and it is the only thing that frees them. Subsystems hold
references to each other but never `queue_free` anything they did not create.
A component placed in the engineering graph owns only its own data; its
`MeshInstance3D` visual is owned by the engineering root's visual table and is
returned to the pool when the node leaves the streaming radius.

**What lives as long as what.**

| Entity | Owner | Freed when |
|---|---|---|
| `VoxelWorld` | `main.gd` | the process ends |
| `PlayerInventory` | `main.gd` | the process ends; contents persist in the save |
| Engineering graph nodes | `EngEngineering` | the player dismantles them, or the dimension changes |
| Component visuals | `EngEngineering` visual table | outside `VISUAL_RANGE`, or the cap is hit, or a dimension change |
| `BlockDrop` | the drop collection on `main.gd` | collected, or after its lifetime |
| Mobs and villagers | the village / spawner | despawn, or a district change |
| Profiler, watchdog, authority | `main.gd` | the process ends |

**Rules that follow from the table.**

1. **Nothing creates a world.** `WorldBackend` enforces it.
2. **Nothing creates an inventory.** There is one GLoot container; engineering
   items are *prototypes inside it*, registered when the engineering system is
   attached to it. A second container would mean a second save path, a second
   set of hotbar rules, and no way to tell which one the player was looking at.
3. **Visuals are the only thing that is pooled.** They are the expensive,
   numerous, and stateless part. Everything with state is long-lived.
4. **A dimension change drops the factory, not the world.** `_switch_dimension`
   clears the engineering graph so The Deeps does not carry the overworld's
   factory in memory.

---

## 12. Persistence

One save format. Every subsystem is a **section** of the same `Dictionary`.

`SaveGame` is below the gameplay layer and persists subsystems through a
duck-typed `Object` answering `serialize()` / `deserialize()` — it does not
name `EngEngineering`, and must not. Naming a concrete class there made
persistence depend upward on a system it has no business knowing about, and
would have made every future subsystem an edit to that file.

`SaveMigration` adds the durability:

* **A version chain.** Every format change appends a step; a step is a pure
  function from old Dictionary to new. A migration that *rewrites* the payload
  to whatever the newest shape happens to be will silently destroy a save
  whose data is already richer than the step understands, so the current step
  is **additive**: a section already in the current shape is stamped and left
  exactly as it is.
* **Forward compatibility is refusal, not guessing.** A save from a newer build
  is reported, not loaded.
* **Integrity.** A checksum over canonical JSON. "Canonical" is load-bearing:
  JSON has one number type, so an integer comes back from the parser as a
  float and re-serialises as `0.0` where the file said `0` — a raw hash over
  the serialisation would make every save fail its own check.
* **A backup taken before each write.** `F9` recovers automatically from the
  `.bak` when the slot is truncated or spliced, and says which file it used.

---

## 13. Assets as a pipeline, not a folder

**The art contract is written down before it is executed.** `assets/ART_DIRECTION.md`
states the rules (one texture tile per one-metre block face, one unit is one
metre, desaturated mid-key, tiling terrain only, CC0 only) and the three
things the project deliberately refuses to do (parallax occlusion below ULTRA,
4K runtime textures, LODs on skinned characters). `assets/rejected/` records
the refusals with their reasons, because a decision nobody wrote down gets
re-litigated by the next person.

**One catalogue, four stages.** `tools/asset_catalog.py` declares every
texture set, model, HDRI and character, with its provider, source ID, licence,
author, resolution ladder and role. Nothing else knows a download URL:

```
asset_catalog.py
   -> acquire_assets.py    download + checksum -> source/ + manifest
   -> process_textures.py  resample/encode/derive -> runtime/textures/
   -> make_lods.py         validate/decimate/bake scale -> runtime/models/
   -> import_assets.py     Godot importer -> .import manifests
```

The catalogue is the authority, not this document and not the manifest. Adding
a texture set means editing `TEXTURES` in the catalogue and re-running the
stages; nothing is hand-placed into `assets/runtime/`.

**Source and runtime are separate trees, and only runtime ships.**
`assets/source/` is 201 MB of raw provider downloads and is gitignored;
`assets/runtime/` is 123 MB of converted textures, 39 MB of decimationed
models and 13 MB of HDRIs, and is committed. The manifest in
`assets/source_manifest/` records the URL, checksum, licence, author,
acquisition date, conversion and optimisation for both, so the runtime tree is
reproducible without trusting the repository that holds it.

**No rung is ever an upscale.** `tiers_for()` caps each set's resolution
ladder at the resolution its source actually has. A 1K texture produces 1024 and
512 and nothing else. Upscaling invents no detail, costs memory, and looks
worse than the rung below it.

**Scale is baked into geometry, never applied at runtime.** `village.gd` used
to carry a hand-tuned `scale` per prop kind. That put a model's real size in a
place with nothing to do with the model, and made the LOD chain disagree with
the node about world size. `make_lods.py` now bakes the scale into the glTF
(`BAKE_HEIGHT` in the catalogue), so `Lantern_01` ships at 0.50 m of real
geometry and the game places every prop at `Vector3.ONE` scale.

**LOD is Godot's, not ours.** `_attach_lods()` sets
`MeshInstance3D.visibility_range` on each tier's meshes — 14 m to LOD1, 34 m
to LOD2 — and adds LOD1/LOD2 as sibling child nodes. There is no per-frame
script and no camera polling, because the LOD system's whole job is to remove
per-frame cost.

**The importer works around an engine deadlock.** `godot --headless --import`
hangs on the second VRAM-compressed texture in any single process, in this
environment, with no GPU and no display. `tools/import_assets.py` therefore
imports one asset per throwaway mirror project and merges the results; a
Godot `.import` payload is addressed by `md5("res://" + path)`, not by which
project produced it, so the output is identical. This is documented in
`assets/THIRD_PARTY_ASSETS.md` with the full reproduction.

**`asset_test` is the acceptance test for all of it.** It fails the build if a
manifest entry lacks a licence, an author, a source page, a date or a
checksum; if a licence is not CC0; if a map is not a power of two or does not
match its rung name; if a set writes a rung above its source resolution; if a
model has fewer than three tiers or tiers that do not decrease; if a block id
resolves to a different texture set than the catalogue promises; if an HDRI is
on disk but not named in `day_night.gd`, or named in code but not on disk.
Pipeline defects that are not yet visible in-game are warnings, not failures,
and the suite prints both counts.

---

## 14. What was removed, and why

Nothing here was removed for tidiness. Each removal closed a hole where two
systems could answer the same question.

| Removed | Why |
|---|---|
| `scripts/world/zylann/` (2 files, 405 lines) | A second world that nothing read. See §1. |
| `F8` / `_toggle_zylann()` | Only existed to build the above. |
| `PlayerInteraction.hotbar` | A fixed block list kept "so the old tests still worked", giving **two** answers to "what is the player holding". Now `-1` — unknown is not a free stone — and the inventory is the only answer. |
| `PlayerInventory`'s dependency on `EngItems` | The container asked the engineering system what exists. The composition root and `EngEngineering.attach()` now register prototypes *into* the container; the container knows the shape of a prototype and nothing about its contents. |
| `PlayerInventory`'s bill helpers | A bill mixes blocks and components; resolving one is engineering's job, not a container's. Moved to `EngItems`. |
| `SaveGame`'s dependency on `EngEngineering` | Persistence is below gameplay and must not know what it persists. Now duck-typed. |

The `mob` layer, `MobSpawner` being INTERNAL, and the separate HUD hotbar
fallback were also removed as *decisions recorded in the table* rather than
code: each was a rule the scanner flagged, and each was resolved by writing
down the intent, not by suppressing the finding.

---

## 15. How to check any of this

```sh
sh godot_client/tools/run_tests.sh <path-to-godot>
```

| Where | What | Cost |
|---|---|---|
| `architecture_test` | every rule in this document, plus tests of the checker itself | source scan |
| `EngArch.violations()` | layering + visibility findings, with file and line context | source scan |
| `EngArch.verify_runtime(node)` | singleton counts in a live tree | one tree walk |
| `main.gd` at startup | `verify_runtime`, on debug builds only | one tree walk |
| **F11** in game | the full report, including the source scan | a keypress |
| **F10** in game | the performance overlay | — |

`architecture_test` deliberately feeds the checker *bad input* — a core module
using a world type, a UI module reaching into an INTERNAL, a class named only
in a comment, a preloaded script. A checker that has never rejected anything is
indistinguishable from one that always passes, and the second kind gets
trusted.

---

## 16. Keys

| Key | |
|---|---|
| F1 | render quality low |
| F2 | render quality medium |
| F3 | render quality high |
| Shift+F1 | render quality ULTRA (the only tier with parallax occlusion) |
| F4 | cycle block texture mapping (Shift+F4 reverses) |
| F5 | save |
| F9 | load |
| F10 | developer tools |
| F11 | system health report |
| F12 | performance overlay |
| C | crafting grid |
| E | talk |
| F | use held tool |
| R | cycle interaction level (assisted / standard / precision) |
| B | engineering workshop |
| 1, 2, 3, 4, 5, 6, 7, 8 | hotbar slots |
| G | switch dimension |
| Q | stow the selected slot into the backpack |
| V | toggle flight (creative) |
| Enter | capture the mouse |

`F8` is free. If you are about to bind it to a voxel backend, read §1 again.

Texture mapping is one key that cycles, not four keys, because four modes on
four consecutive keys reached F5 -- which is save. Only the first branch for a
key runs, so one mapping mode was unreachable.

`Q` exists because of the same class of bug. The starting kit fills all eight
hotbar slots with blocks, `fill_hotbar_from_inventory()` only ever considered
blocks, and `stow_selected()` was called from nowhere. So a manufactured part
could never be *held* -- and holding it is exactly what `F` means, which made
the whole component-placing verb unreachable in ordinary play. A key table
cannot show you that. Only playing to that point can.

Two keys used to be claimed twice, and both were found by `playable_test.gd`
rather than by reading the code:

- **F5** was both save and the second texture mapping mode. One `if/elif`
  chain, first branch wins: the mapping was dead code the table advertised.
- **F** was both "use held tool" and the flight toggle. These are two different
  nodes, each with its own `_unhandled_input`, so *both* ran: every attempt to
  place a part also toggled flight. Flight moved to V.

Note the second one is a different failure from the first, and the harder one.
`F5` was one `if/elif` chain in one file, which a duplicate scan catches.
`F` was claimed in two different files by two different nodes, where a
duplicate scan of `main.gd` alone would find nothing -- and a key is *not* a
global resource. It is a per-node branch, and two nodes listening for it both
fire. Unhandled input has no first-come-wins rule; the scene tree delivers to
every node that wants the event.

A key table is a claim about the running program, so it is tested like one.
`playable_test.gd` reads this table out of the code and refuses a key that is
not bound, that is bound in the wrong file, or that is claimed twice.

## 16. What "playable" means here, and how it is checked

`playable_test.gd` loads the real `scenes/main.tscn` and plays it: chop a tree,
collect the wood, place a block, manufacture a workbench, make hotbar room to
hold it, place it, save, reload, and check that the world, the backpack and the
assembly all came back.

It exists because nineteen other suites were green while the game was unplayable
in three ways at once. Each of those bugs was invisible to a suite that asserted
on a *return value* rather than on the *effect*:

| Bug | Why the other suites missed it |
|---|---|
| Loading a save wiped the backpack | The load returns `ok: true`; the test checked the result, not the pack. |
| A manufactured part could never be held, so F did nothing | Nothing ever held one, so nothing ever noticed. |
| Placing charged the bill twice | Only visible if you can afford the first 8 and then check the second. |

The general rule: **assert on the world, not on the report.** A function that
returns a result and a function that changes the game state are two different
contracts, and only the second one is the one a player experiences.

Where a test must stand in for a player, it says so in a comment. `_walk_to`
moves the player rather than synthesising held keys, because `Input.get_vector`
reads real key state and the synthesiser would be what is under test. Headless
runs also have no mouse capture, so aiming goes through the game's own
`Player.look_along()` instead of fabricated mouse motion -- which is why that
method exists at all.
