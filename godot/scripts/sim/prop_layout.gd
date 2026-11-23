class_name PropLayout
extends RefCounted
## The biome dressing of one 640-unit chunk, shared by the renderer (WorldView3D.dress_chunk: what is drawn)
## and the simulation (Terrain: what blocks movement). One deterministic layout per (chunk, act).
##
## Solid props (trees, dead trees, boulders and the ruins) come from their own random stream, seeded by
## (cx, cy, act) and nothing else: every graphics tier draws and collides with the same ones. Bushes, grass
## and the act's accents come from a second stream; bushes and grass scale with the tier's prop density
## (a visual setting) without moving a single solid prop.
##
##   CLUSTERS groves (2-4 trees, living or dead by the act) or outcrops (3-5 boulders, tilted with the slope),
##   each ringed by 4-6 bushes and 18-28 grass tufts (x density), scale 0.7-1.45 and any yaw;
##   LANDMARKS ruins: an arch flanked by two wall sections, a pillar beside it and bones at its foot;
##   loose grass up to the act's GRASS count (x density); the act's crystals and bones as accents.
## Nothing within SPAWN_CLEAR of the spawn point; trunks, boulders, pillars, walls and arches stay MIN_GAP
## apart; nothing in deep water or on cliffs (Terrain.prop_ok).
##
## Obstacles, circles on the ground plane whose radius and offsets scale with the prop:
##   tree, tree_dead, pillar: one, r 14, high          rock: one, r 18, low (a jump clears it)
##   wall: r 18 at -36, 0 and +36 along it, and at -18 and +18 between them, low. Three circles 36 apart
##     only touch: the notches between them caught a body walking at up to ~34 degrees into the wall and
##     held it; with the two between, only a push within ~16 degrees of straight on stops at the face.
##   arch: two posts, r 14, at -45 and +45 along its span, high; the opening between them is free
##
## Material tags (0.10.0): `solid_tags` holds one byte per obstacle circle, parallel to `solids` (which keeps
## its stride-4 [x, y, r, low] layout): WOOD (tree, tree_dead: fire beacons), STONE (rock, wall, pillar: bolt
## ricochets), ARCH (arch posts). `crystals` lists the act's crystal accents, from a stream of their own that
## no tier density touches, so the simulation can use them (lightning conduction) on every tier alike.
##
## Seeds: a deterministic 64-bit SplitMix finalizer over (c.x * 73856093) ^ (c.y * 19349663) ^
## (stage * 83492791) ^ 0x9E3779B9, salted per stream (solids, decor, accents). Engine hash() of a vector
## is not promised to stay the same across Godot builds; this is.

const CHUNK := 640.0
const CLUSTERS := Vector2i(4, 6)
const LANDMARKS := Vector2i(1, 2)
const SPAWN_CLEAR := 160.0
const MIN_GAP := 48.0
const SOLID := ["tree", "tree_dead", "rock", "pillar", "wall", "arch"]
const DEAD_SHARE := [0.25, 0.85, 0.7, 0.9, 0.5]       # per act: how many grove trees are dead
const GRASS := [220, 150, 175, 150, 160]              # per act: grass tufts a chunk at density 1
## per act: grove vs outcrop weights, and the accents scattered loose (expected count a chunk)
const ACT_PROPS := [
	{"tree": 3.0, "rock": 3.0, "crystal": 1.0, "bones": 0.5},
	{"tree": 0.8, "rock": 5.0, "crystal": 2.0, "bones": 1.5},
	{"tree": 1.2, "rock": 2.0, "crystal": 1.0, "bones": 4.0},
	{"tree": 0.3, "rock": 3.0, "crystal": 6.0, "bones": 0.3},
	{"tree": 0.9, "rock": 2.5, "crystal": 0.8, "bones": 1.5},
]
## obstacle shape per solid kind: [[offset along the prop's length, radius], ...], low (a jump clears it)
const SHAPES := {
	"tree": [[[0.0, 14.0]], false], "tree_dead": [[[0.0, 14.0]], false], "pillar": [[[0.0, 14.0]], false],
	"rock": [[[0.0, 18.0]], true],
	"wall": [[[-36.0, 18.0], [-18.0, 18.0], [0.0, 18.0], [18.0, 18.0], [36.0, 18.0]], true],
	"arch": [[[-45.0, 14.0], [45.0, 14.0]], false],
}
## the largest obstacle radius a layout can hold (18 x the 1.45 top scale)
const MAX_R := 18.0 * 1.45
## how far an obstacle circle's centre can lie outside its own chunk: a wall placed 95 units out from an arch
## 110 units in from the edge, its end circles another 36 x 1.1 along it (~25 units); trees 75 from a cluster
## 70 in (5). Terrain.props_near reaches this much further into the neighbouring chunks.
const MAX_SPILL := 25.0
## per-circle material tags (solid_tags)
const TAG_WOOD := 0
const TAG_STONE := 1
const TAG_ARCH := 2
const KIND_TAG := {"tree": TAG_WOOD, "tree_dead": TAG_WOOD, "rock": TAG_STONE, "wall": TAG_STONE, "pillar": TAG_STONE, "arch": TAG_ARCH}
const SALT_DECOR := 0x5851F42D
const SALT_ACCENT := 0x2545F491

