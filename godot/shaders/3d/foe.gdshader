shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx, cull_back;
// Instanced swarm. One baked mesh per foe kind; UV2 carries (part id, pivot height) so the vertex
// stage can walk legs, swing arms, bob heads and wave tendrils without skeletons.
// INSTANCE_CUSTOM = (walk phase (wrapped), hit flash | corpse dissolve, status code, flag bits); instance
// colour alpha = seed / 63. Instance data is stored as 16-bit halves, so every value stays small.
//   status: 0 none 1 burn 2 chill 3 shock 4 poison 5 bleed 6 frozen 7 CORPSE (lying, crumbling)
//   flags: 1 elite, 2 boss, 8 exile, 16 goblin, 64 ally;  seed 0..63 varies the skin per foe
//   custom.w = flags + 256 x Burn stacks (0..5, the Emberwitch's contagion): burn_norm = stacks / 5 drives the
//   ember crust. 1535 at most, an exact half; the VAT frame (x), flash (y) and tint (colour) are untouched.
uniform float time = 0.0;
uniform vec3 eye_col : source_color = vec3(1.0, 0.8, 0.35);
uniform vec3 glow_col : source_color = vec3(0.5, 0.85, 1.0);
// Status glow by status code (0 none 1 burn 2 chill 3 shock 4 poison 5 bleed 6 frozen): Content.status_cols(colour-blind),
// the element swatches the UI shows, set by WorldView3D.bind. source_color, so they arrive linearised: the old typed-in
// constants were read as linear (vec3(1, .15, .2) rendered #ff6c7b), which washed Bleed pink and paled every status.
uniform vec3 status_cols[7] : source_color;
// the act's Fresnel rim (WorldView3D STAGE_LOOK.rim): moonlight, neutral, frost-cyan, neutral, teal
uniform vec3 rim_col : source_color = vec3(0.0);
uniform float rim_k = 0.0;
// noise scale in model units (WorldView3D.bind, per kind): 2.2 for the 2-unit procedural meshes; the textured ones are
// modelled 26-42 units tall, where 2.2 tiled g_noise ~20x per foe, its mips averaged to 0.5 and the ember crust's
// cracks (abs(n - 0.5) < w) covered the whole body: burning foes rendered as blown cream blobs
uniform float mp_scale = 2.2;
// Vertex animation texture (Models.foe_vat, SVA3): row = frame, column = vertex (UV.x). INSTANCE_CUSTOM.x is
// then the frame coordinate into it (the CPU picks the clip and time), blended between two rows. Positions
// are RGBA8, 10 bits per axis over the clip set's box (vat_min + q / 1023 * vat_ext: RGB the top 8 bits,
// A the low 2 bits of x | y << 2 | z << 4); normals octahedral RG8.
uniform bool has_vat = false;
uniform sampler2D vat_pos : filter_nearest, repeat_disable;
uniform sampler2D vat_nrm : filter_nearest, repeat_disable;
uniform vec3 vat_min = vec3(0.0);
uniform vec3 vat_ext = vec3(1.0);
// Imported PBR foes (tools/blender/process_fal_assets.py): their own albedo, normal and roughness/metal
// maps (glTF: G roughness, B metal), the kind's colour as at most a 10% tint, no procedural mottling,
// veins or glowing parts. UV is the texture's, so their animation texture column is in UV2.x.
uniform float corpse_sink = 0.6;      // how far a corpse sinks as it fades, in model units (WorldView3D: 0.3 x height)
uniform bool has_albedo = false;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool has_normal = false;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform bool has_orm = false;
uniform sampler2D orm_tex : filter_linear_mipmap, repeat_enable;
varying flat float v_part;
// flat: per-instance values. Interpolated, a foe carrying Burn stacks (custom.w = flags + 256 x stacks) read 1279.9999
// in places, and mod(w, 256) decoded those pixels as elite + exile + ally: white-lilac specks over every Emberwitch
// pack (11-18% of its pixels above 245 luma, most of its shimmer)
varying flat vec4 v_custom;
varying vec3 v_mpos;
// bump height of the skin noise, in world units (a foe is about 40-60 units tall)
const float BUMP = 2.5;

global uniform sampler2D g_noise : filter_linear_mipmap, repeat_enable;

vec3 status_col(float s) {
	return status_cols[clamp(int(s + 0.5), 0, 6)];
}

// vat_nrm holds octahedral normals (tools/vat_pack.py): two 8-bit channels per unit vector
vec3 oct_normal(vec2 e) {
	vec2 f = e * 2.0 - 1.0;
	vec3 n = vec3(f.x, f.y, 1.0 - abs(f.x) - abs(f.y));
	float t = clamp(-n.z, 0.0, 1.0);
	n.x += n.x >= 0.0 ? -t : t;
	n.y += n.y >= 0.0 ? -t : t;
	return normalize(n);
}

