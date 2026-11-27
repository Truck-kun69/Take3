extends Node
## Render benchmark: a real run with the full 3D view, swarm sizes 150 / 300 / 500, reporting the
## frame time, the 3D view's CPU cost and draw calls. Needs a renderer (xvfb + lavapipe here, a GPU
## on real hardware). Lavapipe is a CPU rasteriser, so compare runs against each other, not with phones.
##   xvfb-run -a godot --path godot --rendering-method mobile --resolution 1280x720 res://tests/render_bench.tscn -- [out.json]
var main: Node
var stage := 0
var t := 0.0
var frames := 0
var acc := {"frame_ms": 0.0, "view_ms": 0.0, "draws": 0.0, "prims": 0.0}
var results := []
var SIZES := [150, 300, 500]
var _last := 0
var _prof_frames := 0
var _whole := {"process": 0.0, "sim": 0.0}
var _nodes: Array = []
var _node_us := {}

func _ready() -> void:
	if OS.get_environment("BENCH_SIZES") != "":
		SIZES = Array(OS.get_environment("BENCH_SIZES").split(",")).map(func(x): return int(x))
	var sv := get_node("/root/Save")
	sv.path = "user://bench_profile.json"
	sv.data = sv.defaults()
	sv.data.options.sound = false
	sv.data.hero = 0
	main = load("res://scenes/main.tscn").instantiate()
	main.bot_drive = true
	add_child(main)

func _fill(n: int) -> void:
	var w: World = main.world
	while w.sw.n < n:
		w.spawn_foe([Content.E.GRUNT, Content.E.RUNNER, Content.E.BRUTE, Content.E.SPITTER][w.sw.n % 4],
			w.pp + Vector2(randf_range(-520, 520), randf_range(-320, 320)), 0, 0, 1e6)

