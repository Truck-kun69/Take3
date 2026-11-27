class_name Screens
extends Control
## Every full-screen page and overlay, built on demand into this control. `main` owns the flow
## and calls show_*(); buttons call back into main through the `act` signal.

signal act(what: String, arg: Variant)

var main: Node
var page := ""                 # what is showing: "menu", "pause", "" (closed) or "sub" (any other page); main.back() reads it
var _sel_item := -1           # index into the combined gear list in the stash screen
var _sel_node := -1
var _craft_msg := ""
var parent_page := ""          # "camp" while a Camp station (or a page opened from the Camp) is up: Back returns there
var _in_stash := false         # the Gear page is up (a redraw of it is not a new visit)
var _stash_new: Array = []     # the finds marked NEW on this visit to the Gear page
var _armed := ""               # Gear: the action waiting for its second tap ("salvage", "extract" or a shard's id) ...
var _armed_uid := -1           # ... on this item
var _body_sc: ScrollContainer  # the open sheet's scrolling body (a Gear redraw keeps its scroll)
var _prev_scroll := 0

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

var _choices: Array = []       # level-up choices, so number keys can pick them

func close() -> void:
	_choices = []
	page = ""
	parent_page = ""
	_in_stash = false
	UIKit.clear(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _open(max_w: int = 980) -> VBoxContainer:
	_choices = []
	page = "sub"
	_was_stash = _in_stash
	_in_stash = false
	var fresh := get_child_count() == 0          # opening over the game, not refreshing an open sheet
	_prev_scroll = _body_sc.scroll_vertical if is_instance_valid(_body_sc) else 0
	UIKit.clear(self)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var v := UIKit.sheet(self, max_w)
	_body_sc = v.get_parent() as ScrollContainer
	if fresh:                                    # fade in and settle up a few pixels (polish pass)
		modulate.a = 0.0
		var m: Control = get_child(get_child_count() - 1)
		m.position.y = 18.0
		var tw := create_tween().set_parallel(true)
		tw.tween_property(self, "modulate:a", 1.0, 0.16)
		tw.tween_property(m, "position:y", 0.0, 0.22).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	else:
		modulate.a = 1.0
	return v

func _title(v: VBoxContainer, t: String, sub: String = "") -> void:
	v.add_child(UIKit.title(t, 38))
	if sub != "":
		var l := UIKit.label(sub, 18, UIKit.DIM, true, "italic")
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(l)

func _back(v: VBoxContainer, what: String = "menu") -> void:
	if what == "menu" and parent_page == "camp": what = "camp"          # opened from the Camp: back to the Camp
	UIKit.foot(v).add_child(UIKit.button("Back", func(): act.emit(what, null)))

func _grid(cols: int, sep: int = 10) -> GridContainer:
	var g := GridContainer.new()
	g.columns = cols
	g.add_theme_constant_override("h_separation", sep)
	g.add_theme_constant_override("v_separation", sep)
	return g

func _unhandled_key_input(ev: InputEvent) -> void:
	if _choices.is_empty() or not (ev is InputEventKey) or not ev.pressed or ev.echo: return
	var k: int = ev.physical_keycode - KEY_1
	if k >= 0 and k < _choices.size():
		var c: Dictionary = _choices[k]
		_choices = []
		get_viewport().set_input_as_handled()
		act.emit("pick", c)

# ================================================================= main menu
## Title screen, phone first. The 3D stage (MenuStage3D) fills the screen with the chosen exile in the
## middle, under light scrims. Bottom right, under the right thumb: the act pill over one large tile that plays the
## chosen exile at that act (the highest one open, unless another is picked with the pill): PLAY before the first
## run, CONTINUE after. Left: the logo, a Gold and Echoes pill, then Replay Act I (once a run is played), Daily Rift
## (today's code and your best; locked until Act I is cleared), Heroes (the showcase), Codex & Story (the acts, the
## exiles' bios, the bestiary), Options and Replay Intro, and a compact bar for the rest (Camp, Upgrades, Modes).
## A new profile sees one gold action, PLAY. Narrow (portrait) windows stack it all in one column. Every button is
## at least UIKit.MIN_TOUCH tall.
const ROMAN := ["I", "II", "III", "IV", "V", "VI"]
var _act_sel := -1                   # act picked with the act pill this session; -1 (or a sealed one): the highest open

## Campaign acts that can be played (act i opens when act i - 1 is cleared).
func _open_acts(d: Dictionary) -> Array[int]:
	var out: Array[int] = []
	for i in Content.STAGES.size():
		if i == 0 or (i - 1 < d.cleared.size() and bool(d.cleared[i - 1])): out.append(i)
	return out

func _act_pick(d: Dictionary) -> int:
	var open := _open_acts(d)
	return _act_sel if open.has(_act_sel) else open[open.size() - 1]

func show_menu() -> void:
	_choices = []
	UIKit.clear(self)
	page = "menu"
	parent_page = ""
	_in_stash = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	var d: Dictionary = Save.data
	var vs := get_viewport_rect().size
	var m := UIKit.safe_margins(vs)
	var portrait := vs.x < 820.0
	var x0 := m.x + (12.0 if portrait else 32.0)
	var col_w := vs.x - x0 - m.z - 12.0 if portrait else clampf(vs.x * 0.31, 390.0, 470.0)
	var blk_w := clampf(vs.x * 0.29, 380.0, 440.0)
	var bx := vs.x - m.z - 32.0 - blk_w                   # the Continue block's left edge (landscape)
	if main != null and main.menu_stage != null:
		main.menu_stage.frame_x = 0.5 if portrait else ((x0 + col_w) + bx) * 0.5 / vs.x
		main.menu_stage.frame_y = 0.3 if portrait else 0.5          # portrait: the exile above the column
		main.menu_stage._frame()
	_scrims(vs, x0, col_w, bx, portrait)
	var v := _column(Vector2(x0, m.y), Vector2(col_w, vs.y - m.y - m.w))
	if portrait: v.alignment = BoxContainer.ALIGNMENT_END        # the logo and controls below the exile
	var logo := TextureRect.new()
	logo.texture = UIKit.tex("logo")
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var lw := minf(col_w - 14.0, 430.0 if not portrait else 380.0)
	logo.custom_minimum_size = Vector2(0, lw * float(logo.texture.get_height()) / float(logo.texture.get_width()))
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(logo)
	v.add_child(_purse(d))
	v.add_child(_spacer(6))
	if portrait:
		v.add_child(_play_block(d))
		v.add_child(_spacer(4))
	v.add_child(_menu_entries(d))
	v.add_child(_spacer(6))
	v.add_child(_menu_bar(d))
	# keyboard help only without a touchscreen (UIKit.is_touch: DisplayServer.is_touchscreen_available())
	if not UIKit.is_touch():
		var help := UIKit.label("WASD or drag to move  \u00b7  Space roll  \u00b7  F jump  \u00b7  R ultimate  \u00b7  1 2 flasks  \u00b7  Esc pause", 14, UIKit.DIM, true, "italic")
		help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(help)
	if not portrait:
		var blk := _play_block(d)
		add_child(blk)
		var bh := blk.get_combined_minimum_size().y
		blk.position = Vector2(bx, vs.y - m.w - 26.0 - bh)
		blk.size = Vector2(blk_w, bh)
		_hero_plate(Content.HEROES[int(d.hero)], x0 + col_w + 24.0, bx - 24.0, vs.y - m.w - 18.0)
	var ver := UIKit.label("v" + Diag.version(), 13, UIKit.DIM, false, "body")
	ver.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(ver)
	ver.position = Vector2(vs.x - m.z - 12.0 - ver.get_combined_minimum_size().x, m.y + 6.0)

## The title's scrims: behind the left column (and lightly behind the Continue block); clear over the exile.
func _scrims(vs: Vector2, x0: float, col_w: float, bx: float, portrait: bool) -> void:
	var ink := Color(0.02, 0.016, 0.022)
	var gr := Gradient.new()
	gr.set_color(0, Color(ink, 0.8)); gr.set_color(1, Color(ink, 0.5 if portrait else 0.3))
	if not portrait:
		gr.add_point(clampf((x0 + col_w + 20.0) / vs.x, 0.1, 0.9), Color(ink, 0.55))
		gr.add_point(clampf((x0 + col_w + 150.0) / vs.x, 0.1, 0.92), Color(ink, 0.0))
		gr.add_point(clampf((bx - 110.0) / vs.x, 0.15, 0.95), Color(ink, 0.0))
	add_child(_grad_rect(gr, false))
	var g2 := Gradient.new()
	g2.set_color(0, Color(0, 0, 0, 0.35)); g2.set_color(1, Color(0, 0, 0, 0.45))
	g2.add_point(0.14, Color(0, 0, 0, 0)); g2.add_point(0.8, Color(0, 0, 0, 0))
	add_child(_grad_rect(g2, true))

## Replay Act I (once a run is played: it starts Act I, as New Campaign did, which a new profile read as a second way
## to begin), Daily Rift (a random act and exile with two modifiers and no coach, not Act I on 80% of days: locked,
## like the Atlas, until Act I is cleared), Heroes, Codex & Story, Options and Replay Intro: two to a row.
func _menu_entries(d: Dictionary) -> GridContainer:
	var g := _grid(2, 8)
	var td := Daily.today()
	var best := int((d.daily.best as Dictionary).get(td.code, -1))
	var h: Dictionary = Content.HEROES[int(d.hero)]
	var daily_open := daily_unlocked(d)
	var entries := []
	if int(d.stats.get("runs", 0)) > 0:
		entries.append(["Replay Act I", String(Story.act(0).title), func(): act.emit("new_campaign", null), Content.col(Content.STAGES[0].acc)])
	entries.append(["Daily Rift", ("Clear Act I to unlock" if not daily_open else (("%s \u00b7 best %d" % [td.code, best]) if best >= 0 else "Today: %s" % td.code)),
		func(): act.emit("daily", "menu"), Color("7fd8ff")])
	entries.append_array([
		["Heroes", "%s \u00b7 %s" % [h.name, Story.hero(String(h.id)).mechanic], func(): act.emit("heroes", null), Content.col(h.col)],
		["Codex & Story", "Acts, exiles, bestiary", func(): act.emit("codex", "menu"), Color("e8dcc0")],
		["Options", "Audio, graphics, controls", func(): act.emit("options", null), Color("b8ad98")],
		["Replay Intro", "How it began", func(): act.emit("intro", null), Color("c48aff")]])
	for e in entries:
		var t := UIKit.tile(e[0], e[1], e[2], e[3], false, 62)
		if t.has_meta("title_label"): (t.get_meta("title_label") as Label).add_theme_font_size_override("font_size", 20 if String(e[0]).length() <= 12 else 18)
		if e[0] == "Daily Rift": _lock(t, not daily_open)
		g.add_child(t)
	return g

## The Daily Rift opens once Act I is cleared (the title's tile, Modes' tile).
static func daily_unlocked(d: Dictionary) -> bool:
	return (d.cleared as Array).size() > 0 and bool(d.cleared[0])

## The act pill (previous, the act, next; tapping the act steps through the open ones) over PLAY.
func _play_block(d: Dictionary) -> VBoxContainer:
	var b := UIKit.vbox(10)
	var acts := _open_acts(d)
	var cur := _act_pick(d)
	var k := acts.find(cur)
	var s: Dictionary = Content.STAGES[cur]
	var ar := UIKit.hbox(6)
	var prev := _step_btn("\u2039", func(): _act_sel = acts[maxi(0, k - 1)]; show_menu(), 64)
	prev.disabled = k <= 0
	var cleared: bool = cur < d.cleared.size() and bool(d.cleared[cur])
	var at := UIKit.tile(String(s.name), "Act %s of %s%s" % [ROMAN[cur], ROMAN[Content.STAGES.size() - 1], "  \u00b7  cleared" if cleared else ""],
		func(): _act_sel = acts[(k + 1) % acts.size()]; show_menu(), Content.col(s.acc), false, 64)
	at.tooltip_text = String(s.blurb)
	var nxt := _step_btn("\u203a", func(): _act_sel = acts[mini(acts.size() - 1, k + 1)]; show_menu(), 64)
	nxt.disabled = k >= acts.size() - 1
	for c in [prev, at, nxt]: ar.add_child(c)
	b.add_child(ar)
	var tm := int(d.get("torment", 0))
	var fresh := int(d.stats.get("runs", 0)) <= 0            # nothing to continue yet: PLAY
	var sub := ("Begin the campaign" if fresh else "Continue Campaign") + "  \u00b7  %s  \u00b7  Act %s%s" % [Content.HEROES[int(d.hero)].name, ROMAN[cur], ("  \u00b7  " + String(Content.TORMENT[tm].name)) if tm > 0 else ""]
	var play := UIKit.tile("PLAY" if fresh else "CONTINUE", sub, func(): act.emit("campaign", cur), UIKit.GOLD, true, 104)
	var pt: Label = play.get_meta("title_label")
	pt.add_theme_font_override("font", UIKit.font("display_heavy"))
	pt.add_theme_font_size_override("font_size", 42)
	b.add_child(play)
	return b

## The Camp (its NPCs, and Gear), Upgrades (Shard Web and powers) and Modes (the endgame) in one compact row.
func _menu_bar(d: Dictionary) -> HBoxContainer:
	var row := UIKit.hbox(6)
	var unspent := int(d.get("echoes", 0)) > 0
	var prophecy := not (d.prophecy.active as Dictionary).is_empty()
	var modes_new := bool(d.cleared[0]) and not bool(d.get("modes_seen", false))     # Act I opened the endgame: lit until visited
	# lit only once a run is played: before it, nothing there is affordable, and the end of the first run points to it
	var camp := int(d.stats.get("runs", 0)) > 0 and (Camp.has_news(d) or not bool(d.get("camp_seen", false)))
	for e in [["Camp", "camp"], ["Upgrades", "upgrades"], ["Modes", "endgame"]]:
		var b := UIKit.button(e[0], func(): act.emit(e[1], null), 50)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 19)
		if (e[1] == "upgrades" and unspent) or (e[1] == "endgame" and (prophecy or modes_new)) or (e[1] == "camp" and camp):
			b.add_theme_color_override("font_color", Color("ffd27a"))        # something waits in there
		row.add_child(b)
	return row

## Gold and unspent Echoes in one small pill.
func _purse(d: Dictionary) -> CenterContainer:
	var c := CenterContainer.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.035, 0.03, 0.04, 0.85)
	sb.border_color = Color(0.62, 0.45, 0.24, 0.75)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(16)
	sb.content_margin_left = 18; sb.content_margin_right = 18; sb.content_margin_top = 4; sb.content_margin_bottom = 4
	p.add_theme_stylebox_override("panel", sb)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var row := UIKit.hbox(16)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var flow := _resources(d, [["Gold", int(d.gold), UIKit.GOLD], ["Echoes", int(d.get("echoes", 0)), Color("9fd8ff")]])
	for f in flow.get_children():
		flow.remove_child(f)
		row.add_child(f)
	flow.free()                                        # emptied, never in the tree: it leaked once per menu build
	p.add_child(row)
	c.add_child(p)
	return c