vec3 vat_p(int vi, int row) {
	vec4 t = texelFetch(vat_pos, ivec2(vi, row), 0);
	vec3 h = floor(t.rgb * 255.0 + 0.5);
	float a = floor(t.a * 255.0 + 0.5);
	vec3 l = vec3(mod(a, 4.0), mod(floor(a * 0.25), 4.0), floor(a * 0.0625));
	return vat_min + (h * 4.0 + l) * (vat_ext * (1.0 / 1023.0));
}

void vertex() {
	v_custom = INSTANCE_CUSTOM;
	v_mpos = VERTEX;
	float part = has_albedo ? 0.0 : floor(UV2.x + 0.5);
	float piv = UV2.y;
	v_part = part;
	if (has_vat) {
		ivec2 sz = textureSize(vat_pos, 0);
		int vi = clamp(int((has_albedo ? UV2.x : UV.x) * float(sz.x)), 0, sz.x - 1);
		float fr = clamp(INSTANCE_CUSTOM.x, 0.0, float(sz.y - 2));
		int f0 = int(floor(fr));
		VERTEX = mix(vat_p(vi, f0), vat_p(vi, f0 + 1), fr - float(f0));
		vec3 n1 = oct_normal(texelFetch(vat_nrm, ivec2(vi, f0), 0).xy);
		if (has_normal) {
			// the normal map's tangent frame turns with the animated normal (shortest-arc rotation)
			vec3 ax = cross(NORMAL, n1);
			float sn = length(ax);
			float cs = dot(NORMAL, n1);
			if (sn > 1e-4) {
				ax /= sn;
				TANGENT = TANGENT * cs + cross(ax, TANGENT) * sn + ax * dot(ax, TANGENT) * (1.0 - cs);
				BINORMAL = BINORMAL * cs + cross(ax, BINORMAL) * sn + ax * dot(ax, BINORMAL) * (1.0 - cs);
			}
		}
		NORMAL = n1;
		v_mpos = VERTEX;
		// the hit squash (as in the procedural branch below) for the animated foes too: every common kind (grunt,
		// runner, brute, spitter, charger) has an animation texture, so a hit was the emission pop alone. After v_mpos,
		// so the skin noise stays on the body; feet at y 0, so the body squats onto them
		if (INSTANCE_CUSTOM.z < 6.5) {
			float hf = INSTANCE_CUSTOM.y;
			VERTEX.xz *= 1.0 + hf * 1.5;
			VERTEX.y *= 1.0 - hf * 1.2;
		}
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
		VERTEX.y -= INSTANCE_CUSTOM.y * corpse_sink;
	}
	// no terrain lookup here: WorldView3D writes the ground height under each foe into its instance
	// transform (_write_foes, _write_corpses), so this stage does no height texture fetches
}

