class_name FX3D
extends Node3D
## Everything that is not terrain, props, foes, the hero or bosses: projectiles (+ trails), enemy
## shots, XP crystals, death debris that tumbles and bounces, sparks/embers, orbiting blades,
## pickups with rarity loot beams, lightning ribbons, ground decals (telegraphs, shockwaves, event
## circles, blood/scorch marks), event props (chests, pylons, shrines, merchant, altar) and the
## candidate list for the dynamic light pool.
##
## Heights: every instance, spark, debris chip, light and event prop is placed in world space at
## view.ground_y(x, z) plus its own height, here on the CPU (the instanced shaders do no terrain lookup).
## Only geometry draped over the ground per vertex (decals, blood marks, lightning ribbons) still adds
## th() in its vertex shader.

var view: WorldView3D
var w: World
var time := 0.0
const GLOW_CAP := 2400
const DEBRIS_CAP := 600
const SPARK_CAP := 700
const MARK_CAP := 96
const MARK_LIFT := 0.4             # marks lie this far above the ground (clear of its depth, under decals at 0.5)
const ESHOT_RING := Color(1.0, 0.08, 0.46)      # enemy shots' ring: magenta-crimson
const DECAL_POOL := 110

var glow_mm: MultiMeshInstance3D
var _gb := PackedFloat32Array()
var gem_mm: MultiMeshInstance3D
var _gemb := PackedFloat32Array()
var proj_mm: MultiMeshInstance3D
var _pb := PackedFloat32Array()
var blade_mm: MultiMeshInstance3D
var debris_mm: MultiMeshInstance3D
var _db := PackedFloat32Array()
var pick_mm := {}               # shape -> MultiMeshInstance3D
var beam_mm: MultiMeshInstance3D
var bolts: MeshInstance3D
var bolt_mesh: ImmediateMesh
var bolt_mat: ShaderMaterial
var decal_mat: ShaderMaterial
var decals: Array[MeshInstance3D] = []
var _decal_used := 0
var marks_mm: MultiMeshInstance3D
var _marks: Array = []          # [pos, rot, size, kind]
var _mark_head := 0
var objs := {}                  # key -> Node3D event props
var _boss_deaths: Array = []
var ext_glow: Array = []        # [pos, size, colour, shape] pushed by EnvFX each frame (motes)

# debris and sparks (renderer-owned simulation)
var d_pos := PackedVector3Array(); var d_vel := PackedVector3Array(); var d_rot := PackedVector3Array(); var d_spin := PackedVector3Array()
var d_life := PackedFloat32Array(); var d_size := PackedFloat32Array(); var d_col := PackedColorArray(); var d_n := 0
var s_pos := PackedVector3Array(); var s_vel := PackedVector3Array(); var s_life := PackedFloat32Array(); var s_max := PackedFloat32Array()
var s_col := PackedColorArray(); var s_size := PackedFloat32Array(); var s_n := 0
var _lights: Array = []         # transient light events [pos, col, energy, range, life, max]

func _mm(mesh: Mesh, cap: int, mat: Material, colors: bool = true, custom: bool = true, shadows: bool = false) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = colors
	mm.use_custom_data = custom
	mm.mesh = mesh
	mm.instance_count = cap
	mm.visible_instance_count = 0
	mm.custom_aabb = AABB(Vector3(-1e6, -200, -1e6), Vector3(2e6, 1200, 2e6))
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	return mmi

static func _shader(path: String) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load(path)
	return m

static func _lit_vc() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = """shader_type spatial;
render_mode diffuse_burley;
varying vec4 v_c;
void vertex() { v_c = INSTANCE_CUSTOM; }      // instance transforms carry world heights (view.ground_y)
void fragment() { ALBEDO = COLOR.rgb; ROUGHNESS = 0.35 + 0.5 * v_c.y; METALLIC = v_c.z; EMISSION = COLOR.rgb * v_c.x; }"""
	m.shader = sh
	return m

func _ready() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(1, 1)
	glow_mm = _mm(quad, GLOW_CAP, _shader("res://shaders/3d/glow.gdshader"))
	_gb.resize(GLOW_CAP * 20)
	var octa := SphereMesh.new(); octa.radial_segments = 4; octa.rings = 2; octa.radius = 0.5; octa.height = 1.0
	gem_mm = _mm(octa, World.GEM_CAP, _lit_vc())
	_gemb.resize(World.GEM_CAP * 20)
	var bolt := SphereMesh.new(); bolt.radial_segments = 6; bolt.rings = 3; bolt.radius = 0.5; bolt.height = 1.0
	proj_mm = _mm(bolt, 800, _lit_vc())
	_pb.resize(800 * 20)
	var blade := MeshKit.new()
	blade.add("box", Vector3(0, 0, 0), Vector3(1.0, 0.12, 0.28), Color(0.85, 0.88, 0.95))
	blade.add("prism", Vector3(0.62, 0, 0), Vector3(0.28, 0.1, 0.28), Color(0.95, 0.95, 1.0), 0, 0, Vector3(0, 0, -PI / 2))
	blade.add("box", Vector3(-0.55, 0, 0), Vector3(0.12, 0.16, 0.6), Color(0.95, 0.75, 0.3))
	blade_mm = _mm(blade.commit(), 32, _lit_vc(), true, true, true)
	var shard := PrismMesh.new()
	debris_mm = _mm(shard, DEBRIS_CAP, _lit_vc(), true, true, true)
	_db.resize(DEBRIS_CAP * 20)
	var disc := CylinderMesh.new(); disc.top_radius = 0.5; disc.bottom_radius = 0.5; disc.height = 0.18; disc.radial_segments = 12
	var orb := SphereMesh.new(); orb.radius = 0.5; orb.height = 1.0; orb.radial_segments = 12; orb.rings = 6
	var box := BoxMesh.new()
	pick_mm["disc"] = _mm(disc, 300, _lit_vc(), true, true, true)
	pick_mm["orb"] = _mm(orb, 200, _lit_vc(), true, true, true)
	pick_mm["box"] = _mm(box, 120, _lit_vc(), true, true, true)
	pick_mm["octa"] = _mm(octa, 60, _lit_vc(), true, true, true)
	var beam := CylinderMesh.new(); beam.top_radius = 0.5; beam.bottom_radius = 0.5; beam.height = 1.0; beam.radial_segments = 10; beam.cap_top = false; beam.cap_bottom = false
	var bm := ShaderMaterial.new()
	var bs := Shader.new()
	bs.code = """shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;
uniform float time = 0.0;
void fragment() {
	float h = UV.y;
	float a = pow(h, 2.2) * (0.75 + 0.25 * sin(time * 5.0 + UV.x * 20.0));
	ALBEDO = COLOR.rgb * 2.0;
	ALPHA = clamp(a * COLOR.a, 0.0, 1.0);
}"""
	bm.shader = bs
	beam_mm = _mm(beam, 120, bm, true, false)
	bolt_mesh = ImmediateMesh.new()
	bolts = MeshInstance3D.new()
	bolts.mesh = bolt_mesh
	bolts.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	bolts.custom_aabb = AABB(Vector3(-1e6, -200, -1e6), Vector3(2e6, 1200, 2e6))
	bolt_mat = _shader("res://shaders/3d/bolt.gdshader")
	add_child(bolts)
	decal_mat = _shader("res://shaders/3d/decal.gdshader")
	# 9 x 9 quads: the shaders drape every vertex onto the terrain (16-unit height cells), so a telegraph or
	# a crater bends over a hill instead of cutting through it between its four corners
	var plane := PlaneMesh.new()
	plane.size = Vector2(2, 2)
	plane.subdivide_width = 8
	plane.subdivide_depth = 8
	for i in DECAL_POOL:
		var d := MeshInstance3D.new()
		d.mesh = plane
		d.material_override = decal_mat
		d.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		d.visible = false
		add_child(d)
		decals.append(d)
	var mm_mat := ShaderMaterial.new()
	var ms := Shader.new()
	ms.code = """shader_type spatial;
render_mode depth_draw_never, cull_disabled, shadows_disabled;
#include "res://shaders/3d/terrain_h.gdshaderinc"
varying vec4 v_c;
void vertex() {
	v_c = INSTANCE_CUSTOM;
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// the instance sits at ground_y(centre) + MARK_LIFT (CPU); each vertex follows the ground relative to it
	VERTEX += lift(mat3(MODEL_MATRIX), th(w.xz) - th(MODEL_MATRIX[3].xz));
}
void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	float n = fract(sin(dot(floor(p * 6.0 + v_c.y * 10.0), vec2(12.9, 78.2))) * 43758.5);
	float a = smoothstep(1.0, 0.35, length(p) + n * 0.25) * v_c.x;
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 0.3;
	ALPHA = a;
}"""
	mm_mat.shader = ms
	marks_mm = _mm(plane, MARK_CAP, mm_mat)
	for a in ["d_pos", "d_vel", "d_rot", "d_spin"]:
		var v: PackedVector3Array = get(a); v.resize(DEBRIS_CAP); set(a, v)
	d_life.resize(DEBRIS_CAP); d_size.resize(DEBRIS_CAP); d_col.resize(DEBRIS_CAP)
	s_pos.resize(SPARK_CAP); s_vel.resize(SPARK_CAP); s_life.resize(SPARK_CAP); s_max.resize(SPARK_CAP); s_col.resize(SPARK_CAP); s_size.resize(SPARK_CAP)

