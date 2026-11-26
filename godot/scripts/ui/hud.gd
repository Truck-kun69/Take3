class_name Hud
extends Control
## In-run HUD, ARPG layout (Diablo IV / PoE2):
##  bottom-left  liquid life globe (value in the num face), bottom-right ultimate globe
##  bottom-centre action bar: Roll / Flask 1 / Flask 2 / Ultimate slots with cooldown sweeps and key hints,
##                and a thin experience bar along the bottom edge
##  top-centre   carved timer plate (or rift progress), level / kills / gold line, ornate boss bar
##  top-left     buff tiles with remaining seconds; right side: active events and the combo counter
##  centre       event banners in Cinzel with an ornamental rule; toasts on the left
## On touch devices the action bar and ultimate globe give way to the touch buttons.

signal pause_pressed

var w: World
var project: Callable            # world (sim plane) -> screen; set by main for the active renderer
var life: Globe
var ultg: Globe
var bar: ActionBar
var xp_bar: ProgressBar
var clock: Label
var info: Label
var boss_box: VBoxContainer
var boss_bar: ProgressBar
var boss_name: Label
var buffs: BuffTray
var events_lbl: Label
var combo_lbl: Label
var banner_box: VBoxContainer
var banner_t: Label
var banner_s: Label
var banner_time := 0.0
var toasts: VBoxContainer
var upgrade_lbl: Label
var fps_lbl: Label
var _frame_ms := 16.0
var flash_rect: ColorRect
var vignette: ColorRect
var pause_btn: Button
const PAUSE_SIDE := 64
var top_plate: PanelContainer
var _cache := {}

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	flash_rect = _rect(Color(1, 1, 1, 0))
	vignette = _rect(Color(0, 0, 0, 0))
	var vm := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = "shader_type canvas_item; uniform float k = 0.0; void fragment(){ float d = distance(UV, vec2(0.5)); COLOR = vec4(0.55, 0.0, 0.03, smoothstep(0.35, 0.75, d) * k); }"
	vm.shader = sh
	vignette.material = vm
	# top centre: timer plate, info line, boss bar
	top_plate = PanelContainer.new()
	top_plate.add_theme_stylebox_override("panel", UIKit.nine("btn_normal", 16, Vector4(26, 4, 26, 6)))
	top_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tv := UIKit.vbox(0)
	clock = UIKit.label("2:30", 30, UIKit.GOLD, false, "display_heavy")
	clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tv.add_child(clock)
	info = UIKit.label("", 15, UIKit.DIM, false, "display")
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tv.add_child(info)
	top_plate.add_child(tv)
	add_child(top_plate)
	boss_box = UIKit.vbox(2)
	boss_box.visible = false
	boss_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	boss_name = UIKit.label("", 20, Color("f0d8c8"), false, "display")
	boss_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	boss_box.add_child(boss_name)
	boss_bar = UIKit.bar(Color("a01820"), 26)
	boss_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	boss_box.add_child(boss_bar)
	add_child(boss_box)
	buffs = BuffTray.new()
	add_child(buffs)
	events_lbl = UIKit.label("", 16, Color("d9c7ff"), true, "display")
	events_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	events_lbl.add_theme_constant_override("outline_size", 5)
	add_child(events_lbl)
	combo_lbl = UIKit.label("", 34, UIKit.GOLD, false, "display_heavy")
	combo_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(combo_lbl)
	# bottom: globes, action bar, experience
	life = Globe.new(); life.deep = Color(0.3, 0.01, 0.03); life.bright = Color(0.95, 0.14, 0.12)
	add_child(life)
	ultg = Globe.new(); ultg.deep = Color(0.16, 0.06, 0.32); ultg.bright = Color(0.9, 0.62, 1.0)
	add_child(ultg)
	bar = ActionBar.new()
	add_child(bar)
	xp_bar = UIKit.bar(Color("c99a3a"), 14)
	xp_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(xp_bar)
	# banner, toasts, notices
	banner_box = UIKit.vbox(2)
	banner_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner_t = UIKit.label("", 46, Color.WHITE, false, "display_heavy")
	banner_t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner_t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART     # upright a long act title (DROWNED CATHEDRAL) is wider than the canvas
	banner_box.add_child(banner_t)
	var dv := UIKit.divider()
	dv.custom_minimum_size = Vector2(520, 22)
	dv.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	banner_box.add_child(dv)
	banner_s = UIKit.label("", 21, UIKit.TEXT, false, "italic")
	banner_s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner_s.add_theme_constant_override("outline_size", 6)
	banner_box.add_child(banner_s)
	add_child(banner_box)
	toasts = UIKit.vbox(4)
	toasts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(toasts)
	upgrade_lbl = UIKit.label("", 18, Color("9bff8a"), false, "display")
	upgrade_lbl.add_theme_constant_override("outline_size", 5)
	add_child(upgrade_lbl)
	fps_lbl = UIKit.label("", 14, UIKit.DIM, false, "num")
	add_child(fps_lbl)
	# 64 x 64 (it was 56 x 46: 30 dp tall on an S22, the only way into Gear, Settings and leaving a run on touch)
	pause_btn = UIKit.button("II", func(): pause_pressed.emit(), PAUSE_SIDE)
	pause_btn.custom_minimum_size = Vector2(PAUSE_SIDE, PAUSE_SIDE)
	pause_btn.add_theme_font_size_override("font_size", 26)
	add_child(pause_btn)

