shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx, cull_back;
// Instanced swarm. One baked mesh per foe kind; UV2 carries (part id, pivot height) so the vertex
// stage can walk legs, swing arms, bob heads and wave tendrils without skeletons.
// INSTANCE_CUSTOM = (walk phase (wrapped), hit flash | corpse dissolve, status code, flag bits); instance
// colour alpha = seed / 63. Instance data is stored as 16-bit halves, so every value stays small.
//   status: 0 none 1 burn 2 chill 3 shock 4 poison 5 bleed 6 frozen 7 CORPSE (lying, crumbling)
//   flags: 1 elite, 2 boss, 8 exile, 16 goblin, 64 ally;  seed 0..63 varies the skin per foe
uniform float time = 0.0;
uniform vec3 eye_col : source_color = vec3(1.0, 0.8, 0.35);
uniform vec3 glow_col : source_color = vec3(0.5, 0.85, 1.0);
uniform bool colorblind = false;
// Vertex animation texture (Models.foe_vat): row = frame, column = vertex (UV.x). INSTANCE_CUSTOM.x is then
// the frame coordinate into it (the CPU picks the clip and time), blended between two rows.
uniform bool has_vat = false;
uniform sampler2D vat_pos : filter_nearest, repeat_disable;
uniform sampler2D vat_nrm : filter_nearest, repeat_disable;
varying flat float v_part;
varying vec4 v_custom;
varying vec3 v_mpos;
#include "res://shaders/3d/terrain_h.gdshaderinc"

float h31(vec3 p) { return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453); }
float vn3(vec3 p) {
	vec3 i = floor(p); vec3 f = fract(p);
	vec3 u = f * f * (3.0 - 2.0 * f);
	float a = mix(mix(h31(i), h31(i + vec3(1, 0, 0)), u.x), mix(h31(i + vec3(0, 1, 0)), h31(i + vec3(1, 1, 0)), u.x), u.y);
	float b = mix(mix(h31(i + vec3(0, 0, 1)), h31(i + vec3(1, 0, 1)), u.x), mix(h31(i + vec3(0, 1, 1)), h31(i + vec3(1, 1, 1)), u.x), u.y);
	return mix(a, b, u.z);
}

vec3 status_col(float s) {
	if (s < 0.5) return vec3(0.0);
	if (colorblind) {
		if (s < 1.5) return vec3(0.9, 0.62, 0.0);
		if (s < 2.5) return vec3(0.34, 0.71, 0.91);
		if (s < 3.5) return vec3(0.94, 0.89, 0.26);
		if (s < 4.5) return vec3(0.0, 0.62, 0.45);
		if (s < 5.5) return vec3(0.84, 0.37, 0.0);
		return vec3(0.8, 0.95, 1.0);
	}
	if (s < 1.5) return vec3(1.0, 0.45, 0.12);
	if (s < 2.5) return vec3(0.45, 0.85, 1.0);
	if (s < 3.5) return vec3(1.0, 0.92, 0.3);
	if (s < 4.5) return vec3(0.4, 1.0, 0.3);
	if (s < 5.5) return vec3(1.0, 0.15, 0.2);
	return vec3(0.75, 0.95, 1.0);
}

void vertex() {
	v_custom = INSTANCE_CUSTOM;
	v_mpos = VERTEX;
	float part = floor(UV2.x + 0.5);
	float piv = UV2.y;
	v_part = part;
	if (has_vat) {
		ivec2 sz = textureSize(vat_pos, 0);
		int vi = clamp(int(UV.x * float(sz.x)), 0, sz.x - 1);
		float fr = clamp(INSTANCE_CUSTOM.x, 0.0, float(sz.y - 2));
		int f0 = int(floor(fr));
		VERTEX = mix(texelFetch(vat_pos, ivec2(vi, f0), 0).xyz, texelFetch(vat_pos, ivec2(vi, f0 + 1), 0).xyz, fr - float(f0));
		NORMAL = normalize(texelFetch(vat_nrm, ivec2(vi, f0), 0).xyz * 2.0 - 1.0);
		v_mpos = VERTEX;
	} else if (INSTANCE_CUSTOM.z < 6.5) {                           // corpses (7) are not animated
		float ph = INSTANCE_CUSTOM.x;
		float flash = INSTANCE_CUSTOM.y;
		bool frozen = INSTANCE_CUSTOM.z > 5.5;
		if (frozen) ph = 0.0;
		vec3 v = VERTEX;
		if (part > 0.5 && part < 4.5) {
			float side = (part < 1.5 || (part > 3.5 && part < 4.5)) ? 1.0 : -1.0;
			float amp = part < 2.5 ? 0.6 : 0.5;
			float a = sin(ph) * amp * side;
			vec2 rel = vec2(v.x, v.y - piv);
			float c = cos(a);
			float s = sin(a);
			v.x = rel.x * c - rel.y * s;
			v.y = rel.x * s + rel.y * c + piv;
		} else if (part > 4.5 && part < 5.5) {
			v.y += sin(ph * 2.0) * 0.05;
			v.x += sin(ph * 2.0 + 1.0) * 0.04;
		} else if (part > 7.5) {
			v.z += sin(time * 4.0 + v.y * 2.5 + ph) * 0.14 * (0.3 + max(0.0, v.y - piv));
			v.x += cos(time * 3.1 + v.y * 1.7 + ph) * 0.06;
		}
		if (!frozen) {
			v.y += abs(sin(ph)) * 0.09;
			v.x += v.y * 0.07;
		}
		v.xz *= 1.0 + flash * 2.6;
		v.y *= 1.0 - flash * 2.2;
		v.x -= flash * 3.0;
		VERTEX = v;
	}
	if (INSTANCE_CUSTOM.z > 6.5) {
		// corpses sink into the ground as they fade (polish: the noise-holed crumble with glowing edges
		// read as confetti from the game camera once a fight left dozens of bodies)
		VERTEX.y -= INSTANCE_CUSTOM.y * (has_vat ? 0.6 : 0.9);
	}
	// stand on the terrain under the instance's origin (elevation pass)
	vec3 wo = MODEL_MATRIX[3].xyz;
	VERTEX += inverse(mat3(MODEL_MATRIX)) * vec3(0.0, th(wo.xz), 0.0);
}

