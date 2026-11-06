class_name EnvFX
extends Node3D
## How the world reacts to the hero and the swarm (PoE2 direction):
##  - foliage and ground fog part around bodies and get flattened by shockwaves (shared `pushers`)
##  - footsteps kick dust, rolls throw a dust ring, slams raise a cloud
##  - statuses touch the world: burning foes trail flames and smoke, chilled foes shed frost mist,
##    poisoned foes leak green fumes, shocked foes crackle
##  - hits spray ichor sparks and sometimes a splatter mark; every cast flashes light at the hand
##  - ambient motes drift in the torch light (fireflies, embers, crypt dust, neon sparks)
##  - urns and barrels sit in the world and shatter into shards and dust when a skill touches them

var view: WorldView3D
var w: World
var time := 0.0
const SMOKE_CAP := 420
var smoke_mm: MultiMeshInstance3D
var _sb := PackedFloat32Array()
var m_pos := PackedVector3Array(); var m_vel := PackedVector3Array(); var m_life := PackedFloat32Array(); var m_max := PackedFloat32Array()
var m_col := PackedColorArray(); var m_size := PackedFloat32Array(); var m_n := 0
var fog: MeshInstance3D
var fog_mat: ShaderMaterial
var pushers := PackedVector4Array()
var urn_mm: MultiMeshInstance3D
var barrel_mm: MultiMeshInstance3D
var motes: Array = []
var _last_cast := -9.0
var _last_step_sign := 0.0
var _last_roll := 0.0
var _frame := 0

const MOTES := [
	{"col": Color(0.75, 1.0, 0.45), "rise": 0.0, "blink": true},     # Mossglen: fireflies
	{"col": Color(1.0, 0.55, 0.2), "rise": 28.0, "blink": false},    # Cinder: rising embers
	{"col": Color(0.8, 0.8, 0.9), "rise": 4.0, "blink": false},      # Crypt: dust motes
	{"col": Color(0.3, 0.9, 1.0), "rise": 10.0, "blink": true},      # Neon: data sparks
]

func _ready() -> void:
	pushers.resize(16)
	var quad := QuadMesh.new()
	quad.size = Vector2(1, 1)
	smoke_mm = MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = quad
	mm.instance_count = SMOKE_CAP
	mm.visible_instance_count = 0
	mm.custom_aabb = AABB(Vector3(-1e6, -100, -1e6), Vector3(2e6, 800, 2e6))
	smoke_mm.multimesh = mm
	var sm := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = """shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, shadows_disabled, diffuse_lambert_wrap;
varying vec4 v_c;
float h21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vn(vec2 p) { vec2 i = floor(p); vec2 f = fract(p); vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(h21(i), h21(i + vec2(1, 0)), u.x), mix(h21(i + vec2(0, 1)), h21(i + vec2(1, 1)), u.x), u.y); }
void vertex() {
	v_c = INSTANCE_CUSTOM;
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0, 0, 0), vec4(0, length(MODEL_MATRIX[1].xyz), 0, 0), vec4(0, 0, length(MODEL_MATRIX[2].xyz), 0), vec4(0, 0, 0, 1));
}
void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	float n = vn(UV * 4.0 + v_c.x * 7.0) * 0.6 + vn(UV * 9.0 - v_c.x * 3.0) * 0.4;
	float a = smoothstep(1.0, 0.1, length(p) + n * 0.45) * COLOR.a;
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 1.0;
	EMISSION = COLOR.rgb * v_c.y;
	ALPHA = a;
}"""
	sm.shader = sh
	smoke_mm.material_override = sm
	smoke_mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(smoke_mm)
	_sb.resize(SMOKE_CAP * 20)
	m_pos.resize(SMOKE_CAP); m_vel.resize(SMOKE_CAP); m_life.resize(SMOKE_CAP); m_max.resize(SMOKE_CAP); m_col.resize(SMOKE_CAP); m_size.resize(SMOKE_CAP)
	fog = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(3200, 3200)
	fog.mesh = pm
	fog_mat = ShaderMaterial.new()
	fog_mat.shader = load("res://shaders/3d/fog.gdshader")
	fog.material_override = fog_mat
	fog.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(fog)
	urn_mm = _breakable_mm(_urn_mesh())
	barrel_mm = _breakable_mm(_barrel_mesh())

func _breakable_mm(mesh: Mesh) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = 40
	mm.visible_instance_count = 0
	mm.custom_aabb = AABB(Vector3(-1e6, -10, -1e6), Vector3(2e6, 200, 2e6))
	mmi.multimesh = mm
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/3d/prop.gdshader")
	mmi.material_override = mat
	add_child(mmi)
	return mmi

