# NOWS -- Neural Operator Warm Starts (experimental)

An acceleration layer that lets a learned model predict the converged state of
an iterative numerical solve, so the solver can start closer to the answer.

```
world / simulation
    -> numerical field system
    -> NOWS adapter            (nows_field.*)
    -> neural warm start       (nows_fno.*, inference only)
    -> existing iterative solver, now with an initial guess
    -> converged authoritative solution
    -> world state
```

The solver always runs and always owns the result. The network only proposes
where to start.

## Provenance, kept separate on purpose

| Kind | What it is |
| --- | --- |
| Research-derived | The technique. Warm-starting an iterative solve with a learned prediction of its fixed point; the predictor is a Fourier Neural Operator (the canonical neural operator, and the one the NOWS line of work uses). The paper's claims about CFD speed-ups are **not** claims about this engine. |
| Luanti implementation | Everything in this directory: a native C++ forward pass, a portable weight file, the field adapter, the validation envelope, the statistics, and the single hook in the liquid solver. |
| Measured | Only the counters in `nows::Stats` and the Prometheus metrics, plus the inference-cost table below. Nothing in this tree claims a speed-up: there is no trained model, so there is nothing that could demonstrate one. The measurement harness is in place and its output is the artefact that would settle it. |

No Python, no research framework, no autograd and no third-party inference
runtime are linked into the game. The inference pass is a few hundred lines of
C++ over `float` arrays.

## Components

| NOWS concept | C++ symbol | File | Role |
| --- | --- | --- | --- |
| NOWSManager | `nows::Manager` | `nows_manager.*` | Singleton configured from settings. Asks for a warm start, loads the model lazily, counts everything, logs on demand. Single writer: the simulation thread owns it. |
| NOWSModel | `nows::Model` | `nows_model.*` | Backend interface plus the portable `.nowsm` reader/writer. Unknown architectures are refused, not guessed at. |
| NOWSFieldAdapter | `nows::gatherField()`, `nows::projectWarmStart()` | `nows_field.*` | Converts a region of a numerical field into the tensor the model expects, and converts the answer back into an initial-guess field. |
| NOWSWarmStart | `nows::WarmStart` | `nows_types.h` | The suggestion itself: per-cell initial levels, `-1` meaning "no guess". |
| NOWSValidation | `nows::validation::*` | `nows_validation.*` | Pure checks: dimensions, finite values, ranges, residual, exact mass conservation. |
| NOWSStatistics | `nows::Stats` | `nows_types.h`, `nows_manager.*` | Counters, mirrored into the engine's metrics backend. |

The engine's convention is a namespace plus a plain class name (`voxalgo::*`,
`ItemGroup`, `MapSettingsManager`), so the symbols carry the `nows::` prefix
rather than a `NOWS` one.

The adapter is written against reusable numerical fields (a cube of cells with
a fixed channel layout), not against a gameplay object, so the next learned
accelerator -- IRNO, DualNMG, a local neural operator -- plugs in by supplying
its own gather/project pair and its own backend behind `NOWSModel`.

## First integration: the liquid solver

`ServerMap::transformLiquidsLocal()` in `src/servermap.cpp` is Luanti's
iterative relaxation of liquid levels over the voxel grid. It is the engine's
only real iterative numerical field solve, so it is what NOWS accelerates.

The hook is one block inside the loop: the warm start replaces the level a
node *starts* from. Nothing else is touched -- the neighbour scan, the
viscosity rule, the writes, the rollback records, the `on_flood` hooks, the
block updates and the network events all still run exactly as before, and the
node's own bitfield is still what the "did anything change" test compares
against. A wrong guess therefore cannot be written through verbatim: the next
pass recomputes the level from the neighbours.

That is safe as an *initial* guess because the relaxation's fixed point does
not depend on where it starts: at equilibrium every node's level equals the
maximum its neighbours can supply, which is a function of the neighbours
alone. A prediction can change how many passes the transient takes, not where
the field settles. On top of that, the adapter only balances a prediction back
to the region's current total liquid, so it cannot create or destroy water.

## Safety envelope

A prediction has to pass all of this before it reaches the solver:

* the grid is the cube the model was built for, with the declared channels;
* every value is finite (no NaN, no Inf);
* levels lie in `[0,1]` before they are turned into a 3-bit level;
* the RMS deviation from the current field is within `nows_max_residual`;
* the region is fully loaded and inside the map's coordinate range;
* the prediction can be balanced to the region's current mass exactly.

Anything else, plus "no model", "untrained model", "inference over budget" and
"solver did not converge", means the prediction is discarded and the solver
runs its normal path. After a rejection or a non-converged solve the manager
cools down for `nows_cooldown` solves.

With `nows_enabled` off -- the default -- every one of these paths is never
reached: `transformLiquids()` makes exactly the call it always made.

## Settings

