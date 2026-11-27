class_name WorldView3D
extends Node3D
## 3D renderer for a World (the simulation is unchanged: sim (x, y) maps to 3D (x, height, y)).
##
## Look and feel targets Path of Exile 2: a ~52-degree perspective camera that leads the hero
## slightly, ACES tonemapping with bloom on every emissive spell, distance fog in the stage colour,
## a low sun with real shadows, a flickering torch on the hero, and a pool of eight dynamic lights
## re-assigned every frame to the brightest effects (novas, reactions, strikes, meteors, loot).
##
## Draw-call budget: terrain 1, each prop kind 1, each foe kind 1 (MultiMesh), glow sprites 1,
## gems 1, debris 1, projectiles 1, blades 1, pickups 4, beams 1, lightning 1, decal pool <= 96.

## "sky" / "gnd": the hemisphere the ambient light comes from (ProceduralSkyMaterial, AMBIENT_SOURCE_SKY):
## a cool sky above, a dark warm ground below, so tops of things read cool and undersides warm and dim.
const STAGE_LOOK := [
	{"sky": Color(0.314, 0.364, 0.429), "gnd": Color(0.09, 0.065, 0.04), "sun": Color(0.75, 0.85, 1.0), "amb": Color(0.25, 0.34, 0.45), "fog": Color(0.1, 0.16, 0.18), "bg": Color(0.03, 0.06, 0.05), "eye": Color(1.0, 0.85, 0.3),
		"rim": Color(0.6, 0.7, 1.0)},                     # I: moonlight, bluer than Chill's ice (dE00 6.4 -> 10.5)
	{"sky": Color(0.34, 0.3, 0.44), "gnd": Color(0.13, 0.055, 0.03), "sun": Color(1.0, 0.62, 0.4), "amb": Color(0.45, 0.25, 0.18), "fog": Color(0.22, 0.08, 0.05), "bg": Color(0.08, 0.03, 0.02), "eye": Color(1.0, 0.6, 0.2),
		"rim": Color(0.85, 0.85, 0.85), "clutter": Color(2.6, 0.58, 0.45), "sat": 0.75},     # II: neutral (molten-amber sat on Burn's hue and the red ground)
	{"sky": Color(0.3, 0.32, 0.5), "gnd": Color(0.09, 0.065, 0.06), "sun": Color(0.7, 0.75, 1.0), "amb": Color(0.3, 0.3, 0.45), "fog": Color(0.1, 0.09, 0.16), "bg": Color(0.03, 0.03, 0.06), "eye": Color(0.5, 1.0, 0.85),
		"rim": Color(0.74, 1.0, 0.98)},                   # III: frost-cyan
	{"sky": Color(0.17, 0.32, 0.54), "gnd": Color(0.08, 0.055, 0.05), "sun": Color(0.6, 0.85, 1.0), "amb": Color(0.15, 0.3, 0.5), "fog": Color(0.03, 0.08, 0.16), "bg": Color(0.01, 0.03, 0.07), "eye": Color(1.0, 0.3, 0.85),
		"rim": Color(0.85, 0.85, 0.85), "sat": 0.75},      # IV: neutral (rift-violet foes sank 14 luma under the blue ground)
	{"sky": Color(0.22, 0.33, 0.38), "gnd": Color(0.09, 0.075, 0.05), "sun": Color(0.9, 0.74, 0.5), "amb": Color(0.2, 0.3, 0.32), "fog": Color(0.07, 0.12, 0.13), "bg": Color(0.02, 0.04, 0.05), "eye": Color(0.6, 1.0, 0.85),
		"rim": Color(0.2, 1.0, 0.8), "rim_k": 0.35}                      # V: bioluminescent-teal; a candle-warm sun (same luma as the
		                                                  # old 0.62, 0.78, 0.8): Act I's cool light gave V Act I's colours
]
## The act's Fresnel rim (STAGE_LOOK.rim) on foes (foe.gdshader rim_col) and rogue exiles (HeroRig.set_rim). 0.6 on
## foes: at 0.45 a foe without a status sat within 3 luma of the ground beside it in Acts I, II and IV.
const RIM_FOE := 0.6
## Saturation: 0.95 by default, 0.75 in Acts II and IV (sat). The tone curve (tone_curve) raises chroma 12-22%, so
## these keep each act's chroma where it was before the curve, and still lower II's and IV's.
const SAT := 0.95
const RIM_HERO := 0.35
## The hero's own rim, in the hero's colour (the ring's): in the act's rim the hero wore the foes' outline.
const RIM_OWN := 0.6
## The sky's energy: the ambient light (AMBIENT_SOURCE_SKY at full sky contribution, so the environment's own
## ambient energy is ignored). Set once per run: its radiance map re-filters over several frames.
const SKY_ENERGY := 1.8
## Fog: at 0.0007 the ground 500-890 units from the camera took 29-46% of the near-black fog colour.
const FOG_DENSITY := 0.00035
const FOG_GLOOM := 0.0009
const CHUNK := 640.0
## Godot's omni falloff is distance^-attenuation in world units. This world is ~60 units per hero,
## so the default-ish 1.0-1.6 falloff made every light ~0.002x as bright (cycle G2 finding).
## All lights use a gentle 0.5 falloff and energies scaled by LIGHT_GAIN to compensate.
const LIGHT_ATT := 0.5
const LIGHT_GAIN := 5.5
const FOE_STRIDE := 20

var w: World
var cam: Camera3D
var test_nudge := Vector3.ZERO      # tests/shimmer.gd moves the camera by a fraction of a pixel
## The cold open (ColdOpen) flies the camera itself: cine_pos looking at cine_look, the hero hidden until
## hide_hero clears. Everything that follows the camera (ground tiles, water, sun, terrain texture) follows it.
var cine := false
var cine_pos := Vector3.ZERO
var cine_look := Vector3.ZERO
var hide_hero := false
const CINE_FOG := 0.0012
var env: Environment
var sun: DirectionalLight3D
var torch: OmniLight3D
var key_light: OmniLight3D        # small fill on the camera side of the hero so the character always reads
var light_pool: Array[OmniLight3D] = []
var ground: Node3D                 # holds GROUND_TILES x GROUND_TILES mesh tiles
var terrain_mat: ShaderMaterial
var foe_mats: Array[ShaderMaterial] = []     # one per foe kind (same shader; each has its own animation texture)
var _vc: Array = []                           # per kind: PackedFloat32Array of clip [first row, frames, fps] x 5, or empty
var prop_mat: ShaderMaterial
var decal_mat: ShaderMaterial
var hero: HeroRig
var boss_rigs := {}            # uid -> BossRig
var boss_dying: Array = []     # [BossRig, seconds left, Vector2 ground position]: a fallen boss plays its die clip
const BOSS_SINK := 0.8         # the last seconds of a fallen boss: it sinks into the ground, then goes
var fx: FX3D
var env_fx: EnvFX
var time := 0.0
var view_scale := 1.0
var _cam_pos := Vector3.ZERO
var _cam_target := Vector3.ZERO
var _foe_mm: Array[MultiMeshInstance3D] = []
var _foe_n := PackedInt32Array()
var _foe_cap := PackedInt32Array()       # instances allocated per kind's MultiMesh (a power of two, grows only)
const GROUND_SIZE := 2200.0
var GROUND_Q := 20.0            # ground grid spacing, set per graphics tier (Quality.ground_q)
var water: MeshInstance3D
var water_mat: ShaderMaterial
var _cam_y := 0.0
## Fraction of a simulation tick since the latest one (FixedStep.alpha), set by Main after each frame's
## ticks. Moving things are drawn at prev.lerp(now, alpha) (World._snapshot); 1 draws the latest tick.
var alpha := 1.0
var hero_p := Vector2.ZERO            # the hero's drawn position this frame (between the last two ticks)
var hero_y := 0.0                     # and height: the ground, or the jump arc (_hero_height)
var _hero_jp := -1.0                  # drawn jump progress 0..1, -1 on the ground (jump_drawn)
const SNAP_DIST2 := 120.0 * 120.0     # farther than this in one tick is a teleport: drawn where it landed
var _ipos := PackedVector2Array()     # per swarm slot: the drawn position this frame (written by _foes)
var _prop_cells := {}        # Vector2i chunk -> Node3D holding one MultiMesh per prop kind (culled and LOD'd per cell)
var _chunk_key := ""
var _look: Dictionary
var cost_us := 0.0
var profile := false                 # tests/render_bench.tscn: time each part of the frame into prof_us
var prof_us := {}
var _prof_t := 0
func _prof_part(part: String, start: int = -1) -> void:
	var now := Time.get_ticks_usec()
	if start >= 0:
		_prof_t = start
		return
	prof_us[part] = float(prof_us.get(part, 0.0)) + float(now - _prof_t)
	_prof_t = now
var sky_mat: ProceduralSkyMaterial

