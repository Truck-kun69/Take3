extends Node
## Parse and compile check for every script and shader in the project.
##   xvfb-run -a godot --path godot --rendering-method mobile res://tests/parse_all.tscn
## Scripts: loaded (compiled on first load) and checked to be instantiable. Shaders: each is put on a quad in front of
## a camera and rendered, which makes the renderer compile it (shader errors print as SHADER ERROR).
## Prints "PARSE scripts n/m ok, shaders n rendered" and exits non-zero if a script failed.
var bad: Array[String] = []
func _ready() -> void:
	var scripts: Array[String] = []
	var shaders: Array[String] = []
	_walk("res://", scripts, shaders)
	for p in scripts:
		var sc = ResourceLoader.load(p)
		if sc == null or not (sc is GDScript) or not (sc as GDScript).can_instantiate():
			bad.append(p)
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(0, 0, 5)
	var x := -float(shaders.size()) * 0.6
	for p in shaders:
		var sh: Shader = load(p)
		var mat := ShaderMaterial.new()
		mat.shader = sh
		var mi := MeshInstance3D.new()
		mi.mesh = QuadMesh.new()
		mi.material_override = mat
		mi.position = Vector3(x, 0, 0)
		x += 1.2
		if sh.get_mode() == Shader.MODE_SPATIAL: add_child(mi)
		elif sh.get_mode() == Shader.MODE_CANVAS_ITEM:
			var cr := ColorRect.new(); cr.size = Vector2(16, 16); cr.material = mat; add_child(cr)
	for k in 3: await get_tree().process_frame
	print("PARSE scripts %d/%d ok, shaders %d rendered%s" % [scripts.size() - bad.size(), scripts.size(), shaders.size(), ("  FAILED: " + ", ".join(bad)) if not bad.is_empty() else ""])
	get_tree().quit(1 if not bad.is_empty() else 0)

func _walk(dir: String, scripts: Array[String], shaders: Array[String]) -> void:
	var d := DirAccess.open(dir)
	if d == null: return
	for f in d.get_files():
		if f.ends_with(".gd"): scripts.append(dir.path_join(f))
		elif f.ends_with(".gdshader"): shaders.append(dir.path_join(f))
	for sub in d.get_directories():
		if sub.begins_with(".") or sub == "android" or sub == "addons": continue
		_walk(dir.path_join(sub), scripts, shaders)