func _rect(c: Color) -> ColorRect:
	var r := ColorRect.new()
	r.color = c
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(r)
	r.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return r

func bind(world: World) -> void:
	w = world
	_cache.clear()
	_last_vs = Vector2(-1, -1); _last_hp = -1; _last_ult = -1; _last_clock = -1; _last_info = -1; _last_combo = -1; _last_up = "?"; _ev_t = 0.0
	boss_box.visible = false
	banner_time = 0.0
	upgrade_lbl.text = ""
	UIKit.clear(toasts)
	buffs.w = world
	bar.w = world
	w.banner.connect(show_banner)
	w.toast.connect(show_toast)
	w.item_found.connect(func(it: Dictionary, up: bool):
		if up: upgrade_lbl.text = "Upgrade found: " + Items.name_of(it) + "   (Pause, then Gear)"
		elif int(it.rarity) >= Content.Rarity.RARE: show_toast(Items.name_of(it), Content.col(Content.RARITY_COL[it.rarity])))

## Sets a label's text only when it differs; returns true when it did (the caller may need to re-centre).
func _put(k: String, node: Label, txt: String) -> bool:
	if _cache.get(k) != txt:
		_cache[k] = txt
		node.text = txt
		return true
	return false

var _last_vs := Vector2(-1, -1)
var _last_touch := false
var _last_lh := false
var _last_hp := -1
var _last_ult := -1
var _last_clock := -1
var _last_info := -1
var _last_combo := -1
var _last_up := "?"
var _ev_t := 0.0
var _redraw_t := 0.0
var _safe := Vector4.ZERO              # safe-area insets in canvas units (left, top, right, bottom)
var _banner_scaled := false
## The lantern's flame, built once: a half ellipse plus a tip whose height follows the light.
var _flame_o := PackedVector2Array()
var _flame_i := PackedVector2Array()

var banner_dur := 2.8
func show_banner(t: String, s: String, c: Color, dur: float = 2.8) -> void:
	banner_t.text = t.to_upper()
	banner_s.text = s
	banner_t.add_theme_color_override("font_color", c.lerp(Color("f6e7c8"), 0.35))
	banner_dur = maxf(0.8, dur)
	banner_time = banner_dur

const ACT_BANNER_S := 3.5
## A campaign run opens on its act (Story): the title and, under it, the act's place in the story ("Act I · Where the
## first shard fell"), for ACT_BANNER_S, longer if that line needs it to be read at 15 characters a second
## (VoiceBank.read_seconds). The first line of its lore went with it: 108-122 characters in 3.5 s is 31-35 a second;
## the Codex keeps the lore. `title_only` while the coach's first prompt is due (main.start): the review found the
## act's lore (23 words), the narrator's line (23) and Brask's "Drag... to move" (11) on screen at once two seconds
## in, the instruction smallest and last.
func act_banner(world: World, title_only: bool = false) -> void:
	if world.mode != "campaign": return
	var a := Story.act(world.stage)
	var sub := "" if title_only else String(a.subtitle)
	show_banner(String(a.title), sub, Content.col(Content.STAGES[world.stage].acc), maxf(ACT_BANNER_S, VoiceBank.read_seconds(sub)))

