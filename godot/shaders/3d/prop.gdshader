shader_type spatial;
render_mode diffuse_burley;
// Instanced props. Tail channel sways in the wind; glow channel (crystals) emits the stage accent.
// Props fade out (dithered) when they stand between the camera and the hero.
uniform float time = 0.0;
uniform vec3 tint : source_color = vec3(1.0);
uniform vec3 glow_col : source_color = vec3(0.5, 0.85, 1.0);
uniform vec3 hero_pos = vec3(0.0);
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
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	// screen-door fade near the camera-to-hero line (taller props only matter there)
	vec3 to_h = wpos - hero_pos;
	float near = (to_h.z > -10.0 && to_h.z < 140.0 && abs(to_h.x) < 45.0 && wpos.y > 18.0) ? 1.0 : 0.0;
	if (near > 0.5) {
		float dither = fract(dot(FRAGCOORD.xy, vec2(0.5, 0.25)) + 0.25 * mod(FRAGCOORD.y, 2.0));
		if (dither < 0.7) discard;
	}
	ALBEDO = COLOR.rgb * tint;
	ROUGHNESS = 0.9;
	if (v_part > 6.5 && v_part < 7.5) {
		ALBEDO = mix(ALBEDO, glow_col, 0.5);
		EMISSION = glow_col * (1.4 + 0.5 * sin(time * 2.0 + wpos.x * 0.05));
		ROUGHNESS = 0.15;
	}
}
