class_name BossRig
extends Node3D
## Hierarchical bosses. kind "tyrant" (stage boss and rift guardian): horned demon lord with a
## glowing ribcage furnace, wings or cloak, swinging weapon arms and a slam wind-up.
## kind "herald": the pinnacle, a floating crystal star with orbiting shards and a pulsing core.
## Override: res://models/bosses/<tyrant|herald|guardian>.(tscn|glb), AnimationPlayer clips
## idle / walk / attack / slam / hit / die: idle while it stands (under IDLE_SPEED), walk while it moves,
## attack and slam in turn, die once when it falls (WorldView3D keeps the rig until the clip ends).

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
var char_mats: Array[ShaderMaterial] = []
var core_cmat: ShaderMaterial
var light: OmniLight3D
var override: Node3D
const WALK_SPEED := 69.0          # retargeted walk: 111.9 units per 1.62 s cycle
const IDLE_SPEED := 5.0           # world units per second: slower than this (and not attacking) it idles
var _prev_pos := Vector3.ZERO
var _gs := 0.0
var _has_stride := false
var anim: AnimationPlayer
var _yaw := 0.0
var _ph := 0.0
var _atk := 0.0
var _died := false
var _die_t := 0.0                  # seconds since the die clip started
var death_k := 1.0                 # 1 alive .. 0: the boss's light and glow fade out over the fall and the sink

## The boss's own light, x LIGHT_GAIN: LIGHT_E steady plus up to LIGHT_PULSE with its heartbeat
## (was 2.0 + 2.5: with the sun at 1.2 and the glow threshold at 1.25 it washed out the boss and the
## ground around it).
const LIGHT_E := 0.85
const LIGHT_PULSE := 1.06
## The hit-flash overlay's shader, compiled once and shared by every boss (each boss has its own
## material for its own flash value).
static var _flash_sh: Shader

func build(k: String, c: Color, slot: String) -> void:
	kind = k
	col = c
	var p := Models.find_asset("bosses", slot)
	light = OmniLight3D.new()
	light.light_color = c
	light.omni_range = 220.0
	light.omni_attenuation = WorldView3D.LIGHT_ATT
	light.light_energy = LIGHT_E * WorldView3D.LIGHT_GAIN
	light.shadow_enabled = false
	add_child(light)
	if p != "" and load(p) is PackedScene:
		override = load(p).instantiate()
		add_child(override)
		_has_stride = p.contains("tyrant_4")           # the only boss on retargeted clips so far
		anim = override.find_child("AnimationPlayer", true, false) as AnimationPlayer
		_prepare_override(override)
		return
	if k == "herald": _build_herald()
	else: _build_tyrant()

var _over_flash: ShaderMaterial
var _atk_flip := 0
var _glow_over: Array = []         # [material, base energy]
## Authored bosses: loop idle/walk, hit-flash overlay, and recolour every "glow*" material to this
## boss's colour, so one tyrant model serves every act (green, ember, pale and neon bosses).
func _prepare_override(n: Node) -> void:
	if anim != null:
		for nm in ["idle", "walk"]:
			if anim.has_animation(nm): anim.get_animation(nm).loop_mode = Animation.LOOP_LINEAR
		for nm in ["attack", "slam", "hit", "die"]:                  # played once; die holds its last pose
			if anim.has_animation(nm): anim.get_animation(nm).loop_mode = Animation.LOOP_NONE
		if anim.has_animation("idle"): anim.play("idle")
		elif anim.has_animation("walk"): anim.play("walk")
	if _flash_sh == null:
		_flash_sh = Shader.new()
		_flash_sh.code = "shader_type spatial; render_mode unshaded, blend_add, depth_draw_never; uniform vec3 tint = vec3(1.0); uniform float flash = 0.0; void fragment(){ ALBEDO = tint * flash; }"
	_over_flash = ShaderMaterial.new()
	_over_flash.shader = _flash_sh
	_over_flash.set_shader_parameter("tint", Vector3(1.0, 0.85, 0.75))
	_tag(n)