func show_toast(t: String, c: Color) -> void:
	if toasts.get_child_count() > 4:
		toasts.get_child(0).queue_free()
	# a dark plate with a coloured edge, faded in (bare outlined text was hard to read over effects)
	var pc := PanelContainer.new()
	pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.025, 0.03, 0.72)
	sb.border_width_left = 3
	sb.border_color = c
	sb.content_margin_left = 12; sb.content_margin_right = 14; sb.content_margin_top = 3; sb.content_margin_bottom = 4
	sb.corner_radius_top_right = 6; sb.corner_radius_bottom_right = 6
	pc.add_theme_stylebox_override("panel", sb)
	var l := UIKit.label(t, 18, c.lerp(Color("f6e7c8"), 0.25), false, "body")
	pc.add_child(l)
	toasts.add_child(pc)
	pc.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(pc, "modulate:a", 1.0, 0.14)
	tw.tween_interval(2.2)
	tw.tween_property(pc, "modulate:a", 0.0, 0.45)
	tw.tween_callback(pc.queue_free)

func _touch() -> bool:
	return UIKit.is_touch()

func _process(dt: float) -> void:
	if w == null: return
	var vs := get_viewport_rect().size
	var touch := _touch()
	# Layout is recomputed only when the screen size or the touch mode changes (it used to move and resize
	# every control every frame, and reset the top plate's size, which re-ran its container layout).
	# Content-driven positions (the plate's centring, the boss bar under it, the combo under the event
	# list) follow their text through `_put`, which reports a change.
	# the left-handed layout puts the touch buttons bottom left, so the life globe takes the bottom right (it sat on
	# ROLL: the button's centre 129 px from the globe's on an S22, their radii 78 + 95)
	var lh := touch and bool(Save.opt("left_handed"))
	var relayout := vs != _last_vs or touch != _last_touch or lh != _last_lh
	if relayout:
		_last_vs = vs
		_last_touch = touch
		_last_lh = lh
		var gs := clampf(minf(vs.x, vs.y) / 720.0, 0.75, 1.25) * (0.85 if touch else 1.0)
		var m := UIKit.safe_margins(vs)          # x left, y top, z right, w bottom: camera cutouts, rounded corners
		_safe = m
		var gsize := 150.0 * gs
		life.size = Vector2(gsize, gsize)
		life.position = Vector2((vs.x - gsize - 14 - m.z) if lh else (14 + m.x), vs.y - gsize - 12 - m.w)
		ultg.visible = not touch
		ultg.size = Vector2(gsize, gsize)
		ultg.position = Vector2(vs.x - gsize - 14 - m.z, vs.y - gsize - 12 - m.w)
		bar.visible = not touch
		var bw := minf(vs.x - 2 * gsize - 60, 4 * 76.0 * gs + 3 * 10)
		bar.slot = 76.0 * gs
		bar.size = Vector2(bw, 76.0 * gs + 20)
		bar.position = Vector2((vs.x - bw) * 0.5, vs.y - bar.size.y - 22 - m.w)
		var xl := (vs.x * 0.45) if lh else (life.position.x + gsize + 10)
		var xr := (life.position.x - 10) if lh else ((ultg.position.x - 10) if not touch else (vs.x * 0.55))
		xp_bar.position = Vector2(xl, vs.y - 26 - m.w)
		xp_bar.size = Vector2(maxf(60.0, xr - xl), 16)
		pause_btn.position = Vector2(vs.x - PAUSE_SIDE - 12 - m.z, 10 + m.y)
		buffs.position = Vector2(14 + m.x, 12 + m.y)
		buffs.size = Vector2(vs.x * 0.35, 60)
		events_lbl.size = Vector2(minf(360, vs.x * 0.4), 0)
		events_lbl.position = Vector2(vs.x - events_lbl.size.x - 16 - m.z, PAUSE_SIDE + 22 + m.y)       # under the pause button
		combo_lbl.size = Vector2(200, 0)
		banner_box.pivot_offset = Vector2(vs.x * 0.5, 40.0)
		banner_box.size = Vector2(vs.x, 0)
		banner_box.position = Vector2(0, vs.y * 0.2)
		toasts.position = Vector2(18 + m.x, vs.y * 0.4)
		fps_lbl.position = Vector2(vs.x - 330 - m.z, vs.y - 70 - m.w)
	# globes and bottom bar: values
	life.fill = w.hp / w.max_hp
	var hp_i := ceili(w.hp)
	if hp_i != _last_hp:
		_last_hp = hp_i
		life.value_text = "%d" % hp_i
	life.hurt = 1.0 if w.hit_t > 0.0 else 0.0
	if not touch:
		ultg.fill = w.ult / 100.0
		var ult_i := int(w.ult)
		if ult_i != _last_ult:
			_last_ult = ult_i
			ultg.value_text = "READY" if w.ult >= 100.0 else "%d%%" % ult_i
	xp_bar.value = w.xp / w.need
	# top centre: the strings are rebuilt only when a number in them changes
	var plate_dirty := relayout
	var clock_key := int(ceilf(w.t)) * 4 + (1 if w.boss_spawned else 0) + (2 if w.bosses.herald_uid >= 0 else 0) + int(w.progress) * 100000
	if clock_key != _last_clock:
		_last_clock = clock_key
		match w.mode:
			"rift": plate_dirty = _put("clock", clock, "%s   %d%%" % [_fmt(Content.GR_TIME - w.t), int(w.progress)]) or plate_dirty
			"pinnacle": plate_dirty = _put("clock", clock, _fmt(maxf(0.0, w.bosses.herald_at - w.t)) if w.bosses.herald_uid < 0 else "THE HERALD") or plate_dirty
			_: plate_dirty = _put("clock", clock, "BOSS" if w.boss_spawned else _fmt(Content.STAGE_TIME - w.t)) or plate_dirty
	var info_key := w.lvl * 1000003 + w.kills * 1009 + int(w.gold)
	if info_key != _last_info:
		_last_info = info_key
		plate_dirty = _put("info", info, "Level %d   ·   %d slain   ·   %d gold" % [w.lvl, w.kills, int(w.gold)]) or plate_dirty
	if plate_dirty:
		top_plate.size = Vector2(0, 0)
		top_plate.position = Vector2((vs.x - top_plate.get_combined_minimum_size().x) * 0.5, 8 + _safe.y)
	var bf := w.bosses.boss_hp_frac()
	var boss_on := bf >= 0.0
	if boss_on != boss_box.visible:
		boss_box.visible = boss_on
		plate_dirty = true
	if boss_on:
		boss_bar.value = bf
		var nm := "Rift Guardian" if w.mode == "rift" else ("The Shard Herald" + ("   ·   Enraged" if w.bosses.H.get("enraged", false) else "   ·   Phase %d" % w.bosses.herald_phase()) if w.mode == "pinnacle" else String(Story.act(w.stage).boss_name))
		_put("bn", boss_name, nm.to_upper())
		if plate_dirty:
			var bwid := minf(vs.x * 0.5, 640.0)
			boss_box.size = Vector2(bwid, 0)
			boss_box.position = Vector2((vs.x - bwid) * 0.5, top_plate.position.y + top_plate.get_combined_minimum_size().y + 6)
	# running events: rebuilt four times a second (they show whole seconds and counts)
	_ev_t -= dt
	var ev_dirty := relayout
	if _ev_t <= 0.0 or relayout:
		_ev_t = 0.25
		var et := ""
		for ev in w.director.active:
			var line: String = Content.EVENTS[ev.id].name
			match ev.id:
				"breach": line += "  %ds  (%d)" % [ceili(ev.life), ev.kills]
				"cursed": line += ("  %d/%d  %ds" % [ev.kills, ev.quota, ceili(ev.life)]) if ev.state == 1 else "  (touch the chest)"
				"delirium": line += "  reward %d" % ev.reward
				"eclipse", "meteor", "merchant", "forge": line += "  %ds" % ceili(ev.life)
			et += line + "\n"
		ev_dirty = _put("ev", events_lbl, et.strip_edges()) or ev_dirty
	var combo_i := w.combo if w.combo >= 10 else 0
	if combo_i != _last_combo:
		_last_combo = combo_i
		_put("combo", combo_lbl, ("x%d" % combo_i) if combo_i > 0 else "")
	if ev_dirty:
		combo_lbl.position = Vector2(vs.x - 216 - _safe.z, events_lbl.position.y + events_lbl.get_combined_minimum_size().y + 6)
	# banner and toasts
	var a := 0.0
	if banner_time > 0.0:
		banner_time -= dt
		a = clampf(banner_time / 0.5, 0, 1) * clampf((banner_dur - banner_time) / 0.2, 0, 1)
	if banner_box.modulate.a != a: banner_box.modulate.a = a
	if a > 0.0 or _banner_scaled:
		var punch := clampf(1.0 - (banner_dur - banner_time) / 0.22, 0.0, 1.0) if banner_time > 0.0 else 0.0
		banner_box.scale = Vector2.ONE * (1.0 + 0.12 * punch * punch)        # lands with a small punch
		_banner_scaled = punch > 0.0
	var up_txt := upgrade_lbl.text
	if up_txt != _last_up or relayout:
		_last_up = up_txt
		upgrade_lbl.position = Vector2((vs.x - upgrade_lbl.get_combined_minimum_size().x) * 0.5, bar.position.y - 30 if not touch else vs.y - 230 - _safe.w)
	fps_lbl.visible = bool(Save.opt("show_fps"))
	if fps_lbl.visible:
		_frame_ms = lerpf(_frame_ms, dt * 1000.0, 0.1)
		fps_lbl.text = "%d fps  %.1f ms  %d foes  sim %.1f  view %.1f\n%d draws  %dk tris  %s  3D %d%%" % [Engine.get_frames_per_second(), _frame_ms, w.sw.n, w.step_us / 1000.0, Diag.view_us / 1000.0,
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1000.0),
			"GPU crowd" if w.crowd != null and w.crowd.ready else "CPU crowd", int(get_viewport().scaling_3d_scale * 100.0)]
	var fl := w.flash * (0.3 if Save.opt("reduce_flash") else 1.0)
	flash_rect.color = Color(1, 1, 1, clampf(fl * 1.6, 0, 0.6))
	var low := clampf((0.35 - w.hp / w.max_hp) / 0.35, 0, 1) * (0.7 + 0.3 * sin(Time.get_ticks_msec() * 0.008))
	(vignette.material as ShaderMaterial).set_shader_parameter("k", low)
	# the custom-drawn layer (off-screen markers, lantern, hoard and prophecy lines) redraws at 20 Hz:
	# none of it needs the full frame rate, and every redraw rebuilds its polygons and text
	_redraw_t -= dt
	if _redraw_t <= 0.0 or relayout:
		_redraw_t = 0.05
		queue_redraw()

