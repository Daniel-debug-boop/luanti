// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#include "nows/nows_model.h"

#include "constants.h"
#include "irrlichttypes.h"
#include "log.h"
#include "nows/nows_fft.h"

#include <cerrno>
#include <cstring>
#include <fstream>
#include <sstream>

namespace nows {

const char *statusName(Status status)
{
	switch (status) {
	case Status::Ok: return "ok";
	case Status::Disabled: return "disabled";
	case Status::NoModel: return "no-model";
	case Status::ModelInvalid: return "model-invalid";
	case Status::Untrained: return "untrained-model";
	case Status::Incompatible: return "incompatible";
	case Status::TooSmallQueue: return "queue-too-small";
	case Status::NoRegion: return "no-region";
	case Status::PredictionInvalid: return "prediction-invalid";
	case Status::ResidualTooHigh: return "residual-too-high";
	case Status::Cooldown: return "cooldown";
	case Status::BudgetExceeded: return "budget-exceeded";
	case Status::Unprofitable: return "unprofitable";
	}
	return "unknown";
}

/* ------------------------------------------------------------------ */
/* Little-endian primitives. Explicit, so a weight file written on one */
/* host loads on another without depending on the host byte order.    */
/* ------------------------------------------------------------------ */

static void putU32(std::ostream &os, u32 v)
{
	const unsigned char b[4] = {
		(unsigned char)(v & 0xFF),
		(unsigned char)((v >> 8) & 0xFF),
		(unsigned char)((v >> 16) & 0xFF),
		(unsigned char)((v >> 24) & 0xFF),
	};
	os.write((const char *)b, 4);
}

static bool getU32(std::istream &is, u32 *out)
{
	unsigned char b[4];
	is.read((char *)b, 4);
	if (!is.good())
		return false;
	*out = (u32)b[0] | ((u32)b[1] << 8) | ((u32)b[2] << 16) | ((u32)b[3] << 24);
	return true;
}

static void putF32(std::ostream &os, f32 v)
{
	u32 bits;
	static_assert(sizeof(bits) == sizeof(v), "unexpected f32 width");
	std::memcpy(&bits, &v, sizeof(bits));
	putU32(os, bits);
}

static bool getF32(std::istream &is, f32 *out)
{
	u32 bits;
	if (!getU32(is, &bits))
		return false;
	std::memcpy(out, &bits, sizeof(*out));
	return true;
}

static const char NOWS_MAGIC[8] = {'N', 'O', 'W', 'S', 'M', 'D', 'L', '\0'};
static const u32 NOWS_FILE_VERSION = 1;

/* ------------------------------------------------------------------ */

bool validateDesc(const ModelDesc &desc, std::string *error)
{
	auto fail = [&](const std::string &msg) {
		if (error)
			*error = msg;
		return false;
	};

	if (desc.arch.empty())
		return fail("model has no arch tag");
	if (desc.grid == 0 || desc.grid > 32 || !fft::isPowerOfTwo(desc.grid))
		return fail("grid edge must be a power of two in [1,32]");
	if (desc.channels == 0 || desc.channels > 64)
		return fail("channel count out of range");
	if (desc.layers == 0 || desc.layers > 16)
		return fail("layer count out of range");
	if (desc.modes == 0 || desc.modes > desc.grid / 2 + 1)
		return fail("spectral mode count out of range");
	if (desc.in_channels == 0 || desc.in_channels > 64)
		return fail("input channel count out of range");
	if (desc.out_channels == 0 || desc.out_channels > 8)
		return fail("output channel count out of range");
	return true;
}

bool writeModelFile(const std::string &path, const ModelDesc &desc,
		const std::vector<std::pair<std::string, std::vector<f32>>> &tensors,
		std::string *error)
{
	if (!validateDesc(desc, error))
		return false;

	std::ofstream os(path, std::ios::out | std::ios::binary | std::ios::trunc);
	if (!os.good()) {
		if (error)
			*error = "cannot open " + path + " for writing (" + std::strerror(errno) + ")";
		return false;
	}

	os.write(NOWS_MAGIC, 8);
	putU32(os, NOWS_FILE_VERSION);

	std::ostringstream header;
	header << "arch=" << desc.arch << "\n"
		<< "name=" << desc.name << "\n"
		<< "note=" << desc.note << "\n"
		<< "trained=" << (desc.trained ? 1 : 0) << "\n"
		<< "grid=" << desc.grid << "\n"
		<< "channels=" << desc.channels << "\n"
		<< "modes=" << desc.modes << "\n"
		<< "layers=" << desc.layers << "\n"
		<< "in_channels=" << desc.in_channels << "\n"
		<< "out_channels=" << desc.out_channels << "\n";
	const std::string h = header.str();
	putU32(os, (u32)h.size());
	os.write(h.data(), (std::streamsize)h.size());

	putU32(os, (u32)tensors.size());
	for (const auto &t : tensors) {
		putU32(os, (u32)t.first.size());
		os.write(t.first.data(), (std::streamsize)t.first.size());
		putU32(os, (u32)t.second.size());
		for (f32 v : t.second)
			putF32(os, v);
	}

	os.flush();
	if (!os.good()) {
		if (error)
			*error = "write error on " + path;
		return false;
	}
	return true;
}

bool readModelFile(const std::string &path, ModelFile *out, std::string *error)
{
	auto fail = [&](const std::string &msg) {
		if (error)
			*error = msg;
		return false;
	};

	std::ifstream is(path, std::ios::in | std::ios::binary);
	if (!is.good())
		return fail("cannot open model file " + path);

	char magic[8] = {};
	is.read(magic, 8);
	if (!is.good() || std::memcmp(magic, NOWS_MAGIC, 8) != 0)
		return fail("not a NOWS model file (bad magic): " + path);

	u32 version = 0;
	if (!getU32(is, &version))
		return fail("truncated model header: " + path);
	if (version != NOWS_FILE_VERSION)
		return fail("unsupported NOWS model format version " + std::to_string(version));

	u32 header_len = 0;
	if (!getU32(is, &header_len))
		return fail("truncated model header: " + path);
	// A header is a few hundred bytes at most. Anything larger is a corrupt
	// or hostile file, and reading it into memory would be the next line.
	if (header_len == 0 || header_len > 64 * 1024)
		return fail("implausible model header length in " + path);

	std::string header(header_len, '\0');
	is.read(&header[0], (std::streamsize)header_len);
	if (!is.good())
		return fail("truncated model header: " + path);

	ModelDesc desc;
	std::istringstream hs(header);
	std::string line;
	while (std::getline(hs, line)) {
		if (line.empty())
			continue;
		const size_t eq = line.find('=');
		if (eq == std::string::npos)
			continue;
		const std::string key = line.substr(0, eq);
		const std::string val = line.substr(eq + 1);
		if (key == "arch") desc.arch = val;
		else if (key == "name") desc.name = val;
		else if (key == "note") desc.note = val;
		else if (key == "trained") desc.trained = (val == "1");
		else if (key == "grid") desc.grid = (u32)std::stoul(val);
		else if (key == "channels") desc.channels = (u32)std::stoul(val);
		else if (key == "modes") desc.modes = (u32)std::stoul(val);
		else if (key == "layers") desc.layers = (u32)std::stoul(val);
		else if (key == "in_channels") desc.in_channels = (u32)std::stoul(val);
		else if (key == "out_channels") desc.out_channels = (u32)std::stoul(val);
	}

	desc.file_version = version;
	if (!validateDesc(desc, error))
		return false;

	u32 tensor_count = 0;
	if (!getU32(is, &tensor_count))
		return fail("truncated tensor table: " + path);
	if (tensor_count == 0 || tensor_count > 4096)
		return fail("implausible tensor count in " + path);

	ModelFile file;
	file.desc = desc;
	for (u32 t = 0; t < tensor_count; t++) {
		u32 name_len = 0;
		if (!getU32(is, &name_len))
			return fail("truncated tensor name: " + path);
		if (name_len == 0 || name_len > 256)
			return fail("implausible tensor name length in " + path);
		std::string name(name_len, '\0');
		is.read(&name[0], (std::streamsize)name_len);
		if (!is.good())
			return fail("truncated tensor name: " + path);

		u32 count = 0;
		if (!getU32(is, &count))
			return fail("truncated tensor body: " + path);
		// Hard ceiling: the largest tensor a 32^3 FNO3D with 32 modes and
		// 64 channels needs is on the order of 2^27 floats.
		if (count > (1u << 28))
			return fail("implausible tensor size in " + path);

		std::vector<f32> data(count);
		for (u32 i = 0; i < count; i++) {
			if (!getF32(is, &data[i]))
				return fail("truncated tensor data: " + path);
			if (!std::isfinite(data[i]))
				return fail("non-finite weight in tensor '" + name + "' of " + path);
		}
		file.tensors[name] = std::move(data);
	}

	*out = std::move(file);
	return true;
}

std::unique_ptr<Model> loadModelFile(const std::string &path, bool allow_untrained,
		std::string *error)
{
	auto fail = [&](const std::string &msg) {
		if (error)
			*error = msg;
		return nullptr;
	};

	if (path.empty())
		return fail("no NOWS model configured");

	ModelFile file;
	if (!readModelFile(path, &file, error))
		return nullptr;

	if (!file.desc.trained && !allow_untrained) {
		if (error) {
			*error = "model '" + path + "' is marked trained=0 (" + file.desc.note +
					"); set nows_allow_untrained to use it";
		}
		return nullptr;
	}

	if (file.desc.arch == "fno3d")
		return createFnoModel(file.desc, &file, error);

	return fail("unsupported NOWS model architecture '" + file.desc.arch +
			"' in " + path);
}

} // namespace nows