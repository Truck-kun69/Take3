extends Node
## The title menu and its sub-screens at any window size, for layout checks:
##   xvfb-run -a godot --path godot --rendering-method mobile --resolution 1600x720 res://tests/menu_shot.tscn -- <outdir> [touch 0/1] [fresh 0/1] [hero]
## touch 1 lays out for a touchscreen; fresh 1 is a new profile (nothing cleared), 0 a mid-game one.
var main: Node
var out := "user://menu_shots"
var t := 0.0
var step := 0
var shots: Array = ["menu"]

func _ready() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: out = a[0]
	if a.size() > 1: UIKit.touch_mode = int(a[1])
	var fresh := a.size() > 2 and a[2] == "1"
	DirAccess.make_dir_recursive_absolute(out)
	var sv := get_node("/root/Save")
	sv.path = "user://menu_shot_profile.json"
	sv.data = sv.defaults()
	sv.data.options.sound = false
	if not fresh:
		sv.data.cleared = [true, true, false, false, false]
		sv.data.gold = 1840; sv.data.gr_key = 7; sv.data.gr_best = 6
		sv.data.currency.chaos = 3; sv.data.currency.exalt = 1; sv.data.currency.regal = 2
		sv.data.fragments = {"rupture": 1, "greed": 1, "dread": 1}
		sv.data.echoes = 7; sv.data.torment_max = 2; sv.data.torment = 1
	sv.data.hero = int(a[3]) if a.size() > 3 else 2
	main = load("res://scenes/main.tscn").instantiate()
	main.bot_drive = true
	add_child(main)

func _snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out.path_join(name + ".png"))
	print("shot ", name)

func _find_play(n: Node) -> Button:
	if n is Button and n.has_meta("title_label") and (n.get_meta("title_label") as Label).text == "PLAY": return n
	for c in n.get_children():
		var b := _find_play(c)
		if b != null: return b
	return null

func _process(dt: float) -> void:
	t += dt
	if t < 1.2: return
	t = 0.0
	match step:
		0: await _snap("menu")
		1: main.screens.show_endgame()
		2: await _snap("modes")
		3: main.screens.show_upgrades()
		4: await _snap("upgrades")
		5: main.screens.show_stash(false)
		6: await _snap("gear")
		7:                                     # press PLAY: a campaign run with the chosen exile at the act shown
			main.screens.show_menu()
			var play := _find_play(main.screens)
			print("PLAY button found: ", play != null)
			if play != null: play.pressed.emit()
		8:
			var w: World = main.world
			print("PLAY started: state=%s mode=%s act=%d hero=%d (saved hero %d)" % [main.state, w.mode if w else "-", w.stage if w else -1, w.hero if w else -1, int(Save.data.hero)])
			get_tree().quit()
	step += 1
