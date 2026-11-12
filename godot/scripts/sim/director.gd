class_name Director
extends RefCounted
## Pacing director + event deck.
##
## Pacing (Left 4 Dead style): BUILD ramps the spawn rate, PEAK holds it high, RELAX drops it so the
## player can loot and breathe. Intensity is a smoothed mix of recent damage taken and swarm density;
## high intensity cuts BUILD short. Events are never started during PEAK so two spikes never stack.
##
## Event deck: weighted draw with per-event cooldowns, earliest-start times, no immediate repeats,
## a concurrency cap and prerequisites. Each running event is a Dictionary stepped by `_step_<id>`.

enum Phase { BUILD, PEAK, RELAX }
const PHASE_NAME := ["Build", "Peak", "Relax"]

var w: World
var phase := Phase.BUILD
var phase_t := 0.0
var intensity := 0.0
var active: Array = []
var objects: Array = []            # pylons and shrines on the ground: {pos, kind, id, life}
var cd := {}
var last_id := ""
var next_t := 22.0
var shrine_t := 30.0
var nemesis_pending := false
var exile_spawned := false
var history: Array = []            # [time, id] for tests and the end screen
var _uid := 1000
var _pending_drops: Array = []     # [time, pos, kind, data]
var whisper_t := 60.0              # next Whisperer appearance (run time)
var whispers := 0                  # appearances this run
const WHISPER_MAX := 3
var gate_t := 55.0                 # next Rift Gate (bank-or-push)

func _whisper_gap() -> float:
	return w.rng.randf_range(70.0, 95.0) * Moon.whisper_mult(w.sky_date)

func _init(world: World) -> void:
	w = world
	if w.has_mod("breached"):
		next_t = 18.0
	whisper_t = w.rng.randf_range(50.0, 70.0) * Moon.whisper_mult(w.sky_date)

func rate_mult() -> float:
	var m := 1.0
	match phase:
		Phase.BUILD: m = 1.0 + 0.4 * minf(1.0, phase_t / 40.0)
		Phase.PEAK: m = 1.6
		Phase.RELAX: m = 0.45
	if eclipse(): m *= 1.2
	for ev in active:
		if ev.id == "delirium" and ev.inside: m *= 1.6
	return m

func eclipse() -> bool:
	if w.has_mod("eclipsed"):
		return true
	for ev in active:
		if ev.id == "eclipse": return true
	return false

func max_concurrent() -> int:
	if w.mode == "atlas" and int(w.node.get("tier", 1)) >= 3: return 3
	return 2

