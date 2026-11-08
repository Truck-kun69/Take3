class_name Atlas
extends RefCounted
## Node-based map grid (PoE2 Atlas). A seeded W x H lattice; each node is a map with a biome,
## tier, rolled modifiers and edges to neighbours. Completing a node reveals its neighbours.
## Corners hold Citadels (guaranteed pinnacle fragment); some nodes are Corrupted (extra mods,
## extra rewards). Generation is deterministic from the seed so the save stores only progress.

static func generate(seed_v: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var nodes: Array = []
	var W := Content.ATLAS_W
	var H := Content.ATLAS_H
	var start := Vector2i(W / 2, H / 2)
	for y in H:
		for x in W:
			var dist := absi(x - start.x) + absi(y - start.y)
			var node := {"id": y * W + x, "x": x, "y": y, "tier": 1 + dist, "biome": clampi(dist / 2 + rng.randi_range(0, 1), 0, Content.STAGES.size() - 1),
				"mods": [], "kind": "map", "done": false, "open": dist == 0}
			var nm := clampi(dist / 2 + rng.randi_range(0, 1), 0, 3)
			if dist == 0:
				nm = 0
			elif (x == 0 or x == W - 1) and (y == 0 or y == H - 1):
				node.kind = "citadel"
				nm = 3
			elif dist >= 2 and rng.randf() < 0.18:
				node.kind = "corrupted"
				nm += 2
			var pool: Array = Content.MAP_MOD_IDS.duplicate()
			for i in nm:
				if pool.is_empty(): break
				var k := rng.randi_range(0, pool.size() - 1)
				node.mods.append(pool[k])
				pool.remove_at(k)
			nodes.append(node)
	# Edges: 4-neighbour lattice with ~20% of edges removed, keeping the graph connected
	# (an edge is only removed if both endpoints keep at least 2 edges).
	var edges := {}
	for y in H:
		for x in W:
			var a := y * W + x
			if x + 1 < W: edges[_ek(a, a + 1)] = true
			if y + 1 < H: edges[_ek(a, a + W)] = true
	var deg := {}
	for e in edges:
		var ab: Array = _ed(e)
		deg[ab[0]] = deg.get(ab[0], 0) + 1
		deg[ab[1]] = deg.get(ab[1], 0) + 1
	for e in edges.keys():
		var ab: Array = _ed(e)
		if rng.randf() < 0.2 and deg[ab[0]] > 2 and deg[ab[1]] > 2:
			edges.erase(e)
			deg[ab[0]] -= 1
			deg[ab[1]] -= 1
			if not connected(nodes.size(), edges):
				edges[e] = true
				deg[ab[0]] += 1
				deg[ab[1]] += 1
	return {"seed": seed_v, "nodes": nodes, "edges": edges.keys(), "start": start.y * W + start.x}

static func _ek(a: int, b: int) -> int: return mini(a, b) * 1000 + maxi(a, b)
static func _ed(e: int) -> Array: return [e / 1000, e % 1000]

static func neighbours(atlas: Dictionary, id: int) -> Array:
	var out: Array = []
	for e in atlas.edges:
		var ab: Array = _ed(int(e))
		if ab[0] == id: out.append(ab[1])
		elif ab[1] == id: out.append(ab[0])
	return out

static func connected(count: int, edges: Dictionary) -> bool:
	var adj := {}
	for e in edges:
		var ab: Array = _ed(int(e))
		if not adj.has(ab[0]): adj[ab[0]] = []
		if not adj.has(ab[1]): adj[ab[1]] = []
		adj[ab[0]].append(ab[1]); adj[ab[1]].append(ab[0])
	var seen := {0: true}
	var stack := [0]
	while not stack.is_empty():
		var c: int = stack.pop_back()
		for nb in adj.get(c, []):
			if not seen.has(nb):
				seen[nb] = true
				stack.append(nb)
	return seen.size() == count

## Merge saved progress {done: [ids], open: [ids]} into a freshly generated atlas.
static func with_progress(seed_v: int, prog: Dictionary) -> Dictionary:
	var a := generate(seed_v)
	var done: Array = prog.get("done", [])
	var opened: Array = prog.get("open", [])
	for n in a.nodes:
		if done.has(float(n.id)) or done.has(n.id): n.done = true
		if opened.has(float(n.id)) or opened.has(n.id): n.open = true
	return a

static func complete(atlas: Dictionary, id: int) -> void:
	atlas.nodes[id].done = true
	for nb in neighbours(atlas, id):
		atlas.nodes[nb].open = true

static func progress(atlas: Dictionary) -> Dictionary:
	var done: Array = []
	var opened: Array = []
	for n in atlas.nodes:
		if n.done: done.append(n.id)
		if n.open: opened.append(n.id)
	return {"done": done, "open": opened}

## Total item quantity / rarity bonus for a node (mods + tier + corruption).
static func rewards(node: Dictionary) -> Vector2:
	var q := 0.05 * (int(node.tier) - 1)
	var r := 0.04 * (int(node.tier) - 1)
	for m in node.mods:
		q += Content.MAP_MODS[m].qty
		r += Content.MAP_MODS[m].rar
	if node.kind == "corrupted":
		q *= 1.5; r *= 1.5
	return Vector2(q, r)
