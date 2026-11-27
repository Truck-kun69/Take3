shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;
// Low drifting ground fog. Unshaded: the plane covers the screen, and lit it ran the full light loop on
// every pixel. The torch's glow inside it is drawn analytically instead (a soft falloff around the hero,
// who is always pushers[0]), over the act's ambient tint. No discard: a fully transparent pixel costs
// less on a tile-based GPU than breaking its early depth test.
// Anything in `pushers` (the hero and the five newest shockwaves) parts the fog around itself.
// drape (the run): every vertex sits FOG_H above the terrain, or above water and lava where they cover it;
// the title stage has no terrain and keeps its plane where its node puts it.
#include "res://shaders/3d/terrain_h.gdshaderinc"
global uniform sampler2D g_noise : filter_linear_mipmap, repeat_enable;
uniform bool drape = false;
const float FOG_H = 7.0;
uniform vec3 fog_col : source_color = vec3(0.5, 0.5, 0.55);
uniform vec3 shade = vec3(0.45);      // the act's ambient light on the fog
uniform float glow = 1.6;             // how much brighter the fog is right at the torch
uniform float glow_r = 260.0;
uniform float density = 0.35;
uniform float time = 0.0;
uniform vec4 pushers[6];
varying vec3 wp;
void vertex() {
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	if (drape) {
		float g = th(wp.xz);
		if (terrain_l.y < 2.5) g = max(g, terrain_l.x);
		VERTEX += lift(mat3(MODEL_MATRIX), g + FOG_H);
		wp.y += g + FOG_H;
	}
}
void fragment() {
	vec2 p = wp.xz;
	float n = texture(g_noise, p / 1100.0 + time * vec2(0.006, 0.003)).r * 0.6 + texture(g_noise, p / 380.0 - time * vec2(0.0095, 0.007)).g * 0.4;
	float a = smoothstep(0.42, 0.74, n) * density;
	for (int i = 0; i < 6; i++) {
		vec4 q = pushers[i];
		if (q.z <= 0.0) break;
		vec2 d2 = p - q.xy;
		float rmax = q.z * 1.3;
		float dd = dot(d2, d2);
		if (dd < rmax * rmax) a *= mix(1.0, smoothstep(q.z * 0.5, rmax, sqrt(dd)), clamp(q.w, 0.0, 1.0));
	}
	vec2 h = p - pushers[0].xy;
	float lit = exp(-dot(h, h) / (glow_r * glow_r));
	ALBEDO = fog_col * (shade + glow * lit);
	ALPHA = a;
}