Flat snake_case, like the rest of the engine; the dotted spelling from the
specification is accepted as an alias.

| Setting | Default | Meaning |
| --- | --- | --- |
| `nows_enabled` | `false` | Master switch. |
| `nows_model_path` | `""` | Path to a `.nowsm` model. |
| `nows_allow_untrained` | `false` | Permit loading a development placeholder. |
| `nows_fallback` | `true` | Fall back to the normal solver on any problem. |
| `nows_validation` | `true` | Run the structural checks. |
| `nows_max_residual` | `0.35` | Largest RMS deviation from the current field. |
| `nows_grid_size` | `16` | Cube edge handed to the model (power of two, 8..32). |
| `nows_max_region_nodes` | `512` | Upper bound on cells one warm start may touch. |
| `nows_min_queue` | `24` | Below this much queued work, skip. |
| `nows_max_inference_us` | `2000` | Inference slower than this is treated as not worth it. |
| `nows_adaptive` | `true` | Refuse to predict while measurement says prediction does not pay for itself. |
| `nows_min_samples` | `8` | Solves of each kind needed before the adaptive gate is allowed to judge. |
| `nows_cooldown` | `8` | Solves to skip after a rejection. |
| `nows_debug` | `false` | Log the decision per solve and a summary every 64. |

Diagnostics also go to the engine's metrics backend as
`nows_warm_starts_total`, `nows_fallbacks_total`,
`nows_inference_microseconds_total` and `nows_solver_microseconds_total`.

## The profitability gate

A prediction is not free. The arithmetic that decides whether NOWS is worth
anything is:

```
  normal solve                 = N iterations x C us/iteration
  warm-started solve           = W iterations x C us/iteration  + inference
  saving                       = (N - W) x C
  worth it only while          (N - W) x C  >  inference
```

With 20,000 us normal and a 1,000 us inference over a 5,000 us solve that is a
real ~3.3x. With the same 1,000 us inference and only 500 us of savings, NOWS
makes the frame slower. The second case is not a bug to be tuned away -- it is
the correct answer to a predictor that is not good enough, and the layer is
built to notice it by itself.

So the manager measures rather than assumes. `recordSolve()` is told the
iteration count, the solver time and the residual of *every* solve, warm
started or not, and keeps exponential averages (alpha 0.2) of the plain
iteration count, the warm-started iteration count, the measured cost of one
plain iteration and the measured inference time. Once at least
`nows_min_samples` of each kind have been seen, and

```
  expectedSavingUs() = (baseline_iters - nows_iters) * baseline_us_per_iter
```

is not greater than the measured inference cost, `predictWarmStart()` returns
false with `Status::Unprofitable`, counts the skip in
`Stats::unprofitable_skips`, and the plain solver runs. The averages are
exponential rather than cumulative on purpose: a world that stops producing
liquid work must stop judging NOWS on stale evidence.

Three properties matter:

* **It cannot trigger on noise.** The gate is inert until
  `nows_min_samples` samples of both kinds exist, so it cannot disable the
  layer during the first few frames of a server.
* **It is symmetric with reality.** If the model gets genuinely good, the
  saving term grows and the gate reopens. It is a measurement window, not a
  one-way switch.
* **It is not the only guard.** `nows_max_inference_us` still rejects a
  single pathological forward pass before the averages mean anything.

`nows_adaptive = false` turns the gate off, which is what you want while
*collecting* the numbers rather than acting on them. `Manager::profitability()`
returns the raw averages for tests and for the A/B harness, and `statsString()`
prints them alongside a plain statement when NOWS is currently a net cost.

The residual is collected for the same reason: it is the honest measure of how
far from the fixed point a solve stopped, and comparing the plain residual
against the warm-started one is what tells you whether a saved iteration was a
saved iteration or just a different amount of unfinished work.

## Weight file format (`.nowsm`)

Little endian, raw IEEE-754 floats, so a file written by any training stack
loads anywhere without depending on the host byte order.

```
"NOWSMDL\0"            8 bytes, magic
u32                    format version (1)
u32                    header length
char[header_length]    ASCII "key=value\n" lines
u32                    tensor count
  per tensor:
    u32                name length
    char[name_length]  tensor name
    u32                element count
    f32[element_count] values
```

Header keys: `arch`, `name`, `note`, `trained`, `grid`, `channels`, `modes`,
`layers`, `in_channels`, `out_channels`.

`arch = fno3d` tensors, for `channels` C, `modes` M, `layers` L, input
channels Cin and output channels Cout:

| Tensor | Shape |
| --- | --- |
| `lift_w`, `lift_b` | `[C][Cin]`, `[C]` |
| `l{i}_spec_re`, `l{i}_spec_im` | `[M*M*M][C][C]` (separate real/imaginary parts) |
| `l{i}_pw_w`, `l{i}_pw_b` | `[C][C]`, `[C]` |
| `proj_w`, `proj_b` | `[Cout][C]`, `[Cout]` |

