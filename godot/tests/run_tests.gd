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
	if "unit" in args:
		_unit()
		_terrain_tests()
		_meta_tests()
		_sky_tests()
		_fusion_tests()
		_surface_tests()
		_hoard_tests()
		_prophecy_tests()
		_daily_tests()
		_anim_tests()
		_alpha_weapon_tests()
		_v7_tests()
		_gate_p01_tests()
		_tyrant_fsm_tests()
		_audio_tests()
		_height_tests()
		_interp_tests()
		_vat_tests()
		_jump_tests()
		_jump_polish_tests()
		_look_tests()
		_remediation_tests()
		_voice_tests()
		_pack_tests()
		await _alpha10_tests()
		_ops_tests()
		await _fit_tests()
		_perf_tests()
		await _perf_view_tests()
		await _stream_tests()
		_pacing_tests()
	elif "voice" in args:
		_voice_tests()
		_pack_tests()
	elif "alpha10" in args:
		await _alpha10_tests()
	elif "ops" in args:
		_ops_tests()
		await _fit_tests()
	elif "voicesim" in args:
		_pacing_tests()
		_voice_sim()
	elif "perf" in args:
		_perf_tests()
		await _perf_view_tests()
		await _stream_tests()
	elif "stream" in args:
		await _stream_tests()
	elif "lodprobe" in args:
		for kind in ["grunt", "runner", "brute", "charger", "spitter", "breach"]:
			var m: Mesh = Models.foe_mesh(kind)
			var sf := RenderingServer.mesh_get_surface(m.get_rid(), 0)
			var vc: int = sf.get("vertex_count", 0)
			var row := "%s: %d tris, %d verts, hi=%s; LODs:" % [kind, int(sf.get("index_count", 0)) / 3, vc, str(Quality.high())]
			for l in sf.get("lods", []): row += " %d (err %.4f)" % [(l.index_data as PackedByteArray).size() / (2 if vc < 65536 else 4) / 3, l.edge_length]
			print("LODPROBE ", row)
	if "voice_dropin" in args: _voice_dropin_tests()
	if "sim" in args: _sims()
	if "bench" in args: _bench()
	print("\n== %d passed, %d failed ==" % [passes, failures])
	for w in _worlds: w.dispose()
	_worlds.clear()
	for a in args:
		if a.begins_with("--json="):
			var f := FileAccess.open(a.substr(7), FileAccess.WRITE)
			f.store_string(JSON.stringify(report, "  "))
			f.close()
	get_tree().quit(1 if failures > 0 else 0)

var _verbose := OS.get_environment("TESTS_VERBOSE") != ""        # print passing checks too
func ok(cond: bool, what: String) -> void:
	if cond:
		passes += 1
		if _verbose: print("  ok: " + what)
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
	# regression (cycle 3): a screen-wide ultimate must not recharge itself
	var wu := _world({"mode": "rift", "hero": 2, "gr": 1, "seed": 4})
	for k in 200: wu.spawn_foe(Content.E.GRUNT, Vector2(randf_range(-300, 300), randf_range(-200, 200)), 0)
	wu.grid.build(wu.sw)
	wu.ult = 100.0
	wu.use_ult()
	for k in 60: wu.step(1.0 / 60.0)
	ok(wu.ult < 1.0, "ultimate does not refund itself (charge after cast %.1f)" % wu.ult)
	wu.dispose()
	# breakables shatter under skills and pay out
	var wb := _world({"mode": "campaign", "hero": 2, "seed": 21})
	wb.breakables.append({"pos": Vector2(40, 0), "kind": 0, "r": 10.0})
	wb.breakables.append({"pos": Vector2(900, 0), "kind": 1, "r": 13.0})
	wb.nova_at(Vector2.ZERO, 60.0, 1.0, 0, Color.WHITE)
	ok(wb.breakables.size() == 1 and wb.broken.size() == 1, "nova shatters only breakables in reach")
	wb.dispose()
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

# ================================================================= terrain (elevation pass)
func _terrain_tests() -> void:
	print("== terrain")
	for st in Content.TERRAIN.size():
		var a := Terrain.new(st, 4242, Content.TERRAIN[st])
		var b := Terrain.new(st, 4242, Content.TERRAIN[st])
		var same := true
		for k in 50:
			var p := Vector2(k * 137.0 - 3000.0, k * 91.0 - 2000.0)
			if not is_equal_approx(a.height(p), b.height(p)) or a.type_at(p) != b.type_at(p): same = false
		ok(same, "stage %d terrain is deterministic for a seed" % st)
		ok(a.passable(Vector2.ZERO) and a.passable(Vector2(200, 0)) and a.passable(Vector2(0, -200)), "stage %d spawn plateau is walkable" % st)
		var sv := a.survey(Vector2(1800, -1200), 1400.0)
		ok(sv.land + sv.shallow > 0.7 and sv.cliff < 0.12, "stage %d leaves most ground walkable (%s)" % [st, str(sv)])
		# a long random walk never ends up inside a cliff or deep liquid
		var p := Vector2.ZERO
		var bad := 0
		var rng := RandomNumberGenerator.new(); rng.seed = st
		var dir := Vector2.RIGHT
		for i in 3000:
			if i % 40 == 0: dir = Vector2.from_angle(rng.randf() * TAU)
			p = a.move(p, p + dir * 9.0)
			if not a.passable(p): bad += 1
		ok(bad == 0, "stage %d movement slides along cliffs and shores (%d bad steps)" % [st, bad])
	# ice: freezing deep water makes it walkable, and it thaws
	var T := Terrain.new(0, 77, Content.TERRAIN[0])
	var deep := Vector2.INF
	for r in range(300, 4000, 32):
		for k in 16:
			var q := Vector2.from_angle(TAU * k / 16.0) * r
			if T.type_at(q) == Terrain.DEEP: deep = q; break
		if deep != Vector2.INF: break
	ok(deep != Vector2.INF and not T.passable(deep), "deep water blocks movement")
	T.freeze(deep, 40.0, 1.0)
	ok(T.passable(deep), "frozen water can be walked on")
	for i in 70: T.step(1.0 / 60.0)
	ok(not T.passable(deep), "ice thaws")
	ok(T.electrify(deep, 40.0, 1.0) > 0 and T.is_charged(deep), "lightning charges water")
	var L := Terrain.new(3, 77, Content.TERRAIN[3])
	ok(L.freeze(Vector2(5000, 5000), 300.0, 5.0) == 0, "the void never freezes")
	# a run: spawns land on walkable ground and foes never stand in a wall after moving
	var w := _world({"mode": "campaign", "stage": 1, "hero": 0, "seed": 9})
	var spawn_ok := true
	for i in 200:
		if not w.terrain.passable(w.ring_point()): spawn_ok = false
	ok(spawn_ok, "spawn ring points are walkable")
	for i in 120: w.spawn_foe(Content.E.GRUNT)
	var stuck := 0
	for f in 300:
		w.in_move = Vector2.from_angle(f * 0.05)
		w.step(1.0 / 60.0)
	for i in w.sw.n:
		if (w.sw.flags[i] & (Swarm.F_BOSS | Swarm.F_HERALD)) == 0 and not w.terrain.passable(w.sw.pos[i]): stuck += 1
	ok(stuck <= 2, "foes stay on walkable ground (%d inside walls)" % stuck)
	ok(w.terrain.passable(w.pp), "the hero stays on walkable ground")

# ================================================================= Shard Web and Torment
func _meta_tests() -> void:
	print("== shard web / torment")
	var taken := ["start"]
	ok(Content.passive_can_take("m1", taken) and not Content.passive_can_take("m6", taken), "only nodes touching the web can be taken")
	ok(not Content.passive_can_take("start", taken), "a node is taken once")
	var all_linked := true
	for id in Content.PASSIVES:
		for l in Content.PASSIVES[id].links:
			if not Content.PASSIVES.has(l): all_linked = false
	ok(all_linked, "every web link points at a real node")
	# every node is reachable from the centre
	var seen := ["start"]
	var grow := true
	while grow:
		grow = false
		for id in Content.PASSIVES:
			if not seen.has(id) and Content.passive_can_take(id, seen): seen.append(id); grow = true
	ok(seen.size() == Content.PASSIVES.size(), "the whole web is reachable (%d/%d)" % [seen.size(), Content.PASSIVES.size()])
	var keep: Array = Save.data.passives
	Save.data.passives = ["start"]
	var w0 := _world({"mode": "campaign", "stage": 0, "hero": 0, "seed": 3})
	Save.data.passives = ["start", "m1", "m3", "f1"]
	var w1 := _world({"mode": "campaign", "stage": 0, "hero": 0, "seed": 3})
	ok(w1.stats.value("damage", 10.0) > w0.stats.value("damage", 10.0) * 1.07, "passives raise damage")
	ok(w1.max_hp >= w0.max_hp + 14.0, "passives raise life")
	Save.data.passives = keep
	var t0 := _world({"mode": "campaign", "stage": 1, "hero": 0, "seed": 3, "torment": 0})
	var t3 := _world({"mode": "campaign", "stage": 1, "hero": 0, "seed": 3, "torment": 3})
	ok(is_equal_approx(t3.hp_mult() / t0.hp_mult(), float(Content.TORMENT[3].hp)), "torment scales foe life")
	ok(t3.stats.value("item_quantity", 1.0) > t0.stats.value("item_quantity", 1.0), "torment raises loot")
	var tr := _world({"mode": "rift", "hero": 0, "seed": 3, "gr": 4, "torment": 3})
	ok(tr.torment == 0, "rifts ignore torment (they scale by level)")
	var tmax0: int = Save.data.torment_max
	var e0: int = Save.data.echoes
	Save.data.torment_max = 0
	t0.kills = 600
	t0.end_run(true)
	ok(Save.data.torment_max == 1, "a win unlocks the next torment")
	ok(Save.data.echoes - e0 == t0.echoes_run and t0.echoes_run == 600 / 250 + 2, "echoes: kills / 250 + 2 for a win (%d)" % t0.echoes_run)
	Save.data.torment_max = tmax0
	Save.data.echoes = e0

func _sky_tests() -> void:
	print("== sky, lantern and the Whisperer")
	# Moon: 2026-11-09 07:02 UTC was a new moon, 2026-11-24 14:53 UTC a full moon
	var nm := Moon.phase_at(1794207720.0)
	ok(nm < 0.03 or nm > 0.97, "moon: known new moon reads as new (%.3f)" % nm)
	var fm := Moon.phase_at(1795532000.0)
	ok(absf(fm - 0.5) < 0.03 and Moon.phase_id(fm) == "full", "moon: known full moon reads as full (%.3f)" % fm)
	ok(Moon.phase_name(0.25) == "First Quarter" and Moon.phase_name(0.85) == "Waning Crescent", "moon: phase names")
	ok(Moon.omen_id([10, 31]) == "veil" and Moon.omen_id([1, 2]) == "longnight" and Moon.omen_id([12, 25]) == "longnight" and Moon.omen_id([3, 3]) == "", "calendar omens, incl. across the new year")
	var wn := _world({"mode": "campaign", "hero": 0, "seed": 4, "moon": 0.0})
	var wf := _world({"mode": "campaign", "hero": 0, "seed": 4, "moon": 0.5})
	var w0 := _world({"mode": "campaign", "hero": 0, "seed": 4})
	ok(wn.stats.value("item_rarity", 1.0) > w0.stats.value("item_rarity", 1.0), "new moon: rarer loot")
	ok(wn.stats.value("dark_rate", 1.0) > 1.0 and wf.stats.value("dark_rate", 1.0) < 1.0, "new moon darkens faster, full moon slower")
	ok(Moon.eclipse_weight(0.0) > Moon.eclipse_weight(0.5) and wf.spawn_rate() > w0.spawn_rate(), "new moon: more eclipses; full moon: thicker packs")
	# the lantern
	for i in 120: w0.step(1.0 / 20.0)
	ok(w0.light < 1.0, "the light fades over time (%.2f)" % w0.light)
	w0.light = 0.1
	w0.step(0.05)
	ok(w0.engulfed() > 0.0 and w0.gloom() > 0.8, "below the line the hero is engulfed")
	var d_lit := w0.dmg_mult()
	w0.light = 0.0
	ok(w0.dmg_mult() > d_lit * 1.05, "foes hit harder in the dark")
	var i0 := w0.spawn_foe(Content.E.GRUNT, w0.pp + Vector2(60, 0), 0)
	var before := w0.light
	w0.sw.take(i0, 1e9)
	w0._reap()
	ok(w0.light > before, "kills relight the lantern")
	w0.light = 0.05
	w0.relight(1.0)
	ok(is_equal_approx(w0.light, 1.0), "shrines refill it")
	# the Whisperer
	var ww := _world({"mode": "campaign", "hero": 0, "seed": 9})
	ww.offer_whisper()
	ok(ww.whisper_offer.size() == 2 and ww.whisper_offer[0] != ww.whisper_offer[1], "the Whisperer offers two different bargains")
	var hp0 := ww.max_hp
	ww.accept_bargain("glass_crown")
	ok(ww.has_bargain("glass_crown") and ww.max_hp < hp0 * 0.65 and ww.stats.value("crit_chance", 0.0) >= 0.25, "Glass Crown: crit up, life down")
	ok(ww.whisper_offer.is_empty(), "accepting closes the offer")
	ww.accept_bargain("long_night")
	ww.light = 1.0
	ww.step(0.05)
	ok(ww.light <= 0.5, "The Long Night caps the light at half")
	ww.light = 0.0
	ww.step(0.05)
	ok(ww.stats.value("damage", 1.0) > 1.6, "and pays in damage in the dark")
	ww.accept_bargain("blood_price")
	ww.hp = ww.max_hp * 0.5
	ww.flasks[0].c = 60.0
	var hot := ww.heal_hot
	ww.use_flask(0)
	ok(ww.heal_hot == hot and ww.flasks[0].c < 60.0, "Blood Price: the life flask no longer heals")
	ww.accept_bargain("")
	ok(ww.bargains.size() == 3, "refusing takes nothing")
	var e0: int = Save.data.echoes
	ww.kills = 0
	ww.end_run(false)
	ok(ww.echoes_run == 3, "each bargain pays an Echo (%d)" % ww.echoes_run)
	Save.data.echoes = e0
	var wp := _world({"mode": "campaign", "hero": 0, "seed": 9})
	wp.director.whisper_t = 0.0
	wp.step(0.05)
	var found := false
	for o in wp.director.objects:
		if o.kind == "whisper":
			found = true
			wp.pp = o.pos
	ok(found, "the Director places the Whisperer")
	wp.step(0.05)
	ok(wp.whisper_offer.size() == 2, "touching it opens the offer")
	var pin := _world({"mode": "pinnacle", "hero": 0, "seed": 9})
	pin.director.whisper_t = 0.0
	pin.step(0.05)
	ok(pin.director.objects.filter(func(o): return o.kind == "whisper").is_empty() and pin.light == 1.0, "no Whisperer and no dark in the pinnacle")

func _fusion_tests() -> void:
	print("== weapon fusion")
	var w := _world({"mode": "campaign", "hero": 0, "seed": 21})
	for id in ["bolt", "nova", "storm", "orbit"]:
		w.weapons[id] = {"lv": 5, "evo": true, "t": 0.0, "gems": []}
		w.wlocal[id] = Stats.new()
	var ch := w.make_choices()
	var fuses := ch.filter(func(c): return c.kind == "fuse")
	ok(not fuses.is_empty(), "two evolved weapons offer a fusion")
	var c := {"kind": "fuse", "id": Content.fusion_key("nova", "bolt"), "a": "bolt", "b": "nova"}
	ok(c.id == "bolt+nova" and Content.FUSIONS.has(c.id), "fusion keys are sorted pairs")
	var em0 := w.elmask("bolt")
	w.pending = 1
	w.apply_choice(c)
	ok(w.fused("bolt") == "nova" and w.fused("nova") == "bolt", "fusing links both weapons")
	ok(w.elmask("bolt") & (1 << Content.El.FIRE) != 0 and em0 & (1 << Content.El.FIRE) == 0, "a fused weapon carries its partner's element")
	ok(w.wlocal["bolt"].value("damage", 1.0) > 1.2, "fused weapons deal 25% more damage")
	for c2 in w.make_choices():
		ok(not (c2.kind == "fuse" and (c2.a in ["bolt", "nova"] or c2.b in ["bolt", "nova"])), "a fused weapon is never offered again")
	# Glacial Nova: a pulse with foes nearby adds a ring of bolts
	for k in 6: w.spawn_foe(Content.E.GRUNT, w.pp + Vector2(60, 0).rotated(k), 0)
	w.grid.build(w.sw)
	var n0 := w.projs.size()
	w._nova(Content.WEAPONS.nova.evo_s, 1.0)
	ok(w.projs.size() >= n0 + 8, "Glacial Nova hurls eight frost bolts (%d)" % (w.projs.size() - n0))
	# all six fusions run for a few seconds without errors
	for key in Content.FUSIONS:
		var ww := _world({"mode": "campaign", "hero": 0, "seed": 22})
		var ab: PackedStringArray = key.split("+")
		for id in ab:
			ww.weapons[id] = {"lv": 5, "evo": true, "t": 0.0, "gems": []}
			ww.wlocal[id] = Stats.new()
		ww.apply_choice({"kind": "fuse", "id": key, "a": ab[0], "b": ab[1]})
		ww.stats.set_source("t", [["max_hp", "add", 1e6]])
		var k0 := ww.kills
		for f in 300:
			if f % 10 == 0 and ww.sw.n < 60: ww.spawn_foe(Content.E.GRUNT, ww.pp + Vector2(randf_range(-150, 150), randf_range(-150, 150)), 0)
			ww.step(1.0 / 30.0)
		ok(ww.kills > k0 and not ww.over, "%s fights (%d kills)" % [Content.FUSIONS[key].name, ww.kills - k0])
		ww.dispose()

func _surface_tests() -> void:
	print("== surfaces")
	var w := _world({"mode": "campaign", "hero": 0, "seed": 31})
	var T := w.terrain
	var at := T.nearest_passable(w.pp + Vector2(120, 0))
	ok(T.pour(at, 40.0, Terrain.Surf.OIL, 10.0) > 0 and T.surf_at(at) == Terrain.Surf.OIL, "oil pools on dry ground")
	var i := w.spawn_foe(Content.E.BRUTE, at, 0, 0, 50.0)
	w.grid.build(w.sw)
	w.apply_elements(i, 1 << Content.El.FIRE, 0)
	ok(T.surf_at(at) == Terrain.Surf.FIRE, "fire ignites oil")
	T.pour(at + Vector2(64, 0), 24.0, Terrain.Surf.OIL, 10.0)
	T.pour(at + Vector2(32, 0), 24.0, Terrain.Surf.OIL, 10.0)
	for k in 20: T.step(0.13)
	ok(T.surf_at(at + Vector2(64, 0)) == Terrain.Surf.FIRE, "fire runs along connected oil")
	var hp0 := w.sw.hp[w.sw.index_of(w.sw.uid[i])]
	w._surf_t = 1.0
	w._step_surfaces(0.05)
	ok(w.sw.hp[i] < hp0, "foes standing in burning oil take damage")
	# poison: fire detonates, cold crystallises
	var at2 := T.nearest_passable(w.pp + Vector2(-200, 80))
	T.pour(at2, 30.0, Terrain.Surf.POISON, 10.0)
	var j := w.spawn_foe(Content.E.BRUTE, at2, 0, 0, 50.0)
	w.grid.build(w.sw)
	w.apply_elements(j, 1 << Content.El.COLD, 0)
	ok(T.surf_at(at2) == Terrain.Surf.SPIKES, "cold crystallises poison into spikes")
	var at3 := T.nearest_passable(w.pp + Vector2(0, -260))
	T.pour(at3, 30.0, Terrain.Surf.POISON, 10.0)
	var k3 := w.spawn_foe(Content.E.BRUTE, at3, 0, 0, 50.0)
	w.grid.build(w.sw)
	var h3 := w.sw.hp[k3]
	w.apply_elements(k3, 1 << Content.El.FIRE, 0)
	ok(T.surf_at(at3) == Terrain.Surf.NONE and w.sw.hp[k3] < h3 and int(w.metrics.terrain.get("blast", 0)) == 1, "fire detonates poison (and spends the pool)")
	# blood conducts lightning to every foe standing in it
	var at4 := T.nearest_passable(w.pp + Vector2(260, 200))
	T.pour(at4, 48.0, Terrain.Surf.BLOOD, 10.0)
	var a := w.spawn_foe(Content.E.BRUTE, at4, 0, 0, 50.0)
	var b := w.spawn_foe(Content.E.BRUTE, at4 + Vector2(24, 0), 0, 0, 50.0)
	w.grid.build(w.sw)
	var hb := w.sw.hp[b]
	w.apply_elements(a, 1 << Content.El.LIGHT, 0)
	ok(w.sw.hp[b] < hb and int(w.metrics.terrain.get("conduct", 0)) == 1, "lightning arcs through blood")
	# pools fade
	for k in 100: T.step(0.2)
	ok(T.surf.is_empty(), "pools dry up")
	# sources: a spitter dies into a poison pool; Act II seeps open on their own
	var s := w.spawn_foe(Content.E.SPITTER, T.nearest_passable(w.pp + Vector2(-100, -100)), 0)
	var sp := w.sw.pos[s]
	w.sw.take(s, 1e9)
	w._reap()
	ok(T.surf_at(sp) == Terrain.Surf.POISON, "spitters burst into poison")
	var w2 := _world({"mode": "campaign", "hero": 0, "seed": 32, "stage": 1})
	for k in 400: w2._step_surfaces(0.05)
	ok(not w2.terrain.surf.is_empty(), "Act II's tar seeps open by themselves")

func _hoard_tests() -> void:
	print("== bank or push")
	var w := _world({"mode": "campaign", "hero": 0, "seed": 41})
	for k in 5: w.spawn_foe(Content.E.GRUNT, w.pp + Vector2(80, 0), 0)
	for k in 5: w.sw.take(k, 1e9)
	w._reap()
	ok(w.hoard >= 5.0, "kills fill the hoard (%d)" % int(w.hoard))
	w.hoard = 400.0
	w.gate_passed()
	w.gate_passed()
	ok(is_equal_approx(w.hoard_mult, 2.0), "walking past gates raises the multiplier")
	for k in 4: w.gate_passed()
	ok(is_equal_approx(w.hoard_mult, 3.0), "the multiplier caps at x3")
	var g0 := w.gold
	var picks0 := w.picks.size()
	var r := w.bank_hoard(w.pp)
	ok(is_equal_approx(r.value, 1200.0) and w.gold > g0 and w.hoard == 0.0 and w.hoard_mult == 1.0, "banking pays gold and resets")
	ok(r.echoes == 4 and w.hoard_echoes == 4, "banking pays Echoes (%d)" % r.echoes)
	ok(w.picks.size() > picks0, "rare items spill out of the gate")
	# the Director opens gates; touching one banks, ignoring one pushes
	var w2 := _world({"mode": "campaign", "hero": 0, "seed": 42})
	w2.director.gate_t = 0.0
	w2.director.whisper_t = 1e9
	w2.hoard = 100.0
	w2.step(0.05)
	var gate: Dictionary = {}
	for o in w2.director.objects:
		if o.kind == "gate": gate = o
	ok(not gate.is_empty(), "a Rift Gate opens")
	w2.pp = gate.pos
	w2.step(0.05)
	ok(w2.hoard == 0.0 and w2.hoard_banked >= 100.0, "stepping into the gate banks the hoard")
	var w3 := _world({"mode": "campaign", "hero": 0, "seed": 43})
	w3.director.gate_t = 0.0
	w3.step(0.05)
	for o in w3.director.objects: o.life = 0.01
	w3.step(0.05)
	ok(w3.hoard_mult == 1.5, "an unused gate closes and pushes the multiplier")
	# death loses the unbanked hoard; a win banks it
	var w4 := _world({"mode": "campaign", "hero": 0, "seed": 44})
	w4.hoard = 300.0
	w4.hoard_mult = 2.0
	var e0: int = Save.data.echoes
	w4.end_run(false)
	ok(w4.hoard_lost == 600.0 and w4.hoard_echoes == 0, "death loses the unbanked hoard")
	var w5 := _world({"mode": "campaign", "hero": 0, "seed": 45})
	w5.hoard = 300.0
	w5.end_run(true)
	ok(w5.hoard_banked == 300.0 and w5.hoard_echoes == 1, "a win banks what you carry")
	Save.data.echoes = e0

