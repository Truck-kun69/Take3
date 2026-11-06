class_name Models
extends RefCounted
## Model library with drop-in override slots.
##
## Every visual asks this class first for an authored asset and falls back to a procedural one:
##   res://models/heroes/<warden|spark|ember|storm>.(tscn|glb)  -> replaces the hero rig
##   res://models/bosses/<boss|herald|guardian>.(tscn|glb)      -> replaces a boss rig
##   res://models/foes/<grunt|runner|...>.(glb|tscn|tres)       -> first mesh found is instanced for the swarm
##   res://models/props/<rock|tree|crystal|pillar|bones|grass>.(glb|tscn|tres)
## Authored hero/boss scenes may contain an AnimationPlayer with any of: idle, run, cast, roll, hit, die.
## The rigs then play those instead of the procedural animation (see HeroRig.attach_override).

const FOE_KINDS := ["grunt", "runner", "brute", "spitter", "splitter", "mini", "charger", "breach", "goblin", "exile", "boss", "herald"]
const PROP_KINDS := ["rock", "tree", "crystal", "pillar", "bones", "grass"]

static var _cache := {}

static func find_asset(dir: String, id: String) -> String:
	for ext in ["tscn", "glb", "gltf", "tres", "res"]:
		var p := "res://models/%s/%s.%s" % [dir, id, ext]
		if ResourceLoader.exists(p):
			return p
	return ""

## First Mesh inside an authored scene/mesh resource, or null.
static func mesh_from_asset(path: String) -> Mesh:
	var r = load(path)
	if r is Mesh:
		return r
	if r is PackedScene:
		var n: Node = r.instantiate()
		var m := _first_mesh(n)
		n.free()
		return m
	return null

static func _first_mesh(n: Node) -> Mesh:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		return (n as MeshInstance3D).mesh
	for c in n.get_children():
		var m := _first_mesh(c)
		if m != null: return m
	return null

static func foe_mesh(kind: String) -> Mesh:
	var key := "foe:" + kind
	if _cache.has(key): return _cache[key]
	var p := find_asset("foes", kind)
	var m: Mesh = mesh_from_asset(p) if p != "" else _build_foe(kind)
	_cache[key] = m
	return m

static func prop_mesh(kind: String) -> Mesh:
	var key := "prop:" + kind
	if _cache.has(key): return _cache[key]
	var p := find_asset("props", kind)
	var m: Mesh = mesh_from_asset(p) if p != "" else _build_prop(kind)
	_cache[key] = m
	return m

