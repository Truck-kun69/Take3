extends Node
## UI tour: every menu screen without a long bot run, for theme critiques. Works at any window size:
##   xvfb-run -a godot --path godot --rendering-method mobile --resolution 720x1280 res://tests/ui_shots.tscn -- <outdir> [prefix]
var main: Node
var out := "user://ui_shots"
var pre := ""
var t := 0.0
var step := 0

func _ready() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: out = a[0]
	if a.size() > 1: pre = a[1]
	if a.size() > 2: UIKit.touch_mode = int(a[2])          # 0 = desktop layout, 1 = touch layout
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
		0: await _snap("u1_menu"); main.screens.show_codex()
		1: await _snap("u2_codex"); main.screens.show_options("menu")
		2: await _snap("u3_options"); main.screens._sel_item = 2; main.screens.show_stash(false)
		3:
			await _snap("u4_stash")
			main.start({"mode": "campaign", "stage": 0})
			main.world.stats.set_source("shot", [["max_hp", "add", 400.0]])
		4:
			for k in 90: main.world.step(0.033)
			main.world.pending = 1; main._on_level()
		5: await _snap("u5_levelup"); main.screens.close(); main.state = "play"; main.world.pending = 0
		6:
			for k in 60: main.world.step(0.033)
			await _snap("u6_hud")
			main._pause()
		7: await _snap("u7_pause"); main._resume(); main.world.end_run(false)
		8: pass
		9: await _snap("u8_end"); get_tree().quit()
	step += 1
