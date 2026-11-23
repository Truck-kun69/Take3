extends Node
## Game flow: menu -> run -> level-up / pause / merchant overlays -> results. Owns the World, its
## view, the HUD, touch controls and every screen. Also owns the GPU crowd solver, created once
## (a RenderingDevice is expensive) and reused across runs.

var world: World
var view: WorldView                # classic 2D renderer (option "renderer" = 1, and low-end fallback)
var view3d: WorldView3D            # default: PoE2-style 3D renderer
var menu_stage: MenuStage3D        # character-select backdrop behind the main menu
var overlay: Overlay3D
var hud: Hud
var touch: TouchControls
var screens: Screens
var ui: Control
var state := "menu"
var last_cfg := {}
var crowd: CrowdCompute
var subtitles: Subtitles          # voice lines' subtitle banner, on its own layer over everything
var voice_dir: VoiceDirector       # which voice line a run says when (VoiceBank decides what is heard)
var intro: IntroScreen             # the narrated cold open, while it is up
var bot_drive := false          # tests/screenshots: input comes from a Bot instead of devices

func _ready() -> void:
	_input_map()
	# the run renderers (3D, or classic 2D) are created on demand in _bind_view: only the one in use exists
	menu_stage = MenuStage3D.new()
	add_child(menu_stage)
	var layer := CanvasLayer.new()
	add_child(layer)
	ui = Control.new()
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.theme = UIKit.theme()
	layer.add_child(ui)
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay = Overlay3D.new()
	ui.add_child(overlay)
	touch = TouchControls.new()
	ui.add_child(touch)
	hud = Hud.new()
	ui.add_child(hud)
	screens = Screens.new()
	screens.main = self
	ui.add_child(screens)
	screens.act.connect(_on_act)
	var sub_layer := CanvasLayer.new()
	sub_layer.layer = 20
	add_child(sub_layer)
	subtitles = Subtitles.new()
	sub_layer.add_child(subtitles)
	voice_dir = VoiceDirector.new()
	add_child(voice_dir)
	hud.pause_pressed.connect(_pause)
	touch.roll.connect(func(): if world: world.in_roll = true)
	touch.jump.connect(func(): if world: world.in_jump = true)
	touch.ult.connect(func(): if world: world.in_ult = true)
	touch.flask.connect(func(i: int): if world: world.in_flask[i] = true)
	_crowd_setup()
	get_tree().root.size_changed.connect(_on_resize)
	# level of detail switches a little earlier than the 1 px default: the camera is high above the
	# battlefield, so the coarser meshes are indistinguishable (optimisation pass: -4% triangles)
	Quality.load_saved()
	# OpenGL Safe Mode: a Vulkan session that crashed left the sentinel armed, so this launch already runs on
	# Compatibility; make that the saved choice. Then arm it for this session (phones on Vulkan only).
	if Quality.check_sentinel(): Diag.mark("safe mode: the last Vulkan session crashed, now on OpenGL (Compatibility)")
	if Quality.arm_sentinel(): Diag.mark("safe-mode sentinel armed (Vulkan session)")
	_render_scale()
	_ui_scale()
	_menu()
	var st: Dictionary = Save.data.get("selftest", {})
	if st.get("running", false):
		if Diag.crashed_last:                     # the pass that was running took the app down
			var f: String = _st_feature(int(st.pass))
			st.bad.append(f)
			st.results.append({"f": f, "crash": true})
			Diag.mark("selftest: pass %d (%s) crashed" % [st.pass, f])
		Save.mark_dirty(); Save.flush()
		screens.show_selftest_resume(st, Diag.crashed_last)
	elif Diag.crashed_last:
		screens.show_crash(Diag.report)
	elif not bool(Save.data.get("intro_seen", false)) and not bot_drive:
		show_intro()

## The narrated cold open (IntroScreen) over the title menu: on first launch, and from Options > Replay intro.
func show_intro() -> void:
	if intro != null: return
	intro = IntroScreen.new()
	intro.finished.connect(_on_intro_done)
	ui.add_child(intro)

