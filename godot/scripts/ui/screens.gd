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

func close() -> void:
	UIKit.clear(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _open(max_w: int = 980) -> VBoxContainer:
	UIKit.clear(self)
	mouse_filter = Control.MOUSE_FILTER_STOP
	return UIKit.sheet(self, max_w)

func _title(v: VBoxContainer, t: String, sub: String = "") -> void:
	var l := UIKit.label(t, 44, UIKit.GOLD)
	v.add_child(l)
	if sub != "":
		v.add_child(UIKit.label(sub, 18, UIKit.DIM, true))

func _back(v: VBoxContainer, what: String = "menu") -> void:
	v.add_child(UIKit.button("Back", func(): act.emit(what, null)))

# ================================================================= main menu
func show_menu() -> void:
	var v := _open(1100)
	var d: Dictionary = Save.data
	_title(v, "SHARDFALL: RIFT SURVIVORS")
	var sea := Save.season()
	v.add_child(UIKit.label("%s - %s" % [sea.name, sea.d], 17, Color("c48aff"), true))
	var cur := ""
	for c in Content.CURRENCY_IDS:
		if int(d.currency[c]) > 0: cur += "%s x%d   " % [Content.CURRENCY[c].name, d.currency[c]]
	v.add_child(UIKit.label("Gold %d    Fragments %d/%d/%d    Rift key %d    %s" % [d.gold, d.fragments.rupture, d.fragments.greed, d.fragments.dread, d.gr_key, cur], 16, UIKit.DIM, true))
	if Save.has_nemesis():
		v.add_child(UIKit.label("Your nemesis %s awaits (level %d)." % [d.nemesis.name, int(d.nemesis.level) + 1], 17, Color("ff8a2b")))
	v.add_child(UIKit.label("Hero", 22))
	var hg := GridContainer.new()
	hg.columns = 4 if get_viewport_rect().size.x > 900 else 2
	hg.add_theme_constant_override("h_separation", 10)
	hg.add_theme_constant_override("v_separation", 10)
	for i in Content.HEROES.size():
		var h: Dictionary = Content.HEROES[i]
		var b := UIKit.button("%s%s\n%s\nUlt: %s" % ["> " if i == int(d.hero) else "", h.name, h.blurb, h.ult], func(): Save.data.hero = i; Save.mark_dirty(); show_menu(), 96)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_color_override("font_color", Content.col(h.col) if i == int(d.hero) else UIKit.TEXT)
		hg.add_child(b)
	v.add_child(hg)
	v.add_child(UIKit.label("Campaign", 22))
	var sg := GridContainer.new()
	sg.columns = hg.columns
	sg.add_theme_constant_override("h_separation", 10)
	sg.add_theme_constant_override("v_separation", 10)
	for i in Content.STAGES.size():
		var s: Dictionary = Content.STAGES[i]
		var open: bool = i == 0 or bool(d.cleared[i - 1])
		var b2 := UIKit.button("%s%s\n%s" % [s.name, "  (cleared)" if d.cleared[i] else "", s.blurb if open else "Locked"], func(): act.emit("campaign", i), 80)
		b2.disabled = not open
		b2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sg.add_child(b2)
	v.add_child(sg)
	v.add_child(UIKit.label("Endgame", 22))
	var eg := UIKit.hbox()
	var atl := UIKit.button("Atlas of Falls", func(): show_atlas(), 72)
	atl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	atl.disabled = not bool(d.cleared[0])
	atl.tooltip_text = "Clear Mossglen Hollow to unlock"
	eg.add_child(atl)
	var gr := UIKit.button("Greater Rift %d" % int(d.get("gr_sel", d.gr_key)), func(): act.emit("rift", int(Save.data.get("gr_sel", Save.data.gr_key))), 72)
	gr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gr.disabled = not bool(d.cleared[0])
	eg.add_child(gr)
	eg.add_child(UIKit.button("-", func(): Save.data.gr_sel = maxi(1, int(Save.data.get("gr_sel", Save.data.gr_key)) - 1); show_menu(), 72))
	eg.add_child(UIKit.button("+", func(): Save.data.gr_sel = mini(int(Save.data.gr_key), int(Save.data.get("gr_sel", Save.data.gr_key)) + 1); show_menu(), 72))
	var have: bool = int(d.fragments.rupture) > 0 and int(d.fragments.greed) > 0 and int(d.fragments.dread) > 0
	var pin := UIKit.button("Summon the Shard Herald" if have else "Pinnacle: need 3 fragments", func(): act.emit("pinnacle", null), 72)
	pin.disabled = not have
	pin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	eg.add_child(pin)
	v.add_child(eg)
	var row := UIKit.hbox()
	for pair in [["Gear, Crafting & Cube", "stash"], ["Codex", "codex"], ["Options", "options"]]:
		var b3 := UIKit.button(pair[0], func(): act.emit(pair[1], null), 64)
		b3.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b3)
	v.add_child(row)
	v.add_child(UIKit.label("Move: WASD / stick / drag.  Roll: Space / A / ROLL.  Ultimate: R / Y.  Flasks: 1, 2 / LB, RB.  Pause: Esc / Start.", 15, UIKit.DIM, true))

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
	_title(v, "Gear, Crafting & Cube", "Select an item, then apply a shard. Legendary items can be dissolved in the Cube to keep their power in the Codex forever.")
	var list := _gear_list()
	var cols := UIKit.hbox(16)
	v.add_child(cols)
	var left := UIKit.vbox(6)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(left)
	var right := UIKit.vbox(8)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(right)
	left.add_child(UIKit.label("Equipped  (%d in stash)" % Save.data.stash.size(), 20, UIKit.GOLD))
	for k in list.size():
		var e: Dictionary = list[k]
		var it: Dictionary = e.it
		var txt := "%s%s [%s] %s" % ["> " if k == _sel_item else "", "E " if e.eq else "", Content.SLOT_NAME[it.slot], Items.name_of(it)]
		var b := UIKit.button(txt, func(): _sel_item = k; show_stash(in_run), 48)
		b.add_theme_color_override("font_color", Content.col(Content.RARITY_COL[it.rarity]))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		left.add_child(b)
		if k == list.size() - 1 or (e.eq and not list[k + 1].eq):
			pass
	if _sel_item >= 0 and _sel_item < list.size():
		var sel: Dictionary = list[_sel_item]
		var it: Dictionary = sel.it
		right.add_child(UIKit.label(Items.name_of(it), 24, Content.col(Content.RARITY_COL[it.rarity])))
		right.add_child(UIKit.label("%s %s - item level %d - score %d" % [Content.RARITY_NAME[it.rarity], Content.SLOT_NAME[it.slot], it.ilvl, int(Items.score(it))], 16, UIKit.DIM))
		for line in Items.lines(it):
			right.add_child(UIKit.label(line, 17, UIKit.TEXT, true))
		var cur: Dictionary = Save.data.equipped[it.slot]
		if not sel.eq and not cur.is_empty():
			var diff := Items.score(it) - Items.score(cur)
			right.add_child(UIKit.label("%+d vs equipped" % int(diff), 17, Color("7dff6b") if diff > 0 else Color("ff6a6a")))
		var acts := UIKit.hbox()
		if not sel.eq:
			acts.add_child(UIKit.button("Equip", func(): act.emit("equip", it); show_stash(in_run), 52))
			acts.add_child(UIKit.button("Salvage", func(): act.emit("salvage", it); _sel_item = -1; show_stash(in_run), 52))
			if String(it.leg) != "":
				acts.add_child(UIKit.button("Cube: extract power", func(): act.emit("extract", it); _sel_item = -1; show_stash(in_run), 52))
		right.add_child(acts)
		right.add_child(UIKit.label("Craft", 20, UIKit.GOLD))
		var grid := GridContainer.new()
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", 8)
		grid.add_theme_constant_override("v_separation", 8)
		for c in Content.CURRENCY_IDS:
			var n := int(Save.data.currency[c])
			var b2 := UIKit.button("%s x%d" % [Content.CURRENCY[c].name, n], func(): _craft_msg = main.craft(it, c); show_stash(in_run), 48)
			b2.tooltip_text = Content.CURRENCY[c].d
			b2.disabled = n <= 0
			b2.add_theme_color_override("font_color", Content.col(Content.CURRENCY[c].col))
			b2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			grid.add_child(b2)
		right.add_child(grid)
		if _craft_msg != "":
			right.add_child(UIKit.label(_craft_msg, 16, Color("ffb0b0"), true))
	else:
		right.add_child(UIKit.label("Select an item.", 18, UIKit.DIM))
	_back(v, "resume_pause" if in_run else "menu")