## A square step button (previous / next, minus / plus) with a glyph large enough to read and hit.
func _step_btn(txt: String, cb: Callable, h: int) -> Button:
	var b := UIKit.button(txt, cb, h)
	b.custom_minimum_size.x = UIKit.MIN_TOUCH        # 40 dp on an S22 (54 was 35 dp wide)
	b.add_theme_font_size_override("font_size", 30)
	return b

# ================================================================= Heroes (the showcase)
## Main Menu > Heroes. The four exiles down the left; the chosen one stands framed on the title stage to the
## right. Picking one makes them the exile, has them cast and settle back to idle (MenuStage3D.showcase), stops
## whatever was speaking and plays their intro line (main's "hero" action: VoiceBank.stop_all, then
## VoiceBank.play(hero, "intro", 0)); the panel shows their lore (Story.HEROES) and a card for the one mechanic
## they are built around.
func show_heroes() -> void:
	_choices = []
	UIKit.clear(self)
	page = "sub"
	mouse_filter = Control.MOUSE_FILTER_STOP
	var d: Dictionary = Save.data
	var vs := get_viewport_rect().size
	var m := UIKit.safe_margins(vs)
	var portrait := vs.x < 820.0
	var x0 := m.x + (12.0 if portrait else 32.0)
	var col_w := vs.x - x0 - m.z - 12.0 if portrait else clampf(vs.x * 0.36, 400.0, 520.0)
	if main != null and main.menu_stage != null:
		main.menu_stage.frame_x = 0.5 if portrait else clampf((x0 + col_w + vs.x - m.z) * 0.5 / vs.x, 0.55, 0.8)
		main.menu_stage.frame_y = 0.28 if portrait else 0.5
		main.menu_stage._frame()
	_scrims(vs, x0, col_w, vs.x, portrait)
	var top := m.y + (0.0 if portrait else float(UIKit.SUB_BAND))     # clear of the subtitle band: the intro line plays here
	var v := _column(Vector2(x0, top), Vector2(col_w, vs.y - top - m.w))
	if portrait: v.alignment = BoxContainer.ALIGNMENT_END
	v.add_child(UIKit.title("Heroes", 34))
	var hg := _grid(2, 8)
	for i in Content.HEROES.size():
		var hh: Dictionary = Content.HEROES[i]
		var t := UIKit.tile(hh.name, Story.hero(String(hh.id)).title, func(): Save.data.hero = i; Save.mark_dirty(); act.emit("hero", i); show_heroes(), Content.col(hh.col), i == int(d.hero), 60)
		hg.add_child(t)
	v.add_child(hg)
	var h: Dictionary = Content.HEROES[int(d.hero)]
	var st := Story.hero(String(h.id))
	var nm := UIKit.label("%s  \u00b7  %s" % [String(h.name).to_upper(), st.title], 22, Content.col(h.col).lerp(UIKit.TEXT, 0.35), true, "display")
	v.add_child(nm)
	var bio := UIKit.label(String(st.bio), 16, Color("cfc5b0"), true, "italic")
	v.add_child(bio)
	v.add_child(_mechanic_card(h, st))
	v.add_child(_back_btn("menu"))

## The card for an exile's mechanic: its name, what it does, and their weapon and ultimate underneath.
func _mechanic_card(h: Dictionary, st: Dictionary) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.032, 0.045, 0.9)
	sb.border_color = Content.col(h.col).darkened(0.25)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 16; sb.content_margin_right = 16; sb.content_margin_top = 10; sb.content_margin_bottom = 12
	p.add_theme_stylebox_override("panel", sb)
	var b := UIKit.vbox(4)
	b.add_child(UIKit.label(String(st.mechanic).to_upper(), 19, UIKit.GOLD, false, "label"))
	b.add_child(UIKit.label(String(st.mechanic_d), 16, UIKit.TEXT, true, "body"))
	b.add_child(UIKit.divider())
	b.add_child(UIKit.label("Weapon: %s  \u00b7  Ultimate: %s" % [Content.WEAPONS[h.weapon].name, h.ult], 15, UIKit.DIM, true, "italic"))
	b.add_child(UIKit.label(String(h.ult_d), 15, UIKit.DIM, true, "italic"))
	p.add_child(b)
	return p

func _back_btn(what: String) -> Button:
	return UIKit.button("Back", func(): act.emit(what, null), 52)

# ================================================================= Upgrades and Modes (from the menu bar)
func show_upgrades() -> void:
	var v := _open(820)
	var d: Dictionary = Save.data
	_title(v, "Upgrades", "Spend Echoes in the Shard Web; set the legendary powers you have extracted.")
	var g := _grid(1 if get_viewport_rect().size.x < 820.0 else 2, 10)
	var e := int(d.get("echoes", 0))
	g.add_child(UIKit.tile("Shard Web", ("%d Echoes to spend" % e) if e > 0 else "Passive skills, bought with Echoes", func(): act.emit("web", null), Color("9fd8ff"), e > 0, 84))
	g.add_child(UIKit.tile("Codex", "%d of %d legendary powers active" % [(d.codex_active as Array).size(), Content.CODEX_SLOTS], func(): act.emit("codex", null), Color("ff9a4a"), false, 84))
	v.add_child(g)
	_back(v)

## The endgame and everything that feeds it: this season and tonight's moon, your nemesis, fragments and
## rift keys, the Daily Rift, prophecies, the Atlas, the Shard Herald, Greater Rifts and Torment.
func show_endgame() -> void:
	var v := _open(1000)
	var d: Dictionary = Save.data
	var portrait := get_viewport_rect().size.x < 820.0
	var unlocked := bool(d.cleared[0])
	_title(v, "Modes", "Prophecies are always open. The Daily Rift and the rest of the endgame open when Mossglen Hollow falls." if not unlocked else "")
	if unlocked and not bool(d.get("modes_seen", false)):
		d.modes_seen = true
		Save.mark_dirty()
	var th := 62
	var eg := _grid(1 if portrait else 2, 8)
	var act_p: Dictionary = d.prophecy.active
	var dt := UIKit.tile("Daily Rift", "The same seeded rift for everyone today" if daily_unlocked(d) else "Clear Mossglen Hollow to unlock", func(): act.emit("daily", "endgame"), Color("ffd27a"), false, th)
	_lock(dt, not daily_unlocked(d))
	eg.add_child(dt)
	var pr := UIKit.tile("Prophecy" + (" \u2605" if not act_p.is_empty() else ""), (String(Content.PROPHECIES[act_p.id].d)) if not act_p.is_empty() else "Take a contract before a run, for a reward you choose", func(): act.emit("prophecy", null), Color("e8b54e"), not act_p.is_empty(), th)
	eg.add_child(pr)
	var atl := UIKit.tile("Atlas of Falls", "Chart the shattered maps" if unlocked else "Clear Mossglen Hollow to unlock", func(): show_atlas(), Color("8fd8ff"), false, th)
	_lock(atl, not unlocked)
	eg.add_child(atl)
	var have: bool = int(d.fragments.rupture) > 0 and int(d.fragments.greed) > 0 and int(d.fragments.dread) > 0
	var pin := UIKit.tile("The Shard Herald", "Offer three fragments" if have else "Needs Rupture, Greed and Dread fragments", func(): act.emit("pinnacle", null), Color("ff5a4a"), false, th)
	_lock(pin, not have)
	eg.add_child(pin)
	v.add_child(eg)
	var grs := int(d.get("gr_sel", d.gr_key))
	var grow := UIKit.hbox(6)
	var dec := _step_btn("\u2212", func(): Save.data.gr_sel = maxi(1, int(Save.data.get("gr_sel", Save.data.gr_key)) - 1); show_endgame(), th)
	dec.disabled = not unlocked or grs <= 1
	var grt := UIKit.tile("Greater Rift %d" % grs, ("Best %d  \u00b7  keys to %d" % [int(d.gr_best), int(d.gr_key)]) if unlocked else "Clear Mossglen Hollow to unlock", func(): act.emit("rift", int(Save.data.get("gr_sel", Save.data.gr_key))), Color("c48aff"), false, th)
	_lock(grt, not unlocked)
	var inc := _step_btn("+", func(): Save.data.gr_sel = mini(int(Save.data.gr_key), int(Save.data.get("gr_sel", Save.data.gr_key)) + 1); show_endgame(), th)
	inc.disabled = not unlocked or grs >= int(d.gr_key)
	for c in [dec, grt, inc]: grow.add_child(c)
	var rows := _grid(1 if portrait else 2, 8)           # held sideways Greater Rift and Torment share a row: on two the Torment row sat below the fold at an S22's scale
	grow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_child(grow)
	v.add_child(rows)
	# torment: the optional difficulty of the campaign, the atlas and the herald (PLAY shows it when on)
	var tm := int(d.get("torment", 0))
	var tmax := int(d.get("torment_max", 0))
	var trow := UIKit.hbox(6)
	var tdec := _step_btn("\u2212", func(): Save.data.torment = maxi(0, int(Save.data.torment) - 1); Save.mark_dirty(); show_endgame(), th)
	tdec.disabled = tm <= 0
	var T: Dictionary = Content.TORMENT[tm]
	var tsub := ("+%d%% loot  \u00b7  foes x%.1f life" % [int(float(T.loot) * 100), float(T.hp)]) if tm > 0 else ("Win a run to unlock Torment I" if tmax == 0 else "Foes and loot as intended")
	var tt := UIKit.tile(String(T.name), tsub, func():         # the tile steps the tier (its tap did nothing; + and - only)
		Save.data.torment = (int(Save.data.torment) + 1) if int(Save.data.torment) < int(Save.data.torment_max) else 0
		Save.mark_dirty()
		show_endgame(), Color("b3242c") if tm > 0 else Color(0.7, 0.68, 0.66), tm > 0, th)
	var tinc := _step_btn("+", func(): Save.data.torment = mini(int(Save.data.torment_max), int(Save.data.torment) + 1); Save.mark_dirty(); show_endgame(), th)
	tinc.disabled = tm >= tmax
	for c in [tdec, tt, tinc]: trow.add_child(c)
	trow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_child(trow)
	# the season, tonight's sky and the fragments after the modes: above them they pushed 4 of the 6 rows below the fold
	var sea := Save.season()
	var sh := UIKit.hbox(8)
	sh.alignment = BoxContainer.ALIGNMENT_CENTER
	sh.add_child(UIKit.label(String(sea.name).to_upper(), 15, Color("c9a2ff"), false, "label"))
	var sd := UIKit.label(String(sea.d), 16, Color("a99bc4"), true, "italic")
	sd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sh.add_child(sd)
	v.add_child(sh)
	v.add_child(_sky_row())
	if Save.has_nemesis():
		# the nemesis drops a Legendary when slain (Bosses), so it wears Legendary's orange, as its name does in a run
		var nl := UIKit.label("Your nemesis %s awaits  (level %d)" % [d.nemesis.name, int(d.nemesis.level) + 1], 17, Content.col(Content.RARITY_COL[Content.Rarity.LEGENDARY]), true, "italic")
		nl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(nl)
	v.add_child(_resources(d, [["Rupture", int(d.fragments.rupture), Color("ff6a4a")], ["Greed", int(d.fragments.greed), Color("ffd24a")],
		["Dread", int(d.fragments.dread), Color("b890ff")], ["Rift key", int(d.gr_key), Color("c48aff")]]))
	_back(v)

## Hero name, kit, ultimate and element, centred under the hero between the column and the PLAY block.
func _hero_plate(h: Dictionary, x0: float, x1: float, bottom: float) -> void:
	var plate := UIKit.vbox(0)
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(plate)
	plate.position = Vector2(x0, bottom - 150.0)
	plate.size = Vector2(maxf(120.0, x1 - x0), 150.0)
	plate.alignment = BoxContainer.ALIGNMENT_END
	var nm := UIKit.label(String(h.name).to_upper(), 40, Content.col(h.col).lerp(UIKit.TEXT, 0.4), false, "display_heavy")
	nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	plate.add_child(nm)
	var bl := UIKit.label(String(h.blurb), 16, Color("cfc5b0"), true, "italic")
	bl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	plate.add_child(bl)
	plate.add_child(UIKit.divider())
	var ul := UIKit.label("%s  \u00b7  %s" % [String(h.ult).to_upper(), Content.EL_NAME[h.elem].to_upper()], 15, UIKit.GOLD, false, "label")
	ul.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	plate.add_child(ul)
	var ud := UIKit.label(h.ult_d, 16, Color("b8ad98"), true, "italic")
	ud.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	plate.add_child(ud)
	for c in plate.get_children(): (c as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	# taller than 150 (a two-line ultimate on a 600-unit canvas): grow upward, its foot stays on `bottom` (it grew down
	# past the screen's edge: the Emberwitch's "ground." cut off at the Largest UI scale)
	var fit := func():
		var ph := maxf(150.0, plate.get_combined_minimum_size().y)
		plate.position.y = bottom - ph
		plate.size.y = ph
	plate.minimum_size_changed.connect(fit)
	# now, not deferred: the menu can be rebuilt (and this plate freed) before a deferred call runs, and a lambda
	# whose capture was freed logs an error; later size changes arrive through the plate's own signal
	fit.call()

func _column(pos: Vector2, sz: Vector2) -> VBoxContainer:
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(sc)
	sc.position = pos
	sc.size = sz
	var v := UIKit.vbox(9)
	v.custom_minimum_size = Vector2(sz.x - 14.0, sz.y)     # at least screen tall, content centred; scrolls when taller
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	sc.add_child(v)
	return v

func _grad_rect(g: Gradient, vertical: bool) -> TextureRect:
	var gt := GradientTexture2D.new()
	gt.gradient = g
	if vertical:
		gt.fill_to = Vector2(0, 1); gt.width = 4; gt.height = 256
	else:
		gt.fill_to = Vector2(1, 0); gt.width = 512; gt.height = 4
	var r := TextureRect.new()
	r.texture = gt
	r.stretch_mode = TextureRect.STRETCH_SCALE
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return r

## Disable a tile and fade its carved title, so sealed content reads as sealed.
func _lock(t: Button, locked: bool) -> void:
	t.disabled = locked
	if locked and t.has_meta("title_label"):
		(t.get_meta("title_label") as Label).add_theme_color_override("font_color", Color(0.5, 0.47, 0.44))

## A small green-gold gem on a tile's left edge: this act is cleared.
func _cleared_mark(b: Control) -> void:
	var g := Gem.new()
	g.col = Color("9ad06a")
	g.kind = "w"
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(g)
	g.set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT)
	g.offset_left = 8; g.offset_right = 30; g.offset_top = -11; g.offset_bottom = 11

func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c

