extends Node
## Headless test + benchmark runner.
##   godot --headless --path godot res://tests/tests.tscn -- [unit] [sim] [bench] [--json=path]
## Unit tests check invariants of the data-driven systems; `sim` runs bot-played runs in every mode
## and reports balance metrics; `bench` stresses a full swarm and reports per-system frame cost.

var failures := 0
var passes := 0
var report := {}

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		args = PackedStringArray(["unit", "sim", "bench"])
	var save := get_node_or_null("/root/Save")
	if save == null:
		push_error("Save autoload missing")
		get_tree().quit(2)
		return
	save.path = "user://test_profile.json"
	save.data = save.defaults()
	save.data.options.sound = false
	if "unit" in args: _unit()
	if "sim" in args: _sims()
	if "bench" in args: _bench()
	print("\n== %d passed, %d failed ==" % [passes, failures])
	for a in args:
		if a.begins_with("--json="):
			var f := FileAccess.open(a.substr(7), FileAccess.WRITE)
			f.store_string(JSON.stringify(report, "  "))
			f.close()
	get_tree().quit(1 if failures > 0 else 0)

func ok(cond: bool, what: String) -> void:
	if cond:
		passes += 1
	else:
		failures += 1
		print("  FAIL: " + what)

# ================================================================= unit tests
func _unit() -> void:
	print("== unit")
	# stat pipeline: (base + added) * (1 + inc) * more
	var s := Stats.new()
	s.set_source("a", [["damage", "add", 2.0], ["damage", "inc", 0.5]])
	s.set_source("b", [["damage", "more", 1.2], ["damage", "inc", 0.25]])
	ok(is_equal_approx(s.value("damage", 10.0), 12.0 * 1.75 * 1.2), "stat pipeline math")
	s.clear_source("a")
	ok(is_equal_approx(s.value("damage", 10.0), 10.0 * 1.25 * 1.2), "clear_source")
	s.set_source("c", [["cooldown", "inc", -5.0]])
	ok(s.value("cooldown", 1.0) > 0.0, "increased is floored, never inverts")
	var loc := Stats.new()
	loc.set_source("g", [["damage", "more", 0.5]])
	ok(is_equal_approx(s.value("damage", 10.0, loc), 10.0 * 1.25 * 1.2 * 0.5), "local stats layer")
	s.set_source("stack", [["damage", "more", 2.0]], 3.0)
	ok(is_equal_approx(s.components("damage").z, 1.2 * 8.0), "more stacks exponentially")

	# buffs: stacking policies
	var bs := Stats.new()
	var b := Buffs.new(bs)
	b.add("soulharvest"); b.add("soulharvest"); b.add("soulharvest")
	ok(b.stacks("soulharvest") == 3, "INTENSITY stacks")
	ok(is_equal_approx(bs.value("damage", 1.0), 1.06), "stacked buff modifies stats")
	ok(b.add("aegis") and not b.add("aegis"), "UNIQUE rejects reapplication")
	b.add("quicksilver"); b.add("quicksilver"); b.add("quicksilver")
	ok(b.remaining("quicksilver") <= 10.0 + 0.001, "DURATION capped at max_dur")
	b.add("power")
	var first := b.remaining("power")
	b.remove("power")
	b.add("power")
	ok(b.remaining("power") < first, "pylon diminishing returns")
	for k in 200: b.step(0.5)
	ok(b.list.is_empty() and not bs.flag("invuln"), "buffs expire and clear their modifiers")

	# items & crafting
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var bad := 0
	for k in 600:
		var r := k % 4
		var it := Items.make(Content.SLOTS[k % 4], r, 1 + k % 50, rng)
		for cur in Content.CURRENCY_IDS:
			Items.craft(it, cur, rng)
			if not Items.valid(it): bad += 1
	ok(bad == 0, "items stay valid through every crafting op (%d invalid)" % bad)
	var it2 := Items.make("ring", Content.Rarity.NORMAL, 10, rng)
	ok(Items.craft(it2, "chaos", rng) != "", "chaos rejects normal items")
	ok(Items.craft(it2, "transmute", rng) == "" and it2.rarity == Content.Rarity.MAGIC, "transmute -> magic")
	ok(Items.craft(it2, "regal", rng) == "" and it2.rarity == Content.Rarity.RARE, "regal -> rare")
	Items.craft(it2, "corrupt", rng)
	ok(Items.craft(it2, "exalt", rng) != "", "corrupted items are locked")
	var low := Items.make("relic", Content.Rarity.RARE, 1, rng)
	var tiers_ok := true
	for a in low.affixes:
		if int(Content.AFFIXES[a.id].tiers[a.tier][0]) > 1: tiers_ok = false
	ok(tiers_ok, "affix tiers respect item level")
	var j := JSON.parse_string(JSON.stringify(low))
	ok(Items.valid(Items.normalise(j)), "item JSON round trip")

	# atlas
	var at := Atlas.generate(1234)
	var e := {}
	for x in at.edges: e[int(x)] = true
	ok(Atlas.connected(at.nodes.size(), e), "atlas graph connected")
	ok(at.nodes[at.start].open, "atlas start node open")
	Atlas.complete(at, at.start)
	var opened := 0
	for n in at.nodes: if n.open: opened += 1
	ok(opened >= 2, "completing a node reveals neighbours")
	var at2 := Atlas.with_progress(1234, Atlas.progress(at))
	ok(at2.nodes[at.start].done, "atlas progress round trip")
	var cit := 0
	for n in at.nodes: if n.kind == "citadel": cit += 1
	ok(cit == 4, "four citadels")

	# reactions & cascades in a live world
	var w := _world({"mode": "campaign", "hero": 2, "seed": 7})
	for k in 40:
		w.spawn_foe(Content.E.BRUTE, Vector2(100 + (k % 8) * 18, (k / 8) * 18), 0)
	w.grid.build(w.sw)
	for i in w.sw.n: w.sw.apply_status(i, Content.El.COLD, 1.0, 5.0)
	w.hit(0, 1.0, 1 << Content.El.FIRE, Vector2.ZERO, 0.0, 0)
	w._resolve_reactions()
	ok(int(w.metrics.reactions) >= 2, "reaction cascades (%d)" % w.metrics.reactions)
	ok(int(w.metrics.cascade_max) <= Content.REACT_DEPTH + 1, "cascade depth capped (%d)" % w.metrics.cascade_max)
	ok(int(w.metrics.reactions) <= Content.REACT_BUDGET, "reaction budget respected")

	# regression (cycle 1): querying a grid before its first build must not hang
	var g0 := SpatialGrid.new()
	var sw0 := Swarm.new()
	sw0.add(0, Vector2.ZERO, 1.0, 1.0, 5.0, 1.0, 1.0, 0, 0)
	ok(g0.query(Vector2.ZERO, 50.0, sw0) == 0, "unbuilt grid reads empty")
	# regression (cycle 2): an overkilled gremlin must not spin the coin-spill loop
	var wg := _world({"mode": "campaign", "hero": 0, "seed": 9})
	var ge := wg.director.start("goblin")
	var gi := wg.sw.index_of(int(ge.u))
	wg.sw.take(gi, 1e9)
	var tg0 := Time.get_ticks_msec()
	wg.director.step(1.0 / 60.0)
	ok(Time.get_ticks_msec() - tg0 < 200 and wg.picks.size() < 20, "overkill does not explode the gremlin loop")
	wg.dispose()
	# swarm swap-removal keeps uid index coherent
	var sw := Swarm.new()
	for k in 50: sw.add(0, Vector2(k, 0), 10.0, 1.0, 5.0, 1.0, 1.0, 0, 0)
	var u7 := sw.uid[7]
	sw.remove(3); sw.remove(0); sw.remove(10)
	ok(sw.index_of(u7) >= 0 and sw.uid[sw.index_of(u7)] == u7, "uid index survives swap-removal")
	ok(sw.n == 47, "swarm count after removal")

	# director never exceeds its concurrency cap; events fire
	var w2 := _world({"mode": "campaign", "hero": 0, "seed": 3})
	var maxc := 0
	for k in 60 * 140:
		w2.director.step(1.0 / 60.0)
		w2.t += 1.0 / 60.0
		maxc = maxi(maxc, w2.director.active.size())
	ok(maxc <= w2.director.max_concurrent(), "director concurrency cap (%d)" % maxc)
	ok(w2.director.history.size() >= 2, "director starts events (%d)" % w2.director.history.size())

	# greater rift scaling is exponential
	ok(is_equal_approx(Content.gr_hp_mult(11) / Content.gr_hp_mult(10), 1.17), "GR +17% life per level")

	# save round trip
	var sv := get_node("/root/Save")
	sv.data.gold = 123
	sv.data.stash = [Items.make("boots", 2, 20, rng)]
	sv.flush()
	sv.data = sv.defaults()
	sv.load_profile()
	ok(int(sv.data.gold) == 123 and sv.data.stash.size() == 1 and Items.valid(sv.data.stash[0]), "profile save/load")
	sv.data = sv.defaults()
	sv.data.options.sound = false

