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

const STAGE_LOOK := [
	{"sun": Color(1.0, 0.92, 0.78), "amb": Color(0.35, 0.45, 0.4), "fog": Color(0.1, 0.18, 0.14), "bg": Color(0.03, 0.06, 0.05), "eye": Color(1.0, 0.85, 0.3), "props": {"tree": 3, "rock": 3, "grass": 22, "crystal": 1, "pillar": 0.3, "bones": 0.5}},
	{"sun": Color(1.0, 0.62, 0.4), "amb": Color(0.45, 0.25, 0.18), "fog": Color(0.22, 0.08, 0.05), "bg": Color(0.08, 0.03, 0.02), "eye": Color(1.0, 0.6, 0.2), "props": {"tree": 0.8, "rock": 5, "grass": 4, "crystal": 2, "pillar": 0.4, "bones": 1.5}},
	{"sun": Color(0.7, 0.75, 1.0), "amb": Color(0.3, 0.3, 0.45), "fog": Color(0.1, 0.09, 0.16), "bg": Color(0.03, 0.03, 0.06), "eye": Color(0.5, 1.0, 0.85), "props": {"tree": 1.2, "rock": 2, "grass": 6, "crystal": 1, "pillar": 2.5, "bones": 4}},
	{"sun": Color(0.6, 0.85, 1.0), "amb": Color(0.15, 0.3, 0.5), "fog": Color(0.03, 0.08, 0.16), "bg": Color(0.01, 0.03, 0.07), "eye": Color(1.0, 0.3, 0.85), "props": {"tree": 0.3, "rock": 3, "grass": 3, "crystal": 6, "pillar": 1.5, "bones": 0.3}},
]
const CHUNK := 640.0
## Godot's omni falloff is distance^-attenuation in world units. This world is ~60 units per hero,
## so the default-ish 1.0-1.6 falloff made every light ~0.002x as bright (cycle G2 finding).
## All lights use a gentle 0.5 falloff and energies scaled by LIGHT_GAIN to compensate.
const LIGHT_ATT := 0.5
const LIGHT_GAIN := 5.5
const FOE_STRIDE := 20