static func _urn_mesh() -> ArrayMesh:
	var k := MeshKit.new()
	var clay := Color(0.42, 0.32, 0.26)
	k.add("sphere", Vector3(0, 9, 0), Vector3(15, 16, 15), clay, 0, 0, Vector3.ZERO, 14)
	k.add("sphere", Vector3(0, 3, 0), Vector3(11, 6, 11), clay.darkened(0.3), 0, 0, Vector3.ZERO, 12)
	for k2 in 4: k.add("box", Vector3(cos(k2 * 1.57) * 7.4, 11, sin(k2 * 1.57) * 7.4), Vector3(1.2, 6, 1.2), Color(0.2, 0.15, 0.12), 0, 0, Vector3(0, k2 * 1.57, 0))
	k.add("cyl", Vector3(0, 18, 0), Vector3(7, 5, 7), clay.darkened(0.15), 0, 0, Vector3.ZERO, 12)
	k.add("torus", Vector3(0, 20.5, 0), Vector3(4.6, 4.6, 4.6), clay.darkened(0.25), 0, 0, Vector3.ZERO, 12)
	k.add("torus", Vector3(0, 9, 0), Vector3(7.8, 2, 7.8), Color(0.3, 0.2, 0.15), 0, 0, Vector3.ZERO, 14)
	return k.commit()

static func _barrel_mesh() -> ArrayMesh:
	var k := MeshKit.new()
	var wood := Color(0.45, 0.32, 0.2)
	k.add("cyl", Vector3(0, 11, 0), Vector3(16, 22, 16), wood, 0, 0, Vector3.ZERO, 14)
	k.add("sphere", Vector3(0, 11, 0), Vector3(18, 16, 18), wood.darkened(0.1), 0, 0, Vector3.ZERO, 14)
	for y in [3.0, 11.0, 19.0]:
		k.add("torus", Vector3(0, y, 0), Vector3(8.8, 3, 8.8), Color(0.25, 0.25, 0.27), 0, 0, Vector3.ZERO, 14)
	return k.commit()

func bind(world: World) -> void:
	w = world
	m_n = 0
	motes.clear()
	var look: Dictionary = WorldView3D.STAGE_LOOK[w.stage]
	fog_mat.set_shader_parameter("fog_col", (look.fog as Color).lightened(0.25))
	fog_mat.set_shader_parameter("density", [0.3, 0.26, 0.42, 0.3][w.stage])
	_last_cast = w.cast_t

# ================================================================= per frame
func step(dt: float) -> void:
	time += dt
	_frame += 1
	fog.position = Vector3(snappedf(w.pp.x, 32.0), 7.0, snappedf(w.pp.y, 32.0))
	fog_mat.set_shader_parameter("time", time)
	_pushers()
	_footsteps()
	_status_fx()
	_cast_flash()
	_breakables()
	_motes(dt)
	_sim(dt)
	_upload()

func _pushers() -> void:
	var n := 0
	pushers[n] = Vector4(w.pp.x, w.pp.y, 48.0, 14.0); n += 1
	for f in w.fx:                                   # shockwaves flatten grass and blow fog away
		if n >= 6: break
		if f.k == "ring":
			var k: float = clampf(f.t / f.life, 0, 1)
			pushers[n] = Vector4(f.pos.x, f.pos.y, maxf(30.0, float(f.max) * k * 1.1), 26.0 * (1.0 - k)); n += 1
	var sw := w.sw
	var step := maxi(1, sw.n / 40)
	for i in range(_frame % step, sw.n, step):         # a rotating sample of nearby bodies
		if n >= 16: break
		var p := sw.pos[i]
		if p.distance_squared_to(w.pp) < 360.0 * 360.0:
			pushers[n] = Vector4(p.x, p.y, sw.rad[i] * 2.4, 9.0); n += 1
	while n < 16:
		pushers[n] = Vector4(0, 0, 0, 0); n += 1
	view.prop_mat.set_shader_parameter("pushers", pushers)
	fog_mat.set_shader_parameter("pushers", pushers)

func puff(p: Vector3, v: Vector3, c: Color, life: float, size: float, glow: float = 0.0) -> void:
	var cap := SMOKE_CAP if int(Save.opt("quality")) != 0 else SMOKE_CAP / 3
	if m_n >= cap: return
	m_pos[m_n] = p; m_vel[m_n] = v; m_life[m_n] = life; m_max[m_n] = life
	m_col[m_n] = c; m_size[m_n] = size
	_sb[m_n * 20 + 17] = glow
	m_n += 1