func _prophecy_tests() -> void:
	print("== prophecies")
	var saved: Dictionary = Save.data.prophecy.duplicate(true)
	Save.data.prophecy = {"offers": [], "active": {}, "done": 0}
	var offers := Save.prophecy_offers()
	ok(offers.size() == 3 and offers[0][1].size() == 3, "three prophecies on offer, three rewards each")
	ok(offers[0][0] != offers[1][0] and offers[1][0] != offers[2][0], "the offers differ")
	Save.data.prophecy.active = {"id": "reaper", "reward": "chaos"}
	var w := _world({"mode": "campaign", "hero": 0, "seed": 51})
	ok(w.prophecy.id == "reaper", "a run carries the active prophecy")
	var ch0 := int(Save.data.currency.chaos)
	w.kills = 599
	w._step_prophecy(1.0)
	ok(not w.prophecy_done, "not yet (599/600)")
	w.kills = 600
	w._proph_t = 0.0
	w._step_prophecy(1.0)
	ok(w.prophecy_done and int(Save.data.currency.chaos) == ch0 + 4, "fulfilled: the chosen reward pays out")
	ok(Save.data.prophecy.active.is_empty() and int(Save.data.prophecy.done) == 1, "and leaves the profile")
	# item rewards drop at the hero's feet
	var w2 := _world({"mode": "campaign", "hero": 0, "seed": 52, "prophecy": {"id": "alloy", "reward": "rare3"}})
	var p0 := w2.picks.size()
	w2.metrics.fusions = 1
	w2._step_prophecy(1.0)
	ok(w2.picks.size() >= p0 + 3, "three rare items drop")
	# objectives read from the run
	var w3 := _world({"mode": "campaign", "hero": 0, "seed": 53, "prophecy": {"id": "pyre", "reward": "gold"}})
	var e := w3.spawn_foe(Content.E.BRUTE, w3.pp + Vector2(90, 0), 1)
	w3.sw.apply_status(e, Content.El.FIRE, 3.0, 4.0)
	w3.sw.take(e, 1e9)
	w3._reap()
	ok(w3.prophecy_progress().x == 1.0, "a burning elite counts for The Pyre")
	ok(_world({"mode": "pinnacle", "hero": 0, "seed": 54, "prophecy": {"id": "reaper", "reward": "gold"}}).prophecy.is_empty(), "no prophecies in the pinnacle")
	Save.data.prophecy = saved

func _daily_tests() -> void:
	print("== daily rift")
	var s := Daily.seed_for_date("20261112")
	ok(s == Daily.seed_for_date("20261112") and s != Daily.seed_for_date("20261113"), "one seed per day")
	var code := Daily.code_for(s)
	ok(code.begins_with("SHARD-") and code.length() == 10 and Daily.seed_from_code(code) == s, "codes round-trip (%s)" % code)
	ok(Daily.seed_from_code(code.to_lower().replace("shard-", " ")) == s, "codes forgive case, spaces and a missing prefix")
	ok(Daily.seed_from_code("SHARD-0O1I") == -1 and Daily.seed_from_code("nope") == -1, "bad codes are refused")
	var c1 := Daily.config(s)
	var c2 := Daily.config(s)
	ok(c1.stage == c2.stage and c1.hero == c2.hero and c1.mods == c2.mods and c1.mods.size() == 2 and c1.mods[0] != c1.mods[1], "a code always means the same rift")
	# no gear, passives or legendaries
	var eq0: Dictionary = Save.data.equipped.duplicate(true)
	Save.data.equipped.weapon = {"slot": "weapon", "rarity": 3, "base": "", "mods": [["damage", "inc", 5.0]], "leg": "phoenix"}
	var cfg := c1.duplicate()
	cfg["hero"] = int(c1.hero)
	var w := _world(cfg)
	ok(w.daily and w.map_mods == c1.mods and w.stats.value("damage", 1.0) < 2.0 and not w.has_leg("phoenix"), "the rift ignores gear and legendaries")
	Save.data.equipped = eq0
	# score and best
	var dsv: Dictionary = Save.data.daily.duplicate(true)
	Save.data.daily = {"best": {}, "claimed": ""}
	w.kills = 300
	w.t = 100.0
	w.daily_date = "20261112"
	var cl0: Array = Save.data.cleared.duplicate()
	w.end_run(true)
	ok(w.daily_score == 300 + 200 + 1500 and w.daily_best and int(Save.data.daily.best[w.daily_code]) == w.daily_score, "score = kills + 2/s + 1500 for a win (%d)" % w.daily_score)
	ok(Save.data.daily.claimed == "20261112" and w.hoard_echoes >= 3, "the first clear of the day pays 3 Echoes")
	ok(Save.data.cleared == cl0, "a daily win leaves campaign progress alone")
	var w2 := _world(cfg)
	w2.kills = 10
	w2.end_run(false)
	ok(not w2.daily_best and int(Save.data.daily.best[w.daily_code]) == w.daily_score, "a worse run keeps the best")
	Save.data.daily = dsv

func _alpha_weapon_tests() -> void:
	print("== alpha weapons, pacing, champions, unlocks")
	ok(Content.WEAPON_IDS.size() >= 12, "at least twelve weapons")
	for id in ["lance", "mine", "glaive", "wisp", "arc", "aura", "cleave", "meteor", "totem"]:
		var w := _world({"mode": "rift", "hero": 0, "gr": 1, "seed": 11})
		w.weapons.clear()
		w.weapons[id] = {"lv": 5, "evo": true, "t": 0.0, "gems": []}
		w.wlocal[id] = Stats.new()
		w.stats.set_source("t", [["max_hp", "add", 1e6]])
		w.hp = 1e6
		for k in 40: w.spawn_foe(Content.E.GRUNT, w.pp + Vector2(cos(k * 0.7), sin(k * 0.7)) * (50.0 + k * 3.0), 0, 0, 0.2)
		var k0 := w.kills
		for f in 360: w.step(1.0 / 60.0)
		ok(w.kills > k0, "%s kills foes on its own (%d kills in 6 s)" % [Content.WEAPONS[id].name, w.kills - k0])
		ok(Content.PERKS.has(Content.WEAPONS[id].pair) and Content.WEAPONS[id].lv.size() == 5, "%s has five levels and an evolution perk" % id)
	var c := _world({"mode": "campaign", "hero": 0, "seed": 3})
	ok(absf(c.rt() - 0.0) < 0.01 and c.pace < 1.0, "campaign acts are paced")
	c.t = Content.STAGE_TIME
	ok(absf(c.rt() - Content.PACE_REF) < 0.01, "the end of an act sits where the old 150 s ramps ended")
	var r := _world({"mode": "rift", "hero": 0, "gr": 1, "seed": 3})
	ok(r.pace == 1.0 and r.xp_scale == 1.0, "rifts keep real time")
	var m := _world({"mode": "campaign", "hero": 0, "seed": 4})
	m.stats.set_source("t", [["max_hp", "add", 1e6]]); m.hp = 1e6
	m.t = Content.STAGE_TIME / 3.0 - 0.1
	for f in 30: m.step(1.0 / 60.0)
	ok(m.champions_met == 1 and m.champ_uids.size() == 1, "a Rift Champion arrives at a third of the act")
	var ci := -1
	for i in m.sw.n:
		if m.sw.uid[i] == m.champ_uids[0]: ci = i
	ok(ci >= 0 and (m.sw.flags[ci] & Swarm.F_ELITE) != 0 and m.sw.mhp[ci] > 1000.0, "the champion is a giant elite")
	m.hit(ci, 1e9, 0, Vector2.ZERO, 0.0, 0)
	for f in 5: m.step(1.0 / 60.0)
	ok(m.champions_slain == 1, "killing it is counted")
	# unlock track
	var keep = Save.data.duplicate(true)
	Save.data = Save.defaults()
	ok(Save.weapon_pool().size() == 4, "a fresh profile offers the four starting weapons")
	Save.data.stats.kills = 200
	ok(Save.check_unlocks() == ["lance"] and Save.weapon_pool().has("lance"), "150 kills unlock the Storm Lance")
	ok(Save.check_unlocks().is_empty(), "an unlock is granted once")
	Save.data.cleared[0] = true
	ok(Save.check_unlocks().has("glaive"), "clearing Act I unlocks the Frost Glaive")
	var w2 := _world({"mode": "campaign", "hero": 0, "seed": 5})
	var offered := {}
	for k in 60:
		w2.lvl = 3
		for ch in w2.make_choices():
			if ch.kind == "w": offered[ch.id] = true
	ok(offered.has("lance") and not offered.has("meteor"), "level-ups offer unlocked weapons only")
	ok(Content.fusion_def(Content.fusion_key("lance", "meteor")).name != "", "any two weapons have a fusion")
	Save.data = keep

func _v7_tests() -> void:
	print("== roll curve, action buffers")
	var w := _world({"mode": "rift", "hero": 0, "gr": 1, "seed": 21})
	w.stats.set_source("t", [["max_hp", "add", 1e6]]); w.hp = 1e6
	for f in 30: w.step(1.0 / 120.0)
	w.in_move = Vector2.RIGHT
	var spd := w.stats.value("move_speed", float(Content.HEROES[0].spd))
	var p0 := w.pp
	w.in_roll = true
	var half := 0.0
	var steps := 0
	w.step(1.0 / 240.0)
	while w.roll_t > 0.0 and steps < 400:
		w.step(1.0 / 240.0)
		steps += 1
		if half == 0.0 and w.roll_t <= World.ROLL_TIME * 0.5: half = w.pp.distance_to(p0)
	var dist := w.pp.distance_to(p0)
	var flat := spd * 2.6 * World.ROLL_TIME
	ok(absf(dist - flat) / flat < 0.08, "a roll still covers the old distance (%.0f vs %.0f)" % [dist, flat])
	ok(half / dist > 0.56, "most of it in the first half (%.0f%%)" % (100.0 * half / dist))
	var u := _world({"mode": "rift", "hero": 0, "gr": 1, "seed": 22})
	u.stats.set_source("t", [["max_hp", "add", 1e6]]); u.hp = 1e6
	for f in 10: u.step(1.0 / 60.0)
	u.ult = 99.0
	u.in_ult = true
	u.step(1.0 / 60.0)
	ok(u.ult_buffer > 0.0 and u.ult >= 99.0, "an early ultimate press is held, not dropped")
	u.ult = 100.0
	u.step(1.0 / 60.0)
	ok(u.ult < 50.0 and u.ult_buffer == 0.0, "and fires as soon as the charge is full")
	u.ult = 20.0
	u.in_ult = true
	for f in 12: u.step(1.0 / 60.0)
	ok(u.ult_buffer <= 0.0, "the buffer expires after 0.12 s")
	u.ult = 100.0
	u.step(1.0 / 60.0)
	ok(u.ult >= 100.0, "an expired press does not fire later")
	var h := _world({"mode": "rift", "hero": 0, "gr": 1, "seed": 23})
	for f in 10: h.step(1.0 / 60.0)
	h.hitstop = 0.1
	h.in_roll = true
	for f in 3: h.step(1.0 / 60.0)
	ok(h.in_roll, "a press during a hit-stop stays latched")
	for f in 8: h.step(1.0 / 60.0)
	ok(h.roll_t > 0.0 or h.roll_cd > 0.0, "and rolls when the hit-stop ends")
	ok(Sfx.CRITICAL.has("boss") and Sfx.CRITICAL.has("level") and not Sfx.CRITICAL.has("impact"), "boss and level-up cues are exempt from the per-frame sound cap")

func _gate_p01_tests() -> void:
	print("== fixed clock, countdown timers, acceleration")
	var fc := FixedStep.new()
	var total := 0
	for f in 600: total += fc.advance(1.0 / 60.0 + (0.0015 if f % 2 == 0 else -0.0015))      # a jittery 60 Hz display
	ok(total >= 598 and total <= 601, "a jittery 60 Hz display gets one tick per frame (%d ticks in 600 frames)" % total)
	var fc2 := FixedStep.new()
	var per: Array[int] = []
	for f in 60: per.append(fc2.advance(1.0 / 30.0))
	ok(per.min() == 2 and per.max() == 2, "30 fps runs exactly two ticks per frame")
	var fc3 := FixedStep.new()
	ok(fc3.advance(0.5) == FixedStep.MAX_STEPS and fc3.acc == 0.0, "a 500 ms hitch runs two ticks and drops the backlog (no spiral)")
	ok(fc3.advance(0.0) == 0, "and does not catch up afterwards")
	# arcane orbs: same cadence at 60 Hz and when dt doubles. Props stay on (0.10.0: substepped, guarded
	# movement); only the elite's own orbs are counted (violet, 6 s), never the wave spitters' shots, whose
	# paths round the props differ by dt and are not what this measures. A pooled shot re-armed as an orb
	# counts as new: its life jumps up.
	var counts: Array[int] = []
	for dt in [1.0 / 60.0, 1.0 / 30.0]:
		var w := _world({"mode": "rift", "hero": 0, "gr": 1, "seed": 31})
		w.stats.set_source("t", [["max_hp", "add", 1e6]]); w.hp = 1e6
		w.weapons.clear()
		var i := w.spawn_foe(Content.E.BRUTE, w.pp + Vector2(300, 0), 1, 0, 50.0)
		w.sw.affix[i] = Content.Aff.ARCANE
		var shots := 0
		var life := {}
		var steps := int(35.0 / dt)
		for k in steps:
			w.step(dt)
			var now := {}
			for e: World.Proj in w.eshots:
				if e.col == Color("d070ff") and (not life.has(e) or e.life > float(life[e]) + 1e-4): shots += 1
				now[e] = e.life
			life = now
		counts.append(shots)
	ok(counts[0] == counts[1] and counts[0] >= 8, "an arcane elite fires on a fixed cadence at any dt (%s orbs in 35 s)" % str(counts))
	# thunderdome works without a conduit pylon
	var d := _world({"mode": "rift", "hero": 3, "gr": 1, "seed": 32})
	d.stats.set_source("t", [["max_hp", "add", 1e6]]); d.hp = 1e6
	d.weapons.clear()
	for k in 30: d.spawn_foe(Content.E.GRUNT, d.pp + Vector2(cos(k), sin(k)) * 150.0, 0, 0, 50.0)
	d.buffs.add("thunderdome")
	var zaps := 0
	for k in 60:
		d.step(1.0 / 60.0)
		for f in d.fx: if f.k == "zap" and f.t <= 1.0 / 60.0 + 0.0001: zaps += 1        # struck this tick
	ok(zaps >= 8 and not d.buffs.has("conduit"), "the Stormwright's Thunderdome strikes without a Conduit pylon (%d strikes in 1 s)" % zaps)
	# acceleration: crisp, not instant
	var m := _world({"mode": "rift", "hero": 0, "gr": 1, "seed": 33})
	m.stats.set_source("t", [["max_hp", "add", 1e6]]); m.hp = 1e6
	for k in 5: m.step(1.0 / 60.0)
	var spd := m.stats.value("move_speed", float(Content.HEROES[0].spd))
	m.in_move = Vector2.RIGHT
	m.step(1.0 / 60.0)
	var v1 := m.vel.length()
	for k in 3: m.step(1.0 / 60.0)
	var v4 := m.vel.length()
	ok(v1 > spd * 0.2 and v1 < spd * 0.4 and v4 >= spd * 0.99, "walking reaches full speed in 0.06 s (%.0f%% after one tick)" % (100.0 * v1 / spd))
	m.in_move = Vector2.ZERO
	for k in 3: m.step(1.0 / 60.0)
	ok(m.vel.length() < 1.0, "and stops within 0.05 s")

func _tyrant_fsm_tests() -> void:
	print("== tyrant state machine")
	var w := _world({"mode": "campaign", "hero": 0, "stage": 4, "seed": 41})
	w.terrain.props_on = false                       # the state machine alone: the kiting hero is teleported
	w.stats.set_source("t", [["max_hp", "add", 1e7], ["regen", "add", 1e6]]); w.hp = 1e7
	w.weapons.clear()
	w.bosses.spawn_stage_boss(false)
	var u: int = w.bosses.stage_uids[0]
	var seen := {}
	var attacks: Array[String] = []
	var states := {}
	var exposed_ok := true
	var moved_in_windup := false
	var prev_state := -1
	var prev_pos := Vector2.ZERO
	for k in 60 * 60:
		if k % 150 == 0:                             # a kiting hero: every 2.5 s back off to a random range
			var bi := w.sw.index_of(u)
			if bi >= 0: w.pp = w.sw.pos[bi] + Vector2.from_angle(w.rng.randf() * TAU) * w.rng.randf_range(80.0, 380.0)
		w.step(1.0 / 60.0)
		var st: Dictionary = w.bosses.bstate[u]
		var i := w.sw.index_of(u)
		if i < 0: break
		var s := int(st.get("s", -1))
		states[s] = true
		if s == Bosses.WINDUP and prev_state == Bosses.WINDUP and w.sw.pos[i].distance_to(prev_pos) > 3.0: moved_in_windup = true
		if s == Bosses.WINDUP and prev_state != Bosses.WINDUP: attacks.append(String(st.atk))
		if bool(st.exposed) and s != Bosses.RECOVER: exposed_ok = false
		prev_state = s
		prev_pos = w.sw.pos[i]
	for a in attacks: seen[a] = true
	var repeats := 0
	for k in range(1, attacks.size()):
		if attacks[k] == attacks[k - 1]: repeats += 1
	ok(states.size() == 4, "the tyrant goes through chase, windup, execute and recover")
	ok(attacks.size() >= 12, "it attacks steadily (%d attacks in 60 s)" % attacks.size())
	ok(seen.has("cleave") and seen.has("volley") and seen.has("slam") and seen.has("bell"), "it uses dash-cleave, volley, slam and (Act V) the bell: %s" % str(seen.keys()))
	ok(repeats == 0, "never the same attack twice in a row")
	ok(not moved_in_windup, "it stands still while winding up")
	ok(exposed_ok, "it is Exposed only while recovering")
	var w2 := _world({"mode": "campaign", "hero": 0, "stage": 0, "seed": 42})
	w2.bosses.spawn_stage_boss(false)
	var u2: int = w2.bosses.stage_uids[0]
	var j := w2.sw.index_of(u2)
	w2.step(1.0 / 60.0)
	var st2: Dictionary = w2.bosses.bstate[u2]
	var h0 := w2.sw.hp[j]
	w2.hit(j, 100.0, 0, Vector2.ZERO, 0.0, 1)
	var plain := h0 - w2.sw.hp[j]
	st2.exposed = true
	h0 = w2.sw.hp[j]
	w2.hit(j, 100.0, 0, Vector2.ZERO, 0.0, 1)
	var exp := h0 - w2.sw.hp[j]
	ok(absf(exp / plain - 1.3) < 0.01, "an Exposed tyrant takes 30%% more damage (%.2fx)" % (exp / plain))

func _audio_tests() -> void:
	print("== audio buses, voices, pitch climb")
	ok(AudioServer.get_bus_index("Music") > 0 and AudioServer.get_bus_index("SFX") > 0 and AudioServer.get_bus_index("UI") > 0, "Music, SFX and UI buses exist")
	ok(AudioServer.get_bus_effect_count(0) > 0 and AudioServer.get_bus_effect(0, 0) is AudioEffectHardLimiter, "the Master bus ends in a hard limiter")
	ok(Sfx.players["gem"].bus == &"SFX" and Sfx.players["click"].bus == &"UI" and Sfx.ambience.bus == &"Music", "sounds are routed to their buses")
	var safe := bool(Save.opt("sfx_safe"))
	ok(Sfx.players["gem"].max_polyphony == (1 if safe else 5) and Sfx.players["boss"].max_polyphony == (1 if safe else 3), "rapid-fire sounds get 5 voices")
	if not safe:
		Sfx._climb_ms.erase("gem")
		var p0 := Sfx._pitch("gem", 1.0, 100000)
		var p1 := Sfx._pitch("gem", 1.0, 100200)
		var p2 := Sfx._pitch("gem", 1.0, 100400)
		var p3 := Sfx._pitch("gem", 1.0, 101000)
		ok(is_equal_approx(p0, 1.0) and is_equal_approx(p1, pow(2.0, 1.0 / 12.0)) and is_equal_approx(p2, pow(2.0, 2.0 / 12.0)) and is_equal_approx(p3, 1.0), "gem pickups climb a semitone each and reset after a 0.45 s gap")

## A spot facing a cliff band: walkable here, walkable 150-200 units ahead, a cliff cell in between.
func _find_cliff_crossing(w: World) -> Array:
	var T := w.terrain
	for ring in range(8, 60):
		for k in 48:
			var a := TAU * k / 48.0
			var p := Vector2(cos(a), sin(a)) * float(ring) * 32.0
			if not T.passable(p): continue
			for dk in 16:
				var d := Vector2.from_angle(TAU * dk / 16.0)
				var hit := false
				for step in range(1, 6):
					if T.type_at(p + d * step * 16.0) == Terrain.CLIFF: hit = true
				if not (hit and T.passable(p + d * 180.0) and T.passable(p + d * World.JUMP_DIST)): continue
				# a real wall: walking straight at it for 2 s gets nowhere near the far side
				var q := p
				for f in 120: q = T.move(q, q + d * 160.0 / 60.0)
				if (q - p).dot(d) < 60.0:
					return [p, d]
	return []

func _jump_tests() -> void:
	print("== jump")
	var found := []
	var w: World
	for st in [1, 3, 2, 0, 4]:
		w = _world({"mode": "campaign", "hero": 0, "stage": st, "seed": 51})
		found = _find_cliff_crossing(w)
		if not found.is_empty(): break
	ok(not found.is_empty(), "found a cliff to test against")
	if found.is_empty(): return
	w.stats.set_source("t", [["max_hp", "add", 1e7]]); w.hp = 1e7
	w.weapons.clear()
	var start: Vector2 = found[0]
	var dir: Vector2 = found[1]
	w.pp = start
	w.in_move = dir
	for k in 120: w.step(1.0 / 60.0)
	var walked := (w.pp - start).dot(dir)
	ok(walked < 90.0, "walking stops at the cliff (%.0f units in 2 s)" % walked)
	w.pp = start
	w.vel = Vector2.ZERO
	w.jump_cd = 0.0
	w.in_jump = true
	w.step(1.0 / 60.0)
	ok(w.airborne(), "the jump takes off")
	var peak_ok := true
	for k in 60:
		w.step(1.0 / 60.0)
		if w.airborne() and w.jump_progress() < 0.0: peak_ok = false
	var crossed := (w.pp - start).dot(dir)
	ok(not w.airborne() and crossed > 150.0 and w.terrain.passable(w.pp), "and lands past the cliff on solid ground (%.0f units)" % crossed)
	ok(w.jump_cd > 0.0, "then it is on cooldown")
	var before := w.pp
	w.in_jump = true
	w.in_move = Vector2.ZERO
	w.step(1.0 / 60.0)
	ok(not w.airborne(), "a second jump inside the cooldown does nothing")
	# landings are always on solid ground, from anywhere, in any direction
	var bad := 0
	var rng := RandomNumberGenerator.new(); rng.seed = 7
	for k in 400:
		var p := Vector2(rng.randf_range(-2500, 2500), rng.randf_range(-2500, 2500))
		if not w.terrain.passable(p): continue
		var to := w.jump_landing(p, Vector2.from_angle(rng.randf() * TAU))
		if not w.terrain.passable(to): bad += 1
	ok(bad == 0, "every landing is on walkable ground (%d bad of 400 tries)" % bad)
	# in the air: no melee contact, ground telegraphs miss; projectiles still hit
	var a := _world({"mode": "rift", "hero": 0, "gr": 1, "seed": 52})
	a.weapons.clear()
	for k in 5: a.step(1.0 / 60.0)
	a.in_jump = true
	a.in_move = Vector2.RIGHT
	a.step(1.0 / 60.0)
	for k in 6: a.spawn_foe(Content.E.BRUTE, a.pp + Vector2(randf_range(-10, 10), randf_range(-10, 10)), 0, 0, 50.0)
	a.add_tele(0, a.pp, 300.0, 0.05, 0.0, 30.0, true, false, -1, Color.RED, "test slam")
	var hp0 := a.hp
	for k in 15: a.step(1.0 / 60.0)
	ok(a.airborne() and a.hp == hp0, "airborne: neither the swarm nor a slam lands a hit")
	a.spawn_eshot(a.pp + Vector2(-20, 0), Vector2(600, 0), 7.0)
	a.inv_t = 0.0
	for k in 3: a.step(1.0 / 60.0)
	ok(a.hp < hp0, "but projectiles still do")