func _world(cfg: Dictionary) -> World:
	cfg["headless"] = true
	cfg["season"] = cfg.get("season", "")
	var w := World.new()
	w.setup(cfg)
	return w

# ================================================================= bot-played runs
func run_bot(cfg: Dictionary, max_t: float, bot_seed: int) -> Dictionary:
	var w := _world(cfg)
	var bot := Bot.new(w, bot_seed)
	var dt := 1.0 / 60.0
	var frames := 0
	var us := 0
	var worst := 0
	var hp_low := 1.0
	var lvl_t := {}
	while not w.over and w.t < max_t:
		bot.think()
		var t0 := Time.get_ticks_usec()
		w.step(dt)
		var el := Time.get_ticks_usec() - t0
		us += el
		worst = maxi(worst, el)
		frames += 1
		hp_low = minf(hp_low, w.hp / w.max_hp)
		while w.pending > 0:
			var ch := w.make_choices()
			w.apply_choice(Bot.pick(ch, w))
			if not lvl_t.has(w.lvl): lvl_t[w.lvl] = int(w.t)
	var dps: float = w.metrics.dmg_dealt / maxf(1.0, w.t)
	var lv := w.lvl
	w.dispose()
	return {"mode": cfg.mode, "hero": Content.HEROES[int(cfg.hero)].name, "won": w.won, "over": w.over, "t": snappedf(w.t, 0.1), "lvl": lv,
		"kills": w.kills, "killer": w.killer, "hp_low": snappedf(hp_low, 0.01), "dps": int(dps), "reactions": w.metrics.reactions,
		"react_dropped": w.metrics.react_dropped, "react_by": w.metrics.react_by, "cascade_max": w.metrics.cascade_max,
		"texts_per_s": snappedf(float(w.metrics.texts) / maxf(1.0, w.t), 0.1), "peak_foes": w.metrics.peak_foes,
		"perfect": w.metrics.perfect, "events": w.metrics.events, "items": w.metrics.items, "dmg_taken": int(w.metrics.dmg_taken),
		"ms_avg": snappedf(us / 1000.0 / maxf(1, frames), 0.01), "ms_worst": snappedf(worst / 1000.0, 0.01),
		"lvl10_t": lvl_t.get(10, -1), "progress": snappedf(w.progress, 0.1), "gold": int(w.gold)}