## SplitMix64's finalizer (Steele, Lea, Flood 2014) on GDScript's wrapping 64-bit ints.
static func splitmix(x: int) -> int:
	var z := x
	z = (z ^ _shr(z, 30)) * -4658895280553007687          # 0xBF58476D1CE4E5B9
	z = (z ^ _shr(z, 27)) * -7723592293110705685          # 0x94D049BB133111EB
	return z ^ _shr(z, 31)

## Logical right shift (GDScript's >> keeps the sign).
static func _shr(z: int, n: int) -> int:
	return (z >> n) & ((1 << (64 - n)) - 1)

## The seed of one chunk's stream (0 solids, else a salt).
static func seed_of(c: Vector2i, stage: int, salt: int = 0) -> int:
	return splitmix(((c.x * 73856093) ^ (c.y * 19349663) ^ (stage * 83492791) ^ 0x9E3779B9) ^ salt)

## -> {"items": [[kind, pos: Vector2, yaw, scale, y stretch, tilt], ...],
##     "solids": PackedFloat32Array [x, y, r, low (0/1)] per circle,
##     "solid_tags": PackedByteArray, one tag per circle (TAG_WOOD / TAG_STONE / TAG_ARCH),
##     "crystals": PackedVector2Array, the crystal accents (the same with or without decor, on every tier),
##     "arches": Array of [centre: Vector2, yaw] (the landmarks)}
## `terrain` may be null (no placement rules, uniform density). `decor` false leaves out the items of bushes,
## grass and accents (the simulation needs the solids, their tags and the crystals' spots only).
static func chunk(c: Vector2i, stage: int, terrain: Terrain, density: float = 1.0, decor: bool = true) -> Dictionary:
	var st := clampi(stage, 0, 4)
	var out := {"items": [], "solids": PackedFloat32Array(), "solid_tags": PackedByteArray(), "crystals": PackedVector2Array(), "arches": []}
	var placed: Array[Vector2] = []
	var origin := Vector2(c.x * CHUNK, c.y * CHUNK)
	var rs := RandomNumberGenerator.new()
	rs.seed = seed_of(c, stage)
	var act: Dictionary = ACT_PROPS[st]
	var tree_w := float(act.tree) * (terrain.density("tree", c) if terrain != null else 1.0)
	var rock_w := float(act.rock)
	var centers: Array[Vector2] = []
	for k in rs.randi_range(CLUSTERS.x, CLUSTERS.y):
		var cp := origin + Vector2(rs.randf_range(70.0, CHUNK - 70.0), rs.randf_range(70.0, CHUNK - 70.0))
		centers.append(cp)
		if rs.randf() < tree_w / maxf(0.01, tree_w + rock_w):
			for i in rs.randi_range(2, 4):
				_put(out, placed, terrain, "tree_dead" if rs.randf() < DEAD_SHARE[st] else "tree", cp + disc(rs, 75.0), rs, false)
		else:
			for i in rs.randi_range(3, 5):
				_put(out, placed, terrain, "rock", cp + disc(rs, 60.0), rs, true)
	for k in rs.randi_range(LANDMARKS.x, LANDMARKS.y):
		var lp := origin + Vector2(rs.randf_range(110.0, CHUNK - 110.0), rs.randf_range(110.0, CHUNK - 110.0))
		var yaw := rs.randf() * TAU
		var side := Vector2(cos(yaw), -sin(yaw))                       # the arch spans along this
		if not _put(out, placed, terrain, "arch", lp, rs, false, yaw, 1.0): continue
		(out.arches as Array).append([lp, yaw])
		_put(out, placed, terrain, "wall", lp + side * 95.0, rs, false, yaw + rs.randf_range(-0.15, 0.15), rs.randf_range(0.9, 1.1))
		_put(out, placed, terrain, "wall", lp - side * 95.0, rs, false, yaw + rs.randf_range(-0.15, 0.15), rs.randf_range(0.9, 1.1))
		var pp := lp + side.orthogonal() * rs.randf_range(70.0, 100.0) * (1.0 if rs.randf() < 0.5 else -1.0)
		_put(out, placed, terrain, "pillar", pp, rs, false)
		for i in rs.randi_range(2, 3):
			_put(out, placed, terrain, "bones", pp + disc(rs, 40.0), rs, false)
	# the act's accents (crystals and loose bones), from their own stream: their count and spots never
	# depend on the tier, so the simulation may use the crystals
	var ra := RandomNumberGenerator.new()
	ra.seed = seed_of(c, stage, SALT_ACCENT)
	for kind in ["crystal", "bones"]:
		var n := float(act.get(kind, 0.0))
		for i in int(n) + (1 if ra.randf() < n - floorf(n) else 0):
			var ap := origin + Vector2(ra.randf() * CHUNK, ra.randf() * CHUNK)
			var ok_a := _accent_ok(terrain, kind, ap)                # _put's own test for a non-solid prop
			if decor: _put(out, placed, terrain, kind, ap, ra, false)
			elif ok_a: _skip_put(ra)
			if ok_a and kind == "crystal": (out.crystals as PackedVector2Array).append(ap)
	if not decor: return out
	var rd := RandomNumberGenerator.new()
	rd.seed = seed_of(c, stage, SALT_DECOR)
	for cp in centers:
		for i in roundi(rd.randi_range(4, 6) * density):
			_put(out, placed, terrain, "bush", cp + Vector2.from_angle(rd.randf() * TAU) * rd.randf_range(45.0, 115.0), rd, false)
		for i in roundi(rd.randi_range(18, 28) * density):
			_put(out, placed, terrain, "grass", cp + disc(rd, 150.0), rd, false)
	var want := roundi(GRASS[st] * density)
	var have := 0
	for it in out.items:
		if it[0] == "grass": have += 1
	var tries := 0
	while have < want and tries < want * 4:
		tries += 1
		if _put(out, placed, terrain, "grass", origin + Vector2(rd.randf() * CHUNK, rd.randf() * CHUNK), rd, false): have += 1
	return out

