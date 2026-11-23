class_name Bosses
extends RefCounted
## Stage tyrants, the Rift Guardian, Rogue Exiles / Nemesis and the pinnacle Shard Herald.
## Every boss attack is a telegraph (World.Tele) so the player always gets a readable warning,
## and the same hazard code path is used for every shape.

var w: World
var bstate := {}                  # uid -> per-boss timers
var stage_uids: Array[int] = []
var guardian_uid := -1
var guardian_dead := false
var exile_uid := -1
var exile_name := ""
var exile_weapon := ""
var exile_nemesis := false
var exile_lvl := 0
var herald_uid := -1
var herald_at := 90.0
var herald_dead := false
var H := {}                       # herald FSM state
var win_t := -1.0

func _init(world: World) -> void:
	w = world

## Cycle 3: bosses spawned off-screen and walked at 50 px/s toward a hero kiting at 155 px/s, so a
## completed rift could time out without the guardian ever being met. They now arrive on-screen,
## behind a summoning ring, at 55% of the view radius.
func arrival_point() -> Vector2:
	var a := w.rng.randf() * TAU
	var p := w.pp + Vector2(cos(a), sin(a)) * w.view_r * 0.55
	if w.arena_r > 0.0 and p.length() > w.arena_r - 60.0:
		p = p.normalized() * (w.arena_r - 80.0)
	w.fx.append({"k": "ring", "pos": p, "r": 0.0, "max": 90.0, "col": Color("ff4fd8"), "life": 0.9, "t": 0.0})
	w._burst(p, Color("ff4fd8"), 24, 260.0)
	return p

# ---------------------------------------------------------------- stage boss
func spawn_stage_boss(twin: bool) -> void:
	w.boss_spawned = true
	var s: Dictionary = Content.STAGES[w.stage]
	var n := 2 if twin else 1
	for k in n:
		var i := w.sw.add(Content.E.BOSS, arrival_point(), 1400.0 * w.hp_mult() * (0.62 if twin else 1.0) * (2.2 if w.pace < 1.0 else 1.0), 46.0 * w.spd_mult(), 36.0, 16.0, 0.0, Swarm.F_BOSS, 0)
		if i < 0: continue
		var u := w.sw.uid[i]
		stage_uids.append(u)
		bstate[u] = {"bt": 2.0 + k, "sm": 6.0, "sl": 8.0 + k * 2.0}
		w.boss_max += w.sw.mhp[i]
	w.boss_uids = stage_uids
	var story := Story.act(w.stage)                  # the nameplate and the boss's taunt (Story)
	w.banner.emit(String(story.boss_name) + (" x2" if twin else ""), "\u201c%s\u201d" % story.boss_taunt, Content.col(s.boss_col))
	w.moment.emit("boss_spawn", {"boss": "tyrant", "name": String(s.boss)})
	w.shake = 0.8
	Sfx.play("boss")

# Tyrants and the Rift Guardian fight as a state machine: CHASE (walk at the hero) -> WINDUP (stand,
# telegraph the attack) -> EXECUTE (it lands) -> RECOVER (stand still; after the dash-cleave and the
# slam it is Exposed and takes 30% more damage: the punish window) -> CHASE. One attack at a time,
# never the same one twice in a row, chosen by range:
#   cleave  a line telegraph, a dash along it, then a cone cleave where it stops
#   volley  a cone telegraph, then three (four below half life) waves of shots down it
#   slam    a circle under the hero, the longest windup and the longest punish window
#   summon  a roar and a ring of minions (on its own cooldown)
#   bell    the Tide Bishop only: a wide cold blast around the hero
#   beam    the Rift Guardian only: a sweeping beam it channels in place
# Below half life the windups and the gaps between attacks shorten and it walks faster.
enum { CHASE, WINDUP, EXECUTE, RECOVER }

