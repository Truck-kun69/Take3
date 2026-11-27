extends Node
## Startup time (docs/OPTIMIZATION.md O4): from the engine's start to the title menu's first frames, in parts.
##   godot --headless --path godot res://tests/startup.tscn            (scripts and loading only)
##   xvfb-run -a godot --rendering-method mobile --path godot res://tests/startup.tscn   (with shader compiles)
var main: Node
var frames := 0
var _t := 0
var _first := []
var _first_at := 0

func _ready() -> void:
	var t_engine := Time.get_ticks_usec()          # the engine and the four autoloads are up
	var sv := get_node("/root/Save")
	sv.data.intro_seen = true                       # the title, not the cold open
	var t0 := Time.get_ticks_usec()
	var ps: PackedScene = load("res://scenes/main.tscn")
	var t1 := Time.get_ticks_usec()
	main = ps.instantiate()
	var t2 := Time.get_ticks_usec()
	add_child(main)
	var t3 := Time.get_ticks_usec()
	print("STARTUP engine and autoloads %.0f ms | main.tscn load %.0f ms, instantiate %.0f ms, main._ready %.0f ms" % [
		t_engine / 1000.0, (t1 - t0) / 1000.0, (t2 - t1) / 1000.0, (t3 - t2) / 1000.0])
	_t = Time.get_ticks_usec()

func _process(_dt: float) -> void:
	var now := Time.get_ticks_usec()
	if frames == 0: _first_at = now
	_first.append(snappedf((now - _t) / 1000.0, 0.1))
	_t = now
	frames += 1
	if frames == 6:
		print("STARTUP the title's first frame %.0f ms after the engine started; frames %s ms" % [_first_at / 1000.0, str(_first)])
		get_tree().quit()