func step(dt: float) -> void:
	phase_t += dt
	var target := clampf(w.recent_dmg / maxf(1.0, w.max_hp * 0.5), 0.0, 1.0) * 0.6 + clampf(float(w.sw.n) / float(w.foe_cap()), 0.0, 1.0) * 0.4
	intensity = lerpf(intensity, target, minf(1.0, dt * 1.5))
	match phase:
		Phase.BUILD:
			if phase_t > 45.0 or (intensity > 0.7 and phase_t > 15.0): _phase(Phase.PEAK)
		Phase.PEAK:
			if phase_t > 10.0: _phase(Phase.RELAX)
		Phase.RELAX:
			if phase_t > 12.0: _phase(Phase.BUILD)
	if w.mode != "pinnacle":
		if w.t >= next_t and active.size() < max_concurrent() and phase != Phase.PEAK:
			var id := pick()
			if id != "":
				start(id)
				next_t = w.t + (w.rng.randf_range(20.0, 32.0) if w.mode == "rift" else w.rng.randf_range(28.0, 45.0))
			else:
				next_t = w.t + 5.0
		if nemesis_pending and w.t > 45.0:
			nemesis_pending = false
			exile_spawned = true
			w.bosses.spawn_exile(true)
	if w.t >= shrine_t:
		shrine_t = w.t + w.rng.randf_range(40.0, 65.0)
		_place_object()
	if w.t >= gate_t and w.mode != "pinnacle":
		gate_t = w.t + w.rng.randf_range(55.0, 70.0)
		var gp := _near_point(230.0)
		objects.append({"pos": gp, "kind": "gate", "id": "gate", "life": 22.0})
		w.banner.emit("A Rift Gate opens", "Step in to bank your hoard (x%.1f), or walk on and let it grow." % w.hoard_mult, Color("7fd8ff"))
	if w.t >= whisper_t and w.mode != "pinnacle" and not w.boss_spawned and whispers < WHISPER_MAX + (1 if Moon.whisper_mult(w.sky_date) < 1.0 else 0) \
			and w.bargains.size() < Content.WHISPER_IDS.size() - 1:
		whisper_t = w.t + _whisper_gap()
		whispers += 1
		objects.append({"pos": _near_point(200.0), "kind": "whisper", "id": "whisper", "life": 30.0})
		w.banner.emit("A voice in the dark", "Something wants to bargain. Find it before it fades.", Color("9a6bff"))
	_step_objects(dt)
	var k := active.size() - 1
	while k >= 0:
		var ev: Dictionary = active[k]
		ev.t += dt
		call("_step_" + String(ev.id), ev, dt)
		if ev.done:
			active.remove_at(k)
		k -= 1
	k = _pending_drops.size() - 1
	while k >= 0:
		if w.t >= float(_pending_drops[k][0]):
			var pd: Array = _pending_drops[k]
			w.add_pick(pd[1], pd[2], 0.0, pd[3], 40.0)
			_pending_drops.remove_at(k)
		k -= 1

func _phase(p: int) -> void:
	phase = p
	phase_t = 0.0

func pick() -> String:
	var tot := 0.0
	var cand: Array = []
	for id in Content.EVENT_IDS:
		var def: Dictionary = Content.EVENTS[id]
		if w.t < float(def.min_t) or w.t < float(cd.get(id, 0.0)) or id == last_id:
			continue
		var busy := false
		for ev in active:
			if ev.id == id: busy = true
		if busy: continue
		if id == "exile" and (exile_spawned or nemesis_pending): continue
		if id == "merchant" and w.mode == "rift": continue
		var wt := float(def.weight)
		if id == "goblin" and w.has_leg("greed"): wt *= 2.0
		if id == "breach" and w.has_mod("breached"): wt *= 10.0
		if id == "eclipse": wt *= Moon.eclipse_weight(w.moon)
		cand.append([id, wt])
		tot += wt
	if cand.is_empty():
		return ""
	var r := w.rng.randf() * tot
	for c in cand:
		r -= c[1]
		if r <= 0.0: return c[0]
	return cand[cand.size() - 1][0]

func start(id: String) -> Dictionary:
	_uid += 1
	var ev := {"id": id, "uid": _uid, "t": 0.0, "done": false, "kills": 0, "state": 0, "pos": _near_point(170.0), "inside": false}
	cd[id] = w.t + float(Content.EVENTS[id].cd)
	last_id = id
	history.append([w.t, id])
	w.metrics.events[id] = int(w.metrics.events.get(id, 0)) + 1
	active.append(ev)
	var def: Dictionary = Content.EVENTS[id]
	w.banner.emit(def.name, def.d, Content.col(def.col))
	Sfx.play("event")
	call("_start_" + id, ev)
	return ev

func _near_point(d: float) -> Vector2:
	var a := w.rng.randf() * TAU
	var p := w.pp + Vector2(cos(a), sin(a)) * d
	if w.arena_r > 0.0 and p.length() > w.arena_r - 40.0:
		p = p.normalized() * (w.arena_r - 60.0)
	return w.terrain.nearest_passable(p) if w.terrain != null else p

func _rand_in(c: Vector2, r: float) -> Vector2:
	var a := w.rng.randf() * TAU
	return c + Vector2(cos(a), sin(a)) * sqrt(w.rng.randf()) * r

