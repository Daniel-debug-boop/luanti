// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#include "test.h"

#include "constants.h"
#include "emerge.h"
#include "mapblock.h"
#include "mapnode.h"
#include "mock_server.h"
#include "nodedef.h"
#include "nows/nows_field.h"
#include "nows/nows_fft.h"
#include "nows/nows_manager.h"
#include "nows/nows_model.h"
#include "nows/nows_validation.h"
#include "porting.h"
#include "serverenvironment.h"
#include "servermap.h"
#include "settings.h"
#include "util/container.h"
#include "util/metricsbackend.h"

#include <cmath>
#include <fstream>
#include <limits>
#include <memory>
#include <vector>

/*
 * NOWS tests.
 *
 * The point of these is the safety envelope, not the speed-up: a learned warm
 * start is allowed to be wrong, and the engine has to notice and fall back.
 * So the failure paths get the coverage -- malformed models, untrained models,
 * NaN/Inf and out-of-range predictions, mismatched grids, imbalance the field
 * cannot absorb, a missing model, the disabled path -- and the last test runs
 * the real liquid solver with and without a warm start and checks that both
 * converge to the same state.
 */
class TestNOWS : public TestBase
{
public:
	TestNOWS() { TestManager::registerTestModule(this); }
	const char *getName() { return "TestNOWS"; }

	void runTests(IGameDef *gamedef);

	void testFftRoundTrip();
	void testModelFileRoundTrip();
	void testInvalidModels();
	void testUntrainedModelRejected();
	void testPredictionShapeAndDeterminism();
	void testValidationRejectsNonFinite();
	void testMassPreservingProjection();
	void testWarmStartLookup();
	void testConfigDefaultsAndAliases();
	void testManagerFallbacks(IGameDef *gamedef);
	void testProfitabilityGate();
	void testLiquidSolverIntegration(IGameDef *gamedef);
	void testABTable(IGameDef *gamedef);

private:
	/* getTestTempFile() lives on TestBase, so the helper has to as well. */
	std::string writeTempModel(const nows::ModelDesc &desc,
			const std::vector<std::pair<std::string, std::vector<f32>>> &tensors);
};

static TestNOWS g_test_instance;

// --- helpers ------------------------------------------------------------

// A deterministic placeholder model. The weights are a fixed pattern, not
// learned values: this exercises the file format, the loader and the forward
// pass, and proves nothing about prediction quality.
static nows::ModelDesc devDesc(bool trained)
{
	nows::ModelDesc d;
	d.arch = "fno3d";
	d.name = trained ? "dev" : "dev-untrained";
	d.note = trained ? "test fixture" : "UNTRAINED development placeholder";
	d.trained = trained;
	d.grid = 8;
	d.channels = 2;
	d.modes = 2;
	d.layers = 1;
	d.in_channels = nows::FC_COUNT;
	d.out_channels = 1;
	return d;
}

static std::vector<std::pair<std::string, std::vector<f32>>>
devTensors(const nows::ModelDesc &d)
{
	const u32 ch = d.channels, cin = d.in_channels, m = d.modes;
	std::vector<std::pair<std::string, std::vector<f32>>> out;

	std::vector<f32> lift_w(static_cast<size_t>(ch) * cin);
	for (u32 c = 0; c < ch; c++)
		for (u32 k = 0; k < cin; k++)
			lift_w[c * cin + k] = (c == k % ch) ? 0.25f : 0.0f;
	out.emplace_back("lift_w", lift_w);
	out.emplace_back("lift_b", std::vector<f32>(ch, 0.0f));

	for (u32 l = 0; l < d.layers; l++) {
		const std::string base = "l" + std::to_string(l);
		// Zero spectral weights keep the operator a no-op, so the test does
		// not depend on floating point transforms to assert exact values.
		out.emplace_back(base + "_spec_re",
				std::vector<f32>(static_cast<size_t>(m) * m * m * ch * ch, 0.0f));
		out.emplace_back(base + "_spec_im",
				std::vector<f32>(static_cast<size_t>(m) * m * m * ch * ch, 0.0f));
		std::vector<f32> pw(ch * ch, 0.0f);
		for (u32 c = 0; c < ch; c++)
			pw[c * ch + c] = 1.0f;
		out.emplace_back(base + "_pw_w", pw);
		out.emplace_back(base + "_pw_b", std::vector<f32>(ch, 0.0f));
	}

	std::vector<f32> proj(d.out_channels * ch, 0.0f);
	for (u32 o = 0; o < d.out_channels; o++)
		proj[o * ch] = 0.5f;
	out.emplace_back("proj_w", proj);
	out.emplace_back("proj_b", std::vector<f32>(d.out_channels, 0.0f));
	return out;
}

std::string TestNOWS::writeTempModel(const nows::ModelDesc &d,
		const std::vector<std::pair<std::string, std::vector<f32>>> &tensors)
{
	const std::string path = getTestTempFile() + ".nowsm";
	std::string err;
	if (!nows::writeModelFile(path, d, tensors, &err))
		throw TestFailedException("could not write test model: " + err, __FILE__, __LINE__);
	return path;
}

static nows::Field makeInput(u32 grid)
{
	nows::Dims dims;
	dims.x = dims.y = dims.z = grid;
	nows::Field f;
	f.resize(dims, nows::FC_COUNT);
	for (u32 i = 0; i < f.dims.count(); i++) {
		const f32 level = (f32)(i % 8) / 7.0f;
		f.set(i, nows::FC_LEVEL, level);
		f.set(i, nows::FC_FLOWING, level > 0.0f ? 1.0f : 0.0f);
		f.set(i, nows::FC_SOURCE, (i % 16) == 0 ? 1.0f : 0.0f);
		f.set(i, nows::FC_FLOODABLE, (i % 3) == 0 ? 1.0f : 0.0f);
		f.set(i, nows::FC_SOLID, 0.0f);
		f.set(i, nows::FC_NEIGHBOUR_SOURCES, (f32)(i % 6) / 6.0f);
	}
	return f;
}

