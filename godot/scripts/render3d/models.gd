class_name Models
extends RefCounted
## Model library with drop-in override slots.
##
## Every visual asks this class first for an authored asset and falls back to a procedural one:
##   res://models/heroes/<warden|spark|ember|storm>.(tscn|glb)  -> replaces the hero rig
##   res://models/bosses/<boss|herald|guardian>.(tscn|glb)      -> replaces a boss rig
##   res://models/foes/<grunt|runner|...>.(glb|tscn|tres)       -> first mesh found is instanced for the swarm
##   res://models/props/<rock|tree|crystal|pillar|bones|grass>.(glb|tscn|tres)
##   res://models/foes_hi/, props_hi/: denser variants used on the High graphics tier (Quality); the APK
##   leaves props_hi out (export_presets.cfg exclude_filter), so only desktop runs use it
## Authored hero/boss scenes may contain an AnimationPlayer with any of: idle, run, cast, roll, hit, die.
## The rigs then play those instead of the procedural animation (see HeroRig.attach_override).

const FOE_KINDS := ["grunt", "runner", "brute", "spitter", "splitter", "mini", "charger", "breach", "goblin", "exile", "boss", "herald"]
const PROP_KINDS := ["rock", "tree", "tree_dead", "bush", "arch", "wall", "crystal", "pillar", "bones", "grass"]

## The PBR maps a mesh's first surface material brings: {albedo, normal, orm} (whichever exist; orm is
## the glTF metallic-roughness image, G roughness and B metal).
static func pbr_maps(m: Mesh) -> Dictionary:
	var out := {}
	if m == null or m.get_surface_count() == 0: return out
	var mat := m.surface_get_material(0) as BaseMaterial3D
	if mat == null: return out
	if mat.albedo_texture != null: out["albedo"] = mat.albedo_texture
	if mat.normal_enabled and mat.normal_texture != null: out["normal"] = mat.normal_texture
	if mat.roughness_texture != null: out["orm"] = mat.roughness_texture
	return out

## Whether a mesh brings its own PBR material (an albedo texture on any of its surfaces): those draw as
## imported; the rest take the shared prop shader.
static func has_pbr(m: Mesh) -> bool:
	if m == null: return false
	for i in m.get_surface_count():
		var mat := m.surface_get_material(i)
		if mat is BaseMaterial3D and (mat as BaseMaterial3D).albedo_texture != null: return true
	return false

static var _cache := {}

## Albedo floor for the generated models (tech-art finding 4): their base-colour maps came out 2-4 stops darker than
## the ground's photographs (median linear albedo 0.011-0.028 against 0.13-0.20), so trees and walls read as black
## cut-outs and heroes as dark blobs. The linear gain lifts each map's median to 0.05 (x4 at most), the rule
## tools/blender/process_fal_assets.py lift_albedo applies to the bush; set as the material's albedo colour at load.
## Computed from the maps by the tech-art review's albedo_table.py. Foes and bosses keep theirs (status contrast).
const ALBEDO_GAIN := {"tree": 4.0, "tree_dead": 4.0, "wall": 4.0, "bones": 2.98, "rock": 1.77,
	"warden": 2.85, "spark": 2.1, "ember": 3.31, "storm": 4.0}

## The albedo colour that multiplies a map's linear values by the model's gain (1 when it has none).
static func albedo_gain_color(id: String) -> Color:
	var g: float = ALBEDO_GAIN.get(id, 1.0)
	return Color(g, g, g).linear_to_srgb()

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
		# a MultiMesh draws the mesh's own surface materials only: carry the instance's override materials
		# (an imported scene can put its PBR materials there) onto a copy before the instance goes
		var mi := _first_mesh_instance(n)
		if m != null and mi != null:
			var copy: Mesh = null
			for i in m.get_surface_count():
				var om := mi.get_surface_override_material(i)
				if om == null: continue
				if copy == null: copy = m.duplicate()
				copy.surface_set_material(i, om)
			if copy != null: m = copy
		n.free()
		return m
	return null

