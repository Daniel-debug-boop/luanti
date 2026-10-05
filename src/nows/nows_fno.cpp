// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#include "nows/nows_fno.h"

#include "nows/nows_fft.h"

#include <algorithm>
#include <cmath>

namespace nows {

static inline f32 gelu(f32 x)
{
	// tanh approximation, the form the reference FNO implementations use
	const f32 x3 = x * x * x;
	return 0.5f * x * (1.0f + std::tanh(0.7978845608f * (x + 0.044715f * x3)));
}

Fno3dModel::Fno3dModel(const ModelDesc &desc, std::vector<f32> lift_w,
		std::vector<f32> lift_b, std::vector<Layer> layers, std::vector<f32> proj_w,
		std::vector<f32> proj_b):
	m_desc(desc),
	m_lift_w(std::move(lift_w)),
	m_lift_b(std::move(lift_b)),
	m_layers(std::move(layers)),
	m_proj_w(std::move(proj_w)),
	m_proj_b(std::move(proj_b))
{
}

void Fno3dModel::ensureScratch() const
{
	const size_t cells = static_cast<size_t>(m_desc.grid) * m_desc.grid * m_desc.grid;
	const size_t ch = m_desc.channels;
	if (m_v.size() == ch && !m_v.empty() && m_v[0].size() == cells)
		return;

	m_v.assign(ch, std::vector<f32>(cells, 0.0f));
	m_t.assign(ch, std::vector<f32>(cells, 0.0f));
	m_spec_re.assign(ch, std::vector<f32>(cells, 0.0f));
	m_spec_im.assign(ch, std::vector<f32>(cells, 0.0f));
}

bool Fno3dModel::predict(const Field &in, Field &out, std::string *error)
{
	auto fail = [&](const std::string &msg) {
		if (error)
			*error = msg;
		return false;
	};

	const u32 g = m_desc.grid;
	const u32 cells = g * g * g;
	const u32 ch = m_desc.channels;

	Dims want;
	want.x = want.y = want.z = g;
	if (!in.dims.isCube() || in.dims.x != g) {
		return fail("input grid must be " + std::to_string(g) + "^3, got " +
				std::to_string(in.dims.x) + "x" + std::to_string(in.dims.y) + "x" +
				std::to_string(in.dims.z));
	}
	if (in.channels != m_desc.in_channels) {
		return fail("input has " + std::to_string(in.channels) + " channels, model wants " +
				std::to_string(m_desc.in_channels));
	}

	ensureScratch();

	// --- lift: mix the input channels up to the operator width -------------
	for (u32 c = 0; c < ch; c++) {
		std::vector<f32> &dst = m_v[c];
		const f32 bias = m_lift_b[c];
		// The scratch is reused between calls, so it has to be seeded here.
		// Accumulating into whatever the previous solve left behind would make
		// the result depend on how many times the model has run.
		for (u32 i = 0; i < cells; i++)
			dst[i] = bias;
		for (u32 k = 0; k < m_desc.in_channels; k++) {
			const f32 w = m_lift_w[c * m_desc.in_channels + k];
			if (w == 0.0f)
				continue;
			const f32 *src = in.data.data() + k;
			const size_t step = m_desc.in_channels;for (u32 i = 0; i < cells; i++)
			dst[i] += w * src[static_cast<size_t>(i) * step];
		}
	}

	// --- operator layers ---------------------------------------------------
	const u32 modes = m_desc.modes;
	for (const Layer &layer : m_layers) {
		// pointwise branch: t = gelu(W v + b)
		for (u32 c = 0; c < ch; c++) {
			const f32 bias = layer.pw_b[c];
			for (u32 i = 0; i < cells; i++)
				m_t[c][i] = bias;
			for (u32 k = 0; k < ch; k++) {
				const f32 w = layer.pw_w[c * ch + k];
				if (w == 0.0f)
					continue;
				const f32 *src = m_v[k].data();
				for (u32 i = 0; i < cells; i++)
					m_t[c][i] += w * src[i];
			}
			for (u32 i = 0; i < cells; i++)
				m_t[c][i] = gelu(m_t[c][i]);
		}

		// spectral branch: keep the low modes, mix channels, come back
		for (u32 c = 0; c < ch; c++) {
			std::vector<f32> &re = m_spec_re[c];
			std::vector<f32> &im = m_spec_im[c];
			std::copy(m_v[c].begin(), m_v[c].end(), re.begin());
			std::fill(im.begin(), im.end(), 0.0f);
			fft::forward3d(re, im, g, g, g);
		}

		for (u32 kx = 0; kx < modes; kx++)
		for (u32 ky = 0; ky < modes; ky++)
		for (u32 kz = 0; kz < modes; kz++) {
			const u32 mode_index = (kx * modes + ky) * modes + kz;
			// Only the non-negative frequency block: for a real field the
			// remaining modes are the conjugate mirror of this one.
			const size_t idx = (static_cast<size_t>(kx) * g + ky) * g + kz;
			for (u32 oc = 0; oc < ch; oc++) {
				f32 ar = 0.0f, ai = 0.0f;
				for (u32 ic = 0; ic < ch; ic++) {
					const size_t w = (static_cast<size_t>(mode_index) * ch + oc) * ch + ic;
					const f32 wr = layer.spec_re[w];
					const f32 wi = layer.spec_im[w];
					if (wr == 0.0f && wi == 0.0f)
						continue;
					const f32 vr = m_spec_re[ic][idx];
					const f32 vi = m_spec_im[ic][idx];
					ar += wr * vr - wi * vi;
					ai += wr * vi + wi * vr;
				}
				m_spec_re[oc][idx] = ar;
				m_spec_im[oc][idx] = ai;
			}
		}

		for (u32 c = 0; c < ch; c++) {
			fft::inverse3d(m_spec_re[c], m_spec_im[c], g, g, g);
			for (u32 i = 0; i < cells; i++)
				m_v[c][i] = gelu(m_v[c][i] + m_t[c][i] + m_spec_re[c][i]);
		}
	}

	// --- project to the output field --------------------------------------
	Dims odims;
	odims.x = odims.y = odims.z = g;
	out.resize(odims, m_desc.out_channels);
	for (u32 o = 0; o < m_desc.out_channels; o++) {
		const f32 bias = m_proj_b[o];
		f32 *dst = out.data.data() + o;
		const size_t step = m_desc.out_channels;
		for (u32 i = 0; i < cells; i++)
			dst[static_cast<size_t>(i) * step] = bias;
		for (u32 c = 0; c < ch; c++) {
			const f32 w = m_proj_w[o * ch + c];
			if (w == 0.0f)
				continue;
			const f32 *src = m_v[c].data();
			for (u32 i = 0; i < cells; i++)
				dst[static_cast<size_t>(i) * step] += w * src[i];
		}
	}

	return true;
}

/* ------------------------------------------------------------------ */
/* Backend factory                                                     */
/* ------------------------------------------------------------------ */

std::unique_ptr<Model> createFnoModel(const ModelDesc &desc, ModelFile *file,
		std::string *error)
{
	auto fail = [&](const std::string &msg) {
		if (error)
			*error = msg;
		return nullptr;
	};

	if (!file) {
		fail("no model data");
		return nullptr;
	}

	const u32 ch = desc.channels;
	const u32 m = desc.modes;

	auto take = [&](const std::string &name, size_t expect) -> const std::vector<f32> * {
		auto it = file->tensors.find(name);
		if (it == file->tensors.end()) {
			fail("model is missing tensor '" + name + "'");
			return nullptr;
		}
		if (it->second.size() != expect) {
			fail("tensor '" + name + "' has " + std::to_string(it->second.size()) +
					" values, expected " + std::to_string(expect));
			return nullptr;
		}
		return &it->second;
	};

	const std::vector<f32> *lift_w = take("lift_w", (size_t)ch * desc.in_channels);
	if (!lift_w) return nullptr;
	const std::vector<f32> *lift_b = take("lift_b", ch);
	if (!lift_b) return nullptr;

	std::vector<Fno3dModel::Layer> layers;
	layers.reserve(desc.layers);
	for (u32 i = 0; i < desc.layers; i++) {
		const std::string base = "l" + std::to_string(i);
		const size_t spec_count = (size_t)m * m * m * ch * ch;
		const std::vector<f32> *sr = take(base + "_spec_re", spec_count);
		if (!sr) return nullptr;
		const std::vector<f32> *si = take(base + "_spec_im", spec_count);
		if (!si) return nullptr;
		const std::vector<f32> *pw = take(base + "_pw_w", (size_t)ch * ch);
		if (!pw) return nullptr;
		const std::vector<f32> *pb = take(base + "_pw_b", ch);
		if (!pb) return nullptr;

		Fno3dModel::Layer layer;
		layer.spec_re = *sr;
		layer.spec_im = *si;
		layer.pw_w = *pw;
		layer.pw_b = *pb;
		layers.push_back(std::move(layer));
	}

	const std::vector<f32> *proj_w = take("proj_w", (size_t)desc.out_channels * ch);
	if (!proj_w) return nullptr;
	const std::vector<f32> *proj_b = take("proj_b", desc.out_channels);
	if (!proj_b) return nullptr;

	return std::make_unique<Fno3dModel>(desc, *lift_w, *lift_b, std::move(layers),
			*proj_w, *proj_b);
}

} // namespace nows