void TestNOWS::runTests(IGameDef *gamedef)
{
	TEST(testFftRoundTrip);
	TEST(testModelFileRoundTrip);
	TEST(testInvalidModels);
	TEST(testUntrainedModelRejected);
	TEST(testPredictionShapeAndDeterminism);
	TEST(testValidationRejectsNonFinite);
	TEST(testMassPreservingProjection);
	TEST(testWarmStartLookup);
	TEST(testConfigDefaultsAndAliases);
	TEST(testManagerFallbacks, gamedef);
	TEST(testProfitabilityGate);
	TEST(testLiquidSolverIntegration, gamedef);
	TEST(testABTable, gamedef);
}

// --- the FFT the operator depends on ------------------------------------

void TestNOWS::testFftRoundTrip()
{
	const u32 n = 8;
	const size_t cells = n * n * n;
	std::vector<f32> re(cells), im(cells);
	for (size_t i = 0; i < cells; i++)
		re[i] = std::sin(0.7f * (f32)i);

	std::vector<f32> orig = re;
	nows::fft::forward3d(re, im, n, n, n);
	nows::fft::inverse3d(re, im, n, n, n);

	for (size_t i = 0; i < cells; i++)
		UASSERT(std::fabs(re[i] - orig[i]) < 1e-3f);

	// A constant field has all its energy in the zero mode.
	std::fill(re.begin(), re.end(), 1.0f);
	std::fill(im.begin(), im.end(), 0.0f);
	nows::fft::forward3d(re, im, n, n, n);
	UASSERT(std::fabs(re[0] - (f32)cells) < 1e-2f);
	UASSERT(std::fabs(im[0]) < 1e-2f);
	for (size_t i = 1; i < cells; i++)
		UASSERT(std::fabs(re[i]) < 1e-2f);

	UASSERT(nows::fft::isPowerOfTwo(16));
	UASSERT(!nows::fft::isPowerOfTwo(15));
}

// --- model files --------------------------------------------------------

void TestNOWS::testModelFileRoundTrip()
{
	const nows::ModelDesc d = devDesc(true);
	const std::string path = writeTempModel(d, devTensors(d));

	nows::ModelFile file;
	std::string err;
	UASSERT(nows::readModelFile(path, &file, &err));
	UASSERTEQ(u32, file.desc.grid, d.grid);
	UASSERTEQ(u32, file.desc.channels, d.channels);
	UASSERTEQ(u32, file.desc.modes, d.modes);
	UASSERTEQ(u32, file.desc.layers, d.layers);
	UASSERTEQ(u32, file.desc.in_channels, d.in_channels);
	UASSERTEQ(u32, file.desc.out_channels, d.out_channels);
	UASSERTEQ(std::string, file.desc.arch, d.arch);
	UASSERT(file.desc.trained);

	const auto tensors = devTensors(d);
	UASSERTEQ(size_t, file.tensors.size(), tensors.size());
	for (const auto &t : tensors) {
		UASSERT(file.tensors.count(t.first) == 1);
		UASSERTEQ(size_t, file.tensors[t.first].size(), t.second.size());
		for (size_t i = 0; i < t.second.size(); i++)
			UASSERT(file.tensors[t.first][i] == t.second[i]);
	}

	// And the loader instantiates a backend of the declared architecture.
	std::unique_ptr<nows::Model> model = nows::loadModelFile(path, true, &err);
	UASSERT(model != nullptr);
	UASSERTEQ(u32, model->desc().grid, d.grid);
}

void TestNOWS::testInvalidModels()
{
	// A file that is not a model at all.
	{
		const std::string path = getTestTempFile() + ".junk";
		std::ofstream ofs(path, std::ios::out | std::ios::binary);
		ofs << "this is not a model";
		ofs.close();

		nows::ModelFile file;
		std::string err;
		UASSERT(!nows::readModelFile(path, &file, &err));
		UASSERT(!err.empty());
		UASSERT(nows::loadModelFile(path, true, &err) == nullptr);
	}

	// A missing file.
	{
		nows::ModelFile file;
		std::string err;
		UASSERT(!nows::readModelFile(getTestTempFile() + ".absent", &file, &err));
		UASSERT(nows::loadModelFile(getTestTempFile() + ".absent", true, &err) == nullptr);
	}

	// No path configured at all.
	{
		std::string err;
		UASSERT(nows::loadModelFile("", true, &err) == nullptr);
		UASSERT(!err.empty());
	}

	// A truncated file: valid header, cut off in the middle of the tensors.
	{
		const nows::ModelDesc d = devDesc(true);
		const std::string path = writeTempModel(d, devTensors(d));
		std::ifstream in(path, std::ios::in | std::ios::binary);
		std::string blob((std::istreambuf_iterator<char>(in)),
				std::istreambuf_iterator<char>());
		in.close();
		blob.resize(blob.size() / 2);

		const std::string cut = getTestTempFile() + ".cut";
		std::ofstream ofs(cut, std::ios::out | std::ios::binary);
		ofs.write(blob.data(), (std::streamsize)blob.size());
		ofs.close();

		nows::ModelFile file;
		std::string err;
		UASSERT(!nows::readModelFile(cut, &file, &err));
	}

	// A model whose tensor is missing from the file: the backend refuses it.
	{
		nows::ModelDesc d = devDesc(true);
		auto tensors = devTensors(d);
		tensors.pop_back(); // drop proj_b
		const std::string path = writeTempModel(d, tensors);
		std::string err;
		UASSERT(nows::loadModelFile(path, true, &err) == nullptr);
		UASSERT(err.find("proj_b") != std::string::npos);
	}

	// An architecture nobody implements.
	{
		nows::ModelDesc d = devDesc(true);
		d.arch = "quantum_diffusion_operator";
		const std::string path = writeTempModel(d, devTensors(d));
		std::string err;
		UASSERT(nows::loadModelFile(path, true, &err) == nullptr);
		UASSERT(err.find("architecture") != std::string::npos);
	}

	// A grid the FFT cannot do.
	{
		nows::ModelDesc d = devDesc(true);
		d.grid = 12; // not a power of two
		std::string err;
		UASSERT(!nows::validateDesc(d, &err));
	}
}

