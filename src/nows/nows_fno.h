// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once

#include "nows/nows_model.h"

namespace nows {

/*
 * FNO3D -- the engine-native inference backend.
 *
 * Research-derived technique: the warm-start network of the NOWS family is a
 * Fourier Neural Operator: a stack of spectral convolutions mixed with
 * pointwise linear maps. The spectral part sees the low-frequency modes of
 * the field only, which is what makes the operator resolution-independent
 * and cheap enough to run inside a game step.
 *
 * Luanti implementation: a self-contained forward pass over the portable
 * weight file described in nows_model.h. No training code, no autograd, no
 * external inference runtime, no threads of its own. One instance holds
 * scratch buffers, so a model is used from one thread at a time (the server
 * thread that drives ServerMap::transformLiquids).
 */
class Fno3dModel : public Model
{
public:
	struct Layer
	{
		/* [modes^3][channels][channels], kept as separate real and imaginary
		 * parts because that is what the file format stores. */
		std::vector<f32> spec_re;
		std::vector<f32> spec_im;
		/* Pointwise branch: [channels][channels] row-major (out, in). */
		std::vector<f32> pw_w;
		std::vector<f32> pw_b;
	};

	Fno3dModel(const ModelDesc &desc, std::vector<f32> lift_w, std::vector<f32> lift_b,
			std::vector<Layer> layers, std::vector<f32> proj_w, std::vector<f32> proj_b);

	const ModelDesc &desc() const override { return m_desc; }

	bool predict(const Field &in, Field &out, std::string *error) override;

private:
	void ensureScratch() const;

	ModelDesc m_desc;
	std::vector<f32> m_lift_w, m_lift_b;
	std::vector<Layer> m_layers;
	std::vector<f32> m_proj_w, m_proj_b;

	/* Scratch, kept across calls so a solve does not reallocate megabytes. */
	mutable std::vector<std::vector<f32>> m_v;    // [channels][cells]
	mutable std::vector<std::vector<f32>> m_t;    // pointwise branch
	mutable std::vector<std::vector<f32>> m_spec_re;
	mutable std::vector<std::vector<f32>> m_spec_im;
};

} // namespace nows