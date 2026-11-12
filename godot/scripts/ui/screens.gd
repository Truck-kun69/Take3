class_name Screens
extends Control
## Every full-screen page and overlay, built on demand into this control. `main` owns the flow
## and calls show_*(); buttons call back into main through the `act` signal.

signal act(what: String, arg: Variant)

var main: Node
var _sel_item := -1           # index into the combined gear list in the stash screen
var _sel_node := -1
var _craft_msg := ""

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

var _choices: Array = []       # level-up choices, so number keys can pick them

func close() -> void:
	_choices = []
	UIKit.clear(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _open(max_w: int = 980) -> VBoxContainer:
	_choices = []
	UIKit.clear(self)
	mouse_filter = Control.MOUSE_FILTER_STOP
	return UIKit.sheet(self, max_w)

func _title(v: VBoxContainer, t: String, sub: String = "") -> void:
	v.add_child(UIKit.title(t, 38))
	if sub != "":
		var l := UIKit.label(sub, 18, UIKit.DIM, true, "italic")
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(l)

func _back(v: VBoxContainer, what: String = "menu") -> void:
	v.add_child(UIKit.button("Back", func(): act.emit(what, null)))

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
## Character-select layout: the 3D stage (MenuStage3D) fills the screen with the chosen hero on the
## right; a dark gradient on the left hosts the logo and a scrolling column of tiles. Portrait
## phones get one full-width column over a stronger scrim.
func show_menu() -> void:
	_choices = []
	UIKit.clear(self)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var d: Dictionary = Save.data
	var vs := get_viewport_rect().size
	var portrait := vs.x < 820.0
	var wide := not portrait and vs.x >= 1100.0          # two columns, hero in between
	var col_w := vs.x - 24.0 if portrait else (clampf(vs.x * 0.38, 440.0, 560.0) if wide else clampf(vs.x * 0.5, 440.0, 620.0))
	var right_w := clampf(vs.x * 0.27, 320.0, 400.0)
	if main != null and main.menu_stage != null:
		main.menu_stage.frame_x = 0.5 if portrait else ((col_w + 36.0 + vs.x - right_w - 36.0) * 0.5 / vs.x if wide else 0.76)
		main.menu_stage._frame()
	# scrims: opaque behind the columns, clear over the hero
	var gr := Gradient.new()
	var ink := Color(0.02, 0.016, 0.022)
	gr.set_color(0, Color(ink, 0.94)); gr.set_color(1, Color(ink, 0.9 if wide else (0.55 if portrait else 0.0)))
	gr.add_point(clampf((col_w + 30.0) / vs.x, 0.1, 0.95), Color(ink, 0.8))
	gr.add_point(clampf((col_w + 170.0) / vs.x, 0.1, 0.96), Color(ink, 0.55 if portrait else 0.0))
	if wide:
		gr.add_point(clampf((vs.x - right_w - 170.0) / vs.x, 0.1, 0.97), Color(ink, 0.0))
		gr.add_point(clampf((vs.x - right_w - 30.0) / vs.x, 0.1, 0.98), Color(ink, 0.8))
	add_child(_grad_rect(gr, false))
	var g2 := Gradient.new()
	g2.set_color(0, Color(0, 0, 0, 0.55)); g2.set_color(1, Color(0, 0, 0, 0.75))
	g2.add_point(0.16, Color(0, 0, 0, 0)); g2.add_point(0.78, Color(0, 0, 0, 0))
	add_child(_grad_rect(g2, true))
	# left column: identity, exiles, utility
	var v := _column(Vector2(12.0 if portrait else 36.0, 0), Vector2(col_w, vs.y))
	var logo := TextureRect.new()
	logo.texture = UIKit.tex("logo")
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.custom_minimum_size = Vector2(0, (col_w - 14.0) * float(logo.texture.get_height()) / float(logo.texture.get_width()))
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(logo)
	var sea := Save.season()
	var sh := UIKit.hbox(8)
	sh.alignment = BoxContainer.ALIGNMENT_CENTER
	sh.add_child(UIKit.label(String(sea.name).to_upper(), 15, Color("c9a2ff"), false, "label"))
	var sd := UIKit.label(String(sea.d), 16, Color("a99bc4"), true, "italic")
	sd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sh.add_child(sd)
	v.add_child(sh)
	v.add_child(_sky_row())
	v.add_child(_resources(d))
	if Save.has_nemesis():
		var nl := UIKit.label("Your nemesis %s awaits  (level %d)" % [d.nemesis.name, int(d.nemesis.level) + 1], 17, UIKit.EMBER, true, "italic")
		nl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(nl)
	v.add_child(_section("Choose your exile"))
	var hg := _grid(2)
	for i in Content.HEROES.size():
		var h: Dictionary = Content.HEROES[i]
		var t := UIKit.tile(h.name, h.blurb, func(): Save.data.hero = i; Save.mark_dirty(); act.emit("hero", i); show_menu(), Content.col(h.col), i == int(d.hero), 68)
		t.tooltip_text = "Ultimate: %s. %s" % [h.ult, h.ult_d]
		hg.add_child(t)
	v.add_child(hg)
	# the journey: campaign + endgame (its own column on wide screens)
	var j := v
	if wide:
		j = _column(Vector2(vs.x - right_w - 36.0, 0), Vector2(right_w, vs.y))
	_journey(j, d, wide)
	if wide:
		v.add_child(_spacer(4))
	var row := _grid(2, 8)
	var unspent := int(d.get("echoes", 0))
	for pair in [["Gear & Cube", "stash"], ["Shard Web" + ("  (%d)" % unspent if unspent > 0 else ""), "web"], ["Codex", "codex"], ["Options", "options"]]:
		var b3 := UIKit.button(pair[0], func(): act.emit(pair[1], null), 52)
		b3.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b3)
	v.add_child(row)
	var help := UIKit.label("WASD or drag to move  \u00b7  Space roll  \u00b7  R ultimate  \u00b7  1 2 flasks  \u00b7  Esc pause", 14, UIKit.DIM, true, "italic")
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(help)
	v.add_child(_spacer(10))
	if not portrait:
		_hero_plate(Content.HEROES[int(d.hero)], vs, col_w, right_w if wide else 0.0)