void fragment() {
	vec3 base = COLOR.rgb;
	float flags = mod(v_custom.w, 256.0);
	float seed = floor(COLOR.a * 63.0 + 0.5);
	bool corpse = v_custom.z > 6.5;
	// organic detail: mottled skin, darker crevices toward the feet, faint veins, per-foe variation
	vec3 mp = v_mpos * 2.2 + seed * 1.37;
	float n = vn3(mp) * 0.78 + vn3(mp * 2.3) * 0.22;     // polish: the fine octave shimmered as speckle from the game camera
	float vein = smoothstep(0.03, 0.0, abs(vn3(mp * 1.3 + 9.0) - 0.5));
	// grim and dark (loop 1: foes read as clean pink plastic)
	base = mix(base, vec3(dot(base, vec3(0.3, 0.59, 0.11))), 0.35) * 0.55;
	base *= 0.68 + 0.5 * n;
	base *= mix(0.45, 1.0, smoothstep(0.0, 1.2, v_mpos.y));
	base = mix(base, base * vec3(0.5, 0.25, 0.22), vein * 0.6);

	bool elite = mod(flags, 2.0) >= 1.0;
	bool exile = mod(floor(flags / 8.0), 2.0) >= 1.0;
	bool ally = mod(floor(flags / 64.0), 2.0) >= 1.0;
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	vec3 em = vec3(0.0);
	float rough = 0.55 + 0.3 * n;                       // wet sheen where the noise dips
	if (v_part > 5.5 && v_part < 6.5) {
		base = vec3(0.05);
		em += eye_col * 4.0;
	} else if (v_part > 6.5 && v_part < 7.5) {
		em += glow_col * (0.5 + 0.25 * sin(time * 3.0 + v_custom.x));    // shard crystals: embers, not white specks
		rough = 0.2;
	}
	vec3 sc = status_col(v_custom.z);
	if (v_custom.z > 0.5 && !corpse) {
		if (v_custom.z > 5.5) { base = mix(base, vec3(0.62, 0.8, 0.95), 0.6); rough = 0.45; }   // frosted, not mirror: rough 0.1 threw a sun glint off every facet (speckle)
		em += sc * (0.16 + fres * 0.6) * (0.85 + 0.15 * sin(time * 9.0));
	}
	if (elite) em += vec3(1.0, 0.75, 0.25) * fres * 1.4;
	if (exile) em += vec3(1.0, 0.45, 0.15) * fres * 3.0;
	if (ally) { base *= 0.4; em += vec3(0.6, 0.45, 1.0) * (0.6 + fres * 2.0); }
	float fl = clamp(v_custom.y * 10.0, 0.0, 1.0);
	// short, curved hit pop in one flat warm tone (it used to be base x2, which amplified every facet and
	// noise detail into bright dots; a hammered crowd read as confetti; found by bisecting the shader)
	em += vec3(0.95, 0.72, 0.6) * fl * fl * fl * 0.55;
	if (corpse) {
		// crumble from the edges, glowing at the burn line, then gone
		base *= 0.4 * (1.0 - 0.6 * v_custom.y);
		rough = 0.9;
		em = vec3(0.0);
	}
	ALBEDO = base;
	ROUGHNESS = rough;
	EMISSION = em;
	RIM = 0.6;
	RIM_TINT = 0.5;
}