The forward pass is: lift, then per layer `v = gelu(v + pointwise(v) +
spectral(v))`, then project. `grid` must be a power of two in `[8,32]`.

`trained=0` is refused unless `nows_allow_untrained` is set, so a placeholder
can never silently become the default path.

## Getting a real model

1. Train an FNO warm-start network offline against liquid fields produced by
   the engine itself (dump the field, run the solver to its fixed point, use
   that as the label). No framework from that work belongs in the game.
2. Export the weights in the layout above with `trained=1`.
3. Drop the file somewhere the server can read, set `nows_model_path`, and set
   `nows_enabled`.

`util/nows_make_dev_model.py` writes a structurally valid file with
deterministic placeholder weights. It exists to exercise the plumbing and is
**not** a prediction of anything.

## Running the A/B experiment

The question this layer exists to answer is one number: does the saving beat
the inference cost. `testABTable` in `src/unittest/test_nows.cpp` answers it
directly. It builds one fixture -- a real `ServerMap` and `ServerEnvironment`
-- and runs the same set of physical problems three ways:

```
A  plain solver                        -> NORMAL
B  warm started from the field the plain solver itself converged to
                                        -> NOWS (oracle)
C  warm started from a real .nowsm model -> NOWS (model)
```

B is an **oracle**, and is labelled as one: it is the converged answer handed
back as the initial guess, so it saves the maximum any predictor could ever
save. It is a bound, not a result. If B does not beat A, no predictor can, and
the experiment is over before a model is trained. If B does beat A, the gap
between B and C is what the model still has to learn.

C is what actually answers the question. It runs the real manager, so
inference time, the validation envelope, the fallback paths and the
profitability gate are all in the numbers rather than around them. The
harness deliberately sets `nows_adaptive = false` for the duration -- measure
first, judge afterwards -- and prints, per problem and in total:

```
                    NORMAL        NOWS(oracle)   NOWS(model)
  solver iterations      ?               ?             ?
  inference              -               -             ?
  solver time            ?               ?             ?
  total time             ?               ?             ?
  residual               ?               ?             ?
  solution error         -               ?             ?
  fallbacks              -               -             ?
```

plus the line that actually decides it: the saving against the inference cost,
and the resulting net microseconds per problem. `solution error` is the number
of cells where the warm-started run's converged state differs from run A's --
it must be zero, and the harness asserts it.

Run it with:

```sh
LUANTI_NOWS_MODEL=/path/to/model.nowsm ./bin/luanti --run-unittests
```

Without `LUANTI_NOWS_MODEL` the third column stays empty rather than quietly
substituting the oracle for a network. That is the intended behaviour: until a
model is trained, the only honest reading of this table is the A/B comparison
and the bound in column B, and any speed-up claim built on it would be a claim
about a predictor that does not exist.

### Measured inference cost (placeholder model, this machine, CPU only)

`g++ -O2`, single thread, average over 50 forward passes. These are costs, not
speed-ups -- and they say nothing about a trained model, whose architecture is
whatever was chosen during training:

| grid | channels | modes | layers | us per inference |
| --- | --- | --- | --- | --- |
| 8 | 4 | 2 | 1 | 167 |
| 16 | 4 | 2 | 1 | 1400 |
| 16 | 4 | 2 | 2 | 2806 |
| 16 | 8 | 2 | 1 | 2547 |
| 16 | 4 | 4 | 2 | 2912 |
| 32 | 4 | 4 | 2 | 38290 |

The cost is dominated by the per-channel 3D FFT, so it grows with
`grid^3 * channels * layers`. The generator's defaults are sized to sit inside
`nows_max_inference_us` (2000 us) on a modest CPU; anything slower is rejected
by the budget guard and the plain solver runs, which is exactly what happened
to the 5245 us variant of this model during development.

## Tests

`src/unittest/test_nows.cpp` covers the failure paths -- malformed, truncated,
missing and untrained models, wrong grids and channel counts, NaN/Inf and
out-of-range predictions, unbalanceable mass, missing model, the disabled
path, config aliases and clamping -- plus FFT round-trip, determinism and
`NOWSManager` statistics.

Three tests exercise the engine rather than the layer in isolation:

* `testLiquidSolverIntegration` runs the real liquid solver plain and warm
  started from its own converged field and asserts both end in the *same world
  state*, then asserts the iteration cap is honoured, that a non-zero residual
  is reported when it trips, and that a wild out-of-range guess cannot invent
  water. That first assertion is the guarantee that matters most.
* `testProfitabilityGate` drives the manager with synthetic baselines and
  warm-started solves and asserts that a well-separated prediction is allowed
  while one that saves less than it costs is refused with
  `Status::Unprofitable` -- including that the gate stays inert until
  `nows_min_samples` samples of both kinds exist.
* `testABTable` is the experiment described above.