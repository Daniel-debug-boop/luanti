// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once

#include "nows_types.h"

#include <string>
#include <vector>

namespace nows {

struct ModelDesc;

/*
 * Everything the adapter checks before a prediction is allowed anywhere near
 * the solver. All of it is pure arithmetic over the field tensors, so it is
 * unit-testable without a map, a server or a rendering device.
 *
 * The checks are intentionally blunt: a prediction either describes the grid
 * the model was built for, contains only finite numbers in the range the
 * physical field allows, stays close enough to the current state to be a
 * plausible initial guess, and conserves the field's total mass. Anything
 * else is discarded and the solver runs normally.
 */
namespace validation {

/* Grid is a cube of the model's edge, with the model's input channel count. */
bool checkDims(const Field &field, const ModelDesc &desc, std::string *error);

/* No NaN, no +-Inf, anywhere in the tensor. */
bool checkFinite(const Field &field, std::string *error);

/* Every value of `channel` lies in [lo, hi]. */
bool checkRange(const Field &field, u32 channel, f32 lo, f32 hi, std::string *error);

/* RMS deviation between the prediction's `channel` and the current field's
 * `channel`, over the cells both share. 0 if the shapes differ. */
f32 residual(const Field &pred, const Field &cur, u32 channel);

/* Turns a continuous prediction into integer levels and makes the total match
 * the current total exactly.
 *
 * `predicted`, `current` and `applicable` are parallel per-cell vectors;
 * entries where `applicable` is 0 are left untouched. Levels are clamped to
 * [0, max_level] first. If the clamped prediction cannot be balanced back to
 * the current mass (the region has no cells left to move mass through) the
 * prediction is rejected -- a warm start that changes how much liquid exists
 * would be writing physics state, not suggesting an initial guess.
 *
 * Returns false and fills `error` when balancing is impossible. */
bool projectMassPreserving(std::vector<s8> &predicted, const std::vector<s8> &current,
		const std::vector<u8> &applicable, s8 max_level, std::string *error);

} // namespace validation
} // namespace nows