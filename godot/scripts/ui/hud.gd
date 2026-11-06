class_name Hud
extends Control
## In-run HUD: life/xp bars, timer or rift progress, boss bar, buff tray, event tracker, banner,
## toasts, combo meter, upgrade notice, edge-of-screen compass for objectives, full-screen hit
## flash and low-life vignette. Labels are only rewritten when their text changes.

signal pause_pressed

var w: World
var hp_bar: ProgressBar
var hp_txt: Label
var xp_bar: ProgressBar
var clock: Label
var info: Label
var boss_box: VBoxContainer
var boss_bar: ProgressBar
var boss_name: Label
var buffs_lbl: Label
var events_lbl: Label
var banner_t: Label
var banner_s: Label
var banner_time := 0.0
var toasts: VBoxContainer
var combo_lbl: Label
var upgrade_lbl: Label
var fps_lbl: Label
var flash_rect: ColorRect
var vignette: ColorRect
var _cache := {}
var project: Callable            # world (sim plane) -> screen; set by main for the active renderer

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	flash_rect = ColorRect.new()
	flash_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	flash_rect.color = Color(1, 1, 1, 0)
	flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(flash_rect)
	vignette = ColorRect.new()
	vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var vm := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = "shader_type canvas_item; uniform float k = 0.0; void fragment(){ float d = distance(UV, vec2(0.5)); COLOR = vec4(0.7, 0.0, 0.05, smoothstep(0.35, 0.75, d) * k); }"
	vm.shader = sh
	vignette.material = vm
	add_child(vignette)

	var m := MarginContainer.new()
	m.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	for s in ["left", "right", "top"]: m.add_theme_constant_override("margin_" + s, 14)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(m)
	var col := UIKit.vbox(6)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_child(col)
	var top := UIKit.hbox(12)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(top)
	var hpw := Control.new()
	hpw.custom_minimum_size = Vector2(0, 30)
	hpw.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hpw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(hpw)
	hp_bar = UIKit.bar(Color("e0505a"), 30)
	hp_bar.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hp_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hpw.add_child(hp_bar)
	hp_txt = UIKit.label("", 18)
	hp_txt.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hp_txt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hp_txt.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hpw.add_child(hp_txt)
	clock = UIKit.label("2:30", 28, UIKit.GOLD)
	clock.custom_minimum_size = Vector2(150, 0)
	clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	top.add_child(clock)
	var pb := UIKit.button("II", func(): pause_pressed.emit(), 48)
	pb.custom_minimum_size = Vector2(56, 48)
	top.add_child(pb)
	xp_bar = UIKit.bar(Color("6be8ff"), 10)
	xp_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(xp_bar)
	info = UIKit.label("", 17, UIKit.DIM)
	col.add_child(info)
	boss_box = UIKit.vbox(2)
	boss_box.visible = false
	boss_name = UIKit.label("", 18, Color("ffb0b0"))
	boss_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	boss_box.add_child(boss_name)
	boss_bar = UIKit.bar(Color("c0303a"), 14)
	boss_box.add_child(boss_bar)
	col.add_child(boss_box)
	buffs_lbl = UIKit.label("", 16, Color("c9f3ff"))
	col.add_child(buffs_lbl)
	events_lbl = UIKit.label("", 16, Color("e0c8ff"))
	col.add_child(events_lbl)
	combo_lbl = UIKit.label("", 26, UIKit.GOLD)
	col.add_child(combo_lbl)

	banner_t = UIKit.label("", 40, Color.WHITE)
	banner_t.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	banner_t.position.y = 200
	banner_t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner_t.add_theme_constant_override("outline_size", 8)
	banner_t.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	add_child(banner_t)
	banner_s = UIKit.label("", 20, UIKit.TEXT)
	banner_s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner_s.add_theme_constant_override("outline_size", 6)
	banner_s.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	add_child(banner_s)
	toasts = UIKit.vbox(4)
	toasts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(toasts)
	upgrade_lbl = UIKit.label("", 18, Color("7dff6b"))
	add_child(upgrade_lbl)
	fps_lbl = UIKit.label("", 14, UIKit.DIM)
	add_child(fps_lbl)

func bind(world: World) -> void:
	w = world
	_cache.clear()
	boss_box.visible = false
	banner_time = 0.0
	upgrade_lbl.text = ""
	UIKit.clear(toasts)
	w.banner.connect(show_banner)
	w.toast.connect(show_toast)
	w.item_found.connect(func(it: Dictionary, up: bool):
		if up: upgrade_lbl.text = "Upgrade found: " + Items.name_of(it) + "  (Pause > Gear)"
		elif int(it.rarity) >= Content.Rarity.RARE: show_toast(Items.name_of(it), Content.col(Content.RARITY_COL[it.rarity])))

func _put(k: String, node: Label, txt: String) -> void:
	if _cache.get(k) != txt:
		_cache[k] = txt
		node.text = txt

func show_banner(t: String, s: String, c: Color) -> void:
	banner_t.text = t
	banner_s.text = s
	banner_t.add_theme_color_override("font_color", c)
	banner_time = 2.6

func show_toast(t: String, c: Color) -> void:
	if toasts.get_child_count() > 4:
		toasts.get_child(0).queue_free()
	var l := UIKit.label(t, 18, c)
	l.add_theme_constant_override("outline_size", 5)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	toasts.add_child(l)
	var tw := create_tween()
	tw.tween_interval(2.2)
	tw.tween_property(l, "modulate:a", 0.0, 0.5)
	tw.tween_callback(l.queue_free)