func _tag(n: Node) -> void:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		mi.material_overlay = _over_flash
		for i in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(i)
			if not (m is BaseMaterial3D): continue
			var d: BaseMaterial3D = m.duplicate()
			d.rim_enabled = true
			d.rim = 0.45
			d.rim_tint = 0.5
			if String(m.resource_name).begins_with("glow"):
				d.emission = col.lightened(0.15)
				d.albedo_color = col.lightened(0.5)
				_glow_over.append([d, d.emission_energy_multiplier])
			mi.set_surface_override_material(i, d)
	for c in n.get_children(): _tag(c)

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

func _cm(c: Color, kind: int, rough: float = 0.7, metal: float = 0.0, emis: Color = Color.BLACK, ei: float = 0.0) -> ShaderMaterial:
	var m := HeroRig.char_mat(c, kind, rough, metal, emis, ei)
	char_mats.append(m)
	return m

## Charred demon tyrant (loop 2 rebuild): ashen hide with ember cracks, muscular capsule limbs,
## digitigrade legs, segmented curved horns, membrane wings, bone ribs over a furnace core.
## The stage colour only drives the emissive parts, the body stays dark like PoE2 bosses.
func _build_tyrant() -> void:
	HeroRig._prims()
	var hide := _cm(Color("2a2422"), 1, 0.8)
	var hide_l := _cm(Color("3c3330"), 1, 0.75)
	var bone := _cm(Color("cfc4b0"), 1, 0.55)
	var horn := _cm(Color("1c1816"), 2, 0.4, 0.3)
	var memb := _cm(col.darkened(0.75), 0, 0.85)
	memb.set_shader_parameter("grime", 0.8)
	var ember := _cm(col.lightened(0.2), 4, 0.3, 0.0, col, 2.4)
	core_cmat = _cm(col.lightened(0.4), 4, 0.2, 0.0, col, 4.0)
	var eye := _cm(Color.WHITE, 4, 0.2, 0.0, col.lightened(0.3), 5.0)
	root = _n(self, Vector3(0, 52, 0))
	for s2 in [-1.0, 1.0]:                                               # digitigrade legs
		var lg := _n(root, Vector3(-2, 0, 13.0 * s2))
		_p(lg, HeroRig._taper(7.0, 5.0), hide, Vector3(4, -12, 0), Vector3(1, 24, 1), Vector3(0, 0, 0.35))
		_p(lg, HeroRig._taper(4.6, 3.2), hide_l, Vector3(1, -34, 0), Vector3(1, 22, 1), Vector3(0, 0, -0.4))
		_p(lg, HeroRig._sph, horn, Vector3(5, -49, 0), Vector3(15, 6, 12))
		for c in 3: _p(lg, HeroRig._cone, bone, Vector3(13, -51, -4 + c * 4), Vector3(2.2, 6, 2.2), Vector3(0, 0, -1.5))
		legs.append(lg)
	_p(root, HeroRig._sph, hide, Vector3(0, 6, 0), Vector3(30, 24, 34))                  # pelvis mass
	_p(root, HeroRig._sph, hide, Vector3(4, 30, 0), Vector3(38, 44, 50))                  # torso
	_p(root, HeroRig._sph, core_cmat, Vector3(14, 30, 0), Vector3(14, 20, 20))            # furnace behind the ribs
	for r in 4:                                                          # ribs: V-shaped bars on the chest front
		for s3 in [-1.0, 1.0]:
			_p(root, HeroRig._box, bone, Vector3(20.5 - absf(r - 1.5) * 0.8, 20 + r * 6.0, 6.5 * s3), Vector3(2.2, 2.0, 11.0 - r * 0.6), Vector3(0.55 * s3, 0, 0))
	for k in 6:                                                          # ember cracks in the hide
		_p(root, HeroRig._box, ember, Vector3(-6 + k * 3, 18 + (k % 3) * 11, (-1 + (k % 2) * 2) * 22), Vector3(9, 0.8, 0.6), Vector3(0.3 * k, 0, 0.8 - k * 0.3))
	_p(root, HeroRig._sph, hide_l, Vector3(-6, 46, 15), Vector3(22, 18, 20))              # shoulder masses
	_p(root, HeroRig._sph, hide_l, Vector3(-6, 46, -15), Vector3(22, 18, 20))
	head = _n(root, Vector3(14, 58, 0))
	_p(head, HeroRig._sph, hide, Vector3.ZERO, Vector3(18, 16, 17))
	_p(head, HeroRig._sph, hide_l, Vector3(7, -5, 0), Vector3(12, 8, 12))                 # jaw
	for t in 4: _p(head, HeroRig._cone, bone, Vector3(11, -7, -4.5 + t * 3), Vector3(1.4, 4, 1.4), Vector3(0, 0, PI))
	_p(head, HeroRig._box, eye, Vector3(8.4, 1.5, 3.6), Vector3(1.4, 1.4, 2.6))
	_p(head, HeroRig._box, eye, Vector3(8.4, 1.5, -3.6), Vector3(1.4, 1.4, 2.6))
	for s4 in [-1.0, 1.0]:                                               # curved, segmented horns
		var hp := _n(head, Vector3(-2, 6, 7 * s4))
		var prev := hp
		for k in 4:
			var seg := _n(prev, Vector3(0, 5.5 if k > 0 else 0.0, 0))
			seg.rotation = Vector3(0.35 * s4, 0, -0.35)
			_p(seg, HeroRig._taper(1.2 * (4 - k) * 0.5, 1.6 * (4 - k) * 0.5), horn, Vector3(0, 2.8, 0), Vector3(1, 6, 1))
			prev = seg
		var ar := _n(root, Vector3(2, 46, 30 * s4))
		_p(ar, HeroRig._taper(5.2, 4.2), hide, Vector3(0, -12, 0), Vector3(1, 22, 1))
		_p(ar, HeroRig._taper(4.2, 3.4), hide_l, Vector3(4, -30, 0), Vector3(1, 18, 1), Vector3(0, 0, 0.3))
		_p(ar, HeroRig._sph, hide, Vector3(7, -42, 0), Vector3(10, 9, 10))
		for c in 3: _p(ar, HeroRig._cone, bone, Vector3(10, -47, -3 + c * 3), Vector3(1.8, 9, 1.8), Vector3(0, 0, PI * 0.85))
		arms.append(ar)
		var wg := _n(root, Vector3(-14, 52, 10 * s4))                    # membrane wing on a bone strut
		_p(wg, HeroRig._taper(0.6, 1.1), horn, Vector3(-14, 12, 18 * s4), Vector3(1, 46, 1), Vector3(0.9 * s4, 0, 0.9))
		var mm := memb
		var mesh_m := _p(wg, HeroRig._prism, mm, Vector3(-18, 4, 24 * s4), Vector3(50, 42, 1.2), Vector3(0.8 * s4, 0, 0.55))
		_p(wg, HeroRig._box, ember, Vector3(-18, -14, 24 * s4), Vector3(40, 0.6, 0.8), Vector3(0.8 * s4, 0, 0.55))     # ember-lit trailing edge
		mesh_m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		wings.append(wg)
	light.position = Vector3(36, 80, 0)

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

