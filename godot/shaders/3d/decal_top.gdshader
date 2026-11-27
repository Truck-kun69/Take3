shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, depth_test_disabled, cull_disabled, shadows_disabled;
// Hostile telegraphs (FX3D._decals): the ground decal without a depth test, so the bodies and props standing in a
// zone no longer cover it. Depth-tested, a slam on the hero changed 71-74% of its area (26-29% lay under foes), a
// slam beside trees 36-48%, a dash-cleave line through the pack 61-77%; drawn over them, 91-100%.
#include "res://shaders/3d/decal.gdshaderinc"
