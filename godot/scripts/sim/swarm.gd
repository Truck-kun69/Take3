class_name Swarm
extends RefCounted
## All live foes in parallel packed arrays (structure-of-arrays). Dense: indices 0..n-1 are alive,
## removal swaps the last foe into the hole, so loops never test an "alive" flag and stay cache
## friendly. Anything that must survive a swap (pierce lists, boss references) holds `uid`, not index.
##
## Writes go through methods on this object: in GDScript, `other.packed[i] = v` copies the whole
## array (copy-on-write through a temporary), while `packed[i] = v` on self writes in place.

const CAP := 720

const F_ELITE := 1
const F_BOSS := 2
const F_BREACH := 4
const F_EXILE := 8
const F_GOBLIN := 16
const F_EVENT := 32       # counts toward an event quota (cursed chest, ritual, strongbox, delirium)
const F_ALLY := 64        # ethereal echo fighting for the player
const F_RIFTG := 128      # rift guardian
const F_HERALD := 256

var n := 0
var pos := PackedVector2Array()
var kb := PackedVector2Array()        # knockback velocity, decays
var sep := PackedVector2Array()       # separation push (CPU or GPU result)
var dir := PackedVector2Array()       # charge direction / AI scratch
var hp := PackedFloat32Array()
var mhp := PackedFloat32Array()
var shield := PackedFloat32Array()
var spd := PackedFloat32Array()
var rad := PackedFloat32Array()
var dmg := PackedFloat32Array()
var xp := PackedFloat32Array()
var flash := PackedFloat32Array()
var ai_t := PackedFloat32Array()
var ai_s := PackedInt32Array()
var kind := PackedInt32Array()
var flags := PackedInt32Array()
var affix := PackedInt32Array()
var uid := PackedInt32Array()
var tag := PackedInt32Array()         # owning event id (quota bookkeeping)
var hit_t := PackedFloat32Array()     # last blade hit time
# statuses: one stack count and one timer per DoT element, timers for the rest
var burn := PackedFloat32Array()
var burn_t := PackedFloat32Array()
var pois := PackedFloat32Array()
var pois_t := PackedFloat32Array()
var bleed := PackedFloat32Array()
var bleed_t := PackedFloat32Array()
var chill_t := PackedFloat32Array()
var shock_t := PackedFloat32Array()
var freeze_t := PackedFloat32Array()
var cond_t := PackedFloat32Array()    # superconduct (+30% damage taken)
var react_cd := PackedFloat32Array()
var ee_t := PackedFloat32Array()      # elemental equilibrium window
var ee_el := PackedInt32Array()
var dot_acc := PackedFloat32Array()

var _uid_next := 1
var uid_index: Dictionary = {}        # uid -> index (kept current across swaps)

func _init() -> void:
	for a in ["pos", "kb", "sep", "dir"]:
		var v: PackedVector2Array = get(a)
		v.resize(CAP)
		set(a, v)
	for a in ["hp", "mhp", "shield", "spd", "rad", "dmg", "xp", "flash", "ai_t", "hit_t", "burn", "burn_t", "pois", "pois_t", "bleed", "bleed_t",
			"chill_t", "shock_t", "freeze_t", "cond_t", "react_cd", "ee_t", "dot_acc"]:
		var f: PackedFloat32Array = get(a)
		f.resize(CAP)
		set(a, f)
	for a in ["ai_s", "kind", "flags", "affix", "uid", "tag", "ee_el"]:
		var p: PackedInt32Array = get(a)
		p.resize(CAP)
		set(a, p)

func clear() -> void:
	n = 0
	uid_index.clear()

func full() -> bool:
	return n >= CAP

func add(k: int, p: Vector2, h: float, s: float, r: float, d: float, x: float, fl: int, af: int) -> int:
	if n >= CAP:
		return -1
	var i := n
	n += 1
	pos[i] = p; kb[i] = Vector2.ZERO; sep[i] = Vector2.ZERO; dir[i] = Vector2.ZERO
	hp[i] = h; mhp[i] = h; shield[i] = h * 0.6 if (af & Content.Aff.SHIELDED) else 0.0
	spd[i] = s; rad[i] = r; dmg[i] = d; xp[i] = x; flash[i] = 0.0
	ai_t[i] = randf_range(1.0, 2.5); ai_s[i] = 0; kind[i] = k; flags[i] = fl; affix[i] = af; tag[i] = 0; hit_t[i] = -9.0
	burn[i] = 0.0; burn_t[i] = 0.0; pois[i] = 0.0; pois_t[i] = 0.0; bleed[i] = 0.0; bleed_t[i] = 0.0
	chill_t[i] = 0.0; shock_t[i] = 0.0; freeze_t[i] = 0.0; cond_t[i] = 0.0; react_cd[i] = 0.0; ee_t[i] = 0.0; ee_el[i] = -1; dot_acc[i] = 0.0
	uid[i] = _uid_next
	uid_index[_uid_next] = i
	_uid_next += 1
	return i

