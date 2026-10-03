# Third-party assets

Every third-party asset in EMERGENT is **CC0 1.0 Universal** (public domain
dedication). There is no asset in this repository under a share-alike,
attribution-required or otherwise restrictive licence, and none may be added
without updating this file and `assets/source_manifest/manifest.json` in the
same commit.

`tools/asset_test.gd` fails the build if any manifest entry lacks a licence, an
author, a source page, an acquisition date or a checksum, and it fails if a
licence string is not CC0. That check is the reason the columns below are not
just documentation.

## Layout

| Directory | Contents | Tracked? |
| --- | --- | --- |
| `assets/source/` | Raw downloads exactly as the provider served them, plus unpacked ambientCG zips | **No** — 201 MB, gitignored |
| `assets/source_manifest/manifest.json` | Machine-readable record: URL, md5/sha256, licence, author, source resolution, conversion, optimisation, measured output, destination | Yes |
| `assets/runtime/textures/` | Converted texture ladder the game loads | Yes — 123 MB |
| `assets/runtime/models/` | Decimated glTF LOD chains the village loads | Yes — 39 MB |
| `assets/runtime/hdri/` | Sky panoramas for the day/night cycle | Yes — 13 MB |
| `assets/rejected/` | Candidates that were downloaded or considered and then refused, with the reason | Yes |
| `assets/ART_DIRECTION.md` | The art contract this pipeline implements | Yes |

The split between `source/` and `runtime/` is the reproducibility boundary.
`source/` is what a provider published; `runtime/` is what the game reads. Only
the second is committed, and it can be regenerated from the first plus the
four tools below.

## Pipeline

Four stages, in order. Each is idempotent and each reads
`tools/asset_catalog.py` as its single source of truth — the catalogue, not
this document, is what the code executes.

| Stage | Tool | Does |
| --- | --- | --- |
| 1 | `tools/acquire_assets.py` | Downloads every catalogue entry from the provider's own API, verifies md5 (Poly Haven, KayKit) or sha256 (ambientCG), writes the manifest |
| 2 | `tools/process_textures.py` | Lanczos resamples each map onto the 2048/1024/512 ladder, re-encodes, derives ARM and height, composes the ore sets, wipes and rewrites `runtime/textures/` |
| 3 | `tools/make_lods.py` | Validates each glTF, decimates to LOD1/LOD2, enforces the 20k-triangle prop budget, bakes per-model scale, writes `runtime/models/<name>/lod{0,1,2}` |
| 4 | `tools/import_assets.py` | Runs Godot's importer over `runtime/` and produces the `.import` manifests |

Requires Python 3 with Pillow (`tools/requirements.txt`). Godot's binary
importer is dev-only tooling; nothing in `tools/requirements.txt` ships.

```sh
python3 tools/acquire_assets.py      # needs network
python3 tools/process_textures.py
python3 tools/make_lods.py
python3 tools/import_assets.py
```

### Why stage 4 is a separate script

`godot --headless --import` **deadlocks in this environment** when a single
process imports more than one texture. Reproduced on stock
`Godot_v4.4-stable_linux.x86_64` with no GPU and no display:

| Condition | Result |
| --- | --- |
| One 512×512 texture, `compress/mode: 2` | Imports in ~6 s |
| Two 512×512 textures, `compress/mode: 2` | Hangs indefinitely |
| Two 512×512 textures, `compress/mode: 0` | Imports in ~8 s |
| Two hung processes run in parallel | Both stay hung |
| Any size (16 px, 512, 1024, 2048 px) | Same deadlock on the second file |

CPU time during a hang is ~6 s against ~170 s of wall clock, so this is a
block, not slow work. The deadlock is per-process, which means it can be
worked around rather than solved: a Godot `.import` file and its `.ctex`
payload are named and addressed purely by the `res://` path
(`<basename>-<md5("res://" + path)>`), not by which project directory produced
them. `tools/import_assets.py` therefore gives **each asset its own
throwaway mirror project**, imports it in one process, and copies the result
back. Output is byte-identical to what a single full-tree import would produce.

