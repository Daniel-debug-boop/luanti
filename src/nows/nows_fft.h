// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once

#include "irrlichttypes.h"

#include <vector>

namespace nows {
namespace fft {

/*
 * Minimal separable radix-2 complex FFT, sized for the small fixed grids the
 * spectral convolution of a neural operator works on (8..32 per axis).
 *
 * This is deliberately not the engine's audio FFT (src/util/) and not a
 * general-purpose library: NOWS only needs an in-place 3D transform of a cube
 * whose edge is a power of two, a handful of times per solve.
 *
 * Forward is unnormalised, inverse is normalised by 1/(nx*ny*nz).
 */

bool isPowerOfTwo(u32 n);

/* re/im hold nx*ny*nz interleaved-by-plane values (separate arrays). */
void forward3d(std::vector<f32> &re, std::vector<f32> &im,
		u32 nx, u32 ny, u32 nz);

void inverse3d(std::vector<f32> &re, std::vector<f32> &im,
		u32 nx, u32 ny, u32 nz);

/* In-place 1D transform of n complex samples (n a power of two). */
void forward1d(std::vector<f32> &re, std::vector<f32> &im, u32 n,
		u32 stride, u32 offset);

void inverse1d(std::vector<f32> &re, std::vector<f32> &im, u32 n,
		u32 stride, u32 offset);

} // namespace fft
} // namespace nows