# ================================================================= procedural foes (radius 1, feet at y 0)
static func _build_foe(kind: String) -> ArrayMesh:
	var k := MeshKit.new()
	var skin := Color(0.92, 0.92, 0.92)
	var dark := Color(0.35, 0.33, 0.38)
	var crys := Color(0.75, 0.9, 1.0)
	var eye := Color(1.0, 0.85, 0.4)
	match kind:
		"grunt":     # hunched shard imp
			k.pair("capsule", Vector3(0, 0.45, 0.32), Vector3(0.32, 0.45, 0.32), dark, MeshKit.PART_LEG_L, MeshKit.PART_LEG_R, 0.85)
			k.add("sphere", Vector3(0, 1.15, 0), Vector3(1.25, 1.05, 1.15), skin, 0, 0, Vector3.ZERO, 10)
			k.add("sphere", Vector3(0.5, 1.55, 0), Vector3(0.72, 0.66, 0.7), skin, MeshKit.PART_HEAD, 1.4, Vector3.ZERO, 10)
			k.pair("sphere", Vector3(0.82, 1.62, 0.18), Vector3(0.14, 0.14, 0.14), eye, MeshKit.PART_EYE, MeshKit.PART_EYE)
			k.pair("capsule", Vector3(0.25, 1.0, 0.62), Vector3(0.22, 0.4, 0.22), skin, MeshKit.PART_ARM_L, MeshKit.PART_ARM_R, 1.35, Vector3(0, 0, -0.3))
			for i in 3:
				k.add("cone", Vector3(-0.2 - 0.18 * i, 1.75 - 0.1 * i, 0), Vector3(0.22, 0.55, 0.22), crys, MeshKit.PART_GLOW, 0, Vector3(0, 0, 0.5 + 0.2 * i), 6)
		"runner":    # low skittering quadruped
			k.add("sphere", Vector3(0, 0.7, 0), Vector3(1.6, 0.6, 0.9), skin, 0, 0, Vector3.ZERO, 10)
			k.add("sphere", Vector3(0.85, 0.85, 0), Vector3(0.6, 0.5, 0.55), skin, MeshKit.PART_HEAD, 0.8)
			k.pair("sphere", Vector3(1.1, 0.92, 0.15), Vector3(0.12, 0.12, 0.12), eye, MeshKit.PART_EYE, MeshKit.PART_EYE)
			k.pair("capsule", Vector3(0.45, 0.35, 0.45), Vector3(0.14, 0.38, 0.14), dark, MeshKit.PART_LEG_L, MeshKit.PART_LEG_R, 0.7, Vector3(0.4, 0, 0))
			k.pair("capsule", Vector3(-0.45, 0.35, 0.45), Vector3(0.14, 0.38, 0.14), dark, MeshKit.PART_LEG_R, MeshKit.PART_LEG_L, 0.7, Vector3(0.4, 0, 0))
			k.add("cone", Vector3(-0.9, 0.8, 0), Vector3(0.25, 0.7, 0.25), crys, MeshKit.PART_TAIL, 0.8, Vector3(0, 0, 1.9), 6)
		"brute":     # crystal-shouldered golem
			k.pair("cyl", Vector3(0, 0.5, 0.42), Vector3(0.45, 1.0, 0.45), dark, MeshKit.PART_LEG_L, MeshKit.PART_LEG_R, 1.0, Vector3.ZERO, 8)
			k.add("box", Vector3(0, 1.45, 0), Vector3(1.1, 1.0, 1.5), skin, 0, 0, Vector3(0, 0, -0.12))
			k.add("sphere", Vector3(0.45, 2.05, 0), Vector3(0.6, 0.5, 0.6), skin, MeshKit.PART_HEAD, 1.9)
			k.pair("sphere", Vector3(0.72, 2.1, 0.15), Vector3(0.12, 0.08, 0.12), Color(1, 0.4, 0.2), MeshKit.PART_EYE, MeshKit.PART_EYE)
			k.pair("box", Vector3(0.2, 1.1, 0.95), Vector3(0.45, 1.2, 0.45), skin, MeshKit.PART_ARM_L, MeshKit.PART_ARM_R, 1.8)
			k.pair("cone", Vector3(-0.05, 2.25, 0.75), Vector3(0.45, 0.9, 0.45), crys, MeshKit.PART_GLOW, MeshKit.PART_GLOW, 0, Vector3(0.3, 0, 0.1), 5)
		"spitter":   # bloated sack with a tube mouth
			k.add("sphere", Vector3(0, 1.0, 0), Vector3(1.4, 1.3, 1.4), skin, 0, 0, Vector3.ZERO, 12)
			k.add("cyl", Vector3(0.75, 1.2, 0), Vector3(0.38, 0.6, 0.38), dark, MeshKit.PART_HEAD, 1.2, Vector3(0, 0, -1.4))
			k.add("torus", Vector3(1.05, 1.2, 0), Vector3(0.25, 0.25, 0.25), crys, MeshKit.PART_GLOW, 0, Vector3(0, 0, 1.57), 10)
			k.pair("sphere", Vector3(0.45, 1.65, 0.3), Vector3(0.14, 0.14, 0.14), eye, MeshKit.PART_EYE, MeshKit.PART_EYE)
			for i in 4:
				var a := TAU * i / 4.0
				k.add("capsule", Vector3(cos(a) * 0.4, 0.25, sin(a) * 0.4), Vector3(0.14, 0.25, 0.14), dark, MeshKit.PART_TAIL, 0.5)
		"splitter":  # walking crystal cluster
			k.pair("capsule", Vector3(0, 0.4, 0.35), Vector3(0.25, 0.4, 0.25), dark, MeshKit.PART_LEG_L, MeshKit.PART_LEG_R, 0.75)
			k.add("prism", Vector3(0, 1.2, 0), Vector3(1.2, 1.4, 1.0), crys, 0)
			k.add("prism", Vector3(-0.35, 1.5, 0.35), Vector3(0.6, 1.0, 0.5), skin, MeshKit.PART_GLOW, 0, Vector3(0.3, 0, 0.3))
			k.add("prism", Vector3(-0.3, 1.45, -0.4), Vector3(0.55, 0.9, 0.5), skin, MeshKit.PART_GLOW, 0, Vector3(-0.3, 0, 0.2))
			k.pair("sphere", Vector3(0.45, 1.2, 0.18), Vector3(0.12, 0.12, 0.12), eye, MeshKit.PART_EYE, MeshKit.PART_EYE)
		"mini":      # shard beetle
			k.add("prism", Vector3(0, 0.55, 0), Vector3(1.3, 0.8, 1.0), crys, 0, 0, Vector3(0, 0, -1.57))
			k.pair("capsule", Vector3(0.2, 0.2, 0.45), Vector3(0.1, 0.22, 0.1), dark, MeshKit.PART_LEG_L, MeshKit.PART_LEG_R, 0.4, Vector3(0.6, 0, 0))
			k.pair("sphere", Vector3(0.6, 0.6, 0.15), Vector3(0.1, 0.1, 0.1), eye, MeshKit.PART_EYE, MeshKit.PART_EYE)
		"charger":   # horned ram beast
			k.add("sphere", Vector3(-0.1, 0.95, 0), Vector3(1.7, 0.9, 1.0), skin, 0, 0, Vector3.ZERO, 10)
			k.add("sphere", Vector3(0.85, 1.0, 0), Vector3(0.65, 0.6, 0.6), skin, MeshKit.PART_HEAD, 1.0)
			k.pair("cone", Vector3(1.05, 1.35, 0.32), Vector3(0.22, 0.75, 0.22), crys, MeshKit.PART_HEAD, MeshKit.PART_HEAD, 1.0, Vector3(0.4, 0, -1.0), 6)
			k.pair("sphere", Vector3(1.12, 1.08, 0.18), Vector3(0.1, 0.1, 0.1), Color(1, 0.3, 0.2), MeshKit.PART_EYE, MeshKit.PART_EYE)
			k.pair("capsule", Vector3(0.5, 0.35, 0.38), Vector3(0.18, 0.4, 0.18), dark, MeshKit.PART_LEG_L, MeshKit.PART_LEG_R, 0.7)
			k.pair("capsule", Vector3(-0.6, 0.35, 0.38), Vector3(0.18, 0.4, 0.18), dark, MeshKit.PART_LEG_R, MeshKit.PART_LEG_L, 0.7)
		"breach":    # tendril hand from the other side
			k.add("sphere", Vector3(0, 0.9, 0), Vector3(1.0, 1.1, 1.0), skin, 0, 0, Vector3.ZERO, 10)
			for i in 5:
				var a2 := TAU * i / 5.0
				k.add("cone", Vector3(cos(a2) * 0.45, 1.45, sin(a2) * 0.45), Vector3(0.22, 0.9, 0.22), skin, MeshKit.PART_TAIL, 1.2, Vector3(sin(a2) * 0.5, 0, -cos(a2) * 0.5), 6)
			k.add("sphere", Vector3(0.42, 1.0, 0), Vector3(0.3, 0.3, 0.3), Color(1, 0.5, 1), MeshKit.PART_EYE)
			k.add("cyl", Vector3(0, 0.3, 0), Vector3(0.7, 0.6, 0.7), dark, MeshKit.PART_TAIL, 0.6)
		"goblin":    # gremlin hauling a loot sack
			k.pair("capsule", Vector3(0, 0.35, 0.25), Vector3(0.22, 0.35, 0.22), dark, MeshKit.PART_LEG_L, MeshKit.PART_LEG_R, 0.65)
			k.add("sphere", Vector3(0.1, 0.95, 0), Vector3(0.8, 0.8, 0.75), skin, 0)
			k.add("sphere", Vector3(0.4, 1.45, 0), Vector3(0.62, 0.55, 0.6), skin, MeshKit.PART_HEAD, 1.3)
			k.pair("cone", Vector3(0.35, 1.7, 0.42), Vector3(0.15, 0.55, 0.15), skin, MeshKit.PART_HEAD, MeshKit.PART_HEAD, 1.3, Vector3(1.2, 0, 0), 5)
			k.pair("sphere", Vector3(0.68, 1.5, 0.16), Vector3(0.12, 0.12, 0.12), Color(1, 1, 0.3), MeshKit.PART_EYE, MeshKit.PART_EYE)
			k.add("sphere", Vector3(-0.55, 1.2, 0), Vector3(1.0, 1.1, 1.0), Color(0.55, 0.42, 0.25), MeshKit.PART_TAIL, 1.2, Vector3.ZERO, 10)
			k.add("sphere", Vector3(-0.55, 1.75, 0), Vector3(0.5, 0.25, 0.5), Color(1.0, 0.85, 0.2), MeshKit.PART_GLOW)
		"exile":     # hooded rival survivor
			k.pair("capsule", Vector3(0, 0.45, 0.25), Vector3(0.24, 0.45, 0.24), dark, MeshKit.PART_LEG_L, MeshKit.PART_LEG_R, 0.85)
			k.add("cone", Vector3(0, 1.15, 0), Vector3(1.0, 1.2, 1.0), skin, 0, 0, Vector3.ZERO, 10)
			k.add("sphere", Vector3(0.1, 1.95, 0), Vector3(0.6, 0.65, 0.6), dark, MeshKit.PART_HEAD, 1.8)
			k.pair("sphere", Vector3(0.36, 1.98, 0.12), Vector3(0.09, 0.07, 0.09), Color(1, 0.5, 0.2), MeshKit.PART_EYE, MeshKit.PART_EYE)
			k.pair("capsule", Vector3(0.1, 1.3, 0.45), Vector3(0.18, 0.4, 0.18), skin, MeshKit.PART_ARM_L, MeshKit.PART_ARM_R, 1.65)
			k.add("box", Vector3(0.55, 1.5, 0.55), Vector3(0.1, 1.6, 0.12), Color(0.8, 0.85, 0.95), MeshKit.PART_ARM_R, 1.65, Vector3(0, 0, -0.4))
		_:
			k.add("sphere", Vector3(0, 1, 0), Vector3(2, 2, 2), skin)
	return k.commit()

