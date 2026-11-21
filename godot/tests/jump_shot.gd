extends Node
## A jump in stills: take-off, apex, just before landing, landing squash. The run is held (state "held")
## and the world stepped by hand, so each still shows an exact moment of the jump.
##   xvfb-run -a godot --path godot --rendering-method mobile --resolution 900x700 res://tests/jump_shot.tscn -- <out prefix> [hero]
var main: Node
var out := "user://jump"
var hero := 0
var t := 0.0
var phase := 0
const MOMENTS := [["takeoff", 3], ["apex", 16], ["descent", 29], ["land", 35]]   # ticks after the press

func _ready() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: out = a[0]
	if a.size() > 1: hero = int(a[1])
	var sv := get_node("/root/Save")
	sv.path = "user://jump_profile.json"
	sv.data = sv.defaults()
	sv.data.options.sound = false
	sv.data.options.gfx = 3
	sv.data.hero = hero
	main = load("res://scenes/main.tscn").instantiate()
	main.bot_drive = true
	add_child(main)

func _process(dt: float) -> void:
	t += dt
	if phase == 0 and t > 0.6:
		main.start({"mode": "campaign", "stage": 0, "seed": 9})
		var w: World = main.world
		w.stats.set_source("shot", [["max_hp", "add", 1e6]])
		w.weapons.clear()
		main.state = "held"
		for k in 20: w.step(FixedStep.STEP)
		phase = 1
		_run()

func _run() -> void:
	var w: World = main.world
	var v: WorldView3D = main.view3d
	v.alpha = 1.0
	w.in_jump = true
	w.in_move = Vector2(1, 0.25).normalized()
	var done := 0
	for m in MOMENTS:
		while done < int(m[1]):
			w.step(FixedStep.STEP)
			done += 1
		for f in 3: await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("%s_%s.png" % [out, m[0]])
		print("shot %s jp=%.2f y=%.1f" % [m[0], v._hero_jp, v.hero_y - v.ground_y(v.hero_p)])
	get_tree().quit()