## A label-font heading flanked by thin bronze rules.
func _section(txt: String) -> HBoxContainer:
	var h := UIKit.hbox(12)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for k in 3:
		if k == 1:
			var l := UIKit.label(txt.to_upper(), 16, Color("c8a46a"), false, "label")
			h.add_child(l)
		else:
			var r := ColorRect.new()
			r.color = Color(0.62, 0.45, 0.24, 0.55)
			r.custom_minimum_size = Vector2(0, 1)
			r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			h.add_child(r)
	return h

## A strip of numbers in small slots: [[name, amount, colour], ...]. With no list: the crafting shards
## you hold (Gear shows them).
func _resources(d: Dictionary, items: Array = []) -> HFlowContainer:
	var f := HFlowContainer.new()
	f.alignment = FlowContainer.ALIGNMENT_CENTER
	f.add_theme_constant_override("h_separation", 14)
	f.add_theme_constant_override("v_separation", 4)
	f.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var list := items.duplicate()
	if list.is_empty():
		for c in Content.CURRENCY_IDS:
			if int(d.currency[c]) > 0: list.append([Content.CURRENCY[c].name, int(d.currency[c]), Content.col(Content.CURRENCY[c].col)])
	for it in list:
		var h := UIKit.hbox(5)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var gem := ColorRect.new()
		gem.color = it[2]
		gem.custom_minimum_size = Vector2(7, 7)
		gem.rotation = PI / 4.0
		gem.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		gem.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(gem)
		h.add_child(UIKit.label(str(it[1]), 17, UIKit.TEXT, false, "num"))
		h.add_child(UIKit.label(String(it[0]), 15, UIKit.DIM, false, "italic"))
		f.add_child(h)
	return f

# ================================================================= atlas
func show_atlas() -> void:
	var v := _open(1200)
	var atlas: Dictionary = main.get_atlas()
	_title(v, "Atlas of Falls", "Complete a map to reveal its neighbours. Citadels (corners) guard pinnacle fragments. Corrupted maps carry extra modifiers and rewards.")
	var map := AtlasView.new()
	map.atlas = atlas
	map.custom_minimum_size = Vector2(0, 360)
	map.selected = _sel_node
	map.picked.connect(func(id: int): _sel_node = id; show_atlas())
	v.add_child(map)
	if _sel_node >= 0:
		var n: Dictionary = atlas.nodes[_sel_node]
		var rw := Atlas.rewards(n)
		var mods := ""
		for m in n.mods: mods += "- %s: %s\n" % [Content.MAP_MODS[m].name, Content.MAP_MODS[m].d]
		v.add_child(UIKit.label("%s  (Tier %d %s)%s" % [Content.STAGES[int(n.biome)].name, n.tier, String(n.kind).capitalize(), "  COMPLETED" if n.done else ""], 22, UIKit.GOLD))
		v.add_child(UIKit.label(mods if mods != "" else "No modifiers.", 17, UIKit.TEXT, true))
		v.add_child(UIKit.label("+%d%% item quantity, +%d%% item rarity" % [int(rw.x * 100), int(rw.y * 100)], 17, Content.BETTER))
		var run := UIKit.button("Run this map", func(): act.emit("atlas", _sel_node), 64)
		run.disabled = not bool(n.open)
		v.add_child(run)
	_back(v, "endgame")

# ================================================================= stash / crafting / cube
## Gear's two-tap actions: the one waiting for its second tap, on which item.
func _arm(what: String, uid: int) -> void:
	_armed = what
	_armed_uid = uid

func _disarm() -> void:
	_armed = ""
	_armed_uid = -1

func _is_armed(what: String, uid: int) -> bool:
	return _armed == what and _armed_uid == uid

## A redrawn page's scrolling body back where it was, once its new content is laid out.
func _keep_scroll(sc: ScrollContainer, at: int) -> void:
	if at <= 0 or sc == null: return
	await get_tree().process_frame
	if is_instance_valid(sc): sc.scroll_vertical = at

## Equipped gear first (slot order), then the stash: the rarest first, the strongest first within a rarity.
func _gear_list() -> Array:
	var out: Array = []
	for s in Content.SLOTS:
		var it: Dictionary = Save.data.equipped[s]
		if not it.is_empty(): out.append({"it": it, "eq": true})
	var st: Array = (Save.data.stash as Array).duplicate()
	st.sort_custom(func(a, b):
		if int(a.rarity) != int(b.rarity): return int(a.rarity) > int(b.rarity)
		var sa := Items.score(a)
		var sb := Items.score(b)
		if sa != sb: return sa > sb
		return int(a.uid) < int(b.uid))
	for it in st:
		out.append({"it": it, "eq": false})
	return out

var _was_stash := false
func show_stash(in_run: bool = false) -> void:
	var v := _open(1200)
	_in_stash = true
	if not _was_stash:                       # a new visit: this visit's NEW marks are the finds not seen yet
		_stash_new = (Save.data.get("new_items", []) as Array).duplicate()
		Save.data.new_items = []
		Save.mark_dirty()
		_disarm()
	else:                                    # a redraw (a tap on this page) keeps the page where the thumb left it
		_keep_scroll(_body_sc, _prev_scroll)
	_title(v, "Gear", "Select an item, then apply a shard. Extract a legendary item's power and the Codex keeps it forever.")
	v.add_child(_resources(Save.data))                     # the crafting shards you hold
	var list := _gear_list()
	var portrait := get_viewport_rect().size.x < 820.0
	var foot_acts: Array = []                              # the selected item's actions, kept on screen beside Back
	var cols: BoxContainer = UIKit.vbox(14) if portrait else UIKit.hbox(18)
	v.add_child(cols)
	var left := UIKit.vbox(6)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(left)
	var right := UIKit.vbox(8)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_stretch_ratio = 1.1
	cols.add_child(right)
	var stash_head := false
	left.add_child(_section("Equipped"))
	if list.is_empty() or not list[0].eq:
		var ne := UIKit.label("Nothing equipped yet. Choose an item from your stash.", 16, UIKit.DIM, true, "italic")
		ne.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		left.add_child(ne)
	for k in list.size():
		var e: Dictionary = list[k]
		var it: Dictionary = e.it
		if not e.eq and not stash_head:
			stash_head = true
			left.add_child(_section("Stash  \u00b7  %d / %d" % [Save.data.stash.size(), World.STASH_CAP]))
			if Save.data.stash.size() >= World.STASH_CAP - 10:
				var fl := UIKit.label("Nearly full: a full stash salvages its weakest finds. Nim's bench at the Camp clears a whole rarity at once.", 15, Color("ffcf9a"), true, "italic")
				fl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				left.add_child(fl)
		var rc := Content.col(Content.RARITY_COL[it.rarity])
		var marks := ""
		if not e.eq and _stash_new.has(int(it.uid)): marks += "  \u00b7  NEW"
		if not e.eq and Camp.is_locked(Save.data, it): marks += "  \u00b7  locked"
		var t := UIKit.tile(Items.name_of(it), "%s  \u00b7  %s  \u00b7  item level %d%s" % [Content.RARITY_NAME[it.rarity], Content.SLOT_NAME[it.slot], it.ilvl, marks],
			func(): _sel_item = k; _disarm(); show_stash(in_run), rc, k == _sel_item, 62, true, rc.lightened(0.15))
		left.add_child(t)
	if _sel_item >= 0 and _sel_item < list.size():
		var sel: Dictionary = list[_sel_item]
		var it: Dictionary = sel.it
		var rc2 := Content.col(Content.RARITY_COL[it.rarity])
		var card := UIKit.vbox(6)
		var nm := UIKit.label(Items.name_of(it), 26, rc2, true, "display")
		nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		card.add_child(nm)
		var sub := UIKit.label("%s %s  \u00b7  item level %d  \u00b7  score %d" % [Content.RARITY_NAME[it.rarity], Content.SLOT_NAME[it.slot], it.ilvl, int(Items.score(it))], 16, UIKit.DIM, true, "italic")
		sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		card.add_child(sub)
		card.add_child(UIKit.divider())
		var lines := Items.lines(it)
		for i in lines.size():
			var ln := UIKit.label(lines[i], 18, Color("8fb4ff") if i > 0 else Color("cfc5b0"), true)
			ln.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			card.add_child(ln)
		var cur: Dictionary = Save.data.equipped[it.slot]
		if not sel.eq and not cur.is_empty():
			var diff := Items.score(it) - Items.score(cur)
			var dl := UIKit.label("%+d score vs equipped" % int(diff), 17, Content.BETTER if diff > 0 else Color("ff6a6a"), false, "display")
			dl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			card.add_child(dl)
		var cp := PanelContainer.new()
		cp.add_theme_stylebox_override("panel", UIKit.nine("card", 46, Vector4(26, 26, 26, 24), Color(0.78, 0.76, 0.74).lerp(rc2, 0.5)))
		cp.add_child(card)
		right.add_child(cp)
		# what cannot be undone takes two taps, as the bench's "Salvage all" does: salvaging any item (Salvage sits 6 dp
		# from Equip on an S22, and Normal and Magic went in one tap), extracting a legendary power, applying a shard
		# (its first tap shows what it does: touch shows no tooltips)
		var uid := int(it.uid)
		if not sel.eq:
			var locked := Camp.is_locked(Save.data, it)
			var known: bool = String(it.leg) != "" and (Save.data.codex as Array).has(String(it.leg))
			var yt := "Locked: salvage, the bench and the furnace leave it alone." if locked else "Salvage gives " + Camp.yield_text(Camp.salvage_yield(it)) + "."
			if known: yt += " Its power is already in your Codex: extracting it again gives nothing."
			var yl := UIKit.label(yt, 15, UIKit.DIM, true, "italic")
			yl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			card.add_child(yl)
			foot_acts.append(UIKit.button("Equip", func(): _disarm(); act.emit("equip", it); show_stash(in_run), 50))
			var two := true
			var armed_s := _is_armed("salvage", uid)
			var sb := UIKit.button("Tap to confirm" if armed_s else "Salvage", func():
				if two and not armed_s:
					_arm("salvage", uid)
				else:
					_disarm()
					act.emit("salvage", it)
					_sel_item = -1
				show_stash(in_run), 50)
			sb.disabled = locked
			foot_acts.append(sb)
			foot_acts.append(UIKit.button("Unlock" if locked else "Lock", func(): _disarm(); Camp.toggle_lock(Save.data, it); Save.mark_dirty(); show_stash(in_run), 50))
			if String(it.leg) != "":
				var armed_x := _is_armed("extract", uid)
				var xb := UIKit.button("Power known" if known else ("Tap to confirm" if armed_x else "Extract power"), func():
					if not armed_x:
						_arm("extract", uid)
					else:
						_disarm()
						act.emit("extract", it)
						_sel_item = -1
					show_stash(in_run), 50)
				xb.disabled = known
				foot_acts.append(xb)
		right.add_child(_section("Craft"))
		var grid := _grid(2, 8)
		for c in Content.CURRENCY_IDS:
			var n := int(Save.data.currency[c])
			var armed_c := _is_armed(c, uid)
			var b2 := UIKit.button("Tap to apply" if armed_c else "%s  %d" % [Content.CURRENCY[c].name, n], func():
				if not armed_c:
					_arm(c, uid)
				else:
					_disarm()
					_craft_msg = main.craft(it, c)
				show_stash(in_run), 46)
			b2.tooltip_text = Content.CURRENCY[c].d
			b2.disabled = n <= 0
			b2.add_theme_color_override("font_color", Content.col(Content.CURRENCY[c].col))
			b2.add_theme_font_size_override("font_size", 18)
			b2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			grid.add_child(b2)
		right.add_child(grid)
		if Content.CURRENCY.has(_armed) and _armed_uid == uid:          # under the grid, so no button moves
			var sd := UIKit.label("%s: %s Tap it again to apply it to this item." % [Content.CURRENCY[_armed].name, Content.CURRENCY[_armed].d], 17, UIKit.TEXT, true, "italic")
			sd.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			right.add_child(sd)
		if _craft_msg != "":
			right.add_child(UIKit.label(_craft_msg, 17, Color("ffcf9a"), true, "italic"))
	else:
		var hint := UIKit.label("Select an item to inspect, equip or craft.", 19, UIKit.DIM, true, "italic")
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		right.add_child(hint)
	var back_to := "resume_pause" if in_run else ("camp" if parent_page == "camp" else "menu")
	if foot_acts.is_empty():
		_back(v, back_to)
	else:                       # one row held sideways; upright, four buttons go two by two
		foot_acts.append(UIKit.button("Back", func(): act.emit(back_to, null), 50))
		var fr := _grid(foot_acts.size() if (foot_acts.size() <= 3 or not portrait) else (3 if foot_acts.size() > 4 else 2), 10)
		for b in foot_acts:
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			fr.add_child(b)
		UIKit.foot(v).add_child(fr)

# ================================================================= codex
# ================================================================= the Shard Web (passive tree)
var _sel_passive := "start"

