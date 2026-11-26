class_name Coach
extends Control
## The first-run coach (docs/superpowers/specs/2026-11-25-camp-tutorial-crafting-design.md). In a campaign run,
## while Options > Game > Tutorial tips is on and steps remain, Captain Brask shows one prompt at a time over the
## HUD, with a pulsing ring on the touch button it names. A step finishes when the player does the thing
## (Save.data.tutorial.done keeps it, so it is taught once); a contextual step waits for its moment (hurt: the
## flask; a Rift Gate open: banking the hoard; charged: the ultimate; a find: the loot); a prompt left undone for
## SHOW_MAX seconds steps aside and comes back SNOOZE seconds later. The level-up step is taught on the level-up page
## itself (Screens.show_levelup). The goal (survive the clock, then the boss) follows the first fight: the review
## found the run never said it, nor that a hoard not banked at a gate is lost on death.

const STEPS := {
	"move": {"touch": "Drag anywhere on the left half of the screen to move.", "keys": "Move with WASD or the arrow keys.", "ring": "stick"},
	"fight": {"touch": "Your weapons fire on their own. Keep moving and let them work.", "keys": "Your weapons fire on their own. Keep moving and let them work.", "ring": ""},
	"goal": {"touch": "Survive until the clock reads 0:00, then beat the boss to clear the act.", "keys": "Survive until the clock reads 0:00, then beat the boss to clear the act.", "ring": ""},
	"shards": {"touch": "Foes drop blue crystals. Walk over them to gain experience.", "keys": "Foes drop blue crystals. Walk over them to gain experience.", "ring": ""},
	"roll": {"touch": "Tap ROLL to dash through danger. Rolling just before a hit is a perfect dodge.", "keys": "Press Space to roll through danger. Rolling just before a hit is a perfect dodge.", "ring": "roll"},
	"flask": {"touch": "Hurt? Tap flask 1 to heal. Kills refill it.", "keys": "Hurt? Press 1 to drink your life flask. Kills refill it.", "ring": "f0"},
	"jump": {"touch": "Tap JUMP to leap over rocks, walls and gaps.", "keys": "Press F to leap over rocks, walls and gaps.", "ring": "jump"},
	"ult": {"touch": "Your ultimate is charged: tap ULT.", "keys": "Your ultimate is charged: press R.", "ring": "ult"},
	"loot": {"touch": "Gear found. Equip it from the pause menu (Gear & Crafting), or at the Camp after the run.", "keys": "Gear found. Equip it from the pause menu (Gear & Crafting), or at the Camp after the run.", "ring": ""},
	"gate": {"touch": "Step into the Rift Gate to bank your hoard. Fall first and it is lost.", "keys": "Step into the Rift Gate to bank your hoard. Fall first and it is lost.", "ring": ""},
}
const LOOT_AUTO := "Better gear equips itself. See every find in Pause > Gear & Crafting."
const ORDER := ["move", "fight", "goal", "shards", "roll", "flask", "jump", "ult", "loot", "gate"]
const CONTEXT := ["flask", "gate", "ult", "loot"]  # these wait for their moment, and take the stage when it comes
const LEVELUP := "levelup"                         # taught on the level-up page (Screens.show_levelup; main's "pick")
const SHOW_MAX := 12.0
const SNOOZE := 25.0
const GAP := 1.6
const INFO_T := 7.0                                # fight, the goal, the gate and loot inform: done after this long on screen

## Every step the coach teaches, the level-up page's included.
static func all_steps() -> Array:
	return ORDER + [LEVELUP]

static func wants(d: Dictionary, id: String) -> bool:
	var T: Dictionary = d.get("tutorial", {})
	return bool(T.get("on", false)) and not (T.get("done", []) as Array).has(id)

static func remaining(d: Dictionary) -> Array:
	return all_steps().filter(func(id): return wants(d, id))

static func mark(d: Dictionary, id: String) -> void:
	if not d.has("tutorial"): d["tutorial"] = {"on": true, "done": []}
	if not (d.tutorial.done as Array).has(id):
		d.tutorial.done.append(id)
		Save.mark_dirty()

## A run the coach rides along: a campaign run (not the Daily Rift) while tips are on and steps remain.
static func active_for(cfg: Dictionary, d: Dictionary) -> bool:
	return String(cfg.get("mode", "")) == "campaign" and not bool(cfg.get("daily", false)) and not remaining(d).is_empty()