# ================================================================= props (world units, feet at y 0)
static func _build_prop(kind: String) -> ArrayMesh:
	var k := MeshKit.new()
	match kind:
		"rock":
			k.add("sphere", Vector3(0, 6, 0), Vector3(26, 16, 20), Color(0.55, 0.53, 0.5), 0, 0, Vector3(0.2, 0.5, 0.1), 7)
			k.add("sphere", Vector3(10, 4, 7), Vector3(14, 9, 12), Color(0.5, 0.48, 0.46), 0, 0, Vector3(0.1, 1.1, 0.3), 6)
		"tree":      # dead, twisted tree: tall but narrow so it rarely hides the fight
			k.add("cyl", Vector3(0, 28, 0), Vector3(7, 56, 7), Color(0.33, 0.25, 0.2), 0, 0, Vector3(0.05, 0, 0.08), 7)
			k.add("cyl", Vector3(8, 52, 0), Vector3(3, 26, 3), Color(0.33, 0.25, 0.2), 0, 0, Vector3(0, 0, -0.8), 5)
			k.add("cyl", Vector3(-6, 46, 3), Vector3(3, 22, 3), Color(0.33, 0.25, 0.2), 0, 0, Vector3(0.4, 0, 0.9), 5)
			k.add("sphere", Vector3(4, 62, 4), Vector3(26, 14, 22), Color(0.4, 0.45, 0.36), MeshKit.PART_TAIL, 50, Vector3(0.3, 0.4, 0), 7)
			k.add("sphere", Vector3(14, 56, -6), Vector3(18, 11, 16), Color(0.36, 0.4, 0.32), MeshKit.PART_TAIL, 50, Vector3(0, 1.0, 0.3), 6)
			k.add("sphere", Vector3(-8, 52, 8), Vector3(16, 10, 18), Color(0.38, 0.42, 0.33), MeshKit.PART_TAIL, 46, Vector3(0.2, 2.0, 0), 6)
		"crystal":   # glowing shard cluster (emissive channel)
			k.add("prism", Vector3(0, 14, 0), Vector3(10, 28, 9), Color(0.9, 0.95, 1.0), MeshKit.PART_GLOW, 0, Vector3(0.1, 0, 0.15))
			k.add("prism", Vector3(7, 8, 4), Vector3(6, 16, 6), Color(0.9, 0.95, 1.0), MeshKit.PART_GLOW, 0, Vector3(0.3, 0.6, -0.5))
			k.add("prism", Vector3(-6, 7, -3), Vector3(6, 14, 5), Color(0.9, 0.95, 1.0), MeshKit.PART_GLOW, 0, Vector3(-0.2, 1.0, 0.45))
			k.add("sphere", Vector3(0, 2, 0), Vector3(22, 6, 18), Color(0.4, 0.38, 0.36), 0, 0, Vector3.ZERO, 6)
		"pillar":    # broken ruin column
			k.add("box", Vector3(0, 2, 0), Vector3(24, 4, 24), Color(0.6, 0.58, 0.54))
			k.add("cyl", Vector3(0, 22, 0), Vector3(15, 36, 15), Color(0.68, 0.66, 0.62), 0, 0, Vector3.ZERO, 10)
			k.add("cyl", Vector3(0, 42, 1), Vector3(15, 6, 15), Color(0.62, 0.6, 0.56), 0, 0, Vector3(0.35, 0, 0.2), 10)
		"bones":
			k.add("sphere", Vector3(0, 4, 0), Vector3(8, 7, 8), Color(0.88, 0.85, 0.78))
			k.add("capsule", Vector3(9, 1.5, 3), Vector3(2, 6, 2), Color(0.85, 0.82, 0.75), 0, 0, Vector3(0, 0.5, 1.57))
			k.add("capsule", Vector3(-6, 1.5, -5), Vector3(2, 5, 2), Color(0.85, 0.82, 0.75), 0, 0, Vector3(0, -0.8, 1.57))
		"grass":     # tuft of blades (tail channel sways in the wind)
			for i in 7:
				var a := TAU * i / 7.0
				k.add("cone", Vector3(cos(a) * 3.0, 5, sin(a) * 3.0), Vector3(1.6, 10 + (i % 3) * 3, 1.0), Color(0.8, 0.85, 0.7), MeshKit.PART_TAIL, 0, Vector3(sin(a) * 0.3, a, -cos(a) * 0.3), 4)
	return k.commit()