## The Shard Web. `entering` (the page opened, a node taken or the web reset): with Echoes to spend and the selection
## not takeable, the first node within reach is selected, so the page's main button reads Take (it opened on the taken
## start node, Take disabled). The nodes within reach are listed beside the graph as tiles: the graph's own nodes are
## 9.5-14 dp targets on an S22, too small to hit.
func show_web(entering: bool = true) -> void:
	var v := _open(1180)
	var d: Dictionary = Save.data
	var taken: Array = d.passives
	var portrait := get_viewport_rect().size.x < 820.0
	var reach: Array = []
	for id in Content.PASSIVES:
		if Content.passive_can_take(id, taken): reach.append(id)
	if entering and int(d.echoes) > 0 and not Content.passive_can_take(_sel_passive, taken) and not reach.is_empty():
		_sel_passive = String(reach[0])
	_title(v, "The Shard Web", "Echoes from every run buy permanent passives. Take a node that touches one you own.")
	var body: BoxContainer = UIKit.vbox(10) if portrait else UIKit.hbox(18)
	v.add_child(body)
	var view := WebView.new()
	view.taken = taken
	view.selected = _sel_passive
	# held sideways the page is 720 units: the graph gets what the title, the subtitle band and the pinned row leave
	# (the pinned row is UIKit.FOOT_H tall: 417 = 410 + the 7 units FOOT_H grew from 56 to 63); at least 220, which an
	# S22 at its x1.125 leaves (640 - 417 = 223: at the old 300 floor the bottom arm sat under the pinned row)
	var view_h := clampi(int(get_viewport_rect().size.y) - 417, WEB_MIN_H, 480)
	view.custom_minimum_size = Vector2(0, 420) if portrait else Vector2(660, view_h)
	view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view.picked.connect(func(id: String): _sel_passive = id; show_web(false))
	body.add_child(view)
	# side column (landscape): echoes, the nodes within reach, the selected node; scrolled within the graph's height
	var side := UIKit.vbox(8)
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if portrait:
		body.add_child(side)
	else:
		var ssc := ScrollContainer.new()
		ssc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		ssc.custom_minimum_size = Vector2(340, view_h)
		ssc.add_child(side)
		body.add_child(ssc)
	var info := UIKit.hbox(10)
	info.alignment = BoxContainer.ALIGNMENT_CENTER
	info.add_child(UIKit.label("%d" % int(d.echoes), 34, UIKit.GOLD, false, "num_heavy"))
	var il := UIKit.label("Echoes to spend\n%d of %d taken" % [taken.size() - 1, Content.PASSIVES.size() - 1], 16, UIKit.DIM, false, "italic")
	info.add_child(il)
	side.add_child(info)
	var rg := _grid(2 if portrait else 1, 6)
	for id in reach:
		var R: Dictionary = Content.PASSIVES[id]
		var rt := UIKit.tile(String(R.name), String(R.d), func(): _sel_passive = String(id); show_web(false), WebView.branch_col(id), id == _sel_passive, UIKit.MIN_TOUCH)
		rt.set_meta("passive", id)
		rg.add_child(rt)
	if not reach.is_empty():
		side.add_child(_section("Within reach"))
		side.add_child(rg)
	else:
		rg.free()
	if not reach.has(_sel_passive):                    # a tile already says what a node within reach does
		side.add_child(UIKit.divider())
		var P: Dictionary = Content.PASSIVES[_sel_passive]
		var nm := UIKit.label(String(P.name).to_upper(), 22, WebView.branch_col(_sel_passive) if _sel_passive != "start" else UIKit.GOLD, true, "display")
		nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		side.add_child(nm)
		var kd := UIKit.label(String(P.kind).capitalize() + ("  \u00b7  taken" if taken.has(_sel_passive) else ""), 14, UIKit.DIM, false, "label")
		kd.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		side.add_child(kd)
		var ds := UIKit.label(P.d, 18, UIKit.TEXT, true, "body")
		ds.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		side.add_child(ds)
	var can := Content.passive_can_take(_sel_passive, taken) and int(d.echoes) > 0
	var take := UIKit.button("Taken" if taken.has(_sel_passive) else ("Take  \u00b7  1 Echo" if Content.passive_can_take(_sel_passive, taken) else "Not yet reachable"), func():
		if Content.passive_can_take(_sel_passive, Save.data.passives) and int(Save.data.echoes) > 0:
			Save.data.passives.append(_sel_passive)
			Save.data.echoes = int(Save.data.echoes) - 1
			Save.mark_dirty()
			Sfx.play("craft")
		show_web(), 54)
	take.disabled = not can
	var reset := UIKit.button("Reset web  (refund all)", func():
		Save.data.echoes = int(Save.data.echoes) + Save.data.passives.size() - 1
		Save.data.passives = ["start"]
		Save.mark_dirty()
		show_web(), 48)
	reset.disabled = taken.size() <= 1
	var back := UIKit.button("Back", func(): act.emit("upgrades", null), 48)
	# pinned, so held sideways the web keeps its height: one row; upright, Take over Reset and Back
	var ft := UIKit.foot(v)
	for b in [take, reset, back]: b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var fr := _grid(2 if portrait else 3, 10)
	if portrait: ft.add_child(take)
	else: fr.add_child(take)
	fr.add_child(reset)
	fr.add_child(back)
	ft.add_child(fr)
const WEB_MIN_H := 220

## Codex & Story: the acts (Story: what each one is, its boss, and the Rift Echoes found in it), the exiles'
## bios, then the bestiary, lore pages, extracted powers, records and the arsenal. From the main menu (back:
## "menu") and from Upgrades (back: "upgrades").
var _codex_back := "upgrades"
func show_codex(back: String = "upgrades") -> void:
	_codex_back = back
	var v := _open(1100)
	_title(v, "Codex & Story", Story.TITLE)
	var tabs := TabContainer.new()
	tabs.custom_minimum_size = Vector2(0, 520)
	v.add_child(tabs)
	tabs.add_child(_scroll(_story_page(), "Story"))
	tabs.add_child(_scroll(_exiles_page(), "Exiles"))
	# bestiary
	var b := UIKit.vbox(6)
	b.name = "Bestiary"
	for e in Content.ENEMIES:
		var c := Save.bestiary_count(e.id)
		var tier := Save.bestiary_tier(e.id)
		var next := "" if tier >= Content.BESTIARY_TIERS.size() else " (next tier at %d)" % Content.BESTIARY_TIERS[tier]
		var row := UIKit.hbox(12)
		var nm := UIKit.label(e.name if c > 0 else "Unknown horror", 18, UIKit.TEXT if c > 0 else Color(0.45, 0.42, 0.4), false, "display")
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(nm)
		row.add_child(UIKit.label("%d slain  \u00b7  tier %d  \u00b7  +%d%% damage%s" % [c, tier, tier * 3, next], 15, UIKit.DIM, false, "italic"))
		b.add_child(row)
		if tier >= 1: b.add_child(UIKit.label(e.lore, 15, Color("a89c86"), true, "italic"))
	tabs.add_child(_scroll(b, "Bestiary"))
	# lore
	var l := UIKit.vbox(6)
	l.add_child(UIKit.label("%d / %d pages. Every set of %d: +5%% damage, +10 life." % [Save.data.lore.size(), Content.LORE.size(), Content.LORE_SET], 18, UIKit.GOLD))
	for k in Content.LORE.size():
		var have: bool = Save.data.lore.has(k)
		l.add_child(UIKit.label(Content.LORE[k][0] if have else "A missing page", 18, Color("e8dcc0") if have else Color(0.45, 0.42, 0.4), false, "display"))
		if have: l.add_child(UIKit.label(Content.LORE[k][1], 16, Color("a89c86"), true, "italic"))
	tabs.add_child(_scroll(l, "Lore"))
	# legendary powers (Cube codex)
	var p := UIKit.vbox(6)
	p.add_child(UIKit.label("Extracted powers. Up to %d active at once, regardless of gear." % Content.CODEX_SLOTS, 18, UIKit.GOLD, true))
	for id in Content.LEGENDARY_IDS:
		var known: bool = Save.data.codex.has(id)
		var on: bool = Save.data.codex_active.has(id)
		var L: Dictionary = Content.LEGENDARIES[id]
		var bt := UIKit.button("%s%s: %s" % ["[ACTIVE] " if on else "", L.name, L.d] if known else "??? (find and extract this legendary)", func(): act.emit("codex_toggle", id); show_codex(_codex_back), 52)
		bt.disabled = not known
		bt.alignment = HORIZONTAL_ALIGNMENT_LEFT
		bt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		p.add_child(bt)
	tabs.add_child(_scroll(p, "Powers"))
	var r := UIKit.vbox(6)
	var st: Dictionary = Save.data.stats
	for k in st:
		r.add_child(UIKit.label("%s: %s" % [String(k).capitalize(), str(int(st[k])) if k != "playtime" else "%d min" % int(float(st[k]) / 60.0)], 18))
	r.add_child(UIKit.label("Greater Rift best: %d   Herald kills: %d" % [Save.data.gr_best, Save.data.herald_kills], 18))
	tabs.add_child(_scroll(r, "Records"))
	# arsenal: every weapon, what it does, and how the locked ones are earned
	var ar := UIKit.vbox(8)
	var req := {}
	for u in Content.UNLOCKS: req[u.w] = u
	var pool: Array = Save.weapon_pool()
	for id in Content.WEAPON_IDS:
		var wd: Dictionary = Content.WEAPONS[id]
		var have := pool.has(id)
		var row := UIKit.hbox(12)
		var nm := UIKit.label(wd.name, 19, Content.col(wd.col) if have else Color(0.5, 0.47, 0.44), false, "display")
		nm.custom_minimum_size = Vector2(190, 0)
		row.add_child(nm)
		var txt := "%s  Evolves into %s at Lv 5 with %s." % [wd.d[0], wd.evo, Content.PERKS[wd.pair].name]
		if not have:
			var pr: Array = Save.unlock_progress(req[id])
			txt = "Locked: %s (%d / %d)" % [req[id].d, pr[0], pr[1]]
		var dl := UIKit.label(txt, 15, UIKit.DIM if have else Color("b89a6a"), true, "italic")
		dl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(dl)
		ar.add_child(row)
	tabs.add_child(_scroll(ar, "Arsenal"))
	_back(v, back)

## The Codex's Story page: every act that is open (its title and place in the story, its lore, its boss and,
## once cleared, how it ended) and its two Rift Echoes (the fragment once found, else where to look).
func _story_page() -> VBoxContainer:
	var d: Dictionary = Save.data
	var found: Array = d.get("rift_echoes", [])
	var open := _open_acts(d)
	var b := UIKit.vbox(6)
	for i in Story.ACTS.size():
		var a: Dictionary = Story.ACTS[i]
		var cleared: bool = i < d.cleared.size() and bool(d.cleared[i])
		var hd := UIKit.label("%s  \u00b7  %s%s" % [a.subtitle, a.title, "   \u2713" if cleared else ""], 20, Content.col(Content.STAGES[i].acc).lerp(UIKit.TEXT, 0.3), true, "display")
		b.add_child(hd)
		if not open.has(i):
			b.add_child(UIKit.label("Sealed until the act before it is cleared.", 15, Color(0.5, 0.47, 0.44), true, "italic"))
			continue
		b.add_child(UIKit.label(" ".join(a.intro_lines), 16, Color("cfc5b0"), true, "italic"))
		b.add_child(UIKit.label("%s: \u201c%s\u201d" % [a.boss_name, a.boss_taunt], 15, Color("e0b0a0"), true, "body"))
		if cleared: b.add_child(UIKit.label(String(a.victory_note), 15, Color("a8c890"), true, "italic"))
		for k in 2:
			var e: Dictionary = a.echoes[k]
			if found.has(Story.echo_key(i, k)):
				b.add_child(UIKit.label("Rift Memory: %s. %s" % [e.title, e.text], 15, Color("c9b3ff"), true, "body"))
			else:
				# 6.3:1 on the panel (it was 4.28 nominal and rendered 3.09 as thin italic): a hint is worth reading
				b.add_child(UIKit.label("Rift Memory: not yet heard (it waits beside an arch in this act)", 15, Color("9d8fbf"), true, "italic"))
		b.add_child(UIKit.divider())
	return b

## The Codex's Exiles page: each exile's bio and mechanic.
func _exiles_page() -> VBoxContainer:
	var b := UIKit.vbox(8)
	for h in Content.HEROES:
		var st := Story.hero(String(h.id))
		b.add_child(UIKit.label("%s  \u00b7  %s" % [String(h.name).to_upper(), st.title], 20, Content.col(h.col).lerp(UIKit.TEXT, 0.35), true, "display"))
		b.add_child(UIKit.label(String(st.bio), 16, Color("cfc5b0"), true, "italic"))
		b.add_child(UIKit.label("%s: %s" % [st.mechanic, st.mechanic_d], 15, UIKit.TEXT, true, "body"))
		b.add_child(UIKit.divider())
	return b

func _scroll(c: Control, nm: String) -> ScrollContainer:
	var s := ScrollContainer.new()
	s.name = nm
	s.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.add_child(c)
	return s

# ================================================================= options
var _opt_tab := 0

## Options in three tabs (Game / Graphics / Diagnostics): on a 720-high landscape phone the single list
## had grown to ~25 rows with the graphics and test tools below the fold.
## Options, in four tabs. Audio: sound on or off, Master, Music, SFX and Voice (Save.apply_audio: Master and
## Voice are buses, Music and SFX scale their players), and the Safe sound engine. Graphics: the tier, the 3D
## render scale, the renderer (Vulkan or OpenGL Safe Mode), the UI scale, Show FPS and the rest. Game: feel,
## aim, controls, accessibility. Diagnostics: the self-test, benchmark and crash reports (from the main menu).
## `back` is where Back goes: "menu", or "resume_pause" when opened from the pause menu.
const OPT_TABS := ["Audio", "Graphics", "Game", "Diagnostics"]
const UI_SCALES := [0.85, 1.0, 1.15, 1.3]
func show_options(back: String = "menu") -> void:
	var v := _open(900)
	_title(v, "Options", "Shardfall " + Diag.version())
	# upright the four tabs take two rows: on one row they needed ~600 units, wider than an S22's 598-unit canvas
	var tabs := _grid(2 if get_viewport_rect().size.x < 820.0 else OPT_TABS.size(), 8)
	for i in OPT_TABS.size():
		var tb := UIKit.button(OPT_TABS[i], func(): _opt_tab = i; show_options(back), 48)
		tb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if i == _opt_tab: tb.add_theme_color_override("font_color", UIKit.GOLD)
		else: tb.modulate = Color(0.75, 0.72, 0.7)
		tabs.add_child(tb)
	v.add_child(tabs)
	match _opt_tab:
		0:
			_toggle(v, "Sound", "sound", back)
			_slider(v, "Master", "volume", 0.0, 1.0, back)
			_slider(v, "Music", "music_volume", 0.0, 1.0, back)
			_slider(v, "SFX", "sfx_volume", 0.0, 1.0, back)
			_slider(v, "Voice", "voice_volume", 0.0, 1.0, back)
			_toggle(v, "Sound engine: Safe (fewer voices, no ambience)", "sfx_safe", back)
		1:
			_cycle(v, "Graphics tier", "gfx", ["Auto (%s)" % Quality.NAMES[Quality.tier()] if int(Save.opt("gfx")) == 0 else "Auto", "Low", "Medium", "High"], back)
			_cycle(v, "3D scale", "render_scale", ["Auto", "100%", "75%", "50%"], back)
			_renderer_row(v, back)
			_ui_scale_row(v, back)
			_toggle(v, "Show FPS", "show_fps", back)
			_cycle(v, "View", "renderer", ["3D (PoE-style)", "Classic 2D"], back)
			_cycle(v, "Frame rate cap", "frame_cap", ["Auto (%s)" % ("60" if OS.has_feature("mobile") else "none"), "30 (cool, saves battery)", "60", "None"], back)
			_cycle(v, "GPU crowd simulation", "gpu_crowd", ["Auto (%s)" % ("Off" if OS.has_feature("mobile") else "On"), "On", "Off"], back)
			_toggle(v, "Ambient particles (fireflies, embers)", "ambient", back)
			if not Save.opt("gfx_off").is_empty():
				v.add_child(UIKit.label("Switched off after a crash: " + ", ".join(Save.opt("gfx_off").map(func(f): return Quality.FEATURE_NAMES.get(f, f))), 15, Color("e0645a"), true, "italic"))
				v.add_child(UIKit.button("Turn them back on", func(): Save.set_opt("gfx_off", []); Quality.load_saved(); act.emit("options_changed", null); show_options(back), 48))
		2:
			# first, so it is on screen without scrolling (it was the sixth row; a phone held sideways shows four)
			_toggle(v, "Colour-blind palette & patterns", "colorblind", back)
			_slider(v, "Screen shake", "shake", 0.0, 1.5, back)
			_cycle(v, "Damage numbers", "dmg_numbers", ["Off", "Crits & reactions", "All"], back)
			_cycle(v, "Auto-aim", "aim", ["Nearest", "Strongest", "Facing"], back)
			_cycle(v, "Joystick", "joy_mode", ["Floating", "Fixed"], back)
			_toggle(v, "Left-handed layout", "left_handed", back)
			_toggle(v, "Reduce flashing", "reduce_flash", back)
			_toggle(v, "Haptics", "haptics", back)
			_toggle(v, "Auto-equip upgrades", "auto_equip", back)
			_cycle(v, "Loot filter", "loot_filter", ["Show all", "Hide normal", "Rare and better"], back)
			_toggle(v, "Always show touch buttons", "force_touch_ui", back)
			var T: Dictionary = Save.data.tutorial
			_opt_row(v, "Tutorial tips (Captain Brask)", "On" if bool(T.on) else "Off", func():
				T.on = not bool(T.on)
				Save.mark_dirty()
				show_options(back), bool(T.on))
			_opt_row(v, "Replay the tutorial", "From the start", func():
				T.on = true
				T.done = []
				Save.mark_dirty()
				show_options(back), true)
			if back == "menu":
				var sr := _grid(2, 10)
				var cs := _copy_button("Copy save", func(): return Save.export_text(), "Save copied: keep it somewhere safe", 48)
				var ps := UIKit.button("Paste save", func(): show_paste_save(back), 48)
				for b in [cs, ps]:
					b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
					sr.add_child(b)
				v.add_child(sr)
				var sh := UIKit.label("Moving to a new install? Copy your save, keep the text somewhere safe (a note or a message to yourself), then paste it after reinstalling.", 14, UIKit.DIM, true, "italic")
				sh.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				v.add_child(sh)
		3:
			if back != "menu":
				var nl := UIKit.label("The tests start their own scene: open Options from the main menu to run them.", 16, UIKit.DIM, true, "italic")
				nl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				v.add_child(nl)
			else:
				v.add_child(_copy_button("Copy report", func(): return Diag.report_text(), "Report copied: paste it into a message to us", 50))
				v.add_child(UIKit.button("Graphics self-test (finds crashing features)", func(): Save.flush(); act.emit("selftest", null), 50))
				var bb := UIKit.button("Run benchmark (23 s)", func(): Save.flush(); act.emit("bench", null), 50)
				bb.tooltip_text = "A fixed 400-foe scene; Copy report on the result sends it, to compare graphics settings."
				v.add_child(bb)
				if FileAccess.file_exists(Diag.PREV):
					v.add_child(UIKit.button("Last crash report", func():
						show_crash(FileAccess.get_file_as_string(Diag.PREV).strip_edges().split("\n").slice(-30)), 48))
				var st: Dictionary = Save.data.get("selftest", {})
				if not st.get("results", []).is_empty() and not st.get("running", false):
					v.add_child(UIKit.button("Last self-test results", func(): show_selftest(st), 48))
			Quality.device_class()
			var info := UIKit.label("%s  \u00b7  %s  \u00b7  %s\nDevice class: %s (Auto graphics: %s)" % [OS.get_model_name(), Quality.dev_reason, RenderingServer.get_current_rendering_method(),
				["budget", "mid-range", "flagship"][Quality.device_class()], Quality.NAMES[Quality.tier()] if int(Save.opt("gfx")) == 0 else "overridden"], 14, UIKit.DIM, true, "italic")
			info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			v.add_child(info)
	UIKit.foot(v).add_child(UIKit.button("Back", func(): Save.flush(); _opt_tab = 0; act.emit(back, null), 52))