func _tyrant(i: int, st: Dictionary, dt: float, guardian: bool) -> void:
	var half := w.sw.hp[i] < w.sw.mhp[i] * 0.5
	var p := w.sw.pos[i]
	if not st.has("s"):
		st.s = CHASE
		st.t = 1.0 + float(st.get("bt", 2.0)) - 2.0           # twins start out of step
		st.spd = w.sw.spd[i]
		st.atk = ""
		st.last = ""
		st.sm_cd = 6.0
		st.beam_cd = 3.0
		st.exposed = false
	st.t -= dt
	st.sm_cd -= dt
	st.beam_cd -= dt
	match int(st.s):
		CHASE:
			w.sw.set_speed(i, (62.0 * w.spd_mult()) if half else float(st.spd))
			if st.t <= 0.0: _tyrant_windup(i, st, half, guardian, p)
		WINDUP:
			w.sw.set_speed(i, 0.0)
			if st.t <= 0.0: _tyrant_execute(i, st, half, p)
		EXECUTE:
			w.sw.set_speed(i, 0.0)
			_tyrant_execute_step(i, st, dt, half, p)
			if st.t <= 0.0: _tyrant_recover(i, st, half)
		RECOVER:
			w.sw.set_speed(i, 0.0)
			if st.t <= 0.0:
				st.s = CHASE
				st.exposed = false
				st.t = w.rng.randf_range(0.7, 1.2) if half else w.rng.randf_range(1.1, 1.8)
	if w.stage == 4 and not guardian and half and not st.get("flood", false):
		# below half life the Tide Bishop floods the nave for good
		st.flood = true
		w.terrain.tide += 10.0
		w.banner.emit("The nave floods", "The Tide Bishop calls the sea in.", Color("7fe0c0"))
		w.shake = 0.7

## True while this boss stands Exposed after a dash-cleave or a slam (World.hit adds 30% damage).
func exposed(u: int) -> bool:
	var st: Dictionary = bstate.get(u, {})
	return bool(st.get("exposed", false))

func _tyrant_windup(i: int, st: Dictionary, half: bool, guardian: bool, p: Vector2) -> void:
	var to := w.pp - p
	var d := to.length()
	var dir := to / maxf(1.0, d)
	var opts: Array = [["cleave", 3.0 if d > 160.0 else 1.0], ["volley", 2.0 if d > 200.0 else (0.6 if d > 140.0 else 0.0)], ["slam", 3.0 if d < 280.0 else 1.5]]
	if st.sm_cd <= 0.0: opts.append(["summon", 1.5])
	if w.stage == 4 and not guardian: opts.append(["bell", 2.0])
	if guardian and st.beam_cd <= 0.0: opts.append(["beam", 2.5])
	var tot := 0.0
	for o in opts:
		if o[0] == st.last: o[1] = 0.0
		tot += float(o[1])
	var r := w.rng.randf() * tot
	var atk: String = opts[0][0]
	for o in opts:
		r -= float(o[1])
		if r <= 0.0 and float(o[1]) > 0.0:
			atk = o[0]
			break
	st.atk = atk
	st.last = atk
	st.dir = dir
	st.s = WINDUP
	st.atk_t = w.t                                   # the rig plays its attack clip through windup and strike
	match atk:
		"cleave":
			st.t = 0.6 if half else 0.75
			st.len = clampf(d + 60.0, 160.0, 420.0)
			var z := w.add_tele(2, p, 0.0, st.t, 0.0, 20.0, true, false, -1, Color(1, 0.3, 0.25, 0.5), "a dash-cleave")
			z.length = st.len; z.width = 76.0; z.dir = dir
		"volley":
			st.t = 0.5 if half else 0.6
			var zv := w.add_tele(3, p, 460.0, st.t, 0.0, 0.0, false, false, -1, Color(1, 0.55, 0.3, 0.35), "a volley")
			zv.dir = dir; zv.ang = 0.5
		"slam":
			st.t = 0.85 if half else 1.0
			w.add_tele(0, w.pp, 110.0, st.t, 0.0, 22.0, true, false, -1, Color(1, 0.25, 0.3, 0.55), "a slam")
		"summon":
			st.t = 0.6
			Sfx.play("boss")
		"bell":
			st.t = 1.3
			w.add_tele(0, w.pp, 150.0, st.t, 0.0, 14.0, true, false, Content.El.COLD, Color(0.5, 0.95, 0.85, 0.5), "the tolling bell")
			Sfx.play("boss")
		"beam":
			st.t = 1.0
			var zb := w.add_tele(2, p, 0.0, st.t, 3.5, 6.0, true, false, -1, Color(1, 0.3, 0.9, 0.45), "the guardian's beam")
			zb.length = 620.0; zb.width = 36.0; zb.dir = dir; zb.spin = 0.9; zb.tick = 0.25