func _sims() -> void:
	print("== sim (bot-played runs)")
	run_bot({"mode": "campaign", "hero": 0, "seed": 1}, 20.0, 0)     # warm-up: first-use script paths cost ~15 ms once
	var rows: Array = []
	for h in 4:
		rows.append(run_bot({"mode": "campaign", "hero": h, "stage": 0, "seed": 100 + h}, 200.0, h))
	rows.append(run_bot({"mode": "campaign", "hero": 1, "stage": 2, "seed": 77}, 200.0, 5))
	var at := Atlas.generate(99)
	var node: Dictionary = at.nodes[0]
	rows.append(run_bot({"mode": "atlas", "hero": 2, "node": node, "seed": 55}, 200.0, 6))
	rows.append(run_bot({"mode": "rift", "hero": 3, "gr": 1, "seed": 31}, 320.0, 7))
	rows.append(run_bot({"mode": "rift", "hero": 3, "gr": 8, "seed": 32}, 320.0, 8))
	rows.append(run_bot({"mode": "pinnacle", "hero": 0, "seed": 13}, 300.0, 9))
	for r in rows:
		print("  %-8s %-11s won=%-5s t=%6s lvl=%2d kills=%4d dps=%5d react=%4d drop=%3d casc=%d txt/s=%5s foes=%3d ms=%5s/%6s hp_low=%s killer=%s ev=%s" % [
			r.mode, r.hero, r.won, r.t, r.lvl, r.kills, r.dps, r.reactions, r.react_dropped, r.cascade_max, r.texts_per_s, r.peak_foes, r.ms_avg, r.ms_worst, r.hp_low, r.killer, r.events])
	report["sim"] = rows

