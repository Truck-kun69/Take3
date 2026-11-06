class_name HeroRig
extends Node3D
## Articulated procedural hero (~42 units tall, faces +X). Pivots: hips -> torso -> head/arms -> weapon.
## States are blended procedurally every frame from the simulation: run (gait from walk phase and
## speed), cast (arm thrust toward the cast direction, upper body twists to face it), roll (tuck and
## forward flip with stretch), hit (recoil + white flash), death (topple), idle (breathing).
##
## Authored override: res://models/heroes/<id>.(tscn|glb). If it has an AnimationPlayer, the clips
## idle / run / cast / roll / hit / die are played instead, with the same facing logic.

var hero_id := "warden"
var col := Color.WHITE
var hips: Node3D
var torso: Node3D
var head: Node3D
var arm_l: Node3D
var arm_r: Node3D
var leg_l: Node3D
var leg_r: Node3D
var weapon: Node3D
var cape: Node3D
var focus: MeshInstance3D
var _mats: Array[StandardMaterial3D] = []
var _flash_mats: Array[StandardMaterial3D] = []
var override: Node3D
var anim: AnimationPlayer
var _yaw := 0.0
var _cast := 0.0
var _cast_dir := Vector2.RIGHT
var _hit := 0.0
var _dead := 0.0
var _anim_state := ""

func build(id: String, c: Color) -> void:
	hero_id = id
	col = c
	var p := Models.find_asset("heroes", id)
	if p != "":
		var r = load(p)
		if r is PackedScene:
			override = r.instantiate()
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

