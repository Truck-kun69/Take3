extends Node
## Long-session soak (docs/OPTIMIZATION.md O3): bot-played runs back to back on the real game scene, every act
## and every exile in turn, with level-ups, bargains, the merchant, deaths, the end screen and Pause > Main Menu.
## Headless, so the renderer draws nothing: it measures the scripts and the engine's objects, not the GPU.
##   godot --headless --fixed-fps 60 --path godot res://tests/soak.tscn -- [runs 10] [game seconds a run 240]
## Per run it prints the engine's object, resource and node counts and static memory as the run starts (the
## menu, the last run's world freed), the frame's simulation and view cost, and the containers of the run's
## World, view and effects that grew most; at the end, the autoloads' and static caches' sizes, first run to
## last. SOAK_JSON=<path> writes the rows; SOAK_HITCH_MS (25) is the frame time logged as a hitch.
var main: Node
var bot: Bot
var runs := 10
var run_s := 240.0
var k := 0
var phase := "boot"
var t := 0.0
var rows: Array = []
var _acc := {}
var _mid := {}           # container sizes 60 s into the run
var _keep := {}          # autoload and static cache sizes at each run start: name -> Array of sizes
var _t0 := 0
var _last_us := 0        # when this node's last _process ran: the gap is the whole last frame (it runs first)
var _since_start := 0    # frames since this run started (the first few carry the run's own setup)
var _rc := 0             # the resource count at the last frame: SOAK_LOADS=1 marks each frame that loaded something
var _frame_no := 0
var _nodes: Array = []   # SOAK_NODES=1: these nodes' _process run from here, each timed (tree order kept)
var _node_us := {}
var _prof_prev := {}     # the view's part timings (WorldView3D.profile) at the last frame
var _hitch_us := (float(OS.get_environment("SOAK_HITCH_MS")) if OS.get_environment("SOAK_HITCH_MS") != "" else 25.0) * 1000.0

func _ready() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: runs = int(a[0])
	if a.size() > 1: run_s = float(a[1])
	var sv := get_node("/root/Save")
	sv.path = "user://soak_profile.json"
	sv.data = sv.defaults()
	sv.data.intro_seen = true
	sv.data.options.sound = true
	main = load("res://scenes/main.tscn").instantiate()
	main.bot_drive = true
	add_child(main)
	_t0 = Time.get_ticks_msec()

static func _rss_mb() -> float:
	var f := FileAccess.open("/proc/self/status", FileAccess.READ)     # Linux only; its length reads as 0, so by line
	if f == null: return -1.0
	while not f.eof_reached():
		var ln := f.get_line()
		if ln.begins_with("VmRSS:"): return float(ln.split(":")[1].strip_edges().split(" ")[0]) / 1024.0
	return -1.0

func _counts() -> Dictionary:
	return {"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"resources": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"orphans": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"static_mb": snappedf(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, 0.01),
		"rss_mb": snappedf(_rss_mb(), 0.1),
		"view_nodes": main.view3d.get_child_count(true) if main.view3d != null else 0,
		"view_tree": _tree_size(main.view3d) if main.view3d != null else 0,
		"ui_tree": _tree_size(main.screens) + _tree_size(main.hud)}

static func _tree_size(n: Node) -> int:
	if n == null: return 0
	var c := 1
	for ch in n.get_children(true): c += _tree_size(ch)
	return c

