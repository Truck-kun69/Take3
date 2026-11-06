class_name BossRig
extends Node3D
## Hierarchical bosses. kind "tyrant" (stage boss and rift guardian): horned demon lord with a
## glowing ribcage furnace, wings or cloak, swinging weapon arms and a slam wind-up.
## kind "herald": the pinnacle, a floating crystal star with orbiting shards and a pulsing core.
## Override: res://models/bosses/<tyrant|herald|guardian>.(tscn|glb), AnimationPlayer clips
## idle / walk / attack / hit / die.

var kind := "tyrant"
var col := Color.WHITE
var root: Node3D
var legs: Array[Node3D] = []
var arms: Array[Node3D] = []
var wings: Array[Node3D] = []
var head: Node3D
var core_mat: StandardMaterial3D
var shards: Array[Node3D] = []
var flash_mats: Array[StandardMaterial3D] = []
var light: OmniLight3D
var override: Node3D
var anim: AnimationPlayer
var _yaw := 0.0
var _ph := 0.0
var _atk := 0.0

func build(k: String, c: Color, slot: String) -> void:
	kind = k
	col = c
	var p := Models.find_asset("bosses", slot)
	light = OmniLight3D.new()
	light.light_color = c
	light.omni_range = 220.0
	light.omni_attenuation = WorldView3D.LIGHT_ATT
	light.light_energy = 2.0 * WorldView3D.LIGHT_GAIN
	light.shadow_enabled = false
	add_child(light)
	if p != "" and load(p) is PackedScene:
		override = load(p).instantiate()
		add_child(override)
		anim = override.find_child("AnimationPlayer", true, false) as AnimationPlayer
		return
	if k == "herald": _build_herald()
	else: _build_tyrant()

