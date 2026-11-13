class_name World
extends RefCounted
## The run simulation. Pure logic: no nodes, no rendering, so it runs headless at any speed for
## tests and balance bots. Rendering (WorldView) and UI only read from it and push input into it.
##
## Frame order: buffs/stats -> input/move/roll -> spawn -> grid -> foe AI + separation -> contact
## -> weapons -> projectiles -> telegraphs -> DoTs -> reactions -> director/bosses -> pickups -> reap -> level.

signal level_up
signal toast(text: String, col: Color)
signal banner(title: String, sub: String, col: Color)
signal ended(win: bool)
signal merchant_open
signal whisper_open          # the hero touched the Whisperer: whisper_offer holds two bargain ids
signal item_found(item: Dictionary, upgrade: bool)

class Proj:
	var pos := Vector2.ZERO
	var vel := Vector2.ZERO
	var life := 0.0
	var r := 5.0
	var dmg := 0.0
	var pierce := 0
	var chain := 0
	var el := 0
	var wid := ""
	var hits: Array[int] = []
	var dead := false
	var col := Color.WHITE
	var kind := 0             # 0 shot, 1 mine, 2 returning glaive, 3 homing wisp, 4 totem
	var age := 0.0
	var aux := 0.0            # mine/totem: blast radius or fire interval; glaive: 1 once it has turned back
	var tick := 0.0

class Tele:
	var shape := 0            # 0 circle, 1 ring, 2 line (pos -> pos + dir * len), 3 cone
	var pos := Vector2.ZERO
	var dir := Vector2.RIGHT
	var r := 50.0
	var r2 := 0.0
	var length := 0.0
	var width := 30.0
	var ang := 0.6
	var arm := 1.0
	var arm_max := 1.0
	var life := 0.0           # persistent zones keep biting this long after arming
	var dmg := 10.0
	var hostile := true       # hurts the player
	var friendly := false     # hurts foes
	var el := -1
	var tick := 0.5
	var tk := 0.0
	var col := Color(1, 0.3, 0.3)
	var tag := ""
	var spin := 0.0
	var done := false
	var follow := false

const VIEW_R_DEFAULT := 640.0
const STASH_CAP := 80

# ---------------------------------------------------------------- config
var mode := "campaign"        # campaign | atlas | rift | pinnacle
var stage := 0
var hero := 0
var gr_level := 1
var node: Dictionary = {}
var map_mods: Array = []
var season := ""
var rng := RandomNumberGenerator.new()
var headless := false         # tests: no profile writes beyond the in-memory dict
var view_r := VIEW_R_DEFAULT
var terrain: Terrain = null      # set by setup(); heights, water and passability
var torment := 0                 # difficulty tier (Content.TORMENT); 0 in rifts, which scale by level
var echoes_run := 0              # Echoes earned (set at the end of the run)
var moon := -1.0                 # real-world lunar phase 0..1 (0 new, 0.5 full); < 0 = no sky (tests)
var sky_date: Array = []         # [month, day] for the calendar omens
var light := 1.0                 # the lantern: fades over time, kills relight it (see _step_light)
var light_cap := 1.0
var bargains: Array = []         # the Whisperer's bargains accepted this run (Content.WHISPERS ids)
var hoard := 0.0                 # bank-or-push: fills with kills/elites/events; banked at Rift Gates
var hoard_mult := 1.0            # grows each time a gate is walked past (x1 .. x3)
var hoard_banked := 0.0          # total banked this run (after multipliers)
var hoard_lost := 0.0            # unbanked hoard lost on death
var hoard_echoes := 0            # Echoes earned by banking (added at end_run)
var daily := false               # the Daily Rift (or a shared code): no gear, passives, legendaries or sky
var daily_code := ""
var daily_date := ""
var daily_score := 0
var daily_best := false
var prophecy := {}               # the active prophecy {id, reward} (from the profile; cleared when fulfilled)
var prophecy_done := false
var whisper_offer: Array = []    # two ids while the bargain screen is open
var _night_q := -1
var colorblind := false
var aim_mode := 0

# ---------------------------------------------------------------- subsystems
var sw := Swarm.new()
var grid := SpatialGrid.new()
var stats := Stats.new()
var buffs: Buffs
var director: Director
var bosses: Bosses
var crowd: CrowdCompute = null

# ---------------------------------------------------------------- player
var pp := Vector2.ZERO
var face := Vector2.RIGHT
var hp := 100.0
var max_hp := 100.0
var lvl := 1
var xp := 0.0
var need := 9.0
var inv_t := 0.0
var hit_t := 0.0
var mv := 0.0
var walk_ph := 0.0
var roll_t := 0.0
var roll_age := 9.0
var roll_cd := 0.0
var roll_dir := Vector2.RIGHT
var roll_buffer := 0.0
var roll_perfect_used := false
var ult := 0.0
var ult_cd := 0.0
var _ult_lock := 0.0
const ULT_RATE_CAP := 8.0          # max charge per second (a full bar takes >= 12.5 s of fighting)
var flasks: Array = []
var heal_hot := 0.0
var phoenix_used := false
var momentum := 0.0
var hit_count := 0
var regen_acc := 0.0
var cast_t := -9.0                # renderer feed: last weapon cast (hero turns and thrusts toward it)
var cast_dir := Vector2.RIGHT
var breakables: Array = []        # {pos, kind 0 urn / 1 barrel, r}; skills shatter them for small loot (PoE2)
var broken: Array = []            # renderer feed: [pos, kind]
var _brk_t := 6.0
var deaths: Array = []            # renderer feed: [pos, colour, radius, elite] per kill, consumed by the 3D view

# input written by the controller (touch, keyboard, gamepad or test bot)
var in_move := Vector2.ZERO
var in_roll := false
var in_ult := false
var in_flask := [false, false]

# ---------------------------------------------------------------- build
var weapons := {}             # id -> {lv, evo, t, gems: [ids]}
var wlocal := {}              # id -> Stats (gem modifiers local to that weapon)
var perks := {}
var keystones: Array = []
var _elmask_cache := {}
var _elmask_ver := -1

# ---------------------------------------------------------------- entities
var projs: Array[Proj] = []
var eshots: Array[Proj] = []
var _pool: Array[Proj] = []
var teles: Array[Tele] = []
var gem_pos := PackedVector2Array()
var gem_val := PackedFloat32Array()
var gem_mag := PackedByteArray()
var gem_age := PackedFloat32Array()
var gem_n := 0
const GEM_CAP := 400
var picks: Array = []         # {pos, k, v, life, mag, data}
var blades := PackedVector2Array()
var delayed: Array = []       # [time, callable] (echo casts)
var react_q: Array = []

# ---------------------------------------------------------------- run state
var t := 0.0
var kills := 0
var gold := 0.0
var combo := 0
var combo_t := 0.0
var best_combo := 0
var pending := 0
var over := false
var won := false
var killer := ""
var shake := 0.0
var hitstop := 0.0
var slow_t := 0.0
var flash := 0.0
var recent_dmg := 0.0
var boss_spawned := false
var boss_uids: Array[int] = []
var boss_max := 0.0
var progress := 0.0
var arena_r := 0.0
var spawn_acc := 0.0
var swarm_t := 35.0
var bestiary_run := {}
var loot_run: Array = []
var currency_run := {}
var lore_run: Array = []
var frags_run := {}

# ---------------------------------------------------------------- render feed (sim owns the lifetimes)
var texts: Array = []         # {pos, v, col, tier, t, uid}
var fx: Array = []            # {k, pos, r, col, life, t, pts, to}
var bursts: Array = []        # [pos, col, n, speed] consumed by the renderer each frame
var _agg := {}
var _label_t := {}
var _crit_stop := -9.0
var metrics := {"reactions": 0, "react_by": {}, "texts": 0, "peak_foes": 0, "dmg_taken": 0.0, "perfect": 0, "events": {}, "dmg_dealt": 0.0,
	"react_dropped": 0, "cascade_max": 0, "items": 0, "deaths_by": "", "high_ground": 0, "terrain": {"freeze": 0, "shock": 0, "steam": 0}}

# ================================================================= setup
func setup(cfg: Dictionary) -> void:
	mode = cfg.get("mode", "campaign")
	pace = Content.PACE_REF / Content.STAGE_TIME if (mode == "campaign" or mode == "atlas") else 1.0
	xp_scale = 3.0 if pace < 1.0 else 1.0
	stage = int(cfg.get("stage", 0))
	hero = int(cfg.get("hero", 0))
	weapon_pool = cfg.get("weapons_pool", Content.WEAPON_IDS if cfg.get("daily", false) else Save.weapon_pool())
	gr_level = int(cfg.get("gr", 1))
	node = cfg.get("node", {})
	map_mods = node.get("mods", []) if not node.is_empty() else []
	daily = bool(cfg.get("daily", false))
	if daily:
		map_mods = cfg.get("mods", [])
		daily_code = String(cfg.get("code", ""))
		daily_date = String(cfg.get("date", ""))
	if not node.is_empty():
		stage = int(node.biome)
	season = cfg.get("season", Save.season().id) if not daily else ""
	moon = float(cfg.get("moon", -1.0))
	prophecy = (cfg.get("prophecy", Save.data.prophecy.active) as Dictionary).duplicate() if mode != "pinnacle" else {}
	sky_date = cfg.get("sky_date", [])
	headless = cfg.get("headless", false)
	torment = 0 if mode == "rift" else clampi(int(cfg.get("torment", Save.data.get("torment", 0))), 0, Content.TORMENT.size() - 1)
	if cfg.has("seed"):
		rng.seed = int(cfg.seed)
	else:
		rng.randomize()
	seed(rng.randi())
	colorblind = bool(Save.opt("colorblind"))
	aim_mode = int(Save.opt("aim"))
	buffs = Buffs.new(stats)
	director = Director.new(self)
	bosses = Bosses.new(self)
	var h: Dictionary = Content.HEROES[hero]
	weapons[h.weapon] = {"lv": 1, "evo": false, "t": 0.0, "gems": []}
	wlocal[h.weapon] = Stats.new()
	flasks = [{"id": "life", "c": 40.0, "max": 60.0, "cost": 20.0}, {"id": Content.UTIL_FLASKS[rng.randi_range(0, 3)], "c": 30.0, "max": 40.0, "cost": 20.0}]
	_apply_meta()
	max_hp = stats.value("max_hp", float(h.hp))
	hp = max_hp
	need = _need(1)
	if mode == "atlas":                        # map head start: two extra picks per tier above 1
		var bonus := mini(10, 2 * (int(node.tier) - 1))
		lvl += bonus
		pending += bonus
		need = _need(lvl)
	if mode == "pinnacle":
		arena_r = 520.0
	var tp: Dictionary = Content.TERRAIN[mini(stage, Content.TERRAIN.size() - 1)]
	terrain = Terrain.new(stage, rng.randi(), tp, (arena_r + 160.0) if mode == "pinnacle" else 260.0)
	if mode == "pinnacle":
		bosses.spawn_herald()
	if Save.has_nemesis() and mode != "pinnacle":
		director.nemesis_pending = true

## Profile-driven modifiers: meta gold upgrades are folded into gear in this version; equipped
## items, codex legendary powers, bestiary bonuses, lore sets and map mods.
func _apply_meta() -> void:
	if daily:                                  # everyone starts equal: map modifiers only
		var dm: Array = []
		for m in map_mods:
			if m == "hexed": dm.append(["regen", "more", 0.5]); dm.append(["flask_charge", "more", 0.5])
		stats.set_source("map", dm)
		return
	for s in Content.SLOTS:
		var it: Dictionary = Save.data.equipped.get(s, {})
		if not it.is_empty():
			stats.set_source("item:" + s, Items.mods(it))
	var sets := Save.lore_sets()
	if sets > 0:
		stats.set_source("lore", [["damage", "inc", 0.05], ["max_hp", "add", 10.0]], float(sets))
	var mm: Array = []
	for m in map_mods:
		match m:
			"hexed": mm.append(["regen", "more", 0.5]); mm.append(["flask_charge", "more", 0.5])
	var rw := Atlas.rewards(node) if not node.is_empty() else Vector2.ZERO
	mm.append(["item_quantity", "inc", rw.x])
	mm.append(["item_rarity", "inc", rw.y])
	if season == "blight": mm.append(["item_quantity", "inc", 0.25])
	if mode == "rift":
		mm.append(["item_rarity", "inc", 0.04 * gr_level])
		mm.append(["xp_gain", "more", 0.6])     # cycle 3: dense rift spawns out-levelled the +17%/level curve
	var T: Dictionary = Content.TORMENT[torment]
	if torment > 0:
		mm.append(["item_quantity", "inc", float(T.loot)])
		mm.append(["item_rarity", "inc", float(T.loot) * 0.7])
		mm.append(["gold_find", "inc", float(T.gold)])
	stats.set_source("map", mm)
	stats.set_source("passives", Content.passive_mods(Save.data.get("passives", [])))
	stats.set_source("sky", Moon.mods(moon, sky_date))

func has_leg(id: String) -> bool:
	if daily: return false
	if Save.data.codex_active.has(id):
		return true
	for s in Content.SLOTS:
		var it: Dictionary = Save.data.equipped.get(s, {})
		if not it.is_empty() and it.leg == id:
			return true
	return false

func has_mod(id: String) -> bool:
	return map_mods.has(id)

## Superlinear past ~level 20 so long rifts do not snowball (cycle 1: bots hit level 50+).
func _need(l: int) -> float:
	# long acts: quick early levels (a build forms in the first two minutes), then a steepening climb,
	# so a run that snowballs ends near level 45 rather than 65
	return (5.0 + l * 4.0 + 0.15 * l * l) * (xp_scale if pace >= 1.0 else 1.5 + 0.12 * l)

## Acts last Content.STAGE_TIME; the difficulty ramps (spawn rate, foe mix, foe life) were tuned on
## PACE_REF-second acts, so campaign and atlas runs read them through rt(): the same curve, stretched.
## Rifts and the pinnacle fight keep real time.
var pace := 1.0
var xp_scale := 1.0
func rt() -> float:
	return t * pace

# ================================================================= difficulty
func hp_mult() -> float:
	var s: Dictionary = Content.STAGES[stage]
	var m := float(s.hp) * (1.0 + rt() / 110.0)
	if mode == "atlas":
		# cycle 3: full tier pressure ramps in over ~60 s so a fresh level-1 hero can draft first
		m = (1.0 + 0.35 * (int(node.tier) - 1) * minf(1.0, 0.4 + rt() / 100.0)) * (1.0 + rt() / 110.0)
	if mode == "rift": m = 1.5 * float(s.hp) * Content.gr_hp_mult(gr_level) * (1.0 + t / 240.0)
	if pace < 1.0: m *= 1.0 + 2.2 * pow(clampf(t / Content.STAGE_TIME, 0.0, 1.0), 2.0)     # long acts: builds grow further, so do foes
	if has_mod("hardened"): m *= 1.4
	return m * float(Content.TORMENT[torment].hp) * stats.value("foe_hp", 1.0)

func dmg_mult() -> float:
	var s: Dictionary = Content.STAGES[stage]
	var m := float(s.dmg) * (1.0 + rt() / 300.0)     # cycle 2: late-run foes barely scratched the bot
	if mode == "atlas": m = (1.0 + 0.12 * (int(node.tier) - 1)) * (1.0 + rt() / 300.0)
	if mode == "rift": m *= Content.gr_dmg_mult(gr_level)
	if has_mod("lethal"): m *= 1.3
	return m * float(Content.TORMENT[torment].dmg) * stats.value("foe_dmg", 1.0) * (1.0 + 0.3 * engulfed())

