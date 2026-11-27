shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, shadows_disabled;
// Hostile shots (FX3D.esh_mm): camera-facing quads, alpha-blended (not additive), never depth-tested, drawn after the
// other transparent effects (render_priority 100). A white-hot core in an ESHOT_RING ring on a dark outline, so a shot
// reads over the hero's own fire and through the bodies it flies between: in the shared additive glow pass, four shots
// arriving through the Emberwitch's burning pack showed on 47% of their disc (two hidden behind burning foes) and the
// ring rendered #f986aa, 15.6 dE00 from #ff1475.
// The instance colour is an sRGB hex: linearised here (it was read as linear, which paled it).
varying vec3 v_col;
vec3 lin(vec3 c) { return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, step(c, vec3(0.04045))); }
void vertex() {
	v_col = lin(COLOR.rgb);
	vec4 o = MODEL_MATRIX[3];
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], o);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0), vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0), vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0), vec4(0.0, 0.0, 0.0, 1.0));
}
void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	float d = length(p);
	float core = smoothstep(0.34, 0.22, d);
	float ring = smoothstep(0.17, 0.07, abs(d - 0.62));
	float halo = smoothstep(1.0, 0.82, d);
	vec3 c = mix(vec3(0.01), v_col * 1.3, ring);
	c = mix(c, vec3(1.0), core);
	ALBEDO = c;
	ALPHA = max(halo * 0.8, max(ring, core));
}