static func _fmt(s: float) -> String:
	s = maxf(0.0, ceilf(s))
	return "%d:%02d" % [int(s) / 60, int(s) % 60]

## Edge-of-screen chevrons pointing at off-screen objectives (events, shrines, rare loot, bosses).
func _draw() -> void:
	if w == null or not project.is_valid(): return
	var vs := get_viewport_rect().size
	var targets: Array = []
	for ev in w.director.active:
		targets.append([ev.pos, Content.col(Content.EVENTS[ev.id].col)])
	for o in w.director.objects:
		targets.append([o.pos, Content.col(Content.BUFFS[o.id].col)])
	for p in w.picks:
		if p.k == "item" and int(p.data.rarity) >= Content.Rarity.RARE:
			targets.append([p.pos, Content.col(Content.RARITY_COL[p.data.rarity])])
		elif p.k in ["lore", "fragment"]:
			targets.append([p.pos, Color("e8dcc0")])
	for u in w.boss_uids:
		var i := w.sw.index_of(u)
		if i >= 0: targets.append([w.sw.pos[i], Content.DANGER])
	for e in w.rift_echoes:
		if not e.taken: targets.append([e.pos, Color("c48aff")])
	var c := vs * 0.5
	var rect := Rect2(Vector2(50, 120), vs - Vector2(100, 300))
	for t in targets:
		var sp: Vector2 = project.call(t[0] as Vector2)
		if rect.has_point(sp): continue
		var d := sp - c
		if d.length() < 1.0: continue
		var k := minf(absf((rect.size.x * 0.5) / d.x) if d.x != 0.0 else INF, absf((rect.size.y * 0.5) / d.y) if d.y != 0.0 else INF)
		var at := c + d * k
		var dir := d.normalized()
		var n := dir.orthogonal()
		var col: Color = t[1]
		var pts := PackedVector2Array([at + dir * 16.0, at + n * 11.0 - dir * 6.0, at - dir * 1.0, at - n * 11.0 - dir * 6.0])
		draw_colored_polygon(pts, Color(0.05, 0.04, 0.04, 0.85))
		var inner := PackedVector2Array([at + dir * 11.0, at + n * 7.0 - dir * 3.0, at + dir * 1.0, at - n * 7.0 - dir * 3.0])
		draw_colored_polygon(inner, col)
		draw_polyline(PackedVector2Array([pts[0], pts[1], pts[2], pts[3], pts[0]]), Color("c99a50"), 1.5)
	_lantern()

