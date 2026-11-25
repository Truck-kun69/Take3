class_name CampPages
extends RefCounted
## The Camp (docs/superpowers/specs/2026-11-25-camp-tutorial-crafting-design.md): the hub page of friendly NPCs
## and each one's station, built into Screens with its kit (UIKit.sheet and foot, tiles, sections). The rules are
## Camp's (scripts/sim/camp.gd): these pages show them, call them, then save and redraw. A station's Back (and
## Android Back, main.back) returns to the hub: Screens.parent_page is "camp" while a station is up.

const NPCS := {
	"smith": {"name": "Doran Ashhand", "role": "Weaponsmith", "col": "ff9a5a", "glyph": "D",
		"lines": ["Every weapon you carry in there, I can make bite harder.", "Ore from the rift, scrap from your junk, gold for my time.", "Temper it once and it stays tempered. Steel remembers."]},
	"kiln": {"name": "Mother Kiln", "role": "Fusion Furnace", "col": "ffcf6a", "glyph": "K",
		"lines": ["Three trinkets in, one better thing out. The fire is fair.", "Name two weapons and I will teach them to burn together.", "Kindled steel finds its partner sooner, child."]},
	"nim": {"name": "Nim", "role": "Salvager", "col": "c9b79a", "glyph": "N",
		"lines": ["Bring me what you will not wear. I will make it useful.", "Locked things I leave alone. I am a salvager, not a thief.", "Scrap today, a masterwork tomorrow."]},
	"sella": {"name": "Sella Coinwright", "role": "Trader", "col": "7fd8ff", "glyph": "S",
		"lines": ["Fresh stock at dawn, every dawn.", "Gold spends the same on either side of the rift.", "Shards, gear, a fair price. Mostly fair."]},
	"brask": {"name": "Captain Brask", "role": "Drillmaster", "col": "9fe08a", "glyph": "B",
		"lines": ["Keep moving. A still exile is a dead exile.", "Roll through them, not away from them.", "Forget something out there? Ask, and I will drill it again."]},
	"chronicler": {"name": "The Chronicler", "role": "Codex & Story", "col": "e8dcc0", "glyph": "C",
		"lines": ["Every Echo you carry back, I write down.", "The acts, the exiles, the things that hunt them: all here.", "Ink lasts longer than any of us."]},
	"cartographer": {"name": "Wend", "role": "Cartographer", "col": "8fb8ff", "glyph": "W",
		"lines": ["The Atlas grows with every map you clear.", "Today's rift is the same for everyone. Beat them all.", "Prophecies, fragments, deeper rifts: pick your road."]},
}
const NPC_ORDER := ["smith", "kiln", "nim", "sella", "brask", "chronicler", "cartographer"]
const CARD_H := 88

static var _visit := 0                  # rotates the NPCs' lines, one step per visit to the hub
static var _msg := ""                   # the result of the last action on a station, shown once
static var _msg_good := true
static var _furnace_tab := 0            # 0 gear, 1 weapons
static var _pick: Array = []            # the furnace's weapon pair being chosen
static var _fused: Dictionary = {}      # the furnace's last gear fusion, shown on its page
static var _armed := -1                 # the bench: the rarity whose "Salvage all" waits for a second tap

static func plural(slot: String) -> String:
	var n := String(Content.SLOT_NAME[slot])
	return n if n.ends_with("s") else n + "s"

static func line(id: String) -> String:
	var L: Array = NPCS[id].lines
	return String(L[_visit % L.size()])

## One station by name (main's "camp_page" action).
static func show(s: Screens, page: String) -> void:
	match page:
		"smith": show_smith(s)
		"kiln": show_furnace(s)
		"nim": show_bench(s)
		"sella": show_trader(s)
		"brask": show_drill(s)
		_: show_camp(s)