func _end(ev: Dictionary, ok: bool) -> void:
	ev.done = true
	if ok:
		w.hoard += 40.0
		w.metrics.events_done = int(w.metrics.get("events_done", 0)) + 1
	if ok and w.rng.randf() < 0.3:
		w.drop_lore(ev.pos)

func _tagged_alive(ev: Dictionary) -> int:
	var c := 0
	for i in w.sw.n:
		if w.sw.tag[i] == ev.uid: c += 1
	return c

## Removes an event's leftover foes without kill rewards (they are flagged as allies first,
## which `_on_kill` ignores).
func _dismiss(ev: Dictionary) -> void:
	for i in w.sw.n:
		if w.sw.tag[i] == ev.uid:
			w.sw.set_flags(i, Swarm.F_ALLY)
			w.sw.take(i, 1e9)
			w._burst(w.sw.pos[i], Color("c48aff"), 4, 80.0)

func _spawn_tagged(ev: Dictionary, k: int, at: Vector2, elite: int = -1, flags: int = 0, hp_m: float = 1.0) -> int:
	if w.sw.n >= Swarm.CAP - 20:
		return -1
	var i := w.spawn_foe(k, at, elite, Swarm.F_EVENT | flags, hp_m)
	if i >= 0:
		w.sw.set_tag(i, ev.uid)
		ev["spawned"] = int(ev.get("spawned", 0)) + 1
	return i

func on_kill(i: int, at: Vector2) -> void:
	var tg := w.sw.tag[i]
	var f := w.sw.flags[i]
	for ev in active:
		if tg == ev.uid:
			ev.kills += 1
		if ev.id == "breach" and at.distance_to(ev.pos) < ev.r:
			ev.life = minf(30.0, ev.life + 0.35)
			if (f & Swarm.F_BREACH) != 0 and w.rng.randf() < 0.05:
				w.add_pick(at, "splinter", 1.0, null, 40.0)
		if ev.id == "delirium" and ev.inside:
			ev.reward += 1
	if (f & Swarm.F_GOBLIN) != 0:
		w.banner.emit("Gremlin slain!", "Its hoard spills out.", Color("ffd84a"))
		w.loot_shower(at, w.rng.randi_range(2, 4), w.rng.randi_range(3, 6), 18, Content.Rarity.MAGIC)
		if w.rng.randf() < 0.25: w.add_pick(at, "fragment", 0.0, "greed")
		if w.rng.randf() < 0.1: w.drop_item(at, Content.Rarity.LEGENDARY)
		for ev in active:
			if ev.id == "goblin": ev.done = true

# ---------------------------------------------------------------- breach
func _start_breach(ev: Dictionary) -> void:
	ev.r = 40.0
	ev.life = 16.0
	ev.acc = 0.0
func _step_breach(ev: Dictionary, dt: float) -> void:
	ev.r = minf(320.0, ev.r + 22.0 * dt)
	ev.life -= dt
	ev.acc += (5.0 + ev.t * 0.2) * dt
	while ev.acc >= 1.0:
		ev.acc -= 1.0
		var i := _spawn_tagged(ev, Content.E.BREACH, _rand_in(ev.pos, ev.r), 1 if w.rng.randf() < 0.06 else 0, Swarm.F_BREACH)
		if i < 0: break
	if ev.life <= 0.0:
		_dismiss(ev)
		var spl := int(ev.kills / 8)
		if spl > 0: w.add_pick(w.pp, "splinter", float(spl), null, 60.0)
		if ev.kills >= 40: w.drop_item(ev.pos, Content.Rarity.RARE)
		w.toast.emit("The breach closes (%d slain)" % ev.kills, Color("c48aff"))
		_end(ev, ev.kills >= 20)

# ---------------------------------------------------------------- treasure gremlin
func _start_goblin(ev: Dictionary) -> void:
	var p := _near_point(260.0)
	var i := w.spawn_foe(Content.E.GOBLIN, p, 0, Swarm.F_GOBLIN | Swarm.F_EVENT, 0.6)
	ev.u = w.sw.uid[i] if i >= 0 else -1
	ev.life = 22.0
	ev.last_hp = 1.0
