shader_type spatial;
render_mode diffuse_burley;
// Instanced props. Tail channel sways in the wind; glow channel (crystals) emits the stage accent.
// Fully opaque, no discard: props keep the GPU's early depth rejection. A hero standing behind a tall
// prop is shown by the hero's own silhouette pass (HeroRig, depth_test_inverted) instead of the old
// dithered fade, which discarded pixels on every prop.
uniform float time = 0.0;
uniform vec3 tint : source_color = vec3(1.0);
uniform vec3 glow_col : source_color = vec3(0.5, 0.85, 1.0);
// (x, z, radius, strength): the hero, shockwaves and a few bodies push foliage aside (EnvFX._pushers)
uniform vec4 pushers[4];
uniform int push_n = 4;              // 0 on the Low tier: foliage only sways
varying flat float v_part;
varying vec3 wpos;
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
}
void fragment() {
	ALBEDO = COLOR.rgb * tint;
	ROUGHNESS = 0.9;
	if (v_part > 6.5 && v_part < 7.5) {
		ALBEDO = mix(ALBEDO, glow_col, 0.35);
		EMISSION = glow_col * (0.6 + 0.25 * sin(time * 1.2 + wpos.x * 0.05));       // accents, not beacons
		ROUGHNESS = 0.15;
	}
}
