class_name Bot
extends RefCounted
## Scripted player for headless balance runs. Deliberately mediocre: kites away from the swarm's
## pressure field, steps out of telegraphs, rolls through close projectiles, walks to events and
## shrines, drinks below half life and fires its ultimate when ready. Level-up picks follow a
## simple priority: evolutions > keystones > weapon levels > gems > perks.

var w: World
var rng := RandomNumberGenerator.new()
var greedy := true
var skill := 1.0                 # 0..1: how reliably it dodges

func _init(world: World, s: int = 1) -> void:
	w = world
	rng.seed = s

func think() -> void:
	var push := Vector2.ZERO
	var g := w.grid
	var c := g.query(w.pp, 220.0, w.sw)
	for q in c:
		var i := g.results[q]
		if (w.sw.flags[i] & Swarm.F_ALLY) != 0: continue
		var dv := w.pp - w.sw.pos[i]
		var d := maxf(8.0, dv.length())
		push += dv / d * (1.0 / d) * (3.0 if (w.sw.flags[i] & (Swarm.F_BOSS | Swarm.F_HERALD | Swarm.F_EXILE)) != 0 else 1.0)
	var mv := push.normalized() if push.length() > 0.0005 else Vector2.ZERO
	# short-range kits (blades, pulses) must close to their reach; ranged kits keep kiting
	var reach := 0.0
	if w.weapons.has("orbit"): reach = 60.0
	elif w.weapons.has("nova") and not w.weapons.has("bolt"): reach = 90.0
	if reach > 0.0:
		var ni := g.nearest(w.pp, 400.0, w.sw)
		if ni >= 0 and c < 10:
			var dn := w.sw.pos[ni] - w.pp
			if dn.length() > reach * 0.8:
				mv = (mv * 0.3 + dn.normalized()).normalized()
	# leave telegraphs
	for z in w.teles:
		if z.hostile and w.tele_contains(z, w.pp, 20.0) and rng.randf() < skill:
			var out := (w.pp - z.pos).normalized()
			if z.shape == 1: out = -w.pp.normalized()
			if z.shape == 2: out = z.dir.orthogonal()
			mv = (mv + out * 2.0).normalized()
	# objectives when the area is calm
	if greedy and c < 6:
		var goal := Vector2.INF
		for o in w.director.objects:
			goal = o.pos
		for ev in w.director.active:
			if ev.state == 0 and ev.id in ["cursed", "strongbox", "ritual"]:
				goal = ev.pos
		for p in w.picks:
			if p.k in ["item", "lore", "fragment", "currency", "heart"] and p.pos.distance_to(w.pp) < 400.0:
				goal = p.pos
		if goal != Vector2.INF:
			mv = (mv * 0.4 + (goal - w.pp).normalized()).normalized()
	# engage a live boss that is far away (a kiting bot otherwise never meets it)
	var bf := -1
	for u in w.boss_uids:
		if w.sw.index_of(u) >= 0: bf = w.sw.index_of(u)
	if bf >= 0 and w.sw.pos[bf].distance_to(w.pp) > 320.0:
		mv = (mv * 0.3 + (w.sw.pos[bf] - w.pp).normalized()).normalized()
	if w.arena_r > 0.0 and w.pp.length() > w.arena_r - 80.0:
		mv = (mv - w.pp.normalized()).normalized()
	w.in_move = mv
	for q in w.eshots:
		if q.pos.distance_to(w.pp) < 40.0 and rng.randf() < 0.3 * skill:
			w.in_roll = true
			break
	if w.hp < w.max_hp * 0.5: w.in_flask[0] = true
	if c > 15: w.in_flask[1] = true
	if w.ult >= 100.0 and c > 10: w.in_ult = true

static func pick(choices: Array, w: World) -> Dictionary:
	var best: Dictionary = choices[0]
	var bs := -1.0
	for c in choices:
		var s := 1.0
		match c.kind:
			"e": s = 100.0
			"key": s = 50.0 if c.id in ["equilibrium", "chainreact", "glass", "pain"] else 20.0
			"w": s = 30.0 if w.weapons.has(c.id) else 18.0
			"g": s = 25.0
			"p": s = 12.0 + (8.0 if c.id in ["might", "haste", "vigor", "searing", "cryo", "static"] else 0.0)
		s += randf() * 5.0
		if s > bs:
			bs = s
			best = c
	return best