func bind(world: World) -> void:
	w = world
	d_n = 0
	s_n = 0
	_marks.clear()
	_mark_head = 0
	_lights.clear()
	for k in objs: objs[k].queue_free()
	objs.clear()

# ================================================================= per frame
func step(dt: float) -> void:
	time += dt
	(beam_mm.material_override as ShaderMaterial).set_shader_parameter("time", time)
	decal_mat.set_shader_parameter("time", time)
	_consume_feed()
	_sim_debris(dt)
	_sim_sparks(dt)
	var gn := 0
	gn = _projectiles(gn)
	gn = _sparks_upload(gn)
	_gems(dt)
	_blades()
	gn = _pickups(gn)
	for e in ext_glow:
		if gn >= GLOW_CAP: break
		_g(gn * 20, e[0], e[1], e[2], e[3])
		gn += 1
	ext_glow.clear()
	var mm := glow_mm.multimesh
	if gn > 0: mm.buffer = _gb          # nothing to draw: skip the upload
	mm.visible_instance_count = gn
	_debris_upload()
	_contagion(dt)
	_lightning()
	_decals()
	_event_props(dt)
	var k := _lights.size() - 1
	while k >= 0:
		_lights[k][4] -= dt
		if _lights[k][4] <= 0.0: _lights.remove_at(k)
		k -= 1

func light_candidates() -> Array:
	var out: Array = []
	for l in _lights:
		var f: float = l[4] / l[5]
		out.append([l[0], l[1], l[2] * f, l[3]])
	for p in w.picks:
		if p.k == "item" and int(p.data.rarity) >= Content.Rarity.RARE:
			out.append([Vector3(p.pos.x, view.ground_y(p.pos) + 30.0, p.pos.y), Content.col(Content.RARITY_COL[p.data.rarity]), 1.6, 120.0])
	for o in w.director.objects:
		out.append([Vector3(o.pos.x, view.ground_y(o.pos) + 50.0, o.pos.y), Content.col(Content.BUFFS[o.id].col), 2.2, 200.0])
	for ev in w.director.active:
		out.append([Vector3(ev.pos.x, view.ground_y(ev.pos) + 40.0, ev.pos.y), Content.col(Content.EVENTS[ev.id].col), 1.8, 260.0])
	var pc := 0
	for p in w.projs:
		if pc >= 3: break
		out.append([Vector3(p.pos.x, view.ground_y(p.pos) + 16.0, p.pos.y), p.col, 1.2, 90.0])
		pc += 1
	var cg := w.contagion
	if cg != null:
		for b in cg.beacons.slice(0, 2):                  # burning trunks: a low, flickering glow
			var bp: Vector2 = b.pos
			out.append([Vector3(bp.x, view.ground_y(bp) + 70.0, bp.y), Color(1.0, 0.52, 0.2), 0.6 + 0.15 * sin(time * 9.0 + bp.x), 200.0])
	# nearer and brighter first: weight by distance to the hero
	for c in out:
		var d: float = Vector2(c[0].x, c[0].z).distance_to(w.pp)
		c[2] = c[2] * clampf(1.4 - d / 900.0, 0.2, 1.4)
	# the blaze: one light over the hottest burning cluster, only while 3+ foes burn, never brighter than the
	# torch (1.6) or a boss's own light (0.85): it is the first of the pool to go when lights run short
	if cg != null and cg.hot_heat > 0:
		var e := clampf(0.3 + 0.012 * cg.hot_heat, 0.3, 0.8)
		out.append([Vector3(cg.hot.x, view.ground_y(cg.hot) + 42.0, cg.hot.y), Color(1.0, 0.5, 0.18), e * (0.9 + 0.1 * sin(time * 11.0)), 260.0])
	return out

## A transient light at world position p (ground height included).
func add_light(p: Vector3, c: Color, e: float, r: float, life: float) -> void:
	if _lights.size() < 24:
		_lights.append([p, c, e, r, life, life])

