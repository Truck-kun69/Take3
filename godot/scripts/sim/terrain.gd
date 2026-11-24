class_name Terrain
extends RefCounted
## Seeded terrain for a run: heights, liquids (water, lava, void), cliffs, and transient ice and charge.
## Pure simulation, used by the sim for movement and by the renderer for the ground, water and the
## height texture every shader samples (so a foe, a spark and a telegraph all sit on the same hill).
##
## The world is cut into 640-unit chunks of 40 x 40 cells (16 units). Each cell stores the height at its
## centre and a type; gameplay heights are bilinear between cell centres, exactly as the shaders read them.
##   LAND     walkable
##   SHALLOW  walkable, slows to 65% (lava shallows burn)
##   DEEP     blocks movement unless frozen (ice over water, an obsidian crust over lava); void never freezes
##   CLIFF    slope steeper than the stage's limit: blocks movement
## Chunks are generated on demand and prefetched one per frame around the player.

const CELL := 16.0
const CN := 40
const CHUNK := 640.0
enum { LAND, SHALLOW, DEEP, CLIFF }

var stage := 0
var tseed := 0
var prof: Dictionary
var liquid := "water"            # water | lava | void | none
var level := -30.0               # liquid surface height
var flat_r := 260.0              # spawn plateau radius around the origin
var flat_h := 0.0
var _base := FastNoiseLite.new()
var _ramp := FastNoiseLite.new()
var _river := FastNoiseLite.new()
var _detail := FastNoiseLite.new()
var _chunks := {}                # Vector2i -> [PackedFloat32Array heights, PackedByteArray types]
var frozen := {}                 # Vector2i cell -> seconds left
var charged := {}                # Vector2i cell -> seconds left
var steam := {}                  # Vector2i cell -> seconds left (renderer feed: puffs)
var version := 0                 # bumps when ice/charge change, so the renderer re-uploads its state texture

# ---------------------------------------------------------------- surfaces (oil, poison, blood, fire)
# Pools poured on dry or shallow ground by the fight itself, which react with elements:
#   OIL    barrels, Act II seeps        fire ignites it (FIRE, spreading along connected oil)
#   POISON spitters' deaths             fire detonates it; cold crystallises it into SPIKES
#   BLOOD  kills (elites: big pools)    lightning arcs through every foe standing in it
# surf: cell -> [kind, seconds left]. World applies the per-tick effects and the reactions.
enum Surf { NONE, OIL, POISON, BLOOD, FIRE, SPIKES }
var surf := {}
var surf_version := 0
var generated := 0
var tide := 0.0                  # Act V: how far the liquid rises over the act (cells reclassify live)
var level0 := 0.0
var deep_d := 9.0
var _lv_mark := 0.0

func _init(stage_i: int, seed_i: int, profile: Dictionary, flat_radius: float = 260.0) -> void:
	stage = stage_i
	tseed = seed_i
	prof = profile
	liquid = String(prof.get("liquid", "water"))
	level = float(prof.get("level", -30.0))
	flat_r = flat_radius
	flat_h = level + float(prof.get("shore", 22.0)) if liquid != "none" else 0.0
	tide = float(prof.get("tide", 0.0))
	level0 = level
	_lv_mark = level
	deep_d = float(prof.get("deep", 9.0))
	for n in [_base, _ramp, _river, _detail]:
		n.noise_type = FastNoiseLite.TYPE_PERLIN
	_base.seed = tseed
	_base.frequency = 1.0 / float(prof.get("scale", 1100.0))
	_base.fractal_type = FastNoiseLite.FRACTAL_FBM
	_base.fractal_octaves = 4
	_ramp.seed = tseed + 11
	_ramp.frequency = 1.0 / 700.0
	_river.seed = tseed + 23
	_river.frequency = 1.0 / float(prof.get("river_scale", 1500.0))
	_river.fractal_type = FastNoiseLite.FRACTAL_FBM
	_river.fractal_octaves = 2
	_detail.seed = tseed + 37
	_detail.frequency = 1.0 / 140.0