var w: World
var cam: Camera3D
var env: Environment
var sun: DirectionalLight3D
var torch: OmniLight3D
var key_light: OmniLight3D        # small fill on the camera side of the hero so the character always reads
var light_pool: Array[OmniLight3D] = []
var ground: MeshInstance3D
var terrain_mat: ShaderMaterial
var foe_mat: ShaderMaterial
var prop_mat: ShaderMaterial
var decal_mat: ShaderMaterial
var hero: HeroRig
var boss_rigs := {}            # uid -> BossRig
var fx: FX3D
var time := 0.0
var view_scale := 1.0
var _cam_pos := Vector3.ZERO
var _cam_target := Vector3.ZERO
var _foe_mm: Array[MultiMeshInstance3D] = []
var _foe_n := PackedInt32Array()
var _prop_mm := {}
var _chunk_key := ""
var _look: Dictionary
var cost_us := 0.0
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
	# a dim sky used only for reflections, so metal armour has something to reflect instead of black
	sky_mat = ProceduralSkyMaterial.new()
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.sky = sky
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_energy = 0.3
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0
	env.glow_enabled = true
	env.glow_intensity = 0.85
	env.glow_strength = 1.1
	env.glow_bloom = 0.08
	env.glow_hdr_threshold = 1.0
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.set_glow_level(1, 1.0); env.set_glow_level(3, 1.0); env.set_glow_level(5, 0.6)
	env.fog_enabled = true
	env.fog_density = 0.0007
	env.fog_sky_affect = 0.0
	env.ssao_enabled = RenderingServer.get_current_rendering_method() == "forward_plus"   # Forward+ only
	env.ssao_radius = 18.0
	env.ssao_intensity = 1.6
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.08
	env.adjustment_saturation = 1.08
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-52.0), deg_to_rad(-35.0), 0.0)
	sun.light_energy = 0.7
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 1800.0
	sun.shadow_blur = 1.5
	add_child(sun)
	torch = OmniLight3D.new()
	torch.light_color = Color(1.0, 0.78, 0.5)
	torch.omni_range = 300.0
	torch.omni_attenuation = LIGHT_ATT
	torch.light_energy = 3.2 * LIGHT_GAIN
	torch.shadow_enabled = false
	add_child(torch)
	key_light = OmniLight3D.new()
	key_light.light_color = Color(1.0, 0.95, 0.88)
	key_light.omni_range = 110.0
	key_light.omni_attenuation = LIGHT_ATT
	key_light.light_energy = 1.6 * LIGHT_GAIN
	key_light.light_specular = 0.6
	add_child(key_light)
	for i in 8:
		var l := OmniLight3D.new()
		l.omni_range = 160.0
		l.omni_attenuation = LIGHT_ATT
		l.light_energy = 0.0
		l.visible = false
		add_child(l)
		light_pool.append(l)
	terrain_mat = ShaderMaterial.new()
	terrain_mat.shader = load("res://shaders/3d/terrain.gdshader")
	ground = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(7000, 7000)
	ground.mesh = pm
	ground.material_override = terrain_mat
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ground)
	foe_mat = ShaderMaterial.new()
	foe_mat.shader = load("res://shaders/3d/foe.gdshader")
	prop_mat = ShaderMaterial.new()
	prop_mat.shader = load("res://shaders/3d/prop.gdshader")
	for k in Models.FOE_KINDS.size():
		var mmi := MultiMeshInstance3D.new()
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = Models.foe_mesh(Models.FOE_KINDS[k])
		mm.instance_count = Swarm.CAP
		mm.visible_instance_count = 0
		mm.custom_aabb = AABB(Vector3(-1e6, -100, -1e6), Vector3(2e6, 400, 2e6))
		mmi.multimesh = mm
		mmi.material_override = foe_mat
		add_child(mmi)
		_foe_mm.append(mmi)
	_foe_n.resize(Models.FOE_KINDS.size())
	for kind in Models.PROP_KINDS:
		var pmi := MultiMeshInstance3D.new()
		var mm2 := MultiMesh.new()
		mm2.transform_format = MultiMesh.TRANSFORM_3D
		mm2.mesh = Models.prop_mesh(kind)
		mm2.custom_aabb = AABB(Vector3(-1e6, -100, -1e6), Vector3(2e6, 600, 2e6))
		pmi.multimesh = mm2
		pmi.material_override = prop_mat
		pmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if kind == "grass" else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(pmi)
		_prop_mm[kind] = pmi
	fx = FX3D.new()
	add_child(fx)
	fx.view = self
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

func bind(world: World) -> void:
	w = world
	var s: Dictionary = Content.STAGES[w.stage]
	_look = STAGE_LOOK[w.stage]
	terrain_mat.set_shader_parameter("c0", Content.col(s.g0))
	terrain_mat.set_shader_parameter("c1", Content.col(s.g1))
	terrain_mat.set_shader_parameter("c2", Content.col(s.g2))
	terrain_mat.set_shader_parameter("acc", Content.col(s.acc))
	terrain_mat.set_shader_parameter("octaves", 3 if int(Save.opt("quality")) == 0 else 5)
	var tex_path := "res://textures/terrain/%d.png" % w.stage
	terrain_mat.set_shader_parameter("has_tex", ResourceLoader.exists(tex_path))
	if ResourceLoader.exists(tex_path): terrain_mat.set_shader_parameter("albedo_tex", load(tex_path))
	foe_mat.set_shader_parameter("eye_col", _look.eye)
	foe_mat.set_shader_parameter("glow_col", Content.col(s.acc))
	foe_mat.set_shader_parameter("colorblind", w.colorblind)
	prop_mat.set_shader_parameter("glow_col", Content.col(s.acc))
	prop_mat.set_shader_parameter("tint", Content.col(s.g2).lerp(Color.WHITE, 0.55))
	env.background_color = _look.bg
	env.ambient_light_color = _look.amb
	env.fog_light_color = _look.fog
	sun.light_color = _look.sun
	var hq := int(Save.opt("quality")) != 0
	sun.shadow_enabled = hq
	for k in _foe_mm.size():
		_foe_mm[k].cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if hq else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if hero != null: hero.queue_free()
	hero = HeroRig.new()
	hero.scale = Vector3.ONE * 1.3
	add_child(hero)
	var h: Dictionary = Content.HEROES[w.hero]
	hero.build(String(h.id), Content.col(h.col))
	for u in boss_rigs: boss_rigs[u].queue_free()
	boss_rigs.clear()
	for u in exile_rigs: exile_rigs[u].queue_free()
	exile_rigs.clear()
	corpses.clear()
	sky_mat.sky_top_color = _look.amb.lightened(0.2)
	sky_mat.sky_horizon_color = _look.fog.lightened(0.3)
	sky_mat.ground_bottom_color = _look.bg
	sky_mat.ground_horizon_color = _look.fog
	_chunk_key = ""
	_cam_pos = Vector3(w.pp.x, 0, w.pp.y)
	_cam_target = _cam_pos
	_kind_col.clear()
	for k in Models.FOE_KINDS.size(): _kind_col.append(_foe_color(k))
	fx.bind(w)

