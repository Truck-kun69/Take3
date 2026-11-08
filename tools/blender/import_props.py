"""Turn TRELLIS 2 meshes (tools/fal/gen3d.py) into Shardfall's instanced props.

    ~/toolchains/blender/blender -b --factory-startup --python tools/blender/import_props.py -- <gen dir> [names...]

Props are scattered by the hundred with one instanced draw per kind and coloured by the prop
shader from vertex colours, so each generated mesh is:
  1. joined, stood on y = 0, centred, and scaled to the procedural prop's height
  2. decimated from ~20k triangles to a per-prop budget
  3. its baked PBR texture sampled into vertex colours, graded toward the game's palette
  4. tagged in UV2: glowing crystal faces -> part 7 (the shader makes them emit the act's
     accent colour), and a tree's upper branches -> part 8 (they sway and bend away from bodies)
Output: godot/models/props/<name>.glb (the slot picks it up; delete it for the procedural prop).
"""
import bpy
import bmesh
import colorsys
import math
import os
import sys
import numpy as np
from mathutils import Matrix

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(os.path.dirname(HERE)), "godot", "models", "props")

# name -> height (matches the procedural prop), triangle budget, which faces glow / sway
PROPS = {
    "crystal": {"height": 30.0, "tris": 1400, "glow": "crystal"},
    "pillar":  {"height": 48.0, "tris": 1800, "glow": "crystal"},
    "tree":    {"height": 69.0, "tris": 3000, "sway_above": 0.42},     # thin branches shattered at 2000
    "rock":    {"height": 16.0, "tris": 700, "glow": "crystal"},
    "pillar_4": {"height": 50.0, "tris": 1800},
    "rock_4":  {"height": 14.0, "tris": 1000},
    "tree_4":  {"height": 56.0, "tris": 2200, "glow": "warm"},           # candelabra: the flames glow
    "bones":   {"height": 7.0, "tris": 1600},
}


def to_linear(c):
    """Texture pixels are sRGB; vertex colours are linear. Writing one as the other washes colours out."""
    return tuple(x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c)


def sampler(mat):
    tex = None
    if mat and mat.use_nodes:
        bsdf = next((n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
        if bsdf and bsdf.inputs["Base Color"].links:
            n = bsdf.inputs["Base Color"].links[0].from_node
            tex = n if n.type == "TEX_IMAGE" else None
        tex = tex or next((n for n in mat.node_tree.nodes if n.type == "TEX_IMAGE" and n.image), None)
    if tex is None:
        return lambda uv: (0.6, 0.6, 0.6)
    w, h = tex.image.size
    px = np.empty(w * h * 4, dtype=np.float32)
    tex.image.pixels.foreach_get(px)
    px = px.reshape(h, w, 4)
    return lambda uv: tuple(px[int((uv[1] % 1.0) * (h - 1)), int((uv[0] % 1.0) * (w - 1)), :3])


def build(name, cfg, src):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=os.path.join(src, name + ".glb"))
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    bpy.ops.object.select_all(action="DESELECT")
    for o in meshes: o.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    if len(meshes) > 1: bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    bpy.ops.object.parent_clear(type="CLEAR_KEEP_TRANSFORM")
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    # stand it up, centre it, scale to the slot's height
    zs = [v.co.z for v in ob.data.vertices]
    xs = [v.co.x for v in ob.data.vertices]
    ys = [v.co.y for v in ob.data.vertices]
    k = cfg["height"] / max(1e-4, max(zs) - min(zs))
    ob.data.transform(Matrix.Scale(k, 4) @ Matrix.Translation((-(min(xs) + max(xs)) / 2, -(min(ys) + max(ys)) / 2, -min(zs))))
    tris = sum(len(p.vertices) - 2 for p in ob.data.polygons)
    if tris > cfg["tris"]:
        d = ob.modifiers.new("dec", "DECIMATE")
        d.ratio = cfg["tris"] / tris
        d.use_collapse_triangulate = True
        bpy.ops.object.modifier_apply(modifier="dec")
    me = ob.data
    samp = sampler(me.materials[0] if me.materials else None)
    uv_name = me.uv_layers.active.name
    me.uv_layers.new(name="UV2")
    me.color_attributes.new("Col", "BYTE_COLOR", "CORNER")
    uv0 = me.uv_layers[uv_name].data            # fetched after adding layers: adding reallocates them
    uv2 = me.uv_layers["UV2"].data
    col = me.color_attributes["Col"]
    h = cfg["height"]
    glow_n = sway_n = 0
    for poly in me.polygons:
        cols = [samp(uv0[li].uv) for li in poly.loop_indices]
        avg = [sum(c[i] for c in cols) / len(cols) for i in range(3)]
        hh, ss, vv = colorsys.rgb_to_hsv(*avg)
        part = 0
        if cfg.get("glow") == "crystal" and ss > 0.32 and vv > 0.28 and 0.5 < hh < 0.92:
            part = 7                 # blue to violet, saturated: crystal
            glow_n += 1
        elif cfg.get("glow") == "warm" and vv > 0.7 and (hh < 0.2 or hh > 0.97) and ss > 0.1:
            part = 7                 # bright yellow to orange: flame
            glow_n += 1
        cz = sum(me.vertices[me.loops[li].vertex_index].co.z for li in poly.loop_indices) / len(poly.loop_indices)
        if "sway_above" in cfg and cz > cfg["sway_above"] * h:
            part = 8
            sway_n += 1
        for li, c in zip(poly.loop_indices, cols):
            l = 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2]
            g = [max(0.0, min(1.0, (l + (x - l) * 0.85) * 0.85)) for x in c]
            col.data[li].color = (*to_linear(g), 1.0)
            uv2[li].uv = (float(part), 0.0)
    me.color_attributes.active_color = col
    # smooth stone with its real edges kept crisp (flat shading made decimated stone look crumpled)
    me.shade_smooth()
    me.set_sharp_from_angle(angle=math.radians(38))
    me.materials.clear()
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name + ".glb")
    bpy.ops.object.select_all(action="DESELECT")
    ob.select_set(True)
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True, export_yup=True,
                              export_vertex_color="ACTIVE", export_active_vertex_color_when_no_material=True,
                              export_materials="NONE", export_animations=False, export_normals=True)
    print(f"PROP {name}: {len(me.polygons)} tris, {glow_n} glowing, {sway_n} swaying -> {path}")


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    src = argv[0]
    for n in (argv[1:] or [p for p in PROPS if os.path.exists(os.path.join(src, p + ".glb"))]):
        build(n, PROPS[n], src)
