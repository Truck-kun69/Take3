shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, skip_vertex_transform, shadows_disabled;
// Soft contact shadow under every foe: one quad per instance (2D transform: world x/z), laid on the
// terrain in the vertex shader. Grounds the swarm on every tier, including Low (no shadow maps).
#include "res://shaders/3d/terrain_h.gdshaderinc"
uniform float strength = 0.5;
void vertex() {
	vec2 xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xy;
	VERTEX = (VIEW_MATRIX * vec4(xz.x, th(xz) + 0.9, xz.y, 1.0)).xyz;
}
void fragment() {
	float r = length(UV - 0.5) * 2.0;
	ALBEDO = vec3(0.0);
	ALPHA = strength * smoothstep(1.0, 0.25, r);
}