## World -> screen, used by the overlay and the HUD compass.
func to_screen(p: Vector2, h: float = 0.0) -> Vector2:
	return cam.unproject_position(Vector3(p.x, h, p.y))

func _process(dt: float) -> void:
	visible = w != null
	if w == null:
		return
	var t0 := Time.get_ticks_usec()
	time += dt
	for m in [terrain_mat, foe_mat, prop_mat, _aura_mm.material_override]:
		m.set_shader_parameter("time", time)
	_camera(dt)
	_lighting(dt)
	_props()
	_foes()
	_hero(dt)
	_bosses(dt)
	fx.step(dt)
	_assign_lights()
	cost_us = lerpf(cost_us, float(Time.get_ticks_usec() - t0), 0.05)

func _camera(dt: float) -> void:
	var vs := get_viewport().get_visible_rect().size
	var aspect := vs.x / maxf(1.0, vs.y)
	view_scale = 1.0 if aspect >= 1.2 else 1.0 + (1.2 - aspect) * 0.9   # portrait phones see as much ground
	var boss_on := w.bosses.boss_hp_frac() >= 0.0
	var dist := 600.0 * view_scale * (1.18 if boss_on else 1.0)
	var lead := Vector3(w.face.x, 0, w.face.y) * 40.0 * w.mv
	var tgt := Vector3(w.pp.x, 0, w.pp.y) + lead
	_cam_target = _cam_target.lerp(tgt, minf(1.0, dt * 6.0))
	var pitch := deg_to_rad(52.0)
	var off := Vector3(0, sin(pitch), cos(pitch)) * dist
	var tr := w.shake * w.shake * float(Save.opt("shake"))
	var shake := Vector3(sin(time * 53.0), sin(time * 41.0) * 0.6, cos(time * 47.0)) * tr * 16.0
	cam.position = _cam_target + off + shake
	cam.look_at(_cam_target + shake * 0.5, Vector3.UP)
	cam.rotate_object_local(Vector3.FORWARD, sin(time * 37.0) * tr * 0.012)
	ground.position = Vector3(snappedf(_cam_target.x, 64.0), 0, snappedf(_cam_target.z, 64.0))
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

func _lighting(dt: float) -> void:
	var ecl := w.director.eclipse()
	var flick := 1.0 + 0.12 * sin(time * 9.0) + 0.06 * sin(time * 23.7)
	torch.position = Vector3(w.pp.x, 52.0, w.pp.y)
	var to_cam := (cam.global_position - Vector3(w.pp.x, 0, w.pp.y))
	to_cam.y = 0.0
	key_light.position = Vector3(w.pp.x, 46.0, w.pp.y) + to_cam.normalized() * 55.0
	var tgt_sun := 0.06 if ecl else 0.7
	sun.light_energy = lerpf(sun.light_energy, tgt_sun, minf(1.0, dt * 2.0))
	env.ambient_light_energy = lerpf(env.ambient_light_energy, 0.08 if ecl else 0.3, minf(1.0, dt * 2.0))
	torch.light_energy = (4.5 if ecl else 3.2) * flick * LIGHT_GAIN
	torch.omni_range = 260.0 if ecl else 300.0
	env.fog_density = lerpf(env.fog_density, 0.0014 if ecl else 0.0007, minf(1.0, dt))