## The jump's touch button, airborne hazards, and how the 3D view draws it (arc, shadow on every tier).
func _jump_polish_tests() -> void:
	print("== jump: controls, hazards, drawing")
	# the thumb cluster: five buttons, all on screen, at least 12 px of clear space between any two circles,
	# at 16:9, 20:9 and portrait, with and without a camera cutout, for either hand
	var worst := INF
	var off := 0
	var count_ok := true
	for sz in [Vector2(1280, 720), Vector2(1600, 720), Vector2(720, 1280), Vector2(960, 720)]:
		for m in [Vector4.ZERO, Vector4(60, 0, 40, 24)]:
			for lh in [false, true]:
				var lay := TouchControls.layout_for(sz, m, lh)
				count_ok = count_ok and lay.size() == 5 and lay.map(func(b): return b.id).has("jump")
				for i in lay.size():
					var a: Dictionary = lay[i]
					var ap: Vector2 = a.pos
					var ar: float = a.r
					if ap.x - ar < 0.0 or ap.y - ar < 0.0 or ap.x + ar > sz.x or ap.y + ar > sz.y: off += 1
					for j in range(i + 1, lay.size()):
						var b: Dictionary = lay[j]
						worst = minf(worst, ap.distance_to(b.pos) - ar - float(b.r))
	ok(count_ok and off == 0 and worst >= 12.0, "ROLL, ULT, JUMP, 1 and 2 fit on screen with at least 12 px between them at 16:9, 20:9 and portrait (closest pair %.1f px, %d off screen)" % [worst, off])
	# airborne, the hero is untouched by burning oil and poison underfoot; on the ground both hurt
	var w := _world({"mode": "rift", "hero": 0, "gr": 1, "seed": 61})
	w.stats.set_source("t", [["max_hp", "add", 1e6]]); w.hp = 1e6
	w.weapons.clear()
	for k in 5: w.step(1.0 / 60.0)
	w.terrain.pour(w.pp + Vector2(60, 0), 70.0, Terrain.Surf.FIRE, 30.0)
	w.terrain.pour(w.pp + Vector2(160, 0), 70.0, Terrain.Surf.POISON, 30.0)
	var hp0 := w.hp
	w.in_jump = true
	w.in_move = Vector2.RIGHT
	for k in 30: w.step(1.0 / 60.0)           # airborne over the fire and the poison
	var air_hp := w.hp
	ok(w.airborne() and air_hp == hp0, "a jump over burning oil and poison takes no damage")
	var g := _world({"mode": "rift", "hero": 0, "gr": 1, "seed": 61})
	g.stats.set_source("t", [["max_hp", "add", 1e6]]); g.hp = 1e6
	g.weapons.clear()
	for k in 5: g.step(1.0 / 60.0)
	g.terrain.pour(g.pp, 70.0, Terrain.Surf.FIRE, 30.0)
	var g0 := g.hp
	for k in 30: g.step(1.0 / 60.0)
	ok(g.hp < g0, "standing in burning oil does hurt")
	# the 3D view: arc height, the drawn progress between ticks, and the hero's own contact shadow, on Low
	Save.data.options.gfx = 1                      # the Low tier: no shadow maps
	var j := _world({"mode": "campaign", "stage": 0, "hero": 0, "seed": 62})
	j.stats.set_source("t", [["max_hp", "add", 1e6]]); j.hp = 1e6
	j.weapons.clear()
	var v := WorldView3D.new()
	add_child(v)
	v.bind(j)
	for k in 3: j.step(1.0 / 60.0)
	v._process(1.0 / 60.0)
	var blob_ground: float = v._hero_blob.transform.basis.x.x
	ok(Quality.tier() == 0 and v._hero_blob.visible and v._hero_blob.transform.origin.x == v.hero_p.x and v._hero_blob.transform.origin.y == v.hero_p.y,
		"on Low the hero has a contact shadow under it")
	j.in_jump = true
	j.in_move = Vector2.RIGHT
	j.step(1.0 / 60.0)                             # take-off tick
	var ticks := 0
	while j.jump_t > World.JUMP_TIME * 0.5 and ticks < 120:
		j.step(1.0 / 60.0)
		ticks += 1
	v.alpha = 0.5
	v._process(1.0 / 60.0)
	var jp := v._hero_jp
	var expect := maxf(lerpf(v.ground_y(j.jump_from), v.ground_y(j.jump_to), jp) + 4.0 * jp * (1.0 - jp) * WorldView3D.JUMP_ARC, v.ground_y(v.hero_p) + 2.0)
	ok(jp > 0.4 and jp < 0.6 and absf(v.hero_y - expect) < 0.01, "mid-jump the hero is drawn on the arc (progress %.2f, %.1f above the ground)" % [jp, v.hero_y - v.ground_y(v.hero_p)])
	ok(v.hero_y - v.ground_y(v.hero_p) > 50.0, "about 58 units up at the apex")
	ok(v._hero_blob.transform.basis.x.x < blob_ground * 0.8, "and its shadow shrinks while it is up (radius %.1f -> %.1f)" % [blob_ground, v._hero_blob.transform.basis.x.x])
	var t0 := j.jump_t
	v.alpha = 0.0
	v._process(1.0 / 60.0)
	var jp0 := v._hero_jp
	v.alpha = 1.0
	v._process(1.0 / 60.0)
	ok(v._hero_jp > jp0 and absf((v._hero_jp - jp0) - FixedStep.STEP / World.JUMP_TIME) < 0.001, "between ticks the arc moves smoothly (one tick = %.3f of the jump)" % (FixedStep.STEP / World.JUMP_TIME))
	Save.data.options.gfx = 0
	v.queue_free()

func _look_tests() -> void:
	print("== look: resolution, ground, light, draping")
	# 3D resolution: phones by tier, FXAA only at 0.9 and up, the dynamic factor's floor
	var M: Script = load("res://scripts/main.gd")
	ok(M.auto_render_scale(0, true) == 0.75 and M.auto_render_scale(1, true) == 1.0 and M.auto_render_scale(2, true) == 1.0,
		"phones render 3D at 0.75 on Low and natively on Medium and High")
	ok(M.auto_render_scale(0, false) == 1.0 and M.auto_render_scale(2, false) == 1.0, "desktops native on every tier")
	ok(M.fxaa_allowed(1.0) and M.fxaa_allowed(0.9) and not M.fxaa_allowed(0.85) and not M.fxaa_allowed(0.75),
		"FXAA runs at a 3D scale of 0.9 or more only (a Medium phone loses it when the dynamic factor drops)")
	var d := 1.0
	for k in 20: d = M.dyn_down(d, 1.0, 1.0 / 60.0)
	ok(is_equal_approx(d, 0.85) and is_equal_approx(M.dyn_down(1.0, 0.025, 1.0 / 60.0), 0.92),
		"the dynamic factor steps down 0.08 (0.15 when twice over budget) and stops at 0.85 (%.2f)" % d)
	# the ground grid and texture detail per tier
	var qs := []
	var d2 := []
	for g in [1, 2, 3]:
		Save.data.options.gfx = g
		qs.append(Quality.ground_q())
		var gm := ShaderMaterial.new()
		WorldView3D.apply_ground(gm, 0)
		d2.append(gm.get_shader_parameter("detail2"))
	Save.data.options.gfx = 0
	ok(qs == [16.0, 12.0, 10.0], "ground grid spacing Low / Medium / High: %s" % str(qs))
	ok(d2 == [false, true, true], "the second texture scale (detail2) on Medium and High: %s" % str(d2))
	# the run's view: sky ambient, glow, lights, shadows, ground tiles, decals, marks, fog, water
	var w := _world({"mode": "campaign", "stage": 0, "hero": 0, "seed": 64})
	w.stats.set_source("t", [["max_hp", "add", 1e6]]); w.hp = 1e6
	w.weapons.clear()
	var v := WorldView3D.new()
	add_child(v)
	v.bind(w)
	for k in 3: w.step(1.0 / 60.0)
	v._process(1.0 / 60.0)
	ok(v.env.ambient_light_source == Environment.AMBIENT_SOURCE_SKY and v.sky_mat.sky_top_color == WorldView3D.STAGE_LOOK[0].sky
		and v.sky_mat.ground_bottom_color == WorldView3D.STAGE_LOOK[0].gnd, "ambient light comes from the act's sky")
	var cool := true
	for lk in WorldView3D.STAGE_LOOK:
		var sk: Color = lk.sky
		var gn: Color = lk.gnd
		cool = cool and sk.b > sk.r and gn.r > gn.b and gn.get_luminance() < sk.get_luminance() * 0.5
	ok(cool, "every act: a cool sky over a dark, warm ground")
	ok(v.env.glow_blend_mode == Environment.GLOW_BLEND_MODE_SCREEN and v.env.glow_bloom == 0.0 and is_equal_approx(v.env.glow_hdr_threshold, 1.25)
		and is_equal_approx(v.env.glow_intensity, 0.45) and is_equal_approx(v.env.glow_strength, 0.85), "glow: screen blend, no bloom, threshold 1.25, intensity 0.45, strength 0.85")
	for k in 400: v._lighting(1.0 / 60.0)
	var fl: float = v.torch.light_energy / (1.6 * WorldView3D.LIGHT_GAIN)
	ok(w.gloom() == 0.0 and absf(v.sun.light_energy - 1.2) < 0.01 and fl > 0.8 and fl < 1.2 and v.torch.omni_range == 360.0
		and is_equal_approx(v.key_light.light_energy, 0.9 * WorldView3D.LIGHT_GAIN),
		"lights: sun 1.2, torch 1.6 x gain (flicker %.2f) over 360 units, key 0.9 x gain" % fl)
	v._camera(1.0 / 60.0)
	ok(is_equal_approx(v.sun.directional_shadow_max_distance, 720.0 * v.view_scale), "sun shadows reach 720 at the landscape camera (%.0f)" % v.sun.directional_shadow_max_distance)
	var casts := 0
	var span := 0.0
	for c in v.ground.get_children():
		if c.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF: casts += 1
		span = maxf(span, absf(c.position.x) * 2.0 + (c.mesh as PlaneMesh).size.x)
	ok(casts == 0 and v.ground.get_child_count() == WorldView3D.GROUND_TILES * WorldView3D.GROUND_TILES, "ground tiles receive shadows but cast none")
	ok(absf(span - WorldView3D.GROUND_SIZE) <= WorldView3D.GROUND_TILES * v.GROUND_Q, "the ground spans %.0f (GROUND_SIZE 2200)" % span)
	var dp := v.fx.decals[0].mesh as PlaneMesh
	ok(dp.subdivide_width == 8 and dp.subdivide_depth == 8 and v.fx.marks_mm.multimesh.mesh == dp, "decals and marks: 9 x 9 quads to drape over the terrain")
	# a mark on a slope sits at the ground under its centre + 0.4
	var best := w.pp
	var bh := -1e9
	for k in 64:
		var q: Vector2 = w.pp + Vector2.from_angle(TAU * k / 64.0) * (80.0 + 4.0 * k)
		if v.ground_y(q) > bh: bh = v.ground_y(q); best = q
	v.fx._marks.clear()
	v.fx._mark(best, 40.0, 1)
	v._process(1.0 / 60.0)
	var mx := FX3D.mark_xform(v.fx._marks[0], v.ground_y(best))
	ok(v.fx.marks_mm.multimesh.visible_instance_count == 1 and absf(mx.origin.y - (v.ground_y(best) + 0.4)) < 0.001 and is_equal_approx(mx.basis.x.length(), 40.0),
		"a scorch mark on a slope lies at the ground under its centre + 0.4 (%.1f on ground %.1f)" % [mx.origin.y, v.ground_y(best)])
	var o1 := v.fx._make_obj("chest", Color(0.9, 0.7, 0.2))
	var o2 := v.fx._make_obj("shrine", Color(0.9, 0.7, 0.2))
	var m1 = (o1.get_child(0) as MeshInstance3D).material_override
	var m2 = (o2.get_child(0) as MeshInstance3D).material_override
	ok(m1 is ShaderMaterial and m1.shader.resource_path == "res://shaders/3d/prop.gdshader" and m1 == m2, "event props are lit by prop.gdshader, one material per colour")
	o1.queue_free(); o2.queue_free()
	var fp := v.env_fx.fog.mesh as PlaneMesh
	ok(fp.subdivide_width == 24 and fp.subdivide_depth == 24 and v.env_fx.fog_mat.get_shader_parameter("drape") == true and v.env_fx.fog.position.y == 0.0,
		"the ground fog is a 25 x 25 grid draped onto the terrain in its shader")
	v._features()
	var wet: bool = v.water.visible
	w.terrain.liquid = "none"
	v.bind(w)
	v._process(1.0 / 60.0)
	ok(wet and not v.water.visible, "water drawn on a wet act, hidden on an act without liquid")
	v.queue_free()
	# the title stage: the run's sky ambient and glow, dimmer lights, the fog parting at the hero
	var ms := MenuStage3D.new()
	add_child(ms)
	var me: Environment = ms.cam.environment
	var push: PackedVector4Array = ms.fog_mat.get_shader_parameter("pushers")
	ok(me.ambient_light_source == Environment.AMBIENT_SOURCE_SKY and me.glow_blend_mode == Environment.GLOW_BLEND_MODE_SCREEN and me.glow_bloom == 0.0
		and is_equal_approx(me.glow_hdr_threshold, 1.25) and is_equal_approx(me.glow_intensity, 0.45), "title stage: sky ambient and the run's glow")
	ok(push.size() == 6 and push[0] == Vector4(MenuStage3D.ORIGIN.x + MenuStage3D.HERO_AT.x, MenuStage3D.ORIGIN.z + MenuStage3D.HERO_AT.y, 48.0, 14.0),
		"title stage: the fog parts around the hero")
	ok(is_equal_approx(ms.braziers[0].light_energy, 6.0) and is_equal_approx(ms.rift_light.light_energy, 5.4) and is_equal_approx(ms.key_light.light_energy, 4.2),
		"title stage: braziers 6, rift 5.4, key 4.2 (40% under 10, 9, 7)")
	ms.queue_free()
	# bosses: one compiled flash shader for all, a dimmer light
	var b1 := BossRig.new()
	var b2 := BossRig.new()
	add_child(b1); add_child(b2)
	b1.build("tyrant", Color.RED, "tyrant_4")
	b2.build("tyrant", Color.GREEN, "tyrant_4")
	ok(b1._over_flash != null and b1._over_flash != b2._over_flash and b1._over_flash.shader == b2._over_flash.shader and b1._over_flash.shader == BossRig._flash_sh,
		"bosses share one hit-flash shader, each with its own material")
	ok(is_equal_approx(b1.light.light_energy, 0.85 * WorldView3D.LIGHT_GAIN), "a boss's light starts at 0.85 x gain")
	b1.queue_free(); b2.queue_free()

func _anim_tests() -> void:
	print("== foe animation (vertex animation textures)")
	for kind in ["grunt", "runner", "brute", "spitter", "splitter", "mini", "charger", "breach", "goblin"]:
		var v := Models.foe_vat(kind)
		var good := not v.is_empty()
		if good:
			var vc: PackedFloat32Array = v.clips
			for sl in 5:
				if vc[sl * 3 + 1] < 2.0 or vc[sl * 3 + 2] <= 0.0 or vc[sl * 3] + vc[sl * 3 + 1] + 1.0 > float(v.rows): good = false
			if v.pos.get_width() != v.verts or v.pos.get_height() != v.rows: good = false
		ok(good, "%s has walk, attack, hit, death and spawn clips inside its texture" % kind)
	ok(not Models.foe_vat("grunt", 4).is_empty() and Models.foe_vat("grunt", 4) != Models.foe_vat("grunt"), "Act V's skeleton variant has its own clips")
	ok(Models.foe_vat("exile").is_empty(), "kinds without a baked file fall back to the shader animation")
	var w := _world({"mode": "campaign", "hero": 0, "seed": 61})
	for k in 20: w.step(0.05)
	var i := w.spawn_foe(Content.E.GRUNT, w.pp + Vector2(200, 0), 0, 0, 50.0)
	ok(is_equal_approx(w.sw.born[i], w.t), "a foe remembers when it spawned")
	w.sw.take(i, 1.0)
	ok(is_equal_approx(w.sw.hit_at[i], w.t), "a hit starts a flinch")
	var u := w.sw.uid[i]
	w.step(0.05)
	w.sw.take(w.sw.index_of(u), 1.0)
	ok(w.sw.hit_at[w.sw.index_of(u)] < w.t, "but not again within 0.7 s")
	var j := w.spawn_foe(Content.E.GRUNT, w.pp + Vector2(6, 0), 0, 0, 50.0)
	var uj := w.sw.uid[j]
	w.inv_t = 0.0
	w.grid.build(w.sw)
	w._contact()
	ok(is_equal_approx(w.sw.atk_t[w.sw.index_of(uj)], w.t), "touching the hero plays the attack")
	w.dispose()

## 0.9.9: the hero's locomotion rate has no cliff and a standing cast stops when the hero moves; bosses play
## idle and die; models with the albedo map on a later surface count as PBR; solid props (PropLayout) block
## walking (bodies slide round them), a jump clears the low ones and never lands inside any, and every
## graphics tier lays out the same solids.
func _remediation_tests() -> void:
	print("== 0.9.9 remediation")
	var hr := HeroRig.new()
	var worst := 0.0
	var prev := hr.loco_rate(0.0)
	for sp in range(2, 202, 2):
		var r := hr.loco_rate(float(sp))
		worst = maxf(worst, absf(r - prev))
		prev = r
	ok(worst < 0.05, "the locomotion rate has no cliff from 0 to 200 units/s (largest step %.3f)" % worst)
	ok(is_equal_approx(hr.loco_rate(100.0), 1.0) and is_equal_approx(hr.loco_rate(155.0), 1.0), "and plays at the clips' own rate from walk to run speed")
	hr.free()
	var h := HeroRig.new()
	add_child(h)
	h.build("warden", Color.WHITE)
	ok(h.tree != null, "the Warden's model builds its animation tree")
	if h.tree != null:
		var dt := 1.0 / 60.0
		var st := {"pos": Vector2.ZERO, "face": Vector2.RIGHT, "cast_dir": Vector2.RIGHT, "cast_age": 9.0, "mv": 0.0, "vel": 0.0,
			"roll": -1.0, "hit": 0.0, "dead": false, "t": 0.0, "ph": 0.0, "jump": -1.0}
		for k in 10:
			h.animate(st, dt); h.tree.advance(dt)
		st.cast_age = 0.0
		h.animate(st, dt); h.tree.advance(dt)
		var full_on := bool(h.tree.get("parameters/cast_full/active"))
		st.mv = 1.0
		st.vel = 150.0
		for k in 24:
			st.cast_age = float(st.cast_age) + dt
			h.animate(st, dt); h.tree.advance(dt)
		var full_after := bool(h.tree.get("parameters/cast_full/active"))
		var up_after := bool(h.tree.get("parameters/cast_up/active"))
		ok(full_on and not full_after and not up_after, "a standing cast plays full-body and stops once the hero moves, with no upper-body replay (%s -> %s, upper %s)" % [full_on, full_after, up_after])
	h.queue_free()
	var b := BossRig.new()
	add_child(b)
	b.build("tyrant", Color.RED, "tyrant")
	ok(b.anim != null and b.anim.has_animation("idle") and b.anim.has_animation("die"), "the tyrant model has idle and die clips")
	if b.anim != null:
		var bs := {"pos": Vector2(500, 500), "face": Vector2.RIGHT, "hp_frac": 1.0, "flash": 0.0, "t": 0.0, "dt": 1.0 / 60.0, "attack": false, "phase": 0}
		for k in 40:
			b.animate(bs); b.anim.advance(1.0 / 60.0)
		var idle := String(b.anim.current_animation)
		for k in 40:
			bs.pos = Vector2(500.0 + 2.0 * k, 500.0)
			b.animate(bs); b.anim.advance(1.0 / 60.0)
		var walk := String(b.anim.current_animation)
		bs.dead = true
		for k in 6:
			b.animate(bs); b.anim.advance(1.0 / 60.0)
		var die := String(b.anim.current_animation)
		ok(idle == "idle", "a boss standing still plays idle (%s)" % idle)
		ok(walk == "walk", "a boss on the move plays walk (%s)" % walk)
		ok(die == "die" and b.anim.get_animation("die").loop_mode == Animation.LOOP_NONE and b.death_time() > 0.5, "a fallen boss plays die once (%s, %.2f s)" % [die, b.death_time()])
	b.queue_free()
	var am := ArrayMesh.new()
	for sf in 2:
		var stl := SurfaceTool.new()
		stl.begin(Mesh.PRIMITIVE_TRIANGLES)
		stl.add_vertex(Vector3.ZERO); stl.add_vertex(Vector3.RIGHT); stl.add_vertex(Vector3.UP)
		stl.commit(am)
	var tm := StandardMaterial3D.new()
	tm.albedo_texture = ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGB8))
	am.surface_set_material(0, StandardMaterial3D.new())
	am.surface_set_material(1, tm)
	ok(Models.has_pbr(am), "a mesh with the albedo map on its second surface counts as PBR")
	# collision against placed props (test circles [x, y, r, low] on the flat ground round the start)
	var w := _world({"mode": "campaign", "hero": 0, "stage": 0, "seed": 5})
	var t := w.terrain
	var br := World.HERO_R
	var wall := PackedFloat32Array([0.0, 120.0, 14.0, 0.0])
	for wx in [-36.0, -18.0, 0.0, 18.0, 36.0]:
		wall.append_array(PackedFloat32Array([wx, -100.0, 18.0, 1.0]))
	t.set_test_props(wall)
	var p := Vector2(4.0, 40.0)
	var into := false
	for k in 120:
		p = t.move(p, p + Vector2(0.0, 3.0), br)
		if p.distance_to(Vector2(0.0, 120.0)) < 14.0 + br - 0.01: into = true
	ok(not into and p.y > 120.0 + 14.0, "walking into a trunk slides round it, never through (ends at %s)" % p)
	p = Vector2(20.0, -40.0)
	into = false
	var step := Vector2(0.5, -1.0).normalized() * 3.0                 # 27 degrees off straight on
	for k in 160:
		p = t.move(p, p + step, br)
		for cx in [-36.0, -18.0, 0.0, 18.0, 36.0]:
			if p.distance_to(Vector2(cx, -100.0)) < 18.0 + br - 0.01: into = true
	ok(not into and p.y < -100.0 - 18.0, "walking into a wall at an angle slides along it and round its end (ends at %s)" % p)
	p = Vector2(10.0, -40.0)
	into = false
	for k in 120:
		p = t.move(p, p + Vector2(0.0, -3.0), br)
		for cx in [-36.0, -18.0, 0.0, 18.0, 36.0]:
			if p.distance_to(Vector2(cx, -100.0)) < 18.0 + br - 0.01: into = true
	ok(not into and p.y > -100.0, "walking straight at a wall stops at its face, never through (ends at %s)" % p)
	var land := w.jump_landing(Vector2(0.0, -20.0), Vector2(0.0, -1.0))
	ok(land.y < -100.0 - 18.0 - br and t.props_clear(land, br), "a jump vaults the low wall and lands past it (%s)" % land)
	var land2 := w.jump_landing(Vector2(0.0, 0.0), Vector2(0.0, 1.0))
	ok(land2.y > 0.0 and land2.y <= 120.0 - 14.0 - br and t.props_clear(land2, br), "a jump at a trunk comes down short of it (%s)" % land2)
	t.set_test_props(PackedFloat32Array([0.0, 140.0, 18.0, 1.0]))
	var land3 := w.jump_landing(Vector2(0.0, -60.0), Vector2(0.0, 1.0))
	ok(t.props_clear(land3, br) and land3.y > 140.0, "a jump whose landing falls on a boulder lands past it (%s)" % land3)
	w.dispose()
	# the real layout: shapes per kind, the same solids on every tier, the arch opening walkable
	var w2 := _world({"mode": "campaign", "hero": 0, "stage": 0, "seed": 5})
	var shapes_ok := true
	var tiers_ok := true
	var arches := 0
	var arch_ok := true
	for cx in range(-2, 3):
		for cy in range(-2, 3):
			var c := Vector2i(cx, cy)
			var lay := PropLayout.chunk(c, 0, w2.terrain, 1.0)
			var want := 0
			var low := 0
			for it in lay.items:
				match String(it[0]):
					"tree", "tree_dead", "pillar": want += 1
					"rock": want += 1; low += 1
					"wall": want += 5; low += 5
					"arch":
						want += 2
						arches += 1
						var mid: Vector2 = it[1]
						if not w2.terrain.props_clear(mid, br): arch_ok = false
			var sol: PackedFloat32Array = lay.solids
			var nlow := 0
			for j in range(0, sol.size(), 4):
				if sol[j + 3] > 0.5: nlow += 1
			if sol.size() / 4 != want or nlow != low: shapes_ok = false
			if PropLayout.chunk(c, 0, w2.terrain, 0.7).solids != sol or PropLayout.chunk(c, 0, w2.terrain, 1.3).solids != sol: tiers_ok = false
	ok(shapes_ok, "trunks, pillars and boulders block as one circle, walls as five overlapping ones, arches as two posts; boulders and walls are low")
	ok(tiers_ok, "every graphics tier lays out the same solid props (25 chunks)")
	ok(arches > 0 and arch_ok, "the hero fits through an arch's opening (%d arches)" % arches)
	w2.dispose()

## The 3D view places foes, effects, smoke and lights at ground_y() + their own height on the CPU (the
## instanced shaders do no terrain lookup). Checks that ground_y() is the simulation's height on hilly
## ground and that what the view writes for foes, shots, crystals, debris, sparks and lights sits on it.
## 0.10.0: the voice layer. data/voice_manifest.json holds every line once. VoiceBank plays a line's .ogg when
## the file exists, timed (subtitle, ducking, the next intro beat) to its real length, and otherwise a chime of
## the speaker's own for the manifest's estimate; priorities, cooldowns, the voice buses, the intro screen and
## the run's voice cues are checked here, all on a stepped clock.
func _voice_bank() -> VoiceBank:
	var vb := VoiceBank.new()
	vb.manual_clock = true
	add_child(vb)
	return vb

