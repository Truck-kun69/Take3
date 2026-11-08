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

static func tier() -> int:
	var o := int(Save.opt("gfx"))
	if o > 0: return clampi(o - 1, 0, 2)
	if OS.has_feature("web") or RenderingServer.get_current_rendering_method() == "gl_compatibility": return 1
	return 2

static func high() -> bool:
	return tier() >= 2

## Prop count multiplier for the chunked scatter.
static func prop_density() -> float:
	return [0.7, 1.0, 1.3][tier()]

## Ground grid spacing in world units (vertex density of the displaced terrain).
static func ground_q() -> float:
	return [24.0, 20.0, 12.0][tier()]

static func lights() -> int:
	return [4, 8, 14][tier()]