func _on_intro_done() -> void:
	if intro != null: intro.queue_free()
	intro = null

## GPU crowd separation (a compute shader on a local RenderingDevice). Option "gpu_crowd":
## 0 Auto = off on phones (first S21 test crashed seconds into a run; CPU separation is cheap), on
## elsewhere; 1 On; 2 Off.
func _crowd_setup() -> void:
	var o := int(Save.opt("gpu_crowd"))
	var want := o == 1 or (o == 0 and not OS.has_feature("mobile"))
	if want and crowd == null:
		Diag.mark("crowd init")
		crowd = CrowdCompute.new()
		if not crowd.init():
			Diag.mark("crowd unavailable: " + crowd.last_error)
			crowd = null
		else:
			Diag.mark("crowd: GPU separation active")
	elif not want and crowd != null:
		crowd.release()
		crowd = null
		Diag.mark("crowd off (CPU separation)")

## Portrait phones: the 1280x720 design base shrinks the UI to ~0.56x; scale the 2D canvas back up.
## (content_scale_factor only affects 2D, the 3D camera handles portrait framing itself.)
func _ui_scale() -> void:
	var vs := DisplayServer.window_get_size()
	var f := 1.0
	if vs.y > vs.x: f = clampf(float(vs.y) / float(vs.x), 1.0, 1.9)
	get_window().content_scale_factor = f * float(Save.opt("ui_scale"))

## 3D render resolution. Phones are fill-rate bound: rendering the 3D at 75%
## (FSR 1 upscale where the renderer has it, bilinear on Compatibility) and drawing the UI at full
## resolution keeps text sharp. Option "render_scale": 0 auto, 1 = 100%, 2 = 75%, 3 = 50%.
func _render_scale() -> void:
	var opt := int(Save.opt("render_scale"))
	var s := 1.0
	match opt:
		0: s = auto_render_scale(Quality.tier(), OS.has_feature("mobile"))
		2: s = 0.75
		3: s = 0.5
	var vp := get_viewport()
	_base_scale = s
	# the dynamic factor (_dyn_res) runs on Low and Medium only: High holds native resolution
	_dyn_auto = opt == 0 and Quality.tier() < 2 and not RenderingServer.get_video_adapter_name().to_lower().contains("llvmpipe")
	if not _dyn_auto: _dyn = 1.0
	var compat := RenderingServer.get_current_rendering_method() == "gl_compatibility"
	# FSR 1 exists only in Forward+ (the Mobile renderer warned and ignored it on the S22)
	var fsr := RenderingServer.get_current_rendering_method() == "forward_plus" and s < 1.0
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if fsr else Viewport.SCALING_3D_MODE_BILINEAR
	# frame cap: phones with 90/120 Hz screens would otherwise render (and heat) at the panel rate
	# for no visible gain in a top-down game. Option "frame_cap": 0 Auto (60 on phones), 1 30, 2 60, 3 none.
	var cap := [60 if OS.has_feature("mobile") else 0, 30, 60, 0][clampi(int(Save.opt("frame_cap")), 0, 3)] as int
	Engine.max_fps = cap
	# the graphics tier (Quality): LOD bias, anti-aliasing and the sun's shadow atlas
	var hi := Quality.high()
	var mobile := OS.has_feature("mobile")
	vp.mesh_lod_threshold = 1.0 if hi else 1.5
	# one anti-aliasing method at a time, never MSAA and FXAA together: High MSAA 2x (phones too: at native
	# resolution it keeps edges sharp where FXAA would blur the 2048 px textures), Medium FXAA (it smooths
	# the swarm's sub-pixel triangles: a ~40 px foe has ~700), Low neither
	var aa := Quality.on("msaa") and not compat
	if mobile:
		# High: MSAA 2x and no FXAA (sharp edges, no full-screen blur); Medium: FXAA; Low: neither
		vp.msaa_3d = Viewport.MSAA_2X if (aa and Quality.tier() >= 2) else Viewport.MSAA_DISABLED
		_fxaa = aa and Quality.tier() == 1
	else:
		vp.msaa_3d = Viewport.MSAA_2X if (aa and Quality.tier() >= 2) else Viewport.MSAA_DISABLED
		_fxaa = aa and Quality.tier() == 1
	_apply_scale()
	if not compat:
		# the sun's single cascade covers what the high camera sees: 2048 on High phones, 1024 on Medium
		var atlas := (2048 if Quality.tier() >= 2 else 1024) if mobile else (4096 if hi else 2048)
		RenderingServer.directional_shadow_atlas_set_size(atlas, true)
		# the sun's shadow edge: soft medium on High, soft low on Medium; Low draws no sun shadow at all
		var sq: RenderingServer.ShadowQuality = [RenderingServer.SHADOW_QUALITY_HARD, RenderingServer.SHADOW_QUALITY_SOFT_LOW, RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM][Quality.tier()]
		RenderingServer.directional_soft_shadow_filter_set_quality(sq)

