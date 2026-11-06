shader_type canvas_item;
render_mode blend_add;
// Additive sprites for projectiles, XP gems and particles. INSTANCE_CUSTOM.x picks the shape:
// 0 soft orb, 1 faceted gem, 2 spark (streak), 3 ring.
varying vec4 v_custom;
varying vec4 v_col;
void vertex() { v_custom = INSTANCE_CUSTOM; v_col = COLOR; }
void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	float s = v_custom.x;
	float a = 0.0;
	if (s < 0.5) {
		float d = length(p);
		a = smoothstep(1.0, 0.0, d) * 0.6 + smoothstep(0.35, 0.1, d);
	} else if (s < 1.5) {
		float d = abs(p.x) + abs(p.y) * 0.8;
		a = smoothstep(0.75, 0.6, d) + smoothstep(1.0, 0.2, d) * 0.4;
		a *= 0.75 + 0.25 * step(0.0, p.x * p.y);
	} else if (s < 2.5) {
		a = smoothstep(1.0, 0.0, abs(p.y) * 3.0 + abs(p.x)) ;
	} else {
		float d = abs(length(p) - 0.75);
		a = smoothstep(0.25, 0.0, d);
	}
	COLOR = vec4(v_col.rgb * (1.0 + v_custom.y), clamp(a * v_col.a, 0.0, 1.0));
}