func _ready() -> void:
	cam = Camera3D.new()
	cam.fov = 40.0
	cam.near = 10.0
	cam.far = 6000.0
	add_child(cam)
	var we := WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	# the sky is never drawn (the camera looks down); it is the ambient light and what metal reflects:
	# per act a cool sky over a dark warm ground (STAGE_LOOK sky / gnd), lighting tops cool and undersides warm
	sky_mat = ProceduralSkyMaterial.new()
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_64          # only diffuse ambient and dim reflections read it
	env.sky = sky
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0      # all ambient from the sky: ambient_light_energy is ignored (SKY_ENERGY)
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0
	# glow only from what is brighter than 1.25 after exposure (spells, embers, loot), screen-blended so it
	# lightens without the soft-light mode's contrast boost; no bloom, so lit ground and armour never haze
	env.glow_enabled = true
	env.glow_intensity = 0.45
	env.glow_strength = 0.85
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = 1.25
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	env.set_glow_level(1, 1.0); env.set_glow_level(3, 1.0); env.set_glow_level(5, 0.6)
	env.fog_enabled = true
	env.fog_density = FOG_DENSITY
	env.fog_sky_affect = 0.0
	env.ssao_enabled = RenderingServer.get_current_rendering_method() == "forward_plus"   # Forward+ only
	env.ssao_radius = 18.0
	env.ssao_intensity = 1.6
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.08
	env.adjustment_saturation = SAT
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-52.0), deg_to_rad(-35.0), 0.0)
	sun.light_energy = SUN_ENERGY
	sun.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY  # no sun disc in the ambient sky: it would light everything twice
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = SHADOW_DIST      # scaled with the camera distance in _camera
	sun.directional_shadow_fade_start = 0.9                # the fade starts past the hero (camera distance 600)
	sun.shadow_blur = 1.5
	sun.shadow_opacity = 0.65                           # shadows keep a third of the sun: tree shadows read as shade, not holes
	add_child(sun)
	torch = OmniLight3D.new()
	torch.light_color = Color(1.0, 0.78, 0.5)
	torch.omni_range = TORCH_RANGE
	torch.omni_attenuation = LIGHT_ATT
	torch.light_energy = TORCH_ENERGY * LIGHT_GAIN
	torch.shadow_enabled = false
	torch.omni_shadow_mode = OmniLight3D.SHADOW_DUAL_PARABOLOID
	add_child(torch)
	key_light = OmniLight3D.new()
	key_light.light_color = Color(1.0, 0.95, 0.88)
	key_light.omni_range = 110.0
	key_light.omni_attenuation = LIGHT_ATT
	key_light.light_energy = KEY_ENERGY * LIGHT_GAIN
	key_light.light_specular = 0.6
	add_child(key_light)
	for i in 14:
		var l := OmniLight3D.new()
		l.omni_range = 160.0
		l.omni_attenuation = LIGHT_ATT
		l.light_energy = 0.0
		l.visible = false
		add_child(l)
		light_pool.append(l)
	terrain_mat = ShaderMaterial.new()
	terrain_mat.shader = load("res://shaders/3d/terrain.gdshader")
	# elevation pass: a grid of 20-unit quads that follows the camera (snapped to whole quads so it never
	# swims) and is displaced by the terrain height texture in the vertex shader
	ground = Node3D.new()
	_ground_mesh()
	terrain_mat.set_shader_parameter("displace", true)
	add_child(ground)
	water = MeshInstance3D.new()
	var wm := PlaneMesh.new()
	wm.size = Vector2(GROUND_SIZE, GROUND_SIZE)
	water.mesh = wm
	water_mat = ShaderMaterial.new()
	water_mat.shader = load("res://shaders/3d/water.gdshader")
	water.material_override = water_mat
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(water)
	var foe_shader: Shader = load("res://shaders/3d/foe.gdshader")
	prop_mat = ShaderMaterial.new()
	prop_mat.shader = load("res://shaders/3d/prop.gdshader")
	for k in Models.FOE_KINDS.size():
		var mmi := MultiMeshInstance3D.new()
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = Models.foe_mesh(Models.FOE_KINDS[k])
		mm.instance_count = 0             # grown on demand in _foes (bosses, heralds and exiles never use theirs)
		mm.visible_instance_count = 0
		mm.custom_aabb = AABB(Vector3(-1e6, -100, -1e6), Vector3(2e6, 400, 2e6))
		mmi.multimesh = mm
		var fm := ShaderMaterial.new()
		fm.shader = foe_shader
		foe_mats.append(fm)
		_vc.append(PackedFloat32Array())
		mmi.material_override = fm
		add_child(mmi)
		_foe_mm.append(mmi)
	_foe_n.resize(Models.FOE_KINDS.size())
	_foe_cap.resize(Models.FOE_KINDS.size())
	fx = FX3D.new()
	add_child(fx)
	fx.view = self
	env_fx = EnvFX.new()
	env_fx.view = self
	add_child(env_fx)
	_aura_mm = MultiMeshInstance3D.new()
	var amm := MultiMesh.new()
	amm.transform_format = MultiMesh.TRANSFORM_3D
	amm.use_colors = true
	var ap := PlaneMesh.new()
	ap.size = Vector2(2, 2)
	amm.mesh = ap
	amm.instance_count = 64
	amm.visible_instance_count = 0
	amm.custom_aabb = AABB(Vector3(-1e6, -10, -1e6), Vector3(2e6, 20, 2e6))
	_aura_mm.multimesh = amm
	var asm := ShaderMaterial.new()
	var ash := Shader.new()
	ash.code = """shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;
uniform float time = 0.0;
void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	float r = length(p);
	float ang = atan(p.y, p.x);
	float ring = smoothstep(0.05, 0.0, abs(r - 0.82)) * (0.7 + 0.3 * sin(time * 4.0));
	float runes = step(0.62, r) * step(r, 0.76) * step(0.55, fract(ang * 1.2732 * 3.0 + time * 0.3));
	float glow = smoothstep(0.9, 0.2, r) * 0.18;
	ALBEDO = COLOR.rgb * 2.0;
	ALPHA = clamp(ring + runes * 0.45 + glow, 0.0, 1.0);
}"""
	asm.shader = ash
	_aura_mm.material_override = asm
	_aura_mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_aura_mm)
	# contact shadows: one soft blob per foe
	_blob_mm = MultiMeshInstance3D.new()
	var bmm := MultiMesh.new()
	bmm.transform_format = MultiMesh.TRANSFORM_2D
	var bq := QuadMesh.new(); bq.size = Vector2(2, 2)
	bmm.mesh = bq
	bmm.instance_count = _blob_cap             # grows with the swarm (power of two) in _foes
	bmm.visible_instance_count = 0
	bmm.custom_aabb = AABB(Vector3(-1e5, -1e5, -1e5), Vector3(2e5, 2e5, 2e5))
	_blob_mm.multimesh = bmm
	var bsm := ShaderMaterial.new(); bsm.shader = load("res://shaders/3d/blob.gdshader")
	_blob_mm.material_override = bsm
	# the hero's own contact shadow: the same shader on one quad (its transform carries world x, z as x, y)
	_hero_blob = MeshInstance3D.new()
	_hero_blob.mesh = bq
	_hero_blob_mat = ShaderMaterial.new(); _hero_blob_mat.shader = bsm.shader
	_hero_blob.material_override = _hero_blob_mat
	_hero_blob.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_hero_blob.custom_aabb = AABB(Vector3(-1e5, -1e5, -1e5), Vector3(2e5, 2e5, 2e5))
	add_child(_hero_blob)
	_blob_mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_blob_mm)
	_bb.resize(_blob_cap * 8)

## The ground is a grid of separate mesh tiles, not one mesh. The Mobile renderer lights per mesh: as a
## single 3000-unit plane, every ground pixel on screen evaluated every point light in the scene (the
## S22 spent most of a late-fight frame there). A tile only computes the lights that reach it.
const GROUND_TILES := 8
func _ground_mesh() -> void:
	GROUND_Q = Quality.ground_q()
	for c in ground.get_children(): c.queue_free()
	var cells := roundi(GROUND_SIZE / GROUND_TILES / GROUND_Q)       # whole quads per tile: seams share vertices
	var ts := cells * GROUND_Q
	var pm := PlaneMesh.new()
	pm.size = Vector2(ts, ts)
	pm.subdivide_width = cells - 1
	pm.subdivide_depth = cells - 1
	for iz in GROUND_TILES:
		for ix in GROUND_TILES:
			var mi := MeshInstance3D.new()
			mi.mesh = pm
			mi.material_override = terrain_mat
			mi.position = Vector3((ix - GROUND_TILES * 0.5 + 0.5) * ts, 0, (iz - GROUND_TILES * 0.5 + 0.5) * ts)
			mi.custom_aabb = AABB(Vector3(-ts * 0.5, -300, -ts * 0.5), Vector3(ts, 600, ts))
			# the ground receives shadows but casts none: its 8 x 8 tiles were the biggest mesh in the shadow pass,
			# and from 52 degrees the hills' own shading (normals) carries the relief
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			ground.add_child(mi)

## Two tiling CC0 texture sets per act: [base, patches]. The shader blends and tints them.
const GROUND_SETS := [["grass", "cobble_moss"], ["mulch", "rock"], ["rock", "cobble"], ["slate", "gravel"], ["mossdirt", "cobble_moss"]]
## Four independent, seamless fractal-noise fields in one 256x256 RGBA texture (built once, ~50 ms).
static var _noise_tex: ImageTexture
static func noise_tex() -> ImageTexture:
	if _noise_tex != null: return _noise_tex
	var chans: Array[PackedByteArray] = []
	for c in 4:
		var fn := FastNoiseLite.new()
		fn.seed = 7 + c * 101
		fn.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		fn.frequency = 4.0 / 256.0
		fn.fractal_octaves = 4
		var im := fn.get_seamless_image(256, 256)
		im.convert(Image.FORMAT_L8)
		chans.append(im.get_data())
	var data := PackedByteArray()
	data.resize(256 * 256 * 4)
	for i in 256 * 256:
		data[i * 4] = chans[0][i]; data[i * 4 + 1] = chans[1][i]; data[i * 4 + 2] = chans[2][i]; data[i * 4 + 3] = chans[3][i]
	var img := Image.create_from_data(256, 256, false, Image.FORMAT_RGBA8, data)
	img.generate_mipmaps()
	_noise_tex = ImageTexture.create_from_image(img)
	RenderingServer.global_shader_parameter_set("g_noise", _noise_tex)       # terrain, fog, smoke, foes and water all sample it
	return _noise_tex

static func apply_ground(mat: ShaderMaterial, stage: int) -> void:
	noise_tex()
	mat.set_shader_parameter("detail2", Quality.tier() >= 1)
	var gs: Array = GROUND_SETS[clampi(stage, 0, GROUND_SETS.size() - 1)]
	var ok := ResourceLoader.exists("res://textures/terrain/%s.jpg" % gs[0])
	mat.set_shader_parameter("has_tex", ok)
	if not ok: return
	mat.set_shader_parameter("tex_a", load("res://textures/terrain/%s.jpg" % gs[0]))
	mat.set_shader_parameter("tex_b", load("res://textures/terrain/%s.jpg" % gs[1]))
	mat.set_shader_parameter("nrm_a", load("res://textures/terrain/%s_n.jpg" % gs[0]))
	mat.set_shader_parameter("nrm_b", load("res://textures/terrain/%s_n.jpg" % gs[1]))

