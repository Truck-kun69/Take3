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

## Engine errors and warnings, caught through a Logger. On Android the engine's own log file is off
## (it wrote every message to flash), so this is how the crash report still shows what the engine
## complained about: each distinct message once, at most MAX_ENGINE per session, into the trail.
class ErrorTrail extends Logger:
	var seen := {}
	var count := 0
	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		var msg := rationale if rationale != "" else code
		var key := "%s:%d:%s" % [file.get_file(), line, msg.left(60)]
		if seen.has(key) or count >= Diag.MAX_ENGINE: return
		seen[key] = true
		count += 1
		Diag.mark("engine %s: %s (%s:%d %s)" % [["error", "warning", "script error", "shader error"][clampi(error_type, 0, 3)], msg.left(140), file.get_file(), line, function])
	func _log_message(_message: String, _error: bool) -> void:
		pass

const MAX_ENGINE := 40
var _mutex := Mutex.new()          # the logger can be called from the render and audio threads
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
			report = PackedStringArray()
			for l in lines:                          # every first occurrence, then the tail of the trail
				if l.contains(" first ") or l.contains("== boot") or l.contains(" device ") or l.contains(" gpu ") or l.contains(" start ") or l.contains(" engine "): report.append(l)
			report.append("-- last moments --")
			report.append_array(lines.slice(maxi(0, lines.size() - 16)))
			var eng := _engine_errors()
			if not eng.is_empty():
				report.append("-- engine errors --")
				report.append_array(eng)
			var pf := FileAccess.open(PREV, FileAccess.WRITE)
			if pf != null: pf.store_string("\n".join(lines) + "\n" + "\n".join(eng))
	_f = FileAccess.open(PATH, FileAccess.WRITE)
	OS.add_logger(ErrorTrail.new())
	mark("== boot %s" % Time.get_datetime_string_from_system())
	mark("device %s | %s %s | cpus %d" % [OS.get_model_name(), OS.get_name(), OS.get_version(), OS.get_processor_count()])

func _ready() -> void:
	await get_tree().process_frame          # the adapter name is only known once the renderer is up
	mark("gpu %s | %s | %s" % [RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_api_version(), RenderingServer.get_current_rendering_method()])
	mark("device class %d (%s) auto tier %s" % [Quality.device_class(), Quality.dev_reason, Quality.NAMES[Quality.tier()]])

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

## First-occurrence breadcrumbs: the first time each kind of thing happens in this session (a sound,
## a kill, a corpse dissolving, a decal, a light...) it is written down. After a hard crash, whatever
## appeared just before the trail ends is the prime suspect.
var _seen := {}
func first(key: String) -> void:
	if _seen.has(key): return
	_seen[key] = true
	mark("first " + key)

func mark(s: String) -> void:
	_mutex.lock()
	if _f != null:
		_f.store_line("%7.2f %s" % [Time.get_ticks_msec() / 1000.0, s])
		_f.flush()
	_mutex.unlock()

## Twice a second while a run is live: enough to see what was growing when it died.
func beat(w: World, dt: float, label: String = "run") -> void:
	_beat_t -= dt
	if _beat_t > 0.0 or w == null: return
	_beat_t = 0.25
	mark("%s t=%.1f foes=%d projs=%d eshots=%d fx=%d texts=%d mem=%dMB vmem=%dMB fps=%d | sim %.1f view %.1f cpu %.1f ms" % [label, w.t, w.sw.n, w.projs.size(),
		w.eshots.size(), w.fx.size(), w.texts.size(), OS.get_static_memory_usage() / 1048576,
		int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0), Engine.get_frames_per_second(),
		w.step_us / 1000.0, view_us / 1000.0, Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0])

## Set by WorldView3D each frame (its own CPU cost), read by beat().
var view_us := 0.0

## The game's version: application/config/version, which is also the APK's versionName (the Android export
## preset leaves version/name empty, so the build takes this one).
static func version() -> String:
	return String(ProjectSettings.get_setting("application/config/version", "dev"))

