extends Node
## A late-run fight frozen in place, for A/B timing of what a frame costs.
##   xvfb-run -a godot --path godot --rendering-method mobile --resolution 1280x720 res://tests/late_bench.tscn -- [gfx 1-3] [out.png]
## Env LATE_OFF=feature,feature turns Quality features off; LATE_FOES / LATE_GEMS / LATE_SURF override the scene.
var main: Node
var t := 0.0
var phase := 0
var frames := 0
var t0 := 0
var sim_acc := 0.0
var view_acc := 0.0
var out := ""
func _env(k: String, d: int) -> int:
	return int(OS.get_environment(k)) if OS.get_environment(k) != "" else d
func _ready() -> void:
	var a := OS.get_cmdline_user_args()
	var sv := get_node("/root/Save")
	sv.path = "user://late_profile.json"
	sv.data = sv.defaults()
	sv.data.options.sound = false
	sv.data.options.show_fps = true
	sv.data.options.gfx = int(a[0]) if a.size() > 0 else 2
	if a.size() > 1: out = a[1]
	if OS.get_environment("LATE_OFF") != "": sv.data.options.gfx_off = Array(OS.get_environment("LATE_OFF").split(","))
	main = load("res://scenes/main.tscn").instantiate()
	main.bot_drive = true
	add_child(main)
func _process(dt: float) -> void:
	t += dt
	if phase == 0 and t > 0.8:
		phase = 1; t = 0.0
		main.start({"mode": "campaign", "stage": 3, "hero": 2})
		var w: World = main.world
		w.stats.set_source("b", [["max_hp", "add", 1e6], ["regen", "add", 1e5]])
		w.hp = 1e6
		w.weapons.clear()
		for id in ["aura", "wisp", "nova", "storm"]:
			w.weapons[id] = {"lv": 5, "evo": true, "t": 0.0, "gems": []}
			w.wlocal[id] = Stats.new()
		w.lvl = 34
		w.t = 350.0
		for k in _env("LATE_SURF", 14):
			w.terrain.pour(w.pp + Vector2(randf_range(-420, 420), randf_range(-260, 260)), randf_range(40, 90), Terrain.Surf.BLOOD if k % 3 != 0 else Terrain.Surf.POISON, 60.0)
		for k in _env("LATE_GEMS", 260):
			w.add_gem(w.pp + Vector2(randf_range(-520, 520), randf_range(-320, 320)), 1.0)
	elif phase == 1:
		var w: World = main.world
		w.in_move = Vector2.ZERO
		for nm in OS.get_environment("LATE_HIDE").split(",", false):
			var v: WorldView3D = main.view3d
			if nm == "foes":
				for m in v._foe_mm: m.visible = false
			elif nm == "notex": v.terrain_mat.set_shader_parameter("has_tex", false)
			elif nm == "flat":
				var sm := StandardMaterial3D.new(); sm.albedo_color = Color(0.2, 0.25, 0.3)
				for c in v.ground.get_children(): c.material_override = sm
			elif v.get(nm) != null: v.get(nm).visible = false
		while w.sw.n < _env("LATE_FOES", 110): w.spawn_foe(Content.E.GRUNT + (w.sw.n % 5), w.pp + Vector2(randf_range(-520, 520), randf_range(-320, 320)), 0, 0, 40.0)
		if t > 3.0 and frames == 0: t0 = Time.get_ticks_usec()
		if t > 3.0:
			frames += 1
			sim_acc += w.step_us; view_acc += Diag.view_us
			if frames == 40:
				phase = 2
				var ms := (Time.get_ticks_usec() - t0) / 1000.0 / 39.0
				print("LATE frame %.1f ms | sim %.1f view %.1f | foes %d projs %d gems %d picks %d fx %d texts %d | draws %d tris %dk" % [ms, sim_acc / 40000.0, view_acc / 40000.0, w.sw.n, w.projs.size(), w.gem_n, w.picks.size(), w.fx.size(), w.texts.size(),
					int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)), int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1000.0)])
				if out != "":
					await RenderingServer.frame_post_draw
					get_viewport().get_texture().get_image().save_png(out)
				get_tree().quit()
