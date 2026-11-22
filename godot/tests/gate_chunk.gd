extends Node
## Gate checks that need the engine (tools/gate_check.py runs this headless):
##   godot --headless --path godot res://tests/gate_chunk.tscn
## - one 640 x 640 chunk dressed per act (WorldView3D._build_cell): prints the prop instances it holds, by
##   kind, and fails under 150
## - imported PBR props (Models.has_pbr) draw their own materials: no material_override on their MultiMesh
## - High-tier phones render 3D at native resolution (Main.auto_render_scale)
## - each generated prop and foe resolves (on this tier) to its own PBR model at its height
## Exits 0 when everything holds, 1 otherwise.
const CHUNKS := [Vector2i(1, 1), Vector2i(-2, 1), Vector2i(0, 0)]
const MIN_INSTANCES := 150
# the generated models (tools/fal_assets.py) as the game resolves them on this tier (props_hi, foes_hi and act
# variants included): drawn with their own PBR maps, at their heights (tools/verify_assets.py ranges)
const GEN_PROPS := {"tree": [115.0, 145.0], "tree_dead": [115.0, 145.0], "arch": [114.0, 126.0], "wall": [61.0, 69.0],
	"pillar": [90.0, 100.0], "rock": [36.0, 40.0], "bones": [20.5, 23.5], "bush": [24.5, 27.5]}
const GEN_FOES := ["grunt", "runner", "brute", "spitter", "charger"]

func _ready() -> void:
	var save := get_node("/root/Save")
	save.path = "user://gate_profile.json"
	save.data = save.defaults()
	save.data.options.sound = false
	save.data.options.gfx = 3                               # the High tier (phones' default on a flagship)
	var bad := 0
	var M: Script = load("res://scripts/main.gd")
	var hi_scale: float = M.auto_render_scale(2, true, false)
	print("GATE render scale on High phones: %.2f" % hi_scale)
	if hi_scale != 1.0: bad += 1
	for k in GEN_PROPS:
		var pm := Models.prop_mesh(k)
		var ph := pm.get_aabb().size.y if pm != null else 0.0
		var pok: bool = pm != null and Models.has_pbr(pm) and ph >= GEN_PROPS[k][0] and ph <= GEN_PROPS[k][1]
		print("GATE prop %s: height %.2f (%.0f-%.0f), own PBR maps %s %s" % [k, ph, GEN_PROPS[k][0], GEN_PROPS[k][1], Models.has_pbr(pm) if pm != null else false, "ok" if pok else "FAIL"])
		if not pok: bad += 1
	for k in GEN_FOES:
		var fm := Models.foe_mesh(k)
		var fh := fm.get_aabb().size.y if fm != null else 0.0
		var maps: Array = Models.pbr_maps(fm).keys() if fm != null else []
		var fok := fh >= 24.0 and fh <= 42.0 and maps.has("albedo") and not Models.foe_vat(k).is_empty()
		print("GATE foe %s: height %.2f (24-42), maps %s, animation texture %s %s" % [k, fh, maps, not Models.foe_vat(k).is_empty(), "ok" if fok else "FAIL"])
		if not fok: bad += 1
	for stage in 5:
		var w := World.new()
		w.setup({"mode": "campaign", "stage": stage, "hero": 0, "seed": 7, "headless": true, "season": ""})
		var v := WorldView3D.new()
		add_child(v)
		v.bind(w)
		v._process(1.0 / 60.0)
		for c in CHUNKS:
			var cell: Node3D = v._build_cell(c)
			var total := 0
			var by := {}
			for ch in cell.get_children():
				var mmi := ch as MultiMeshInstance3D
				if mmi == null: continue
				var n := mmi.multimesh.instance_count
				total += n
				var mesh := mmi.multimesh.mesh
				var kind := "?"
				for k in Models.PROP_KINDS:
					if Models.prop_mesh(k, stage) == mesh: kind = k
				by[kind] = n
				if Models.has_pbr(mesh) and mmi.material_override != null:
					print("GATE FAIL stage %d chunk %s: PBR prop %s has a material_override" % [stage, c, kind]); bad += 1
			var ok := total >= MIN_INSTANCES
			print("GATE chunk stage %d %s: %d prop instances %s %s" % [stage, c, total, JSON.stringify(by), "ok" if ok else "FAIL (< 150)"])
			if not ok: bad += 1
			cell.free()
		v.free()
	print("GATE engine checks: %s" % ("PASS" if bad == 0 else "%d FAILED" % bad))
	Models._cache.clear()                                  # static caches hold meshes: let them go before the engine exits
	await get_tree().process_frame
	get_tree().quit(0 if bad == 0 else 1)