func _tyrant_execute(i: int, st: Dictionary, half: bool, p: Vector2) -> void:
	st.s = EXECUTE
	st.wave = 0
	st.wave_t = 0.0
	var dir: Vector2 = st.dir
	match String(st.atk):
		"cleave":
			st.t = 0.6                                   # 0.3 s dash, then the cleave lands where it stopped
			st.dash_v = float(st.len) / 0.3
			st.dash_t = 0.3
			var z := w.add_tele(3, p + dir * float(st.len), 140.0, 0.6, 0.0, 16.0, true, false, -1, Color(1, 0.35, 0.25, 0.5), "a dash-cleave")
			z.dir = dir; z.ang = 0.9
			Sfx.play("roll")
		"volley":
			st.waves = 4 if half else 3
			st.t = 0.15 * float(st.waves)
		"slam":
			st.t = 0.05
			w.shake = maxf(w.shake, 0.5)
		"summon":
			st.t = 0.05
			for k in 8:
				var a2 := TAU * k / 8.0
				w.spawn_foe(Content.E.GRUNT, p + Vector2(cos(a2), sin(a2)) * 60.0, 0)
			st.sm_cd = 6.5 if half else 9.0
		"bell":
			st.t = 0.05
		"beam":
			st.t = 3.5                                   # it channels in place while the beam sweeps
			st.beam_cd = 9.0

func _tyrant_execute_step(i: int, st: Dictionary, dt: float, half: bool, p: Vector2) -> void:
	match String(st.atk):
		"cleave":
			if float(st.dash_t) > 0.0:
				st.dash_t -= dt
				var np := p + (st.dir as Vector2) * float(st.dash_v) * dt
				if w.arena_r > 0.0 and np.length() > w.arena_r - 40.0: np = np.normalized() * (w.arena_r - 40.0)
				w.sw.set_pos(i, np)
		"volley":
			st.wave_t -= dt
			if st.wave_t <= 0.0 and int(st.wave) < int(st.waves):
				st.wave_t += 0.15
				st.wave += 1
				var n := 9 if half else 7
				var base := (st.dir as Vector2).angle()
				var spd := 170.0 * float(Content.STAGES[w.stage].spd)
				for k in n:
					var a := base + lerpf(-0.5, 0.5, float(k) / float(n - 1)) + (0.035 if int(st.wave) % 2 == 0 else 0.0)
					w.spawn_eshot(p, Vector2(cos(a), sin(a)) * spd, 8.0)
				Sfx.play("zap")

func _tyrant_recover(i: int, st: Dictionary, half: bool) -> void:
	st.s = RECOVER
	match String(st.atk):
		"cleave":
			st.t = 1.0
			st.exposed = true
		"slam":
			st.t = 1.4
			st.exposed = true
		"volley": st.t = 0.6
		"beam": st.t = 0.8
		_: st.t = 0.5
	if st.exposed:
		w._text(w.sw.pos[i] + Vector2(0, -40), 0.0, Color("ffd84a"), 3, -1, "Exposed")

# ---------------------------------------------------------------- rift guardian
func spawn_guardian() -> void:
	var i := w.sw.add(Content.E.BOSS, arrival_point(), 2600.0 * w.hp_mult(), 50.0 * w.spd_mult(), 40.0, 18.0, 0.0, Swarm.F_RIFTG, 0)
	if i < 0: return
	guardian_uid = w.sw.uid[i]
	bstate[guardian_uid] = {"bt": 2.0, "sm": 5.0, "sl": 6.0}
	w.boss_uids = [guardian_uid]
	w.boss_max = w.sw.mhp[i]
	w.banner.emit("Rift Guardian", "Greater Rift %d" % w.gr_level, Color("ff4fd8"))
	w.moment.emit("boss_spawn", {"boss": "tyrant", "name": "Rift Guardian"})
	Sfx.play("boss")