void TestNOWS::testUntrainedModelRejected()
{
	const nows::ModelDesc d = devDesc(false);
	const std::string path = writeTempModel(d, devTensors(d));

	std::string err;
	UASSERT(nows::loadModelFile(path, false, &err) == nullptr);
	UASSERT(err.find("trained=0") != std::string::npos);

	// Opting in is the only way to run one, so a placeholder can never
	// silently become the engine's default.
	std::unique_ptr<nows::Model> model = nows::loadModelFile(path, true, &err);
	UASSERT(model != nullptr);
	UASSERT(!model->desc().trained);
}

// --- inference ----------------------------------------------------------

void TestNOWS::testPredictionShapeAndDeterminism()
{
	const nows::ModelDesc d = devDesc(true);
	const std::string path = writeTempModel(d, devTensors(d));
	std::string err;
	std::unique_ptr<nows::Model> model = nows::loadModelFile(path, true, &err);
	UASSERT(model != nullptr);

	const nows::Field in = makeInput(d.grid);
	nows::Field out;
	UASSERT(model->predict(in, out, &err));
	UASSERT(!out.empty());
	UASSERT(out.dims.isCube());
	UASSERTEQ(u32, out.dims.x, d.grid);
	UASSERTEQ(u32, out.channels, d.out_channels);
	UASSERTEQ(size_t, out.data.size(),
			(size_t)d.grid * d.grid * d.grid * d.out_channels);
	UASSERT(nows::validation::checkFinite(out, &err));

	// Same input, same answer: no hidden randomness, no time dependence.
	nows::Field again;
	UASSERT(model->predict(in, again, &err));
	UASSERTEQ(size_t, again.data.size(), out.data.size());
	for (size_t i = 0; i < out.data.size(); i++)
		UASSERT(again.data[i] == out.data[i]);

	// A field of the wrong shape is refused rather than reinterpreted.
	nows::Dims wrong;
	wrong.x = wrong.y = wrong.z = d.grid * 2;
	nows::Field big;
	big.resize(wrong, d.in_channels);
	nows::Field out2;
	UASSERT(!model->predict(big, out2, &err));
	UASSERT(!err.empty());

	// Wrong channel count is refused too.
	nows::Dims small;
	small.x = small.y = small.z = d.grid;
	nows::Field wrong_channels;
	wrong_channels.resize(small, d.in_channels + 1);
	UASSERT(!model->predict(wrong_channels, out2, &err));
}

void TestNOWS::testValidationRejectsNonFinite()
{
	nows::Dims dims;
	dims.x = dims.y = dims.z = 4;
	nows::Field f;
	f.resize(dims, 1);
	std::string err;

	UASSERT(nows::validation::checkFinite(f, &err));

	const f32 nan_value = std::nanf("");
	f.data[5] = nan_value;
	UASSERT(!nows::validation::checkFinite(f, &err));
	UASSERT(err.find("non-finite") != std::string::npos);

	const f32 inf_value = std::numeric_limits<f32>::infinity();
	f.data[5] = inf_value;
	UASSERT(!nows::validation::checkFinite(f, &err));

	f.data[5] = 0.5f;
	UASSERT(nows::validation::checkFinite(f, &err));

	// Range: a level outside [0,1] cannot be a liquid level.
	for (u32 i = 0; i < f.dims.count(); i++)
		f.set(i, 0, 0.5f);
	UASSERT(nows::validation::checkRange(f, 0, 0.0f, 1.0f, &err));
	f.set(3, 0, 1.5f);
	UASSERT(!nows::validation::checkRange(f, 0, 0.0f, 1.0f, &err));
	UASSERT(!nows::validation::checkRange(f, 9, 0.0f, 1.0f, &err));

	// Residual: known values, known answer.
	nows::Field a, b;
	a.resize(dims, 1);
	b.resize(dims, 1);
	for (u32 i = 0; i < a.dims.count(); i++) {
		a.set(i, 0, 0.0f);
		b.set(i, 0, (i == 0) ? 1.0f : 0.0f);
	}
	// One cell of 1.0 out of 64 cells: RMS = sqrt(1/64).
	UASSERT(std::fabs(nows::validation::residual(a, b, 0) - 0.125f) < 1e-5f);
	UASSERT(nows::validation::residual(a, b, 3) == 0.0f);
}