# ================================================================= world feed -> effects
func _consume_feed() -> void:
	for b in w.bursts:
		var pos: Vector2 = b[0]
		var cnt: int = b[2]
		var sc: Color = b[1]
		if sc.s < 0.25: sc = sc.lerp(Color(1.0, 0.7, 0.4), 0.6)         # pale hit colours read as white dust: warm them
		var gy := view.ground_y(pos)
		for i in mini(cnt, 6):
			_spark(Vector3(pos.x, gy + 10.0, pos.y), Vector3(randf_range(-1, 1), randf_range(0.4, 1.6), randf_range(-1, 1)) * float(b[3]) * 0.9, sc, randf_range(0.16, 0.36), randf_range(2.5, 4.5))
	w.bursts.clear()
	for d in w.deaths:
		var pos2: Vector2 = d[0]
		var col: Color = d[1]
		var r: float = d[2]
		var elite: bool = d[3]
		if d.size() > 6: view.add_corpse(int(d[4]), pos2, d[5], r, int(d[6]))
		var dc := col.darkened(0.55).lerp(Color(0.22, 0.03, 0.03), 0.35)   # ash and gore, not pale chips
		var gy2 := view.ground_y(pos2)
		for i in (5 if elite else 2):
			_debris(Vector3(pos2.x, gy2 + r * 0.9, pos2.y), Vector3(randf_range(-1, 1), randf_range(0.8, 1.8), randf_range(-1, 1)) * randf_range(120, 240), dc, r * randf_range(0.14, 0.3), randf_range(0.6, 1.1))
		_mark(pos2, r * (1.6 if elite else 1.1), 0)
		if elite: add_light(Vector3(pos2.x, gy2 + 30.0, pos2.y), Color(1, 0.8, 0.4), 3.0, 180.0, 0.35)
	w.deaths.clear()
	for f in w.fx:
		if f.get("seen", false): continue
		f.seen = true
		var g3 := view.ground_y(f.pos)
		var p3 := Vector3(f.pos.x, g3 + 30.0, f.pos.y)
		match f.k:
			"ring": add_light(p3, f.col, 3.5, maxf(120.0, float(f.max) * 1.2), f.life)
			"zap": add_light(Vector3(f.pos.x, g3 + 60.0, f.pos.y), f.col, 5.0, 200.0, 0.22); _mark(f.pos, f.r * 0.9, 1)
			"arc": add_light(p3, f.col, 2.0, 120.0, 0.15)
			"incinerate":                    # the Emberwitch's detonation: a scorch, a flash, a spray of embers
				_mark(f.pos, float(f.r) * 0.95, 1)
				add_light(Vector3(f.pos.x, g3 + 40.0, f.pos.y), f.col, 5.0, float(f.r) * 3.0, 0.4)
				for i in 14:
					var a := randf() * TAU
					_spark(Vector3(f.pos.x, g3 + 8.0, f.pos.y), Vector3(cos(a) * randf_range(60, 200), randf_range(160, 420), sin(a) * randf_range(60, 200)), Color(1.0, randf_range(0.35, 0.7), 0.12), randf_range(0.4, 0.9), randf_range(3.0, 6.0))
			"conflag":                       # a burning foe goes up: a bigger flash and a ring of fire
				_mark(f.pos, float(f.r) * 0.8, 1)
				add_light(Vector3(f.pos.x, g3 + 40.0, f.pos.y), f.col, 6.0, 300.0, 0.45)
				for i in 22:
					var a2 := TAU * i / 22.0
					_spark(Vector3(f.pos.x, g3 + 12.0, f.pos.y), Vector3(cos(a2) * 320.0, randf_range(80, 260), sin(a2) * 320.0), Color(1.0, randf_range(0.45, 0.8), 0.18), randf_range(0.35, 0.6), randf_range(4.0, 7.0))
			"beacon": add_light(Vector3(f.pos.x, g3 + 90.0, f.pos.y), f.col, 4.0, 240.0, 0.5)
			"crater":                        # the Warden's vault slam
				_mark(f.pos, float(f.r) * 0.85, 2)
				add_light(p3, f.col, 4.0, 240.0, 0.3)
				for i in 16:
					var a3 := randf() * TAU
					_debris(Vector3(f.pos.x + cos(a3) * 30.0, g3 + 6.0, f.pos.y + sin(a3) * 30.0), Vector3(cos(a3) * randf_range(120, 260), randf_range(220, 420), sin(a3) * randf_range(120, 260)), Color(0.36, 0.31, 0.26), randf_range(4.0, 9.0))
			"spark_burst":                   # a Rime Bolt glancing off stone
				add_light(p3, f.col, 1.6, 110.0, 0.15)
				for i in 10:
					_spark(Vector3(f.pos.x, g3 + 18.0, f.pos.y), Vector3(randf_range(-1, 1), randf_range(0.2, 1.2), randf_range(-1, 1)) * 300.0, f.col.lightened(0.3), randf_range(0.15, 0.3), randf_range(2.0, 3.5))
	for z in w.teles:
		if z.arm > 0.0 and z.arm <= 0.05 and z.col.a > 0.01 and z.hostile:
			_mark(z.pos, z.r * 0.8 if z.shape == 0 else 40.0, 2)
			add_light(Vector3(z.pos.x, view.ground_y(z.pos) + 30.0, z.pos.y), z.col, 4.0, z.r * 2.5 + 60.0, 0.3)
			for i in 10:
				var dp := z.pos + Vector2(randf_range(-z.r, z.r), randf_range(-z.r, z.r)) * 0.5
				_debris(Vector3(dp.x, view.ground_y(dp) + 4.0, dp.y), Vector3(randf_range(-0.5, 0.5), randf_range(1.0, 2.0), randf_range(-0.5, 0.5)) * 200.0, Color(0.4, 0.37, 0.34), randf_range(3.0, 7.0))

## p: the boss rig's world position (it already stands at the ground height).
func boss_death(p: Vector3, c: Color) -> void:
	add_light(p + Vector3(0, 60, 0), c, 8.0, 500.0, 1.2)
	for i in 60:
		_debris(p + Vector3(randf_range(-30, 30), randf_range(20, 90), randf_range(-30, 30)), Vector3(randf_range(-1, 1), randf_range(0.6, 2.0), randf_range(-1, 1)) * randf_range(150, 380), c.darkened(randf_range(0.0, 0.5)), randf_range(5.0, 14.0))
	for i in 80:
		_spark(p + Vector3(0, 50, 0), Vector3(randf_range(-1, 1), randf_range(-0.2, 1.5), randf_range(-1, 1)) * 420.0, c.lightened(0.3), randf_range(0.5, 1.2), randf_range(6.0, 14.0))

## Sparks fly in world space from p (ground height included): gravity and drag only, no ground contact.
func _spark(p: Vector3, v: Vector3, c: Color, life: float, size: float) -> void:
	var cap := SPARK_CAP if Quality.tier() >= 1 else SPARK_CAP / 3
	if s_n >= cap: return
	s_pos[s_n] = p; s_vel[s_n] = v; s_life[s_n] = life; s_max[s_n] = life; s_col[s_n] = c; s_size[s_n] = size
	s_n += 1

