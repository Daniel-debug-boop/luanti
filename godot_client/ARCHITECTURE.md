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

## 4. The one world

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

## 5. Server boundaries and the message contract

Two files, two jobs:

* `NetAuthority` — **is this allowed?** Op allow-list, required fields,
  session check, per-peer token bucket, server-side economy charge, ownership
  on every node the command touches, and reach against the server's own
  clamped belief about where the player is.
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

## 6. Determinism

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

## 7. Threading

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

## 8. Ownership and lifetime of world entities

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

## 9. Persistence

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

## 10. What was removed, and why

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

## 11. How to check any of this

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

## 12. Keys

| Key | |
|---|---|
| F1–F3 | render quality |
| F4–F7 | texture mapping |
| F5 / F9 | save / load |
| F10 | performance overlay |
| F11 | architecture report |
| C | crafting grid |
| E | talk |
| F | use held tool |
| R | cycle interaction level (assisted / standard / precision) |
| B | engineering workshop |
| 1–8, G | hotbar, dimension |

`F8` is free. If you are about to bind it to a voxel backend, read §1 again.
