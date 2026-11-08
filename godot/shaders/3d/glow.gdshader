shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;
// Camera-facing additive sprites for projectiles, gems' halos, sparks and embers (MultiMesh).
// INSTANCE_CUSTOM.x shape: 0 soft orb, 1 star flare, 2 ember (hot core), 3 ring
varying vec4 v_custom;
#include "res://shaders/3d/terrain_h.gdshaderinc"
void vertex() {
	v_custom = INSTANCE_CUSTOM;
	vec4 o = MODEL_MATRIX[3];
	o.y += th(o.xz);                                  // heights are above the terrain (elevation pass)
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], o);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0), vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0), vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0), vec4(0.0, 0.0, 0.0, 1.0));
}
void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	float d = length(p);
	float s = v_custom.x;
	float a;
	if (s < 0.5) a = smoothstep(1.0, 0.0, d) * 0.55 + smoothstep(0.3, 0.05, d) * 1.2;
	else if (s < 1.5) a = smoothstep(1.0, 0.0, d) * 0.3 + smoothstep(0.06, 0.0, abs(p.x) * abs(p.y) + 0.0) * smoothstep(1.0, 0.2, d) * 1.5;
	else if (s < 2.5) a = smoothstep(1.0, 0.1, d) * 0.9;
	else a = smoothstep(0.2, 0.0, abs(d - 0.75)) * 1.2;
	ALBEDO = COLOR.rgb * (1.5 + v_custom.y);
	ALPHA = clamp(a * COLOR.a, 0.0, 1.0);
}
