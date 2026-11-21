class_name TouchControls
extends Control
## Floating virtual joystick + action buttons.
##  - The stick appears wherever the thumb lands on the movement half (left by default, right when
##    left-handed). Fixed mode anchors it bottom-corner instead.
##  - Response curve: 12% radial dead zone, then a 1.6 power curve, so small thumb motions give
##    precise slow movement and the outer ring is full speed.
##  - Buttons: Roll (big), Ultimate (with charge ring), two flasks (with charge fill). Each tracks
##    its own touch index, so you can move, roll and drink at the same time (multi-touch).

signal roll
signal jump
signal ult
signal flask(i: int)

const R0 := 64.0                    # stick radius at the 720 px reference height; scaled like the buttons
const DEAD := 0.12
var stick_id := -1
var origin := Vector2.ZERO
var knob := Vector2.ZERO
var value := Vector2.ZERO
var world: World
var _btn_touch := {}
var _seen_touch := DisplayServer.is_touchscreen_available() and UIKit.touch_mode != 0

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_PASS

func _left_handed() -> bool: return bool(Save.opt("left_handed"))
func _fixed() -> bool: return int(Save.opt("joy_mode")) == 1

## Layout, cached: rebuilt only when the size, the handedness option or the safe area changes (it used
## to allocate four Dictionaries on every touch event and every redraw). Everything sits inside the
## display's safe area (camera cutouts, rounded corners).
var _layout: Array[Dictionary] = []
var _home := Vector2.ZERO
var R := R0
var _lay_size := Vector2(-1, -1)
var _lay_lh := false

func _relayout() -> void:
	var s := size
	_lay_size = s
	_lay_lh = _left_handed()
	var m := UIKit.safe_margins(s)
	var sc := clampf(minf(s.x, s.y) / 720.0, 0.75, 1.4)
	R = R0 * sc
	var side := -1.0 if _lay_lh else 1.0
	var base_x := (s.x - 110.0 * sc - m.z) if side > 0.0 else (110.0 * sc + m.x)
	var y := s.y - 120.0 * sc - m.w
	_layout = [
		{"id": "roll", "pos": Vector2(base_x, y), "r": 52.0 * sc, "label": "ROLL"},
		{"id": "ult", "pos": Vector2(base_x - side * 128.0 * sc, y + 22.0 * sc), "r": 42.0 * sc, "label": "ULT"},
		{"id": "f0", "pos": Vector2(base_x - side * 18.0 * sc, y - 118.0 * sc), "r": 32.0 * sc, "label": "1"},
		{"id": "f1", "pos": Vector2(base_x - side * 100.0 * sc, y - 82.0 * sc), "r": 32.0 * sc, "label": "2"},
		{"id": "jump", "pos": Vector2(base_x - side * 196.0 * sc, y - 46.0 * sc), "r": 36.0 * sc, "label": "JUMP"},
	]
	_home = Vector2(s.x - 150.0 * sc - m.z, s.y - 150.0 * sc - m.w) if _lay_lh else Vector2(150.0 * sc + m.x, s.y - 150.0 * sc - m.w)

func _buttons() -> Array[Dictionary]:
	if _layout.is_empty(): _relayout()
	return _layout

func _stick_home() -> Vector2:
	if _layout.is_empty(): _relayout()
	return _home

func _in_move_half(p: Vector2) -> bool:
	return (p.x > size.x * 0.5) if _left_handed() else (p.x < size.x * 0.5)

func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventScreenTouch:
		var t := ev as InputEventScreenTouch
		if not _seen_touch and ev.device != InputEvent.DEVICE_ID_EMULATION:   # a real finger, not mouse emulation
			_seen_touch = true
		if t.pressed:
			for b in _buttons():
				if t.position.distance_to(b.pos) < b.r * 1.25:
					_btn_touch[t.index] = b.id
					_press(b.id)
					accept_event()
					return
			if stick_id < 0 and _in_move_half(t.position):
				stick_id = t.index
				origin = _stick_home() if _fixed() else t.position
				knob = origin
				_update(t.position)
				accept_event()
		else:
			_btn_touch.erase(t.index)
			if t.index == stick_id:
				stick_id = -1
				value = Vector2.ZERO
		queue_redraw()
	elif ev is InputEventScreenDrag:
		var d := ev as InputEventScreenDrag
		if d.index == stick_id:
			_update(d.position)
			accept_event()
			queue_redraw()

func _update(p: Vector2) -> void:
	var v := (p - origin) / R
	var m := v.length()
	if m > 1.0:
		if not _fixed():                       # the floating base follows a thumb that overshoots
			origin += (p - origin).normalized() * (m - 1.0) * R
		v /= m
		m = 1.0
	knob = origin + v * R
	if m < DEAD:
		value = Vector2.ZERO
	else:
		value = v.normalized() * pow((m - DEAD) / (1.0 - DEAD), 1.6)

func _press(id: String) -> void:
	match id:
		"roll": roll.emit()
		"jump": jump.emit()
		"ult": ult.emit()
		"f0": flask.emit(0)
		"f1": flask.emit(1)
	if Save.opt("haptics"):
		Input.vibrate_handheld(15)