func spd_mult() -> float:
	return float(Content.STAGES[stage].spd) * (1.0 + minf(0.25, rt() / 600.0)) * (1.2 if has_mod("swift") else 1.0)

# ================================================================= main step
var step_us := 0.0               # smoothed cost of step() (diagnostics: CPU sim vs render)

func step(dt: float) -> void:
	if over:
		return
	var _t0 := Time.get_ticks_usec()
	_step(dt)
	step_us = lerpf(step_us, float(Time.get_ticks_usec() - _t0), 0.1)

func _step(dt: float) -> void:
	if over:
		return
	if hitstop > 0.0:
		hitstop -= dt
		shake = maxf(0.0, shake - dt * 1.5)
		return
	if slow_t > 0.0:                         # perfect-dodge slow motion
		slow_t -= dt
		dt *= 0.4
	t += dt
	sw.clock = t
	Sfx.listener = pp
	terrain.step(dt)
	terrain.prefetch(pp, 3, 1)
	if terrain.tide > 0.0:
		_step_tide()
	if fmod(t, 7.0) < dt: terrain.trim(pp)
	buffs.step(dt)
	_step_light(dt)
	_step_surfaces(dt)
	_step_prophecy(dt)
	_refresh_max_hp()
	shake = maxf(0.0, shake - dt * 1.8)
	flash = maxf(0.0, flash - dt)
	recent_dmg = maxf(0.0, recent_dmg - dt * max_hp * 0.08)
	if combo_t > 0.0:
		combo_t -= dt
		if combo_t <= 0.0: combo = 0
	_step_player(dt)
	_spawn(dt)
	grid.build(sw)
	_step_foes(dt)
	_contact()
	_step_weapons(dt)
	_step_delayed()
	_step_meteors()
	_step_projs(dt)
	_step_eshots(dt)
	_step_teles(dt)
	_step_dots(dt)
	_resolve_reactions()
	director.step(dt)
	bosses.step(dt)
	_step_breakables(dt)
	_step_pickups(dt)
	_step_feed(dt)
	_reap()
	metrics.peak_foes = maxi(metrics.peak_foes, sw.n)
	while xp >= need:
		xp -= need
		lvl += 1
		need = _need(lvl)
		pending += 1
	if pending > 0:
		level_up.emit()

func _refresh_max_hp() -> void:
	var m := stats.value("max_hp", float(Content.HEROES[hero].hp))
	if absf(m - max_hp) > 0.01:
		var frac := hp / max_hp
		max_hp = m
		hp = clampf(frac * max_hp, 1.0, max_hp)

# ================================================================= player
func _step_player(dt: float) -> void:
	var spd := stats.value("move_speed", float(Content.HEROES[hero].spd))
	var mvv := in_move.limit_length(1.0)
	var tm := terrain.speed_mul(pp)
	var np := pp
	if roll_t > 0.0:
		roll_t -= dt
		np += roll_dir * spd * 2.6 * dt               # a roll is not slowed by shallows
	else:
		np += mvv * spd * tm * dt
	pp = terrain.move(pp, np)
	if terrain.burns(pp):
		_lava_t -= dt
		if _lava_t <= 0.0:
			_lava_t = 0.5
			hurt_player(max_hp * 0.05, "Molten shallows")
	else:
		_lava_t = 0.0
	roll_age += dt
	if arena_r > 0.0 and pp.length() > arena_r - 14.0:
		pp = pp.normalized() * (arena_r - 14.0)
	if mvv.length() > 0.05 and roll_t <= 0.0:
		face = mvv.normalized()
	mv = lerpf(mv, mvv.length(), minf(1.0, 12.0 * dt))
	walk_ph += dt * (7.0 + 9.0 * mv)
	if keystones.has("momentum"):
		momentum = minf(10.0, momentum + dt) if mvv.length() > 0.3 else 0.0
	if inv_t > 0.0: inv_t -= dt
	if hit_t > 0.0: hit_t -= dt
	if roll_cd > 0.0: roll_cd -= dt
	if ult_cd > 0.0: ult_cd -= dt
	# dodge roll with a 0.15s input buffer
	if in_roll:
		roll_buffer = 0.15
		in_roll = false
	if roll_buffer > 0.0:
		roll_buffer -= dt
		if roll_cd <= 0.0 and not stats.flag("no_roll"):
			_roll(mvv)
			roll_buffer = 0.0
	if in_ult:
		in_ult = false
		use_ult()
	for f in 2:
		if in_flask[f]:
			in_flask[f] = false
			use_flask(f)
	# regeneration
	var rg := stats.value("regen", 0.0) + stats.value("regen_pct", 0.0) * max_hp
	if heal_hot > 0.0:
		var h := minf(heal_hot, max_hp * 0.25 * dt)
		heal_hot -= h
		rg += h / dt
	if rg > 0.0:
		hp = minf(max_hp, hp + rg * dt)
	if buffs.has("conduit"):
		_conduit(dt)

var _lava_t := 0.0
var _tide_step := 0

## Act V: the water climbs over the act (and keeps climbing while its boss lives); a banner marks each third.
func _step_tide() -> void:
	var k := clampf(t / Content.STAGE_TIME, 0.0, 1.0)
	if boss_spawned: k = 1.0 + minf(0.6, (t - Content.STAGE_TIME) / 120.0)
	terrain.set_level(terrain.level0 + terrain.tide * k)
	var step := int(k * 3.0)
	if step > _tide_step and step <= 3:
		_tide_step = step
		banner.emit("The tide rises", "Deep water spreads; cold makes a road across it.", Color("7fe0c0"))

func _roll(mvv: Vector2) -> void:
	roll_dir = mvv.normalized() if mvv.length() > 0.1 else face
	roll_t = 0.26
	roll_age = 0.0
	roll_perfect_used = false
	roll_cd = 1.4 * stats.value("dodge_cd", 1.0)
	_burst(pp, Color(0.8, 0.8, 0.9), 6, 90.0)
	Sfx.play("roll")
	if has_leg("ouroboros"):
		nova_at(pp, 110.0, weapon_damage_base() * 1.5, 1 << Content.El.FIRE, Color("ff8a3c"))

func invulnerable() -> bool:
	return roll_t > 0.0 or inv_t > 0.0 or stats.flag("invuln")

## Returns true when the hit landed.
func hurt_player(d: float, src: String = "") -> bool:
	if over:
		return false
	if roll_t > 0.0:
		if roll_age < 0.2 and not roll_perfect_used:      # perfect dodge: slow-mo + guaranteed crits
			roll_perfect_used = true
			slow_t = 0.35
			buffs.add("riposte")
			metrics.perfect += 1
			fx.append({"k": "ring", "pos": pp, "r": 0.0, "max": 120.0, "col": Color(1, 1, 1, 0.9), "life": 0.35, "t": 0.0})
			toast.emit("Perfect dodge!", Color.WHITE)
			Sfx.play("perfect")
		return false
	if inv_t > 0.0 or stats.flag("invuln"):
		return false
	var armor := stats.value("armor", 0.0)
	d *= dmg_mult() * 100.0 / (100.0 + maxf(0.0, armor))
	hp -= d
	inv_t = 0.5
	hit_t = 0.15
	shake = minf(1.0, shake + 0.35)
	recent_dmg += d
	metrics.dmg_taken += d
	_burst(pp, Color("ee5a5f"), 8, 160.0)
	Sfx.play("hurt")
	if hp <= 0.0:
		if has_leg("phoenix") and not phoenix_used:
			phoenix_used = true
			hp = max_hp * 0.5
			inv_t = 2.0
			nova_at(pp, 240.0, weapon_damage_base() * 8.0, 1 << Content.El.FIRE, Color("ffb24a"))
			banner.emit("Phoenix Ember", "You rise from the ashes.", Color("ffb24a"))
		else:
			hp = 0.0
			killer = src
			metrics.deaths_by = src
			end_run(false)
	return true

func use_flask(f: int) -> void:
	var fl: Dictionary = flasks[f]
	if fl.c < fl.cost:
		return
	if f == 0 and has_bargain("blood_price"):          # the Whisperer's price: the flask is poison now
		fl.c -= fl.cost
		Sfx.play("flask")
		nova_at(pp, 190.0, weapon_damage_base() * 6.0, 1 << Content.El.CHAOS, Color("7dff6b"), 260.0)
		var pz := add_tele(0, pp, 150.0, 0.0, 4.0, weapon_damage_base() * 0.9, false, true, Content.El.CHAOS, Color(0.45, 1.0, 0.4, 0.45), "ground")
		pz.follow = true
		pz.tick = 0.4
		return
	if f == 0 and stats.value("flask_heal", 1.0) <= 0.0:
		return
	fl.c -= fl.cost
	Sfx.play("flask")
	match fl.id:
		"life": heal_hot += max_hp * 0.45 * stats.value("flask_heal", 1.0)
		"sulphur":
			var z := add_tele(0, pp, 120.0, 0.0, 5.0, weapon_damage_base() * 0.8, false, true, Content.El.FIRE, Color(1.0, 0.55, 0.2, 0.5), "ground")
			z.follow = true
			z.tick = 0.4
		_: buffs.add(fl.id)

func gain_flask(v: float) -> void:
	var m := stats.value("flask_charge", 1.0)
	for fl in flasks:
		fl.c = minf(fl.max, fl.c + v * m)

func use_ult() -> void:
	var blood := keystones.has("bloodmagic")
	if blood:
		if ult_cd > 0.0 or hp <= max_hp * 0.31: return
		hp -= max_hp * 0.3
		ult_cd = 10.0
	elif ult < 100.0:
		return
	else:
		ult = 0.0
	var h: String = Content.HEROES[hero].id
	_ult_lock = t + 6.0
	shake = 1.0
	flash = 0.25
	Sfx.play("ult")
	banner.emit(Content.HEROES[hero].ult, "", Content.col(Content.HEROES[hero].col))
	match h:
		"warden": buffs.add("cyclone")
		"spark":
			for i in sw.n:
				if sw.pos[i].distance_to(pp) < view_r:
					sw.set_freeze(i, 2.5)
					hit(i, weapon_damage_base() * 6.0, 1 << Content.El.COLD, (sw.pos[i] - pp).normalized(), 0.0, 0)
			fx.append({"k": "ring", "pos": pp, "r": 0.0, "max": view_r, "col": Color("aef4ff"), "life": 0.6, "t": 0.0})
			terrain.freeze(pp, view_r, 9.0)             # every lake on screen becomes a road
		"ember":
			nova_at(pp, view_r * 0.9, weapon_damage_base() * 10.0, 1 << Content.El.FIRE, Color("ff8a3c"))
			for k in 6:
				var a := TAU * k / 6.0
				var z := add_tele(0, pp + Vector2(cos(a), sin(a)) * 160.0, 70.0, 0.0, 6.0, weapon_damage_base() * 0.7, false, true, Content.El.FIRE, Color(1, 0.45, 0.15, 0.45), "ground")
				z.tick = 0.4
		"storm": buffs.add("thunderdome")

## Cycle 3: a screen-wide ultimate used to refund itself (its own damage and kills charged it),
## looping forever at GR25. Charge is now blocked for 6 s after a cast and rate-capped per second.
var _ult_gain_window := 0.0
var _ult_gain := 0.0
func charge_ult(v: float) -> void:
	if t < _ult_lock:
		return
	if t - _ult_gain_window >= 1.0:
		_ult_gain_window = t
		_ult_gain = 0.0
	var add := minf(v * stats.value("ult_charge", 1.0), maxf(0.0, ULT_RATE_CAP - _ult_gain))
	_ult_gain += add
	ult = minf(100.0, ult + add)

# ================================================================= spawning
func spawn_rate() -> float:
	var r := (1.4 + rt() * 0.045) * director.rate_mult()
	if mode == "rift": r = (2.6 + t * 0.05) * director.rate_mult()
	if mode == "pinnacle": r = 1.8 if bosses.herald_uid < 0 else (0.6 if bosses.herald_phase() < 3 else 1.4)
	if boss_spawned and mode != "rift": r *= 0.5
	if has_mod("packed"): r *= 1.4
	return r * Moon.spawn_mult(moon)

func foe_cap() -> int:
	return mini(Swarm.CAP - 60, 190 + stage * 25 + (40 if mode == "rift" else 0))

func _spawn(dt: float) -> void:
	spawn_acc += spawn_rate() * dt
	while spawn_acc >= 1.0:
		spawn_acc -= 1.0
		if sw.n < foe_cap():
			spawn_foe(_pick_type())
	if mode != "pinnacle" and not boss_spawned and t >= swarm_t:
		swarm_t += 40.0
		for k in 22:
			var a := TAU * k / 22.0
			spawn_foe(Content.E.RUNNER, pp + Vector2(cos(a), sin(a)) * (view_r + 40.0))
	if (mode == "campaign" or mode == "atlas") and not boss_spawned and champions_met < 2 and t >= Content.STAGE_TIME * (champions_met + 1) / 3.0:
		_spawn_champion()
	if (mode == "campaign" or mode == "atlas") and not boss_spawned and t >= Content.STAGE_TIME:
		bosses.spawn_stage_boss(has_mod("twinned"))

## Rift Champions: a mid-boss at each third of an act. A giant twin-affix elite with an escort; it
## pays out a burst of experience, pulls every crystal in, and counts toward the unlock track.
var new_unlocks: Array = []        # weapon ids earned by this run (shown on the end screen)
var champions_met := 0
var champions_slain := 0
var champ_uids: Array[int] = []
const CHAMP_NAMES := ["Gorehowl the Unbroken", "Ashmaw, Hunger of the Rift", "Skarn the Many-Scarred", "Vexa Hollowcrown", "The Pale Warden", "Mordrath Rimebound"]
func _spawn_champion() -> void:
	champions_met += 1
	var kind: int = [Content.E.BRUTE, Content.E.CHARGER][champions_met % 2]
	var at := ring_point(60.0)
	var i := spawn_foe(kind, at, 1, 0, 9.0 + 5.0 * champions_met)
	if i < 0: return
	sw.affix[i] |= _roll_affix() | Content.Aff.SHIELDED
	sw.rad[i] *= 1.7
	sw.dmg[i] *= 1.3
	champ_uids.append(sw.uid[i])
	for k in 6 + 3 * champions_met:
		spawn_foe(Content.E.GRUNT if k % 3 != 0 else Content.E.RUNNER, at + Vector2(randf_range(-70, 70), randf_range(-70, 70)), 0)
	banner.emit(CHAMP_NAMES[(stage * 2 + champions_met - 1) % CHAMP_NAMES.size()], "A Rift Champion hunts you.", Color("ffb02e"))
	shake = maxf(shake, 0.5)
	Sfx.play("boss")

func _pick_type() -> int:
	var r := rng.randf()
	var t := rt()                                   # the foe mix follows the act's pace
	var a := 0.0
	var pb := 0.0 if t < 35.0 else minf(0.12, (t - 35.0) / 800.0)
	var pr := 0.0 if t < 10.0 else minf(0.28, (t - 10.0) / 320.0 + 0.05)
	var ps := 0.0 if t < 45.0 else minf(0.09, (t - 45.0) / 900.0 + 0.02)
	var psp := 0.0 if t < 30.0 else minf(0.08, (t - 30.0) / 900.0 + 0.02)
	var pc := 0.0 if t < 60.0 else minf(0.07, (t - 60.0) / 1000.0 + 0.02)
	if mode == "rift":
		pb += 0.05; ps += 0.03; pc += 0.03
	a += pb
	if r < a: return Content.E.BRUTE
	a += pr
	if r < a: return Content.E.RUNNER
	a += ps
	if r < a: return Content.E.SPITTER
	a += psp
	if r < a: return Content.E.SPLITTER
	a += pc
	if r < a: return Content.E.CHARGER
	return Content.E.GRUNT