void TestNOWS::testMassPreservingProjection()
{
	const size_t n = 8;
	const s8 max_level = 7;

	// Current field: four cells carrying level 4, total 16.
	std::vector<s8> current(n, -1);
	std::vector<u8> applicable(n, 0);
	current[0] = current[1] = current[2] = current[3] = 4;
	applicable[0] = applicable[1] = applicable[2] = applicable[3] = 1;

	// A prediction that adds liquid has to be balanced back.
	std::vector<s8> predicted(n, -1);
	predicted[0] = 7;
	predicted[1] = 7;
	predicted[2] = 7;
	predicted[3] = 7;

	std::string err;
	UASSERT(nows::validation::projectMassPreserving(predicted, current, applicable,
			max_level, &err));

	long total = 0;
	for (size_t i = 0; i < n; i++) {
		if (applicable[i])
			total += predicted[i];
		UASSERT(predicted[i] >= 0 && predicted[i] <= max_level);
	}
	UASSERTEQ(long, total, 16);

	// Out-of-range predictions are clamped, not trusted.
	predicted[0] = 99;
	predicted[1] = 99;
	predicted[2] = 99;
	predicted[3] = 99;
	UASSERT(nows::validation::projectMassPreserving(predicted, current, applicable,
			max_level, &err));
	total = 0;
	for (size_t i = 0; i < n; i++)
		if (applicable[i])
			total += predicted[i];
	UASSERTEQ(long, total, 16);

	// The projection only touches applicable cells.
	UASSERT(predicted[7] == -1);

	// A current field the solver could never have produced is rejected rather
	// than balanced through: the projection is only allowed to move liquid
	// around, never to believe an impossible amount of it.
	std::vector<s8> impossible(n, -1);
	std::vector<u8> one_app(n, 0);
	impossible[0] = 99;
	one_app[0] = 1;
	std::vector<s8> greedy(n, -1);
	greedy[0] = 3;
	UASSERT(!nows::validation::projectMassPreserving(greedy, impossible, one_app,
			max_level, &err));
	UASSERT(err.find("out-of-range") != std::string::npos);

	// Balancing a prediction onto a reachable total always succeeds, which is
	// what keeps the warm start from being able to create or destroy liquid.
	std::vector<s8> one(n, -1);
	one[0] = 1;
	greedy[0] = 7;
	UASSERT(nows::validation::projectMassPreserving(greedy, one, one_app,
			max_level, &err));
	UASSERTEQ(s8, greedy[0], 1);

	// Mismatched vectors are a programming error, not a prediction.
	std::vector<s8> short_current(n - 1, 0);
	std::vector<u8> all_app(n, 1);
	UASSERT(!nows::validation::projectMassPreserving(greedy, short_current, all_app,
			max_level, &err));
}

void TestNOWS::testWarmStartLookup()
{
	nows::WarmStart w;
	UASSERT(w.empty());
	UASSERT(w.levelAt(v3s16(0, 0, 0)) == -1);

	w.origin = v3s16(10, 20, 30);
	w.dim[0] = 4;
	w.dim[1] = 4;
	w.dim[2] = 4;
	w.level.assign(64, (s8)-1);

	UASSERT(!w.contains(v3s16(9, 20, 30)));
	UASSERT(w.contains(v3s16(10, 20, 30)));
	UASSERT(w.contains(v3s16(13, 23, 33)));
	UASSERT(!w.contains(v3s16(14, 23, 33)));

	UASSERT(w.levelAt(v3s16(11, 21, 31)) == -1);
	w.set(v3s16(11, 21, 31), 5);
	UASSERTEQ(s8, w.levelAt(v3s16(11, 21, 31)), 5);
	UASSERTEQ(u32, w.guessCount(), 1);

	// Writes outside the region are dropped, not clamped into it.
	w.set(v3s16(99, 0, 0), 3);
	UASSERTEQ(u32, w.guessCount(), 1);
}

void TestNOWS::testConfigDefaultsAndAliases()
{
	// Safe by default: no settings, no acceleration.
	nows::Config cfg = nows::Manager::configFromSettings(nullptr);
	UASSERT(!cfg.enabled);
	UASSERT(cfg.fallback);
	UASSERT(cfg.validation);
	UASSERT(!cfg.debug);
	UASSERT(!cfg.allow_untrained);
	UASSERT(cfg.model_path.empty());
	UASSERT(cfg.grid_size == 16);
	UASSERT(cfg.max_region_nodes > 0);

	// Snake case, the engine's own convention.
	Settings snake;
	snake.set("nows_enabled", "true");
	snake.set("nows_model_path", "/tmp/model.nowsm");
	snake.set("nows_max_residual", "0.5");
	snake.set("nows_grid_size", "8");
	cfg = nows::Manager::configFromSettings(&snake);
	UASSERT(cfg.enabled);
	UASSERTEQ(std::string, cfg.model_path, std::string("/tmp/model.nowsm"));
	UASSERT(std::fabs(cfg.max_residual - 0.5f) < 1e-5f);
	UASSERTEQ(u32, cfg.grid_size, 8u);

	// Dotted aliases from the NOWS specification work too.
	Settings dotted;
	dotted.set("nows.enabled", "true");
	dotted.set("nows.model", "/tmp/dotted.nowsm");
	dotted.set("nows.validation", "false");
	cfg = nows::Manager::configFromSettings(&dotted);
	UASSERT(cfg.enabled);
	UASSERTEQ(std::string, cfg.model_path, std::string("/tmp/dotted.nowsm"));
	UASSERT(!cfg.validation);

	// Out of range values are clamped, never trusted.
	Settings wild;
	wild.set("nows_grid_size", "999");
	wild.set("nows_max_residual", "42");
	cfg = nows::Manager::configFromSettings(&wild);
	UASSERT(cfg.grid_size >= 8 && cfg.grid_size <= 32);
	UASSERT(cfg.max_residual <= 1.0f);
}

// --- manager behaviour --------------------------------------------------

void TestNOWS::testManagerFallbacks(IGameDef *gamedef)
{
	nows::Manager &mgr = nows::Manager::get();

	// Disabled: the manager must not even look at the map.
	{
		Settings off;
		mgr.initialize(&off);
		mgr.resetStats();

		nows::WarmStart guess;
		nows::Status status = nows::Status::Ok;
		UASSERT(!mgr.predictWarmStart(nullptr, gamedef, v3s16(0, 0, 0), 1000,
				guess, status));
		UASSERTEQ(int, (int)status, (int)nows::Status::Disabled);
		UASSERT(guess.empty());
		UASSERTEQ(u64, mgr.statsCopy().nows_applied, 0u);
	}

	// Enabled but no model: falls back, counts it, and stays harmless.
	{
		Settings on;
		on.set("nows_enabled", "true");
		on.set("nows_min_queue", "1");
		mgr.initialize(&on);
		mgr.resetStats();

		nows::WarmStart guess;
		nows::Status status = nows::Status::Ok;
		UASSERT(!mgr.predictWarmStart(nullptr, gamedef, v3s16(0, 0, 0), 1000,
				guess, status));
		UASSERTEQ(int, (int)status, (int)nows::Status::NoModel);
		UASSERT(guess.empty());
		UASSERT(mgr.statsCopy().fallbacks >= 1);

		// Solver statistics still work, and are what a disabled engine
		// reports anyway.
		mgr.recordSolve(false, 42, 1000, true);
		const nows::Stats s = mgr.statsCopy();
		UASSERTEQ(u64, s.baseline_solves, 1u);
		UASSERTEQ(u64, s.baseline_iterations, 42u);
		UASSERT(std::fabs(s.baselineIterationsPerSolve() - 42.0) < 1e-6);
	}

	// Enabled with a model that does not exist: same outcome, no crash.
	{
		Settings bad;
		bad.set("nows_enabled", "true");
		bad.set("nows_min_queue", "1");
		bad.set("nows_model_path", getTestTempFile() + ".nonexistent");
		mgr.initialize(&bad);
		mgr.resetStats();

		nows::WarmStart guess;
		nows::Status status = nows::Status::Ok;
		UASSERT(!mgr.predictWarmStart(nullptr, gamedef, v3s16(0, 0, 0), 1000,
				guess, status));
		UASSERT(status == nows::Status::ModelInvalid ||
				status == nows::Status::NoModel);
		UASSERT(mgr.statsCopy().model_load_failures >= 1);
	}

	// Leave the singleton in its default state for whatever runs next.
	Settings off;
	mgr.initialize(&off);
	mgr.resetStats();
}