## Debris starts at world position p (ground height included) and bounces on the ground under it.
func _debris(p: Vector3, v: Vector3, c: Color, size: float, life: float = -1.0) -> void:
	var cap := DEBRIS_CAP if Quality.tier() >= 1 else DEBRIS_CAP / 3
	if d_n >= cap: return
	d_pos[d_n] = p; d_vel[d_n] = v; d_rot[d_n] = Vector3(randf() * TAU, randf() * TAU, randf() * TAU)
	d_spin[d_n] = Vector3(randf_range(-12, 12), randf_range(-12, 12), randf_range(-12, 12)); d_life[d_n] = life if life > 0.0 else randf_range(1.0, 1.6)
	d_size[d_n] = size; d_col[d_n] = c
	d_n += 1

## One persistent mark ([pos, angle, size, kind, time]) as a marks_mm instance: its centre gy + MARK_LIFT
## (gy = view.ground_y under it); the marks shader drapes the rest of it relative to that centre.
static func mark_xform(m: Array, gy: float) -> Transform3D:
	var s: float = m[2]
	return Transform3D(Basis(Vector3.UP, m[1]).scaled(Vector3(s, 1, s)), Vector3(m[0].x, gy + MARK_LIFT, m[0].y))

func _mark(p: Vector2, size: float, kind: int) -> void:
	var e := [p, randf() * TAU, size, kind, time]
	if _marks.size() < MARK_CAP: _marks.append(e)
	else:
		_marks[_mark_head] = e
		_mark_head = (_mark_head + 1) % MARK_CAP

func _sim_debris(dt: float) -> void:
	var i := 0
	while i < d_n:
		d_life[i] -= dt
		if d_life[i] <= 0.0:
			d_n -= 1
			d_pos[i] = d_pos[d_n]; d_vel[i] = d_vel[d_n]; d_rot[i] = d_rot[d_n]; d_spin[i] = d_spin[d_n]; d_life[i] = d_life[d_n]; d_size[i] = d_size[d_n]; d_col[i] = d_col[d_n]
			continue
		var v := d_vel[i]
		v.y -= 900.0 * dt
		var p := d_pos[i] + v * dt
		var fl := view.ground_y(Vector2(p.x, p.z)) + d_size[i] * 0.3
		if p.y < fl:                                   # on the ground under it: rest on it, and bounce if falling
			p.y = fl
			if v.y < 0.0:                              # (a chip thrown up a slope is lifted, not reflected)
				v = Vector3(v.x * 0.55, -v.y * 0.35, v.z * 0.55)
				d_spin[i] *= 0.6
		d_pos[i] = p
		d_vel[i] = v
		d_rot[i] += d_spin[i] * dt
		i += 1

func _sim_sparks(dt: float) -> void:
	var i := 0
	var drag := pow(0.15, dt)
	while i < s_n:
		s_life[i] -= dt
		if s_life[i] <= 0.0:
			s_n -= 1
			s_pos[i] = s_pos[s_n]; s_vel[i] = s_vel[s_n]; s_life[i] = s_life[s_n]; s_max[i] = s_max[s_n]; s_col[i] = s_col[s_n]; s_size[i] = s_size[s_n]
			continue
		var v := s_vel[i] * drag
		v.y -= 380.0 * dt
		s_vel[i] = v
		s_pos[i] += v * dt
		i += 1

# ================================================================= uploads
func _g(o: int, p: Vector3, s: float, c: Color, shape: float, boost: float = 0.0) -> void:
	_gb[o] = s; _gb[o + 1] = 0.0; _gb[o + 2] = 0.0; _gb[o + 3] = p.x
	_gb[o + 4] = 0.0; _gb[o + 5] = s; _gb[o + 6] = 0.0; _gb[o + 7] = p.y
	_gb[o + 8] = 0.0; _gb[o + 9] = 0.0; _gb[o + 10] = s; _gb[o + 11] = p.z
	_gb[o + 12] = c.r; _gb[o + 13] = c.g; _gb[o + 14] = c.b; _gb[o + 15] = c.a
	_gb[o + 16] = shape; _gb[o + 17] = boost; _gb[o + 18] = 0.0; _gb[o + 19] = 0.0

func _projectiles(gn: int) -> int:
	var pn := 0
	for p in w.projs:
		if pn >= 800 or gn >= GLOW_CAP - 4: break
		var v := Vector3(p.vel.x, 0, p.vel.y)
		var d := v.normalized() if v.length() > 0.01 else Vector3.RIGHT
		var at := p.pos if p.prev == Vector2.INF else view.lerp_pos(p.prev, p.pos)     # between the last two ticks
		var pos := Vector3(at.x, view.ground_y(at) + 16.0, at.y)      # trails below are offset from this
		var b := Basis(d * p.r * 3.4, Vector3.UP * p.r * 1.3, d.cross(Vector3.UP) * p.r * 1.3)
		_wb(pn * 20, b, pos, p.col, Color(4.0, 0.0, 0.0, 0.0))
		pn += 1
		_g(gn * 20, pos, p.r * 7.0, Color(p.col.r, p.col.g, p.col.b, 0.9), 0.0, 0.5); gn += 1
		for k in 3:                                   # trail
			var tp := pos - v * 0.018 * (k + 1)
			_g(gn * 20, tp, p.r * (5.0 - k * 1.2), Color(p.col.r, p.col.g, p.col.b, 0.5 - k * 0.14), 0.0); gn += 1
	for q in w.eshots:
		if gn >= GLOW_CAP - 3: break
		var qa := q.pos if q.prev == Vector2.INF else view.lerp_pos(q.prev, q.pos)
		var qp := Vector3(qa.x, view.ground_y(qa) + 14.0, qa.y)
		# hostile shots, one look for all of them: a white-hot core inside a vivid magenta-crimson ring. No
		# hero spell uses that hue (fire is orange, cold cyan, lightning yellow), so a shot never reads as
		# one of yours, and the ring's colour no longer follows the shooter's
		_g(gn * 20, qp, q.r * 3.2, Color(ESHOT_RING.r, ESHOT_RING.g, ESHOT_RING.b, 0.95), 3.0, 0.6); gn += 1
		_g(gn * 20, qp, q.r * 1.5, Color(1.0, 0.97, 0.95, 1.0), 2.0, 1.2); gn += 1
		_g(gn * 20, qp - Vector3(q.vel.x, 0, q.vel.y) * 0.03, q.r * 2.2, Color(ESHOT_RING.r, ESHOT_RING.g, ESHOT_RING.b, 0.35), 0.0); gn += 1
	var mm := proj_mm.multimesh
	if pn > 0: mm.buffer = _pb          # nothing to draw: skip the upload
	mm.visible_instance_count = pn
	return gn

