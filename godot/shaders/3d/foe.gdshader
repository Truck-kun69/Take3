shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx, cull_back;
// Instanced swarm. One baked mesh per foe kind; UV2 carries (part id, pivot height) so the vertex
// stage can walk legs, swing arms, bob heads and wave tendrils without skeletons.
// INSTANCE_CUSTOM = (walk phase, hit flash, status code, flag bits)
//   status: 0 none 1 burn 2 chill 3 shock 4 poison 5 bleed 6 frozen
//   flags: 1 elite, 2 boss, 8 exile, 16 goblin, 64 ally
uniform float time = 0.0;
uniform vec3 eye_col : source_color = vec3(1.0, 0.8, 0.35);
uniform vec3 glow_col : source_color = vec3(0.5, 0.85, 1.0);
uniform bool colorblind = false;
varying flat float v_part;
varying vec4 v_custom;

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
	float part = floor(UV2.x + 0.5);
	float piv = UV2.y;
	v_part = part;
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
		v.x += v.y * 0.07;                                   // lean into the chase
	}
	// hit reaction: squash and a recoil away from the facing direction
	v.xz *= 1.0 + flash * 2.6;
	v.y *= 1.0 - flash * 2.2;
	v.x -= flash * 3.0;
	VERTEX = v;
}

void fragment() {
	vec3 base = COLOR.rgb;
	float flags = v_custom.w;
	bool elite = mod(flags, 2.0) >= 1.0;
	bool exile = mod(floor(flags / 8.0), 2.0) >= 1.0;
	bool ally = mod(floor(flags / 64.0), 2.0) >= 1.0;
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	vec3 em = vec3(0.0);
	float rough = 0.72;
	if (v_part > 5.5 && v_part < 6.5) {
		base = vec3(0.05);
		em += eye_col * 4.0;
	} else if (v_part > 6.5 && v_part < 7.5) {
		em += glow_col * (1.2 + 0.6 * sin(time * 3.0 + v_custom.x));
		rough = 0.2;
	}
	vec3 sc = status_col(v_custom.z);
	if (v_custom.z > 0.5) {
		if (v_custom.z > 5.5) { base = mix(base, vec3(0.7, 0.9, 1.0), 0.75); rough = 0.1; }
		em += sc * (0.25 + fres * 2.2) * (0.8 + 0.2 * sin(time * 9.0));
	}
	if (elite) em += vec3(1.0, 0.75, 0.25) * fres * 2.5;
	if (exile) em += vec3(1.0, 0.45, 0.15) * fres * 3.0;
	if (ally) { base *= 0.4; em += vec3(0.6, 0.45, 1.0) * (0.6 + fres * 2.0); }
	float fl = clamp(v_custom.y * 10.0, 0.0, 1.0);
	em += mix(base, vec3(1.0), 0.6) * fl * fl * fl * 1.6;    // short, curved hit flash (a pop, not a strobe)
	ALBEDO = base;
	ROUGHNESS = rough;
	EMISSION = em;
	RIM = 0.25;
	RIM_TINT = 0.4;
}
