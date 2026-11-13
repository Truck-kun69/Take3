extends Node
## One frame with the alpha weapons firing (visual check).
##   xvfb-run -a godot --path godot --rendering-method mobile --resolution 1280x720 res://tests/weapons_shot.tscn -- <out.png> [ids,comma]
var main: Node
var out := "user://weapons.png"
var ids := ["lance", "mine", "glaive", "wisp", "arc", "aura", "cleave", "meteor", "totem"]
var t := 0.0
var phase := 0
func _ready() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: out = a[0]
	if a.size() > 1: ids = Array(a[1].split(","))
	var sv := get_node("/root/Save")
	sv.path = "user://wshot_profile.json"
	sv.data = sv.defaults()
	sv.data.options.sound = false
	main = load("res://scenes/main.tscn").instantiate()
	main.bot_drive = true
	add_child(main)
func _process(dt: float) -> void:
	t += dt
	if phase == 0 and t > 0.8:
		phase = 1; t = 0.0
		main.start({"mode": "campaign", "stage": 0, "hero": 0})
		var w: World = main.world
		w.stats.set_source("shot", [["max_hp", "add", 1e6]])
		w.weapons.clear()
		for id in ids:
			w.weapons[id] = {"lv": 5, "evo": false, "t": 0.0, "gems": []}
			w.wlocal[id] = Stats.new()
	elif phase == 1:
		var w: World = main.world
		if w.sw.n < 90: w.spawn_foe(Content.E.GRUNT + (w.sw.n % 4), w.pp + Vector2(randf_range(-420, 420), randf_range(-260, 260)), 0, 0, 6.0)
		if t > 5.0:
			phase = 2
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(out)
			get_tree().quit()