func ring_point(extra: float = 30.0) -> Vector2:
	var p := pp
	for tries in 6:                                  # spawns land on walkable ground, not in a lake or on a cliff
		var a := rng.randf() * TAU
		p = pp + Vector2(cos(a), sin(a)) * (view_r + extra)
		if arena_r > 0.0 and p.length() > arena_r:
			p = p.normalized() * (arena_r - 30.0)
		if terrain == null or terrain.passable(p):
			return p
	return terrain.nearest_passable(p)

## Spawns a foe. elite: -1 roll, 0 never, 1 always. Returns the swarm index or -1.
func spawn_foe(k: int, at: Vector2 = Vector2.INF, elite: int = -1, extra_flags: int = 0, hp_m: float = 1.0) -> int:
	var e: Dictionary = Content.ENEMIES[k]
	var p := at if at != Vector2.INF else ring_point()
	if terrain != null and at != Vector2.INF and (extra_flags & (Swarm.F_BOSS | Swarm.F_HERALD)) == 0:
		p = terrain.nearest_passable(p)
	var el := false
	if elite == 1:
		el = true
	elif elite == -1 and k != Content.E.MINI and k != Content.E.RUNNER and rt() >= 35.0:
		var ch := 0.025 * (3.0 if has_mod("elite") else 1.0) * (1.6 if mode == "rift" else 1.0)
		el = rng.randf() < ch
	var af := 0
	if el:
		af = _roll_affix()
		if mode == "rift" or (mode == "atlas" and int(node.tier) >= 4):
			af |= _roll_affix()
	var h := float(e.hp) * hp_mult() * (5.0 if el else 1.0) * hp_m
	var s := float(e.spd) * spd_mult() * randf_range(0.92, 1.08) * (1.4 if (af & Content.Aff.HASTED) else 1.0)
	var r := float(e.r) * (1.35 if el else 1.0)
	var d := float(e.dmg) * (1.4 if el else 1.0)
	var fl := extra_flags | (Swarm.F_ELITE if el else 0)
	var i := sw.add(k, p, h, s, r, d, float(e.xp), fl, af)
	if i >= 0 and el and season == "mirrored" and (extra_flags & Swarm.F_EVENT) == 0 and not sw.full():
		sw.add(k, p + Vector2(20, 0), h, s, r, d, float(e.xp), fl, af)
	return i

func _roll_affix() -> int:
	var pool := [Content.Aff.HASTED, Content.Aff.SHIELDED]
	if rt() >= 40.0 or stage >= 1: pool.append(Content.Aff.VOLATILE)
	if rt() >= 70.0 or stage >= 2: pool.append(Content.Aff.VAMPIRIC)
	if rt() >= 90.0 or stage >= 2: pool.append(Content.Aff.ARCANE)
	return pool[rng.randi_range(0, pool.size() - 1)]

# ================================================================= foes
var _shots_req: Array = []
var _sep_parity := 0
func _step_foes(dt: float) -> void:
	sw.tick_timers(dt)
	if crowd != null and crowd.ready:
		crowd.collect(sw)          # last frame's GPU separation result
		crowd.dispatch(sw)         # kick off this frame's
	else:
		_sep_parity = 1 - _sep_parity
		sw.cpu_separation(grid, _sep_parity, pp, view_r + 40.0)
	_shots_req.clear()
	var target := pp
	sw.step_move(dt, target, _shots_req, 1.0, terrain)
	for q in range(0, _shots_req.size(), 3):
		var sp: Proj = _new_proj()
		sp.pos = _shots_req[q]; sp.vel = _shots_req[q + 1] * 170.0; sp.life = 4.0; sp.r = 5.0
		sp.dmg = _shots_req[q + 2]; sp.col = Color("e9f7a0")
		eshots.append(sp)
	# recycle stragglers onto the spawn ring; arcane elites fire slow orbs
	var far := view_r + 280.0
	for i in sw.n:
		var f := sw.flags[i]
		if (f & (Swarm.F_BOSS | Swarm.F_EVENT | Swarm.F_EXILE | Swarm.F_GOBLIN | Swarm.F_HERALD | Swarm.F_RIFTG)) == 0 and sw.pos[i].distance_squared_to(pp) > far * far:
			sw.set_pos(i, ring_point(40.0))
		if (sw.affix[i] & Content.Aff.ARCANE) != 0 and sw.ai_s[i] == 0 and fmod(t + float(sw.uid[i]) * 0.37, 3.5) < dt:
			var o: Proj = _new_proj()
			o.pos = sw.pos[i]; o.vel = (pp - sw.pos[i]).normalized() * 90.0; o.life = 6.0; o.r = 9.0; o.dmg = sw.dmg[i] * 1.2; o.col = Color("d070ff")
			eshots.append(o)

func _contact() -> void:
	if invulnerable() and roll_t <= 0.0:
		return
	var c := grid.query(pp, 30.0, sw)
	var res := grid.results
	for q in c:
		var i := res[q]
		if (sw.flags[i] & Swarm.F_ALLY) != 0 or sw.freeze_t[i] > 0.0 or sw.dmg[i] <= 0.0:
			continue
		if pp.distance_to(sw.pos[i]) < sw.rad[i] + 11.0:
			if t - sw.atk_t[i] > 0.9: sw.atk_t[i] = t          # animation feed: it swings
			var d := sw.dmg[i] * (0.8 if sw.pois[i] > 0.0 else 1.0)
			if hurt_player(d, _src_name(i)) and (sw.affix[i] & Content.Aff.VAMPIRIC) != 0:
				sw.heal(i, sw.mhp[i] * 0.12)
			return

func _src_name(i: int) -> String:
	if (sw.flags[i] & Swarm.F_EXILE) != 0:
		return bosses.exile_name
	return Content.ENEMIES[sw.kind[i]].name

# ================================================================= weapons
func weapon_damage_base() -> float:
	return 10.0 * stats.value("damage", 1.0) * (1.0 + 0.03 * lvl)

var weapon_pool: Array = Content.WEAPON_IDS      # what level-ups may offer this run (the unlock track)

func _wstat(id: String) -> Dictionary:
	var w: Dictionary = weapons[id]
	var def: Dictionary = Content.WEAPONS[id]
	return def.evo_s if w.evo else def.lv[int(w.lv) - 1]

## Element bitmask a weapon applies, from its native element, infusions and perks.
func elmask(id: String) -> int:
	if _elmask_ver != stats.version:
		_elmask_cache.clear()
		_elmask_ver = stats.version
	if _elmask_cache.has(id):
		return _elmask_cache[id]
	var loc: Stats = wlocal[id]
	var m := 0
	if not stats.flag("no_status", loc):
		m = 1 << int(Content.WEAPONS[id].elem)
		if fused(id) != "": m |= 1 << int(Content.WEAPONS[fused(id)].elem)     # fusion: the partner's element too
		if stats.flag("apply_fire", loc): m |= 1 << Content.El.FIRE
		if stats.flag("apply_cold", loc): m |= 1 << Content.El.COLD
		if stats.flag("apply_light", loc): m |= 1 << Content.El.LIGHT
		if stats.flag("apply_chaos", loc): m |= 1 << Content.El.CHAOS
		if stats.flag("apply_phys", loc): m |= 1 << Content.El.PHYS
	_elmask_cache[id] = m
	return m

## The weapon this one is fused with, or "".
func fused(id: String) -> String:
	return String(weapons[id].get("fuse", "")) if weapons.has(id) else ""

func _fused_pair(a: String, b: String) -> bool:
	return fused(a) == b

## A ring of frost bolts from a point (Glacial Nova, Hailstorm, Frost Halo).
func _bolt_ring(at: Vector2, n: int, dmg: float, a0: float = 0.0, spd: float = 420.0) -> void:
	var em := elmask("bolt")
	for k in n:
		var a := a0 + TAU * k / n
		var p: Proj = _new_proj()
		p.pos = at; p.vel = Vector2(cos(a), sin(a)) * spd; p.life = 0.8; p.r = 6.0
		p.dmg = dmg; p.pierce = 1; p.chain = 0; p.el = em; p.wid = "bolt"; p.col = Color("c8f6ff")
		projs.append(p)

var _nova_t := -9.0
var _halo_t := 0.0
var _tempest_t := 0.0

func _dmg_scale(id: String) -> float:
	var s := stats.value("damage", 1.0, wlocal[id])
	if keystones.has("pain") and hp < max_hp * 0.5: s *= 1.5
	if keystones.has("momentum"): s *= 1.0 + 0.04 * momentum
	return s

func _cd(id: String, base: float) -> float:
	return maxf(0.08, base * stats.value("cooldown", 1.0, wlocal[id]))

func _step_weapons(dt: float) -> void:
	for id in weapons:
		var w: Dictionary = weapons[id]
		var s: Dictionary = _wstat(id)
		if id == "orbit":
			_orbit(dt, s)
			continue
		w.t += dt
		if w.t >= _cd(id, float(s.cd)):
			if _fire(id, s, 1.0):
				w.t = 0.0
				var echoes := int(stats.value("echo", 0.0, wlocal[id]))
				for e in echoes:
					delayed.append([t + 0.25 * (e + 1), id, s])

func _step_delayed() -> void:
	var i := delayed.size() - 1
	while i >= 0:
		if t >= float(delayed[i][0]):
			_fire(delayed[i][1], delayed[i][2], 0.7)
			delayed.remove_at(i)
		i -= 1

func _fire(id: String, s: Dictionary, mul: float) -> bool:
	match id:
		"bolt": return _bolt(s, mul)
		"nova": return _nova(s, mul)
		"storm": return _storm(s, mul)
		"lance": return _lance(s, mul)
		"mine": return _mine(s, mul)
		"glaive": return _glaive(s, mul)
		"wisp": return _wisp(s, mul)
		"arc": return _arc(s, mul)
		"aura": return _aura_tick(s, mul)
		"cleave": return _cleave(s, mul)
		"meteor": return _meteor(s, mul)
		"totem": return _totem(s, mul)
	return false

# ----------------------------------------------------------------- the alpha weapons
func _shot(id: String, at: Vector2, vel: Vector2, dmg: float, r: float, life: float, pierce: int, col: Color, kind: int = 0) -> Proj:
	var p: Proj = _new_proj()
	p.pos = at; p.vel = vel; p.life = life; p.r = r; p.dmg = dmg; p.pierce = pierce
	p.chain = int(stats.value("chain", 0.0, wlocal[id])) if kind == 0 else 0
	p.el = elmask(id); p.wid = id; p.col = col; p.kind = kind
	projs.append(p)
	return p

## Storm Lance: a heavy bolt that goes through everything in a line.
func _lance(s: Dictionary, mul: float) -> bool:
	var tg := _target(520.0)
	if tg < 0: return false
	var n := int(s.n) + int(stats.value("proj_count", 0.0, wlocal["lance"]))
	var base := (sw.pos[tg] - pp).angle()
	_cast(sw.pos[tg] - pp)
	for k in n:
		var a := base + (k - (n - 1) * 0.5) * 0.2
		_shot("lance", pp, Vector2(cos(a), sin(a)) * 640.0, float(s.dmg) * _dmg_scale("lance") * mul, 11.0, 0.95, 99, Color("fff0a0"))
	Sfx.play("shoot", 0.7)
	Sfx.play("thunder", 1.6, 0.35)
	return true

## Ember Mines: dropped where you stand; a foe stepping near sets one off.
func _mine(s: Dictionary, mul: float) -> bool:
	if grid.nearest(pp, 520.0, sw) < 0: return false
	var live := 0
	for p in projs:
		if p.kind == 1: live += 1
	var n := int(s.n) + int(stats.value("proj_count", 0.0, wlocal["mine"]))
	for k in n:
		if live >= 18: break
		var off := Vector2.ZERO if k == 0 else Vector2(cos(TAU * k / n + t), sin(TAU * k / n + t)) * 46.0
		var m := _shot("mine", pp + off, Vector2.ZERO, float(s.dmg) * _dmg_scale("mine") * mul, 6.0, 10.0, 0, Color("ff9a4a"), 1)
		m.aux = float(s.rad) * stats.value("area", 1.0, wlocal["mine"])
		live += 1
	Sfx.play("pickup", 0.6, 0.5)
	return true

## Frost Glaive: flies out, turns, and comes home, cutting on both passes.
func _glaive(s: Dictionary, mul: float) -> bool:
	var tg := _target(420.0)
	if tg < 0: return false
	var n := int(s.n) + int(stats.value("proj_count", 0.0, wlocal["glaive"]))
	var base := (sw.pos[tg] - pp).angle()
	_cast(sw.pos[tg] - pp)
	for k in n:
		var a := base + (k - (n - 1) * 0.5) * 0.5
		_shot("glaive", pp, Vector2(cos(a), sin(a)) * 520.0, float(s.dmg) * _dmg_scale("glaive") * mul, 13.0 if weapons.glaive.evo else 10.0, 2.4, 99, Color("bfefff"), 2)
	Sfx.play("roll", 1.3, 0.7)
	return true

## Grave Wisps: slow seekers that find their own targets.
func _wisp(s: Dictionary, mul: float) -> bool:
	if grid.nearest(pp, 480.0, sw) < 0: return false
	var n := int(s.n) + int(stats.value("proj_count", 0.0, wlocal["wisp"]))
	var a0 := rng.randf() * TAU
	for k in n:
		var a := a0 + TAU * k / n
		_shot("wisp", pp, Vector2(cos(a), sin(a)) * 230.0, float(s.dmg) * _dmg_scale("wisp") * mul, 5.0, 2.6, int(s.pierce) + int(stats.value("pierce", 0.0, wlocal["wisp"])), Color("a8ff8c"), 3)
	Sfx.play("shoot", 1.5, 0.5)
	return true

## Chain Arc: lightning that leaps from foe to foe, weakening a little each jump.
func _arc(s: Dictionary, mul: float) -> bool:
	var i := _target(380.0)
	if i < 0: return false
	_cast(sw.pos[i] - pp)
	var dmg := float(s.dmg) * _dmg_scale("arc") * mul
	var em := elmask("arc")
	var seen: Array[int] = []
	var pts := PackedVector2Array([pp])
	var jumps := int(s.n) + int(stats.value("chain", 0.0, wlocal["arc"]))
	var at := sw.pos[i]
	for j in jumps:
		var u := sw.uid[i]
		seen.append(u)
		at = sw.pos[i]
		pts.append(at + Vector2(randf_range(-6, 6), randf_range(-6, 6)))
		hit(i, dmg, em, Vector2.ZERO, 0.0, 0)
		dmg *= 0.9
		var c := grid.query(at, 170.0, sw)
		var best := -1
		var bd := INF
		for q in c:
			var k := grid.results[q]
			if k >= sw.n or sw.hp[k] <= 0.0 or (sw.flags[k] & Swarm.F_ALLY) != 0 or seen.has(sw.uid[k]): continue
			var d := sw.pos[k].distance_squared_to(at)
			if d < bd:
				bd = d; best = k
		if best < 0: break
		i = best
	fx.append({"k": "arc", "pos": pp, "col": Color("e2d4ff"), "life": 0.16, "t": 0.0, "pts": pts})
	Sfx.play("thunder", 1.8, 0.4)
	return true

