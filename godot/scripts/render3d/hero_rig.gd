class_name HeroRig
extends Node3D
## Articulated procedural hero, PoE2 direction: layered gear (gambeson under plate, pauldrons,
## tassets, greaves; robes with swinging skirts, cowls, mantles), worn materials from the
## character shader (cloth weave, scuffed leather, metal with bright worn edges), a 4-segment cape
## and robe skirts that trail and flutter, and rune/crystal emissives that flare on every cast.
## Faces +X, ~48 units at scale 1.
##
## States from the simulation: run (gait from walk phase and speed), cast (turn to target and thrust),
## roll (tuck and forward flip), hit (recoil + red tint), death (topple), idle (breathing, cape drift).
## Authored override: res://models/heroes/<id>.(tscn|glb), clips idle / run / cast / roll / hit / die.

var hero_id := "warden"
var col := Color.WHITE
var hips: Node3D
var torso: Node3D
var head: Node3D
var arm_l: Node3D
var arm_r: Node3D
var leg_l: Node3D
var leg_r: Node3D
var shin_l: Node3D
var shin_r: Node3D
var fore_l: Node3D
var fore_r: Node3D
var weapon: Node3D
var cape: Array[Node3D] = []
var skirt: Array[Node3D] = []
var _mats: Array[ShaderMaterial] = []
var _glow_mats: Array[ShaderMaterial] = []
var override: Node3D
var anim: AnimationPlayer
var _yaw := 0.0
var _cast := 0.0
var _hit := 0.0
var _dead := 0.0
var _anim_state := ""
var _cape_v := 0.0
var _cape_a := 0.0
var _prev_pos := Vector3.ZERO

static var _shader: Shader
static func char_mat(c: Color, kind: int, rough: float = 0.7, metal: float = 0.0, emis: Color = Color.BLACK, ei: float = 0.0) -> ShaderMaterial:
	if _shader == null: _shader = load("res://shaders/3d/char.gdshader")
	var m := ShaderMaterial.new()
	m.shader = _shader
	m.set_shader_parameter("albedo", c)
	m.set_shader_parameter("kind", kind)
	m.set_shader_parameter("roughness", rough)
	m.set_shader_parameter("metallic", metal)
	m.set_shader_parameter("emission", emis)
	m.set_shader_parameter("emission_energy", ei)
	return m

func build(id: String, c: Color) -> void:
	hero_id = id
	col = c
	var p := Models.find_asset("heroes", id)
	if p != "" and load(p) is PackedScene:
		override = load(p).instantiate()
		add_child(override)
		anim = _find_anim(override)
		return
	_build_procedural()

