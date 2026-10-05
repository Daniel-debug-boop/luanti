// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once

#include "irr_v3d.h"
#include "irrlichttypes.h"

#include <string>
#include <vector>

/*
 * NOWS -- Neural Operator Warm Starts.
 *
 * Research-derived technique: warm-starting an iterative numerical solve with
 * a learned prediction of the converged state (the "v_u" network of the NOWS
 * family, typically a Fourier Neural Operator) instead of a fixed or
 * hand-chosen initial guess.
 *
 * Luanti implementation: this header and the rest of src/nows/ are an
 * engine-native inference path. No Python, no research framework and no
 * external inference runtime is linked into the game. Inference is plain C++
 * over a portable weight file (see nows_model.h and src/nows/README.md).
 *
 * Measured behaviour: see NOWSStats. Nothing in this file claims a speed-up;
 * every number there is counted at runtime by the solver integration in
 * ServerMap::transformLiquids().
 */

namespace nows {

/* Outcome of a warm-start attempt. Anything other than Ok means the caller
 * runs the plain numerical solve with its normal initial state. */
enum class Status
{
	Ok,
	Disabled,          // nows.enabled is false
	NoModel,           // no model path configured or the file is absent
	ModelInvalid,      // model file present but malformed / wrong version
	Untrained,         // model is a development placeholder, not allowed
	Incompatible,      // grid/shape does not match the model
	TooSmallQueue,     // not enough queued work to be worth the overhead
	NoRegion,          // the sampled region holds nothing the model can act on
	PredictionInvalid, // NaN/Inf, out of range or wrong dimensions
	ResidualTooHigh,   // prediction disagrees with the current field too much
	Cooldown,          // temporarily disabled after a recent failure
	BudgetExceeded,    // last inference exceeded the configured time budget
	Unprofitable,      // measured: prediction is not paying for its own cost
};

const char *statusName(Status status);

/* ------------------------------------------------------------------ */
/* Dense real-valued tensor. Cell-major: index = cell * channels + c.  */
/* ------------------------------------------------------------------ */

struct Dims
{
	u32 x = 1, y = 1, z = 1;

	u32 count() const { return x * y * z; }
	bool operator==(const Dims &o) const { return x == o.x && y == o.y && z == o.z; }
	bool operator!=(const Dims &o) const { return !(*this == o); }
	/* Cubes keep the FFT sizes identical in all three axes. */
	bool isCube() const { return x == y && y == z; }
};

struct Field
{
	Dims dims;
	u32 channels = 0;
	std::vector<f32> data;

	bool empty() const { return dims.count() == 0 || channels == 0 || data.empty(); }

	void resize(const Dims &d, u32 c)
	{
		dims = d;
		channels = c;
		data.assign(static_cast<size_t>(dims.count()) * c, 0.0f);
	}

	f32 at(u32 cell, u32 channel) const
	{
		return data[static_cast<size_t>(cell) * channels + channel];
	}

	void set(u32 cell, u32 channel, f32 value)
	{
		data[static_cast<size_t>(cell) * channels + channel] = value;
	}
};

/* ------------------------------------------------------------------ */
/* Input feature layout of the liquid field adapter.                   */
/* ------------------------------------------------------------------ */

enum FeatureChannel : u32
{
	/* Liquid level of the node, normalised to [0,1] over the full level range. */
	FC_LEVEL = 0,
	/* 1 if the node is a liquid source. */
	FC_SOURCE = 1,
	/* 1 if the node is flowing liquid (i.e. the field the solver relaxes). */
	FC_FLOWING = 2,
	/* 1 if the node can be replaced by liquid (floodable). */
	FC_FLOODABLE = 3,
	/* 1 if the node blocks liquid. */
	FC_SOLID = 4,
	/* Number of liquid-source neighbours in the 6-neighbourhood, /6. */
	FC_NEIGHBOUR_SOURCES = 5,
	FC_COUNT = 6,
};

/* ------------------------------------------------------------------ */
/* Configuration. Defaults are deliberately inert: NOWS is off.        */
/* ------------------------------------------------------------------ */

struct Config
{
	bool enabled = false;
	/* Fall back to the plain solver whenever the prediction is unusable.
	 * Turning this off is a debugging aid only; it never makes a bad
	 * prediction authoritative. */
	bool fallback = true;
	/* Run the structural validation checks on every prediction. */
	bool validation = true;
	/* Log per-solve lines (verbose log level required). */
	bool debug = false;
	/* Permit loading a model whose header says trained=0. Development only. */
	bool allow_untrained = false;

	std::string model_path;

	/* Reject a prediction whose RMS level deviation from the current field
	 * exceeds this. 1.0 means "deviating by the full level range". */
	f32 max_residual = 0.35f;

