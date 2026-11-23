class_name Contagion
extends RefCounted
## The Emberwitch's contagion (0.10.0): her Shock Pulse becomes Incineration, and fire spreads through a pack.
##
## Stage 1, Incineration: each cast lands on the densest cluster within CAST_RANGE. It detonates for
##   DETONATE_K x the spell power and +2 Burn on everything in ZONE_R, then the ground burns for ZONE_TIME,
##   pulsing every ZONE_TICK: +1 Burn on everything standing in it.
## Stage 2, thermal ramp: every RAMP_TICK a burning foe takes burn_dps x stacks x (1 + RAMP x (stacks - 1)) x
##   RAMP_TICK. Burn stacks cap at MAX_BURN_STACKS and burn for BURN_TIME after the latest one (Swarm.burn_t).
##   The 3D view packs stacks / 5 over a foe's flag bits (custom.w + 256 x stacks) for the ember crust.
## Stage 3, spread: a foe with 2+ stacks whose spread cooldown is up passes its fire to up to SPREAD_N foes
##   within CONTAGION_R that carry fewer stacks (unburned first): each gets max(1, stacks - 1), one generation
##   further (burn_gen <= MAX_GEN: a generation-4 fire spreads no more); the source waits SPREAD_CD.
##   Conflagration: a burning foe dying, or one reaching MAX_BURN_STACKS, blasts CONFLAG_R for CONFLAG_K x the
##   spell power and +2 Burn, at most once every CONFLAG_CD. At most EVENT_CAP spread and conflagration
##   events a tick, however big the blaze.
##   Beacons: an Incineration or conflagration that reaches a WOOD solid (PropLayout.TAG_WOOD: tree and dead
##   tree trunks; never bushes or grass, which are not solids) sets it alight for BEACON_TIME; a lit trunk
##   gives +1 Burn every BEACON_TICK to foes within BEACON_R of its bark.
## The view reads zones, beacons, burning and the hottest cluster (hot, hot_heat) for the fire, the one
## dynamic light and the crackle-to-rumble audio bed. World.metrics counts ember_ignitions, ember_spreads,
## ember_conflagrations and ember_beacons (the pause menu shows them).

const MAX_BURN_STACKS := 5
const BURN_TIME := 4.0
const SPREAD_CD := 0.35
const MAX_GEN := 4
const CAST_RANGE := 420.0
const ZONE_R := 85.0
const ZONE_TIME := 1.6
const ZONE_TICK := 0.25
const DETONATE_K := 0.6
const DETONATE_STACKS := 2
const PULSE_STACKS := 1
const RAMP_TICK := 0.25
const RAMP := 0.18
const BURN_DPS_K := 0.12          # one Burn stack's damage per second, as a share of the spell power that lit it
const CONTAGION_R := 72.0
const SPREAD_N := 2
const CONFLAG_R := 115.0
const CONFLAG_K := 1.25
const CONFLAG_STACKS := 2
const CONFLAG_CD := 1.5
const EVENT_CAP := 60
const BEACON_TIME := 6.0
const BEACON_TICK := 0.5
const BEACON_R := 55.0
const LIGHT_MIN := 3              # the cluster light needs at least this many foes burning
const DENSE_SAMPLES := 24         # candidate centres tried when looking for the densest cluster
const ARC_FX_CAP := 10            # fire arcs drawn a tick (every spread still counts)
const COL := Color("ff7b2e")

var w: World
var on := false                   # the hero is the Emberwitch
var zones: Array = []             # {pos, r, t (age), next (age of the next pulse), power}
var beacons: Array = []           # {pos, r (bark radius), t (seconds left), tick, key}
var _lit := {}                    # Vector2i (trunk centre) -> true while that trunk burns
var conflag_cd := 0.0
var _queue: Array = []            # conflagrations to blast at the next step: [pos, gen]
var _ramp_t := 0.0
var _events := 0                  # spread and conflagration events this tick (EVENT_CAP)
var _arcs := 0
var power := 0.0                  # the latest Incineration's spell power (conflagrations and beacons scale from it)
var burning := 0                  # foes burning now
var hot := Vector2.ZERO           # centroid of the hottest burning cluster ...
var hot_heat := 0                 # ... and its stacks; 0 while fewer than LIGHT_MIN foes burn
var last_at := Vector2.INF        # where the latest Incineration landed

func _init(world: World) -> void:
	w = world
	on = String(Content.HEROES[world.hero].id) == "ember"
	for k in ["ember_ignitions", "ember_spreads", "ember_conflagrations", "ember_beacons"]:
		w.metrics[k] = 0

## The Emberwitch's cast (World._nova): Incineration on the densest cluster in range. False when no foe is near.
func cast(spell_power: float) -> bool:
	var at := densest(w.pp, CAST_RANGE)
	if at == Vector2.INF: return false
	cast_at(at, spell_power)
	return true

