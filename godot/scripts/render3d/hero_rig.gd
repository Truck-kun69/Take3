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
static func char_mat(c: Color, kind: int, rough: float = 0.7, metal: float = 0.0, emis: Color = Color.BLACK, ei: float = 0.0, sh: Shader = null) -> ShaderMaterial:
	if _shader == null: _shader = load("res://shaders/3d/char.gdshader")
	var m := ShaderMaterial.new()
	m.shader = sh if sh != null else _shader
	m.set_shader_parameter("albedo", c)
	m.set_shader_parameter("kind", kind)
	m.set_shader_parameter("roughness", rough)
	m.set_shader_parameter("metallic", metal)
	m.set_shader_parameter("emission", emis)
	m.set_shader_parameter("emission_energy", ei)
	return m

# ---------------------------------------------------------------- x-ray silhouette (the player's hero only)
## Where anything stands between the camera and the hero (a tree, a pillar, a wall of foes), the hidden
## parts show as a translucent silhouette in the hero's colour. Every hero material writes XRAY_REF into
## the stencil buffer where the hero is visible, and carries XRAY_CODE as its next pass: drawn only where
## the depth test fails (depth_test_inverted, i.e. behind something) and the stencil does not hold
## XRAY_REF, so the hero's own overlapping parts never tint each other. Attached in _tag_meshes (authored
## models) and at the end of _build_procedural. Set xray before build(); exiles and the menu hero leave it off.
const XRAY_REF := 2
const XRAY_CODE := """shader_type spatial;
render_mode unshaded, depth_test_inverted, depth_draw_never, cull_back, blend_mix, shadows_disabled, fog_disabled;
stencil_mode read, write, compare_not_equal, %d;
uniform vec4 tint : source_color = vec4(1.0, 0.85, 0.6, 0.45);
void fragment() {
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.0);
	ALBEDO = mix(tint.rgb, vec3(1.0), rim * 0.35);
	ALPHA = tint.a * (0.6 + 0.4 * rim);
}"""
var xray := false
var _xray_mat: ShaderMaterial
static var _xray_shader: Shader
static var _stencil_char: Shader

## The silhouette pass, one material per rig, tinted with the hero's colour (alpha 0.45 at the rim).
func _xray() -> ShaderMaterial:
	if _xray_mat == null:
		if _xray_shader == null:
			_xray_shader = Shader.new()
			_xray_shader.code = XRAY_CODE % XRAY_REF
		_xray_mat = ShaderMaterial.new()
		_xray_mat.shader = _xray_shader
		var t := col.lightened(0.3)
		_xray_mat.set_shader_parameter("tint", Color(t.r, t.g, t.b, 0.45))
	return _xray_mat

## char.gdshader with a stencil write of XRAY_REF, for the procedural hero's parts.
static func _char_stencil() -> Shader:
	if _stencil_char == null:
		var base: Shader = load("res://shaders/3d/char.gdshader")
		_stencil_char = Shader.new()
		_stencil_char.code = base.code.replace("shader_type spatial;", "shader_type spatial;\nstencil_mode write, compare_always, %d;" % XRAY_REF)
	return _stencil_char

func build(id: String, c: Color) -> void:
	hero_id = id
	col = c
	var p := Models.find_asset("heroes", id)
	if p != "" and load(p) is PackedScene:
		override = load(p).instantiate()
		add_child(override)
		anim = _find_anim(override)
		_prepare_override(override)
		return
	_build_procedural()

static var _flash_shader: Shader
## Authored models: loop the locomotion clips, add a red hit-flash overlay, and give every
## "glow*" material its own copy so casts can flare it (the procedural rig does the same in-shader).
func _prepare_override(n: Node) -> void:
	if anim != null:
		for nm in ["idle", "run", "walk"]:
			if anim.has_animation(nm): anim.get_animation(nm).loop_mode = Animation.LOOP_LINEAR
		_build_tree()
	if _flash_shader == null:
		_flash_shader = Shader.new()
		# the hit flash, plus the act's Fresnel rim (set_rim): additive over the authored PBR materials
		_flash_shader.code = "shader_type spatial; render_mode unshaded, blend_add, depth_draw_never; uniform float flash = 0.0; uniform vec3 rim_col : source_color = vec3(0.0); uniform float rim_k = 0.0; void fragment(){ ALBEDO = vec3(1.0, 0.22, 0.12) * flash + rim_col * pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0) * rim_k; }"
	var fm := ShaderMaterial.new()
	fm.shader = _flash_shader
	_mats.append(fm)
	_tag_meshes(n, fm)

