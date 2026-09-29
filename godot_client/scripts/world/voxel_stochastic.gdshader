// Stochastic triplanar voxel material.
//
// DERIVED FROM: acegiak/Godot4TerrainShader (Terrain.gdshader)
//   https://github.com/acegiak/Godot4TerrainShader
//   Apache License 2.0 — see addons/terrain-shader/LICENSE
//   itself based on /u/Rotoscope's stochastic sampling shader for Unity
//
// Modified from the upstream version in two ways, both required by this
// project's chunked voxel renderer:
//
//  1. Projection is sampled in WORLD space, not object space. Upstream uses
//     VERTEX, which for us is chunk-local, so the texture would visibly reset
//     at every 16-node chunk border. World space keeps the projection
//     continuous across the whole world.
//
//  2. The mesher's baked per-vertex colour (daylight x face shade x ambient
//     occlusion) is multiplied into ALBEDO, and the detail UV2 set drives a
//     second, finer sample. Upstream has no such channel.
//
// The stochastic_sample() and triplanar_texture() functions are upstream's,
// unchanged: they jitter each sample by a hash of its cell so the repeating
// grid pattern of a tiled texture is broken up.

shader_type spatial;

uniform float uv_scale : hint_range(0.01, 4.0) = 0.25;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 albedo_tint : source_color = vec4(1.0);

// Detail layer: sampled from UV2, which the mesher tiles DETAIL_UV_SCALE times
// per block, so it breaks up the base surface without changing its tiling.
uniform float detail_strength : hint_range(0.0, 1.0) = 0.35;
uniform sampler2D detail_tex : source_color, filter_linear_mipmap, repeat_enable;

// How much finer than the base the detail layer tiles. Must match
// MaterialLibrary.DETAIL_UV_SCALE, which is what the mesher uses for UV2.
const float DETAIL_SCALE = 4.0;

uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform sampler2D normal_tex : filter_linear_mipmap, repeat_enable;

uniform sampler2D arm_tex : filter_linear_mipmap, repeat_enable;
uniform bool use_arm = true;
uniform float roughness_override : hint_range(-1.0, 1.0) = -1.0;
uniform float metallic_override : hint_range(0.0, 1.0) = -1.0;

varying vec3 power_normal;
varying vec3 triplanar_pos;
varying vec3 vertex_tint;
varying vec2 detail_uv;

vec2 hash(vec2 p) {
	return fract(sin(p * mat2(vec2(127.1, 311.7), vec2(269.5, 183.3))) * 43758.5453);
}

void vertex() {
	// The mesher bakes daylight, face shading and ambient occlusion into
	// vertex colour; carry it through to tint the photo albedo.
	vertex_tint = COLOR.rgb;

	// Triplanar weights: pow(abs(n), 10) concentrates the projection onto the
	// dominant axis, so a flat top is sampled from Y and a wall face from X/Z.
	power_normal = normalize(pow(abs(NORMAL), vec3(10.0, 10.0, 10.0)));
	triplanar_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz * vec3(1.0, -1.0, 1.0);
	detail_uv = UV2;
}

// Upstream's stochastic_sample(), unchanged. Samples the texture with a hash
// offset per cell so identical UVs across neighbouring blocks do not land on
// the same texel, which is what hides the repeating pattern.
vec4 stochastic_sample(sampler2D tex, vec2 uv) {
	vec2 skewV = mat2(vec2(1.0, 1.0), vec2(-0.57735027, 1.15470054)) * uv * 3.464;

	vec2 vxID = floor(skewV);
	vec2 fracV = fract(skewV);
	vec3 barry = vec3(fracV.x, fracV.y, 1.0 - fracV.x - fracV.y);

	mat4 bw_vx = barry.z > 0.0 ?
		mat4(vec4(vxID, 0.0, 0.0), vec4((vxID + vec2(0.0, 1.0)), 0.0, 0.0),
			vec4(vxID + vec2(1.0, 0.0), 0, 0), vec4(barry.zyx, 0)) :
		mat4(vec4(vxID + vec2(1.0, 1.0), 0.0, 0.0),
			vec4((vxID + vec2(1.0, 0.0)), 0.0, 0.0),
			vec4(vxID + vec2(0.0, 1.0), 0, 0),
			vec4(-barry.z, 1.0 - barry.y, 1.0 - barry.x, 0));

	vec2 ddx = dFdx(uv);
	vec2 ddy = dFdy(uv);

	return (textureGrad(tex, uv + hash(bw_vx[0].xy), ddx, ddy) * bw_vx[3].x) +
		(textureGrad(tex, uv + hash(bw_vx[1].xy), ddx, ddy) * bw_vx[3].y) +
		(textureGrad(tex, uv + hash(bw_vx[2].xy), ddx, ddy) * bw_vx[3].z);
}

vec4 triplanar_texture(sampler2D p_sampler, vec3 p_weights,
		vec3 p_triplanar_pos, float scale, vec2 uv_offset) {
	vec4 samp = vec4(0.0);
	vec2 s = vec2(scale, scale);
	samp += stochastic_sample(p_sampler, p_triplanar_pos.xy * s + uv_offset)
		* p_weights.z;
	samp += stochastic_sample(p_sampler, p_triplanar_pos.xz * s + uv_offset)
		* p_weights.y;
	samp += stochastic_sample(p_sampler, p_triplanar_pos.zy * vec2(-1.0, 1.0) * s
		+ uv_offset) * p_weights.x;
	return samp;
}

void fragment() {
	vec3 base = triplanar_texture(albedo_tex, power_normal, triplanar_pos,
		uv_scale, vec2(0.0)).rgb * albedo_tint.rgb;
	if (detail_strength > 0.0) {
		// The detail layer is sampled from UV2, which the mesher tiles finer
		// than UV1, and blended in triplanar space so it wraps a cliff face
		// as cleanly as the base.
		vec3 dpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz * vec3(1.0, -1.0, 1.0);
		vec3 d = triplanar_texture(detail_tex, power_normal, dpos,
			uv_scale * DETAIL_SCALE, detail_uv).rgb;
		base = mix(base, base * d * 2.0, detail_strength);
	}

	ALBEDO = base * vertex_tint;

	if (normal_strength > 0.0) {
		vec3 npos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz * vec3(1.0, -1.0, 1.0);
		vec3 n = triplanar_texture(normal_tex, power_normal, npos, uv_scale,
			vec2(0.0)).rgb * 2.0 - 1.0;
		NORMAL_MAP = vec3(n.xy, normal_strength);
		NORMAL_MAP_DEPTH = 1.0;
	}

	// The ARM map packs occlusion in R, roughness in G, metalness in B. The
	// overrides win where set, so a translucent block can be forced to a
	// fixed finish (water, ice) instead of reading its roughness off the map.
	if (use_arm) {
		vec3 apos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz * vec3(1.0, -1.0, 1.0);
		vec3 arm = triplanar_texture(arm_tex, power_normal, apos, uv_scale,
			vec2(0.0)).rgb;
		ROUGHNESS = roughness_override >= 0.0 ? roughness_override : arm.g;
		METALLIC = metallic_override >= 0.0 ? metallic_override : arm.b;
		AO = arm.r;
		AO_LIGHT_AFFECT = 0.4;
	} else {
		ROUGHNESS = roughness_override >= 0.0 ? roughness_override : 0.9;
		METALLIC = metallic_override >= 0.0 ? metallic_override : 0.0;
	}
}