func _on_resize() -> void:
	_ui_scale()
	if state == "menu": screens.show_menu()

func _input_map() -> void:
	var keys := {
		"move_left": [KEY_A, KEY_LEFT], "move_right": [KEY_D, KEY_RIGHT], "move_up": [KEY_W, KEY_UP], "move_down": [KEY_S, KEY_DOWN],
		"roll": [KEY_SPACE, KEY_SHIFT], "jump": [KEY_F], "ult": [KEY_R, KEY_Q], "flask1": [KEY_1], "flask2": [KEY_2], "pause": [KEY_ESCAPE, KEY_P], "gear": [KEY_TAB, KEY_I],
	}
	var pads := {"roll": JOY_BUTTON_A, "jump": JOY_BUTTON_X, "ult": JOY_BUTTON_Y, "flask1": JOY_BUTTON_LEFT_SHOULDER, "flask2": JOY_BUTTON_RIGHT_SHOULDER, "pause": JOY_BUTTON_START, "gear": JOY_BUTTON_BACK}
	var axes := {"move_left": [JOY_AXIS_LEFT_X, -1.0], "move_right": [JOY_AXIS_LEFT_X, 1.0], "move_up": [JOY_AXIS_LEFT_Y, -1.0], "move_down": [JOY_AXIS_LEFT_Y, 1.0]}
	for a in keys:
		if not InputMap.has_action(a):
			InputMap.add_action(a, 0.2)
		for k in keys[a]:
			var e := InputEventKey.new()
			e.physical_keycode = k
			InputMap.action_add_event(a, e)
		if pads.has(a):
			var j := InputEventJoypadButton.new()
			j.button_index = pads[a]
			InputMap.action_add_event(a, j)
		if axes.has(a):
			var m := InputEventJoypadMotion.new()
			m.axis = axes[a][0]
			m.axis_value = axes[a][1]
			InputMap.action_add_event(a, m)

# ================================================================= flow
func _menu() -> void:
	state = "menu"
	Sfx.stop_ambience()
	VoiceBank.stop_all(0.15)
	if voice_dir != null: voice_dir.unbind()
	if subtitles != null: subtitles.in_run = false
	_free_world()
	hud.visible = false
	touch.visible = false
	menu_stage.show_stage(int(Save.data.hero))
	screens.show_menu()

func _free_world() -> void:
	if voice_dir != null: voice_dir.unbind()
	if world != null:
		world.dispose()
	world = null
	if view != null: view.w = null
	if view3d != null: view3d.w = null
	hud.w = null
	touch.world = null