var w: World
var touch: TouchControls
var main: Node
var active := ""              # the step on screen ("" none)
var shown_t := 0.0
var gap := 2.0                # seconds before the next prompt may show
var snooze := {}              # step -> seconds until it may show again
var done_flash := 0.0         # the tick after a finished step
var _moved := 0.0
var _last_pp := Vector2.ZERO
var _k0 := 0
var _xp0 := 0.0
var _lv0 := 1
var _roll_prev := 9.0
var _rolled := false
var _f_prev := 0.0
var _drank := false
var _ult_prev := 0.0
var _ulted := false
var _item := false
var _bank0 := 0
var _panel: PanelContainer
var _body: Label
var _anim := 0.0

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_theme_stylebox_override("panel", UIKit.nine("tile", 24, Vector4(20, 10, 20, 12), Color(String(CampPages.NPCS.brask.col)).lerp(Color(0.75, 0.72, 0.68), 0.5)))
	var v := UIKit.vbox(2)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var who := UIKit.label("CAPTAIN BRASK", 13, Color("cfe8c0"), false, "label")
	who.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(who)
	_body = UIKit.label("", 19, UIKit.TEXT, true, "italic")
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.custom_minimum_size.x = 300
	v.add_child(_body)
	_panel.add_child(v)
	add_child(_panel)
	_panel.visible = false

## A run starts: the coach watches it (main.start calls this only when Coach.active_for the run).
func bind(world: World, tc: TouchControls) -> void:
	w = world
	touch = tc
	active = ""
	shown_t = 0.0
	gap = 2.0
	snooze.clear()
	_moved = 0.0
	_last_pp = world.pp
	_roll_prev = world.roll_age
	_f_prev = float(world.flasks[0].c)
	_ult_prev = world.ult
	_item = false
	if not world.item_found.is_connected(_on_item): world.item_found.connect(_on_item)
	visible = true

func unbind() -> void:
	if w != null and w.item_found.is_connected(_on_item): w.item_found.disconnect(_on_item)
	w = null
	active = ""
	if _panel != null: _panel.visible = false
	visible = false

func _on_item(_it: Dictionary, _up: bool) -> void:
	_item = true

func _process(dt: float) -> void:
	var on: bool = w != null and main != null and main.state == "play"
	if _panel != null: _panel.visible = on and active != ""       # under a page (level-up, pause) it waits
	if not on: return
	tick(dt)
	_anim += dt
	if active != "" and _ring_at().z > 0.0: queue_redraw()

## One step of the coach's watch: the trackers, then the prompt on screen (finished? stepped aside?) or the next.
func tick(dt: float) -> void:
	if w == null: return
	var d: Dictionary = Save.data
	_moved += w.pp.distance_to(_last_pp)
	_last_pp = w.pp
	if w.roll_age < _roll_prev: _rolled = true            # a roll started (its age resets)
	_roll_prev = w.roll_age
	var fc := float(w.flasks[0].c)
	if fc < _f_prev - 0.5: _drank = true                  # the life flask was drunk (kills only ever add)
	_f_prev = fc
	if w.ult < _ult_prev - 50.0: _ulted = true
	_ult_prev = w.ult
	for k in snooze.keys():
		snooze[k] = float(snooze[k]) - dt
		if float(snooze[k]) <= 0.0: snooze.erase(k)
	if done_flash > 0.0: done_flash -= dt
	if active != "":
		shown_t += dt
		if _done(active):
			mark(d, active)
			active = ""
			done_flash = 0.6
			gap = GAP
			_show_panel("")
			if remaining(d).filter(func(id): return id != LEVELUP).is_empty():
				w.banner.emit("Drills done", "Captain Brask: “You will do. Find me at the Camp if you forget.”", Color(String(CampPages.NPCS.brask.col)))
			return
		if shown_t > SHOW_MAX:
			snooze[active] = SNOOZE
			active = ""
			gap = GAP
			_show_panel("")
		return
	gap -= dt
	if gap > 0.0: return
	var nxt := next_step(d)
	if nxt != "": _start(nxt)

## The next step to teach now: a contextual one whose moment has come, else the drill's next in order.
func next_step(d: Dictionary) -> String:
	for id in CONTEXT + ORDER:
		if wants(d, id) and not snooze.has(id) and _ready_for(id, d): return id
	return ""