## In-place write into the projectile buffer (a member, so no copy-on-write).
func _wb(o: int, b: Basis, p: Vector3, c: Color, cu: Color) -> void:
	_pb[o] = b.x.x; _pb[o + 1] = b.y.x; _pb[o + 2] = b.z.x; _pb[o + 3] = p.x
	_pb[o + 4] = b.x.y; _pb[o + 5] = b.y.y; _pb[o + 6] = b.z.y; _pb[o + 7] = p.y
	_pb[o + 8] = b.x.z; _pb[o + 9] = b.y.z; _pb[o + 10] = b.z.z; _pb[o + 11] = p.z
	_pb[o + 12] = c.r; _pb[o + 13] = c.g; _pb[o + 14] = c.b; _pb[o + 15] = c.a
	_pb[o + 16] = cu.r; _pb[o + 17] = cu.g; _pb[o + 18] = cu.b; _pb[o + 19] = cu.a

func _sparks_upload(gn: int) -> int:
	for i in s_n:
		if gn >= GLOW_CAP: break
		var a := s_life[i] / s_max[i]
		var c := s_col[i]
		c.a = a
		_g(gn * 20, s_pos[i], s_size[i] * (0.4 + a), c, 2.0)
		gn += 1
	return gn

func _gems(dt: float) -> void:
	var n := 0
	var cull := w.view_r + 40.0
	var gc := Color("6be8ff") if not w.colorblind else Color("56b4e9")
	for i in w.gem_n:
		var g := w.gem_pos[i]
		if g.distance_to(w.pp) > cull: continue
		var big := w.gem_val[i] >= 4.0
		var s := 9.0 if big else 6.0
		var b := Basis(Vector3.UP, time * 2.5 + i).scaled(Vector3(s, s * 1.6, s))
		var p := Vector3(g.x, view.ground_y(g) + 10.0 + sin(time * 4.0 + i) * 2.5, g.y)
		var c := Color("ffd84a") if big else gc
		var o := n * 20
		_gemb[o] = b.x.x; _gemb[o + 1] = b.y.x; _gemb[o + 2] = b.z.x; _gemb[o + 3] = p.x
		_gemb[o + 4] = b.x.y; _gemb[o + 5] = b.y.y; _gemb[o + 6] = b.z.y; _gemb[o + 7] = p.y
		_gemb[o + 8] = b.x.z; _gemb[o + 9] = b.y.z; _gemb[o + 10] = b.z.z; _gemb[o + 11] = p.z
		_gemb[o + 12] = c.r; _gemb[o + 13] = c.g; _gemb[o + 14] = c.b; _gemb[o + 15] = 1.0
		_gemb[o + 16] = 2.2; _gemb[o + 17] = 0.0; _gemb[o + 18] = 0.0; _gemb[o + 19] = 0.0
		n += 1
	var mm := gem_mm.multimesh
	if n > 0: mm.buffer = _gemb          # nothing to draw: skip the upload
	mm.visible_instance_count = n

func _blades() -> void:
	var mm := blade_mm.multimesh
	var n := mini(w.blades.size(), 32)
	var cyc := w.buffs.has("cyclone")
	for k in n:
		var bp := view.lerp_pos(w.blades_prev[k], w.blades[k]) if k < w.blades_prev.size() else w.blades[k]
		var tang := (bp - view.hero_p).orthogonal().normalized()
		var d := Vector3(tang.x, 0, tang.y)
		var s := 22.0 if cyc else 15.0
		var b := Basis(d * s, Vector3.UP * s, d.cross(Vector3.UP) * s)
		mm.set_instance_transform(k, Transform3D(b, Vector3(bp.x, view.ground_y(bp) + 14.0, bp.y)))
		mm.set_instance_color(k, Color(0.95, 0.85, 0.55))
		mm.set_instance_custom_data(k, Color(1.5 if cyc else 0.6, 0.0, 0.9, 0.0))
	mm.visible_instance_count = n

func _debris_upload() -> void:
	for i in d_n:
		var r := d_rot[i]
		var s := d_size[i] * clampf(d_life[i] * 2.0, 0.0, 1.0)
		var b := Basis.from_euler(r).scaled(Vector3(s, s * 1.4, s * 0.7))
		var p := d_pos[i]
		var c := d_col[i]
		var o := i * 20
		_db[o] = b.x.x; _db[o + 1] = b.y.x; _db[o + 2] = b.z.x; _db[o + 3] = p.x
		_db[o + 4] = b.x.y; _db[o + 5] = b.y.y; _db[o + 6] = b.z.y; _db[o + 7] = p.y
		_db[o + 8] = b.x.z; _db[o + 9] = b.y.z; _db[o + 10] = b.z.z; _db[o + 11] = p.z
		_db[o + 12] = c.r; _db[o + 13] = c.g; _db[o + 14] = c.b; _db[o + 15] = 1.0
		_db[o + 16] = 0.0; _db[o + 17] = 0.6; _db[o + 18] = 0.0; _db[o + 19] = 0.0      # x emission 0 (chips glowed pale), y rough
	var mm := debris_mm.multimesh
	if d_n > 0: mm.buffer = _db          # nothing to draw: skip the upload
	mm.visible_instance_count = d_n

func _pickups(gn: int) -> int:
	var counts := {"disc": 0, "orb": 0, "box": 0, "octa": 0}
	var bn := 0
	var bmm := beam_mm.multimesh
	for p in w.picks:
		var pos: Vector2 = p.pos
		if pos.distance_to(w.pp) > w.view_r + 60.0: continue
		var gy := view.ground_y(pos)
		var bob := sin(time * 4.0 + pos.x * 0.07) * 2.0
		var shape := "orb"
		var c := Color.WHITE
		var s := Vector3(9, 9, 9)
		var em := 0.6
		var rot := Basis(Vector3.UP, time * 2.0 + pos.y * 0.1)
		match p.k:
			"coin": shape = "disc"; c = Color("ffd84a"); s = Vector3(8, 8, 8); em = 0.5; rot = Basis(Vector3.RIGHT, PI / 2).rotated(Vector3.UP, time * 4.0 + pos.x)
			"heart": c = Color("ff3a4e"); s = Vector3(10, 10, 10); em = 0.8
			"item":
				shape = "box"
				var it: Dictionary = p.data
				c = Content.col(Content.RARITY_COL[it.rarity])
				s = Vector3(9, 12, 6); em = 0.4
				if int(it.rarity) >= Content.Rarity.MAGIC and bn < 120:
					var h: float = 60.0 + 70.0 * it.rarity
					bmm.set_instance_transform(bn, Transform3D(Basis().scaled(Vector3(10 + it.rarity * 3, h, 10 + it.rarity * 3)), Vector3(pos.x, gy + h * 0.5, pos.y)))
					bmm.set_instance_color(bn, Color(c.r, c.g, c.b, 0.5 + 0.15 * it.rarity))
					bn += 1
			"currency": c = Content.col(Content.CURRENCY[p.data].col); s = Vector3(7, 7, 7); em = 1.5
			"lore": shape = "box"; c = Color("e8dcc0"); s = Vector3(10, 2, 13); em = 0.3
			"fragment", "splinter":
				shape = "octa"; c = Color("c48aff"); s = Vector3(8, 16, 8); em = 2.0
				if p.k == "fragment" and bn < 120:
					bmm.set_instance_transform(bn, Transform3D(Basis().scaled(Vector3(14, 260, 14)), Vector3(pos.x, gy + 130.0, pos.y)))
					bmm.set_instance_color(bn, Color(0.77, 0.54, 1.0, 0.8))
					bn += 1
			"progress": c = Color("ff4fd8"); em = 2.5
			"flask": shape = "box"; c = Color("c9f3ff"); s = Vector3(6, 11, 6); em = 0.8
			_:
				c = {"magnet": Color("8b6bff"), "frenzy": Color("ff8a2b"), "aegis": Color("ffd24a"), "vital": Color("5dff6b"), "nuke": Color("9fefff")}.get(p.k, Color.WHITE) as Color
				em = 2.5
				s = Vector3(11, 11, 11)
		var mm: MultiMesh = pick_mm[shape].multimesh
		var n: int = counts[shape]
		if n >= mm.instance_count: continue
		mm.set_instance_transform(n, Transform3D(rot.scaled(s), Vector3(pos.x, gy + 9.0 + bob, pos.y)))
		mm.set_instance_color(n, c)
		mm.set_instance_custom_data(n, Color(em, 0.2, 0.6 if shape == "disc" else 0.0, 0.0))
		counts[shape] = n + 1
		if em >= 1.5 and gn < GLOW_CAP:
			_g(gn * 20, Vector3(pos.x, gy + 10.0 + bob, pos.y), 30.0, Color(c.r, c.g, c.b, 0.5), 0.0)
			gn += 1
	for shape in counts:
		pick_mm[shape].multimesh.visible_instance_count = counts[shape]
	bmm.visible_instance_count = bn
	return gn