# ---------------------------------------------------------------- generation
func _raw(x: float, y: float) -> float:
	var amp: float = prof.get("amp", 80.0)
	var b := clampf(_base.get_noise_2d(x, y) * 1.6, -1.0, 1.0)
	var h := b * amp
	var steps := int(prof.get("terraces", 0))
	if steps > 0:
		# terraces: plateaus joined by ramps; where the ramp noise is low the step is a cliff
		var u := (b * 0.5 + 0.5) * steps
		var f := u - floorf(u)
		var w := lerpf(0.035, 0.42, clampf(_ramp.get_noise_2d(x, y) * 1.4 + 0.5, 0.0, 1.0))
		var s := smoothstep(0.5 - w, 0.5 + w, f)
		h = ((floorf(u) + s) / steps * 2.0 - 1.0) * amp
	var rw: float = prof.get("river", 0.0)
	if rw > 0.0:
		var rv := absf(_river.get_noise_2d(x, y))
		var carve := smoothstep(rw, rw * 0.35, rv)
		h = lerpf(h, level0 - float(prof.get("river_depth", 26.0)), carve)   # river beds sit under the act's starting surface: a rising tide never reshapes the ground
	h += _detail.get_noise_2d(x, y) * float(prof.get("detail", 4.0))
	var d := sqrt(x * x + y * y)
	if d < flat_r + 220.0:
		h = lerpf(h, flat_h, smoothstep(flat_r + 220.0, flat_r, d))
	return h

func chunk(c: Vector2i) -> Array:
	var ch = _chunks.get(c)
	if ch != null:
		return ch
	# heights with a one-cell border so slopes at the chunk edge see their neighbours
	var B := CN + 2
	var hb := PackedFloat32Array()
	hb.resize(B * B)
	var x0 := c.x * CHUNK - CELL * 0.5
	var y0 := c.y * CHUNK - CELL * 0.5
	for j in B:
		for i in B:
			hb[j * B + i] = _raw(x0 + i * CELL, y0 + j * CELL)
	var hs := PackedFloat32Array()
	hs.resize(CN * CN)
	var ty := PackedByteArray()
	ty.resize(CN * CN)
	var cliff: float = prof.get("cliff", 1.15) * CELL
	var deep: float = prof.get("deep", 9.0)
	# classified against level0, the act's starting surface, never the live level: a chunk generated (or
	# regenerated after trim()) while the Act V tide is up gets the same stored types as one generated at the
	# start, so props placed on it (PropLayout, through prop_ok) and everything keyed on it stay deterministic.
	# cell_type() reclassifies against the live level while the tide is on.
	for j in CN:
		for i in CN:
			var k := (j + 1) * B + i + 1
			var h := hb[k]
			hs[j * CN + i] = h
			var t := LAND
			if liquid != "none" and h < level0:
				t = SHALLOW if (level0 - h) < deep and liquid != "void" else DEEP
			else:
				var s := maxf(maxf(absf(hb[k + 1] - h), absf(hb[k - 1] - h)), maxf(absf(hb[k + B] - h), absf(hb[k - B] - h)))
				if s > cliff:
					t = CLIFF
			ty[j * CN + i] = t
	ch = [hs, ty]
	_chunks[c] = ch
	generated += 1
	return ch

## Generates at most `budget` missing chunks within `r` chunks of `p` (call every frame).
func prefetch(p: Vector2, r: int = 3, budget: int = 1) -> void:
	var cc := Vector2i(floori(p.x / CHUNK), floori(p.y / CHUNK))
	for ring in r + 1:
		for dy in range(-ring, ring + 1):
			for dx in range(-ring, ring + 1):
				if maxi(absi(dx), absi(dy)) != ring: continue
				var c := cc + Vector2i(dx, dy)
				if not _chunks.has(c):
					chunk(c)
					budget -= 1
					if budget <= 0: return

## Drops chunks far from the player (memory stays bounded on long runs).
func trim(p: Vector2, keep: int = 6) -> void:
	_lc = Vector2i(1 << 30, 0)
	var cc := Vector2i(floori(p.x / CHUNK), floori(p.y / CHUNK))
	for c in _chunks.keys():
		if maxi(absi(c.x - cc.x), absi(c.y - cc.y)) > keep:
			_chunks.erase(c)
	for c in _prop_chunks.keys():
		if maxi(absi(c.x - cc.x), absi(c.y - cc.y)) > keep:
			_prop_chunks.erase(c)
			_prop_tags.erase(c)
			_prop_crystals.erase(c)
	var per := int(CHUNK / PCELL)
	for cell in _prop_cells.keys():
		if maxi(absi(floori(float(cell.x) / per) - cc.x), absi(floori(float(cell.y) / per) - cc.y)) > keep:
			_prop_cells.erase(cell)
			_prop_cell_tags.erase(cell)