# ================================================================= codex
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
		b.add_child(UIKit.label("%s - %d slain - tier %d: +%d%% damage%s" % [e.name if c > 0 else "???", c, tier, tier * 3, next], 18, UIKit.TEXT if c > 0 else UIKit.DIM))
		if tier >= 1: b.add_child(UIKit.label("    " + e.lore, 15, UIKit.DIM, true))
	tabs.add_child(_scroll(b, "Bestiary"))
	# lore
	var l := UIKit.vbox(6)
	l.add_child(UIKit.label("%d / %d pages. Every set of %d: +5%% damage, +10 life." % [Save.data.lore.size(), Content.LORE.size(), Content.LORE_SET], 18, UIKit.GOLD))
	for k in Content.LORE.size():
		var have: bool = Save.data.lore.has(k)
		l.add_child(UIKit.label(Content.LORE[k][0] if have else "Missing page", 19, Color("e8dcc0") if have else UIKit.DIM))
		if have: l.add_child(UIKit.label("    " + Content.LORE[k][1], 15, UIKit.DIM, true))
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
func show_options(back: String = "menu") -> void:
	var v := _open(900)
	_title(v, "Options")
	_toggle(v, "Sound", "sound", back)
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
	_cycle(v, "Effects quality", "quality", ["Low", "High"], back)
	_toggle(v, "Show FPS", "show_fps", back)
	v.add_child(UIKit.button("Back", func(): Save.flush(); act.emit(back, null)))