func bind(world: World) -> void:
	_preload_release()
	w = world
	_preload_paths()
	_feat_sig = -1
	if GROUND_Q != Quality.ground_q(): _ground_mesh()
	var s: Dictionary = Content.STAGES[w.stage]
	_look = STAGE_LOOK[w.stage]
	terrain_mat.set_shader_parameter("c0", Content.col(s.g0))
	terrain_mat.set_shader_parameter("c1", Content.col(s.g1))
	terrain_mat.set_shader_parameter("c2", Content.col(s.g2))
	terrain_mat.set_shader_parameter("acc", Content.col(s.acc))
	apply_ground(terrain_mat, w.stage)
	Models.tint_props(w.stage, _look.get("clutter", Color(1, 1, 1)))
	for fm in foe_mats:
		fm.set_shader_parameter("eye_col", _look.eye)
		fm.set_shader_parameter("glow_col", Content.col(s.acc))
		fm.set_shader_parameter("status_cols", Content.status_cols(w.colorblind))
		fm.set_shader_parameter("rim_col", _look.rim)
		fm.set_shader_parameter("rim_k", float(_look.get("rim_k", RIM_FOE)))     # Act V: its foes drew above the hero
	prop_mat.set_shader_parameter("glow_col", Content.col(s.acc))
	prop_mat.set_shader_parameter("tint", Color(0.96, 0.95, 0.93))      # neutral: props keep their own colours
	env.background_color = _look.bg
	env.fog_light_color = _look.fog
	# saturation per act (SAT unless the act says): Act II's ground drew at C* 45, Act IV's 76% blue at C* 29
	env.adjustment_saturation = float(_look.get("sat", SAT))
	sun.light_color = _look.sun
	var hq := Quality.tier() >= 1
	sun.shadow_enabled = hq
	for k in _foe_mm.size():
		_foe_mm[k].cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if hq else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if hero != null: hero.queue_free()
	hero = HeroRig.new()
	hero.xray = true                  # the silhouette through props and crowds (HeroRig.XRAY_CODE)
	hero.scale = Vector3.ONE * 1.3
	add_child(hero)
	var h: Dictionary = Content.HEROES[w.hero]
	hero.build(String(h.id), Content.col(h.col))
	hero.set_rim(Content.col(String(h.col)), RIM_OWN)
	for u in boss_rigs: boss_rigs[u].queue_free()
	boss_rigs.clear()
	for e in boss_dying: (e[0] as BossRig).queue_free()
	boss_dying.clear()
	for u in exile_rigs: exile_rigs[u].queue_free()
	exile_rigs.clear()
	corpses.clear()
	sky_mat.sky_top_color = _look.sky
	sky_mat.sky_horizon_color = _look.sky.lerp(_look.fog, 0.4)
	sky_mat.ground_bottom_color = _look.gnd
	sky_mat.ground_horizon_color = _look.gnd.lerp(_look.fog, 0.4)
	sky_mat.energy_multiplier = SKY_ENERGY
	_clear_props()
	# terrain: liquid kind and colours per stage; textures recomposed on the first frame
	var lk := {"water": 0, "lava": 1, "void": 2, "none": 3}.get(w.terrain.liquid, 3) as int
	RenderingServer.global_shader_parameter_set("terrain_l", Vector4(w.terrain.level, lk, 0, 0))
	water.visible = lk != 3
	var wc: Array = [[Color(0.02, 0.07, 0.07), Color(0.12, 0.26, 0.2)], [Color(0.02, 0.01, 0.01), Color(0.2, 0.06, 0.02)],
		[Color(0.01, 0.015, 0.03), Color(0.06, 0.08, 0.12)], [Color(0, 0, 0), Color(0, 0, 0)],
		[Color(0.02, 0.06, 0.06), Color(0.14, 0.27, 0.25)]][mini(w.stage, 4)]
	water_mat.set_shader_parameter("deep_col", wc[0])
	water_mat.set_shader_parameter("shallow_col", wc[1])
	water_mat.set_shader_parameter("glow_col", Content.col(s.acc).lerp(Color(1.0, 0.45, 0.1), 0.6))
	_tex_center = Vector2i(1 << 30, 0)
	_hn = 0                       # the old world's height window is stale until the first frame recomposes it
	_ts_ver = -1
	_sf_ver = -1
	_cam_y = ground_y(w.pp)
	_liquid_kind = lk
	_foe_unit.resize(Models.FOE_KINDS.size()); _foe_h.resize(Models.FOE_KINDS.size())
	for k in Models.FOE_KINDS.size():                # act-specific swarm variants (models/foes/<kind>_<stage>)
		var fmesh := Models.foe_mesh(Models.FOE_KINDS[k], w.stage)
		_foe_mm[k].multimesh.mesh = fmesh
		var vat := Models.foe_vat(Models.FOE_KINDS[k], w.stage)
		var mh := fmesh.get_aabb().size.y if fmesh != null else 2.0
		_foe_h[k] = mh
		_foe_unit[k] = (1.0 / float(Content.ENEMIES[k].r)) if (mh > 10.0 and k < Content.ENEMIES.size()) else 1.0
		var pbr := Models.pbr_maps(fmesh)
		foe_mats[k].set_shader_parameter("has_albedo", pbr.has("albedo"))
		foe_mats[k].set_shader_parameter("has_normal", pbr.has("normal"))
		foe_mats[k].set_shader_parameter("has_orm", pbr.has("orm"))
		for key in pbr: foe_mats[k].set_shader_parameter(key + "_tex", pbr[key])
		foe_mats[k].set_shader_parameter("corpse_sink", mh * (0.3 if not vat.is_empty() else 0.45))
		foe_mats[k].set_shader_parameter("mp_scale", mp_scale(mh))
		foe_mats[k].set_shader_parameter("has_vat", not vat.is_empty())
		if not vat.is_empty():
			foe_mats[k].set_shader_parameter("vat_pos", vat.pos)
			foe_mats[k].set_shader_parameter("vat_nrm", vat.nrm)
			foe_mats[k].set_shader_parameter("vat_min", vat.vmin)
			foe_mats[k].set_shader_parameter("vat_ext", vat.vext)
		_vc[k] = vat.clips if not vat.is_empty() else PackedFloat32Array()
	_cam_pos = Vector3(w.pp.x, 0, w.pp.y)
	_cam_target = _cam_pos
	_kind_col.clear()
	for k in Models.FOE_KINDS.size(): _kind_col.append(_foe_color(k))
	fx.bind(w)
	env_fx.bind(w)
	# radial shadows from the hero's light: high quality only, and never on Compatibility (the OpenGL fallback), where the
	# omni shadow renders as a large black wedge
	torch.shadow_enabled = false          # set by _features (never on phones)
	torch.shadow_bias = 0.08

## Where something that moved from a to b over the latest tick is drawn this frame.
func lerp_pos(a: Vector2, b: Vector2) -> Vector2:
	return b if a.distance_squared_to(b) > SNAP_DIST2 else a.lerp(b, alpha)

## World -> screen, used by the overlay and the HUD compass.
func to_screen(p: Vector2, h: float = 0.0) -> Vector2:
	return cam.unproject_position(Vector3(p.x, h + ground_y(p), p.y))

func _process(dt: float) -> void:
	visible = w != null
	if w == null:
		return
	var t0 := Time.get_ticks_usec()
	time += dt
	hero_p = lerp_pos(w.prev_pp, w.pp)
	_hero_jp = jump_drawn()
	hero_y = _hero_height(_hero_jp)
	for m in [terrain_mat, prop_mat, _aura_mm.material_override]:
		m.set_shader_parameter("time", time)
	for fm in foe_mats: fm.set_shader_parameter("time", time)
	if profile:
		_prof_part("start", t0)
		_camera(dt); _prof_part("camera")
		_lighting(dt); _prof_part("lighting")
		_props(); _prof_part("props")
		_foes(); _prof_part("foes")
		_hero(dt); _prof_part("hero")
		_bosses(dt); _prof_part("bosses")
		env_fx.step(dt); _prof_part("env_fx")
		if Quality.on("effects"): _surf_fx()
		_prof_part("surf_fx")
		fx.step(dt); _prof_part("fx")
		_assign_lights(); _prof_part("lights")
	else:
		_camera(dt)
		_lighting(dt)
		_props()
		_foes()
		_hero(dt)
		_bosses(dt)
		env_fx.step(dt)
		if Quality.on("effects"): _surf_fx()
		fx.step(dt)
		_assign_lights()
	_preload_step()
	var sig := Quality.tier() * 131 + Quality.off.hash()
	if sig != _feat_sig:
		_feat_sig = sig
		_features()
	cost_us = lerpf(cost_us, float(Time.get_ticks_usec() - t0), 0.05)
	Diag.view_us = cost_us

## The models a run will need later, loaded on a loader thread ahead of time (O7): loading a boss's or a rival
## exile's model and its 2048 px textures took 15-24 ms on a desktop in the frame it appeared. The act's tyrant
## 45 s before it comes (campaign and atlas: Content.STAGE_TIME), the rift's guardian and the pinnacle's Herald
## from the start, a nemesis's hero model from the start (it comes after 45 s). A rogue exile (about six acts
## in ten meet one, from 55 s on) is one of three exiles, picked by the run's dice as it spawns: on Medium and High
## all three are loaded from 30 s, and the two it did not pick are let go once it has come. Each is held until the
## next run; a rig's own load() then finds it in the cache, or waits for the thread if it is still loading.
const EXILE_MODELS := {"bolt": "spark", "nova": "ember", "storm": "storm"}     # Bosses.exile_weapon -> hero model
var ahead := {}                      # path -> the loaded resource, null while its thread runs, false if it failed
var _paths := {}                     # what this run may load ahead, resolved once at bind (find_asset probes the disk)
var _exile_settled := false
func _preload_paths() -> void:
	_paths.clear()
	_exile_settled = false
	if w == null: return
	var own := Models.find_asset("bosses", "tyrant_%d" % w.stage)
	_paths["tyrant"] = own if own != "" else Models.find_asset("bosses", "tyrant")
	_paths["guardian"] = Models.find_asset("bosses", "guardian")
	_paths["herald"] = Models.find_asset("bosses", "herald")
	for wid in EXILE_MODELS: _paths["exile_" + wid] = Models.find_asset("heroes", EXILE_MODELS[wid])
	var nm: Dictionary = Save.data.get("nemesis", {})
	_paths["nemesis"] = "" if nm.is_empty() else Models.find_asset("heroes", EXILE_MODELS.get(String(nm.get("weapon", "")), "warden"))

func _preload_step() -> void:
	var want: Array = []
	var m := w.mode
	if (m == "campaign" or m == "atlas") and not w.boss_spawned and w.t >= Content.STAGE_TIME - 45.0: want.append(_paths.tyrant)
	elif m == "rift" and w.bosses.guardian_uid < 0: want.append(_paths.guardian)
	elif m == "pinnacle" and w.bosses.herald_uid < 0: want.append(_paths.herald)
	var dr := w.director
	if dr != null:
		if dr.nemesis_pending: want.append(_paths.nemesis)
		if m != "pinnacle" and not dr.exile_spawned and w.t >= 30.0 and Quality.tier() >= 1:
			for wid in EXILE_MODELS: want.append(_paths["exile_" + wid])
		if dr.exile_spawned and not _exile_settled:
			_exile_settled = true
			var keep: String = _paths.get("exile_" + String(w.bosses.exile_weapon), "")
			for wid in EXILE_MODELS:
				var p: String = _paths["exile_" + wid]
				if p != keep and p != _paths.nemesis and ahead.has(p): _let_go(p)
	for p in want:
		if p == "" or ahead.has(p): continue
		ahead[p] = null if ResourceLoader.load_threaded_request(p) == OK else false
	for p in ahead:
		if ahead[p] != null: continue
		match ResourceLoader.load_threaded_get_status(p):
			ResourceLoader.THREAD_LOAD_LOADED: ahead[p] = ResourceLoader.load_threaded_get(p)
			ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE: ahead[p] = false

