// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once

#include "nows_types.h"

#include "gamedef.h"
#include "irr_v3d.h"

#include <string>
#include <vector>

class Map;

namespace nows {

/*
 * NOWSFieldAdapter -- turns a region of a numerical field into the tensor a
 * neural operator expects, and turns the model's answer back into an initial
 * guess for the solver.
 *
 * The adapter is written against reusable numerical fields (a cube of cells
 * with a fixed feature layout), not against a gameplay object, so the next
 * learned accelerator -- IRNO, DualNMG, a local neural operator -- can reuse
 * it by supplying a different gather/project pair.
 *
 * Luanti implementation: the first consumer is the voxel liquid field of
 * ServerMap::transformLiquidsLocal().
 */
struct GatheredField
{
	/* Feature tensor handed to the model: FeatureChannel values per cell. */
	Field input;
	/* World position of cell (0,0,0). */
	v3s16 origin = v3s16(0, 0, 0);
	/* Cells the warm start may influence (flowing liquid only). */
	std::vector<u8> applicable;
	/* The solver's own current level per applicable cell, -1 elsewhere. */
	std::vector<s8> current;
	/* Cells that actually carry liquid, i.e. how much there is to redistribute. */
	u32 liquid_cells = 0;
};

/* Samples a cubic region of `map` centred on `center` and fills `out`.
 * `cfg.grid_size` must be a power of two in [8,32]. */
bool gatherField(Map *map, IGameDef *gamedef, const v3s16 &center,
		const Config &cfg, GatheredField &out, std::string *error);

/* Validates `pred` against the gathered field and produces the initial-guess
 * field the solver can consume. Never writes to the map: the returned
 * WarmStart is a suggestion, and the solver decides what to do with it. */
bool projectWarmStart(const Field &pred, const GatheredField &gathered,
		const Config &cfg, WarmStart &out, std::string *error);

} // namespace nows