## Sizes of an object's own Array, Dictionary and packed-array members (one level), by "prefix.name".
static func _sizes(o: Object, prefix: String, out: Dictionary) -> void:
	if o == null: return
	for p in o.get_property_list():
		if (int(p.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0: continue
		var v = o.get(p.name)
		match typeof(v):
			TYPE_ARRAY, TYPE_DICTIONARY, TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, \
			TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY, TYPE_PACKED_VECTOR4_ARRAY:
				out[prefix + "." + String(p.name)] = v.size()

func _run_sizes() -> Dictionary:
	var out := {}
	var w: World = main.world
	if w == null: return out
	_sizes(w, "World", out)
	for sub in ["sw", "director", "bosses", "terrain", "contagion", "grid"]:
		var o = w.get(sub)
		if o is Object: _sizes(o, "World." + sub, out)
	if main.view3d != null:
		_sizes(main.view3d, "View", out)
		var fx = main.view3d.get("fx")
		if fx is Object: _sizes(fx, "Fx", out)
	_sizes(main.hud, "Hud", out)
	_sizes(main.overlay, "Overlay", out)
	return out

func _keep_sizes() -> Dictionary:
	var out := {}
	for n in ["Sfx", "Diag", "Voice", "Save"]:
		var o := get_node_or_null("/root/" + n)
		if o != null: _sizes(o, n, out)
	out["Models._cache"] = Models._cache.size()
	out["HeroRig._tcache"] = HeroRig._tcache.size()
	out["Save.data(json bytes)"] = JSON.stringify(Save.data).length()
	return out

func _start_run() -> void:
	var stage := k % 5
	Save.data.hero = k % 4
	var c := _counts()
	c["run"] = k
	c["hero"] = String(Content.HEROES[k % 4].id)
	c["act"] = stage + 1
	rows.append(c)
	var ks := _keep_sizes()
	for key in ks:
		if not _keep.has(key): _keep[key] = []
		_keep[key].append(ks[key])
	var s0 := Time.get_ticks_usec()
	main.start({"mode": "campaign", "stage": stage})
	c["start_ms"] = snappedf((Time.get_ticks_usec() - s0) / 1000.0, 0.1)
	_since_start = 0
	if OS.get_environment("SOAK_NODES") != "" and _nodes.is_empty():
		for n in [main, main.view3d, main.menu_stage, main.overlay, main.touch, main.hud, main.screens, main.subtitles, main.voice_dir,
				get_node_or_null("/root/Sfx"), get_node_or_null("/root/Save"), get_node_or_null("/root/Voice"), get_node_or_null("/root/Diag")]:
			if n != null and n.has_method("_process") and n.is_processing():
				n.set_process(false)
				_nodes.append(n)
		main.view3d.profile = true
	if OS.get_environment("SOAK_NODES") != "": main.world.profile = true
	main.world.stats.set_source("soak", [["max_hp", "add", 900.0], ["regen", "add", 12.0]])
	bot = Bot.new(main.world, 50 + k)
	_acc = {"sim": 0.0, "view": 0.0, "frames": 0, "worst": 0.0, "foes": 0, "levels": 0, "bargains": 0, "merchants": 0, "frame_worst": 0.0, "hitches": 0}
	_mid = {}
	phase = "run"
	t = 0.0

func _end_row(why: String) -> void:
	var r: Dictionary = rows[-1]
	var w: World = main.world
	var f := maxf(1.0, float(_acc.frames))
	r["why"] = why
	r["game_s"] = snappedf(w.t if w != null else 0.0, 0.1)
	r["sim_ms"] = snappedf(_acc.sim / f / 1000.0, 0.01)
	r["view_ms"] = snappedf(_acc.view / f / 1000.0, 0.01)
	r["worst_ms"] = snappedf(_acc.worst / 1000.0, 0.01)
	r["frame_worst_ms"] = snappedf(_acc.frame_worst / 1000.0, 0.1)
	r["hitches"] = _acc.hitches
	r["foes_max"] = _acc.foes
	r["levels"] = _acc.levels
	var end := _run_sizes()
	var grew: Array = []
	for key in end:
		var a := int(_mid.get(key, 0))
		var b := int(end[key])
		if b >= 64 and b > a * 2 and not _mid.is_empty(): grew.append("%s %d->%d" % [key, a, b])
	r["grew"] = grew
	var big: Array = end.keys()
	big.sort_custom(func(x, y): return int(end[x]) > int(end[y]))
	r["largest"] = big.slice(0, 6).map(func(x): return "%s %d" % [x, int(end[x])])
	print("SOAK run %d %s act %d: %s at %.0f s, sim %.2f ms view %.2f ms (worst %.1f ms; whole frame worst %.1f ms, %d over the hitch line; the start %.0f ms), %d foes max, %d level-ups | at start: %d objects, %d resources, %d nodes, %d orphans, static %.1f MB, rss %.0f MB, view tree %d, ui tree %d" % [
		r.run, r.hero, r.act, why, r.game_s, r.sim_ms, r.view_ms, r.worst_ms, r.frame_worst_ms, r.hitches, r.start_ms, r.foes_max, r.levels,
		r.objects, r.resources, r.nodes, r.orphans, r.static_mb, r.rss_mb, r.view_tree, r.ui_tree])
	if not grew.is_empty(): print("     grew after 60 s: " + ", ".join(grew))
	print("     largest: " + ", ".join(r.largest))

func _process(dt: float) -> void:
	t += dt
	var now := Time.get_ticks_usec()
	var frame_us := float(now - _last_us) if _last_us > 0 else 0.0
	_last_us = now
	_frame_no += 1
	var rc := int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
	if rc != _rc and OS.get_environment("SOAK_LOADS") != "":
		print("SOAK frame %d (%.1f ms) resources %d -> %d" % [_frame_no - 1, frame_us / 1000.0, _rc, rc])     # the frame that just ran
	_rc = rc
	if phase == "run" and main.world != null:
		_since_start += 1
		if _since_start > 3:          # past the start's own frames
			_acc.frame_worst = maxf(_acc.frame_worst, frame_us)
			if frame_us > _hitch_us:
				_acc.hitches += 1
				var vu: float = main.view3d.cost_us if main.view3d != null else 0.0
				var parts := ""
				if not _nodes.is_empty():
					var tot := 0.0
					var ks: Array = _node_us.keys()
					ks.sort_custom(func(a, b): return _node_us[a] > _node_us[b])
					for key in ks: tot += _node_us[key]
					parts = " | nodes " + ", ".join(ks.slice(0, 3).map(func(key): return "%s %.1f" % [key, _node_us[key] / 1000.0])) + ", engine and the rest %.1f" % ((frame_us - tot) / 1000.0)
					if main.view3d != null:
						var pu: Dictionary = main.view3d.prof_us
						var d := {}
						for key in pu: d[key] = float(pu[key]) - float(_prof_prev.get(key, 0.0))
						var pk: Array = d.keys()
						pk.sort_custom(func(a, b): return d[a] > d[b])
						parts += " | view parts " + ", ".join(pk.slice(0, 4).map(func(key): return "%s %.1f" % [key, d[key] / 1000.0]))
					var wt: Dictionary = main.world.prof_tick
					if not wt.is_empty():
						var wk: Array = wt.keys()
						wk.sort_custom(func(a, b): return wt[a] > wt[b])
						parts += " | tick " + ", ".join(wk.slice(0, 4).map(func(key): return "%s %.1f" % [key, wt[key] / 1000.0]))
				print("SOAK hitch run %d frame %d at %.1f s (%s): %.1f ms = sim %.2f + view %.2f + the rest %.2f, %d foes%s" % [k, _frame_no - 1, main.world.t, main.state, frame_us / 1000.0,
					main.sim_us / 1000.0, vu / 1000.0, (frame_us - main.sim_us - vu) / 1000.0, main.world.sw.n, parts])
	if main.view3d != null and main.view3d.profile: _prof_prev = main.view3d.prof_us.duplicate()
	if main.world != null and main.world.profile: main.world.prof_tick = {}        # this frame's ticks from here
	_node_us = {}
	for n in _nodes:
		if not is_instance_valid(n): continue
		var n0 := Time.get_ticks_usec()
		n._process(dt)
		var nm := String(n.name)
		if nm.begins_with("@") and n.get_script() != null: nm = (n.get_script() as Script).resource_path.get_file().get_basename()
		_node_us[nm] = float(Time.get_ticks_usec() - n0)
	match phase:
		"boot":
			if t > 1.0 and main.state == "menu": _start_run()
		"run":
			var w: World = main.world
			if w == null: return
			if main.state == "levelup":
				main._on_act("pick", Bot.pick(w.make_choices(), w))
				_acc.levels += 1
			elif main.state == "whisper":
				main._on_act("bargain", Bot.bargain(w.whisper_offer, 50 + k))
				_acc.bargains += 1
			elif main.state == "merchant":
				if w.gold >= Director.GAMBLE_COST: w.director.gamble(Content.SLOTS[k % Content.SLOTS.size()])
				main._on_act("resume", null)
				_acc.merchants += 1
			if main.state == "play":
				bot.w = w
				bot.think()
				_acc.frames += 1
				_acc.sim += main.sim_us
				var vc: float = main.view3d.cost_us if main.view3d != null else 0.0
				_acc.view += vc
				_acc.worst = maxf(_acc.worst, main.sim_us + vc)
				_acc.foes = maxi(_acc.foes, w.sw.n)
				if _mid.is_empty() and w.t >= 60.0: _mid = _run_sizes()
			if w.over and main.state == "end" and main.screens.page != "":
				_end_row("died" if not w.won else "won")
				phase = "end_screen"
				t = 0.0
			elif not w.over and w.t >= run_s and main.state == "play":
				if k % 2 == 0:
					_end_row("abandoned")
					main._on_act("abandon", null)      # Pause > Abandon: the end screen, then the menu
					phase = "end_screen"
				else:
					_end_row("left")
					main._pause()
					main._leave_run()                  # Pause > Main Menu
					phase = "next"
				t = 0.0
		"end_screen":
			if t > 1.5:
				main._on_act("menu", null)
				phase = "next"
				t = 0.0
		"next":
			if t > 0.5 and main.state == "menu":
				k += 1
				if k >= runs: _finish()
				else: _start_run()

func _finish() -> void:
	phase = "done"
	var last := _counts()
	last["run"] = k
	rows.append(last)
	print("SOAK after %d runs: %d objects, %d resources, %d nodes, %d orphans, static %.1f MB, rss %.0f MB, view tree %d, ui tree %d (%.0f s)" % [
		k, last.objects, last.resources, last.nodes, last.orphans, last.static_mb, last.rss_mb, last.view_tree, last.ui_tree, (Time.get_ticks_msec() - _t0) / 1000.0])
	var ks := _keep_sizes()
	for key in ks:
		if not _keep.has(key): _keep[key] = []
		_keep[key].append(ks[key])
	var moved: Array = []
	for key in _keep:
		var a: Array = _keep[key]
		if a.size() >= 2 and int(a[-1]) != int(a[0]): moved.append("%s %s" % [key, str(a)])
	print("SOAK kept between runs (changed): " + ("none" if moved.is_empty() else "\n  " + "\n  ".join(moved)))
	if OS.get_environment("SOAK_JSON") != "":
		var f := FileAccess.open(OS.get_environment("SOAK_JSON"), FileAccess.WRITE)
		f.store_string(JSON.stringify({"rows": rows, "kept": _keep}, "  "))
		f.close()
	# sounds still playing hold their streams past the audio server's shutdown, which reads as leaks at exit
	for p in get_tree().root.find_children("*", "AudioStreamPlayer", true, false): p.stop()
	for p in get_tree().root.find_children("*", "AudioStreamPlayer2D", true, false): p.stop()
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().quit()
