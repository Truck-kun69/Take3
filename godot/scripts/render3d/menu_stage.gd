class_name MenuStage3D
extends Node3D
## Character-select backdrop (PoE2 / Diablo IV style): the chosen hero idles on cracked flagstones
## between two braziers, a rift crystal hangs behind them, fog drifts and embers rise. It sits far
## from the play field and has its own camera and environment, so it never touches a run.

const ORIGIN := Vector3(200000, 0, 0)
const HERO_AT := Vector2(-45, 30)     # sim-space spot the hero stands on, between the braziers
var frame_x := 0.62                   # where on screen (0..1) the hero should stand; set by the menu layout
var cam: Camera3D
var hero: HeroRig
var hero_id := ""
var crystal: MeshInstance3D
var crystal_mat: StandardMaterial3D
var rift_light: OmniLight3D
var key_light: OmniLight3D
var braziers: Array[OmniLight3D] = []
var fog_mat: ShaderMaterial
var terrain_mat: ShaderMaterial
var t := 0.0
var _cast_t := 0.0

func _ready() -> void:
	position = ORIGIN
	cam = Camera3D.new()
	cam.fov = 34.0
	cam.near = 2.0
	cam.far = 4000.0
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.02, 0.018, 0.03)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.32, 0.3, 0.42)
	e.ambient_light_energy = 0.25
	e.tonemap_mode = Environment.TONE_MAPPER_ACES
	e.glow_enabled = true
	e.glow_intensity = 0.9
	e.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	e.fog_enabled = true
	e.fog_light_color = Color(0.08, 0.07, 0.12)
	e.fog_density = 0.0016
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.2, 0.18, 0.3); sm.sky_horizon_color = Color(0.12, 0.1, 0.16)
	var sky := Sky.new(); sky.sky_material = sm
	e.sky = sky
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	cam.environment = e
	add_child(cam)
	var moon := DirectionalLight3D.new()
	moon.rotation = Vector3(deg_to_rad(-38), deg_to_rad(28), 0)
	moon.light_color = Color(0.55, 0.62, 0.9)
	moon.light_energy = 0.35
	moon.shadow_enabled = true
	add_child(moon)
	# ground
	terrain_mat = ShaderMaterial.new()
	terrain_mat.shader = load("res://shaders/3d/terrain.gdshader")
	terrain_mat.set_shader_parameter("c0", Color("15131f")); terrain_mat.set_shader_parameter("c1", Color("2c2942"))
	terrain_mat.set_shader_parameter("c2", Color("3a3658")); terrain_mat.set_shader_parameter("acc", Color("8fd8ff"))
	var g := MeshInstance3D.new()
	var pm := PlaneMesh.new(); pm.size = Vector2(1600, 1600)
	g.mesh = pm
	g.material_override = terrain_mat
	add_child(g)
	# ruins and rocks framing the scene
	var prop_mat := ShaderMaterial.new()
	prop_mat.shader = load("res://shaders/3d/prop.gdshader")
	prop_mat.set_shader_parameter("tint", Color(0.7, 0.68, 0.75))
	prop_mat.set_shader_parameter("glow_col", Color("8fd8ff"))
	for spec in [["pillar", Vector3(-190, 0, -90), 1.4, 0.3], ["pillar", Vector3(150, 0, -150), 1.7, 1.2], ["pillar", Vector3(-60, 0, -220), 1.2, 2.0],
			["rock", Vector3(90, 0, 40), 1.2, 0.5], ["rock", Vector3(-150, 0, 30), 1.0, 2.2], ["crystal", Vector3(110, 0, -60), 1.0, 0.4], ["bones", Vector3(-40, 0, 60), 1.0, 1.0]]:
		var mi := MeshInstance3D.new()
		mi.mesh = Models.prop_mesh(spec[0])
		mi.material_override = prop_mat
		mi.position = spec[1]
		mi.scale = Vector3.ONE * float(spec[2])
		mi.rotation.y = spec[3]
		add_child(mi)
	# the rift crystal hanging behind the hero
	crystal = MeshInstance3D.new()
	var oct := SphereMesh.new(); oct.radial_segments = 6; oct.rings = 2; oct.radius = 0.5; oct.height = 1.0
	crystal.mesh = oct
	crystal_mat = StandardMaterial3D.new()             # faceted, self-lit shard: glow picks it up
	crystal_mat.albedo_color = Color("3a2470")
	crystal_mat.metallic = 0.4
	crystal_mat.roughness = 0.15
	crystal_mat.emission_enabled = true
	crystal_mat.emission = Color("9a7aff")
	crystal_mat.emission_energy_multiplier = 1.6
	crystal_mat.rim_enabled = true
	crystal_mat.rim = 0.8
	crystal.material_override = crystal_mat
	crystal.scale = Vector3(20, 58, 20)
	crystal.position = Vector3(-25, 112, -150)
	add_child(crystal)
	rift_light = _omni(Vector3(-25, 108, -110), Color("9a7aff"), 260.0, 9.0)
	# braziers: stone bowl, embers, flickering firelight
	for x in [-118.0, 28.0]:                              # either side of the hero, slightly behind
		var bz := MeshInstance3D.new()
		var k := MeshKit.new()
		k.add("cyl", Vector3(0, 14, 0), Vector3(10, 28, 10), Color(0.35, 0.33, 0.36), 0, 0, Vector3.ZERO, 10)
		k.add("cyl", Vector3(0, 30, 0), Vector3(26, 6, 26), Color(0.3, 0.28, 0.3), 0, 0, Vector3.ZERO, 12)
		k.add("sphere", Vector3(0, 33, 0), Vector3(20, 8, 20), Color(1.0, 0.55, 0.2), MeshKit.PART_GLOW, 0, Vector3.ZERO, 10)
		bz.mesh = k.commit()
		var bm := ShaderMaterial.new()
		bm.shader = load("res://shaders/3d/prop.gdshader")
		bm.set_shader_parameter("glow_col", Color(1.0, 0.5, 0.15))
		bm.set_shader_parameter("tint", Color(0.8, 0.78, 0.8))
		bz.material_override = bm
		bz.position = Vector3(x, 0, -15)
		add_child(bz)
		braziers.append(_omni(Vector3(x, 50, -11), Color(1.0, 0.6, 0.3), 240.0, 10.0))
		add_child(_flames(Vector3(x, 34, -15)))
	add_child(_embers())
	# warm key light from the camera side and a cool rim from behind, so textured heroes read on the dark stage
	key_light = _omni(Vector3(HERO_AT.x + 70, 90, HERO_AT.y + 110), Color(1.0, 0.82, 0.62), 260.0, 7.0)
	_omni(Vector3(HERO_AT.x - 40, 70, HERO_AT.y - 80), Color(0.55, 0.65, 1.0), 200.0, 5.0)
	fog_mat = ShaderMaterial.new()
	fog_mat.shader = load("res://shaders/3d/fog.gdshader")
	fog_mat.set_shader_parameter("fog_col", Color(0.35, 0.33, 0.45))
	fog_mat.set_shader_parameter("density", 0.4)
	var fog := MeshInstance3D.new()
	var fp := PlaneMesh.new(); fp.size = Vector2(1400, 1400)
	fog.mesh = fp
	fog.material_override = fog_mat
	fog.position.y = 6.0
	add_child(fog)
	visible = false