func _voice_tests() -> void:
	print("== 0.10.0 voice")
	var vb := _voice_bank()
	ok(vb.errors.is_empty(), "the voice manifest loads with 0 errors%s" % ("" if vb.errors.is_empty() else ": " + "; ".join(vb.errors)))
	ok(vb.entries.size() == 61, "it holds 61 lines (%d)" % vb.entries.size())
	var hero_cues := {"intro": 1, "cast": 3, "ult": 2, "kill_streak": 2, "low_hp": 2, "boss_spawn": 1, "death": 1}
	var miss: Array = []
	for h in ["warden", "spark", "ember", "storm"]:
		for c in hero_cues:
			if vb.variants(h, c) != int(hero_cues[c]): miss.append("%s/%s" % [h, c])
	if vb.variants("narrator", "intro") != 4: miss.append("narrator/intro")
	for k in 5:
		if vb.variants("narrator", "act_%d" % k) != 1: miss.append("narrator/act_%d" % k)
	for b in ["tyrant", "herald"]:
		for c in ["spawn", "die"]:
			if vb.variants(b, c) != 1: miss.append("%s/%s" % [b, c])
	ok(miss.is_empty(), "each exile resolves its 7 cues (12 lines), the narrator 4 intro beats and 5 act openings, both bosses spawn and die%s" % ("" if miss.is_empty() else ": missing " + str(miss)))
	var rules := {"cast": [0, 60.0], "kill_streak": [1, 30.0], "low_hp": [2, 15.0], "ult": [2, 4.0], "boss_spawn": [3, 0.0], "death": [3, 0.0], "spawn": [3, 0.0], "die": [3, 0.0], "intro": [3, 0.0]}
	var off: Array = []
	for id in vb.entries:
		var e: Dictionary = vb.entries[id]
		var cue := String(e.cue)
		var want: Array = rules.get(cue, [3, 0.0]) if not cue.begins_with("act_") else [3, 0.0]
		if int(e.priority) != int(want[0]) or not is_equal_approx(float(e.cooldown_s), float(want[1])): off.append(id)
		if String(e.file) != "res://audio/voices/%s/%s_%d.ogg" % [e.speaker, cue, int(e.variant)] or String(id) != "%s_%s_%d" % [e.speaker, cue, int(e.variant)]: off.append(id + " (path)")
	ok(off.is_empty(), "priorities, cooldowns, ids and .ogg paths follow the cue table%s" % ("" if off.is_empty() else ": " + str(off)))
	# no .ogg (the line pointed at a missing file, so this holds once the real pack is in): the speaker's chime,
	# held for the manifest's estimate
	var e0: Dictionary = vb.entries["warden_cast_0"]
	e0.file = "res://tests/fixtures/no_such_line.ogg"
	var r := vb.say("warden", "cast", 0)
	ok(bool(r.played) and not bool(r.using_pack) and is_equal_approx(float(r.duration), float(e0.duration_fallback_s)) and String(r.text) == String(e0.text) and String(r.speaker) == "warden",
		"with no .ogg a line plays the speaker's chime for the manifest's estimate (%.1f s) and returns its text" % float(r.get("duration", 0.0)))
	var ap := vb.active_player()
	ok(ap != null and ap.stream is AudioStreamWAV and ap.bus == &"VoiceHero", "the chime is a generated AudioStreamWAV on the VoiceHero bus")
	var sigs := {}
	var fresh := VoiceBank.new()
	var c_us := Time.get_ticks_usec()
	var c_len := 0.0
	for s in ["warden", "spark", "ember", "storm", "narrator", "tyrant", "herald"]:
		var ch: AudioStreamWAV = fresh.chime(s)
		if ch != null and ch.data.size() > 0:
			sigs[hash(ch.data)] = s
			c_len = maxf(c_len, ch.data.size() / 2.0 / VoiceBank.CHIME_RATE)
	var c_ms := (Time.get_ticks_usec() - c_us) / 1000.0
	fresh.free()
	ok(sigs.size() == 7, "all 7 speakers have a chime of their own (%d distinct, the longest %.2f s)" % [sigs.size(), c_len])
	ok(c_ms < 250.0, "the 7 chimes are made in %.0f ms on this machine (one a frame at startup on a phone)" % c_ms)
	vb.queue_free()
	# priority: a higher line cuts in, an equal or lower one waits its turn
	var pb := _voice_bank()
	var a := pb.say("warden", "cast", 0)
	var b2 := pb.say("warden", "boss_spawn")
	ok(bool(a.played) and bool(b2.played) and pb.active_id() == "warden_boss_spawn_0", "a boss_spawn line (priority 3) cuts off a cast bark (priority 0)")
	var c2 := pb.say("warden", "cast", 1)
	ok(not bool(c2.played) and String(c2.reason) == "busy", "a bark is refused while a higher-priority line plays (%s)" % c2.get("reason", ""))
	pb.queue_free()
	var ub := _voice_bank()
	var u := ub.say("ember", "ult", 0)
	var c3 := ub.say("ember", "cast", 0)
	ok(bool(u.played) and not bool(c3.played) and ub.active_cue() == "ult", "a cast bark is refused while an ult line (priority 2) plays")
	ub.queue_free()
	# cooldowns: per cue, and a 2.8 s gap after any line before the next priority 0-1 bark
	var cb := _voice_bank()
	var ccd := float(cb.line("storm", "cast", 0).cooldown_s)
	var fired := 0
	var first_len := 0.0
	for k in 20:
		var rr := cb.say("storm", "cast")
		if bool(rr.played):
			fired += 1
			first_len = float(rr.duration)
		cb.step(0.3)
	ok(fired == 1, "rapid casts fire once and are held back through the %.0f s cooldown (%d fired in 6 s)" % [ccd, fired])
	cb.step(ccd - 6.0 - 0.5)
	var early := cb.say("storm", "cast")
	cb.step(maxf(ccd, first_len + VoiceBank.GLOBAL_GAP_S) - (ccd - 0.5) + 0.05)      # past the cooldown and the 2.8 s gap after the line
	var again := cb.say("storm", "cast")
	ok(not bool(early.played) and String(early.reason) == "cooldown" and bool(again.played), "still held 0.5 s before it ends (%s), and fire again once it has passed (another variant: no repeats)" % early.get("reason", ""))
	cb.queue_free()
	var gb := _voice_bank()
	var g0 := gb.say("spark", "cast", 0)
	gb.step(float(g0.duration) + 1.0)
	var g1 := gb.say("spark", "kill_streak", 0)
	gb.step(2.0)
	var g2 := gb.say("spark", "kill_streak", 0)
	ok(bool(g0.played) and not bool(g1.played) and String(g1.reason) == "gap" and bool(g2.played), "a priority 0-1 bark waits 2.8 s after the last line ends (%s)" % g1.get("reason", ""))
	gb.step(float(g2.duration) + 0.5)
	ok(bool(gb.say("spark", "low_hp", 0).played), "a low-health line (priority 2) does not wait for that gap")
	gb.queue_free()
	# drop-in: a real .ogg at the line's path replaces the chime, timed to its own length
	var db := _voice_bank()
	db.entries["warden_cast_0"].file = "res://tests/fixtures/voice_probe.ogg"
	var real := db.say("warden", "cast", 0)
	var rp := db.active_player()
	var st: AudioStream = rp.stream if rp != null else null
	ok(bool(real.played) and bool(real.using_pack) and st is AudioStreamOggVorbis and absf(float(real.duration) - st.get_length()) < 0.001 and absf(float(real.duration) - 1.25) < 0.05,
		"a dropped-in .ogg plays instead of the chime, timed to its real length (%.2f s, estimate %.1f s)" % [float(real.get("duration", 0.0)), float(db.entries["warden_cast_0"].duration_fallback_s)])
	ok(st is AudioStreamOggVorbis and not (st as AudioStreamOggVorbis).loop, "and never loops")
	db.step(1.3)
	ok(not db.is_speaking(), "the line ends when the clip does, not at the estimate")
	db.entries["warden_low_hp_0"].file = "res://tests/fixtures/no_such_line.ogg"
	var absent := db.say("warden", "low_hp", 0)
	ok(bool(absent.played) and not bool(absent.using_pack) and is_equal_approx(float(absent.duration), float(db.entries["warden_low_hp_0"].duration_fallback_s)), "a line whose .ogg is missing falls back to the chime")
	db.queue_free()
	# buses
	var bi := ["Voice", "VoiceHero", "VoiceNarrator", "VoiceBoss"].map(func(n): return AudioServer.get_bus_index(n))
	ok(not bi.has(-1), "Voice, VoiceHero, VoiceNarrator and VoiceBoss buses exist (%s)" % str(bi))
	if not bi.has(-1):
		ok(AudioServer.get_bus_send(bi[0]) == &"Master" and AudioServer.get_bus_send(bi[1]) == &"Voice" and AudioServer.get_bus_send(bi[2]) == &"Voice" and AudioServer.get_bus_send(bi[3]) == &"Voice",
			"the three voice buses feed Voice, and Voice feeds Master")
		var comp := false
		for k in AudioServer.get_bus_effect_count(bi[1]):
			if AudioServer.get_bus_effect(bi[1], k) is AudioEffectCompressor: comp = true
		var ps: AudioEffectPitchShift = null
		var rv := false
		for k in AudioServer.get_bus_effect_count(bi[3]):
			var fx := AudioServer.get_bus_effect(bi[3], k)
			if fx is AudioEffectPitchShift: ps = fx
			if fx is AudioEffectReverb: rv = true
		ok(comp and rv and ps != null and is_equal_approx(ps.pitch_scale, 0.9), "VoiceHero has a compressor; VoiceBoss a reverb and a 0.90 pitch shift")
	var rb := _voice_bank()
	rb.say("narrator", "act_0")
	var nb: StringName = rb.active_player().bus if rb.active_player() != null else &""
	rb.stop(0.0)
	rb.say("tyrant", "spawn")
	var tb: StringName = rb.active_player().bus if rb.active_player() != null else &""
	ok(nb == &"VoiceNarrator" and tb == &"VoiceBoss", "narrator lines play on VoiceNarrator, boss lines on VoiceBoss (%s, %s)" % [nb, tb])
	rb.queue_free()
	# ducking: Music -6 dB and SFX -3 dB over 0.12 s while a voice plays, back over 0.25 s when it ends
	var mi := AudioServer.get_bus_index("Music")
	var si := AudioServer.get_bus_index("SFX")
	var m0 := AudioServer.get_bus_volume_db(mi)
	var s0 := AudioServer.get_bus_volume_db(si)
	var kb := _voice_bank()
	var kl := kb.say("spark", "ult", 0)
	kb.step(0.06)
	var m_half := AudioServer.get_bus_volume_db(mi)
	kb.step(0.07)
	var m_d := AudioServer.get_bus_volume_db(mi)
	var s_d := AudioServer.get_bus_volume_db(si)
	ok(m_half < m0 - 1.0 and m_half > m0 - 5.0 and is_equal_approx(m_d, m0 - 6.0) and is_equal_approx(s_d, s0 - 3.0),
		"while a voice plays, Music ducks 6 dB and SFX 3 dB, smoothly over 0.12 s (%.1f halfway; %.1f / %.1f dB)" % [m_half - m0, m_d - m0, s_d - s0])
	kb.step(float(kl.duration) - 0.13)
	kb.step(0.13)
	var m_mid := AudioServer.get_bus_volume_db(mi)
	kb.step(0.13)
	ok(not kb.is_speaking() and m_mid < m0 - 0.5 and m_mid > m0 - 5.5 and is_equal_approx(AudioServer.get_bus_volume_db(mi), m0) and is_equal_approx(AudioServer.get_bus_volume_db(si), s0),
		"and both buses return exactly to their levels over 0.25 s once it ends (%.1f dB halfway)" % (m_mid - m0))
	kb.queue_free()
	# Options > Voice volume drives the Voice bus
	var vi := AudioServer.get_bus_index("Voice")
	var vv0 = Save.opt("voice_volume")
	Save.set_opt("voice_volume", 0.5)
	var half_db := AudioServer.get_bus_volume_db(vi) if vi >= 0 else 99.0
	Save.set_opt("voice_volume", 0.0)
	var muted := vi >= 0 and AudioServer.is_bus_mute(vi)
	Save.set_opt("voice_volume", 1.0 if vv0 == null else vv0)
	ok(vv0 != null and absf(half_db - linear_to_db(0.5)) < 0.01 and muted and vi >= 0 and not AudioServer.is_bus_mute(vi), "Options > Voice volume sets the Voice bus (50%% = %.1f dB; 0 mutes it)" % half_db)
	# subtitles: up for max(2.0, duration + 0.35) s
	ok(is_equal_approx(VoiceBank.subtitle_seconds(1.0), 1.35) and is_equal_approx(VoiceBank.subtitle_seconds(4.0), 4.35), "a subtitle stays up for its line's length + 0.35 s")
	var sb := _voice_bank()
	var subs := Subtitles.new()
	subs.manual_clock = true
	add_child(subs)
	subs.bind(sb)
	var sl := sb.say("warden", "boss_spawn")
	var hold := VoiceBank.subtitle_seconds(float(sl.duration))
	subs.step(hold - 0.05)
	var shown := subs.is_showing() and subs.shown_text() == String(sl.text)
	subs.step(0.1)
	ok(shown and not subs.is_showing(), "the subtitle banner shows the line and clears after %.2f s" % hold)
	subs.queue_free()
	sb.queue_free()
	# the stream cache keeps at most 16 voice clips in memory
	var lb := _voice_bank()
	for k in 17: lb.cache_put("res://fake/%d.ogg" % k, AudioStreamWAV.new())
	ok(lb.cache_size() == VoiceBank.LRU_MAX and not lb.cache_has("res://fake/0.ogg") and lb.cache_has("res://fake/16.ogg"), "at most 16 voice streams stay in memory, the least recently used dropped first")
	lb.cache_get("res://fake/1.ogg")
	lb.cache_put("res://fake/17.ogg", AudioStreamWAV.new())
	ok(lb.cache_has("res://fake/1.ogg") and not lb.cache_has("res://fake/2.ogg"), "a stream just played is kept over an older one")
	lb.queue_free()
	# hero select: a new exile's intro replaces the last one's at once
	var hb := _voice_bank()
	var p1 := hb.preview_hero("warden")
	hb.step(0.5)
	var p2 := hb.preview_hero("ember")
	ok(bool(p1.played) and bool(p2.played) and hb.active_id() == "ember_intro_0", "picking another exile stops the last intro and plays the new one's (%s)" % hb.active_id())
	hb.queue_free()
	# the cold open: four narrator beats, each held for its line + 0.5 s; a tap moves on, Skip ends it
	var ib := _voice_bank()
	var intro := IntroScreen.new()
	intro.bank = ib
	intro.manual_clock = true
	add_child(intro)
	var b0 := ib.active_id()
	var d0 := ib.remaining()                         # the clip's length once the pack is in, the estimate until then
	var adv := func(x: float) -> void:
		ib.step(x)
		intro.step(x)
	adv.call(d0 + IntroScreen.GAP_S - 0.05)
	var still0 := intro.beat == 0
	adv.call(0.1)
	ok(IntroScreen.GAP_S == 0.5 and b0 == "narrator_intro_0" and still0 and intro.beat == 1 and ib.active_id() == "narrator_intro_1", "the intro holds each beat for its line + 0.5 s, then plays the next")
	intro.tap()
	ok(intro.beat == 2 and ib.active_id() == "narrator_intro_2" and intro.shown_text() == String(ib.entries["narrator_intro_2"].text), "a tap moves to the next beat at once, cutting the narrator off; the text is the manifest's")
	intro.skip()
	ok(intro.done and not ib.is_speaking(), "Skip ends the intro and stops the narrator")
	intro.queue_free()
	ib.queue_free()
	# in a run: the act opening, a boss and the exile's reply, the ultimate, low life, a streak, a cast, death
	var vw := World.new()
	vw.setup({"mode": "campaign", "stage": 1, "hero": 2, "seed": 3, "headless": true, "season": ""})
	var dbk := _voice_bank()
	var dir := VoiceDirector.new()
	dir.bank = dbk
	dir.manual_clock = true
	dir.cast_chance = 1.0
	dir.cast_min_foes = 0
	add_child(dir)
	dir.bind(vw)
	var go := func(x: float) -> void:
		dbk.step(x)
		dir.step(x)
	ok(dbk.active_id() == "narrator_act_1_0", "a campaign run opens with the narrator's line for its act (%s)" % dbk.active_id())
	go.call(dbk.remaining() + 0.01)
	vw.moment.emit("boss_spawn", {"boss": "tyrant", "name": "Cindermaw"})
	var boss_line := dbk.active_id()
	go.call(dbk.remaining() + VoiceDirector.REPLY_GAP_S + 0.01)
	ok(boss_line == "tyrant_spawn_0" and dbk.active_id() == "ember_boss_spawn_0", "a boss arrives with its spawn line, then the exile replies (%s, %s)" % [boss_line, dbk.active_id()])
	go.call(dbk.remaining() + 0.01)
	vw.moment.emit("ult", {})
	ok(dbk.active_speaker() == "ember" and dbk.active_cue() == "ult", "the ultimate plays an ult line")
	go.call(dbk.remaining() + 3.0)
	vw.hp = vw.max_hp * 0.2
	go.call(0.1)
	ok(dbk.active_cue() == "low_hp", "dropping under 30%% life plays a low-health line (%s)" % dbk.active_cue())
	go.call(dbk.remaining() + 3.0)
	vw.combo = 30
	go.call(0.1)
	ok(dbk.active_cue() == "kill_streak", "a 25-kill streak plays a kill-streak line (%s)" % dbk.active_cue())
	go.call(dbk.remaining() + 3.0)
	vw.cast_t = vw.t + 1.0
	go.call(0.1)
	ok(dbk.active_cue() == "cast", "a weapon cast in a fight can bark (%s)" % dbk.active_cue())
	go.call(dbk.remaining() + 0.5)
	vw.moment.emit("boss_die", {"boss": "herald"})
	ok(dbk.active_id() == "herald_die_0", "a boss's fall plays its die line")
	go.call(dbk.remaining() + 0.5)
	vw.ended.emit(false)
	ok(dbk.active_speaker() == "ember" and dbk.active_cue() == "death", "falling plays the exile's death line")
	dir.unbind()
	dir.queue_free()
	dbk.queue_free()
	vw.dispose()
	# the World raises the moments the director listens for
	var mw := World.new()
	mw.setup({"mode": "campaign", "stage": 2, "hero": 0, "seed": 5, "headless": true, "season": ""})
	var seen: Array = []
	mw.moment.connect(func(k: String, info: Dictionary) -> void: seen.append([k, String(info.get("boss", "")), String(info.get("name", ""))]))
	mw.ult = 100.0
	mw.use_ult()
	mw.bosses.spawn_stage_boss(false)
	var bix := -1
	for i in mw.sw.n:
		if (mw.sw.flags[i] & Swarm.F_BOSS) != 0: bix = i
	if bix >= 0: mw.bosses.on_kill(bix, mw.sw.pos[bix])
	mw.bosses._do_spawn_herald()
	var pale := String(Content.STAGES[2].boss)
	ok(seen.has(["ult", "", ""]) and seen.has(["boss_spawn", "tyrant", pale]) and seen.has(["boss_die", "tyrant", pale]) and seen.has(["boss_spawn", "herald", "The Shard Herald"]),
		"the World raises ult, boss_spawn and boss_die moments with the boss's voice and name (%s)" % str(seen))
	mw.dispose()
	# the game itself: a first launch opens on the intro over the menu; picking an exile plays their intro line
	var sv: Node = get_node("/root/Save")
	var keep: Dictionary = sv.data
	sv.data = sv.defaults()
	sv.data.options.sound = false
	Diag.crashed_last = false
	var mn: Node = load("res://scenes/main.tscn").instantiate()
	add_child(mn)
	var intro_up: bool = mn.get("intro") != null and int(mn.intro.beat) == 0 and VoiceBank.current != null and VoiceBank.current.active_id() == "narrator_intro_0"
	if mn.get("intro") != null: mn.intro.skip()
	var intro_gone: bool = mn.get("intro") == null and bool(sv.data.intro_seen) and mn.state == "menu"
	ok(intro_up and intro_gone, "a first launch opens on the narrated intro over the menu, and Skip leaves the menu (%s, %s)" % [intro_up, intro_gone])
	mn._on_act("hero", 3)
	var vid := VoiceBank.current.active_id() if VoiceBank.current != null else ""
	ok(vid == "storm_intro_0", "picking an exile on the title screen plays their intro line (%s)" % vid)
	mn.queue_free()
	VoiceBank.stop_all(0.0)
	sv.data = keep

## 0.10.1: the version on screen and in reports comes from one setting; "Copy report" puts the device, settings,
## last benchmark and session trails on the clipboard as text; "Copy save" / "Paste save" carry a profile across a
## reinstall (the release-key switch): one checksummed line that survives a chat app's wrapping, never carrying
## this phone's diagnostics or (from the next iteration) purchases, which only Google Play can restore.
func _ops_tests() -> void:
	print("== 0.10.1 report and save transfer")
	var ver := String(ProjectSettings.get_setting("application/config/version", ""))
	ok(ver != "" and Diag.version() == ver and RegEx.create_from_string("^\\d+\\.\\d+\\.\\d+").search(ver) != null, "the version comes from application/config/version (%s)" % ver)
	var sv: Node = get_node("/root/Save")
	var keep: Dictionary = sv.data
	sv.data = sv.defaults()
	var bench := {"fps": 57.6, "ms": 17.4, "low1": 41.0, "foes": 400, "draws": 212, "ktris": 610, "tier": "High", "scale": 100, "res": "2340x1080",
		"device": "SM-S901B", "gpu": "Adreno (TM) 730", "renderer": "mobile"}
	sv.data.bench = bench
	var had_prev := FileAccess.file_exists(Diag.PREV)
	var prev_text := FileAccess.get_file_as_string(Diag.PREV) if had_prev else ""
	var pf := FileAccess.open(Diag.PREV, FileAccess.WRITE)
	pf.store_string("  1.00 == boot\n  2.00 start campaign\n  9.50 run t=7.0 foes=212 TEST-PREV-TAIL\n")
	pf.close()
	var rep := Diag.report_text()
	if had_prev:
		var rf := FileAccess.open(Diag.PREV, FileAccess.WRITE)
		rf.store_string(prev_text)
		rf.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(Diag.PREV))
	ok(rep.begins_with("Shardfall " + ver) and rep.contains("device:") and rep.contains("gpu:") and rep.contains("graphics:"), "Copy report opens with the version, the device, the GPU and the graphics settings")
	ok(rep.contains("58 FPS") and rep.contains("610k"), "it carries the last benchmark")
	ok(rep.contains("TEST-PREV-TAIL"), "and the previous session's trail (the crash trail, after a crash)")
	ok(rep.length() < 20000, "and stays short enough to paste into a message (%d characters)" % rep.length())
	# Copy save / Paste save
	sv.data = sv.defaults()
	sv.data.gold = 1234
	sv.data.echoes = 9
	sv.data.passives = ["start", "m1", "m3"]
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for k in 40: sv.data.stash.append(Items.make(Content.SLOTS[k % 4], k % 4, 30, rng))
	sv.data.selftest = {"results": [{"f": "base", "fps": 60}]}
	sv.data.bench = {"fps": 61.0}
	var token: String = sv.export_text()
	ok(token.begins_with("SHARDFALL-SAVE:1:") and not token.contains("\n"), "Copy save makes one line of text (%d characters with 40 items in the stash)" % token.length())
	ok(token.length() < 65536, "short enough for one chat message (under 65,536 characters)")
	sv.data = sv.defaults()
	sv.data.gold = 7
	sv.data.selftest = {"results": [{"f": "base", "fps": 33}]}
	sv.data.bench = {"fps": 33.0}
	var wrapped := ""
	for i in range(0, token.length(), 60): wrapped += token.substr(i, 60) + "\n "
	var err: String = sv.import_text(wrapped)
	ok(err == "" and int(sv.data.gold) == 1234 and sv.data.stash.size() == 40 and sv.data.passives == ["start", "m1", "m3"] and int(sv.data.echoes) == 9,
		"Paste save restores the profile, even after a chat app wraps the text (%s)" % (err if err != "" else "ok"))
	ok(is_equal_approx(float(sv.data.bench.get("fps", 0.0)), 33.0) and int(sv.data.selftest.results[0].fps) == 33, "this phone's own benchmark and self-test results stay")
	var bk := String(sv.path).get_basename() + "_before_paste.json"
	ok(FileAccess.file_exists(bk) and FileAccess.get_file_as_string(bk).contains("\"gold\":7"), "the profile it replaced is kept in %s" % bk.get_file())
	var before := JSON.stringify(sv.data)
	var at := token.length() - 10
	var flipped := token.substr(0, at) + ("A" if token[at] != "A" else "B") + token.substr(at + 1)
	var e1: String = sv.import_text(flipped)
	var e2: String = sv.import_text(token.substr(0, token.length() - 40))
	var e3: String = sv.import_text("hello there")
	ok(e1 != "" and e2 != "" and e3 != "" and JSON.stringify(sv.data) == before, "a damaged, cut-short or foreign paste is refused and changes nothing (%s | %s | %s)" % [e1, e2, e3])
	sv.data["purchases"] = {"from_google_play": true}
	var forged: String = sv.encode_save({"version": 2, "gold": 5, "purchases": {"starter_pack": true}})
	var e4: String = sv.import_text(forged)
	ok(e4 == "" and int(sv.data.gold) == 5 and sv.data.get("purchases", {}) == {"from_google_play": true}, "a pasted save never brings purchases: the phone keeps its own (%s)" % str(sv.data.get("purchases", {})))
	sv.data.erase("purchases")
	# the buttons, and the version on the title screen
	sv.data = sv.defaults()
	sv.data.options.sound = false
	sv.data.intro_seen = true
	Diag.crashed_last = false
	var mn: Node = load("res://scenes/main.tscn").instantiate()
	add_child(mn)
	var on_title := _texts(mn.screens, "Label").any(func(s): return s.contains(ver))
	mn.screens._opt_tab = Screens.OPT_TABS.find("Game")
	mn.screens.show_options("menu")
	var game_tab := _texts(mn.screens, "Button")
	var opt_sub := _texts(mn.screens, "Label").any(func(s): return s.contains(ver))
	mn.screens._opt_tab = Screens.OPT_TABS.find("Diagnostics")
	mn.screens.show_options("menu")
	var diag_tab := _texts(mn.screens, "Button")
	mn.screens.show_crash(PackedStringArray(["one", "two"]))
	var crash := _texts(mn.screens, "Button")
	mn.screens.show_bench(bench)
	var bench_b := _texts(mn.screens, "Button")
	mn.screens._opt_tab = 0
	ok(on_title and opt_sub, "the title screen and the Options title show the version")
	ok(game_tab.has("Copy save") and game_tab.has("Paste save"), "Options has Copy save and Paste save")
	ok(diag_tab.has("Copy report") and crash.has("Copy report") and bench_b.has("Copy report"), "Copy report is in Options > Diagnostics, on the crash report and on the benchmark result")
	mn.queue_free()
	sv.data = keep