func _step_goblin(ev: Dictionary, dt: float) -> void:
	var i := w.sw.index_of(int(ev.u))
	if i < 0:
		ev.done = true
		return
	if w.sw.hp[i] <= 0.0:
		return                               # dying this frame (or dismissed): the kill handler pays out
	# clamped: an overkill hit must not make this loop run millions of times (cycle 2 hang)
	var frac := clampf(w.sw.hp[i] / w.sw.mhp[i], 0.0, 1.0)
	while ev.last_hp - frac > 0.1:          # every 10% of its life lost spills coins
		ev.last_hp -= 0.1
		w.add_pick(w.sw.pos[i], "coin", 2.0)
	ev.life -= dt
	if ev.life <= 0.0:
		w.fx.append({"k": "ring", "pos": w.sw.pos[i], "r": 0.0, "max": 60.0, "col": Color("ffd84a"), "life": 0.5, "t": 0.0})
		w.sw.set_flags(i, Swarm.F_ALLY)
		w.sw.take(i, 1e9)
		w.toast.emit("The gremlin escaped through a portal", Color("ffd84a"))
		ev.done = true

# ---------------------------------------------------------------- cursed chest
func _start_cursed(ev: Dictionary) -> void:
	ev.life = 40.0
	ev.quota = 45
	ev.acc = 0.0
func _step_cursed(ev: Dictionary, dt: float) -> void:
	if ev.state == 0:
		ev.life -= dt
		if w.pp.distance_to(ev.pos) < 40.0:
			ev.state = 1
			ev.life = 25.0
			w.banner.emit("The curse wakes", "Slay %d foes in 25 seconds." % ev.quota, Color("ff4a5e"))
		elif ev.life <= 0.0:
			ev.done = true
		return
	ev.life -= dt
	ev.acc += 5.0 * dt
	while ev.acc >= 1.0:
		ev.acc -= 1.0
		_spawn_tagged(ev, w._pick_type(), _rand_in(ev.pos, 260.0) + Vector2(0, 0), -1)
	if ev.kills >= ev.quota:
		_dismiss(ev)
		w.banner.emit("Curse lifted", "", Color("ffd84a"))
		w.loot_shower(ev.pos, 2, 3, 15, Content.Rarity.RARE)
		if w.rng.randf() < 0.3: w.add_pick(ev.pos, "fragment", 0.0, "dread")
		_end(ev, true)
	elif ev.life <= 0.0:
		_dismiss(ev)
		w.toast.emit("The curse lingers (%d / %d)" % [ev.kills, ev.quota], Color("ff4a5e"))
		w.drop_item(ev.pos, Content.Rarity.MAGIC)
		_end(ev, false)

# ---------------------------------------------------------------- strongbox
func _start_strongbox(ev: Dictionary) -> void:
	ev.life = 60.0
func _step_strongbox(ev: Dictionary, dt: float) -> void:
	ev.life -= dt
	if ev.state == 0:
		if w.pp.distance_to(ev.pos) < 40.0:
			ev.state = 1
			for k in w.rng.randi_range(6, 9):
				var a: float = TAU * k / 8.0
				_spawn_tagged(ev, [Content.E.GRUNT, Content.E.BRUTE, Content.E.CHARGER][k % 3], ev.pos + Vector2(cos(a), sin(a)) * 90.0, 1 if k % 3 == 0 else 0)
		elif ev.life <= 0.0:
			ev.done = true
		return
	if _tagged_alive(ev) == 0:
		w.loot_shower(ev.pos, w.rng.randi_range(1, 3), w.rng.randi_range(1, 2), 8, Content.Rarity.MAGIC)
		_end(ev, true)
	elif ev.life <= 0.0:
		_end(ev, false)