# ================================================================= stress benchmark
func _bench() -> void:
	print("== bench (full swarm, per-system cost)")
	var w := _world({"mode": "rift", "hero": 3, "gr": 1, "seed": 5})
	var cc := CrowdCompute.new()
	if cc.init():
		w.crowd = cc
	report["crowd"] = "gpu" if w.crowd != null else "cpu (" + cc.last_error + ")"
	print("  crowd separation: ", report["crowd"])
	for id in ["bolt", "nova", "orbit"]:
		w.weapons[id] = {"lv": 5, "evo": true, "t": 0.0, "gems": []}
		w.wlocal[id] = Stats.new()
	w.weapons.storm.lv = 5
	w.weapons.storm.evo = true
	w.stats.set_source("bench", [["apply_fire", "add", 1.0], ["apply_cold", "add", 1.0], ["max_hp", "add", 1e6], ["regen", "add", 1e5]])
	w.hp = w.stats.value("max_hp", 100.0)
	while w.sw.n < Swarm.CAP - 40:
		w.spawn_foe(Content.E.GRUNT, w.pp + Vector2(randf_range(-600, 600), randf_range(-400, 400)), 0, 0, 50.0)
	var probes := {"grid": 0, "foes": 0, "weapons": 0, "projs": 0, "dots": 0, "react": 0, "total": 0}
	var dt := 1.0 / 60.0
	var frames := 240
	for f in frames:
		while w.sw.n < Swarm.CAP - 40:
			w.spawn_foe(Content.E.GRUNT, w.ring_point(), 0, 0, 50.0)
		var t0 := Time.get_ticks_usec()
		w.grid.build(w.sw)
		var t1 := Time.get_ticks_usec()
		w._step_foes(dt)
		var t2 := Time.get_ticks_usec()
		w._step_weapons(dt)
		var t3 := Time.get_ticks_usec()
		w._step_projs(dt)
		var t4 := Time.get_ticks_usec()
		w._step_dots(dt)
		var t5 := Time.get_ticks_usec()
		w._resolve_reactions()
		var t6 := Time.get_ticks_usec()
		w._step_feed(dt)
		w._reap()
		w.t += dt
		probes.grid += t1 - t0; probes.foes += t2 - t1; probes.weapons += t3 - t2; probes.projs += t4 - t3; probes.dots += t5 - t4; probes.react += t6 - t5
		probes.total += Time.get_ticks_usec() - t0
	var line := "  foes=%d " % w.sw.n
	var out := {}
	for k in probes:
		out[k] = snappedf(probes[k] / 1000.0 / frames, 0.01)
		line += "%s=%.2fms " % [k, out[k]]
	print(line)
	report["bench"] = out
	ok(true, "bench ran")