The import is resumable: a run cut short by a shell timeout picks up where it
left off, and `already_imported()` treats an `.import` file with a missing or
zero-byte payload as *not* done — a half-written import otherwise reports
itself as present while loading nothing.

## Conversion and optimisation

Uniform across every texture set, from `process_textures.py`:

- **Resample** — Lanczos to 2048 / 1024 / 512. The ladder is capped at the
  source resolution by `asset_catalog.tiers_for()`, so a 1K source never
  produces a 2048 rung. Nothing is ever upscaled.
- **Data-map cap** — normal, ARM and height maps are written at half the albedo
  rung above 1024 (`DATA_CAP = 1024`). A 2048 albedo is lit by 1024 data maps.
- **Albedo** — JPEG quality 88, 4:4:4 chroma, baseline, non-interlaced.
  Progressive JPEG is excluded because it defeats partial texture streaming.
- **Normal / ARM / height** — lossless PNG. These carry the lighting, and
  artefacts in them are lighting artefacts.
- **Metadata** — EXIF and ICC stripped from every output.
- **Mipmaps** — generated by Godot at import, from `project.godot`'s
  `[importer_defaults]`. Not baked into the source files.
- **Import compression** — `compress/mode: 2` (VRAM/S3TC-BPTC),
  `mipmaps/generate: true`, `detect_3d/compress_to: 1`,
  `process/size_limit: 0`.

Measured output for the largest hero set (`aerial_grass_rock`, 4K source):
albedo 512 / 1024 / 2048 = 104 KB / 451 KB / 1.71 MB; ARM 512 / 1024 =
466 KB / 1.91 MB; normal 512 / 1024 = 532 KB / 2.10 MB; height 1024 = 8 KB.
The height map is small because it is derived from the normal map's own
gradient and is mostly flat, which is the point: it is a displacement hint,
not a second albedo.

Across all 26 texture sets: **179 runtime files, 123 MB**, against 201 MB of
raw downloads.

## Textures (26 sets)

`Role` is `surface` (bound as a block's albedo) or `detail` (bound as a detail
overlay). `Rungs` are the resolution ladder actually written.

| Set | Provider | Source | Rungs | Role | Used by |
| --- | --- | --- | --- | --- | --- |
| `aerial_grass_rock` | Poly Haven | 4K | 2048, 1024, 512 | surface | grass; leaves detail |
| `forest_leaves_02` | Poly Haven | 4K | 2048, 1024, 512 | surface | leaves |
| `bark_brown_02` | Poly Haven | 4K | 2048, 1024, 512 | surface | wood, cactus; planks detail |
| `oak_wood_planks` | Poly Haven | 2K | 2048, 1024, 512 | surface | planks |
| `cobblestone_04` | Poly Haven | 2K | 2048, 1024, 512 | surface | cobblestone; asphalt detail |
| `brick_wall_003` | Poly Haven | 2K | 2048, 1024, 512 | surface | brick |
| `concrete_floor_02` | Poly Haven | 2K | 2048, 1024, 512 | surface | concrete; brick detail |
| `asphalt_01` | Poly Haven | 2K | 2048, 1024, 512 | surface | asphalt |
| `corrugated_iron` | Poly Haven | 2K | 2048, 1024, 512 | surface | metal plate |
| `brown_mud_leaves_01` | Poly Haven | 1K | 1024, 512 | surface | dirt |
| `rock_06` | Poly Haven | 1K | 1024, 512 | surface | stone, bedrock; deepslate + ore detail |
| `rock_face_04` | Poly Haven | 1K | 1024, 512 | surface | deepslate family |
| `aerial_rocks_02` | Poly Haven | 1K | 1024, 512 | surface | gravel; dirt + sand detail |
| `sand_01` | Poly Haven | 1K | 1024, 512 | surface | sand |
| `snow_02` | Poly Haven | 1K | 1024, 512 | surface | snow; ice detail |
| `coast_sand_rocks_02` | Poly Haven | 1K | 1024, 512 | surface | ice; snow detail |
| `forrest_ground_01` | Poly Haven | 1K | 1024, 512 | detail | grass + cactus detail |
| `acg_metal_057a` | ambientCG | 1K | 1024, 512 | surface | copper block |
| `acg_metal_055a` | ambientCG | 1K | 1024, 512 | surface | iron block |
| `acg_metal_032` | ambientCG | 1K | 1024, 512 | surface | steel block |
| `acg_metal_048a` | ambientCG | 1K | 1024, 512 | surface | brass block |
| `acg_metal_063` | ambientCG | 1K | 1024, 512 | detail | metal plate detail |
| `ore_copper` | derived | — | 1024, 512 | surface | copper ore |
| `ore_iron` | derived | — | 1024, 512 | surface | iron ore |
| `ore_silver` | derived | — | 1024, 512 | surface | silver ore |
| `ore_coal` | derived | — | 1024, 512 | surface | coal ore |