func _omni(p: Vector3, c: Color, r: float, e: float) -> OmniLight3D:
	var l := OmniLight3D.new()
	l.position = p
	l.light_color = c
	l.omni_range = r
	l.omni_attenuation = 0.5
	l.light_energy = e
	add_child(l)
	return l

func _spark_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.albedo_color = c
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var gt := GradientTexture2D.new()
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5); gt.fill_to = Vector2(0.5, 0.0)
	var gr := Gradient.new()
	gr.set_color(0, Color(1, 1, 1, 1)); gr.set_color(1, Color(1, 1, 1, 0))
	gt.gradient = gr
	m.albedo_texture = gt
	return m

func _flames(p: Vector3) -> CPUParticles3D:
	var f := CPUParticles3D.new()
	f.position = p
	f.amount = 40
	f.lifetime = 0.7
	var q := QuadMesh.new(); q.size = Vector2(9, 9)
	q.material = _spark_mat(Color(1.0, 0.55, 0.2))
	f.mesh = q
	f.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	f.emission_sphere_radius = 7.0
	f.direction = Vector3.UP
	f.spread = 15.0
	f.gravity = Vector3(0, 30, 0)
	f.initial_velocity_min = 20.0; f.initial_velocity_max = 45.0
	f.scale_amount_min = 0.6; f.scale_amount_max = 1.6
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1.0, 0.85, 0.4, 1.0)); ramp.set_color(1, Color(0.9, 0.2, 0.05, 0.0))
	f.color_ramp = ramp
	return f