# ---------------------------------------------------------------- rogue exile / nemesis
func spawn_exile(nemesis: bool) -> void:
	var nm: Dictionary = Save.data.nemesis
	if nemesis and not nm.is_empty():
		exile_name = String(nm.name)
		exile_weapon = String(nm.weapon)
		exile_lvl = int(nm.level)
		exile_nemesis = true
	else:
		exile_name = Content.EXILE_NAMES[w.rng.randi_range(0, Content.EXILE_NAMES.size() - 1)] + " " + Content.EXILE_TITLES[w.rng.randi_range(0, Content.EXILE_TITLES.size() - 1)]
		exile_weapon = ["bolt", "nova", "storm"][w.rng.randi_range(0, 2)]
		exile_lvl = 0
	var m := pow(1.25, exile_lvl)
	var i := w.spawn_foe(Content.E.EXILE, w.ring_point(20.0), 0, Swarm.F_EXILE, m)
	if i < 0: return
	exile_uid = w.sw.uid[i]
	bstate[exile_uid] = {"atk": 2.0, "blink_hp": 1.0}
	var title := ("Nemesis " if exile_nemesis else "") + exile_name
	w.banner.emit(title, ("It remembers killing you. Level %d." % (exile_lvl + 1)) if exile_nemesis else "A Rogue Exile wielding " + Content.WEAPONS[exile_weapon].name, Color("ff8a2b"))
	Sfx.play("boss")

func _exile(i: int, st: Dictionary, dt: float) -> void:
	st.atk -= dt
	var p := w.sw.pos[i]
	var to := w.pp - p
	var dmg := 9.0 * (1.0 + 0.15 * exile_lvl)
	if st.atk <= 0.0:
		match exile_weapon:
			"bolt":
				var base := to.angle()
				for k in 5:
					var a := base + (k - 2) * 0.16
					w.spawn_eshot(p, Vector2(cos(a), sin(a)) * 260.0, dmg, 6.0, Color("aef4ff"))
				st.atk = 1.6
			"nova":
				if to.length() < 170.0:
					w.add_tele(0, p, 130.0, 0.6, 0.0, dmg * 1.8, true, false, -1, Color(1, 0.5, 0.3, 0.5), exile_name)
					st.atk = 2.2
				else:
					st.atk = 0.3
			_:
				for k in 3:
					w.add_tele(0, w.pp + Vector2(w.rng.randf_range(-70, 70), w.rng.randf_range(-70, 70)), 50.0, 0.9, 0.0, dmg * 1.5, true, false, -1, Color(0.8, 0.6, 1, 0.5), exile_name)
				st.atk = 2.5
	var frac := clampf(w.sw.hp[i] / w.sw.mhp[i], 0.0, 1.0)
	if st.blink_hp - frac > 0.15:            # blinks away after taking a big chunk
		st.blink_hp = frac
		var a := w.rng.randf() * TAU
		w.fx.append({"k": "ring", "pos": p, "r": 0.0, "max": 50.0, "col": Color("ff8a2b"), "life": 0.3, "t": 0.0})
		w.sw.set_pos(i, w.pp + Vector2(cos(a), sin(a)) * 220.0)

# ---------------------------------------------------------------- pinnacle: the Shard Herald
func spawn_herald() -> void:
	herald_at = 90.0

func _do_spawn_herald() -> void:
	var lv := maxf(1.0, float(w.lvl))
	# cycle 2: 9000 * (0.6 + 0.04 lv) died in 33 s; the pinnacle should be a 2-3 minute fight
	var i := w.sw.add(Content.E.HERALD, Vector2(0, -260), 24000.0 * (0.5 + 0.05 * lv), 70.0, 44.0, 20.0, 0.0, Swarm.F_HERALD, 0)
	if i < 0: return
	herald_uid = w.sw.uid[i]
	H = {"phase": 1, "cd": 2.5, "last": "", "enrage": w.t + 180.0, "enraged": false, "trans": 0.0}
	w.boss_uids = [herald_uid]
	w.boss_max = w.sw.mhp[i]
	w.banner.emit("The Shard Herald", "It sings the next shardfall.", Color("c48aff"))
	w.moment.emit("boss_spawn", {"boss": "herald", "name": "The Shard Herald"})
	w.shake = 1.0
	Sfx.play("boss")

func herald_phase() -> int:
	return int(H.get("phase", 0))

const HERALD_ATK := {1: ["volley", "slam", "summon"], 2: ["volley", "slam", "summon", "beam", "arena"], 3: ["volley", "beam", "arena", "storm", "storm"]}