## "Copy report": what a bug report needs, as plain text for a message: the version, the device, the GPU, the
## graphics and sound settings, the last benchmark and self-test, the last crashed session's trail (diag_prev.txt)
## and the end of this session's.
func report_text() -> String:
	var r := PackedStringArray()
	r.append("Shardfall %s report, %s" % [version(), Time.get_datetime_string_from_system()])
	var mem := OS.get_memory_info()
	r.append("device: %s | %s %s | %d cpus | %.1f GB RAM" % [OS.get_model_name(), OS.get_name(), OS.get_version(), OS.get_processor_count(), float(mem.get("physical", 0)) / 1.0e9])
	r.append("gpu: %s | %s | %s renderer" % [RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_api_version(), RenderingServer.get_current_rendering_method()])
	var ws := DisplayServer.window_get_size()
	r.append("screen: %dx%d window, UI scale %.2f" % [ws.x, ws.y, float(Save.opt("ui_scale"))])
	var off: Array = Save.opt("gfx_off")
	r.append("graphics: %s tier (option %s, device class %s) | 3D resolution option %s | frame cap option %s | switched off: %s" % [Quality.NAMES[Quality.tier()],
		["Auto", "Low", "Medium", "High"][clampi(int(Save.opt("gfx")), 0, 3)], ["budget", "mid-range", "flagship"][Quality.device_class()],
		["Auto", "100%", "75%", "50%"][clampi(int(Save.opt("render_scale")), 0, 3)], ["Auto", "30", "60", "None"][clampi(int(Save.opt("frame_cap")), 0, 3)],
		"none" if off.is_empty() else ", ".join(off)])
	r.append("sound: %s, volume %d%%, voices %d%%, safe engine %s" % ["on" if Save.opt("sound") else "off", roundi(float(Save.opt("volume")) * 100.0),
		roundi(float(Save.opt("voice_volume")) * 100.0), "on" if Save.opt("sfx_safe") else "off"])
	var b: Dictionary = Save.data.get("bench", {})
	if not b.is_empty():
		r.append("last benchmark: %d FPS, %.1f ms a frame, 1%% low %d FPS, %s foes, %s draw calls, %sk triangles (%s graphics, 3D at %s%%, %s)" % [roundi(float(b.get("fps", 0.0))),
			float(b.get("ms", 0.0)), roundi(float(b.get("low1", 0.0))), b.get("foes", "?"), b.get("draws", "?"), b.get("ktris", "?"), b.get("tier", "?"), b.get("scale", "?"), b.get("res", "?")])
	var st: Dictionary = Save.data.get("selftest", {})
	if not st.get("results", []).is_empty():
		var parts := PackedStringArray()
		for x in st.results: parts.append("%s %s" % [x.get("f", "?"), "CRASHED" if x.get("crash", false) else "%s FPS" % x.get("fps", "?")])
		r.append("self-test: %s%s" % [", ".join(parts), "" if st.get("bad", []).is_empty() else "; switched off: " + ", ".join(st.bad)])
	if FileAccess.file_exists(PREV):
		r.append("-- the last session that crashed%s --" % (" (the one before this)" if crashed_last else ""))
		r.append_array(_tail(FileAccess.get_file_as_string(PREV), 60))
	if FileAccess.file_exists(PATH):
		r.append("-- this session --")
		r.append_array(_tail(FileAccess.get_file_as_string(PATH), 40))
	return "\n".join(r)

static func _tail(text: String, n: int) -> PackedStringArray:
	var lines := text.strip_edges().split("\n")
	return lines.slice(maxi(0, lines.size() - n))

func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_PREDELETE: mark("== exit")
		NOTIFICATION_APPLICATION_PAUSED: mark("== background")
		NOTIFICATION_APPLICATION_RESUMED: mark("resumed")
