class_name IntroScreen
extends Control
## The cold open on first launch (Options > Replay intro shows it again): the narrator's four intro beats from
## the voice manifest, each on screen while its line plays and GAP_S after it (the real clip's length once the
## voice pack is in, the manifest's estimate until then). A tap moves to the next beat at once, cutting the
## narrator off; Skip ends the intro. finished fires once, after the last beat or Skip.

signal finished

const GAP_S := 0.6
const FADE_S := 0.5
var bank: VoiceBank
var manual_clock := false
var beat := -1
var done := false
var _beats := 0
var _hold := 0.0
var _t := 0.0
var _text: Label
var _dots: Label

func _ready() -> void:
	if bank == null: bank = VoiceBank.current
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var vs := get_viewport_rect().size
	var m := UIKit.safe_margins(vs)
	var bg := ColorRect.new()
	bg.color = Color(0.016, 0.012, 0.022)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var box := UIKit.vbox(22)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(box)
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = m.x + 48.0
	box.offset_right = -(m.z + 48.0)
	box.offset_top = m.y + 56.0
	box.offset_bottom = -(m.w + 56.0)
	_text = UIKit.label("", 34 if vs.x >= 820.0 else 27, UIKit.TEXT, true, "display")
	_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_text.custom_minimum_size = Vector2(minf(vs.x - m.x - m.z - 96.0, 980.0), 0)
	_text.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(_text)
	_dots = UIKit.label("", 18, UIKit.GOLD, false, "display")
	_dots.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_dots)
	var hint := UIKit.label("Tap to continue", 16, UIKit.DIM, false, "italic")
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(hint)
	var sk := UIKit.button("Skip", skip, 48)
	sk.custom_minimum_size = Vector2(120, 48)
	add_child(sk)
	sk.position = Vector2(vs.x - m.z - 24.0 - 120.0, m.y + 20.0)
	_beats = bank.variants("narrator", "intro") if bank != null else 0
	if _beats == 0:
		_finish.call_deferred()
		return
	_play(0)

func _process(dt: float) -> void:
	if not manual_clock: step(dt)

func step(dt: float) -> void:
	if done: return
	_t += dt
	_text.modulate.a = minf(1.0, _t / FADE_S)
	if _t >= _hold: _next()

func tap() -> void:
	_next()

func skip() -> void:
	if done: return
	if bank != null: bank.stop(0.06)
	_finish()

func shown_text() -> String:
	return _text.text if _text != null else ""

func _gui_input(e: InputEvent) -> void:
	# touches arrive as emulated mouse clicks too: one handler, or a tap would skip two beats
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		tap()
		accept_event()

func _unhandled_key_input(e: InputEvent) -> void:
	if not e.is_pressed() or done: return
	if e.is_action("ui_cancel"): skip()
	elif e.is_action("ui_accept"): tap()

func _play(k: int) -> void:
	beat = k
	var ln: Dictionary = bank.line("narrator", "intro", k)
	_text.text = String(ln.get("text", ""))
	_text.modulate.a = 0.0
	var r := bank.say("narrator", "intro", k, {"subtitle": false})
	_hold = (float(r.duration) if bool(r.played) else float(ln.get("duration_fallback_s", 4.0))) + GAP_S
	_t = 0.0
	var d := ""
	for i in _beats: d += ("◆" if i == k else "◇") + ("   " if i < _beats - 1 else "")
	_dots.text = d

func _next() -> void:
	if done: return
	if beat + 1 < _beats:
		bank.stop(0.06)
		_play(beat + 1)
	else:
		_finish()

func _finish() -> void:
	if done: return
	done = true
	if bank != null and bank.active_speaker() == "narrator": bank.stop(0.12)
	Save.data.intro_seen = true
	Save.mark_dirty()
	finished.emit()