func _mat(c: Color, rough: float = 0.7, metal: float = 0.0, emis: Color = Color.BLACK, ei: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	if ei > 0.0:
		m.emission_enabled = true
		m.emission = emis
		m.emission_energy_multiplier = ei
	else:
		m.emission_enabled = true          # used for the hit flash
		m.emission = Color.WHITE
		m.emission_energy_multiplier = 0.0
		_flash_mats.append(m)
	m.rim_enabled = true
	m.rim = 0.6
	m.rim_tint = 0.3
	_mats.append(m)
	return m

func _piv(parent: Node3D, pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	parent.add_child(n)
	return n

func _part(parent: Node3D, mesh: Mesh, mat: Material, pos: Vector3, scl: Vector3, rot: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.scale = scl
	mi.rotation = rot
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(mi)
	return mi

static var _box: BoxMesh
static var _sph: SphereMesh
static var _cyl: CylinderMesh
static var _cone: CylinderMesh
static var _oct: SphereMesh
static func _prims() -> void:
	if _box != null: return
	_box = BoxMesh.new()
	_sph = SphereMesh.new(); _sph.radius = 0.5; _sph.height = 1.0; _sph.radial_segments = 16; _sph.rings = 8
	_cyl = CylinderMesh.new(); _cyl.top_radius = 0.5; _cyl.bottom_radius = 0.5; _cyl.height = 1.0; _cyl.radial_segments = 12
	_cone = CylinderMesh.new(); _cone.top_radius = 0.0; _cone.bottom_radius = 0.5; _cone.height = 1.0; _cone.radial_segments = 12
	_oct = SphereMesh.new(); _oct.radius = 0.5; _oct.height = 1.0; _oct.radial_segments = 4; _oct.rings = 2

static var _tcache := {}
## Tapered cylinder (frustum) meshes, cached by radii.
static func _taper(top: float, bottom: float) -> CylinderMesh:
	var key := "%.2f_%.2f" % [top, bottom]
	if _tcache.has(key): return _tcache[key]
	var c := CylinderMesh.new()
	c.top_radius = top; c.bottom_radius = bottom; c.height = 1.0; c.radial_segments = 14; c.rings = 1
	_tcache[key] = c
	return c

## Heroic proportions (~48 units at scale 1): long legs, tapered chest wider at the shoulders,
## a head about 1/7 of the height, rounded limbs, and the class silhouette on top.
func _build_procedural() -> void:
	_prims()
	var skin := _mat(Color("e2bf98"), 0.75)
	var cloth := _mat(col, 0.7, 0.05)
	var cloth_d := _mat(col.darkened(0.5), 0.85)
	var leather := _mat(Color("3a2a22"), 0.7)
	var dark := _mat(Color("22242e"), 0.5, 0.4)
	var steel := _mat(Color("b8bcc8"), 0.35, 0.35)       # low metallic: no sky to reflect, high metallic reads black
	var trim := _mat(Color("e8b848"), 0.35, 0.35)
	var glow := _mat(col.lightened(0.3), 0.3, 0.0, col, 2.5)
	var eyes := _mat(Color.WHITE, 0.2, 0.0, col.lightened(0.5), 2.5)
	hips = _piv(self, Vector3(0, 20, 0))
	torso = _piv(hips, Vector3(0, 1, 0))
	leg_l = _piv(hips, Vector3(0, 0, -3.2))
	leg_r = _piv(hips, Vector3(0, 0, 3.2))
	for lg in [leg_l, leg_r]:
		_part(lg, _taper(2.2, 1.7), dark, Vector3(0, -5.5, 0), Vector3(1, 11, 1))
		_part(lg, _taper(1.7, 1.5), dark, Vector3(0, -14, 0), Vector3(1, 9, 1))
		_part(lg, _box, leather, Vector3(1.4, -19.2, 0), Vector3(6.5, 3.2, 4.2))
	_part(hips, _box, leather, Vector3(0, 0.5, 0), Vector3(7, 4, 10.5))
	_part(torso, _taper(5.6, 4.2), cloth, Vector3(0, 7, 0), Vector3(1.0, 13, 1.25))      # chest, wide at the shoulders
	_part(torso, _taper(4.4, 4.6), trim, Vector3(0, 1.2, 0), Vector3(1.0, 2.0, 1.2))
	_part(torso, _sph, glow, Vector3(4.6, 8.5, 0), Vector3(1.8, 1.8, 1.8))
	_part(torso, _taper(1.4, 1.6), skin, Vector3(0, 14.5, 0), Vector3(1, 2.5, 1))        # neck
	head = _piv(torso, Vector3(0, 18.5, 0))
	_part(head, _sph, skin, Vector3.ZERO, Vector3(6.6, 7.2, 6.4))
	_part(head, _box, eyes, Vector3(3.0, 0.6, 1.3), Vector3(0.5, 0.9, 1.0))
	_part(head, _box, eyes, Vector3(3.0, 0.6, -1.3), Vector3(0.5, 0.9, 1.0))
	arm_l = _piv(torso, Vector3(0, 12.5, -6.6))
	arm_r = _piv(torso, Vector3(0, 12.5, 6.6))
	for ar in [arm_l, arm_r]:
		_part(ar, _sph, cloth, Vector3(0, -0.5, 0), Vector3(4.6, 4.2, 4.6))
		_part(ar, _taper(1.6, 1.3), cloth, Vector3(0, -5, 0), Vector3(1, 8, 1))
		_part(ar, _taper(1.3, 1.1), skin, Vector3(0.6, -11.5, 0), Vector3(1, 7, 1), Vector3(0, 0, 0.12))
		_part(ar, _sph, skin, Vector3(1.0, -15.5, 0), Vector3(2.4, 2.4, 2.4))
	var hand := _piv(arm_r, Vector3(1.0, -15.5, 0))
	weapon = _piv(hand, Vector3.ZERO)
	weapon.rotation.z = -0.25 if hero_id != "warden" else -1.1    # staves upright, the sword angled forward
	cape = _piv(torso, Vector3(-4.2, 13.5, 0))
	_part(cape, _box, cloth_d, Vector3(-0.6, -12, 0), Vector3(1.0, 25, 11.5))
	match hero_id:
		"warden":     # plumed great helm, broad sword, kite shield, pauldrons
			_part(head, _taper(3.6, 3.7), steel, Vector3(0, 0.8, 0), Vector3(1, 7.5, 1))
			_part(head, _box, dark, Vector3(3.3, 0.6, 0), Vector3(0.6, 1.0, 4.4))
			_part(head, _cone, _mat(Color("c8282a"), 0.7), Vector3(-1.5, 7, 0), Vector3(2.2, 7, 1.6), Vector3(0, 0, 0.7))
			_part(weapon, _box, steel, Vector3(0, 13, 0), Vector3(1.2, 22, 3.0))
			_part(weapon, _box, trim, Vector3(0, 1.8, 0), Vector3(1.8, 1.8, 8.5))
			_part(weapon, _box, leather, Vector3(0, -1.5, 0), Vector3(1.6, 5, 1.6))
			_part(arm_l, _box, _mat(Color("8a5a20"), 0.45, 0.6), Vector3(3.2, -9, 0), Vector3(1.6, 13, 9.5))
			_part(arm_l, _sph, trim, Vector3(4.2, -9, 0), Vector3(1.4, 3, 3))
			for side in [-1.0, 1.0]:
				_part(torso, _sph, steel, Vector3(0, 13, 6.6 * side), Vector3(6, 3.6, 6))
		"spark":      # deep hood, frost goggles, long staff with an ice crystal
			_part(head, _sph, cloth, Vector3(-0.9, 1.2, 0), Vector3(7.8, 7.8, 7.6))
			_part(head, _box, _mat(Color("9fefff"), 0.15, 0.0, Color("5ad6ff"), 2.5), Vector3(2.9, 1.0, 0), Vector3(0.8, 1.8, 5.6))
			_part(torso, _taper(5.2, 7.5), cloth_d, Vector3(0, -6, 0), Vector3(1.0, 9, 1.2))     # robe skirt
			_part(weapon, _cyl, _mat(Color("6a4a22"), 0.8), Vector3(0, 12, 0), Vector3(1.0, 36, 1.0))
			focus = _part(weapon, _oct, _mat(Color("c8f6ff"), 0.05, 0.2, Color("5ad6ff"), 3.0), Vector3(0, 32, 0), Vector3(3.2, 6.4, 3.2))
		"ember":      # wide-brimmed witch hat, flame-topped staff, robe
			_part(head, _cyl, cloth, Vector3(0, 2.8, 0), Vector3(14, 0.8, 14))
			_part(head, _cone, cloth, Vector3(-1.2, 9.2, 0), Vector3(7, 12, 7), Vector3(0, 0, 0.3))
			_part(torso, _taper(5.2, 8.0), cloth_d, Vector3(0, -6, 0), Vector3(1.0, 9, 1.2))
			_part(weapon, _cyl, _mat(Color("4a2a1a"), 0.9), Vector3(0, 12, 0), Vector3(1.1, 36, 1.1))
			focus = _part(weapon, _sph, _mat(Color("ffc080"), 0.2, 0.0, Color("ff5a1a"), 3.5), Vector3(0, 31, 0), Vector3(4.2, 4.2, 4.2))
			_part(weapon, _cone, _mat(Color("ffd070"), 0.3, 0.0, Color("ff8a20"), 3.0), Vector3(0, 36, 0), Vector3(2.6, 7, 2.6))
		_:            # stormwright: horned crown, mantle, forked rod
			_part(head, _taper(3.6, 3.6), trim, Vector3(0, 3.8, 0), Vector3(1, 1.6, 1))
			var horn := _mat(Color("d8c8ff"), 0.4, 0.3, Color("b890ff"), 1.2)
			_part(head, _cone, horn, Vector3(0, 8, 3.2), Vector3(1.5, 8, 1.5), Vector3(0.35, 0, 0))
			_part(head, _cone, horn, Vector3(0, 8, -3.2), Vector3(1.5, 8, 1.5), Vector3(-0.35, 0, 0))
			_part(torso, _taper(7.0, 5.6), cloth_d, Vector3(-0.5, 12, 0), Vector3(1.0, 3.5, 1.35))   # mantle
			_part(weapon, _cyl, _mat(Color("3a3656"), 0.5, 0.5), Vector3(0, 11, 0), Vector3(1.1, 32, 1.1))
			focus = _part(weapon, _oct, _mat(Color("ece0ff"), 0.05, 0.2, Color("b890ff"), 3.0), Vector3(0, 29, 0), Vector3(3.2, 5.6, 3.2))
			_part(weapon, _box, horn, Vector3(0, 29, 3.4), Vector3(0.8, 8, 0.8), Vector3(0.45, 0, 0))
			_part(weapon, _box, horn, Vector3(0, 29, -3.4), Vector3(0.8, 8, 0.8), Vector3(-0.45, 0, 0))

## st: {pos, face, mv, ph, cast_age, cast_dir, roll (0..1 or -1), hit (0..1), dead, t}
func animate(st: Dictionary, dt: float) -> void:
	var p: Vector2 = st.pos
	position = Vector3(p.x, 0.0, p.y)
	# facing: cast direction wins for 0.35 s (PoE2: you turn to throw the spell), else movement
	var want: Vector2 = st.face
	if float(st.cast_age) < 0.35: want = st.cast_dir
	var target_yaw := atan2(-want.y, want.x)
	_yaw = lerp_angle(_yaw, target_yaw, minf(1.0, dt * 16.0))
	rotation.y = _yaw
	_cast = clampf(1.0 - float(st.cast_age) / 0.3, 0.0, 1.0)
	_hit = maxf(_hit - dt * 6.0, float(st.hit))
	if st.dead: _dead = minf(1.0, _dead + dt * 2.0)
	if override != null:
		_animate_override(st)
		return
	var mv: float = st.mv
	var ph: float = st.ph
	var sw := sin(ph) * 0.75 * mv
	var t: float = st.t
	leg_l.rotation.z = sw
	leg_r.rotation.z = -sw
	var cast_k := sin(_cast * PI * 0.5)
	arm_l.rotation.z = -sw * 0.8 + cast_k * 0.6
	arm_r.rotation.z = sw * 0.8 - cast_k * 1.5
	arm_r.rotation.x = -cast_k * 0.35
	torso.rotation.z = -0.16 * mv - 0.12 * cast_k + _hit * 0.35
	torso.rotation.y = sin(ph) * 0.12 * mv
	var breath := 1.0 + sin(t * 2.2) * 0.02 * (1.0 - mv)
	torso.scale = Vector3(1, breath, 1)
	hips.position.y = 20.0 + absf(sin(ph)) * 1.6 * mv - _hit * 1.5
	head.rotation.z = 0.1 * mv - _hit * 0.3
	cape.rotation.z = -0.25 - 0.55 * mv + sin(t * 7.0) * 0.08 * (0.3 + mv)
	if focus != null:
		var fm := focus.material_override as StandardMaterial3D
		fm.emission_energy_multiplier = 3.0 + cast_k * 6.0
	# roll: tuck and flip forward
	var roll: float = st.roll
	if roll >= 0.0:
		hips.rotation.z = -roll * TAU
		hips.position.y = 12.0 + sin(roll * PI) * 6.0
		leg_l.rotation.z = 1.2
		leg_r.rotation.z = 1.2
	else:
		hips.rotation.z = 0.0
	# hit flash
	for m in _flash_mats:                          # PoE2-style red hit tint, not a white strobe
		m.emission = Color(1.0, 0.15, 0.1)
		m.emission_energy_multiplier = _hit * _hit * 1.2
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