# ================================================================= lightning ribbons
func _ribbon(pts: PackedVector3Array, width: float, col: Color) -> void:
	var cam_pos := view.cam.global_position
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var side := (b - a).cross(cam_pos - a).normalized() * width
		bolt_mesh.surface_set_color(col)
		bolt_mesh.surface_set_uv(Vector2(0, 0)); bolt_mesh.surface_add_vertex(a - side)
		bolt_mesh.surface_set_uv(Vector2(0, 1)); bolt_mesh.surface_add_vertex(a + side)
		bolt_mesh.surface_set_uv(Vector2(1, 1)); bolt_mesh.surface_add_vertex(b + side)
		bolt_mesh.surface_set_uv(Vector2(0, 0)); bolt_mesh.surface_add_vertex(a - side)
		bolt_mesh.surface_set_uv(Vector2(1, 1)); bolt_mesh.surface_add_vertex(b + side)
		bolt_mesh.surface_set_uv(Vector2(1, 0)); bolt_mesh.surface_add_vertex(b - side)

## The Emberwitch's fire between events: embers rising off every Incineration zone, flames off every lit
## trunk (Contagion.zones, beacons). Fewer on the Low tier.
func _contagion(_dt: float) -> void:
	var cg := w.contagion
	if cg == null: return
	var per := 1 if Quality.tier() == 0 else 3
	for z in cg.zones:
		var zp: Vector2 = z.pos
		var zr: float = z.r
		for i in per:
			var a := randf() * TAU
			var q := zp + Vector2(cos(a), sin(a)) * zr * sqrt(randf())
			_spark(Vector3(q.x, view.ground_y(q) + 4.0, q.y), Vector3(randf_range(-20, 20), randf_range(240, 420), randf_range(-20, 20)), Color(1.0, randf_range(0.3, 0.65), 0.1), randf_range(0.5, 1.0), randf_range(2.5, 5.0))
	for b in cg.beacons:
		var bp: Vector2 = b.pos
		var br: float = b.r
		for i in per:
			var a2 := randf() * TAU
			var h := randf_range(30.0, 120.0)
			_spark(Vector3(bp.x + cos(a2) * br * 0.8, view.ground_y(bp) + h, bp.y + sin(a2) * br * 0.8), Vector3(randf_range(-25, 25), randf_range(180, 340), randf_range(-25, 25)), Color(1.0, randf_range(0.35, 0.7), 0.12), randf_range(0.4, 0.8), randf_range(3.0, 6.0))

func _lightning() -> void:
	bolt_mesh.clear_surfaces()
	var any := false
	for f in w.fx:
		if f.k == "zap" or f.k == "arc" or f.k == "fire_arc": any = true
	if not any: return
	bolt_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, bolt_mat)
	for f in w.fx:
		var k: float = 1.0 - clampf(f.t / f.life, 0, 1)
		var col: Color = f.col
		col.a = k
		if f.k == "zap":                 # a strike falls from the sky in jagged steps
			var at: Vector2 = f.pos
			var pts := PackedVector3Array()
			var seed_v := int(f.pos.x * 13.0 + f.pos.y * 7.0)
			for s in 9:
				var y := 420.0 * (1.0 - s / 8.0)
				var j := 0.0 if s == 8 else 1.0
				pts.append(Vector3(at.x + sin(seed_v + s * 2.1 + time * 30.0) * 16.0 * j, y, at.y + cos(seed_v * 0.7 + s * 1.7) * 16.0 * j))
			_ribbon(pts, 9.0 * k + 2.0, col)
			_ribbon(pts, 3.0, Color(1, 1, 1, k))
		elif f.k == "arc":
			var src: PackedVector2Array = f.pts
			var pts2 := PackedVector3Array()
			for i in src.size():
				pts2.append(Vector3(src[i].x, 20.0, src[i].y))
				if i < src.size() - 1:
					var m := (src[i] + src[i + 1]) * 0.5
					pts2.append(Vector3(m.x + randf_range(-10, 10), 24.0 + randf_range(-6, 6), m.y + randf_range(-10, 10)))
			_ribbon(pts2, 5.0, col)
		elif f.k == "fire_arc":          # fire leaping from a burning foe to its neighbour: a low ember arc
			var a0: Vector2 = f.pos
			var b0: Vector2 = f.to
			var lift := 18.0 + 0.3 * a0.distance_to(b0)
			var pts3 := PackedVector3Array()
			for s in 7:                   # heights over the ground: the ribbon shader drapes them (th())
				var u := s / 6.0
				var q := a0.lerp(b0, u)
				pts3.append(Vector3(q.x, 16.0 + 4.0 * lift * u * (1.0 - u), q.y))
			_ribbon(pts3, 4.0 * k + 1.5, col)
			_ribbon(pts3, 1.5, Color(1.0, 0.9, 0.6, k))
	bolt_mesh.surface_end()

# ================================================================= ground decals
func _decal(pos: Vector2, xform_basis: Basis, kind: float, col: Color, prog: float, inner: float = 0.0, hatch: bool = false, y: float = 0.6) -> void:
	if _decal_used >= DECAL_POOL: return
	var d := decals[_decal_used]
	_decal_used += 1
	Diag.first("decal kind %d" % int(kind))
	d.visible = true
	d.transform = Transform3D(xform_basis, Vector3(pos.x, y, pos.y))
	d.set_instance_shader_parameter("col", col)
	d.set_instance_shader_parameter("kind", kind)
	d.set_instance_shader_parameter("prog", prog)
	d.set_instance_shader_parameter("inner", inner)
	d.set_instance_shader_parameter("hatch", 1.0 if hatch else 0.0)