func _process(dt: float) -> void:
	if w == null: return
	var vs := get_viewport_rect().size
	hp_bar.value = w.hp / w.max_hp
	_put("hp", hp_txt, "%d / %d" % [ceili(w.hp), ceili(w.max_hp)])
	xp_bar.value = w.xp / w.need
	match w.mode:
		"rift":
			_put("clock", clock, "%s  %d%%" % [_fmt(Content.GR_TIME - w.t), int(w.progress)])
		"pinnacle":
			_put("clock", clock, _fmt(maxf(0.0, w.bosses.herald_at - w.t)) if w.bosses.herald_uid < 0 else "HERALD")
		_:
			_put("clock", clock, "BOSS" if w.boss_spawned else _fmt(Content.STAGE_TIME - w.t))
	_put("info", info, "Lv %d   %d kills   %d gold   %s   %s" % [w.lvl, w.kills, int(w.gold), Content.HEROES[w.hero].name, ", ".join(w.keystones.map(func(k): return Content.KEYSTONES[k].name))])
	var bf := w.bosses.boss_hp_frac()
	boss_box.visible = bf >= 0.0
	if bf >= 0.0:
		boss_bar.value = bf
		var nm := "Rift Guardian" if w.mode == "rift" else ("The Shard Herald" + ("  ENRAGED" if w.bosses.H.get("enraged", false) else "  Phase %d" % w.bosses.herald_phase()) if w.mode == "pinnacle" else String(Content.STAGES[w.stage].boss))
		_put("bn", boss_name, nm)
	var bt := ""
	for b in w.buffs.list:
		var def: Dictionary = Content.BUFFS[b.id]
		bt += "%s%s %ds   " % [def.name, (" x%d" % b.stacks) if b.stacks > 1 else "", ceili(b.t)]
	_put("buffs", buffs_lbl, bt)
	var et := ""
	for ev in w.director.active:
		et += Content.EVENTS[ev.id].name
		match ev.id:
			"breach": et += " %ds (%d)" % [ceili(ev.life), ev.kills]
			"cursed": et += (" %d/%d %ds" % [ev.kills, ev.quota, ceili(ev.life)]) if ev.state == 1 else " (touch the chest)"
			"delirium": et += " reward %d" % ev.reward
			"eclipse", "meteor": et += " %ds" % ceili(ev.life)
		et += "   "
	_put("ev", events_lbl, et)
	_put("combo", combo_lbl, ("x%d combo" % w.combo) if w.combo >= 10 else "")
	if banner_time > 0.0:
		banner_time -= dt
		var a := clampf(banner_time / 0.5, 0, 1)
		banner_t.modulate.a = a
		banner_s.modulate.a = a
	else:
		banner_t.modulate.a = 0.0
		banner_s.modulate.a = 0.0
	banner_t.size.x = vs.x
	banner_t.position = Vector2(0, vs.y * 0.24)
	banner_s.size.x = vs.x
	banner_s.position = Vector2(0, vs.y * 0.24 + 52)
	toasts.position = Vector2(16, vs.y * 0.42)
	upgrade_lbl.position = Vector2(16, vs.y - 230)
	fps_lbl.visible = bool(Save.opt("show_fps"))
	if fps_lbl.visible:
		fps_lbl.text = "%d fps  %d foes  %s" % [Engine.get_frames_per_second(), w.sw.n, "GPU crowd" if w.crowd != null and w.crowd.ready else "CPU crowd"]
		fps_lbl.position = Vector2(vs.x - 260, vs.y - 30)
	var fl := w.flash * (0.3 if Save.opt("reduce_flash") else 1.0)
	flash_rect.color = Color(1, 1, 1, clampf(fl * 1.6, 0, 0.6))
	var low := clampf((0.35 - w.hp / w.max_hp) / 0.35, 0, 1) * (0.7 + 0.3 * sin(Time.get_ticks_msec() * 0.008))
	(vignette.material as ShaderMaterial).set_shader_parameter("k", low)
	queue_redraw()

static func _fmt(s: float) -> String:
	s = maxf(0.0, ceilf(s))
	return "%d:%02d" % [int(s) / 60, int(s) % 60]

## Edge-of-screen arrows pointing at off-screen objectives (events, shrines, rare loot, bosses).
func _draw() -> void:
	if w == null: return
	if not project.is_valid(): return
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
		if i >= 0: targets.append([w.sw.pos[i], Color("ff4a5e")])
	var c := vs * 0.5
	var rect := Rect2(Vector2(40, 120), vs - Vector2(80, 180))
	for t in targets:
		var sp: Vector2 = project.call(t[0] as Vector2)
		if rect.has_point(sp): continue
		var d := (sp - c)
		if d.length() < 1.0: continue
		var k := minf(absf((rect.size.x * 0.5) / d.x) if d.x != 0.0 else INF, absf((rect.size.y * 0.5) / d.y) if d.y != 0.0 else INF)
		var at := c + d * k
		var dir := d.normalized()
		var col: Color = t[1]
		draw_colored_polygon(PackedVector2Array([at + dir * 14.0, at + dir.orthogonal() * 9.0 - dir * 6.0, at - dir.orthogonal() * 9.0 - dir * 6.0]), col)