func _journey(j: VBoxContainer, d: Dictionary, wide: bool) -> void:
	var th := 64 if wide else 68
	j.add_child(_section("Campaign"))
	var sg := _grid(1 if wide else 2, 8)
	for i in Content.STAGES.size():
		var s: Dictionary = Content.STAGES[i]
		var open: bool = i == 0 or (i - 1 < d.cleared.size() and bool(d.cleared[i - 1]))
		var t2 := UIKit.tile("%s  %s" % [["I", "II", "III", "IV", "V", "VI"][i], s.name], s.blurb if open else "Sealed until the previous act falls", func(): act.emit("campaign", i), Content.col(s.acc), false, th)
		_lock(t2, not open)
		if i < d.cleared.size() and bool(d.cleared[i]):
			_cleared_mark(t2)
			t2.tooltip_text = "Cleared"
		sg.add_child(t2)
	j.add_child(sg)
	# torment: optional difficulty for the campaign, atlas and pinnacle
	var tm := int(d.get("torment", 0))
	var tmax := int(d.get("torment_max", 0))
	var trow := UIKit.hbox(6)
	var tdec := UIKit.button("\u2212", func(): Save.data.torment = maxi(0, int(Save.data.torment) - 1); Save.mark_dirty(); show_menu(), 52)
	tdec.custom_minimum_size.x = 48
	tdec.disabled = tm <= 0
	var T: Dictionary = Content.TORMENT[tm]
	var tsub := ("+%d%% loot  \u00b7  foes x%.1f life" % [int(float(T.loot) * 100), float(T.hp)]) if tm > 0 else ("Win a run to unlock Torment I" if tmax == 0 else "Foes and loot as intended")
	var tt := UIKit.tile(String(T.name), tsub, func(): pass, Color("b3242c") if tm > 0 else Color(0.7, 0.68, 0.66), tm > 0, 52)
	var tinc := UIKit.button("+", func(): Save.data.torment = mini(int(Save.data.torment_max), int(Save.data.torment) + 1); Save.mark_dirty(); show_menu(), 52)
	tinc.custom_minimum_size.x = 48
	tinc.disabled = tm >= tmax
	for c in [tdec, tt, tinc]: trow.add_child(c)
	j.add_child(trow)
	j.add_child(_section("Endgame"))
	var unlocked := bool(d.cleared[0])
	var eg := _grid(1 if wide else 2, 8)
	var atl := UIKit.tile("Atlas of Falls", "Chart the shattered maps" if unlocked else "Clear Mossglen Hollow to unlock", func(): show_atlas(), Color("8fd8ff"), false, th)
	_lock(atl, not unlocked)
	eg.add_child(atl)
	var have: bool = int(d.fragments.rupture) > 0 and int(d.fragments.greed) > 0 and int(d.fragments.dread) > 0
	var pin := UIKit.tile("The Shard Herald", "Offer three fragments" if have else "Needs Rupture, Greed and Dread fragments", func(): act.emit("pinnacle", null), Color("ff5a4a"), false, th)
	_lock(pin, not have)
	eg.add_child(pin)
	j.add_child(eg)
	var grs := int(d.get("gr_sel", d.gr_key))
	var grow := UIKit.hbox(6)
	var dec := UIKit.button("\u2212", func(): Save.data.gr_sel = maxi(1, int(Save.data.get("gr_sel", Save.data.gr_key)) - 1); show_menu(), th)
	dec.custom_minimum_size.x = 48
	dec.disabled = not unlocked or grs <= 1
	var grt := UIKit.tile("Greater Rift %d" % grs, "Best %d  \u00b7  keys to %d" % [int(d.gr_best), int(d.gr_key)], func(): act.emit("rift", int(Save.data.get("gr_sel", Save.data.gr_key))), Color("c48aff"), false, th)
	_lock(grt, not unlocked)
	var inc := UIKit.button("+", func(): Save.data.gr_sel = mini(int(Save.data.gr_key), int(Save.data.get("gr_sel", Save.data.gr_key)) + 1); show_menu(), th)
	inc.custom_minimum_size.x = 48
	inc.disabled = not unlocked or grs >= int(d.gr_key)
	for c in [dec, grt, inc]: grow.add_child(c)
	j.add_child(grow)

