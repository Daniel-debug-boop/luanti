# Third-party shaders

Both addons here are vendored verbatim from their upstream projects, with
their licences included alongside them. Nothing in either addon was modified.

---

## `terrain-shader/` — Triplanar terrain shader

* Upstream: <https://github.com/acegiak/Godot4TerrainShader>
* Licence: Apache License 2.0 (see `terrain-shader/LICENSE`)
* Files: `Terrain.gdshader`, `Triplanar.gdshader`, `TriplanarSplit.gdshader`,
  `StochasticTexture.gdshader`

Upstream's description: "Split texture, stochastic sampled, triplanar texture
shader for Godot4", itself based on /u/Rotoscope's stochastic sampling shader
for Unity and John Watson's split triplanar terrain shader for Godot 3.

This is the stochastic-sampling half of the surface work: Godot's built-in
triplanar projection fixes stretching but does nothing about the visible
repeating grid pattern, because the same texture lands at the same offset on
every block. Stochastic sampling jitters each block's sample position, which is
what breaks the repeat. `Terrain.gdshader` additionally splits the texture by
slope, so a cliff face and a flat top take different textures.

Note that upstream targets a heightmap terrain and expects a `ShaderMaterial`
with `top_tex` / `wall_tex` uniforms set per material. It is a hand-authored
shader, so it bypasses `StandardMaterial3D` entirely: the per-block albedo,
normal, and ARM maps configured in `scripts/world/material_library.gd` do not
apply to it. Select it with `MaterialLibrary.Mapping.SHADER_TRIPLANAR`.

---

## `voxel/` — GPU DDA voxel renderer

* Upstream: <https://github.com/viktor-ferenczi/godot-voxel>
* Licence: MIT, Copyright (c) 2023 Viktor Ferenczi (see `voxel/LICENSE`)
* Files: `Shaders/Opaque.gdshader`, `Shaders/Transparent.gdshader`,
  `Shaders/Shadow.gdshader`, `Shaders/DDA.gdshaderinc`,
  `Shaders/Config.gdshaderinc`, `Shaders/TexturedSampler.gdshaderinc`,
  `Shaders/VoxSampler.gdshaderinc`, `plugin.gd`

Upstream's description: "Voxel rendering for Godot 4.3+ (GPU, shader, DDA
algorithm) ... Based on an efficient 2-level DDA algorithm, implemented 100% on
the GPU as a fragment shader."

This is the GPU-raymarching option. It is a fundamentally different rendering
architecture from the one this project uses:

* It renders the entire voxel volume as a **single box mesh** (8 vertices, 12
  faces, front faces culled) and ray-marches inside it in the fragment shader,
  rather than greedy-meshing chunk geometry on the CPU.
* It needs two GPU resources built from the voxel data: a 16x256 `RGB8` cube
  map saying which voxel cubes are non-empty, and a 256x16xN `R8`
  `Texture2DArray` of voxel indices. Upstream's README is explicit that the
  import configuration for that texture array is critical and easy to get
  wrong.
* Because geometry comes from the ray march, it needs the voxel data uploaded
  as textures, not just present as `VoxelBlock` arrays.

Our renderer already greedy-meshes chunks on the CPU into per-block-id
surfaces with baked ambient occlusion, which is a different (and, for a
Luanti world being viewed, a more direct) pipeline. These shaders are vendored
so the alternative is available to switch to; they are not wired into the
default render path.

---

## Not vendored: Zylann's godot_voxel

* Upstream: <https://github.com/Zylann/godot_voxel>

Referenced in the request as a chunking/voxel engine. It is a **C++
GDExtension module**, and its own documentation states the plugin packages
"contain the word GDExtension in the title" and are built for a specific
`4.7` branch of a custom Godot build. It cannot be loaded by the stock Godot
4.4 binary this project targets, and it would replace the voxel renderer
outright rather than providing a shader. Using it means switching this project
to a custom engine build, which is a different decision from the one asked
for here.
