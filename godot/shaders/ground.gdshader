shader_type canvas_item;
// Infinite procedural ground in world space: three octaves of value noise blend the stage's
// palette, plus scattered stones, grass tufts and a soft grid of shard veins. The quad follows the
// camera; the noise is sampled at the world position so the ground never swims.
uniform vec3 c0 : source_color = vec3(0.06, 0.14, 0.1);
uniform vec3 c1 : source_color = vec3(0.1, 0.29, 0.17);
uniform vec3 c2 : source_color = vec3(0.17, 0.48, 0.26);
uniform vec3 acc : source_color = vec3(0.6, 0.8, 0.4);
uniform float time = 0.0;
uniform float darkness = 0.0;
varying vec2 wpos;

float h21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(h21(i), h21(i + vec2(1, 0)), u.x), mix(h21(i + vec2(0, 1)), h21(i + vec2(1, 1)), u.x), u.y);
}
void vertex() { wpos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy; }
void fragment() {
	vec2 p = wpos;
	float n = vnoise(p / 380.0) * 0.55 + vnoise(p / 120.0) * 0.3 + vnoise(p / 40.0) * 0.15;
	vec3 col = mix(c0, c1, smoothstep(0.25, 0.6, n));
	col = mix(col, c2, smoothstep(0.62, 0.85, n) * 0.6);
	// stones / tufts on a jittered 48px lattice
	vec2 cell = floor(p / 48.0);
	vec2 jit = vec2(h21(cell), h21(cell + 17.0));
	vec2 q = (fract(p / 48.0) - jit) * 48.0;
	float r = h21(cell + 3.0);
	if (r > 0.82) {
		float st = length(q * vec2(1.0, 1.4)) - 3.0 - r * 4.0;
		col = mix(col, mix(c1 * 1.4, acc * 0.5, 0.3), smoothstep(1.0, -1.0, st) * 0.6);
		col *= 1.0 - smoothstep(2.0, -1.0, length(q + vec2(-1.5, -2.5)) - 4.0) * 0.12;
	} else if (r > 0.5) {
		float blade = abs(q.x + sin(q.y * 0.4 + time * 1.5 + r * 6.0) * 1.2) - 0.7;
		col = mix(col, c2 * 1.35, smoothstep(1.0, 0.0, blade) * step(-6.0, q.y) * step(q.y, 0.0) * 0.45);
	}
	// faint glowing shard veins
	float v = abs(vnoise(p / 260.0 + 4.0) - 0.5);
	col += acc * smoothstep(0.012, 0.0, v) * (0.12 + 0.06 * sin(time * 2.0 + p.x * 0.01));
	col *= 1.0 - darkness;
	COLOR = vec4(col, 1.0);
}