# ================================================================= the hub
static func show_camp(s: Screens) -> void:
	var v := s._open(1100)
	s.parent_page = ""
	_visit += 1
	_msg = ""
	_armed = -1
	var d: Dictionary = Save.data
	var first := not bool(d.get("camp_seen", false))
	if first:
		d.camp_seen = true
		Save.mark_dirty()
	if first:
		s._title(v, "The Camp", "Captain Brask: “First night at camp? Each of us does one thing. Tap a face to see what.”")
	else:
		s._title(v, "The Camp", "Between rifts, the exiles who keep the fire.")
	v.add_child(purse(s, d))
	var vw := s.get_viewport_rect().size.x
	var g := s._grid(1 if vw < 820.0 else (3 if vw >= 1250.0 else 2), 10)
	var n_stash := (d.stash as Array).size()
	var n_new := (d.get("new_items", []) as Array).size()
	var gear := UIKit.tile("Gear & Stash", ("%d / %d in the stash" % [n_stash, World.STASH_CAP]) + (("  ·  %d new" % n_new) if n_new > 0 else "  ·  equip, craft, lock"),
		func(): s.parent_page = "camp"; s.show_stash(false), Color("e8b54e"), false, CARD_H)
	g.add_child(gear)
	for id in NPC_ORDER:
		g.add_child(_card(id, _status(d, id), func(): _go(s, id)))
	v.add_child(g)
	s._back(v)

static func _go(s: Screens, id: String) -> void:
	match id:
		"chronicler":                         # set first: the page's Back reads it while it is built
			s.parent_page = "camp"
			s.act.emit("codex", "camp")
		"cartographer":
			s.parent_page = "camp"
			s.act.emit("endgame", null)
		_: show(s, id)

## The line under an NPC's name on the hub: what their station holds for you now.
static func _status(d: Dictionary, id: String) -> String:
	match id:
		"smith":
			var pl := Camp.pool(d)
			var n := 0
			var ready := false
			for w in pl:
				if Camp.temper_rank(d, w) > 0: n += 1
				var c := Camp.temper_cost(d, w)
				if not c.is_empty() and Camp.can_pay(d, c): ready = true
			return "%d of %d tempered%s" % [n, pl.size(), "  ·  one is ready" if ready else ""]
		"kiln":
			var gr := Camp.fuse_groups(d)
			return "%d fusion%s ready  ·  %d pair%s kindled" % [gr.size(), "" if gr.size() == 1 else "s", (d.kindled as Array).size(), "" if (d.kindled as Array).size() == 1 else "s"]
		"nim":
			var junk := Camp.bulk_list(d, 0).size() + Camp.bulk_list(d, 1).size()
			return ("%d Normal and Magic to salvage" % junk) if junk > 0 else "Nothing to salvage yet"
		"sella":
			var T: Dictionary = d.get("trader", {})
			if String(T.get("day", "")) != Camp.today(): return "New stock today"
			return "%d item%s left today" % [(T.stock as Array).size(), "" if (T.stock as Array).size() == 1 else "s"]
		"brask":
			return "How to play  ·  tips %s" % ("on" if bool(d.tutorial.on) else "off")
		"chronicler":
			return "%d lore pages  ·  %d Rift Echoes" % [(d.lore as Array).size(), (d.get("rift_echoes", []) as Array).size()]
		"cartographer":
			return "Daily Rift, Atlas, prophecies"
	return ""

## An NPC's card on the hub: their medallion, name and role, what they hold for you, and one line of theirs.
static func _card(id: String, status: String, cb: Callable) -> Button:
	var N: Dictionary = NPCS[id]
	var col := Color(String(N.col))
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, CARD_H)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var base_t := Color(0.75, 0.72, 0.68).lerp(col, 0.3)
	var pad := Vector4(16, 12, 16, 12)
	b.add_theme_stylebox_override("normal", UIKit.nine("tile", 24, pad, base_t))
	b.add_theme_stylebox_override("hover", UIKit.nine("tile", 24, pad, base_t.lightened(0.3)))
	b.add_theme_stylebox_override("pressed", UIKit.nine("tile", 24, pad, Color("f2c76a")))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	UIKit.press_fx(b)
	var h := UIKit.hbox(14)
	h.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	h.offset_left = 16; h.offset_right = -16; h.offset_top = 8; h.offset_bottom = -8
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var md := Medallion.new(col, String(N.glyph), 58.0)
	md.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(md)
	var t := UIKit.vbox(0)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.alignment = BoxContainer.ALIGNMENT_CENTER
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var nm := UIKit.label(String(N.name), 19, col.lightened(0.25), false, "display")
	var rl := UIKit.label(String(N.role).to_upper(), 13, Color("c8a46a"), false, "label")
	var st := UIKit.label(status, 15, UIKit.TEXT, false, "italic")
	for l in [nm, rl, st]:
		(l as Label).text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		(l as Label).mouse_filter = Control.MOUSE_FILTER_IGNORE
		t.add_child(l)
	h.add_child(t)
	b.add_child(h)
	b.pressed.connect(func(): Sfx.play("click"); cb.call())
	b.set_meta("npc", id)
	return b