func _herald(i: int, dt: float) -> void:
	var frac := w.sw.hp[i] / w.sw.mhp[i]
	var want := 1 if frac > 0.66 else (2 if frac > 0.33 else 3)
	if want > int(H.phase):
		H.phase = want
		H.trans = 2.0
		w.sw.set_freeze(i, 2.0)
		w.banner.emit("The Herald shatters", "Phase %d" % want, Color("c48aff"))
		w.nova_at(w.sw.pos[i], 1.0, 0.0, 0, Color("c48aff"))
		for k in 6:
			var a := TAU * k / 6.0
			w.spawn_foe(Content.E.BRUTE, w.sw.pos[i] + Vector2(cos(a), sin(a)) * 90.0, 1)
	if not H.enraged and w.t >= H.enrage:
		H.enraged = true
		w.banner.emit("ENRAGED", "The Herald's song becomes a scream.", Color("ff2b4a"))
	if H.trans > 0.0:
		H.trans -= dt
		return
	H.cd -= dt
	if H.cd > 0.0:
		return
	var opts: Array = HERALD_ATK[int(H.phase)].duplicate()
	opts.erase(H.last)
	var p := w.sw.pos[i]
	var far := p.distance_to(w.pp) > 300.0
	var atk: String = opts[w.rng.randi_range(0, opts.size() - 1)]
	if far and w.rng.randf() < 0.5 and opts.has("volley"):
		atk = "volley"
	H.last = atk
	H.atk_t = w.t
	var em := 3.0 if H.enraged else 1.0
	var dmg := 14.0 * em
	match atk:
		"volley":
			for wv in 3:
				var base := (w.pp - p).angle() + wv * 0.1
				for k in 9:
					var a := base + (k - 4) * 0.14
					w.spawn_eshot(p, Vector2(cos(a), sin(a)) * (210.0 + wv * 40.0), dmg * 0.6, 7.0, Color("d8b0ff"))
		"slam":
			for k in 3:
				var z := w.add_tele(0, w.pp + w.face * 70.0 * k, 85.0, 0.9 + 0.35 * k, 0.0, dmg * 1.6, true, false, -1, Color(0.8, 0.4, 1, 0.5), "the Herald")
		"summon":
			for k in 6:
				var a2 := TAU * k / 6.0
				w.spawn_foe(Content.E.GRUNT, p + Vector2(cos(a2), sin(a2)) * 70.0, 1 if k == 0 else 0)
		"beam":
			for k in 2:
				var z2 := w.add_tele(2, p, 0.0, 1.0, 3.5, dmg * 0.5, true, false, -1, Color(1, 0.4, 1, 0.45), "the Herald's beam")
				z2.length = 700.0; z2.width = 40.0; z2.dir = (w.pp - p).normalized().rotated(PI * k); z2.spin = 0.8; z2.tick = 0.25
		"arena":
			var z3 := w.add_tele(1, Vector2.ZERO, w.arena_r, 1.5, 7.0, dmg * 0.6, true, false, -1, Color(0.6, 0.2, 1, 0.4), "the closing arena")
			z3.r2 = w.arena_r - 150.0
			z3.tick = 0.5
		"storm":
			for k in 10:
				w.add_tele(0, w.pp + Vector2(w.rng.randf_range(-220, 220), w.rng.randf_range(-220, 220)), 55.0, w.rng.randf_range(0.9, 1.6), 0.0, dmg, true, false, -1, Color(0.9, 0.5, 1, 0.5), "the shard storm")
	var base_cd: float = [0.0, 3.0, 2.6, 1.9][int(H.phase)]
	H.cd = base_cd * (0.5 if H.enraged else 1.0)

# ---------------------------------------------------------------- per-frame
func step(dt: float) -> void:
	if win_t > 0.0:
		win_t -= dt
		if win_t <= 0.0:
			w.end_run(true)
		return
	for u in stage_uids:
		var i := w.sw.index_of(u)
		if i >= 0: _tyrant(i, bstate[u], dt, false)
	if guardian_uid >= 0:
		var gi := w.sw.index_of(guardian_uid)
		if gi >= 0: _tyrant(gi, bstate[guardian_uid], dt, true)
	if exile_uid >= 0:
		var ei := w.sw.index_of(exile_uid)
		if ei >= 0: _exile(ei, bstate[exile_uid], dt)
	if w.mode == "pinnacle":
		if herald_uid < 0 and not herald_dead and w.t >= herald_at:
			_do_spawn_herald()
		var hi := w.sw.index_of(herald_uid)
		if hi >= 0: _herald(hi, dt)
	if w.mode == "rift" and guardian_uid < 0 and w.progress >= Content.GR_PROGRESS:
		spawn_guardian()