# ================================================================= props
func _props() -> void:
	var cx := floori(w.pp.x / CHUNK)
	var cy := floori(w.pp.y / CHUNK)
	var key := "%d:%d" % [cx, cy]
	if key == _chunk_key:
		prop_mat.set_shader_parameter("hero_pos", Vector3(w.pp.x, 0, w.pp.y))
		return
	_chunk_key = key
	var dens: Dictionary = _look.props
	var per := {}
	for kind in Models.PROP_KINDS: per[kind] = []
	for gx in range(cx - 2, cx + 3):
		for gy in range(cy - 2, cy + 3):
			var rng := RandomNumberGenerator.new()
			rng.seed = hash(Vector3i(gx, gy, w.stage))
			for kind in Models.PROP_KINDS:
				var n := float(dens.get(kind, 0.0))
				var cnt := int(n) + (1 if rng.randf() < n - floorf(n) else 0)
				for i in cnt:
					var p := Vector2((gx + rng.randf()) * CHUNK, (gy + rng.randf()) * CHUNK)
					if p.length() < 120.0: continue          # keep the spawn point clear
					var s := rng.randf_range(0.7, 1.35)
					var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.85, 1.2), s))
					per[kind].append(Transform3D(b, Vector3(p.x, 0, p.y)))
	for kind in per:
		var mm: MultiMesh = _prop_mm[kind].multimesh
		var list: Array = per[kind]
		mm.instance_count = list.size()
		for i in list.size():
			mm.set_instance_transform(i, list[i])

# ================================================================= foes
## All kinds share one flat member buffer (kind k owns [k*CAP*STRIDE, (k+1)*CAP*STRIDE)), written in place.
## Writing into an element of an Array of PackedFloat32Arrays would copy the whole array per write
## (copy-on-write through a temporary), so per-kind buffers are only sliced out at upload time.
var _fb := PackedFloat32Array()

func _foes() -> void:
	var sw := w.sw
	var span := Swarm.CAP * FOE_STRIDE
	if _fb.size() != span * _foe_mm.size():
		_fb.resize(span * _foe_mm.size())
	_foe_n.fill(0)
	var cull := w.view_r + 60.0
	var ecl := w.director.eclipse()
	for i in sw.n:
		var k := sw.kind[i]
		if k == Content.E.BOSS or k == Content.E.HERALD or k == Content.E.EXILE:
			continue
		var p := sw.pos[i]
		var dpl := p.distance_to(w.pp)
		if dpl > cull: continue
		var f := sw.flags[i]
		if ecl and dpl > 280.0 and (f & (Swarm.F_EXILE | Swarm.F_GOBLIN)) == 0: continue
		var dir := (w.pp - p) / maxf(0.001, dpl)
		if (f & Swarm.F_GOBLIN) != 0: dir = -dir
		elif k == Content.E.CHARGER and sw.ai_s[i] == 2: dir = sw.dir[i]
		elif (f & Swarm.F_ALLY) != 0 and sw.dir[i] != Vector2.ZERO: dir = sw.dir[i]
		var n := _foe_n[k]
		var o := k * span + n * FOE_STRIDE
		var s := sw.rad[i] * (1.15 if k == Content.E.EXILE else 1.0)
		# basis columns: x = (dir.x, 0, dir.y) * s (model +X faces the heading), y = up * s, z = (-dir.y, 0, dir.x) * s
		_fb[o] = dir.x * s; _fb[o + 1] = 0.0; _fb[o + 2] = -dir.y * s; _fb[o + 3] = p.x
		_fb[o + 4] = 0.0; _fb[o + 5] = s; _fb[o + 6] = 0.0; _fb[o + 7] = 0.0
		_fb[o + 8] = dir.y * s; _fb[o + 9] = 0.0; _fb[o + 10] = dir.x * s; _fb[o + 11] = p.y
		var c := _kind_col[k]
		_fb[o + 12] = c.r; _fb[o + 13] = c.g; _fb[o + 14] = c.b; _fb[o + 15] = 1.0
		var moving := 0.0 if sw.freeze_t[i] > 0.0 else 1.0
		_fb[o + 16] = time * (4.0 + sw.spd[i] * 0.05) * moving + float(sw.uid[i]) * 1.37
		_fb[o + 17] = maxf(0.0, sw.flash[i])
		_fb[o + 18] = _status_code(i)
		_fb[o + 19] = float(f & 0xff) + 256.0 * float(sw.uid[i] % 64)
		_foe_n[k] = n + 1
		if (f & Swarm.F_ELITE) != 0 and dpl < 520.0:
			var naff := 0
			var af := sw.affix[i]
			while af != 0:
				naff += af & 1
				af >>= 1
			_aura(p, sw.rad[i] * 2.2, Color("ffb02e") if naff >= 2 else Color("4f86ff"))
	_corpses()
	var amm := _aura_mm.multimesh
	amm.visible_instance_count = _aura_n
	_aura_n = 0
	for k in _foe_mm.size():
		var mm := _foe_mm[k].multimesh
		if _foe_n[k] > 0 or mm.visible_instance_count != 0:
			mm.buffer = _fb.slice(k * span, (k + 1) * span)
			mm.visible_instance_count = _foe_n[k]

