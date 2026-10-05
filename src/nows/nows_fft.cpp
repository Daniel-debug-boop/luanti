// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#include "nows/nows_fft.h"

#include <cmath>

namespace nows {
namespace fft {

/* Spelled out rather than taken from <cmath> so the behaviour does not depend
 * on M_PI being defined on this platform. */
static constexpr f32 NOWS_PI = 3.14159265358979323846f;

bool isPowerOfTwo(u32 n)
{
	return n != 0 && (n & (n - 1)) == 0;
}

void forward1d(std::vector<f32> &re, std::vector<f32> &im, u32 n,
		u32 stride, u32 offset)
{
	if (!isPowerOfTwo(n) || n < 2)
		return;

	for (u32 len = 2; len <= n; len <<= 1) {
		const f32 ang = -2.0f * NOWS_PI / (f32)len;
		const f32 wr = std::cos(ang);
		const f32 wi = std::sin(ang);
		const u32 half = len >> 1;
		for (u32 i = 0; i < n; i += len) {
			f32 cr = 1.0f, ci = 0.0f;
			for (u32 k = 0; k < half; k++) {
				const u32 a = offset + (i + k) * stride;
				const u32 b = offset + (i + k + half) * stride;
				const f32 br = re[b], bi = im[b];
				const f32 tr = br * cr - bi * ci;
				const f32 ti = br * ci + bi * cr;
				re[b] = re[a] - tr;
				im[b] = im[a] - ti;
				re[a] += tr;
				im[a] += ti;
				// Rotate the twiddle factor once per butterfly.
				const f32 nr = cr * wr - ci * wi;
				ci = cr * wi + ci * wr;
				cr = nr;
			}
		}
	}
}

void inverse1d(std::vector<f32> &re, std::vector<f32> &im, u32 n,
		u32 stride, u32 offset)
{
	if (!isPowerOfTwo(n) || n < 2)
		return;

	for (u32 i = 0; i < n; i++) {
		const u32 k = offset + i * stride;
		im[k] = -im[k];
	}
	forward1d(re, im, n, stride, offset);
	const f32 inv = 1.0f / (f32)n;
	for (u32 i = 0; i < n; i++) {
		const u32 k = offset + i * stride;
		re[k] *= inv;
		im[k] *= -inv;
	}
}

void forward3d(std::vector<f32> &re, std::vector<f32> &im,
		u32 nx, u32 ny, u32 nz)
{
	// x lines: stride 1
	for (u32 z = 0; z < nz; z++)
	for (u32 y = 0; y < ny; y++)
		forward1d(re, im, nx, 1, (z * ny + y) * nx);
	// y lines: stride nx
	for (u32 z = 0; z < nz; z++)
	for (u32 x = 0; x < nx; x++)
		forward1d(re, im, ny, nx, (z * ny) * nx + x);
	// z lines: stride nx*ny
	for (u32 y = 0; y < ny; y++)
	for (u32 x = 0; x < nx; x++)
		forward1d(re, im, nz, nx * ny, y * nx + x);
}

void inverse3d(std::vector<f32> &re, std::vector<f32> &im,
		u32 nx, u32 ny, u32 nz)
{
	forward3d(re, im, nx, ny, nz);
	const f32 inv = 1.0f / (f32)(nx * ny * nz);
	for (size_t i = 0; i < re.size(); i++) {
		re[i] *= inv;
		im[i] *= -inv;
	}
}

} // namespace fft
} // namespace nows