## Graphics > UI scale: the canvas scale on top of the automatic one (main._ui_scale), in four steps. The value is
## the scale this screen applies (main clamps it where the pages would no longer fit), with a note when it is less.
func _ui_scale_row(v: VBoxContainer, back: String) -> void:
	var cur := float(Save.opt("ui_scale"))
	var k := 1
	for i in UI_SCALES.size():
		if absf(UI_SCALES[i] - cur) < 0.01: k = i
	var applied := roundi(UIKit.ui_scale_applied * 100.0)
	_opt_row(v, "UI scale", ["Small", "Normal", "Large", "Largest"][k] + " (%d%%)" % applied, func():
		Save.set_opt("ui_scale", UI_SCALES[(k + 1) % UI_SCALES.size()])
		act.emit("options_changed", null)
		show_options(back))
	if applied < roundi(UI_SCALES[k] * 100.0):
		var nt := UIKit.label("%s asks for %d%%: this screen fits %d%% before the pages would run off it." % [["Small", "Normal", "Large", "Largest"][k], roundi(UI_SCALES[k] * 100.0), applied], 16, UIKit.DIM, true, "italic")
		v.add_child(nt)

## Options > Graphics > Renderer: Vulkan (the Mobile renderer) or OpenGL Safe Mode (Compatibility). The
## engine picks its driver before any script runs, so a change applies on the next launch (Quality.set_api).
func _renderer_row(v: VBoxContainer, back: String) -> void:
	var api := int(Save.opt("gfx_api"))
	_opt_row(v, "Renderer", ["Vulkan", "OpenGL Safe Mode"][clampi(api, 0, 1)], func():
		Quality.set_api(Quality.API_GL if api == Quality.API_VULKAN else Quality.API_VULKAN)
		show_options(back), api == Quality.API_VULKAN)
	var running := RenderingServer.get_current_rendering_method()
	var note := ""
	if Quality.safe_fell_back: note = "Switched to OpenGL Safe Mode: the last session crashed on Vulkan."
	elif running in ["forward_plus", "mobile", "gl_compatibility"] and (api == Quality.API_GL) != Quality.api_is_gl():
		note = "Applies on the next launch (running %s now)." % ("OpenGL" if Quality.api_is_gl() else "Vulkan")
	if note != "": v.add_child(UIKit.label(note, 15, Color("e0b85a"), true, "italic"))

## The Daily Rift: today's seeded run (act, exile, two modifiers), its share code, your best scores,
## and a field to enter a friend's code.
## `back`: the page its Back returns to (the title's tile: "menu"; Modes' tile: "endgame"), kept across its own
## redraws. It always went to Modes, even opened from the title, a page the player had never seen.
var _daily_back := "endgame"
func show_daily(msg: String = "", back: String = "") -> void:
	if back != "": _daily_back = back
	var v := _open(900)
	var D: Dictionary = Save.data.daily
	var td := Daily.today()
	var dd := Time.get_date_dict_from_system()
	_title(v, "Daily Rift", "%s %d. The same rift for everyone today. Gear, passives and legendaries stay behind." % [["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"][int(dd.month) - 1], int(dd.day)])
	var code := UIKit.label(String(td.code), 40, UIKit.GOLD, false, "display_heavy")
	code.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(code)
	var info := UIKit.label("Act %s: %s   \u00b7   Exile: %s   \u00b7   %s" % [["I", "II", "III", "IV", "V"][int(td.stage)], Content.STAGES[td.stage].name,
		Content.HEROES[td.hero].name, " + ".join(td.mods.map(func(m): return Content.MAP_MODS[m].name))], 18, UIKit.TEXT, true, "body")
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(info)
	var best := int(D.best.get(td.code, -1))
	var bl := UIKit.label(("Your best today: %d" % best) if best >= 0 else "Not attempted yet today. First clear: +3 Echoes.", 17, Color("cfc5b0"), true, "italic")
	bl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(bl)
	var row := _grid(2, 10)
	var go := UIKit.button("Enter today's rift", func(): act.emit("daily_go", td), 56)
	go.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(go)
	var cp := UIKit.button("Copy code", func(): DisplayServer.clipboard_set(String(td.code)); show_daily("Copied " + String(td.code)), 56)
	cp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(cp)
	v.add_child(row)
	v.add_child(_section("A friend's rift"))
	var er := UIKit.hbox(10)
	var le := LineEdit.new()
	le.placeholder_text = "SHARD-XXXX"
	le.max_length = 10
	le.custom_minimum_size = Vector2(220, 50)
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.add_theme_font_size_override("font_size", 22)
	er.add_child(le)
	er.add_child(UIKit.button("Play this code", func():
		var s := Daily.seed_from_code(le.text)
		if s < 0: show_daily("That is not a rift code (it looks like SHARD-7KQ2).")
		else: act.emit("daily_go", Daily.config(s)), 50))
	v.add_child(er)
	if msg != "":
		var ml := UIKit.label(msg, 16, Color("ffd27a"), true, "italic")
		ml.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(ml)
	if not D.best.is_empty():
		v.add_child(_section("Your rifts"))
		var keys: Array = D.best.keys()
		keys.reverse()
		var hl := ""
		for k in keys.slice(0, 5): hl += "%s   %d\n" % [k, int(D.best[k])]
		var hv := UIKit.label(hl.strip_edges(), 16, UIKit.DIM, true, "body")
		hv.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(hv)
	UIKit.foot(v).add_child(UIKit.button("Back", func(): act.emit(_daily_back, null), 50))

## Prophecies: three offers, each with three rewards to choose from; the active one can be abandoned.
func show_prophecies() -> void:
	var v := _open(1000)
	var P: Dictionary = Save.data.prophecy
	_title(v, "Prophecies", "Choose a fate and name your price. It holds until fulfilled within a single run.")
	if not P.active.is_empty():
		var A: Dictionary = Content.PROPHECIES[P.active.id]
		var al := UIKit.label("Active: %s. %s  Reward: %s" % [A.name, A.d, Content.PROPHECY_REWARDS[P.active.reward]], 18, Color("ffd27a"), true, "body")
		al.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(al)
		v.add_child(UIKit.button("Abandon it", func(): P.active = {}; P.offers = []; Save.mark_dirty(); show_prophecies(), 46))
	else:
		var portrait := get_viewport_rect().size.x < 820.0
		var row: BoxContainer = UIKit.vbox(10) if portrait else UIKit.hbox(14)
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		v.add_child(row)
		for off in Save.prophecy_offers():
			var id: String = off[0]
			var D: Dictionary = Content.PROPHECIES[id]
			var card := PanelContainer.new()
			card.add_theme_stylebox_override("panel", UIKit.nine("card", 46, Vector4(18, 20, 18, 20), Color("c9a25a")))
			card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			card.custom_minimum_size = Vector2(0 if portrait else 280, 0)
			var cv := UIKit.vbox(8)
			card.add_child(cv)
			var nm := UIKit.label(D.name, 23, UIKit.TEXT, true, "display")
			nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			cv.add_child(nm)
			var ds := UIKit.label(D.d, 17, Color("cfc5b0"), true, "body")
			ds.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			cv.add_child(ds)
			for rw in off[1]:
				var b := UIKit.button(Content.PROPHECY_REWARDS[rw], func():
					P.active = {"id": id, "reward": rw}
					P.offers = []
					Save.mark_dirty()
					Sfx.play("event")
					show_menu(), 44)
				cv.add_child(b)
			row.add_child(card)
	var dn := UIKit.label("Prophecies fulfilled: %d" % int(P.done), 15, UIKit.DIM, true, "italic")
	dn.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(dn)
	UIKit.foot(v).add_child(UIKit.button("Back", func(): act.emit("endgame", null), 50))

## Shown on launch after a session that ended without closing cleanly: the tail of its breadcrumb
## trail and the engine's errors. Copy report puts the whole report (Diag.report_text) on the clipboard.
func show_crash(lines: PackedStringArray) -> void:
	var v := _open(1100)
	_title(v, "The last session ended unexpectedly", "Tap Copy report and paste it into a message to us: it shows what the game was doing when it stopped.")
	if Quality.safe_fell_back:
		v.add_child(UIKit.label("The game now runs in OpenGL Safe Mode. Options > Graphics > Renderer switches back to Vulkan.", 16, Color("e0b85a"), true, "italic"))
	var t := UIKit.label("\n".join(lines), 12, Color("d8d0c0"), true, "body")
	t.add_theme_font_override("font", SystemFont.new())
	var sc := _scroll(t, "crash")
	sc.custom_minimum_size = Vector2(0, clampf(get_viewport_rect().size.y - 470.0, 160.0, 400.0))
	v.add_child(sc)
	var cr := _grid(2, 10)
	for b in [_copy_button("Copy report", func(): return Diag.report_text(), "Copied: paste it into a message", 50), UIKit.button("Continue", func(): show_menu(), 50)]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cr.add_child(b)
	UIKit.foot(v).add_child(cr)

## After a crash (or a background) during the self-test: what crashed, and resume.
func show_selftest_resume(st: Dictionary, crashed: bool) -> void:
	var v := _open(860)
	var f: String = st.bad[st.bad.size() - 1] if crashed and not st.bad.is_empty() else ""
	if crashed:
		_title(v, "Found one", "The game crashed while turning on: %s. It stays off. Continue the test to check the rest." % (Quality.FEATURE_NAMES.get(f, "the basic scene (foes, hero, ground)")))
	else:
		_title(v, "Self-test paused", "Continue where it stopped?")
	_selftest_rows(v, st)
	var row := _grid(2, 10)
	for pair in [["Continue the test", "selftest_resume"], ["Stop", "menu"]]:
		var b := UIKit.button(pair[0], func():
			if pair[1] == "menu":
				st.running = false
				Save.data.options.gfx_off = st.bad.filter(func(x): return x != "base")
				Quality.load_saved()
				Save.flush()
			act.emit(pair[1], null), 54)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)
	UIKit.foot(v).add_child(row)

func show_selftest(st: Dictionary) -> void:
	var v := _open(860)
	_title(v, "Self-test complete", ("Crashing features are switched off: " + ", ".join(st.bad.map(func(x): return Quality.FEATURE_NAMES.get(x, x)))) if not st.bad.is_empty() else "Nothing crashed. Tap Copy report and send it over.")
	_selftest_rows(v, st)
	var tip := UIKit.label("FPS after each feature is switched on (400 foes). Big drops show what is expensive on this phone.", 15, UIKit.DIM, true, "italic")
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(tip)
	var sr := _grid(2, 10)
	for b in [_copy_button("Copy report", func(): return Diag.report_text(), "Copied: paste it into a message", 54), UIKit.button("Back", func(): act.emit("menu", null), 54)]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sr.add_child(b)
	UIKit.foot(v).add_child(sr)

func _selftest_rows(outer: VBoxContainer, st: Dictionary) -> void:
	var v := UIKit.vbox(2)
	var sc := _scroll(v, "rows")
	sc.custom_minimum_size = Vector2(0, mini(36 * st.results.size(), int(get_viewport_rect().size.y * 0.5)))
	outer.add_child(sc)
	for r in st.results:
		var h := UIKit.hbox(12)
		var nm := "Basic scene" if r.f == "base" else "+ " + String(Quality.FEATURE_NAMES.get(r.f, r.f))
		var k := UIKit.label(nm, 17, UIKit.DIM, false, "body")
		k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(k)
		h.add_child(UIKit.label("CRASHED" if r.get("crash", false) else "%s FPS  %dk tris" % [r.fps, r.ktris], 17, Color("e0645a") if r.get("crash", false) else UIKit.TEXT, false, "body"))
		v.add_child(h)