## Hero name, ultimate and element, centred under the hero between the columns.
func _hero_plate(h: Dictionary, vs: Vector2, left_w: float, right_w: float) -> void:
	var x0 := left_w + 36.0
	var x1 := vs.x - (right_w + 36.0 if right_w > 0.0 else 24.0)
	var plate := UIKit.vbox(0)
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(plate)
	plate.position = Vector2(x0, vs.y - 150.0)
	plate.size = Vector2(x1 - x0, 130.0)
	plate.alignment = BoxContainer.ALIGNMENT_END
	var nm := UIKit.label(String(h.name).to_upper(), 42, Content.col(h.col).lerp(UIKit.TEXT, 0.4), false, "display_heavy")
	nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	plate.add_child(nm)
	plate.add_child(UIKit.divider())
	var ul := UIKit.label("%s  \u00b7  %s" % [String(h.ult).to_upper(), Content.EL_NAME[h.elem].to_upper()], 15, UIKit.GOLD, false, "label")
	ul.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	plate.add_child(ul)
	var ud := UIKit.label(h.ult_d, 16, Color("b8ad98"), true, "italic")
	ud.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	plate.add_child(ud)
	for c in plate.get_children(): (c as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE

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

## Gold, fragments, keys and crafting shards as a strip of numbers in small slots.
func _resources(d: Dictionary) -> HFlowContainer:
	var f := HFlowContainer.new()
	f.alignment = FlowContainer.ALIGNMENT_CENTER
	f.add_theme_constant_override("h_separation", 14)
	f.add_theme_constant_override("v_separation", 4)
	var items := [["Gold", int(d.gold), UIKit.GOLD], ["Rupture", int(d.fragments.rupture), Color("ff6a4a")], ["Greed", int(d.fragments.greed), Color("ffd24a")],
		["Dread", int(d.fragments.dread), Color("b890ff")], ["Rift key", int(d.gr_key), Color("c48aff")]]
	for c in Content.CURRENCY_IDS:
		if int(d.currency[c]) > 0: items.append([Content.CURRENCY[c].name, int(d.currency[c]), Content.col(Content.CURRENCY[c].col)])
	for it in items:
		var h := UIKit.hbox(5)
		var gem := ColorRect.new()
		gem.color = it[2]
		gem.custom_minimum_size = Vector2(7, 7)
		gem.rotation = PI / 4.0
		gem.size_flags_vertical = Control.SIZE_SHRINK_CENTER
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
		v.add_child(UIKit.label("+%d%% item quantity, +%d%% item rarity" % [int(rw.x * 100), int(rw.y * 100)], 17, Color("7dff6b")))
		var run := UIKit.button("Run this map", func(): act.emit("atlas", _sel_node), 64)
		run.disabled = not bool(n.open)
		v.add_child(run)
	_back(v)

# ================================================================= stash / crafting / cube
func _gear_list() -> Array:
	var out: Array = []
	for s in Content.SLOTS:
		var it: Dictionary = Save.data.equipped[s]
		if not it.is_empty(): out.append({"it": it, "eq": true})
	for it in Save.data.stash:
		out.append({"it": it, "eq": false})
	return out

func show_stash(in_run: bool = false) -> void:
	var v := _open(1200)
	_title(v, "Gear, Crafting & Cube", "Select an item, then apply a shard. Legendary items dissolve in the Cube and keep their power in the Codex forever.")
	var list := _gear_list()
	var portrait := get_viewport_rect().size.x < 820.0
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
			left.add_child(_section("Stash  \u00b7  %d" % Save.data.stash.size()))
		var rc := Content.col(Content.RARITY_COL[it.rarity])
		var t := UIKit.tile(Items.name_of(it), "%s  \u00b7  %s  \u00b7  item level %d" % [Content.RARITY_NAME[it.rarity], Content.SLOT_NAME[it.slot], it.ilvl],
			func(): _sel_item = k; show_stash(in_run), rc, k == _sel_item, 62, true, rc.lightened(0.15))
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
			var dl := UIKit.label("%+d score vs equipped" % int(diff), 17, Color("7dff6b") if diff > 0 else Color("ff6a6a"), false, "display")
			dl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			card.add_child(dl)
		var cp := PanelContainer.new()
		cp.add_theme_stylebox_override("panel", UIKit.nine("card", 46, Vector4(26, 26, 26, 24), Color(0.78, 0.76, 0.74).lerp(rc2, 0.5)))
		cp.add_child(card)
		right.add_child(cp)
		var acts := UIKit.hbox()
		acts.alignment = BoxContainer.ALIGNMENT_CENTER
		if not sel.eq:
			acts.add_child(UIKit.button("Equip", func(): act.emit("equip", it); show_stash(in_run), 50))
			acts.add_child(UIKit.button("Salvage", func(): act.emit("salvage", it); _sel_item = -1; show_stash(in_run), 50))
			if String(it.leg) != "":
				acts.add_child(UIKit.button("Cube: extract", func(): act.emit("extract", it); _sel_item = -1; show_stash(in_run), 50))
		right.add_child(acts)
		right.add_child(_section("Craft"))
		var grid := _grid(2, 8)
		for c in Content.CURRENCY_IDS:
			var n := int(Save.data.currency[c])
			var b2 := UIKit.button("%s  %d" % [Content.CURRENCY[c].name, n], func(): _craft_msg = main.craft(it, c); show_stash(in_run), 46)
			b2.tooltip_text = Content.CURRENCY[c].d
			b2.disabled = n <= 0
			b2.add_theme_color_override("font_color", Content.col(Content.CURRENCY[c].col))
			b2.add_theme_font_size_override("font_size", 16)
			b2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			grid.add_child(b2)
		right.add_child(grid)
		if _craft_msg != "":
			right.add_child(UIKit.label(_craft_msg, 17, Color("ffcf9a"), true, "italic"))
	else:
		var hint := UIKit.label("Select an item to inspect, equip or craft.", 19, UIKit.DIM, true, "italic")
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		right.add_child(hint)
	_back(v, "resume_pause" if in_run else "menu")

# ================================================================= codex
# ================================================================= the Shard Web (passive tree)
var _sel_passive := "start"

func show_web() -> void:
	var v := _open(1180)
	var d: Dictionary = Save.data
	var taken: Array = d.passives
	var portrait := get_viewport_rect().size.x < 820.0
	_title(v, "The Shard Web", "Echoes from every run buy permanent passives. Take a node that touches one you own.")
	var body: BoxContainer = UIKit.vbox(10) if portrait else UIKit.hbox(18)
	v.add_child(body)
	var view := WebView.new()
	view.taken = taken
	view.selected = _sel_passive
	view.custom_minimum_size = Vector2(0, 420) if portrait else Vector2(700, mini(480, int(get_viewport_rect().size.y) - 250))
	view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view.picked.connect(func(id: String): _sel_passive = id; show_web())
	body.add_child(view)
	# side column (landscape): echoes, the selected node, actions
	var side := UIKit.vbox(10)
	side.custom_minimum_size.x = 0 if portrait else 300
	side.alignment = BoxContainer.ALIGNMENT_CENTER
	body.add_child(side)
	var info := UIKit.hbox(10)
	info.alignment = BoxContainer.ALIGNMENT_CENTER
	info.add_child(UIKit.label("%d" % int(d.echoes), 34, UIKit.GOLD, false, "num_heavy"))
	var il := UIKit.label("Echoes to spend\n%d of %d taken" % [taken.size() - 1, Content.PASSIVES.size() - 1], 16, UIKit.DIM, false, "italic")
	info.add_child(il)
	side.add_child(info)
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
	side.add_child(take)
	var reset := UIKit.button("Reset web  (refund all)", func():
		Save.data.echoes = int(Save.data.echoes) + Save.data.passives.size() - 1
		Save.data.passives = ["start"]
		Save.mark_dirty()
		show_web(), 48)
	reset.disabled = taken.size() <= 1
	side.add_child(reset)
	side.add_child(UIKit.button("Back", func(): act.emit("menu", null), 48))

func show_codex() -> void:
	var v := _open(1100)
	_title(v, "Codex")
	var tabs := TabContainer.new()
	tabs.custom_minimum_size = Vector2(0, 520)
	v.add_child(tabs)
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
		var bt := UIKit.button("%s%s: %s" % ["[ACTIVE] " if on else "", L.name, L.d] if known else "??? (find and extract this legendary)", func(): act.emit("codex_toggle", id); show_codex(), 52)
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
	_back(v)

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
func show_options(back: String = "menu") -> void:
	var v := _open(900)
	_title(v, "Options")
	var tabs := _grid(3, 8)
	for i in 3:
		var tb := UIKit.button(["Game", "Graphics", "Diagnostics"][i], func(): _opt_tab = i; show_options(back), 46)
		tb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if i == _opt_tab: tb.add_theme_color_override("font_color", UIKit.GOLD)
		else: tb.modulate = Color(0.75, 0.72, 0.7)
		tabs.add_child(tb)
	v.add_child(tabs)
	match _opt_tab:
		0:
			_toggle(v, "Sound", "sound", back)
			_toggle(v, "Sound engine: Safe (fewer voices, no ambience)", "sfx_safe", back)
			_slider(v, "Volume", "volume", 0.0, 1.0, back)
			_slider(v, "Screen shake", "shake", 0.0, 1.5, back)
			_cycle(v, "Damage numbers", "dmg_numbers", ["Off", "Crits & reactions", "All"], back)
			_cycle(v, "Auto-aim", "aim", ["Nearest", "Strongest", "Facing"], back)
			_cycle(v, "Joystick", "joy_mode", ["Floating", "Fixed"], back)
			_toggle(v, "Left-handed layout", "left_handed", back)
			_toggle(v, "Colour-blind palette & patterns", "colorblind", back)
			_toggle(v, "Reduce flashing", "reduce_flash", back)
			_toggle(v, "Haptics", "haptics", back)
			_toggle(v, "Auto-equip upgrades", "auto_equip", back)
			_cycle(v, "Loot filter", "loot_filter", ["Show all", "Hide normal", "Rare and better"], back)
			_toggle(v, "Always show touch buttons", "force_touch_ui", back)
		1:
			_cycle(v, "Graphics", "gfx", ["Auto (%s)" % Quality.NAMES[Quality.tier()] if int(Save.opt("gfx")) == 0 else "Auto", "Low", "Medium", "High"], back)
			_cycle(v, "Renderer", "renderer", ["3D (PoE-style)", "Classic 2D"], back)
			_cycle(v, "3D resolution", "render_scale", ["Auto", "100%", "75%", "50%"], back)
			_cycle(v, "Frame rate cap", "frame_cap", ["Auto (%s)" % ("60" if OS.has_feature("mobile") else "none"), "30 (cool, saves battery)", "60", "None"], back)
			_cycle(v, "GPU crowd simulation", "gpu_crowd", ["Auto (%s)" % ("Off" if OS.has_feature("mobile") else "On"), "On", "Off"], back)
			_toggle(v, "Show FPS", "show_fps", back)
			if not Save.opt("gfx_off").is_empty():
				v.add_child(UIKit.label("Switched off after a crash: " + ", ".join(Save.opt("gfx_off").map(func(f): return Quality.FEATURE_NAMES.get(f, f))), 15, Color("e0645a"), true, "italic"))
				v.add_child(UIKit.button("Turn them back on", func(): Save.set_opt("gfx_off", []); Quality.load_saved(); act.emit("options_changed", null); show_options(back), 44))
		2:
			if back != "menu":
				var nl := UIKit.label("The tests start their own scene: open Options from the main menu to run them.", 16, UIKit.DIM, true, "italic")
				nl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				v.add_child(nl)
			else:
				v.add_child(UIKit.button("Graphics self-test (finds crashing features)", func(): Save.flush(); act.emit("selftest", null), 50))
				var bb := UIKit.button("Run benchmark (23 s)", func(): Save.flush(); act.emit("bench", null), 50)
				bb.tooltip_text = "A fixed 400-foe scene; screenshot the result to compare graphics settings."
				v.add_child(bb)
				if FileAccess.file_exists(Diag.PREV):
					v.add_child(UIKit.button("Last crash report", func():
						show_crash(FileAccess.get_file_as_string(Diag.PREV).strip_edges().split("\n").slice(-30)), 46))
				var st: Dictionary = Save.data.get("selftest", {})
				if not st.get("results", []).is_empty() and not st.get("running", false):
					v.add_child(UIKit.button("Last self-test results", func(): show_selftest(st), 46))
			var info := UIKit.label("%s  \u00b7  %s  \u00b7  %s" % [OS.get_model_name(), RenderingServer.get_video_adapter_name(), RenderingServer.get_current_rendering_method()], 14, UIKit.DIM, true, "italic")
			info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			v.add_child(info)
	v.add_child(UIKit.button("Back", func(): Save.flush(); _opt_tab = 0; act.emit(back, null)))

## Shown on launch after a session that ended without closing cleanly: the tail of its breadcrumb
## trail and the engine's errors, small enough to fit one screenshot.
func show_crash(lines: PackedStringArray) -> void:
	var v := _open(1100)
	_title(v, "The last session ended unexpectedly", "Please screenshot this and send it over. It shows what the game was doing when it stopped.")
	var t := UIKit.label("\n".join(lines), 12, Color("d8d0c0"), true, "body")
	t.add_theme_font_override("font", SystemFont.new())
	var sc := _scroll(t, "crash")
	sc.custom_minimum_size = Vector2(0, 400)
	v.add_child(sc)
	v.add_child(UIKit.button("Continue", func(): show_menu(), 50))

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
	v.add_child(row)

func show_selftest(st: Dictionary) -> void:
	var v := _open(860)
	_title(v, "Self-test complete", ("Crashing features are switched off: " + ", ".join(st.bad.map(func(x): return Quality.FEATURE_NAMES.get(x, x)))) if not st.bad.is_empty() else "Nothing crashed. Screenshot this and send it over.")
	_selftest_rows(v, st)
	var tip := UIKit.label("FPS after each feature is switched on (400 foes). Big drops show what is expensive on this phone.", 15, UIKit.DIM, true, "italic")
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(tip)
	v.add_child(UIKit.button("Back", func(): act.emit("menu", null), 54))

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

## Benchmark result: big FPS figure, then the detail rows to screenshot and send back.
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
	var tip := UIKit.label("Screenshot this and send it over. Try Options > Graphics Medium / High and 3D resolution to compare.", 15, UIKit.DIM, true, "italic")
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(tip)
	var row2 := _grid(2, 10)
	for pair in [["Run again", "bench"], ["Back", "menu"]]:
		var b := UIKit.button(pair[0], func(): act.emit(pair[1], null), 54)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row2.add_child(b)
	v.add_child(row2)

## One option row: name on the left in Garamond, its value as a bronze button on the right.
func _opt_row(v: VBoxContainer, label: String, value: String, cb: Callable, on: bool = true) -> void:
	var h := UIKit.hbox(12)
	var l := UIKit.label(label, 19, UIKit.TEXT)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(l)
	var b := UIKit.button(value, cb, 46)
	b.custom_minimum_size.x = 230
	b.add_theme_font_size_override("font_size", 17)
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
	s.value_changed.connect(func(x: float): Save.set_opt(key, x); l.text = "%s  %d%%" % [label, int(x * 100)])
	h.add_child(s)
	v.add_child(h)

# ================================================================= in-run overlays
func show_levelup(w: World) -> void:
	var v := _open(1180)
	var portrait := get_viewport_rect().size.x < 820.0
	_title(v, "Level %d" % w.lvl, "The rift offers a gift. Choose one.")
	var choices := w.make_choices()
	_choices = choices
	var row: BoxContainer = UIKit.vbox(10) if portrait else UIKit.hbox(16)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(row)
	for i in choices.size():
		row.add_child(_choice_card(w, choices[i], i, portrait))
	# weapon + gem overview so links are visible while choosing
	v.add_child(_section("Your arsenal"))
	var o := ""
	for id in w.weapons:
		var wd: Dictionary = w.weapons[id]
		o += "%s %s%d   %s\n" % [Content.WEAPONS[id].name, "Evolved " if wd.evo else "Lv ", wd.lv, ("Linked: " + ", ".join(wd.gems.map(func(g): return Content.GEMS[g].name))) if not wd.gems.is_empty() else "no links"]
	var al := UIKit.label(o.strip_edges(), 16, UIKit.DIM, true, "italic")
	al.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(al)

## An ornate card: silver frame tinted by the reward type, a gem, small-caps tag, carved name, lore-face description.
func _choice_card(w: World, c: Dictionary, idx: int, portrait: bool) -> Button:
	var tx := w.choice_text(c)
	var col := Content.col(tx.col)
	if col.s < 0.15: col = Color("d8b878")              # plain perks: aged gold instead of white
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, 150) if portrait else Vector2(260, 296)
	if portrait: b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var frame := Color(0.78, 0.76, 0.74).lerp(col, 0.45)
	var pad := Vector4(20, 22, 20, 22)
	b.add_theme_stylebox_override("normal", UIKit.nine("card", 46, pad, frame))
	b.add_theme_stylebox_override("hover", UIKit.nine("card", 46, pad, frame.lightened(0.35)))
	b.add_theme_stylebox_override("pressed", UIKit.nine("card", 46, pad, Color("f2c76a")))
	b.add_theme_stylebox_override("focus", UIKit.nine("card", 46, pad, frame.lightened(0.2)))
	b.pressed.connect(func(): act.emit("pick", c))
	var v := UIKit.vbox(6)
	v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	v.offset_left = 22; v.offset_right = -22; v.offset_top = 26; v.offset_bottom = -24
	v.alignment = BoxContainer.ALIGNMENT_BEGIN if not portrait else BoxContainer.ALIGNMENT_CENTER
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(v)
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

