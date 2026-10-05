// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#include "nows/nows_field.h"

#include "constants.h"
#include "map.h"
#include "mapblock.h"
#include "mapnode.h"
#include "nodedef.h"
#include "nows/nows_model.h"
#include "nows/nows_validation.h"
#include "util/numeric.h"

#include <algorithm>
#include <cmath>

namespace nows {

static const v3s16 neighbour_dirs[6] = {
	v3s16(0, 1, 0), v3s16(0, 0, 1), v3s16(1, 0, 0),
	v3s16(0, 0, -1), v3s16(-1, 0, 0), v3s16(0, -1, 0),
};

/* All blocks a cube of `grid` cells starting at `origin` can touch. A grid of
 * at most 32 spans at most two map blocks per axis, so the eight corners of
 * the cell range cover every block. */
static bool regionIsLoaded(Map *map, const v3s16 &origin, u32 grid)
{
	for (int corner = 0; corner < 8; corner++) {
		const v3s16 cell(origin.X + ((corner & 1) ? (int)grid - 1 : 0),
				origin.Y + ((corner & 2) ? (int)grid - 1 : 0),
				origin.Z + ((corner & 4) ? (int)grid - 1 : 0));
		const MapBlock *block = map->getBlockNoCreateNoEx(getNodeBlockPos(cell));
		if (!block)
			return false;
	}
	return true;
}

bool gatherField(Map *map, IGameDef *gamedef, const v3s16 &center,
		const Config &cfg, GatheredField &out, std::string *error)
{
	auto fail = [&](const std::string &msg) {
		if (error)
			*error = msg;
		return false;
	};

	if (!map || !gamedef)
		return fail("gatherField called without a map");

	u32 grid = cfg.grid_size;
	if (grid < 8 || grid > 32 || (grid & (grid - 1)) != 0)
		return fail("nows_grid_size must be a power of two in [8,32]");

	const NodeDefManager *ndef = gamedef->getNodeDefManager();
	if (!ndef)
		return fail("no node definitions available");

	const s32 half = (s32)(grid - 1) / 2;
	// Keep the whole cube inside the coordinate range the node grid can hold.
	const s32 lo = -31000, hi = 31000;
	v3s16 origin(
		rangelim(center.X - half, lo, hi - (s32)grid + 1),
		rangelim(center.Y - half, lo, hi - (s32)grid + 1),
		rangelim(center.Z - half, lo, hi - (s32)grid + 1));

	if (!regionIsLoaded(map, origin, grid))
		return fail("warm-start region is not fully loaded");

	Dims dims;
	dims.x = dims.y = dims.z = grid;
	out.input.resize(dims, FC_COUNT);
	out.origin = origin;
	const u32 cells = grid * grid * grid;
	out.applicable.assign(cells, 0);
	out.current.assign(cells, -1);
	out.liquid_cells = 0;

	const f32 max_level = (f32)LIQUID_LEVEL_MAX;

	for (u32 z = 0; z < grid; z++)
	for (u32 y = 0; y < grid; y++)
	for (u32 x = 0; x < grid; x++) {
		const u32 cell = (x * grid + y) * grid + z;
		const v3s16 p(origin.X + (s32)x, origin.Y + (s32)y, origin.Z + (s32)z);

		bool valid = false;
		const MapNode n = map->getNode(p, &valid);
		const ContentFeatures &cf = ndef->get(n);

		const bool is_source = cf.liquid_type == LIQUID_SOURCE;
		const bool is_flowing = cf.liquid_type == LIQUID_FLOWING;
		const bool floodable = cf.liquid_type == LIQUID_NONE && cf.floodable;
		// "Blocks liquid" is exactly what the solver treats as a barrier:
		// neither liquid nor floodable.
		const bool blocks = cf.liquid_type == LIQUID_NONE && !cf.floodable;

		u8 sources = 0;
		for (int i = 0; i < 6; i++) {
			const ContentFeatures &cn = ndef->get(map->getNode(p + neighbour_dirs[i]));
			if (cn.liquid_type == LIQUID_SOURCE)
				sources++;
		}

		const s8 level = is_flowing ? (s8)(n.param2 & LIQUID_LEVEL_MASK) : (s8)-1;

		out.input.set(cell, FC_LEVEL, valid && is_flowing ? (f32)level / max_level : 0.0f);
		out.input.set(cell, FC_SOURCE, is_source ? 1.0f : 0.0f);
		out.input.set(cell, FC_FLOWING, is_flowing ? 1.0f : 0.0f);
		out.input.set(cell, FC_FLOODABLE, floodable ? 1.0f : 0.0f);
		out.input.set(cell, FC_SOLID, blocks ? 1.0f : 0.0f);
		out.input.set(cell, FC_NEIGHBOUR_SOURCES, (f32)sources / 6.0f);

		// Only flowing liquid can be moved by the relaxation, so only those
		// cells are ever candidates for a guess. Sources, air and solids are
		// left entirely to the solver.
		if (is_flowing) {
			out.applicable[cell] = 1;
			out.current[cell] = level;
			out.liquid_cells++;
		}
	}

	if (out.liquid_cells == 0) {
		if (error)
			*error = "region holds no flowing liquid to warm start";
		return false;
	}

	return true;
}

bool projectWarmStart(const Field &pred, const GatheredField &gathered,
		const Config &cfg, WarmStart &out, std::string *error)
{
	out.clear();

	std::string err;
	// The prediction has to describe the very region that was gathered:
	// same cube, and at least one channel to read the level from.
	if (pred.empty() || !pred.dims.isCube() || pred.dims != gathered.input.dims) {
		if (error)
			*error = "prediction grid does not match the gathered region";
		return false;
	}
	if (pred.channels < 1) {
		if (error)
			*error = "prediction has no channels";
		return false;
	}

	if (cfg.validation) {
		if (!validation::checkFinite(pred, error))
			return false;
		// Levels are a normalised [0,1] quantity; a model that leaves that
		// range is not describing a liquid level.
		if (!validation::checkRange(pred, 0, 0.0f, 1.0f, error))
			return false;

		// A prediction that disagrees wildly with the current field is not a
		// warm start, it is a different simulation.
		const u32 rcells = pred.dims.count();
		double acc = 0.0;
		for (u32 i = 0; i < rcells; i++) {
			const double d = (double)pred.at(i, 0) -
					(double)gathered.input.at(i, FC_LEVEL);
			acc += d * d;
		}
		const f32 res = (f32)std::sqrt(acc / (double)rcells);
		if (res > cfg.max_residual) {
			if (error)
				*error = "prediction residual " + std::to_string(res) +
						" exceeds nows_max_residual";
			return false;
		}
	}

	const u32 cells = gathered.input.dims.count();
	std::vector<s8> predicted(cells, -1);
	for (u32 i = 0; i < cells; i++) {
		if (!gathered.applicable[i])
			continue;
		const f32 v = pred.at(i, 0);
		const f32 scaled = std::round(v * (f32)LIQUID_LEVEL_MAX);
		predicted[i] = (s8)rangelim((s32)scaled, 0, (s32)LIQUID_LEVEL_MAX);
	}

	if (!validation::projectMassPreserving(predicted, gathered.current,
			gathered.applicable, (s8)LIQUID_LEVEL_MAX, error))
		return false;

	// Only publish guesses that actually differ from what the solver already
	// has: an identical initial level is noise in the diff, not an acceleration.
	out.origin = gathered.origin;
	out.dim[0] = gathered.input.dims.x;
	out.dim[1] = gathered.input.dims.y;
	out.dim[2] = gathered.input.dims.z;
	out.level.assign(cells, (s8)-1);
	u32 applied = 0;
	for (u32 i = 0; i < cells; i++) {
		if (!gathered.applicable[i] || predicted[i] < 0)
			continue;
		if (predicted[i] == gathered.current[i])
			continue;
		const u32 x = i / (gathered.input.dims.y * gathered.input.dims.z);
		const u32 y = (i / gathered.input.dims.z) % gathered.input.dims.y;
		const u32 z = i % gathered.input.dims.z;
		const v3s16 p(out.origin.X + (s32)x, out.origin.Y + (s32)y, out.origin.Z + (s32)z);
		out.set(p, predicted[i]);
		applied++;
	}

	if (applied == 0) {
		if (error)
			*error = "prediction matches the current field; nothing to warm start";
		return false;
	}

	if (applied > cfg.max_region_nodes) {
		if (error)
			*error = "warm start would touch " + std::to_string(applied) +
					" cells, over nows_max_region_nodes";
		return false;
	}

	return true;
}

} // namespace nows