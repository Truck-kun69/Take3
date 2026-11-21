shader_type spatial;
render_mode diffuse_lambert, specular_schlick_ggx;
// Ground in world space. Detail comes from two tiling, mipmapped CC0 texture sets per act (albedo +
// normal), blended by a low-frequency mask and tinted by the act palette: the GPU filters them, so
// the image stays stable under a moving camera. Noise is only used for broad, low-frequency variation
// (the earlier all-procedural ground had no mipmaps, and its fine terms shimmered).
uniform vec3 c0 : source_color = vec3(0.06, 0.14, 0.1);
uniform vec3 c1 : source_color = vec3(0.1, 0.29, 0.17);
uniform vec3 c2 : source_color = vec3(0.17, 0.48, 0.26);
uniform vec3 acc : source_color = vec3(0.6, 0.8, 0.4);
uniform float time = 0.0;
// four independent low-frequency noise fields in one small tiling texture (the global g_noise, built by WorldView3D.noise_tex):
// one filtered lookup replaces a dozen per-pixel hash evaluations (the S22 spent most of its frame here)
global uniform sampler2D g_noise : filter_linear_mipmap, repeat_enable;
uniform bool detail2 = false;        // High tier: sample each set at a second scale to hide the repeat
uniform bool has_tex = false;
uniform sampler2D tex_a : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_b : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D nrm_a : filter_linear_mipmap, repeat_enable;
uniform sampler2D nrm_b : filter_linear_mipmap, repeat_enable;
uniform float tex_scale = 0.0045;       // one tile every ~220 world units
uniform float tint = 0.45;               // how far the act palette recolours the photographs
uniform bool displace = false;     // the run's ground follows the terrain; the title stage stays flat
varying vec3 wp;
varying vec3 v_n;
#include "res://shaders/3d/terrain_h.gdshaderinc"