func _status_code(i: int) -> float:
	var sw := w.sw
	if sw.freeze_t[i] > 0.0: return 6.0
	if sw.burn[i] > 0.0: return 1.0
	if sw.shock_t[i] > 0.0: return 3.0
	if sw.chill_t[i] > 0.0: return 2.0
	if sw.pois[i] > 0.0: return 4.0
	if sw.bleed[i] > 0.0: return 5.0
	return 0.0

var _kind_col: Array[Color] = []

# ---------------------------------------------------------------- corpses: topple, lie, crumble
var corpses: Array = []          # [kind, pos, dir, rad, t0, seed]
const CORPSE_LIFE := 3.6
func add_corpse(kind: int, pos: Vector2, dir: Vector2, rad: float, seed_v: int) -> void:
	if kind == Content.E.BOSS or kind == Content.E.HERALD or kind == Content.E.EXILE: return
	if corpses.size() >= 140: corpses.pop_front()
	corpses.append([kind, pos, dir if dir != Vector2.ZERO else Vector2.RIGHT, rad, time, seed_v % 64])

func _corpses() -> void:
	var span := Swarm.CAP * FOE_STRIDE
	var k2 := corpses.size() - 1
	while k2 >= 0:
		if time - float(corpses[k2][4]) > CORPSE_LIFE: corpses.remove_at(k2)
		k2 -= 1
	for c in corpses:
		var k: int = c[0]
		var n := _foe_n[k]
		if n >= Swarm.CAP: continue
		var age: float = time - float(c[4])
		var fall := clampf(age / 0.28, 0.0, 1.0)
		fall = 1.0 - (1.0 - fall) * (1.0 - fall)                       # ease-out topple
		var a := fall * PI * 0.5
		var d: Vector2 = c[2]
		var s: float = c[3]
		var xa := Vector3(-d.x, 0, -d.y)                                # falls backwards, away from the hero
		var side := Vector3(-d.y, 0, d.x)
		var ya := Vector3.UP * cos(a) + side * sin(a)
		var za := xa.cross(ya)
		var o := k * span + n * FOE_STRIDE
		var p: Vector2 = c[1]
		var bounce := sin(clampf((age - 0.28) / 0.2, 0.0, 1.0) * PI) * 0.08 * s
		_fb[o] = xa.x * s; _fb[o + 1] = ya.x * s; _fb[o + 2] = za.x * s; _fb[o + 3] = p.x
		_fb[o + 4] = xa.y * s; _fb[o + 5] = ya.y * s; _fb[o + 6] = za.y * s; _fb[o + 7] = 0.42 * s * fall + bounce
		_fb[o + 8] = xa.z * s; _fb[o + 9] = ya.z * s; _fb[o + 10] = za.z * s; _fb[o + 11] = p.y
		var col := _kind_col[k]
		_fb[o + 12] = col.r; _fb[o + 13] = col.g; _fb[o + 14] = col.b; _fb[o + 15] = 1.0
		_fb[o + 16] = 0.0
		_fb[o + 17] = clampf((age - 1.2) / (CORPSE_LIFE - 1.2), 0.0, 1.0)  # dissolve
		_fb[o + 18] = 7.0
		_fb[o + 19] = 256.0 * float(c[5])
		_foe_n[k] = n + 1

