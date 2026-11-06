extends Node3D
## Model turntable for visual critique, lit like the game (dim ambient, low sun, warm torches).
##   xvfb-run -a godot --path godot --rendering-method mobile res://tests/model_view.tscn -- <out.png> [heroes|foes|bosses]
var t := 0.0
var rigs: Array = []
var mode := "heroes"
var out := "user://models.png"
var foe_mm: Array = []

func _ready() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: out = a[0]
	if a.size() > 1: mode = a[1]
	var we := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.05, 0.05, 0.07)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.35, 0.33, 0.4)
	e.ambient_light_energy = 0.35
	e.tonemap_mode = Environment.TONE_MAPPER_ACES
	e.glow_enabled = true
	e.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	var sm := ProceduralSkyMaterial.new()
	var sky := Sky.new(); sky.sky_material = sm
	e.sky = sky
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	we.environment = e
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-48), deg_to_rad(-35), 0)
	sun.light_energy = 0.7
	sun.light_color = Color(0.85, 0.85, 1.0)
	sun.shadow_enabled = true
	add_child(sun)
	var g := MeshInstance3D.new(); var pm := PlaneMesh.new(); pm.size = Vector2(3000, 3000); g.mesh = pm
	var gm := ShaderMaterial.new(); gm.shader = load("res://shaders/3d/terrain.gdshader")
	gm.set_shader_parameter("c0", Color("2a1210")); gm.set_shader_parameter("c1", Color("4a2019")); gm.set_shader_parameter("c2", Color("6a2a18")); gm.set_shader_parameter("acc", Color("ff9a3c"))
	g.material_override = gm
	add_child(g)
	var cam := Camera3D.new()
	cam.fov = 34
	add_child(cam)
	for x in [40.0, 220.0]:
		var l := OmniLight3D.new(); l.omni_range = 260; l.omni_attenuation = 0.5; l.light_energy = 14; l.light_color = Color(1, 0.8, 0.6)
		l.position = Vector3(x, 70, 90); add_child(l)
	match mode:
		"heroes":
			cam.position = Vector3(108, 105, 245); cam.look_at(Vector3(108, 30, 0))
			var ids := ["warden", "spark", "ember", "storm"]
			for i in 4:
				var h := HeroRig.new(); add_child(h)
				h.build(ids[i], Content.col(Content.HEROES[i].col)); h.scale = Vector3.ONE * 1.3
				rigs.append([h, Vector2(i * 72.0, 0)])
		"foes":
			cam.position = Vector3(110, 80, 150); cam.look_at(Vector3(110, 12, -10))
			var fm := ShaderMaterial.new(); fm.shader = load("res://shaders/3d/foe.gdshader")
			fm.set_shader_parameter("glow_col", Color("ff9a3c")); fm.set_shader_parameter("eye_col", Color(1, 0.6, 0.2))
			var kinds := ["grunt", "runner", "brute", "spitter", "splitter", "mini", "charger", "breach", "goblin"]
			var base := Color("4a2019").lerp(Color(0.55, 0.5, 0.48), 0.5)
			for k in kinds.size():
				var mmi := MultiMeshInstance3D.new(); var mm := MultiMesh.new()
				mm.transform_format = MultiMesh.TRANSFORM_3D; mm.use_colors = true; mm.use_custom_data = true
				mm.mesh = Models.foe_mesh(kinds[k]); mm.instance_count = 2
				var row := k / 5
				var px := (k % 5) * 55.0 - 0.0
				var pz := -row * 60.0
				var s := 14.0 if kinds[k] != "brute" else 12.0
				mm.set_instance_transform(0, Transform3D(Basis(Vector3.UP, -0.9).scaled(Vector3(s, s, s)), Vector3(px, 0, pz)))
				mm.set_instance_color(0, base)
				mm.set_instance_custom_data(0, Color(t, 0, 0, 1.0 if k == 2 else 0.0))
				# second instance: the same foe as a crumbling corpse
				mm.set_instance_transform(1, Transform3D(Basis(Vector3(1, 0, 0), PI / 2).rotated(Vector3.UP, -0.5).scaled(Vector3(s, s, s)), Vector3(px + 22, s * 0.42, pz + 26)))
				mm.set_instance_color(1, base)
				mm.set_instance_custom_data(1, Color(0, 0.25 + 0.1 * k, 7, 256.0 * k))
				mmi.multimesh = mm; mmi.material_override = fm
				add_child(mmi)
				foe_mm.append(mmi)
			var ex := HeroRig.new(); add_child(ex); ex.build("ember", Color("4a2a2a")); ex.scale = Vector3.ONE * 1.35
			rigs.append([ex, Vector2(250, 0)])
		_:
			cam.position = Vector3(110, 150, 260); cam.look_at(Vector3(110, 60, 0))
			var b := BossRig.new(); add_child(b); b.build("tyrant", Color("ff6a2a"), "tyrant"); b.position = Vector3(40, 0, 0)
			var hr := BossRig.new(); add_child(hr); hr.build("herald", Color("c48aff"), "herald"); hr.position = Vector3(200, 0, 0)
			rigs.append([b, Vector2(40, 0)]); rigs.append([hr, Vector2(200, 0)])

func _process(dt: float) -> void:
	t += dt
	for i in rigs.size():
		var r = rigs[i][0]
		if r is HeroRig:
			r.animate({"pos": rigs[i][1], "face": Vector2(0.35, 1).normalized(), "mv": 1.0 if i % 2 == 0 else 0.0, "ph": t * 10.0,
				"cast_age": 9.0 if i < 2 else fmod(t, 0.6), "cast_dir": Vector2(0.35, 1).normalized(), "roll": -1.0, "hit": 0.0, "dead": false, "t": t}, dt)
		else:
			r.animate({"pos": rigs[i][1], "face": Vector2(0.3, 1).normalized(), "hp_frac": 1.0, "flash": 0.0, "t": t, "dt": dt, "attack": fmod(t, 2.0) < dt, "phase": 1})
	if t > 1.6:
		set_process(false)
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(out)
		get_tree().quit()