func start(cfg: Dictionary) -> void:
	_free_world()
	VoiceBank.stop_all(0.1)
	menu_stage.hide_stage()
	last_cfg = cfg.duplicate()
	cfg["hero"] = int(cfg.get("hero", Save.data.hero)) if cfg.get("daily", false) else int(Save.data.hero)
	Diag.mark("start %s gfx=%s scale=%.2f crowd=%s" % [str(cfg), Quality.NAMES[Quality.tier()], get_viewport().scaling_3d_scale, "gpu" if crowd != null else "cpu"])
	if not cfg.has("moon"):
		cfg["moon"] = Moon.now()
		cfg["sky_date"] = Moon.today()
	world = World.new()
	world.crowd = crowd
	world.setup(cfg)
	Diag.mark("world ready")
	world.level_up.connect(_on_level)
	world.ended.connect(_on_end)
	world.merchant_open.connect(func(): if state == "play": state = "merchant"; screens.show_merchant(world))
	world.whisper_open.connect(func(): if state == "play": state = "whisper"; Sfx.play("event"); screens.show_whisper(world))
	_bind_view()
	Diag.mark("view bound")
	hud.bind(world)
	touch.world = world
	hud.visible = true
	touch.visible = true
	screens.close()
	state = "play"
	Sfx.start_ambience(world.stage)
	subtitles.in_run = true
	voice_dir.bind(world)

func use_3d() -> bool:
	return int(Save.opt("renderer")) == 0

## Creates the renderer the options ask for and frees the other one (it held a full swarm's
## MultiMesh, materials and lights for nothing). Renderers sit first among main's children so they
## process before the HUD and overlay, which project through their camera.
func _bind_view() -> void:
	if use_3d():
		if view != null:
			view.queue_free()
			view = null
		if view3d == null:
			view3d = WorldView3D.new()
			add_child(view3d)
			move_child(view3d, 0)
		overlay.view = view3d
		view3d.bind(world)
		view3d.cam.make_current()
		hud.project = func(p: Vector2) -> Vector2: return view3d.to_screen(p)
	else:
		if view3d != null:
			view3d.queue_free()
			view3d = null
		overlay.view = null
		if view == null:
			view = WorldView.new()
			add_child(view)
			move_child(view, 0)
		view.bind(world)
		view.cam.make_current()
		hud.project = func(p: Vector2) -> Vector2: return get_viewport().get_canvas_transform() * p
	_clock.reset()

## The simulation clock: see FixedStep. Input is read in _process before stepping (Godot runs
## _physics_process before _process, so stepping there would act on last frame's input).
## After the ticks, the 3D view gets the fraction of a tick left over (alpha): it draws moving things
## between the previous tick and this one (World._snapshot), so motion is smooth at any frame rate.
var _clock := FixedStep.new()
func _sim(dt: float) -> void:
	var n := _clock.advance(dt)
	for k in n:
		if world == null or world.over: break
		world.step(FixedStep.STEP)
	if view3d != null: view3d.alpha = _clock.alpha()

func _on_level() -> void:
	if state != "play": return
	state = "levelup"
	Sfx.play("level")
	screens.show_levelup(world)

func _on_end(win: bool) -> void:
	if win and world.mode == "atlas":
		var a := get_atlas()
		Atlas.complete(a, int(world.node.id))
		Save.data.atlas = {"seed": a.seed, "prog": Atlas.progress(a)}
		Save.mark_dirty()
	state = "end"
	await get_tree().create_timer(0.8).timeout
	if world != null:
		screens.show_end(world)

func _pause() -> void:
	if state != "play": return
	state = "pause"
	Sfx.fire_stop()
	screens.show_pause(world)

func _resume() -> void:
	if world == null: return
	state = "play"
	screens.close()

## World-side first-occurrence breadcrumbs (see Diag.first).
func _firsts() -> void:
	if world == null: return
	if world.kills > 0: Diag.first("kill")
	if not world.projs.is_empty(): Diag.first("projectile")
	if not world.eshots.is_empty(): Diag.first("enemy projectile")
	if not world.teles.is_empty(): Diag.first("telegraph")
	if world.gem_n > 0: Diag.first("xp gem")
	for e in world.fx: Diag.first("fx " + String(e.k))
	for p in world.picks: Diag.first("pickup " + String(p.k))
	for ev in world.director.active: Diag.first("event " + String(ev.id))
	for o in world.director.objects: Diag.first("object " + String(o.kind))
	if not world.breakables.is_empty(): Diag.first("breakables")
	if world.hp < world.max_hp: Diag.first("hero hit")
	if world.lvl > 1: Diag.first("level 2")

