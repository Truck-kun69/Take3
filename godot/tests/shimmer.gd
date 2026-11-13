extends Node
## Shimmer metric: how much the ground changes when the camera moves by a fraction of a pixel.
## A stable, mip-filtered image barely changes; aliasing detail (procedural noise, sub-pixel
## geometry) flickers. Freezes a run, renders two frames NUDGE world units apart and prints the
## mean absolute luminance difference (0-255) over the play field (HUD excluded).
##   xvfb-run -a godot --path godot --rendering-method mobile --resolution 1280x720 res://tests/shimmer.tscn -- <out dir> [stage]
const NUDGE := 0.35
var main: Node
var out := "user://shimmer"
var stage := 0
var t := 0.0
var phase := 0
var shots: Array[Image] = []
var nudge := Vector3.ZERO
var busy := false

func _ready() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: out = a[0]
	if a.size() > 1: stage = int(a[1])
	DirAccess.make_dir_recursive_absolute(out)
	var sv := get_node("/root/Save")
	sv.path = "user://shimmer_profile.json"
	sv.data = sv.defaults()
	sv.data.options.sound = false
	main = load("res://scenes/main.tscn").instantiate()
	main.bot_drive = true
	add_child(main)

func _process(_dt: float) -> void:
	t += 1.0 / 60.0
	match phase:
		0:
			if t > 0.8:
				main.start({"mode": "campaign", "stage": stage})
				main.world.stats.set_source("shot", [["max_hp", "add", 1e6]])
				phase = 1; t = 0.0
		1:
			main.world.in_move = Vector2(1, 0.3).normalized()
			if t > 2.5:
				Engine.time_scale = 0.0
				phase = 2; t = 0.0
		2, 3:
			if t > 0.3 and not busy:
				busy = true
				main.view3d.set("test_nudge", Vector3(NUDGE, 0, NUDGE * 0.6) * float(phase - 2))
				await RenderingServer.frame_post_draw
				await RenderingServer.frame_post_draw
				var im := get_viewport().get_texture().get_image()
				im.save_png(out.path_join("shimmer%d_%s.png" % [stage, "a" if phase == 2 else "b"]))
				shots.append(im)
				phase += 1; t = 0.0; busy = false
		4:
			var a := shots[0]; var b := shots[1]
			var sum := 0.0; var n := 0; var lum := 0.0; var grad := 0.0
			for y in range(int(a.get_height() * 0.16), int(a.get_height() * 0.72), 2):
				for x in range(int(a.get_width() * 0.12), int(a.get_width() * 0.76), 2):
					sum += absf(a.get_pixel(x, y).get_luminance() - b.get_pixel(x, y).get_luminance()); n += 1; lum += a.get_pixel(x, y).get_luminance()
					grad += 0.5 * (absf(a.get_pixel(x, y).get_luminance() - a.get_pixel(x + 1, y).get_luminance()) + absf(a.get_pixel(x, y).get_luminance() - a.get_pixel(x, y + 1).get_luminance()))
			# a clean image moved by a fraction of a pixel changes by about that fraction of its own pixel-to-pixel
			# contrast; aliasing detail changes by far more. So: change / contrast (lower is steadier).
			print("SHIMMER stage %d: change %.2f, contrast %.2f, ratio %.2f" % [stage, sum / n * 255.0, grad / n * 255.0, sum / maxf(grad, 0.0001)])
			phase = 5
			get_tree().quit()