# ---------------------------------------------------------------- queries
func cell_of(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x / CELL), floori(p.y / CELL))

func _cell_h(cx: int, cy: int) -> float:
	var c := Vector2i(floori(float(cx) / CN), floori(float(cy) / CN))
	var ch: Array = chunk(c)
	return (ch[0] as PackedFloat32Array)[(cy - c.y * CN) * CN + (cx - c.x * CN)]

var _lc := Vector2i(1 << 30, 0)
var _lch: Array
func cell_type(cx: int, cy: int) -> int:
	var c := Vector2i(floori(float(cx) / CN), floori(float(cy) / CN))
	if c != _lc:                                      # most queries in a frame hit the same chunk
		_lch = chunk(c)
		_lc = c
	var k := (cy - c.y * CN) * CN + (cx - c.x * CN)
	var t: int = (_lch[1] as PackedByteArray)[k]
	if tide > 0.0 and t != CLIFF:                     # rising water: classify against the current level
		var h: float = (_lch[0] as PackedFloat32Array)[k]
		t = LAND if h >= level else (SHALLOW if level - h < deep_d else DEEP)
	return t

## Ground height: bilinear between cell centres (the shaders do the same with the height texture).
func height(p: Vector2) -> float:
	var fx := p.x / CELL - 0.5
	var fy := p.y / CELL - 0.5
	var ix := floori(fx)
	var iy := floori(fy)
	var tx := fx - ix
	var ty := fy - iy
	var a := lerpf(_cell_h(ix, iy), _cell_h(ix + 1, iy), tx)
	var b := lerpf(_cell_h(ix, iy + 1), _cell_h(ix + 1, iy + 1), tx)
	return lerpf(a, b, ty)

## The stored type of a cell, classified against level0 (no live tide): what prop placement reads.
func static_type(cx: int, cy: int) -> int:
	var c := Vector2i(floori(float(cx) / CN), floori(float(cy) / CN))
	var ch: Array = chunk(c)
	return (ch[1] as PackedByteArray)[(cy - c.y * CN) * CN + (cx - c.x * CN)]

func type_at(p: Vector2) -> int:
	var c := cell_of(p)
	return cell_type(c.x, c.y)

func is_liquid(p: Vector2) -> bool:
	var t := type_at(p)
	return t == SHALLOW or t == DEEP

func is_frozen(p: Vector2) -> bool:
	return frozen.has(cell_of(p))

func passable(p: Vector2) -> bool:
	var c := cell_of(p)
	var t := cell_type(c.x, c.y)
	if t == LAND or t == SHALLOW: return true
	if t == DEEP: return frozen.has(c)
	return false

## Moves from `a` toward `b`, sliding along walls; anything already stuck may always move (escape).
## With a body radius, solid props push the body out as well (props_resolve); a push that would put it
## on a cliff or in deep water keeps it where it was. A step longer than the body's radius is taken in
## sub-steps of at most that radius, so a fast body (a dash, a long tick) cannot pass through a trunk
## whose far side it would otherwise be pushed out of.
func move(a: Vector2, b: Vector2, body_r: float = 0.0) -> Vector2:
	if body_r <= 0.0 or not props_on: return _move_cells(a, b)
	var d := b - a
	if d.length_squared() <= body_r * body_r: return _move_step(a, b, body_r)
	var n := ceili(d.length() / body_r)
	var p := a
	for k in n:
		var q := _move_step(p, p + d / n, body_r)
		if q == p: break                                   # blocked: the rest of the step would be too
		p = q
	return p

func _move_step(a: Vector2, b: Vector2, body_r: float) -> Vector2:
	var q := _move_cells(a, b)
	var r := props_resolve(q, body_r)
	if r != q and not passable(r) and passable(q): return a
	return r

func _move_cells(a: Vector2, b: Vector2) -> Vector2:
	if passable(b) or not passable(a):
		return b
	var sx := Vector2(b.x, a.y)
	if passable(sx): return sx
	var sy := Vector2(a.x, b.y)
	if passable(sy): return sy
	return a