func show_pause(w: World) -> void:
	var v := _open(700)
	_title(v, "Paused", "%s - %s" % [Content.HEROES[w.hero].name, w.mode.capitalize()])
	v.add_child(UIKit.button("Resume", func(): act.emit("resume", null)))
	v.add_child(UIKit.button("Gear & Crafting", func(): show_stash(true)))
	v.add_child(UIKit.button("Options", func(): show_options("resume_pause")))
	v.add_child(UIKit.button("Abandon run", func(): act.emit("abandon", null)))
	v.add_child(_section("Your build"))
	var build := ""
	for id in w.weapons:
		var wd: Dictionary = w.weapons[id]
		build += "%s  %s%d%s\n" % [Content.WEAPONS[id].name, "Evolved " if wd.evo else "Lv ", wd.lv,
			("  \u00b7  " + ", ".join(wd.gems.map(func(g): return Content.GEMS[g].name))) if not wd.gems.is_empty() else ""]
	var perks := []
	for id in w.perks: perks.append("%s %d" % [Content.PERKS[id].name, w.perks[id]])
	if not perks.is_empty(): build += "  \u00b7  ".join(perks)
	var bl := UIKit.label(build.strip_edges(), 16, UIKit.DIM, true, "italic")
	bl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(bl)

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

func show_end(w: World) -> void:
	var v := _open(820)
	var won: bool = w.won
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
	var rows := [["Time", Hud._fmt(w.t)], ["Slain", str(w.kills)], ["Level", str(w.lvl)], ["Best combo", str(w.best_combo)], ["Gold", str(int(w.gold))],
		["Items", str(w.loot_run.size())], ["Reactions", str(w.metrics.reactions)], ["Perfect dodges", str(w.metrics.perfect)], ["Lore pages", str(w.lore_run.size())]]
	if w.mode == "rift": rows.append(["Rift progress", "%d%%" % int(w.progress)])
	rows.append(["Echoes", "+%d" % w.echoes_run])
	if w.torment > 0: rows.append(["Difficulty", String(Content.TORMENT[w.torment].name)])
	var g := _grid(3 if get_viewport_rect().size.x >= 820.0 else 2, 10)
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
	var row := _grid(2, 10)
	for pair in [["Play again", "retry"], ["Return to menu", "menu"]]:
		var bt := UIKit.button(pair[0], func(): act.emit(pair[1], null), 58)
		bt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(bt)
	v.add_child(row)

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
			var r := {"start": 15.0, "minor": 9.0, "notable": 15.0, "keystone": 20.0}[P.kind] as float
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
			if P.kind == "notable" or P.kind == "keystone":
				var nm := String(P.name)
				var fs := 13
				var tw := font.get_string_size(nm, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
				var horizontal := absf(float(P.y)) < 0.05             # side branches: label above, clear of the next node
				var tp := p + (Vector2(-tw * 0.5, -r - 9.0) if horizontal else Vector2(r + 10.0, 5.0))      # vertical branches: label to the right
				draw_string_outline(font, tp, nm, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 4, Color(0, 0, 0, 0.9))
				draw_string(font, tp, nm, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col.lightened(0.3) if own else Color(0.7, 0.66, 0.6))
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
		var n := {"w": 4, "e": 8, "p": 24, "g": 6, "key": 5}.get(kind, 24) as int
		var pts := PackedVector2Array()
		for i in n:
			var a := -PI / 2.0 + TAU * float(i) / float(n)
			var rr := r if kind != "e" or i % 2 == 0 else r * 0.55
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
