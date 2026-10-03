# `--render-test` — automated GPU visual validation

Renders the real game from fixed camera positions at a fixed resolution,
captures the real framebuffer, and records enough about the machine and the
run to tell you whether the result means anything.

> **An LLVMpipe / software-rasteriser result is not a valid hardware-GPU
> visual validation.** The pipeline detects it and fails. It does not produce
> a misleading screenshot.

## What it is, and what it is not

It is a **mode**, not a second renderer. The whole `main.tscn` scene is
assembled exactly as it is for play; the differences are that the world is
seeded from a fixed constant and that a `RenderTest` node is handed the
finished scene to drive. The same `VoxelWorld`, the same greedy mesher, the
same `MaterialLibrary` and shaders, the same `RenderSettings` environment,
the same lighting and the same post-processing run for both.

There is deliberately no "just for the screenshot" code path. A benchmark
that renders through anything other than the shipping renderer measures the
benchmark rather than the game, and would keep passing while the game broke.

## Running it

```sh
godot --path godot_client -- --render-test
```

or, against a standalone build:

```sh
./luantivoxel.x86_64 --resolution 1920x1080 -- \
    --render-test --all-cameras --output render-test-results
```

### Options

| Option | Default | Meaning |
|---|---|---|
| `--render-test` | — | Enter render-test mode. Without it nothing changes. |
| `--scene <name>` | `benchmark` | Which scene to load. |
| `--resolution <W>x<H>` | `1920x1080` | Real framebuffer size. |
| `--frames <N>` | `120` | Frames rendered per camera before capture. |
| `--warmup-frames <N>` | `30` | Frames rendered and discarded first. |
| `--output <dir>` | `render-test-results` | Where results are written. |
| `--camera <preset>` | `front` | One of `front`, `side`, `elevated`, `environment`. |
| `--all-cameras` | off | Shoot every preset. |
| `--no-ui` | off | Hide the HUD; developer diagnostics are always hidden. |
| `--capture-every <N>` | `0` | Also capture periodically, not just the final frame. |
| `--effects <preset>` | `baseline` | `baseline` or `game`. **See below.** |
| `--allow-software` | off | Permit a software render. **See below.** |
| `--no-gpu-validation` | off | Skip the hardware check. **See below.** |

Unknown options are a **usage error**, not a shrug. A typo in a flag name
would otherwise silently produce a run with the wrong settings.

`--allow-software` and `--no-gpu-validation` exist so the pipeline itself
can be exercised on a machine with no GPU. They are named for what they do,
they are documented, and output produced with them still records
`"hardware_acceleration": false` and `classification: software` in every
artefact. They are not a way to obtain a passing result.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 2 | Usage error (bad or unknown option) |
| 3 | `GPU_NOT_FOUND` — no adapter could be identified as hardware |
| 4 | `SOFTWARE_RENDERING_DETECTED` |
| 5 | `RENDERER_INITIALIZATION_FAILURE` |
| 6 | `SCREENSHOT_CAPTURE_FAILURE` |
| 7 | `MISSING_SCENE` — no camera preset matched |
| 8 | Capture written, but its **contents** are unusable |

A failure always writes `FAILURE.txt` next to whatever else it managed to
produce, so a refused run explains itself even though it captured nothing.

## Two verdicts, not one

A run answers two separate questions, and reports them separately:

- **Is this machine rendering on a GPU?** (`gpu-info.txt`, `HARDWARE GPU:`)
- **Do the frames actually show the world?** (`capture-content.txt`,
  `CAPTURE CONTENT:`)

Collapsing these into a single `PASS` is how a corrupt render gets reported
as a success. A T4 run produced four PNGs at exactly 1920x1080 on real
hardware, every one of them a bright near-uniform haze, and the original
validator said PASS — because it only checked that a file existed at the
right size.

## Judging the pixels

Every final capture is measured from the real framebuffer before it is
written: distinct colours (quantised to 5 bits per channel), mean and
standard deviation of Rec.601 luma, the dominant colour's share, and the
fraction of near-black and near-white pixels. A frame is rejected when it
is a flat fill, has no luma variance, is one colour, or is bright *and*
low-contrast (fog or bloom over geometry that is not there).

Both conditions in that last check are required on purpose. A high mean on
its own is a legitimate snowfield or an overexposed sky; a high mean with
no contrast is a bug.

The thresholds are in **0..1 luma units**, and the notebook's Python check
normalises PIL's 0..255 channel values before comparing. That normalisation
was itself a bug: without it `mean > 0.82` was true of every frame and the
washed-out check could never fire. Notebook cell 7 now runs the check
against a deliberately broken frame and fails if that frame is accepted, so
the validator cannot silently degrade into a no-op.

## Effect presets: diagnose in `baseline`, judge in `game`

The shipping tier runs parallax occlusion, the stochastic triplanar shader,
SSIL, volumetric fog and glow. When geometry is wrong, every one of those
amplifies it: POM ray-marches through surfaces that should not be there,
fog fills every hole in the world, and the result is a picture where the
actual fault cannot be seen.

- **`baseline`** (default) — plain box UVs, LOW quality. POM, stochastic
  mapping, SSIL, volumetric fog and the SDFGI cascades are off. This is the
  capture you diagnose in.
- **`game`** — the shipping look, HIGH quality, stochastic mapping. This is
  the capture you judge the game by.

A fault visible in **both** is a mesh problem. A fault visible only in
`game` is a post-processing problem. The Colab notebook runs both and
suffixes the game-preset files with `_game`, so the two are never confused.

## Camera and environment volumes stay together

In normal play the fog volume and the reflection-probe ring are re-anchored
on the player every frame. The benchmark camera is somewhere the player
never goes, so left alone they would sit behind it and the captures would
be shot through fog that has no business being there. The render test moves
them to its own camera position before each preset, through the same
`_follow_volumes_at` the game uses.