## A station's head: the NPC's medallion, name and role, and their line.
static func _header(s: Screens, v: VBoxContainer, id: String, sub: String) -> void:
	var N: Dictionary = NPCS[id]
	var col := Color(String(N.col))
	var h := UIKit.hbox(14)
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	var md := Medallion.new(col, String(N.glyph), 62.0)
	md.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(md)
	var t := UIKit.vbox(0)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var top := UIKit.hbox(12)
	top.add_child(UIKit.label(String(N.name), 28, col.lightened(0.2), false, "display"))
	var rl := UIKit.label(String(N.role).to_upper(), 14, Color("c8a46a"), false, "label")
	rl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top.add_child(rl)
	t.add_child(top)
	t.add_child(UIKit.label("“%s”" % line(id), 16, UIKit.DIM, true, "italic"))
	h.add_child(t)
	v.add_child(h)
	if sub != "":
		var l := UIKit.label(sub, 15, UIKit.TEXT, true, "italic")
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(l)

## Gold, Rift Ore and Shard Scrap in one strip.
static func purse(s: Screens, d: Dictionary, extra: Array = []) -> HFlowContainer:
	var items: Array = [["Gold", int(d.gold), UIKit.GOLD], ["Rift Ore", Camp.mat(d, "ore"), Camp.part_col("ore")], ["Shard Scrap", Camp.mat(d, "scrap"), Camp.part_col("scrap")]]
	items.append_array(extra)
	return s._resources(d, items)

static func _note(v: VBoxContainer, txt: String, col: Color) -> void:
	var l := UIKit.label(txt, 17, col, true, "italic")
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(l)

## The message an action left, once.
static func _flash(v: VBoxContainer) -> void:
	if _msg == "": return
	_note(v, _msg, Color("aef0a0") if _msg_good else Color("ff9a8a"))
	_msg = ""

static func _say(m: String, good: bool) -> void:
	_msg = m
	_msg_good = good
	if good:
		Save.mark_dirty()
		Sfx.play("craft")

## A row on a station: a framed panel holding the content on the left and an action column on the right.
static func _row(left: Control, right: Control, tint: Color) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UIKit.nine("tile", 24, Vector4(18, 12, 18, 12), Color(0.72, 0.68, 0.64).lerp(tint, 0.3)))
	var h := UIKit.hbox(14)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(left)
	if right != null:
		right.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(right)
	p.add_child(h)
	return p

## The action column of a row: its button over what it costs (red where the purse falls short).
static func _act(txt: String, cost: Dictionary, d: Dictionary, cb: Callable, w: int = 200) -> VBoxContainer:
	var c := UIKit.vbox(2)
	var b := UIKit.button(txt, cb, 50)
	b.custom_minimum_size.x = w
	b.disabled = not cost.is_empty() and not Camp.can_pay(d, cost)
	c.add_child(b)
	if not cost.is_empty():
		var l := UIKit.label(Camp.cost_text(cost, true), 13, UIKit.DIM if Camp.can_pay(d, cost) else Color("ff8a7a"), true, "italic")
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.custom_minimum_size.x = w
		c.add_child(l)
	return c

## Five pips: the filled ones gold.
static func _pips(n: int, of: int, col: Color) -> HBoxContainer:
	var h := UIKit.hbox(9)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for k in of:
		var g := ColorRect.new()
		g.color = col if k < n else Color(0.25, 0.22, 0.2)
		g.custom_minimum_size = Vector2(9, 9)
		g.rotation = PI / 4.0
		g.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		g.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(g)
	return h