# ---------------------------------------------------------------- eclipse
func _start_eclipse(ev: Dictionary) -> void:
	ev.life = 35.0
func _step_eclipse(ev: Dictionary, dt: float) -> void:
	ev.life -= dt
	if ev.life <= 0.0:
		w.toast.emit("The light returns", Color("fff2b0"))
		_end(ev, true)

# ---------------------------------------------------------------- starfall
func _start_meteor(ev: Dictionary) -> void:
	ev.life = 18.0
	ev.acc = 0.0
func _step_meteor(ev: Dictionary, dt: float) -> void:
	ev.life -= dt
	ev.acc += dt
	if ev.acc >= 0.55:
		ev.acc = 0.0
		var at := w.pp if w.rng.randf() < 0.25 else _rand_in(w.pp, 300.0)
		var z := w.add_tele(0, at, 60.0, 1.2, 0.0, 22.0, true, true, Content.El.FIRE, Color(1.0, 0.6, 0.2, 0.55), "Starfall")
		z.dmg = 22.0
		_pending_meteor_hit(at)
		if w.rng.randf() < 0.12:
			_pending_drops.append([w.t + 1.25, at, "currency", "exalt"])
	if ev.life <= 0.0:
		_end(ev, true)
func _pending_meteor_hit(at: Vector2) -> void:
	# friendly half of the meteor: foes take scaled weapon damage instead of the flat player damage
	var z := w.add_tele(0, at, 60.0, 1.2, 0.0, w.weapon_damage_base() * 4.0, false, true, Content.El.FIRE, Color(0, 0, 0, 0), "")
	z.friendly = true

# ---------------------------------------------------------------- wandering merchant
func _start_merchant(ev: Dictionary) -> void:
	ev.life = 45.0
func _step_merchant(ev: Dictionary, dt: float) -> void:
	ev.life -= dt
	var inside := w.pp.distance_to(ev.pos) < 50.0
	if inside and not ev.inside:
		w.merchant_open.emit()
	ev.inside = inside
	if ev.life <= 0.0:
		ev.done = true

const GAMBLE_COST := 60
func gamble(slot: String) -> Dictionary:
	if w.gold < GAMBLE_COST:
		return {}
	w.gold -= GAMBLE_COST
	var r := w.rng.randf()
	var rar := Content.Rarity.LEGENDARY if r < 0.08 else (Content.Rarity.RARE if r < 0.38 else Content.Rarity.MAGIC)
	var it := Items.make(slot, rar, w.ilvl() + 2, w.rng)
	w._take_item(it)
	return it

# ---------------------------------------------------------------- delirium mirror
func _start_delirium(ev: Dictionary) -> void:
	ev.r = 280.0
	ev.life = 30.0
	ev.reward = 0
	ev.acc = 0.0
	ev.pos = w.pp
func _step_delirium(ev: Dictionary, dt: float) -> void:
	ev.inside = w.pp.distance_to(ev.pos) < ev.r
	ev.life -= dt * (1.0 if ev.inside else 3.0)          # the fog fades fast once you leave it
	if ev.inside:
		ev.acc += 3.0 * dt
		while ev.acc >= 1.0:
			ev.acc -= 1.0
			_spawn_tagged(ev, w._pick_type(), w.ring_point(10.0), -1, 0, 1.0 + 1.5 * ev.t / 30.0)
	if ev.life <= 0.0:
		_dismiss(ev)
		var tier := int(ev.reward / 15)
		if tier > 0:
			w.loot_shower(w.pp, mini(4, tier), mini(5, tier + 1), 6 * tier, Content.Rarity.MAGIC if tier < 3 else Content.Rarity.RARE)
		w.toast.emit("The mirror shatters (reward tier %d)" % tier, Color("d8d8e8"))
		_end(ev, tier >= 2)

# ---------------------------------------------------------------- blood ritual
func _start_ritual(ev: Dictionary) -> void:
	ev.life = 45.0
	ev.waves = 0
	ev.wave_t = 0.0