## Withering Aura: everything close to you takes damage on every tick.
func _aura_tick(s: Dictionary, mul: float) -> bool:
	var r := float(s.rad) * stats.value("area", 1.0, wlocal["aura"])
	aura_r = r
	var c := grid.query(pp, r, sw)
	if c == 0: return true
	var hl := grid.results.slice(0, c)
	var dmg := float(s.dmg) * _dmg_scale("aura") * mul
	var em := elmask("aura")
	var slow: bool = weapons.aura.evo
	for q in hl.size():
		var i := hl[q]
		if i >= sw.n or (sw.flags[i] & Swarm.F_ALLY) != 0: continue
		if slow: sw.chill_t[i] = maxf(sw.chill_t[i], 0.6)
		hit(i, dmg, em, Vector2.ZERO, 0.0, 0)
	if t - _aura_fx_t > 0.8:
		_aura_fx_t = t
		fx.append({"k": "ring", "pos": pp, "r": r * 0.5, "max": r, "col": Color("b86bff"), "life": 0.5, "t": 0.0})
	return true
var aura_r := 0.0
var _aura_fx_t := -9.0

## Reaper's Cleave: a wide sweep toward the nearest foe, with a hard shove.
func _cleave(s: Dictionary, mul: float) -> bool:
	var r := float(s.rad) * stats.value("area", 1.0, wlocal["cleave"])
	var tg := grid.nearest(pp, r + 30.0, sw)
	if tg < 0: return false
	var dir := (sw.pos[tg] - pp).normalized()
	_cast(dir)
	var half := 1.25 if weapons.cleave.evo else 0.95
	var c := grid.query(pp, r, sw)
	var hl := grid.results.slice(0, c)
	var dmg := float(s.dmg) * _dmg_scale("cleave") * mul
	var em := elmask("cleave")
	for q in hl.size():
		var i := hl[q]
		if i >= sw.n or (sw.flags[i] & Swarm.F_ALLY) != 0: continue
		var dv := sw.pos[i] - pp
		if dv.length() > 1.0 and absf(dir.angle_to(dv)) > half: continue
		hit(i, dmg, em, dv.normalized(), 420.0 if weapons.cleave.evo else 240.0, 0)
	var pts := PackedVector2Array()
	for k in 9:
		var a := dir.angle() + lerpf(-half, half, k / 8.0)
		pts.append(pp + Vector2(cos(a), sin(a)) * r)
	fx.append({"k": "arc", "pos": pp, "col": Color("ff8a96"), "life": 0.16, "t": 0.0, "pts": pts})
	shatter(pp + dir * r * 0.6, r * 0.5)
	Sfx.play("impact", 0.7, 0.9)
	return true

## Meteor: marks a foe's position, lands a moment later.
var meteors: Array = []            # [land time, pos, radius, damage, element mask]
func _meteor(s: Dictionary, mul: float) -> bool:
	var cands := grid.query(pp, view_r * 0.8, sw)
	if cands == 0: return false
	var picks_i := grid.results.slice(0, cands)
	var r := float(s.rad) * stats.value("area", 1.0, wlocal["meteor"])
	_cast(sw.pos[picks_i[0]] - pp if picks_i[0] < sw.n else face)
	for k in int(s.n):
		var i := picks_i[rng.randi_range(0, cands - 1)]
		if i >= sw.n: continue
		var at := sw.pos[i]
		meteors.append([t + 0.85, at, r, float(s.dmg) * _dmg_scale("meteor") * mul, elmask("meteor")])
		fx.append({"k": "ring", "pos": at, "r": r, "max": r * 0.2, "col": Color("ff8a3c"), "life": 0.85, "t": 0.0})
	return true

func _step_meteors() -> void:
	var k := meteors.size() - 1
	while k >= 0:
		var m: Array = meteors[k]
		if t >= float(m[0]):
			nova_at(m[1], float(m[2]), float(m[3]), int(m[4]), Color("ffb060"), 320.0)
			_burst(m[1], Color("ff9a4a"), 16, 260.0)
			shake = minf(1.0, shake + 0.12)
			Sfx.play_at("explode", m[1])
			meteors.remove_at(k)
		k -= 1

## Rime Totem: stays where it was planted and shoots what comes near.
func _totem(s: Dictionary, mul: float) -> bool:
	if grid.nearest(pp, 520.0, sw) < 0: return false
	var cap := int(s.n)
	var live: Array = []
	for p in projs:
		if p.kind == 4: live.append(p)
	while live.size() >= cap:
		var oldest: Proj = live[0]
		for p in live:
			if p.life < oldest.life: oldest = p
		oldest.dead = true
		live.erase(oldest)
	var tot := _shot("totem", pp + face * 26.0, Vector2.ZERO, float(s.dmg) * _dmg_scale("totem") * mul, 9.0, float(s.dur), 0, Color("9fe8ff"), 4)
	tot.aux = float(s.rate)
	fx.append({"k": "ring", "pos": tot.pos, "r": 0.0, "max": 60.0, "col": Color("9fe8ff"), "life": 0.3, "t": 0.0})
	Sfx.play("ice", 0.8, 0.7)
	return true

func _target(max_d: float) -> int:
	match aim_mode:
		1:  # strongest: highest current life in range
			var c := grid.query(pp, max_d, sw)
			var res := grid.results
			var best := -1
			var bh := -1.0
			for q in c:
				var i := res[q]
				if (sw.flags[i] & Swarm.F_ALLY) == 0 and sw.hp[i] > bh:
					bh = sw.hp[i]
					best = i
			return best
		2:  # facing: nearest inside a 70-degree cone ahead, else nearest
			var c2 := grid.query(pp, max_d, sw)
			var res2 := grid.results
			var best2 := -1
			var bd := INF
			for q in c2:
				var i := res2[q]
				if (sw.flags[i] & Swarm.F_ALLY) != 0: continue
				var dv := sw.pos[i] - pp
				if dv.normalized().dot(face) > 0.57 and dv.length_squared() < bd:
					bd = dv.length_squared()
					best2 = i
			if best2 >= 0: return best2
	return grid.nearest(pp, max_d, sw)

func _cast(d: Vector2) -> void:
	if t - cast_t > 0.12:
		cast_t = t
		cast_dir = d.normalized() if d.length() > 0.01 else face

func _bolt(s: Dictionary, mul: float) -> bool:
	var tg := _target(460.0)
	if tg < 0:
		return false
	var loc: Stats = wlocal["bolt"]
	var n := int(s.n) + int(stats.value("proj_count", 0.0, loc))
	var base := (sw.pos[tg] - pp).angle()
	var dmg := float(s.dmg) * _dmg_scale("bolt") * mul
	_cast(sw.pos[tg] - pp)
	var em := elmask("bolt")
	var ch := int(stats.value("chain", 0.0, loc))
	var pc := int(s.pierce) + int(stats.value("pierce", 0.0, loc))
	for k in n:
		var a := base + (k - (n - 1) * 0.5) * 0.13
		var p: Proj = _new_proj()
		p.pos = pp; p.vel = Vector2(cos(a), sin(a)) * 440.0; p.life = 1.15; p.r = 7.0 if weapons.bolt.evo else 5.0
		p.dmg = dmg; p.pierce = pc; p.chain = ch; p.el = em; p.wid = "bolt"; p.col = Color("aef4ff")
		projs.append(p)
	Sfx.play("shoot")
	Sfx.play("ice", 1.0, 0.5)
	return true

func _nova(s: Dictionary, mul: float) -> bool:
	var r := float(s.rad) * stats.value("area", 1.0, wlocal["nova"])
	if grid.nearest(pp, r + 40.0, sw) < 0:
		return false
	_cast(face)
	nova_at(pp, r, float(s.dmg) * _dmg_scale("nova") * mul, elmask("nova"), Color("ff7b50"), 520.0 if weapons.nova.evo else 260.0)
	_nova_t = t
	if _fused_pair("nova", "bolt"):                                  # Glacial Nova
		_bolt_ring(pp, 8, float(s.dmg) * 0.45 * _dmg_scale("bolt") * mul, rng.randf() * TAU)
	Sfx.play("nova")
	Sfx.play("fire", 1.0, 0.7)
	return true

## Area hit used by the nova weapon, ultimates and legendary powers.
func nova_at(at: Vector2, r: float, dmg: float, em: int, col: Color, kb: float = 200.0) -> void:
	shatter(at, r)
	var c := grid.query(at, r, sw)
	var hit_list := grid.results.slice(0, c)
	for q in hit_list.size():
		var i := hit_list[q]
		if i >= sw.n or (sw.flags[i] & Swarm.F_ALLY) != 0: continue
		hit(i, dmg, em, (sw.pos[i] - at).normalized(), kb, 0)
	fx.append({"k": "ring", "pos": at, "r": 0.0, "max": r, "col": col, "life": 0.3, "t": 0.0})

func _storm(s: Dictionary, mul: float) -> bool:
	if sw.n == 0:
		return false
	var cands := grid.query(pp, view_r * 0.85, sw)
	if cands == 0:
		return false
	var picks_i := grid.results.slice(0, cands)
	var r := float(s.rad) * stats.value("area", 1.0, wlocal["storm"])
	var dmg := float(s.dmg) * _dmg_scale("storm") * mul
	var em := elmask("storm")
	_cast(sw.pos[picks_i[0]] - pp if picks_i[0] < sw.n else face)
	for k in int(s.n):
		var i := picks_i[rng.randi_range(0, cands - 1)]
		if i >= sw.n: continue
		strike_at(sw.pos[i], r, dmg, em)
		if _fused_pair("storm", "bolt"):                             # Hailstorm
			_bolt_ring(sw.pos[i] if i < sw.n else pp, 4, dmg * 0.3, rng.randf() * TAU, 360.0)
		elif _fused_pair("storm", "nova") and i < sw.n:              # Thunderclap
			nova_at(sw.pos[i], 75.0, dmg * 0.5, elmask("nova"), Color("ff9ae0"), 160.0)
	Sfx.play("thunder")
	shake = minf(1.0, shake + 0.05)
	return true

func strike_at(at: Vector2, r: float, dmg: float, em: int) -> void:
	shatter(at, r)
	var c := grid.query(at, r, sw)
	var hl := grid.results.slice(0, c)
	for q in hl.size():
		var j := hl[q]
		if j < sw.n and (sw.flags[j] & Swarm.F_ALLY) == 0:
			hit(j, dmg, em, Vector2.ZERO, 0.0, 0)
	var pts := PackedVector2Array()
	var y := at.y - 380.0
	while y < at.y:
		pts.append(Vector2(at.x + randf_range(-14, 14), y))
		y += 40.0
	pts.append(at)
	fx.append({"k": "zap", "pos": at, "r": r, "col": Color("d9c8ff"), "life": 0.25, "t": 0.0, "pts": pts})

func _orbit(dt: float, s: Dictionary) -> void:
	var w: Dictionary = weapons.orbit
	var cyc := buffs.has("cyclone")
	var rad := float(s.rad) * stats.value("area", 1.0, wlocal["orbit"]) * (2.0 if cyc else 1.0)
	if _fused_pair("orbit", "nova"):                                  # Solar Wheel: each pulse flings the blades wide
		rad *= 1.0 + 0.7 * clampf(1.0 - (t - _nova_t) / 0.6, 0.0, 1.0)
	var spd := float(s.spd) / maxf(0.2, stats.value("cooldown", 1.0, wlocal["orbit"]))
	w.t += spd * dt
	var n := int(s.n) + int(stats.value("proj_count", 0.0, wlocal["orbit"]))
	blades.resize(n)
	for k in n:
		var a: float = w.t + TAU * k / n
		blades[k] = pp + Vector2(cos(a), sin(a)) * rad
	var dmg := float(s.dmg) * _dmg_scale("orbit") * (3.0 if cyc else 1.0)
	var em := elmask("orbit")
	if _fused_pair("orbit", "bolt"):                                  # Frost Halo
		_halo_t += dt
		if _halo_t >= 0.55:
			_halo_t = 0.0
			for b in mini(n, 4):
				var bp: Vector2 = blades[(b * n) / mini(n, 4)]
				_bolt_ring(bp, 1, dmg * 0.6, (bp - pp).angle(), 380.0)
	if not breakables.is_empty():
		for b in n: shatter(blades[b], 12.0)
	var c := grid.query(pp, rad + 30.0, sw)
	var hl := grid.results.slice(0, c)
	for q in hl.size():
		var i := hl[q]
		if i >= sw.n or (sw.flags[i] & Swarm.F_ALLY) != 0 or t - sw.hit_t[i] < 0.25:
			continue
		var p := sw.pos[i]
		var rr := sw.rad[i] + 14.0
		for b in n:
			if p.distance_squared_to(blades[b]) < rr * rr:
				sw.set_hit_t(i, t)
				hit(i, dmg, em, (p - pp).normalized(), 120.0, 0)
				if _fused_pair("orbit", "storm") and t - _tempest_t > 0.4 and i < sw.n:   # Tempest Blades
					_tempest_t = t
					strike_at(sw.pos[i], 42.0, dmg * 1.6, elmask("storm"))
				Sfx.play("impact", 1.0, 0.55)
				break

func _conduit(dt: float) -> void:
	if fmod(t, 0.25) < dt:
		var c := grid.query(pp, 220.0, sw)
		var hl := grid.results.slice(0, mini(c, 3))
		for q in hl.size():
			var i := hl[q]
			if i < sw.n:
				var pts := PackedVector2Array([pp, (pp + sw.pos[i]) * 0.5 + Vector2(randf_range(-12, 12), randf_range(-12, 12)), sw.pos[i]])
				fx.append({"k": "arc", "pos": pp, "col": Color("fff07a"), "life": 0.12, "t": 0.0, "pts": pts})
				hit(i, weapon_damage_base() * 2.0, 1 << Content.El.LIGHT, Vector2.ZERO, 0.0, 0)
	if buffs.has("thunderdome") and fmod(t, 0.1) < dt:
		var j := grid.nearest(pp + Vector2(randf_range(-260, 260), randf_range(-200, 200)), 200.0, sw)
		if j >= 0: strike_at(sw.pos[j], 48.0, weapon_damage_base() * 2.5, 1 << Content.El.LIGHT)

