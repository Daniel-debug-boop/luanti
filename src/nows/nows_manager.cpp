// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#include "nows/nows_manager.h"

#include "constants.h"
#include "gamedef.h"
#include "log.h"
#include "map.h"
#include "nows/nows_field.h"
#include "nows/nows_model.h"
#include "porting.h"
#include "settings.h"
#include "util/metricsbackend.h"
#include "util/numeric.h"
#include "util/string.h"

#include <algorithm>
#include <cstdlib>
#include <sstream>

namespace nows {

/* ------------------------------------------------------------------ */
/* Settings                                                            */
/* ------------------------------------------------------------------ */

/*
 * Feature flags follow Luanti's flat snake_case settings convention
 * (nows_enabled, nows_model_path, ...). The dotted spelling from the NOWS
 * specification (nows.enabled, nows.model, ...) is accepted as an alias so a
 * configuration written either way works.
 */
static bool readRaw(const Settings *s, const char *dotted, const char *snake,
		std::string *out)
{
	if (s && s->exists(dotted)) {
		*out = s->get(dotted);
		return true;
	}
	if (s && s->exists(snake)) {
		*out = s->get(snake);
		return true;
	}
	return false;
}

static bool readBool(const Settings *s, const char *dotted, const char *snake, bool def)
{
	std::string raw;
	if (!readRaw(s, dotted, snake, &raw))
		return def;
	if (raw.empty())
		return def;
	return is_yes(raw);
}

static u32 readU32(const Settings *s, const char *dotted, const char *snake, u32 def,
		u32 lo, u32 hi)
{
	std::string raw;
	if (!readRaw(s, dotted, snake, &raw) || raw.empty())
		return def;
	const long v = strtol(raw.c_str(), nullptr, 10);
	if (v < (long)lo)
		return lo;
	if (v > (long)hi)
		return hi;
	return (u32)v;
}

static f32 readF32(const Settings *s, const char *dotted, const char *snake, f32 def,
		f32 lo, f32 hi)
{
	std::string raw;
	if (!readRaw(s, dotted, snake, &raw) || raw.empty())
		return def;
	const f32 v = (f32)strtod(raw.c_str(), nullptr);
	if (!(v == v)) // NaN
		return def;
	return rangelim(v, lo, hi);
}

Config Manager::configFromSettings(const Settings *settings)
{
	Config cfg;
	if (!settings)
		return cfg;

	cfg.enabled = readBool(settings, "nows.enabled", "nows_enabled", false);
	cfg.fallback = readBool(settings, "nows.fallback", "nows_fallback", true);
	cfg.validation = readBool(settings, "nows.validation", "nows_validation", true);
	cfg.debug = readBool(settings, "nows.debug", "nows_debug", false);
	cfg.allow_untrained = readBool(settings, "nows.allow_untrained",
			"nows_allow_untrained", false);

	std::string path;
	if (readRaw(settings, "nows.model", "nows_model_path", &path))
		cfg.model_path = path;

	cfg.max_residual = readF32(settings, "nows.max_residual", "nows_max_residual",
			0.35f, 0.0f, 1.0f);
	cfg.grid_size = readU32(settings, "nows.grid", "nows_grid_size", 16, 8, 32);
	cfg.max_region_nodes = readU32(settings, "nows.max_region_nodes",
			"nows_max_region_nodes", 512, 1, 4096);
	cfg.min_queue = readU32(settings, "nows.min_queue", "nows_min_queue", 24, 1, 1000000);
	cfg.max_inference_us = readU32(settings, "nows.max_inference_us",
			"nows_max_inference_us", 2000, 1, 1000000);
	cfg.cooldown_solves = readU32(settings, "nows.cooldown", "nows_cooldown", 8, 0, 1000000);
	cfg.adaptive = readBool(settings, "nows.adaptive", "nows_adaptive", true);
	cfg.min_samples = readU32(settings, "nows.min_samples", "nows_min_samples", 8, 1, 1000000);

	// The FFT wants a power of two; round the configured grid down to one.
	if (cfg.grid_size & (cfg.grid_size - 1)) {
		u32 p = 1;
		while ((p << 1) <= cfg.grid_size)
			p <<= 1;
		cfg.grid_size = p;
	}

	return cfg;
}

/* ------------------------------------------------------------------ */

Manager &Manager::get()
{
	static Manager instance;
	return instance;
}

void Manager::initialize(const Settings *settings, MetricsBackend *metrics)
{
	std::lock_guard<std::mutex> lock(m_mutex);
	const Config cfg = configFromSettings(settings);
	const bool model_changed = cfg.model_path != m_config.model_path;
	m_config = cfg;
	if (model_changed || (!m_model && !cfg.model_path.empty())) {
		// Drop the old model: a new path, or the first load attempt.
		m_model.reset();
		m_loaded_from.clear();
		m_load_failed = false;
		m_cooldown = 0;
	}
	m_last_inference_us = 0;

	// Telemetry goes through the engine's own metrics backend, so NOWS shows
	// up in the same Prometheus output as everything else and costs no
	// logging on the hot path.
	if (metrics != m_metrics) {
		// The handles below are shared_ptr, but increment() on them writes
		// through the backend's registry -- so a counter that outlives the
		// backend that created it is a use-after-free, and the allocator
		// reports it as heap corruption at exit. Re-pointing at a different
		// backend (or at none at all, which is what a plain reload does)
		// therefore drops the old backend's handles instead of keeping the
		// newest ones forever.
		m_metrics = metrics;
		m_counter_applied.reset();
		m_counter_fallbacks.reset();
		m_counter_inference_us.reset();
		m_counter_solver_us.reset();
	}
	if (metrics && !m_counter_applied) {
		m_counter_applied = metrics->addCounter("nows_warm_starts_total",
				"Warm-started liquid solves");
		m_counter_fallbacks = metrics->addCounter("nows_fallbacks_total",
				"Predictions discarded before the solver ran");
		m_counter_inference_us = metrics->addCounter(
				"nows_inference_microseconds_total",
				"Time spent inside the neural operator");
		m_counter_solver_us = metrics->addCounter("nows_solver_microseconds_total",
				"Time spent in the liquid solver");
	}
}

bool Manager::isReady() const
{
	std::lock_guard<std::mutex> lock(m_mutex);
	return m_model != nullptr;
}

void Manager::ensureModelLocked(std::string *error)
{
	if (m_model)
		return;
	if (m_config.model_path.empty() || m_load_failed) {
		if (error)
			*error = "no NOWS model configured";
		return;
	}

	std::string load_error;
	std::unique_ptr<Model> model = loadModelFile(m_config.model_path,
			m_config.allow_untrained, &load_error);
	if (!model) {
		m_load_failed = true;
		m_stats.model_load_failures++;
		warningstream << "NOWS: " << load_error << std::endl;
		if (error)
			*error = load_error;
		return;
	}

	m_model = std::move(model);
	m_loaded_from = m_config.model_path;

	actionstream << "NOWS: loaded model '" << m_model->desc().name << "' ("
			<< m_model->desc().arch << ", grid " << m_model->desc().grid << ", "
			<< (m_model->desc().trained ? "trained" : "UNTRAINED development model")
			<< ") from " << m_loaded_from << std::endl;
}

bool Manager::predictWarmStart(Map *map, IGameDef *gamedef,
		const v3s16 &center, size_t queue_size, WarmStart &out, Status &status)
{
	out.clear();
	status = Status::Disabled;

	std::unique_lock<std::mutex> lock(m_mutex);
	if (!m_config.enabled)
		return false;
	m_stats.solves++;

	if (queue_size < m_config.min_queue) {
		status = Status::TooSmallQueue;
		m_stats.nows_skipped++;
		return false;
	}
	if (m_cooldown > 0) {
		m_cooldown--;
		status = Status::Cooldown;
		m_stats.nows_skipped++;
		return false;
	}

	/*
	 * The economic gate.
	 *
	 * NOWS is only worth running when what it saves the solver is worth more
	 * than what the prediction costs. Both halves of that are measured here,
	 * from this server's own history: the iterations a plain solve needed, the
	 * microseconds an iteration costs on the plain path, the iterations the
	 * same solve needed warm started, and the microseconds the inference took.
	 * If the difference comes out at or below zero, the honest answer is that
	 * the layer is making the game slower, so it stops running until the
	 * evidence changes.
	 */
	if (m_config.adaptive &&
			m_profit.baseline_samples >= m_config.min_samples &&
			m_profit.nows_samples >= m_config.min_samples &&
			m_profit.expectedSavingUs() <= m_profit.inference_us) {
		status = Status::Unprofitable;
		m_stats.nows_skipped++;
		m_stats.unprofitable_skips++;
		if (m_config.debug) {
			infostream << "NOWS: skipped, a warm start saves "
					<< m_profit.expectedSavingUs() << " us but inference costs "
					<< m_profit.inference_us << " us" << std::endl;
		}
		return false;
	}

	std::string error;
	ensureModelLocked(&error);
	if (!m_model) {
		status = !m_config.model_path.empty() ? Status::ModelInvalid : Status::NoModel;
		m_stats.nows_skipped++;
		// The solver is about to run with no warm start at all: that IS the
		// fallback, whether the model was never configured or failed to
		// load, so it is counted here and not only on the slow paths below
		// that already return through the shared fallback accounting.
		m_stats.fallbacks++;
		if (m_counter_fallbacks)
			m_counter_fallbacks->increment();
		return false;
	}

	if (m_model->desc().grid != m_config.grid_size) {
		status = Status::Incompatible;
		m_stats.nows_skipped++;
		if (m_config.debug) {
			infostream << "NOWS: skipped, model grid " << m_model->desc().grid
					<< " != nows_grid_size " << m_config.grid_size << std::endl;
		}
		return false;
	}

	lock.unlock();

	GatheredField gathered;
	std::string gather_error;
	bool ok = gatherField(map, gamedef, center, m_config, gathered, &gather_error);

	Field predicted;
	if (ok) {
		const u64 t0 = porting::getTimeUs();
		std::string predict_error;
		ok = m_model->predict(gathered.input, predicted, &predict_error);
		const u64 elapsed = porting::getTimeUs() - t0;

		lock.lock();
		if (ok) {
			m_stats.inferences++;
			m_stats.inference_us += elapsed;
			if (m_profit.nows_samples || m_profit.inference_us > 0.0) {
				const f32 a = 0.2f;
				m_profit.inference_us += a * ((f64)elapsed - m_profit.inference_us);
			} else {
				m_profit.inference_us = (f64)elapsed;
			}
			if (m_counter_inference_us)
				m_counter_inference_us->increment((double)elapsed);
			m_last_inference_us = (u32)std::min<u64>(elapsed, 0xFFFFFFFFull);
			if (elapsed > m_config.max_inference_us) {
				// Inference that costs more than it can save is worse than no
				// inference at all: back off and run the plain solve.
				ok = false;
				gather_error = "inference took " + std::to_string(elapsed) +
						" us, over nows_max_inference_us";
				status = Status::BudgetExceeded;
			}
		} else {
			gather_error = predict_error;
			m_stats.rejections++;
			status = Status::PredictionInvalid;
		}
		lock.unlock();
	}

	if (ok) {
		WarmStart guess;
		std::string project_error;
		ok = projectWarmStart(predicted, gathered, m_config, guess, &project_error);
		if (!ok) {
			gather_error = project_error;
			status = Status::PredictionInvalid;
		} else {
			lock.lock();
			out = std::move(guess);
			m_stats.nows_applied++;
			if (m_counter_applied)
				m_counter_applied->increment();
			status = Status::Ok;
			if (m_config.debug) {
				actionstream << "NOWS: warm start " << out.guessCount() << " cells"
						<< " (inference " << m_last_inference_us << " us)" << std::endl;
			}
		}
	}

	if (!ok) {
		lock.lock();
		m_stats.fallbacks++;
		if (m_counter_fallbacks)
			m_counter_fallbacks->increment();
		m_cooldown = m_config.cooldown_solves;
		if (m_config.debug) {
			infostream << "NOWS: falling back to the normal solver ("
					<< statusName(status) << ": " << gather_error << ")" << std::endl;
		}
	}

	return ok;
}

void Manager::recordSolve(bool used_nows, u32 iterations, u64 solver_us, bool converged,
		u32 residual)
{
	std::lock_guard<std::mutex> lock(m_mutex);

	if (m_counter_solver_us)
		m_counter_solver_us->increment((double)solver_us);

	// Exponential averages, seeded from the first sample of each kind.
	const f64 iters = (f64)iterations;
	const f64 us_per_iter = iterations ? (f64)solver_us / iters : 0.0;
	const f64 alpha = 0.2;

	if (used_nows) {
		m_stats.nows_solves++;
		m_stats.nows_iterations += iterations;
		m_stats.nows_solver_us += solver_us;
		m_stats.nows_residual += residual;
		m_profit.nows_iters = m_profit.nows_samples ?
				m_profit.nows_iters + alpha * (iters - m_profit.nows_iters) : iters;
		m_profit.nows_samples++;
		if (!converged) {
			m_stats.convergence_failures++;
			m_cooldown = m_config.cooldown_solves;
			if (m_config.debug) {
				infostream << "NOWS: solver did not reach its fixed point after "
						<< iterations << " iterations; cooling down" << std::endl;
			}
		}
	} else {
		m_stats.baseline_solves++;
		m_stats.baseline_iterations += iterations;
		m_stats.baseline_solver_us += solver_us;
		m_stats.baseline_residual += residual;
		m_profit.baseline_iters = m_profit.baseline_samples ?
				m_profit.baseline_iters + alpha * (iters - m_profit.baseline_iters) : iters;
		m_profit.baseline_us_per_iter = m_profit.baseline_samples ?
				m_profit.baseline_us_per_iter + alpha * (us_per_iter - m_profit.baseline_us_per_iter) :
				us_per_iter;
		m_profit.baseline_samples++;
	}

	if (m_config.debug && (m_stats.nows_solves + m_stats.baseline_solves) % 64 == 0) {
		infostream << "NOWS: " << m_stats.baseline_solves << " normal solves ("
				<< m_stats.baselineIterationsPerSolve() << " it avg), "
				<< m_stats.nows_solves << " warm-started solves ("
				<< m_stats.nowsIterationsPerSolve() << " it avg), "
				<< m_stats.fallbacks << " fallbacks, "
				<< m_stats.rejections << " rejections, "
				<< m_stats.convergence_failures << " convergence failures"
				<< std::endl;
	}
}

Stats Manager::statsCopy() const
{
	std::lock_guard<std::mutex> lock(m_mutex);
	return m_stats;
}

Manager::Profitability Manager::profitability() const
{
	std::lock_guard<std::mutex> lock(m_mutex);
	return m_profit;
}

std::string Manager::statsString() const
{
	std::lock_guard<std::mutex> lock(m_mutex);
	const Stats &s = m_stats;
	std::ostringstream os;
	os << "NOWS statistics" << std::endl;
	os << "  solves:                " << s.solves << std::endl;
	os << "  warm starts applied:   " << s.nows_applied << std::endl;
	os << "  skipped (too small):   " << s.nows_skipped << std::endl;
	os << "  fallbacks:             " << s.fallbacks << std::endl;
	os << "  prediction rejections: " << s.rejections << std::endl;
	os << "  convergence failures:  " << s.convergence_failures << std::endl;
	os << "  inferences:            " << s.inferences << std::endl;
	os << "  model load failures:   " << s.model_load_failures << std::endl;
	os << "  normal solves:         " << s.baseline_solves << " ("
			<< s.baselineIterationsPerSolve() << " iterations avg, "
			<< s.baselineSolverMs() << " ms total)" << std::endl;
	os << "  warm-started solves:   " << s.nows_solves << " ("
			<< s.nowsIterationsPerSolve() << " iterations avg, "
			<< s.nowsSolverMs() << " ms total)" << std::endl;
	os << "  inference time:        " << s.inferenceMs() << " ms total" << std::endl;
	os << "  refused as unprofitable: " << s.unprofitable_skips << std::endl;
	os << "  residual work:         " << s.baseline_residual << " normal, "
			<< s.nows_residual << " warm started" << std::endl;
	os << "  economics per solve:   saved " << s.savedUsPerSolve() << " us, inference "
			<< s.inferenceUsPerSolve() << " us, net " << s.netUsPerSolve() << " us"
			<< std::endl;
	if (s.netUsPerSolve() < 0.0 && s.nows_solves)
		os << "    (NOWS is currently a net cost; nows_adaptive will switch it off)"
				<< std::endl;
	return os.str();
}

void Manager::resetStats()
{
	std::lock_guard<std::mutex> lock(m_mutex);
	m_stats = Stats();
	m_profit = Profitability();
	m_cooldown = 0;
}

} // namespace nows