func _find_anim(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer: return n
	for ch in n.get_children():
		var a := _find_anim(ch)
		if a != null: return a
	return null

func _m(c: Color, kind: int, rough: float = 0.7, metal: float = 0.0, emis: Color = Color.BLACK, ei: float = 0.0) -> ShaderMaterial:
	var m := char_mat(c, kind, rough, metal, emis, ei)
	_mats.append(m)
	if kind >= 4: _glow_mats.append(m)
	return m

func _piv(parent: Node3D, pos: Vector3, rot: Vector3 = Vector3.ZERO) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	n.rotation = rot
	parent.add_child(n)
	return n

func _part(parent: Node3D, mesh: Mesh, mat: Material, pos: Vector3, scl: Vector3, rot: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.scale = scl
	mi.rotation = rot
	parent.add_child(mi)
	return mi

static var _box: BoxMesh
static var _sph: SphereMesh
static var _hemi: SphereMesh
static var _cyl: CylinderMesh
static var _cone: CylinderMesh
static var _oct: SphereMesh
static var _tor: TorusMesh
static var _prism: PrismMesh
static func _prims() -> void:
	if _box != null: return
	_box = BoxMesh.new()
	_sph = SphereMesh.new(); _sph.radius = 0.5; _sph.height = 1.0; _sph.radial_segments = 20; _sph.rings = 10
	_hemi = SphereMesh.new(); _hemi.radius = 0.5; _hemi.height = 0.5; _hemi.is_hemisphere = true; _hemi.radial_segments = 18; _hemi.rings = 6
	_cyl = CylinderMesh.new(); _cyl.top_radius = 0.5; _cyl.bottom_radius = 0.5; _cyl.height = 1.0; _cyl.radial_segments = 14
	_cone = CylinderMesh.new(); _cone.top_radius = 0.0; _cone.bottom_radius = 0.5; _cone.height = 1.0; _cone.radial_segments = 14
	_oct = SphereMesh.new(); _oct.radius = 0.5; _oct.height = 1.0; _oct.radial_segments = 4; _oct.rings = 2
	_tor = TorusMesh.new(); _tor.inner_radius = 0.78; _tor.outer_radius = 1.0; _tor.rings = 24; _tor.ring_segments = 8
	_prism = PrismMesh.new()

static var _tcache := {}
static func _taper(top: float, bottom: float) -> CylinderMesh:
	var key := "%.2f_%.2f" % [top, bottom]
	if _tcache.has(key): return _tcache[key]
	var c := CylinderMesh.new()
	c.top_radius = top; c.bottom_radius = bottom; c.height = 1.0; c.radial_segments = 16; c.rings = 1
	_tcache[key] = c
	return c

func _build_procedural() -> void:
	_prims()
	var caster := hero_id != "warden"
	var skin := _m(Color("b08a6c"), 3)
	var gamb := _m(Color("5a5048"), 0)
	var dye := col.lerp(Color(0.42, 0.4, 0.38), 0.55).darkened(0.35)     # muted PoE2 cloth
	var cloth := _m(dye, 0)
	var cloth_d := _m(dye.darkened(0.4), 0)
	var leather := _m(Color("4a3426"), 1, 0.6)
	var leather_d := _m(Color("2c211b"), 1, 0.65)
	var steel := _m(Color("a9aeb8"), 2, 0.35, 0.8)
	var steel_d := _m(Color("5c606a"), 2, 0.45, 0.75)
	var brass := _m(Color("c9973e"), 2, 0.3, 0.85)
	var rune := _m(col.lightened(0.4), 4, 0.3, 0.0, col, 2.2)
	hips = _piv(self, Vector3(0, 21, 0))
	torso = _piv(hips, Vector3(0, 1, 0))
	# ---- legs: thigh, knee, shin (own pivot), boot with cuff
	leg_l = _piv(hips, Vector3(0, -0.5, -3.1))
	leg_r = _piv(hips, Vector3(0, -0.5, 3.1))
	for lg in [leg_l, leg_r]:
		_part(lg, _taper(2.4, 1.8), gamb if not caster else leather_d, Vector3(0, -5.5, 0), Vector3(1, 11, 1))
		var sh := _piv(lg, Vector3(0, -11, 0))
		if lg == leg_l: shin_l = sh
		else: shin_r = sh
		_part(sh, _sph, steel if not caster else leather, Vector3(0.6, 0, 0), Vector3(3.6, 3.2, 3.4))
		_part(sh, _taper(1.9, 1.5), steel if not caster else leather_d, Vector3(0.2, -4.8, 0), Vector3(1, 9.5, 1))
		_part(sh, _box, steel_d if not caster else leather_d, Vector3(1.3, -9.6, 0), Vector3(6.6, 2.6, 4.2))
		_part(sh, _taper(2.1, 2.1), leather, Vector3(0.2, -7.2, 0), Vector3(1, 1.4, 1))
	# ---- pelvis and belt with buckle and pouches
	_part(hips, _taper(4.6, 4.2), leather, Vector3(0, 0.6, 0), Vector3(1, 3.2, 1.2))
	_part(hips, _box, brass, Vector3(4.6, 0.6, 0), Vector3(0.8, 2.2, 2.6))
	_part(hips, _box, leather_d, Vector3(2.0, -0.6, -5.2), Vector3(3, 3.4, 1.6))
	_part(hips, _box, leather_d, Vector3(-1.6, -0.6, 5.2), Vector3(3, 3.4, 1.6))
	# ---- torso: gambeson/robe body, neck, head
	_part(torso, _taper(5.6, 4.3), gamb if not caster else cloth, Vector3(0, 7, 0), Vector3(1.0, 13, 1.25))
	_part(torso, _taper(1.5, 1.7), skin, Vector3(0, 14.6, 0), Vector3(1, 2.6, 1))
	head = _piv(torso, Vector3(0, 18.6, 0))
	_part(head, _sph, skin, Vector3.ZERO, Vector3(6.4, 7.0, 6.2))
	_part(head, _sph, skin, Vector3(1.2, -2.0, 0), Vector3(3.2, 2.2, 4.0))                  # jaw
	_part(head, _box, _m(Color("1a1412"), 1), Vector3(2.9, 0.5, 1.3), Vector3(0.5, 0.8, 1.0))
	_part(head, _box, _m(Color("1a1412"), 1), Vector3(2.9, 0.5, -1.3), Vector3(0.5, 0.8, 1.0))
	# ---- arms: shoulder, upper arm, elbow pivot, forearm, hand
	arm_l = _piv(torso, Vector3(0, 12.4, -6.4))
	arm_r = _piv(torso, Vector3(0, 12.4, 6.4))
	for ar in [arm_l, arm_r]:
		_part(ar, _sph, gamb if not caster else cloth, Vector3(0, -0.5, 0), Vector3(4.4, 4.0, 4.4))
		_part(ar, _taper(1.6, 1.35), gamb if not caster else cloth, Vector3(0, -4.8, 0), Vector3(1, 8, 1))
		var fo := _piv(ar, Vector3(0, -9, 0))
		if ar == arm_l: fore_l = fo
		else: fore_r = fo
		_part(fo, _taper(1.45, 1.2), steel if not caster else leather, Vector3(0.4, -3.4, 0), Vector3(1, 7, 1))
		_part(fo, _sph, steel_d if not caster else skin, Vector3(0.6, -7.4, 0), Vector3(2.6, 2.6, 2.4))
	var hand := _piv(fore_r, Vector3(0.6, -7.4, 0))
	weapon = _piv(hand, Vector3.ZERO)
	weapon.rotation.z = -0.25 if caster else -1.15
	# ---- cape: four chained cloth segments with a tattered hem
	var cp := _piv(torso, Vector3(-4.0, 13.4, 0))
	for i in 4:
		var seg := _piv(cp if i == 0 else cape[i - 1], Vector3(0, 0, 0) if i == 0 else Vector3(0, -6.2, 0))
		_part(seg, _box, cloth_d if not caster else cloth_d, Vector3(-0.5, -3.1, 0), Vector3(0.9, 6.4, 11.0 + i * 0.8))
		cape.append(seg)
	for k in 4:
		_part(cape[3], _prism, cloth_d, Vector3(-0.5, -7.4, -4.2 + k * 2.8), Vector3(0.8, 2.6 + (k % 2) * 1.4, 2.6), Vector3(PI, 0, 0))
	match hero_id:
		"warden": _warden(steel, steel_d, brass, leather, cloth, rune)
		"spark": _spark(cloth, cloth_d, leather, brass, skin)
		"ember": _ember(cloth, cloth_d, leather, steel_d, skin)
		_: _storm(cloth, cloth_d, leather, brass, skin)

# ---------------------------------------------------------------- class kits
func _warden(steel: Material, steel_d: Material, brass: Material, leather: Material, cloth: Material, rune: Material) -> void:
	_part(torso, _taper(6.2, 4.9), steel, Vector3(0.4, 9, 0), Vector3(1.0, 9.5, 1.28))       # breastplate
	_part(torso, _taper(4.9, 4.6), steel_d, Vector3(0.3, 3.4, 0), Vector3(1.0, 3.2, 1.25))   # plackart
	_part(torso, _tor, steel_d, Vector3(0, 14.2, 0), Vector3(2.4, 2.0, 2.4))                 # gorget
	_part(torso, _box, cloth, Vector3(4.6, -3, 0), Vector3(0.6, 12, 6.5))                   # tabard front
	_part(torso, _box, brass, Vector3(4.9, 6.5, 0), Vector3(0.4, 2.2, 2.2))                 # crest on the chest
	for side in [-1.0, 1.0]:                                                                 # tassets
		_part(hips, _box, steel, Vector3(1.5, -3.4, 4.4 * side), Vector3(5.5, 6.0, 0.8), Vector3(0.18 * side, 0, 0))
	for ar in [arm_l, arm_r]:                                                                # layered lames, flat and dark
		var side := -1.0 if ar == arm_l else 1.0
		for k in 3:
			_part(ar, _hemi, steel_d if k > 0 else steel, Vector3(0, 1.4 - k * 1.6, side * 0.6 * k), Vector3(6.6 - k * 0.5, 2.6, 6.2 - k * 0.4), Vector3(side * (0.25 + k * 0.12), 0, 0))
	# sallet helm with visor slit and a plume
	_part(head, _sph, steel, Vector3(-0.3, 1.0, 0), Vector3(7.4, 7.4, 7.2))
	_part(head, _box, _m(Color("0c0b0d"), 1), Vector3(3.5, 0.6, 0), Vector3(0.5, 0.9, 5.2))
	_part(head, _taper(0.5, 3.8), steel, Vector3(-3.3, -1.6, 0), Vector3(1, 2.4, 1), Vector3(0, 0, 1.0))
	for k in 4:
		_part(head, _cone, _m(Color("8c1c1c"), 0), Vector3(-1.5 - k * 1.6, 5.2 - k * 0.6, 0), Vector3(1.6, 4.6, 1.2), Vector3(0, 0, 1.25 + k * 0.12))
	# bastard sword with glowing fuller runes
	_part(weapon, _box, steel, Vector3(0, 14, 0), Vector3(1.0, 22, 2.8))
	_part(weapon, _box, rune, Vector3(0.55, 13, 0), Vector3(0.1, 16, 0.5))
	_part(weapon, _box, brass, Vector3(0, 2.6, 0), Vector3(1.6, 1.4, 8.4))
	_part(weapon, _taper(0.8, 0.8), leather, Vector3(0, -0.8, 0), Vector3(1, 5, 1))
	_part(weapon, _sph, brass, Vector3(0, -3.6, 0), Vector3(1.8, 1.8, 1.8))
	# heater shield on the left forearm with a rim and a glowing boss
	var sh := _piv(fore_l, Vector3(2.4, -3.5, 0))                                            # dark oak heater shield
	var oak := _m(Color("3a2a1e"), 1, 0.8)
	_part(sh, _box, oak, Vector3(0, 0, 0), Vector3(1.4, 13, 10))
	_part(sh, _prism, oak, Vector3(0, -8.6, 0), Vector3(1.4, 4.2, 10), Vector3(PI, 0, 0))
	_part(sh, _box, steel_d, Vector3(0.2, 6.4, 0), Vector3(1.7, 1.0, 10.6))
	_part(sh, _box, steel_d, Vector3(0.2, 0, 5.1), Vector3(1.7, 13, 0.8))
	_part(sh, _box, steel_d, Vector3(0.2, 0, -5.1), Vector3(1.7, 13, 0.8))
	_part(sh, _box, _m(col.darkened(0.2), 0), Vector3(0.75, 1, 0), Vector3(0.2, 7, 4.2))     # painted heraldry in the hero colour
	_part(sh, _sph, rune, Vector3(0.9, 1, 0), Vector3(1.0, 2.0, 2.0))

## Robe: one continuous flared skirt split into a front and back panel that swing separately,
## with a dark hem band (loop 1: stacked tiers read as lampshades).
func _robe(cloth: Material, cloth_d: Material, n: int, flare: float) -> void:
	var h := 6.0 + n * 4.0
	for side in [1.0, -1.0]:
		var s := _piv(hips, Vector3(0.4 * side, -0.6, 0))
		_part(s, _taper(4.7, 4.9 + flare * n * 1.6), cloth, Vector3(0.9 * side, -h * 0.5, 0), Vector3(0.62, h, 1.18))
		_part(s, _taper(4.9 + flare * n * 1.6, 5.0 + flare * n * 1.7), cloth_d, Vector3(0.9 * side, -h + 0.4, 0), Vector3(0.64, 1.0, 1.2))
		skirt.append(s)

func _spark(cloth: Material, cloth_d: Material, leather: Material, brass: Material, skin: Material) -> void:
	_robe(cloth, cloth_d, 3, 0.55)
	var fur := _m(Color("d8dde2"), 0, 0.95)
	_part(torso, _tor, fur, Vector3(0, 13.2, 0), Vector3(6.6, 4.0, 7.0))                    # fur mantle
	_part(torso, _taper(4.6, 4.4), leather, Vector3(0, 2.2, 0), Vector3(1, 2.2, 1.2))
	var ice := _m(Color("bdf3ff"), 5, 0.1, 0.0, Color("5ad6ff"), 1.6)
	for k in 3: _part(hips, _oct, ice, Vector3(4.2, -2.2, -2.4 + k * 2.4), Vector3(1.1, 2.0, 1.1))     # belt talismans
	_part(head, _sph, cloth_d, Vector3(-1.8, 1.2, 0), Vector3(8.2, 8.6, 8.0))                   # deep cowl, face showing
	_part(head, _tor, cloth_d, Vector3(1.2, 0.8, 0), Vector3(3.9, 4.6, 3.9), Vector3(0, 0, PI / 2))   # cowl rim
	_part(head, _box, _m(Color("9fefff"), 4, 0.2, 0.0, Color("5ad6ff"), 1.6), Vector3(3.0, 0.7, 0), Vector3(0.25, 0.6, 3.2))     # frost goggles band
	var wood := _m(Color("4a3220"), 1, 0.75)
	_part(weapon, _taper(0.55, 0.65), wood, Vector3(0, 12, 0), Vector3(1, 38, 1))
	for k in 3: _part(weapon, _tor, brass, Vector3(0, 6 + k * 9, 0), Vector3(0.9, 0.8, 0.9))
	for k in 3:
		var a := TAU * k / 3.0
		_part(weapon, _prism, brass, Vector3(cos(a) * 1.4, 31.5, sin(a) * 1.4), Vector3(0.8, 5.0, 0.8), Vector3(sin(a) * 0.35, 0, -cos(a) * 0.35))
	_part(weapon, _oct, ice, Vector3(0, 34, 0), Vector3(3.4, 7.0, 3.4))

func _ember(cloth: Material, cloth_d: Material, leather: Material, steel_d: Material, skin: Material) -> void:
	_robe(cloth_d, cloth, 3, 0.7)
	var hem := _m(Color("ffb070"), 4, 0.3, 0.0, Color("ff5a1a"), 1.4)
	_part(skirt[0], _taper(5.9, 6.0), hem, Vector3(0.9, -17.6, 0), Vector3(0.66, 0.5, 1.22))      # ember-lit hem
	_part(skirt[1], _taper(5.9, 6.0), hem, Vector3(-0.9, -17.6, 0), Vector3(0.66, 0.5, 1.22))
	_part(torso, _taper(5.0, 4.3), leather, Vector3(0, 5.5, 0), Vector3(1, 6.5, 1.2))          # corset
	var bone := _m(Color("e8dcc6"), 1, 0.6)
	_part(hips, _sph, bone, Vector3(4.6, -2.4, 2.4), Vector3(2.4, 2.6, 2.2))                    # skull talisman
	var hair := _m(Color("2a1416"), 0, 0.8)
	for k in 5: _part(head, _box, hair, Vector3(-2.6, -2.5 - k * 0.3, -3.0 + k * 1.5), Vector3(1.2, 7 + k % 2 * 2, 1.2), Vector3(0, 0, 0.25))
	_part(head, _cyl, cloth_d, Vector3(0, 3.0, 0), Vector3(15, 0.7, 15))                       # wide brim
	_part(head, _taper(0.4, 3.8), cloth_d, Vector3(-1.4, 8.5, 0), Vector3(1, 11, 1), Vector3(0, 0, 0.35))
	_part(head, _cone, cloth_d, Vector3(-5.3, 13.6, 0), Vector3(1.4, 4, 1.4), Vector3(0, 0, 1.6))    # bent tip
	var wood := _m(Color("2e1d14"), 1, 0.8)
	_part(weapon, _taper(0.55, 0.75), wood, Vector3(0, 12, 0), Vector3(1, 36, 1))
	for k in 4: _part(weapon, _cone, wood, Vector3(0, 30, 0), Vector3(1.1, 7, 1.1), Vector3(0.6 * cos(k * 1.57), k * 1.57, 0.6 * sin(k * 1.57)))   # gnarled claw
	_part(weapon, _sph, _m(Color("ffd0a0"), 4, 0.2, 0.0, Color("ff5a1a"), 3.0), Vector3(0, 32, 0), Vector3(4.2, 4.2, 4.2))

func _storm(cloth: Material, cloth_d: Material, leather: Material, brass: Material, skin: Material) -> void:
	_part(torso, _taper(7.2, 5.6), cloth_d, Vector3(-0.4, 12, 0), Vector3(1.0, 3.6, 1.35))     # mantle
	_part(torso, _box, cloth, Vector3(4.4, -2, 0), Vector3(0.5, 13, 5.5))                      # sash
	_robe(cloth_d, cloth, 2, 0.4)
	var tattoo := _m(Color("d8c8ff"), 4, 0.3, 0.0, Color("b890ff"), 1.8)
	for fo in [fore_l, fore_r]:
		for k in 3: _part(fo, _tor, tattoo, Vector3(0.4, -1.5 - k * 1.6, 0), Vector3(1.5, 0.6, 1.5))
	_part(head, _taper(3.5, 3.5), brass, Vector3(0, 3.6, 0), Vector3(1, 1.4, 1))
	var horn := _m(Color("d0c4ea"), 1, 0.45)
	_part(head, _cone, horn, Vector3(-0.5, 7.5, 3.2), Vector3(1.5, 8, 1.5), Vector3(0.4, 0, -0.25))
	_part(head, _cone, horn, Vector3(-0.5, 7.5, -3.2), Vector3(1.5, 8, 1.5), Vector3(-0.4, 0, -0.25))
	var shaft := _m(Color("2c2a3e"), 2, 0.45, 0.6)
	_part(weapon, _taper(0.6, 0.6), shaft, Vector3(0, 11, 0), Vector3(1, 34, 1))
	var crys := _m(Color("e2d6ff"), 5, 0.1, 0.0, Color("b890ff"), 1.8)
	_part(weapon, _oct, crys, Vector3(0, 30, 0), Vector3(3.0, 6.4, 3.0))
	_part(weapon, _box, brass, Vector3(0, 28, 3.2), Vector3(0.7, 9, 0.7), Vector3(0.5, 0, 0))
	_part(weapon, _box, brass, Vector3(0, 28, -3.2), Vector3(0.7, 9, 0.7), Vector3(-0.5, 0, 0))

## st: {pos, face, mv, ph, cast_age, cast_dir, roll (0..1 or -1), hit (0..1), dead, t}
func animate(st: Dictionary, dt: float) -> void:
	var p: Vector2 = st.pos
	position = Vector3(p.x, 0.0, p.y)
	var want: Vector2 = st.face
	if float(st.cast_age) < 0.35: want = st.cast_dir
	_yaw = lerp_angle(_yaw, atan2(-want.y, want.x), minf(1.0, dt * 16.0))
	rotation.y = _yaw
	_cast = clampf(1.0 - float(st.cast_age) / 0.3, 0.0, 1.0)
	_hit = maxf(_hit - dt * 6.0, float(st.hit))
	if st.dead: _dead = minf(1.0, _dead + dt * 2.0)
	var t: float = st.t
	for m in _mats:
		m.set_shader_parameter("flash", _hit * _hit * 0.9)
	if override != null:
		_animate_override(st)
		return
	var mv: float = st.mv
	var ph: float = st.ph
	var sw := sin(ph) * 0.7 * mv
	var cast_k := sin(_cast * PI * 0.5)
	leg_l.rotation.z = sw
	leg_r.rotation.z = -sw
	shin_l.rotation.z = -maxf(0.0, -sin(ph)) * 0.9 * mv                 # knee bends on the back swing
	shin_r.rotation.z = -maxf(0.0, sin(ph)) * 0.9 * mv
	arm_l.rotation.z = -sw * 0.8 + cast_k * 0.5
	arm_r.rotation.z = sw * 0.8 - cast_k * 1.6
	arm_r.rotation.x = -cast_k * 0.3
	fore_l.rotation.z = 0.35 + 0.25 * mv
	fore_r.rotation.z = 0.3 + 0.2 * mv - cast_k * 0.3
	torso.rotation.z = -0.18 * mv - 0.14 * cast_k + _hit * 0.35
	torso.rotation.y = sin(ph) * 0.14 * mv + cast_k * 0.25
	torso.scale = Vector3(1, 1.0 + sin(t * 2.2) * 0.018 * (1.0 - mv), 1)
	hips.position.y = 21.0 + absf(sin(ph)) * 1.6 * mv - _hit * 1.5
	head.rotation.z = 0.1 * mv - _hit * 0.3
	# cape: a damped spring driven by speed and turning, plus flutter that grows with speed
	var spd := (position - _prev_pos).length() / maxf(dt, 0.001)
	_prev_pos = position
	var target := -0.12 - clampf(spd / 220.0, 0.0, 1.0) * 0.95
	_cape_v += ((target - _cape_a) * 60.0 - _cape_v * 9.0) * dt
	_cape_a += _cape_v * dt
	for i in cape.size():
		cape[i].rotation.z = (_cape_a if i == 0 else _cape_a * 0.25) + sin(t * 8.0 - i * 0.9) * (0.04 + 0.1 * mv) * (i + 1) * 0.5
		cape[i].rotation.x = sin(t * 5.3 - i * 1.3) * 0.05 * (i + 1) * mv
	for i in skirt.size():
		var sd := 1.0 if i == 0 else -1.0            # front panel kicks forward with the stride, back panel trails
		skirt[i].rotation.z = -absf(sw) * 0.35 * sd - 0.12 * mv * (1.0 - sd) * 0.5
		skirt[i].rotation.x = sin(ph + i) * 0.05 * mv
	for m in _glow_mats:
		m.set_shader_parameter("pulse", cast_k * 2.5 + 0.15 * sin(t * 3.0))
	var roll: float = st.roll
	if roll >= 0.0:
		hips.rotation.z = -roll * TAU
		hips.position.y = 12.0 + sin(roll * PI) * 6.0
		leg_l.rotation.z = 1.2
		leg_r.rotation.z = 1.2
		shin_l.rotation.z = -1.6
		shin_r.rotation.z = -1.6
	else:
		hips.rotation.z = 0.0
	if _dead > 0.0:
		rotation.z = -_dead * PI * 0.5
		position.y = -_dead * 4.0

func _animate_override(st: Dictionary) -> void:
	if anim == null: return
	var want := "run" if float(st.mv) > 0.2 else "idle"
	if float(st.roll) >= 0.0: want = "roll"
	elif _hit > 0.5: want = "hit"
	elif float(st.cast_age) < 0.3: want = "cast"
	if st.dead: want = "die"
	if want != _anim_state and anim.has_animation(want):
		_anim_state = want
		anim.play(want, 0.12)