## 0.10.1, the S22 check: held sideways a phone's UI is 720 units tall, and a page's Back and main actions sit in
## its sheet's foot, on screen however long the page gets (the end of a run with bargains, unlocks, happenings and
## loot; a 60-line crash report; Options; the benchmark). Held upright (1080x2340, the UI scaled 1.9x as main does)
## a long title wraps instead of pushing the crash report off the screen's right edge.
func _fit_tests() -> void:
	var sv: Node = get_node("/root/Save")
	var keep: Dictionary = sv.data
	sv.data = sv.defaults()
	sv.data.options.sound = false
	sv.data.intro_seen = true
	Diag.crashed_last = false
	var mn: Node = load("res://scenes/main.tscn").instantiate()
	add_child(mn)
	var win := get_window()
	var size0 := win.size                       # headless: 64x64
	win.size = Vector2i(2340, 1080)             # the S22 held sideways: a 1560x720 UI
	await get_tree().process_frame
	var vs: Vector2 = mn.screens.get_viewport_rect().size
	var w := _world({"mode": "campaign", "stage": 0, "hero": 2})
	w.bargains = ["ember_pact", "blood_price", "long_night"]
	w.new_unlocks = ["glaive", "wisp"]
	w.director.history = [[30.0, "breach"], [90.0, "goblin"], [150.0, "eclipse"], [210.0, "ritual"]]
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for k in 6: w.loot_run.append(Items.make(Content.SLOTS[k % 4], Content.Rarity.RARE + k % 2, 20, rng))
	mn.screens.show_end(w)
	var end_r := await _off_screen(mn.screens, ["Play again", "Return to menu"])
	var trail: Array = []
	for i in 60: trail.append("[%d.0] line %d of the session's trail" % [i, i])
	mn.screens.show_crash(PackedStringArray(trail))
	var crash_r := await _off_screen(mn.screens, ["Copy report", "Continue"])
	mn.screens._opt_tab = Screens.OPT_TABS.find("Game")
	mn.screens.show_options("menu")
	var opt_r := await _off_screen(mn.screens, ["Back"])
	mn.screens._opt_tab = 0
	mn.screens.show_bench({"fps": 57.6, "ms": 17.4, "low1": 41.0, "foes": 400, "draws": 212, "ktris": 610, "tier": "High", "scale": 100,
		"res": "2340x1080", "device": "SM-S901B", "gpu": "Adreno (TM) 730", "renderer": "mobile"})
	var bench_r := await _off_screen(mn.screens, ["Copy report", "Run again", "Back"])
	var srng := RandomNumberGenerator.new()
	srng.seed = 5
	for k in 8: sv.data.stash.append(Items.make(Content.SLOTS[k % 4], k % 4, 20, srng))
	var leg := -1
	for k in sv.data.stash.size():
		if String(sv.data.stash[k].get("leg", "")) != "": leg = k
	var stash_want := ["Equip", "Salvage", "Back"] + (["Cube: extract"] if leg >= 0 else [])
	mn.screens._sel_item = leg if leg >= 0 else 2
	mn.screens.show_stash(false)
	var stash_r := await _off_screen(mn.screens, stash_want)
	var pause_want := ["Resume", "Build & Stats", "Gear & Crafting", "Settings", "Restart Run", "Main Menu"]
	mn.screens.show_pause(w)
	var pause_r := await _off_screen(mn.screens, pause_want) + _one_row(mn.screens, ["Build & Stats", "Gear & Crafting", "Settings"])
	mn.screens._sel_passive = "a6"
	mn.screens.show_web()
	var web_want := ["Not yet reachable", "Reset web  (refund all)", "Back"]      # a6 from a fresh profile: not reachable yet
	var web_r := await _off_screen(mn.screens, web_want) + _graph_shown(mn.screens)
	ok(vs.y == 720.0 and end_r == "", "held sideways (%dx%d UI), the end of a long run keeps Play again and Return to menu on screen%s" % [vs.x, vs.y, end_r])
	ok(crash_r == "" and opt_r == "" and bench_r == "", "and so do the crash report's Copy report and Continue, Options' Back and the benchmark's buttons%s%s%s" % [crash_r, opt_r, bench_r])
	ok(stash_r == "", "the stash keeps the selected item's %s on screen with Back%s" % [" / ".join(stash_want.slice(0, stash_want.size())), stash_r])
	ok(pause_r == "" and web_r == "", "the pause menu: Build & Stats, Gear & Crafting and Settings on one row, every button on screen; the Shard Web's whole graph, Take, Reset and Back on screen%s%s" % [pause_r, web_r])
	# held upright: the S22's 1080x2340, which main._ui_scale answers by scaling the UI up 1.9x
	win.size = Vector2i(1080, 2340)
	await get_tree().process_frame
	var pv: Vector2 = mn.screens.get_viewport_rect().size
	mn.screens.show_crash(PackedStringArray(trail.slice(0, 8)))
	var up_r := await _off_screen(mn.screens, ["Copy report", "Continue"])
	var title_lines := 0
	for l in mn.screens.find_children("*", "Label", true, false):
		if String(l.text) == "THE LAST SESSION ENDED UNEXPECTEDLY": title_lines = (l as Label).get_line_count()
	mn.screens.show_stash(false)
	up_r += await _off_screen(mn.screens, stash_want)
	mn.screens.show_pause(w)
	up_r += await _off_screen(mn.screens, pause_want) + _one_row(mn.screens, ["Build & Stats", "Gear & Crafting", "Settings"])
	mn.screens.show_web()
	up_r += await _off_screen(mn.screens, web_want) + _graph_shown(mn.screens)
	win.size = size0
	await get_tree().process_frame
	ok(pv.x < 700.0 and up_r == "" and title_lines >= 2, "held upright (%dx%d UI), the crash report's title wraps (%d lines) and its buttons, the stash's, the pause menu's and the Shard Web's stay on screen%s" % [pv.x, pv.y, title_lines, up_r])
	# the Shard Web's names: none on another, all inside the view, at the sizes its page gives it
	var wv := Screens.WebView.new()
	var web_bad: Array = []
	var named := 0
	for sz in [Vector2(560, 420), Vector2(600, 420), Vector2(700, 310), Vector2(830, 310), Vector2(830, 390), Vector2(1000, 480)]:
		wv.size = sz
		var lay: Dictionary = wv.label_layout()
		named = lay.size()
		var ids: Array = lay.keys()
		for i in ids.size():
			var a: Rect2 = lay[ids[i]]
			if not Rect2(Vector2.ZERO, sz).encloses(a): web_bad.append("%s outside at %dx%d" % [ids[i], sz.x, sz.y])
			for j in range(i + 1, ids.size()):
				if a.intersects(lay[ids[j]]): web_bad.append("%s on %s at %dx%d" % [ids[i], ids[j], sz.x, sz.y])
	wv.free()
	ok(named == 8 and web_bad.is_empty(), "the Shard Web's 8 notable and keystone names never overlap and stay inside the view%s" % (("  (" + "; ".join(web_bad) + ")") if not web_bad.is_empty() else ""))
	mn.queue_free()
	sv.data = keep

## "" when the Shard Web's graph is drawn whole: inside the screen and every scroll area around it.
func _graph_shown(root: Control) -> String:
	for g in root.find_children("*", "Control", true, false):
		if not (g is Screens.WebView): continue
		var r := (g as Control).get_global_rect()
		var n := g.get_parent()
		while n != null:
			if n is ScrollContainer and not (n as Control).get_global_rect().grow(0.5).encloses(r):
				return "  (the web's graph %s runs past its scroll area %s)" % [str(r), str((n as Control).get_global_rect())]
			n = n.get_parent()
		return "" if root.get_viewport_rect().grow(0.5).encloses(r) else "  (the web's graph is off the screen)"
	return "  (no Shard Web graph)"

## "" when the buttons named share one row (the same top edge); else where each one is.
func _one_row(root: Control, labels: Array) -> String:
	var ys := {}
	for b in root.find_children("*", "Button", true, false):
		if labels.has(String(b.text)) and (b as Control).is_visible_in_tree(): ys[String(b.text)] = roundi((b as Control).global_position.y)
	return "" if ys.size() == labels.size() and ys.values().all(func(y): return y == ys.values()[0]) else "  (not one row: %s)" % str(ys)

## "" when every button named is visible, inside the screen and inside every scroll area around it; else what is not.
func _off_screen(root: Control, labels: Array) -> String:
	await get_tree().create_timer(0.35).timeout          # the sheet's 0.22 s settle
	var vr := root.get_viewport_rect().grow(0.5)
	var bad: Array = []
	for want in labels:
		var found := false
		for b in root.find_children("*", "Button", true, false):
			if String(b.text) != want or not (b as Control).is_visible_in_tree(): continue
			found = true
			var r := (b as Control).get_global_rect()
			var why := ""
			if not vr.encloses(r): why = "off the screen at %s" % str(r)
			var n := b.get_parent()
			while n != null and why == "":
				if n is ScrollContainer and not (n as Control).get_global_rect().grow(0.5).encloses(r): why = "scrolled out of sight"
				n = n.get_parent()
			if why != "": bad.append("%s %s" % [want, why])
		if not found: bad.append(want + " missing")
	return "" if bad.is_empty() else "  (" + "; ".join(bad) + ")"

func _texts(root: Node, cls: String) -> Array:
	var out: Array = []
	for c in root.find_children("*", cls, true, false):
		out.append(String(c.text))
	return out

