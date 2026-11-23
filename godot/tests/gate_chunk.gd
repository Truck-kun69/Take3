extends Node
## Gate checks that need the engine (tools/gate_check.py runs this headless):
##   godot --headless --path godot res://tests/gate_chunk.tscn
## - each generated prop and foe resolves (on the High tier) to its own PBR model at its height
## - one 640 x 640 chunk dressed per act and chunk on each tier (WorldView3D._build_cell): Medium and High
##   hold >= 150 prop instances, Low 80-145 (Quality.DENSITY 0.45: ~105 on average, the Galaxy A05's budget)
##   and fewer than Medium; the solid props (PropLayout) are the same
##   on every tier (they collide); bones, bushes and grass cast no shadow; grass and bushes stop at the near
##   range with no fade; imported PBR props draw their own materials (no material_override)
## - High-tier phones render 3D at native resolution (Main.auto_render_scale)
## Exits 0 when everything holds, 1 otherwise.
const CHUNKS := [Vector2i(1, 1), Vector2i(-2, 1), Vector2i(0, 0)]
const MIN_INSTANCES := 150
const MIN_LOW := 80                 # Low (density 0.45) is never bare ...
const MAX_LOW := 145                # ... and never over the Mali-G52's per-chunk budget
# the generated models (tools/fal_assets.py) as the game resolves them on this tier (props_hi, foes_hi and act
# variants included): drawn with their own PBR maps, at their heights (tools/verify_assets.py ranges)
const GEN_PROPS := {"tree": [115.0, 145.0], "tree_dead": [115.0, 145.0], "arch": [114.0, 126.0], "wall": [61.0, 69.0],
	"pillar": [90.0, 100.0], "rock": [36.0, 40.0], "bones": [20.5, 23.5], "bush": [24.5, 27.5]}
const GEN_FOES := ["grunt", "runner", "brute", "spitter", "charger"]
const TIERS := {1: "Low", 2: "Medium", 3: "High"}     # Save options.gfx -> name

func _ready() -> void:
	var save := get_node("/root/Save")
	save.path = "user://gate_profile.json"
	save.data = save.defaults()
	save.data.options.sound = false
	save.data.options.gfx = 3                               # the High tier (phones' default on a flagship)
	var bad := 0
	var M: Script = load("res://scripts/main.gd")
	var hi_scale: float = M.auto_render_scale(2, true)
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
		var fok := fh >= 24.0 and fh <= 42.0 and maps.has("albedo") and maps.has("normal") and maps.has("orm") and not Models.foe_vat(k).is_empty()
		print("GATE foe %s: height %.2f (24-42), maps %s, animation texture %s %s" % [k, fh, maps, not Models.foe_vat(k).is_empty(), "ok" if fok else "FAIL"])
		if not fok: bad += 1
	# chunk dressing per tier: counts, shadows, near range, materials
	var counts := {}                                        # "stage,chunk" -> {gfx: instances}
	for gfx in TIERS:
		save.data.options.gfx = gfx
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
					by[kind] = int(by.get(kind, 0)) + n
					if Models.has_pbr(mesh) and mmi.material_override != null:
						print("GATE FAIL stage %d chunk %s: PBR prop %s has a material_override" % [stage, c, kind]); bad += 1
					if WorldView3D.CLUTTER.has(kind) and mmi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
						print("GATE FAIL stage %d chunk %s: %s casts a shadow" % [stage, c, kind]); bad += 1
					# the near range is NEAR_END at the 600-unit camera and follows the camera's distance (portrait
					# and square screens and the boss zoom pull it back): never under NEAR_END, never faded
					if WorldView3D.NEAR_ONLY.has(kind) and (absf(mmi.visibility_range_end - v._near_end) > 0.5 or v._near_end < WorldView3D.NEAR_END - 0.5 or mmi.visibility_range_fade_mode != GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED):
						print("GATE FAIL stage %d chunk %s: %s range %.0f (view %.0f) fade %d" % [stage, c, kind, mmi.visibility_range_end, v._near_end, mmi.visibility_range_fade_mode]); bad += 1
				var key := "%d %s" % [stage, c]
				if not counts.has(key): counts[key] = {}
				counts[key][gfx] = total
				var floor_n := MIN_LOW if gfx == 1 else MIN_INSTANCES
				var ok: bool = total >= floor_n and (gfx != 1 or total <= MAX_LOW)
				print("GATE chunk %-6s stage %d %s: %d prop instances %s, grass and bushes to %.0f units %s" % [TIERS[gfx], stage, c, total, JSON.stringify(by), v._near_end,
					"ok" if ok else ("FAIL (< %d)" % floor_n if total < floor_n else "FAIL (> %d)" % MAX_LOW)])
				if not ok: bad += 1
				cell.free()
			# the solid props are the same on every tier: they block movement
			if gfx == 3:
				for c in CHUNKS:
					var s_lo: PackedFloat32Array = PropLayout.chunk(c, stage, w.terrain, Quality.DENSITY[0]).solids
					var s_md: PackedFloat32Array = PropLayout.chunk(c, stage, w.terrain, Quality.DENSITY[1]).solids
					var s_hi: PackedFloat32Array = PropLayout.chunk(c, stage, w.terrain, Quality.DENSITY[2]).solids
					var same := s_lo == s_md and s_md == s_hi and s_md == PropLayout.solids(c, stage, w.terrain)
					print("GATE solids stage %d %s: %d obstacle circles, identical on every tier %s" % [stage, c, s_md.size() / 4, "ok" if same else "FAIL"])
					if not same: bad += 1
			v.free()
			w.dispose()                                      # its bosses and director point back at it
	for key in counts:
		var t: Dictionary = counts[key]
		if not (int(t[1]) < int(t[2]) and int(t[2]) <= int(t[3])):
			print("GATE FAIL %s: Low %d, Medium %d, High %d (Low must be under Medium, Medium at most High)" % [key, t[1], t[2], t[3]]); bad += 1
	print("GATE engine checks: %s" % ("PASS" if bad == 0 else "%d FAILED" % bad))
	Models._cache.clear()                                  # static caches hold meshes: let them go before the engine exits
	await get_tree().process_frame
	get_tree().quit(0 if bad == 0 else 1)
