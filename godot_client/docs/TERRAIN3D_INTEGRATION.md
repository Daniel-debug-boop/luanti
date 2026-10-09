# Terrain3D as the terrain representation layer

This is the boundary between **who decides what the world is** and **who draws
it**. Arnis is the first; Terrain3D is the second. Neither is allowed to become
the other.

```
OSM + elevation/DEM
  -> Arnis                          authoritative geographic/world backend (offline)
     -> converted chunks + manifest  the authoritative world data
        -> Launti (this Godot client)
           |-- VoxelWorld        voxels, collision, edits, caves, buildings, roads
           |                     water, vegetation, POIs, gameplay entities
           `-- TerrainLayer      ground surface -> Terrain3D
                 -> Terrain3D   terrain mesh + LOD + terrain materials + detail
                    -> Godot Forward+
```

## Who owns what

| Concern | Owner | Notes |
|---|---|---|
| Geographic/world data | **Arnis** (offline, via converted chunks) | elevation, land layout, what exists where |
| Chunk bytes, coordinate lattice, manifest/provenance | **ChunkFiles** | unchanged by this work; see `docs/ARNIS_INTEGRATION.md` |
| Voxels, collision, digging, caves, edits | **VoxelWorld** | still authoritative for gameplay and physics |
| Ground surface mesh, terrain LOD, terrain materials, ground detail | **Terrain3D** | reads heights, never invents them |
| Buildings, roads, water, land use, POIs, entities | **Launti systems** | deliberately *not* baked into Terrain3D |

Terrain3D is a renderer here. It has no generator, no noise, no fallback, and
no data of its own on disk: nothing in this layer ever calls `save`, and the
`data_directory` setting is deliberately left empty so a stray run cannot leave
a second copy of the world behind.

## Version

* **Terrain3D 1.0.2** (`addons/terrain_3d/plugin.cfg`), matching the project's
  **Godot 4.4** (`project.godot`, `config/features` = `4.4`, Forward+).
* Upstream states 1.0.2 supports Godot 4.4–4.6
  (<https://terrain3d.readthedocs.io/en/stable/docs/installation.html>;
  Godot Asset Library asset 3892). The version is pinned in `plugin.cfg` and
  the addon is vendored under `addons/terrain_3d/`, so a client build is not
  affected by whatever upstream publishes next.
* The addon is isolated: `addons/terrain_3d/**` is upstream code and is not
  edited here. Everything Launti adds lives in `scripts/world/`.

## Coordinate transform

One node is one metre, and Terrain3D is configured with
`set_vertex_spacing(1.0)`, so **no scale factor exists anywhere in this
pipeline**. There is also no axis swap and no sign flip. Stated in full:

| Space | X | Y | Z | Unit |
|---|---|---|---|---|
| Arnis / converted chunk (Luanti block lattice) | `bx*16 + x` | `by*16 + y` | `bz*16 + z` | node |
| Launti world (`VoxelWorld`, `ChunkFiles`, player) | same | same | same | node = 1 m |
| Terrain3D sample | same X | **height** (top face of the column) | same Z | metre |

The height written for a column is `top_node_y + 1`, the **top face of the
highest ground node** in that column — the plane the player stands on. The
mapping is applied as:

* `ArnisTerrainSource.surface_y(wx, wz)` returns that height, or `NAN` when the
  authoritative world has no such column.
* `TerrainLayer` writes it into Terrain3D's height map at sample `(wx, wz)`
  (region = 256 samples, origin = the region's lower-left sample).
* Region `Vector2i(rx, rz)` covers world X in `[rx*256, rx*256 + 255]` and the
  same in Z, so a region boundary is a chunk boundary at every 16th chunk.

Because X and Z are never exchanged or negated, a road or building placed by
Launti at node `(wx, wy, wz)` stands on the terrain surface at `(wx, ·, wz)`.
The tests pin this with **asymmetric** fixtures (different heights on the +X
side than on the +Z side); a symmetric world cannot detect a swap.

## Data flow at runtime

1. `TerrainLayer.configure()` refuses if the Terrain3D class is not registered,
   or if the world directory has no converted-world manifest. A refusal is a
   message and the game runs exactly as it did before this layer existed.
2. `TerrainLayer.update_around(focus)` — called from `main.gd` each frame —
   keeps the regions within `stream_radius` resident, building at most
   `regions_per_update` per call (nearest first) and dropping regions that fall
   outside the radius. The whole converted world is never loaded: cost is the
   player's visible window, not the world's size.
3. Heights come from `ArnisTerrainSource`, which reads the converted chunk
   files. For a chunk that exists on disk *and* is resident, it reads the live
   world instead, so a dug hole or placed block reaches the terrain surface.
   A chunk that is **not** on disk is never read from the live world.
4. A column the world does not contain is written as a Terrain3D **hole**
   (control-map hole bit), not as `0.0`. `0` is a legal height (the world
   floor); absence must not be indistinguishable from it.
5. `VoxelWorld` asks `TerrainLayer.covers_chunk()` before meshing. A chunk it
   can hand over loses the upward faces of its ground blocks
   (`GreedyMesher.hidden_tops`); side faces, caves, overhangs, buildings,
   roads and water are untouched. `TerrainLayer.coverage_changed` re-meshes
   only chunks whose status actually changed.
6. On the voxel side, `VoxelWorld.ground_layer` defaults to `null`. With no
   layer, meshing is byte-for-byte what it always was.

## Materials

`Terrain3DMaterialSet` builds Terrain3D's own `Terrain3DTextureAsset` sets from
the project's existing content ids and open-source runtime textures (ambientCG
/ Poly Haven assets already vendored under `assets/runtime/textures/`). The
assignment is data-driven: a column's texture id is derived from the ground
content the authoritative chunk actually contains, via
`ArnisTerrainSource.classify()`. No bespoke shader is written; Terrain3D's
supported material system is used as-is. Texture sets are only created for
ground ids, so a future content id cannot quietly become terrain.

## What stays out of Terrain3D

Roads, buildings, waterways, land-use data, POIs and gameplay entities remain
Launti/voxel concerns. `ArnisTerrainSource.GROUND_IDS` is the whole definition
of "this node is terrain": water and ice are hydrology, wood/leaves/cactus are
vegetation, and planks/concrete/asphalt/glass/metal are things that were built.
Asphalt on a hillside therefore reports the **hillside's** height, which is what
makes "the road sits on the terrain" true by construction rather than by luck.

## Tests

`tools/terrain3d_test.gd` (part of `tools/*_test.gd`, run by
`tools/run_tests.sh`) covers:

* A/B — authoritative world detection and the Arnis -> Launti -> Terrain3D
  coordinate transform, on asymmetric heights.
* C/D/E — known elevations on flat ground, slopes, high/low points, and
  continuity across chunk and region boundaries.
* F/G — streaming (resident set, drop distance, holes preserved) and Terrain3D
  LOD (a coarse and a fine bake of the same data).
* H — alignment: a prop placed at a node stands on the sampled surface, and
  the baked mesh spans the fixture's real relief.
* I — authoritative absence stays absent: the procedural generator is never
  entered (a counting spy generator asserts `calls == 0`), and the voxel world
  still refuses to fill a missing authoritative chunk.
* J — non-authoritative/legacy worlds still fill gaps procedurally and still
  hand over only the chunks that are really present.
* K — reload determinism: two independent loads of the same world produce
  identical terrain.
* The renderer-ownership rule: the handoff removes exactly the upward ground
  surface (measured by area), and a *partial* handoff removes exactly the
  covered half and no side faces.
* Materials: every registered content id is classified deliberately (none lands
  in `unknown`), ground ids get a Terrain3D texture id, and a built id never
  does.

`tools/arnis_authoritative_test.gd` remains the guard on the Arnis side and is
unchanged by this work.

## Known limitations

* Collision is off by default on the layer (`enable_collision = false`):
  voxels are authoritative for physics, and a second collision surface under
  the player would be a bug.
* Terrain3D only draws over chunks the layer has complete authoritative
  coverage of. A partially covered chunk keeps its voxel ground, so a streaming
  edge can show voxel ground next to Terrain3D ground by design rather than a
  hole.
* The `--terrain3d` flag is opt-in. Without it the game is exactly the voxel
  renderer it was, which keeps the integration testable and reversible.
* Terrain3D texture sets are only as good as the project's texture import
  pass: the sets and texture ids are built from `assets/source_manifest/`
  regardless, but in a checkout where `assets/runtime/textures/**` has not
  been imported the maps do not load and the ground renders in flat vertex
  colour. That is the same dependency every other material in the project has,
  and it is why the material assertions check the derived mapping rather than
  pixel output.