## One preloaded model let go (a load still running is collected first, so the loader never keeps it).
func _let_go(p: String) -> void:
	if ahead.get(p, false) == null: ResourceLoader.load_threaded_get(p)
	ahead.erase(p)

## The view leaving (the app closing, a test's main freed): a load still running is collected, never left behind.
func _exit_tree() -> void:
	_preload_release()

## A new run (or none): what the last one preloaded is let go; a load still running is finished first, so the
## loader thread is never left holding it.
func _preload_release() -> void:
	for p in ahead:
		if ahead[p] == null: ResourceLoader.load_threaded_get(p)
	ahead.clear()

## Quality feature switches (self-test / gfx_off), applied every frame so they can change mid-run.
var _props_on := true
var _feat_sig := -1                 # graphics tier + feature switches last applied by _features
var _terr_on := true
var _hi_on := true
func _features() -> void:
	var mobile := OS.has_feature("mobile")
	sun.shadow_enabled = Quality.tier() >= 1 and Quality.on("sun_shadow")
	# one shadow cascade on phones and below High: the camera looks down at a small patch, and every extra
	# split is another scene pass plus a blend per pixel
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS if (Quality.high() and not mobile) else DirectionalLight3D.SHADOW_ORTHOGONAL
	# the torch's omni shadow re-renders the scene around the hero (+865k triangles at 400 foes in the
	# self-test) as a dual paraboloid: never on phones, High tier only elsewhere
	torch.shadow_enabled = not mobile and Quality.tier() >= 2 and Quality.on("torch_shadow") and RenderingServer.get_current_rendering_method() != "gl_compatibility"
	env.glow_enabled = Quality.on("post")
	env.fog_enabled = Quality.on("post")
	water.visible = Quality.on("water") and _liquid_kind != 3      # 3: this act has no liquid at all
	fx.visible = Quality.on("effects")
	env_fx.visible = Quality.on("effects")
	var fs := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if (Quality.tier() >= 1 and Quality.on("foe_shadow")) else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for m in _foe_mm:
		if m.cast_shadow != fs: m.cast_shadow = fs
	terrain_mat.set_shader_parameter("displace", Quality.on("terrain"))
	if Quality.on("terrain") != _terr_on:
		_terr_on = Quality.on("terrain")
		_tex_center = Vector2i(1 << 30, 0)       # recompose: terrain_o.z = 0 makes every th() lookup return 0
		_hn = 0                                  # and ground_y() 0 with it
		_clear_props()                           # props were planted at the old heights
	if Quality.on("props") != _props_on or Quality.high() != _hi_on:
		_props_on = Quality.on("props")
		_hi_on = Quality.high()
		_clear_props()
	if GROUND_Q != Quality.ground_q(): _ground_mesh()

func _camera(dt: float) -> void:
	var vs := get_viewport().get_visible_rect().size
	var aspect := vs.x / maxf(1.0, vs.y)
	view_scale = 1.0 if aspect >= 1.2 else 1.0 + (1.2 - aspect) * 0.9   # portrait phones see as much ground
	var boss_on := w.bosses.boss_hp_frac() >= 0.0
	var dist := 600.0 * view_scale * (1.18 if boss_on else 1.0)
	_near_range(dist)
	sun.directional_shadow_max_distance = SHADOW_DIST * dist / 600.0
	var lead := Vector3(w.face.x, 0, w.face.y) * 40.0 * w.mv
	_cam_y = lerpf(_cam_y, ground_y(hero_p), minf(1.0, dt * 4.0))        # the camera rides the hills, smoothly
	var tgt := Vector3(hero_p.x, _cam_y, hero_p.y) + lead                  # the drawn hero, not the latest tick
	_cam_target = _cam_target.lerp(tgt, minf(1.0, dt * 6.0))
	var pitch := deg_to_rad(52.0)
	var off := Vector3(0, sin(pitch), cos(pitch)) * dist
	var tr := w.shake * w.shake * float(Save.opt("shake"))
	var shake := Vector3(sin(time * 53.0), sin(time * 41.0) * 0.6, cos(time * 47.0)) * tr * 16.0
	if cine:
		_cam_target = cine_look
		cam.position = cine_pos + shake
		cam.look_at(cine_look + shake * 0.5, Vector3.UP)
	else:
		cam.position = _cam_target + off + shake + test_nudge
		cam.look_at(_cam_target + shake * 0.5, Vector3.UP)
		cam.rotate_object_local(Vector3.FORWARD, sin(time * 37.0) * tr * 0.012)
	ground.position = Vector3(snappedf(_cam_target.x, GROUND_Q), 0, snappedf(_cam_target.z, GROUND_Q))
	water.position = Vector3(snappedf(_cam_target.x, 64.0), w.terrain.level, snappedf(_cam_target.z, 64.0))
	water_mat.set_shader_parameter("time", time)
	_terrain_tex(dt)
	sun.position = _cam_target
	# spawn ring / culling radius from where the screen corners hit the ground
	var r := 0.0
	for c in [Vector2.ZERO, Vector2(vs.x, 0), Vector2(0, vs.y), vs]:
		var o := cam.project_ray_origin(c)
		var n := cam.project_ray_normal(c)
		if n.y < -0.01:
			var hit := o + n * (-o.y / n.y)
			r = maxf(r, Vector2(hit.x, hit.z).distance_to(w.pp))
	w.view_r = clampf(r, 400.0, 1400.0)

const SUN_ENERGY := 1.2
const SUN_FLOOR := 0.32
const TORCH_ENERGY := 1.6           # x LIGHT_GAIN; full gloom raises it by 40%
const TORCH_RANGE := 360.0
const KEY_ENERGY := 0.9             # x LIGHT_GAIN
## The sun's shadow reaches SHADOW_DIST of view depth at the landscape camera distance (600): the hero
## stands at 600, the top of the screen at about 840. The shadow map covers only that slice, so its texels
## are dense; portrait and the boss zoom pull the camera back, and the distance grows with it.
const SHADOW_DIST := 720.0
func _lighting(dt: float) -> void:
	var gl := w.gloom()            # 0 lit .. 1 dark (eclipse or the lantern running out)
	var flick := 1.0 + 0.12 * sin(time * 9.0) + 0.06 * sin(time * 23.7) + 0.25 * gl * sin(time * 3.1) * sin(time * 17.0)
	var gy := hero_y                   # the lantern rides with the hero, up into a jump too
	torch.position = Vector3(hero_p.x, 52.0 + gy, hero_p.y)
	var to_cam := (cam.global_position - Vector3(hero_p.x, 0, hero_p.y))
	to_cam.y = 0.0
	key_light.position = Vector3(hero_p.x, 46.0 + gy, hero_p.y) + to_cam.normalized() * 55.0
	# full gloom dims the sun to its floor (SUN_FLOOR) and thickens the fog, never to black: the sky's ambient stays,
	# so the ground and the swarm stay readable outside the torch's pool
	sun.light_energy = lerpf(sun.light_energy, lerpf(SUN_ENERGY, SUN_FLOOR, gl), minf(1.0, dt * 2.0))
	torch.light_energy = TORCH_ENERGY * lerpf(1.0, 1.4, gl) * flick * LIGHT_GAIN
	torch.omni_range = TORCH_RANGE * lerpf(1.0, 0.87, gl)
	# the cold open looks far across the Hollow: thicker fog, over the sky too, so the streamed ground fades
	# into the dark instead of ending at an edge
	env.fog_density = lerpf(env.fog_density, CINE_FOG if cine else lerpf(FOG_DENSITY, FOG_GLOOM, gl), minf(1.0, dt * (4.0 if cine else 1.0)))
	env.fog_sky_affect = 1.0 if cine else 0.0

# ================================================================= props
## Props are batched per 640-unit chunk and kind (optimisation pass): a cell off screen is frustum-culled
## as a whole, and a distant cell draws the imported mesh's automatic lower LOD. One batch per kind for
## the whole 5x5 neighbourhood drew every prop every frame (props were ~70% of all triangles).
## The 5 x 5 chunks of props around the hero. The hero's chunk and the ring around it are built at once
## (a run's start, a teleport); the outer ring, which is all a chunk crossing adds, is queued and built a
## cell a frame, nearest first: five cells in one frame made every crossing a hitch (O6). The outer ring
## starts 640-1280 units from the hero, at the edge of the screen.
var _prop_queue: Array[Vector2i] = []
func _props() -> void:
	var cx := floori(w.pp.x / CHUNK)
	var cy := floori(w.pp.y / CHUNK)
	var key := "%d:%d" % [cx, cy]
	if key == _chunk_key:
		if not _prop_queue.is_empty():
			var q: Vector2i = _prop_queue.pop_front()
			if not _prop_cells.has(q): _prop_cells[q] = _build_cell(q)
		return
	_chunk_key = key
	var want := {}
	for gx in range(cx - 2, cx + 3):
		for gy in range(cy - 2, cy + 3):
			want[Vector2i(gx, gy)] = true
	for c in _prop_cells.keys():
		if not want.has(c):
			_prop_cells[c].queue_free()
			_prop_cells.erase(c)
	_prop_queue.clear()
	var here := Vector2i(cx, cy)
	for c in want:
		if _prop_cells.has(c): continue
		if maxi(absi(c.x - cx), absi(c.y - cy)) <= 1: _prop_cells[c] = _build_cell(c)
		else: _prop_queue.append(c)
	_prop_queue.sort_custom(func(a: Vector2i, b: Vector2i): return (a - here).length_squared() < (b - here).length_squared())

func _clear_props() -> void:
	for c in _prop_cells: _prop_cells[c].queue_free()
	_prop_cells.clear()
	_prop_queue.clear()
	_cell_cache.clear()
	_cell_lru.clear()
	_chunk_key = ""

