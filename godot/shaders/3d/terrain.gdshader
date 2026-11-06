shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
// Procedural ground in world space: fbm-blended stage palette, cracked flagstone patches, pebbles,
// derivative-based normals so the sun and torch rake across the relief, and pulsing shard veins.
// Optional authored texture slot: res://textures/terrain/<stage>.png (tiled, tinted by the palette).
uniform vec3 c0 : source_color = vec3(0.06, 0.14, 0.1);
uniform vec3 c1 : source_color = vec3(0.1, 0.29, 0.17);
uniform vec3 c2 : source_color = vec3(0.17, 0.48, 0.26);
uniform vec3 acc : source_color = vec3(0.6, 0.8, 0.4);
uniform float time = 0.0;
uniform int octaves = 4;
uniform bool has_tex = false;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform float tex_scale = 0.004;
varying vec3 wp;

float h21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vn(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(h21(i), h21(i + vec2(1, 0)), u.x), mix(h21(i + vec2(0, 1)), h21(i + vec2(1, 1)), u.x), u.y);
}
float fbm(vec2 p) {
	float a = 0.5; float s = 0.0;
	for (int i = 0; i < 6; i++) { if (i >= octaves) break; s += vn(p) * a; p = p * 2.03 + 17.0; a *= 0.5; }
	return s;
}
// cellular distance for flagstones / cracks
vec2 cell(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p);
	float d1 = 9.0; float d2 = 9.0;
	for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
		vec2 g = vec2(float(x), float(y));
		vec2 o = vec2(h21(i + g), h21(i + g + 31.0));
		float d = length(g + o - f);
		if (d < d1) { d2 = d1; d1 = d; } else if (d < d2) { d2 = d; }
	}
	return vec2(d1, d2);
}
float height(vec2 p) {
	float h = fbm(p / 90.0) * 0.6 + vn(p / 14.0) * 0.25;
	vec2 c = cell(p / 70.0);
	float stones = smoothstep(0.36, 0.28, fbm(p / 400.0 + 3.0));      // flagstone patches (rare)
	h += stones * smoothstep(0.0, 0.08, c.y - c.x) * 0.35;
	return h;
}
void vertex() { wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	vec2 p = wp.xz;
	float n = fbm(p / 420.0);
	vec3 col = mix(c0, c1, smoothstep(0.3, 0.62, n));
	col = mix(col, c2, smoothstep(0.6, 0.85, fbm(p / 160.0 + 9.0)) * 0.55);
	float stones = smoothstep(0.36, 0.28, fbm(p / 400.0 + 3.0));
	vec2 c = cell(p / 70.0);
	float crack = smoothstep(0.06, 0.0, c.y - c.x);
	col = mix(col, mix(vec3(0.32, 0.31, 0.3), c1 * 1.6, 0.35) * (0.85 + 0.3 * h21(floor(p / 70.0))), stones * 0.75);
	col *= 1.0 - crack * stones * 0.45;
	// dirt paths and darker hollows break up the palette (PoE2 grounds are desaturated and mottled)
	float dirt = smoothstep(0.45, 0.7, fbm(p / 220.0 + 21.0));
	col = mix(col, vec3(0.16, 0.13, 0.1) + c1 * 0.25, dirt * 0.55);
	col *= 0.75 + 0.35 * vn(p / 9.0);
	// pebbles
	vec2 pc = floor(p / 22.0);
	vec2 po = (fract(p / 22.0) - vec2(h21(pc), h21(pc + 5.0))) * 22.0;
	float peb = smoothstep(2.6, 1.6, length(po * vec2(1.0, 1.3)) - h21(pc + 9.0) * 2.0) * step(0.7, h21(pc + 2.0));
	col = mix(col, vec3(0.45, 0.44, 0.42) * (0.8 + c1), peb * 0.7);
	if (has_tex) col = mix(col, texture(albedo_tex, p * tex_scale).rgb * (c1 * 2.0 + 0.4), 0.7);
	// normals from the height field
	float e = 1.5;
	float hc = height(p);
	float hx = height(p + vec2(e, 0.0));
	float hz = height(p + vec2(0.0, e));
	vec3 nw = normalize(vec3((hc - hx) * 14.0 + peb * 0.0, 1.0, (hc - hz) * 14.0));
	NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
	// shard veins
	float v = abs(fbm(p / 300.0 + 4.0) - 0.5);
	float vein = smoothstep(0.004, 0.0, v) * smoothstep(0.55, 0.62, fbm(p / 900.0 + 7.0));
	col = mix(col, vec3(dot(col, vec3(0.3, 0.59, 0.11))), 0.3);       // desaturate
	ALBEDO = col * (0.55 + 0.25 * hc);
	ROUGHNESS = mix(0.95, 0.6, stones);
	EMISSION = acc * vein * (0.35 + 0.25 * sin(time * 1.6 + p.x * 0.01 + p.y * 0.007));
}