# ================================================================= 0.10.0 alpha
## Counts the engine's errors and warnings while it is attached (the main.tscn flow must raise none). The
## headless dummy renderer keeps no materials and logs "material is null" whenever a mesh with a surface
## override material is freed: that is the stand-in renderer talking, not the game, so it is counted apart.
class ErrCount extends Logger:
	var n := 0
	var dummy := 0
	var seen: Array = []
	func _log_error(_function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if file.contains("servers/rendering/dummy/"):
			dummy += 1
			return
		n += 1
		if seen.size() < 6: seen.append("%s:%d %s" % [file.get_file(), line, rationale if rationale != "" else code])
	func _log_message(_message: String, _error: bool) -> void:
		pass

## 0.10.0-alpha: solid props (the foe guard, no tunnelling, chunk-edge spill, a tide that moves no solid, the
## same run on Low and High through trims), the rigs' fades, the game's own flow (intro, menu, heroes, a run,
## pause, back to the menu) with no error and nothing left behind, VoiceBank's clip timing and stop_all, the
## Emberwitch's contagion at 400 foes, the three prop synergies, Rift Echoes, the safe-mode sentinel, the
## story's data and the menus' touch targets.
func _alpha10_tests() -> void:
	print("== 0.10.0 alpha")
	# ---- determinism primitives: SplitMix64 against its reference values (tools: Python)
	ok(PropLayout.splitmix(1) == 6238072747940578789 and PropLayout.splitmix(12345) == -906084347102765743 and PropLayout.splitmix(-7) == -2622165800321222925,
		"PropLayout.splitmix matches the SplitMix64 reference (64-bit wrapping, logical shifts)")
	ok(PropLayout.seed_of(Vector2i(3, -2), 1) == PropLayout.seed_of(Vector2i(3, -2), 1) and PropLayout.seed_of(Vector2i(3, -2), 1) != PropLayout.seed_of(Vector2i(-2, 3), 1),
		"chunk seeds are stable and tell mirrored chunks apart")
	# ---- the foe guard: beside impassable ground a prop never shoves a foe off its feet
	var gw := _world({"mode": "campaign", "stage": 2, "hero": 0, "seed": 41})
	var T := gw.terrain
	var edges: Array = []
	for cy in range(-60, 61):
		for cx in range(-60, 61):
			var q := Vector2(cx * Terrain.CELL + 8.0, cy * Terrain.CELL + 8.0)
			if not T.passable(q) and T.passable(q + Vector2(Terrain.CELL, 0)): edges.append(q + Vector2(Terrain.CELL, 0))
			if edges.size() >= 60: break
		if edges.size() >= 60: break
	var rr := RandomNumberGenerator.new()
	rr.seed = 7
	var bad := 0
	var trials := 0
	for e in edges:
		for k in 6:
			var p0: Vector2 = e + Vector2(rr.randf_range(0.0, 10.0), rr.randf_range(-8.0, 8.0))
			if not T.passable(p0): continue
			T.set_test_props(PackedFloat32Array([p0.x + rr.randf_range(4.0, 22.0), p0.y + rr.randf_range(-12.0, 12.0), rr.randf_range(10.0, 22.0), 0.0]))
			var np0 := p0 + Vector2(rr.randf_range(-8.0, 8.0), rr.randf_range(-8.0, 8.0))
			var r0 := T.foe_move(p0, np0, 12.0)
			trials += 1
			if not T.passable(r0): bad += 1
	ok(trials >= 100 and bad == 0, "foe_move beside impassable ground never ends a foe off it (%d of %d moves)" % [bad, trials])
	# ---- anti-tunnelling: a 35-unit step never carries a body through an r 14 trunk
	T.set_test_props(PackedFloat32Array([0.0, 0.0, 14.0, 0.0]))
	var tun := 0
	for mover in ["move", "foe_move"]:
		var p1 := Vector2(-60.0, 0.0)
		for k in 6:
			var n1: Vector2 = T.move(p1, p1 + Vector2(35.0, 0.0), 6.0) if mover == "move" else T.foe_move(p1, p1 + Vector2(35.0, 0.0), 6.0)
			if n1.x > 0.0 or n1.length() < 14.0 + 6.0 - 0.01: tun += 1
			p1 = n1
	ok(tun == 0, "a 35 unit/tick step never tunnels through an r 14 trunk, walking or as a foe (%d tunnelled)" % tun)
	T.props_on = true
	T._prop_test_on = false
	# ---- chunk-edge spill: a circle centred in one chunk is seen from the next
	T._prop_chunk(Vector2i(1, 0))
	T._prop_chunks[Vector2i(0, 0)] = PackedFloat32Array([636.0, 100.0, 20.0, 1.0])
	T._prop_tags[Vector2i(0, 0)] = PackedByteArray([PropLayout.TAG_STONE])
	T._prop_cells.clear()
	T._prop_cell_tags.clear()
	var spill := false
	var nb := T.props_near(Vector2(650.0, 100.0))
	for j in range(0, nb.size(), 4):
		if is_equal_approx(nb[j], 636.0) and is_equal_approx(nb[j + 1], 100.0): spill = true
	ok(spill and T.props_clear(Vector2(650.0, 100.0), 10.0) == false, "props_near sees a wall that spills over a chunk edge (MAX_SPILL), and it blocks there")
	# ---- Act V: the tide rises 40 and no solid moves
	var w5 := _world({"mode": "campaign", "stage": 4, "hero": 0, "seed": 9})
	var cs := [Vector2i(0, 0), Vector2i(1, 1), Vector2i(-2, 1), Vector2i(2, -1)]
	var before: Array = []
	for c in cs: before.append([PropLayout.chunk(c, 4, w5.terrain, 1.0, false).solids, PropLayout.solid_tags(c, 4, w5.terrain)])
	w5.terrain.level += 40.0
	w5.terrain._chunks.clear()
	var same := true
	for k in cs.size():
		var c2: Vector2i = cs[k]
		if PropLayout.chunk(c2, 4, w5.terrain, 1.0, false).solids != before[k][0] or PropLayout.solid_tags(c2, 4, w5.terrain) != before[k][1]: same = false
	ok(same, "Act V: the liquid 40 units higher leaves every solid and its tag where it was (placement reads level0)")
	var tags_ok := true
	var woods := 0
	for c3 in cs:
		var lay := PropLayout.chunk(c3, 0, gw.terrain, 1.0, false)
		var tg: PackedByteArray = lay.solid_tags
		if tg.size() * 4 != (lay.solids as PackedFloat32Array).size(): tags_ok = false
		for t in tg:
			if t > PropLayout.TAG_ARCH: tags_ok = false
			if t == PropLayout.TAG_WOOD: woods += 1
	ok(tags_ok and woods > 0, "every solid carries a tag (WOOD, STONE or ARCH), parallel to the circles (%d wood)" % woods)
	# ---- the same run on Low and on High, one of them trimming its caches all the way
	var sv: Node = get_node("/root/Save")
	var gfx0: int = int(sv.data.options.gfx)
	var sigs: Array = []
	for tier in [1, 3]:
		sv.data.options.gfx = tier
		var dw := _world({"mode": "campaign", "stage": 0, "hero": 0, "seed": 77})
		dw.stats.set_source("t", [["max_hp", "add", 1e6]]); dw.hp = 1e6
		for k in 1800:
			if tier == 1 and k % 300 == 150: dw.terrain.trim(dw.pp, 1)
			dw.step(1.0 / 60.0)
		var hsh := 0
		for i in dw.sw.n: hsh = hash([hsh, roundi(dw.sw.pos[i].x * 8.0), roundi(dw.sw.pos[i].y * 8.0)])
		sigs.append([dw.sw.n, dw.kills, roundi(dw.pp.x * 8.0), roundi(dw.pp.y * 8.0), hsh])
	sv.data.options.gfx = gfx0
	ok(sigs[0] == sigs[1], "1,800 ticks on Low (trimming its prop caches) and on High end identical (%s)" % str(sigs[0]))
	# ---- rigs: a boss's light dies with it; a standing cast gives way to a roll, a jump or death
	var bo := BossRig.new()
	add_child(bo)
	bo.build("tyrant", Color.RED, "tyrant")
	var e0 := bo.light.light_energy
	var total := bo.death_time() + WorldView3D.BOSS_SINK
	var dtb := 1.0 / 60.0
	var tb := 0.0
	while tb < total + 0.1:
		bo.animate({"pos": Vector2(500, 500), "face": Vector2.RIGHT, "hp_frac": 0.0, "flash": 0.0, "t": tb, "dt": dtb, "attack": false, "phase": 0,
			"dead": true, "fade": clampf((total - tb) / total, 0.0, 1.0)})
		if bo.anim != null: bo.anim.advance(dtb)
		tb += dtb
	ok(e0 > 0.0 and bo.light.light_energy <= 0.001 and not bo.light.visible, "a dying boss's light fades from %.2f to 0 over its death and sink (%.4f)" % [e0, bo.light.light_energy])
	bo.queue_free()
	var aborted: Array = []
	for how in ["roll", "jump", "dead"]:
		var hh := HeroRig.new()
		add_child(hh)
		hh.build("warden", Color.WHITE)
		if hh.tree == null:
			hh.queue_free()
			continue
		var st := {"pos": Vector2.ZERO, "face": Vector2.RIGHT, "cast_dir": Vector2.RIGHT, "cast_age": 9.0, "mv": 0.0, "vel": 0.0,
			"roll": -1.0, "hit": 0.0, "dead": false, "t": 0.0, "ph": 0.0, "jump": -1.0}
		for k in 10:
			hh.animate(st, dtb); hh.tree.advance(dtb)
		st.cast_age = 0.0
		hh.animate(st, dtb); hh.tree.advance(dtb)
		var on := bool(hh.tree.get("parameters/cast_full/active"))
		match how:
			"roll": st.roll = 0.3
			"jump": st.jump = 0.3
			"dead": st.dead = true
		for k in 30:
			st.cast_age = float(st.cast_age) + dtb
			hh.animate(st, dtb); hh.tree.advance(dtb)
		if on and not bool(hh.tree.get("parameters/cast_full/active")): aborted.append(how)
		hh.queue_free()
	ok(aborted == ["roll", "jump", "dead"], "a standing cast fades out on a roll, a jump and death (%s)" % str(aborted))
	# ---- the game itself: intro -> main menu -> heroes -> a run -> pause -> main menu, no error, nothing left
	var keep: Dictionary = sv.data
	sv.data = sv.defaults()
	sv.data.options.sound = false
	Diag.crashed_last = false
	var orph0 := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	var errs := ErrCount.new()
	OS.add_logger(errs)
	var mn: Node = load("res://scenes/main.tscn").instantiate()
	add_child(mn)
	var steps: Array = []
	if mn.intro != null and mn.state == "intro": steps.append("intro")
	mn.intro.skip()
	if mn.intro == null and mn.state == "menu" and mn.screens.page == "menu": steps.append("menu")
	mn._on_act("heroes", null)
	sv.data.hero = 1                                  # what the Sparkcaller's tile does before it acts
	mn._on_act("hero", 1)
	if mn.screens.page == "sub" and int(sv.data.hero) == 1 and VoiceBank.current != null and VoiceBank.current.active_id() == "spark_intro_0": steps.append("heroes")
	mn.back()
	if mn.screens.page == "menu": steps.append("back")
	mn._on_act("campaign", 0)
	for k in 30: mn._process(1.0 / 60.0)
	if mn.state == "play" and mn.world != null and mn.world.t > 0.0: steps.append("run")
	mn._pause()
	if mn.state == "pause" and mn.screens.page == "pause": steps.append("pause")
	mn._on_act("build", null)
	mn.back()
	if mn.state == "pause" and mn.screens.page == "pause": steps.append("build")
	mn.back()
	if mn.state == "play": steps.append("resume")
	mn._pause()
	mn.screens.confirm("Leave this run?", "", "Leave", "leave")
	mn._on_act("leave", null)
	var speaking := VoiceBank.current != null and VoiceBank.current.is_speaking()
	if mn.state == "menu" and mn.world == null and mn.screens.page == "menu" and not speaking: steps.append("main menu")
	mn.free()
	await get_tree().process_frame                     # pages cleared with queue_free go at the end of a frame
	await get_tree().process_frame
	OS.remove_logger(errs)
	var orph := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) - orph0
	ok(steps == ["intro", "menu", "heroes", "back", "run", "pause", "build", "resume", "main menu"] and errs.n == 0 and orph == 0,
		"main.tscn: intro, main menu, heroes, Back, a run, pause, Build & Stats, resume, Main Menu: %s, %d errors%s (%d from the headless dummy renderer), %d orphan nodes left" % [str(steps), errs.n, (" " + str(errs.seen)) if errs.n > 0 else "", errs.dummy, int(orph)])
	VoiceBank.stop_all()
	sv.data = keep
	# ---- VoiceBank: a clip times its line; stop_all is immediate and gives Music and SFX back their 0 dB
	var vb := _voice_bank()
	var ln: Dictionary = vb.entries["narrator_act_0_0"]
	ln.file = "res://tests/fixtures/voice_probe.ogg"
	var probe: AudioStream = load(ln.file)
	var rp := vb.say("narrator", "act_0", 0)
	ok(bool(rp.using_pack) and absf(float(rp.duration) - probe.get_length()) < 0.001 and absf(vb.duration_of("narrator", "act_0", 0) - probe.get_length()) < 0.001
		and is_equal_approx(VoiceBank.subtitle_seconds(float(rp.duration)), probe.get_length() + 0.35),
		"a clip times its line: %.2f s played, the same from duration_of, its subtitle up %.2f s (length + 0.35)" % [float(rp.duration), VoiceBank.subtitle_seconds(float(rp.duration))])
	vb.queue_free()
	var cur := VoiceBank.current
	var mus := AudioServer.get_bus_index("Music")
	var sfx := AudioServer.get_bus_index("SFX")
	if cur != null:
		cur.say("warden", "boss_spawn", 0)
		cur.step(0.5)
		var ducked := AudioServer.get_bus_volume_db(mus) < -3.0 and AudioServer.get_bus_volume_db(sfx) < -1.0
		VoiceBank.stop_all()
		ok(ducked and not cur.is_speaking() and is_zero_approx(AudioServer.get_bus_volume_db(mus)) and is_zero_approx(AudioServer.get_bus_volume_db(sfx)),
			"stop_all stops the line at once and returns Music (%.1f dB) and SFX (%.1f dB) to 0 dB" % [AudioServer.get_bus_volume_db(mus), AudioServer.get_bus_volume_db(sfx)])
	var eb := _voice_bank()
	var picks := {}
	for k in 40:
		var rk := eb.say("ember", "kill_streak")
		if bool(rk.played): picks[int(rk.variant)] = true
		eb.stop_now()
		eb.step(11.0)
	ok(not picks.has(eb.escalation_variant("ember", "burning_12")) and eb.escalation_variant("ember", "burning_12") >= 0 and eb.escalation_variant("warden", "hp_30") >= 0
		and eb.escalation_variant("spark", "ricochet_2") >= 0 and eb.escalation_variant("storm", "conduct") >= 0,
		"the four escalation lines resolve, and the frenzy line never comes up as an ordinary streak bark (%s)" % str(picks.keys()))
	eb.queue_free()
	# ---- the Emberwitch's contagion: 400 foes, three clusters 0 / 55 / 110 from the strike, a tree and a boulder beside it
	var cw := _world({"mode": "campaign", "stage": 0, "hero": 2, "seed": 21})
	cw.stats.set_source("t", [["max_hp", "add", 1e6]]); cw.hp = 1e6
	cw.need = 1e12
	var cp := Vector2(400, 0)
	cw.pp = cp + Vector2(-90, 0)
	var tree_at := cp + Vector2(30, 70)
	cw.terrain.set_test_props(PackedFloat32Array([tree_at.x, tree_at.y, 16.0, 0.0, cp.x - 60.0, cp.y - 70.0, 18.0, 1.0]))
	var power := float(Content.WEAPONS.nova.lv[0].dmg) * cw._dmg_scale("nova")
	var crng := RandomNumberGenerator.new()
	crng.seed = 5
	var cluster3: Array = []
	var nfoe := 0
	var hp_min := INF
	while cw.sw.n < 400:
		var g := 3 if nfoe >= 150 else nfoe % 3
		var at: Vector2
		if g < 3:
			at = cp + Vector2([0.0, 55.0, 110.0][g], 0.0) + Vector2(crng.randf_range(-8, 8), crng.randf_range(-26, 26))
		else:
			at = cp + Vector2.from_angle(crng.randf() * TAU) * crng.randf_range(150.0, 320.0)
		var fi := cw.spawn_foe(Content.E.GRUNT, at, 0, 0, 1.0)
		if fi < 0: break
		var fh := Contagion.DETONATE_K * power * crng.randf_range(3.0, 16.0)      # every foe >= 3x the detonation
		cw.sw.mhp[fi] = fh; cw.sw.hp[fi] = fh; cw.sw.spd[fi] = 0.0
		hp_min = minf(hp_min, fh)
		if g == 2: cluster3.append(cw.sw.uid[fi])
		nfoe += 1
	cw.grid.build(cw.sw)
	cw.contagion.cast_at(cp, power)
	cw.weapons.nova.t = 0.0
	var c3_gen := -1
	var t_us := 0
	for k in 600:
		var t0 := Time.get_ticks_usec()
		cw.step(1.0 / 60.0)
		t_us += Time.get_ticks_usec() - t0
		if c3_gen < 0:
			for u in cluster3:
				var j := cw.sw.index_of(u)
				if j >= 0 and cw.sw.burn_stacks[j] > 0:
					c3_gen = cw.sw.burn_gen[j]
					break
	var m := cw.metrics
	var avg_ms := t_us / 600.0 / 1000.0
	var wood_only := true
	for b in cw.contagion.beacons:
		if (b.pos as Vector2).distance_to(tree_at) > 0.5: wood_only = false
	ok(hp_min >= 3.0 * Contagion.DETONATE_K * power and c3_gen >= 1, "the cluster 110 out (beyond the strike) catches through contagion, generation %d" % c3_gen)
	ok(cw.kills >= 30 and int(m.ember_spreads) >= 20 and int(m.ember_conflagrations) >= 5 and int(m.ember_beacons) >= 1 and wood_only,
		"400 foes, 10 s: %d slain, %d spreads, %d conflagrations, %d beacons (the tree only, never the boulder)" % [cw.kills, int(m.ember_spreads), int(m.ember_conflagrations), int(m.ember_beacons)])
	ok(avg_ms < 4.0, "and the whole tick averages %.2f ms (under 4 ms)" % avg_ms)
	ok(int(m.ember_ignitions) > 0 and cw.contagion.burning >= 0 and Contagion.MAX_BURN_STACKS == 5 and Contagion.MAX_GEN == 4, "Burn caps at 5 stacks and generation 4")
	# ---- the Warden's vault slam
	var vw := _world({"mode": "campaign", "stage": 0, "hero": 0, "seed": 3})
	vw.weapons.clear()
	vw.stats.set_source("t", [["max_hp", "add", 1e6]]); vw.hp = 1e6
	vw.terrain.set_test_props(PackedFloat32Array([100.0, 0.0, 18.0, 1.0]))
	var vfoes: Array = []
	for k in 5:
		var vi := vw.spawn_foe(Content.E.GRUNT, Vector2(200, 0) + Vector2.from_angle(TAU * k / 5.0) * 45.0, 0, 0, 1.0)
		vw.sw.spd[vi] = 0.0
		vfoes.append(vw.sw.uid[vi])
	vw._jump(Vector2.RIGHT)
	var vaulted := vw.jump_vaulted
	for k in 50: vw.step(1.0 / 60.0)
	var hurt := 0
	for u in vfoes:
		var j2 := vw.sw.index_of(u)
		if j2 < 0 or vw.sw.hp[j2] < vw.sw.mhp[j2]: hurt += 1
	vw._jump(Vector2.UP)                                # over open ground
	var plain := not vw.jump_vaulted
	ok(vaulted and int(vw.metrics.get("warden_vaults", 0)) == 1 and hurt >= 4 and plain,
		"the Warden's jump over a boulder lands in a crater (%d of 5 foes hit); a jump over open ground does not" % hurt)
	# ---- the Sparkcaller's ricochet off stone
	var sw2 := _world({"mode": "campaign", "stage": 0, "hero": 1, "seed": 4})
	sw2.weapons.clear()
	sw2.terrain.set_test_props(PackedFloat32Array([100.0, 0.0, 18.0, 1.0, 100.0, 200.0, 18.0, 0.0]))
	var rics: Array = []
	sw2.moment.connect(func(k: String, info: Dictionary) -> void: if k == "ricochet": rics.append(int(info.bounces)))
	var bolt: World.Proj = sw2._new_proj()
	bolt.pos = Vector2(60, 0); bolt.vel = Vector2(440, 0); bolt.life = 5.0; bolt.r = 5.0; bolt.dmg = 10.0; bolt.wid = "bolt"
	sw2.projs.append(bolt)
	for k in 12: sw2._step_projs(1.0 / 60.0)
	var first := bolt.bounces == 1 and bolt.vel.x < 0.0 and is_equal_approx(bolt.dmg, 12.5)
	bolt.pos = Vector2(60, 0); bolt.vel = Vector2(440, 0)
	for k in 12: sw2._step_projs(1.0 / 60.0)
	var second := bolt.bounces == 2 and is_equal_approx(bolt.dmg, 15.625) and rics == [2]
	bolt.pos = Vector2(60, 0); bolt.vel = Vector2(440, 0)
	for k in 12: sw2._step_projs(1.0 / 60.0)
	var third_dead := bolt.dead                        # read before the pool hands the same Proj out again
	var wood: World.Proj = sw2._new_proj()
	wood.pos = Vector2(60, 200); wood.vel = Vector2(440, 0); wood.life = 5.0; wood.r = 5.0; wood.dmg = 10.0; wood.wid = "bolt"
	sw2.projs.append(wood)
	for k in 20: sw2._step_projs(1.0 / 60.0)
	ok(first and second and third_dead and wood.bounces == 0 and wood.pos.x > 130.0,
		"a Rime Bolt glances off stone twice (x1.25 each: %.2f), the third stone shatters it, and wood lets it through" % 15.625)
	# ---- the Stormwright's conduction: shallow water (Act V) and rift crystals
	var stw := _world({"mode": "campaign", "stage": 4, "hero": 3, "seed": 8})
	var ST := stw.terrain
	var wet := Vector2.INF
	var dry := Vector2.INF
	for r2 in range(200, 3000, 32):
		for k in 24:
			var q2 := Vector2.from_angle(TAU * k / 24.0) * r2
			if wet == Vector2.INF and ST.type_at(q2) == Terrain.SHALLOW and not ST.is_frozen(q2): wet = q2
			if dry == Vector2.INF and ST.type_at(q2) == Terrain.LAND and ST.crystals_near(q2, 80.0) == 0: dry = q2
		if wet != Vector2.INF and dry != Vector2.INF: break
	var crys := Vector2.INF
	for cy2 in range(-2, 3):
		for cx2 in range(-2, 3):
			var cc := PropLayout.chunk(Vector2i(cx2, cy2), 4, ST, 1.0, false).crystals as PackedVector2Array
			if crys == Vector2.INF and not cc.is_empty(): crys = cc[0]
	var cond_ok := wet != Vector2.INF and stw.conducts(wet) and dry != Vector2.INF and not stw.conducts(dry) and (crys == Vector2.INF or stw.conducts(crys + Vector2(30, 0)))
	var ci := stw.spawn_foe(Content.E.GRUNT, wet, 0, 0, 1.0)
	var near_i := stw.spawn_foe(Content.E.GRUNT, wet + Vector2(50, 0), 0, 0, 1.0)
	var out_i := stw.spawn_foe(Content.E.GRUNT, wet + Vector2(150, 0), 0, 0, 1.0)
	stw.grid.build(stw.sw)
	var h_near := stw.sw.hp[near_i]
	var h_out := stw.sw.hp[out_i]
	var arcs0 := stw.fx.filter(func(f): return f.k == "arc").size()
	stw._conduct(ci, 34.0, 20.0, 1 << Content.El.LIGHT)
	ok(cond_ok and stw.sw.hp[near_i] < h_near and stw.sw.hp[out_i] < h_out and stw.fx.filter(func(f): return f.k == "arc").size() > arcs0
		and int(stw.metrics.get("storm_conducts", 0)) == 1,
		"Skyfall conducts through shallow water and beside a crystal (not on dry land): twice the radius, and an arc branches to a foe outside it")
	# ---- Rift Echoes: two per act, placed by rule (the same run seed: the same spots), on open ground beside
	# the act's arches; touching one surges and speaks
	var ea := _world({"mode": "campaign", "stage": 0, "hero": 0, "seed": 1})
	var eb2 := _world({"mode": "campaign", "stage": 0, "hero": 2, "seed": 1})
	var ec2 := _world({"mode": "campaign", "stage": 0, "hero": 1, "seed": 999})
	var same_e := ea.rift_echoes.size() == 2 and eb2.rift_echoes.size() == 2 and ec2.rift_echoes.size() == 2
	for k in mini(ea.rift_echoes.size(), eb2.rift_echoes.size()):
		if (ea.rift_echoes[k].pos as Vector2).distance_to(eb2.rift_echoes[k].pos) > 0.01: same_e = false
	for wq in [ea, ec2]:
		for e in (wq as World).rift_echoes:
			if (e.pos as Vector2).length() < World.ECHO_MIN or not (wq as World).terrain.passable(e.pos): same_e = false
	var heard: Array = []
	ea.moment.connect(func(k: String, info: Dictionary) -> void: if k == "echo": heard.append(int(info.k)))
	ea.pp = ea.rift_echoes[0].pos
	ea._step_echoes()
	ok(same_e and bool(ea.rift_echoes[0].taken) and ea.buffs.has("rift_surge") and is_equal_approx(ea.buffs.remaining("rift_surge"), Story.ECHO_SURGE_S)
		and heard == [0] and (sv.data.rift_echoes as Array).has(Story.echo_key(0, 0)),
		"two Echo Shards per act beside its arches (the same run seed: the same spots); touching one gives a 10 s Rift Surge, the exchange and the Codex page")
	# ---- the safe-mode sentinel (Options > Renderer and the crash fallback), on a scratch file
	var keep_path := Quality.override_path
	var keep_api: int = int(sv.data.options.get("gfx_api", 0))
	Quality.override_path = "user://test_override.cfg"
	sv.set_opt("gfx_api", Quality.API_VULKAN)
	var armed: bool = Quality.arm_sentinel(true) and Quality.read_api().gl and Quality.read_api().sentinel
	Quality.disarm_sentinel()
	var disarmed := not FileAccess.file_exists(Quality.override_path)
	Quality.arm_sentinel(true)
	var fell: bool = Quality.check_sentinel() and int(sv.opt("gfx_api")) == Quality.API_GL and Quality.read_api().gl and not Quality.read_api().sentinel and Quality.safe_fell_back
	Quality.set_api(Quality.API_VULKAN)
	var back_v := not FileAccess.file_exists(Quality.override_path)
	Quality.override_path = keep_path
	Quality.safe_fell_back = false
	sv.set_opt("gfx_api", keep_api)
	ok(armed and disarmed and fell and back_v, "the crash sentinel: armed on Vulkan, disarmed by a clean end, a crash falls back to OpenGL Safe Mode, Options switches back")
	# ---- the story's data
	var story_ok := Story.ACTS.size() == Content.STAGES.size() and Story.HEROES.size() == 4
	for a in Story.ACTS:
		for k in ["title", "subtitle", "intro_lines", "boss_name", "boss_taunt", "victory_note", "echoes"]:
			if not a.has(k): story_ok = false
		if (a.echoes as Array).size() != 2: story_ok = false
	for i in Content.STAGES.size():
		if String(Story.ACTS[i].boss_name) != String(Content.STAGES[i].boss): story_ok = false
	ok(story_ok, "The Shattering of the Veil: 5 acts (title, subtitle, lore, boss and taunt, victory note, 2 Rift Echoes each), 4 exiles")
	# ---- the menus: every button at least 48 units tall, in landscape and in portrait
	sv.data = sv.defaults()
	sv.data.options.sound = false
	sv.data.intro_seen = true
	var mm: Node = load("res://scenes/main.tscn").instantiate()
	add_child(mm)
	var small: Array = []
	var pages := 0
	var sizes: Array = []
	var root_size := get_tree().root.size
	var root_scale := get_tree().root.content_scale_factor
	# main rescales the canvas from the OS window on every resize, and headless cannot report a phone's: the
	# test plays that part itself, with main's handler detached until it is done
	var on_resize := Callable(mm, "_on_resize")
	if get_tree().root.size_changed.is_connected(on_resize): get_tree().root.size_changed.disconnect(on_resize)
	for orient in [Vector2i(1280, 720), Vector2i(720, 1280)]:
		get_tree().root.size = orient
		await get_tree().process_frame                 # main's resize handler runs first (it sets the scale from the window)
		# what main._ui_scale does on a portrait phone (headless cannot report the window): the canvas scaled
		# so the 1280 x 720 design base becomes a 720-unit-wide portrait page
		get_tree().root.content_scale_factor = 1.0 if orient.x > orient.y else float(orient.y) / float(orient.x)
		await get_tree().process_frame
		sizes.append(mm.screens.get_viewport_rect().size)
		if mm.world != null: mm._on_act("leave", null)
		pages += _menu_pages(mm, small)
	get_tree().root.size = root_size
	get_tree().root.content_scale_factor = root_scale
	get_tree().root.size_changed.connect(on_resize)
	var portrait_seen: bool = sizes.size() == 2 and (sizes[1] as Vector2).x < 820.0 and (sizes[0] as Vector2).x >= 820.0
	mm.free()
	VoiceBank.stop_all()
	sv.data = keep
	ok(pages == 14 and small.is_empty() and portrait_seen, "every button on the main menu, Heroes, Codex, Options (4 tabs), Pause, Build & Stats and a confirmation is at least %d tall, landscape and portrait (%s)%s" % [UIKit.MIN_TOUCH, str(sizes), ("" if small.is_empty() else ": " + str(small.slice(0, 4)))])

## Every page _alpha10_tests checks for touch targets, in the current window; returns how many were shown.
func _menu_pages(mm: Node, small: Array) -> int:
	var pages := 0
	for page in ["menu", "heroes", "codex", "options", "pause", "build", "confirm"]:
		match page:
			"menu": mm.screens.show_menu()
			"heroes": mm.screens.show_heroes()
			"codex": mm.screens.show_codex("menu")
			"options":
				for tab in 4:
					mm.screens._opt_tab = tab
					mm.screens.show_options("menu")
					small.append_array(_small_buttons(mm.screens, "options %d" % tab))
				mm.screens._opt_tab = 0
				pages += 1
				continue
			"pause":
				mm._on_act("campaign", 0)
				mm._pause()
			"build": mm._on_act("build", null)
			"confirm": mm.screens.confirm("Leave this run?", "", "Leave", "leave")
		small.append_array(_small_buttons(mm.screens, page))
		pages += 1
	mm._on_act("leave", null)
	return pages

func _small_buttons(root: Node, label: String) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Button and (n as Control).visible:
			var h := maxf((n as Control).custom_minimum_size.y, (n as Control).get_combined_minimum_size().y)
			if h < UIKit.MIN_TOUCH: out.append("%s: %s (%d)" % [label, (n as Button).text, int(h)])
		stack.append_array(n.get_children())
	return out

## 0.10.3: the voice pack is in. Every manifest line has its clip, imported and never looping, and VoiceBank plays
## each from the pack at the clip's own length (a speaker's chime is now only for a clip that goes missing).
func _pack_tests() -> void:
	print("== 0.10.3 voice pack")
	var vb := _voice_bank()
	var missing: Array = []
	var looping: Array = []
	var not_played: Array = []
	var total := 0.0
	for id in vb.entries:
		var e: Dictionary = vb.entries[id]
		if not ResourceLoader.exists(String(e.file)):
			missing.append(id)
			continue
		var st := load(String(e.file)) as AudioStreamOggVorbis
		if st == null or st.loop: looping.append(id)
		vb.stop_now()
		vb.step(60.0)                                   # past every cooldown and the gap between lines
		var r := vb.say(String(e.speaker), String(e.cue), int(e.variant))
		if not bool(r.played) or not bool(r.using_pack) or st == null or absf(float(r.duration) - st.get_length()) > 0.001:
			not_played.append("%s (%s)" % [id, r.get("reason", "chime") if not bool(r.get("using_pack", false)) else "length"])
		else:
			total += float(r.duration)
	vb.stop_now()
	vb.queue_free()
	ok(missing.is_empty() and looping.is_empty(), "all %d lines have their clip, imported as Ogg Vorbis that never loops%s" % [vb.entries.size(),
		("  (missing: " + ", ".join(missing.slice(0, 6)) + ")") if not missing.is_empty() else (("  (looping: " + ", ".join(looping) + ")") if not looping.is_empty() else "")])
	ok(not_played.is_empty(), "each plays from the pack at its own length: %.0f s of speech in all%s" % [total, ("  (" + ", ".join(not_played.slice(0, 6)) + ")") if not not_played.is_empty() else ""])

## 0.10.4 performance: each optimised hot loop is checked against the plain definition of what it computes.
func _perf_tests() -> void:
	print("== 0.10.4 performance")
	var w := _world({"mode": "rift", "hero": 3, "gr": 1, "seed": 5})
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	while w.sw.n < 400:                               # a packed crowd: about 13 foes to every 64-unit square
		w.spawn_foe(Content.E.GRUNT + w.sw.n % 4, w.pp + Vector2(rng.randf_range(-200, 200), rng.randf_range(-150, 150)), 0, 0, 50.0)
	var a := _sep_check(w)
	# two boss-sized bodies in the crowd: their pushes come from separation's own pass for big bodies
	for k in 2:
		w.sw.add(Content.E.GRUNT, w.pp + Vector2(60.0 - 120.0 * k, 20.0), 1000.0, 0.0, [36.0, 44.0][k], 0.0, 0.0, Swarm.F_BOSS, 0)
	var b := _sep_check(w)
	ok(a[1] == 0 and b[1] == 0 and a[0] > 500 and b[2] > 10, "separation on its own fine grid matches the all-pairs definition for every swarm foe: %d pushes, then %d with two bosses in the crowd (%d of them by a boss); %d and %d differ by over 1e-3" % [a[0], b[0], b[2], a[1], b[1]])
	# the swarm's terrain step, inlined: bit-identical to 0.10.3's foe_move on moves through Act I's forest
	var fw := _world({"mode": "campaign", "stage": 0, "hero": 0, "seed": 41})
	var T := fw.terrain
	var frng := RandomNumberGenerator.new()
	frng.seed = 7
	var moves := 0
	var fdiff := 0
	var pushed_by_props := 0
	var cases: Array = []
	for k in 6000:
		var p0 := fw.pp + Vector2(frng.randf_range(-1400, 1400), frng.randf_range(-1400, 1400))
		var step := Vector2.from_angle(frng.randf() * TAU) * (frng.randf_range(0.5, 3.0) if k % 5 != 0 else frng.randf_range(8.0, 40.0))
		var br := frng.randf_range(7.0, 18.0)
		cases.append([p0, p0 + step, br])
	for c in cases:
		var ref := _foe_move_ref(T, c[0], c[1], c[2])
		if T.props_resolve(c[1], c[2]) != c[1]: pushed_by_props += 1
		var got: Vector2 = T.foe_move(c[0], c[1], c[2])
		moves += 1
		if got != ref: fdiff += 1
	# Act V with its tide risen 20 units: cells reclassify live, shallows slow and deep water blocks
	var tw := _world({"mode": "campaign", "stage": 4, "hero": 0, "seed": 41})
	var TT := tw.terrain
	TT.level = TT.level0 + 20.0
	var wet := 0
	for c in cases:
		var p5: Vector2 = tw.pp + (c[0] - fw.pp)
		var n5: Vector2 = tw.pp + (c[1] - fw.pp)
		if TT.is_liquid(p5): wet += 1
		if TT.foe_move(p5, n5, c[2]) != _foe_move_ref(TT, p5, n5, c[2]): fdiff += 1
		moves += 1
	ok(fdiff == 0 and pushed_by_props > 100 and TT.tide > 0.0 and wet > 200, "foe_move, one-step case and cell lookup inlined: identical to 0.10.3's on %d moves through Act I's forest and Act V under a risen tide (%d pushed by a prop, %d starting in water), %d differ" % [moves, pushed_by_props, wet, fdiff])
	if OS.get_environment("PERF_BENCH") != "":
		var tb := INF
		var tr := INF
		for round in 5:
			var t0 := Time.get_ticks_usec()
			for c in cases: T.foe_move(c[0], c[1], c[2])
			var t1 := Time.get_ticks_usec()
			for c in cases: _foe_move_ref(T, c[0], c[1], c[2])
			var t2 := Time.get_ticks_usec()
			tb = minf(tb, (t1 - t0) / float(cases.size()))
			tr = minf(tr, (t2 - t1) / float(cases.size()))
		print("  PERF foe_move: %.2f us a move (0.10.3: %.2f us)" % [tb, tr])
	if OS.get_environment("PERF_BENCH") != "":     # timing on the frozen crowd: best of 7 rounds of 60 calls
		var best := INF
		for round in 7:
			var t0 := Time.get_ticks_usec()
			for k in 60: w.sw.cpu_separation(w.grid, k % 2, w.pp, INF)
			best = minf(best, (Time.get_ticks_usec() - t0) / 60000.0)
		print("  PERF separation, %d foes: %.3f ms a call" % [w.sw.n, best])

