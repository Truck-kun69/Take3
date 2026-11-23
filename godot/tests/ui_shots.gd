extends Node
## UI tour: every menu screen without a long bot run, for theme critiques. Works at any window size:
##   xvfb-run -a godot --path godot --rendering-method mobile --resolution 720x1280 res://tests/ui_shots.tscn -- <outdir> [prefix]
## A phone with a camera cutout (the S22, 2340x1080): SHOT_SAFE=left,top,right,bottom insets in pixels, e.g.
##   SHOT_SAFE=96,0,0,0 ... --resolution 2340x1080 (landscape, the cutout on the left; portrait: 0,96,0,0)
var main: Node
var out := "user://ui_shots"
var pre := ""
var t := 0.0
var step := -2                     # -2, -1: the first-launch intro, then picking an exile (their intro line subtitled)

func _ready() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: out = a[0]
	if a.size() > 1: pre = a[1]
	if a.size() > 2: UIKit.touch_mode = int(a[2])          # 0 = desktop layout, 1 = touch layout
	if OS.get_environment("SHOT_SAFE") != "":                # e.g. "60,0,40,24": a phone's cutout and corner insets
		var m := OS.get_environment("SHOT_SAFE").split(",")
		UIKit.safe_override = Vector4(float(m[0]), float(m[1]), float(m[2]), float(m[3]))
	DirAccess.make_dir_recursive_absolute(out)
	var sv := get_node("/root/Save")
	sv.path = "user://ui_shot_profile.json"
	sv.data = sv.defaults()
	sv.data.options.sound = false
	sv.data.cleared = [true, true, false, false, false]
	sv.data.gold = 1840; sv.data.gr_key = 7; sv.data.gr_best = 6
	sv.data.currency.chaos = 3; sv.data.currency.exalt = 1; sv.data.currency.regal = 2
	sv.data.fragments = {"rupture": 1, "greed": 1, "dread": 1}
	sv.data.hero = 2
	sv.data.echoes = 7; sv.data.torment_max = 2; sv.data.torment = 1
	sv.data.passives = ["start", "m1", "m3", "m5", "a1", "a2", "a4", "f1", "o1", "o3"]
	if a.size() > 3: sv.data.hero = int(a[3])        # HERO_OVERRIDE: which exile the title stage shows
	var rng := RandomNumberGenerator.new(); rng.seed = 5
	for k in 8: sv.data.stash.append(Items.make(Content.SLOTS[k % 4], k % 4, 20, rng))
	main = load("res://scenes/main.tscn").instantiate()
	main.bot_drive = true
	add_child(main)

func _snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out.path_join(pre + name + ".png"))
	print("shot ", pre + name)

func _process(dt: float) -> void:
	t += dt
	if t < 0.8: return
	t = 0.0
	match step:
		-2: main.show_intro()
		-1: await _snap("u0_intro"); main.intro.skip(); main._on_act("hero", int(Save.data.hero))
		0: await _snap("u1_menu"); main._on_act("heroes", null)
		1: await _snap("u1b_heroes"); main.screens.show_codex("menu")
		2: await _snap("u2_codex"); main.screens.show_options("menu")
		3: await _snap("u3_options"); main.screens._opt_tab = 2; main.screens.show_options("menu")
		4: await _snap("u3b_options_game"); main.screens._opt_tab = 3; main.screens.show_options("menu")
		5:
			await _snap("u3c_options_diag")
			DisplayServer.clipboard_set(Save.export_text())     # what Copy save leaves on the clipboard
			main.screens.show_paste_save("menu")
		6:
			await _snap("u3d_paste_save"); main.screens._opt_tab = 0
			main.screens.show_crash(PackedStringArray(["[12.4] run: act 1, 212 foes, 3D High", "[12.9] boss: The Tyrant spawned", "ERROR: vk::Queue::submit failed (device lost)"]))
		7: await _snap("u3e_crash"); main.screens._sel_item = 2; main.screens.show_stash(false)
		8:
			await _snap("u4_stash")
			main.start({"mode": "campaign", "stage": 0})
			main.world.stats.set_source("shot", [["max_hp", "add", 400.0]])
		9:
			for k in 90: main.world.step(0.033)
			main.world.pending = 1; main._on_level()
		10: await _snap("u5_levelup"); main.screens.close(); main.state = "play"; main.world.pending = 0
		11:
			for k in 60: main.world.step(0.033)
			main.world.light = 0.12               # show the lantern below the Engulfed line
			await _snap("u6_hud")
			main._pause()
		12: await _snap("u7_pause"); main._on_act("build", null)
		13: await _snap("u7c_build"); main.screens.show_pause(main.world); main.screens.confirm("Leave this run?", "You keep the gold and Echoes it has earned so far. The run itself ends here.", "Leave", "leave")
		14:
			await _snap("u7d_confirm"); main._resume()
			main.world.whisper_offer = ["blood_price", "long_night"]; main.state = "whisper"; main.screens.show_whisper(main.world)
		15:
			await _snap("u7b_whisper"); main._on_act("bargain", "ember_pact"); main.world.end_run(false)
		16: pass
		17: await _snap("u8_end"); main._menu(); main.screens._sel_passive = "a6"; main.screens.show_web()
		18: await _snap("u9_web"); get_tree().quit()
	step += 1