# ================================================================= damage pipeline
## Every hit on a foe goes through here. depth > 0 marks reaction damage (cascade level).
func hit(i: int, dmg: float, em: int, kdir: Vector2, kb: float, depth: int) -> void:
	if i < 0 or i >= sw.n or sw.hp[i] <= 0.0:
		return
	var f := sw.flags[i]
	var crit := false
	if depth == 0:
		var cc := stats.value("crit_chance", 0.05)
		if rng.randf() < cc:
			crit = true
			dmg *= stats.value("crit_mult", 1.8)
			Sfx.play("crit")
			if t - _crit_stop > 0.6:                  # PoE2-style weight: a 25 ms freeze on crits, at most ~4% of the time
				_crit_stop = t
				hitstop = maxf(hitstop, 0.025)
				shake = minf(1.0, shake + 0.06)
		if sw.freeze_t[i] > 0.0 and has_leg("rimeheart"):
			dmg *= 1.2
		if terrain.height(pp) - terrain.height(sw.pos[i]) > HIGH_GROUND:
			dmg *= 1.15                               # striking down from a ridge or ledge
			metrics.high_ground += 1
	if sw.shock_t[i] > 0.0: dmg *= 1.15
	if sw.cond_t[i] > 0.0: dmg *= 1.3
	if keystones.has("equilibrium") and sw.ee_t[i] > 0.0 and em != 0 and (em & (1 << sw.ee_el[i])) == 0:
		dmg *= 1.4
	if (f & (Swarm.F_ELITE | Swarm.F_BOSS | Swarm.F_EXILE | Swarm.F_HERALD | Swarm.F_RIFTG)) != 0 and has_leg("furnace"):
		dmg *= 1.5
	var bt := _bestiary_bonus(sw.kind[i])
	if bt > 0.0: dmg *= 1.0 + bt
	var absorbed := sw.take(i, dmg)
	metrics.dmg_dealt += dmg
	if kb > 0.0 and (f & (Swarm.F_BOSS | Swarm.F_HERALD | Swarm.F_RIFTG)) == 0:
		sw.push(i, kdir * kb)
	_text(sw.pos[i], dmg - absorbed, Color("7fd8ff") if absorbed > 0.0 else Color.WHITE, 1 if crit else (2 if depth > 0 else 0), sw.uid[i])
	charge_ult(dmg * 0.012)
	var leech := stats.value("leech", 0.0)
	if leech > 0.0: hp = minf(max_hp, hp + dmg * leech)
	if depth == 0:
		hit_count += 1
		if has_leg("stormherald") and hit_count % 12 == 0:
			_chain_arc(i, 5, weapon_damage_base() * 2.0)
		if keystones.has("avatar"):
			em |= 1 << rng.randi_range(0, 4)
		if has_leg("rimeheart") and sw.chill_t[i] > 0.0 and rng.randf() < 0.12:
			sw.set_freeze(i, 1.5)
	if em != 0 and sw.hp[i] > 0.0:
		apply_elements(i, em, depth)

const HIGH_GROUND := 24.0

func _bestiary_bonus(k: int) -> float:
	var id: String = Content.ENEMIES[k].id
	return 0.03 * Save.bestiary_tier(id)

## Applies statuses for each element in `em`; when a foe already carries the partner status of
## a reaction, the reaction is queued (resolved after all hits this frame, within a budget).
func apply_elements(i: int, em: int, depth: int) -> void:
	if depth == 0 and terrain.liquid != "none":
		_terrain_react(i, em)
	if depth == 0 and not terrain.surf.is_empty():
		_surface_react(i, em)
	var cap := Content.REACT_DEPTH + int(stats.value("react_depth", 0.0))
	for el in 5:
		if (em & (1 << el)) == 0:
			continue
		if sw.react_cd[i] <= 0.0 and depth < cap:
			for ri in Content.REACTIONS.size():
				var R: Dictionary = Content.REACTIONS[ri]
				var other := -1
				if R.a == el: other = R.b
				elif R.b == el: other = R.a
				if other >= 0 and sw.has_status(i, other):
					react_q.append([sw.uid[i], ri, depth, false])
					sw.set_react_cd(i, 0.45)
					sw.consume_status(i, other, 0.5)
					break
		sw.apply_status(i, el, 1.0, 3.0)
		if keystones.has("equilibrium"):
			sw.set_ee(i, el, 3.0)

## The ground reacts to elements (elevation pass):
##   cold on a foe in water or lava freezes it into a walkable ice sheet or obsidian crust for 6 s
##   lightning on a foe in water electrifies the pool: the charge leaps to every foe wading in it
##   fire on a foe in water or on ice raises steam and melts the ice
var _shock_water_t := -9.0
func _terrain_react(i: int, em: int) -> void:
	var fp := sw.pos[i]
	if not terrain.is_liquid(fp):
		return
	if (em & (1 << Content.El.COLD)) != 0:
		if terrain.freeze(fp, 60.0, 6.0 * stats.value("ice_dur", 1.0)) > 0:
			metrics.terrain.freeze += 1
			fx.append({"k": "ring", "pos": fp, "r": 0.0, "max": 70.0, "col": Color("c8f4ff"), "life": 0.35, "t": 0.0})
	if (em & (1 << Content.El.LIGHT)) != 0 and terrain.liquid == "water" and not terrain.is_frozen(fp) and t - _shock_water_t > 0.3:
		_shock_water_t = t
		_water_chain(i)
	if (em & (1 << Content.El.FIRE)) != 0 and terrain.liquid == "water":
		terrain.scald(fp, 44.0)
		metrics.terrain.steam += 1
		_burst(fp, Color(0.85, 0.88, 0.9, 0.6), 10, 70.0)

# ================================================================= surfaces (oil, poison, blood)
## Elements meeting a pool under the struck foe:
##   fire + oil      -> the pool ignites (and the fire runs along connected oil)
##   fire + poison   -> the pool detonates in a toxic blast and is spent
##   cold + poison   -> crystal spikes that cut and slow whatever stands in them
##   lightning+blood -> the charge arcs through every foe standing in blood nearby
var _surf_react_t := -9.0
var _blood_t := -9.0
func _surface_react(i: int, em: int) -> void:
	var fp := sw.pos[i]
	var s := terrain.surf_at(fp)
	if s == Terrain.Surf.NONE: return
	if s == Terrain.Surf.OIL and (em & (1 << Content.El.FIRE)) != 0:
		if terrain.convert(fp, 48.0, Terrain.Surf.OIL, Terrain.Surf.FIRE, 4.0) > 0:
			metrics.terrain.ignite = int(metrics.terrain.get("ignite", 0)) + 1
			Diag.first("surface: oil ignites")
			fx.append({"k": "ring", "pos": fp, "r": 0.0, "max": 80.0, "col": Color("ff9a3c"), "life": 0.35, "t": 0.0})
			Sfx.play_at("fire", fp)
	elif s == Terrain.Surf.POISON and (em & (1 << Content.El.FIRE)) != 0 and t - _surf_react_t > 0.15:
		_surf_react_t = t
		terrain.clear_surf(fp, 40.0, Terrain.Surf.POISON)
		nova_at(fp, 110.0, weapon_damage_base() * 3.0, (1 << Content.El.CHAOS) | (1 << Content.El.FIRE), Color("8aff4a"), 220.0)
		_burst(fp, Color("8aff4a"), 18, 220.0)
		shake = minf(1.0, shake + 0.25)
		Sfx.play_at("explode", fp)
		metrics.terrain.blast = int(metrics.terrain.get("blast", 0)) + 1
		Diag.first("surface: poison blast")
	elif s == Terrain.Surf.POISON and (em & (1 << Content.El.COLD)) != 0:
		if terrain.convert(fp, 48.0, Terrain.Surf.POISON, Terrain.Surf.SPIKES, 6.0) > 0:
			metrics.terrain.spikes = int(metrics.terrain.get("spikes", 0)) + 1
			Diag.first("surface: poison spikes")
			fx.append({"k": "ring", "pos": fp, "r": 0.0, "max": 60.0, "col": Color("d8ffb0"), "life": 0.3, "t": 0.0})
			Sfx.play_at("ice", fp)
	elif s == Terrain.Surf.BLOOD and (em & (1 << Content.El.LIGHT)) != 0 and t - _blood_t > 0.3:
		_blood_t = t
		_blood_chain(i)

func _blood_chain(i: int) -> void:
	var fp := sw.pos[i]
	var c := grid.query(fp, 280.0, sw)
	var near := []
	for q in c: near.append(grid.results[q])
	var pts := PackedVector2Array([fp])
	var hits := 0
	for j in near:
		if j == i or j >= sw.n or sw.hp[j] <= 0.0: continue
		if terrain.surf_at(sw.pos[j]) != Terrain.Surf.BLOOD: continue
		hit(j, weapon_damage_base() * 1.1, 1 << Content.El.LIGHT, Vector2.ZERO, 0.0, 1)
		sw.apply_status(j, Content.El.LIGHT, 1.0, 2.0)
		pts.append(sw.pos[j])
		hits += 1
		if hits >= 12: break
	if hits > 0:
		fx.append({"k": "arc", "pos": fp, "col": Color("ff6b6b"), "life": 0.2, "t": 0.0, "pts": pts})
		metrics.terrain.conduct = int(metrics.terrain.get("conduct", 0)) + 1
		Diag.first("surface: blood conducts")
		Sfx.play_at("zap", fp)

## Standing in a pool, four times a second: fire burns (foes and the hero), spikes cut and chill,
## poison poisons, oil slows. Act II's tar seeps open on their own every few seconds.
var _surf_t := 0.0
var _seep_t := 6.0
func _step_surfaces(dt: float) -> void:
	if stage == 1 and mode != "pinnacle":
		_seep_t -= dt
		if _seep_t <= 0.0:
			_seep_t = rng.randf_range(7.0, 11.0)
			var a := rng.randf() * TAU
			terrain.pour(pp + Vector2(cos(a), sin(a)) * rng.randf_range(140.0, 300.0), rng.randf_range(36.0, 60.0), Terrain.Surf.OIL, 30.0)
	if terrain.surf.is_empty(): return
	_surf_t += dt
	if _surf_t < 0.25: return
	_surf_t = 0.0
	var base := weapon_damage_base()
	for i in sw.n:
		if sw.hp[i] <= 0.0 or (sw.flags[i] & Swarm.F_ALLY) != 0: continue
		match terrain.surf_at(sw.pos[i]):
			Terrain.Surf.FIRE:
				hit(i, base * 0.6, 1 << Content.El.FIRE, Vector2.ZERO, 0.0, 1)
			Terrain.Surf.SPIKES:
				hit(i, base * 0.45, 1 << Content.El.COLD, Vector2.ZERO, 0.0, 1)
				sw.apply_status(i, Content.El.COLD, 1.0, 1.0)
			Terrain.Surf.POISON:
				sw.apply_status(i, Content.El.CHAOS, 1.0, 2.0)
			Terrain.Surf.OIL:
				sw.apply_status(i, Content.El.COLD, 0.5, 0.6)       # sticky: a light chill
	match terrain.surf_at(pp):
		Terrain.Surf.FIRE: hurt_player(5.0, "burning oil")
		Terrain.Surf.POISON: hurt_player(1.5, "poison")

func _water_chain(i: int) -> void:
	var fp := sw.pos[i]
	terrain.electrify(fp, 130.0, 1.4)
	var c := grid.query(fp, 260.0, sw)
	var near := []                                    # copied: hit() can run other grid queries
	for q in c: near.append(grid.results[q])
	var hits := 0
	var pts := PackedVector2Array([fp])
	var dmg := weapon_damage_base() * 0.8
	for j in near:
		if j == i or sw.hp[j] <= 0.0: continue
		if not terrain.is_liquid(sw.pos[j]) or terrain.is_frozen(sw.pos[j]): continue
		hit(j, dmg, 1 << Content.El.LIGHT, Vector2.ZERO, 0.0, 1)
		sw.apply_status(j, Content.El.LIGHT, 1.0, 2.0)
		terrain.electrify(sw.pos[j], 40.0, 1.0)
		pts.append(sw.pos[j])
		hits += 1
		if hits >= 10: break
	if hits > 0:
		metrics.terrain.shock += 1
		for k in range(1, pts.size()):
			fx.append({"k": "arc", "pos": fp, "col": Color("bfe8ff"), "life": 0.22, "t": 0.0, "pts": PackedVector2Array([fp, pts[k]])})

func _resolve_reactions() -> void:
	var budget := Content.REACT_BUDGET
	var guard := 0
	while not react_q.is_empty() and guard < 200:
		guard += 1
		var job: Array = react_q.pop_front()
		if budget <= 0:
			metrics.react_dropped += 1
			continue
		var i := sw.index_of(job[0])
		if i < 0:
			continue
		budget -= 1
		_react(i, Content.REACTIONS[job[1]], int(job[2]), bool(job[3]))
	react_q.clear()

func _react(i: int, R: Dictionary, depth: int, echo: bool) -> void:
	metrics.reactions += 1
	metrics.react_by[R.id] = int(metrics.react_by.get(R.id, 0)) + 1
	metrics.cascade_max = maxi(metrics.cascade_max, depth + 1)
	var at := sw.pos[i]
	var scale := (1.0 + 0.05 * lvl) * stats.value("reaction_damage", 1.0) * pow(Content.REACT_FALLOFF, depth) * (0.5 if echo else 1.0)
	var col := Content.col(R.col)
	var spread_m := (1 << int(R.spread)) if int(R.spread) >= 0 else 0
	if t - float(_label_t.get(R.id, -9.0)) > 0.35:       # one label per reaction kind per 0.35 s
		_label_t[R.id] = t
		_text(at + Vector2(0, -18), 0.0, col, 3, -1, R.name)
	match R.id:
		"septic":
			var pay: float = sw.dot_dps(i) * maxf(sw.pois_t[i], sw.bleed_t[i]) * float(R.payout) * scale
			sw.consume_status(i, Content.El.CHAOS)
			sw.consume_status(i, Content.El.PHYS)
			hit(i, pay, 0, Vector2.ZERO, 0.0, depth + 1)
		"frostbite":
			sw.set_freeze(i, float(R.freeze))
			hit(i, float(R.dmg) * scale, 0, Vector2.ZERO, 0.0, depth + 1)
		"hemoarc":
			_chain_arc(i, int(R.arc), float(R.dmg) * scale + sw.bleed[i] * 6.0 * scale, spread_m, depth + 1)
		_:
			var c := grid.query(at, float(R.r), sw)
			var hl := grid.results.slice(0, c)
			for q in hl.size():
				var j := hl[q]
				if j >= sw.n or (sw.flags[j] & Swarm.F_ALLY) != 0: continue
				if R.has("debuff"): sw.set_cond(j, float(R.debuff))
				var kd := (sw.pos[j] - at).normalized()
				hit(j, float(R.dmg) * scale, spread_m, kd, float(R.get("kb", 0.0)), depth + 1)
	fx.append({"k": "ring", "pos": at, "r": 0.0, "max": maxf(40.0, float(R.r)), "col": col, "life": 0.3, "t": 0.0})
	_burst(at, col, 10, 200.0)
	if not echo and has_leg("cascade"):
		react_q.append([sw.uid[i], Content.REACTIONS.find(R), depth, true])

func _chain_arc(i: int, count: int, dmg: float, em: int = 1 << Content.El.LIGHT, depth: int = 0) -> void:
	var cur := i
	var seen := {sw.uid[i]: true}
	var pts := PackedVector2Array([sw.pos[i]])
	for k in count:
		var c := grid.query(sw.pos[cur], 170.0, sw)
		var best := -1
		var bd := INF
		for q in c:
			var j := grid.results[q]
			if seen.has(sw.uid[j]) or (sw.flags[j] & Swarm.F_ALLY) != 0: continue
			var d := sw.pos[j].distance_squared_to(sw.pos[cur])
			if d < bd:
				bd = d; best = j
		if best < 0: break
		seen[sw.uid[best]] = true
		pts.append(sw.pos[best])
		hit(best, dmg, em, Vector2.ZERO, 0.0, maxi(1, depth))
		cur = best
	if pts.size() > 1:
		fx.append({"k": "arc", "pos": pts[0], "col": Color("fff07a"), "life": 0.18, "t": 0.0, "pts": pts})

