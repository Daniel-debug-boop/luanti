// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once

#include "nows_types.h"

#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace nows {

/*
 * A model is a pure function from a dense feature field to a dense predicted
 * field. It never touches the world: it cannot, because it only sees numbers.
 * That is what makes it impossible for the network to become the authority
 * for any simulation state -- the solver still has to accept the result.
 */
struct ModelDesc
{
	/* Format version of the weight file this description came from. */
	u32 file_version = 1;
	/* Architecture tag. "fno3d" is the only one implemented today; the loader
	 * is arch-tagged so IRNO/DualNMG/local-NN backends can register later
	 * without changing the call sites. */
	std::string arch = "fno3d";
	std::string name = "unnamed";
	/* Human-readable note, e.g. "UNTRAINED development placeholder". */
	std::string note;

	/* All three are cubes with a power-of-two edge (FNO3D). */
	u32 grid = 0;
	u32 channels = 0;
	u32 modes = 0;
	u32 layers = 0;
	u32 in_channels = 0;
	u32 out_channels = 0;

	/* False for a development/placeholder weight file. Loading one requires
	 * an explicit opt-in, so a placeholder can never silently become the
	 * engine's default path. */
	bool trained = false;
};

class Model
{
public:
	virtual ~Model() = default;

	virtual const ModelDesc &desc() const = 0;

	/* Pure inference. `in` must be desc().grid^3 cells with
	 * desc().in_channels channels; `out` receives desc().out_channels
	 * channels. Returns false and fills `error` on a shape mismatch. */
	virtual bool predict(const Field &in, Field &out, std::string *error) = 0;
};

/* ------------------------------------------------------------------ */
/* Portable weight file (.nowsm)                                       */
/*                                                                     */
/*   "NOWSMDL\0"           8 bytes, magic                              */
/*   u32                   format version (1), little endian          */
/*   u32                   header length in bytes                      */
/*   char[header_length]   ASCII "key=value\n" lines                   */
/*   u32                   tensor count                                */
/*   per tensor:                                                     */
/*     u32                 name length                                  */
/*     char[name_length]    tensor name                                  */
/*     u32                 element count                                */
/*     f32[element_count]  values, IEEE-754 little endian               */
/*                                                                     */
/* Keys: arch, name, note, trained, grid, channels, modes, layers,      */
/*       in_channels, out_channels                                       */
/*                                                                     */
/* Little endian and raw IEEE-754 keep the file host independent, which  */
/* is what lets a model be trained/exported offline (any framework) and  */
/* shipped as a data file. See src/nows/README.md.                       */
/* ------------------------------------------------------------------ */

struct ModelFile
{
	ModelDesc desc;
	std::map<std::string, std::vector<f32>> tensors;
};

bool readModelFile(const std::string &path, ModelFile *out, std::string *error);

bool writeModelFile(const std::string &path, const ModelDesc &desc,
		const std::vector<std::pair<std::string, std::vector<f32>>> &tensors,
		std::string *error);

/* Reads and validates the weight file, then instantiates the backend named
 * by its arch tag. Returns nullptr and sets `error` on any problem. */
std::unique_ptr<Model> loadModelFile(const std::string &path, bool allow_untrained,
		std::string *error);

/* Backend factory. Implemented in nows_fno.cpp; kept separate so that a
 * second architecture only has to add one branch here. */
std::unique_ptr<Model> createFnoModel(const ModelDesc &desc, ModelFile *file,
		std::string *error);

/* Structural validation of the description itself (power-of-two grid, sane
 * channel counts, at least one layer, ...). */
bool validateDesc(const ModelDesc &desc, std::string *error);

} // namespace nows