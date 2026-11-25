extends Node
## The Camp's pages for a look: the hub, the five stations and the end of a run.
##   xvfb-run -a godot --path godot --rendering-method mobile --resolution 2340x1080 res://tests/camp_shots.tscn -- <outdir> [prefix]
## SHOT_SAFE=left,top,right,bottom as in tests/ui_shots.gd.
var main: Node
var out := "user://camp_shots"
var pre := ""
var t := 0.0
var step := 0

func _ready() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: out = a[0]
	if a.size() > 1: pre = a[1]
	if OS.get_environment("SHOT_SAFE") != "":
		var m := OS.get_environment("SHOT_SAFE").split(",")
		UIKit.safe_override = Vector4(float(m[0]), float(m[1]), float(m[2]), float(m[3]))
	DirAccess.make_dir_recursive_absolute(out)
	var sv := get_node("/root/Save")
	sv.path = "user://camp_shot_profile.json"
	sv.data = sv.defaults()
	sv.data.options.sound = false
	sv.data.intro_seen = true
	sv.data.cleared = [true, true, false, false, false]
	sv.data.unlocked = ["lance", "mine", "glaive"]
	sv.data.gold = 2460; sv.data.materials = {"scrap": 38, "ore": 7}
	sv.data.currency.divine = 1; sv.data.currency.chaos = 2
	sv.data.temper = {"bolt": 3, "orbit": 1, "nova": 5}
	sv.data.kindled = ["bolt+nova"]
	sv.data.hero = 1
	var rng := RandomNumberGenerator.new(); rng.seed = 11
	for k in 3: sv.data.stash.append(Items.make("ring", Content.Rarity.MAGIC, 12 + k * 3, rng))
	for k in 3: sv.data.stash.append(Items.make("amulet", Content.Rarity.RARE, 22, rng))
	for k in 4: sv.data.stash.append(Items.make(Content.SLOTS[k], Content.Rarity.NORMAL, 8, rng))
	sv.data.locked = [int(sv.data.stash[3].uid)]
	main = load("res://scenes/main.tscn").instantiate()
	main.bot_drive = true
	add_child(main)

func _snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out.path_join(pre + name + ".png"))
	print("shot ", pre + name)

func _process(dt: float) -> void:
	t += dt
	if t < 0.8: return
	t = 0.0
	match step:
		0: main._on_act("camp", null)
		1: await _snap("c1_camp"); CampPages.show_smith(main.screens)
		2: await _snap("c2_smith"); CampPages._furnace_tab = 0; CampPages.show_furnace(main.screens)
		3: await _snap("c3_furnace_gear"); CampPages._furnace_tab = 1; CampPages._pick = ["orbit", "storm"]; CampPages.show_furnace(main.screens)
		4: await _snap("c4_furnace_weapons"); CampPages.show_bench(main.screens)
		5: await _snap("c5_bench"); CampPages.show_trader(main.screens)
		6: await _snap("c6_trader"); CampPages.show_drill(main.screens)
		7:
			await _snap("c7_drill")
			main.start({"mode": "campaign", "stage": 0})
			main.world.champions_slain = 2; main.world.kills = 640
			main.world.end_run(true)
		8: pass
		9: await _snap("c8_end"); get_tree().quit()
	step += 1