## Recently built cells' batches (meshes, boxes, buffers), kept after a cell leaves the 5 x 5: a run circles
## over the same few chunks, and walking back into one builds no layout again, only its nodes (O6). At most
## CELL_CACHE cells (about 16 KB of buffers each, 1.3 MB in all); cleared with the props (a new run, a graphics change).
const CELL_CACHE := 81                 # a 9 x 9 area of chunks: the 5 x 5 moving about inside it
var _cell_cache := {}                 # Vector2i chunk -> cell_parts(chunk)
var _cell_lru: Array[Vector2i] = []   # oldest first
func _cell_data(c: Vector2i) -> Array:
	var d = _cell_cache.get(c)
	if d != null:
		_cell_lru.erase(c)
		_cell_lru.append(c)
		return d
	var parts := cell_parts(c)
	_cell_cache[c] = parts
	_cell_lru.append(c)
	while _cell_lru.size() > CELL_CACHE: _cell_cache.erase(_cell_lru.pop_front())
	return parts

# ---------------------------------------------------------------- terrain textures
## The 7 x 7 chunks around the player as one R32F height texture (1 texel per 16-unit cell) plus an
## RG8 state texture (R ice, G charge), published as global shader uniforms (terrain_h.gdshaderinc).
const TEX_CHUNKS := 7
var _th_img: Image
var _th_tex: ImageTexture
var _sf_img: Image
var _sf_tex: ImageTexture
var _sf_ver := -1
var _sf_bytes := PackedByteArray()
var _sf_time := -9.0
var _sf_center := Vector2i(1 << 30, 0)
var _ts_img: Image
var _ts_tex: ImageTexture
var _tex_center := Vector2i(1 << 30, 0)
var _ts_ver := -1
var _ts_t := 0.0

var _liquid_kind := 3
func _terrain_tex(dt: float) -> void:
	var T := w.terrain
	if T.tide > 0.0:
		RenderingServer.global_shader_parameter_set("terrain_l", Vector4(T.level, _liquid_kind, 0, 0))
	var cc := Vector2i(floori(w.pp.x / Terrain.CHUNK), floori(w.pp.y / Terrain.CHUNK))
	var n := TEX_CHUNKS * Terrain.CN
	var half := TEX_CHUNKS / 2
	if cc != _tex_center:
		_tex_center = cc
		if _th_img == null: _th_img = Image.create(n, n, false, Image.FORMAT_RF)
		for dy in TEX_CHUNKS:
			for dx in TEX_CHUNKS:
				var ch: Array = T.chunk(cc + Vector2i(dx - half, dy - half))
				var img := Image.create_from_data(Terrain.CN, Terrain.CN, false, Image.FORMAT_RF, (ch[0] as PackedFloat32Array).to_byte_array())
				_th_img.blit_rect(img, Rect2i(0, 0, Terrain.CN, Terrain.CN), Vector2i(dx * Terrain.CN, dy * Terrain.CN))
		if _th_tex == null: _th_tex = ImageTexture.create_from_image(_th_img)
		else: _th_tex.update(_th_img)
		var o := Vector2(cc - Vector2i(half, half)) * Terrain.CHUNK
		# the same heights on the CPU, for ground_y (one copy per chunk crossing)
		_hd = _th_img.get_data().to_float32_array()
		_hox = o.x
		_hoz = o.y
		_hn = n if Quality.on("terrain") else 0
		Diag.mark("terrain texture rebuilt around chunk %s" % str(cc))
		RenderingServer.global_shader_parameter_set("terrain_h", _th_tex)
		RenderingServer.global_shader_parameter_set("terrain_o", Vector4(o.x, o.y, n if Quality.on("terrain") else 0, Terrain.CELL))
		_ts_ver = -1
	_surf_tex(T, cc, n, half)
	_ts_t -= dt
	var live := not T.frozen.is_empty() or not T.charged.is_empty()
	if T.version != _ts_ver or (live and _ts_t <= 0.0) or _ts_tex == null:
		_ts_ver = T.version
		_ts_t = 0.15
		if _ts_img == null: _ts_img = Image.create(n, n, false, Image.FORMAT_RG8)
		_ts_img.fill(Color(0, 0, 0))
		var base := (cc - Vector2i(half, half)) * Terrain.CN
		for c in T.frozen:
			var q: Vector2i = c - base
			if q.x >= 0 and q.y >= 0 and q.x < n and q.y < n:
				_ts_img.set_pixel(q.x, q.y, Color(clampf(float(T.frozen[c]), 0.0, 1.0), 0, 0))
		for c in T.charged:
			var q: Vector2i = c - base
			if q.x >= 0 and q.y >= 0 and q.x < n and q.y < n:
				var px := _ts_img.get_pixel(q.x, q.y)
				_ts_img.set_pixel(q.x, q.y, Color(px.r, clampf(float(T.charged[c]) * 1.5, 0.0, 1.0), 0))
		if _ts_tex == null:
			_ts_tex = ImageTexture.create_from_image(_ts_img)
			RenderingServer.global_shader_parameter_set("terrain_s", _ts_tex)
		else: _ts_tex.update(_ts_img)

## Surfaces (oil / poison / blood / fire / spikes) as an RGBA8 texture over the same 7 x 7 chunks.
func _surf_tex(T: Terrain, cc: Vector2i, n: int, half: int) -> void:
	if T.surf_version == _sf_ver and cc == _sf_center and _sf_tex != null: return
	# kills pour blood and pools expire almost every frame in a late fight, and each change used to redraw
	# every cell with Image.set_pixel. Content changes now reach the GPU at 10 Hz (a move of the window
	# is still immediate), written straight into a reusable byte array
	if cc == _sf_center and _sf_tex != null and time - _sf_time < 0.1: return
	_sf_time = time
	_sf_ver = T.surf_version
	_sf_center = cc
	var by := _sf_bytes                      # a local: element writes on a member array go through the object each time
	if by.size() != n * n * 4: by.resize(n * n * 4)
	by.fill(0)
	var bx := (cc.x - half) * Terrain.CN
	var bz := (cc.y - half) * Terrain.CN
	var surf := T.surf
	for c: Vector2i in surf:
		var qx := c.x - bx
		var qy := c.y - bz
		if qx < 0 or qy < 0 or qx >= n or qy >= n: continue
		var cell: Array = surf[c]
		var fade := int(clampf(cell[1] / 1.5, 0.0, 1.0) * 255.0)       # pools thin out in their last 1.5 s
		var o := (qy * n + qx) * 4
		var kind: int = cell[0]
		if kind == Terrain.Surf.BLOOD: by[o + 2] = fade
		elif kind == Terrain.Surf.POISON: by[o + 1] = fade
		elif kind == Terrain.Surf.OIL: by[o] = fade
		elif kind == Terrain.Surf.FIRE: by[o + 3] = fade
		elif kind == Terrain.Surf.SPIKES:                                  # oil + poison = spikes
			by[o] = fade
			by[o + 1] = fade
	_sf_bytes = by
	if _sf_img == null: _sf_img = Image.create_from_data(n, n, false, Image.FORMAT_RGBA8, _sf_bytes)
	else: _sf_img.set_data(n, n, false, Image.FORMAT_RGBA8, _sf_bytes)
	if _sf_tex == null:
		_sf_tex = ImageTexture.create_from_image(_sf_img)
		RenderingServer.global_shader_parameter_set("terrain_f", _sf_tex)
	else: _sf_tex.update(_sf_img)

## Burning oil: flame puffs at a few burning cells in view each frame.
func _surf_fx() -> void:
	var T := w.terrain
	if T.surf.is_empty(): return
	var k := 0
	for c in T.surf:
		if int(T.surf[c][0]) != Terrain.Surf.FIRE: continue
		var p := (Vector2(c) + Vector2(randf(), randf())) * Terrain.CELL
		if p.distance_to(w.pp) > w.view_r: continue
		if randf() < 0.35:
			env_fx.puff(Vector3(p.x, ground_y(p) + 4.0, p.y), Vector3(randf_range(-6, 6), randf_range(30, 60), randf_range(-6, 6)),
				Color(1.0, randf_range(0.35, 0.6), 0.1), randf_range(0.4, 0.8), randf_range(10.0, 18.0), 2.5)
			k += 1
			if k >= 5: break

## Ground height under a point: the bilinear lookup over 16-unit cell centres that th() does in
## terrain_h.gdshaderinc and Terrain.height() does in the simulation, read from the 7 x 7 chunk window
## composed for the height texture (Terrain.height measured 2.9 us a call). Outside the window it asks the
## simulation; with hills switched off it is 0, matching the flat ground the shaders then draw.
## Everything instanced in the 3D view (foes, effects, smoke, props, rigs, lights) is placed at
## ground_y() + its own height on the CPU; only surfaces draped over the ground (terrain, decals,
## blood marks, contact shadows, lightning ribbons) still sample th() per vertex.
const INV_CELL := 1.0 / Terrain.CELL
var _hd := PackedFloat32Array()     # the window's heights, row-major, _hn x _hn
var _hn := 0                        # texels per side; 0 until composed and while hills are off
var _hox := 0.0                     # world x, z of texel 0's corner
var _hoz := 0.0
func ground_y(p: Vector2) -> float:
	if _hn > 0:
		var fx := (p.x - _hox) * INV_CELL - 0.5
		var fz := (p.y - _hoz) * INV_CELL - 0.5
		if fx >= 0.0 and fz >= 0.0 and fx < _hn - 1 and fz < _hn - 1:
			var ix := int(fx)
			var iz := int(fz)
			var k := iz * _hn + ix
			var a := lerpf(_hd[k], _hd[k + 1], fx - ix)
			var b := lerpf(_hd[k + _hn], _hd[k + _hn + 1], fx - ix)
			return lerpf(a, b, fz - iz)
	if w == null or w.terrain == null or not Quality.on("terrain"): return 0.0
	return w.terrain.height(p)

## Biome dressing, one 640-unit chunk at a time: the layout is PropLayout's (shared with Terrain, which
## blocks movement at its solid props); this turns it into transforms on the drawn ground. Bushes and
## grass scale with the tier's prop density; the solid props never do. Every prop sinks 1 unit into the
## ground so slopes never show a gap under it; boulders lean with the slope.
const CLUTTER := ["bones", "bush", "grass"]          # small: they cast no shadow
const NEAR_ONLY := ["grass"]                          # drawn in quarter-chunk batches, only near the camera
const NEAR_END := 950.0                               # their visibility range at the 600-unit camera