// --- the economic gate --------------------------------------------------

/*
 * NOWS is only worth running when the solver work it removes is worth more
 * than the prediction costs. Both numbers come from the server's own history,
 * and the gate closes when the difference is not positive. This test drives
 * that decision directly: the gate is checked before the model is even
 * consulted, so it can be exercised without a map.
 */
void TestNOWS::testProfitabilityGate()
{
	nows::Manager &mgr = nows::Manager::get();

	Settings cfg;
	cfg.set("nows_enabled", "true");
	cfg.set("nows_min_queue", "1");
	cfg.set("nows_adaptive", "true");
	cfg.set("nows_min_samples", "2");
	mgr.initialize(&cfg);

	nows::WarmStart guess;
	nows::Status status = nows::Status::Ok;

	// Not enough evidence yet: the layer tries, and fails later for the
	// ordinary "no model" reason rather than being pre-emptively gated.
	mgr.resetStats();
	mgr.recordSolve(false, 1000, 100000, true, 0);
	UASSERT(!mgr.predictWarmStart(nullptr, nullptr, v3s16(0, 0, 0), 100, guess, status));
	UASSERT(status != nows::Status::Unprofitable);

	// A warm start that saves nothing is a net cost at any price: the gate
	// must refuse it even before it knows the model is unusable.
	mgr.resetStats();
	for (int i = 0; i < 4; i++) {
		mgr.recordSolve(false, 1000, 100000, true, 0);
		mgr.recordSolve(true, 1000, 100000, true, 0);
	}
	UASSERT(!mgr.predictWarmStart(nullptr, nullptr, v3s16(0, 0, 0), 100, guess, status));
	UASSERTEQ(int, (int)status, (int)nows::Status::Unprofitable);
	UASSERT(mgr.statsCopy().unprofitable_skips >= 1);

	// A warm start that removes most of the iterations passes the gate and
	// fails later for a different, unrelated reason.
	mgr.resetStats();
	for (int i = 0; i < 6; i++) {
		mgr.recordSolve(false, 1000, 100000, true, 0);
		mgr.recordSolve(true, 100, 10000, true, 0);
	}
	UASSERT(!mgr.predictWarmStart(nullptr, nullptr, v3s16(0, 0, 0), 100, guess, status));
	UASSERT(status != nows::Status::Unprofitable);

	// The reported economics follow the same arithmetic.
	const nows::Stats s = mgr.statsCopy();
	UASSERT(s.baseline_us_per_iteration() > 0.0);
	UASSERT(s.savedUsPerSolve() > s.inferenceUsPerSolve());
	UASSERT(s.netUsPerSolve() > 0.0);
	UASSERT(mgr.profitability().baseline_samples >= 2);

	Settings off;
	mgr.initialize(&off);
	mgr.resetStats();
}

// --- integration: the real solver ---------------------------------------