## The 3D view's per-frame foe instance writer, optimised in 0.10.4, against the 0.10.3 code on a real frame: a
## campaign run through main.tscn with a mixed crowd (elites, a charging Ramshard, frozen, burning, poisoned).
func _perf_view_tests() -> void:
	var sv: Node = get_node("/root/Save")
	var keep: Dictionary = sv.data
	sv.data = sv.defaults()
	sv.data.options.sound = false
	sv.data.intro_seen = true
	Diag.crashed_last = false
	var mn: Node = load("res://scenes/main.tscn").instantiate()
	add_child(mn)
	await get_tree().process_frame
	mn.start({"mode": "campaign", "stage": 0})
	var w: World = mn.world
	w.stats.set_source("t", [["max_hp", "add", 1e6]])
	w.hp = 1e6
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for k in 160:
		var kind: int = [Content.E.GRUNT, Content.E.RUNNER, Content.E.BRUTE, Content.E.SPITTER, Content.E.CHARGER][k % 5]
		var i := w.spawn_foe(kind, w.pp + Vector2(rng.randf_range(-400, 400), rng.randf_range(-260, 260)), 1 if k % 11 == 0 else 0)
		if i < 0: continue
		match k % 7:
			1: w.sw.set_freeze(i, 2.0)
			2: w.sw.set_burn(i, 3, 5.0, 1, 3.0)
			3: w.sw.pois[i] = 4.0
			4: w.sw.set_ai(i, 2, 0.4)
	for f in 6: await get_tree().process_frame
	var V: WorldView3D = mn.view3d
	var diff := 0
	var written := 0
	for k in V._foe_mm.size():
		var size: int = (V._start[k + 1] - V._start[k]) * WorldView3D.FOE_STRIDE
		if size == 0: continue
		var a := PackedFloat32Array()
		a.resize(size)
		var b := PackedFloat32Array()
		b.resize(size)
		var na: int = V._write_foes(a, k, w.sw, V.hero_p)
		var nb: int = _write_foes_ref(V, b, k, w.sw, V.hero_p)
		written += na
		if na != nb or a != b: diff += 1
	ok(diff == 0 and written > 100, "the 3D view's foe instances, swarm arrays read through locals: the same buffers as 0.10.3's writer for every kind (%d foes written, %d kinds differ)" % [written, diff])
	mn._free_world()                                  # the run's World holds reference cycles: dispose of it
	mn.queue_free()
	sv.data = keep

## 0.10.4 streaming (docs/OPTIMIZATION.md O6): what a chunk crossing costs the 3D view. The hero walks east
## through 8 chunks of Act I (the world ticking between crossings, as walking does), and each crossing frame's
## prop cells (WorldView3D._props) and terrain textures (_terrain_tex) are timed; PERF_BENCH=1 prints them.
func _stream_tests() -> void:
	print("== 0.10.4 streaming")
	var sv: Node = get_node("/root/Save")
	var keep: Dictionary = sv.data
	sv.data = sv.defaults()
	sv.data.options.sound = false
	sv.data.intro_seen = true
	Diag.crashed_last = false
	var mn: Node = load("res://scenes/main.tscn").instantiate()
	add_child(mn)
	await get_tree().process_frame
	mn.start({"mode": "campaign", "stage": int(OS.get_environment("STREAM_ACT")) if OS.get_environment("STREAM_ACT") != "" else 0})
	var w: World = mn.world
	w.stats.set_source("t", [["max_hp", "add", 1e6]])
	w.hp = 1e6
	for f in 4: await get_tree().process_frame
	var V: WorldView3D = mn.view3d
	mn.set_process(false)                       # the walk below drives the world and the view itself
	V.set_process(false)
	var T := w.terrain
	var rows: Array = []
	while not V._prop_queue.is_empty(): V._props()     # the start's outer ring (the first frames build it)
	var gen0 := T.generated
	for k in 8:
		var x := (k + 1) * Terrain.CHUNK + 8.0
		# the walk up to the border: 90 ticks inside the chunk before (the world prefetches as it goes)
		w.pp = Vector2(x - Terrain.CHUNK * 0.5, 40.0)
		w.prev_pp = w.pp
		for i in 90: w.step(FixedStep.STEP)
		w.pp = Vector2(x, 40.0)
		w.prev_pp = w.pp
		var g := T.generated
		var t0 := Time.get_ticks_usec()
		V._terrain_tex(FixedStep.STEP)              # the frame's order: _camera (the textures), then _props
		var t1 := Time.get_ticks_usec()
		V._props()
		var t2 := Time.get_ticks_usec()
		# and the frames after it, while the crossing's queued cells are built (the worst of them)
		var after := 0.0
		for f in 8:
			var f0 := Time.get_ticks_usec()
			V._terrain_tex(FixedStep.STEP)
			V._props()
			after = maxf(after, (Time.get_ticks_usec() - f0) / 1000.0)
		rows.append([(t2 - t1) / 1000.0, (t1 - t0) / 1000.0, T.generated - g, after])
	# then back west over the same ground: the cells come from the cache (only their nodes are made)
	var back := 0.0
	for k in 4:
		var x := (7 - k) * Terrain.CHUNK - 8.0
		w.pp = Vector2(x + Terrain.CHUNK * 0.5, 40.0)
		w.prev_pp = w.pp
		for i in 30: w.step(FixedStep.STEP)
		w.pp = Vector2(x, 40.0)
		w.prev_pp = w.pp
		for f in 9:
			var f0 := Time.get_ticks_usec()
			V._terrain_tex(FixedStep.STEP)
			V._props()
			back = maxf(back, (Time.get_ticks_usec() - f0) / 1000.0)
	var props := 0.0
	var tex := 0.0
	var worst := 0.0
	var worst_after := 0.0
	var gen_in := 0
	for r in rows:
		props += r[0]
		tex += r[1]
		worst = maxf(worst, r[0] + r[1])
		worst_after = maxf(worst_after, r[3])
		gen_in += int(r[2])
	if OS.get_environment("PERF_BENCH") != "":
		print("  STREAM crossings %d: props %.2f ms, terrain textures %.2f ms a crossing (worst crossing %.2f ms; worst frame after one %.2f ms), %d chunks generated in crossing frames (%d in all)" % [
			rows.size(), props / rows.size(), tex / rows.size(), worst, worst_after, gen_in, T.generated - gen0])
		print("  STREAM walking back over 4 crossings: the worst frame %.2f ms (cells from the cache)" % back)
		print("  STREAM per crossing [props ms, textures ms, chunks generated, worst frame after]: " + str(rows.map(func(r): return [snappedf(r[0], 0.01), snappedf(r[1], 0.01), r[2], snappedf(r[3], 0.01)])))
	ok(rows.size() == 8 and V._prop_cells.size() == 25 and V._prop_queue.is_empty(), "the hero walks through 8 chunk crossings; 25 prop cells stand around it once the queue drains (%d)" % V._prop_cells.size())
	var want_cells := 0
	var cc := Vector2i(floori(w.pp.x / WorldView3D.CHUNK), floori(w.pp.y / WorldView3D.CHUNK))
	for c in V._prop_cells:
		if maxi(absi(c.x - cc.x), absi(c.y - cc.y)) <= 2: want_cells += 1
	ok(want_cells == 25, "and they are the 5 x 5 around the hero's chunk (%d of 25)" % want_cells)
	# a teleport (a run's start, a portal) builds the hero's chunk and its ring at once, the outer ring after
	w.pp = Vector2(50.0 * Terrain.CHUNK + 300.0, 7.0 * Terrain.CHUNK + 300.0)
	w.prev_pp = w.pp
	for dy in range(-3, 4):
		for dx in range(-3, 4): T.chunk(Vector2i(50 + dx, 7 + dy))
	V._terrain_tex(FixedStep.STEP)
	V._props()
	var core := 0
	for c in V._prop_cells:
		if maxi(absi(c.x - 50), absi(c.y - 7)) <= 1: core += 1
	ok(core == 9 and V._prop_queue.size() == 16, "a teleport: the 3 x 3 around the hero at once (%d), the outer 16 queued (%d)" % [core, V._prop_queue.size()])
	# cell_parts writes upright props straight into the buffers: the same as dress_chunk's transforms, batched
	# as 0.10.3's _build_cell did (rotation within float rounding, positions exact), on chunks of every act
	var worst_d := 0.0
	var bad := 0
	var inst := 0
	for k in 12:
		var c := Vector2i(50 + (k % 3) - 1, 7 + (k / 3) % 3 - 1)
		var got := V.cell_parts(c)
		var want := _cell_parts_ref(V, c)
		if got.size() != want.size():
			bad += 1
			continue
		for i in got.size():
			var a: PackedFloat32Array = got[i][3]
			var b2: PackedFloat32Array = want[i][3]
			if got[i][0] != want[i][0] or got[i][4] != want[i][4] or got[i][2] != want[i][2] or a.size() != b2.size():
				bad += 1
				continue
			inst += int(got[i][4])
			for j in a.size():
				var d := absf(a[j] - b2[j])
				if j % 4 == 3:
					if d != 0.0: bad += 1               # the origin column: exact
				else: worst_d = maxf(worst_d, d)
	ok(bad == 0 and worst_d == 0.0 and inst > 1000, "prop cells as one buffer a batch: the same batches and transforms as 0.10.3's per-instance writes (%d instances, %d differ)" % [inst, bad])
	var cached: Array = V._cell_data(Vector2i(50, 7))
	var again: Array = V._cell_data(Vector2i(50, 7))
	var fresh := V.cell_parts(Vector2i(50, 7))
	var same := cached == again and cached.size() == fresh.size()
	for i in mini(cached.size(), fresh.size()):
		if cached[i][3] != fresh[i][3] or cached[i][0] != fresh[i][0]: same = false
	ok(same and V._cell_cache.size() <= WorldView3D.CELL_CACHE, "a cached cell is the one cell_parts builds; the cache holds at most %d (%d)" % [WorldView3D.CELL_CACHE, V._cell_cache.size()])
	# chunk generation: every act's heights and types, the same as 0.10.3's _raw (its profile read per sample)
	var gdiff := 0
	var gen_us := 1e9
	for act in 5:
		var TT := Terrain.new(act, 77 + act, Content.TERRAIN[act])
		var t0 := Time.get_ticks_usec()
		for k in 6:
			var c := Vector2i(k - 3, (k * 7) % 5 - 2)
			var ch: Array = TT.chunk(c)
			var B := Terrain.CN + 2
			var x0 := c.x * Terrain.CHUNK - Terrain.CELL * 0.5
			var y0 := c.y * Terrain.CHUNK - Terrain.CELL * 0.5
			var hs: PackedFloat32Array = ch[0]
			for j in Terrain.CN:
				for i in Terrain.CN:
					var want := PackedFloat32Array([_raw_ref(TT, x0 + (i + 1) * Terrain.CELL, y0 + (j + 1) * Terrain.CELL)])[0]
					if hs[j * Terrain.CN + i] != want: gdiff += 1
		gen_us = minf(gen_us, float(Time.get_ticks_usec() - t0))
	ok(gdiff == 0, "terrain chunks of all five acts: heights identical to 0.10.3's (%d cells differ)" % gdiff)
	if OS.get_environment("STREAM_PARTS") != "":         # one cell's build, in parts (best of 3 rounds of 10 chunks, terrain ready)
		var best := [1e9, 1e9, 1e9, 1e9]
		var items := 0
		for c in range(40, 50):
			for dy in range(2, 5):
				for dx in range(-1, 2): T.chunk(Vector2i(c + dx, dy))
		for round in 3:
			var us := [0.0, 0.0, 0.0, 0.0]
			items = 0
			for k in 10:
				var c := Vector2i(40 + k, 3)
				var a0 := Time.get_ticks_usec()
				var lay := PropLayout.chunk(c, w.stage, T, Quality.prop_density())
				var a1 := Time.get_ticks_usec()
				var lists := V.dress_chunk(c)
				var a2 := Time.get_ticks_usec()
				var parts := V.cell_parts(c)
				var a3 := Time.get_ticks_usec()
				var cell := V._build_cell(c)
				var a4 := Time.get_ticks_usec()
				us[0] += a1 - a0
				us[1] += a2 - a1
				us[2] += a3 - a2
				us[3] += a4 - a3
				items += lay.items.size()
				cell.free()
			for i in 4: best[i] = minf(best[i], us[i])
		print("  STREAM a cell (best of 3 x 10 fresh chunks): PropLayout.chunk %.2f ms, dress_chunk (layout + transforms) %.2f ms, cell_parts (+ batches, buffers) %.2f ms, _build_cell (all of it) %.2f ms, %d items" % [
			best[0] / 10000.0, best[1] / 10000.0, best[2] / 10000.0, best[3] / 10000.0, items / 10])
	# the Emberwitch's fire loops ship baked (tools/bake_loops.sh): loading them is not synthesizing 10 s of audio
	var sfx := get_node("/root/Sfx")
	for spec in [["fire_crackle", 4.0, false], ["fire_rumble", 6.0, true]]:
		sfx.streams.erase(spec[0])
		var f0 := Time.get_ticks_usec()
		var st: AudioStream = sfx._fire_loop(spec[0], spec[1], spec[2])
		var ms := (Time.get_ticks_usec() - f0) / 1000.0
		ok(st is AudioStreamOggVorbis and (st as AudioStreamOggVorbis).loop and absf(st.get_length() - float(spec[1])) < 0.05 and ms < 25.0,
			"the %s loop is the baked file, looping, %.2f s, loaded in %.1f ms" % [spec[0], st.get_length() if st != null else 0.0, ms])
	mn._free_world()
	mn.queue_free()
	sv.data = keep

## 0.10.3's prop batching (_build_cell: dress_chunk's transforms, grass by quarter), as [kind, mesh, AABB, buffer, n].
func _cell_parts_ref(V: WorldView3D, c: Vector2i) -> Array:
	var out := []
	var lists := V.dress_chunk(c)
	for kind in lists:
		var list: Array = lists[kind]
		if list.is_empty(): continue
		var mesh := Models.prop_mesh(kind, V.w.stage)
		if mesh == null: continue
		var parts := [list]
		var boxes := [AABB(Vector3(c.x * WorldView3D.CHUNK, -200.0, c.y * WorldView3D.CHUNK), Vector3(WorldView3D.CHUNK, 600.0, WorldView3D.CHUNK))]
		if WorldView3D.NEAR_ONLY.has(kind):
			parts = [[], [], [], []]
			boxes = []
			var half := WorldView3D.CHUNK * 0.5
			for q in 4:
				boxes.append(AABB(Vector3(c.x * WorldView3D.CHUNK + (q % 2) * half, -200.0, c.y * WorldView3D.CHUNK + (q / 2) * half), Vector3(half, 600.0, half)))
			for t in list:
				var o: Vector3 = (t as Transform3D).origin
				var qx := 1 if o.x - c.x * WorldView3D.CHUNK >= half else 0
				var qz := 1 if o.z - c.y * WorldView3D.CHUNK >= half else 0
				parts[qz * 2 + qx].append(t)
		for pi in parts.size():
			if (parts[pi] as Array).is_empty(): continue
			out.append([kind, mesh, boxes[pi], WorldView3D.tbuf(parts[pi]), (parts[pi] as Array).size()])
	return out

## 0.10.3's Terrain._raw: the act profile read per sample (the reference for the hoisted one).
func _raw_ref(T: Terrain, x: float, y: float) -> float:
	var prof := T.prof
	var amp: float = prof.get("amp", 80.0)
	var b := clampf(T._base.get_noise_2d(x, y) * 1.6, -1.0, 1.0)
	var h := b * amp
	var steps := int(prof.get("terraces", 0))
	if steps > 0:
		var u := (b * 0.5 + 0.5) * steps
		var f := u - floorf(u)
		var w := lerpf(0.035, 0.42, clampf(T._ramp.get_noise_2d(x, y) * 1.4 + 0.5, 0.0, 1.0))
		var s := smoothstep(0.5 - w, 0.5 + w, f)
		h = ((floorf(u) + s) / steps * 2.0 - 1.0) * amp
	var rw: float = prof.get("river", 0.0)
	if rw > 0.0:
		var rv := absf(T._river.get_noise_2d(x, y))
		var carve := smoothstep(rw, rw * 0.35, rv)
		h = lerpf(h, T.level0 - float(prof.get("river_depth", 26.0)), carve)
	h += T._detail.get_noise_2d(x, y) * float(prof.get("detail", 4.0))
	var d := sqrt(x * x + y * y)
	if d < T.flat_r + 220.0:
		h = lerpf(h, T.flat_h, smoothstep(T.flat_r + 220.0, T.flat_r, d))
	return h

## 0.10.3's WorldView3D._write_foes, kept as the reference the optimised one must match bit for bit.
func _write_foes_ref(V: WorldView3D, buf: PackedFloat32Array, k: int, sw: Swarm, pp: Vector2) -> int:
	var c := V._kind_col[k]
	var vc: PackedFloat32Array = V._vc[k]
	var authored := not vc.is_empty()
	var unit := V._foe_unit[k] if k < V._foe_unit.size() else 1.0
	var n := 0
	# the ground height goes into the instance transform (foe.gdshader does no terrain lookup): ground_y's
	# window lookup inlined, through locals, since this runs for every foe on screen every frame
	var hd := V._hd
	var hn := V._hn
	var hox := V._hox
	var hoz := V._hoz
	for v in range(V._start[k], V._start[k + 1]):
		var i := V._order[v]
		var p := V._ipos[i]
		var dpl := p.distance_to(pp)
		var f := sw.flags[i]
		var dir := (pp - p) / maxf(0.001, dpl)
		if (f & Swarm.F_GOBLIN) != 0: dir = -dir
		elif k == Content.E.CHARGER and sw.ai_s[i] == 2: dir = sw.dir[i]
		elif (f & Swarm.F_ALLY) != 0 and sw.dir[i] != Vector2.ZERO: dir = sw.dir[i]
		var gy := 0.0
		var fx := (p.x - hox) * WorldView3D.INV_CELL - 0.5
		var fz := (p.y - hoz) * WorldView3D.INV_CELL - 0.5
		if hn > 0 and fx >= 0.0 and fz >= 0.0 and fx < hn - 1 and fz < hn - 1:
			var ix := int(fx)
			var iz := int(fz)
			var kk := iz * hn + ix
			var ga := lerpf(hd[kk], hd[kk + 1], fx - ix)
			gy = lerpf(ga, lerpf(hd[kk + hn], hd[kk + hn + 1], fx - ix), fz - iz)
		else:
			gy = V.ground_y(p)
		var o := n * WorldView3D.FOE_STRIDE
		var s := sw.rad[i] * unit
		# basis columns: x = (dir.x, 0, dir.y) * s (model +X faces the heading), y = up * s, z = (-dir.y, 0, dir.x) * s
		buf[o] = dir.x * s; buf[o + 1] = 0.0; buf[o + 2] = -dir.y * s; buf[o + 3] = p.x
		buf[o + 4] = 0.0; buf[o + 5] = s; buf[o + 6] = 0.0; buf[o + 7] = gy
		buf[o + 8] = dir.y * s; buf[o + 9] = 0.0; buf[o + 10] = dir.x * s; buf[o + 11] = p.y
		# per-instance colour and custom data reach the GPU as 16-bit halves (exact integers only to
		# 2048): the seed rides in the colour's alpha, flags alone in custom.w, and the walk phase is
		# wrapped to whole cycles (it used to grow with time, and flag+256*seed decoded as random elite
		# and ally bits: the swarm sparkled with their rim glows)
		buf[o + 12] = c.r; buf[o + 13] = c.g; buf[o + 14] = c.b; buf[o + 15] = float(sw.uid[i] % 64) / 63.0
		var moving := 0.0 if sw.freeze_t[i] > 0.0 else 1.0
		var ph := fposmod(V.time * (4.0 + sw.spd[i] * 0.05) * moving + float(sw.uid[i]) * 1.37, TAU * 8.0)
		if not authored:
			buf[o + 16] = ph
		else:
			# authored clips (vertex animation texture): spawn, then attack, then a flinch, else the walk
			# cycle; the value is the frame row, which the shader blends with the next one
			var age := V.w.t - sw.born[i]
			var ta := V.w.t - sw.atk_t[i]
			var th := V.w.t - sw.hit_at[i]
			if vc[13] > 0.0 and age * vc[14] < vc[13] - 1.0:
				buf[o + 16] = vc[12] + age * vc[14]
			elif vc[4] > 0.0 and ta * vc[5] < vc[4] - 1.0:
				buf[o + 16] = vc[3] + ta * vc[5]
			elif vc[7] > 0.0 and th * vc[8] * 1.6 < vc[7] - 1.0:
				buf[o + 16] = vc[6] + th * vc[8] * 1.6
			else:
				buf[o + 16] = vc[0] + fposmod(ph / TAU, 1.0) * vc[1]
		buf[o + 17] = maxf(0.0, sw.flash[i])
		buf[o + 18] = V._status_code(i)
		# the Emberwitch's Burn stacks ride over the flag bits (flags + 256 x stacks <= 1535, exact as a half);
		# foe.gdshader reads them back as burn_norm = stacks / 5 for the ember crust
		buf[o + 19] = float(f & 0xff) + 256.0 * float(sw.burn_stacks[i])
		n += 1
	return n


## 0.10.3's Terrain.foe_move, from the terrain's public helpers: the reference the inlined one must match.
func _foe_move_ref(T: Terrain, p: Vector2, np: Vector2, body_r: float) -> Vector2:
	var cp := T.cell_of(p)
	var t := T.cell_type(cp.x, cp.y)
	if t == Terrain.SHALLOW and not T.frozen.has(cp):
		np = p + (np - p) * 0.65
	if body_r <= 0.0 or not T.props_on:
		return np if T.cell_of(np) == cp else T._move_cells(p, np)
	var d := np - p
	if d.length_squared() <= body_r * body_r: return _foe_step_ref(T, p, np, body_r)
	var n := ceili(d.length() / body_r)
	var at := p
	for k in n:
		var q := _foe_step_ref(T, at, at + d / n, body_r)
		if q == at: break
		at = q
	return at

func _foe_step_ref(T: Terrain, p: Vector2, np: Vector2, body_r: float) -> Vector2:
	var q := np if T.cell_of(np) == T.cell_of(p) else T._move_cells(p, np)
	var r := T.props_resolve(q, body_r)
	if r != q and not T.passable(r) and T.passable(q): return p
	return r

## [pushes compared, pushes differing by over 1e-3, swarm foes a boss overlaps] for both parities, with and without
## the visibility cull, against the all-pairs definition (bosses ignore their own push, so only swarm foes count).
func _sep_check(w: World) -> Array:
	var sw := w.sw
	var compared := 0
	var differ := 0
	var by_boss := 0
	for par in [0, 1]:
		for vis in [INF, 160.0]:
			var ref := sw.sep.duplicate()
			var start: int = par
			for i in range(start, sw.n, 2):
				var p := sw.pos[i]
				if p.distance_squared_to(w.pp) > vis * vis:
					ref[i] = Vector2.ZERO
					continue
				var push := Vector2.ZERO
				for j in sw.n:
					if j == i: continue
					var dd := p.distance_squared_to(sw.pos[j])
					var rr := sw.rad[i] + sw.rad[j]
					if dd < rr * rr and dd > 0.0001:
						var dl := sqrt(dd)
						push += (p - sw.pos[j]) / dl * (rr - dl)
						if sw.rad[j] > Swarm.SEP_SMALL_R and par == 0 and vis == INF: by_boss += 1
				ref[i] = push * 6.0
			sw.cpu_separation(w.grid, par, w.pp, vis)
			for i in sw.n:
				if sw.rad[i] > Swarm.SEP_SMALL_R: continue
				if sw.sep[i].distance_to(ref[i]) > 1e-3: differ += 1
				elif ref[i] != Vector2.ZERO: compared += 1
	return [compared, differ, by_boss]

## 0.10.4 voice pacing (docs/OPTIMIZATION.md O5): a cast bark at most once a minute per exile, a streak bark every 30 s,
## no line of priority 0-2 again within 90 s (an escalation line within 180 s), story lines (priority 3) always.
func _pacing_tests() -> void:
	print("== 0.10.4 voice pacing")
	var vb := _voice_bank()
	var cd := float(vb.line("spark", "cast", 0).cooldown_s)
	# random cast barks, each tried just after the cue's cooldown: no line twice within REPEAT_S
	var said: Array = []
	var twice := 0
	for k in 8:
		var r := vb.say("spark", "cast")
		if bool(r.played):
			for e in said:
				if e[1] == String(r.id) and vb.now - float(e[0]) < VoiceBank.REPEAT_S: twice += 1
			said.append([vb.now, String(r.id)])
		vb.stop_now()
		vb.step(cd + 1.0)
	ok(cd >= 60.0 and twice == 0 and said.size() >= 6, "cast barks: a %.0f s cooldown, and in %d plays over %.0f s none repeats within %.0f s" % [cd, said.size(), vb.now, VoiceBank.REPEAT_S])
	# an escalation line (the Sparkcaller's second ricochet): once, then not again for 2 x REPEAT_S
	var esc := vb.escalation_variant("spark", "ricochet_2")
	vb.stop_now()
	vb.step(VoiceBank.REPEAT_S * 2.0 + 1.0)
	var e1 := vb.say("spark", "cast", esc)
	vb.stop_now()
	vb.step(cd + 1.0)
	var e2 := vb.say("spark", "cast", esc)
	vb.stop_now()
	vb.step(VoiceBank.REPEAT_S * 2.0)
	var e3 := vb.say("spark", "cast", esc)
	ok(esc >= 0 and bool(e1.played) and not bool(e2.played) and String(e2.get("reason", "")) == "repeat" and bool(e3.played),
		"an escalation line plays, is refused as a repeat %.0f s later, and plays again after %.0f s" % [cd + 1.0, VoiceBank.REPEAT_S * 2.0])
	# story lines are never held back as repeats: an exile's intro twice in a row
	vb.stop_now()
	var i1 := vb.say("ember", "intro", 0)
	vb.stop_now()
	var i2 := vb.say("ember", "intro", 0)
	ok(bool(i1.played) and bool(i2.played), "story lines (priority 3) always play: the Emberwitch's intro twice in a row")
	vb.stop_now()
	vb.queue_free()