# ---------------------------------------------------------------- magic / rare monster auras
var _aura_mm: MultiMeshInstance3D
var _aura_n := 0
func _aura(p: Vector2, r: float, c: Color) -> void:
	if _aura_n >= 64: return
	var mm := _aura_mm.multimesh
	mm.set_instance_transform(_aura_n, Transform3D(Basis().scaled(Vector3(r, 1, r)), Vector3(p.x, 0.8, p.y)))
	mm.set_instance_color(_aura_n, c)
	_aura_n += 1

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
	hero.animate({"pos": w.pp, "face": w.face, "mv": w.mv, "ph": w.walk_ph, "cast_age": w.t - w.cast_t, "cast_dir": w.cast_dir,
		"roll": (1.0 - w.roll_t / 0.26) if w.roll_t > 0.0 else -1.0, "hit": 1.0 if w.hit_t > 0.0 else 0.0, "dead": w.over and not w.won, "t": time}, dt)
	hero.visible = not (w.inv_t > 0.0 and w.roll_t <= 0.0 and fmod(time, 0.12) < 0.04)

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
			rig.scale = Vector3.ONE * 1.35
			exile_rigs[u] = rig
		var to := w.pp - w.sw.pos[i]
		rig.animate({"pos": w.sw.pos[i], "face": to.normalized(), "mv": 1.0 if w.sw.freeze_t[i] <= 0.0 else 0.0, "ph": time * 9.0 + u, "cast_age": fmod(time + u, 1.6),
			"cast_dir": to.normalized(), "roll": -1.0, "hit": clampf(w.sw.flash[i] * 10.0, 0, 1), "dead": false, "t": time}, dt)
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
			rig.build("herald" if k == Content.E.HERALD else "tyrant", c, "herald" if k == Content.E.HERALD else ("guardian" if guardian else "tyrant"))
			rig.scale = Vector3.ONE * (w.sw.rad[i] / 36.0)
			boss_rigs[u] = rig
		var st: Dictionary = w.bosses.bstate.get(u, {})
		var atk := float(st.get("atk_t", -9.0)) > w.t - dt * 1.5
		if k == Content.E.HERALD: atk = float(w.bosses.H.get("atk_t", -9.0)) > w.t - dt * 1.5
		rig.animate({"pos": w.sw.pos[i], "face": (w.pp - w.sw.pos[i]).normalized(), "hp_frac": w.sw.hp[i] / w.sw.mhp[i], "flash": w.sw.flash[i],
			"t": time, "dt": dt, "attack": atk, "phase": w.bosses.herald_phase()})
	for u in boss_rigs.keys():
		if not alive.has(u):
			var rig2: BossRig = boss_rigs[u]
			fx.boss_death(rig2.global_position, rig2.col)
			rig2.queue_free()
			boss_rigs.erase(u)

# ================================================================= dynamic light pool
func _assign_lights() -> void:
	var cand: Array = fx.light_candidates()
	cand.sort_custom(func(a, b): return a[2] > b[2])
	for i in light_pool.size():
		var l := light_pool[i]
		if i < cand.size():
			var c: Array = cand[i]
			l.visible = true
			l.position = c[0]
			l.light_color = c[1]
			l.light_energy = c[2] * LIGHT_GAIN
			l.omni_range = c[3]
		else:
			l.visible = false
