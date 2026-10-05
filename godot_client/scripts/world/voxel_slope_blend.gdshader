// Slope-blended voxel material.
//
// Two texture sets on one material, chosen by how steep the face is: the TOP
// set (grass, sand, snow -- whatever covers level ground) on faces pointing up,
// the SIDE set (rock, cliff face) on faces standing vertically. A voxel block
// is one block id but three visually different surfaces, and this is what makes
// a grass block read as grass on top and dirt/rock at the sides without the
// mesher having to assign separate materials per face.
//
// The projection and stochastic sampling are the same as
// voxel_stochastic.gdshader's, and for the same reasons: sampled in WORLD space
// so a texture never resets at a 16-node chunk border, and hash-jittered per
// cell so the tiling grid is broken up. The stochastic functions are shared
// verbatim with that shader (both are upstream's, from
// acegiak/Godot4TerrainShader, Apache 2.0 -- see addons/terrain-shader/LICENSE).
//
// THE SLOPE RULE
//
// `slope_factor` is a smoothstep of the face normal's Y against
// `slope_threshold` (0.7 by default, per the rendering specification). Signed,
// not absolute: only an *upward* face gets ground cover. A cave ceiling has a
// normal of -1 and correctly stays rock, where abs() would have carpeted it in
// grass.
//
// The smoothstep width is not cosmetic. The mesher bakes per-vertex face
// shading, and Surface Nets produces smoothly varying normals, so a hard
// comparator would draw a visible hard edge crawling across a slope as the
// normal crosses the threshold. The band turns that into a gradient that lands
// over roughly 8 degrees of slope.

shader_type spatial;

uniform float slope_threshold : hint_range(0.0, 1.0) = 0.7;
uniform float slope_blend : hint_range(0.001, 0.5) = 0.1;

uniform float uv_scale : hint_range(0.01, 4.0) = 1.0;
uniform vec4 albedo_tint : source_color = vec4(1.0);

// The two ends of the blend. `top_*` covers level ground, `side_*` the walls.
uniform sampler2D top_albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D side_albedo_tex : source_color, filter_linear_mipmap, repeat_enable;

uniform sampler2D top_normal_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D side_normal_tex : filter_linear_mipmap, repeat_enable;

uniform sampler2D top_arm_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D side_arm_tex : filter_linear_mipmap, repeat_enable;

// Detail layer: sampled from UV2, which the mesher tiles DETAIL_UV_SCALE times
// per block, so it breaks up the base surface without changing its tiling.
uniform float detail_strength : hint_range(0.0, 1.0) = 0.35;
uniform sampler2D top_detail_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D side_detail_tex : source_color, filter_linear_mipmap, repeat_enable;

// How much finer than the base the detail layer tiles. Must match
// MaterialLibrary.DETAIL_UV_SCALE, which is what the mesher uses for UV2.
const float DETAIL_SCALE = 4.0;

uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform bool use_arm = true;
uniform float roughness_override : hint_range(-1.0, 1.0) = -1.0;
uniform float metallic_override : hint_range(0.0, 1.0) = -1.0;

varying vec3 power_normal;
varying vec3 triplanar_pos;
varying vec3 vertex_tint;
varying vec2 detail_uv;
// 0 on a wall, 1 on level ground, smooth in between. Interpolated across the
// face like any other varying.
varying float slope_factor;

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

	// Chunk instances are translated, never rotated or scaled, so the
	// object-space normal is already the world-space normal.
	slope_factor = smoothstep(slope_threshold - slope_blend,
		slope_threshold + slope_blend, NORMAL.y);
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

// One texture set, resolved for this fragment: the base sample from all three
// projection axes, plus the detail overlay if one is bound. Both ends of the
// slope blend go through this, so the two sides cannot drift apart in how they
// are projected or detailed.
vec3 set_albedo(sampler2D base_tex, sampler2D detail_tex, vec3 pos,
		vec2 duv) {
	vec3 c = triplanar_texture(base_tex, power_normal, pos, uv_scale,
		vec2(0.0)).rgb;
	if (detail_strength > 0.0) {
		vec3 d = triplanar_texture(detail_tex, power_normal, pos,
			uv_scale * DETAIL_SCALE, duv).rgb;
		c = mix(c, c * d * 2.0, detail_strength);
	}
	return c;
}

void fragment() {
	vec3 pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz * vec3(1.0, -1.0, 1.0);

	// The blend itself. Everything that differs between the two sets --
	// albedo, normal, roughness -- is resolved the same way, so a fragment
	// halfway up a slope is halfway between grass and rock in all of them
	// rather than a grass texture lit like rock.
	vec3 top_albedo = set_albedo(top_albedo_tex, top_detail_tex, pos, detail_uv);
	vec3 side_albedo = set_albedo(side_albedo_tex, side_detail_tex, pos,
		detail_uv);
	ALBEDO = mix(side_albedo, top_albedo, slope_factor) * albedo_tint.rgb
		* vertex_tint;

	if (normal_strength > 0.0) {
		vec3 nt = triplanar_texture(top_normal_tex, power_normal, pos, uv_scale,
			vec2(0.0)).rgb * 2.0 - 1.0;
		vec3 ns = triplanar_texture(side_normal_tex, power_normal, pos, uv_scale,
			vec2(0.0)).rgb * 2.0 - 1.0;
		vec3 n = normalize(mix(ns, nt, slope_factor));
		NORMAL_MAP = vec3(n.xy, normal_strength);
		NORMAL_MAP_DEPTH = 1.0;
	}

	// The ARM map packs occlusion in R, roughness in G, metalness in B. The
	// overrides win where set, so a translucent block can be forced to a
	// fixed finish instead of reading one off the blended maps -- which would
	// otherwise hand a glass pane the roughness of whichever set its slope
	// happened to be nearer.
	if (use_arm) {
		vec3 at = triplanar_texture(top_arm_tex, power_normal, pos, uv_scale,
			vec2(0.0)).rgb;
		vec3 as = triplanar_texture(side_arm_tex, power_normal, pos, uv_scale,
			vec2(0.0)).rgb;
		vec3 arm = mix(as, at, slope_factor);
		ROUGHNESS = roughness_override >= 0.0 ? roughness_override : arm.g;
		METALLIC = metallic_override >= 0.0 ? metallic_override : arm.b;
		AO = arm.r;
		AO_LIGHT_AFFECT = 0.4;
	} else {
		ROUGHNESS = roughness_override >= 0.0 ? roughness_override : 0.9;
		METALLIC = metallic_override >= 0.0 ? metallic_override : 0.0;
	}
}