# ================================================================= benchmark
## Options > Benchmark: a fixed, invulnerable 23 s rift (3 s warm-up, 20 s measured) with the swarm
## held at ~400 foes and every effect weapon evolved, walking a circle so terrain and props stream.
## The result screen is meant to be screenshotted and sent back to tune the tiers on a real phone.
const BENCH_WARM := 3.0
const BENCH_LEN := 20.0
var _bench_t := 0.0
var _bench_ms: PackedFloat32Array = PackedFloat32Array()
var _bench_acc := {}

func start_bench() -> void:
	start({"mode": "rift", "gr": 3, "seed": 7, "moon": -1.0})
	voice_dir.unbind()                     # the benchmark runs silent of voices
	state = "bench"
	_bench_t = 0.0
	_bench_ms = PackedFloat32Array()
	_bench_acc = {"draws": 0.0, "tris": 0.0, "foes": 0.0, "n": 0}
	world.stats.set_source("bench", [["invuln", "add", 1.0], ["max_hp", "add", 1e6]])
	Diag.mark("bench start")
	for id in ["bolt", "nova", "orbit"]:
		world.weapons[id] = {"lv": 5, "evo": true, "t": 0.0, "gems": []}
		world.wlocal[id] = Stats.new()
	hud.visible = true
	touch.visible = false

func _bench_step_world(dt: float) -> void:
	_bench_t += dt
	var a := world.t * 0.35
	world.in_move = Vector2(-sin(a), cos(a))                 # a slow circle of radius ~ speed / 0.35
	var target := mini(400, int(400.0 * _bench_t / 2.0))      # ramp in over 2 s: first-use shader work spreads out
	while world.sw.n < target and not world.sw.full():
		world.spawn_foe([Content.E.GRUNT, Content.E.RUNNER, Content.E.BRUTE, Content.E.SPITTER][world.sw.n % 4], world.ring_point(), 0, 0, 30.0)
	world.progress = 0.0
	world.pending = 0
	world.whisper_offer = []
	world.light = 0.6
	_sim(dt)

func _bench_step(dt: float) -> void:
	_bench_step_world(dt)
	if _bench_t > BENCH_WARM:
		_bench_ms.append(dt * 1000.0)
		_bench_acc.draws += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		_bench_acc.tris += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		_bench_acc.foes += world.sw.n
		_bench_acc.n += 1
	if _bench_t >= BENCH_WARM + BENCH_LEN:
		var ms := _bench_ms.duplicate()
		ms.sort()
		var tot := 0.0
		for m in ms: tot += m
		var n := maxi(1, ms.size())
		var res := {"fps": 1000.0 * n / maxf(1.0, tot), "ms": tot / n, "low1": 1000.0 / maxf(0.1, ms[mini(ms.size() - 1, int(ms.size() * 0.99))]) if ms.size() > 0 else 0.0,
			"draws": int(_bench_acc.draws / maxf(1, _bench_acc.n)), "ktris": int(_bench_acc.tris / maxf(1, _bench_acc.n) / 1000.0),
			"foes": int(_bench_acc.foes / maxf(1, _bench_acc.n)), "tier": Quality.NAMES[Quality.tier()], "scale": int(get_viewport().scaling_3d_scale * 100.0),
			"gpu": RenderingServer.get_video_adapter_name(), "renderer": RenderingServer.get_current_rendering_method(),
			"res": "%dx%d" % [get_viewport().size.x, get_viewport().size.y], "device": OS.get_model_name()}
		Save.data["bench"] = res
		Save.mark_dirty()
		Save.flush()
		print("BENCH ", res)
		Diag.mark("bench done %s" % str(res))
		_menu()
		screens.show_bench(res)

# ================================================================= graphics self-test
## Bisects device crashes: pass 0 runs the benchmark scene with every Quality feature off, then each
## pass switches one more on for 7 s and records the FPS. Progress is flushed before each pass, so
## when a driver crash kills the app the next launch knows which feature did it: that one stays
## off ("gfx_off") and the test resumes. Features found crashing remain off for normal play.
const ST_PASS := 7.0
var _st: Dictionary = {}
var _st_t := 0.0
var _st_frames := 0
var _st_time := 0.0

