class_name SpatialGrid
extends RefCounted
## Hashed uniform grid rebuilt every frame (O(n)). Buckets are singly linked lists in two flat
## arrays, so building allocates nothing. The world is unbounded, so cells hash into a fixed table;
## hash collisions only cost a few extra distance checks. A stamp array de-duplicates results
## when two cells collide into the same bucket.

const TABLE := 4096
const MASK := TABLE - 1
var cell := 64.0
var inv := 1.0 / 64.0
var head := PackedInt32Array()
var next := PackedInt32Array()
var stamp := PackedInt32Array()
var results := PackedInt32Array()
var _q := 0

func _init() -> void:
	head.resize(TABLE)
	head.fill(-1)                # an unbuilt grid must read as empty, not as a self-loop on foe 0
	next.resize(Swarm.CAP)
	next.fill(-1)
	stamp.resize(Swarm.CAP)
	results.resize(Swarm.CAP)

static func _h(cx: int, cy: int) -> int:
	return ((cx * 73856093) ^ (cy * 19349663)) & MASK

func build(sw: Swarm) -> void:
	head.fill(-1)
	var pos := sw.pos
	for i in sw.n:
		var p := pos[i]
		var b := _h(floori(p.x * inv), floori(p.y * inv))
		next[i] = head[b]
		head[b] = i

## Fills `results[0..count)` with indices of foes whose centre lies within r (+ their radius) of p.
func query(p: Vector2, r: float, sw: Swarm) -> int:
	_q += 1
	var c := 0
	var pos := sw.pos
	var rad := sw.rad
	var x0 := floori((p.x - r - 24.0) * inv)
	var x1 := floori((p.x + r + 24.0) * inv)
	var y0 := floori((p.y - r - 24.0) * inv)
	var y1 := floori((p.y + r + 24.0) * inv)
	for cx in range(x0, x1 + 1):
		for cy in range(y0, y1 + 1):
			var i := head[_h(cx, cy)]
			while i >= 0:
				if stamp[i] != _q:
					stamp[i] = _q
					var rr := r + rad[i]
					if p.distance_squared_to(pos[i]) <= rr * rr:
						results[c] = i
						c += 1
				i = next[i]
	return c

## Nearest foe to p within max_d that passes `mask_out` (flags it must NOT have). -1 if none.
func nearest(p: Vector2, max_d: float, sw: Swarm, mask_out: int = Swarm.F_ALLY) -> int:
	var c := query(p, max_d, sw)
	var best := -1
	var bd := INF
	for q in c:
		var i := results[q]
		if (sw.flags[i] & mask_out) != 0:
			continue
		var d := p.distance_squared_to(sw.pos[i])
		if d < bd:
			bd = d
			best = i
	return best
