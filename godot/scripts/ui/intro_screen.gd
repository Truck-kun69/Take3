class_name IntroScreen
extends Control
## The cold open, on first launch and from Main Menu > Replay Intro: the narrator's four intro beats from the
## voice manifest (VoiceBank.play("narrator", "intro", i)), each on screen while its line plays and GAP_S after
## it (the real clip's length once the voice pack is in, the manifest's estimate until then). With a ColdOpen
## (main gives it one on the 3D renderer) the words sit over Act I, its camera sweeping down across the four
## beats while the Rift Shard strikes, and after the last beat the camera glides on as the screen fades to
## black for GLIDE_S before the title stage takes over. Without one (classic 2D, the tests) they sit over black.
## A tap (or Next) moves to the next beat at once; Skip ends the intro. Both stop the narrator
## (VoiceBank.stop_all) and mark the intro seen. finished fires once, after the glide or Skip.

signal finished

const GAP_S := 0.5
const FADE_S := 0.5
const GLIDE_S := 1.4
var bank: VoiceBank
var cold: ColdOpen
var manual_clock := false
var beat := -1
var done := false
var gliding := false
var _beats := 0
var _hold := 0.0
var _t := 0.0
var _starts: Array[float] = []       # each beat's planned start (s) on the cold open's timeline
var _total := 0.0
var _u := 0.0                        # the camera's progress, eased toward the beat's own (a tap glides, not cuts)
var _glide := 0.0
var _text: Label
var _dots: Label
var _black: ColorRect

func _ready() -> void:
	if bank == null: bank = VoiceBank.current
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var vs := get_viewport_rect().size
	var m := UIKit.safe_margins(vs)
	if cold == null:
		var bg := ColorRect.new()
		bg.color = Color(0.016, 0.012, 0.022)
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(bg)
		bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	else:
		# over the 3D: a scrim under the words only, the Hollow clear above them
		var gr := Gradient.new()
		gr.set_color(0, Color(0, 0, 0, 0.0))
		gr.set_color(1, Color(0.01, 0.008, 0.014, 0.82))
		gr.add_point(0.5, Color(0, 0, 0, 0.0))
		var gt := GradientTexture2D.new()
		gt.gradient = gr
		gt.fill_from = Vector2(0, 0)
		gt.fill_to = Vector2(0, 1)
		var scrim := TextureRect.new()
		scrim.texture = gt
		scrim.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		scrim.stretch_mode = TextureRect.STRETCH_SCALE
		scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(scrim)
		scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var box := UIKit.vbox(18)
	box.alignment = BoxContainer.ALIGNMENT_END if cold != null else BoxContainer.ALIGNMENT_CENTER
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(box)
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = m.x + 48.0
	box.offset_right = -(m.z + 48.0)
	box.offset_top = m.y + 56.0
	box.offset_bottom = -(m.w + (64.0 if cold != null else 56.0))
	_text = UIKit.label("", 34 if vs.x >= 820.0 else 27, UIKit.TEXT, true, "display")
	_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_text.custom_minimum_size = Vector2(minf(vs.x - m.x - m.z - 96.0, 980.0), 0)
	_text.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_text.add_theme_constant_override("outline_size", 8)
	_text.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
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
	_black = ColorRect.new()
	_black.color = Color(0, 0, 0, 0)
	_black.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_black)
	_black.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_beats = bank.variants("narrator", "intro") if bank != null else 0
	if _beats == 0:
		_finish.call_deferred()
		return
	for i in _beats:                                  # the timeline the camera is laid over
		_starts.append(_total)
		_total += bank.duration_of("narrator", "intro", i) + GAP_S
	_play(0)

func _process(dt: float) -> void:
	if not manual_clock: step(dt)

func step(dt: float) -> void:
	if done: return
	if gliding:
		_glide = minf(1.0, _glide + dt / GLIDE_S)
		_black.color.a = _glide * _glide
		_text.modulate.a = 1.0 - _glide
		if cold != null: cold.step(dt, 1.0, _glide)
		if _glide >= 1.0: _finish()
		return
	_t += dt
	_text.modulate.a = minf(1.0, _t / FADE_S)
	var target := clampf((_starts[beat] + minf(_t, _hold)) / maxf(0.001, _total), 0.0, 1.0) if beat >= 0 else 0.0
	_u = target if _u > target else move_toward(_u, target, dt * 0.35 + (target - _u) * minf(1.0, dt * 3.0))
	if cold != null: cold.step(dt, _u)
	if _t >= _hold: _next()

## Tap / Next: the narrator is cut off and the next beat starts at once (after the last: the glide).
func tap() -> void:
	if done: return
	_seen()
	if gliding: return
	_stop_voice()
	_next()

## Skip: the narrator stops and the intro ends here (no glide).
func skip() -> void:
	if done: return
	_seen()
	_stop_voice()
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
	if done or gliding: return
	if beat + 1 < _beats:
		_stop_voice()
		_play(beat + 1)
	elif cold != null:
		gliding = true
		_stop_voice()
	else:
		_finish()

## The bank this intro speaks through (VoiceBank.stop_all in the game: the autoload is that bank).
func _stop_voice() -> void:
	if bank == null: return
	if bank == VoiceBank.current: VoiceBank.stop_all()
	else: bank.stop()

func _seen() -> void:
	if not bool(Save.data.get("intro_seen", false)):
		Save.data.intro_seen = true
		Save.mark_dirty()

func _finish() -> void:
	if done: return
	done = true
	if bank != null and bank.active_speaker() == "narrator": _stop_voice()
	_seen()
	finished.emit()