## DoT payout every 0.5s per foe.
var _dot_t := 0.0
func _step_dots(dt: float) -> void:
	_dot_t += dt
	if _dot_t < 0.5:
		return
	_dot_t -= 0.5
	var scale := (1.0 + 0.06 * lvl) * stats.value("dot_damage", 1.0) * 0.5
	for i in sw.n:
		var dps := sw.dot_dps(i)
		if dps <= 0.0:
			continue
		if sw.bleed[i] > 0.0 and sw.kb[i].length() > 60.0:
			dps += sw.bleed[i] * 1.1        # bleeding foes being thrown around bleed twice as hard
		var d := dps * scale
		sw.take(i, d)
		# tiny ticks (< 3 damage and < 2% of the foe's life) are pure noise on screen
		if d >= 3.0 or d >= sw.mhp[i] * 0.02:
			var col := Color("ff8a3c") if sw.burn[i] >= sw.pois[i] and sw.burn[i] >= sw.bleed[i] else (Color("7dff6b") if sw.pois[i] >= sw.bleed[i] else Color("ff4a5e"))
			_text(sw.pos[i], d, col, 4, sw.uid[i])
		metrics.dmg_dealt += d

# ================================================================= projectiles & hostile shots
func _new_proj() -> Proj:
	var p: Proj = _pool.pop_back() if not _pool.is_empty() else Proj.new()
	p.dead = false
	p.hits.clear()
	p.pierce = 0
	p.chain = 0
	p.el = 0
	p.wid = ""
	p.kind = 0; p.age = 0.0; p.aux = 0.0; p.tick = 0.0
	return p

func _step_projs(dt: float) -> void:
	var k := 0
	while k < projs.size():
		var p: Proj = projs[k]
		p.pos += p.vel * dt
		p.life -= dt
		if p.kind != 0 and not p.dead:
			p.age += dt
			if _step_special(p, dt):
				if p.dead:
					_pool.append(p)
					projs[k] = projs[projs.size() - 1]
					projs.pop_back()
				else:
					k += 1
				continue
		if not breakables.is_empty() and shatter(p.pos, p.r):
			p.dead = p.pierce <= 0
		if p.life <= 0.0:
			p.dead = true
		else:
			var c := grid.query(p.pos, p.r, sw)
			var hl := grid.results.slice(0, c) if c > 0 else PackedInt32Array()
			for q in hl.size():
				var i := hl[q]
				if (sw.flags[i] & Swarm.F_ALLY) != 0 or p.hits.has(sw.uid[i]):
					continue
				p.hits.append(sw.uid[i])
				hit(i, p.dmg, p.el, p.vel.normalized(), 140.0, 0)
				_burst(p.pos, Color("bff1ff"), 2, 90.0)
				if p.chain > 0:
					p.chain -= 1
					var nx := _chain_target(p, i)
					if nx >= 0:
						p.vel = (sw.pos[nx] - p.pos).normalized() * p.vel.length()
						p.life = maxf(p.life, 0.6)
						break
				if p.pierce <= 0:
					p.dead = true
					break
				p.pierce -= 1
		if p.dead:
			_pool.append(p)
			projs[k] = projs[projs.size() - 1]
			projs.pop_back()
		else:
			k += 1

## Mines, glaives, wisps and totems. Returns true when the shot handled its own collisions this frame.
func _step_special(p: Proj, dt: float) -> bool:
	match p.kind:
		1:  # mine: arms after a moment, bursts when a foe is close or its time runs out near foes
			if p.life <= 0.0: p.dead = true
			elif p.age > 0.35 and grid.nearest(p.pos, 24.0, sw) >= 0:
				nova_at(p.pos, p.aux, p.dmg, p.el, Color("ff9a4a"), 220.0)
				_burst(p.pos, Color("ff9a4a"), 8, 180.0)
				Sfx.play_at("explode", p.pos)
				p.dead = true
			return true
		2:  # glaive: slows, turns back at the top of its arc, forgets who it cut, flies home
			if p.aux < 0.5:
				p.vel *= maxf(0.0, 1.0 - 2.6 * dt)
				if p.age > 0.55:
					p.aux = 1.0
					p.hits.clear()
			else:
				var home := pp - p.pos
				if home.length() < 22.0 or p.life <= 0.0:
					p.dead = true
					return true
				p.vel = p.vel.lerp(home.normalized() * 560.0, minf(1.0, dt * 9.0))
			return false                     # ordinary collisions (it pierces everything)
		3:  # wisp: steers toward the nearest foe
			p.tick -= dt
			if p.tick <= 0.0:
				p.tick = 0.12
				var j := grid.nearest(p.pos, 300.0, sw)
				if j >= 0:
					var want := (sw.pos[j] - p.pos).normalized() * 330.0
					p.vel = p.vel.lerp(want, 0.45)
			return false
		4:  # totem: fires a shard at the nearest foe in range
			if p.life <= 0.0:
				p.dead = true
				return true
			p.tick -= dt
			if p.tick <= 0.0:
				p.tick = maxf(0.12, p.aux * stats.value("cooldown", 1.0, wlocal["totem"]))
				var j := grid.nearest(p.pos, 300.0, sw)
				if j >= 0:
					var d := (sw.pos[j] - p.pos).normalized()
					var sh := _shot("totem", p.pos, d * 460.0, p.dmg, 5.0, 0.8, int(stats.value("pierce", 0.0, wlocal["totem"])), Color("c8f6ff"))
					sh.el = p.el
			return true
	return false

func _chain_target(p: Proj, from_i: int) -> int:
	var c := grid.query(sw.pos[from_i], 220.0, sw)
	var best := -1
	var bd := INF
	for q in c:
		var j := grid.results[q]
		if p.hits.has(sw.uid[j]) or (sw.flags[j] & Swarm.F_ALLY) != 0: continue
		var d := sw.pos[j].distance_squared_to(p.pos)
		if d < bd:
			bd = d; best = j
	return best

func _step_eshots(dt: float) -> void:
	var k := 0
	while k < eshots.size():
		var q: Proj = eshots[k]
		q.pos += q.vel * dt
		q.life -= dt
		if q.life <= 0.0:
			q.dead = true
		elif q.pos.distance_squared_to(pp) < (q.r + 10.0) * (q.r + 10.0):
			q.dead = hurt_player(q.dmg, "a projectile") or roll_t <= 0.0
		if q.dead:
			_pool.append(q)
			eshots[k] = eshots[eshots.size() - 1]
			eshots.pop_back()
		else:
			k += 1

func spawn_eshot(at: Vector2, vel: Vector2, dmg: float, r: float = 6.0, col: Color = Color("ff6a6a"), life: float = 5.0) -> void:
	if eshots.size() >= 360:
		return
	var q: Proj = _new_proj()
	q.pos = at; q.vel = vel; q.dmg = dmg; q.r = r; q.col = col; q.life = life
	eshots.append(q)

# ================================================================= telegraphs (unified hazard system)
func add_tele(shape: int, at: Vector2, r: float, arm: float, life: float, dmg: float, hostile: bool, friendly: bool, el: int, col: Color, tag: String) -> Tele:
	var z := Tele.new()
	z.shape = shape; z.pos = at; z.r = r; z.arm = arm; z.arm_max = maxf(0.001, arm); z.life = life; z.dmg = dmg
	z.hostile = hostile; z.friendly = friendly; z.el = el; z.col = col; z.tag = tag
	if teles.size() < 64:
		teles.append(z)
	return z

func tele_contains(z: Tele, p: Vector2, pad: float) -> bool:
	match z.shape:
		0: return p.distance_to(z.pos) < z.r + pad
		1: var d := p.distance_to(z.pos); return d < z.r + pad and d > z.r2 - pad
		2:
			var a := z.pos
			var b := z.pos + z.dir * z.length
			var ab := b - a
			var tt := clampf((p - a).dot(ab) / maxf(1.0, ab.length_squared()), 0.0, 1.0)
			return p.distance_to(a + ab * tt) < z.width * 0.5 + pad
		3:
			var v := p - z.pos
			return v.length() < z.r + pad and absf(v.angle_to(z.dir)) < z.ang
	return false

func _step_teles(dt: float) -> void:
	var k := 0
	while k < teles.size():
		var z: Tele = teles[k]
		if z.follow: z.pos = pp
		if z.spin != 0.0: z.dir = z.dir.rotated(z.spin * dt)
		if z.arm > 0.0:
			z.arm -= dt
			if z.arm <= 0.0:
				_tele_bite(z)
				if z.life <= 0.0: z.done = true
		else:
			z.life -= dt
			z.tk -= dt
			if z.tk <= 0.0:
				z.tk = z.tick
				_tele_bite(z)
			if z.life <= 0.0: z.done = true
		if z.done:
			teles[k] = teles[teles.size() - 1]
			teles.pop_back()
		else:
			k += 1

func _tele_bite(z: Tele) -> void:
	if z.hostile and tele_contains(z, pp, 8.0):
		hurt_player(z.dmg, z.tag)
	if z.friendly:
		var reach := z.r if z.shape != 2 else z.length
		var c := grid.query(z.pos, reach, sw)
		var hl := grid.results.slice(0, c)
		for q in hl.size():
			var i := hl[q]
			if i < sw.n and (sw.flags[i] & Swarm.F_ALLY) == 0 and tele_contains(z, sw.pos[i], sw.rad[i]):
				hit(i, z.dmg, (1 << z.el) if z.el >= 0 else 0, (sw.pos[i] - z.pos).normalized(), 60.0, 0)
	if z.arm_max > 0.05 and z.life <= 0.0:       # one-shot slams leave a mark
		_burst(z.pos, z.col, 12, 220.0)
		shake = minf(1.0, shake + 0.25)

# ================================================================= pickups & gems
func add_gem(at: Vector2, v: float) -> void:
	if gem_n >= GEM_CAP:
		gem_val[rng.randi_range(0, GEM_CAP - 1)] += v
		return
	if gem_pos.size() < GEM_CAP:
		gem_pos.resize(GEM_CAP); gem_val.resize(GEM_CAP); gem_mag.resize(GEM_CAP); gem_age.resize(GEM_CAP)
	gem_pos[gem_n] = at
	gem_val[gem_n] = v
	gem_mag[gem_n] = 0
	gem_age[gem_n] = 0.0
	gem_n += 1

func add_pick(at: Vector2, k: String, v: float = 0.0, data = null, life: float = 30.0) -> Dictionary:
	var d := {"pos": at + Vector2(randf_range(-10, 10), randf_range(-10, 10)), "k": k, "v": v, "life": life, "mag": false, "data": data}
	picks.append(d)
	return d

func vacuum() -> void:
	for i in gem_n: gem_mag[i] = 2
	for p in picks: p.mag = true

func _step_pickups(dt: float) -> void:
	var rad := 70.0 * stats.value("pickup", 1.0)
	var xm := stats.value("xp_gain", 1.0) * (1.0 + minf(0.5, combo * 0.002))
	var i := 0
	while i < gem_n:
		var g := gem_pos[i]
		var d := g.distance_to(pp)
		gem_age[i] += dt
		if d < rad and gem_mag[i] == 0: gem_mag[i] = 1
		if gem_mag[i] > 0:
			var sp := (850.0 if gem_mag[i] == 2 else 380.0) * dt
			gem_pos[i] = g.move_toward(pp, sp)
		elif gem_age[i] > 3.0:
			# shard gravity: XP left behind by distant kills drifts home, accelerating with age,
			# so ranged builds are not punished for killing far away
			gem_pos[i] = g.move_toward(pp, (60.0 + 45.0 * (gem_age[i] - 3.0)) * dt)
		if d < 14.0:
			xp += gem_val[i] * xm
			Sfx.play("gem")
			gem_n -= 1
			gem_pos[i] = gem_pos[gem_n]; gem_val[i] = gem_val[gem_n]; gem_mag[i] = gem_mag[gem_n]; gem_age[i] = gem_age[gem_n]
		else:
			i += 1
	var k := picks.size() - 1
	while k >= 0:
		var p: Dictionary = picks[k]
		p.life -= dt
		var d2: float = p.pos.distance_to(pp)
		if d2 < rad: p.mag = true
		if not p.mag and p.k in DRIFT and p.get("age", 0.0) > 3.0:
			p.pos = p.pos.move_toward(pp, (60.0 + 45.0 * (p.age - 3.0)) * dt)
		p.age = p.get("age", 0.0) + dt
		if p.mag:
			p.pos = p.pos.move_toward(pp, (850.0 if d2 > rad else 360.0) * dt)
		if d2 < 18.0:
			picks.remove_at(k)
			collect(p)
		elif p.life <= 0.0 and p.k != "item" and p.k != "lore" and p.k != "fragment":
			picks.remove_at(k)
		k -= 1

const DRIFT := ["coin", "currency", "progress", "splinter"]

func collect(p: Dictionary) -> void:
	match p.k:
		"coin":
			gold += p.v * stats.value("gold_find", 1.0) * (2.0 if has_leg("greed") else 1.0)
			Sfx.play("coin")
		"heart": hp = minf(max_hp, hp + max_hp * 0.25); Sfx.play("heal")
		"magnet": vacuum(); toast.emit("Vacuum Orb", Color("8b6bff"))
		"frenzy": buffs.add("frenzy"); toast.emit("Overclock", Color("ff8a2b"))
		"aegis": buffs.add("aegis"); toast.emit("Aegis", Color("ffd24a"))
		"vital": buffs.add("vital"); toast.emit("Vital Surge", Color("5dff6b"))
		"nuke":
			nova_at(pp, view_r, weapon_damage_base() * 9.0, (1 << Content.El.FIRE) | (1 << Content.El.PHYS), Color("e9fbff"), 380.0)
			eshots.clear()
			flash = 0.3; shake = 1.0
			toast.emit("Shard Nova", Color("9fefff"))
		"item": _take_item(p.data)
		"currency":
			currency_run[p.data] = int(currency_run.get(p.data, 0)) + 1
			Save.add_currency(p.data)
			toast.emit(Content.CURRENCY[p.data].name, Content.col(Content.CURRENCY[p.data].col))
			Sfx.play("coin")
		"lore":
			var id: int = int(p.data)
			if not Save.data.lore.has(id):
				Save.data.lore.append(id)
				Save.mark_dirty()
				lore_run.append(id)
				banner.emit(Content.LORE[id][0], Content.LORE[id][1], Color("e8dcc0"))
				if Save.data.lore.size() % Content.LORE_SET == 0:
					toast.emit("Lore set complete: +5% damage, +10 life", Color("e8dcc0"))
					_apply_meta()
		"fragment":
			Save.data.fragments[p.data] = int(Save.data.fragments.get(p.data, 0)) + 1
			frags_run[p.data] = int(frags_run.get(p.data, 0)) + 1
			Save.mark_dirty()
			banner.emit("Fragment of " + String(p.data).capitalize(), "Collect all three to summon the Shard Herald.", Color("c48aff"))
		"splinter":
			Save.data.splinters = int(Save.data.splinters) + int(p.v)
			if Save.data.splinters >= 10:
				Save.data.splinters -= 10
				add_pick(pp, "fragment", 0.0, "rupture")
			Save.mark_dirty()
		"flask":
			flasks[1] = {"id": p.data, "c": 40.0, "max": 40.0, "cost": 20.0}
			toast.emit(Content.FLASK_NAME[p.data], Color("c9f3ff"))
		"progress": progress = minf(Content.GR_PROGRESS, progress + p.v)
		"pylon", "shrine": pass        # world objects handled by the Director

func _take_item(it: Dictionary) -> void:
	metrics.items += 1
	loot_run.append(it)
	var cur: Dictionary = Save.data.equipped.get(it.slot, {})
	var upgrade := Items.score(it) > Items.score(cur) + 0.5
	if upgrade and Save.opt("auto_equip"):
		if not cur.is_empty(): stash_add(cur)
		equip(it)
		toast.emit("Equipped " + Items.name_of(it), Content.col(Content.RARITY_COL[it.rarity]))
	else:
		stash_add(it)
	item_found.emit(it, upgrade and not Save.opt("auto_equip"))