## The clip an authored boss should play: die once dead; a new attack alternates attack and slam (an attack
## plays to its end); a hard hit flinches when nothing else runs; a running attack or flinch continues;
## otherwise idle under IDLE_SPEED world units per second, walk above it.
func pick_clip(dead: bool, attack: bool, busy: bool, flinch: bool, speed: float) -> String:
	if anim == null: return ""
	if dead: return "die" if anim.has_animation("die") else ("idle" if anim.has_animation("idle") else "walk")
	if attack and not busy:
		_atk_flip = 1 - _atk_flip
		return "slam" if (_atk_flip == 1 and anim.has_animation("slam")) else "attack"
	if flinch and not busy and anim.current_animation != "hit" and anim.has_animation("hit"): return "hit"
	if busy or (anim.current_animation == "hit" and anim.is_playing()): return anim.current_animation
	return "idle" if speed < IDLE_SPEED and anim.has_animation("idle") else "walk"

## Seconds the death clip runs (0 when this boss has none): how long the view keeps a fallen boss.
func death_time() -> float:
	return anim.get_animation("die").length if anim != null and anim.has_animation("die") else 0.0

## A fallen boss: its own light and every glowing material fade smoothly to nothing across the die clip and
## the sink (WorldView3D.BOSS_SINK). The view may pass "fade" (1 .. 0, the fall and sink still to come);
## without it (tests) the rig times the fade itself.
func _death_fade(st: Dictionary, dt: float) -> void:
	_die_t += dt
	var total := maxf(0.1, death_time() + WorldView3D.BOSS_SINK)
	var k := clampf(1.0 - _die_t / total, 0.0, 1.0)
	if st.has("fade"): k = minf(k, clampf(float(st.fade), 0.0, 1.0))
	death_k = k
	var e := k * k                                           # eased: the glow dies away rather than cutting
	light.light_energy = LIGHT_E * WorldView3D.LIGHT_GAIN * e
	light.visible = e > 0.001
	for g in _glow_over:
		(g[0] as BaseMaterial3D).emission_energy_multiplier = float(g[1]) * e
	_over_flash.set_shader_parameter("flash", 0.0)