## Small HUD text (hoard, prophecy, Engulfed): UIKit.MIN_TEXT (it was 16, 10.3 sp on an S22) with a dark outline so
## it reads over effects.
func _small(f: Font, p: Vector2, txt: String, c: Color) -> void:
	draw_string_outline(f, p, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, UIKit.MIN_TEXT, 4, Color(0.02, 0.015, 0.02, 0.85 * c.a))
	draw_string(f, p, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, UIKit.MIN_TEXT, c)

## The lantern (World.light): a flame and a bar left of the timer plate. Gold while lit, guttering
## toward violet as it fades; below the Engulfed line it pulses and the flame shrinks to an ember.
func _lantern() -> void:
	if w.mode == "pinnacle": return
	var tp := top_plate.position
	var th := top_plate.get_combined_minimum_size().y
	var wid := 150.0
	var at := Vector2(tp.x - wid - 28.0, tp.y + th * 0.5 + 6.0)
	if at.x < 230.0: at = Vector2(tp.x + top_plate.get_combined_minimum_size().x * 0.5 - wid * 0.5 + 10.0, tp.y + th + 8.0)   # narrow screens: under the plate
	var l: float = w.light
	var eng := l < World.LIGHT_ENGULF
	var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.009)
	var col := Color("6a4fb0").lerp(Color("ffc45a"), clampf(l / 0.7, 0.0, 1.0))
	if eng: col = col.lerp(Color("b48aff"), pulse * 0.6)
	var bar := Rect2(at + Vector2(0, -6), Vector2(wid, 12))
	draw_rect(bar.grow(2.0), Color(0.03, 0.02, 0.03, 0.85))
	draw_rect(Rect2(bar.position, Vector2(wid * w.light_cap, 12)), Color(0.12, 0.1, 0.12, 0.9))
	draw_rect(Rect2(bar.position, Vector2(wid * l, 12)), col)
	var ex := bar.position.x + wid * World.LIGHT_ENGULF
	draw_line(Vector2(ex, bar.position.y - 2), Vector2(ex, bar.end.y + 2), Color(0.8, 0.7, 1.0, 0.7), 1.5)
	draw_rect(bar.grow(2.0), Color("c99a50"), false, 1.2)
	# the flame: a teardrop that shrinks and dims with the light
	var fc := Vector2(at.x - 17.0, at.y + 4.0)
	var fh := lerpf(7.0, 21.0, clampf(l / 0.6, 0.0, 1.0)) * (1.0 + 0.08 * sin(Time.get_ticks_msec() * 0.021))
	if _flame_o.is_empty():
		for i in 13:
			var fa := PI * i / 12.0
			_flame_o.append(Vector2(cos(fa) * 7.5, sin(fa) * 5.5))
			_flame_i.append(_flame_o[i] * 0.72)
		_flame_o.append(Vector2.ZERO)
		_flame_i.append(Vector2.ZERO)
	_flame_o[13] = Vector2(0, -fh)
	_flame_i[13] = Vector2(0, -fh * 0.72)
	draw_set_transform(fc)
	draw_colored_polygon(_flame_o, Color(0.02, 0.01, 0.02, 0.8))
	draw_colored_polygon(_flame_i, col.lightened(0.25))
	draw_set_transform(Vector2.ZERO)
	if w.hoard > 0.0 or w.hoard_mult > 1.0:                  # bank-or-push: what a death would cost
		var f3 := UIKit.font("label")
		var hc := Color("7fd8ff").lerp(Color("ffb347"), clampf((w.hoard_mult - 1.0) / 2.0, 0.0, 1.0))
		_small(f3, Vector2(bar.position.x, bar.end.y + 16.0), "HOARD %d  x%.1f" % [int(w.hoard), w.hoard_mult], hc)
	if not w.prophecy.is_empty():                              # the active prophecy's progress
		var f4 := UIKit.font("label")
		var pr: Vector2 = w.prophecy_progress()
		var pc := Color("ffd27a") if not w.prophecy_done else Color("8aff9a")
		var ptx := ("%s  %d/%d" % [Content.PROPHECIES[w.prophecy.id].name.to_upper(), int(pr.x), int(pr.y)]) if not w.prophecy_done else "PROPHECY FULFILLED"
		_small(f4, Vector2(bar.position.x, bar.end.y + 36.0), ptx, pc)      # 20 under the hoard's line at the 18 floor
	if eng:
		var f2 := UIKit.font("label")
		var et := "ENGULFED"
		var ew := f2.get_string_size(et, HORIZONTAL_ALIGNMENT_LEFT, -1, UIKit.MIN_TEXT).x     # measured at the size _small draws
		_small(f2, Vector2(fc.x - 14.0 - ew, bar.end.y - 1.0), et, Color(0.8, 0.68, 1.0, 0.6 + 0.4 * pulse))