## How often the voices speak in a real run: bot-played campaign acts (8 minutes, the boss at the end) for each
## exile, with the game's VoiceDirector and VoiceBank on the run's clock. Prints, per run, lines a minute by cue,
## the share of the time someone is speaking, the same line again within a minute, and the longest silence.
func _voice_sim() -> void:
	print("== voice frequency (bot-played acts)")
	var dt := 1.0 / 60.0
	for hero in 4:
		var w := _world({"mode": "campaign", "stage": hero % 3, "hero": hero, "seed": 300 + hero})
		var vb := _voice_bank()
		var vd := VoiceDirector.new()
		vd.manual_clock = true
		vd.bank = vb
		add_child(vd)
		vd.bind(w)
		var log: Array = []
		vb.line_started.connect(func(info): log.append([vb.now, String(info.id), String(info.cue), String(info.speaker), float(info.duration)]))
		var bot := Bot.new(w, 11 + hero)
		while not w.over and w.t < 480.0:
			bot.think()
			w.step(dt)
			vd.step(dt)
			vb.step(dt)
			if not w.whisper_offer.is_empty(): w.accept_bargain(Bot.bargain(w.whisper_offer, hero))
			while w.pending > 0: w.apply_choice(Bot.pick(w.make_choices(), w))
		var mins := maxf(0.01, w.t / 60.0)
		var by := {}
		var talk := 0.0
		var again := 0
		var last_at := {}
		var gap := 0.0
		var prev_end := 0.0
		for e in log:
			by[e[2]] = int(by.get(e[2], 0)) + 1
			talk += e[4]
			if last_at.has(e[1]) and e[0] - float(last_at[e[1]]) < 60.0:
				again += 1
				if OS.get_environment("VOICE_SIM_REPEATS") != "": print("    repeat %s after %.0f s" % [e[1], e[0] - float(last_at[e[1]])])
			last_at[e[1]] = e[0]
			gap = maxf(gap, e[0] - prev_end)
			prev_end = e[0] + e[4]
		gap = maxf(gap, w.t - prev_end)
		print("  %s, act %d, %.1f min%s: %d lines, %.1f a minute, speaking %.0f%% of the time, %d repeats within a minute, longest silence %.0f s" % [
			Content.HEROES[hero].name, w.stage + 1, mins, (" (died)" if w.over and not w.won else ""), log.size(), log.size() / mins, 100.0 * talk / maxf(1.0, w.t), again, gap])
		print("    by cue: " + ", ".join(by.keys().map(func(k): return "%s %.1f/min" % [k, by[k] / mins])))
		vd.unbind()
		vd.queue_free()
		vb.queue_free()

## The gate's drop-in check (tools/gate_check.py): a clip encoded by tools/gen_voices.py at a real line's path
## (narrator act_0), imported by Godot, must play instead of the chime at its own length, never looping.
func _voice_dropin_tests() -> void:
	print("== voice drop-in")
	var vb := _voice_bank()
	var ln := vb.line("narrator", "act_0", 0)
	var r := vb.say("narrator", "act_0", 0)
	var st: AudioStream = vb.active_player().stream if vb.active_player() != null else null
	ok(bool(r.using_pack) and st is AudioStreamOggVorbis and absf(float(r.duration) - st.get_length()) < 0.001 and not (st as AudioStreamOggVorbis).loop,
		"%s plays instead of the chime at its real length (%.2f s; the estimate is %.1f s), never looping" % [ln.get("file", "?"), float(r.duration), float(ln.get("duration_fallback_s", 0.0))])
	vb.step(float(r.duration) + 0.01)
	ok(not vb.is_speaking(), "and the line ends when the clip does")
	vb.queue_free()

func _height_tests() -> void:
	print("== heights in the 3D view")
	var w := _world({"mode": "campaign", "stage": 1, "hero": 0, "seed": 41})
	w.stats.set_source("t", [["max_hp", "add", 1e6]]); w.hp = 1e6
	var T := w.terrain
	# a walkable spot with real hills around it: the height spans more than 40 units within 300
	var spot := w.pp
	var best := 0.0
	for r in range(0, 3000, 150):
		for a in 12:
			var c := Vector2.from_angle(TAU * a / 12.0) * r
			if not T.passable(c): continue
			var lo := INF
			var hi := -INF
			for k in 16:
				var h := T.height(c + Vector2.from_angle(TAU * k / 16.0) * 300.0)
				lo = minf(lo, h); hi = maxf(hi, h)
			if hi - lo > best:
				best = hi - lo
				spot = c
		if best > 40.0: break
	w.pp = spot
	var v := WorldView3D.new()
	add_child(v)
	v.bind(w)
	v._process(1.0 / 60.0)                 # composes the height window around the hero
	var rng := RandomNumberGenerator.new(); rng.seed = 5
	var worst := 0.0
	var lo2 := INF
	var hi2 := -INF
	var pts := PackedVector2Array()
	for k in 3000:
		var p := spot + Vector2(rng.randf_range(-1400, 1400), rng.randf_range(-1400, 1400))
		pts.append(p)
		var hb := T.height(p)
		worst = maxf(worst, absf(v.ground_y(p) - hb))
		lo2 = minf(lo2, hb); hi2 = maxf(hi2, hb)
	ok(worst < 0.01 and hi2 - lo2 > 40.0, "ground_y() equals Terrain.height() on hilly ground (max difference %.4f over a %.0f-unit height range)" % [worst, hi2 - lo2])
	var t0 := Time.get_ticks_usec()
	var acc := 0.0
	for p in pts: acc += v.ground_y(p)
	var t1 := Time.get_ticks_usec()
	for p in pts: acc += T.height(p)
	var t2 := Time.get_ticks_usec()
	print("  ground_y %.2f us a call, Terrain.height %.2f us a call" % [float(t1 - t0) / pts.size(), float(t2 - t1) / pts.size()])
	ok(t1 - t0 < t2 - t1, "and is cheaper than asking the simulation")
	# foes: the ground height is in each instance's transform (row-major 3x4: element 7 is the y origin)
	for k in 60: w.spawn_foe(Content.E.GRUNT + k % 5, spot + Vector2.from_angle(k * 0.7) * (90.0 + 4.0 * k), 0, 0, 50.0)
	for k in 30: w.add_gem(spot + Vector2.from_angle(k * 1.3) * (60.0 + 7.0 * k), 1.0)
	for k in 90: w.step(1.0 / 60.0)          # the hero's weapons fire; shots, kills, bursts and debris follow
	for k in 3:                              # and a few shots of each side placed over the slopes
		var pr := World.Proj.new()
		pr.pos = spot + Vector2.from_angle(k * 2.1) * 150.0; pr.vel = Vector2(300, 40); pr.life = 2.0
		w.projs.append(pr)
		var es := World.Proj.new()
		es.pos = spot + Vector2.from_angle(k * 2.1 + 1.0) * 170.0; es.vel = Vector2(-200, 60); es.life = 2.0; es.r = 6.0
		w.eshots.append(es)
	v._process(1.0 / 60.0)
	var checked := 0
	var bad := 0
	for kind in v._foe_mm.size():
		if kind >= v._fbk.size(): continue
		var buf: PackedFloat32Array = v._fbk[kind]
		for j in range(v._start[kind], v._start[kind + 1]):
			var o := (j - v._start[kind]) * WorldView3D.FOE_STRIDE
			checked += 1
			if absf(buf[o + 7] - v.ground_y(w.sw.pos[v._order[j]])) > 0.01: bad += 1
	ok(checked >= 20 and bad == 0, "every drawn foe stands at ground_y() (%d checked, %d off)" % [checked, bad])
	var fx := v.fx
	var pn := mini(w.projs.size(), 800)
	var pbad := 0
	for k in pn:
		if absf(fx._pb[k * 20 + 7] - (v.ground_y(w.projs[k].pos) + 16.0)) > 0.01: pbad += 1
	ok(pn > 0 and pbad == 0, "hero shots fly 16 above the ground under them (%d shots)" % pn)
	var ebad := 0
	for j in w.eshots.size():                # glow sprites: 4 per hero shot (head + trail), then 3 per enemy shot, ring first
		var go := (4 * pn + 3 * j) * 20
		if absf(fx._gb[go + 7] - (v.ground_y(w.eshots[j].pos) + 14.0)) > 0.01: ebad += 1
	ok(w.eshots.size() > 0 and ebad == 0, "enemy shots fly 14 above the ground under them (%d shots)" % w.eshots.size())
	var gbad := 0
	var gn := 0
	for i in w.gem_n:
		if w.gem_pos[i].distance_to(w.pp) > w.view_r + 40.0: continue
		var y := fx._gemb[gn * 20 + 7] - v.ground_y(w.gem_pos[i])
		if y < 7.4 or y > 12.6: gbad += 1
		gn += 1
	ok(gn > 0 and gbad == 0, "XP crystals bob 7.5 to 12.5 above the ground (%d crystals)" % gn)
	# debris: thrown, it lands and rests on the ground under it, never inside a slope
	var dpos := spot + Vector2(40, 0)
	for k in 12:
		fx._debris(Vector3(dpos.x, v.ground_y(dpos) + 20.0, dpos.y), Vector3(randf_range(-1, 1), 1.2, randf_range(-1, 1)) * 200.0, Color.GRAY, 5.0, 1.5)
	var dbad := 0
	for f in 60:
		fx._sim_debris(1.0 / 60.0)
		for i in fx.d_n:
			var p3: Vector3 = fx.d_pos[i]
			if p3.y < v.ground_y(Vector2(p3.x, p3.z)) + fx.d_size[i] * 0.3 - 0.01: dbad += 1
	ok(fx.d_n > 0 and dbad == 0, "debris never sinks below the ground under it (%d chips, 60 frames)" % fx.d_n)
	# sparks from a hit burst start 10 above the ground there; lights are world positions
	var bp := spot + Vector2(-70, 30)
	var s0 := fx.s_n
	w.bursts.append([bp, Color(1, 0.5, 0.2), 3, 100.0])
	fx._consume_feed()
	ok(fx.s_n > s0 and absf(fx.s_pos[fx.s_n - 1].y - (v.ground_y(bp) + 10.0)) < 0.01, "hit sparks start 10 above the ground at the hit")
	var lbad := 0
	var cands := fx.light_candidates()
	for c in cands:
		var lp: Vector3 = c[0]
		if lp.y < v.ground_y(Vector2(lp.x, lp.z)) - 0.01: lbad += 1
	ok(lbad == 0, "dynamic light candidates are above the ground (%d candidates)" % cands.size())
	v.queue_free()

## Drawing between ticks: World snapshots positions at the start of each tick, Main hands the view
## FixedStep.alpha(), and the view draws prev.lerp(now, alpha).
func _interp_tests() -> void:
	print("== interpolation between ticks")
	var w := _world({"mode": "rift", "hero": 0, "gr": 1, "seed": 51})
	w.stats.set_source("t", [["max_hp", "add", 1e6]]); w.hp = 1e6
	w.weapons.clear()
	var i := w.spawn_foe(Content.E.GRUNT, w.pp + Vector2(300, 0), 0, 0, 50.0)
	ok(w.sw.prev[i] == w.sw.pos[i], "a new foe starts with its previous position where it spawned")
	w.in_move = Vector2.RIGHT
	for k in 20: w.step(FixedStep.STEP)
	var before := w.pp
	var fpos := w.sw.pos[i]
	w.step(FixedStep.STEP)
	ok(w.prev_pp == before and w.pp != before, "each tick keeps where the hero stood at its start")
	ok(w.sw.prev[i] == fpos, "and where each foe stood")
	# removing a foe moves the last one into its slot, previous position included
	var j := w.spawn_foe(Content.E.GRUNT, w.pp + Vector2(-300, 40), 0, 0, 50.0)
	w.step(FixedStep.STEP)
	var lastp := w.sw.prev[w.sw.n - 1]
	var last_uid := w.sw.uid[w.sw.n - 1]
	w.sw.remove(i)
	var moved := w.sw.index_of(last_uid)
	ok(j >= 0 and w.sw.prev[moved] == lastp, "a foe moved to another slot keeps its previous position")
	# the view's lerp, and its teleport guard
	var v := WorldView3D.new()
	add_child(v)
	v.bind(w)
	v.alpha = 0.5
	v._process(1.0 / 60.0)
	ok(v.hero_p.distance_to((w.prev_pp + w.pp) * 0.5) < 0.001, "at alpha 0.5 the hero is drawn halfway between the last two ticks")
	ok(v.lerp_pos(Vector2.ZERO, Vector2(500, 0)) == Vector2(500, 0), "a jump of 500 in one tick is drawn where it landed (teleport)")
	# a 120 Hz display: one tick every other frame. Drawn at the latest tick, the walking hero stood still on
	# every other frame; drawn between ticks it moves an even amount every frame
	var m := _world({"mode": "rift", "hero": 0, "gr": 1, "seed": 52})
	m.stats.set_source("t", [["max_hp", "add", 1e6]]); m.hp = 1e6
	m.in_move = Vector2.RIGHT
	for k in 30: m.step(FixedStep.STEP)              # up to full walking speed
	var clock := FixedStep.new()
	var last_drawn := m.pp
	var last_raw := m.pp
	var steps_drawn: Array[float] = []
	var steps_raw: Array[float] = []
	for f in 120:
		var n := clock.advance(1.0 / 120.0)
		for k in n: m.step(FixedStep.STEP)
		var drawn := m.prev_pp.lerp(m.pp, clock.alpha())
		steps_drawn.append(drawn.x - last_drawn.x)
		steps_raw.append(m.pp.x - last_raw.x)
		last_drawn = drawn
		last_raw = m.pp
	steps_drawn = steps_drawn.slice(4)
	steps_raw = steps_raw.slice(4)
	var still_raw := steps_raw.filter(func(d): return absf(d) < 0.001).size()
	var still_drawn := steps_drawn.filter(func(d): return absf(d) < 0.001).size()
	ok(still_raw >= 50 and still_drawn == 0 and steps_drawn.max() < steps_drawn.min() * 1.3,
		"at 120 Hz the drawn hero moves every frame (%d of %d frames stood still at the latest tick, %d between ticks; per-frame step %.2f to %.2f)" % [still_raw, steps_raw.size(), still_drawn, steps_drawn.min(), steps_drawn.max()])
	v.queue_free()

## Packed vertex animation (tools/vat_pack.py, SVA3): every foe kind and act variant loads, with all five
## clips inside its rows and played at 12 fps or more (the spawn clips were baked at 6 and stay so); the
## positions are RGBA8 texels that decode (as foe.gdshader's vat_p does) to points inside their box.
func _vat_tests() -> void:
	print("== packed vertex animation")
	var files := 0
	var bad: Array[String] = []
	var d := DirAccess.open("res://models/foes")
	for f in d.get_files():
		if not f.ends_with(".vat"): continue
		files += 1
		var kind := f.get_basename()
		var parts := kind.split("_")
		var vat := Models.foe_vat(parts[0], int(parts[1]) if parts.size() > 1 else -1)
		if vat.is_empty():
			bad.append(kind + ": did not load"); continue
		var rows: int = vat.rows
		var tex: ImageTexture = vat.pos
		if tex.get_width() != int(vat.verts) or tex.get_height() != rows: bad.append(kind + ": texture size")
		var img := tex.get_image()
		var vmin: Vector3 = vat.vmin
		var vext: Vector3 = vat.vext
		if img.get_format() != Image.FORMAT_RGBA8 or (vat.nrm as ImageTexture).get_image().get_format() != Image.FORMAT_RG8: bad.append(kind + ": texture formats")
		# the box spans every clip: at least most of the standing mesh, at most three of its heights (a spawn
		# rises from up to a body and a half below the ground: the KayKit skeletons' grave rise is 2.4)
		var mh := Models.foe_mesh(parts[0], int(parts[1]) if parts.size() > 1 else -1).get_aabb().size.y
		if vext.y < mh * 0.7 or vext.y > mh * 3.0: bad.append(kind + ": box height %.2f for a mesh %.2f tall" % [vext.y, mh])
		var lo_y := INF
		var hi_y := -INF
		for k in 64:
			var c8 := img.get_pixel(int(k * 37) % img.get_width(), int(k * 11) % rows)
			var a := roundi(c8.a * 255.0)
			var q := Vector3(roundi(c8.r * 255.0) * 4 + (a & 3), roundi(c8.g * 255.0) * 4 + ((a >> 2) & 3), roundi(c8.b * 255.0) * 4 + (a >> 4))
			var p := vmin + q / 1023.0 * vext
			lo_y = minf(lo_y, p.y); hi_y = maxf(hi_y, p.y)
			if p.x < vmin.x - 1e-4 or p.x > vmin.x + vext.x + 1e-4 or p.z < vmin.z - 1e-4 or p.z > vmin.z + vext.z + 1e-4: bad.append(kind + ": texel outside its box")
		if hi_y - lo_y < vext.y * 0.2: bad.append(kind + ": sampled points span %.2f of %.2f" % [hi_y - lo_y, vext.y])
		var c: PackedFloat32Array = vat.clips
		for si in Models.VAT_SLOTS.size():
			var first := c[si * 3]; var n := c[si * 3 + 1]; var fps := c[si * 3 + 2]
			var slot: String = Models.VAT_SLOTS[si]
			if n < 2 or first + n + 1 > rows: bad.append("%s %s: rows %d..%d of %d" % [kind, slot, first, first + n, rows])
			if fps < (5.9 if slot == "spawn" else 11.9): bad.append("%s %s: %.1f fps" % [kind, slot, fps])
	ok(files >= 11 and bad.is_empty(), "all %d foe animations load, five clips each, at 12 fps or more%s" % [files, ("  " + "; ".join(bad)) if not bad.is_empty() else ""])

## Every world _world() makes, disposed before the runner quits: a World's bosses and director point back at
## it, so one left undisposed (and its terrain, swarm and generators) outlives the run as a reference cycle.
var _worlds: Array[World] = []
func _world(cfg: Dictionary) -> World:
	cfg["headless"] = true
	cfg["season"] = cfg.get("season", "")
	var w := World.new()
	w.setup(cfg)
	_worlds.append(w)
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
		if not w.whisper_offer.is_empty():
			w.accept_bargain(Bot.bargain(w.whisper_offer, bot_seed))
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
		"lvl10_t": lvl_t.get(10, -1), "progress": snappedf(w.progress, 0.1), "gold": int(w.gold),
		"light_avg": snappedf(float(w.metrics.get("light_sum", 0.0)) / maxf(1.0, w.t), 0.01), "dark_s": int(w.metrics.get("dark_s", 0.0)), "bargains": w.bargains}

func _sims() -> void:
	print("== sim (bot-played runs)")
	Save.data.nemesis = {}            # unit tests end runs in defeat, which raises a nemesis the bots would then meet
	run_bot({"mode": "campaign", "hero": 0, "seed": 1}, 20.0, 0)     # warm-up: first-use script paths cost ~15 ms once
	var rows: Array = []
	for h in 4:
		rows.append(run_bot({"mode": "campaign", "hero": h, "stage": 0, "seed": 100 + h, "weapons_pool": Content.WEAPON_IDS}, 620.0, h))
	if OS.get_environment("SIM_ONE") != "":                 # one run, for A/B checks
		for sd in OS.get_environment("SIM_ONE").split(","):
			var r1 := run_bot({"mode": "campaign", "hero": 0, "stage": 0, "seed": int(sd), "weapons_pool": Content.WEAPON_IDS}, 620.0, int(sd))
			print("  ONE seed=%s won=%s t=%s lvl=%d killer=%s hp_low=%s" % [sd, r1.won, r1.t, r1.lvl, r1.killer, r1.hp_low])
		return
	if OS.get_environment("SIM_QUICK") != "":
		rows.append(run_bot({"mode": "campaign", "hero": 0, "stage": 3, "seed": 78}, 660.0, 5))
		for r in rows:
			print("  %-8s %-11s won=%-5s t=%6s lvl=%2d kills=%5d dps=%5d foes=%3d hp_low=%s killer=%s" % [r.mode, r.hero, r.won, r.t, r.lvl, r.kills, r.dps, r.peak_foes, r.hp_low, r.killer])
		return
	rows.append(run_bot({"mode": "campaign", "hero": 1, "stage": 2, "seed": 77}, 620.0, 5))
	rows.append(run_bot({"mode": "campaign", "hero": 0, "stage": 4, "seed": 55}, 660.0, 7))      # Act V: rising tide, Tide Bishop
	var at := Atlas.generate(99)
	var node: Dictionary = at.nodes[0]
	rows.append(run_bot({"mode": "atlas", "hero": 2, "node": node, "seed": 55}, 620.0, 6))
	rows.append(run_bot({"mode": "rift", "hero": 3, "gr": 1, "seed": 31}, 320.0, 7))
	rows.append(run_bot({"mode": "rift", "hero": 3, "gr": 8, "seed": 32}, 320.0, 8))
	rows.append(run_bot({"mode": "rift", "hero": 1, "gr": 15, "seed": 33}, 320.0, 10))
	rows.append(run_bot({"mode": "rift", "hero": 2, "gr": 25, "seed": 34}, 320.0, 11))
	rows.append(run_bot({"mode": "pinnacle", "hero": 0, "seed": 13}, 300.0, 9))
	for r in rows:
		print("  %-8s %-11s won=%-5s t=%6s lvl=%2d kills=%4d dps=%5d react=%4d drop=%3d casc=%d txt/s=%5s foes=%3d ms=%5s/%6s hp_low=%s killer=%s light=%s dark=%ds pact=%s ev=%s" % [
			r.mode, r.hero, r.won, r.t, r.lvl, r.kills, r.dps, r.reactions, r.react_dropped, r.cascade_max, r.texts_per_s, r.peak_foes, r.ms_avg, r.ms_worst, r.hp_low, r.killer, r.light_avg, r.dark_s, r.bargains, r.events])
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
	# the foe step's own parts, through the same Swarm calls World._step_foes makes
	var fp := {"timers": 0, "separation": 0, "move": 0, "move_no_terrain": 0}
	var shots: Array = []
	for f in frames:
		w.grid.build(w.sw)
		var a0 := Time.get_ticks_usec()
		w.sw.tick_timers(dt)
		var a1 := Time.get_ticks_usec()
		w.sw.cpu_separation(w.grid, f % 2, w.pp, w.view_r + 40.0)
		var a2 := Time.get_ticks_usec()
		shots.clear()
		w.sw.step_move(dt, w.pp, shots, 1.0, w.terrain)
		var a3 := Time.get_ticks_usec()
		shots.clear()
		w.sw.step_move(dt, w.pp, shots, 1.0, null)
		var a4 := Time.get_ticks_usec()
		fp.timers += a1 - a0; fp.separation += a2 - a1; fp.move += a3 - a2; fp.move_no_terrain += a4 - a3
	if OS.get_environment("BENCH_EXP") != "":
		var vr2 := (w.view_r + 40.0) * (w.view_r + 40.0)
		var inside := 0
		for i in w.sw.n:
			if w.sw.pos[i].distance_squared_to(w.pp) <= vr2: inside += 1
		var e0 := Time.get_ticks_usec()
		for f in 60:
			shots.clear(); w.sw.step_move(dt, w.pp, shots, 1.0, w.terrain)
		var e1 := Time.get_ticks_usec()
		w.terrain.props_on = false
		for f in 60:
			shots.clear(); w.sw.step_move(dt, w.pp, shots, 1.0, w.terrain)
		var e2 := Time.get_ticks_usec()
		w.terrain.props_on = true
		print("  EXP view_r=%.0f inside=%d/%d move+terrain=%.2fms cells_only=%.2fms" % [w.view_r, inside, w.sw.n, (e1 - e0) / 60000.0, (e2 - e1) / 60000.0])
	var fl := "  foe step:"
	for k in fp:
		out["foe_" + k] = snappedf(fp[k] / 1000.0 / frames, 0.01)
		fl += " %s=%.2fms" % [k, out["foe_" + k]]
	print(fl)
	report["bench"] = out
	ok(true, "bench ran")