func remove(i: int) -> void:
	var l := n - 1
	uid_index.erase(uid[i])
	if i != l:
		pos[i] = pos[l]; kb[i] = kb[l]; sep[i] = sep[l]; dir[i] = dir[l]
		hp[i] = hp[l]; mhp[i] = mhp[l]; shield[i] = shield[l]; spd[i] = spd[l]; rad[i] = rad[l]; dmg[i] = dmg[l]; xp[i] = xp[l]
		flash[i] = flash[l]; ai_t[i] = ai_t[l]; ai_s[i] = ai_s[l]; kind[i] = kind[l]; flags[i] = flags[l]; affix[i] = affix[l]
		uid[i] = uid[l]; tag[i] = tag[l]; hit_t[i] = hit_t[l]
		burn[i] = burn[l]; burn_t[i] = burn_t[l]; pois[i] = pois[l]; pois_t[i] = pois_t[l]; bleed[i] = bleed[l]; bleed_t[i] = bleed_t[l]
		chill_t[i] = chill_t[l]; shock_t[i] = shock_t[l]; freeze_t[i] = freeze_t[l]; cond_t[i] = cond_t[l]; react_cd[i] = react_cd[l]
		ee_t[i] = ee_t[l]; ee_el[i] = ee_el[l]; dot_acc[i] = dot_acc[l]
		uid_index[uid[i]] = i
	n = l

func index_of(u: int) -> int:
	return uid_index.get(u, -1)

# ---------------------------------------------------------------- per-foe writes (called from World)
func set_pos(i: int, p: Vector2) -> void: pos[i] = p
func push(i: int, v: Vector2) -> void: kb[i] += v
func set_flash(i: int, v: float) -> void: flash[i] = v
func set_ai(i: int, s: int, t: float) -> void:
	ai_s[i] = s
	ai_t[i] = t
func set_dir(i: int, d: Vector2) -> void: dir[i] = d
func set_tag(i: int, t: int) -> void: tag[i] = t
func set_hit_t(i: int, t: float) -> void: hit_t[i] = t
func set_freeze(i: int, t: float) -> void: freeze_t[i] = maxf(freeze_t[i], t)
func set_cond(i: int, t: float) -> void: cond_t[i] = maxf(cond_t[i], t)
func set_react_cd(i: int, t: float) -> void: react_cd[i] = t
func set_ee(i: int, el: int, t: float) -> void:
	ee_el[i] = el
	ee_t[i] = t
func heal(i: int, amt: float) -> void: hp[i] = minf(mhp[i], hp[i] + amt)
func scale_hp(i: int, m: float) -> void:
	hp[i] *= m
	mhp[i] *= m
func set_speed(i: int, s: float) -> void: spd[i] = s
func set_flags(i: int, f: int) -> void: flags[i] = f

## Raw damage after the shield; returns the amount the shield absorbed.
func take(i: int, amt: float) -> float:
	var ab := 0.0
	if shield[i] > 0.0:
		ab = minf(shield[i], amt)
		shield[i] -= ab
		amt -= ab
	hp[i] -= amt
	flash[i] = 0.1
	return ab

## Elemental statuses. Returns true when the status was newly applied (used for reactions).
func apply_status(i: int, el: int, stacks: float, dur: float) -> void:
	match el:
		Content.El.FIRE:
			burn[i] = minf(30.0, burn[i] + stacks); burn_t[i] = maxf(burn_t[i], dur)
		Content.El.CHAOS:
			pois[i] = minf(30.0, pois[i] + stacks); pois_t[i] = maxf(pois_t[i], dur * 1.8)
		Content.El.PHYS:
			bleed[i] = minf(30.0, bleed[i] + stacks); bleed_t[i] = maxf(bleed_t[i], dur * 1.25)
		Content.El.COLD:
			chill_t[i] = maxf(chill_t[i], dur * 0.7)
		Content.El.LIGHT:
			shock_t[i] = maxf(shock_t[i], dur)

func has_status(i: int, el: int) -> bool:
	match el:
		Content.El.FIRE: return burn[i] > 0.0
		Content.El.CHAOS: return pois[i] > 0.0
		Content.El.PHYS: return bleed[i] > 0.0
		Content.El.COLD: return chill_t[i] > 0.0
		Content.El.LIGHT: return shock_t[i] > 0.0
	return false

func consume_status(i: int, el: int, frac: float = 1.0) -> void:
	match el:
		Content.El.FIRE: burn[i] *= (1.0 - frac)
		Content.El.CHAOS: pois[i] *= (1.0 - frac)
		Content.El.PHYS: bleed[i] *= (1.0 - frac)
		Content.El.COLD: chill_t[i] *= (1.0 - frac)
		Content.El.LIGHT: shock_t[i] *= (1.0 - frac)

## Damage-over-time per second currently ticking on foe i (before player scaling).
func dot_dps(i: int) -> float:
	return burn[i] * 2.4 + pois[i] * 1.4 + bleed[i] * 1.1