## Swarm fast path: one cell lookup when the foe stays in its cell (the common case at 16-unit cells).
## Shallows scale the whole step (knockback included) by 0.65. A body radius adds the solid props, with
## move()'s guard: a prop never shoves a foe onto a cliff or into deep water. A step longer than the body's
## radius (a charger's dash, a hard knockback) is sub-stepped like move()'s.
func foe_move(p: Vector2, np: Vector2, body_r: float = 0.0) -> Vector2:
	var cp := Vector2i(floori(p.x / CELL), floori(p.y / CELL))
	# cell_type(cp.x, cp.y), inlined (0.10.4): the same chunk cache and the same live tide reclassification
	var cc := Vector2i(floori(float(cp.x) / CN), floori(float(cp.y) / CN))
	if cc != _lc:
		_lch = chunk(cc)
		_lc = cc
	var ck := (cp.y - cc.y * CN) * CN + (cp.x - cc.x * CN)
	var t: int = (_lch[1] as PackedByteArray)[ck]
	if tide > 0.0 and t != CLIFF:
		var h: float = (_lch[0] as PackedFloat32Array)[ck]
		t = LAND if h >= level else (SHALLOW if level - h < deep_d else DEEP)
	if t == SHALLOW and not frozen.has(cp):
		np = p + (np - p) * 0.65
	if body_r <= 0.0 or not props_on:
		return np if cell_of(np) == cp else _move_cells(p, np)
	var d := np - p
	if d.length_squared() <= body_r * body_r:
		# _foe_step inlined for the one-step case (nearly every foe, every tick; 0.10.4)
		var q := np if (floori(np.x / CELL) == cp.x and floori(np.y / CELL) == cp.y) else _move_cells(p, np)
		if _prop_test_on: return _foe_step(p, np, body_r)
		var pa = _prop_cells.get(Vector2i(floori(q.x * INV_PCELL), floori(q.y * INV_PCELL)))
		if pa == null: return _foe_step(p, np, body_r)          # the first visit files the cell's circles
		if (pa as PackedFloat32Array).is_empty(): return q       # open ground: nothing to push out of
		var r := _resolve_circles(q, body_r, false, pa)
		if r != q and not passable(r) and passable(q): return p
		return r
	var n := ceili(d.length() / body_r)
	var at := p
	for k in n:
		var q := _foe_step(at, at + d / n, body_r)
		if q == at: break
		at = q
	return at

func _foe_step(p: Vector2, np: Vector2, body_r: float) -> Vector2:
	var q := np if (floori(np.x / CELL) == floori(p.x / CELL) and floori(np.y / CELL) == floori(p.y / CELL)) else _move_cells(p, np)
	# no prop circle reaches q's cell (open ground, the common case): props_resolve would return q as it is
	if not _prop_test_on:
		var pa = _prop_cells.get(Vector2i(floori(q.x * INV_PCELL), floori(q.y * INV_PCELL)))
		if pa != null and (pa as PackedFloat32Array).is_empty(): return q
	var r := props_resolve(q, body_r)
	if r != q and not passable(r) and passable(q): return p
	return r

# ---------------------------------------------------------------- solid props (PropLayout)
## Trees, boulders and ruins block walking, rolling and the swarm. Each chunk's obstacle circles come
## from PropLayout (the same layout the renderer draws) on first use, and are filed in PCELL cells: a cell
## holds every circle within PROP_REACH of it, so a body of up to that radius looks at its own cell only.
## Low circles (boulders, walls) a jump clears; a landing inside any circle is refused (World.jump_landing).
const PCELL := 64.0
const INV_PCELL := 1.0 / PCELL
const PROP_REACH := 48.0          # the largest body radius that collides with props (swarm foes reach ~34)
var props_on := true              # off: nothing blocks (menus, some tests)
var _prop_chunks := {}            # Vector2i chunk -> PackedFloat32Array of its circles [x, y, r, low] x n
var _prop_tags := {}              # Vector2i chunk -> PackedByteArray: each circle's tag (PropLayout.TAG_*)
var _prop_crystals := {}          # Vector2i chunk -> PackedVector2Array: its crystal accents
var _prop_cells := {}             # Vector2i PCELL cell -> PackedFloat32Array of the circles reaching it
var _prop_cell_tags := {}         # Vector2i PCELL cell -> PackedByteArray, parallel to _prop_cells
var _prop_test := PackedFloat32Array()
var _prop_test_tags := PackedByteArray()
var _prop_test_on := false

