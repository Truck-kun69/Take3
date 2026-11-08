extends Node
## Terrain tour: each stage from the game camera, plus a freeze and an electrified pool.
##   xvfb-run -a godot --path godot --rendering-method mobile res://tests/terrain_shots.tscn -- <outdir> [stages]
var main: Node
var out := "user://terrain"
var stages := [0, 1, 2, 3]
var si := 0
var t := 0.0
var phase := 0

func _ready() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: out = a[0]
	if a.size() > 1: stages = Array(a[1].split(",")).map(func(x): return int(x))
	DirAccess.make_dir_recursive_absolute(out)
	var sv := get_node("/root/Save")
	sv.path = "user://terrain_profile.json"
	sv.data = sv.defaults()
	sv.data.options.sound = false
	sv.data.hero = 1
	if OS.get_environment("SHOT_2D") != "": sv.data.options.renderer = 1
	main = load("res://scenes/main.tscn").instantiate()
	main.bot_drive = true
	add_child(main)

func _snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out.path_join(name + ".png"))
	print("shot ", name)

## A spot near the origin with liquid within view (walks outward until one is found).
func _lake_spot(T: Terrain) -> Vector2:
	for r in range(300, 2600, 80):
		for k in 24:
			var p := Vector2(cos(TAU * k / 24.0), sin(TAU * k / 24.0)) * r
			if T.is_liquid(p + Vector2(160, 0)) and T.passable(p):
				return p
	return Vector2(400, 0)

func _process(dt: float) -> void:
	t += dt
	match phase:
		0:
			if t > 0.8:
				main.start({"mode": "campaign", "stage": stages[si]})
				main.world.stats.set_source("shot", [["max_hp", "add", 1e6]])
				main.world.pp = _lake_spot(main.world.terrain)
				phase = 1; t = 0.0
		1:
			main.world.in_move = Vector2.ZERO
			if t > 1.6:
				phase = 2; t = 0.0
				await _snap("stage%d_terrain" % stages[si])
				var w: World = main.world
				if OS.get_environment("SHOT_NO_FREEZE") == "": w.terrain.freeze(w.pp + Vector2(170, -40), 70.0, 8.0)
				var wet := w.terrain.nearest_passable(w.pp)
				for r in range(40, 600, 16):                      # a liquid cell south of the freeze
					var q := w.pp + Vector2(160, 60 + r * 0.3) + Vector2(r * 0.2, r * 0.5)
					if w.terrain.is_liquid(q) and not w.terrain.is_frozen(q):
						wet = q
						break
				w.terrain.electrify(wet, 110.0, 8.0)
		2:
			main.world.in_move = Vector2.ZERO
			if t > 0.6:
				await _snap("stage%d_reactions" % stages[si])
				si += 1; phase = 0; t = 0.0
				if si >= stages.size():
					get_tree().quit()