## Advance timers and DoTs. Returns nothing; dot damage is accumulated in dot_acc and paid out by
## World every 0.5s so damage numbers stay readable.
func tick_timers(dt: float) -> void:
	for i in n:
		if flash[i] > 0.0: flash[i] -= dt
		if react_cd[i] > 0.0: react_cd[i] -= dt
		if chill_t[i] > 0.0: chill_t[i] -= dt
		if shock_t[i] > 0.0: shock_t[i] -= dt
		if freeze_t[i] > 0.0: freeze_t[i] -= dt
		if cond_t[i] > 0.0: cond_t[i] -= dt
		if ee_t[i] > 0.0: ee_t[i] -= dt
		if burn[i] > 0.0:
			burn_t[i] -= dt
			if burn_t[i] <= 0.0: burn[i] = 0.0
		if pois[i] > 0.0:
			pois_t[i] -= dt
			if pois_t[i] <= 0.0: pois[i] = 0.0
		if bleed[i] > 0.0:
			bleed_t[i] -= dt
			if bleed_t[i] <= 0.0: bleed[i] = 0.0

## Movement toward `target`, plus separation and decaying knockback. AI states for spitters and
## chargers live in ai_s/ai_t. Returns nothing; shots requested by spitters are written into
## `shots_out` as [pos, dir, dmg] triples (flat Array) for World to spawn.
func step_move(dt: float, target: Vector2, shots_out: Array, slow_mul: float) -> void:
	var decay := maxf(0.0, 1.0 - 8.0 * dt)
	for i in n:
		var p := pos[i]
		var to := target - p
		var d := to.length()
		var m := to / d if d > 0.001 else Vector2.ZERO
		var s := spd[i] * slow_mul
		var v := m * s
		var k := kind[i]
		if freeze_t[i] > 0.0:
			v = Vector2.ZERO
		else:
			if chill_t[i] > 0.0:
				s *= 0.65
				v *= 0.65
			if (flags[i] & F_GOBLIN) != 0:
				# flee: away from the player with a sideways weave
				var side := Vector2(-m.y, m.x) * sin(ai_t[i] * 2.3 + float(uid[i]))
				v = (-m + side * 0.8).normalized() * s
				ai_t[i] += dt
			elif (flags[i] & F_ALLY) != 0:
				v = dir[i] * s        # allies steer via World
			elif k == Content.E.SPITTER:
				var pref := 1.0 if d > 250.0 else (-1.0 if d < 180.0 else 0.0)
				var sgn := 1.0 if (uid[i] & 1) == 0 else -1.0
				v = m * s * pref + Vector2(-m.y, m.x) * s * 0.6 * sgn
				ai_t[i] -= dt
				if ai_t[i] <= 0.0 and d < 430.0:
					ai_t[i] = randf_range(2.2, 2.8)
					shots_out.append(p)
					shots_out.append(m)
					shots_out.append(dmg[i])
			elif k == Content.E.CHARGER:
				ai_t[i] -= dt
				if ai_s[i] == 0:
					if d < 320.0 and ai_t[i] <= 0.0:
						ai_s[i] = 1; ai_t[i] = 0.7; dir[i] = m
				elif ai_s[i] == 1:
					v = Vector2.ZERO
					if ai_t[i] <= 0.0:
						ai_s[i] = 2; ai_t[i] = 0.5
				else:
					v = dir[i] * 380.0 * slow_mul
					if ai_t[i] <= 0.0:
						ai_s[i] = 0; ai_t[i] = randf_range(2.0, 3.5)
			if (flags[i] & (F_BOSS | F_HERALD)) == 0:
				v += sep[i]
		pos[i] = p + (v + kb[i]) * dt
		kb[i] *= decay

## CPU separation (fallback for devices without compute): each foe is pushed out of overlapping
## neighbours found through the spatial grid.
## Staggered: only foes with i % 2 == parity are solved each frame; the others keep last frame's
## push. Separation is a soft force, so 30 Hz is visually identical and halves the cost.
func cpu_separation(grid: SpatialGrid, parity: int = -1) -> void:
	var start := 0 if parity < 0 else parity
	var stride := 1 if parity < 0 else 2
	for i in range(start, n, stride):
		var p := pos[i]
		var r := rad[i]
		var push_v := Vector2.ZERO
		var c := grid.query(p, r * 1.6, self)
		var res := grid.results
		for q in c:
			var j := res[q]
			if j == i:
				continue
			var dv := p - pos[j]
			var dd := dv.length_squared()
			var rr := r + rad[j]
			if dd < rr * rr and dd > 0.0001:
				var dl := sqrt(dd)
				push_v += dv / dl * (rr - dl)
		sep[i] = push_v * 6.0

## GPU separation result, mapped by uid (the swarm may have been reordered since dispatch).
func apply_sep(out: PackedFloat32Array, uids: PackedInt32Array, count: int) -> void:
	for i in n:
		sep[i] = Vector2.ZERO
	for k in count:
		var i: int = uid_index.get(uids[k], -1)
		if i >= 0:
			sep[i] = Vector2(out[k * 2], out[k * 2 + 1])