func _prop_chunk(c: Vector2i) -> PackedFloat32Array:
	if not _prop_chunks.has(c):
		var lay := PropLayout.chunk(c, stage, self, 1.0, false)
		_prop_chunks[c] = lay.solids
		_prop_tags[c] = lay.solid_tags
		_prop_crystals[c] = lay.crystals
	return _prop_chunks[c]

## The circles [x, y, r, low] x n that a body of radius <= PROP_REACH anywhere in p's cell can touch.
## Circles of neighbouring chunks count too: a chunk's circle can lie up to PropLayout.MAX_SPILL outside it.
func props_near(p: Vector2) -> PackedFloat32Array:
	if _prop_test_on: return _prop_test
	var cell := Vector2i(floori(p.x * INV_PCELL), floori(p.y * INV_PCELL))
	var hit = _prop_cells.get(cell)                 # one lookup: every foe asks every tick
	if hit != null: return hit
	var x0 := cell.x * PCELL
	var y0 := cell.y * PCELL
	var m := PROP_REACH + PropLayout.MAX_R + PropLayout.MAX_SPILL
	var out := PackedFloat32Array()
	var tags := PackedByteArray()
	for cx in range(floori((x0 - m) / CHUNK), floori((x0 + PCELL + m) / CHUNK) + 1):
		for cy in range(floori((y0 - m) / CHUNK), floori((y0 + PCELL + m) / CHUNK) + 1):
			var a := _prop_chunk(Vector2i(cx, cy))
			var ta: PackedByteArray = _prop_tags[Vector2i(cx, cy)]
			for j in range(0, a.size(), 4):
				var reach := a[j + 2] + PROP_REACH
				if a[j] + reach < x0 or a[j] - reach > x0 + PCELL or a[j + 1] + reach < y0 or a[j + 1] - reach > y0 + PCELL: continue
				out.append(a[j]); out.append(a[j + 1]); out.append(a[j + 2]); out.append(a[j + 3])
				tags.append(ta[j / 4])
	_prop_cells[cell] = out
	_prop_cell_tags[cell] = tags
	return out

## The tags of props_near(p)'s circles, in the same order (one byte per circle).
func props_near_tags(p: Vector2) -> PackedByteArray:
	if _prop_test_on: return _prop_test_tags
	props_near(p)
	return _prop_cell_tags[Vector2i(floori(p.x * INV_PCELL), floori(p.y * INV_PCELL))]

## Crystal accents within r of p (PropLayout's own stream: the same on every tier).
func crystals_near(p: Vector2, r: float) -> int:
	var n := 0
	var cc := Vector2i(floori(p.x / CHUNK), floori(p.y / CHUNK))
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var c := cc + Vector2i(dx, dy)
			if not _prop_crystals.has(c): _prop_chunk(c)
			for q in (_prop_crystals[c] as PackedVector2Array):
				if q.distance_squared_to(p) <= r * r: n += 1
	return n

## A body of radius br at p pushed out of the prop circles around it, along each circle's normal to its
## edge (centre + direction * (r + br)); two passes, so a body wedged between two circles settles against
## both. A body moving into a circle off its centre keeps the sideways part of its step: it slides round.
## skip_low: boulders and walls do not count.
func props_resolve(p: Vector2, br: float, skip_low: bool = false) -> Vector2:
	if not props_on: return p
	return _resolve_circles(p, br, skip_low, props_near(p))

## props_resolve's work, given the circles of p's cell (foe_move has already looked them up).
func _resolve_circles(p: Vector2, br: float, skip_low: bool, a: PackedFloat32Array) -> Vector2:
	var n := a.size()
	if n == 0: return p
	var cell := Vector2i(floori(p.x * INV_PCELL), floori(p.y * INV_PCELL))
	for it in 2:
		if it == 1:
			# the first pass may have pushed the body into another cell, whose circles it must see now
			var c2 := Vector2i(floori(p.x * INV_PCELL), floori(p.y * INV_PCELL))
			if c2 != cell:
				cell = c2
				a = props_near(p)
				n = a.size()
		var moved := false
		for j in range(0, n, 4):
			if skip_low and a[j + 3] > 0.5: continue
			var dx := p.x - a[j]
			var dy := p.y - a[j + 1]
			var rr := a[j + 2] + br
			var d2 := dx * dx + dy * dy
			if d2 >= rr * rr: continue
			var d := sqrt(d2)
			if d < 1e-4: p = Vector2(a[j] + rr, a[j + 1])
			else: p = Vector2(a[j] + dx / d * rr, a[j + 1] + dy / d * rr)
			moved = true
		if not moved: break
	return p

