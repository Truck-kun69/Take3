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
var generated := 0

func _init(stage_i: int, seed_i: int, profile: Dictionary, flat_radius: float = 260.0) -> void:
	stage = stage_i
	tseed = seed_i
	prof = profile
	liquid = String(prof.get("liquid", "water"))
	level = float(prof.get("level", -30.0))
	flat_r = flat_radius
	flat_h = level + float(prof.get("shore", 22.0)) if liquid != "none" else 0.0
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
		h = lerpf(h, level - float(prof.get("river_depth", 26.0)), carve)
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
	for j in CN:
		for i in CN:
			var k := (j + 1) * B + i + 1
			var h := hb[k]
			hs[j * CN + i] = h
			var t := LAND
			if liquid != "none" and h < level:
				t = SHALLOW if (level - h) < deep and liquid != "void" else DEEP
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
	return (_lch[1] as PackedByteArray)[(cy - c.y * CN) * CN + (cx - c.x * CN)]

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
func move(a: Vector2, b: Vector2) -> Vector2:
	if passable(b) or not passable(a):
		return b
	var sx := Vector2(b.x, a.y)
	if passable(sx): return sx
	var sy := Vector2(a.x, b.y)
	if passable(sy): return sy
	return a

## Swarm fast path: one cell lookup when the foe stays in its cell (the common case at 16-unit cells).
## Shallows scale the whole step (knockback included) by 0.65.
func foe_move(p: Vector2, np: Vector2) -> Vector2:
	var cp := cell_of(p)
	var t := cell_type(cp.x, cp.y)
	if t == SHALLOW and not frozen.has(cp):
		np = p + (np - p) * 0.65
	if cell_of(np) == cp:
		return np
	return move(p, np)

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

func is_charged(p: Vector2) -> bool:
	return charged.has(cell_of(p))

func step(dt: float) -> void:
	for d in [frozen, charged, steam]:
		var gone := []
		for c in d:
			d[c] -= dt
			if d[c] <= 0.0: gone.append(c)
		for c in gone: d.erase(c)
		if not gone.is_empty() and d != steam: version += 1

## Prop placement rules for the renderer's scatter.
func prop_ok(kind: String, p: Vector2) -> bool:
	var c := cell_of(p)
	var t := cell_type(c.x, c.y)
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