# ================================================================= Doran Ashhand, Weaponsmith
static func show_smith(s: Screens) -> void:
	var v := s._open(1000)
	s.parent_page = "camp"
	var d: Dictionary = Save.data
	_header(s, v, "smith", "A tempered weapon hits harder in every run that takes it: +8% damage a rank, 8% faster from rank 3, a masterwork at 5.")
	v.add_child(purse(s, d))
	_flash(v)
	var pl := Camp.pool(d)
	var grid := s._grid(1 if s.get_viewport_rect().size.x < 1250.0 else 2, 8)
	v.add_child(grid)
	for id in Content.WEAPON_IDS:
		var W: Dictionary = Content.WEAPONS[id]
		var col := Color(String(W.col))
		var r := Camp.temper_rank(d, id)
		var left := UIKit.vbox(3)
		var top := UIKit.hbox(12)
		top.add_child(UIKit.label(String(W.name), 21, col.lightened(0.15) if pl.has(id) else UIKit.DIM, false, "display"))
		top.add_child(_pips(r, Camp.TEMPER_MAX, UIKit.GOLD))
		top.add_child(UIKit.label(Camp.RANK_NAME[r], 15, Color("c8a46a"), false, "label"))
		left.add_child(top)
		var right: Control = null
		if not pl.has(id):
			var need := ""
			for u in Content.UNLOCKS:
				if u.w == id: need = String(u.d)
			left.add_child(UIKit.label("Not yet earned: %s." % need, 15, UIKit.DIM, true, "italic"))
		else:
			left.add_child(UIKit.label(Camp.temper_text(r), 15, UIKit.TEXT, true, "italic"))
			var hit := "Level-1 hit %.1f" % Camp.temper_hit(id, r)
			if r < Camp.TEMPER_MAX: hit += "  \u2192  %.1f" % Camp.temper_hit(id, r + 1)
			left.add_child(UIKit.label(hit, 14, UIKit.DIM, false, "italic"))
			var cost := Camp.temper_cost(d, id)
			if cost.is_empty():
				var ml := UIKit.label("MASTERWORK", 16, UIKit.GOLD, false, "label")
				ml.custom_minimum_size.x = 200
				ml.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				right = ml
			else:
				right = _act("Temper", cost, d, func():
					var e := Camp.temper(d, id)
					_say(("%s is now %s." % [W.name, Camp.RANK_NAME[Camp.temper_rank(d, id)]]) if e == "" else e, e == "")
					show_smith(s))
		grid.add_child(_row(left, right, col))
	s._back(v, "camp")

# ================================================================= Nim, Salvager (the salvage bench)
static func show_bench(s: Screens) -> void:
	var v := s._open(940)
	s.parent_page = "camp"
	var d: Dictionary = Save.data
	_header(s, v, "nim", "Break gear you will not wear into Shard Scrap and crafting shards, a whole rarity at a time. Locked and equipped items are never touched.")
	v.add_child(purse(s, d))
	_flash(v)
	var grid := s._grid(1 if s.get_viewport_rect().size.x < 1250.0 else 2, 8)      # two columns on a wide screen
	v.add_child(grid)
	for r in [Content.Rarity.NORMAL, Content.Rarity.MAGIC, Content.Rarity.RARE]:
		var items := Camp.bulk_list(d, r)
		var y := Camp.bulk_yield(items)
		var rc := Content.col(Content.RARITY_COL[r])
		var left := UIKit.vbox(3)
		left.add_child(UIKit.label("%s items  ·  %d" % [Content.RARITY_NAME[r], items.size()], 21, rc, false, "display"))
		left.add_child(UIKit.label(("Gives " + Camp.yield_text(y)) if not items.is_empty() else "None to salvage.", 15, UIKit.TEXT if not items.is_empty() else UIKit.DIM, true, "italic"))
		var label := "Salvage all"
		if _armed == r: label = "Tap to confirm"
		var right := _act(label, {}, d, func():
			if r >= Content.Rarity.MAGIC and _armed != r:          # Magic and Rare ask twice
				_armed = r
				show_bench(s)
				return
			_armed = -1
			var got := Camp.salvage_all(d, r)
			_say("Salvaged %d %s items for %s." % [items.size(), Content.RARITY_NAME[r], Camp.yield_text(got)], true)
			show_bench(s))
		(right.get_child(0) as Button).disabled = items.is_empty()
		grid.add_child(_row(left, right, rc))
	var mode := int(Save.opt("auto_salvage"))
	var al := UIKit.vbox(2)
	al.add_child(UIKit.label("Salvage on the way", 20, Color("e8dcc0"), false, "display"))
	al.add_child(UIKit.label("Nim breaks down finds that are no upgrade as you pick them up: no stash clutter, the scrap and shards straight to you.", 14, UIKit.DIM, true, "italic"))
	var names := ["Off", "Normal finds", "Normal and Magic"]
	var ab := UIKit.button(names[mode % 3], func():
		Save.set_opt("auto_salvage", (mode + 1) % 3)
		_say("Salvage on the way: %s." % names[(mode + 1) % 3].to_lower(), true)
		show_bench(s), 50)
	ab.custom_minimum_size.x = 200
	ab.add_theme_color_override("font_color", UIKit.GOLD if mode > 0 else UIKit.DIM)
	grid.add_child(_row(al, ab, Color("c9b79a")))
	var locked := 0
	for it in d.stash:
		if Camp.is_locked(d, it): locked += 1
	_note(v, "%d locked in the stash. Legendary items are never salvaged here: extract their power in the Cube, or salvage one at a time in Gear." % locked, UIKit.DIM)
	var row := s._grid(2, 10)
	var gear := UIKit.button("Gear & Stash", func(): s.parent_page = "camp"; s.show_stash(false), 50)
	var back := UIKit.button("Back", func(): show_camp(s), 50)
	for b in [gear, back]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)
	UIKit.foot(v).add_child(row)