func stash_add(it: Dictionary) -> void:
	var st: Array = Save.data.stash
	if st.size() >= STASH_CAP:            # full stash: salvage the weakest normal/magic item
		var worst := -1
		var ws := INF
		for k in st.size():
			if int(st[k].rarity) <= Content.Rarity.MAGIC and Items.score(st[k]) < ws:
				ws = Items.score(st[k]); worst = k
		if worst < 0:
			Save.add_currency("transmute", 2)
			return
		st.remove_at(worst)
		Save.add_currency("transmute")
	st.append(it)
	Save.mark_dirty()

func equip(it: Dictionary) -> void:
	Save.data.equipped[it.slot] = it
	stats.set_source("item:" + it.slot, Items.mods(it))
	Save.mark_dirty()

# ================================================================= drops
func ilvl() -> int:
	var b := 1 + stage * 6 + int(rt() / 30.0)
	if mode == "atlas": b += int(node.tier) * 4
	if mode == "rift": b += gr_level * 2
	if mode == "pinnacle": b = 45
	return clampi(b, 1, 50)

func drop_item(at: Vector2, rarity_floor: int = 0, slot: String = "") -> void:
	var r := Items.roll_rarity(rng, stats.value("item_rarity", 1.0) - 1.0 + (0.5 if director.eclipse() else 0.0), rarity_floor)
	var lf := int(Save.opt("loot_filter"))
	if (lf == 1 and r == Content.Rarity.NORMAL) or (lf == 2 and r < Content.Rarity.RARE):
		gold += 2.0 * (r + 1)      # filtered items are auto-sold
		return
	var it := Items.make(slot if slot != "" else Items.random_slot(rng), r, ilvl(), rng)
	add_pick(at, "item", 0.0, it, 999.0)
	match r:
		Content.Rarity.MAGIC: Sfx.play_at("drop_magic", at)
		Content.Rarity.RARE: Sfx.play("drop_rare")
		Content.Rarity.LEGENDARY:
			Sfx.play("drop_legendary")
			banner.emit("Legendary drop!", Items.name_of(it), Content.col(Content.RARITY_COL[3]))

func drop_currency(at: Vector2, n: int = 1) -> void:
	for k in n:
		var tot := 0
		for c in Content.CURRENCY_WEIGHT: tot += Content.CURRENCY_WEIGHT[c]
		var r := rng.randi_range(0, tot - 1)
		for c in Content.CURRENCY_IDS:
			r -= Content.CURRENCY_WEIGHT[c]
			if r < 0:
				add_pick(at, "currency", 0.0, c, 60.0)
				Sfx.play_at("drop_currency", at)
				break

func drop_lore(at: Vector2) -> void:
	var missing: Array = []
	for k in Content.LORE.size():
		if not Save.data.lore.has(k): missing.append(k)
	if not missing.is_empty():
		add_pick(at, "lore", 0.0, missing[rng.randi_range(0, missing.size() - 1)], 999.0)

func drop_powerup(at: Vector2) -> void:
	var n := 0
	for p in picks:
		if ["magnet", "frenzy", "aegis", "vital", "nuke"].has(p.k): n += 1
	if n >= 3: return
	var opts := [["magnet", 30], ["vital", 26], ["frenzy", 22], ["nuke", 14], ["aegis", 8]]
	var r := rng.randi_range(0, 99)
	for o in opts:
		r -= o[1]
		if r < 0:
			add_pick(at, o[0], 0.0, null, 25.0)
			return

func loot_shower(at: Vector2, items: int, cur: int, coins: int, floor_r: int = 1) -> void:
	for k in items: drop_item(at + Vector2(randf_range(-40, 40), randf_range(-40, 40)), floor_r)
	drop_currency(at, cur)
	for k in coins: add_pick(at + Vector2(randf_range(-50, 50), randf_range(-50, 50)), "coin", 3.0)

# ================================================================= kills
func _reap() -> void:
	var i := sw.n - 1
	while i >= 0:
		if sw.hp[i] <= 0.0:
			_on_kill(i)
			sw.remove(i)
		i -= 1

func _on_kill(i: int) -> void:
	var f := sw.flags[i]
	var k := sw.kind[i]
	var at := sw.pos[i]
	if (f & Swarm.F_ALLY) != 0:
		return
	kills += 1
	var kid: String = Content.ENEMIES[k].id
	bestiary_run[kid] = int(bestiary_run.get(kid, 0)) + 1
	combo += 1
	combo_t = 3.5
	best_combo = maxi(best_combo, combo)
	charge_ult(0.6)
	var elite := (f & Swarm.F_ELITE) != 0
	if deaths.size() < 48:
		deaths.append([at, _foe_col(k), sw.rad[i], elite or (f & (Swarm.F_EXILE | Swarm.F_GOBLIN)) != 0, k, (pp - at).normalized(), sw.uid[i]])
	gain_flask(4.0 if elite else 1.0)
	relight(0.5 if (f & (Swarm.F_BOSS | Swarm.F_EXILE | Swarm.F_RIFTG)) != 0 else (0.05 if elite else LIGHT_PER_KILL))
	_burst(at, _foe_col(k), 14 if elite else 5, 200.0 if elite else 120.0)
	director.on_kill(i, at)
	hoard += 15.0 if elite else (60.0 if (f & (Swarm.F_BOSS | Swarm.F_EXILE | Swarm.F_RIFTG)) != 0 else 1.0)
	if elite and sw.burn[i] > 0.0: metrics.burn_elites = int(metrics.get("burn_elites", 0)) + 1
	if sw.freeze_t[i] > 0.0: metrics.frozen_kills = int(metrics.get("frozen_kills", 0)) + 1
	# the fight leaves its marks: blood where the big ones fall, poison where spitters burst
	if k == Content.E.SPITTER: terrain.pour(at, 30.0, Terrain.Surf.POISON, 12.0)
	elif elite or k == Content.E.BRUTE: terrain.pour(at, 32.0 if elite else 18.0, Terrain.Surf.BLOOD, 14.0)
	elif rng.randf() < 0.06: terrain.pour(at, 12.0, Terrain.Surf.BLOOD, 10.0)
	if (f & (Swarm.F_BOSS | Swarm.F_HERALD | Swarm.F_RIFTG | Swarm.F_EXILE | Swarm.F_GOBLIN)) != 0:
		bosses.on_kill(i, at)
		return
	add_gem(at, sw.xp[i] * (4.0 if elite else 1.0))
	if champ_uids.has(sw.uid[i]):
		champ_uids.erase(sw.uid[i])
		champions_slain += 1
		for g in 10: add_gem(at + Vector2(randf_range(-40, 40), randf_range(-40, 40)), need * 0.12)
		vacuum()
		hoard += 80.0
		gain_flask(40.0)
		hitstop = maxf(hitstop, 0.12)
		banner.emit("Champion slain", "Its hoard is yours.", Color("ffd84a"))
	if mode == "rift":
		progress = minf(Content.GR_PROGRESS, progress + (1.2 if elite else 0.07))
		if elite: add_pick(at, "progress", 2.5, null, 20.0)
	if k == Content.E.SPLITTER:
		for s in 3:
			if not sw.full(): spawn_foe(Content.E.MINI, at + Vector2(randf_range(-14, 14), randf_range(-14, 14)), 0)
	var qty := stats.value("item_quantity", 1.0)
	if elite:
		hitstop = maxf(hitstop, 0.04)
		Sfx.play_at("explode", at)
		for c in 3: add_pick(at, "coin", 2.0 * (1.5 if season == "avarice" else 1.0))
		if rng.randf() < 0.35: add_pick(at, "heart")
		if rng.randf() < 0.4: drop_powerup(at)
		if rng.randf() < 0.18 * qty * (1.4 if season == "mirrored" else 1.0): drop_item(at, Content.Rarity.MAGIC)
		if rng.randf() < 0.12 * qty: drop_currency(at)
		if rng.randf() < 0.05: add_pick(at, "flask", 0.0, Content.UTIL_FLASKS[rng.randi_range(0, 3)])
		if (sw.affix[i] & Content.Aff.VOLATILE) != 0 or has_mod("volatile"):
			add_tele(0, at, 60.0, 0.7, 0.0, 9.0 * sw.dmg[i] / 6.0, true, false, -1, Color(1, 0.55, 0.2, 0.6), "volatile")
		if season == "ethereal": _ethereal(k, at)
		if season == "avarice":
			add_tele(0, at, 50.0, 0.8, 0.0, 6.0, true, false, -1, Color(1, 0.85, 0.2, 0.6), "avarice")
	else:
		if rng.randf() < 0.012: drop_powerup(at)
		if rng.randf() < 0.004 * qty: drop_item(at)
		if rng.randf() < 0.006 * qty: drop_currency(at)
		var rc := rng.randf()
		if k == Content.E.BRUTE:
			if rc < 0.45: add_pick(at, "coin", 3.0)
		elif rc < 0.05 * (1.5 if season == "avarice" else 1.0): add_pick(at, "coin", 1.0)
		elif rc > 0.988: add_pick(at, "heart")
	if season == "soulharvest": buffs.add("soulharvest")
	if season == "blight" and rng.randf() < 0.15:
		add_tele(0, at, 40.0, 0.4, 3.0, 3.0, true, false, -1, Color(0.4, 1.0, 0.3, 0.35), "blight")
	if sw.bleed[i] > 0.0 and has_leg("gorefeast"):
		hp = minf(max_hp, hp + max_hp * 0.01)
	Sfx.play("kill")

func _ethereal(k: int, at: Vector2) -> void:
	var j := sw.add(k, at, 80.0 * lvl, 150.0, 12.0, 0.0, 0.0, Swarm.F_ALLY, 0)
	if j >= 0:
		sw.set_ai(j, 0, 10.0)

func _foe_col(k: int) -> Color:
	return Content.col(Content.STAGES[stage].acc).lerp(Color.WHITE, 0.2)

# ================================================================= render feed bookkeeping
func _burst(at: Vector2, col: Color, n: int, spd: float) -> void:
	if bursts.size() < 64:
		bursts.append([at, col, n, spd])

## tier: 0 normal, 1 crit, 2 reaction damage, 3 reaction label, 4 DoT tick
func _text(at: Vector2, v: float, col: Color, tier: int, u: int, label: String = "") -> void:
	var opt := int(Save.opt("dmg_numbers"))
	if opt == 0 or (opt == 1 and tier != 1 and tier != 3):
		return
	if u >= 0 and _agg.has(u):                   # merge hits on one foe within 0.12s into one number
		var e: Dictionary = _agg[u]
		if e.t < 0.12 and e.tier == tier:
			e.v += v
			return
	if texts.size() >= 70:
		texts.pop_front()
	var e2 := {"pos": at + Vector2(randf_range(-6, 6), 0), "v": v, "col": col, "tier": tier, "t": 0.0, "uid": u, "label": label}
	texts.append(e2)
	if u >= 0: _agg[u] = e2
	metrics.texts += 1

func _step_feed(dt: float) -> void:
	var k := texts.size() - 1
	while k >= 0:
		var e: Dictionary = texts[k]
		e.t += dt
		if e.t > (1.0 if e.tier == 3 else 0.65):
			if _agg.get(e.uid) == e: _agg.erase(e.uid)
			texts.remove_at(k)
		k -= 1
	k = fx.size() - 1
	while k >= 0:
		var f: Dictionary = fx[k]
		f.t += dt
		if f.t >= f.life: fx.remove_at(k)
		k -= 1

# ================================================================= level-up choices
func make_choices() -> Array:
	if lvl in Content.KEYSTONE_LEVELS and keystones.size() < Content.KEYSTONE_LEVELS.find(lvl) + 1:
		var ks: Array = []
		for id in Content.KEYSTONE_IDS:
			if not keystones.has(id): ks.append({"kind": "key", "id": id})
		ks.shuffle()
		return ks.slice(0, 3)
	var pool: Array = []
	var evos: Array = []
	var fresh: Array = []                                   # weapons not held yet: at most two offered per level-up
	for id in Content.WEAPON_IDS:
		if not weapons.has(id):
			if weapons.size() < Content.MAX_WEAPONS and weapon_pool.has(id): fresh.append({"kind": "w", "id": id})
		elif int(weapons[id].lv) < 5:
			pool.append({"kind": "w", "id": id})
		elif not weapons[id].evo and int(perks.get(Content.WEAPONS[id].pair, 0)) >= 1:
			evos.append({"kind": "e", "id": id})
	for a in weapons:                                       # fusions: two evolved, unfused weapons
		for b in weapons:
			if a < b and weapons[a].evo and weapons[b].evo and fused(a) == "" and fused(b) == "":
				evos.append({"kind": "fuse", "id": Content.fusion_key(a, b), "a": a, "b": b})
	for id in Content.WEAPON_IDS:
		if weapons.has(id) and weapons[id].gems.size() < Content.SOCKETS:
			for g in Content.GEM_IDS:
				var req: String = Content.GEMS[g].req
				if weapons[id].gems.has(g): continue
				if req == "" or Content.WEAPONS[id].tags.has(req):
					if rng.randf() < 0.22: pool.append({"kind": "g", "id": g, "w": id})
	for id in Content.PERK_IDS:
		if int(perks.get(id, 0)) < 5: pool.append({"kind": "p", "id": id})
	fresh.shuffle()
	pool.append_array(fresh.slice(0, 2))
	pool.shuffle()
	var out: Array = evos.slice(0, 2)
	var seen := {}
	for c in pool:
		if out.size() >= 3 + (1 if lvl >= 10 else 0): break
		var key: String = c.kind + c.id
		if seen.has(key): continue
		seen[key] = true
		out.append(c)
	if out.is_empty(): out.append({"kind": "heal", "id": "heal"})
	return out

func choice_text(c: Dictionary) -> Dictionary:
	match c.kind:
		"w":
			var lv := int(weapons[c.id].lv) if weapons.has(c.id) else 0
			var W: Dictionary = Content.WEAPONS[c.id]
			return {"tag": "New weapon" if lv == 0 else "Weapon Lv %d -> %d" % [lv, lv + 1], "name": W.name, "d": W.d[lv] + "  [%s]" % Content.EL_NAME[W.elem], "col": W.col}
		"e": return {"tag": "Evolution", "name": Content.WEAPONS[c.id].evo, "d": Content.WEAPONS[c.id].evo_d, "col": "f4c04e"}
		"fuse": return {"tag": "Fusion: %s + %s" % [Content.WEAPONS[c.a].evo, Content.WEAPONS[c.b].evo], "name": Content.fusion_def(c.id).name,
			"d": Content.fusion_def(c.id).d + " Both deal 25% more damage and carry each other's element.", "col": Content.fusion_def(c.id).col}
		"p":
			var pl := int(perks.get(c.id, 0))
			return {"tag": "New perk" if pl == 0 else "Perk Lv %d -> %d" % [pl, pl + 1], "name": Content.PERKS[c.id].name, "d": Content.PERKS[c.id].d, "col": "ece8dd"}
		"g": return {"tag": "Support gem -> " + Content.WEAPONS[c.w].name, "name": Content.GEMS[c.id].name, "d": Content.GEMS[c.id].d, "col": "8ad6a0"}
		"key": return {"tag": "Keystone", "name": Content.KEYSTONES[c.id].name, "d": Content.KEYSTONES[c.id].d, "col": "ff6bd6"}
	return {"tag": "Fully upgraded", "name": "Second Wind", "d": "Heal 30% of your life.", "col": "5dff6b"}

