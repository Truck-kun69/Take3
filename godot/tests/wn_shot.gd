extends Node
## What's new as an updated tester sees it on launch (main shows it itself: a profile that has played, an older
## seen_version).  xvfb-run -a godot --path godot --rendering-method mobile --resolution 2340x1080 res://tests/wn_shot.tscn -- <outdir>
var main: Node
var out := "user://wn_shot"
var t := 0.0

func _ready() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: out = a[0]
	DirAccess.make_dir_recursive_absolute(out)
	var sv := get_node("/root/Save")
	sv.path = "user://wn_shot_profile.json"
	sv.data = sv.defaults()
	sv.data.options.sound = false
	sv.data.intro_seen = true
	sv.data.stats.runs = 4
	sv.data.seen_version = "0.10.6-alpha"
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)

func _process(dt: float) -> void:
	t += dt
	if t < 1.5: return
	set_process(false)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out.path_join("whats_new.png"))
	print("shot whats_new, seen_version now ", get_node("/root/Save").data.seen_version)
	get_tree().quit()
