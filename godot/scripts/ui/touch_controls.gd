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
signal ult
signal flask(i: int)

const R := 64.0
const DEAD := 0.12
var stick_id := -1
var origin := Vector2.ZERO
var knob := Vector2.ZERO
var value := Vector2.ZERO
var world: World
var _btn_touch := {}

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_PASS

func _left_handed() -> bool: return bool(Save.opt("left_handed"))
func _fixed() -> bool: return int(Save.opt("joy_mode")) == 1

func _buttons() -> Array:
	var s := size
	var sc := clampf(minf(s.x, s.y) / 720.0, 0.75, 1.4)
	var side := -1.0 if _left_handed() else 1.0
	var base_x := s.x - 110.0 * sc if side > 0.0 else 110.0 * sc
	var y := s.y - 120.0 * sc
	return [
		{"id": "roll", "pos": Vector2(base_x, y), "r": 52.0 * sc, "label": "ROLL"},
		{"id": "ult", "pos": Vector2(base_x - side * 128.0 * sc, y + 22.0 * sc), "r": 42.0 * sc, "label": "ULT"},
		{"id": "f0", "pos": Vector2(base_x - side * 18.0 * sc, y - 118.0 * sc), "r": 32.0 * sc, "label": "1"},
		{"id": "f1", "pos": Vector2(base_x - side * 100.0 * sc, y - 82.0 * sc), "r": 32.0 * sc, "label": "2"},
	]

func _stick_home() -> Vector2:
	var s := size
	var sc := clampf(minf(s.x, s.y) / 720.0, 0.75, 1.4)
	return Vector2(s.x - 150.0 * sc, s.y - 150.0 * sc) if _left_handed() else Vector2(150.0 * sc, s.y - 150.0 * sc)

func _in_move_half(p: Vector2) -> bool:
	return (p.x > size.x * 0.5) if _left_handed() else (p.x < size.x * 0.5)

func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventScreenTouch:
		var t := ev as InputEventScreenTouch
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
		"ult": ult.emit()
		"f0": flask.emit(0)
		"f1": flask.emit(1)
	if Save.opt("haptics"):
		Input.vibrate_handheld(15)

func _process(_dt: float) -> void:
	queue_redraw()

func _draw() -> void:
	if stick_id >= 0:
		draw_circle(origin, R, Color(1, 1, 1, 0.08))
		draw_arc(origin, R, 0, TAU, 48, Color(1, 1, 1, 0.35), 3.0)
		draw_circle(knob, 26.0, Color(1, 1, 1, 0.35))
	elif _fixed():
		var h := _stick_home()
		draw_arc(h, R, 0, TAU, 48, Color(1, 1, 1, 0.2), 3.0)
	var font := ThemeDB.fallback_font
	for b in _buttons():
		var held := _btn_touch.values().has(b.id)
		var fill := Color(1, 1, 1, 0.2 if held else 0.1)
		draw_circle(b.pos, b.r, fill)
		draw_arc(b.pos, b.r, 0, TAU, 40, Color(1, 1, 1, 0.4), 2.5)
		if world != null:
			var k := -1.0
			var col := Color("f4c04e")
			match b.id:
				"ult": k = world.ult / 100.0
				"f0": k = world.flasks[0].c / world.flasks[0].max; col = Color("ff5a6a")
				"f1": k = world.flasks[1].c / world.flasks[1].max; col = Color("8adfff")
				"roll": k = clampf(1.0 - world.roll_cd / 1.4, 0, 1); col = Color("c9f3ff")
			if k >= 0.0:
				draw_arc(b.pos, b.r - 5.0, -PI / 2, -PI / 2 + TAU * k, 40, col if k >= 1.0 or b.id != "ult" else col.darkened(0.4), 6.0)
		var fs := int(b.r * 0.42)
		var tw := font.get_string_size(b.label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(font, b.pos + Vector2(-tw * 0.5, fs * 0.35), b.label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.85))