func boss_hp_frac() -> float:
	if w.boss_max <= 0.0:
		return -1.0
	var tot := 0.0
	var any := false
	for u in w.boss_uids:
		var i := w.sw.index_of(u)
		if i >= 0:
			tot += maxf(0.0, w.sw.hp[i])
			any = true
	return tot / w.boss_max if any else -1.0

func on_kill(i: int, at: Vector2) -> void:
	var f := w.sw.flags[i]
	var u := w.sw.uid[i]
	if (f & Swarm.F_BOSS) != 0 and stage_uids.has(u):
		var alive := 0
		for su in stage_uids:
			if su != u and w.sw.index_of(su) >= 0 and w.sw.hp[w.sw.index_of(su)] > 0.0: alive += 1
		w.loot_shower(at, 2, 2, 10, Content.Rarity.RARE)
		if alive == 0:
			w.moment.emit("boss_die", {"boss": "tyrant", "name": String(Content.STAGES[w.stage].boss)})
			_victory(at, "The tyrant falls")
			if w.mode == "atlas" and w.node.get("kind", "") == "citadel":
				w.add_pick(at, "fragment", 0.0, ["rupture", "greed", "dread"][w.rng.randi_range(0, 2)])
	elif (f & Swarm.F_RIFTG) != 0:
		guardian_dead = true
		var left := Content.GR_TIME - w.t
		var up := 3 if left >= 120.0 else (2 if left >= 60.0 else (1 if left > 0.0 else 0))
		Save.data.gr_best = maxi(int(Save.data.gr_best), w.gr_level if left > 0.0 else int(Save.data.gr_best))
		Save.data.gr_key = maxi(int(Save.data.gr_key), w.gr_level + up)
		Save.mark_dirty()
		w.loot_shower(at, 3, 4, 20, Content.Rarity.RARE)
		w.moment.emit("boss_die", {"boss": "tyrant", "name": "Rift Guardian"})
		if w.rng.randf() < 0.15 + 0.01 * w.gr_level: w.drop_item(at, Content.Rarity.LEGENDARY)
		_victory(at, "Rift complete: key upgraded +%d" % up if up > 0 else "Rift complete (out of time)")
	elif (f & Swarm.F_EXILE) != 0:
		w.banner.emit(exile_name + " is slain", "Nemesis vanquished." if exile_nemesis else "Their loot is yours.", Color("ff8a2b"))
		w.loot_shower(at, 2 + exile_lvl, 3, 20, Content.Rarity.RARE)
		if exile_nemesis:
			w.drop_item(at, Content.Rarity.LEGENDARY)
			Save.data.nemesis = {}
			Save.mark_dirty()
		exile_uid = -1
	elif (f & Swarm.F_HERALD) != 0:
		herald_dead = true
		w.moment.emit("boss_die", {"boss": "herald", "name": "The Shard Herald"})
		Save.data.herald_kills = int(Save.data.herald_kills) + 1
		Save.mark_dirty()
		w.loot_shower(at, 4, 6, 40, Content.Rarity.RARE)
		w.drop_item(at, Content.Rarity.LEGENDARY)
		w.drop_item(at, Content.Rarity.LEGENDARY)
		w.drop_lore(at)
		_victory(at, "The song ends")

func _victory(at: Vector2, msg: String) -> void:
	w.banner.emit(msg, "Collect your spoils.", Color("ffd84a"))
	if w.rng.randf() < 0.4: w.drop_lore(at)
	for i in w.sw.n:
		if (w.sw.flags[i] & (Swarm.F_BOSS | Swarm.F_RIFTG | Swarm.F_HERALD)) == 0:
			w.sw.set_flags(i, Swarm.F_ALLY)
			w.sw.take(i, 1e9)
	w.eshots.clear()
	w.teles.clear()
	w.vacuum()
	w.shake = 1.0
	win_t = 4.0
	Sfx.play("win")

## Nemesis system: an exile that kills you returns stronger in the next run.
func on_player_death() -> void:
	if exile_uid >= 0 and w.sw.index_of(exile_uid) >= 0 and w.killer == exile_name:
		Save.data.nemesis = {"name": exile_name, "weapon": exile_weapon, "level": exile_lvl + 1}
		Save.mark_dirty()