## Centre of the densest pack within `rng` of `from`: of up to DENSE_SAMPLES foes in range, the one with the
## most foes within ZONE_R (ties: the nearer). Vector2.INF when nothing is in range.
func densest(from: Vector2, rng: float) -> Vector2:
	var sw := w.sw
	var c := w.grid.query(from, rng, sw)
	if c == 0: return Vector2.INF
	var cands := w.grid.results.slice(0, c)
	var step := maxi(1, c / DENSE_SAMPLES)
	var best := Vector2.INF
	var best_n := -1
	var best_d := INF
	for q in range(0, c, step):
		var i := cands[q]
		if i >= sw.n or (sw.flags[i] & Swarm.F_ALLY) != 0: continue
		var p := sw.pos[i]
		var n := w.grid.query(p, ZONE_R, sw)
		var d := p.distance_squared_to(from)
		if n > best_n or (n == best_n and d < best_d):
			best_n = n
			best_d = d
			best = p
	return best

## Stage 1: the detonation and the burning ground it leaves.
func cast_at(at: Vector2, spell_power: float) -> void:
	power = spell_power
	last_at = at
	var r := ZONE_R * w.stats.value("area", 1.0, w.wlocal.get("nova"))
	zones.append({"pos": at, "r": r, "t": 0.0, "next": ZONE_TICK, "power": spell_power})
	var em := w.elmask("nova") if w.weapons.has("nova") else (1 << Content.El.FIRE)
	var hl := _foes_in(at, r)
	for i in hl:
		w.hit(i, DETONATE_K * spell_power, em, (w.sw.pos[i] - at).normalized(), 140.0, 0)
		ignite(i, DETONATE_STACKS, 0, spell_power * BURN_DPS_K)
	w.fx.append({"k": "incinerate", "pos": at, "r": r, "col": COL, "life": ZONE_TIME, "t": 0.0})
	w.fx.append({"k": "ring", "pos": at, "r": 0.0, "max": r, "col": COL, "life": 0.35, "t": 0.0})
	w.shatter(at, r)
	_beacons_near(at, r)
	w.shake = minf(1.0, w.shake + 0.06)

## Adds `add` Burn stacks to foe i (capped), lit by a fire `gen` spreads from an Incineration, a stack doing
## `dps` a second (the stronger of the old and new). A foe reaching MAX_BURN_STACKS asks for a conflagration.
func ignite(i: int, add: int, gen: int, dps: float) -> void:
	var sw := w.sw
	if i < 0 or i >= sw.n or sw.hp[i] <= 0.0 or (sw.flags[i] & Swarm.F_ALLY) != 0: return
	var was := sw.burn_stacks[i]
	var s := mini(MAX_BURN_STACKS, was + add)
	sw.set_burn(i, s, maxf(sw.burn_dps[i], dps), mini(sw.burn_gen[i], gen) if was > 0 else mini(gen, MAX_GEN), BURN_TIME)
	if was == 0: w.metrics.ember_ignitions += 1
	if s >= MAX_BURN_STACKS and was < MAX_BURN_STACKS: _ask_conflag(sw.pos[i], sw.burn_gen[i])

## A foe died (World._on_kill, while it is reaped): a burning one conflagrates.
func on_kill(i: int) -> void:
	if on and w.sw.burn_stacks[i] > 0: _ask_conflag(w.sw.pos[i], w.sw.burn_gen[i])

func _ask_conflag(at: Vector2, gen: int) -> void:
	if conflag_cd > 0.0: return
	conflag_cd = CONFLAG_CD
	_queue.append([at, gen])

## Once a tick, after the foes moved and before they are reaped (World._step).
func step(dt: float) -> void:
	if not on: return
	_events = 0
	_arcs = 0
	conflag_cd = maxf(0.0, conflag_cd - dt)
	var q := _queue
	_queue = []
	for c in q:
		if _events >= EVENT_CAP: break
		_conflagrate(c[0], int(c[1]))
	var k := zones.size() - 1
	while k >= 0:
		var z: Dictionary = zones[k]
		z.t += dt
		while z.t >= z.next and z.next <= ZONE_TIME + 1e-4:
			for i in _foes_in(z.pos, z.r): ignite(i, PULSE_STACKS, 0, float(z.power) * BURN_DPS_K)
			w.fx.append({"k": "ring", "pos": z.pos, "r": z.r * 0.35, "max": z.r, "col": COL.lightened(0.15), "life": 0.25, "t": 0.0})
			z.next += ZONE_TICK
		if z.t >= ZONE_TIME: zones.remove_at(k)
		k -= 1
	_step_beacons(dt)
	_ramp_t += dt
	if _ramp_t >= RAMP_TICK:
		_ramp_t -= RAMP_TICK
		_ramp()
	_spread()

