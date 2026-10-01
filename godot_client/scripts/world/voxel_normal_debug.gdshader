shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

// Draws the world-space surface normal as colour: x -> red, y -> green,
// z -> blue.
//
// This is the geometry diagnostic. Shading tells you a face is lit oddly;
// this tells you which way the face actually points, which is the
// difference between "the light is wrong" and "this triangle is inside out".
// A back-face culled or mis-wound face shows up here as a missing region or
// as a colour that disagrees with the surface it is supposed to belong to.

void fragment() {
	// Transform to world space: the mesher's normals are in block-local
	// space, so a view-space normal would make the picture change as the
	// camera moves. A diagnostic has to be stable.
	vec3 n = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	ALBEDO = n * 0.5 + 0.5;
	ALPHA = 1.0;
}