func _ready_for(id: String, d: Dictionary) -> bool:
	var T: Array = d.tutorial.done
	match id:
		"move": return true
		"fight": return T.has("move") or w.t > 8.0
		"goal": return T.has("fight") or w.t > 15.0
		"shards": return w.gem_n > 0 and (T.has("fight") or w.t > 12.0)
		"roll": return (T.has("shards") or w.t > 30.0) and (w.t > 20.0 and foes_near(220.0) >= 3)
		"flask": return w.hp < w.max_hp * 0.7 and float(w.flasks[0].c) >= float(w.flasks[0].cost)
		"jump": return T.has("roll") and w.t > 50.0
		"ult": return w.ult >= 100.0
		"loot": return _item
		"gate": return gate_open()
	return false

func _done(id: String) -> bool:
	match id:
		"move": return _moved >= 160.0
		"fight": return w.kills - _k0 >= 8 or shown_t > INFO_T
		"goal": return shown_t > INFO_T
		"gate": return shown_t > INFO_T or int(w.metrics.get("banked", 0)) > _bank0
		"shards": return w.lvl > _lv0 or w.xp > _xp0 + 0.001
		"roll": return _rolled
		"flask": return _drank
		"jump": return w.jump_t > 0.0
		"ult": return _ulted or w.ult < 100.0
		"loot": return shown_t > INFO_T
	return true

func _start(id: String) -> void:
	active = id
	shown_t = 0.0
	_k0 = w.kills
	_xp0 = w.xp
	_lv0 = w.lvl
	_rolled = false
	_drank = false
	_ulted = false
	_bank0 = int(w.metrics.get("banked", 0))
	if id == "move": _moved = 0.0
	_show_panel(prompt(id, _touch_ui()))

## A step's words: for touch or for keys. With "Auto-equip upgrades" on (the default), a find that is an upgrade is
## already worn when the loot step speaks, so it says so instead of "Equip it" (the review found the two disagreeing).
static func prompt(id: String, touch_ui: bool) -> String:
	if id == "loot" and bool(Save.opt("auto_equip")): return LOOT_AUTO
	var S: Dictionary = STEPS[id]
	return String(S.touch) if touch_ui else String(S.keys)

func _touch_ui() -> bool:
	return touch != null and touch.shows_buttons()

func _show_panel(txt: String) -> void:
	if _panel == null: return
	_panel.visible = txt != ""
	queue_redraw()
	if txt == "": return
	_body.text = txt
	var vs := get_viewport_rect().size
	var wdt := minf(560.0, vs.x - 40.0)
	_panel.size = Vector2(wdt, 0)
	_panel.reset_size()
	_panel.size.x = wdt
	var h := _panel.get_combined_minimum_size().y
	# under the in-run subtitle (Subtitles._layout: its foot is 196 units up, 330 upright) and over the bottom edge
	var m := UIKit.safe_margins(vs)
	var foot := vs.y - m.w - (96.0 if vs.x >= 820.0 else 236.0)
	_panel.position = Vector2((vs.x - wdt) * 0.5, foot - h)
	_panel.modulate.a = 0.0
	create_tween().tween_property(_panel, "modulate:a", 1.0, 0.25)

## Where the active step's ring goes, as (x, y, radius); z = 0 for none.
func _ring_at() -> Vector3:
	if active == "" or not _touch_ui(): return Vector3.ZERO
	var r: String = STEPS[active].ring
	if r == "": return Vector3.ZERO
	if r == "stick":
		var p := touch._stick_home()
		return Vector3(p.x, p.y, touch.R * 1.25)
	var b := touch.button_at(r)
	if b.is_empty(): return Vector3.ZERO
	return Vector3(b.pos.x, b.pos.y, float(b.r) + 10.0)

func _draw() -> void:
	var q := _ring_at()
	if q.z <= 0.0: return
	var c := Vector2(q.x, q.y)
	var pulse := 0.5 + 0.5 * sin(_anim * 5.0)
	var col := Color(String(CampPages.NPCS.brask.col))       # Captain Brask's colour
	draw_arc(c, q.z + 6.0 * pulse, 0.0, TAU, 56, Color(col, 0.35 + 0.5 * pulse), 4.0, true)
	draw_arc(c, q.z + 16.0 * pulse, 0.0, TAU, 56, Color(col, 0.25 * (1.0 - pulse)), 2.0, true)

## A Rift Gate is open in the run (Director: a "gate" object, 22 s, banks the hoard when the hero steps in).
func gate_open() -> bool:
	for o in w.director.objects:
		if String(o.kind) == "gate": return true
	return false

## How many foes stand within `r` of the hero.
func foes_near(r: float) -> int:
	var n := 0
	var sw: Swarm = w.sw
	var r2 := r * r
	for i in sw.n:
		if sw.pos[i].distance_squared_to(w.pp) <= r2: n += 1
	return n