func apply_choice(c: Dictionary) -> void:
	match c.kind:
		"w":
			if weapons.has(c.id): weapons[c.id].lv += 1
			else:
				weapons[c.id] = {"lv": 1, "evo": false, "t": 0.0, "gems": []}
				wlocal[c.id] = Stats.new()
		"fuse":
			weapons[c.a].fuse = c.b
			weapons[c.b].fuse = c.a
			for id in [c.a, c.b]: wlocal[id].set_source("fusion", [["damage", "more", 1.25]])
			_elmask_ver = -1
			shake = 1.0
			fx.append({"k": "ring", "pos": pp, "r": 0.0, "max": 240.0, "col": Content.col(Content.fusion_def(c.id).col), "life": 0.5, "t": 0.0})
			banner.emit(Content.fusion_def(c.id).name, Content.fusion_def(c.id).d, Content.col(Content.fusion_def(c.id).col))
			metrics.fusions = int(metrics.get("fusions", 0)) + 1
		"e":
			weapons[c.id].evo = true
			shake = 0.8
			fx.append({"k": "ring", "pos": pp, "r": 0.0, "max": 170.0, "col": Color("f4c04e"), "life": 0.4, "t": 0.0})
		"p":
			perks[c.id] = int(perks.get(c.id, 0)) + 1
			stats.set_source("perk:" + c.id, Content.PERKS[c.id].mods, float(perks[c.id]))
		"g":
			weapons[c.w].gems.append(c.id)
			wlocal[c.w].set_source("gem:" + c.id, Content.GEMS[c.id].mods)
		"key":
			keystones.append(c.id)
			stats.set_source("key:" + c.id, Content.KEYSTONES[c.id].get("mods", []))
		_: hp = minf(max_hp, hp + max_hp * 0.3)
	pending = maxi(0, pending - 1)
	inv_t = maxf(inv_t, 0.8)

# ================================================================= end
func end_run(win: bool) -> void:
	if over:
		return
	if win and hoard > 0.0 and mode != "pinnacle":
		bank_hoard(pp, false)
	elif not win:
		hoard_lost = hoard * hoard_mult
		hoard = 0.0
	over = true
	won = win
	var d: Dictionary = Save.data
	for kid in bestiary_run:
		d.bestiary[kid] = int(d.bestiary.get(kid, 0)) + int(bestiary_run[kid])
	var g := int(gold * float(Content.STAGES[stage].gold)) + int(t / 10.0) + (40 * (stage + 1) if win else 0)
	d.gold = int(d.gold) + g
	gold = g
	d.stats.runs = int(d.stats.runs) + 1
	d.stats.kills = int(d.stats.kills) + kills
	d.stats.playtime = float(d.stats.playtime) + t
	d.stats.best_combo = maxi(int(d.stats.best_combo), best_combo)
	d.stats.champions = int(d.stats.get("champions", 0)) + champions_slain
	if not win:
		d.stats.deaths = int(d.stats.deaths) + 1
		bosses.on_player_death()
	if daily:
		_daily_end(d)
	elif win and mode == "campaign":
		while d.cleared.size() <= stage: d.cleared.append(false)
		d.cleared[stage] = true
	new_unlocks = Save.check_unlocks()
	# Echoes for the Shard Web: a share of kills, a win bonus, rift depth and the torment tier
	echoes_run = mini(12, kills / 250 + (2 if win else 0) + (gr_level / 3 if mode == "rift" else 0) + (int(Content.TORMENT[torment].echo) if win else 0) + bargains.size()) + hoard_echoes
	if not bargains.is_empty():
		d.stats["bargains"] = int(d.stats.get("bargains", 0)) + bargains.size()
	d.echoes = int(d.get("echoes", 0)) + echoes_run
	if win and not daily and mode != "rift" and torment >= int(d.get("torment_max", 0)) and torment < Content.TORMENT.size() - 1:
		d.torment_max = torment + 1                  # beating a tier opens the next
	Save.mark_dirty()
	if not headless:
		Save.flush()
	Sfx.play("win" if win else "lose")
	ended.emit(win)

# ================================================================= the lantern (darkness meter)
## Light fades over the run and kills relight it: a hero who keeps killing keeps the dark back;
## one who kites or stalls watches the world close in. Below LIGHT_ENGULF the hero is Engulfed:
## foes hit 30% harder and drop 30% rarer loot. Pylons and shrines refill it; the Eclipse
## event drains it 2.5x as fast; the Moon, the calendar and some bargains scale the rate (dark_rate).
const LIGHT_PER_KILL := 0.003
const LIGHT_ENGULF := 0.2

func _step_light(dt: float) -> void:
	light_cap = 0.5 if has_bargain("long_night") else 1.0
	if mode == "pinnacle":
		light = light_cap
	else:
		var rate := (0.018 + 0.027 * minf(1.0, t / Content.STAGE_TIME)) * stats.value("dark_rate", 1.0)
		if director.eclipse(): rate *= 2.5
		var was := light
		light = clampf(light - rate * dt, 0.0, light_cap)
		if was >= LIGHT_ENGULF and light < LIGHT_ENGULF:
			banner.emit("Engulfed", "The dark closes in. Foes hit harder; their loot is richer. Kill to relight.", Color("6a5a9a"))
			stats.set_source("engulfed", [["item_rarity", "inc", 0.3]])
		elif was < LIGHT_ENGULF and light >= LIGHT_ENGULF:
			stats.clear_source("engulfed")
	if light < LIGHT_ENGULF: metrics.dark_s = float(metrics.get("dark_s", 0.0)) + dt
	metrics.light_sum = float(metrics.get("light_sum", 0.0)) + light * dt
	if has_bargain("long_night"):
		var q := int(gloom() * 10.0)
		if q != _night_q:
			_night_q = q
			stats.set_source("night", [["damage", "more", 1.0 + 0.08 * q]])

func relight(v: float) -> void:
	light = minf(light_cap, light + v)

## 0 in full light, 1 in full dark (Eclipse counts as full dark). The renderers dim by this.
func gloom() -> float:
	if director.eclipse(): return 1.0
	return clampf((0.6 - light) / 0.6, 0.0, 1.0)

## 0..1: how far below the Engulfed line the light has fallen.
func engulfed() -> float:
	return clampf((LIGHT_ENGULF - light) / LIGHT_ENGULF, 0.0, 1.0) if light < LIGHT_ENGULF else 0.0

# ================================================================= the Daily Rift
func _daily_end(d: Dictionary) -> void:
	daily_score = Daily.score(self)
	var D: Dictionary = d.daily
	var prev := int(D.best.get(daily_code, -1))
	daily_best = daily_score > prev
	if daily_best:
		D.best.erase(daily_code)
		D.best[daily_code] = daily_score                  # re-inserted: the dict stays in recency order
		while D.best.size() > 30: D.best.erase(D.best.keys()[0])
	if won and daily_date != "" and D.claimed != daily_date:   # today's rift, first clear: a small reward
		D.claimed = daily_date
		hoard_echoes += 3
		metrics.daily_reward = true

# ================================================================= prophecies
## [current, target] for the active prophecy, from this run's metrics.
func prophecy_progress() -> Vector2:
	if prophecy.is_empty(): return Vector2.ZERO
	var P: Dictionary = Content.PROPHECIES[prophecy.id]
	var tg := float(P.target)
	var tm: Dictionary = metrics.terrain
	var cur := 0.0
	match String(prophecy.id):
		"pyre": cur = metrics.get("burn_elites", 0)
		"rime": cur = metrics.get("frozen_kills", 0)
		"conduit": cur = int(tm.get("shock", 0)) + int(tm.get("conduct", 0))
		"reaper": cur = kills
		"unscathed": cur = 1.0 if boss_spawned and metrics.dmg_taken < 150.0 else 0.0
		"hoarder": cur = metrics.get("best_bank", 0.0)
		"gambler": cur = 1.0 if float(metrics.get("best_mult", 0.0)) >= 2.0 else 0.0
		"alloy": cur = metrics.get("fusions", 0)
		"pilgrim": cur = metrics.get("events_done", 0)
		"kindling": cur = int(tm.get("ignite", 0)) + int(tm.get("blast", 0))
	return Vector2(minf(float(cur), tg), tg)

var _proph_t := 0.0
func _step_prophecy(dt: float) -> void:
	if prophecy.is_empty() or prophecy_done: return
	_proph_t -= dt
	if _proph_t > 0.0: return
	_proph_t = 0.5
	var pr := prophecy_progress()
	if pr.x >= pr.y: fulfil_prophecy()

## Pays the chosen reward now (items drop at the hero's feet) and clears it from the profile.
func fulfil_prophecy() -> void:
	prophecy_done = true
	var P: Dictionary = Content.PROPHECIES[prophecy.id]
	match String(prophecy.reward):
		"legendary": drop_item(pp + Vector2(0, 30), Content.Rarity.LEGENDARY)
		"rare3":
			for k in 3: drop_item(pp + Vector2(cos(k * 2.1), sin(k * 2.1)) * 34.0, Content.Rarity.RARE)
		"chaos": Save.add_currency("chaos", 4)
		"exalt": Save.add_currency("exalt", 2)
		"echoes": Save.data.echoes = int(Save.data.echoes) + 6
		"gold": Save.data.gold = int(Save.data.gold) + 600
	if not headless or Save.data.prophecy.active.get("id", "") == prophecy.id:
		Save.data.prophecy.active = {}
		Save.data.prophecy.offers = []
		Save.data.prophecy.done = int(Save.data.prophecy.done) + 1
	Save.mark_dirty()
	metrics.prophecy = prophecy.id
	banner.emit("Prophecy fulfilled: " + P.name, Content.PROPHECY_REWARDS[prophecy.reward], Color("ffd27a"))
	fx.append({"k": "ring", "pos": pp, "r": 0.0, "max": 200.0, "col": Color("ffd27a"), "life": 0.5, "t": 0.0})
	Sfx.play("level")

# ================================================================= bank or push (Rift Gates)
## Banks the hoard at the current multiplier: gold now, Echoes at the end of the run, and rare items
## that spill out of the gate (one per 150 banked, at most four). Resets the multiplier.
func bank_hoard(at: Vector2, drop: bool = true) -> Dictionary:
	var v := hoard * hoard_mult
	var g := v * 0.5
	var e := int(v / 300.0)
	var items := mini(4, int(v / 150.0))
	gold += g
	hoard_echoes += e
	hoard_banked += v
	if drop:
		for k in items: drop_item(at + Vector2(cos(k * 1.9), sin(k * 1.9)) * 30.0, Content.Rarity.RARE)
	var res := {"value": v, "gold": g, "echoes": e, "items": items if drop else 0, "mult": hoard_mult}
	metrics.banked = int(metrics.get("banked", 0)) + 1
	metrics.best_bank = maxf(float(metrics.get("best_bank", 0.0)), v)
	if v > 0.0: metrics.best_mult = maxf(float(metrics.get("best_mult", 0.0)), hoard_mult)
	if v > 0.0:
		banner.emit("Hoard banked", "+%d gold   +%d Echoes   %d rare items   (x%.1f)" % [int(g), e, res.items, hoard_mult], Color("7fd8ff"))
	hoard = 0.0
	hoard_mult = 1.0
	return res

## A gate closed without being used: the unbanked hoard grows more valuable, and more at risk.
func gate_passed() -> void:
	hoard_mult = minf(3.0, hoard_mult + 0.5)
	metrics.pushed = int(metrics.get("pushed", 0)) + 1
	toast.emit("You walked past the gate: hoard x%.1f" % hoard_mult, Color("7fd8ff"))

# ================================================================= the Whisperer
func has_bargain(id: String) -> bool:
	return bargains.has(id)

## Called by the Director when the hero touches the Whisperer: two bargains not yet taken.
func offer_whisper() -> void:
	var pool: Array = []
	for id in Content.WHISPER_IDS:
		if not bargains.has(id): pool.append(id)
	if pool.size() < 2:
		return
	whisper_offer = []
	for k in 2:
		var j := rng.randi_range(0, pool.size() - 1)
		whisper_offer.append(pool[j])
		pool.remove_at(j)
	whisper_open.emit()

## Accept one of the offered bargains ("" refuses). The boon and the price apply for the rest of the run.
func accept_bargain(id: String) -> void:
	whisper_offer = []
	if id == "" or bargains.has(id) or not Content.WHISPERS.has(id):
		toast.emit("The whisper fades, unanswered", Color("9a6bff"))
		return
	bargains.append(id)
	var B: Dictionary = Content.WHISPERS[id]
	stats.set_source("whisper:" + id, B.mods)
	_refresh_max_hp()
	if id == "long_night": light = minf(light, 0.5)
	metrics.bargains = bargains.duplicate()
	banner.emit(B.name, "%s.  %s." % [B.boon, B.cost], Color("b48aff"))
	Sfx.play("event")

# ================================================================= breakables (urns and barrels)
## Clusters of 3-5 appear near the hero every 18-30 s (never more than 10 nearby). Any skill area or
## projectile touching one shatters it: coins mostly, sometimes a heart, power-up or currency.
func _step_breakables(dt: float) -> void:
	if mode == "pinnacle":
		return
	_brk_t -= dt
	var k := breakables.size() - 1
	var near := 0
	while k >= 0:
		var d: float = breakables[k].pos.distance_to(pp)
		if d > 1300.0: breakables.remove_at(k)
		elif d < 700.0: near += 1
		k -= 1
	if _brk_t <= 0.0:
		_brk_t = rng.randf_range(18.0, 30.0)
		if near < 10:
			var a := rng.randf() * TAU
			var c := terrain.nearest_passable(pp + Vector2(cos(a), sin(a)) * rng.randf_range(260.0, 420.0))
			var kind := rng.randi_range(0, 1)
			for i in rng.randi_range(3, 5):
				var bp := c + Vector2(rng.randf_range(-40, 40), rng.randf_range(-40, 40))
				if terrain.type_at(bp) == Terrain.LAND:
					breakables.append({"pos": bp, "kind": kind, "r": 10.0 if kind == 0 else 13.0})

## Returns true if anything broke.
func shatter(at: Vector2, r: float) -> bool:
	if breakables.is_empty():
		return false
	var any := false
	var k := breakables.size() - 1
	while k >= 0:
		var b: Dictionary = breakables[k]
		if b.pos.distance_to(at) < r + b.r:
			breakables.remove_at(k)
			any = true
			if broken.size() < 32: broken.append([b.pos, b.kind])
			if int(b.kind) == 1: terrain.pour(b.pos, 40.0, Terrain.Surf.OIL, 18.0)     # barrels spill oil
			Sfx.play_at("break", b.pos)
			var roll := rng.randf()
			if mode == "rift" and roll >= 0.65: roll = 1.0       # rifts: urns pay coins only, no sustain from pots
			if roll < 0.65:
				for c in rng.randi_range(1, 3): add_pick(b.pos, "coin", 1.0)
			elif roll < 0.73: add_pick(b.pos, "heart")
			elif roll < 0.77: drop_powerup(b.pos)
			elif roll < 0.80: drop_currency(b.pos)
		k -= 1
	return any

## Breaks the World <-> Director/Bosses reference cycle so RefCounted can free the run.
func dispose() -> void:
	if director != null: director.w = null
	if bosses != null: bosses.w = null
	director = null
	bosses = null
	crowd = null
	level_up.get_connections().map(func(c): level_up.disconnect(c.callable))
