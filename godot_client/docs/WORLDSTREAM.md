# WorldStream

A native streaming module: a latitude/longitude goes in, H3 cells come out;
Mapbox vector-tile bytes go in, building/highway/landuse geometry comes out;
that geometry comes out again as meshlets, ready for a GPU.

Two things it deliberately is not:

* **not a second world.** It does not register with `WorldBackend`, does not
  generate voxels, holds no region data, and appears nowhere in the "exactly
  one world" rule that `systems_test` and `zylann_test` enforce. It produces
  arrays; placing them is somebody else's decision.
* **not a tile fetcher.** `ws::TileSource` is an interface, and the module
  never opens a socket or a file. This is what makes the whole thing testable
  with no I/O and lets the caller decide between an HTTP cache, a local
  fixture and a pre-baked archive.

## Layout

```
worldstream/
  src/                   the modules (headers + implementation)
    ws_types.hpp         value types: footprints, splines, meshlets, batches
    ws_arena.hpp         bump-pointer arena + fixed pool (no frame heap churn)
    ws_ring.hpp          SPSC lock-free ring with release/acquire hand-off
    ws_streamer.hpp/.cpp Module 1: H3 grid + vector-tile parsing
    ws_mesher.hpp/.cpp   Module 2: extrusion, ribbons, meshoptimizer meshlets
    gdextension/         the Godot binding (two RefCounted classes)
  tools/worldstream_test.cpp   the native unit suite (no Godot, no I/O)
  third_party/           pinned submodules
  ws_build_profile.json  the godot-cpp profile the extension is built with
  CMakeLists.txt         one tree: core, tests, optional GDExtension

ws_build/
  build.sh               the entry point (resumable; see below)
  gen/                   generated godot-cpp bindings, committed
  bin/                   libworldstream.*.so, built (git-ignored)
  build.log, cfg.log     last build's logs, committed

addons/worldstream/worldstream.gdextension   what Godot loads
scripts/world/world_stream.gd                the scripted facade
tools/worldstream_test.gd                    the Godot-side end-to-end suite
```

Pinned dependencies (`third_party/`, plus `godot-cpp` beside the project):
h3 (H3 grid), vtzero + protozero (vector tiles), meshoptimizer (meshlets),
spz and earcut (geometry). They are git submodules at fixed revisions; the
build never downloads anything, so a checkout either has its sources or fails
with the exact `git submodule update` command that would get them.

## Build

```sh
sh ws_build/build.sh                  # everything
sh ws_build/build.sh --no-extension   # core + tests only
sh ws_build/build.sh --full-godotcpp  # untrimmed godot-cpp bindings
JOBS=4 sh ws_build/build.sh           # parallel build
```

The script is **resumable**: it is incremental and checks each artifact before
its stage, so it can be interrupted (or killed by a time limit) and re-run.
That matters because godot-cpp is the long pole and on a single-core machine
it *will* be interrupted. It requires `cmake` on `PATH`
(`pip install cmake` on a machine without it).

It writes `ws_build_status.log` (`GODOTCPP_BUILD_DONE`, `GODOTCPP_LIB_DONE`,
`WORLDSTREAM_CORE_DONE`, `WORLDSTREAM_TESTS_PASS`, `WORLDSTREAM_LIB_DONE`) and
runs the native suite as part of the build: a build that produces an artifact
whose tests fail is not a successful build.

### Why godot-cpp is built from a profile

The default godot-cpp build compiles 1 964 generated source files. The
extension uses Variant types and its own registered classes only -- it calls
no engine class method -- so `ws_build_profile.json` lists the classes
godot-cpp's own core needs (`RefCounted`, `OS`, `Mutex`, `Semaphore`) and the
generated API shrinks to 82 files. Same library, same behaviour, a build that
finishes on a single core. Use `--full-godotcpp` when adding binding code that
touches engine classes; the profile file explains what to add and why.

## Using it from GDScript

```gdscript
var ws := WorldStream.new()
if ws.available:
    var cells := ws.cells_around(37.8715, -122.2730, 9, 2)   # H3 disk
    var parsed := ws.parse_tile(bytes, cells[0], 9, 1000.0)  # tile bytes in
    var data := ws.build_meshlets(parsed["batch"])           # geometry out
    var mesh := ws.mesh_from_meshlets(data)                  # renderable
```

`WorldStream` is the facade: it checks that the native class exists *and*
that its `module_version()` matches the version the script was written
against, and otherwise reports `available = false` with a reason. Every method
then degrades to an empty result. Three states are legitimate and all three
must not crash anything: built, not built, and built-but-stale.

Coordinates are tile-local metres centred on the tile, with y flipped so +y is
north (MVT's y grows downward). Deeper conversions -- H3 radians, MVT integer
units for a given extent -- happen at the boundaries of the native modules and
nowhere else.

## Verification

| Suite | What it proves |
| --- | --- |
| `worldstream_native` (C++) | arena alignment/exhaustion/recycling, ring order and backpressure accounting, H3 disk sizes (1 / 7 / 19), degree↔radian handling, and on the fixture tile: metres conversion, MVT y-flip, `height` beating `building:levels`, per-class stats, unknown layers skipped, garbage refused. Then meshing: earcut roofs, wall normals, road lift, every index in range, **every meshlet inside its own 64/126 window**, bounds, and byte-identical rebuilds |
| `worldstream_test` (Godot) | the same chain through the extension: H3 queries, the resolution band, the fixture parsed through `Marshalls.base64_to_raw`, classes and stats, meshlet limits, `mesh_from_meshlets` producing a real `ArrayMesh` with one surface, determinism, and the failure paths (garbage refused, nothing handed back) |

Both suites report either state honestly: the native suite is skipped by
`run_tests.sh` with the command that builds it when it is absent, and the
Godot suite prints `info native module present: false` and passes on its
degradation assertions. A suite that cannot tell "absent" from "broken" is not
a suite.

The fixture lives in `worldstream/tools/worldstream_test.cpp` (encoded with
protozero) and is printed as base64 by that test; `tools/worldstream_test.gd`
carries a copy of that string. One encoder, two consumers -- two hand-written
fixtures would drift.

## Honest limitations

* **Nothing renders it yet.** The output is verified to build a real
  `ArrayMesh`, and that is where it stops: there is no node that streams OSM
  tiles, no material for the ids the parser emits (every feature gets
  `material_id = 0`), and no place in `main.tscn` that draws them. The module
  is a source of geometry; turning it into a city is a product decision, not a
  wiring gap.
* **No tile fetcher.** Callers supply bytes. H3 cells are the cache key, and
  the ring/arena are built for a worker-thread producer, but the fetch stage
  does not exist.
* **AO is a placeholder** (`ao` is a wall height gradient, roofs are 1.0); the
  field exists so a real bake has somewhere to write.
* **Road width is a parameter, not a tag.** `Spline` carries no width, so
  every road ribbon uses `road_width_m`.
* **`Meshlet` normal cones are computed and carried, but no mesh shader reads
  them** -- Godot has no mesh-shader path, so the meshlet arrays exist for a
  consumer that does not exist yet. The index/vertex arrays are what the
  current renderer path consumes.
* The `linux.debug` and `linux.release` slots in the `.gdextension` point at
  the same release-built library, deliberately; see the file's comment.