## Benchmark result: big FPS figure, then the detail rows; Copy report puts them (and the device) on the clipboard.
func show_bench(r: Dictionary) -> void:
	var v := _open(760)
	_title(v, "Benchmark", "%s graphics  \u00b7  3D at %d%%  \u00b7  %s" % [r.tier, r.scale, r.res])
	var big := UIKit.label("%d FPS" % roundi(r.fps), 54, UIKit.GOLD, false, "num_heavy")
	big.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(big)
	var rows := [["Average frame", "%.1f ms" % r.ms], ["1% low", "%d FPS" % roundi(r.low1)], ["Foes on screen", str(r.foes)],
		["Draw calls", str(r.draws)], ["Triangles", "%dk" % r.ktris], ["Device", String(r.device)], ["GPU", String(r.gpu)], ["Renderer", String(r.renderer)]]
	for row in rows:
		var h := UIKit.hbox(12)
		var k := UIKit.label(row[0], 18, UIKit.DIM, false, "body")
		k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(k)
		h.add_child(UIKit.label(row[1], 18, UIKit.TEXT, false, "body"))
		v.add_child(h)
	var tip := UIKit.label("Tap Copy report and send it over. To compare, change Options > Graphics > Graphics tier or 3D scale and run it again.", 15, UIKit.DIM, true, "italic")
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(tip)
	var row2 := _grid(3, 10)
	var cb := _copy_button("Copy report", func(): return Diag.report_text(), "Copied", 54)
	cb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row2.add_child(cb)
	for pair in [["Run again", "bench"], ["Back", "menu"]]:
		var b := UIKit.button(pair[0], func(): act.emit(pair[1], null), 54)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row2.add_child(b)
	UIKit.foot(v).add_child(row2)

## A button that puts text on the clipboard and says so on itself.
func _copy_button(label: String, text_fn: Callable, done: String, h: int) -> Button:
	var b := UIKit.button(label, func(): pass, h)
	b.pressed.connect(func():
		DisplayServer.clipboard_set(String(text_fn.call()))
		b.text = done)
	return b

## Paste save: what is on the clipboard, checked before anything changes; Replace keeps the old profile in a
## backup file beside the new one.
func show_paste_save(back: String) -> void:
	var v := _open(760)
	var txt := DisplayServer.clipboard_get()
	var got = Save.decode_save(txt)
	if typeof(got) == TYPE_STRING:
		_title(v, "Paste save", String(got) if txt.strip_edges() != "" else "Nothing on the clipboard. Copy the save text first, then come back here.")
		UIKit.foot(v).add_child(UIKit.button("Back", func(): show_options(back), 50))
		return
	_title(v, "Replace your progress?", "The pasted save has %d gold and %d items in the stash. Your current progress (%d gold) is replaced; a backup of it stays on this phone." % [int(got.get("gold", 0)), (got.get("stash", []) as Array).size(), int(Save.data.gold)])
	var row := _grid(2, 10)
	var rep := UIKit.button("Replace", func():
		var err := Save.import_text(txt)
		Quality.load_saved()
		act.emit("options_changed", null)
		show_paste_done(err, back), 54)
	var cancel := UIKit.button("Cancel", func(): show_options(back), 54)
	for b in [rep, cancel]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)
	UIKit.foot(v).add_child(row)

func show_paste_done(err: String, back: String) -> void:
	var v := _open(760)
	_title(v, "Save restored" if err == "" else "Paste save", "Your progress is back." if err == "" else err)
	UIKit.foot(v).add_child(UIKit.button("Back", func(): show_options(back), 50))

## One option row: name on the left in Garamond, its value as a bronze button on the right.
func _opt_row(v: VBoxContainer, label: String, value: String, cb: Callable, on: bool = true) -> void:
	var h := UIKit.hbox(12)
	var l := UIKit.label(label, 19, UIKit.TEXT, true)        # wraps: unwrapped, a long label pushed the value off a narrow screen
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(l)
	var b := UIKit.button(value, cb, 48)
	b.custom_minimum_size.x = 230
	b.add_theme_font_size_override("font_size", 19)
	b.add_theme_color_override("font_color", UIKit.GOLD if on else UIKit.DIM)
	h.add_child(b)
	v.add_child(h)

func _toggle(v: VBoxContainer, label: String, key: String, back: String) -> void:
	var on := bool(Save.opt(key))
	_opt_row(v, label, "On" if on else "Off", func(): Save.set_opt(key, not on); act.emit("options_changed", null); show_options(back), on)

func _cycle(v: VBoxContainer, label: String, key: String, names: Array, back: String) -> void:
	var cur := int(Save.opt(key))
	_opt_row(v, label, names[cur % names.size()], func(): Save.set_opt(key, (cur + 1) % names.size()); act.emit("options_changed", null); show_options(back))

func _slider(v: VBoxContainer, label: String, key: String, lo: float, hi: float, _back_s: String) -> void:
	var h := UIKit.hbox(12)
	var l := UIKit.label("%s  %d%%" % [label, int(float(Save.opt(key)) * 100)], 19)
	l.custom_minimum_size = Vector2(250, 0)
	h.add_child(l)
	var s := HSlider.new()
	s.min_value = lo; s.max_value = hi; s.step = 0.05
	s.value = float(Save.opt(key))
	s.custom_minimum_size = Vector2(0, 48)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.value_changed.connect(func(x: float):
		Save.set_opt(key, x)                          # Master and Voice: Save.apply_audio sets their buses
		l.text = "%s  %d%%" % [label, int(x * 100)]
		if key == "music_volume" or key == "sfx_volume": act.emit("audio_changed", null))
	h.add_child(s)
	v.add_child(h)

# ================================================================= in-run overlays
## The cards are dealt in one after another (each fades in from 0.08 s, 0.07 s apart), so they are built one a
## frame, the arsenal last: the screen cost 5-7 ms in one frame on a desktop, inside the tick that levelled up
## (O7). Each card's fade still starts when it always did. Another screen, or the next level-up, stops the rest.
var _lv_token := 0
func show_levelup(w: World) -> void:
	var v := _open(1180)
	_lv_token += 1
	var my := _lv_token
	var t0 := Time.get_ticks_msec()
	var portrait := get_viewport_rect().size.x < 820.0
	_title(v, "Level %d" % w.lvl, "The rift offers a gift. Choose one.")
	if main != null and main.coach != null and main.coach.w == w and Coach.wants(Save.data, Coach.LEVELUP):
		var tip := UIKit.label("Captain Brask: \u201cPick one. A new weapon (up to four), a level for one you carry, a perk or a gem: they all stack. A weapon at level 5 evolves with the perk its card names.\u201d", 16, Color("cfe8c0"), true, "italic")
		tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(tip)
	var choices := w.make_choices()
	_choices = choices
	var row: BoxContainer = UIKit.vbox(10) if portrait else UIKit.hbox(16)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(row)
	for i in choices.size():
		if i > 0:
			await get_tree().process_frame
			if my != _lv_token or not is_instance_valid(row) or not row.is_inside_tree(): return
		var card := _choice_card(w, choices[i], i, portrait, _side_card_w(choices.size()))
		row.add_child(card)
		card.modulate.a = 0.0
		var tw := card.create_tween()
		tw.tween_interval(maxf(0.0, 0.08 + 0.07 * i - (Time.get_ticks_msec() - t0) / 1000.0))
		tw.tween_property(card, "modulate:a", 1.0, 0.18)
	await get_tree().process_frame
	if my != _lv_token or not is_instance_valid(v) or not v.is_inside_tree(): return
	# weapon + gem overview so links are visible while choosing
	v.add_child(_section("Your arsenal"))
	var o := ""
	for id in w.weapons:
		var wd: Dictionary = w.weapons[id]
		var tr := w.temper_rank(id)
		o += "%s %s%d%s   %s\n" % [Content.WEAPONS[id].name, ("Fused " if wd.get("fuse", "") != "" else ("Evolved " if wd.evo else "Lv ")), wd.lv, ("  \u00b7  " + Camp.RANK_NAME[tr]) if tr > 0 else "", ("Linked: " + ", ".join(wd.gems.map(func(g): return Content.GEMS[g].name))) if not wd.gems.is_empty() else "no links"]
	var al := UIKit.label(o.strip_edges(), 16, UIKit.DIM, true, "italic")
	al.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(al)

## An ornate card: silver frame tinted by the reward type, a gem, small-caps tag, carved name, lore-face description.
## The cards' frames hold their text at the 18-unit floor (tests: _frame_fit_tests). Upright a tag, a name, the rule and a
## line of description need 116 units inside the card's 26 / 24 insets: 150 left 100, so the text sat on the frame; the
## card is CARD_UP_H. Held sideways three cards share the sheet's width (up to CARD_SIDE_W each, four: about 262; they
## were 260 and a fusion's or a keystone's text overran by up to 80). A card whose text still needs more grows to it.
const CARD_UP_H := 170
const CARD_SIDE_H := 296
const CARD_SIDE_W := 320
const CARD_INSETS := Vector4(22, 26, 22, 24)          # left, top, right, bottom: clear of the card's ornaments

## Held sideways: the width of each of `n` level-up cards in a row inside the sheet (UIKit.sheet: at most 1180 wide, a
## 34-unit margin each side, room for the scroll bar), at least 260 and at most CARD_SIDE_W.
func _side_card_w(n: int) -> float:
	var room := minf(1180.0, get_viewport_rect().size.x - 28.0) - 68.0 - 16.0
	return clampf((room - 16.0 * float(maxi(1, n) - 1)) / float(maxi(1, n)), 260.0, float(CARD_SIDE_W))

func _choice_card(w: World, c: Dictionary, idx: int, portrait: bool, side_w: float = CARD_SIDE_W) -> Button:
	var tx := w.choice_text(c)
	var col := Content.col(tx.col)
	if col.s < 0.15: col = Color("d8b878")              # plain perks: aged gold instead of white
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, CARD_UP_H) if portrait else Vector2(side_w, CARD_SIDE_H)
	if portrait: b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var frame := Color(0.78, 0.76, 0.74).lerp(col, 0.45)
	var pad := Vector4(20, 22, 20, 22)
	b.add_theme_stylebox_override("normal", UIKit.nine("card", 46, pad, frame))
	b.add_theme_stylebox_override("hover", UIKit.nine("card", 46, pad, frame.lightened(0.35)))
	b.add_theme_stylebox_override("pressed", UIKit.nine("card", 46, pad, Color("f2c76a")))
	b.add_theme_stylebox_override("focus", UIKit.nine("card", 46, pad, frame.lightened(0.2)))
	b.pressed.connect(func(): act.emit("pick", c))
	UIKit.press_fx(b)
	var v := UIKit.vbox(4 if portrait else 6)              # upright: no rule under the name, so two lines of text fit 170
	v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	v.offset_left = CARD_INSETS.x; v.offset_right = -CARD_INSETS.z; v.offset_top = CARD_INSETS.y; v.offset_bottom = -CARD_INSETS.w
	v.alignment = BoxContainer.ALIGNMENT_BEGIN if not portrait else BoxContainer.ALIGNMENT_CENTER
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(v)
	var base_h := float(CARD_UP_H if portrait else CARD_SIDE_H)
	v.minimum_size_changed.connect(func():              # the text wraps to the card's width: the frame grows to hold it
		if is_instance_valid(b): b.custom_minimum_size.y = maxf(base_h, v.get_combined_minimum_size().y + CARD_INSETS.y + CARD_INSETS.w))
	if not portrait:
		var gem := Gem.new()
		gem.col = col
		gem.kind = String(c.kind)
		gem.custom_minimum_size = Vector2(0, 64)
		v.add_child(gem)
	var tag := UIKit.label(String(tx.tag).to_upper(), 13, col.lerp(UIKit.TEXT, 0.25), true, "display")
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(tag)
	var nm := UIKit.label(String(tx.name), 23, UIKit.TEXT, true, "display")
	nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(nm)
	if not portrait:
		var dv := UIKit.divider()
		dv.custom_minimum_size = Vector2(0, 16)
		v.add_child(dv)
	var ds := UIKit.label(String(tx.d), 17, Color("cfc5b0"), true, "body")
	ds.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(ds)
	if not portrait and not UIKit.is_touch():
		var sp := Control.new()
		sp.size_flags_vertical = Control.SIZE_EXPAND_FILL
		v.add_child(sp)
		var key := UIKit.label(str(idx + 1), 16, UIKit.DIM, false, "num")
		key.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(key)
	for n in v.get_children(): (n as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	return b

## Pause (the HUD's pause button, Back or Esc): Resume, Build & Stats, Gear, Options, Restart
## Run and Main Menu (both confirmed first). Back from any page opened here returns here (main.back()).
func show_pause(w: World) -> void:
	var v := _open(700)
	page = "pause"
	_title(v, "Paused", "%s - %s" % [Content.HEROES[w.hero].name, (Story.act(w.stage).title if w.mode == "campaign" else w.mode.capitalize())])
	v.add_child(UIKit.button("Resume", func(): act.emit("resume", null)))
	var row := _grid(3, 8)                           # the three pages on one row, Restart and Main Menu under them
	for e in [["Build & Stats", func(): show_build(w)], ["Gear", func(): show_stash(true)], ["Options", func(): show_options("resume_pause")]]:
		var b := UIKit.button(e[0], e[1], 54)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)
	v.add_child(row)
	var row2 := _grid(2, 8)
	var rb := UIKit.button("Restart Run", func(): confirm("Restart this run?", "You keep the gold and Echoes it has earned so far, and start the same run again.", "Restart", "restart"), 54)
	var mb := UIKit.button("Main Menu", func(): confirm("Leave this run?", "You keep the gold and Echoes it has earned so far. The run itself ends here.", "Leave", "leave"), 54)
	for b2 in [rb, mb]:
		b2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row2.add_child(b2)
	v.add_child(row2)
	var ctext := contagion_line(w)
	if ctext != "":                                  # made only when shown: a label outside the tree is never freed
		var cl := UIKit.label(ctext, 16, Color("ffa15a"), true, "italic")
		cl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(cl)