namespace {

struct LiquidFixture
{
	ServerMap *map = nullptr;
	content_t source = CONTENT_IGNORE;
	content_t flowing = CONTENT_IGNORE;
};

/* Registers a source/flowing pair the liquid solver can actually run on: the
 * unit test framework's water has no flowing alternative, so nothing would
 * ever spread. */
static void defineLiquidNodes(IGameDef *gamedef, content_t *source, content_t *flowing)
{
	NodeDefManager *ndef = (NodeDefManager *)gamedef->getNodeDefManager();

	ContentFeatures ff;
	ff.name = "nows_test:water_flowing";
	ff.drawtype = NDT_AIRLIKE;
	ff.param_type = CPT_LIGHT;
	ff.liquid_type = LIQUID_FLOWING;
	ff.liquid_viscosity = 3;
	ff.liquid_range = 2;
	ff.floodable = false;
	ff.walkable = false;
	*flowing = ndef->set(ff.name, std::move(ff));

	ContentFeatures sf;
	sf.name = "nows_test:water_source";
	sf.drawtype = NDT_AIRLIKE;
	sf.param_type = CPT_LIGHT;
	sf.liquid_type = LIQUID_SOURCE;
	sf.liquid_viscosity = 3;
	sf.liquid_range = 2;
	sf.liquid_renewable = true;
	sf.liquid_alternative_flowing_id = *flowing;
	sf.floodable = false;
	sf.walkable = false;
	*source = ndef->set(sf.name, std::move(sf));

	// The flowing node has to name itself as its own flowing alternative and
	// point back at the source, or the solver treats neighbours as foreign.
	ContentFeatures ff2;
	ff2.name = "nows_test:water_flowing";
	ff2.drawtype = NDT_AIRLIKE;
	ff2.param_type = CPT_LIGHT;
	ff2.liquid_type = LIQUID_FLOWING;
	ff2.liquid_viscosity = 3;
	ff2.liquid_range = 2;
	ff2.liquid_alternative_source_id = *source;
	ff2.liquid_alternative_flowing_id = *flowing;
	ff2.floodable = false;
	ff2.walkable = false;
	*flowing = ndef->set(ff2.name, std::move(ff2));
}

static void fillFixture(ServerMap *map, content_t source, content_t flowing, int variant)
{
	// Stone floor, so the water has something to sit on.
	for (s16 z = 0; z < 8; z++)
	for (s16 x = 0; x < 8; x++)
		map->setNode(v3s16(x, 0, z), MapNode(t_CONTENT_STONE));

	// A different starting problem per variant, so the comparison is not one
	// lucky configuration repeated.
	const v3s16 src_pos(2 + (variant % 4), 3 + (variant % 3), 2 + ((variant / 4) % 4));
	const v3s16 flow_pos(src_pos.X, src_pos.Y - 1, src_pos.Z);

	MapNode src(source);
	map->setNode(src_pos, src);

	MapNode flow(flowing);
	flow.param2 = (u8)(1 + (variant % 5)); // a level, no flow-down flag
	map->setNode(flow_pos, flow);
}

static UniqueQueue<v3s16> seedQueue(const v3s16 &src_pos)
{
	UniqueQueue<v3s16> queue;
	queue.push_back(v3s16(src_pos.X, src_pos.Y - 1, src_pos.Z));
	queue.push_back(src_pos);
	return queue;
}

static v3s16 sourcePosForVariant(int variant)
{
	return v3s16(2 + (variant % 4), 3 + (variant % 3), 2 + ((variant / 4) % 4));
}

/* One engine, one world, shared by the integration test and the A/B table:
 * constructing a MockServer, an EmergeManager, a ServerMap and a
 * ServerEnvironment per test is neither cheap nor something the suite does
 * anywhere else. */
struct LiquidHarness
{
	std::unique_ptr<MetricsBackend> mb;
	std::unique_ptr<MockServer> server;
	std::unique_ptr<EmergeManager> emerge;
	std::unique_ptr<ServerEnvironment> env;
	ServerMap *map = nullptr;
	content_t source = CONTENT_IGNORE;
	content_t flowing = CONTENT_IGNORE;
	bool ready = false;

	bool start(IGameDef *gamedef, const std::string &world_dir)
	{
		mb = std::make_unique<MetricsBackend>();
		server = std::make_unique<MockServer>(world_dir);
		{
			std::ofstream ofs(server->getWorldPath() + DIR_DELIM "world.mt",
					std::ios::out | std::ios::binary);
			ofs << "backend = dummy\n";
		}
		server->createScripting();
		try {
			server->getScriptIface()->loadBuiltin();
		} catch (ModError &e) {
			rawstream << "NOWS: could not start scripting: " << e.what() << std::endl;
			return false;
		}
		emerge = std::make_unique<EmergeManager>(server.get(), mb.get());
		auto smap = std::make_unique<ServerMap>(server->getWorldPath(), gamedef,
				emerge.get(), mb.get());
		map = smap.get();
		env = std::make_unique<ServerEnvironment>(std::move(smap), server.get(), mb.get());
		env->loadMeta();
		defineLiquidNodes(gamedef, &source, &flowing);
		map->emergeBlock(v3s16(0, 0, 0), true);
		ready = true;
		return true;
	}

	~LiquidHarness()
	{
		if (env)
			env->deactivateBlocksAndObjects();
	}

	std::map<v3s16, MapNode> snapshot() const
	{
		std::map<v3s16, MapNode> out;
		for (s16 z = 0; z < 8; z++)
		for (s16 y = 0; y < 6; y++)
		for (s16 x = 0; x < 8; x++)
			out[v3s16(x, y, z)] = map->getNode(v3s16(x, y, z));
		return out;
	}

	/* Nodes whose content or level differs from `want`. Two solves of the
	 * same problem that agree everywhere differ by zero. */
	static size_t differences(const std::map<v3s16, MapNode> &want,
			const std::map<v3s16, MapNode> &got)
	{
		size_t n = 0;
		for (const auto &entry : want) {
			auto it = got.find(entry.first);
			if (it == got.end()) {
				n++;
				continue;
			}
			const u8 mask = LIQUID_LEVEL_MASK | LIQUID_FLOW_DOWN_MASK;
			if (it->second.getContent() != entry.second.getContent() ||
					(it->second.param2 & mask) != (entry.second.param2 & mask))
				n++;
		}
		return n;
	}
};

struct SolveReport
{
	u32 iterations = 0;
	u32 residual = 0;
	u64 solver_us = 0;
	u64 inference_us = 0;
	bool used_nows = false;
	size_t solution_error = 0;
};

static SolveReport runSolve(ServerMap *map, ServerEnvironment *env,
		UniqueQueue<v3s16> queue, const nows::WarmStart *guess)
{
	std::map<v3s16, MapBlock *> modified;
	SolveReport rep;
	rep.used_nows = guess != nullptr;
	const u64 t0 = porting::getTimeUs();
	map->transformLiquidsLocal(modified, queue, env, 20000, guess,
			&rep.iterations, &rep.residual);
	rep.solver_us = porting::getTimeUs() - t0;
	return rep;
}

/* Warm start built from a field the plain solver already converged to. It is
 * an oracle, not a model: it is the best a perfect predictor could do, and it
 * is labelled as such wherever it is reported. */
static nows::WarmStart oracleFrom(const std::map<v3s16, MapNode> &converged,
		content_t flowing)
{
	nows::WarmStart oracle;
	oracle.origin = v3s16(0, 0, 0);
	oracle.dim[0] = oracle.dim[1] = oracle.dim[2] = 8;
	oracle.level.assign(512, (s8)-1);
	for (s16 z = 0; z < 8; z++)
	for (s16 y = 0; y < 6; y++)
	for (s16 x = 0; x < 8; x++) {
		const MapNode &n = converged.at(v3s16(x, y, z));
		if (n.getContent() == flowing)
			oracle.set(v3s16(x, y, z), (s8)(n.param2 & LIQUID_LEVEL_MASK));
	}
	return oracle;
}

/* One harness for both integration tests: a MockServer, an EmergeManager and a
 * ServerEnvironment are far too heavy to build twice. */
static LiquidHarness &sharedHarness(IGameDef *gamedef, const std::string &world_dir)
{
	static LiquidHarness harness;
	if (!harness.ready)
		harness.start(gamedef, world_dir);
	return harness;
}

} // namespace