Full per-asset provenance — source page, author, acquisition date, download
URL, md5/sha256 — is in `assets/source_manifest/manifest.json`.

### Authors and licences

- **Poly Haven** — <https://polyhaven.com> — CC0 1.0 Universal.
- **ambientCG** — <https://ambientcg.com> — CC0 1.0 Universal.
- **KayKit** (via `addons/kaykit_character_pack_*`) — <https://kaylousberg.itch.io/kaykit-adventurers> — CC0 1.0 Universal.

## Derived textures (4 sets)

The ores are the only textures with no upstream asset. Each is composed by
`process_textures.py` (`ore_mix_v1`) from two CC0 sources already in the table
above, so they carry CC0 by derivation rather than by download:

| Set | Host rock | Metal blended in | Reads as |
| --- | --- | --- | --- |
| `ore_copper` | `rock_06` | `acg_metal_057a` | copper vein |
| `ore_iron` | `rock_06` | `acg_metal_055a` | iron vein |
| `ore_silver` | `rock_06` | `acg_metal_032` | silver vein, brighter inclusion threshold so it reads as rarer than copper |
| `ore_coal` | `rock_06` | *(none — value crushed)* | coal seam; coal is not a metal, so nothing metallic is blended in |

The method: host-rock albedo composited with the metal's albedo through a
deterministic value-noise inclusion mask, so the result is byte-reproducible;
ARM rebuilt with the metal's roughness and metalness inside the mask; the host
normal map reused unchanged, since ore inclusions are sub-voxel.

## Models (17 props)

All Poly Haven 1K glTF bundles (container + `.bin` + external textures), all
CC0. Every one is static, so every one gets a three-tier LOD chain.

| Prop | LOD0 tris | LOD1 | LOD2 | LOD2 vs LOD0 |
| --- | ---: | ---: | ---: | ---: |
| `Barrel_01` | 2,682 | 1,187 | 160 | 6.0% |
| `wooden_barrels_01` | 19,422 | 7,626 | 952 | 4.9% |
| `wine_barrel_01` | 10,820 | 4,694 | 676 | 6.2% |
| `wooden_crate_01` | 6,576 | 2,890 | 348 | 5.3% |
| `wooden_crate_02` | 5,176 | 2,258 | 337 | 6.5% |
| `old_military_crate` | 10,476 | 4,635 | 653 | 6.2% |
| `metal_tool_chest` | 13,360 | 5,911 | 738 | 5.5% |
| `treasure_chest` | 19,341 | 8,695 | 1,205 | 6.2% |
| `street_lamp_01` | 14,123 | 6,140 | 899 | 6.4% |
| `Lantern_01` | 19,662 | 8,840 | 1,194 | 6.1% |
| `wooden_lantern_01` | 8,321 | 3,463 | 351 | 4.2% |
| `painted_wooden_bench` | 630 | 212 | 10 | 1.6% |
| `painted_wooden_stool` | 676 | 302 | 28 | 4.1% |
| `chinese_stool` | 1,090 | 392 | 24 | 2.2% |
| `ceramic_pot` | 3,592 | 1,580 | 214 | 6.0% |
| `planter_pot_clay` | 3,080 | 1,322 | 160 | 5.2% |
| `potted_plant_01` | 19,765 | 8,844 | 1,053 | 5.3% |
| **Total** | **158,792** | | | |

Every chain is strictly decreasing, and no LOD2 is more than 6.5% of its
LOD0. `asset_test.gd` asserts both properties per prop, so a regression here
fails the suite rather than quietly shipping.