func _toggle(v: VBoxContainer, label: String, key: String, back: String) -> void:
	var on := bool(Save.opt(key))
	v.add_child(UIKit.button("%s: %s" % [label, "On" if on else "Off"], func(): Save.set_opt(key, not on); act.emit("options_changed", null); show_options(back), 52))

func _cycle(v: VBoxContainer, label: String, key: String, names: Array, back: String) -> void:
	var cur := int(Save.opt(key))
	v.add_child(UIKit.button("%s: %s" % [label, names[cur % names.size()]], func(): Save.set_opt(key, (cur + 1) % names.size()); act.emit("options_changed", null); show_options(back), 52))

func _slider(v: VBoxContainer, label: String, key: String, lo: float, hi: float, _back_s: String) -> void:
	var h := UIKit.hbox()
	var l := UIKit.label("%s: %d%%" % [label, int(float(Save.opt(key)) * 100)], 20)
	l.custom_minimum_size = Vector2(260, 0)
	h.add_child(l)
	var s := HSlider.new()
	s.min_value = lo; s.max_value = hi; s.step = 0.05
	s.value = float(Save.opt(key))
	s.custom_minimum_size = Vector2(0, 48)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.value_changed.connect(func(x: float): Save.set_opt(key, x); l.text = "%s: %d%%" % [label, int(x * 100)])
	h.add_child(s)
	v.add_child(h)

# ================================================================= in-run overlays
func show_levelup(w: World) -> void:
	var v := _open(900)
	_title(v, "Level %d" % w.lvl, "Choose one.")
	var choices := w.make_choices()
	for c in choices:
		var tx := w.choice_text(c)
		var b := UIKit.button("%s\n%s\n%s" % [tx.tag, tx.name, tx.d], func(): act.emit("pick", c), 110)
		b.add_theme_color_override("font_color", Content.col(tx.col))
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(b)
	# weapon + gem overview so links are visible while choosing
	var o := ""
	for id in w.weapons:
		var wd: Dictionary = w.weapons[id]
		o += "%s %s%d  [%s]\n" % [Content.WEAPONS[id].name, "EVO " if wd.evo else "Lv", wd.lv, ", ".join(wd.gems.map(func(g): return Content.GEMS[g].name)) if not wd.gems.is_empty() else "no links"]
	v.add_child(UIKit.label(o, 16, UIKit.DIM, true))

