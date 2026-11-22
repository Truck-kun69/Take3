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

## -> {"items": [[kind, pos: Vector2, yaw, scale, y stretch, tilt], ...],
##     "solids": PackedFloat32Array [x, y, r, low (0/1)] per circle}
## `terrain` may be null (no placement rules, uniform density). `decor` false skips bushes, grass and
## accents (the simulation needs only the solids).
static func chunk(c: Vector2i, stage: int, terrain: Terrain, density: float = 1.0, decor: bool = true) -> Dictionary:
	var st := clampi(stage, 0, 4)
	var out := {"items": [], "solids": PackedFloat32Array()}
	var placed: Array[Vector2] = []
	var origin := Vector2(c.x * CHUNK, c.y * CHUNK)
	var rs := RandomNumberGenerator.new()
	rs.seed = hash(Vector3i(c.x, c.y, stage))
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
		_put(out, placed, terrain, "wall", lp + side * 95.0, rs, false, yaw + rs.randf_range(-0.15, 0.15), rs.randf_range(0.9, 1.1))
		_put(out, placed, terrain, "wall", lp - side * 95.0, rs, false, yaw + rs.randf_range(-0.15, 0.15), rs.randf_range(0.9, 1.1))
		var pp := lp + side.orthogonal() * rs.randf_range(70.0, 100.0) * (1.0 if rs.randf() < 0.5 else -1.0)
		_put(out, placed, terrain, "pillar", pp, rs, false)
		for i in rs.randi_range(2, 3):
			_put(out, placed, terrain, "bones", pp + disc(rs, 40.0), rs, false)
	if not decor: return out
	var rd := RandomNumberGenerator.new()
	rd.seed = hash(Vector4i(c.x, c.y, stage, 7))
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
	for kind in ["crystal", "bones"]:                                 # the act's accents
		var n := float(act.get(kind, 0.0))
		for i in int(n) + (1 if rd.randf() < n - floorf(n) else 0):
			_put(out, placed, terrain, kind, origin + Vector2(rd.randf() * CHUNK, rd.randf() * CHUNK), rd, false)
	return out

## The obstacle circles of one chunk (the simulation's view of chunk()).
static func solids(c: Vector2i, stage: int, terrain: Terrain) -> PackedFloat32Array:
	return chunk(c, stage, terrain, 1.0, false).solids

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
		for e in shape[0]:
			var q2: Vector2 = p + along * float(e[0]) * s
			sol.append(q2.x); sol.append(q2.y); sol.append(float(e[1]) * s); sol.append(1.0 if shape[1] else 0.0)
		out.solids = sol
	return true