LOD selection is Godot's own `visibility_range` per `MeshInstance3D` — 14 m to
LOD1, 34 m to LOD2 — not a per-frame script, so it costs nothing while the
player stands still.

Each tier is cut from the tier above it against its own triangle budget
(`LOD_TARGETS`, 45% then 15%), not from the source. The bisection in
`decimate_to_budget` searches for the finest uniform cluster grid that still
fits the budget, so a tier lands as detailed as its budget allows instead of
wherever a fixed heuristic put it. Budget: `MAX_TRIS = 20000`. Five props
arrived over it and were reduced at LOD0: `potted_plant_01` 176,226 → 19,765;
`treasure_chest` 103,330 → 19,341; `Lantern_01` 33,902 → 19,662;
`wooden_barrels_01` 33,142 → 19,422; `street_lamp_01` 30,610 → 14,123.

Scale: `Lantern_01` shipped at 0.294 m tall — a lantern shorter than a
player's knee. `make_lods.py` bakes a ×1.7017 scale into the geometry to bring
it to 0.50 m, which is a real-world lantern height. `BAKE_HEIGHT` in
`asset_catalog.py` is the only place that scale is expressed.

`make_lods.py` validates each glTF before decimating and records the verdict
per model in the manifest. All 17 currently pass. It checks for non-finite
vertex positions, degenerate triangles, missing `TEXCOORD_0` and missing
`NORMAL`, embedded-vs-external texture references, footprint and triangle
gates.

## HDRIs (9)

All Poly Haven 1K `.hdr`, CC0, used as `PanoramaSkyMaterial` backgrounds by
`scripts/world/day_night.gd`. The clock picks one panorama for the day and one
after dusk, with sunset panoramas for the horizon hours.

| Set | Slot |
| --- | --- |
| `quarry_01_puresky` | day |
| `kloofendal_48d_partly_cloudy_puresky` | day |
| `autumn_field_puresky` | day |
| `farm_field_puresky` | day |
| `belfast_sunset_puresky` | dusk |
| `venice_sunset` | dusk |
| `dikhololo_night` | night |
| `moonless_golf` | night |
| `clarens_night_01` | night |

## Characters (5)

KayKit, CC0, vendored under `addons/kaykit_character_pack_*`:
`kaykit_knight`, `kaykit_mage`, `kaykit_barbarian` (villagers) and
`kaykit_skeleton_warrior`, `kaykit_skeleton_minion` (mobs).

**These deliberately have no LODs.** They are skinned and animated, and vertex
cluster decimation on a skinned mesh collapses the bones' influence weights
into something that deforms wrongly. The art direction accepts the cost rather
than shipping broken animation — see the "Rejected" section of
`assets/ART_DIRECTION.md`.

## Procedural (1)

`glass` is not a texture. It is a `StandardMaterial3D` in
`MaterialLibrary.PROCEDURAL`: alpha 0.26, roughness 0.06, metallic 0.0,
`CULL_DISABLED`. Glass is mostly the sky seen through it, so a downloaded glass
texture would be a fourth resident texture for a block whose appearance is
decided by what is behind it.

## Rejected

Recorded in full, with reasons, in `assets/rejected/`. Summary:

| Rejected | Why |
| --- | --- |
| Parallax occlusion by default | Costs a ray march per fragment on faces that are flat by construction — a block face has no relief to reveal. Now ULTRA-only. |
| 4K runtime textures | The game is played at 1–3 m from a one-metre block face; a 2048 albedo is already past the point where texels are resolvable. Capped at 2048, and only for sets whose source supports it. |
| LODs on skinned characters | Decimation breaks skin weights. Accepted frame cost instead. |
| `forrest_ground_01` as the grass albedo | A flat top-down photograph with visible mowing stripes. Demoted to a detail overlay and replaced by `aerial_grass_rock`. |
| Higher-poly potted plants | `potted_plant_01` at 176,226 triangles was the single most expensive prop in the set; decimated to budget instead. |
| AI-generated and non-CC0 sources | Out of scope by policy. Nothing ripped from a commercial game, nothing model-generated. |