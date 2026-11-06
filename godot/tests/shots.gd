extends Node
## Screenshot tour (needs a real renderer: run under xvfb with Vulkan/lavapipe or a GPU).
##   xvfb-run -a godot --path godot --rendering-method mobile res://tests/shots.tscn -- <outdir>
## Plays a bot-driven run and captures the menu, combat, level-up, an event, the atlas and gear.
var main: Node
var out := "user://shots"
var bot: Bot
var t := 0.0
var step := 0
var shots := []

func _ready() -> void:
	var a := OS.get_cmdline_user_args()
	if not a.is_empty(): out = a[0]
	DirAccess.make_dir_recursive_absolute(out)
	var sv := get_node("/root/Save")
	sv.path = "user://shot_profile.json"
	sv.data = sv.defaults()
	sv.data.options.sound = false
	sv.data.cleared = [true, true, false, false]
	sv.data.currency.chaos = 3; sv.data.currency.exalt = 1; sv.data.currency.regal = 2
	sv.data.fragments = {"rupture": 1, "greed": 1, "dread": 0}
	var rng := RandomNumberGenerator.new(); rng.seed = 5
	for k in 6: sv.data.stash.append(Items.make(Content.SLOTS[k % 4], k % 4, 20, rng))
	main = load("res://scenes/main.tscn").instantiate()
	main.bot_drive = true
	add_child(main)

func _snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(out.path_join(name + ".png"))
	print("shot ", name)

func _process(dt: float) -> void:
	t += dt
	match step:
		0:
			if t > 1.0:
				step = 1; await _snap("01_menu")
				main.start({"mode": "campaign", "stage": 1})
				bot = Bot.new(main.world, 3)
				main.world.stats.set_source("shot", [["max_hp", "add", 400.0], ["regen", "add", 20.0]])
				t = 0.0
		1:
			_drive()
			if main.world.t > 2.0 and main.world.director.active.is_empty() and step == 1:
				main.world.director.start("breach")
				main.world.director.objects.append({"pos": main.world.pp + Vector2(160, -60), "kind": "pylon", "id": "power", "life": 60.0})
			if main.world.t > 24.0:
				step = 2; await _snap("02_combat_breach")
		2:
			_drive()
			if main.world.t > 30.0 and main.state == "play":
				main.world.pending = 1
				main._on_level()
				step = 3; t = 0.0
		3:
			if t > 0.5:
				step = 4; await _snap("03_levelup")
				main.screens.close(); main.state = "play"; main.world.pending = 0
				main.world.director.start("eclipse")
				t = 0.0
		4:
			_drive()
			if t > 6.0:
				step = 5; await _snap("04_eclipse")
				main._pause(); t = 0.0
		5:
			if t > 0.4:
				main.screens._sel_item = 1
				main.screens.show_stash(true); step = 6; t = 0.0
		6:
			if t > 0.5:
				step = 7; await _snap("05_gear_crafting")
				main._menu(); main.screens._sel_node = main.get_atlas().start; main.screens.show_atlas(); t = 0.0
		7:
			if t > 0.6:
				step = 8; await _snap("06_atlas")
				main.start({"mode": "pinnacle"})
				bot = Bot.new(main.world, 4)
				main.world.stats.set_source("shot", [["max_hp", "add", 600.0], ["regen", "add", 30.0], ["damage", "more", 0.3]])
				main.world.bosses.herald_at = 3.0
				t = 0.0
		8:
			_drive()
			if main.world.t > 16.0:
				step = 9; await _snap("07_herald")
				print("view upload cost: %.2f ms, fps %d" % [main.view.cost_us / 1000.0, Engine.get_frames_per_second()])
				get_tree().quit()

func _drive() -> void:
	if main.world == null: return
	if main.state == "levelup":
		main._on_act("pick", Bot.pick(main.world.make_choices(), main.world))
	if main.state != "play": return
	bot.w = main.world
	bot.think()