## Liquid globe with the bronze frame and a value in the num face.
class Globe extends Control:
	var fill := 1.0
	var hurt := 0.0
	var value_text := ""
	var deep := Color.RED
	var bright := Color.RED
	var _liq: ColorRect
	var _frame: TextureRect
	var _val: Label
	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_liq = ColorRect.new()
		_liq.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var m := ShaderMaterial.new()
		m.shader = load("res://shaders/globe.gdshader")
		_liq.material = m
		add_child(_liq)
		_frame = TextureRect.new()
		_frame.texture = UIKit.tex("orb_frame")
		_frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_frame)
		_val = UIKit.label("", 22, Color("fff3e6"), false, "num_heavy")
		_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_val.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_val.add_theme_constant_override("outline_size", 6)
		add_child(_val)
	func _process(_dt: float) -> void:
		var inset := size * 0.06
		_liq.position = inset
		_liq.size = size - inset * 2.0
		_frame.size = size
		_val.size = size
		_val.add_theme_font_size_override("font_size", maxi(UIKit.MIN_TEXT, int(size.x * 0.15)))     # 16 on a touch S22 (10.3 sp)
		_val.text = value_text
		var m := _liq.material as ShaderMaterial
		m.set_shader_parameter("fill", fill)
		m.set_shader_parameter("hurt", hurt)
		m.set_shader_parameter("deep", deep)
		m.set_shader_parameter("bright", bright)
		m.set_shader_parameter("time", Time.get_ticks_msec() / 1000.0)