## How hardware GPU detection works

`RenderTest.probe_adapter()` reads the adapter through **`RenderingServer`**,
specifically `get_video_adapter_name()`, `get_video_adapter_vendor()` and
`get_video_adapter_api_version()`.

That source is not arbitrary. `OS.get_video_adapter_driver_info()` returns
an **empty array** on this project even when the adapter is perfectly
queryable, and reading it first meant every run classified as `unknown` and
slipped past a check that would otherwise have caught it. The device string
from `RenderingServer` is what actually names the adapter.

The name and vendor are then matched, case-insensitively, against
`SOFTWARE_MARKERS`:

```
llvmpipe · softpipe · swrast · swiftshader · mesa offscreen
software rasterizer/rasteriser · software renderer
cpu rasterizer/rasteriser · microsoft basic render
```

and, separately, against a list of known hardware vendors/devices. The
result is one of three values:

- `hardware` — passes
- `software` — **fails**, exit 4
- `unknown` — **fails**, exit 3

`unknown` is deliberately a failure. An adapter that cannot be positively
identified as hardware is not evidence of hardware, and treating it as one
is precisely how a machine with no GPU ends up reporting a pass.

`classify_adapter()` is a pure static function, and `render_test_test`
feeds it the real strings Mesa, SwiftShader and the common virtual drivers
emit, plus empty and unrecognised ones. A validator that has never rejected
anything is indistinguishable from one that always passes, so the negative
cases are the ones that matter.

## Virtual display is not GPU acceleration

These are three different things and the pipeline keeps them apart:

| | What it is | Does it prove GPU? |
|---|---|---|
| **Xvfb** | a virtual X display | **No.** It is just a framebuffer to draw into. |
| **llvmpipe** | Mesa's CPU rasteriser | **No.** Every pixel is drawn by the CPU. |
| **NVIDIA / AMD / Intel driver** | a hardware driver | **Yes.** |

Running under Xvfb proves nothing on its own, and the render test never
treats it as proof. The adapter string is what decides. This is why the
software-rendering capture in `RENDER-CHECK.md` is filed as evidence that
*rendering works*, and explicitly not as evidence of visual quality.

## Determinism

The world, the village and the mob spawner are all seeded from
`RenderTest.SEED = 173927`, which is written into `metadata.json`. Two runs
on two machines produce the same terrain, so captures are directly
comparable and a visual difference means a renderer change rather than a
different world.

The four camera presets are expressed as offsets from a point found by
scanning the generated terrain, not as absolute coordinates. A preset framed
on a hard-coded coordinate would point at sky on any seed but one, and
produce a screenshot of nothing.

## Output

```
render-test-results/
├── captures/
│   ├── front.png          1920x1080, real framebuffer
│   ├── side.png
│   ├── elevated.png
│   └── environment.png
├── metadata.json          resolution, seed, scene, adapter, classification
├── performance.json       frame times, fps, resolution
├── performance.txt        the same, human-readable
├── gpu-info.txt           HARDWARE GPU: PASS|FAIL, plus the adapter detail
├── capture-content.txt    CAPTURE CONTENT: PASS|FAIL, plus the measurements
├── render-log.txt         what the run did, in order
└── FAILURE.txt            only when the run was refused
```

`performance.json` reports `gpu_frame_ms: null`. Godot exposes no GPU-side
timer without vendor timestamp queries, which are not enabled here, and
"unavailable" is the honest value — a number copied from the CPU time would
be a fabrication. CPU-side frame times are real and are labelled as CPU-side.

## Google Colab

`tools/LUANTIVOXEL_GPU_RENDER_TEST.ipynb`. Open it, choose
**Runtime → Run all**, and it will: report the environment, clone the repo,
install Godot and its export templates, build, verify the GPU, render,
validate the captures, package a ZIP and display the screenshots inline.

The C++ engine in `src/` is not compiled — the game is the Godot client, and
building a C++ engine nobody runs would add minutes to every run.

**Cell 5 is a hard gate.** If the adapter is not positively hardware, the
notebook raises and stops with:

```
Hardware GPU rendering was not detected. Refusing to produce a
misleading final visual-validation result.
```

Colab GPU availability varies, and "GPU" in the runtime picker does not
always mean a GPU is attached. That is a property of the environment, not of
this pipeline.

## Limitations

- **A real GPU run found a real bug, and the winding fix has been verified
  only on llvmpipe.** The greedy mesher emitted the −X, −Y and −Z faces
  inside out, so 6 of 12 triangles on an isolated block were back-face
  culled. `mesher_test.gd` now asserts that every triangle's geometric
  normal agrees with its stored normal, and that all six directions survive
  culling — the earlier tests counted triangles, and a culled triangle is
  still a triangle, so nothing caught it. The fix changes ~390k pixels in a
  single 1920x1080 capture locally. Whether it is fully correct on a GPU
  driver is what the next Colab run will show.
- **The content validator does not catch every broken frame.** It rejects
  flat, featureless and washed-out captures. A frame showing correct-looking
  but *wrong* geometry — plausible shading on an incomplete mesh — passes.
  It is a floor, not a substitute for looking at the pictures.
- The development environment has no GPU, so the hardware path is verified
  by unit-testing the classifier against real device strings and by
  verifying that the software path *fails*, not by a successful hardware
  run.
- The framebuffer is captured from the root viewport, so a capture needs a
  display server (Xvfb is enough). There is no pure-offscreen path today.
- SDFGI does not run in this project (it needs an editor-authored
  `SDFGIProbeVolume3D`), so the captures show ambient occlusion but no
  global illumination.
- Performance numbers are CPU-side only, as above.