func _process(dt: float) -> void:
	t += dt
	if stage == 0:
		if t > 1.0:
			main.start({"mode": "campaign", "stage": 1})
			main.world.stats.set_source("bench", [["max_hp", "add", 1e7], ["regen", "add", 1e6]])
			stage = 1; t = 0.0; _last = Time.get_ticks_usec()
			if OS.get_environment("BENCH_NO_SHADOW") != "": main.view3d.sun.shadow_enabled = false
			if OS.get_environment("BENCH_NO_LOD") != "": get_viewport().mesh_lod_threshold = 0.0
			if OS.get_environment("BENCH_LOD") != "": get_viewport().mesh_lod_threshold = float(OS.get_environment("BENCH_LOD"))
			if OS.get_environment("BENCH_ORTHO") != "": main.view3d.sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
			main.view3d.profile = true
			if OS.get_environment("BENCH_NODES") != "":     # time these nodes' own _process here instead
				for n in [main.hud, main.overlay, main.touch, main.subtitles,
						get_node_or_null("/root/Sfx"), get_node_or_null("/root/Save"), get_node_or_null("/root/Voice")]:
					if n != null and n.has_method("_process"):
						n.set_process(false)
						_nodes.append(n)
		return
	var idx := stage - 1
	if idx >= SIZES.size():
		return
	_fill(SIZES[idx])
	if OS.get_environment("BENCH_NO_PROPS") != "":
		for c in main.view3d._prop_cells: main.view3d._prop_cells[c].visible = false
	main.world.in_move = Vector2(cos(t * 0.7), sin(t * 0.5)) * 0.6
	for n in _nodes:
		var n0 := Time.get_ticks_usec()
		n._process(dt)
		var key := String(n.name)
		_node_us[key] = float(_node_us.get(key, 0.0)) + float(Time.get_ticks_usec() - n0)
	var now := Time.get_ticks_usec()
	if t > 1.5:                                      # warm up 1.5 s per size, then sample 90 frames
		if frames == 0:
			main.view3d.prof_us = {}     # the part timings count the sampled frames only
			_node_us = {}
			_whole = {"process": 0.0, "sim": 0.0}
		frames += 1
		_whole.process += Performance.get_monitor(Performance.TIME_PROCESS) * 1e6
		if OS.get_environment("BENCH_FRAMES") != "": print("RF %d proc=%.2f sim=%.2f view=%.2f" % [main.world.sw.n, Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, main.sim_us / 1000.0, main.view3d.cost_us / 1000.0])
		_whole.sim += main.sim_us
		_prof_frames += 1
		acc.frame_ms += (now - _last) / 1000.0
		acc.view_ms += main.view3d.cost_us / 1000.0
		acc.draws += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		acc.prims += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		if frames >= 90:
			var r := {"foes": main.world.sw.n}
			for k in acc: r[k] = snappedf(acc[k] / frames, 0.01)
			results.append(r)
			if stage == 1: _breakdown()
			print("RBENCH foes=%d frame=%.1fms view=%.2fms draws=%d tris=%d" % [r.foes, r.frame_ms, r.view_ms, r.draws, r.prims])
			var pu: Dictionary = main.view3d.prof_us
			var total_frames := float(max(1, _prof_frames))
			print("RPROF foes=%d " % r.foes + " ".join(pu.keys().map(func(k): return "%s=%.2fms" % [k, pu[k] / 1000.0 / total_frames])))
			if not _nodes.is_empty():
				print("RNODES foes=%d " % r.foes + " ".join(_node_us.keys().map(func(k): return "%s=%.2fms" % [k, _node_us[k] / 1000.0 / total_frames])))
			var vt := 0.0
			for k in pu: if not String(k).begins_with("fx:"): vt += pu[k]
			print("RFRAME foes=%d process=%.2fms sim=%.2fms view=%.2fms rest=%.2fms" % [r.foes, _whole.process / 1000.0 / total_frames, _whole.sim / 1000.0 / total_frames,
				vt / 1000.0 / total_frames, (_whole.process - _whole.sim - vt) / 1000.0 / total_frames])
			main.view3d.prof_us = {}
			_prof_frames = 0
			for k in acc: acc[k] = 0.0
			frames = 0; t = 0.0; stage += 1
			if stage - 1 >= SIZES.size():
				var a := OS.get_cmdline_user_args()
				if a.size() > 0:
					var f := FileAccess.open(a[0], FileAccess.WRITE); f.store_string(JSON.stringify(results, "  ")); f.close()
				get_tree().quit()
	_last = now

func _tris(m: Mesh) -> int:
	var n := 0
	for i in m.get_surface_count():
		var a := m.surface_get_arrays(i)
		n += (a[Mesh.ARRAY_INDEX].size() if a[Mesh.ARRAY_INDEX] != null else a[Mesh.ARRAY_VERTEX].size()) / 3
	return n

func _breakdown() -> void:
	var rows := []
	for n in main.view3d.find_children("*", "GeometryInstance3D", true, false):
		if not n.is_visible_in_tree(): continue
		if n is MultiMeshInstance3D and n.multimesh != null and n.multimesh.mesh != null:
			var c: int = n.multimesh.visible_instance_count if n.multimesh.visible_instance_count >= 0 else n.multimesh.instance_count
			if c > 0: rows.append([_tris(n.multimesh.mesh) * c, "MM %s x%d (%d tris each) shadow=%d" % [n.name, c, _tris(n.multimesh.mesh), n.cast_shadow]])
		elif n is MeshInstance3D and n.mesh != null:
			rows.append([_tris(n.mesh), "MI %s shadow=%d" % [n.get_path().get_concatenated_names().right(60), n.cast_shadow]])
	rows.sort_custom(func(a, b): return a[0] > b[0])
	var tot := 0
	for r in rows: tot += r[0]
	print("BREAKDOWN total %d tris in %d nodes" % [tot, rows.size()])
	for r in rows.slice(0, 18): print("  %8d %s" % r)
