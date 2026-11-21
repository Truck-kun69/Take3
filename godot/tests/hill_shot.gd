extends Node
## One frame on a hillside from the game camera: foes, crystals, shots of both sides, loot and debris on
## the slopes. For checking heights, enemy-shot contrast, foe readability and the hero's x-ray by eye.
##   xvfb-run -a godot --path godot --rendering-method mobile --resolution 1280x720 res://tests/hill_shot.tscn -- <out.png> [stage]
## Env: HILL_GLOOM=1 full darkness (eclipse); HILL_XRAY=1 parks the hero behind a tall prop.
var main: Node
var out := "user://hill.png"
var stage := 1
var t := 0.0
var phase := 0

func _ready() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: out = a[0]
	if a.size() > 1: stage = int(a[1])
	var sv := get_node("/root/Save")
	sv.path = "user://hill_profile.json"
	sv.data = sv.defaults()
	sv.data.options.sound = false
	sv.data.options.gfx = 2
	main = load("res://scenes/main.tscn").instantiate()
	main.bot_drive = false
	add_child(main)

## The walkable spot whose 300-unit surroundings span the most height (first one over 60 units).
func _hill(T: Terrain) -> Vector2:
	var spot := Vector2.ZERO
	var best := 0.0
	for r in range(200, 4000, 120):
		for k in 16:
			var c := Vector2.from_angle(TAU * k / 16.0) * r
			if not T.passable(c): continue
			var lo := INF
			var hi := -INF
			for j in 16:
				var h := T.height(c + Vector2.from_angle(TAU * j / 16.0) * 260.0)
				lo = minf(lo, h); hi = maxf(hi, h)
			if hi - lo > best:
				best = hi - lo
				spot = c
		if best > 60.0: break
	print("hill spot ", spot, " height span ", best)
	return spot

func _process(dt: float) -> void:
	t += dt
	match phase:
		0:
			if t > 0.6:
				main.start({"mode": "campaign", "stage": stage, "seed": 3})
				var w: World = main.world
				w.stats.set_source("shot", [["max_hp", "add", 1e6]])
				w.pp = _hill(w.terrain)
				phase = 1
				t = 0.0
		1:
			var w: World = main.world
			if t > 0.3 and phase == 1:
				for k in 40: w.spawn_foe(Content.E.GRUNT + k % 5, w.pp + Vector2.from_angle(k * 0.9) * (130.0 + 5.0 * k), 0, 0, 50.0)
				for k in 24: w.add_gem(w.pp + Vector2.from_angle(k * 1.7) * (70.0 + 9.0 * k), 1.0 + (3.0 if k % 5 == 0 else 0.0))
				for k in 8:
					var es := World.Proj.new()
					es.pos = w.pp + Vector2.from_angle(k * 0.8 + 0.3) * (120.0 + 20.0 * k); es.vel = (w.pp - es.pos).normalized() * 40.0; es.life = 20.0; es.r = 7.0
					w.eshots.append(es)
				if OS.get_environment("HILL_GLOOM") != "": w.set("eclipse_t", 999.0)
				phase = 2
				t = 0.0
		2:
			var w: World = main.world
			w.in_move = Vector2.ZERO
			if t > 2.5:
				phase = 3
				await RenderingServer.frame_post_draw
				get_viewport().get_texture().get_image().save_png(out)
				print("shot ", out, " gloom ", w.gloom())
				get_tree().quit()
