shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
// Character material (heroes, bosses, exiles). Procedural surface detail in part-local space so it
// sticks to the part while it animates:
//   kind 0 cloth   : weave, fold shading, frayed darkening toward hems
//   kind 1 leather : mottled grain, scuffs, low sheen
//   kind 2 metal   : worn bright edges (fresnel + noise), pitted grime, dents in roughness
//   kind 3 skin    : soft wrap lighting with a warm subsurface tint
//   kind 4 glow    : emissive rune / crystal, pulsing with `pulse`
//   kind 5 crystal : glassy, fresnel-lit, internal glow
uniform vec3 albedo : source_color = vec3(0.6);
uniform float roughness = 0.7;
uniform float metallic = 0.0;
uniform int kind = 0;
uniform vec3 emission : source_color = vec3(0.0);
uniform float emission_energy = 0.0;
uniform float pulse = 0.0;
uniform float flash = 0.0;
uniform vec3 flash_col : source_color = vec3(1.0, 0.15, 0.1);
uniform float grime = 0.4;
uniform float time = 0.0;
varying vec3 opos;

float h31(vec3 p) { return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453); }
float vn3(vec3 p) {
	vec3 i = floor(p); vec3 f = fract(p);
	vec3 u = f * f * (3.0 - 2.0 * f);
	float a = mix(mix(h31(i), h31(i + vec3(1, 0, 0)), u.x), mix(h31(i + vec3(0, 1, 0)), h31(i + vec3(1, 1, 0)), u.x), u.y);
	float b = mix(mix(h31(i + vec3(0, 0, 1)), h31(i + vec3(1, 0, 1)), u.x), mix(h31(i + vec3(0, 1, 1)), h31(i + vec3(1, 1, 1)), u.x), u.y);
	return mix(a, b, u.z);
}
float fbm3(vec3 p) { return vn3(p) * 0.55 + vn3(p * 2.1 + 7.0) * 0.3 + vn3(p * 4.3 + 13.0) * 0.15; }

void vertex() {
	vec3 scl = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	opos = VERTEX * scl;
}

void fragment() {
	float n = fbm3(opos * 0.35);
	float fine = vn3(opos * 2.5);
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.0);
	vec3 col = albedo;
	float rough = roughness;
	float metal = metallic;
	vec3 em = emission * emission_energy;
	if (kind == 0) {
		float weave = 0.5 + 0.5 * sin(UV.x * 260.0) * sin(UV.y * 260.0);
		col *= 0.78 + 0.25 * n + 0.06 * weave;
		col *= 1.0 - grime * smoothstep(0.55, 0.85, fbm3(opos * 0.12 + 3.0)) * 0.5;
		rough = clamp(roughness + 0.1, 0.0, 1.0);
	} else if (kind == 1) {
		col *= 0.65 + 0.45 * n;
		col = mix(col, col * 1.5, smoothstep(0.82, 0.95, fine) * 0.4);       // scuffs
		rough = roughness - 0.15 * fine;
	} else if (kind == 2) {
		float pits = smoothstep(0.6, 0.9, fbm3(opos * 0.5 + 9.0));
		col *= 0.75 + 0.3 * n - pits * grime * 0.45;
		col += vec3(0.45) * fres * smoothstep(0.35, 0.75, n);               // worn bright edges
		rough = clamp(roughness + 0.25 * pits - 0.1 * fres, 0.08, 1.0);
	} else if (kind == 3) {
		col *= 0.92 + 0.12 * n;
		col = mix(col, col * vec3(1.08, 0.94, 0.9), 0.5);        // warm skin tint (no SSS on Mobile)
		rough = 0.6;
	} else if (kind == 4) {
		em = emission * emission_energy * (0.8 + 0.4 * n) * (1.0 + pulse);
	} else {
		col *= 0.6 + 0.4 * n;
		em += emission * (fres * 2.5 + 0.4 * n) * max(emission_energy, 0.5) * (1.0 + pulse);
		rough = 0.08;
	}
	ALBEDO = col;
	ROUGHNESS = rough;
	METALLIC = metal;
	EMISSION = em + flash_col * flash;
	RIM = 0.55;
	RIM_TINT = 0.35;
}