# ================================================================= Mother Kiln, the Fusion Furnace
static func show_furnace(s: Screens) -> void:
	var v := s._open(1000)
	s.parent_page = "camp"
	var d: Dictionary = Save.data
	_header(s, v, "kiln", "")
	v.add_child(purse(s, d, [["Divine Orb", int(d.currency.get("divine", 0)), Camp.part_col("divine")]]))
	var tabs := s._grid(2, 8)
	for k in 2:
		var tb := UIKit.tile(["Gear", "Weapons"][k], ["Three items become one, a rarity higher", "Kindle a pair to fuse sooner, and harder"][k],
			func(): _furnace_tab = k; _fused = {}; show_furnace(s), Color("ffcf6a"), _furnace_tab == k, 64)
		tabs.add_child(tb)
	v.add_child(tabs)
	_flash(v)
	if _furnace_tab == 0: _furnace_gear(s, v, d)
	else: _furnace_weapons(s, v, d)
	s._back(v, "camp")

static func _furnace_gear(s: Screens, v: VBoxContainer, d: Dictionary) -> void:
	if not _fused.is_empty():
		var rc := Content.col(Content.RARITY_COL[int(_fused.rarity)])
		var card := UIKit.vbox(4)
		var nm := UIKit.label(Items.name_of(_fused), 24, rc, true, "display")
		nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		card.add_child(nm)
		var sub := UIKit.label("%s %s  ·  item level %d  ·  now in your stash" % [Content.RARITY_NAME[int(_fused.rarity)], Content.SLOT_NAME[_fused.slot], int(_fused.ilvl)], 15, UIKit.DIM, true, "italic")
		sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		card.add_child(sub)
		for ln in Items.lines(_fused):
			var l := UIKit.label(ln, 16, Color("8fb4ff"), true)
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			card.add_child(l)
		var cp := PanelContainer.new()
		cp.add_theme_stylebox_override("panel", UIKit.nine("card", 46, Vector4(26, 22, 26, 20), Color(0.78, 0.76, 0.74).lerp(rc, 0.5)))
		cp.add_child(card)
		v.add_child(cp)
	var groups := Camp.fuse_groups(d)
	var partial := Camp.fuse_partial(d)
	if not partial.is_empty():
		var bits := PackedStringArray()
		for p in partial.slice(0, 6): bits.append("%s %s %d/%d" % [Content.RARITY_NAME[int(p[1])], plural(String(p[0])), int(p[2]), Camp.FUSE_N])
		_note(v, "Gathering: " + ",  ".join(bits), UIKit.DIM)
	if groups.is_empty():
		_note(v, "Bring three unlocked items of one slot and one rarity (Normal, Magic or Rare). The weakest three of a kind go in first.", UIKit.DIM)
		return
	for g in groups:
		var r := int(g.rarity)
		var rc := Content.col(Content.RARITY_COL[r])
		var rc2 := Content.col(Content.RARITY_COL[r + 1])
		var three: Array = (g.items as Array).slice(0, Camp.FUSE_N)
		var top := 0
		for it in three: top = maxi(top, int(it.ilvl))
		var left := UIKit.vbox(3)
		var head := UIKit.hbox(8)
		head.add_child(UIKit.label("3 %s %s" % [Content.RARITY_NAME[r], plural(String(g.slot))], 20, rc, false, "display"))
		head.add_child(UIKit.label("→", 20, UIKit.DIM, false, "display"))
		head.add_child(UIKit.label("1 %s %s" % [Content.RARITY_NAME[r + 1], Content.SLOT_NAME[g.slot]], 20, rc2, false, "display"))
		left.add_child(head)
		var names := PackedStringArray()
		for it in three: names.append(Items.name_of(it))
		left.add_child(UIKit.label("In: %s  ·  item level up to %d%s" % [", ".join(names), top, ("  ·  %d more of this kind" % (g.items.size() - 3)) if g.items.size() > 3 else ""], 14, UIKit.DIM, true, "italic"))
		var right := _act("Fuse", Camp.fuse_cost(r), d, func():
			var out = Camp.fuse_items(d, three)
			if typeof(out) == TYPE_STRING:
				_say(String(out), false)
			else:
				_fused = out
				_say("The furnace gives up %s." % Items.name_of(out), true)
			show_furnace(s))
		v.add_child(_row(left, right, rc2))
	_note(v, "Rare into Legendary also takes a Divine Orb. Lock an item in Gear to keep it out of the fire.", UIKit.DIM)

