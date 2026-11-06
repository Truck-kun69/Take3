extends Node
## Game flow: menu -> run -> level-up / pause / merchant overlays -> results. Owns the World, its
## view, the HUD, touch controls and every screen. Also owns the GPU crowd solver, created once
## (a RenderingDevice is expensive) and reused across runs.

var world: World
var view: WorldView                # classic 2D renderer (option "renderer" = 1, and low-end fallback)
var view3d: WorldView3D            # default: PoE2-style 3D renderer
var overlay: Overlay3D
var hud: Hud
var touch: TouchControls
var screens: Screens
var ui: Control
var state := "menu"
var last_cfg := {}
var crowd: CrowdCompute
var bot_drive := false          # tests/screenshots: input comes from a Bot instead of devices

func _ready() -> void:
	_input_map()
	view = WorldView.new()
	add_child(view)
	view3d = WorldView3D.new()
	add_child(view3d)
	var layer := CanvasLayer.new()
	add_child(layer)
	ui = Control.new()
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.theme = UIKit.theme()
	layer.add_child(ui)
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay = Overlay3D.new()
	overlay.view = view3d
	ui.add_child(overlay)
	touch = TouchControls.new()
	ui.add_child(touch)
	hud = Hud.new()
	ui.add_child(hud)
	screens = Screens.new()
	screens.main = self
	ui.add_child(screens)
	screens.act.connect(_on_act)
	hud.pause_pressed.connect(_pause)
	touch.roll.connect(func(): if world: world.in_roll = true)
	touch.ult.connect(func(): if world: world.in_ult = true)
	touch.flask.connect(func(i: int): if world: world.in_flask[i] = true)
	crowd = CrowdCompute.new()
	if not crowd.init():
		print("crowd compute unavailable: ", crowd.last_error, " (CPU separation in use)")
		crowd = null
	else:
		print("crowd compute: GPU separation active")
	get_tree().root.size_changed.connect(_on_resize)
	_menu()

func _on_resize() -> void:
	if state == "menu": screens.show_menu()

func _input_map() -> void:
	var keys := {
		"move_left": [KEY_A, KEY_LEFT], "move_right": [KEY_D, KEY_RIGHT], "move_up": [KEY_W, KEY_UP], "move_down": [KEY_S, KEY_DOWN],
		"roll": [KEY_SPACE, KEY_SHIFT], "ult": [KEY_R, KEY_Q], "flask1": [KEY_1], "flask2": [KEY_2], "pause": [KEY_ESCAPE, KEY_P], "gear": [KEY_TAB, KEY_I],
	}
	var pads := {"roll": JOY_BUTTON_A, "ult": JOY_BUTTON_Y, "flask1": JOY_BUTTON_LEFT_SHOULDER, "flask2": JOY_BUTTON_RIGHT_SHOULDER, "pause": JOY_BUTTON_START, "gear": JOY_BUTTON_BACK}
	var axes := {"move_left": [JOY_AXIS_LEFT_X, -1.0], "move_right": [JOY_AXIS_LEFT_X, 1.0], "move_up": [JOY_AXIS_LEFT_Y, -1.0], "move_down": [JOY_AXIS_LEFT_Y, 1.0]}
	for a in keys:
		if not InputMap.has_action(a):
			InputMap.add_action(a, 0.2)
		for k in keys[a]:
			var e := InputEventKey.new()
			e.physical_keycode = k
			InputMap.action_add_event(a, e)
		if pads.has(a):
			var j := InputEventJoypadButton.new()
			j.button_index = pads[a]
			InputMap.action_add_event(a, j)
		if axes.has(a):
			var m := InputEventJoypadMotion.new()
			m.axis = axes[a][0]
			m.axis_value = axes[a][1]
			InputMap.action_add_event(a, m)

# ================================================================= flow
func _menu() -> void:
	state = "menu"
	_free_world()
	hud.visible = false
	touch.visible = false
	screens.show_menu()

func _free_world() -> void:
	if world != null:
		world.dispose()
	world = null
	view.w = null
	view3d.w = null
	hud.w = null
	touch.world = null

func start(cfg: Dictionary) -> void:
	_free_world()
	last_cfg = cfg.duplicate()
	cfg["hero"] = int(Save.data.hero)
	world = World.new()
	world.crowd = crowd
	world.setup(cfg)
	world.level_up.connect(_on_level)
	world.ended.connect(_on_end)
	world.merchant_open.connect(func(): if state == "play": state = "merchant"; screens.show_merchant(world))
	_bind_view()
	hud.bind(world)
	touch.world = world
	hud.visible = true
	touch.visible = true
	screens.close()
	state = "play"

func use_3d() -> bool:
	return int(Save.opt("renderer")) == 0

func _bind_view() -> void:
	if use_3d():
		view.w = null
		view3d.bind(world)
		view3d.cam.make_current()
		hud.project = func(p: Vector2) -> Vector2: return view3d.to_screen(p)
	else:
		view3d.w = null
		view.bind(world)
		view.cam.make_current()
		hud.project = func(p: Vector2) -> Vector2: return get_viewport().get_canvas_transform() * p

