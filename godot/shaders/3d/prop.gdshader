shader_type spatial;
render_mode diffuse_burley;
// Instanced props. Tail channel sways in the wind; glow channel (crystals) emits the stage accent.
// Fully opaque, no discard: props keep the GPU's early depth rejection. A hero standing behind a tall
// prop is shown by the hero's own silhouette pass (HeroRig.XRAY_CODE: depth_test_inverted, masked by
// the stencil the hero writes) instead of the old dithered fade, which discarded pixels on every prop.
// Surface: the shared noise (g_noise, world space) breaks up each prop's flat vertex colour by +-14% and
// sets its roughness between 0.55 and 0.92; the base darkens where it meets the ground (AO over the first
// 16 units); a 0.35 rim light outlines it against the ground.
global uniform sampler2D g_noise : filter_linear_mipmap, repeat_enable;
uniform float time = 0.0;
uniform vec3 tint : source_color = vec3(1.0);
uniform vec3 glow_col : source_color = vec3(0.5, 0.85, 1.0);
// (x, z, radius, strength): the hero, shockwaves and a few bodies push foliage aside (EnvFX._pushers)
uniform vec4 pushers[4];
uniform int push_n = 4;              // 0 on the Low tier: foliage only sways
varying flat float v_part;
varying vec3 wpos;
varying float v_h;                   // height above the prop's own origin (its foot on the ground)
void vertex() {
	float part = floor(UV2.x + 0.5);
	v_part = part;
	vec3 wroot = MODEL_MATRIX[3].xyz;
	if (part > 7.5) {
		float sway = sin(time * 1.7 + wroot.x * 0.02 + wroot.z * 0.03) * 0.08 * max(0.0, VERTEX.y);
		VERTEX.x += sway;
		VERTEX.z += sway * 0.6;
	}
	vec3 wv = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	if (part > 7.5) {                                      // swaying parts also bend away from bodies
		vec2 off = vec2(0.0);
		float flat_k = 0.0;
		for (int i = 0; i < 4; i++) {
			if (i >= push_n) break;
			vec4 q = pushers[i];
			if (q.z <= 0.0) break;
			vec2 d = wv.xz - q.xy;
			float l = length(d);
			float k = clamp(1.0 - l / q.z, 0.0, 1.0);
			off += (l > 0.01 ? d / l : vec2(0.0)) * k * q.w;
			flat_k = max(flat_k, k * min(q.w / 12.0, 1.0));
		}
		float hgt = max(0.0, wv.y - wroot.y);
		vec3 woff = vec3(off.x, -hgt * flat_k * 0.6, off.y) * min(1.0, hgt / 10.0);
		// world offset back to model space without inverse(): a prop's basis is a rotation about Y times a
		// per-axis scale, so its columns are orthogonal and each model axis is dot(offset, column) / |column|^2
		vec3 c0 = MODEL_MATRIX[0].xyz;
		vec3 c1 = MODEL_MATRIX[1].xyz;
		vec3 c2 = MODEL_MATRIX[2].xyz;
		VERTEX += vec3(dot(woff, c0) / dot(c0, c0), dot(woff, c1) / dot(c1, c1), dot(woff, c2) / dot(c2, c2));
		wv += woff;
	}
	wpos = wv;
	v_h = wv.y - wroot.y;
}
void fragment() {
	// two lookups: one projected from above (tops), one from the side (trunks, rock faces), mixed by the
	// normal, so neither streaks; r = albedo breakup, g = roughness
	vec3 wn = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
	vec2 top = texture(g_noise, wpos.xz * (1.0 / 64.0)).rg;
	vec2 side = texture(g_noise, vec2(wpos.x + wpos.z, wpos.y) * (1.0 / 48.0)).rg;
	vec2 nz = mix(side, top, smoothstep(0.35, 0.8, abs(wn.y)));
	ALBEDO = COLOR.rgb * tint * (0.86 + 0.28 * nz.r);
	ROUGHNESS = mix(0.55, 0.92, nz.g);
	// contact occlusion at the foot: ambient fully, direct light partly (AO_LIGHT_AFFECT), so a prop sits on
	// the ground instead of hovering; foliage blades (part 8+) are thin and get half of it
	float ao = mix(0.5, 1.0, smoothstep(0.0, 16.0, v_h));
	AO = v_part > 7.5 ? mix(1.0, ao, 0.5) : ao;
	AO_LIGHT_AFFECT = 0.3;
	RIM = 0.35;
	RIM_TINT = 0.4;
	if (v_part > 6.5 && v_part < 7.5) {
		ALBEDO = mix(ALBEDO, glow_col, 0.35);
		EMISSION = glow_col * (0.6 + 0.25 * sin(time * 1.2 + wpos.x * 0.05));       // accents, not beacons
		ROUGHNESS = 0.15;
	}
}
