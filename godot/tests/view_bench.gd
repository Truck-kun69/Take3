extends Node
## CPU cost of preparing a full swarm for drawing (WorldView3D), headless.
##   godot --headless --path godot res://tests/view_bench.tscn
var main: Node
var t := 0.0
var done := false
func _ready() -> void:
	var sv := get_node("/root/Save")
	sv.path = "user://vbench_profile.json"
	sv.data = sv.defaults()
	sv.data.options.sound = false
	main = load("res://scenes/main.tscn").instantiate()
	main.bot_drive = true
	add_child(main)
func _process(dt: float) -> void:
	t += dt
	if t > 0.5 and main.world == null:
		main.start({"mode": "rift", "hero": 3, "gr": 1, "seed": 5})
		main.world.stats.set_source("bench", [["max_hp", "add", 1e6], ["regen", "add", 1e5]])
	if main.world == null or done: return
	var w: World = main.world
	while w.sw.n < Swarm.CAP - 40:
		w.spawn_foe(Content.E.GRUNT + (w.sw.n % 5), w.pp + Vector2(randf_range(-600, 600), randf_range(-400, 400)), 0, 0, 50.0)
	if t > 3.0:
		done = true
		var v: WorldView3D = main.view3d
		var probes := {}
		for name in ["_foes", "_corpses"]:
			var t0 := Time.get_ticks_usec()
			for k in 100: v.call(name)
			probes[name] = (Time.get_ticks_usec() - t0) / 100000.0
		print("VIEW foes=%d  _foes(incl. corpses)=%.2fms  _corpses=%.2fms  whole view (Diag)=%.2fms  sim step=%.2fms" % [w.sw.n, probes["_foes"], probes["_corpses"], Diag.view_us / 1000.0, w.step_us / 1000.0])
		get_tree().quit()
