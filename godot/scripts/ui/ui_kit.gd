class_name UIKit
extends RefCounted
## Theme + tiny builder helpers so every screen is built in code with consistent styling and
## thumb-sized hit targets (min 56px tall buttons on touch).

const BG := Color("0d1019")
const PANEL := Color("161b2a")
const PANEL2 := Color("1e2538")
const EDGE := Color("39415e")
const TEXT := Color("ece8dd")
const DIM := Color("9aa0b4")
const GOLD := Color("f4c04e")

static func theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 20
	var b := _box(PANEL2, EDGE, 10)
	var bh := _box(Color("273050"), GOLD.darkened(0.2), 10)
	var bp := _box(Color("101420"), GOLD, 10)
	var bd := _box(Color("141824"), Color("262b3a"), 10)
	for s in ["normal", "focus"]: t.set_stylebox(s, "Button", b)
	t.set_stylebox("hover", "Button", bh)
	t.set_stylebox("pressed", "Button", bp)
	t.set_stylebox("disabled", "Button", bd)
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_disabled_color", "Button", Color("5a6070"))
	t.set_color("font_hover_color", "Button", Color.WHITE)
	t.set_stylebox("panel", "PanelContainer", _box(PANEL, EDGE, 14))
	t.set_stylebox("panel", "Panel", _box(PANEL, EDGE, 14))
	t.set_color("font_color", "Label", TEXT)
	t.set_constant("separation", "VBoxContainer", 10)
	t.set_constant("separation", "HBoxContainer", 10)
	t.set_stylebox("normal", "LineEdit", _box(PANEL2, EDGE, 8))
	t.set_stylebox("panel", "TabContainer", _box(PANEL, EDGE, 14))
	t.set_stylebox("tab_selected", "TabContainer", _box(Color("273050"), GOLD, 8))
	t.set_stylebox("tab_unselected", "TabContainer", _box(PANEL2, EDGE, 8))
	t.set_stylebox("tab_hovered", "TabContainer", _box(Color("273050"), EDGE, 8))
	t.set_stylebox("background", "ProgressBar", _box(Color(0, 0, 0, 0.55), Color(0, 0, 0, 0.8), 6))
	t.set_stylebox("fill", "ProgressBar", _box(Color("e0505a"), Color(0, 0, 0, 0), 6))
	t.set_stylebox("slider", "HSlider", _box(PANEL2, EDGE, 6))
	return t

static func _box(bg: Color, edge: Color, r: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = edge
	s.set_border_width_all(2)
	s.set_corner_radius_all(r)
	s.content_margin_left = 14; s.content_margin_right = 14
	s.content_margin_top = 10; s.content_margin_bottom = 10
	s.anti_aliasing = true
	return s

static func label(txt: String, size: int = 20, col: Color = TEXT, wrap: bool = false) -> Label:
	var l := Label.new()
	l.text = txt
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l

static func button(txt: String, cb: Callable, min_h: int = 56) -> Button:
	var b := Button.new()
	b.text = txt
	b.custom_minimum_size = Vector2(0, min_h)
	b.pressed.connect(func(): Sfx.play("click"); cb.call())
	return b

static func vbox(sep: int = 10) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	return v

static func hbox(sep: int = 10) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	return h

static func panel(child: Control) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_child(child)
	return p

static func bar(col: Color, h: int = 16) -> ProgressBar:
	var b := ProgressBar.new()
	b.show_percentage = false
	b.custom_minimum_size = Vector2(0, h)
	b.max_value = 1.0
	b.step = 0.0
	var f := _box(col, Color(0, 0, 0, 0), 6)
	f.content_margin_top = 0; f.content_margin_bottom = 0
	b.add_theme_stylebox_override("fill", f)
	return b

## Full-screen dimmed overlay hosting a centred scrollable sheet.
static func sheet(parent: Control, max_w: int = 980) -> VBoxContainer:
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.06, 0.82)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	parent.add_child(dim)
	var m := MarginContainer.new()
	m.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, 16)
	parent.add_child(m)
	var cc := CenterContainer.new()
	m.add_child(cc)
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.custom_minimum_size = Vector2(mini(max_w, int(parent.get_viewport_rect().size.x) - 32), mini(1400, int(parent.get_viewport_rect().size.y) - 32))
	cc.add_child(sc)
	var v := vbox(12)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(v)
	return v

static func clear(n: Node) -> void:
	for c in n.get_children():
		c.queue_free()