void fragment() {
	vec3 base = COLOR.rgb;
	float flags = mod(v_custom.w, 256.0);
	float seed = floor(COLOR.a * 63.0 + 0.5);
	bool corpse = v_custom.z > 6.5;
	// organic detail: mottled skin, darker crevices toward the feet, faint veins, per-foe variation
	vec3 mp = v_mpos * mp_scale + seed * 1.37;
	// one lookup in the shared noise texture (a sheared projection of the model position, so no axis
	// shows stretching) replaces three 3D value noises = 24 hash evaluations per pixel of every foe
	vec4 nz = texture(g_noise, (mp.xy + mp.z * vec2(0.71, 0.37)) * 0.2);
	float n = clamp(0.5 + (nz.r - 0.5) * 1.25, 0.0, 1.0);
	float rough = 0.35 + 0.5 * n;                       // 0.35 wet sheen where the noise dips .. 0.85 dry hide
	float metal = 0.0;
	if (has_albedo) {
		vec3 tint = COLOR.rgb / max(0.001, max(COLOR.r, max(COLOR.g, COLOR.b)));
		base = texture(albedo_tex, UV).rgb * mix(vec3(1.0), tint, 0.1);
		if (has_normal) NORMAL_MAP = texture(normal_tex, UV).rgb;
		// ORM baked from the 16k-triangle mesh (process_fal_assets.py): R ambient occlusion darkens the
		// sculpted creases the 1,800-triangle mesh lost, G roughness, B metal
		if (has_orm) { vec3 orm = texture(orm_tex, UV).rgb; base *= mix(0.65, 1.0, orm.r); rough = orm.g; metal = orm.b; }
		else rough = 0.75;
	} else {
	// the same noise as a bump: screen-space surface gradient (Mikkelsen 2010), no extra texture taps.
	// dFdx / dFdy of the view-space position and of the noise height give the gradient of the height
	// over the surface, which tilts the normal: mottled skin catches the light instead of reading flat
	vec3 dpx = dFdx(VERTEX);
	vec3 dpy = dFdy(VERTEX);
	vec3 r1 = cross(dpy, NORMAL);
	vec3 r2 = cross(NORMAL, dpx);
	float det = dot(dpx, r1);
	vec3 sgrad = (dFdx(nz.r) * r1 + dFdy(nz.r) * r2) * sign(det);
	vec3 bn = normalize(abs(det) * NORMAL - BUMP * sgrad);
	if (abs(det) > 1e-8) NORMAL = bn;
	float vein = smoothstep(0.035, 0.0, abs(nz.b - 0.5));
	// grim but readable: 15% desaturated at 85% brightness (35% at 55% sank the swarm into dark floors)
	base = mix(base, vec3(dot(base, vec3(0.3, 0.59, 0.11))), 0.15) * 0.85;
	base *= 0.68 + 0.5 * n;
	base *= mix(0.45, 1.0, smoothstep(0.0, 1.2, v_mpos.y));
	base = mix(base, base * vec3(0.5, 0.25, 0.22), vein * 0.6);
	}

	// ember crust (contagion): the hide chars and the noise's ridges crack open, glowing and flickering
	// hotter with every stack. Plain texture/trig math only (GLES3 and Mali safe: no inverse(), no loops).
	float burn_n = clamp(floor(v_custom.w / 256.0 + 0.001) * 0.2, 0.0, 1.0);
	vec3 crust = vec3(0.0);
	if (burn_n > 0.0 && !corpse) {
		// thin cracks (the noise's 0.5 crossings) widen a little with the stacks; the char darkens the hide
		// between them, so the glow reads as lines of fire on a black crust, not a white blob
		// anti-aliased: the edge widened to the pixel footprint, and a crack thinner than a pixel fades to its area
		// (cw / (cw + aw)) instead of breaking up into specks that crawl as the camera moves
		float cw = 0.06 * (1.0 + burn_n);
		float aw = fwidth(nz.g) * 3.0;
		float crack = smoothstep(cw + aw, 0.0, abs(nz.g - 0.5)) * cw / (cw + aw);
		float flick = 0.75 + 0.25 * sin(time * 13.0 + seed * 2.3 + v_mpos.y * mp_scale * 1.364) * sin(time * 7.3 + seed);
		base *= 1.0 - 0.8 * burn_n;
		rough = mix(rough, 0.9, burn_n * 0.6);
		vec3 fire = mix(vec3(0.9, 0.16, 0.02), vec3(1.0, 0.42, 0.06), burn_n);
		crust = fire * (crack * (0.5 + 1.0 * burn_n) + 0.05 * burn_n) * flick;
	}
	bool elite = mod(flags, 2.0) >= 1.0;
	bool exile = mod(floor(flags / 8.0), 2.0) >= 1.0;
	bool ally = mod(floor(flags / 64.0), 2.0) >= 1.0;
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	vec3 em = vec3(0.0);
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
		// fresnel 0.4, not 0.6: at 0.6 ACES pushed a red rim toward white (the swatch's colour, not a paler one)
		em += sc * (0.16 + fres * 0.4) * (0.85 + 0.15 * sin(time * 9.0)) * (1.0 - 0.6 * burn_n);   // the crust shows Burn
	}
	em += crust;
	// a status takes the act's rim: the two were added, and Act I's moon-cyan over Bleed's red read pastel pink
	if (!corpse && v_custom.z < 0.5) em += rim_col * fres * rim_k;
	if (elite) em += vec3(1.0, 0.75, 0.25) * fres * 1.4;
	if (exile) em += vec3(1.0, 0.45, 0.15) * fres * 3.0;
	if (ally) { base *= 0.4; em += vec3(0.6, 0.45, 1.0) * (0.6 + fres * 2.0); }
	float fl = clamp(v_custom.y * 10.0, 0.0, 1.0);
	// short, curved hit pop in one flat warm tone (it used to be base x2, which amplified every facet and
	// noise detail into bright dots; a hammered crowd read as confetti; found by bisecting the shader). Squared, not
	// cubed: cubed, four frames after a hit (60 fps) only 4-13% of a foe's pixels still differed by 5 dE00
	em += vec3(0.95, 0.72, 0.6) * fl * fl * 0.55;
	if (corpse) {
		// crumble from the edges, glowing at the burn line, then gone
		base *= 0.4 * (1.0 - 0.6 * v_custom.y);
		rough = 0.9;
		em = vec3(0.0);
	}
	ALBEDO = base;
	ROUGHNESS = rough;
	METALLIC = metal;
	EMISSION = em;
	RIM = 0.75;                                          // a crisp edge light: silhouettes against the ground
	RIM_TINT = 0.5;
}