## st: {pos, face, hp_frac, flash, t, dt, attack (bool, set on telegraph/burst), phase, dead (optional)}
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
		var fl0 := clampf(float(st.flash) * 10.0, 0.0, 1.0)
		_over_flash.set_shader_parameter("flash", fl0 * fl0 * 0.5)
		var pulse0 := 0.5 + 0.5 * sin(t * (3.0 + 4.0 * (1.0 - float(st.hp_frac))))
		for g in _glow_over:
			(g[0] as BaseMaterial3D).emission_energy_multiplier = float(g[1]) * (0.7 + 0.6 * pulse0 + _atk * 1.2)
		light.light_energy = (LIGHT_E + pulse0 * LIGHT_PULSE) * WorldView3D.LIGHT_GAIN
		if anim != null:
			# ground speed in world units per second, from the rig's own movement (smoothed)
			var sc := maxf(0.01, global_transform.basis.get_scale().x)
			var gs := (position - _prev_pos).length() / maxf(dt, 0.001)
			_prev_pos = position
			_gs = lerpf(_gs, gs if gs < 900.0 else 0.0, minf(1.0, dt * 6.0))
			var busy := (anim.current_animation == "attack" or anim.current_animation == "slam") and anim.is_playing()
			var want := pick_clip(bool(st.get("dead", false)), bool(st.attack), busy, fl0 > 0.85, _gs)
			if want == "die":
				if not _died:                                        # once; LOOP_NONE holds the last pose
					_died = true
					_die_t = 0.0
					anim.play("die", 0.15)
				anim.speed_scale = 1.0
				_death_fade(st, dt)
				return
			if anim.has_animation(want) and (anim.current_animation != want or not anim.is_playing()): anim.play(want, 0.2)
			# the walk cadence follows the ground speed where the stride was measured (retargeted clips)
			anim.speed_scale = clampf(_gs / sc / WALK_SPEED, 0.6, 1.8) if want == "walk" and _has_stride else 1.0
		return
	var fl := clampf(float(st.flash) * 10.0, 0.0, 1.0)
	for m in char_mats:
		m.set_shader_parameter("flash", fl * fl * fl * 0.35)
	for m in flash_mats:
		m.emission = col.lightened(0.5)
		m.emission_energy_multiplier = fl * fl * fl * 0.5
	var pulse := 0.5 + 0.5 * sin(t * (3.0 + 4.0 * (1.0 - float(st.hp_frac))))
	if core_mat != null: core_mat.emission_energy_multiplier = (2.0 + pulse * 3.0) if kind == "herald" else (3.0 + pulse * 4.0)
	if core_cmat != null: core_cmat.set_shader_parameter("pulse", pulse * 1.5)
	light.light_energy = (LIGHT_E + pulse * LIGHT_PULSE) * WorldView3D.LIGHT_GAIN
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
	root.position.y = 52.0 + absf(sin(_ph)) * 3.0
	# slam wind-up: both arms rise then crash down
	var raise := sin(clampf(_atk, 0.0, 1.0) * PI)
	for i in arms.size():
		arms[i].rotation.z = -sw * 0.6 * (1.0 if i == 0 else -1.0) - raise * 2.4
	for i in wings.size():
		wings[i].rotation.x = sin(t * 3.0) * 0.25 * (1.0 if i == 0 else -1.0)
	head.rotation.z = -0.15 + sin(t * 1.5) * 0.08 - raise * 0.3
	root.rotation.z = -0.1 - raise * 0.15