## The act's Fresnel rim colour (WorldView3D STAGE_LOOK.rim) at strength k: on the procedural rig's materials
## (char.gdshader) and on an authored model's hit-flash overlay, which draws additively over its PBR.
var rim_col := Color.BLACK
func set_rim(c: Color, k: float) -> void:
	rim_col = c
	for m in _mats:
		m.set_shader_parameter("rim_col", c)
		m.set_shader_parameter("rim_k", k)

var _glow_over: Array = []          # [material, base emission energy]
func _tag_meshes(n: Node, fm: ShaderMaterial) -> void:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		mi.material_overlay = fm
		for i in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(i)
			if not (m is BaseMaterial3D): continue
			# per-instance copy with a cool rim light, so the hero separates from dark floors (PoE2 look)
			var d: BaseMaterial3D = m.duplicate()
			d.rim_enabled = true
			d.rim = 0.55
			d.rim_tint = 0.35
			if d.albedo_texture != null: d.albedo_color = Models.albedo_gain_color(hero_id)   # the albedo floor (Models.ALBEDO_GAIN)
			if xray:                       # write XRAY_REF where visible; draw the silhouette pass where hidden
				d.stencil_mode = BaseMaterial3D.STENCIL_MODE_CUSTOM
				d.stencil_flags = BaseMaterial3D.STENCIL_FLAG_WRITE
				d.stencil_compare = BaseMaterial3D.STENCIL_COMPARE_ALWAYS
				d.stencil_reference = XRAY_REF
				d.next_pass = _xray()
			mi.set_surface_override_material(i, d)
			if String(m.resource_name).begins_with("glow"):
				_glow_over.append([d, d.emission_energy_multiplier])
	for c in n.get_children(): _tag_meshes(c, fm)

