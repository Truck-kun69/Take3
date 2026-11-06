shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, shadows_disabled, diffuse_lambert_wrap;
// Low drifting ground fog. Lit (not unshaded) so the hero's torch and spell lights glow inside it.
// Anything in `pushers` (hero, nearby foes, shockwaves) parts the fog around itself.
uniform vec3 fog_col : source_color = vec3(0.5, 0.5, 0.55);
uniform float density = 0.35;
uniform float time = 0.0;
uniform vec4 pushers[16];
varying vec3 wp;
float h21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vn(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(h21(i), h21(i + vec2(1, 0)), u.x), mix(h21(i + vec2(0, 1)), h21(i + vec2(1, 1)), u.x), u.y);
}
void vertex() { wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	vec2 p = wp.xz;
	float n = vn(p / 260.0 + time * vec2(0.025, 0.012)) * 0.6 + vn(p / 90.0 - time * vec2(0.04, 0.03)) * 0.4;
	float a = smoothstep(0.38, 0.78, n) * density;
	for (int i = 0; i < 16; i++) {
		vec4 q = pushers[i];
		if (q.z <= 0.0) continue;
		float d = length(p - q.xy);
		a *= mix(1.0, smoothstep(q.z * 0.5, q.z * 1.3, d), clamp(q.w, 0.0, 1.0));
	}
	ALBEDO = fog_col;
	ROUGHNESS = 1.0;
	ALPHA = a;
}