## Whether an accent could stand at p (the rules _put applies to a non-solid prop).
static func _accent_ok(terrain: Terrain, kind: String, p: Vector2) -> bool:
	return p.length() >= SPAWN_CLEAR and (terrain == null or terrain.prop_ok(kind, p))

## Draws exactly what _put draws for a placed non-solid prop (scale, stretch, yaw), so the accent stream
## stays in step whether or not decor items are kept.
static func _skip_put(rng: RandomNumberGenerator) -> void:
	rng.randf(); rng.randf(); rng.randf()

## The obstacle circles of one chunk (the simulation's view of chunk()).
static func solids(c: Vector2i, stage: int, terrain: Terrain) -> PackedFloat32Array:
	return chunk(c, stage, terrain, 1.0, false).solids

## The tag of every obstacle circle of one chunk, parallel to solids().
static func solid_tags(c: Vector2i, stage: int, terrain: Terrain) -> PackedByteArray:
	return chunk(c, stage, terrain, 1.0, false).solid_tags

static func disc(rng: RandomNumberGenerator, r: float) -> Vector2:
	return Vector2.from_angle(rng.randf() * TAU) * sqrt(rng.randf()) * r

## One prop at p if the spot allows it; yaw < -100 = a random one, scale 0 = the cluster range 0.7-1.45.
## A solid one also records its obstacle circles.
static func _put(out: Dictionary, placed: Array[Vector2], terrain: Terrain, kind: String, p: Vector2, rng: RandomNumberGenerator,
		tilt: bool, yaw: float = -1000.0, sc: float = 0.0) -> bool:
	if p.length() < SPAWN_CLEAR: return false
	if terrain != null and not terrain.prop_ok(kind, p): return false
	var solid := SOLID.has(kind)
	if solid:
		for q in placed:
			if q.distance_squared_to(p) < MIN_GAP * MIN_GAP: return false
		placed.append(p)
	var s := sc if sc > 0.0 else rng.randf_range(0.7, 1.45)
	var ys := rng.randf_range(0.92, 1.08)
	var y := yaw if yaw > -100.0 else rng.randf() * TAU
	(out.items as Array).append([kind, p, y, s, ys, tilt])
	if solid:
		var shape: Array = SHAPES[kind]
		var along := Vector2(cos(y), -sin(y))                          # the mesh's X axis on the ground
		var sol: PackedFloat32Array = out.solids
		var tags: PackedByteArray = out.solid_tags
		for e in shape[0]:
			var q2: Vector2 = p + along * float(e[0]) * s
			sol.append(q2.x); sol.append(q2.y); sol.append(float(e[1]) * s); sol.append(1.0 if shape[1] else 0.0)
			tags.append(int(KIND_TAG[kind]))
		out.solids = sol
		out.solid_tags = tags
	return true
