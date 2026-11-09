extends Node
## Crash breadcrumbs for real devices, where there is no debugger and no console.
##
## Every line goes to user://diag.txt and is flushed immediately, so a hard crash (a GPU driver
## fault, the OS killing the app) still leaves the last thing the game did on disk. A session
## that ends cleanly (or is sent to the background, which is how Android apps usually "close")
## writes a closing line; if the previous trail has none, the menu shows a crash report with the
## trail's tail plus the engine's own errors from that session (Godot's file log), to screenshot.

const PATH := "user://diag.txt"
const PREV := "user://diag_prev.txt"
const CLEAN := ["== exit", "== background"]

var crashed_last := false
var report: PackedStringArray = PackedStringArray()   # previous session's tail (when it crashed)
var _f: FileAccess
var _beat_t := 0.0

func _enter_tree() -> void:
	if FileAccess.file_exists(PATH):
		var lines := FileAccess.get_file_as_string(PATH).strip_edges().split("\n")
		var last := lines[lines.size() - 1] if lines.size() > 0 else ""
		var clean := false
		for c in CLEAN:
			if last.contains(c): clean = true
		if not clean and lines.size() > 1:
			crashed_last = true
			report = lines.slice(maxi(0, lines.size() - 22))
			var eng := _engine_errors()
			if not eng.is_empty():
				report.append("-- engine errors --")
				report.append_array(eng)
			var pf := FileAccess.open(PREV, FileAccess.WRITE)
			if pf != null: pf.store_string("\n".join(lines) + "\n" + "\n".join(eng))
	_f = FileAccess.open(PATH, FileAccess.WRITE)
	mark("== boot %s" % Time.get_datetime_string_from_system())
	mark("device %s | %s %s | cpus %d" % [OS.get_model_name(), OS.get_name(), OS.get_version(), OS.get_processor_count()])

func _ready() -> void:
	await get_tree().process_frame          # the adapter name is only known once the renderer is up
	mark("gpu %s | %s | %s" % [RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_api_version(), RenderingServer.get_current_rendering_method()])

## The last error/warning lines from the previous session's engine log (Godot rotates it on boot).
func _engine_errors() -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open("user://logs")
	if d == null: return out
	var newest := ""
	for fn in d.get_files():
		if fn.begins_with("godot") and fn != "godot.log" and fn > newest: newest = fn
	if newest == "": return out
	var lines := FileAccess.get_file_as_string("user://logs/" + newest).split("\n")
	for l in lines:
		if l.contains("ERROR") or l.contains("WARNING") or l.contains("crash") or l.contains("signal"):
			out.append(l.strip_edges().left(140))
	return out.slice(maxi(0, out.size() - 10))

func mark(s: String) -> void:
	if _f == null: return
	_f.store_line("%7.2f %s" % [Time.get_ticks_msec() / 1000.0, s])
	_f.flush()

## Twice a second while a run is live: enough to see what was growing when it died.
func beat(w: World, dt: float, label: String = "run") -> void:
	_beat_t -= dt
	if _beat_t > 0.0 or w == null: return
	_beat_t = 0.5
	mark("%s t=%.1f foes=%d projs=%d eshots=%d fx=%d texts=%d mem=%dMB vmem=%dMB fps=%d | sim %.1f view %.1f cpu %.1f ms" % [label, w.t, w.sw.n, w.projs.size(),
		w.eshots.size(), w.fx.size(), w.texts.size(), OS.get_static_memory_usage() / 1048576,
		int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0), Engine.get_frames_per_second(),
		w.step_us / 1000.0, view_us / 1000.0, Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0])

## Set by WorldView3D each frame (its own CPU cost), read by beat().
var view_us := 0.0

func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_PREDELETE: mark("== exit")
		NOTIFICATION_APPLICATION_PAUSED: mark("== background")
		NOTIFICATION_APPLICATION_RESUMED: mark("resumed")
