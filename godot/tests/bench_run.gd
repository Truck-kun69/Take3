extends Node
## Runs the in-game benchmark (Options > Run benchmark) and saves the result screen.
##   xvfb-run -a godot --path godot --rendering-method mobile --resolution 1280x720 res://tests/bench_run.tscn -- <outdir> [gfx 0-3] [gpu_crowd 0-2]
var main: Node
var out := "user://bench"
var t := 0.0
var snapped := false

func _ready() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: out = a[0]
	DirAccess.make_dir_recursive_absolute(out)
	var sv := get_node("/root/Save")
	sv.path = "user://bench_profile.json"
	sv.data = sv.defaults()
	sv.data.options.sound = false
	sv.data.options.show_fps = true
	if a.size() > 1: sv.data.options.gfx = int(a[1])
	if a.size() > 2: sv.data.options.gpu_crowd = int(a[2])
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)

func _process(dt: float) -> void:
	t += dt
	if t > 1.0 and main.state == "menu" and not main.screens.get_child_count() == 0 and Save.data.bench.is_empty() and main.world == null:
		main._on_act("bench", null)
	if main.state == "bench" and not snapped and main._bench_t > 8.0:
		snapped = true
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(out.path_join("bench_play.png"))
	if not Save.data.bench.is_empty() and main.state == "menu":
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(out.path_join("bench_result.png"))
		get_tree().quit()
