class_name Quality
extends RefCounted
## Graphics tiers. Visual only: the simulation, spawns and balance are identical on every tier.
##   0 Low     old phones: no sun shadows, 3 terrain octaves, a third of the particles
##   1 Medium  the web build (WebGL2 / Compatibility) and the previous "High"
##   2 High    Android (Vulkan Mobile renderer) and desktop: MSAA 2x, soft sun shadows on a 4096
##             atlas, a 12-unit terrain grid, 1.3x prop density, 14 dynamic lights, the
##             high-detail foe and prop meshes (models/*_hi) and earlier LOD switches
## Option "gfx": 0 Auto (High everywhere except the web, which gets Medium), 1 Low, 2 Medium, 3 High.

const NAMES := ["Low", "Medium", "High"]

## Rendering features that can be switched off one by one (the graphics self-test bisects device
## crashes with these; features it finds crashing stay off via the "gfx_off" option).
const FEATURES := ["props", "terrain", "water", "lights", "post", "effects", "foe_shadow", "sun_shadow", "torch_shadow", "msaa", "high_detail"]
const FEATURE_NAMES := {"props": "Trees, rocks and ruins", "terrain": "Hills (terrain height in shaders)", "water": "Water and lava",
	"lights": "Dynamic lights", "post": "Glow and fog", "effects": "Spell effects and ground marks", "foe_shadow": "Foe shadows",
	"sun_shadow": "Sun shadows", "torch_shadow": "Hero torch shadow", "msaa": "Anti-aliasing (MSAA)", "high_detail": "High-detail props and ground"}
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
	if OS.has_feature("web") or RenderingServer.get_current_rendering_method() == "gl_compatibility": return mini(dc, 1)
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
	if OS.has_feature("mobile") or OS.has_feature("web"):
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

## Prop count multiplier for the chunked scatter.
static func prop_density() -> float:
	return [0.7, 1.0, 1.3][tier()]

## Ground grid spacing in world units (vertex density of the displaced terrain).
static func ground_q() -> float:
	return 12.0 if high() else [24.0, 20.0, 20.0][tier()]

static func lights() -> int:
	return [4, 8, 14][tier()] if on("lights") else 0