## Bottom action bar: four bronze slots with an icon glyph, cooldown sweep, charge fill and key hint.
class ActionBar extends Control:
	var w: World
	var slot := 76.0
	const SLOTS := [["roll", "Space"], ["f0", "1"], ["f1", "2"], ["ult", "R"]]
	var tex: Texture2D
	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		tex = UIKit.tex("slot")          # load outside _draw: a texture first loaded mid-draw renders blank
	func _process(_dt: float) -> void:
		queue_redraw()
	func _draw() -> void:
		if w == null: return
		var fnt := UIKit.font("num")
		var lfont := UIKit.font("display")
		var gap := 10.0
		for k in SLOTS.size():
			var r := Rect2(Vector2(k * (slot + gap), 0), Vector2(slot, slot))
			draw_texture_rect(tex, r, false)
			var c := r.get_center()
			var rad := slot * 0.3
			var frac := 1.0
			var col := Color.WHITE
			var label := ""
			match SLOTS[k][0]:
				"roll":
					frac = clampf(1.0 - w.roll_cd / 1.4, 0, 1); col = Color("cfe9ff"); label = "Roll"
					_glyph_roll(c, rad, col)
				"f0", "f1":
					var fl: Dictionary = w.flasks[0 if SLOTS[k][0] == "f0" else 1]
					frac = fl.c / fl.max
					col = Color("e0333a") if fl.id == "life" else Color("8adfff")
					label = "Life" if fl.id == "life" else String(fl.id).capitalize()
					_glyph_flask(c, rad, col, frac)
				"ult":
					frac = w.ult / 100.0; col = Color("d8a8ff"); label = "Ultimate"
					_glyph_star(c, rad, col)
			if frac < 1.0:                                      # cooldown / charge sweep
				var pts := PackedVector2Array([c])
				var a0 := -PI / 2 + TAU * frac
				for s in 25:
					var a := a0 + (TAU * (1.0 - frac)) * s / 24.0
					pts.append(c + Vector2(cos(a), sin(a)) * slot * 0.42)
				draw_colored_polygon(pts, Color(0, 0, 0, 0.55))
			elif SLOTS[k][0] == "ult":
				draw_arc(c, slot * 0.42, 0, TAU, 40, Color(0.85, 0.6, 1.0, 0.5 + 0.4 * sin(Time.get_ticks_msec() * 0.006)), 3.0)
			draw_string_outline(fnt, r.position + Vector2(6, 20), SLOTS[k][1], HORIZONTAL_ALIGNMENT_LEFT, -1, 17, 4, Color(0, 0, 0, 0.9))
			draw_string(fnt, r.position + Vector2(6, 20), SLOTS[k][1], HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color("e8d6b0"))
			var lw := lfont.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
			draw_string_outline(lfont, Vector2(c.x - lw * 0.5, r.end.y + 17), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, 4, Color(0, 0, 0, 0.9))
			draw_string(lfont, Vector2(c.x - lw * 0.5, r.end.y + 17), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, UIKit.DIM)
	func _glyph_roll(c: Vector2, r: float, col: Color) -> void:
		draw_arc(c, r, -2.4, 1.2, 24, col, 3.0)
		var tip := c + Vector2(cos(1.2), sin(1.2)) * r
		draw_colored_polygon(PackedVector2Array([tip + Vector2(6, -2), tip + Vector2(-4, 6), tip + Vector2(-2, -6)]), col)
	func _glyph_flask(c: Vector2, r: float, col: Color, frac: float) -> void:
		var body := Rect2(c + Vector2(-r * 0.6, -r * 0.3), Vector2(r * 1.2, r * 1.15))
		draw_rect(body, Color(0.08, 0.06, 0.07), true)
		draw_rect(Rect2(body.position + Vector2(0, body.size.y * (1.0 - frac)), Vector2(body.size.x, body.size.y * frac)), col, true)
		draw_rect(body, Color("c99a50"), false, 2.0)
		draw_rect(Rect2(c + Vector2(-r * 0.25, -r * 0.75), Vector2(r * 0.5, r * 0.45)), Color("8a6a3a"), true)
	func _glyph_star(c: Vector2, r: float, col: Color) -> void:
		var pts := PackedVector2Array()
		for i in 10:
			var a := -PI / 2 + i * TAU / 10.0
			pts.append(c + Vector2(cos(a), sin(a)) * (r if i % 2 == 0 else r * 0.42))
		draw_colored_polygon(pts, col)