func _on_level() -> void:
	if state != "play": return
	state = "levelup"
	Sfx.play("level")
	screens.show_levelup(world)

func _on_end(win: bool) -> void:
	if win and world.mode == "atlas":
		var a := get_atlas()
		Atlas.complete(a, int(world.node.id))
		Save.data.atlas = {"seed": a.seed, "prog": Atlas.progress(a)}
		Save.mark_dirty()
	state = "end"
	await get_tree().create_timer(0.8).timeout
	if world != null:
		screens.show_end(world)

func _pause() -> void:
	if state != "play": return
	state = "pause"
	screens.show_pause(world)

func _resume() -> void:
	if world == null: return
	state = "play"
	screens.close()

func _process(dt: float) -> void:
	if world == null:
		return
	if state == "play":
		if not bot_drive:
			world.in_move = touch.value if touch.stick_id >= 0 else Input.get_vector("move_left", "move_right", "move_up", "move_down")
		if Input.is_action_just_pressed("roll"): world.in_roll = true
		if Input.is_action_just_pressed("ult"): world.in_ult = true
		if Input.is_action_just_pressed("flask1"): world.in_flask[0] = true
		if Input.is_action_just_pressed("flask2"): world.in_flask[1] = true
		if Input.is_action_just_pressed("pause"): _pause(); return
		if Input.is_action_just_pressed("gear"): state = "pause"; screens.show_stash(true); return
		world.step(minf(dt, 0.05))
	elif state == "pause" and Input.is_action_just_pressed("pause"):
		_resume()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED:
		_pause()
	elif what == NOTIFICATION_WM_GO_BACK_REQUEST:      # Android back button
		if state == "play": _pause()
		elif state == "pause": _resume()
		elif state == "menu": pass
		else: _menu()

# ================================================================= screen actions
func _on_act(what: String, arg) -> void:
	match what:
		"menu": _menu()
		"campaign": start({"mode": "campaign", "stage": int(arg)})
		"rift": start({"mode": "rift", "gr": int(arg)})
		"atlas":
			var a := get_atlas()
			start({"mode": "atlas", "node": a.nodes[int(arg)]})
		"pinnacle":
			for k in ["rupture", "greed", "dread"]:
				Save.data.fragments[k] = int(Save.data.fragments[k]) - 1
			Save.mark_dirty()
			start({"mode": "pinnacle"})
		"stash": screens.show_stash(false)
		"codex": screens.show_codex()
		"options": screens.show_options("menu")
		"options_changed":
			if world != null:
				world.colorblind = bool(Save.opt("colorblind"))
				world.aim_mode = int(Save.opt("aim"))
				_bind_view()
		"equip": equip(arg)
		"salvage":
			Save.data.stash.erase(arg)
			var gain := {0: ["transmute", 1], 1: ["augment", 2], 2: ["chaos", 1], 3: ["divine", 2]}[int(arg.rarity)] as Array
			Save.add_currency(gain[0], gain[1])
		"extract":
			if not Save.data.codex.has(arg.leg):
				Save.data.codex.append(arg.leg)
				if Save.data.codex_active.size() < Content.CODEX_SLOTS: Save.data.codex_active.append(arg.leg)
			Save.data.stash.erase(arg)
			Save.mark_dirty()
			Sfx.play("craft")
		"codex_toggle":
			var act: Array = Save.data.codex_active
			if act.has(arg): act.erase(arg)
			elif act.size() < Content.CODEX_SLOTS: act.append(arg)
			Save.mark_dirty()
		"pick":
			world.apply_choice(arg)
			Sfx.play("click")
			if world.pending > 0: screens.show_levelup(world)
			else: _resume()
		"resume": _resume()
		"resume_pause":
			if world != null and state == "pause": screens.show_pause(world)
			else: _menu()
		"abandon":
			if world != null: world.end_run(false)
		"retry": start(last_cfg)

func equip(it: Dictionary) -> void:
	var cur: Dictionary = Save.data.equipped[it.slot]
	Save.data.stash.erase(it)
	if not cur.is_empty(): Save.data.stash.append(cur)
	Save.data.equipped[it.slot] = it
	Save.mark_dirty()
	if world != null:
		world.stats.set_source("item:" + it.slot, Items.mods(it))

func craft(it: Dictionary, cur: String) -> String:
	if int(Save.data.currency.get(cur, 0)) <= 0:
		return "You have no " + Content.CURRENCY[cur].name + "."
	var msg := Items.craft(it, cur)
	if msg != "":
		return msg
	Save.data.currency[cur] = int(Save.data.currency[cur]) - 1
	Save.mark_dirty()
	Sfx.play("craft")
	if world != null and Save.data.equipped[it.slot] == it:
		world.stats.set_source("item:" + it.slot, Items.mods(it))
	return Content.CURRENCY[cur].name + " applied."

func get_atlas() -> Dictionary:
	var d: Dictionary = Save.data.atlas
	if not d.has("seed"):
		d = {"seed": randi() % 1000000, "prog": {}}
		Save.data.atlas = d
		Save.mark_dirty()
	return Atlas.with_progress(int(d.seed), d.get("prog", {}))