## Whether a body of radius br at p is clear of every prop circle (low ones too).
func props_clear(p: Vector2, br: float) -> bool:
	if not props_on: return true
	var a := props_near(p)
	for j in range(0, a.size(), 4):
		var dx := p.x - a[j]
		var dy := p.y - a[j + 1]
		var rr := a[j + 2] + br
		if dx * dx + dy * dy < rr * rr: return false
	return true

## Whether a body of radius br can fly straight from a to b: no high circle (trunk, pillar, arch post)
## within reach of the segment. Boulders and walls are low: a jump clears them. Sampled every half cell,
## which PROP_REACH's margin over br covers.
func props_path_clear(a: Vector2, b: Vector2, br: float) -> bool:
	if not props_on: return true
	var ab := b - a
	var l2 := maxf(1e-6, ab.length_squared())
	var steps := maxi(1, ceili(sqrt(l2) / (PCELL * 0.5)))
	for k in steps + 1:
		var arr := props_near(a + ab * (float(k) / steps))
		for j in range(0, arr.size(), 4):
			if arr[j + 3] > 0.5: continue
			var c := Vector2(arr[j], arr[j + 1])
			var t := clampf((c - a).dot(ab) / l2, 0.0, 1.0)
			# the nearest point is the start and the path leads away from the circle: a jump off a trunk the hero
			# is touching is a jump away from it, not into it
			if t == 0.0 and ab.dot(a - c) > 0.0: continue
			var rr := arr[j + 2] + br
			if c.distance_squared_to(a + ab * t) < rr * rr: return false
	return true

## Every prop circle overlapping the disc (p, r): [[centre, radius, low, tag], ...] (tag PropLayout.TAG_*).
## Whole chunks are read (cached), so this is for one-off area effects (Contagion's beacons), not per foe.
func props_in(p: Vector2, r: float) -> Array:
	var out: Array = []
	if not props_on: return out
	if _prop_test_on:
		for j in range(0, _prop_test.size(), 4):
			var rr := _prop_test[j + 2] + r
			var c := Vector2(_prop_test[j], _prop_test[j + 1])
			if c.distance_squared_to(p) < rr * rr: out.append([c, _prop_test[j + 2], _prop_test[j + 3] > 0.5, _prop_test_tags[j / 4]])
		return out
	var m := r + PropLayout.MAX_R
	for cx in range(floori((p.x - m) / CHUNK), floori((p.x + m) / CHUNK) + 1):
		for cy in range(floori((p.y - m) / CHUNK), floori((p.y + m) / CHUNK) + 1):
			var ck := Vector2i(cx, cy)
			var a := _prop_chunk(ck)
			var ta: PackedByteArray = _prop_tags[ck]
			for j in range(0, a.size(), 4):
				var rr2 := a[j + 2] + r
				var c2 := Vector2(a[j], a[j + 1])
				if c2.distance_squared_to(p) < rr2 * rr2: out.append([c2, a[j + 2], a[j + 3] > 0.5, ta[j / 4]])
	return out

## Whether a body of radius br flying straight from a to b passes over a low circle (a boulder or wall it
## clears): the Warden's vault (World._jump). Sampled like props_path_clear.
func props_path_low(a: Vector2, b: Vector2, br: float) -> bool:
	if not props_on: return false
	var ab := b - a
	var l2 := maxf(1e-6, ab.length_squared())
	var steps := maxi(1, ceili(sqrt(l2) / (PCELL * 0.5)))
	for k in steps + 1:
		var arr := props_near(a + ab * (float(k) / steps))
		for j in range(0, arr.size(), 4):
			if arr[j + 3] < 0.5: continue
			var c := Vector2(arr[j], arr[j + 1])
			var t := clampf((c - a).dot(ab) / l2, 0.0, 1.0)
			if t <= 0.0 or t >= 1.0: continue              # beside the take-off or the landing, not under the flight
			var rr := arr[j + 2] + br
			if c.distance_squared_to(a + ab * t) < rr * rr: return true
	return false

