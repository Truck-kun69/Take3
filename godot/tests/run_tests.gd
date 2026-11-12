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
		rows.append(run_bot({"mode": "campaign", "hero": h, "stage": 0, "seed": 100 + h}, 200.0, h))
	rows.append(run_bot({"mode": "campaign", "hero": 1, "stage": 2, "seed": 77}, 200.0, 5))
	rows.append(run_bot({"mode": "campaign", "hero": 0, "stage": 4, "seed": 55}, 240.0, 7))      # Act V: rising tide, Tide Bishop
	var at := Atlas.generate(99)
	var node: Dictionary = at.nodes[0]
	rows.append(run_bot({"mode": "atlas", "hero": 2, "node": node, "seed": 55}, 200.0, 6))
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
	report["bench"] = out
	ok(true, "bench ran")
