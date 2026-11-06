shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;
// Ground-plane effect quad (unit quad lying on the ground, scaled by the instance). Instance
// uniforms choose the shape:  kind 0 telegraph circle, 1 ring/annulus, 2 line, 3 cone, 4 shockwave ring,
// 5 soft glow disc, 6 rune circle (shrines, altars, breaches).
instance uniform vec4 col : source_color = vec4(1.0, 0.3, 0.3, 0.6);
instance uniform float kind = 0.0;
instance uniform float prog = 0.0;       // telegraph fill 0..1, ring expansion 0..1
instance uniform float inner = 0.0;      // ring inner radius fraction, cone half-angle (radians)
instance uniform float hatch = 0.0;
uniform float time = 0.0;
void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	float r = length(p);
	float a = 0.0;
	float pulse = 0.6 + 0.4 * sin(time * 10.0);
	if (kind < 0.5) {
		float edge = smoothstep(0.9, 0.97, r) * smoothstep(1.0, 0.97, r);
		float fill = step(r, prog) * 0.55 + 0.18;
		a = (r < 1.0 ? fill : 0.0) + edge * (1.4 + pulse * step(0.8, prog));
		if (hatch > 0.5 && r < 1.0) a += step(0.5, fract((p.x + p.y) * 6.0 + time)) * 0.25;
	} else if (kind < 1.5) {
		float band = step(inner, r) * step(r, 1.0);
		a = band * (0.25 + 0.5 * step(0.999, prog) * pulse) + smoothstep(0.02, 0.0, abs(r - inner)) * 1.5;
	} else if (kind < 2.5) {
		float side = abs(p.y);
		a = step(side, 1.0) * (0.3 + 0.45 * step(UV.x, prog)) + smoothstep(0.12, 0.0, abs(side - 0.92)) * 1.2;
	} else if (kind < 3.5) {
		float ang = abs(atan(p.y, p.x));
		a = step(r, 1.0) * step(ang, inner) * (0.3 + 0.45 * step(r, prog));
	} else if (kind < 4.5) {
		float rr = prog;
		a = smoothstep(0.12, 0.0, abs(r - rr)) * (1.0 - prog) * 2.5 + step(r, rr) * (1.0 - prog) * 0.25;
	} else if (kind < 5.5) {
		a = smoothstep(1.0, 0.0, r) * 0.8;
	} else {
		float ang = atan(p.y, p.x);
		float ring = smoothstep(0.04, 0.0, abs(r - 0.9)) + smoothstep(0.03, 0.0, abs(r - 0.7));
		float runes = step(0.7, r) * step(r, 0.9) * step(0.6, fract(ang * 6.0 / 6.283 * 8.0 + time * 0.2));
		a = (ring * 1.4 + runes * 0.5) * (0.7 + 0.3 * sin(time * 3.0));
	}
	ALBEDO = col.rgb * 2.0;
	ALPHA = clamp(a * col.a, 0.0, 1.0);
}
