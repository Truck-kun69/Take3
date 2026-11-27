shader_type canvas_item;
// Liquid globe (life / ultimate): a sloshing surface at `fill`, swirling noise, a bright meniscus,
// darker depths and an inner shadow toward the rim. The frame texture is drawn on top.
uniform float fill = 1.0;
uniform vec4 deep : source_color = vec4(0.32, 0.02, 0.04, 1.0);
uniform vec4 bright : source_color = vec4(0.95, 0.16, 0.12, 1.0);
uniform float time = 0.0;
uniform float hurt = 0.0;
float h(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vn(vec2 p) { vec2 i = floor(p); vec2 f = fract(p); vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(h(i), h(i + vec2(1, 0)), u.x), mix(h(i + vec2(0, 1)), h(i + vec2(1, 1)), u.x), u.y); }
void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float inside = smoothstep(0.86, 0.83, r);
	float surface = 1.0 - 2.0 * clamp(fill, 0.0, 1.0) + sin(p.x * 5.0 + time * 2.0) * 0.025 + sin(p.x * 9.0 - time * 3.1) * 0.012;
	float liquid = smoothstep(surface - 0.012, surface + 0.012, p.y);
	float swirl = vn(p * 3.0 + vec2(time * 0.3, -time * 0.5)) * 0.6 + vn(p * 7.0 - time * 0.4) * 0.4;
	vec3 col = mix(bright.rgb, deep.rgb, clamp((p.y + 1.0) * 0.5 + 0.15, 0.0, 1.0)) * (0.7 + 0.55 * swirl);
	col += bright.rgb * smoothstep(0.045, 0.0, abs(p.y - surface)) * 0.9 * step(0.001, fill) * step(fill, 0.999);
	vec3 empty = vec3(0.025, 0.02, 0.03) + 0.03 * swirl;
	vec3 c = mix(empty, col, liquid);
	c = mix(c, vec3(1.0, 0.85, 0.8), hurt * 0.35 * liquid);
	c *= 1.0 - smoothstep(0.5, 0.86, r) * 0.6;
	COLOR = vec4(c, inside);
}