float h21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
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
void vertex() {
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_n = vec3(0.0, 1.0, 0.0);
	if (displace) {
		float h = th(wp.xz);
		VERTEX += lift(mat3(MODEL_MATRIX), h - wp.y);    // the tiles are only translated: no 4x4 inverse per vertex
		wp.y = h;
		v_n = tnormal(wp.xz);
	}
}
void fragment() {
	vec2 p = wp.xz;
	vec4 nz = texture(g_noise, p / 1700.0);        // r: palette, g: stone patches, b: accents, a: dirt
	float n = nz.r;
	vec3 pal = mix(c0, c1, smoothstep(0.3, 0.62, n));
	pal = mix(pal, c2, smoothstep(0.55, 0.8, nz.b) * 0.55);
	float stones = smoothstep(0.45, 0.33, nz.g);      // paved / rocky patches
	vec3 col; vec3 nw; float hc = 0.5;
	if (has_tex) {
		// each set is sampled at two scales and mixed: hides the repeat from the high camera
		vec2 ua = p * tex_scale;
		vec2 ub = vec2(p.y, -p.x) * tex_scale * 0.37 + 0.31;
		vec3 a = texture(tex_a, ua).rgb;
		vec3 b = texture(tex_b, ua * 1.3).rgb;
		if (detail2) {
			float mixk = 0.35 + 0.3 * nz.b;
			a = mix(a, texture(tex_a, ub).rgb, mixk);
			b = mix(b, texture(tex_b, ub).rgb, mixk * 0.6);
		}
		// the second set wins where the mask is high, breaking along the first set's dark crevices
		float la = dot(a, vec3(0.33));
		float k = smoothstep(0.35, 0.65, stones * 1.4 - la * 0.6 + 0.1);
		vec3 t = mix(a, b, k);
		hc = dot(t, vec3(0.33));
		vec3 grey = vec3(hc);
		// tint: keep the photograph's light and dark, take most of the hue from the act palette
		vec3 hue = pal / max(0.001, dot(pal, vec3(0.33)));
		col = mix(t, grey * hue, tint) * mix(vec3(1.0), pal * 4.0, 0.25);
		col = mix(col, vec3(dot(col, vec3(0.3, 0.59, 0.11))), 0.3) * 0.85;       // muted: the act colours the light, not the paint
		col = mix(col, col * mix(vec3(0.75, 0.74, 0.78), vec3(1.0), 0.3), k);        // stone reads cooler than soil
		vec3 na = texture(nrm_a, ua).rgb * 2.0 - 1.0;
		vec3 nb = texture(nrm_b, ua * 1.3).rgb * 2.0 - 1.0;
		vec3 nn = mix(na, nb, k);
		nw = normalize(vec3(nn.x * 1.3, nn.z, -nn.y * 1.3));
	} else {
		col = pal * (0.85 + 0.3 * nz.a);
		nw = vec3(0.0, 1.0, 0.0);
	}
	// dirt paths and darker hollows break up the palette (broad, low-frequency only)
	float dirt = smoothstep(0.5, 0.72, nz.a);
	col = mix(col, col * vec3(0.62, 0.55, 0.5), dirt * 0.5);
	// elevation: steep faces turn to bare dark rock with strata, ground near the liquid is wet and dark
	float slope = 1.0 - clamp(v_n.y, 0.0, 1.0);
	float rock = smoothstep(0.28, 0.5, slope);
	float strata = 0.75 + 0.25 * sin(wp.y * 0.55 + nz.b * 6.0);
	col = mix(col, mix(c0 * 0.9, vec3(0.2, 0.19, 0.2), 0.5) * strata, rock);
	// read elevation from above: valleys darker and damper, ridges lighter and drier (critique 1: from the
	// high camera, slope shading alone made hills invisible)
	if (displace) {
		float hn = clamp((wp.y - terrain_l.x) / 130.0, 0.0, 1.0);
		col *= mix(0.62, 1.22, smoothstep(0.0, 1.0, hn));
		col = mix(col, col * vec3(1.08, 1.04, 0.94), smoothstep(0.6, 1.0, hn));     // sun-bleached tops
		float lip = smoothstep(0.18, 0.32, slope) * (1.0 - rock);                      // light catches ledge rims
		col *= 1.0 + lip * 0.25;
	}
	float shore = 0.0;
	if (displace && terrain_l.y < 2.5) {
		shore = smoothstep(terrain_l.x + 14.0, terrain_l.x, wp.y);
		vec3 wet = terrain_l.y < 0.5 ? col * 0.45 : mix(col * 0.5, vec3(0.25, 0.06, 0.02), 0.5);
		col = mix(col, wet, shore);
	}
	// combine the detail normal with the terrain's own slope
	vec3 tn = v_n;
	vec3 tt = normalize(cross(tn, vec3(0.0, 0.0, 1.0)));
	vec3 tb = cross(tt, tn);
	nw = normalize(tt * nw.x * -1.0 + tn * nw.y + tb * nw.z);
	NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
	// shard veins
	vec4 nv = texture(g_noise, p / 1150.0 + 0.37);
	float vf = nv.a - 0.5;
	float vw = max(fwidth(vf) * 1.5, 0.004);                          // never thinner than ~1.5 pixels: no crawling
	float vein = smoothstep(vw, 0.0, abs(vf)) * smoothstep(0.5, 0.58, nv.r);
	float rough = mix(mix(0.95, 0.6, stones), 0.25, shore);
	vec3 emit = acc * vein * (0.2 + 0.14 * sin(time * 1.6 + p.x * 0.01 + p.y * 0.007));     // veins: an undertone, not a web of neon
	// surfaces: oil, poison, blood pools; burning oil; crystallised poison (noisy edges, organic blobs)
	vec4 sf = tsurf(p);
	if (sf.r + sf.g + sf.b + sf.a > 0.02) {
		vec4 ns = texture(g_noise, p / 95.0);                 // fine noise, only inside surfaces
		float edge = (ns.r - 0.5) * 0.6;
		// spikes are encoded as oil + poison together (the two never share a cell)
		float spk = smoothstep(0.32, 0.55, min(sf.r, sf.g) + edge);
		float oil = smoothstep(0.32, 0.55, sf.r + edge) * (1.0 - spk);
		float poi = smoothstep(0.32, 0.55, sf.g + edge) * (1.0 - spk);
		float bld = smoothstep(0.32, 0.55, sf.b + edge);
		float fire = smoothstep(0.3, 0.6, sf.a + edge * 0.6);
		vec3 sheen = 0.5 + 0.5 * cos(6.2831 * (vec3(0.0, 0.33, 0.67) + ns.g * 1.5 + time * 0.05));
		col = mix(col, vec3(0.025, 0.022, 0.02) + sheen * 0.05, oil * 0.92);
		float orim = oil * (1.0 - smoothstep(0.55, 0.9, sf.r + edge));          // a lighter tide line at the edge
		emit += (sheen * 0.03 + vec3(0.012)) * oil + vec3(0.07, 0.065, 0.05) * orim;
		col = mix(col, vec3(0.16, 0.42, 0.06), poi * 0.85);
		col = mix(col, vec3(0.2, 0.01, 0.012), bld * 0.88);
		rough = mix(rough, 0.12, max(max(oil, bld), poi * 0.6));
		float bub = smoothstep(0.62, 0.78, texture(g_noise, p / 50.0 + vec2(time * 0.09, -time * 0.05)).b);
		emit += vec3(0.25, 0.9, 0.1) * poi * (0.12 + 0.35 * bub);
		float fl = texture(g_noise, p / 75.0 + vec2(0.0, -time * 0.3)).g * 0.6 + texture(g_noise, p / 33.0 + vec2(time * 0.16, -time * 0.4)).a * 0.4 + 0.12;
		col = mix(col, vec3(0.04, 0.025, 0.02), fire);                          // charred, with licks of flame
		float lick = pow(clamp(fl, 0.0, 1.0), 2.2);
		emit += mix(vec3(0.5, 0.08, 0.01), vec3(1.0, 0.5, 0.12), lick) * fire * (0.15 + 1.5 * lick);
		float shard = 0.0;
		if (spk > 0.01) shard = smoothstep(0.12, 0.0, cell(p / 9.0).x) * spk;     // the 3x3 cell search only where spikes are
		col = mix(col, vec3(0.75, 0.95, 0.7), spk * 0.6);
		emit += vec3(0.6, 1.0, 0.55) * (spk * 0.18 + shard * 0.8);
	}
	ALBEDO = col;
	ROUGHNESS = rough;
	EMISSION = emit;
}
