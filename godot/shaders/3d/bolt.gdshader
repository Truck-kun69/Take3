shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;
// Lightning / arcs / beams built as camera-facing ribbons in an ImmediateMesh. Vertex colour carries
// intensity; UV.y across the ribbon gives a hot white core with coloured falloff.
#include "res://shaders/3d/terrain_h.gdshaderinc"
void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX += inverse(mat3(MODEL_MATRIX)) * vec3(0.0, th(w.xz), 0.0);
}
void fragment() {
	float x = abs(UV.y - 0.5) * 2.0;
	float core = smoothstep(0.35, 0.0, x);
	float glow = smoothstep(1.0, 0.0, x);
	ALBEDO = mix(COLOR.rgb, vec3(1.0), core * 0.8) * 2.5;
	ALPHA = clamp((glow * 0.6 + core) * COLOR.a, 0.0, 1.0);
}