## Buff tiles: a small bronze slot each, element-coloured gem, stacks, and seconds remaining.
class BuffTray extends Control:
	var w: World
	var tex: Texture2D
	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		tex = UIKit.tex("slot")
	func _process(_dt: float) -> void:
		queue_redraw()
	func _draw() -> void:
		if w == null: return
		var fnt := UIKit.font("num")
		var s := 46.0
		var x := 0.0
		for b in w.buffs.list:
			var def: Dictionary = Content.BUFFS[b.id]
			var r := Rect2(Vector2(x, 0), Vector2(s, s))
			draw_texture_rect(tex, r, false)
			var col := Content.col(def.col)
			var c := r.get_center()
			draw_colored_polygon(PackedVector2Array([c + Vector2(0, -12), c + Vector2(10, 0), c + Vector2(0, 12), c + Vector2(-10, 0)]), col)
			draw_colored_polygon(PackedVector2Array([c + Vector2(0, -12), c + Vector2(10, 0), c + Vector2(0, -2)]), col.lightened(0.45))
			var frac := clampf(b.t / maxf(0.01, b.dur), 0, 1)
			draw_rect(Rect2(r.position + Vector2(5, s - 7), Vector2((s - 10) * frac, 3)), col, true)
			var txt := "%d" % ceili(b.t)
			draw_string_outline(fnt, r.position + Vector2(4, s + 16), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, 4, Color(0, 0, 0, 0.9))
			draw_string(fnt, r.position + Vector2(4, s + 16), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color("e8d6b0"))
			if b.stacks > 1:
				draw_string_outline(fnt, r.position + Vector2(s - 18, 17), str(b.stacks), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, 4, Color(0, 0, 0, 0.9))
				draw_string(fnt, r.position + Vector2(s - 18, 17), str(b.stacks), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)
			x += s + 8