func _circle(pos: Vector2, r: float, kind: float, col: Color, prog: float, inner: float = 0.0, hatch: bool = false) -> void:
	_decal(pos, Basis().scaled(Vector3(r, 1, r)), kind, col, prog, inner, hatch)

func _decals() -> void:
	_decal_used = 0
	if w.arena_r > 0.0:
		_circle(Vector2.ZERO, w.arena_r + 20.0, 1, Color(0.75, 0.5, 1.0, 0.8), 1.0, w.arena_r / (w.arena_r + 20.0))
	for z in w.teles:
		if z.col.a <= 0.01: continue
		var prog := 1.0 - clampf(z.arm / z.arm_max, 0.0, 1.0) if z.arm > 0.0 else 1.0
		var c := Color(z.col.r, z.col.g, z.col.b, minf(1.0, z.col.a + 0.3))
		match z.shape:
			0:
				if z.hostile: _circle(z.pos, z.r, 0, c, prog, 0.0, w.colorblind)
				else:                                          # your own consecrated / burning ground
					_circle(z.pos, z.r, 5, Color(c.r, c.g, c.b, 0.22), 1.0)
					_circle(z.pos, z.r, 1, Color(c.r, c.g, c.b, 0.5), 1.0, 0.97)
			1: _circle(z.pos, z.r, 1, c, prog, z.r2 / z.r)
			2:
				var d := Vector3(z.dir.x, 0, z.dir.y)
				var half := z.length * 0.5
				var bb := Basis(d * half, Vector3.UP, d.cross(Vector3.UP) * z.width * 0.5)
				_decal(z.pos + z.dir * half, bb, 2, c, prog)
			3:
				var d2 := Vector3(z.dir.x, 0, z.dir.y)
				_decal(z.pos, Basis(d2 * z.r, Vector3.UP, d2.cross(Vector3.UP) * z.r), 3, c, prog, z.ang)
	var rings := 0
	for f in w.fx:
		if f.k == "ring": rings += 1
	var ring_dim := 1.0 if rings <= 4 else maxf(0.35, sqrt(4.0 / rings))
	var cg := w.contagion
	if cg != null:
		for z in cg.zones:                                 # Incineration: burning ground and its edge
			var fade := clampf((Contagion.ZONE_TIME - float(z.t)) / 0.4, 0.0, 1.0)
			_circle(z.pos, z.r, 5, Color(1.0, 0.42, 0.1, 0.3 * fade), 1.0)
			_circle(z.pos, z.r, 1, Color(1.0, 0.58, 0.2, 0.7 * fade), 1.0, 0.95)
	for f in w.fx:
		if f.k == "ring":
			var k: float = clampf(f.t / f.life, 0, 1)
			var rc: Color = f.col
			rc.a *= ring_dim                              # many at once: each one dimmer, the total stays readable
			_circle(f.pos, maxf(20.0, float(f.max)), 4, rc, k)
	for ev in w.director.active:
		var col := Content.col(Content.EVENTS[ev.id].col)
		match ev.id:
			"breach":
				_circle(ev.pos, ev.r, 6, Color(0.75, 0.5, 1.0, 0.45), 1.0)
				_circle(ev.pos, ev.r * 0.98, 5, Color(0.5, 0.25, 0.9, 0.12), 1.0)
			"cursed":
				_circle(ev.pos, 40.0, 6, col, 1.0)
				if ev.state == 1: _circle(ev.pos, 260.0, 1, Color(1, 0.3, 0.35, 0.6), 1.0, 0.985)
			"ritual": _circle(ev.pos, 160.0 if ev.state == 1 else 40.0, 6, Color(1, 0.15, 0.25, 0.9), 1.0)
			"delirium":
				_circle(ev.pos, ev.r, 1, Color(0.9, 0.9, 1.0, 0.5), 1.0, 0.99)
				_circle(ev.pos, ev.r, 5, Color(0.7, 0.7, 0.8, 0.12 if ev.inside else 0.06), 1.0)
			"strongbox", "merchant": _circle(ev.pos, 34.0, 6, col, 1.0)
	for o in w.director.objects:
		var oc := Content.col(Content.BUFFS[o.id].col)
		_circle(o.pos, 46.0, 6, oc, 1.0)
		_circle(o.pos, 70.0, 5, Color(oc.r, oc.g, oc.b, 0.35), 1.0)
	for i in range(_decal_used, DECAL_POOL):
		if not decals[i].visible: break
		decals[i].visible = false
	# persistent marks (blood, scorch, craters), fading over 20 s
	var mm := marks_mm.multimesh
	var n := 0
	for m in _marks:
		var age: float = time - float(m[4])
		var a := clampf(1.0 - age / 20.0, 0.0, 1.0)
		if a <= 0.0: continue
		var s: float = m[2]
		marks_mm.multimesh.set_instance_transform(n, mark_xform(m, view.ground_y(m[0])))
		var mc := Color(0.32, 0.02, 0.03) if m[3] == 0 else (Color(0.05, 0.04, 0.04) if m[3] == 1 else Color(0.12, 0.1, 0.09))
		mm.set_instance_color(n, mc)
		mm.set_instance_custom_data(n, Color(a * 0.75, float(m[1]), 0, 0))
		n += 1
	mm.visible_instance_count = n

# ================================================================= event props
## Event props (chests, strongboxes, shrines, pylons, gates, the merchant, rituals) are lit by prop.gdshader
## like the act's own props: vertex colours with its noise breakup, base occlusion, roughness and rim, and
## the glow parts in the event's colour. One material per colour, shared, its time kept running.
var _obj_mats := {}
func _obj_mat(col: Color) -> ShaderMaterial:
	if not _obj_mats.has(col):
		var sm := ShaderMaterial.new()
		sm.shader = load("res://shaders/3d/prop.gdshader")
		sm.set_shader_parameter("glow_col", col)
		sm.set_shader_parameter("push_n", 0)
		_obj_mats[col] = sm
	return _obj_mats[col]

