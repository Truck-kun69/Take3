shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, shadows_disabled, specular_schlick_ggx;
// Liquid surface at the stage's level (elevation pass). Depth below the surface comes from the terrain
// height texture, so shores fade in and deep water goes dark. Kinds: 0 water (ripples, sky sheen,
// ice sheets where cold froze it, crackling where lightning charged it), 1 lava (glowing crust that
// cold turns to obsidian), 2 void (a starry abyss).
#include "res://shaders/3d/terrain_h.gdshaderinc"
uniform float time = 0.0;
uniform vec3 deep_col : source_color = vec3(0.02, 0.06, 0.08);
uniform vec3 shallow_col : source_color = vec3(0.1, 0.22, 0.22);
uniform vec3 glow_col : source_color = vec3(1.0, 0.45, 0.1);
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
	float depth = terrain_l.x - th(p);
	if (depth < -1.0) discard;
	float shore = smoothstep(0.0, 18.0, depth);
	vec2 st = tstate(p);
	float kind = terrain_l.y;
	vec3 col; float a; float rough = 0.08; vec3 em = vec3(0.0); float metal = 0.0;
	// ripples: two scrolling noise layers perturb the normal
	float r1 = vn(p / 26.0 + vec2(time * 0.35, time * 0.2));
	float r2 = vn(p / 11.0 - vec2(time * 0.5, -time * 0.3));
	vec3 n = normalize(vec3((r1 - 0.5) * 0.35 + (r2 - 0.5) * 0.2, 1.0, (r2 - 0.5) * 0.35 - (r1 - 0.5) * 0.2));
	if (kind < 0.5) {
		col = mix(shallow_col, deep_col, smoothstep(2.0, 26.0, depth));
		a = mix(0.45, 0.94, smoothstep(0.0, 22.0, depth));
		// sky sheen: a grazing reflection of the cold sky and a moving glint, so water reads as water
		// against dark ground (critique 1)
		float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 2.0);
		float glint = smoothstep(0.7, 0.95, vn(p / 5.0 + vec2(time * 0.8, -time * 0.5))) * smoothstep(0.55, 0.8, vn(p / 31.0 - time * 0.1));
		col += vec3(0.13, 0.18, 0.22) * (0.25 + fres) + vec3(0.6, 0.7, 0.75) * glint * 0.5;   // (Act V pass: 0.22/0.35 read as ice)
		float foam = smoothstep(4.0, 0.0, depth) * smoothstep(0.4, 0.7, vn(p / 7.0 + time * 0.6));
		col += vec3(0.55, 0.6, 0.6) * foam * 0.8;
		if (st.r > 0.01) {                       // ice sheet: pale, cracked, opaque, rough
			float crack = smoothstep(0.035, 0.0, abs(vn(p / 18.0) - 0.5)) + smoothstep(0.03, 0.0, abs(vn(p / 7.0 + 3.0) - 0.5)) * 0.5;
			float k = smoothstep(0.05, 0.6, st.r);
			vec3 ice = mix(vec3(0.36, 0.52, 0.62), vec3(0.62, 0.78, 0.86), vn(p / 40.0)) * (1.0 - crack * 0.5);
			ice = mix(ice, vec3(0.75, 0.88, 0.95), smoothstep(0.55, 0.85, vn(p / 13.0)) * 0.35);   // frosted patches
			col = mix(col, ice, k);
			a = mix(a, 0.95, k);
			float st_r = k;
			rough = mix(rough, 0.3, st_r);
			n = mix(n, vec3(0.0, 1.0, 0.0), st_r);
			em += vec3(0.3, 0.55, 0.7) * crack * st_r * 0.5;
		}
		if (st.g > 0.01) {                       // electrified: bright crackling filaments
			float arc = smoothstep(0.05, 0.0, abs(vn(p / 9.0 + time * 6.0) - 0.5)) + smoothstep(0.04, 0.0, abs(vn(p / 4.0 - time * 9.0) - 0.5)) * 0.6;
			em += vec3(0.65, 0.85, 1.0) * arc * st.g * 3.5 + vec3(0.2, 0.35, 0.6) * st.g * 0.5;
		}
	} else if (kind < 1.5) {
		// lava: dark crust plates with glowing seams and a few open pools (critique 2: an all-bright flow
		// swamped the foes' silhouettes in combat)
		float flow = vn(p / 55.0 + vec2(time * 0.04, 0.0)) * 0.55 + vn(p / 19.0 - time * 0.09) * 0.3 + vn(p / 7.0) * 0.15;
		float crust = smoothstep(0.36, 0.46, flow);
		float seam = smoothstep(0.035, 0.0, abs(flow - 0.41));
		col = mix(glow_col * 0.45, vec3(0.05, 0.035, 0.03) * (0.8 + 0.4 * vn(p / 9.0)), crust);
		em = glow_col * ((1.0 - crust) * 0.85 + seam * 1.3) * (0.9 + 0.25 * sin(time * 2.0 + p.x * 0.02)) * shore;
		a = mix(0.5, 1.0, shore);
		rough = mix(0.35, 0.9, crust);
		if (st.r > 0.01) {                       // obsidian crust where cold struck it
			col = mix(col, vec3(0.04, 0.035, 0.05), st.r);
			em *= 1.0 - st.r * 0.92;
			rough = mix(rough, 0.15, st.r);
			metal = st.r * 0.3;
		}
	} else {                                     // void: black with drifting motes
		col = vec3(0.0);
		float star = step(0.985, h21(floor(p / 6.0 + vec2(time * 0.2, 0.0))));
		em = vec3(0.6, 0.4, 1.0) * star * 1.5 + vec3(0.12, 0.04, 0.2) * (1.0 - shore) * 2.0;
		a = mix(0.0, 1.0, smoothstep(0.0, 30.0, depth));
		rough = 1.0;
	}
	ALBEDO = col;
	ALPHA = a * clamp(depth + 1.0, 0.0, 1.0);
	ROUGHNESS = rough;
	METALLIC = metal;
	SPECULAR = 0.6;
	EMISSION = em;
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
}
