class_name Overlay3D
extends Control
## Screen-space text over the 3D world, projected from world positions:
##  - damage numbers (pop, rise, fade; crits larger and gold; reaction names in their colour)
##  - PoE-style loot labels: dark plate, rarity-coloured border and name, for magic and better
##  - boss / exile nameplates with health, elite affix tags, event timers and object names
##  - a constant soft vignette that frames the action (PoE2's look)

var view: WorldView3D
var font: Font                     # damage numbers (Alegreya Sans black)
var f_name: Font                   # reactions, boss / exile names (Cinzel)
var f_tag: Font                    # events, affixes (Marcellus SC)
var f_loot: Font                   # loot plates (EB Garamond)
var _vig: ColorRect

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	font = UIKit.font("num_heavy")
	f_name = UIKit.font("display")
	f_tag = UIKit.font("label")
	f_loot = UIKit.font("body")
	_vig = ColorRect.new()
	_vig.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_vig.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sm := ShaderMaterial.new()
	var sh := Shader.new()
	# gloom (the lantern running low) pulls the dark ring in toward the hero
	sh.code = "shader_type canvas_item; uniform float gloom = 0.0; void fragment(){ vec2 d = (UV - 0.5) * vec2(1.2, 1.0); float r = length(d); float a = smoothstep(0.45, 0.85, r) * 0.55; a = max(a, smoothstep(0.46 - 0.18 * gloom, 0.85 - 0.2 * gloom, r) * 0.8 * gloom); COLOR = vec4(0.0, 0.0, 0.03, a); }"
	sm.shader = sh
	_vig.material = sm
	add_child(_vig)

func _process(_dt: float) -> void:
	visible = view != null and view.w != null and view.visible
	if visible:
		queue_redraw()
		var g := 0.0 if view.w.director.eclipse() else view.w.gloom()     # eclipse already has its own look
		(_vig.material as ShaderMaterial).set_shader_parameter("gloom", g)

func _text(p: Vector2, txt: String, col: Color, size: int, outline: int = 5, f: Font = null) -> void:
	if f == null: f = f_tag
	var wdt := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var at := p - Vector2(wdt * 0.5, 0)
	draw_string_outline(f, at, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, size, outline, Color(0.02, 0.02, 0.04, col.a * 0.9))
	draw_string(f, at, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)

## PoE-style loot plate: near-black body, rarity border with a darker inner line, name in Garamond.
func _plate(p: Vector2, txt: String, col: Color, size: int) -> void:
	var sz := f_loot.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, size)
	var asc := f_loot.get_ascent(size)
	var r := Rect2(p - Vector2(sz.x * 0.5 + 9, asc + 3), Vector2(sz.x + 18, asc + f_loot.get_descent(size) + 6))
	draw_rect(r, Color(0.015, 0.012, 0.018, 0.86))
	draw_rect(r.grow(-2), Color(col.r, col.g, col.b, 0.22), false, 1.0)
	draw_rect(r, col, false, 1.5)
	draw_string(f_loot, Vector2(r.position.x + 9, r.position.y + 3 + asc), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)

