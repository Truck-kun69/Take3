shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, shadows_disabled, diffuse_lambert_wrap;
// Low drifting ground fog. Lit (not unshaded) so the hero's torch and spell lights glow inside it.
// Anything in `pushers` (hero, nearby foes, shockwaves) parts the fog around itself.
// Cost: the plane covers the screen, so (a) the noise is two lookups in the shared noise texture,
// (b) pixels with no fog are discarded before the renderer runs its light loop on them, and (c) the
// pusher list is packed from index 0 (EnvFX._pushers), so the loop stops at the first empty slot.
global uniform sampler2D g_noise : filter_linear_mipmap, repeat_enable;
uniform vec3 fog_col : source_color = vec3(0.5, 0.5, 0.55);
uniform float density = 0.35;
uniform float time = 0.0;
uniform vec4 pushers[16];
varying vec3 wp;
void vertex() { wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	vec2 p = wp.xz;
	float n = texture(g_noise, p / 1100.0 + time * vec2(0.006, 0.003)).r * 0.6 + texture(g_noise, p / 380.0 - time * vec2(0.0095, 0.007)).g * 0.4;
	float a = smoothstep(0.42, 0.74, n) * density;
	if (a < 0.004) discard;
	for (int i = 0; i < 16; i++) {
		vec4 q = pushers[i];
		if (q.z <= 0.0) break;
		vec2 d2 = p - q.xy;
		float rmax = q.z * 1.3;
		float dd = dot(d2, d2);
		if (dd < rmax * rmax) a *= mix(1.0, smoothstep(q.z * 0.5, rmax, sqrt(dd)), clamp(q.w, 0.0, 1.0));
	}
	ALBEDO = fog_col;
	ROUGHNESS = 1.0;
	ALPHA = a;
}