func _st_feature(p: int) -> String:
	return "base" if p == 0 else String(Quality.FEATURES[p - 1])

func start_selftest(resume: bool) -> void:
	if not resume or Save.data.selftest.is_empty():
		Save.data["selftest"] = {"running": true, "pass": 0, "bad": [], "results": []}
	_st = Save.data["selftest"]
	_st.running = true
	if resume: _st.pass = int(_st.pass) + 1
	Save.data.options.gfx_off = []
	start_bench()
	state = "selftest"
	_st_begin_pass()

func _st_apply() -> void:
	Quality.off = {}
	for i in Quality.FEATURES.size():
		var f: String = Quality.FEATURES[i]
		if i + 1 > int(_st.pass) or _st.bad.has(f): Quality.off[f] = true
	_render_scale()

func _st_begin_pass() -> void:
	while int(_st.pass) <= Quality.FEATURES.size() and _st.bad.has(_st_feature(int(_st.pass))):
		_st.pass = int(_st.pass) + 1
	if int(_st.pass) > Quality.FEATURES.size():
		_st_finish()
		return
	_st_apply()
	_st_t = 0.0
	_st_frames = 0
	_st_time = 0.0
	Save.mark_dirty(); Save.flush()            # on disk before the pass can crash
	Diag.mark("selftest pass %d: +%s" % [_st.pass, _st_feature(int(_st.pass))])

func _st_step(dt: float) -> void:
	_bench_step_world(dt)
	_st_t += dt
	if _st_t > 1.0:                            # 1 s to settle, then measure
		_st_frames += 1
		_st_time += dt
	if _st_t >= ST_PASS:
		var fps := _st_frames / maxf(0.01, _st_time)
		_st.results.append({"f": _st_feature(int(_st.pass)), "fps": snappedf(fps, 0.1),
			"ktris": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1000.0)})
		Diag.mark("selftest pass %d ok fps=%.1f" % [_st.pass, fps])
		_st.pass = int(_st.pass) + 1
		_st_begin_pass()

func _st_finish() -> void:
	_st.running = false
	Save.data.options.gfx_off = _st.bad.filter(func(f): return f != "base")
	Save.mark_dirty(); Save.flush()
	Diag.mark("selftest done bad=%s" % str(_st.bad))
	Quality.load_saved()
	# OpenGL Safe Mode: a Vulkan session that crashed left the sentinel armed, so this launch already runs on
	# Compatibility; make that the saved choice. Then arm it for this session (phones on Vulkan only).
	if Quality.check_sentinel(): Diag.mark("safe mode: the last Vulkan session crashed, now on OpenGL (Compatibility)")
	if Quality.arm_sentinel(): Diag.mark("safe-mode sentinel armed (Vulkan session)")
	_render_scale()
	var res: Dictionary = _st.duplicate(true)
	_menu()
	screens.show_selftest(res)

## Dynamic resolution (render scale on Auto): the frame is pixel-bound on phones, so when a fight drops
## below ~70% of the target rate the 3D resolution steps down (to 55% at most), and creeps back up
## once there is headroom. The UI always stays at full resolution. Not used in the benchmark.
var _base_scale := 1.0
var _dyn := 1.0
var _fxaa := false                  # the tier asks for FXAA (it runs only while the 3D scale is 0.9 or more)
const FXAA_MIN_SCALE := 0.9

## The 3D resolution option "Auto": phones native on Medium and High, 0.75 on Low (the Mobile renderer
## upsamples a scaled image with a plain bilinear filter, no FSR, so every step below native softens the
## whole frame); desktops native.
static func auto_render_scale(tier: int, mobile: bool) -> float:
	if mobile: return [0.75, 1.0, 1.0][clampi(tier, 0, 2)]
	return 1.0