func _footsteps() -> void:
	var s := signf(sin(w.walk_ph))
	if w.mv > 0.3 and s != _last_step_sign and w.roll_t <= 0.0:
		var side := Vector2(-w.face.y, w.face.x) * 5.0 * s
		var dust := (WorldView3D.STAGE_LOOK[w.stage].fog as Color).lightened(0.35)
		for i in 2:
			puff(Vector3(w.pp.x + side.x, 3, w.pp.y + side.y), Vector3(randf_range(-14, 14), randf_range(8, 20), randf_range(-14, 14)), Color(dust.r, dust.g, dust.b, 0.35), 0.7, 14.0)
		Sfx.play("step", randf_range(0.9, 1.15), 0.5)
	_last_step_sign = s
	if w.roll_t > 0.0 and _last_roll <= 0.0:          # roll start: dust ring
		for i in 10:
			var a := TAU * i / 10.0
			puff(Vector3(w.pp.x, 4, w.pp.y), Vector3(cos(a) * 70.0, 10.0, sin(a) * 70.0), Color(0.6, 0.55, 0.5, 0.4), 0.8, 18.0)
	_last_roll = w.roll_t
	for z in w.teles:                                   # slams raise a dust cloud as they land
		if z.hostile and z.arm > 0.0 and z.arm <= 0.05 and z.shape == 0:
			for i in 12:
				var a2 := randf() * TAU
				puff(Vector3(z.pos.x, 6, z.pos.y), Vector3(cos(a2), 0.3, sin(a2)) * randf_range(60, 140), Color(0.45, 0.4, 0.36, 0.5), 1.2, 30.0)

func _status_fx() -> void:
	var sw := w.sw
	var r2 := (w.view_r + 40.0) * (w.view_r + 40.0)
	var fxv := view.fx
	for i in range(_frame % 2, sw.n, 2):
		var p := sw.pos[i]
		if p.distance_squared_to(w.pp) > r2: continue
		var h := sw.rad[i] * 1.6
		if sw.flash[i] > 0.099:                          # fresh hit: ichor sparks and sometimes a splatter
			fxv._spark(Vector3(p.x, h, p.y), Vector3(randf_range(-1, 1), randf_range(0.5, 1.4), randf_range(-1, 1)) * 140.0, Color(0.55, 0.05, 0.06), 0.35, 5.0)
			if randf() < 0.12: fxv._mark(p + Vector2(randf_range(-8, 8), randf_range(-8, 8)), sw.rad[i] * 0.7, 0)
		if sw.burn[i] > 0.0 and randf() < 0.35:
			fxv._spark(Vector3(p.x + randf_range(-6, 6), h, p.y + randf_range(-6, 6)), Vector3(randf_range(-10, 10), randf_range(40, 90), randf_range(-10, 10)), Color(1.0, 0.45, 0.1), 0.45, 9.0)
			if randf() < 0.25: puff(Vector3(p.x, h + 10, p.y), Vector3(0, 35, 0), Color(0.12, 0.1, 0.1, 0.45), 1.2, 16.0)
		if sw.chill_t[i] > 0.0 and randf() < 0.12:
			puff(Vector3(p.x, h * 0.6, p.y), Vector3(randf_range(-12, 12), 6, randf_range(-12, 12)), Color(0.7, 0.9, 1.0, 0.35), 0.9, 14.0, 0.3)
		if sw.pois[i] > 0.0 and randf() < 0.1:
			puff(Vector3(p.x, h * 0.5, p.y), Vector3(randf_range(-8, 8), 14, randf_range(-8, 8)), Color(0.35, 0.8, 0.2, 0.4), 1.1, 15.0, 0.4)
		if sw.shock_t[i] > 0.0 and randf() < 0.15:
			fxv._spark(Vector3(p.x + randf_range(-10, 10), h + randf_range(-5, 8), p.y + randf_range(-10, 10)), Vector3(randf_range(-60, 60), randf_range(0, 60), randf_range(-60, 60)), Color(1.0, 0.95, 0.5), 0.12, 6.0)

func _cast_flash() -> void:
	if w.cast_t != _last_cast:
		_last_cast = w.cast_t
		var el := Content.el_col(int(Content.HEROES[w.hero].elem), w.colorblind)
		var hand := w.pp + w.cast_dir * 22.0
		view.fx.add_light(Vector3(hand.x, 40, hand.y), el, 3.0, 160.0, 0.14)
		for i in 5:
			view.fx._spark(Vector3(hand.x, 38, hand.y), Vector3(w.cast_dir.x * 120.0 + randf_range(-40, 40), randf_range(0, 50), w.cast_dir.y * 120.0 + randf_range(-40, 40)), el.lightened(0.3), 0.25, 6.0)