func _build_cell(c: Vector2i) -> Node3D:
	var cell := Node3D.new()
	add_child(cell)
	if not Quality.on("props"): return cell
	for part in _cell_data(c):
		var kind: String = part[0]
		var mesh: Mesh = part[1]
		var pmi := MultiMeshInstance3D.new()
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = int(part[4])
		mm.buffer = part[3]                      # one upload for the part (it was a call per instance)
		mm.custom_aabb = (part[2] as AABB).grow(160.0)
		pmi.multimesh = mm
		# imported PBR props draw their own materials (albedo, normal, roughness maps); the procedural and
		# vertex-coloured ones (grass, crystals, the act variants) keep the shared prop shader (sway, tint)
		if not Models.has_pbr(mesh): pmi.material_override = prop_mat
		pmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if CLUTTER.has(kind) else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if NEAR_ONLY.has(kind):
			pmi.visibility_range_end = _near_end
			pmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
			pmi.add_to_group("near_only")
		cell.add_child(pmi)
	return cell

## One chunk's props as MultiMesh data, nodes aside: [kind, mesh, AABB, buffer, instances] per batch. A kind
## is one batch per chunk; grass (NEAR_ONLY) is four, one per quarter: a range test on a whole chunk measures
## to its centre, up to ~450 units from where the hero stands in it, so its own grass could blink out; a
## quarter's centre is never far. The buffer holds 12 floats an instance (TRANSFORM_3D: the basis rows, each
## followed by its origin component), as MultiMesh.set_instance_transform writes them.
func cell_parts(c: Vector2i) -> Array:
	var out := []
	var lists := dress_chunk(c)
	for kind in lists:
		var list: Array = lists[kind]
		if list.is_empty(): continue
		var mesh := Models.prop_mesh(kind, w.stage)
		if mesh == null: continue
		var parts := [list]
		var boxes := [AABB(Vector3(c.x * CHUNK, -200.0, c.y * CHUNK), Vector3(CHUNK, 600.0, CHUNK))]
		if NEAR_ONLY.has(kind):
			parts = [[], [], [], []]
			boxes = []
			var half := CHUNK * 0.5
			for q in 4:
				boxes.append(AABB(Vector3(c.x * CHUNK + (q % 2) * half, -200.0, c.y * CHUNK + (q / 2) * half), Vector3(half, 600.0, half)))
			for t in list:
				var o: Vector3 = (t as Transform3D).origin
				var qx := 1 if o.x - c.x * CHUNK >= half else 0
				var qz := 1 if o.z - c.y * CHUNK >= half else 0
				parts[qz * 2 + qx].append(t)
		for pi in parts.size():
			var part: Array = parts[pi]
			if part.is_empty(): continue
			out.append([kind, mesh, boxes[pi], tbuf(part), part.size()])
	return out

## Transform3Ds as a MultiMesh TRANSFORM_3D buffer (checked against set_instance_transform on a real renderer).
static func tbuf(list: Array) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(list.size() * 12)
	var o := 0
	for t: Transform3D in list:
		var x := t.basis.x
		var y := t.basis.y
		var z := t.basis.z
		var p := t.origin
		b[o] = x.x; b[o + 1] = y.x; b[o + 2] = z.x; b[o + 3] = p.x
		b[o + 4] = x.y; b[o + 5] = y.y; b[o + 6] = z.y; b[o + 7] = p.y
		b[o + 8] = x.z; b[o + 9] = y.z; b[o + 10] = z.z; b[o + 11] = p.z
		o += 12
	return b

## Grass and bushes stop at NEAR_END from the camera at its 600-unit distance; the boss zoom and portrait
## screens pull the camera back, and the range follows it (else their near ground would go bare).
var _near_end := NEAR_END
func _near_range(dist: float) -> void:
	var e := NEAR_END * dist / 600.0
	if absf(e - _near_end) < 1.0: return
	_near_end = e
	for n in get_tree().get_nodes_in_group("near_only"):
		(n as GeometryInstance3D).visibility_range_end = e

## kind -> Array of Transform3D for one chunk (no nodes: _build_cell instances them; tests count them).
func dress_chunk(c: Vector2i) -> Dictionary:
	var lay := PropLayout.chunk(c, w.stage, w.terrain, Quality.prop_density())
	var lists := {}
	for it in lay.items:
		var kind: String = it[0]
		var p: Vector2 = it[1]
		var s: float = it[3]
		var b := Basis(Vector3.UP, float(it[2])).scaled(Vector3(s, s * float(it[4]), s))
		if it[5]:                                                      # boulders lean with the slope
			var e := 12.0
			var n := Vector3(ground_y(p - Vector2(e, 0)) - ground_y(p + Vector2(e, 0)), 2.0 * e,
				ground_y(p - Vector2(0, e)) - ground_y(p + Vector2(0, e))).normalized()
			var ax := Vector3.UP.cross(n)
			if ax.length() > 1e-4: b = Basis(ax.normalized(), Vector3.UP.angle_to(n) * 0.6) * b
		if not lists.has(kind): lists[kind] = []
		lists[kind].append(Transform3D(b, Vector3(p.x, ground_y(p) - 1.0, p.y)))
	return lists

# ================================================================= foes
## Each kind has its own buffer, exactly as long as its MultiMesh (a grow-only power-of-two instance
## count), written in place and passed to the MultiMesh whole: no per-frame slices or allocations.
var _fbk: Array[PackedFloat32Array] = []     # per foe kind: _foe_cap[k] instances x FOE_STRIDE floats
var _vis := PackedInt32Array()       # swarm indices drawn this frame (pass 1 order)
var _order := PackedInt32Array()     # the same, grouped by kind: kind k occupies [_start[k], _start[k + 1])
var _start := PackedInt32Array()
var _cursor := PackedInt32Array()
var _corpse_n := PackedInt32Array()
var _blob_mm: MultiMeshInstance3D
var _bb := PackedFloat32Array()      # blob shadows: 2D transform per foe (only x scale, x, y scale, y change)
var _blob_cap := 64

func _foes() -> void:
	var sw := w.sw
	var nk := _foe_mm.size()
	if _fbk.size() != nk:
		_fbk.resize(nk)
		_start.resize(nk + 1)
		_cursor.resize(nk)
	if _vis.size() != Swarm.CAP: _vis.resize(Swarm.CAP)
	if _ipos.size() != Swarm.CAP: _ipos.resize(Swarm.CAP)
	_foe_n.fill(0)
	var nb := 0
	var cull := w.view_r + 60.0
	var gl := w.gloom()
	var dark_r := lerpf(2000.0, 280.0, gl) if gl > 0.05 else INF     # beyond the lantern's reach, foes are unseen
	var pp := hero_p
	var ap := alpha
	# pass 1: which foes are drawn (counted per kind), where (between the last two ticks), contact shadows
	# and elite auras
	var nv := 0
	# through locals (0.10.4): the swarm's arrays, and this pass's own outputs (assigned back below)
	var K := sw.kind
	var POS := sw.pos
	var PREV := sw.prev
	var FL := sw.flags
	var ipos := _ipos
	var vis := _vis
	var fnk := _foe_n
	for i in sw.n:
		var k := K[i]
		if k == Content.E.BOSS or k == Content.E.HERALD or k == Content.E.EXILE:
			continue
		var p := POS[i]
		var q := PREV[i]
		if q.distance_squared_to(p) <= SNAP_DIST2: p = q.lerp(p, ap)
		ipos[i] = p
		var dpl := p.distance_to(pp)
		if dpl > cull: continue
		var f := FL[i]
		if dpl > dark_r and (f & (Swarm.F_EXILE | Swarm.F_GOBLIN)) == 0: continue
		vis[nv] = i
		nv += 1
		fnk[k] += 1
		if (f & Swarm.F_ELITE) != 0 and dpl < 520.0:
			var naff := 0
			var af := sw.affix[i]
			while af != 0:
				naff += af & 1
				af >>= 1
			_aura(p, sw.rad[i] * 2.2, Color("ffb02e") if naff >= 2 else Color("4f86ff"))
	_ipos = ipos
	_vis = vis
	_foe_n = fnk
	# bucket the drawn foes by kind (a counting sort into _vis's own order, through _order)
	_start[0] = 0
	for k in nk:
		_start[k + 1] = _start[k] + _foe_n[k]
		_cursor[k] = _start[k]
	if _order.size() != Swarm.CAP: _order.resize(Swarm.CAP)
	var order := _order
	var cursor := _cursor
	for v in nv:
		var i := vis[v]
		var k := K[i]
		order[cursor[k]] = i
		cursor[k] += 1
	_order = order
	_cursor = cursor
	_corpse_count()
	# pass 2, one kind at a time: write its instances straight into that kind's own buffer (taken out of
	# the array while it is written, so the writes go through a local) and hand the buffer over whole.
	# The buffer is sized to the MultiMesh's instance count, so nothing is sliced or allocated per frame
	for k in nk:
		var mm := _foe_mm[k].multimesh
		var fn := _foe_n[k] + _corpse_n[k]
		if fn == 0:
			if mm.visible_instance_count != 0: mm.visible_instance_count = 0
			continue
		fn = mini(fn, Swarm.CAP)
		if fn > _foe_cap[k]:
			var cap := maxi(32, _foe_cap[k])
			while cap < fn: cap *= 2
			_foe_cap[k] = mini(cap, Swarm.CAP)
			mm.instance_count = _foe_cap[k]
		var buf: PackedFloat32Array = _fbk[k]
		_fbk[k] = PackedFloat32Array()
		if buf.size() != _foe_cap[k] * FOE_STRIDE: buf.resize(_foe_cap[k] * FOE_STRIDE)
		var n := _write_foes(buf, k, sw, pp)
		n = _write_corpses(buf, k, n)
		mm.buffer = buf
		mm.visible_instance_count = n
		_fbk[k] = buf
	# contact shadows: the same grow-only power-of-two capacity, uploaded only when there are any
	var bmm := _blob_mm.multimesh
	nb = nv
	if nb > _blob_cap:
		while _blob_cap < nb: _blob_cap *= 2
		_blob_cap = mini(_blob_cap, Swarm.CAP)
		bmm.instance_count = _blob_cap
		_bb.resize(_blob_cap * 8)
		_bb.fill(0.0)
	var bb := _bb
	var RAD := sw.rad
	for v in nb:
		var i := vis[v]
		var bo := v * 8
		var br := RAD[i] * 1.15
		var p := ipos[i]
		bb[bo] = br; bb[bo + 3] = p.x; bb[bo + 5] = br; bb[bo + 7] = p.y
	_bb = bb
	if nb > 0:
		bmm.buffer = _bb
	bmm.visible_instance_count = nb
	var amm := _aura_mm.multimesh
	amm.visible_instance_count = _aura_n
	_aura_n = 0

