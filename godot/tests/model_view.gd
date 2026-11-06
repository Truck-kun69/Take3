extends Node3D
## Model turntable: renders the four hero rigs, a tyrant, the herald and the foe kinds side by side.
##   xvfb-run -a godot --path godot --rendering-method mobile res://tests/model_view.tscn -- <out.png>
var t := 0.0
var rigs: Array = []
func _ready() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.08, 0.09, 0.12)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.4, 0.42, 0.5)
	e.ambient_light_energy = 0.6
	e.tonemap_mode = Environment.TONE_MAPPER_ACES
	e.glow_enabled = true
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-50), deg_to_rad(-35), 0)
	sun.shadow_enabled = true
	add_child(sun)
	var cam := Camera3D.new()
	cam.fov = 40
	add_child(cam)
	cam.position = Vector3(170, 190, 330)
	cam.look_at(Vector3(170, 25, 0))
	var g := MeshInstance3D.new(); var pm := PlaneMesh.new(); pm.size = Vector2(2000, 2000); g.mesh = pm
	var gm := StandardMaterial3D.new(); gm.albedo_color = Color(0.2, 0.2, 0.22); g.material_override = gm
	add_child(g)
	var ids := ["warden", "spark", "ember", "storm"]
	for i in 4:
		var h := HeroRig.new()
		add_child(h)
		h.build(ids[i], Content.col(Content.HEROES[i].col))
		h.scale = Vector3.ONE * 1.3
		h.position = Vector3(i * 70.0, 0, 60)
		rigs.append(h)
	var fm := ShaderMaterial.new(); fm.shader = load("res://shaders/3d/foe.gdshader")
	for k in 10:
		var mi := MeshInstance3D.new()
		mi.mesh = Models.foe_mesh(Models.FOE_KINDS[k])
		mi.material_override = fm
		mi.scale = Vector3.ONE * 13.0
		mi.position = Vector3(-20 + k * 38.0, 0, -40)
		mi.rotation.y = -0.6
		add_child(mi)
	var b := BossRig.new(); add_child(b); b.build("tyrant", Color("ff6a2a"), "tyrant"); b.position = Vector3(330, 0, -150); b.scale = Vector3.ONE * 0.8
	var hr := BossRig.new(); add_child(hr); hr.build("herald", Color("c48aff"), "herald"); hr.position = Vector3(30, 0, -170); hr.scale = Vector3.ONE * 0.6
	rigs.append(b); rigs.append(hr)

func _process(dt: float) -> void:
	t += dt
	for i in 4:
		var h: HeroRig = rigs[i]
		h.animate({"pos": Vector2(i * 70.0, 60), "face": Vector2(0.3, 1).normalized(), "mv": 1.0 if i % 2 == 0 else 0.0, "ph": t * 10.0, "cast_age": 9.0 if i < 2 else fmod(t, 0.6),
			"cast_dir": Vector2(0.3, 1).normalized(), "roll": -1.0, "hit": 0.0, "dead": false, "t": t}, dt)
	rigs[4].animate({"pos": Vector2(330, -150), "face": Vector2(0.4, 1).normalized(), "hp_frac": 1.0, "flash": 0.0, "t": t, "dt": dt, "attack": false, "phase": 1})
	rigs[5].animate({"pos": Vector2(30, -170), "face": Vector2(0, 1), "hp_frac": 1.0, "flash": 0.0, "t": t, "dt": dt, "attack": false, "phase": 1})
	if t > 1.5:
		await RenderingServer.frame_post_draw
		var a := OS.get_cmdline_user_args()
		get_viewport().get_texture().get_image().save_png(a[0] if not a.is_empty() else "user://models.png")
		get_tree().quit()
		set_process(false)