func _embers() -> CPUParticles3D:
	var f := CPUParticles3D.new()
	f.position = Vector3(-40, 10, 0)
	f.amount = 70
	f.lifetime = 6.0
	f.preprocess = 6.0
	var q := QuadMesh.new(); q.size = Vector2(2.2, 2.2)
	q.material = _spark_mat(Color(1.0, 0.6, 0.25))
	f.mesh = q
	f.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	f.emission_box_extents = Vector3(220, 10, 120)
	f.direction = Vector3.UP
	f.spread = 25.0
	f.gravity = Vector3(4, 6, 0)
	f.initial_velocity_min = 8.0; f.initial_velocity_max = 22.0
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1.0, 0.7, 0.3, 0.0)); ramp.add_point(0.2, Color(1.0, 0.65, 0.3, 1.0)); ramp.set_color(ramp.get_point_count() - 1, Color(1.0, 0.3, 0.1, 0.0))
	f.color_ramp = ramp
	return f

## Aim the camera at the hero, then yaw it so the hero lands at `frame_x` across the screen.
func _frame() -> void:
	var hero_c := Vector3(HERO_AT.x, 42.0, HERO_AT.y)
	cam.position = hero_c + Vector3(40.0, 46.0, 300.0)
	cam.look_at(global_position + hero_c, Vector3.UP)
	var vs := get_viewport().get_visible_rect().size
	var aspect := vs.x / maxf(1.0, vs.y)
	var half_h := atan(tan(deg_to_rad(cam.fov) * 0.5) * aspect)
	cam.rotate_y(atan((frame_x - 0.5) * 2.0 * tan(half_h)))

func show_stage(hero_index: int) -> void:
	visible = true
	_frame()
	cam.make_current()
	var h: Dictionary = Content.HEROES[hero_index]
	if String(h.id) != hero_id:
		hero_id = String(h.id)
		if hero != null: hero.queue_free()
		hero = HeroRig.new()
		add_child(hero)
		hero.build(hero_id, Content.col(h.col))
		hero.scale = Vector3.ONE * 1.5
		_cast_t = 0.6                                    # greet with a cast flourish

func hide_stage() -> void:
	visible = false

func _process(dt: float) -> void:
	if not visible: return
	t += dt
	_cast_t += dt
	if _cast_t > 5.0: _cast_t = 0.0
	if hero != null:
		var face := Vector2(0.55, 1.0).normalized()
		# HeroRig positions in its parent's space; the stage itself is offset to ORIGIN
		hero.animate({"pos": HERO_AT, "face": face, "mv": 0.0, "ph": 0.0, "cast_age": _cast_t, "cast_dir": face,
			"roll": -1.0, "hit": 0.0, "dead": false, "t": t}, dt)
	crystal.position.y = 112.0 + sin(t * 0.8) * 6.0
	crystal.rotation.y = t * 0.3
	crystal_mat.emission_energy_multiplier = 1.4 + 0.6 * sin(t * 1.7)
	rift_light.light_energy = 8.0 + 2.0 * sin(t * 1.7)
	for i in braziers.size():
		braziers[i].light_energy = 10.0 * (1.0 + 0.12 * sin(t * 9.0 + i * 2.0) + 0.07 * sin(t * 23.0 + i))
	terrain_mat.set_shader_parameter("time", t)
	fog_mat.set_shader_parameter("time", t)
