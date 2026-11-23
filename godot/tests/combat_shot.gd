extends Node
## The release gate's combat render smoke (tools/gate_check.py, when Xvfb and a Vulkan driver are present):
## a real run through main.tscn on the Mobile renderer, the Emberwitch's contagion burning through a pack,
## one frame saved for the gate to measure (central playfield contrast and brightness).
##   xvfb-run -a godot --path godot --rendering-method mobile --resolution 1280x720 res://tests/combat_shot.tscn -- <out.png> [hero] [stage]
## Prints "SMOKE foes=<n> burning=<n> hero=<id> stage=<i>" before it quits.
var main: Node
var out := "user://combat.png"
var hero := 2
var stage := 0
var t := 0.0
var phase := 0

func _ready() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: out = a[0]
	if a.size() > 1: hero = int(a[1])
	if a.size() > 2: stage = int(a[2])
	var sv := get_node("/root/Save")
	sv.path = "user://combat_shot_profile.json"
	sv.data = sv.defaults()
	sv.data.options.sound = false
	sv.data.options.gfx = 2
	sv.data.hero = hero
	sv.data.intro_seen = true
	main = load("res://scenes/main.tscn").instantiate()
	main.bot_drive = true
	add_child(main)

func _process(dt: float) -> void:
	t += dt
	if phase == 0 and t > 0.8:
		phase = 1
		t = 0.0
		main.start({"mode": "campaign", "stage": stage})
		var w: World = main.world
		w.stats.set_source("smoke", [["max_hp", "add", 1e6]])
		w.hp = 1e6
		w.need = 1e12                                    # no level-up screen over the fight
	elif phase == 1:
		var w: World = main.world
		while w.sw.n < 60:
			var a := randf() * TAU
			if w.spawn_foe(Content.E.GRUNT + (w.sw.n % 4), w.pp + Vector2(cos(a), sin(a)) * randf_range(140.0, 360.0), 0, 0, 4.0) < 0: break
		# game time, not wall time: a software renderer draws a few frames a second and the fixed clock runs at
		# most two ticks a frame. 4 s in, the Emberwitch has cast and the pack is burning.
		if w.t > 4.0 or t > 90.0:
			phase = 2
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(out)
			print("SMOKE foes=%d burning=%d hero=%s stage=%d t=%.1f" % [w.sw.n, w.contagion.burning if w.contagion != null else 0, w.hero_id, w.stage, w.t])
			main._free_world()
			main.queue_free()
			await get_tree().process_frame
			await get_tree().process_frame
			Models._cache.clear()                     # static caches hold meshes: let them go before the engine exits
			get_tree().quit()