## Live foes of kind k into buf from slot 0; returns the slots used.
func _write_foes(buf: PackedFloat32Array, k: int, sw: Swarm, pp: Vector2) -> int:
	var c := _kind_col[k]
	var vc: PackedFloat32Array = _vc[k]
	var authored := not vc.is_empty()
	var unit := _foe_unit[k] if k < _foe_unit.size() else 1.0
	var n := 0
	# the ground height goes into the instance transform (foe.gdshader does no terrain lookup): ground_y's
	# window lookup inlined, through locals, since this runs for every foe on screen every frame
	var hd := _hd
	var hn := _hn
	var hox := _hox
	var hoz := _hoz
	# the swarm's arrays and the clocks through locals: a member read on another object is a lookup per use,
	# and this loop made a dozen of them per foe (0.10.4)
	var order := _order
	var ipos := _ipos
	var F := sw.flags
	var AI := sw.ai_s
	var DIR := sw.dir
	var RAD := sw.rad
	var UID := sw.uid
	var SPD := sw.spd
	var FRZ := sw.freeze_t
	var BORN := sw.born
	var ATK := sw.atk_t
	var HIT := sw.hit_at
	var FLASH := sw.flash
	var BST := sw.burn_stacks
	var BURN := sw.burn
	var SHOCK := sw.shock_t
	var CHILL := sw.chill_t
	var POIS := sw.pois
	var BLEED := sw.bleed
	var wt := w.t
	var tm := time
	for v in range(_start[k], _start[k + 1]):
		var i := order[v]
		var p := ipos[i]
		var dpl := p.distance_to(pp)
		var f := F[i]
		var dir := (pp - p) / maxf(0.001, dpl)
		if (f & Swarm.F_GOBLIN) != 0: dir = -dir
		elif k == Content.E.CHARGER and AI[i] == 2: dir = DIR[i]
		elif (f & Swarm.F_ALLY) != 0 and DIR[i] != Vector2.ZERO: dir = DIR[i]
		var gy := 0.0
		var fx := (p.x - hox) * INV_CELL - 0.5
		var fz := (p.y - hoz) * INV_CELL - 0.5
		if hn > 0 and fx >= 0.0 and fz >= 0.0 and fx < hn - 1 and fz < hn - 1:
			var ix := int(fx)
			var iz := int(fz)
			var kk := iz * hn + ix
			var ga := lerpf(hd[kk], hd[kk + 1], fx - ix)
			gy = lerpf(ga, lerpf(hd[kk + hn], hd[kk + hn + 1], fx - ix), fz - iz)
		else:
			gy = ground_y(p)
		var o := n * FOE_STRIDE
		var s := RAD[i] * unit
		# basis columns: x = (dir.x, 0, dir.y) * s (model +X faces the heading), y = up * s, z = (-dir.y, 0, dir.x) * s
		buf[o] = dir.x * s; buf[o + 1] = 0.0; buf[o + 2] = -dir.y * s; buf[o + 3] = p.x
		buf[o + 4] = 0.0; buf[o + 5] = s; buf[o + 6] = 0.0; buf[o + 7] = gy
		buf[o + 8] = dir.y * s; buf[o + 9] = 0.0; buf[o + 10] = dir.x * s; buf[o + 11] = p.y
		# per-instance colour and custom data reach the GPU as 16-bit halves (exact integers only to
		# 2048): the seed rides in the colour's alpha, flags alone in custom.w, and the walk phase is
		# wrapped to whole cycles (it used to grow with time, and flag+256*seed decoded as random elite
		# and ally bits: the swarm sparkled with their rim glows)
		buf[o + 12] = c.r; buf[o + 13] = c.g; buf[o + 14] = c.b; buf[o + 15] = float(UID[i] % 64) / 63.0
		var frz := FRZ[i]
		var moving := 0.0 if frz > 0.0 else 1.0
		var ph := fposmod(tm * (4.0 + SPD[i] * 0.05) * moving + float(UID[i]) * 1.37, TAU * 8.0)
		if not authored:
			buf[o + 16] = ph
		else:
			# authored clips (vertex animation texture): spawn, then attack, then a flinch, else the walk
			# cycle; the value is the frame row, which the shader blends with the next one
			var age := wt - BORN[i]
			var ta := wt - ATK[i]
			var th := wt - HIT[i]
			if vc[13] > 0.0 and age * vc[14] < vc[13] - 1.0:
				buf[o + 16] = vc[12] + age * vc[14]
			elif vc[4] > 0.0 and ta * vc[5] < vc[4] - 1.0:
				buf[o + 16] = vc[3] + ta * vc[5]
			elif vc[7] > 0.0 and th * vc[8] * 1.6 < vc[7] - 1.0:
				buf[o + 16] = vc[6] + th * vc[8] * 1.6
			else:
				buf[o + 16] = vc[0] + fposmod(ph / TAU, 1.0) * vc[1]
		buf[o + 17] = maxf(0.0, FLASH[i])
		# _status_code(i), inlined
		var bs := BST[i]
		var st := 0.0
		if frz > 0.0: st = 6.0
		elif BURN[i] > 0.0 or bs > 0: st = 1.0
		elif SHOCK[i] > 0.0: st = 3.0
		elif CHILL[i] > 0.0: st = 2.0
		elif POIS[i] > 0.0: st = 4.0
		elif BLEED[i] > 0.0: st = 5.0
		buf[o + 18] = st
		# the Emberwitch's Burn stacks ride over the flag bits (flags + 256 x stacks <= 1535, exact as a half);
		# foe.gdshader reads them back as burn_norm = stacks / 5 for the ember crust
		buf[o + 19] = float(f & 0xff) + 256.0 * float(bs)
		n += 1
	return n

func _status_code(i: int) -> float:
	var sw := w.sw
	if sw.freeze_t[i] > 0.0: return 6.0
	if sw.burn[i] > 0.0 or sw.burn_stacks[i] > 0: return 1.0
	if sw.shock_t[i] > 0.0: return 3.0
	if sw.chill_t[i] > 0.0: return 2.0
	if sw.pois[i] > 0.0: return 4.0
	if sw.bleed[i] > 0.0: return 5.0
	return 0.0

var _kind_col: Array[Color] = []
## Per foe kind: instance scale per unit of radius, and the mesh's height. The pack meshes are about 2 units
## tall and scale by the radius itself (unit 1); the generated ones are modelled at their height in world
## units for the kind's base radius (Content.ENEMIES r), so they scale by radius / base radius.
var _foe_unit := PackedFloat32Array()
var _foe_h := PackedFloat32Array()

# ---------------------------------------------------------------- corpses: topple, lie, crumble
var corpses: Array = []          # [kind, pos, dir, rad, t0, seed, ground height]
const CORPSE_LIFE := 3.6
func add_corpse(kind: int, pos: Vector2, dir: Vector2, rad: float, seed_v: int) -> void:
	if kind == Content.E.BOSS or kind == Content.E.HERALD or kind == Content.E.EXILE: return
	if corpses.size() >= 140: corpses.pop_front()
	corpses.append([kind, pos, dir if dir != Vector2.ZERO else Vector2.RIGHT, rad, time, seed_v % 64, ground_y(pos)])
	Diag.first("corpse")

## Expires old corpses and counts the rest per kind (they share their kind's MultiMesh).
func _corpse_count() -> void:
	var k2 := corpses.size() - 1
	while k2 >= 0:
		if time - float(corpses[k2][4]) > CORPSE_LIFE: corpses.remove_at(k2)
		k2 -= 1
	if _corpse_n.size() != _foe_mm.size(): _corpse_n.resize(_foe_mm.size())
	_corpse_n.fill(0)
	for c in corpses: _corpse_n[int(c[0])] += 1

## Corpses of kind k into buf after its live foes (from slot n); returns the slots used.
func _write_corpses(buf: PackedFloat32Array, k: int, n: int) -> int:
	if _corpse_n[k] == 0: return n
	var cap := buf.size() / FOE_STRIDE
	var vcd: PackedFloat32Array = _vc[k]
	var col := _kind_col[k]
	var unit := _foe_unit[k] if k < _foe_unit.size() else 1.0
	var mh := _foe_h[k] if k < _foe_h.size() else 2.1
	for c in corpses:
		if int(c[0]) != k: continue
		if n >= cap: break
		var age: float = time - float(c[4])
		var o := n * FOE_STRIDE
		var p: Vector2 = c[1]
		var d: Vector2 = c[2]
		var s: float = float(c[3]) * unit
		var gy: float = c[6]
		if not vcd.is_empty() and vcd[10] > 0.0:           # an authored death clip: play it once, hold its last frame
			buf[o] = d.x * s; buf[o + 1] = 0.0; buf[o + 2] = -d.y * s; buf[o + 3] = p.x
			buf[o + 4] = 0.0; buf[o + 5] = s; buf[o + 6] = 0.0; buf[o + 7] = gy
			buf[o + 8] = d.y * s; buf[o + 9] = 0.0; buf[o + 10] = d.x * s; buf[o + 11] = p.y
			buf[o + 12] = col.r; buf[o + 13] = col.g; buf[o + 14] = col.b; buf[o + 15] = float(c[5]) / 63.0
			buf[o + 16] = vcd[9] + minf(age * vcd[11], vcd[10] - 1.0)
			buf[o + 17] = clampf((age - 1.6) / (CORPSE_LIFE - 1.6), 0.0, 1.0)
			buf[o + 18] = 7.0
			buf[o + 19] = 0.0
			n += 1
			continue
		var fall := clampf(age / 0.28, 0.0, 1.0)
		fall = 1.0 - (1.0 - fall) * (1.0 - fall)                       # ease-out topple
		var a := fall * PI * 0.5
		var xa := Vector3(-d.x, 0, -d.y)                                # falls backwards, away from the hero
		var side := Vector3(-d.y, 0, d.x)
		var ya := Vector3.UP * cos(a) + side * sin(a)
		var za := xa.cross(ya)
		var bounce := sin(clampf((age - 0.28) / 0.2, 0.0, 1.0) * PI) * 0.04 * mh * s
		buf[o] = xa.x * s; buf[o + 1] = ya.x * s; buf[o + 2] = za.x * s; buf[o + 3] = p.x
		buf[o + 4] = xa.y * s; buf[o + 5] = ya.y * s; buf[o + 6] = za.y * s; buf[o + 7] = gy + 0.2 * mh * s * fall + bounce
		buf[o + 8] = xa.z * s; buf[o + 9] = ya.z * s; buf[o + 10] = za.z * s; buf[o + 11] = p.y
		buf[o + 12] = col.r; buf[o + 13] = col.g; buf[o + 14] = col.b; buf[o + 15] = float(c[5]) / 63.0
		buf[o + 16] = 0.0
		buf[o + 17] = clampf((age - 1.2) / (CORPSE_LIFE - 1.2), 0.0, 1.0)  # dissolve
		if age > 1.2: Diag.first("corpse dissolving")
		buf[o + 18] = 7.0
		buf[o + 19] = 0.0
		n += 1
	return n