## Pause > Build & Stats: the weapons and their links, the perks, and how the run is going (and the
## Emberwitch's contagion, the Warden's vaults, the Sparkcaller's ricochets, the Stormwright's conductions).
func show_build(w: World) -> void:
	var v := _open(820)
	_title(v, "Build & Stats", "%s  \u00b7  level %d" % [Content.HEROES[w.hero].name, w.lvl])
	v.add_child(_section("Your build"))
	var build := ""
	for id in w.weapons:
		var wd: Dictionary = w.weapons[id]
		build += "%s  %s%d%s\n" % [Content.WEAPONS[id].name, ("Fused " if wd.get("fuse", "") != "" else ("Evolved " if wd.evo else "Lv ")), wd.lv,
			("  \u00b7  " + ", ".join(wd.gems.map(func(g): return Content.GEMS[g].name))) if not wd.gems.is_empty() else ""]
	var perks := []
	for id in w.perks: perks.append("%s %d" % [Content.PERKS[id].name, w.perks[id]])
	if not perks.is_empty(): build += "  \u00b7  ".join(perks)
	var bl := UIKit.label(build.strip_edges(), 16, UIKit.TEXT, true, "body")
	bl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(bl)
	v.add_child(_section("This run"))
	var m := w.metrics
	var lines := ["Time %s  \u00b7  %d slain  \u00b7  best streak %d" % [Hud._fmt(w.t), w.kills, w.best_combo],
		"Damage dealt %d  \u00b7  taken %d  \u00b7  %d reactions" % [int(m.get("dmg_dealt", 0.0)), int(m.get("dmg_taken", 0.0)), int(m.get("reactions", 0))]]
	var syn := {"warden": ["warden_vaults", "vault slams"], "spark": ["spark_ricochets", "ricochets"], "storm": ["storm_conducts", "conductions"]}
	if syn.has(w.hero_id): lines.append("%d %s" % [int(m.get(syn[w.hero_id][0], 0)), syn[w.hero_id][1]])
	if int(m.get("echoes", 0)) > 0: lines.append("%d Rift Memor%s heard" % [int(m.echoes), "y" if int(m.echoes) == 1 else "ies"])
	var cl := contagion_line(w)
	if cl != "": lines.append(cl)
	for ln in lines:
		var l := UIKit.label(ln, 16, Color("cfc5b0"), true, "italic")
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(l)
	UIKit.foot(v).add_child(UIKit.button("Back", func(): show_pause(w), 52))

## A yes/no question over the current page (Restart Run, Main Menu): `what` goes to main as an action on yes;
## no (or Back) returns to the pause menu.
func confirm(title: String, body: String, yes_txt: String, what: String) -> void:
	var v := _open(620)
	page = "confirm"
	_title(v, title, body)
	var row := _grid(2, 10)
	var yes := UIKit.button(yes_txt, func(): act.emit(what, null), 56)
	var no := UIKit.button("Cancel", func(): act.emit("resume_pause", null), 56)
	for b in [no, yes]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)
	v.add_child(row)

## The Emberwitch's contagion so far this run (World.metrics), for the pause menu; empty for other heroes.
static func contagion_line(w: World) -> String:
	if w.contagion == null or not w.contagion.on: return ""
	var m := w.metrics
	return "Contagion: %d ignited  \u00b7  %d spread  \u00b7  %d conflagrations  \u00b7  %d trees alight" % [
		int(m.get("ember_ignitions", 0)), int(m.get("ember_spreads", 0)), int(m.get("ember_conflagrations", 0)), int(m.get("ember_beacons", 0))]

## The real sky: tonight's Moon (drawn to its true phase) and any calendar omen, with what they change.
func _sky_row() -> HBoxContainer:
	var ph := Moon.now()
	var md := Moon.today()
	var row := UIKit.hbox(10)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	var disc := MoonDisc.new()
	disc.phase = ph
	disc.custom_minimum_size = Vector2(34, 34)
	row.add_child(disc)
	var tv := UIKit.vbox(0)
	tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var P: Dictionary = Moon.PHASES[Moon.phase_id(ph)]
	tv.add_child(UIKit.label("%s  \u00b7  %d%% LIT" % [Moon.phase_name(ph).to_upper(), roundi(Moon.illumination(ph) * 100.0)], 14, Color("d8dcef"), false, "label"))
	tv.add_child(UIKit.label(String(P.d), 15, Color("a9aec4"), true, "italic"))
	var o := Moon.omen_id(md)
	if o != "":
		tv.add_child(UIKit.label("%s: %s" % [Moon.OMENS[o].name, Moon.OMENS[o].d], 15, Color("c9a2ff"), true, "italic"))
	row.add_child(tv)
	return row

