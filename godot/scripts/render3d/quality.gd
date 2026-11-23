class_name Quality
extends RefCounted
## Graphics tiers. Visual only: the simulation, spawns and balance are identical on every tier.
##   0 Low     budget phones: no sun shadows, fewer props and particles, no anti-aliasing
##   1 Medium  mid-range phones: one-cascade sun shadow (1024 atlas on phones), FXAA
##   2 High    flagship phones: native resolution, FXAA, 2048 shadow atlas, no torch shadow.
##             Desktop High: MSAA 2x, two shadow cascades on a 4096 atlas, the torch shadow.
##             Both: a 12-unit terrain grid, 1.3x prop density, 14 dynamic lights, the high-detail
##             foe meshes and earlier LOD switches
## Option "gfx": 0 Auto (by device class: GPU name and memory), 1 Low, 2 Medium, 3 High.

const NAMES := ["Low", "Medium", "High"]

## Rendering features that can be switched off one by one (the graphics self-test bisects device
## crashes with these; features it finds crashing stay off via the "gfx_off" option).
const FEATURES := ["props", "terrain", "water", "lights", "post", "effects", "foe_shadow", "sun_shadow", "torch_shadow", "msaa", "high_detail"]
const FEATURE_NAMES := {"props": "Trees, rocks and ruins", "terrain": "Hills (terrain height in shaders)", "water": "Water and lava",
	"lights": "Dynamic lights", "post": "Glow and fog", "effects": "Spell effects and ground marks", "foe_shadow": "Foe shadows",
	"sun_shadow": "Sun shadows", "torch_shadow": "Hero torch shadow", "msaa": "Anti-aliasing", "high_detail": "High-detail props and ground"}
static var off := {}            # feature -> true while switched off (self-test pass or saved gfx_off)

static func on(f: String) -> bool:
	return not off.has(f)

static func load_saved() -> void:
	off = {}
	for f in Save.opt("gfx_off"): off[f] = true

static func tier() -> int:
	var o := int(Save.opt("gfx"))
	if o > 0: return clampi(o - 1, 0, 2)
	var dc := device_class()
	# the OpenGL fallback (Vulkan failed to start) runs Medium at most
	if RenderingServer.get_current_rendering_method() == "gl_compatibility": return mini(dc, 1)
	return dc

## Device class for Auto: 0 budget, 1 mid-range, 2 flagship, from the GPU name and total RAM. The first
## Auto picked High on every phone, and a Galaxy A05 (Mali-G52 MC2, 4 GB) crashed under it.
static var _dev := -1
static var dev_reason := ""
static func device_class() -> int:
	if _dev >= 0: return _dev
	var gpu := RenderingServer.get_video_adapter_name().to_lower()
	var ram_gb := float(OS.get_memory_info().get("physical", 8.0e9)) / 1.0e9
	var c := 2
	if OS.has_feature("mobile"):
		c = 1
		var budget := RegEx.create_from_string("mali-(t|g31|g5\\d)|adreno \\(tm\\) ([3-5]\\d\\d|60\\d|61\\d)|powervr|ge8\\d\\d")
		var flag := RegEx.create_from_string("adreno \\(tm\\) (6[5-9]\\d|[7-9]\\d\\d)|mali-g7[1-9]\\b|mali-g7\\d\\d|mali-g[89]\\d\\d|immortalis|xclipse")
		if budget.search(gpu) != null: c = 0
		elif flag.search(gpu) != null: c = 2
		if ram_gb > 0.5 and ram_gb <= 4.5: c = 0                 # 4 GB phones share that RAM with the GPU
	_dev = c
	dev_reason = "%s, %.1f GB RAM" % [RenderingServer.get_video_adapter_name(), ram_gb]
	return _dev

static func high() -> bool:
	return tier() >= 2 and on("high_detail")