func _m(c: Color, rough: float = 0.6, metal: float = 0.0, emis: Color = Color.BLACK, ei: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c; m.roughness = rough; m.metallic = metal
	m.emission_enabled = true
	if ei > 0.0:
		m.emission = emis; m.emission_energy_multiplier = ei
	else:
		m.emission = Color.WHITE; m.emission_energy_multiplier = 0.0
		flash_mats.append(m)
	m.rim_enabled = true
	m.rim = 0.4
	return m

func _p(parent: Node3D, mesh: Mesh, mat: Material, pos: Vector3, scl: Vector3, rot: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh; mi.material_override = mat; mi.position = pos; mi.scale = scl; mi.rotation = rot
	parent.add_child(mi)
	return mi

func _n(parent: Node3D, pos: Vector3) -> Node3D:
	var n := Node3D.new(); n.position = pos; parent.add_child(n); return n

func _build_tyrant() -> void:
	HeroRig._prims()
	var hide_m := _m(col.darkened(0.55), 0.8)
	var plate := _m(col.darkened(0.2), 0.45, 0.3)
	var bone := _m(Color("e8e0d0"), 0.6)
	core_mat = _m(col.lightened(0.2), 0.2, 0.0, col, 5.0)
	var eye := _m(Color.WHITE, 0.2, 0.0, Color("ff5030"), 6.0)
	root = _n(self, Vector3(0, 48, 0))
	for s in [-1.0, 1.0]:
		var lg := _n(root, Vector3(0, 0, 12.0 * s))
		_p(lg, HeroRig._box, hide_m, Vector3(0, -22, 0), Vector3(13, 44, 13))
		_p(lg, HeroRig._box, plate, Vector3(4, -46, 0), Vector3(20, 8, 15))
		legs.append(lg)
	var body := _p(root, HeroRig._sph, hide_m, Vector3(0, 30, 0), Vector3(38, 52, 46))
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_p(root, HeroRig._sph, core_mat, Vector3(14, 32, 0), Vector3(14, 18, 18))
	for r in 4:
		_p(root, HeroRig._box, bone, Vector3(17, 22 + r * 6, 0), Vector3(3, 2.5, 30), Vector3(0, 0, 0.2))
	head = _n(root, Vector3(10, 62, 0))
	_p(head, HeroRig._sph, plate, Vector3.ZERO, Vector3(20, 18, 20))
	_p(head, HeroRig._box, eye, Vector3(9, 1, 4), Vector3(2, 2, 3))
	_p(head, HeroRig._box, eye, Vector3(9, 1, -4), Vector3(2, 2, 3))
	for s in [-1.0, 1.0]:
		_p(head, HeroRig._cone, bone, Vector3(-2, 12, 9 * s), Vector3(5, 22, 5), Vector3(0.5 * s, 0, 0.5))
		var ar := _n(root, Vector3(4, 46, 26 * s))
		_p(ar, HeroRig._box, hide_m, Vector3(0, -16, 0), Vector3(11, 32, 11))
		_p(ar, HeroRig._sph, plate, Vector3(0, 0, 0), Vector3(18, 14, 18))
		_p(ar, HeroRig._cone, bone, Vector3(4, -36, 0), Vector3(9, 20, 9), Vector3(0, 0, PI * 0.9))
		arms.append(ar)
		var wg := _n(root, Vector3(-16, 50, 10 * s))
		var wm := _m(col.darkened(0.6), 0.9)
		wm.cull_mode = BaseMaterial3D.CULL_DISABLED
		_p(wg, HeroRig._box, wm, Vector3(-18, 8, 22 * s), Vector3(40, 1.5, 44), Vector3(0.3 * s, 0, 0.4))
		wings.append(wg)
	light.position = Vector3(30, 80, 0)

func _build_herald() -> void:
	HeroRig._prims()
	var crys := _m(Color(0.62, 0.45, 0.95, 0.72), 0.1, 0.2)
	crys.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA                 # the core glows through the shell
	crys.rim = 0.8
	crys.rim_tint = 0.6
	core_mat = _m(Color("f0e0ff"), 0.1, 0.0, Color("b070ff"), 3.0)
	root = _n(self, Vector3(0, 70, 0))
	_p(root, HeroRig._oct, crys, Vector3(0, 0, 0), Vector3(40, 90, 40))
	_p(root, HeroRig._sph, core_mat, Vector3(0, 0, 0), Vector3(22, 22, 22))
	for i in 8:
		var s := _n(root, Vector3.ZERO)
		var a := TAU * i / 8.0
		_p(s, HeroRig._oct, crys, Vector3(cos(a) * 60.0, sin(i * 1.7) * 12.0, sin(a) * 60.0), Vector3(10, 26, 10), Vector3(0.4, a, 0.3))
		shards.append(s)
	var halo := TorusMesh.new()
	halo.inner_radius = 0.92; halo.outer_radius = 1.0; halo.rings = 48
	_p(root, halo, _m(Color("d0b0ff"), 0.2, 0.0, Color("9a60ff"), 1.5), Vector3(0, 40, 0), Vector3(36, 36, 36))
	light.position = Vector3(0, 70, 0)
	light.light_energy = 4.0
	light.omni_range = 360.0

## st: {pos, face, hp_frac, flash, t, dt, attack (bool, set on telegraph/burst), phase}
func animate(st: Dictionary) -> void:
	var p: Vector2 = st.pos
	var dt: float = st.dt
	position = Vector3(p.x, 0, p.y)
	var f: Vector2 = st.face
	_yaw = lerp_angle(_yaw, atan2(-f.y, f.x), minf(1.0, dt * 4.0))
	rotation.y = _yaw
	if st.attack: _atk = 1.0
	_atk = maxf(0.0, _atk - dt * 1.6)
	var t: float = st.t
	if override != null:
		if anim != null:
			var want := "attack" if _atk > 0.3 else "walk"
			if anim.has_animation(want) and anim.current_animation != want: anim.play(want, 0.2)
		return
	var fl := clampf(float(st.flash) * 10.0, 0.0, 1.0)
	for m in flash_mats:
		m.emission = col.lightened(0.5)
		m.emission_energy_multiplier = fl * fl * fl * 0.5
	var pulse := 0.5 + 0.5 * sin(t * (3.0 + 4.0 * (1.0 - float(st.hp_frac))))
	if core_mat != null: core_mat.emission_energy_multiplier = (2.0 + pulse * 3.0) if kind == "herald" else (3.0 + pulse * 4.0)
	light.light_energy = (2.0 + pulse * 2.5) * WorldView3D.LIGHT_GAIN
	if kind == "herald":
		root.position.y = 70.0 + sin(t * 1.3) * 8.0
		root.rotation.y = t * 0.4
		for i in shards.size():
			shards[i].rotation.y = t * (0.6 + 0.1 * i) * (1.0 + float(st.phase) * 0.5)
			shards[i].position.y = sin(t * 2.0 + i) * 10.0
		root.scale = Vector3.ONE * (1.0 + _atk * 0.12)
		return
	_ph += dt * 4.5
	var sw := sin(_ph) * 0.45
	legs[0].rotation.z = sw
	legs[1].rotation.z = -sw
	root.position.y = 48.0 + absf(sin(_ph)) * 3.0
	# slam wind-up: both arms rise then crash down
	var raise := sin(clampf(_atk, 0.0, 1.0) * PI)
	for i in arms.size():
		arms[i].rotation.z = -sw * 0.6 * (1.0 if i == 0 else -1.0) - raise * 2.4
	for i in wings.size():
		wings[i].rotation.x = sin(t * 3.0) * 0.25 * (1.0 if i == 0 else -1.0)
	head.rotation.z = -0.15 + sin(t * 1.5) * 0.08 - raise * 0.3
	root.rotation.z = -0.1 - raise * 0.15
