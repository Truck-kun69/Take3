class_name WorldView
extends Node2D
## Draws a World. Read-only with respect to the simulation (except consuming `bursts`).
## Layers (back to front): ground shader -> under (telegraphs, event areas, pickups) -> swarm
## MultiMesh (1 draw call) -> actors (player, blades, bosses' extras) -> glow MultiMesh
## (projectiles, gems, particles: 1 draw call) -> over (rings, arcs, numbers).

var w: World
var cam: Camera2D
var ground: Polygon2D
var ground_mat: ShaderMaterial
var swarm_mm: MultiMeshInstance2D
var swarm_mat: ShaderMaterial
var glow_mm: MultiMeshInstance2D
var under: Node2D
var actors: Node2D
var over: Node2D
var modulate_node: CanvasModulate
var light: PointLight2D
var font: Font
var time := 0.0
var zoom := 1.0
var _buf := PackedFloat32Array()
var _gbuf := PackedFloat32Array()
var ghosts: Array = []
var cost_us := 0.0              # smoothed CPU cost of building the instance buffers (for the bench)
var _ghost_t := 0.0

# particles (renderer-owned, fed by World.bursts)
const PCAP_HI := 420
const PCAP_LO := 160
var p_pos := PackedVector2Array()
var p_vel := PackedVector2Array()
var p_life := PackedFloat32Array()
var p_max := PackedFloat32Array()
var p_col := PackedColorArray()
var p_size := PackedFloat32Array()
var p_n := 0
const GLOW_CAP := 1400

func _ready() -> void:
	font = ThemeDB.fallback_font
	ground = Polygon2D.new()
	ground.polygon = PackedVector2Array([Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)])
	ground_mat = ShaderMaterial.new()
	ground_mat.shader = load("res://shaders/ground.gdshader")
	ground.material = ground_mat
	add_child(ground)
	under = _layer(); add_child(under)
	under.draw.connect(_draw_under)
	swarm_mm = MultiMeshInstance2D.new()
	swarm_mm.multimesh = _make_mm(Swarm.CAP)
	swarm_mat = ShaderMaterial.new()
	swarm_mat.shader = load("res://shaders/swarm.gdshader")
	swarm_mm.material = swarm_mat
	add_child(swarm_mm)
	actors = _layer(); add_child(actors)
	actors.draw.connect(_draw_actors)
	glow_mm = MultiMeshInstance2D.new()
	glow_mm.multimesh = _make_mm(GLOW_CAP)
	var gm := ShaderMaterial.new()
	gm.shader = load("res://shaders/glow.gdshader")
	glow_mm.material = gm
	add_child(glow_mm)
	over = _layer(); add_child(over)
	over.draw.connect(_draw_over)
	cam = Camera2D.new()
	add_child(cam)
	cam.make_current()
	modulate_node = CanvasModulate.new()
	modulate_node.color = Color.WHITE
	add_child(modulate_node)
	light = PointLight2D.new()
	var gt := GradientTexture2D.new()
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(0.5, 0.0)
	gt.width = 256; gt.height = 256
	var g := Gradient.new()
	g.set_color(0, Color(1, 0.95, 0.85, 1)); g.set_color(1, Color(0, 0, 0, 0))
	gt.gradient = g
	light.texture = gt
	light.texture_scale = 3.2
	light.energy = 1.3
	light.enabled = false
	add_child(light)
	p_pos.resize(PCAP_HI); p_vel.resize(PCAP_HI); p_life.resize(PCAP_HI); p_max.resize(PCAP_HI); p_col.resize(PCAP_HI); p_size.resize(PCAP_HI)
	_buf.resize(Swarm.CAP * 16)
	_gbuf.resize(GLOW_CAP * 16)

func _layer() -> Node2D:
	var n := Node2D.new()
	return n

