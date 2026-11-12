// Terrain height and state, shared by every 3D shader (elevation pass). WorldView3D composes the
// simulation's heights for the 7 x 7 chunks around the player into terrain_h (R32F, one texel per
// 16-unit cell) and sets these globals; th() is the same bilinear lookup as Terrain.height() in the sim.
//   terrain_o = (world x of texel 0's corner, world z of it, texels per side, cell size)
//   terrain_s = R: ice / obsidian crust 0..1, G: electrified 0..1
//   terrain_l = (liquid level, liquid kind 0 water 1 lava 2 void 3 none, 0, 0)
global uniform sampler2D terrain_h;
global uniform sampler2D terrain_s;
global uniform vec4 terrain_o;
global uniform vec4 terrain_l;
global uniform sampler2D terrain_f;   // surfaces: R oil, G poison, B blood, A fire; R+G together = crystal spikes

float th(vec2 xz) {
	if (terrain_o.z < 2.0) return 0.0;
	vec2 f = (xz - terrain_o.xy) / terrain_o.w - 0.5;
	vec2 i = floor(f);
	vec2 t = f - i;
	int n = int(terrain_o.z);
	ivec2 a = clamp(ivec2(i), ivec2(0), ivec2(n - 2));
	if (any(lessThan(i, vec2(0.0))) || any(greaterThan(i, vec2(float(n - 2))))) t = clamp(t, 0.0, 0.0);
	float h00 = texelFetch(terrain_h, a, 0).r;
	float h10 = texelFetch(terrain_h, a + ivec2(1, 0), 0).r;
	float h01 = texelFetch(terrain_h, a + ivec2(0, 1), 0).r;
	float h11 = texelFetch(terrain_h, a + ivec2(1, 1), 0).r;
	return mix(mix(h00, h10, t.x), mix(h01, h11, t.x), t.y);
}

// bilinear over cell centres, so ice sheets and charged water have soft edges instead of square cells
vec2 tstate(vec2 xz) {
	if (terrain_o.z < 2.0) return vec2(0.0);
	vec2 f = (xz - terrain_o.xy) / terrain_o.w - 0.5;
	vec2 i = floor(f);
	vec2 t = f - i;
	ivec2 a = clamp(ivec2(i), ivec2(0), ivec2(int(terrain_o.z) - 2));
	vec2 s00 = texelFetch(terrain_s, a, 0).rg;
	vec2 s10 = texelFetch(terrain_s, a + ivec2(1, 0), 0).rg;
	vec2 s01 = texelFetch(terrain_s, a + ivec2(0, 1), 0).rg;
	vec2 s11 = texelFetch(terrain_s, a + ivec2(1, 1), 0).rg;
	return mix(mix(s00, s10, t.x), mix(s01, s11, t.x), t.y);
}

// surfaces, bilinear over cell centres like tstate (pools get soft edges)
vec4 tsurf(vec2 xz) {
	if (terrain_o.z < 2.0) return vec4(0.0);
	vec2 f = (xz - terrain_o.xy) / terrain_o.w - 0.5;
	vec2 i = floor(f);
	vec2 t = f - i;
	ivec2 a = clamp(ivec2(i), ivec2(0), ivec2(int(terrain_o.z) - 2));
	vec4 s00 = texelFetch(terrain_f, a, 0);
	vec4 s10 = texelFetch(terrain_f, a + ivec2(1, 0), 0);
	vec4 s01 = texelFetch(terrain_f, a + ivec2(0, 1), 0);
	vec4 s11 = texelFetch(terrain_f, a + ivec2(1, 1), 0);
	return mix(mix(s00, s10, t.x), mix(s01, s11, t.x), t.y);
}

vec3 tnormal(vec2 xz) {
	float e = 10.0;
	float hx = th(xz + vec2(e, 0.0)) - th(xz - vec2(e, 0.0));
	float hz = th(xz + vec2(0.0, e)) - th(xz - vec2(0.0, e));
	return normalize(vec3(-hx, 2.0 * e, -hz));
}