## Tests: exactly these circles [x, y, r, low] x n block, instead of the layout. `tags` (one per circle,
## PropLayout.TAG_*) defaults to STONE for low circles and WOOD for high ones.
func set_test_props(circles: PackedFloat32Array, tags: PackedByteArray = PackedByteArray()) -> void:
	_prop_test = circles
	if tags.size() != circles.size() / 4:
		tags = PackedByteArray()
		for j in range(0, circles.size(), 4): tags.append(PropLayout.TAG_STONE if circles[j + 3] > 0.5 else PropLayout.TAG_WOOD)
	_prop_test_tags = tags
	_prop_test_on = true

func speed_mul(p: Vector2) -> float:
	var c := cell_of(p)
	return 0.65 if cell_type(c.x, c.y) == SHALLOW and not frozen.has(c) else 1.0

## Shallow lava burns (damage per second, scaled by the caller).
func burns(p: Vector2) -> bool:
	return liquid == "lava" and type_at(p) == SHALLOW and not is_frozen(p)

## Nearest passable point (spawns, knockback landings): spirals outward over cells.
func nearest_passable(p: Vector2, max_r: float = 240.0) -> Vector2:
	if passable(p): return p
	var r := CELL
	while r <= max_r:
		for k in 12:
			var a := TAU * k / 12.0
			var q := p + Vector2(cos(a), sin(a)) * r
			if passable(q): return q
		r += CELL
	return p

# ---------------------------------------------------------------- elemental terrain reactions
## Cold over water or lava: ice / an obsidian crust you can walk on. Returns cells frozen.
func freeze(p: Vector2, r: float, secs: float) -> int:
	if liquid == "void" or liquid == "none": return 0
	var n := 0
	var c0 := cell_of(p)
	var cr := int(ceilf(r / CELL))
	for dy in range(-cr, cr + 1):
		for dx in range(-cr, cr + 1):
			if dx * dx + dy * dy > cr * cr: continue
			var c := c0 + Vector2i(dx, dy)
			var t := cell_type(c.x, c.y)
			if t == SHALLOW or t == DEEP:
				frozen[c] = maxf(float(frozen.get(c, 0.0)), secs)
				n += 1
	if n > 0: version += 1
	return n

## Lightning into water: charges the water near the strike (the sim chains damage through it).
func electrify(p: Vector2, r: float, secs: float) -> int:
	if liquid != "water": return 0
	var n := 0
	var c0 := cell_of(p)
	var cr := int(ceilf(r / CELL))
	for dy in range(-cr, cr + 1):
		for dx in range(-cr, cr + 1):
			if dx * dx + dy * dy > cr * cr: continue
			var c := c0 + Vector2i(dx, dy)
			var t := cell_type(c.x, c.y)
			if (t == SHALLOW or t == DEEP) and not frozen.has(c):
				charged[c] = maxf(float(charged.get(c, 0.0)), secs)
				n += 1
	if n > 0: version += 1
	return n

## Fire onto ice melts it in a puff of steam; fire into water raises steam.
func scald(p: Vector2, r: float) -> int:
	if liquid != "water": return 0
	var n := 0
	var c0 := cell_of(p)
	var cr := int(ceilf(r / CELL))
	for dy in range(-cr, cr + 1):
		for dx in range(-cr, cr + 1):
			if dx * dx + dy * dy > cr * cr: continue
			var c := c0 + Vector2i(dx, dy)
			var t := cell_type(c.x, c.y)
			if t == SHALLOW or t == DEEP:
				if frozen.erase(c): n += 1
				steam[c] = 1.2
	if n > 0: version += 1
	return n

func surf_at(p: Vector2) -> int:
	var s = surf.get(cell_of(p))
	return int(s[0]) if s != null else Surf.NONE

## Pours a pool (a disc of cells) on land or shallows; never over fire or spikes, never on cliffs/deep.
func pour(p: Vector2, r: float, kind: int, secs: float) -> int:
	var n := 0
	var c0 := cell_of(p)
	var cr := int(ceilf(r / CELL))
	for dy in range(-cr, cr + 1):
		for dx in range(-cr, cr + 1):
			if dx * dx + dy * dy > cr * cr: continue
			var c := c0 + Vector2i(dx, dy)
			var t := cell_type(c.x, c.y)
			if t == CLIFF or t == DEEP: continue
			var cur = surf.get(c)
			if cur != null and int(cur[0]) in [Surf.FIRE, Surf.SPIKES]: continue
			surf[c] = [kind, maxf(secs, float(cur[1]) if cur != null and int(cur[0]) == kind else 0.0)]
			n += 1
	if n > 0: surf_version += 1
	return n