static func _furnace_weapons(s: Screens, v: VBoxContainer, d: Dictionary) -> void:
	var pl := Camp.pool(d)
	var vw := s.get_viewport_rect().size.x
	var g := s._grid(2 if vw < 820.0 else (5 if vw >= 1250.0 else 4), 8)
	for id in pl:
		var W: Dictionary = Content.WEAPONS[id]
		var b := UIKit.tile(String(W.name), "", func():
			if _pick.has(id): _pick.erase(id)
			else:
				_pick.append(id)
				while _pick.size() > 2: _pick.pop_front()
			show_furnace(s), Color(String(W.col)), _pick.has(id), 50)
		g.add_child(b)
	if _pick.size() == 2:
		var key := Content.fusion_key(_pick[0], _pick[1])
		var F: Dictionary = Content.fusion_def(key)
		var left := UIKit.vbox(3)
		left.add_child(UIKit.label(String(F.name), 22, Color(String(F.col)), false, "display"))
		left.add_child(UIKit.label(String(F.d), 15, UIKit.TEXT, true, "italic"))
		var right: Control
		if Camp.kindled(d, key):
			var kl := UIKit.label("KINDLED", 16, UIKit.GOLD, false, "label")
			kl.custom_minimum_size.x = 200
			kl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			right = kl
		else:
			right = _act("Kindle", Camp.kindle_cost(d), d, func():
				var e := Camp.kindle(d, _pick[0], _pick[1])
				_say(("%s is kindled. It will find its pair at level 5." % F.name) if e == "" else e, e == "")
				show_furnace(s))
		v.add_child(_row(left, right, Color(String(F.col))))
	else:
		_note(v, "Pick two weapons to kindle. In a run a kindled pair may fuse as soon as both reach level 5, evolved or not, and its fusion deals 35% more damage instead of 25%.", UIKit.TEXT)
	v.add_child(g)
	v.add_child(s._section("Named hybrids"))
	var hy := PackedStringArray()
	for key in Content.FUSIONS:
		var ab := String(key).split("+")
		hy.append("%s%s (%s + %s)" % ["\u2605 " if Camp.kindled(d, key) else "", Content.FUSIONS[key].name, Content.WEAPONS[ab[0]].name, Content.WEAPONS[ab[1]].name])
	_note(v, "These six pairs fuse into something new; any other pair shares its elements for 25% more damage (35% kindled). \u2605 kindled.  " + ",  ".join(hy), UIKit.DIM)
	if not (d.kindled as Array).is_empty():
		v.add_child(s._section("Kindled pairs  ·  %d" % (d.kindled as Array).size()))
		var names := PackedStringArray()
		for k in d.kindled:
			var ab := String(k).split("+")
			names.append("%s (%s + %s)" % [Content.fusion_def(k).name, Content.WEAPONS[ab[0]].name, Content.WEAPONS[ab[1]].name])
		_note(v, ", ".join(names), Color("ffd27a"))

