# Render verification

`render-check-llvmpipe-800x600.png` is a frame captured from the exported
standalone build, running on a virtual framebuffer (Xvfb) with Mesa's
**llvmpipe** software rasteriser — there is no GPU in the build environment.

It exists because the project's honest-limitations list said *"nothing has
ever been rendered"*. That was true until this capture. It is the first
frame this project has ever produced.

## What it does and does not prove

It **does** prove the game renders: real geometry, textures, daylight
lighting and the HUD (including the red health hearts) all draw. The frame
carries ~90,000 distinct colours, so it is shaded geometry rather than a
flat fill, and the world visibly streams in across successive frames.

It does **not** prove the game looks good, or that it runs at a playable
frame rate. Nobody has looked at this with human eyes. It is pixel
statistics plus one image, not a playtest.

## Performance, measured

Timing `--quit-after N` measures the first N frames, which are dominated by
a ~6 s startup (world generation, chunk meshing, shader compilation).
Separating startup from steady state at 640x480:

| | steady-state frame | fps |
|---|---|---|
| HIGH tier | 332 ms | 3.0 |
| LOW tier | 284 ms | 3.5 |

Across resolutions, 6.25x the pixels costs only 2.4x the time — a large
resolution-independent cost plus a pixel-proportional one, with roughly 70%
of the frame at 800x600 being fragment shading.

**These numbers say nothing about GPU performance.** llvmpipe executes every
fragment shader on the CPU across a few 256-bit SIMD threads; a GPU runs the
same shader across thousands of ALUs at once. The measured cost is dominated
by exactly the term that GPU parallelism eliminates, so the two are not
comparable and no scaling factor converts one into the other. Notably, SSIL
and volumetric fog cost only 15% of the software frame despite being
raymarching passes — among the most GPU-favourable workloads in graphics.

The only way to get a real frame rate is to run the build on hardware with a
GPU.

## Reproducing

```sh
Xvfb :99 -screen 0 1280x720x24 &
export DISPLAY=:99 LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe
./luantivoxel.x86_64 --rendering-driver opengl3 --resolution 800x600
import -window "$(xdotool search --name LuantiVoxel | head -1)" frame.png
```

Requires `xvfb`, `libgl1-mesa-dri`, `imagemagick` and `xdotool`. Audio falls
back to a dummy driver, which is expected without a sound card.