func _breakables() -> void:
	var counts := [0, 0]
	for b in w.breakables:
		var mmi: MultiMeshInstance3D = urn_mm if b.kind == 0 else barrel_mm
		var n: int = counts[b.kind]
		if n >= 40: continue
		var p: Vector2 = b.pos
		var yaw := fmod(p.x * 0.37 + p.y * 0.11, TAU)
		mmi.multimesh.set_instance_transform(n, Transform3D(Basis(Vector3.UP, yaw), Vector3(p.x, 0, p.y)))
		counts[b.kind] = n + 1
	urn_mm.multimesh.visible_instance_count = counts[0]
	barrel_mm.multimesh.visible_instance_count = counts[1]
	for e in w.broken:
		var p2: Vector2 = e[0]
		var c := Color(0.62, 0.42, 0.3) if e[1] == 0 else Color(0.45, 0.32, 0.2)
		for i in 9:
			view.fx._debris(Vector3(p2.x, 10, p2.y), Vector3(randf_range(-1, 1), randf_range(0.8, 1.8), randf_range(-1, 1)) * randf_range(90, 200), c.darkened(randf_range(0, 0.4)), randf_range(2.5, 5.0))
		for i in 6:
			puff(Vector3(p2.x, 8, p2.y), Vector3(randf_range(-40, 40), randf_range(10, 40), randf_range(-40, 40)), Color(0.55, 0.48, 0.4, 0.45), 1.0, 20.0)
	w.broken.clear()

func _motes(dt: float) -> void:
	var cfg: Dictionary = MOTES[w.stage]
	while motes.size() < 36:
		motes.append([Vector3(w.pp.x + randf_range(-300, 300), randf_range(8, 90), w.pp.y + randf_range(-260, 260)), randf() * TAU])
	for m in motes:
		var p: Vector3 = m[0]
		m[1] += dt
		p += Vector3(sin(m[1] * 0.7) * 10.0, float(cfg.rise) + sin(m[1] * 1.3) * 6.0, cos(m[1] * 0.9) * 10.0) * dt
		if p.y > 120.0 or absf(p.x - w.pp.x) > 340.0 or absf(p.z - w.pp.y) > 300.0:
			p = Vector3(w.pp.x + randf_range(-300, 300), randf_range(4, 30), w.pp.y + randf_range(-260, 260))
		m[0] = p
		var a := 0.55
		if cfg.blink: a = clampf(sin(m[1] * 2.2) * 1.4, 0.0, 1.0) * 0.8
		var c: Color = cfg.col
		view.fx.ext_glow.append([p, 6.0, Color(c.r, c.g, c.b, a), 0.0])

func _sim(dt: float) -> void:
	var i := 0
	while i < m_n:
		m_life[i] -= dt
		if m_life[i] <= 0.0:
			m_n -= 1
			m_pos[i] = m_pos[m_n]; m_vel[i] = m_vel[m_n]; m_life[i] = m_life[m_n]; m_max[i] = m_max[m_n]; m_col[i] = m_col[m_n]; m_size[i] = m_size[m_n]
			_sb[i * 20 + 17] = _sb[m_n * 20 + 17]
			continue
		m_vel[i] *= pow(0.3, dt)
		m_pos[i] += m_vel[i] * dt
		i += 1

func _upload() -> void:
	for i in m_n:
		var k := m_life[i] / m_max[i]
		var s := m_size[i] * (1.6 - k * 0.8)
		var p := m_pos[i]
		var c := m_col[i]
		var o := i * 20
		_sb[o] = s; _sb[o + 1] = 0.0; _sb[o + 2] = 0.0; _sb[o + 3] = p.x
		_sb[o + 4] = 0.0; _sb[o + 5] = s; _sb[o + 6] = 0.0; _sb[o + 7] = p.y
		_sb[o + 8] = 0.0; _sb[o + 9] = 0.0; _sb[o + 10] = s; _sb[o + 11] = p.z
		_sb[o + 12] = c.r; _sb[o + 13] = c.g; _sb[o + 14] = c.b; _sb[o + 15] = c.a * minf(1.0, k * 2.0)
		_sb[o + 16] = float(i) * 0.31
	var mm := smoke_mm.multimesh
	mm.buffer = _sb
	mm.visible_instance_count = m_n