# ================================================================= Sella Coinwright, Trader
static func show_trader(s: Screens) -> void:
	var v := s._open(1000)
	s.parent_page = "camp"
	var d: Dictionary = Save.data
	_header(s, v, "sella", "")
	v.add_child(purse(s, d))
	_flash(v)
	var stock := Camp.trader_stock(d)
	if stock.is_empty():
		_note(v, "Sold out. Fresh stock at dawn, or pay Sella to dig out more.", UIKit.DIM)
	for k in stock.size():
		var e: Dictionary = stock[k]
		var it: Dictionary = e.it
		var rc := Content.col(Content.RARITY_COL[int(it.rarity)])
		var left := UIKit.vbox(2)
		left.add_child(UIKit.label(Items.name_of(it), 20, rc, false, "display"))
		var sub := UIKit.vbox(0)                    # stacked and wrapping: side by side they widened the page off a phone held upright
		sub.add_child(UIKit.label("%s %s  ·  item level %d  ·  score %d" % [Content.RARITY_NAME[int(it.rarity)], Content.SLOT_NAME[it.slot], int(it.ilvl), int(Items.score(it))], 14, UIKit.DIM, true, "italic"))
		var cur: Dictionary = d.equipped.get(it.slot, {})
		var diff := Items.score(it) - Items.score(cur)
		sub.add_child(UIKit.label(("%+d vs equipped" % int(diff)) if not cur.is_empty() else "nothing equipped there", 14, Color("7dff6b") if diff > 0 else Color("ff8a7a"), true, "italic"))
		left.add_child(sub)
		var ls := Items.lines(it)
		var shown := PackedStringArray()
		for i in range(1, mini(ls.size(), 4)): shown.append(ls[i].split("  (")[0])
		if not shown.is_empty(): left.add_child(UIKit.label("  ·  ".join(shown), 14, Color("8fb4ff"), true))
		var right := _act("Buy", {"gold": int(e.price)}, d, func():
			var nm := Items.name_of(it)
			var er := Camp.trader_buy(d, k)
			_say(("%s is in your stash." % nm) if er == "" else er, er == "")
			show_trader(s), 170)
		v.add_child(_row(left, right, rc))
	v.add_child(s._section("Crafting shards"))
	var g := s._grid(2 if s.get_viewport_rect().size.x < 820.0 else 3, 8)
	for id in Camp.SHARD_IDS:
		var p := int(Camp.SHARD_PRICES[id])
		var b := UIKit.button("%s  ·  %d Gold" % [Content.CURRENCY[id].name, p], func():
			var er := Camp.buy_shard(d, id)
			_say(("Bought a %s (%d held)." % [Content.CURRENCY[id].name, int(d.currency[id])]) if er == "" else er, er == "")
			show_trader(s), 48)
		b.disabled = int(d.gold) < p
		b.add_theme_color_override("font_color", Content.col(Content.CURRENCY[id].col))
		b.add_theme_font_size_override("font_size", 18)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		g.add_child(b)
	v.add_child(g)
	var row := s._grid(2, 10)
	var rc2 := Camp.restock_cost(d)
	var rs := UIKit.button("Restock  ·  %d Gold" % rc2, func():
		var er := Camp.restock(d)
		_say("Sella digs out fresh stock." if er == "" else er, er == "")
		show_trader(s), 50)
	rs.disabled = int(d.gold) < rc2
	var back := UIKit.button("Back", func(): show_camp(s), 50)
	for b in [rs, back]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)
	UIKit.foot(v).add_child(row)

