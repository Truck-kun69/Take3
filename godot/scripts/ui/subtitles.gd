class_name Subtitles
extends Control
## The subtitle banner: each voice line's speaker and text (VoiceBank.line_started), above the action bar while
## a run is being played and along the top otherwise (menus, and the level-up, pause and end screens, whose
## cards and buttons fill the middle and bottom), held for VoiceBank.subtitle_seconds(duration) = max(2.0, duration + 0.35)
## s, so a clip is never cut off mid-sentence on screen. A line said with "subtitle": false (the intro's own
## narration) or a line that is stopped clears it.

const FADE_S := 0.2
var manual_clock := false
var in_run := false:                 # main sets it every frame: true only while a run is being played
	set(v):
		if v == in_run: return
		in_run = v
		if _panel != null: _layout()
var _bank: VoiceBank
var _left := 0.0
var _alpha := 0.0
var _panel: PanelContainer
var _text: RichTextLabel
var _shown := ""

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.02, 0.016, 0.022, 0.74)
	sb.border_color = Color(UIKit.GOLD, 0.3)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 18.0
	sb.content_margin_right = 18.0
	sb.content_margin_top = 9.0
	sb.content_margin_bottom = 10.0
	_panel.add_theme_stylebox_override("panel", sb)
	_text = RichTextLabel.new()
	_text.bbcode_enabled = true
	_text.fit_content = true
	_text.scroll_active = false
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text.add_theme_font_override("normal_font", UIKit.font("body"))
	_text.add_theme_font_override("bold_font", UIKit.font("label"))
	_text.add_theme_font_size_override("normal_font_size", 22)
	_text.add_theme_font_size_override("bold_font_size", 19)
	_text.add_theme_color_override("default_color", UIKit.TEXT)
	_text.add_theme_constant_override("outline_size", 4)
	_text.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_panel.add_child(_text)
	add_child(_panel)
	_panel.modulate.a = 0.0
	_panel.visible = false
	_layout()
	get_viewport().size_changed.connect(_layout)
	if _bank == null and VoiceBank.current != null: bind(VoiceBank.current)

func bind(b: VoiceBank) -> void:
	if _bank != null and is_instance_valid(_bank):
		if _bank.line_started.is_connected(_on_line): _bank.line_started.disconnect(_on_line)
		if _bank.line_ended.is_connected(_on_end): _bank.line_ended.disconnect(_on_end)
	_bank = b
	if b != null:
		b.line_started.connect(_on_line)
		b.line_ended.connect(_on_end)

func _on_line(info: Dictionary) -> void:
	if not bool(info.get("subtitle", true)):
		_left = 0.0
		return
	var col: Color = info.get("color", UIKit.GOLD)
	_shown = String(info.get("text", ""))
	_text.text = "[b][color=#%s]%s[/color][/b]   %s" % [col.to_html(false), String(info.get("name", "")).to_upper(), _shown.replace("[", "[lb]")]
	_left = float(info.get("subtitle_s", VoiceBank.subtitle_seconds(float(info.get("duration", 0.0)))))
	_layout()

## Written lines with no voice clip (a Rift Echo's hero/narrator exchange): each [name, colour, text, seconds],
## shown one after another in this banner, never blocking play. A voice line arriving cuts in as usual; the
## exchange carries on after it.
var _queue: Array = []
func exchange(lines: Array) -> void:
	_queue.append_array(lines)
	if _left <= 0.0: _next_written()

func _next_written() -> void:
	if _queue.is_empty(): return
	var ln: Array = _queue.pop_front()
	var col: Color = ln[1]
	_shown = String(ln[2])
	_text.text = "[b][color=#%s]%s[/color][/b]   %s" % [col.to_html(false), String(ln[0]).to_upper(), _shown.replace("[", "[lb]")]
	_left = float(ln[3])
	_layout()

func _on_end(info: Dictionary) -> void:
	if bool(info.get("stopped", false)): _left = 0.0     # cut off or stopped: the line that cut in shows its own

func _process(dt: float) -> void:
	if not manual_clock: step(dt)

func step(dt: float) -> void:
	var was := _left
	_left = maxf(0.0, _left - dt)
	if was > 0.0 and _left <= 0.0 and not _queue.is_empty(): _next_written()
	_alpha = move_toward(_alpha, 1.0 if _left > 0.0 else 0.0, dt / FADE_S)
	if _panel != null:
		_panel.modulate.a = _alpha
		_panel.visible = _alpha > 0.001

func is_showing() -> bool:
	return _left > 0.0

func shown_text() -> String:
	return _shown if _left > 0.0 else ""

## Centred, at most 920 px wide; in a run its bottom edge sits above the globes and the action bar (higher in
## portrait, over the touch buttons), in the menus it hangs from the top of the safe area.
func _layout() -> void:
	if _panel == null: return
	var vs := get_viewport_rect().size
	var m := UIKit.safe_margins(vs)
	var w := minf(vs.x - m.x - m.z - 48.0, 920.0)
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.offset_left = -w * 0.5
	_panel.offset_right = w * 0.5
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	if in_run:
		var lift := m.w + (196.0 if vs.x >= 820.0 else 330.0)
		_panel.anchor_top = 1.0
		_panel.anchor_bottom = 1.0
		_panel.offset_top = -lift
		_panel.offset_bottom = -lift
		_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	else:
		_panel.anchor_top = 0.0
		_panel.anchor_bottom = 0.0
		_panel.offset_top = m.y + 22.0
		_panel.offset_bottom = m.y + 22.0
		_panel.grow_vertical = Control.GROW_DIRECTION_END
