extends Node
## Drives the graphics self-test (Options > Graphics self-test) for screenshots.
##   xvfb-run -a godot --path godot --rendering-method mobile res://tests/selftest_run.tscn -- <outdir> <start|resume> [kill_after_s]
## "start" begins a fresh test (and with kill_after_s, exits abruptly mid-test like a driver crash);
## "resume" relaunches: snaps the resume screen, continues, and snaps the final result.
var main: Node
var out := "user://selftest"
var mode := "start"
var t := 0.0
var stage := 0

func _ready() -> void:
	var a := OS.get_cmdline_user_args()
	out = a[0]
	mode = a[1]
	DirAccess.make_dir_recursive_absolute(out)
	var sv := get_node("/root/Save")
	sv.path = "user://selftest_profile.json"
	if mode == "start":
		sv.data = sv.defaults()
		sv.data.options.sound = false
		sv.flush()
	else:
		sv.load_profile()
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)

func _snap(n: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out.path_join(n + ".png"))
	print("shot ", n)

func _process(dt: float) -> void:
	t += dt
	var a := OS.get_cmdline_user_args()
	if mode == "start":
		if stage == 0 and t > 1.5:
			stage = 1
			main._on_act("selftest", null)
		if a.size() > 2 and t > float(a[2]):
			OS.kill(OS.get_process_id())          # simulate the driver crash
	else:
		if stage == 0 and t > 2.0:
			stage = 1
			await _snap("st_resume")
			main._on_act("selftest_resume", null)
		if stage == 1 and main.state == "menu" and t > 4.0:
			stage = 2
			await _snap("st_done")
			get_tree().quit()