func _step_ritual(ev: Dictionary, dt: float) -> void:
	ev.life -= dt
	if ev.state == 0:
		if w.pp.distance_to(ev.pos) < 40.0:
			ev.state = 1
			ev.t0 = ev.t
		elif ev.life <= 0.0:
			ev.done = true
		return
	ev.wave_t -= dt
	if ev.waves < 3 and ev.wave_t <= 0.0:
		ev.waves += 1
		ev.wave_t = 5.0
		for k in 10:
			var a: float = TAU * k / 10.0 + ev.waves
			_spawn_tagged(ev, [Content.E.GRUNT, Content.E.RUNNER, Content.E.SPLITTER, Content.E.BRUTE][k % 4], ev.pos + Vector2(cos(a), sin(a)) * 160.0, 1 if k == 0 else 0)
	if ev.waves >= 3 and _tagged_alive(ev) == 0:
		var fast: bool = ev.t - ev.t0 < 25.0
		w.banner.emit("Tribute accepted", "Swift sacrifice: a rare reward." if fast else "", Color("ff2b4a"))
		w.drop_item(ev.pos, Content.Rarity.RARE if fast else Content.Rarity.MAGIC)
		w.drop_currency(ev.pos, 2)
		_end(ev, true)
	elif ev.life <= 0.0:
		_dismiss(ev)
		_end(ev, false)

# ---------------------------------------------------------------- rogue exile
func _start_exile(ev: Dictionary) -> void:
	exile_spawned = true
	w.bosses.spawn_exile(false)
	ev.done = true
func _step_exile(ev: Dictionary, _dt: float) -> void:
	ev.done = true

# ---------------------------------------------------------------- pylons & shrines
func _place_object() -> void:
	var pylon := w.rng.randf() < 0.45
	var ids: Array = Content.PYLON_IDS if pylon else Content.SHRINE_IDS
	var id: String = ids[w.rng.randi_range(0, ids.size() - 1)]
	objects.append({"pos": _near_point(220.0), "kind": "pylon" if pylon else "shrine", "id": id, "life": 60.0})

func _step_objects(dt: float) -> void:
	var k := objects.size() - 1
	while k >= 0:
		var o: Dictionary = objects[k]
		o.life -= dt
		if o.kind == "gate":
			if w.pp.distance_to(o.pos) < 40.0:
				objects.remove_at(k)
				w.bank_hoard(o.pos)
				Sfx.play("pylon")
			elif o.life <= 0.0:
				objects.remove_at(k)
				w.gate_passed()
			k -= 1
			continue
		if o.kind == "whisper":
			if w.pp.distance_to(o.pos) < 34.0:
				objects.remove_at(k)
				w.offer_whisper()
			elif o.life <= 0.0:
				objects.remove_at(k)
				w.toast.emit("The voice falls silent", Color("9a6bff"))
			k -= 1
			continue
		if w.pp.distance_to(o.pos) < 30.0:
			w.relight(1.0)
			w.buffs.add(o.id)
			var def: Dictionary = Content.BUFFS[o.id]
			w.banner.emit(def.name, _buff_desc(o.id), Content.col(def.col))
			Sfx.play("pylon")
			if w.rng.randf() < 0.08: w.drop_lore(o.pos)
			objects.remove_at(k)
		elif o.life <= 0.0:
			objects.remove_at(k)
		k -= 1

static func _buff_desc(id: String) -> String:
	match id:
		"power": return "Your damage is quadrupled."
		"conduit": return "Lightning arcs from you to nearby foes."
		"channel": return "Cooldowns reduced by 65%."
		"shield": return "You are invulnerable."
		"speed": return "Movement speed greatly increased."
		"fortune": return "+75% item rarity, +50% gold."
		"enlight": return "+25% experience."
		"frenzied": return "20% faster cooldowns."
		"empowered": return "Ultimate charges twice as fast."
	return ""
