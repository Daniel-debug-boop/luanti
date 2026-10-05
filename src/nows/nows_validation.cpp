// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#include "nows/nows_validation.h"

#include "nows/nows_model.h"

#include <cmath>

namespace nows {
namespace validation {

bool checkDims(const Field &field, const ModelDesc &desc, std::string *error)
{
	auto fail = [&](const std::string &msg) {
		if (error)
			*error = msg;
		return false;
	};

	if (field.empty())
		return fail("prediction is empty");
	if (field.channels != desc.out_channels)
		return fail("prediction has " + std::to_string(field.channels) +
				" output channels, model declares " + std::to_string(desc.out_channels));
	if (!field.dims.isCube() || field.dims.x != desc.grid)
		return fail("prediction grid " + std::to_string(field.dims.x) + "x" +
				std::to_string(field.dims.y) + "x" + std::to_string(field.dims.z) +
				" does not match the model's " + std::to_string(desc.grid) + "^3");
	return true;
}

bool checkFinite(const Field &field, std::string *error)
{
	for (size_t i = 0; i < field.data.size(); i++) {
		if (!std::isfinite(field.data[i])) {
			if (error) {
				*error = "prediction contains a non-finite value at index " +
						std::to_string(i);
			}
			return false;
		}
	}
	return true;
}

bool checkRange(const Field &field, u32 channel, f32 lo, f32 hi, std::string *error)
{
	if (channel >= field.channels) {
		if (error)
			*error = "prediction has no channel " + std::to_string(channel);
		return false;
	}
	const size_t cells = field.dims.count();
	for (size_t i = 0; i < cells; i++) {
		const f32 v = field.data[i * field.channels + channel];
		if (!std::isfinite(v) || v < lo || v > hi) {
			if (error) {
				*error = "prediction value " + std::to_string(v) + " at cell " +
						std::to_string(i) + " is outside [" + std::to_string(lo) + ", " +
						std::to_string(hi) + "]";
			}
			return false;
		}
	}
	return true;
}

f32 residual(const Field &pred, const Field &cur, u32 channel)
{
	if (pred.empty() || cur.empty() || pred.dims != cur.dims)
		return 0.0f;
	if (channel >= pred.channels || channel >= cur.channels)
		return 0.0f;

	const size_t cells = pred.dims.count();
	double acc = 0.0;
	for (size_t i = 0; i < cells; i++) {
		const double d = (double)pred.data[i * pred.channels + channel] -
				(double)cur.data[i * cur.channels + channel];
		acc += d * d;
	}
	return (f32)std::sqrt(acc / (double)cells);
}

bool projectMassPreserving(std::vector<s8> &predicted, const std::vector<s8> &current,
		const std::vector<u8> &applicable, s8 max_level, std::string *error)
{
	const size_t n = predicted.size();
	if (current.size() != n || applicable.size() != n) {
		if (error)
			*error = "mass projection got mismatched cell vectors";
		return false;
	}

	long cur_sum = 0, pred_sum = 0;
	for (size_t i = 0; i < n; i++) {
		if (!applicable[i])
			continue;
		if (current[i] < 0 || current[i] > max_level) {
			if (error)
				*error = "current field has an out-of-range level at cell " +
						std::to_string(i);
			return false;
		}
		// Clamp first: a level is a 3-bit field, so anything outside is a
		// prediction that cannot be represented at all.
		if (predicted[i] < 0)
			predicted[i] = 0;
		if (predicted[i] > max_level)
			predicted[i] = max_level;
		cur_sum += current[i];
		pred_sum += predicted[i];
	}

	long delta = cur_sum - pred_sum;
	if (delta == 0)
		return true;

	// Move one level at a time, deterministically, from cells that can give
	// (or take) mass towards the current total. Integer levels mean this is
	// exact when the capacity allows it, and never off by a rounding drift.
	size_t cursor = 0;
	while (delta != 0) {
		bool moved = false;
		for (size_t step = 0; step < n && delta != 0; step++) {
			const size_t i = (cursor + step) % n;
			if (!applicable[i])
				continue;
			if (delta > 0 && predicted[i] < max_level) {
				predicted[i]++;
				delta--;
				moved = true;
			} else if (delta < 0 && predicted[i] > 0) {
				predicted[i]--;
				delta++;
				moved = true;
			}
		}
		if (!moved) {
			if (error) {
				*error = "prediction cannot be balanced to the current mass "
						"(off by " + std::to_string(delta) + " level(s))";
			}
			return false;
		}
		cursor = (cursor + 1) % n;
	}

	return true;
}

} // namespace validation
} // namespace nows