static func _first_mesh_instance(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		return n as MeshInstance3D
	for c in n.get_children():
		var r := _first_mesh_instance(c)
		if r != null: return r
	return null

static func _first_mesh(n: Node) -> Mesh:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		return (n as MeshInstance3D).mesh
	for c in n.get_children():
		var m := _first_mesh(c)
		if m != null: return m
	return null

## stage >= 0 prefers an act-specific variant: res://models/foes/<kind>_<stage>.glb (props likewise).
static func foe_mesh(kind: String, stage: int = -1) -> Mesh:
	var ask := "foe?%s:%d:%d" % [kind, stage, int(Quality.high())]       # the resolved mesh, without probing the files again
	if _cache.has(ask): return _cache[ask]
	var m := _foe_mesh(kind, stage)
	_cache[ask] = m
	return m

static func _foe_mesh(kind: String, stage: int) -> Mesh:
	if stage >= 0 and find_asset("foes", "%s_%d" % [kind, stage]) != "":
		kind = "%s_%d" % [kind, stage]
	var hi := Quality.high() and find_asset("foes_hi", kind) != ""     # High tier: the detailed variant
	var key := ("foe_hi:" if hi else "foe:") + kind
	if _cache.has(key): return _cache[key]
	var p := find_asset("foes_hi" if hi else "foes", kind)
	var m: Mesh = mesh_from_asset(p) if p != "" else _build_foe(kind)
	_cache[key] = m
	return m

## Vertex animation for an imported foe (tools/blender/import_packs.py bake_vat), or {} when the kind has
## none. Returns {pos: ImageTexture (RGBA half, row = frame, column = vertex), nrm: ImageTexture (RGBA8),
## clips: PackedFloat32Array of [first row, frames, fps] for walk, attack, hit, death, spawn (frames 0 = absent)}.
const VAT_SLOTS := ["walk", "attack", "hit", "death", "spawn"]
static func foe_vat(kind: String, stage: int = -1) -> Dictionary:
	if stage >= 0 and FileAccess.file_exists("res://models/foes/%s_%d.vat" % [kind, stage]):
		kind = "%s_%d" % [kind, stage]
	var key := "vat:" + kind
	if _cache.has(key): return _cache[key]
	var out := {}
	var path := "res://models/foes/%s.vat" % kind
	if FileAccess.file_exists(path):
		# SVA3 (tools/vat_pack.py): header, the positions' bounding box, clip table, then a deflated body of
		# positions as RGBA8 (10 bits per axis over the box: RGB the top 8 bits, A the low 2 bits of each) and
		# normals as octahedral RG8; foe.gdshader decodes both. Inflated once here and cached.
		var b := FileAccess.get_file_as_bytes(path)
		if b.size() > 40 and b.slice(0, 4).get_string_from_ascii() == "SVA3":
			var nv := b.decode_u16(4)
			var rows := b.decode_u16(6)
			var nc := b.decode_u16(8)
			var raw := b.decode_u32(12)
			var vmin := Vector3(b.decode_float(16), b.decode_float(20), b.decode_float(24))
			var vext := Vector3(b.decode_float(28), b.decode_float(32), b.decode_float(36))
			var clips := PackedFloat32Array()
			clips.resize(VAT_SLOTS.size() * 3)
			var o := 40
			for c in nc:
				var nm := b.slice(o, o + 8).get_string_from_ascii()
				var si := VAT_SLOTS.find(nm)
				if si >= 0:
					clips[si * 3] = b.decode_u16(o + 8); clips[si * 3 + 1] = b.decode_u16(o + 10); clips[si * 3 + 2] = b.decode_float(o + 12)
				o += 20
			var body := b.slice(o).decompress(raw, FileAccess.COMPRESSION_DEFLATE)
			var psz := rows * nv * 4
			if body.size() == raw and raw == rows * nv * 6:
				var pimg := Image.create_from_data(nv, rows, false, Image.FORMAT_RGBA8, body.slice(0, psz))
				var nimg := Image.create_from_data(nv, rows, false, Image.FORMAT_RG8, body.slice(psz, raw))
				out = {"pos": ImageTexture.create_from_image(pimg), "nrm": ImageTexture.create_from_image(nimg), "clips": clips,
					"verts": nv, "rows": rows, "vmin": vmin, "vext": vext}
			else:
				Diag.mark("VAT %s: body is %d bytes, expected %d" % [kind, body.size(), raw])
		elif b.size() >= 4:
			Diag.mark("VAT %s: not SVA3 (%s); run tools/vat_pack.py" % [kind, b.slice(0, 4).get_string_from_ascii()])
	_cache[key] = out
	return out

## Every prop cell asks for each of its kinds' meshes (WorldView3D.cell_parts): the answer is cached per
## (kind, act, tier), since resolving it probes up to ten paths with ResourceLoader.exists (O6).
static func prop_mesh(kind: String, stage: int = -1) -> Mesh:
	var ask := "prop?%s:%d:%d" % [kind, stage, int(Quality.high())]
	if _cache.has(ask): return _cache[ask]
	var m := _prop_mesh(kind, stage)
	_cache[ask] = m
	return m

static func _prop_mesh(kind: String, stage: int) -> Mesh:
	if stage >= 0 and find_asset("props", "%s_%d" % [kind, stage]) != "":
		kind = "%s_%d" % [kind, stage]
	var hi := Quality.high() and find_asset("props_hi", kind) != ""
	var key := ("prop_hi:" if hi else "prop:") + kind
	if _cache.has(key): return _cache[key]
	var p := find_asset("props_hi" if hi else "props", kind)
	var m: Mesh = mesh_from_asset(p) if p != "" else _build_prop(kind)
	var id := p.get_file().get_basename()
	if m != null and ALBEDO_GAIN.has(id):                # the imported material is shared: set once, not multiplied
		for i in m.get_surface_count():
			var mat := m.surface_get_material(i)
			if mat is BaseMaterial3D and (mat as BaseMaterial3D).albedo_texture != null:
				(mat as BaseMaterial3D).albedo_color = albedo_gain_color(id)
	_cache[key] = m
	return m

# ================================================================= procedural foes (radius 1, feet at y 0)
static func _build_foe(kind: String) -> ArrayMesh:
	var k := MeshKit.new()
	var skin := Color(0.9, 0.88, 0.86)          # tinted per stage by the instance colour
	var flesh := Color(0.62, 0.5, 0.48)
	var bone := Color(0.93, 0.9, 0.82)
	var dark := Color(0.3, 0.28, 0.3)
	var crys := Color(0.8, 0.92, 1.0)
	var eye := Color(1.0, 0.85, 0.4)
	const L := MeshKit.PART_LEG_L
	const R := MeshKit.PART_LEG_R
	const AL := MeshKit.PART_ARM_L
	const AR := MeshKit.PART_ARM_R
	const HD := MeshKit.PART_HEAD
	const EY := MeshKit.PART_EYE
	const GL := MeshKit.PART_GLOW
	const TL := MeshKit.PART_TAIL
	match kind:
		"grunt":     # ghoul: digitigrade legs, hunched spine, exposed ribs, long clawed arms, crystal growths
			k.pair("capsule", Vector3(0.05, 0.62, 0.3), Vector3(0.24, 0.34, 0.26), dark, L, R, 0.95, Vector3(0, 0, -0.35), 10)
			k.pair("capsule", Vector3(-0.05, 0.22, 0.3), Vector3(0.18, 0.26, 0.2), dark, L, R, 0.95, Vector3(0, 0, 0.45), 10)
			k.pair("cone", Vector3(0.14, 0.04, 0.3), Vector3(0.22, 0.16, 0.16), bone, L, R, 0.95, Vector3(0, 0, -1.57), 6)
			k.add("sphere", Vector3(-0.02, 1.08, 0), Vector3(0.5, 0.62, 0.66), flesh, 0, 0, Vector3(0, 0, -0.15), 14)
			k.add("sphere", Vector3(0.14, 1.48, 0), Vector3(0.62, 0.72, 0.84), skin, 0, 0, Vector3(0, 0, -0.35), 14)
			for r in 4:
				k.add("torus", Vector3(0.12 + r * 0.03, 1.22 + r * 0.1, 0), Vector3(0.3, 0.3, 0.38), bone, 0, 0, Vector3(0, 0, 1.25), 12)
			k.add("sphere", Vector3(0.42, 1.86, 0), Vector3(0.44, 0.42, 0.42), skin, HD, 1.75, Vector3.ZERO, 14)
			k.add("sphere", Vector3(0.58, 1.74, 0), Vector3(0.3, 0.16, 0.3), flesh, HD, 1.75, Vector3(0, 0, -0.3), 10)
			for t in 3: k.add("cone", Vector3(0.66, 1.71, -0.08 + t * 0.08), Vector3(0.04, 0.09, 0.04), bone, HD, 1.75, Vector3(0, 0, PI), 4)
			k.pair("sphere", Vector3(0.62, 1.92, 0.11), Vector3(0.05, 0.04, 0.05), eye, EY, EY)
			k.pair("capsule", Vector3(0.22, 1.38, 0.5), Vector3(0.13, 0.36, 0.13), skin, AL, AR, 1.7, Vector3(0, 0, -0.3), 8)
			k.pair("capsule", Vector3(0.42, 0.92, 0.52), Vector3(0.11, 0.34, 0.11), skin, AL, AR, 1.7, Vector3(0, 0, 0.3), 8)
			for c in 3: k.pair("cone", Vector3(0.52, 0.58, 0.44 + c * 0.06), Vector3(0.05, 0.24, 0.05), bone, AL, AR, 1.7, Vector3(0, 0, -2.7), 4)
			for i in 4:
				k.add("prism", Vector3(-0.22 - 0.06 * i, 1.85 - 0.18 * i, -0.18 + 0.12 * (i % 3)), Vector3(0.16, 0.44 - i * 0.05, 0.14), crys, GL, 0, Vector3(0.2 * (i % 2), 0, 0.9 + 0.15 * i))
		"runner":    # feral hound: long body, neck, snout, ears, two-segment legs, spine crystals, tail
			k.add("sphere", Vector3(-0.1, 0.82, 0), Vector3(1.55, 0.62, 0.66), skin, 0, 0, Vector3(0, 0, 0.05), 14)
			k.add("sphere", Vector3(0.45, 0.92, 0), Vector3(0.75, 0.62, 0.7), flesh, 0, 0, Vector3.ZERO, 12)
			k.add("capsule", Vector3(0.82, 1.04, 0), Vector3(0.24, 0.3, 0.24), skin, HD, 1.0, Vector3(0, 0, -0.9), 10)
			k.add("sphere", Vector3(1.08, 1.12, 0), Vector3(0.42, 0.34, 0.36), skin, HD, 1.0, Vector3.ZERO, 12)
			k.add("capsule", Vector3(1.32, 1.06, 0), Vector3(0.14, 0.2, 0.14), flesh, HD, 1.0, Vector3(0, 0, -1.4), 8)
			k.pair("cone", Vector3(0.98, 1.32, 0.13), Vector3(0.1, 0.24, 0.08), skin, HD, HD, 1.0, Vector3(0.3, 0, 0.3), 5)
			k.pair("sphere", Vector3(1.22, 1.18, 0.12), Vector3(0.045, 0.04, 0.045), Color(1, 0.4, 0.2), EY, EY)
			for leg in [[0.45, L, R], [-0.6, R, L]]:
				k.pair("capsule", Vector3(leg[0], 0.55, 0.26), Vector3(0.12, 0.28, 0.12), dark, leg[1], leg[2], 0.8, Vector3(0, 0, 0.25), 8)
				k.pair("capsule", Vector3(leg[0] - 0.05, 0.2, 0.26), Vector3(0.09, 0.22, 0.09), dark, leg[1], leg[2], 0.8, Vector3(0, 0, -0.2), 8)
			for i in 5: k.add("prism", Vector3(0.4 - i * 0.24, 1.12 - absf(i - 2) * 0.03, 0), Vector3(0.12, 0.32, 0.1), crys, GL, 0, Vector3(0, 0, 0.3))
			k.add("cone", Vector3(-0.98, 0.95, 0), Vector3(0.16, 0.7, 0.16), skin, TL, 0.9, Vector3(0, 0, 1.9), 6)
		"brute":     # rubble golem: stacked stone blocks, a glowing crystal heart, huge fists
			var stone := Color(0.72, 0.7, 0.68)
			k.pair("box", Vector3(0, 0.45, 0.42), Vector3(0.48, 0.9, 0.5), stone, L, R, 0.95, Vector3(0, 0.3, 0.05))
			k.add("box", Vector3(0, 1.2, 0), Vector3(0.9, 0.7, 1.3), stone, 0, 0, Vector3(0.1, 0, -0.1))
			k.add("box", Vector3(0.0, 1.78, 0), Vector3(1.04, 0.56, 1.62), skin, 0, 0, Vector3(-0.1, 0.2, -0.15))
			k.add("sphere", Vector3(0.6, 1.45, 0), Vector3(0.36, 0.36, 0.36), crys, GL, 0, Vector3.ZERO, 6)     # core gem proud of the chest (loop 2: z-fighting)
			k.add("box", Vector3(0.42, 2.18, 0), Vector3(0.45, 0.4, 0.5), stone, HD, 2.0, Vector3(0, 0.4, 0.1))
			k.pair("sphere", Vector3(0.66, 2.2, 0.1), Vector3(0.1, 0.06, 0.1), Color(1, 0.5, 0.2), EY, EY)
			k.pair("box", Vector3(0.1, 1.55, 1.0), Vector3(0.4, 0.75, 0.4), stone, AL, AR, 1.9, Vector3(0.2, 0, 0))
			k.pair("box", Vector3(0.25, 0.7, 1.05), Vector3(0.62, 0.62, 0.62), skin, AL, AR, 1.9, Vector3(0.3, 0.4, 0.2))
			for i in 3: k.pair("prism", Vector3(-0.15 + i * 0.2, 2.2, 0.62), Vector3(0.25, 0.6, 0.22), crys, GL, GL, 0, Vector3(0.4, 0, 0.2 * i - 0.2))
		"spitter":   # bloated corpse sack: pustules that glow, a ringed maw, stubby legs
			k.add("sphere", Vector3(0, 1.0, 0), Vector3(1.45, 1.3, 1.4), flesh, 0, 0, Vector3.ZERO, 16)
			k.add("sphere", Vector3(-0.15, 1.55, 0), Vector3(0.9, 0.7, 0.9), skin, 0, 0, Vector3.ZERO, 14)
			for i in 7:
				var a := TAU * i / 7.0
				k.add("sphere", Vector3(cos(a) * 0.55, 1.05 + sin(i * 2.3) * 0.35, sin(a) * 0.55), Vector3(0.2, 0.2, 0.2), crys, GL, 0, Vector3.ZERO, 8)
			k.add("cyl", Vector3(0.68, 1.28, 0), Vector3(0.42, 0.45, 0.42), dark, HD, 1.2, Vector3(0, 0, -1.3), 12)
			k.add("torus", Vector3(0.92, 1.36, 0), Vector3(0.24, 0.24, 0.24), bone, HD, 1.2, Vector3(0, 0, 1.3), 12)
			k.pair("sphere", Vector3(0.5, 1.78, 0.26), Vector3(0.06, 0.06, 0.06), eye, EY, EY)
			for i in 4:
				var a2 := TAU * i / 4.0 + 0.4
				k.add("capsule", Vector3(cos(a2) * 0.45, 0.22, sin(a2) * 0.45), Vector3(0.14, 0.24, 0.14), dark, L if i % 2 == 0 else R, 0.45, Vector3.ZERO, 8)
		"splitter":  # crystal husk: a humanoid swallowed by crystal clusters
			k.pair("capsule", Vector3(0, 0.42, 0.28), Vector3(0.2, 0.42, 0.2), dark, L, R, 0.85, Vector3.ZERO, 8)
			k.add("capsule", Vector3(0, 1.15, 0), Vector3(0.42, 0.42, 0.46), skin, 0, 0, Vector3(0, 0, -0.2), 12)
			k.add("sphere", Vector3(0.25, 1.75, 0), Vector3(0.4, 0.44, 0.4), skin, HD, 1.6, Vector3.ZERO, 12)
			k.pair("sphere", Vector3(0.43, 1.78, 0.1), Vector3(0.07, 0.06, 0.07), Color(0.6, 0.9, 1.0), EY, EY)
			k.pair("capsule", Vector3(0.15, 1.15, 0.42), Vector3(0.12, 0.38, 0.12), skin, AL, AR, 1.45, Vector3(0, 0, -0.2), 8)
			for i in 6:
				var a3 := TAU * i / 6.0
				k.add("prism", Vector3(-0.1 + cos(a3) * 0.3, 1.3 + sin(i * 1.7) * 0.3, sin(a3) * 0.3), Vector3(0.28, 0.75 - (i % 3) * 0.12, 0.24), crys, GL, 0, Vector3(sin(a3) * 0.6, a3, -cos(a3) * 0.6))
		"mini":      # crystal mite: shard body on six legs
			k.add("prism", Vector3(0, 0.55, 0), Vector3(1.0, 0.8, 0.8), crys, 0, 0, Vector3(0, 0, -1.57))
			k.add("sphere", Vector3(-0.3, 0.5, 0), Vector3(0.6, 0.45, 0.55), dark, 0, 0, Vector3.ZERO, 10)
			for i in 3:
				k.pair("capsule", Vector3(0.25 - i * 0.3, 0.3, 0.42), Vector3(0.06, 0.26, 0.06), dark, L if i % 2 == 0 else R, R if i % 2 == 0 else L, 0.45, Vector3(0.7, 0, 0), 6)
			k.pair("sphere", Vector3(0.55, 0.6, 0.13), Vector3(0.08, 0.08, 0.08), eye, EY, EY)
		"charger":   # tusked boar beast with a crystal ridge
			k.add("sphere", Vector3(-0.15, 0.98, 0), Vector3(1.75, 0.95, 1.05), skin, 0, 0, Vector3(0, 0, 0.08), 14)
			k.add("sphere", Vector3(0.45, 1.1, 0), Vector3(0.9, 0.85, 0.95), flesh, 0, 0, Vector3.ZERO, 12)
			k.add("sphere", Vector3(0.95, 0.98, 0), Vector3(0.62, 0.55, 0.58), skin, HD, 1.0, Vector3(0, 0, -0.2), 12)
			k.add("cyl", Vector3(1.22, 0.9, 0), Vector3(0.3, 0.25, 0.3), flesh, HD, 1.0, Vector3(0, 0, -1.4), 10)
			k.pair("cone", Vector3(1.2, 0.85, 0.2), Vector3(0.09, 0.42, 0.09), bone, HD, HD, 1.0, Vector3(0.3, 0, -0.5), 6)
			k.pair("cone", Vector3(0.88, 1.32, 0.28), Vector3(0.14, 0.7, 0.14), bone, HD, HD, 1.0, Vector3(0.6, 0, -0.9), 6)
			k.pair("sphere", Vector3(1.12, 1.1, 0.2), Vector3(0.07, 0.07, 0.07), Color(1, 0.3, 0.2), EY, EY)
			for i in 6: k.add("prism", Vector3(0.5 - i * 0.25, 1.48 - absf(i - 2) * 0.04, 0), Vector3(0.16, 0.42, 0.12), crys, GL, 0, Vector3(0, 0, 0.35))
			for leg in [[0.5, L, R], [-0.65, R, L]]:
				k.pair("capsule", Vector3(leg[0], 0.4, 0.38), Vector3(0.18, 0.42, 0.18), dark, leg[1], leg[2], 0.75, Vector3.ZERO, 8)
		"breach":    # abyssal mass: tentacles around a single great eye
			k.add("sphere", Vector3(0, 0.9, 0), Vector3(1.0, 1.15, 1.0), skin, 0, 0, Vector3.ZERO, 14)
			for i in 7:
				var a4 := TAU * i / 7.0
				k.add("cone", Vector3(cos(a4) * 0.45, 1.45, sin(a4) * 0.45), Vector3(0.2, 1.0, 0.2), flesh, TL, 1.2, Vector3(sin(a4) * 0.6, 0, -cos(a4) * 0.6), 8)
				k.add("cone", Vector3(cos(a4) * 0.5, 0.25, sin(a4) * 0.5), Vector3(0.16, 0.6, 0.16), dark, TL, 0.5, Vector3(sin(a4) * 1.9, 0, -cos(a4) * 1.9), 6)
			k.add("sphere", Vector3(0.42, 1.05, 0), Vector3(0.38, 0.38, 0.38), Color(1, 0.5, 1), EY, 0, Vector3.ZERO, 12)
			k.add("sphere", Vector3(0.58, 1.05, 0), Vector3(0.12, 0.2, 0.12), Color(0.05, 0.0, 0.05), 0, 0, Vector3.ZERO, 8)
		"goblin":    # hunched imp dragging a bulging sack of glowing coin
			k.pair("capsule", Vector3(0, 0.35, 0.22), Vector3(0.2, 0.34, 0.2), dark, L, R, 0.65, Vector3.ZERO, 8)
			k.add("sphere", Vector3(0.1, 0.92, 0), Vector3(0.72, 0.72, 0.68), skin, 0, 0, Vector3(0, 0, -0.4), 12)
			k.add("sphere", Vector3(0.45, 1.32, 0), Vector3(0.6, 0.52, 0.56), skin, HD, 1.25, Vector3.ZERO, 12)
			k.add("cone", Vector3(0.78, 1.28, 0), Vector3(0.14, 0.32, 0.14), flesh, HD, 1.25, Vector3(0, 0, -1.6), 6)
			k.pair("cone", Vector3(0.38, 1.6, 0.36), Vector3(0.12, 0.55, 0.1), skin, HD, HD, 1.25, Vector3(1.25, 0, 0.2), 5)
			k.pair("sphere", Vector3(0.7, 1.4, 0.14), Vector3(0.06, 0.06, 0.06), Color(1, 1, 0.3), EY, EY)
			k.pair("capsule", Vector3(0.0, 0.95, 0.36), Vector3(0.1, 0.32, 0.1), skin, AL, AR, 1.15, Vector3(0, 0, 0.6), 8)
			k.add("sphere", Vector3(-0.62, 1.1, 0), Vector3(1.05, 1.15, 1.0), Color(0.5, 0.38, 0.24), TL, 1.1, Vector3.ZERO, 12)
			k.add("torus", Vector3(-0.62, 1.66, 0), Vector3(0.22, 0.22, 0.22), Color(0.4, 0.3, 0.2), TL, 1.1, Vector3.ZERO, 10)
			for i in 4: k.add("cyl", Vector3(-0.55 + (i % 2) * 0.12, 1.72 + i * 0.04, -0.1 + i * 0.07), Vector3(0.16, 0.04, 0.16), Color(1.0, 0.85, 0.25), GL, 0, Vector3(0.3 * i, 0, 0.2), 8)
		"exile":     # rendered with a HeroRig in the 3D view; this mesh is the 2D/low fallback only
			k.pair("capsule", Vector3(0, 0.45, 0.25), Vector3(0.24, 0.45, 0.24), dark, L, R, 0.85)
			k.add("cone", Vector3(0, 1.15, 0), Vector3(1.0, 1.2, 1.0), skin, 0, 0, Vector3.ZERO, 10)
			k.add("sphere", Vector3(0.1, 1.95, 0), Vector3(0.6, 0.65, 0.6), dark, HD, 1.8)
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
		"grass":     # a clump of five broad blades (tail channel sways in the wind). Each blade is several
			# pixels wide from the game camera: the earlier seven thin cones were under a pixel and read as noise
			for i in 5:
				var a := TAU * i / 5.0 + 0.4
				var hgt := 11.0 + (i % 3) * 3.5
				# their own colours (the prop shader's tint is neutral): dark olive and dry straw blades. Read as linear albedo,
				# so halved from 0.27-0.42: at full value the clumps were 2-4x the ground's luma, the brightest thing unlit
				k.add("cone", Vector3(cos(a) * 3.5, hgt * 0.45, sin(a) * 3.5), Vector3(5.0, hgt, 1.6), Color(0.135, 0.155, 0.085) if i % 2 == 0 else Color(0.21, 0.2, 0.12), MeshKit.PART_TAIL, 0, Vector3(sin(a) * 0.45, a, -cos(a) * 0.45), 3)
	return k.commit()
