shader_type canvas_item;
// One draw call for the whole swarm. Each MultiMesh instance is a quad; the body is an SDF built
// from a per-kind polar profile, shaded with a fake top-left light, outlined, given eyes, and
// tinted by status. INSTANCE_CUSTOM = (kind, hit flash, status code, flags).
//   status: 0 none, 1 burn, 2 chill, 3 shock, 4 poison, 5 bleed, 6 frozen
//   flags bits: 1 elite, 2 boss, 4 breach, 8 exile, 16 goblin, 64 ally (ethereal)

uniform float time = 0.0;
uniform bool colorblind = false;
varying vec4 v_custom;
varying vec4 v_col;

const float BASE[12] = float[](0.62, 0.55, 0.64, 0.6, 0.6, 0.5, 0.58, 0.55, 0.6, 0.6, 0.66, 0.6);
const float AMP[12]  = float[](0.04, 0.10, 0.06, 0.03, 0.10, 0.12, 0.14, 0.16, 0.05, 0.03, 0.08, 0.18);
const float LOBES[12]= float[](5.0, 2.0, 4.0, 6.0, 6.0, 4.0, 3.0, 9.0, 3.0, 8.0, 7.0, 5.0);

vec3 status_col(float s) {
	if (colorblind) {
		if (s < 0.5) return vec3(0.0);
		if (s < 1.5) return vec3(0.9, 0.62, 0.0);
		if (s < 2.5) return vec3(0.34, 0.71, 0.91);
		if (s < 3.5) return vec3(0.94, 0.89, 0.26);
		if (s < 4.5) return vec3(0.0, 0.62, 0.45);
		if (s < 5.5) return vec3(0.84, 0.37, 0.0);
		return vec3(0.8, 0.95, 1.0);
	}
	if (s < 0.5) return vec3(0.0);
	if (s < 1.5) return vec3(1.0, 0.54, 0.24);
	if (s < 2.5) return vec3(0.5, 0.9, 1.0);
	if (s < 3.5) return vec3(0.9, 0.82, 0.29);
	if (s < 4.5) return vec3(0.49, 1.0, 0.42);
	if (s < 5.5) return vec3(1.0, 0.29, 0.37);
	return vec3(0.8, 0.95, 1.0);
}

void vertex() {
	v_custom = INSTANCE_CUSTOM;
	v_col = COLOR;
}

void fragment() {
	int kind = int(v_custom.x + 0.5);
	float flags = v_custom.w;
	bool elite = mod(flags, 2.0) >= 1.0;
	bool ally = mod(floor(flags / 64.0), 2.0) >= 1.0;
	vec2 p = (UV - 0.5) * 2.0 * 1.25;            // quad is 1.25x the body so the rim glow fits
	float ang = atan(p.y, p.x);
	float seed = v_col.a * 50.0;
	float wob = sin(time * 3.0 + seed) * 0.02;
	float prof = BASE[kind] + AMP[kind] * cos(LOBES[kind] * ang + seed + time * (kind == 7 ? 2.0 : 0.3)) + wob;
	if (kind == 2) prof += 0.08 * smoothstep(-0.2, -1.0, p.y);       // brute: hunched top
	float d = length(p) - prof;                                        // < 0 inside the body
	vec3 base = v_col.rgb;
	vec4 outc = vec4(0.0);
	// rim glow for elites (gold), exiles (orange), allies (ethereal violet)
	if (elite || kind >= 9 || ally) {
		vec3 gc = ally ? vec3(0.75, 0.6, 1.0) : (kind == 9 ? vec3(1.0, 0.55, 0.2) : vec3(1.0, 0.85, 0.3));
		float g = smoothstep(0.35, 0.0, d) * (0.55 + 0.25 * sin(time * 6.0 + seed));
		outc = vec4(gc, g * 0.6);
	}
	if (d < 0.0) {
		// fake lighting: brighter toward the top-left, darker toward the bottom-right
		float lit = clamp(0.62 - dot(normalize(p + vec2(0.0001)), vec2(0.55, 0.65)) * 0.35 - length(p) * 0.15, 0.0, 1.0);
		vec3 c = mix(base * 0.55, base * 1.25, lit);
		// crystalline facets on shard creatures
		if (kind == 4 || kind == 5 || kind == 11) c *= 0.9 + 0.2 * step(0.0, sin(ang * 3.0 + p.x * 4.0));
		// eyes (front-facing pair) on organic kinds
		if (kind != 4 && kind != 5 && kind != 11) {
			vec2 e1 = p - vec2(-0.2, -0.12);
			vec2 e2 = p - vec2(0.2, -0.12);
			float eye = min(length(e1 * vec2(1.0, 0.8)), length(e2 * vec2(1.0, 0.8)));
			c = mix(c, vec3(0.06, 0.05, 0.09), smoothstep(0.11, 0.08, eye));
			float glint = min(length(e1 - vec2(0.03, -0.03)), length(e2 - vec2(0.03, -0.03)));
			c = mix(c, (kind == 10 || kind == 9) ? vec3(1.0, 0.3, 0.2) : vec3(1.0), smoothstep(0.04, 0.02, glint));
		}
		// status tint and a pulsing ring just inside the outline
		vec3 sc = status_col(v_custom.z);
		if (v_custom.z > 0.5) {
			c = mix(c, sc, v_custom.z > 5.5 ? 0.7 : 0.25);
			c = mix(c, sc, smoothstep(-0.14, -0.04, d) * (0.6 + 0.4 * sin(time * 8.0)));
		}
		if (ally) c = mix(c, vec3(0.7, 0.6, 1.0), 0.5);
		c = mix(c, vec3(1.0), clamp(v_custom.y * 9.0, 0.0, 1.0));         // hit flash
		float edge = smoothstep(-0.07, -0.03, d);                          // dark outline
		c = mix(c, vec3(0.05, 0.06, 0.1), edge);
		float a = smoothstep(0.0, -0.02, d) * (ally ? 0.7 : 1.0);
		outc = mix(outc, vec4(c, 1.0), a);
	}
	COLOR = outc;
}