	/* Edge length of the cubic field handed to the model. Must be a power of
	 * two in [8,32]. */
	u32 grid_size = 16;
	/* Upper bound on cells the warm start may touch. */
	u32 max_region_nodes = 512;
	/* Below this many queued nodes the inference cost is not worth it. */
	u32 min_queue = 24;
	/* If a single inference exceeds this many microseconds, NOWS backs off. */
	u32 max_inference_us = 2000;
	/* Number of solver calls to skip after a rejected or non-converged one. */
	u32 cooldown_solves = 8;
	/* Back off when the measured savings do not cover the measured cost.
	 * This is the difference between an accelerator and a tax: an inference
	 * that saves 500 us while costing 1000 us has made the solve slower. */
	bool adaptive = true;
	/* Solver calls of each kind needed before that verdict is trusted. */
	u32 min_samples = 8;
};

/* ------------------------------------------------------------------ */
/* Counters. Cheap: a handful of integer adds on the server thread.   */
/* ------------------------------------------------------------------ */

struct Stats
{
	u64 solves = 0;                  // solver calls that reached the decision point
	u64 nows_applied = 0;            // warm starts actually handed to the solver
	u64 nows_skipped = 0;            // calls where NOWS declined to run
	u64 fallbacks = 0;               // prediction rejected or unusable
	u64 rejections = 0;              // predictions that failed validation
	u64 convergence_failures = 0;    // solver did not reach its fixed point
	u64 inferences = 0;

	u64 baseline_solves = 0;         // calls solved without a warm start
	u64 baseline_iterations = 0;
	u64 nows_solves = 0;
	u64 nows_iterations = 0;

	u64 inference_us = 0;            // total time inside the model
	u64 baseline_solver_us = 0;
	u64 nows_solver_us = 0;
	u64 model_load_failures = 0;
	u64 unprofitable_skips = 0;     // refused because it would cost more than it saves

	/* Work the solver still had queued when it returned. Zero means the field
	 * reached its fixed point; anything else is residual work, not error. */
	u64 baseline_residual = 0;
	u64 nows_residual = 0;

	/* Running economics, the whole point of the layer. These are the numbers
	 * that decide whether NOWS is worth enabling at all. */
	f64 baseline_us_per_iteration() const
	{
		return baseline_iterations ? (f64)baseline_solver_us / (f64)baseline_iterations : 0.0;
	}
	/* Microseconds a warm-started solve saved, per solve, on average. */
	f64 savedUsPerSolve() const
	{
		if (!nows_solves)
			return 0.0;
		return ((f64)baselineIterationsPerSolve() - (f64)nowsIterationsPerSolve()) *
				baseline_us_per_iteration();
	}
	/* Microseconds inference cost per warm-started solve, on average. */
	f64 inferenceUsPerSolve() const
	{
		return nows_solves ? (f64)inference_us / (f64)nows_solves : 0.0;
	}
	/* Positive means the layer is paying for itself on average. */
	f64 netUsPerSolve() const
	{
		return savedUsPerSolve() - inferenceUsPerSolve();
	}

	/* Derived, not stored: average solver iterations per solve. */
	f64 baselineIterationsPerSolve() const
	{
		return baseline_solves ? (f64)baseline_iterations / (f64)baseline_solves : 0.0;
	}
	f64 nowsIterationsPerSolve() const
	{
		return nows_solves ? (f64)nows_iterations / (f64)nows_solves : 0.0;
	}
	f64 inferenceMs() const { return inference_us / 1000.0; }
	f64 baselineSolverMs() const { return baseline_solver_us / 1000.0; }
	f64 nowsSolverMs() const { return nows_solver_us / 1000.0; }
};

/* ------------------------------------------------------------------ */
/* The warm start itself.                                              */
/*                                                                     */
/* This is an INITIAL GUESS only. It carries no authoritative state:   */
/* the solver still decides every node's content and level, still      */
/* writes through the normal path (rollback, on_flood hooks, block      */
/* updates, network events), and still owns the final result. A cell    */
/* entry of -1 means "no guess, use the node's current level".         */
/* ------------------------------------------------------------------ */

struct WarmStart
{
	/* World position of cell (0,0,0). */
	v3s16 origin = v3s16(0, 0, 0);
	u32 dim[3] = {0, 0, 0};
	/* dim.x*dim.y*dim.z entries, -1 for cells with no guess. */
	std::vector<s8> level;

	bool empty() const { return level.empty(); }

	void clear()
	{
		origin = v3s16(0, 0, 0);
		dim[0] = dim[1] = dim[2] = 0;
		level.clear();
	}

	u32 cellCount() const
	{
		return static_cast<u32>(level.size());
	}

	u32 guessCount() const
	{
		u32 n = 0;
		for (s8 v : level) {
			if (v >= 0)
				n++;
		}
		return n;
	}

	bool contains(const v3s16 &p) const
	{
		if (level.empty())
			return false;
		const s32 lx = p.X - origin.X, ly = p.Y - origin.Y, lz = p.Z - origin.Z;
		return lx >= 0 && ly >= 0 && lz >= 0 &&
				static_cast<u32>(lx) < dim[0] && static_cast<u32>(ly) < dim[1] &&
				static_cast<u32>(lz) < dim[2];
	}

	s8 levelAt(const v3s16 &p) const
	{
		if (!contains(p))
			return -1;
		const u32 lx = static_cast<u32>(p.X - origin.X);
		const u32 ly = static_cast<u32>(p.Y - origin.Y);
		const u32 lz = static_cast<u32>(p.Z - origin.Z);
		return level[(lx * dim[1] + ly) * dim[2] + lz];
	}

	void set(const v3s16 &p, s8 v)
	{
		if (!contains(p))
			return;
		const u32 lx = static_cast<u32>(p.X - origin.X);
		const u32 ly = static_cast<u32>(p.Y - origin.Y);
		const u32 lz = static_cast<u32>(p.Z - origin.Z);
		level[(lx * dim[1] + ly) * dim[2] + lz] = v;
	}
};

} // namespace nows