## FXAA only at a 3D scale of 0.9 or more: below that the bilinear upsample already blurs the frame, and
## FXAA on top smears edges and texture detail further.
static func fxaa_allowed(scale: float) -> bool:
	return scale >= FXAA_MIN_SCALE - 0.001

## The dynamic factor after a slow second: down 0.08 (0.15 when the frame took over twice its budget),
## never under DYN_FLOOR.
static func dyn_down(dyn: float, avg: float, target: float) -> float:
	return maxf(DYN_FLOOR, dyn - (0.15 if avg > target * 2.0 else 0.08))

## The 3D resolution (base scale x the dynamic factor) and FXAA with it.
func _apply_scale() -> void:
	var vp := get_viewport()
	var sc := _base_scale * _dyn
	vp.scaling_3d_scale = sc
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if (_fxaa and fxaa_allowed(sc)) else Viewport.SCREEN_SPACE_AA_DISABLED

var _dyn_auto := false
const DYN_FLOOR := 0.85             # the dynamic factor (Low, Medium) never drops the frame below 85% of the tier's scale
var _dyn_acc := 0.0
var _dyn_n := 0
var _dyn_good := 0
func _dyn_res(dt: float) -> void:
	if not _dyn_auto: return
	_dyn_acc += dt; _dyn_n += 1
	if _dyn_acc < 1.2: return
	var avg := _dyn_acc / _dyn_n
	_dyn_acc = 0.0; _dyn_n = 0
	var target := 1.0 / float(Engine.max_fps if Engine.max_fps > 0 else 60)
	var was := _dyn
	if avg > target * 1.4:
		_dyn = dyn_down(_dyn, avg, target)
		_dyn_good = 0
	elif avg < target * 1.12:
		_dyn_good += 1
		if _dyn_good >= 4:
			_dyn = minf(1.0, _dyn + 0.05)
			_dyn_good = 2
	else:
		_dyn_good = 0
	if _dyn != was:
		_apply_scale()
		Diag.mark("dyn res %.2f (avg %.1f ms)" % [_base_scale * _dyn, avg * 1000.0])

func _process(dt: float) -> void:
	if subtitles != null: subtitles.in_run = state == "play"     # modal screens and menus: subtitles along the top
	if world == null:
		return
	if state in ["play", "bench", "selftest"]: _firsts()
	if state == "selftest":
		Diag.beat(world, dt, "selftest")
		_st_step(dt)
		return
	if state == "bench":
		Diag.beat(world, dt, "bench")
		_bench_step(dt)
		return
	if state == "play": Diag.beat(world, dt)
	if state == "play": _dyn_res(dt)
	if state == "play":
		if not bot_drive:
			world.in_move = touch.value if touch.stick_id >= 0 else Input.get_vector("move_left", "move_right", "move_up", "move_down")
		if Input.is_action_just_pressed("roll"): world.in_roll = true
		if Input.is_action_just_pressed("jump"): world.in_jump = true
		if Input.is_action_just_pressed("ult"): world.in_ult = true
		if Input.is_action_just_pressed("flask1"): world.in_flask[0] = true
		if Input.is_action_just_pressed("flask2"): world.in_flask[1] = true
		if Input.is_action_just_pressed("pause"): _pause(); return
		if Input.is_action_just_pressed("gear"): state = "pause"; screens.show_stash(true); return
		_sim(dt)
		if world != null: Sfx.fire_bed(world.contagion.burning if world.contagion != null else 0, dt)
	elif state == "pause" and Input.is_action_just_pressed("pause"):
		_resume()

func _notification(what: int) -> void:
	# the safe-mode sentinel follows Diag's clean-end lifecycle: disarmed in the background and on quit
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		Quality.disarm_sentinel()
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		Quality.arm_sentinel()
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED:
		_pause()
	elif what == NOTIFICATION_WM_GO_BACK_REQUEST:      # Android back button
		if state == "play": _pause()
		elif state == "pause": _resume()
		elif state == "menu": pass
		else: _menu()

