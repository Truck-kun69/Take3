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
	if OS.has_feature("web") or RenderingServer.get_current_rendering_method() == "gl_compatibility": return 1
	return 2

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