func show_pause(w: World) -> void:
	var v := _open(700)
	_title(v, "Paused", "%s - %s" % [Content.HEROES[w.hero].name, w.mode.capitalize()])
	v.add_child(UIKit.button("Resume", func(): act.emit("resume", null)))
	v.add_child(UIKit.button("Gear & Crafting", func(): show_stash(true)))
	v.add_child(UIKit.button("Options", func(): show_options("resume_pause")))
	v.add_child(UIKit.button("Abandon run", func(): act.emit("abandon", null)))
	var build := ""
	for id in w.weapons:
		build += "%s Lv%d %s\n" % [Content.WEAPONS[id].name, w.weapons[id].lv, w.weapons[id].gems]
	for id in w.perks:
		build += "%s %d   " % [Content.PERKS[id].name, w.perks[id]]
	v.add_child(UIKit.label(build, 15, UIKit.DIM, true))

func show_end(w: World) -> void:
	var v := _open(800)
	var title := "Victory" if w.won else "You fell"
	_title(v, title, ("Slain by " + w.killer) if not w.won and w.killer != "" else "")
	var rows := [["Time", Hud._fmt(w.t)], ["Kills", str(w.kills)], ["Level", str(w.lvl)], ["Best combo", str(w.best_combo)], ["Gold earned", str(int(w.gold))],
		["Items found", str(w.loot_run.size())], ["Reactions triggered", str(w.metrics.reactions)], ["Perfect dodges", str(w.metrics.perfect)], ["Lore pages", str(w.lore_run.size())]]
	if w.mode == "rift": rows.append(["Rift progress", "%d%%" % int(w.progress)])
	for r in rows:
		var h := UIKit.hbox()
		var a := UIKit.label(r[0], 20, UIKit.DIM)
		a.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(a)
		h.add_child(UIKit.label(r[1], 20, UIKit.TEXT))
		v.add_child(h)
	var ev := ""
	for e in w.director.history: ev += Content.EVENTS[e[1]].name + ", "
	if ev != "": v.add_child(UIKit.label("Events: " + ev.trim_suffix(", "), 16, Color("e0c8ff"), true))
	var best := ""
	for it in w.loot_run:
		if int(it.rarity) >= Content.Rarity.RARE: best += Items.name_of(it) + ", "
	if best != "": v.add_child(UIKit.label("Notable loot: " + best.trim_suffix(", "), 16, UIKit.GOLD, true))
	v.add_child(UIKit.button("Play again", func(): act.emit("retry", null)))
	v.add_child(UIKit.button("Menu", func(): act.emit("menu", null)))

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


## Atlas node map: lattice of nodes with edges, drawn in a Control.
class AtlasView extends Control:
	signal picked(id: int)
	var atlas: Dictionary
	var selected := -1
	func _pos(n: Dictionary) -> Vector2:
		var pad := Vector2(40, 30)
		var cell := (size - pad * 2) / Vector2(Content.ATLAS_W - 1, Content.ATLAS_H - 1)
		return pad + Vector2(int(n.x), int(n.y)) * cell
	func _draw() -> void:
		var font := ThemeDB.fallback_font
		for e in atlas.edges:
			var a: Dictionary = atlas.nodes[int(e) / 1000]
			var b: Dictionary = atlas.nodes[int(e) % 1000]
			var lit: bool = (a.done or b.done)
			draw_line(_pos(a), _pos(b), Color(0.6, 0.55, 0.9, 0.8) if lit else Color(0.3, 0.3, 0.4, 0.5), 3.0 if lit else 1.5)
		for n in atlas.nodes:
			var p := _pos(n)
			var col := Content.col(Content.STAGES[int(n.biome)].acc)
			var r := 16.0 + float(n.tier)
			if not n.open: col = Color(0.25, 0.25, 0.3)
			if n.kind == "citadel": draw_rect(Rect2(p - Vector2(r, r), Vector2(r, r) * 2), Color(0.77, 0.54, 1.0, 0.35))
			if n.kind == "corrupted": draw_circle(p, r + 6.0, Color(1, 0.2, 0.2, 0.3))
			draw_circle(p, r, col.darkened(0.5) if not n.done else col)
			draw_arc(p, r, 0, TAU, 32, Color.WHITE if int(n.id) == selected else col, 3.0 if int(n.id) == selected else 1.5)
			draw_string(font, p + Vector2(-6, 6), str(n.tier), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)
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