## Stage 2: burning foes take their ramped Burn damage (Swarm.burn_ramp); counts the blaze and finds its
## hottest cluster (96-unit cells, by stacks).
var _hurt := PackedFloat32Array()
func _ramp() -> void:
	var sw := w.sw
	burning = sw.burn_ramp(RAMP, RAMP_TICK, w.stats.value("dot_damage", 1.0), _hurt)
	var cells := {}
	var dealt := 0.0
	for k in range(0, _hurt.size(), 2):
		var i := int(_hurt[k])
		var d := _hurt[k + 1]
		dealt += d
		var p := sw.pos[i]
		if d >= 3.0 or d >= sw.mhp[i] * 0.02: w.text_dot(p, d, sw.uid[i])
		if burning < LIGHT_MIN: continue
		var key := Vector2i(floori(p.x / 96.0), floori(p.y / 96.0))
		var acc = cells.get(key)
		if acc == null:
			cells[key] = [p, sw.burn_stacks[i], 1]
		else:
			acc[0] += p
			acc[1] += sw.burn_stacks[i]
			acc[2] += 1
	w.metrics.dmg_dealt += dealt
	hot_heat = 0
	for key in cells:
		var acc2: Array = cells[key]
		if int(acc2[1]) > hot_heat:
			hot_heat = int(acc2[1])
			hot = acc2[0] / float(acc2[2])

## Stage 3: burning foes pass their fire on (sources and targets picked inside Swarm, in place).
var _src := PackedInt32Array()
var _tg := PackedInt32Array()
func _spread() -> void:
	var sw := w.sw
	if _src.size() != Swarm.CAP: _src.resize(Swarm.CAP)
	if _tg.size() != 2: _tg.resize(2)
	var ns := sw.spread_sources(_src, MAX_GEN, SPREAD_CD)
	for k in ns:
		if _events >= EVENT_CAP: return
		var i := _src[k]
		var src := sw.pos[i]
		var c := w.grid.query(src, CONTAGION_R, sw)
		var nt := sw.spread_targets(i, w.grid.results, c, _tg)
		if nt == 0: continue
		var s := sw.burn_stacks[i]
		var gen := sw.burn_gen[i] + 1
		var dps := sw.burn_dps[i]
		for t in nt:
			if _events >= EVENT_CAP: return
			var j := _tg[t]
			ignite(j, maxi(1, s - 1), gen, dps)
			_events += 1
			w.metrics.ember_spreads += 1
			if _arcs < ARC_FX_CAP:
				_arcs += 1
				w.fx.append({"k": "fire_arc", "pos": src, "to": sw.pos[j], "col": COL, "life": 0.3, "t": 0.0})

func _conflagrate(at: Vector2, gen: int) -> void:
	_events += 1
	w.metrics.ember_conflagrations += 1
	var em := w.elmask("nova") if w.weapons.has("nova") else (1 << Content.El.FIRE)
	var g := mini(gen + 1, MAX_GEN)
	for i in _foes_in(at, CONFLAG_R):
		w.hit(i, CONFLAG_K * power, em, (w.sw.pos[i] - at).normalized(), 260.0, 1)
		ignite(i, CONFLAG_STACKS, g, power * BURN_DPS_K)
	w.fx.append({"k": "conflag", "pos": at, "r": CONFLAG_R, "col": Color("ffb347"), "life": 0.6, "t": 0.0})
	w.fx.append({"k": "ring", "pos": at, "r": 0.0, "max": CONFLAG_R, "col": Color("ff9a3c"), "life": 0.4, "t": 0.0})
	w.shatter(at, CONFLAG_R)
	_beacons_near(at, CONFLAG_R)
	w.shake = minf(1.0, w.shake + 0.1)
	Sfx.play_at("explode", at)

## Wood trunks reached by a fire of radius r at `at` catch alight.
func _beacons_near(at: Vector2, r: float) -> void:
	for c in w.terrain.props_in(at, r):
		if int(c[3]) != PropLayout.TAG_WOOD: continue
		var key := Vector2i(roundi((c[0] as Vector2).x), roundi((c[0] as Vector2).y))
		if _lit.has(key):
			for b in beacons:
				if b.key == key: b.t = BEACON_TIME
			continue
		_lit[key] = true
		beacons.append({"pos": c[0], "r": float(c[1]), "t": BEACON_TIME, "tick": 0.0, "key": key})
		w.metrics.ember_beacons += 1
		w.fx.append({"k": "beacon", "pos": c[0], "r": float(c[1]), "col": COL, "life": 0.5, "t": 0.0})

func _step_beacons(dt: float) -> void:
	var k := beacons.size() - 1
	while k >= 0:
		var b: Dictionary = beacons[k]
		b.t -= dt
		b.tick += dt
		while b.tick >= BEACON_TICK:
			b.tick -= BEACON_TICK
			for i in _foes_in(b.pos, float(b.r) + BEACON_R): ignite(i, 1, 0, power * BURN_DPS_K)
		if b.t <= 0.0:
			_lit.erase(b.key)
			beacons.remove_at(k)
		k -= 1

## Live, hostile foes within r of p (their bodies' reach included), as a list safe to hit while iterating.
func _foes_in(p: Vector2, r: float) -> PackedInt32Array:
	var sw := w.sw
	var c := w.grid.query(p, r, sw)
	var out := PackedInt32Array()
	for q in c:
		var i := w.grid.results[q]
		if i < sw.n and sw.hp[i] > 0.0 and (sw.flags[i] & Swarm.F_ALLY) == 0: out.append(i)
	return out