## Redraw only when something drawn has changed: touches redraw from _gui_input; here, layout changes,
## charge levels (quantised to what a redraw can show) and the touch mode. The roll cooldown sweep and
## the "ultimate ready" pulse animate at 20 Hz. No per-frame allocations.
const ANIM_HZ := 20.0
var _anim_t := 0.0
var _q_ult := -1
var _q_f0 := -1
var _q_f1 := -1
var _q_mode := -1
var _was_cd := false
func _process(dt: float) -> void:
	var redraw := false
	if size != _lay_size or _left_handed() != _lay_lh:
		_relayout()
		redraw = true
	var mode := (UIKit.touch_mode + 1) * 2 + (1 if _seen_touch else 0)
	if mode != _q_mode:
		_q_mode = mode
		redraw = true
	if world != null:
		var u := int(world.ult)
		var f0 := int(world.flasks[0].c / maxf(1.0, world.flasks[0].max) * 32.0)
		var f1 := int(world.flasks[1].c / maxf(1.0, world.flasks[1].max) * 32.0)
		if u != _q_ult or f0 != _q_f0 or f1 != _q_f1:
			_q_ult = u; _q_f0 = f0; _q_f1 = f1
			redraw = true
		var cd := world.roll_cd > 0.0 or world.jump_cd > 0.0
		if cd != _was_cd:
			_was_cd = cd
			redraw = true
		if cd or world.ult >= 100.0:
			_anim_t -= dt
			if _anim_t <= 0.0:
				_anim_t = 1.0 / ANIM_HZ
				redraw = true
	if redraw: queue_redraw()

## Unit circle for the flask liquid polygon, built once.
static var _unit: PackedVector2Array

const BRONZE := Color("b98a4a")
const BRONZE_D := Color("5a3c1e")

## A forged ring: dark rim, bronze band, thin highlight, so it reads on any floor.
func _ring(p: Vector2, r: float, a: float, w: float = 3.0) -> void:
	draw_arc(p, r + 1.5, 0, TAU, 48, Color(0, 0, 0, 0.55 * a), w + 3.0, true)
	draw_arc(p, r, 0, TAU, 48, Color(BRONZE.r, BRONZE.g, BRONZE.b, a), w, true)
	draw_arc(p, r - w * 0.5, PI * 1.05, PI * 1.7, 16, Color(1, 0.92, 0.75, 0.45 * a), 1.2, true)

func _draw() -> void:
	# desktop/gamepad players never see on-screen buttons (cycle 2: they cluttered the play area)
	if UIKit.touch_mode == 0 or (not _seen_touch and not bool(Save.opt("force_touch_ui"))):
		return
	if stick_id >= 0:
		draw_circle(origin, R, Color(0.03, 0.025, 0.03, 0.35))
		_ring(origin, R, 0.75)
		for k in 4:                                   # compass notches
			var a := k * PI / 2.0
			draw_line(origin + Vector2(cos(a), sin(a)) * (R - 8.0), origin + Vector2(cos(a), sin(a)) * (R + 6.0), Color(BRONZE.r, BRONZE.g, BRONZE.b, 0.7), 2.0)
		var ks := R / R0                              # the knob scales with the stick
		draw_circle(knob, 27.0 * ks, Color(0.05, 0.04, 0.05, 0.75))
		draw_circle(knob, 21.0 * ks, Color(BRONZE_D.r, BRONZE_D.g, BRONZE_D.b, 0.8))
		_ring(knob, 26.0 * ks, 0.95, 2.5)
		draw_circle(knob + Vector2(-6, -7) * ks, 6.0 * ks, Color(1, 0.9, 0.7, 0.18))
	elif _fixed():
		_ring(_stick_home(), R, 0.35)
	var font := UIKit.font("display")
	for b in _buttons():
		var bp: Vector2 = b.pos
		var br: float = b.r
		var held := _btn_touch.values().has(b.id)
		var col := Color("f4c04e")
		var k := -1.0
		if world != null:
			match b.id:
				"ult": k = world.ult / 100.0
				"f0": k = world.flasks[0].c / world.flasks[0].max; col = Color("e0434f")
				"f1": k = world.flasks[1].c / world.flasks[1].max; col = Color("5ab4ff")
				"roll": k = clampf(1.0 - world.roll_cd / 1.4, 0, 1); col = Color("c9f3ff")
				"jump": k = clampf(1.0 - world.jump_cd / World.JUMP_CD, 0, 1); col = Color("ffd9a0")
		draw_circle(bp, br, Color(0.04, 0.035, 0.045, 0.62 if held else 0.48))
		if b.id.begins_with("f") and k >= 0.0:        # flask liquid level
			var lvl := clampf(k, 0.0, 1.0)
			var top := bp.y + br - 2.0 * br * lvl
			if _unit.is_empty():
				for j in 33: _unit.append(Vector2(cos(TAU * float(j) / 32.0), sin(TAU * float(j) / 32.0)))
			var pts := PackedVector2Array()
			pts.resize(33)
			for j in 33:
				var q := bp + _unit[j] * (br - 4.0)
				q.y = maxf(q.y, top)
				pts[j] = q
			draw_colored_polygon(pts, Color(col.r, col.g, col.b, 0.42))
		if held: draw_circle(bp, br - 3.0, Color(col.r, col.g, col.b, 0.16))
		_ring(bp, br, 0.85 if held else 0.65, 3.0)
		if k >= 0.0 and not b.id.begins_with("f"):
			var ready := k >= 1.0
			draw_arc(bp, br - 6.0, -PI / 2, -PI / 2 + TAU * k, 40, col if ready or b.id != "ult" else col.darkened(0.45), 5.0, true)
			if ready and b.id == "ult":
				var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.006)
				draw_arc(bp, br + 5.0, 0, TAU, 48, Color(col.r, col.g, col.b, 0.35 + 0.35 * pulse), 3.0, true)
		var fs := int(br * 0.4)
		var tw := font.get_string_size(b.label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var tp := bp + Vector2(-tw * 0.5, fs * 0.36)
		draw_string_outline(font, tp, b.label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 4, Color(0, 0, 0, 0.8))
		draw_string(font, tp, b.label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color("efe2c4"))