void TestNOWS::testLiquidSolverIntegration(IGameDef *gamedef)
{
	LiquidHarness &h = sharedHarness(gamedef, getTestTempDirectory());
	if (!h.ready) {
		UTEST(false, "%s", "NOWS integration test could not start a server");
		return;
	}

	// ---- baseline: the solver exactly as the engine has always run it ----
	fillFixture(h.map, h.source, h.flowing, 0);
	UniqueQueue<v3s16> queue = seedQueue(sourcePosForVariant(0));
	const SolveReport base = runSolve(h.map, h.env.get(), queue, nullptr);
	UASSERT(base.iterations > 0);

	const std::map<v3s16, MapNode> converged = h.snapshot();

	bool any_flowing = false;
	for (const auto &entry : converged)
		if (entry.second.getContent() == h.flowing)
			any_flowing = true;
	UASSERT(any_flowing);

	// ---- the same problem, warm started from its own converged field ----
	const nows::WarmStart oracle = oracleFrom(converged, h.flowing);
	UASSERT(oracle.guessCount() > 0);

	fillFixture(h.map, h.source, h.flowing, 0);
	UniqueQueue<v3s16> q2 = seedQueue(sourcePosForVariant(0));
	const SolveReport warm = runSolve(h.map, h.env.get(), q2, &oracle);
	UASSERT(warm.iterations > 0);
	UASSERTEQ(size_t, LiquidHarness::differences(converged, h.snapshot()), (size_t)0);

	// ---- the iteration cap is honoured and reported ----
	fillFixture(h.map, h.source, h.flowing, 0);
	UniqueQueue<v3s16> q3 = seedQueue(sourcePosForVariant(0));
	std::map<v3s16, MapBlock *> modified;
	u32 capped = 0, capped_residual = 0;
	h.map->transformLiquidsLocal(modified, q3, h.env.get(), 1, nullptr, &capped,
			&capped_residual);
	UASSERTEQ(u32, capped, 1u);
	UASSERT(capped_residual > 0); // work was left, so this is not a fixed point
	UASSERT(!q3.empty());

	// ---- a warm start cannot invent water ----
	nows::WarmStart wild;
	wild.origin = v3s16(30000, 30000, 30000);
	wild.dim[0] = wild.dim[1] = wild.dim[2] = 2;
	wild.level.assign(8, 7);
	fillFixture(h.map, h.source, h.flowing, 0);
	UniqueQueue<v3s16> q4 = seedQueue(sourcePosForVariant(0));
	runSolve(h.map, h.env.get(), q4, &wild);
	UASSERTEQ(size_t, LiquidHarness::differences(converged, h.snapshot()), (size_t)0);
}

// --- the A/B experiment -------------------------------------------------
//
// Two runs of the same physical problems, one plain and one warm started,
// with every number the decision needs. The warm start used here is an
// ORACLE: the field the plain solver itself converged to. That is not a
// prediction, it is the upper bound on what any predictor could save, and it
// is labelled that way in the output. To measure a real model, point
// LUANTI_NOWS_MODEL at a .nowsm file and the third column runs it through the
// real manager, including the inference cost and the fallback paths.