## A 2D quad with explicit UVs (QuadMesh is authored for 3D and flips V in canvas space).
func _make_mm(cap: int) -> MultiMesh:
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = PackedVector2Array([Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(0.5, 0.5), Vector2(-0.5, 0.5)])
	arr[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	arr[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = cap
	mm.visible_instance_count = 0
	# Buffers are uploaded wholesale every frame, so the engine never recomputes bounds; without a
	# huge custom AABB the batch is culled as soon as the camera leaves the origin.
	mm.custom_aabb = AABB(Vector3(-1e6, -1e6, -1), Vector3(2e6, 2e6, 2))
	return mm

func bind(world: World) -> void:
	w = world
	var s: Dictionary = Content.STAGES[w.stage]
	ground_mat.set_shader_parameter("c0", Content.col(s.g0))
	ground_mat.set_shader_parameter("c1", Content.col(s.g1))
	ground_mat.set_shader_parameter("c2", Content.col(s.g2))
	ground_mat.set_shader_parameter("acc", Content.col(s.acc))
	swarm_mat.set_shader_parameter("colorblind", w.colorblind)
	p_n = 0
	ghosts.clear()

func pcap() -> int:
	return PCAP_LO if int(Save.opt("quality")) == 0 else PCAP_HI

# ================================================================= per frame
func _process(dt: float) -> void:
	visible = w != null
	if w == null:
		return
	time += dt
	var vs := get_viewport_rect().size
	zoom = clampf(minf(vs.x, vs.y) / 520.0, 0.8, 1.35)
	cam.zoom = Vector2(zoom, zoom)
	w.view_r = vs.length() / zoom * 0.5
	var sh := w.shake * w.shake * 18.0 * float(Save.opt("shake"))
	cam.position = w.pp + Vector2(sin(time * 53.0), cos(time * 47.0)) * sh
	var half := vs / zoom * 0.5 + Vector2(64, 64)
	ground.position = cam.position
	ground.scale = half
	ground_mat.set_shader_parameter("time", time)
	swarm_mat.set_shader_parameter("time", time)
	var ecl := w.director.eclipse()
	var target := Color(0.18, 0.16, 0.3) if ecl else Color.WHITE
	modulate_node.color = modulate_node.color.lerp(target, minf(1.0, dt * 2.0))
	light.enabled = modulate_node.color.r < 0.95
	light.position = w.pp
	var t0 := Time.get_ticks_usec()
	_feed_particles(dt)
	_upload_swarm(ecl)
	_upload_glow()
	cost_us = lerpf(cost_us, float(Time.get_ticks_usec() - t0), 0.05)
	_ghost_t -= dt
	if w.roll_t > 0.0 and _ghost_t <= 0.0:
		_ghost_t = 0.05
		ghosts.append([w.pp, 0.3])
	for g in ghosts: g[1] -= dt
	while not ghosts.is_empty() and ghosts[0][1] <= 0.0: ghosts.pop_front()
	under.queue_redraw()
	actors.queue_redraw()
	over.queue_redraw()

func _status_code(i: int) -> float:
	var sw := w.sw
	if sw.freeze_t[i] > 0.0: return 6.0
	if sw.burn[i] > 0.0: return 1.0
	if sw.shock_t[i] > 0.0: return 3.0
	if sw.chill_t[i] > 0.0: return 2.0
	if sw.pois[i] > 0.0: return 4.0
	if sw.bleed[i] > 0.0: return 5.0
	return 0.0

func _foe_color(k: int, f: int) -> Color:
	var s: Dictionary = Content.STAGES[w.stage]
	var acc := Content.col(s.acc)
	match k:
		Content.E.RUNNER: return acc.lerp(Color(1, 1, 0.6), 0.4)
		Content.E.BRUTE: return Content.col(s.g2).lerp(acc, 0.35)
		Content.E.SPITTER: return acc.lerp(Color.WHITE, 0.45)
		Content.E.SPLITTER, Content.E.MINI: return acc.lerp(Color(0.5, 0.7, 1.0), 0.35)
		Content.E.CHARGER: return acc.lerp(Color(1.0, 0.5, 0.3), 0.4)
		Content.E.BREACH: return Color("a070ff")
		Content.E.GOBLIN: return Color("d8b040")
		Content.E.EXILE: return Color("e06a3a")
		Content.E.BOSS: return Content.col(s.boss_col)
		Content.E.HERALD: return Color("c48aff")
	return acc

func _upload_swarm(ecl: bool) -> void:
	var sw := w.sw
	var n := sw.n
	var vis := 0
	var cull := w.view_r + 80.0
	var dark_r := 260.0
	for i in n:
		var p := sw.pos[i]
		var dpl := p.distance_to(w.pp)
		if dpl > cull: continue
		if ecl and dpl > dark_r and (sw.flags[i] & (Swarm.F_BOSS | Swarm.F_HERALD | Swarm.F_EXILE)) == 0: continue
		var k := sw.kind[i]
		var f := sw.flags[i]
		var s := sw.rad[i] * 2.5
		var bob := 1.0 + 0.07 * sin(time * 9.0 + float(sw.uid[i]))
		var o := vis * 16
		_buf[o] = s / bob; _buf[o + 1] = 0.0; _buf[o + 2] = 0.0; _buf[o + 3] = p.x
		_buf[o + 4] = 0.0; _buf[o + 5] = s * bob; _buf[o + 6] = 0.0; _buf[o + 7] = p.y
		var c := _foe_color(k, f)
		_buf[o + 8] = c.r; _buf[o + 9] = c.g; _buf[o + 10] = c.b; _buf[o + 11] = fmod(float(sw.uid[i]) * 0.137, 1.0)
		_buf[o + 12] = float(k); _buf[o + 13] = maxf(0.0, sw.flash[i]); _buf[o + 14] = _status_code(i); _buf[o + 15] = float(f & 0xff)
		vis += 1
	var mm := swarm_mm.multimesh
	mm.buffer = _buf
	mm.visible_instance_count = vis

func _glow(o: int, p: Vector2, s: float, c: Color, shape: float, boost: float = 0.0, rot: float = 0.0) -> void:
	var cs := cos(rot) * s
	var sn := sin(rot) * s
	_gbuf[o] = cs; _gbuf[o + 1] = -sn; _gbuf[o + 2] = 0.0; _gbuf[o + 3] = p.x
	_gbuf[o + 4] = sn; _gbuf[o + 5] = cs; _gbuf[o + 6] = 0.0; _gbuf[o + 7] = p.y
	_gbuf[o + 8] = c.r; _gbuf[o + 9] = c.g; _gbuf[o + 10] = c.b; _gbuf[o + 11] = c.a
	_gbuf[o + 12] = shape; _gbuf[o + 13] = boost; _gbuf[o + 14] = 0.0; _gbuf[o + 15] = 0.0

func _upload_glow() -> void:
	var n := 0
	var cull := w.view_r + 40.0
	for p in w.projs:
		if n >= GLOW_CAP: break
		_glow(n * 16, p.pos, p.r * 4.5, p.col, 0.0, 0.4)
		n += 1
	for q in w.eshots:
		if n >= GLOW_CAP: break
		_glow(n * 16, q.pos, q.r * 4.0, q.col, 0.0, 0.2)
		n += 1
	var gc := Color("6be8ff") if not w.colorblind else Color("56b4e9")
	for i in w.gem_n:
		if n >= GLOW_CAP: break
		var gp := w.gem_pos[i]
		if gp.distance_to(w.pp) > cull: continue
		var big := w.gem_val[i] >= 4.0
		_glow(n * 16, gp + Vector2(0, sin(time * 4.0 + i) * 2.0), 18.0 if big else 12.0, Color("ffd84a") if big else gc, 1.0, 0.3)
		n += 1
	for i in p_n:
		if n >= GLOW_CAP: break
		var a := p_life[i] / p_max[i]
		var c := p_col[i]
		c.a = a
		_glow(n * 16, p_pos[i], p_size[i] * (0.5 + a), c, 2.0, 0.0, p_vel[i].angle())
		n += 1
	var mm := glow_mm.multimesh
	mm.buffer = _gbuf
	mm.visible_instance_count = n

func _feed_particles(dt: float) -> void:
	var cap := pcap()
	for b in w.bursts:
		var cnt: int = b[2]
		for k in cnt:
			if p_n >= cap: break
			var a := randf() * TAU
			var s := randf_range(0.3, 1.0) * float(b[3])
			p_pos[p_n] = b[0]; p_vel[p_n] = Vector2(cos(a), sin(a)) * s
			var l := randf_range(0.25, 0.5)
			p_life[p_n] = l; p_max[p_n] = l; p_col[p_n] = b[1]; p_size[p_n] = randf_range(6.0, 11.0)
			p_n += 1
	w.bursts.clear()
	var i := 0
	var drag := pow(0.02, dt)
	while i < p_n:
		p_life[i] -= dt
		if p_life[i] <= 0.0:
			p_n -= 1
			p_pos[i] = p_pos[p_n]; p_vel[i] = p_vel[p_n]; p_life[i] = p_life[p_n]; p_max[i] = p_max[p_n]; p_col[i] = p_col[p_n]; p_size[i] = p_size[p_n]
			continue
		p_pos[i] += p_vel[i] * dt
		p_vel[i] *= drag
		i += 1

# ================================================================= under layer
func _draw_under() -> void:
	if w == null: return
	var c := under
	# arena boundary (pinnacle)
	if w.arena_r > 0.0:
		c.draw_arc(Vector2.ZERO, w.arena_r, 0, TAU, 128, Color(0.75, 0.5, 1.0, 0.8), 6.0)
		c.draw_arc(Vector2.ZERO, w.arena_r + 14.0, 0, TAU, 128, Color(0.75, 0.5, 1.0, 0.25), 18.0)
	for ev in w.director.active:
		_draw_event(c, ev)
	for o in w.director.objects:
		_draw_object(c, o)
	for z in w.teles:
		_draw_tele(c, z)
	for p in w.picks:
		_draw_pick(c, p)

func _draw_tele(c: Node2D, z: World.Tele) -> void:
	if z.col.a <= 0.01: return
	var prog := 1.0 - clampf(z.arm / z.arm_max, 0.0, 1.0) if z.arm > 0.0 else 1.0
	var col := z.col
	var fill := Color(col.r, col.g, col.b, col.a * 0.25)
	var edge := Color(col.r, col.g, col.b, minf(1.0, col.a + 0.35))
	var pulse := 0.5 + 0.5 * sin(time * 10.0)
	match z.shape:
		0:
			c.draw_circle(z.pos, z.r, fill)
			if z.arm > 0.0:
				c.draw_circle(z.pos, z.r * prog, Color(col.r, col.g, col.b, col.a * 0.45))
			c.draw_arc(z.pos, z.r, 0, TAU, 48, edge, 2.5 + pulse * (2.0 if z.arm > 0.0 and z.arm < 0.3 else 0.0))
			if w.colorblind and z.hostile:
				for k in 6:
					var a := TAU * k / 6.0 + time
					c.draw_line(z.pos + Vector2(cos(a), sin(a)) * z.r * 0.3, z.pos + Vector2(cos(a), sin(a)) * z.r * 0.9, edge, 2.0)
		1:
			var mid := (z.r + z.r2) * 0.5
			c.draw_arc(z.pos, mid, 0, TAU, 128, fill if z.arm > 0.0 else Color(col.r, col.g, col.b, col.a * 0.6), z.r - z.r2)
			c.draw_arc(z.pos, z.r2, 0, TAU, 128, edge, 3.0)
		2:
			var a2 := z.pos
			var b := z.pos + z.dir * z.length
			var nrm := z.dir.orthogonal() * z.width * 0.5
			var poly := PackedVector2Array([a2 + nrm, b + nrm, b - nrm, a2 - nrm])
			c.draw_colored_polygon(poly, fill if z.arm > 0.0 else Color(col.r, col.g, col.b, col.a * (0.55 + 0.25 * pulse)))
			c.draw_polyline(PackedVector2Array([a2 + nrm, b + nrm, b - nrm, a2 - nrm, a2 + nrm]), edge, 2.0)
		3:
			var pts := PackedVector2Array([z.pos])
			for k in 13:
				pts.append(z.pos + z.dir.rotated(-z.ang + 2.0 * z.ang * k / 12.0) * z.r)
			c.draw_colored_polygon(pts, fill)

func _draw_event(c: Node2D, ev: Dictionary) -> void:
	var p: Vector2 = ev.pos
	match ev.id:
		"breach":
			var r: float = ev.r
			c.draw_circle(p, r, Color(0.45, 0.25, 0.8, 0.12))
			c.draw_arc(p, r, 0, TAU, 96, Color(0.75, 0.55, 1.0, 0.9), 4.0)
			for k in 5:
				var a := time * (0.6 + k * 0.2) + k * 1.3
				c.draw_arc(p, r * (0.25 + 0.15 * k), a, a + 1.6, 24, Color(0.8, 0.6, 1.0, 0.35), 3.0)
			_label(c, p + Vector2(0, -r - 16), "%.0fs" % ev.life, Color("e0c8ff"), 18)
		"cursed":
			_chest(c, p, Color("a02030"), Color("ff4a5e"))
			if ev.state == 1:
				c.draw_arc(p, 260.0, 0, TAU, 96, Color(1, 0.3, 0.35, 0.6), 3.0)
				c.draw_arc(p, 46.0, -PI / 2, -PI / 2 + TAU * clampf(float(ev.kills) / float(ev.quota), 0, 1), 32, Color("ffd84a"), 5.0)
				_label(c, p + Vector2(0, -60), "%d / %d   %.0fs" % [ev.kills, ev.quota, ev.life], Color("ffb0b0"), 18)
		"strongbox":
			_chest(c, p, Color("6a4a2a"), Color("c8a070"))
		"merchant":
			c.draw_circle(p + Vector2(0, 14), 16.0, Color(0, 0, 0, 0.3))
			c.draw_colored_polygon(PackedVector2Array([p + Vector2(-14, 14), p + Vector2(14, 14), p + Vector2(6, -16), p + Vector2(-6, -16)]), Color("2f7a4a"))
			c.draw_circle(p + Vector2(0, -20), 9.0, Color("e0c090"))
			_label(c, p + Vector2(0, -40), "Merchant", Color("7dff6b"), 16)
		"ritual":
			var pts := PackedVector2Array()
			for k in 6:
				var a := -PI / 2 + TAU * k / 5.0 * 2.0
				pts.append(p + Vector2(cos(a), sin(a)) * 28.0)
			c.draw_polyline(pts, Color("ff2b4a"), 3.0)
			c.draw_arc(p, 160.0 if ev.state == 1 else 34.0, 0, TAU, 64, Color(1, 0.17, 0.29, 0.5), 3.0)
		"delirium":
			c.draw_circle(p, ev.r, Color(0.85, 0.85, 0.95, 0.07 if not ev.inside else 0.12))
			c.draw_arc(p, ev.r, 0, TAU, 96, Color(0.9, 0.9, 1.0, 0.5), 2.0)
			_label(c, p + Vector2(0, -ev.r - 14), "Delirium %d" % ev.reward, Color("e8e8f8"), 18)

func _chest(c: Node2D, p: Vector2, body: Color, trim: Color) -> void:
	c.draw_rect(Rect2(p + Vector2(-16, -8), Vector2(32, 20)), body)
	c.draw_rect(Rect2(p + Vector2(-17, -14), Vector2(34, 8)), trim)
	c.draw_rect(Rect2(p + Vector2(-3, -6), Vector2(6, 8)), Color("ffd84a"))
	c.draw_arc(p, 30.0 + sin(time * 4.0) * 3.0, 0, TAU, 32, Color(trim.r, trim.g, trim.b, 0.5), 2.0)

func _draw_object(c: Node2D, o: Dictionary) -> void:
	var p: Vector2 = o.pos
	var col := Content.col(Content.BUFFS[o.id].col)
	if o.kind == "pylon":
		c.draw_colored_polygon(PackedVector2Array([p + Vector2(0, -46), p + Vector2(12, -8), p + Vector2(0, 10), p + Vector2(-12, -8)]), col.darkened(0.2))
		c.draw_colored_polygon(PackedVector2Array([p + Vector2(0, -46), p + Vector2(12, -8), p + Vector2(0, -14)]), col.lightened(0.4))
		c.draw_circle(p + Vector2(0, -20), 30.0 + sin(time * 3.0) * 4.0, Color(col.r, col.g, col.b, 0.15))
	else:
		c.draw_rect(Rect2(p + Vector2(-14, -22), Vector2(28, 30)), Color("4a4a58"))
		c.draw_circle(p + Vector2(0, -8), 7.0, col)
		c.draw_arc(p, 26.0, 0, TAU, 32, Color(col.r, col.g, col.b, 0.5), 2.0)
	_label(c, p + Vector2(0, -58), Content.BUFFS[o.id].name, col, 14)

func _draw_pick(c: Node2D, p: Dictionary) -> void:
	var pos: Vector2 = p.pos
	var bob := sin(time * 5.0 + pos.x * 0.1) * 2.0
	match p.k:
		"coin": c.draw_circle(pos + Vector2(0, bob), 5.0, Color("ffd84a")); c.draw_circle(pos + Vector2(-1, bob - 1), 2.0, Color("fff2b0"))
		"heart": c.draw_circle(pos + Vector2(-3, bob), 5.0, Color("ff4a5e")); c.draw_circle(pos + Vector2(3, bob), 5.0, Color("ff4a5e")); c.draw_colored_polygon(PackedVector2Array([pos + Vector2(-8, bob + 1), pos + Vector2(8, bob + 1), pos + Vector2(0, bob + 10)]), Color("ff4a5e"))
		"item":
			var it: Dictionary = p.data
			var rc := Content.col(Content.RARITY_COL[it.rarity])
			var h: float = 30.0 + 30.0 * it.rarity
			if it.rarity >= Content.Rarity.MAGIC:      # loot beam, taller per rarity
				c.draw_rect(Rect2(pos + Vector2(-3, -h), Vector2(6, h)), Color(rc.r, rc.g, rc.b, 0.35 + 0.15 * sin(time * 4.0)))
			c.draw_rect(Rect2(pos + Vector2(-7, -7 + bob), Vector2(14, 14)), rc.darkened(0.3))
			c.draw_rect(Rect2(pos + Vector2(-5, -5 + bob), Vector2(10, 10)), rc)
			if it.rarity >= Content.Rarity.RARE:
				_label(c, pos + Vector2(0, -h - 8), Items.name_of(it), rc, 14)
		"currency":
			var cc := Content.col(Content.CURRENCY[p.data].col)
			c.draw_colored_polygon(PackedVector2Array([pos + Vector2(0, -7 + bob), pos + Vector2(6, bob), pos + Vector2(0, 7 + bob), pos + Vector2(-6, bob)]), cc)
		"lore":
			c.draw_rect(Rect2(pos + Vector2(-8, -10 + bob), Vector2(16, 20)), Color("e8dcc0"))
			c.draw_line(pos + Vector2(-5, -4 + bob), pos + Vector2(5, -4 + bob), Color("8a7a5a"), 1.5)
			c.draw_line(pos + Vector2(-5, 1 + bob), pos + Vector2(5, 1 + bob), Color("8a7a5a"), 1.5)
			c.draw_rect(Rect2(pos + Vector2(-2, -60), Vector2(4, 50)), Color(0.9, 0.86, 0.75, 0.3))
		"fragment", "splinter":
			c.draw_colored_polygon(PackedVector2Array([pos + Vector2(0, -12 + bob), pos + Vector2(7, bob), pos + Vector2(0, 10 + bob), pos + Vector2(-7, bob)]), Color("c48aff"))
			if p.k == "fragment": c.draw_rect(Rect2(pos + Vector2(-3, -80), Vector2(6, 70)), Color(0.77, 0.54, 1.0, 0.4))
		"progress": c.draw_circle(pos + Vector2(0, bob), 7.0, Color("ff4fd8")); c.draw_circle(pos + Vector2(0, bob), 11.0, Color(1, 0.3, 0.85, 0.25))
		"flask": c.draw_rect(Rect2(pos + Vector2(-5, -8 + bob), Vector2(10, 14)), Color("c9f3ff")); c.draw_rect(Rect2(pos + Vector2(-3, -12 + bob), Vector2(6, 4)), Color("8a7a5a"))
		_:
			var pc := {"magnet": Color("8b6bff"), "frenzy": Color("ff8a2b"), "aegis": Color("ffd24a"), "vital": Color("5dff6b"), "nuke": Color("9fefff")}.get(p.k, Color.WHITE) as Color
			c.draw_circle(pos + Vector2(0, bob), 10.0, Color(pc.r, pc.g, pc.b, 0.3))
			c.draw_circle(pos + Vector2(0, bob), 6.5, pc)
			_label(c, pos + Vector2(0, bob + 4), String(p.k).substr(0, 1).to_upper(), Color(0.05, 0.05, 0.1), 11)

# ================================================================= actors
func _draw_actors() -> void:
	if w == null: return
	var c := actors
	var hcol := Content.col(Content.HEROES[w.hero].col)
	for g in ghosts:
		c.draw_circle(g[0], 10.0, Color(hcol.r, hcol.g, hcol.b, g[1]))
	# orbiting blades
	var cyc := w.buffs.has("cyclone")
	for b in w.blades.size():
		var bp := w.blades[b]
		var a := (bp - w.pp).angle() + PI / 2
		var dirv := Vector2(cos(a), sin(a))
		var len := 14.0 if not cyc else 22.0
		c.draw_line(bp - dirv * len, bp + dirv * len, Color("f0b94d"), 5.0)
		c.draw_line(bp - dirv * len, bp + dirv * len, Color("fff2c0"), 2.0)
	_draw_hero(c, hcol)
	# boss / exile name plates and health
	for u in w.boss_uids + ([w.bosses.exile_uid] if w.bosses.exile_uid >= 0 else []):
		var i := w.sw.index_of(u)
		if i < 0: continue
		var p := w.sw.pos[i]
		var rr := w.sw.rad[i]
		var fr := clampf(w.sw.hp[i] / w.sw.mhp[i], 0, 1)
		c.draw_rect(Rect2(p + Vector2(-rr, -rr - 16), Vector2(rr * 2, 5)), Color(0, 0, 0, 0.6))
		c.draw_rect(Rect2(p + Vector2(-rr, -rr - 16), Vector2(rr * 2 * fr, 5)), Color("ff4a5e"))
		if u == w.bosses.exile_uid:
			_label(c, p + Vector2(0, -rr - 22), w.bosses.exile_name, Color("ff8a2b"), 14)
	# elite affix tags
	for i in w.sw.n:
		if (w.sw.flags[i] & Swarm.F_ELITE) != 0 and w.sw.affix[i] != 0 and w.sw.pos[i].distance_to(w.pp) < 320.0:
			var names := ""
			for bit in Content.AFFIX_NAMES:
				if (w.sw.affix[i] & bit) != 0: names += Content.AFFIX_NAMES[bit] + " "
			_label(c, w.sw.pos[i] + Vector2(0, -w.sw.rad[i] - 8), names.strip_edges(), Color("ffd84a"), 11)

func _draw_hero(c: Node2D, hcol: Color) -> void:
	var p := w.pp
	var bob := sin(w.walk_ph) * 2.0 * w.mv
	var f := w.face
	var flip := -1.0 if f.x < 0.0 else 1.0
	c.draw_set_transform(Vector2.ZERO)
	c.draw_circle(p + Vector2(0, 13), 12.0, Color(0, 0, 0, 0.35))
	var hit := w.hit_t > 0.0
	var inv := w.inv_t > 0.0 and fmod(time, 0.12) < 0.06
	var body := Color.WHITE if hit else hcol
	if inv: body.a = 0.5
	# cape trailing opposite the facing
	var back := -f * (8.0 + 6.0 * w.mv)
	var cc := body.darkened(0.45)
	var sh0 := p + Vector2(-7, -6 + bob)
	var sh1 := p + Vector2(7, -6 + bob)
	var hem0 := p + back + Vector2(-9, 10)
	var hem1 := p + back + Vector2(9, 10)
	c.draw_polygon(PackedVector2Array([sh0, sh1, hem1]), PackedColorArray([cc, cc, cc]))
	c.draw_polygon(PackedVector2Array([sh0, hem1, hem0]), PackedColorArray([cc, cc, cc]))
	c.draw_circle(p + Vector2(0, bob), 11.0, Color("0d1019"))
	c.draw_circle(p + Vector2(0, bob), 9.5, body)
	c.draw_circle(p + Vector2(-2.5, -2.5 + bob), 4.5, body.lightened(0.3))
	# head + eyes looking along facing
	var hp := p + Vector2(0, -12 + bob)
	c.draw_circle(hp, 7.5, Color("0d1019"))
	c.draw_circle(hp, 6.5, Color("f0d0b0") if not hit else Color.WHITE)
	c.draw_circle(hp + f * 2.5 + Vector2(-2, -0.5), 1.4, Color("0d1019"))
	c.draw_circle(hp + f * 2.5 + Vector2(2, -0.5), 1.4, Color("0d1019"))
	# element focus held forward
	var el := Content.el_col(int(Content.HEROES[w.hero].elem), w.colorblind)
	c.draw_circle(p + f * 13.0 + Vector2(0, bob), 4.0 + sin(time * 8.0), Color(el.r, el.g, el.b, 0.9))
	if w.stats.flag("invuln"):
		c.draw_arc(p, 22.0, 0, TAU, 32, Color("ffd24a"), 3.0)
	# roll cooldown pip
	var rc := clampf(1.0 - w.roll_cd / 1.4, 0, 1)
	c.draw_arc(p + Vector2(0, 22), 4.0, -PI / 2, -PI / 2 + TAU * rc, 16, Color("c9f3ff") if rc >= 1.0 else Color("5a7f94"), 2.5)

# ================================================================= over layer
func _draw_over() -> void:
	if w == null: return
	var c := over
	for f in w.fx:
		var k: float = clampf(f.t / f.life, 0, 1)
		var col: Color = f.col
		match f.k:
			"ring":
				var r: float = lerpf(10.0, f.max, k)
				c.draw_arc(f.pos, r, 0, TAU, 64, Color(col.r, col.g, col.b, 1.0 - k), 6.0 * (1.0 - k) + 1.0)
			"zap", "arc":
				var pts: PackedVector2Array = f.pts
				c.draw_polyline(pts, Color(col.r, col.g, col.b, 1.0 - k), 4.0)
				c.draw_polyline(pts, Color(1, 1, 1, 1.0 - k), 1.5)
				if f.k == "zap": c.draw_circle(f.pos, f.r * (1.0 - k), Color(col.r, col.g, col.b, 0.3 * (1.0 - k)))
	_draw_texts(c)

func _draw_texts(c: Node2D) -> void:
	for e in w.texts:
		var k: float = e.t / (1.0 if e.tier == 3 else 0.65)
		var rise := -32.0 * k - (14.0 if e.tier == 3 else 0.0)
		var col: Color = e.col
		var size := 16
		var txt := ""
		match int(e.tier):
			0: txt = str(int(round(e.v)))
			1: txt = str(int(round(e.v))) + "!"; size = 22; col = Color("ffd24a")
			2: txt = str(int(round(e.v))); size = 18
			3: txt = e.label; size = 18
			4: txt = str(int(round(e.v))); size = 13
		if txt == "0" or txt == "": continue
		col.a = 1.0 - maxf(0.0, k - 0.6) * 2.5
		var pos: Vector2 = e.pos + Vector2(0, rise)
		var sc := 1.0 + (0.3 * (1.0 - minf(1.0, k * 6.0)) if e.tier == 1 else 0.0)
		_label(c, pos, txt, col, int(size * sc), true)

func _label(c: CanvasItem, p: Vector2, txt: String, col: Color, size: int, outline: bool = true) -> void:
	var wdt := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var at := p - Vector2(wdt * 0.5, 0)
	if outline:
		c.draw_string_outline(font, at, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 4, Color(0.03, 0.03, 0.06, col.a * 0.9))
	c.draw_string(font, at, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
