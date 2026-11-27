shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;
// Lightning / arcs / beams built as camera-facing ribbons in an ImmediateMesh. Vertex colour carries
// intensity; UV.y across the ribbon gives a hot white core with coloured falloff.
// COLOR.rgb is an sRGB colour (FX3D passes the element hexes): linearised per vertex, like glow.gdshader.
#include "res://shaders/3d/terrain_h.gdshaderinc"
varying vec3 v_col;
vec3 lin(vec3 c) { return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, step(c, vec3(0.04045))); }
void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX += lift(mat3(MODEL_MATRIX), th(w.xz));
	v_col = lin(COLOR.rgb);
}
void fragment() {
	float x = abs(UV.y - 0.5) * 2.0;
	float core = smoothstep(0.35, 0.0, x);
	float glow = smoothstep(1.0, 0.0, x);
	ALBEDO = mix(v_col, vec3(1.0), core * 0.8) * 2.5;
	ALPHA = clamp((glow * 0.6 + core) * COLOR.a, 0.0, 1.0);
}