## Cells of `kind` within r of p become `to` for `secs` (ignite oil, crystallise poison). Returns the count.
func convert(p: Vector2, r: float, kind: int, to: int, secs: float) -> int:
	var n := 0
	var c0 := cell_of(p)
	var cr := int(ceilf(r / CELL))
	for dy in range(-cr, cr + 1):
		for dx in range(-cr, cr + 1):
			var c := c0 + Vector2i(dx, dy)
			var s = surf.get(c)
			if s != null and int(s[0]) == kind and dx * dx + dy * dy <= cr * cr:
				surf[c] = [to, secs]
				n += 1
	if n > 0: surf_version += 1
	return n

## Removes `kind` within r (a detonated poison pool is spent).
func clear_surf(p: Vector2, r: float, kind: int) -> void:
	var c0 := cell_of(p)
	var cr := int(ceilf(r / CELL))
	for dy in range(-cr, cr + 1):
		for dx in range(-cr, cr + 1):
			var c := c0 + Vector2i(dx, dy)
			var s = surf.get(c)
			if s != null and int(s[0]) == kind: surf.erase(c)
	surf_version += 1

var _spread_t := 0.0
func _step_surf(dt: float) -> void:
	if surf.is_empty(): return
	var gone := []
	for c in surf:
		surf[c][1] -= dt
		if surf[c][1] <= 0.0: gone.append(c)
	for c in gone: surf.erase(c)
	if not gone.is_empty(): surf_version += 1
	# fire creeps along connected oil, a cell every 0.12 s
	_spread_t += dt
	if _spread_t < 0.12: return
	_spread_t = 0.0
	var lit := []
	for c in surf:
		if int(surf[c][0]) != Surf.FIRE: continue
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var s = surf.get(c + d)
			if s != null and int(s[0]) == Surf.OIL: lit.append(c + d)
	for c in lit: surf[c] = [Surf.FIRE, 4.0]
	if not lit.is_empty(): surf_version += 1

func is_charged(p: Vector2) -> bool:
	return charged.has(cell_of(p))

func step(dt: float) -> void:
	_step_surf(dt)
	for d in [frozen, charged, steam]:
		var gone := []
		for c in d:
			d[c] -= dt
			if d[c] <= 0.0: gone.append(c)
		for c in gone: d.erase(c)
		if not gone.is_empty() and d != steam: version += 1

## Raises (or lowers) the liquid surface; the renderer re-reads it every frame.
func set_level(l: float) -> void:
	level = l
	if absf(level - _lv_mark) >= 1.0:
		_lv_mark = level
		version += 1

## Prop placement rules for PropLayout (the renderer's scatter and the simulation's obstacles). Read against
## the stored types (level0), never the live Act V tide, so a layout never depends on when it is built.
func prop_ok(kind: String, p: Vector2) -> bool:
	var c := cell_of(p)
	var t := static_type(c.x, c.y)
	if t == DEEP or t == CLIFF: return false
	if t == SHALLOW: return kind == "rock" or kind == "grass" and liquid == "water"
	return true

## Per-chunk density multiplier: forests cluster where the base noise is high and dry.
func density(kind: String, c: Vector2i) -> float:
	var p := (Vector2(c) + Vector2(0.5, 0.5)) * CHUNK
	if kind == "tree":
		return clampf(1.0 + _ramp.get_noise_2d(p.x * 0.6, p.y * 0.6) * 2.2, 0.15, 2.6)
	return 1.0

## Fraction of each type over an area (tests and tuning).
func survey(center: Vector2, half: float) -> Dictionary:
	var cnt := [0, 0, 0, 0]
	var x := center.x - half
	while x < center.x + half:
		var y := center.y - half
		while y < center.y + half:
			cnt[type_at(Vector2(x, y))] += 1
			y += CELL
		x += CELL
	var tot := float(cnt[0] + cnt[1] + cnt[2] + cnt[3])
	return {"land": cnt[0] / tot, "shallow": cnt[1] / tot, "deep": cnt[2] / tot, "cliff": cnt[3] / tot}