# ---------------------------------------------------------------- magic / rare monster auras
var _aura_mm: MultiMeshInstance3D
var _aura_n := 0
func _aura(p: Vector2, r: float, c: Color) -> void:
	if _aura_n >= 64: return
	Diag.first("elite aura")
	var mm := _aura_mm.multimesh
	mm.set_instance_transform(_aura_n, Transform3D(Basis().scaled(Vector3(r, 1, r)), Vector3(p.x, 0.8 + ground_y(p), p.y)))
	mm.set_instance_color(_aura_n, c)
	_aura_n += 1

## The foe shader's noise scale for a mesh this tall (model units): the procedural meshes are ~2 units and keep 2.2;
## the textured ones are 26-42 units, scaled to about half a noise tile per foe (2.31 / height).
static func mp_scale(mesh_h: float) -> float:
	return 2.2 if mesh_h <= 10.0 else 2.31 / mesh_h

func _foe_color(k: int) -> Color:
	var s: Dictionary = Content.STAGES[w.stage]
	var acc := Content.col(s.acc)
	var base := Content.col(s.g1).lerp(Color(0.55, 0.5, 0.48), 0.5)
	match k:
		Content.E.RUNNER: return base.lerp(acc, 0.35)
		Content.E.BRUTE: return Color(0.42, 0.4, 0.42)
		Content.E.SPITTER: return base.lerp(Color(0.75, 0.8, 0.5), 0.45)
		Content.E.SPLITTER, Content.E.MINI: return base.lerp(Color(0.55, 0.7, 0.95), 0.5)
		Content.E.CHARGER: return base.lerp(Color(0.6, 0.35, 0.25), 0.5)
		Content.E.BREACH: return Color(0.55, 0.35, 0.85)
		Content.E.GOBLIN: return Color(0.55, 0.7, 0.35)
		Content.E.EXILE: return Color(0.35, 0.3, 0.32)
	return base

# ================================================================= hero and bosses
func _hero(dt: float) -> void:
	hero.animate({"pos": hero_p, "face": w.face, "mv": w.mv, "ph": w.walk_ph, "cast_age": w.t - w.cast_t, "cast_dir": w.cast_dir,
		"vel": w.vel.length(), "roll": (1.0 - w.roll_t / 0.26) if w.roll_t > 0.0 else -1.0, "jump": _hero_jp,
		"hit": 1.0 if w.hit_t > 0.0 else 0.0, "dead": w.over and not w.won, "t": time}, dt)
	hero.position.y += hero_y
	hero.visible = not hide_hero and not (w.inv_t > 0.0 and w.roll_t <= 0.0 and fmod(time, 0.12) < 0.04)
	# contact shadow under the hero on every tier (Low has no shadow maps): it shrinks and fades as the
	# hero rises, so a jump reads as height above the ground
	var g := ground_y(hero_p)
	var lift := clampf((hero_y - g) / JUMP_ARC, 0.0, 1.0)
	var br := HERO_BLOB_R * (1.0 - 0.35 * lift)
	_hero_blob.transform = Transform3D(Basis().scaled(Vector3(br, br, 1.0)), Vector3(hero_p.x, hero_p.y, 0.0))
	_hero_blob_mat.set_shader_parameter("strength", 0.55 * (1.0 - 0.6 * lift))
	# landing: a ring of dust where the hero comes down
	if _hero_jp < 0.0 and _was_air:
		for i in 12:
			var a := TAU * i / 12.0
			env_fx.puff(Vector3(hero_p.x, g + 4.0, hero_p.y), Vector3(cos(a) * 95.0, 12.0, sin(a) * 95.0), Color(0.6, 0.55, 0.5, 0.45), 0.7, 18.0)
	_was_air = _hero_jp >= 0.0

## Jumps: from the take-off ground height to the landing ground height, plus a parabola JUMP_ARC high at
## the apex, never below the ground under the hero (a ridge on the way lifts the hero over it).
const JUMP_ARC := 58.0
const HERO_BLOB_R := 17.0
var _hero_blob: MeshInstance3D
var _hero_blob_mat: ShaderMaterial
var _was_air := false

## Jump progress (0 take-off, 1 landing) at the moment drawn, between the last two ticks; -1 on the ground.
func jump_drawn() -> float:
	var t1 := w.jump_t
	var t0 := w.jump_t_prev
	if t1 <= 0.0 and t0 <= 0.0: return -1.0
	if t0 <= 0.0: t0 = World.JUMP_TIME            # the take-off tick: the jump begins at its first instant
	return clampf(1.0 - lerpf(t0, t1, alpha) / World.JUMP_TIME, 0.0, 1.0)

func _hero_height(jp: float) -> float:
	var g := ground_y(hero_p)
	if jp < 0.0: return g
	var jh := 4.0 * jp * (1.0 - jp) * JUMP_ARC
	return maxf(lerpf(ground_y(w.jump_from), ground_y(w.jump_to), jp) + jh, g + 2.0)

var exile_rigs := {}
func _exiles(dt: float) -> void:
	var alive := {}
	for i in w.sw.n:
		if w.sw.kind[i] != Content.E.EXILE: continue
		var u := w.sw.uid[i]
		alive[u] = true
		var rig: HeroRig = exile_rigs.get(u)
		if rig == null:
			rig = HeroRig.new()
			add_child(rig)
			var wid := String(w.bosses.exile_weapon)
			rig.build({"bolt": "spark", "nova": "ember", "storm": "storm"}.get(wid, "warden"), Color("4a2a2a"))
			rig.set_rim(_look.rim, RIM_HERO)
			rig.scale = Vector3.ONE * 1.35
			exile_rigs[u] = rig
		var at := lerp_pos(w.sw.prev[i], w.sw.pos[i])
		var to := hero_p - at
		rig.animate({"pos": at, "face": to.normalized(), "mv": 1.0 if w.sw.freeze_t[i] <= 0.0 else 0.0, "ph": time * 9.0 + u, "cast_age": fmod(time + u, 1.6),
			"vel": w.sw.spd[i] if w.sw.freeze_t[i] <= 0.0 else 0.0,
			"cast_dir": to.normalized(), "roll": -1.0, "hit": clampf(w.sw.flash[i] * 10.0, 0, 1), "dead": false, "t": time}, dt)
		rig.position.y += ground_y(at)
	for u in exile_rigs.keys():
		if not alive.has(u):
			exile_rigs[u].queue_free()
			exile_rigs.erase(u)

func _bosses(dt: float) -> void:
	_exiles(dt)
	var alive := {}
	for i in w.sw.n:
		var k := w.sw.kind[i]
		if k != Content.E.BOSS and k != Content.E.HERALD: continue
		var u := w.sw.uid[i]
		alive[u] = true
		var rig: BossRig = boss_rigs.get(u)
		if rig == null:
			rig = BossRig.new()
			add_child(rig)
			var guardian := (w.sw.flags[i] & Swarm.F_RIFTG) != 0
			var c := Color("c48aff") if k == Content.E.HERALD else (Color("ff4fd8") if guardian else Content.col(Content.STAGES[w.stage].boss_col))
			var slot := "herald" if k == Content.E.HERALD else ("guardian" if guardian else "tyrant")
			if slot == "tyrant" and Models.find_asset("bosses", "tyrant_%d" % w.stage) != "":
				slot = "tyrant_%d" % w.stage                  # an act's own boss model (Act V: the Tide Bishop)
			rig.build("herald" if k == Content.E.HERALD else "tyrant", c, slot)
			rig.scale = Vector3.ONE * (w.sw.rad[i] / 36.0)
			boss_rigs[u] = rig
		var st: Dictionary = w.bosses.bstate.get(u, {})
		var atk := float(st.get("atk_t", -9.0)) > w.t - dt * 1.5
		if k == Content.E.HERALD: atk = float(w.bosses.H.get("atk_t", -9.0)) > w.t - dt * 1.5
		var bat := lerp_pos(w.sw.prev[i], w.sw.pos[i])
		rig.animate({"pos": bat, "face": (hero_p - bat).normalized(), "hp_frac": w.sw.hp[i] / w.sw.mhp[i], "flash": w.sw.flash[i],
			"t": time, "dt": dt, "attack": atk, "phase": w.bosses.herald_phase()})
		rig.position.y += ground_y(bat)
	for u in boss_rigs.keys():
		if not alive.has(u):
			var rig2: BossRig = boss_rigs[u]
			fx.boss_death(rig2.global_position, rig2.col)
			boss_rigs.erase(u)
			var hold := rig2.death_time()
			if hold > 0.0:                                     # an authored boss falls with its die clip
				boss_dying.append([rig2, hold + BOSS_SINK, Vector2(rig2.position.x, rig2.position.z)])
			else:
				rig2.queue_free()
	for i in range(boss_dying.size() - 1, -1, -1):
		var e: Array = boss_dying[i]
		var r3: BossRig = e[0]
		e[1] = float(e[1]) - dt
		if float(e[1]) <= 0.0:
			r3.queue_free()
			boss_dying.remove_at(i)
			continue
		var bp: Vector2 = e[2]
		var yaw := r3.rotation.y
		var total := maxf(0.001, r3.death_time() + BOSS_SINK)
		r3.animate({"pos": bp, "face": Vector2(cos(yaw), -sin(yaw)), "hp_frac": 0.0, "flash": 0.0, "t": time, "dt": dt,
			"attack": false, "phase": 0, "dead": true, "fade": float(e[1]) / total})
		var sink := clampf((BOSS_SINK - float(e[1])) / BOSS_SINK, 0.0, 1.0)
		# set, never added to: animate() put the rig at y 0, and the fall is measured from the ground under it
		r3.position.y = ground_y(bp) - sink * sink * 100.0 * r3.scale.y

# ================================================================= dynamic light pool
func _assign_lights() -> void:
	var cand: Array = fx.light_candidates()
	cand.sort_custom(func(a, b): return a[2] > b[2])
	var nl := Quality.lights()
	for i in light_pool.size():
		var l := light_pool[i]
		if i < cand.size() and i < nl:
			var c: Array = cand[i]
			l.visible = true
			if i == 0: Diag.first("dynamic light")
			if i == 7: Diag.first("8 dynamic lights")
			l.position = c[0]                     # candidates are world positions (FX3D adds the ground height)
			l.light_color = c[1]
			l.light_energy = c[2] * LIGHT_GAIN
			l.omni_range = c[3]
		else:
			l.visible = false