## The Whisperer's offer: two bargains, each a boon and its price, or walk away.
func show_whisper(w: World) -> void:
	var v := _open(900)
	var portrait := get_viewport_rect().size.x < 820.0
	var tl := UIKit.title("The Whisperer", 40)
	(tl.get_child(0) as Label).add_theme_color_override("font_color", Color("b48aff"))
	v.add_child(tl)
	var q := UIKit.label("\u201cEvery gift has a price, exile. Choose one, or walk on and wonder.\u201d", 18, Color("b9aed6"), true, "italic")
	q.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(q)
	var row: BoxContainer = UIKit.vbox(10) if portrait else UIKit.hbox(16)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(row)
	for id in w.whisper_offer:
		var B: Dictionary = Content.WHISPERS[id]
		var b := Button.new()
		b.custom_minimum_size = Vector2(0, 170) if portrait else Vector2(330, 250)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var frame := Color("8a6bd0")
		var pad := Vector4(20, 22, 20, 22)
		b.add_theme_stylebox_override("normal", UIKit.nine("card", 46, pad, frame))
		b.add_theme_stylebox_override("hover", UIKit.nine("card", 46, pad, frame.lightened(0.35)))
		b.add_theme_stylebox_override("pressed", UIKit.nine("card", 46, pad, Color("d9c2ff")))
		b.add_theme_stylebox_override("focus", UIKit.nine("card", 46, pad, frame.lightened(0.2)))
		b.pressed.connect(func(): act.emit("bargain", id))
		var cv := UIKit.vbox(8)
		cv.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		cv.offset_left = 24; cv.offset_right = -24; cv.offset_top = 26; cv.offset_bottom = -24
		cv.alignment = BoxContainer.ALIGNMENT_CENTER
		b.add_child(cv)
		var nm := UIKit.label(String(B.name), 25, UIKit.TEXT, true, "display")
		nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cv.add_child(nm)
		var dv := UIKit.divider()
		dv.custom_minimum_size = Vector2(0, 14)
		cv.add_child(dv)
		var bl := UIKit.label(String(B.boon), 19, UIKit.GOLD, true, "body")
		bl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cv.add_child(bl)
		var cl := UIKit.label("but " + String(B.cost).substr(0, 1).to_lower() + String(B.cost).substr(1), 17, Color("e0645a"), true, "italic")
		cl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cv.add_child(cl)
		for n in cv.get_children(): (n as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
		cv.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(b)
	if not w.bargains.is_empty():
		var ml := UIKit.label("Already bound: " + ", ".join(w.bargains.map(func(x): return Content.WHISPERS[x].name)), 15, UIKit.DIM, true, "italic")
		ml.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(ml)
	var note := UIKit.label("Each bargain lasts the run, marks it, and pays +1 Echo at its end.", 15, UIKit.DIM, true, "italic")
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(note)
	v.add_child(UIKit.button("Refuse and walk on", func(): act.emit("bargain", ""), 54))

## The end of a run. What the run brought home comes first (Gold, Echoes, Rift Ore, Items; a Daily Rift's score), then
## Time, Slain and Level, and one line for the rest. The review found twelve equal tiles in the run's order: held
## sideways on an S22 the rewards and Brask's only tip sat below the fold, and a win offered Play again (the same act)
## with no way on: a campaign win with the next act open now leads with "Next: Act <N>".
func show_end(w: World) -> void:
	var v := _open(820)
	var won: bool = w.won
	var portrait := get_viewport_rect().size.x < 820.0
	var tl := UIKit.title("Victory" if won else "You have fallen", 44)
	(tl.get_child(0) as Label).add_theme_color_override("font_color", UIKit.GOLD if won else Color("d23a34"))
	v.add_child(tl)
	var sub := ""
	if not won and w.killer != "": sub = "Slain by " + w.killer
	elif won: sub = "The rift is sealed, for now."
	else: sub = "The rift claims another exile."
	var sl := UIKit.label(sub, 19, UIKit.DIM, true, "italic")
	sl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(sl)
	# what the run opened, under the subtitle: the new weapons sat below the fold at an S22's scale, and a first clear of
	# Act I (Act II, the Daily Rift, the Atlas, Greater Rifts, Torment I) was not named at all
	var opened: Array = w.new_unlocks.map(func(x): return String(Content.WEAPONS[x].name))
	if not opened.is_empty(): opened[opened.size() - 1] = String(opened[opened.size() - 1]) + " (at level-ups)"
	for o in w.opened: opened.append(String(o) + (" (Modes)" if String(o).begins_with("Torment") else ""))
	if not opened.is_empty():
		var ul := UIKit.label("Unlocked: " + ", ".join(opened), 18, UIKit.GOLD, true, "display")
		ul.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ul.set_meta("unlocked", true)
		v.add_child(ul)
	if not bool(Save.data.get("camp_seen", false)) and not w.daily:      # a new exile: point them to the Camp
		var tip := UIKit.label("Captain Brask: \u201c%s\u201d" % String(CampPages.next_station(Save.data)[1]), 17, Color("cfe8c0"), true, "italic")
		tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(tip)
	var rows: Array = []
	if w.daily: rows.append(["Rift score" + ("  NEW BEST" if w.daily_best else ""), str(w.daily_score)])
	rows.append_array([["Gold", str(int(w.gold))], ["Echoes", "+%d" % w.echoes_run]])
	if not w.daily: rows.append(["Rift Ore", "+%d" % w.ore_run])
	rows.append(["Items", str(w.loot_run.size())])
	rows.append_array([["Time", Hud._fmt(w.t)], ["Slain", str(w.kills)], ["Level", str(w.lvl)]])
	var rest: Array = [["Best combo", str(w.best_combo)], ["Champions", str(w.champions_slain)], ["Reactions", str(w.metrics.reactions)],
		["Perfect dodges", str(w.metrics.perfect)], ["Lore pages", str(w.lore_run.size())]]
	if w.mode == "rift": rows.append(["Rift progress", "%d%%" % int(w.progress)])
	elif w.hoard_lost > 0.0: rows.append(["Hoard lost", str(int(w.hoard_lost))])         # it teaches the Rift Gate
	elif w.hoard_banked > 0.0: rows.append(["Hoard banked", str(int(w.hoard_banked))])
	if w.hoard_banked > 0.0 and (w.mode == "rift" or w.hoard_lost > 0.0): rest.append(["Hoard banked", str(int(w.hoard_banked))])
	if w.hoard_lost > 0.0 and w.mode == "rift": rest.append(["Hoard lost", str(int(w.hoard_lost))])
	if w.salvaged_run > 0: rest.append(["Salvaged on the way", "%d (+%d scrap)" % [w.salvaged_run, w.salvaged_scrap]])
	if w.torment > 0: rest.append(["Difficulty", String(Content.TORMENT[w.torment].name)])
	var g := _grid(2 if portrait else 4, 10)
	for r in rows:
		var pv := UIKit.vbox(0)
		pv.alignment = BoxContainer.ALIGNMENT_CENTER
		var val := UIKit.label(r[1], 30, Color("f4e2b8"), false, "num_heavy")
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		pv.add_child(val)
		var key := UIKit.label(String(r[0]).to_upper(), 13, Color("b89a6a"), false, "label")
		key.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		pv.add_child(key)
		var pc := PanelContainer.new()
		pc.add_theme_stylebox_override("panel", UIKit.nine("tile", 24, Vector4(12, 10, 12, 10), Color(0.7, 0.62, 0.52)))
		pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pc.add_child(pv)
		g.add_child(pc)
	v.add_child(g)
	var rl := UIKit.label("   \u00b7   ".join(rest.map(func(r): return "%s %s" % [r[0], r[1]])), 17, UIKit.DIM, true, "italic")
	rl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(rl)
	if not w.bargains.is_empty():
		v.add_child(_section("Marked by the Whisperer"))
		var wl := UIKit.label(", ".join(w.bargains.map(func(x): return Content.WHISPERS[x].name)), 18, Color("c9a2ff"), true, "display")
		wl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(wl)
	var ev := ""
	for e in w.director.history: ev += Content.EVENTS[e[1]].name + ", "
	if ev != "":
		v.add_child(_section("Happenings"))
		var el := UIKit.label(ev.trim_suffix(", "), 17, Color("d9c7ff"), true, "italic")
		el.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(el)
	var best := ""
	for it in w.loot_run:
		if int(it.rarity) >= Content.Rarity.RARE: best += Items.name_of(it) + ", "
	if best != "":
		v.add_child(_section("Notable loot"))
		var bl := UIKit.label(best.trim_suffix(", "), 17, UIKit.GOLD, true, "display")
		bl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(bl)
	var acts: Array = [["Play again", "retry"], ["Camp", "camp"], ["Main menu", "menu"]]
	var nxt := next_act(w)
	if nxt >= 0: acts.push_front(["Next: Act %s" % ROMAN[nxt], "campaign"])
	var row := _grid(acts.size() if not portrait else 2, 10)
	for pair in acts:
		var arg: Variant = nxt if pair[1] == "campaign" else null
		var bt := UIKit.button(pair[0], func(): act.emit(pair[1], arg), 58)
		bt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(bt)
	UIKit.foot(v).add_child(row)

## The act a campaign win opens next (-1: not a campaign win, the last act, or the next one still sealed).
static func next_act(w: World) -> int:
	if not w.won or w.mode != "campaign" or w.daily or w.stage + 1 >= Content.STAGES.size(): return -1
	var cl: Array = Save.data.cleared
	return w.stage + 1 if w.stage < cl.size() and bool(cl[w.stage]) else -1

## "What's new" (WhatsNew): once after an update, from the title; Captain Brask's page rereads it (all=true).
func show_whats_new(all: bool = false) -> void:
	var v := _open(860)
	var ver := Diag.version()
	_title(v, "What's new", "Alpha " + ver.split("-")[0])
	var seen := "" if all else String(Save.data.get("seen_version", ""))
	for e in WhatsNew.since(seen if seen != "" else ("0.0.0" if all else "0.10.6")):
		v.add_child(_section("Alpha " + String(e[0])))
		for n in e[1]:
			var h := UIKit.vbox(0)
			h.add_child(UIKit.label(String(n[0]), 20, UIKit.GOLD, false, "display"))
			h.add_child(UIKit.label(String(n[1]), 16, UIKit.TEXT, true, "italic"))
			v.add_child(h)
	Save.data.seen_version = ver
	Save.mark_dirty()
	UIKit.foot(v).add_child(UIKit.button("Continue", func(): act.emit("camp" if parent_page == "camp" else "menu", null)))

## The Wayside Forge (a friendly NPC met in a run): Doran's apprentice hones each weapon you carry once, a temper rank
## for this run, for run gold (World.hone_weapon). Leave resumes the run.
func show_forge(w: World) -> void:
	var v := _open(820)
	var h := UIKit.hbox(14)
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	var md := CampPages.Medallion.new(Content.col(Content.EVENTS.forge.col), "A", 62.0)
	md.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(md)
	var t := UIKit.vbox(0)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.add_child(UIKit.label("Wayside Forge", 30, Color("ffb98a"), false, "display"))
	t.add_child(UIKit.label("\u201cMaster Doran taught me. Hand it over, I will be quick.\u201d  Ash, his apprentice", 16, UIKit.DIM, true, "italic"))
	h.add_child(t)
	v.add_child(h)
	var ev := w.director.forge()
	var sub := UIKit.label("Hone a weapon for this run: one temper rank each, once here. You have %d gold." % int(w.gold), 16, UIKit.TEXT, true, "italic")
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(sub)
	if _craft_msg != "":
		var ml := UIKit.label(_craft_msg, 16, Color("ffcf9a"), true, "italic")
		ml.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(ml)
		_craft_msg = ""
	for id in w.weapons:
		var W: Dictionary = Content.WEAPONS[id]
		var r := w.temper_rank(id)
		var row := UIKit.hbox(12)
		var l := UIKit.vbox(0)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.add_child(UIKit.label(String(W.name), 20, Content.col(W.col).lightened(0.15), false, "display"))
		l.add_child(UIKit.label("%s  \u00b7  %s" % [Camp.RANK_NAME[r], Camp.temper_text(r)], 14, UIKit.DIM, true, "italic"))
		row.add_child(l)
		var done: bool = not ev.is_empty() and (ev.honed as Array).has(id)
		var c := w.hone_cost(id)
		var b := UIKit.button("Honed" if done else ("Masterwork" if r >= Camp.TEMPER_MAX else "Hone  \u00b7  %d gold" % c), func():
			var e := w.hone_weapon(id)
			_craft_msg = ("%s is %s for this run." % [W.name, Camp.RANK_NAME[w.temper_rank(id)]]) if e == "" else e
			if e == "": Sfx.play("craft")
			show_forge(w), 50)
		b.custom_minimum_size.x = 220
		b.disabled = done or r >= Camp.TEMPER_MAX or int(w.gold) < c or ev.is_empty()
		row.add_child(b)
		v.add_child(row)
	UIKit.foot(v).add_child(UIKit.button("Leave", func(): act.emit("resume", null)))

func show_merchant(w: World) -> void:
	var v := _open(700)
	_title(v, "Wandering Merchant", "Gamble %d gold for an unidentified item. You have %d." % [Director.GAMBLE_COST, int(w.gold)])
	for s in Content.SLOTS:
		var b := UIKit.button("Gamble a " + Content.SLOT_NAME[s], func():
			var it: Dictionary = w.director.gamble(s)
			if not it.is_empty(): Sfx.play("craft")
			show_merchant(w), 56)
		b.disabled = w.gold < Director.GAMBLE_COST
		v.add_child(b)
	v.add_child(UIKit.button("Leave", func(): act.emit("resume", null)))


## The Shard Web drawn as a constellation: links, then nodes (taken bright, takeable pulsing, the rest dim).
class WebView extends Control:
	signal picked(id: String)
	var taken: Array = []
	var selected := ""
	var font: Font
	static func branch_col(id: String) -> Color:
		match id.substr(0, 1):
			"m": return Color("e0623a")
			"a": return Color("9a86ff")
			"f": return Color("6fc46a")
			"o": return Color("e8b54e")
		return Color("e8b54e")
	func _ready() -> void:
		font = UIKit.font("display")
	func _pos(id: String) -> Vector2:
		var P: Dictionary = Content.PASSIVES[id]
		return size * 0.5 + Vector2(float(P.x) * (size.x * 0.5 - 70.0), float(P.y) * (size.y * 0.5 - 44.0))
	func _process(_dt: float) -> void:
		queue_redraw()
	func _draw() -> void:
		var t := Time.get_ticks_msec() * 0.001
		for id in Content.PASSIVES:
			for l in Content.PASSIVES[id].links:
				var both: bool = taken.has(id) and taken.has(l)
				var col := branch_col(l if id == "start" else id)
				draw_line(_pos(id), _pos(l), Color(0, 0, 0, 0.7), 6.0, true)
				draw_line(_pos(id), _pos(l), col if both else Color(0.35, 0.32, 0.33, 0.6), 3.0 if both else 1.5, true)
		for id in Content.PASSIVES:
			var P: Dictionary = Content.PASSIVES[id]
			var p := _pos(id)
			var r := _radius(String(P.kind))
			var col := branch_col(id)
			var own := taken.has(id)
			var can := Content.passive_can_take(id, taken)
			draw_circle(p, r + 3.0, Color(0, 0, 0, 0.8))
			if P.kind == "keystone":
				var pts := PackedVector2Array()
				for k in 9: pts.append(p + Vector2.from_angle(TAU * k / 8.0 + PI / 8.0) * r)
				draw_colored_polygon(pts, col.darkened(0.2) if own else Color(0.12, 0.11, 0.12))
				draw_polyline(pts, col if (own or can) else Color(0.35, 0.33, 0.33), 2.5, true)
			else:
				draw_circle(p, r, col.darkened(0.15) if own else Color(0.12, 0.11, 0.12))
				draw_arc(p, r, 0, TAU, 32, col if (own or can) else Color(0.35, 0.33, 0.33), 2.5 if P.kind != "minor" else 1.6, true)
			if own: draw_circle(p + Vector2(-r * 0.3, -r * 0.3), r * 0.3, Color(1, 1, 1, 0.25))
			if can and not own:
				draw_arc(p, r + 5.0 + sin(t * 4.0) * 1.5, 0, TAU, 32, Color(col, 0.7), 1.5, true)
			if id == selected:
				draw_arc(p, r + 8.0, 0, TAU, 40, Color.WHITE, 2.0, true)
		var lay := label_layout()
		for id in lay:
			var nm := String(Content.PASSIVES[id].name)
			var tp: Vector2 = (lay[id] as Rect2).position + Vector2(0, font.get_ascent(LABEL_FS))
			draw_string_outline(font, tp, nm, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FS, 4, Color(0, 0, 0, 0.9))
			draw_string(font, tp, nm, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FS, branch_col(id).lightened(0.3) if taken.has(id) else Color(0.7, 0.66, 0.6))

	const LABEL_FS := 18
	static func _radius(kind: String) -> float:
		return {"start": 15.0, "minor": 9.0, "notable": 15.0, "keystone": 20.0}.get(kind, 9.0)

	## Where each notable's and keystone's name goes (id -> its rectangle): above or below a node on the side arms,
	## right or left of one on the upright arms, the first spot that overlaps no name placed before it, moved inside
	## the view. On the side arms a notable and its keystone sit closer than their names are wide, so one of the two
	## goes below.
	func label_layout() -> Dictionary:
		if font == null: font = UIKit.font("display")
		var out := {}
		var placed: Array = []
		var bounds := Rect2(Vector2(2, 2), size - Vector2(4, 4))
		for id in Content.PASSIVES:
			var P: Dictionary = Content.PASSIVES[id]
			if P.kind != "notable" and P.kind != "keystone": continue
			var ts := font.get_string_size(String(P.name), HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FS)
			var p := _pos(id)
			var r := _radius(String(P.kind))
			var above := Rect2(p + Vector2(-ts.x * 0.5, -r - 9.0 - ts.y), ts)
			var below := Rect2(p + Vector2(-ts.x * 0.5, r + 9.0), ts)
			var right := Rect2(p + Vector2(r + 10.0, -ts.y * 0.5), ts)
			var left := Rect2(p + Vector2(-r - 10.0 - ts.x, -ts.y * 0.5), ts)
			var tries := [above, below, right, left] if absf(float(P.y)) < 0.05 else [right, left, above, below]
			var pick := _inside(tries[0], bounds)
			for c in tries:
				var cc := _inside(c, bounds)
				if placed.all(func(q): return not (q as Rect2).intersects(cc)):
					pick = cc
					break
			placed.append(pick)
			out[id] = pick
		return out

	static func _inside(r: Rect2, b: Rect2) -> Rect2:
		return Rect2(Vector2(clampf(r.position.x, b.position.x, maxf(b.position.x, b.end.x - r.size.x)),
			clampf(r.position.y, b.position.y, maxf(b.position.y, b.end.y - r.size.y))), r.size)
	func _gui_input(ev: InputEvent) -> void:
		if (ev is InputEventMouseButton and ev.pressed) or (ev is InputEventScreenTouch and ev.pressed):
			var best := ""
			var bd := 30.0
			for id in Content.PASSIVES:
				var dd := _pos(id).distance_to(ev.position)
				if dd < bd: bd = dd; best = id
			if best != "":
				picked.emit(best)
				accept_event()

## A faceted gem drawn for a level-up card: diamond for weapons, star for evolutions, round for perks,
## hexagon for gems, a split keystone for keystones.
class Gem extends Control:
	var col := Color.WHITE
	var kind := "p"
	func _draw() -> void:
		var c := size / 2.0
		var r := minf(size.x, size.y) * 0.42
		draw_circle(c, r * 1.25, Color(col.r, col.g, col.b, 0.12))
		draw_circle(c, r * 0.95, Color(col.r, col.g, col.b, 0.16))
		var n := {"w": 4, "e": 8, "fuse": 12, "p": 24, "g": 6, "key": 5}.get(kind, 24) as int
		var pts := PackedVector2Array()
		for i in n:
			var a := -PI / 2.0 + TAU * float(i) / float(n)
			var rr := r if (kind != "e" and kind != "fuse") or i % 2 == 0 else r * (0.55 if kind == "e" else 0.7)
			pts.append(c + Vector2(cos(a), sin(a)) * rr * (0.82 if kind == "p" else 1.0))
		draw_colored_polygon(pts, col.darkened(0.45))
		# facets: light from the top-left
		for i in n:
			var a2 := pts[i]; var b2 := pts[(i + 1) % n]
			var m := (a2 + b2) * 0.5 - c
			var lit := clampf(0.5 - m.normalized().dot(Vector2(0.6, 0.8)) * 0.5, 0.0, 1.0)
			draw_colored_polygon(PackedVector2Array([c, a2, b2]), col.darkened(0.5).lerp(col.lightened(0.35), lit))
		pts.append(pts[0])
		draw_polyline(pts, Color("d9b46a"), 2.0, true)
		draw_circle(c + Vector2(-r * 0.25, -r * 0.3), r * 0.12, Color(1, 1, 1, 0.7))

## Atlas node map: lattice of nodes with edges, drawn in a Control.
class AtlasView extends Control:
	signal picked(id: int)
	var atlas: Dictionary
	var selected := -1
	func _pos(n: Dictionary) -> Vector2:
		var pad := Vector2(40, 30)
		var cell := (size - pad * 2) / Vector2(Content.ATLAS_W - 1, Content.ATLAS_H - 1)
		return pad + Vector2(int(n.x), int(n.y)) * cell
	var font: Font
	func _ready() -> void:
		font = UIKit.font("display")
	func _draw() -> void:
		var bronze := Color("b98a4a")
		for e in atlas.edges:
			var a: Dictionary = atlas.nodes[int(e) / 1000]
			var b: Dictionary = atlas.nodes[int(e) % 1000]
			var lit: bool = (a.done or b.done)
			draw_line(_pos(a), _pos(b), Color(0, 0, 0, 0.6), 6.0 if lit else 4.0, true)
			draw_line(_pos(a), _pos(b), Color(bronze, 0.85) if lit else Color(0.36, 0.32, 0.34, 0.6), 2.5 if lit else 1.5, true)
		var t := Time.get_ticks_msec() * 0.001
		for n in atlas.nodes:
			var p := _pos(n)
			var col := Content.col(Content.STAGES[int(n.biome)].acc)
			var r := 15.0 + float(n.tier) * 1.2
			var open: bool = n.open
			if n.kind == "citadel":
				var q := r + 9.0
				var dia := PackedVector2Array([p + Vector2(0, -q), p + Vector2(q, 0), p + Vector2(0, q), p + Vector2(-q, 0)])
				draw_colored_polygon(dia, Color(0.45, 0.25, 0.7, 0.45))
				dia.append(dia[0])
				draw_polyline(dia, Color("c48aff"), 2.0, true)
			if n.kind == "corrupted":
				var pts := PackedVector2Array()
				for i in 25:
					var ang := TAU * float(i) / 24.0
					pts.append(p + Vector2(cos(ang), sin(ang)) * (r + 6.0 + (3.0 if i % 2 == 0 else 0.0)))
				draw_polyline(pts, Color(0.85, 0.15, 0.12, 0.85), 2.0, true)
			if n.done:
				draw_circle(p, r + 9.0, Color(col, 0.18))
			draw_circle(p, r + 2.0, Color(0, 0, 0, 0.8))
			var fill: Color = col.darkened(0.15) if n.done else (col.darkened(0.62) if open else Color(0.12, 0.11, 0.12))
			draw_circle(p, r, fill)
			draw_circle(p + Vector2(-r * 0.25, -r * 0.3), r * 0.45, Color(1, 1, 1, 0.07))
			var ring := Color("f2c76a") if n.done else (bronze if open else Color(0.3, 0.28, 0.28))
			draw_arc(p, r, 0, TAU, 40, ring, 2.0, true)
			if int(n.id) == selected:
				draw_arc(p, r + 5.0 + sin(t * 4.0) * 1.5, 0, TAU, 40, Color.WHITE, 2.0, true)
			var txt := str(n.tier)
			var fs := 17
			var tw := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			var tp := p + Vector2(-tw * 0.5, fs * 0.36)
			draw_string_outline(font, tp, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 4, Color(0, 0, 0, 0.9))
			draw_string(font, tp, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color("f4ead2") if open else Color(0.5, 0.47, 0.45))
	func _process(_dt: float) -> void:
		if selected >= 0: queue_redraw()
	func _gui_input(ev: InputEvent) -> void:
		if (ev is InputEventMouseButton and ev.pressed) or (ev is InputEventScreenTouch and ev.pressed):
			var best := -1
			var bd := 40.0
			for n in atlas.nodes:
				var d := _pos(n).distance_to(ev.position)
				if d < bd:
					bd = d; best = int(n.id)
			if best >= 0:
				picked.emit(best)
				accept_event()


## The Moon drawn to its phase: dark disc, the lit limb (right while waxing), an elliptical terminator.
class MoonDisc extends Control:
	var phase := 0.0
	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - 2.0
		draw_circle(c, r + 2.0, Color(0, 0, 0, 0.7))
		draw_circle(c, r, Color(0.16, 0.17, 0.22))
		var waxing := phase < 0.5
		var k := cos(TAU * phase)
		var pts := PackedVector2Array()
		var n := 24
		for i in n + 1:                      # the lit limb, top to bottom
			var a := -PI / 2.0 + PI * i / n
			pts.append(c + Vector2(r * cos(a) * (1.0 if waxing else -1.0), r * sin(a)))
		for i in n + 1:                      # the terminator, bottom to top
			var a := PI / 2.0 - PI * i / n
			pts.append(c + Vector2(r * k * cos(a) * (1.0 if waxing else -1.0), r * sin(a)))
		if Moon.illumination(phase) > 0.01:
			draw_colored_polygon(pts, Color(0.93, 0.92, 0.84))
		draw_arc(c, r, 0, TAU, 40, Color(0.75, 0.78, 0.9, 0.5), 1.2, true)