# ================================================================= Captain Brask, Drillmaster
const HOW_TO := [
	["Move", "Drag anywhere on the left half of the screen; the stick follows your thumb. (WASD or arrows on a keyboard.)"],
	["Fight", "Your weapons fire on their own at the nearest foe. Options › Game sets what they aim at."],
	["Grow", "Foes drop blue shards. Gather them to level up, then pick one of the cards: a new weapon (up to four), a weapon level, a perk or a support gem."],
	["Evolve and fuse", "A weapon at level 5 with its paired perk can evolve. Two evolved weapons can fuse into a hybrid. A pair kindled at Mother Kiln's furnace fuses at level 5, evolved or not."],
	["Survive", "ROLL dashes through attacks (Space); rolling just before a hit is a perfect dodge. JUMP clears rocks, walls and gaps (F). Flasks 1 and 2 heal and buff, and refill as you kill."],
	["Ultimate", "ULT charges as you fight. When its ring glows, tap it (R)."],
	["The dark", "The light fades as a run goes on and kills relight it. In the dark you are Engulfed: foes hit harder and drop richer loot."],
	["Loot and the Camp", "Champions and bosses drop gear. Equip and craft it in Gear & Stash. At the Camp: temper weapons, fuse and salvage gear, and trade."],
]

static func show_drill(s: Screens) -> void:
	var v := s._open(940)
	s.parent_page = "camp"
	var d: Dictionary = Save.data
	_header(s, v, "brask", "")
	_flash(v)
	for e in HOW_TO:
		var left := UIKit.vbox(2)
		left.add_child(UIKit.label(String(e[0]), 19, Color("cfe8c0"), false, "display"))
		left.add_child(UIKit.label(String(e[1]), 15, UIKit.TEXT, true, "italic"))
		v.add_child(_row(left, null, Color("9fe08a")))
	var wl := UIKit.vbox(2)
	wl.add_child(UIKit.label("What's new", 19, Color("cfe8c0"), false, "display"))
	wl.add_child(UIKit.label("What changed in the last few versions, as testers were told.", 15, UIKit.TEXT, true, "italic"))
	var wb := UIKit.button("Read", func(): s.parent_page = "camp"; s.show_whats_new(true), 50)
	wb.custom_minimum_size.x = 160
	v.add_child(_row(wl, wb, Color("9fe08a")))
	var T: Dictionary = d.tutorial
	var row := s._grid(2 if s.get_viewport_rect().size.x < 820.0 else 4, 8)
	var tips := UIKit.button("Tutorial tips: %s" % ("On" if bool(T.on) else "Off"), func():
		T.on = not bool(T.on)
		_say("Tutorial tips are %s." % ("on" if T.on else "off"), true)
		show_drill(s), 50)
	var replay := UIKit.button("Replay tutorial", func():
		T.on = true
		T.done = []
		_say("The tips start again in your next campaign run.", true)
		show_drill(s), 50)
	var train := UIKit.button("Training run", func():
		T.on = true
		Save.mark_dirty()
		s.act.emit("new_campaign", null), 50)
	var back := UIKit.button("Back", func(): show_camp(s), 50)
	for b in [tips, replay, train, back]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 18)
		row.add_child(b)
	UIKit.foot(v).add_child(row)

# ================================================================= the NPCs' medallions
## A round bronze-rimmed medallion with the NPC's initial, in their colour (no portraits: the art budget is
## for the run).
class Medallion extends Control:
	var col := Color.WHITE
	var glyph := ""
	func _init(c: Color, g: String, sz: float) -> void:
		col = c
		glyph = g
		custom_minimum_size = Vector2(sz, sz)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func _draw() -> void:
		var r := minf(size.x, size.y) * 0.5
		var c := size * 0.5
		draw_circle(c, r, Color(0.05, 0.04, 0.05, 0.95))
		draw_circle(c, r * 0.84, col.darkened(0.74))
		draw_arc(c, r - 1.5, 0.0, TAU, 48, Color("b98a4a"), 2.5, true)
		draw_arc(c, r * 0.84, 0.0, TAU, 48, Color(col, 0.6), 1.5, true)
		var f := UIKit.font("display")
		var fs := int(r * 0.95)
		var ts := f.get_string_size(glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		var base := c.y + (f.get_ascent(fs) - f.get_descent(fs)) * 0.5
		draw_string(f, Vector2(c.x - ts.x * 0.5, base), glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col.lightened(0.3))
