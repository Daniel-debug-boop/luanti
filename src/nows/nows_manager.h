// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once

#include "nows_types.h"

#include <memory>
#include <mutex>
#include <string>

class IGameDef;
class Map;
class MetricsBackend;
class MetricCounter;
class Settings;
using MetricCounterPtr = std::shared_ptr<MetricCounter>;

namespace nows {

class Model;

/*
 * NOWSManager -- the single entry point the simulation talks to.
 *
 * Deliberately shaped like the rest of the engine's subsystems: a process
 * wide singleton configured from settings, cheap to call, and impossible to
 * reach from Lua or a mod. A simulation subsystem asks for a warm start and
 * gets either one or a clean "no"; it never has to know whether a neural
 * network, a file or a fallback was involved.
 *
 * Everything here runs on the thread that drives the simulation (the server
 * thread, via Server::AsyncRunStep -> ServerMap::transformLiquids). The
 * manager owns no threads of its own: NOWS must not turn into an inference
 * pool that competes with the rest of the engine for CPU.
 *
 * Threading contract: single writer. initialize(), predictWarmStart() and
 * recordSolve() are called from the simulation thread and must not race with
 * each other. The mutex is there so that a reader -- the debug dump or a
 * metrics scrape -- can read the counters without waiting on a long
 * inference; it does not make the model object itself thread safe, and the
 * model is deliberately used without holding it during inference so a reader
 * is never blocked for the length of a forward pass.
 */
class Manager
{
public:
	static Manager &get();

	/* Reads configuration (including the model path) and prepares the
	 * manager. Safe to call more than once; later calls re-read settings.
	 *
	 * `metrics` is optional: when the engine hands over its metrics backend
	 * the counters below are registered there, which is how the stats reach
	 * Prometheus without any logging cost on the hot path. */
	void initialize(const Settings *settings, MetricsBackend *metrics = nullptr);

	const Config &config() const { return m_config; }
	bool isEnabled() const { return m_config.enabled; }
	/* True when a model is loaded and inference can run. */
	bool isReady() const;

	/* Builds an initial guess for the region around `center`.
	 * `queue_size` is how much work the solver has queued, which is the
	 * signal that warm starting could pay for itself at all.
	 *
	 * Returns true only when `out` holds a usable guess. On false, `status`
	 * says why, and the caller must run its normal solve. */
	bool predictWarmStart(Map *map, IGameDef *gamedef, const v3s16 &center,
			size_t queue_size, WarmStart &out, Status &status);

	/* Called by the solver after every solve it ran.
	 *
	 * `residual` is the work the solver still had queued when it returned:
	 * zero means the field reached its fixed point. */
	void recordSolve(bool used_nows, u32 iterations, u64 solver_us, bool converged,
			u32 residual = 0);

	/* Thread-safe copy of the counters, for tests and diagnostics. */
	Stats statsCopy() const;
	std::string statsString() const;
	void resetStats();

	/* Exposed for tests and for the dev model generator. */
	static Config configFromSettings(const Settings *settings);

	/* What the layer currently believes about its own economics, using the
	 * same estimate the adaptive gate uses. Reported by statsString(). */
	struct Profitability
	{
		f64 baseline_iters = 0.0;
		f64 nows_iters = 0.0;
		f64 baseline_us_per_iter = 0.0;
		f64 inference_us = 0.0;
		u32 baseline_samples = 0;
		u32 nows_samples = 0;

		/* Microseconds a warm-started solve is expected to save, from the
		 * measured difference in iterations times the measured cost of one
		 * iteration on the plain path. */
		f64 expectedSavingUs() const
		{
			return (baseline_iters - nows_iters) * baseline_us_per_iter;
		}
	};
	Profitability profitability() const;

private:
	Manager() = default;

	/* Loads (or reloads) the model named by the configuration. */
	void ensureModelLocked(std::string *error);

	Config m_config;
	std::unique_ptr<Model> m_model;

	mutable std::mutex m_mutex;
	Stats m_stats;
	/* Solver calls to skip before trying again. */
	u32 m_cooldown = 0;
	/* Microseconds the last successful inference took. */
	u32 m_last_inference_us = 0;
	/* Model file the currently loaded model came from. */
	std::string m_loaded_from;
	bool m_load_failed = false;

	/* Running averages behind the adaptive gate. They are deliberately
	 * exponential rather than cumulative, so a world that stops producing
	 * liquid work stops judging NOWS on old evidence. */
	Profitability m_profit;

	/* Engine telemetry, registered once when a backend shows up. */
	MetricsBackend *m_metrics = nullptr;
	MetricCounterPtr m_counter_applied;
	MetricCounterPtr m_counter_fallbacks;
	MetricCounterPtr m_counter_inference_us;
	MetricCounterPtr m_counter_solver_us;
};

} // namespace nows