func _make_obj(kind: String, col: Color) -> Node3D:
	var n := Node3D.new()
	var k := MeshKit.new()
	match kind:
		"chest", "strongbox", "cursed":
			var wood := Color(0.45, 0.3, 0.18) if kind != "cursed" else Color(0.45, 0.08, 0.1)
			k.add("box", Vector3(0, 9, 0), Vector3(34, 18, 22), wood)
			k.add("cyl", Vector3(0, 19, 0), Vector3(22, 34, 22), wood.lightened(0.1), 0, 0, Vector3(PI / 2, 0, PI / 2), 10)
			k.add("box", Vector3(0, 12, 11.5), Vector3(36, 3, 1), Color(0.85, 0.7, 0.3))
			k.add("box", Vector3(0, 13, 12), Vector3(5, 7, 2), Color(1, 0.85, 0.3), MeshKit.PART_GLOW)
		"pylon":
			k.add("box", Vector3(0, 4, 0), Vector3(30, 8, 30), Color(0.3, 0.3, 0.34))
			k.add("prism", Vector3(0, 46, 0), Vector3(16, 76, 16), col, MeshKit.PART_GLOW)
			k.add("prism", Vector3(0, 46, 0), Vector3(16, 76, 16), col, MeshKit.PART_GLOW, 0, Vector3(0, PI / 2, 0))
		"shrine":
			k.add("box", Vector3(0, 3, 0), Vector3(36, 6, 36), Color(0.35, 0.34, 0.36))
			k.add("box", Vector3(0, 26, 0), Vector3(18, 40, 10), Color(0.45, 0.44, 0.47))
			k.add("sphere", Vector3(0, 34, 6), Vector3(8, 8, 3), col, MeshKit.PART_GLOW)
		"merchant":
			k.add("cone", Vector3(0, 20, 0), Vector3(22, 40, 22), Color(0.2, 0.42, 0.28), 0, 0, Vector3.ZERO, 10)
			k.add("sphere", Vector3(2, 42, 0), Vector3(12, 12, 12), Color(0.85, 0.72, 0.55))
			k.add("sphere", Vector3(-8, 24, 0), Vector3(18, 20, 18), Color(0.5, 0.36, 0.2))
			k.add("sphere", Vector3(10, 30, 10), Vector3(5, 5, 5), Color(1, 0.8, 0.4), MeshKit.PART_GLOW)
		"gate":               # a standing ring of dressed stones around a glowing veil (faces the camera)
			k.add("cyl", Vector3(0, 2, 0), Vector3(96, 4, 40), Color(0.24, 0.24, 0.28), 0, 0, Vector3.ZERO, 16)
			for i in 16:
				var a := PI * (i + 0.5) / 16.0 - 0.18
				var a2 := a * (PI + 0.36) / PI
				var rp := Vector3(cos(a2) * 44.0, 8.0 + sin(a2) * 54.0, 0)
				k.add("box", rp, Vector3(9, 13, 10), Color(0.34, 0.35, 0.4).darkened(0.1 * (i % 3)), 0, 0, Vector3(0, 0, a2 - PI / 2.0))
				if i % 3 == 1: k.add("box", rp + Vector3(0, 0, 5.5), Vector3(3, 6, 1), col, MeshKit.PART_GLOW, 0, Vector3(0, 0, a2 - PI / 2.0))
			k.add("cyl", Vector3(0, 32, -1), Vector3(78, 2, 96), col, MeshKit.PART_GLOW, 0, Vector3(PI / 2.0, 0, 0), 24)
		"whisper":            # a hooded, faceless figure with two violet eyes and orbiting shards
			k.add("cone", Vector3(0, 26, 0), Vector3(30, 52, 30), Color(0.05, 0.04, 0.07), 0, 0, Vector3.ZERO, 12)
			k.add("sphere", Vector3(0, 52, 0), Vector3(17, 19, 17), Color(0.06, 0.05, 0.08))
			k.add("sphere", Vector3(3.5, 52, 6.5), Vector3(11, 12, 6), Color(0.0, 0.0, 0.0))
			k.add("sphere", Vector3(-2.2, 53, 9.2), Vector3(2.2, 1.4, 1.2), col, MeshKit.PART_GLOW)
			k.add("sphere", Vector3(2.2, 53, 9.2), Vector3(2.2, 1.4, 1.2), col, MeshKit.PART_GLOW)
			for i in 5:
				var a := TAU * i / 5.0
				k.add("prism", Vector3(cos(a) * 30.0, 30 + 8.0 * sin(a * 2.0), sin(a) * 30.0), Vector3(4, 12, 4), col, MeshKit.PART_GLOW)
		"ritual":
			k.add("cyl", Vector3(0, 6, 0), Vector3(40, 12, 40), Color(0.3, 0.27, 0.27), 0, 0, Vector3.ZERO, 6)
			for i in 5:
				var a := TAU * i / 5.0
				k.add("cyl", Vector3(cos(a) * 26.0, 18, sin(a) * 26.0), Vector3(3, 10, 3), Color(0.9, 0.85, 0.75))
				k.add("sphere", Vector3(cos(a) * 26.0, 25, sin(a) * 26.0), Vector3(3, 5, 3), Color(1, 0.3, 0.2), MeshKit.PART_GLOW)
		_:
			k.add("sphere", Vector3(0, 10, 0), Vector3(20, 20, 20), col, MeshKit.PART_GLOW)
	var mi := MeshInstance3D.new()
	mi.mesh = k.commit()
	mi.material_override = _obj_mat(col)
	n.add_child(mi)
	add_child(n)
	return n

func _event_props(dt: float) -> void:
	for c in _obj_mats: _obj_mats[c].set_shader_parameter("time", time)
	var want := {}
	for ev in w.director.active:
		var kind := ""
		match ev.id:
			"cursed", "strongbox", "merchant", "ritual": kind = ev.id
		if kind == "": continue
		var key := "ev%d" % ev.uid
		want[key] = true
		if not objs.has(key): objs[key] = _make_obj(kind, Content.col(Content.EVENTS[ev.id].col))
		objs[key].position = Vector3(ev.pos.x, view.ground_y(ev.pos), ev.pos.y)
		if ev.id == "cursed" and ev.state == 1: objs[key].rotation.y += dt * 0.5
	for o in w.director.objects:
		var key2 := "ob%d_%d" % [int(o.pos.x), int(o.pos.y)]
		want[key2] = true
		if not objs.has(key2): objs[key2] = _make_obj(o.kind, Content.col(Content.BUFFS[o.id].col))
		objs[key2].position = Vector3(o.pos.x, view.ground_y(o.pos), o.pos.y)
		if o.kind == "pylon": objs[key2].rotation.y += dt * 0.8
		elif o.kind == "gate":            # shrinks away in its last 3 s
			objs[key2].scale = Vector3.ONE * clampf(float(o.life) / 3.0, 0.15, 1.0)
		elif o.kind == "whisper":       # turns to watch the hero, bobs, and fades in its last seconds
			var to: Vector2 = w.pp - o.pos
			objs[key2].rotation.y = lerp_angle(objs[key2].rotation.y, atan2(to.x, to.y), minf(1.0, dt * 2.0))
			objs[key2].position.y += 6.0 + sin(time * 1.7) * 3.0
			objs[key2].scale = Vector3.ONE * clampf(float(o.life) / 3.0, 0.2, 1.0)
	for key3 in objs.keys():
		if not want.has(key3):
			objs[key3].queue_free()
			objs.erase(key3)