void TestNOWS::testABTable(IGameDef *gamedef)
{
	LiquidHarness &h = sharedHarness(gamedef, getTestTempDirectory());
	if (!h.ready) {
		UTEST(false, "%s", "NOWS A/B test could not start a server");
		return;
	}

	nows::Manager &mgr = nows::Manager::get();

	// Optional real model. Absent, the third column stays empty rather than
	// pretending the oracle is a network.
	const char *model_env = getenv("LUANTI_NOWS_MODEL");
	std::string model_path = model_env ? model_env : "";
	u32 grid = 0;
	if (!model_path.empty()) {
		nows::ModelFile mf;
		std::string err;
		if (!nows::readModelFile(model_path, &mf, &err)) {
			rawstream << "NOWS A/B: ignoring unusable model: " << err << std::endl;
			model_path.clear();
		} else {
			grid = mf.desc.grid;
		}
	}

	Settings cfg;
	cfg.set("nows_enabled", model_path.empty() ? "false" : "true");
	cfg.set("nows_model_path", model_path);
	cfg.set("nows_allow_untrained", "true");
	cfg.set("nows_min_queue", "1");
	cfg.set("nows_cooldown", "0");
	cfg.set("nows_adaptive", "false"); // measure first, judge afterwards
	if (grid)
		cfg.set("nows_grid_size", std::to_string(grid));
	mgr.initialize(&cfg);
	mgr.resetStats();

	const int problems = 5;
	u64 sum_iters_normal = 0, sum_us_normal = 0, sum_iters_warm = 0, sum_us_warm = 0;
	u64 sum_inference_us = 0, sum_iters_model = 0, sum_us_model = 0;
	u64 sum_residual_normal = 0, sum_residual_warm = 0, sum_residual_model = 0;
	size_t sum_error_warm = 0, sum_error_model = 0;
	int model_runs = 0;

	for (int k = 0; k < problems; k++) {
		const v3s16 src_pos = sourcePosForVariant(k);

		fillFixture(h.map, h.source, h.flowing, k);
		const SolveReport normal = runSolve(h.map, h.env.get(),
				seedQueue(src_pos), nullptr);
		const std::map<v3s16, MapNode> converged = h.snapshot();
		const nows::WarmStart oracle = oracleFrom(converged, h.flowing);

		fillFixture(h.map, h.source, h.flowing, k);
		const SolveReport warm = runSolve(h.map, h.env.get(),
				seedQueue(src_pos), &oracle);
		const size_t err_warm = LiquidHarness::differences(converged, h.snapshot());

		size_t err_model = 0;
		SolveReport model_run;
		if (!model_path.empty()) {
			fillFixture(h.map, h.source, h.flowing, k);
			nows::WarmStart guess;
			nows::Status status = nows::Status::Disabled;
			const u64 t0 = porting::getTimeUs();
			const bool have = mgr.predictWarmStart(h.map, gamedef, src_pos, 64, guess,
					status);
			model_run = runSolve(h.map, h.env.get(), seedQueue(src_pos),
					have ? &guess : nullptr);
			// Inference is whatever the round trip cost beyond the solve
			// itself, so gather+model+project is all of it.
			model_run.inference_us = porting::getTimeUs() - t0 - model_run.solver_us;
			model_run.used_nows = have;
			if (have) {
				model_runs++;
				err_model = LiquidHarness::differences(converged, h.snapshot());
				sum_iters_model += model_run.iterations;
				sum_us_model += model_run.solver_us;
				sum_inference_us += model_run.inference_us;
				sum_residual_model += model_run.residual;
				sum_error_model += err_model;
			}
		}

		sum_iters_normal += normal.iterations;
		sum_us_normal += normal.solver_us;
		sum_residual_normal += normal.residual;
		sum_iters_warm += warm.iterations;
		sum_us_warm += warm.solver_us;
		sum_residual_warm += warm.residual;
		sum_error_warm += err_warm;

		rawstream << "NOWS A/B problem " << k << std::endl;
		rawstream << "  normal : iterations " << normal.iterations << ", solver "
				<< normal.solver_us << " us, residual " << normal.residual << std::endl;
		rawstream << "  oracle : iterations " << warm.iterations << ", solver "
				<< warm.solver_us << " us, residual " << warm.residual
				<< ", solution error " << err_warm << " nodes" << std::endl;
		if (!model_path.empty()) {
			rawstream << "  model  : iterations " << model_run.iterations
					<< ", inference " << model_run.inference_us << " us, solver "
					<< model_run.solver_us << " us, residual " << model_run.residual
					<< ", solution error " << err_model << " nodes"
					<< (model_run.used_nows ? "" : " (no prediction applied)") << std::endl;
		}

		// The guarantee that does not depend on which predictor was used.
		UASSERTEQ(size_t, err_warm, (size_t)0);
	}

	const double n = (double)problems;
	rawstream << "NOWS A/B totals over " << problems << " identical problems"
			<< std::endl;
	rawstream << "                     NORMAL       NOWS(oracle)";
	if (model_runs)
		rawstream << "      NOWS(model)";
	rawstream << std::endl;
	rawstream << "  solver iterations   " << (sum_iters_normal / problems) << "         "
			<< (sum_iters_warm / problems);
	if (model_runs)
		rawstream << "              " << (sum_iters_model / (u64)model_runs);
	rawstream << std::endl;
	rawstream << "  inference           --            --";
	if (model_runs)
		rawstream << "              " << (sum_inference_us / (u64)model_runs) << " us";
	rawstream << std::endl;
	rawstream << "  solver time         " << (sum_us_normal / n) << " us        "
			<< (sum_us_warm / n) << " us";
	if (model_runs)
		rawstream << "              " << (sum_us_model / (u64)model_runs) << " us";
	rawstream << std::endl;
	// Total is what the frame actually pays: solver plus, on the warm path,
	// the prediction that bought the shorter solver.
	rawstream << "  total time          " << (sum_us_normal / n) << " us        "
			<< (sum_us_warm / n) << " us";
	if (model_runs)
		rawstream << "              " << (sum_us_model / (u64)model_runs +
				sum_inference_us / (u64)model_runs) << " us";
	rawstream << std::endl;
	rawstream << "  residual work       " << sum_residual_normal << "            "
			<< sum_residual_warm;
	if (model_runs)
		rawstream << "                 " << sum_residual_model;
	rawstream << std::endl;
	rawstream << "  solution error      --            " << sum_error_warm << " nodes";
	if (model_runs)
		rawstream << "              " << sum_error_model << " nodes";
	rawstream << std::endl;

	const nows::Stats s = mgr.statsCopy();
	rawstream << "  fallbacks           --            --";
	if (model_runs)
		rawstream << "              " << s.fallbacks;
	rawstream << std::endl;

	if (model_runs) {
		// Per problem, on both sides: the model column only sums the solves
		// that actually took a prediction, so the two totals do not cover the
		// same number of problems and subtracting them directly would be a
		// difference of sums, not a saving per problem.
		const double mr = (double)model_runs;
		const double inference_per = (double)sum_inference_us / mr;
		const double solver_per = (double)sum_us_model / mr;
		const double save_per = ((double)sum_us_normal / n) - solver_per;
		const double oracle_per = ((double)sum_us_normal / n) -
				((double)sum_us_warm / n);
		rawstream << "  saving vs inference (model): solver saved " << save_per
				<< " us/problem, inference " << inference_per
				<< " us/problem, net " << (save_per - inference_per)
				<< " us/problem" << std::endl;
		rawstream << "  oracle upper bound: solver saved " << oracle_per
				<< " us/problem before any inference at all" << std::endl;
		if (save_per <= inference_per)
			rawstream << "    -> NOWS is a net cost here; nows_adaptive would switch it off"
					<< std::endl;
		else
			rawstream << "    -> NOWS pays for itself here; nows_adaptive would keep it on"
					<< std::endl;
	}
	rawstream << "  (run inside the unit-test binary on this machine; treat as a "
			"pipeline measurement, not a benchmark)" << std::endl;

	Settings off;
	mgr.initialize(&off);
	mgr.resetStats();
}