func _find_anim(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer: return n
	for ch in n.get_children():
		var a := _find_anim(ch)
		if a != null: return a
	return null

func _m(c: Color, kind: int, rough: float = 0.7, metal: float = 0.0, emis: Color = Color.BLACK, ei: float = 0.0) -> ShaderMaterial:
	var m := char_mat(c, kind, rough, metal, emis, ei, _char_stencil() if xray else null)
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
	if xray:                               # the silhouette pass on every part (their shader writes XRAY_REF: _m)
		for m in _mats: m.next_pass = _xray()

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

## st: {pos, face, mv, ph, cast_age, cast_dir, roll (0..1 or -1), jump (0..1 or -1), hit (0..1), dead, t}
func animate(st: Dictionary, dt: float) -> void:
	var p: Vector2 = st.pos
	position = Vector3(p.x, 0.0, p.y)
	var want: Vector2 = st.face
	if float(st.cast_age) < 0.35: want = st.cast_dir
	_yaw = lerp_angle(_yaw, atan2(-want.y, want.x), minf(1.0, dt * 14.0))
	rotation.y = _yaw
	_cast = clampf(1.0 - float(st.cast_age) / 0.3, 0.0, 1.0)
	_hit = maxf(_hit - dt * 6.0, float(st.hit))
	if st.dead: _dead = minf(1.0, _dead + dt * 2.0)
	var t: float = st.t
	for m in _mats:
		m.set_shader_parameter("flash", _hit * _hit * 0.9)
	if override != null:
		_animate_override(st, dt)
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
	var jp := float(st.get("jump", -1.0))
	if jp >= 0.0 and roll < 0.0:                       # airborne: knees up at the apex, arms out for balance
		var tk := sin(jp * PI)
		leg_l.rotation.z = lerpf(leg_l.rotation.z, 1.0, tk)
		leg_r.rotation.z = lerpf(leg_r.rotation.z, 1.0, tk)
		shin_l.rotation.z = lerpf(shin_l.rotation.z, -1.5, tk)
		shin_r.rotation.z = lerpf(shin_r.rotation.z, -1.5, tk)
		arm_l.rotation.z = lerpf(arm_l.rotation.z, -0.7, tk)
	if _dead > 0.0:
		rotation.z = -_dead * PI * 0.5
		position.y = -_dead * 4.0

## Animation tree for an imported hero (tools/blender/process_fal_assets.py: Meshy rig and clips):
## idle, then walk/run synced and blended by ground speed -> upper-body cast layer (cast while moving) ->
## full-body cast (standing) -> roll (scrubbed by the dodge timer) -> jump (scrubbed by the jump's
## progress; the view lifts the body along the arc) -> death. Clip names are matched case-insensitively
## (cast or attack, roll or dodge, die or death); a missing one is an error, not a silent fallback.
const REQUIRED := {"idle": ["idle"], "walk": ["walk"], "run": ["run"], "cast": ["cast", "attack"], "roll": ["roll", "dodge"],
	"jump": ["jump"], "die": ["die", "death"]}
const UPPER_KEYS := ["spine", "chest", "neck", "head", "clavicle", "shoulder", "arm", "hand"]
const CAST_RATE := 1.25
const CAST_VIS_CD := 0.45           # at most one visible cast per 0.45 s: auto-weapons fire faster than that
const V_WALK := 75.0                # world units per second at which the walk clip plays at its own rate
const V_RUN := 155.0                # and the run clip
const CAST_MOVE_K := 0.35           # above this share of the walk speed the hero counts as moving (casts)
var tree: AnimationTree
var _clips := {}                    # role -> the clip's name in this model
var _v_walk := V_WALK
var _v_run := V_RUN
var _last_cast_age := 9.0
var _cast_flip := 0
var _cast_vis_cd := 0.0
var _roll_k := 0.0
var _jump_k := 0.0
var _spd := 0.0
var _was_hit := false
var _cast_fading := false           # a fade-out of the full-body cast was requested (once); clears when it ends

## role -> clip name, matched case-insensitively against the model's own clips.
func _map_clips() -> Dictionary:
	var have := {}
	for nm in anim.get_animation_list(): have[String(nm).to_lower()] = String(nm)
	var out := {}
	for role in REQUIRED:
		for alt in REQUIRED[role]:
			if have.has(alt):
				out[role] = have[alt]
				break
		if not out.has(role):
			push_error("HeroRig %s: no '%s' clip (looked for %s; the model has %s)" % [hero_id, role, "/".join(REQUIRED[role]), ", ".join(have.values())])
	for opt in ["cast2", "hit"]:
		if have.has(opt): out[opt] = have[opt]
	return out

func _build_tree() -> void:
	if anim == null:
		push_error("HeroRig %s: the model has no AnimationPlayer" % hero_id)
		return
	var list := anim.get_animation_list()
	if list.is_empty():
		push_error("HeroRig %s: the model's AnimationPlayer has no clips" % hero_id)
		return
	_clips = _map_clips()
	for role in REQUIRED:
		if not _clips.has(role): _clips[role] = _clips.get("idle", String(list[0]))
	for role in ["idle", "walk", "run"]:
		anim.get_animation(_clips[role]).loop_mode = Animation.LOOP_LINEAR
	var bt := AnimationNodeBlendTree.new()
	# walk and run share one cycle (sync); idle stands apart, blended in by speed
	var moving := AnimationNodeBlendSpace1D.new()
	moving.min_space = _v_walk; moving.max_space = _v_run; moving.sync = true
	moving.add_blend_point(_clip("walk"), _v_walk, -1, "walk")
	moving.add_blend_point(_clip("run"), _v_run, -1, "run")
	bt.add_node("moving", moving)
	bt.add_node("rate", AnimationNodeTimeScale.new())
	bt.connect_node("rate", 0, "moving")
	bt.add_node("idle", _clip("idle"))
	bt.add_node("loco", AnimationNodeBlend2.new())
	bt.connect_node("loco", 0, "idle"); bt.connect_node("loco", 1, "rate")
	var prev := "loco"
	var cast2 := String(_clips.get("cast2", _clips.cast))
	for layer in ["up", "full"]:
		var pick := AnimationNodeTransition.new()
		pick.xfade_time = 0.0
		pick.add_input("a"); pick.add_input("b")
		bt.add_node("pick_" + layer, pick)
		bt.add_node("c1_" + layer, _clip("cast"))
		var c2 := AnimationNodeAnimation.new(); c2.animation = cast2
		bt.add_node("c2_" + layer, c2)
		bt.connect_node("pick_" + layer, 0, "c1_" + layer); bt.connect_node("pick_" + layer, 1, "c2_" + layer)
		bt.add_node("crate_" + layer, AnimationNodeTimeScale.new())
		bt.connect_node("crate_" + layer, 0, "pick_" + layer)
		var os := AnimationNodeOneShot.new()
		os.fadein_time = 0.08; os.fadeout_time = 0.22
		if layer == "up":
			os.filter_enabled = true
			var ca := anim.get_animation(_clips.cast)
			for ti in ca.get_track_count():
				var tp := ca.track_get_path(ti)
				var bone := String(tp.get_concatenated_subnames()).to_lower()
				for k in UPPER_KEYS:
					if bone.contains(k):
						os.set_filter_path(tp, true)
						break
		bt.add_node("cast_" + layer, os)
		bt.connect_node("cast_" + layer, 0, prev); bt.connect_node("cast_" + layer, 1, "crate_" + layer)
		prev = "cast_" + layer
	bt.add_node("roll_clip", _clip("roll"))
	bt.add_node("roll_seek", AnimationNodeTimeSeek.new()); bt.connect_node("roll_seek", 0, "roll_clip")
	# sync on the roll and jump blends and on the life transition: the casts under them keep advancing while
	# a roll, a jump or death covers them, so a cast's requested fade-out completes there instead of freezing
	# at full weight until the cover lifts (0.10.0: cast_full aborts on roll, jump and death)
	var rb := AnimationNodeBlend2.new()
	rb.sync = true
	bt.add_node("roll", rb)
	bt.connect_node("roll", 0, prev); bt.connect_node("roll", 1, "roll_seek")
	bt.add_node("jump_clip", _clip("jump"))
	bt.add_node("jump_seek", AnimationNodeTimeSeek.new()); bt.connect_node("jump_seek", 0, "jump_clip")
	var jb := AnimationNodeBlend2.new()
	jb.sync = true
	bt.add_node("jump", jb)
	bt.connect_node("jump", 0, "roll"); bt.connect_node("jump", 1, "jump_seek")
	var below := "jump"
	if _clips.has("hit"):
		var hit := AnimationNodeOneShot.new()
		hit.fadein_time = 0.05; hit.fadeout_time = 0.2
		bt.add_node("hit_clip", _clip("hit")); bt.add_node("hit", hit)
		bt.connect_node("hit", 0, below); bt.connect_node("hit", 1, "hit_clip")
		below = "hit"
	var life := AnimationNodeTransition.new()
	life.xfade_time = 0.12
	life.sync = true
	life.add_input("alive"); life.add_input("dead")
	bt.add_node("die_clip", _clip("die")); bt.add_node("life", life)
	bt.connect_node("life", 0, below); bt.connect_node("life", 1, "die_clip")
	bt.connect_node("output", 0, "life")
	tree = AnimationTree.new()
	tree.tree_root = bt
	anim.get_parent().add_child(tree)
	tree.anim_player = tree.get_path_to(anim)
	tree.active = true
	for layer in ["up", "full"]: tree.set("parameters/crate_%s/scale" % layer, CAST_RATE)

## The locomotion clips' playback rate at ground speed `spd`: 1.0 across [walk, run] (the blend space
## covers that span), speed over the nearest end outside it, clamped to 0.85-1.30. Continuous: no step
## anywhere, so the stride never jumps as the hero speeds up or slows down.
func loco_rate(spd: float) -> float:
	var ref := clampf(spd, _v_walk, _v_run)
	return clampf(spd / ref, 0.85, 1.30)

func _clip(role: String) -> AnimationNodeAnimation:
	var n := AnimationNodeAnimation.new()
	n.animation = _clips.get(role, role)
	return n

func _animate_override(st: Dictionary, dt: float = 0.016) -> void:
	var cast_k := sin(_cast * PI * 0.5)
	for g in _glow_over:
		(g[0] as BaseMaterial3D).emission_energy_multiplier = float(g[1]) * (1.0 + cast_k * 2.5 + 0.12 * sin(float(st.t) * 3.0))
	if anim == null: return
	var mv: float = st.mv
	var roll: float = st.roll
	if tree != null:
		# ground speed in world units from the simulation's walking velocity ("vel"); viewers that hold the
		# model in place pass "gs"; neither: the input strength times the run speed
		var raw := float(st.vel) if st.has("vel") else (float(st.gs) if st.has("gs") else mv * _v_run)
		if mv < 0.05 and not st.has("gs"): raw = 0.0
		_spd = lerpf(_spd, raw, minf(1.0, dt * 12.0))
		tree.set("parameters/loco/blend_amount", clampf(_spd / (_v_walk * 0.6), 0.0, 1.0))
		tree.set("parameters/moving/blend_position", clampf(_spd, _v_walk, _v_run))
		tree.set("parameters/rate/scale", loco_rate(_spd))
		_cast_vis_cd = maxf(0.0, _cast_vis_cd - dt)
		var age := float(st.cast_age)
		var jp := float(st.get("jump", -1.0))
		# a full-body cast freezes the legs: once the hero moves, rolls, jumps or dies it fades out, requested
		# once (not every frame while it fades), and the same cast is not replayed on the upper body; a cast that
		# starts while moving takes the upper-body layer
		if bool(tree.get("parameters/cast_full/active")):
			if not _cast_fading and (_spd > _v_walk * CAST_MOVE_K or roll >= 0.0 or jp >= 0.0 or bool(st.dead)):
				tree.set("parameters/cast_full/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FADE_OUT)
				_cast_fading = true
		else:
			_cast_fading = false
		if age < _last_cast_age and age < 0.3 and roll < 0.0 and not st.dead and _cast_vis_cd <= 0.0:
			var layer := "up" if _spd > _v_walk * CAST_MOVE_K else "full"
			if not bool(tree.get("parameters/cast_up/active")) and not bool(tree.get("parameters/cast_full/active")):
				_cast_flip = 1 - _cast_flip
				tree.set("parameters/pick_%s/transition_request" % layer, "a" if _cast_flip == 0 else "b")
				tree.set("parameters/cast_%s/request" % layer, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
				_cast_vis_cd = CAST_VIS_CD
		_last_cast_age = age
		_roll_k = move_toward(_roll_k, 1.0 if roll >= 0.0 else 0.0, dt * 12.0)
		tree.set("parameters/roll/blend_amount", _roll_k)
		if roll >= 0.0:
			tree.set("parameters/roll_seek/seek_request", clampf(roll, 0.0, 0.98) * anim.get_animation(_clips.roll).length)
		# the jump clip follows the simulation's jump progress (World.jump_progress); the view lifts the body
		_jump_k = move_toward(_jump_k, 1.0 if jp >= 0.0 else 0.0, dt * 14.0)
		tree.set("parameters/jump/blend_amount", _jump_k)
		if jp >= 0.0:
			tree.set("parameters/jump_seek/seek_request", clampf(jp, 0.0, 0.98) * anim.get_animation(_clips.jump).length)
		var hit_now := _hit > 0.5
		if _clips.has("hit"):
			if hit_now and not _was_hit and roll < 0.0: tree.set("parameters/hit/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
		else:
			override.rotation.z = -0.12 * _hit                       # no hit clip: a short lean back on the hit
		_was_hit = hit_now
		var life := "dead" if st.dead else "alive"
		if tree.get("parameters/life/current_state") != life: tree.set("parameters/life/transition_request", life)
		return
	var want := "run" if mv > 0.2 else "idle"
	if roll >= 0.0: want = "roll"
	elif _hit > 0.5: want = "hit"
	elif float(st.cast_age) < 0.3: want = "cast"
	if st.dead: want = "die"
	if want != _anim_state and anim.has_animation(want):
		_anim_state = want
		anim.play(want, 0.08 if want == "roll" or want == "cast" else 0.15)
	# the roll follows the simulation's dodge timer exactly; the run cadence follows speed
	if want == "roll" and anim.has_animation("roll"):
		anim.speed_scale = 0.0
		anim.seek(clampf(roll, 0.0, 0.999) * anim.get_animation("roll").length, true)
	else:
		anim.speed_scale = lerpf(0.85, 1.25, clampf(mv, 0.0, 1.0)) if want == "run" else 1.0