func _draw() -> void:
	if view == null or view.w == null:
		return
	var w := view.w
	var vs := get_viewport_rect().size
	var on := Rect2(Vector2(-60, -60), vs + Vector2(120, 120))
	# loot labels (PoE style). Only magic+ items and rare drops get plates, to keep the screen clean.
	for p in w.picks:
		var sp := view.to_screen(p.pos, 26.0)
		if not on.has_point(sp): continue
		match p.k:
			"item":
				var it: Dictionary = p.data
				if int(it.rarity) >= Content.Rarity.MAGIC:
					_plate(sp + Vector2(0, -12), Items.name_of(it), Content.col(Content.RARITY_COL[it.rarity]), 16 if it.rarity < 2 else 18)
			"currency": _plate(sp + Vector2(0, -10), Content.CURRENCY[p.data].name, Content.col(Content.CURRENCY[p.data].col), 15)
			"lore": _plate(sp + Vector2(0, -10), "Lore Page", Color("e8dcc0"), 15)
			"fragment": _plate(sp + Vector2(0, -10), "Fragment of " + String(p.data).capitalize(), Color("c48aff"), 17)
	# event and object names
	for ev in w.director.active:
		var sp2 := view.to_screen(ev.pos, 60.0)
		if not on.has_point(sp2): continue
		var label: String = Content.EVENTS[ev.id].name
		match ev.id:
			"breach": label += "  %ds" % ceili(ev.life)
			"cursed": label += ("  %d/%d  %ds" % [ev.kills, ev.quota, ceili(ev.life)]) if ev.state == 1 else ""
			"delirium": label += "  %d" % ev.reward
			"eclipse", "meteor", "exile": continue
		_text(sp2, label, Content.col(Content.EVENTS[ev.id].col), 15)
	for o in w.director.objects:
		var sp3 := view.to_screen(o.pos, 96.0)
		if on.has_point(sp3): _text(sp3, Content.BUFFS[o.id].name, Content.col(Content.BUFFS[o.id].col), 14)
	# elite affixes and boss / exile plates
	for i in w.sw.n:
		var f := w.sw.flags[i]
		if (f & (Swarm.F_ELITE | Swarm.F_EXILE)) == 0: continue
		var p3 := w.sw.pos[i]
		if p3.distance_to(w.pp) > 420.0: continue
		var sp4 := view.to_screen(p3, w.sw.rad[i] * 2.6 + 8.0)
		if (f & Swarm.F_EXILE) != 0:
			_text(sp4 + Vector2(0, -12), w.bosses.exile_name, Color("ff8a2b"), 16, 5, f_name)
			_bar(sp4, 70.0, w.sw.hp[i] / w.sw.mhp[i], Color("ff8a2b"))
		elif w.sw.affix[i] != 0:
			var names := ""
			for bit in Content.AFFIX_NAMES:
				if (w.sw.affix[i] & bit) != 0: names += Content.AFFIX_NAMES[bit] + " "
			_text(sp4, names.strip_edges(), Color("8ab4ff"), 12, 4)
			_bar(sp4 + Vector2(0, 6), 40.0, w.sw.hp[i] / w.sw.mhp[i], Color("ffd84a"))
	# damage numbers
	for e in w.texts:
		var life := 1.0 if e.tier == 3 else 0.65
		var k: float = e.t / life
		var col: Color = e.col
		var size := 17
		var txt := ""
		match int(e.tier):
			0: txt = str(int(round(e.v)))
			1: txt = str(int(round(e.v))); size = 26; col = Color("ffd24a")
			2: txt = str(int(round(e.v))); size = 19
			3: txt = e.label.to_upper(); size = 19
			4: txt = str(int(round(e.v))); size = 14
		if txt == "0" or txt == "": continue
		col.a = 1.0 - maxf(0.0, k - 0.55) * 2.2
		var sp5 := view.to_screen(e.pos, 30.0) + Vector2(0, -46.0 * k - (16.0 if e.tier == 3 else 0.0))
		var pop := 1.0 + (0.45 * (1.0 - minf(1.0, k * 7.0)) if e.tier == 1 else 0.15 * (1.0 - minf(1.0, k * 8.0)))
		_text(sp5, txt, col, int(size * pop), 6 if e.tier == 1 else 5, f_name if e.tier == 3 else font)

func _bar(p: Vector2, wdt: float, frac: float, col: Color) -> void:
	var r := Rect2(p - Vector2(wdt * 0.5, 0), Vector2(wdt, 5))
	draw_rect(r, Color(0, 0, 0, 0.7))
	draw_rect(Rect2(r.position, Vector2(wdt * clampf(frac, 0, 1), 5)), col)