# ================================================================= screen actions
func _on_act(what: String, arg) -> void:
	match what:
		"menu": _menu()
		"hero":
			menu_stage.show_stage(int(arg))
			menu_stage.showcase()
			if VoiceBank.current != null: VoiceBank.current.preview_hero(String(Content.HEROES[int(arg)].id))
		"intro": show_intro()
		"campaign": start({"mode": "campaign", "stage": int(arg)})
		"rift": start({"mode": "rift", "gr": int(arg)})
		"atlas":
			var a := get_atlas()
			start({"mode": "atlas", "node": a.nodes[int(arg)]})
		"pinnacle":
			for k in ["rupture", "greed", "dread"]:
				Save.data.fragments[k] = int(Save.data.fragments[k]) - 1
			Save.mark_dirty()
			start({"mode": "pinnacle"})
		"stash": screens.show_stash(false)
		"upgrades": screens.show_upgrades()
		"endgame": screens.show_endgame()
		"codex": screens.show_codex()
		"web": screens.show_web()
		"prophecy": screens.show_prophecies()
		"daily": screens.show_daily()
		"daily_go": start(arg)
		"options": screens.show_options("menu")
		"bench": start_bench()
		"selftest": start_selftest(false)
		"selftest_resume": start_selftest(true)
		"options_changed":
			if world != null:
				world.colorblind = bool(Save.opt("colorblind"))
				world.aim_mode = int(Save.opt("aim"))
				_bind_view()
			_render_scale()
			Sfx.apply_options()
			_crowd_setup()
			if world != null: world.crowd = crowd
		"equip": equip(arg)
		"salvage":
			Save.data.stash.erase(arg)
			var gain := {0: ["transmute", 1], 1: ["augment", 2], 2: ["chaos", 1], 3: ["divine", 2]}[int(arg.rarity)] as Array
			Save.add_currency(gain[0], gain[1])
		"extract":
			if not Save.data.codex.has(arg.leg):
				Save.data.codex.append(arg.leg)
				if Save.data.codex_active.size() < Content.CODEX_SLOTS: Save.data.codex_active.append(arg.leg)
			Save.data.stash.erase(arg)
			Save.mark_dirty()
			Sfx.play("craft")
		"codex_toggle":
			var act: Array = Save.data.codex_active
			if act.has(arg): act.erase(arg)
			elif act.size() < Content.CODEX_SLOTS: act.append(arg)
			Save.mark_dirty()
		"pick":
			world.apply_choice(arg)
			Sfx.play("click")
			if world.pending > 0: screens.show_levelup(world)
			else: _resume()
		"bargain":
			world.accept_bargain(String(arg))
			_resume()
		"resume": _resume()
		"resume_pause":
			if world != null and state == "pause": screens.show_pause(world)
			else: _menu()
		"abandon":
			if world != null: world.end_run(false)
		"retry": start(last_cfg)

func equip(it: Dictionary) -> void:
	var cur: Dictionary = Save.data.equipped[it.slot]
	Save.data.stash.erase(it)
	if not cur.is_empty(): Save.data.stash.append(cur)
	Save.data.equipped[it.slot] = it
	Save.mark_dirty()
	if world != null:
		world.stats.set_source("item:" + it.slot, Items.mods(it))

func craft(it: Dictionary, cur: String) -> String:
	if int(Save.data.currency.get(cur, 0)) <= 0:
		return "You have no " + Content.CURRENCY[cur].name + "."
	var msg := Items.craft(it, cur)
	if msg != "":
		return msg
	Save.data.currency[cur] = int(Save.data.currency[cur]) - 1
	Save.mark_dirty()
	Sfx.play("craft")
	if world != null and Save.data.equipped[it.slot] == it:
		world.stats.set_source("item:" + it.slot, Items.mods(it))
	return Content.CURRENCY[cur].name + " applied."

func get_atlas() -> Dictionary:
	var d: Dictionary = Save.data.atlas
	if not d.has("seed"):
		d = {"seed": randi() % 1000000, "prog": {}}
		Save.data.atlas = d
		Save.mark_dirty()
	return Atlas.with_progress(int(d.seed), d.get("prog", {}))