## Prop count multiplier for the chunked scatter (bushes and grass only: the solid props never scale). Low
## draws under half of Medium's clutter: ~105-135 instances a chunk instead of ~160, the Mali-G52's (Galaxy
## A05) worst per-pixel cost in a field of grass.
const DENSITY := [0.45, 1.0, 1.3]
static func prop_density() -> float:
	return DENSITY[tier()]

## Ground grid spacing in world units (vertex density of the displaced terrain).
static func ground_q() -> float:
	return [16.0, 12.0, 10.0][tier()]

static func lights() -> int:
	return [4, 8, 14][tier()] if on("lights") else 0

# ---------------------------------------------------------------- renderer: Vulkan or OpenGL Safe Mode
## Options > Graphics > Renderer: "Vulkan" (the Mobile renderer) or "OpenGL Safe Mode" (Compatibility). The
## choice lives in the project-settings override file (project.godot: application/config/
## project_settings_override), which the engine reads before it starts a driver: it applies on the next launch.
##
## Crash sentinel (Galaxy A05: a Mali-G52 Vulkan driver fault can kill the app mid-session). A process cannot
## change its own driver, so the fallback is armed in advance: on phones, while the app is in the foreground
## on Vulkan, the override file already asks for Compatibility and carries the sentinel. Every clean end of the
## session (the app sent to the background, which is how Android apps close, or quit) disarms it again, and a
## resume re-arms it: the same lifecycle as Diag's "== exit" / "== background" lines. If the app dies on
## Vulkan, the armed file stays: the next launch boots on Compatibility, finds the sentinel, and makes Safe
## Mode the saved choice (the crash report says so; Options > Graphics > Renderer switches back).
const OVERRIDE := "user://override.cfg"
static var override_path := OVERRIDE
const API_VULKAN := 0
const API_GL := 1
static var safe_fell_back := false      # this launch came up in Safe Mode because the last run crashed

static func api_is_gl() -> bool:
	return RenderingServer.get_current_rendering_method() == "gl_compatibility"

## Writes the override file: Compatibility (gl true) or none (Vulkan), optionally armed as the sentinel.
static func write_api(gl: bool, sentinel: bool = false) -> void:
	if not gl:
		if FileAccess.file_exists(override_path): DirAccess.remove_absolute(ProjectSettings.globalize_path(override_path))
		return
	var cf := ConfigFile.new()
	cf.set_value("rendering", "renderer/rendering_method", "gl_compatibility")
	cf.set_value("rendering", "renderer/rendering_method.mobile", "gl_compatibility")
	if sentinel: cf.set_value("shardfall", "sentinel", true)
	cf.save(override_path)

## What the override file asks for: {"gl": bool, "sentinel": bool}.
static func read_api() -> Dictionary:
	var cf := ConfigFile.new()
	if not FileAccess.file_exists(override_path) or cf.load(override_path) != OK: return {"gl": false, "sentinel": false}
	return {"gl": String(cf.get_value("rendering", "renderer/rendering_method.mobile", "")) == "gl_compatibility",
		"sentinel": bool(cf.get_value("shardfall", "sentinel", false))}

## The player's choice (Options): Safe Mode now and on every launch, or Vulkan from the next launch.
static func set_api(api: int) -> void:
	Save.set_opt("gfx_api", api)
	write_api(api == API_GL)

## The session is in the foreground: arm the sentinel (phones on Vulkan only; force: tests on a desktop).
static func arm_sentinel(force: bool = false) -> bool:
	if not force and (not OS.has_feature("mobile") or api_is_gl()): return false
	if int(Save.opt("gfx_api")) != API_VULKAN: return false
	write_api(true, true)
	return true

## The session ended cleanly (or the app left the foreground): back to what the player chose.
static func disarm_sentinel() -> void:
	if not read_api().sentinel: return
	write_api(int(Save.opt("gfx_api")) == API_GL)

## On launch: an armed sentinel means the last run died mid-fight. Safe Mode becomes the saved choice.
static func check_sentinel() -> bool:
	if not read_api().sentinel: return false
	Save.set_opt("gfx_api", API_GL)
	write_api(true)
	safe_fell_back = true
	return true
