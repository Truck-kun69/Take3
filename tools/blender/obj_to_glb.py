"""Hunyuan 3.1 Rapid's OBJ -> the .glb Meshy's rigging takes (it accepts .glb only).

    ~/toolchains/blender/blender -b --factory-startup --python tools/blender/obj_to_glb.py -- <id> [<id> ...] [--preview] [--yaw id=deg,...]

In:  tools/.fal_raw/<id>/model.obj and texture.png (the base colour map Rapid returns with it)
Out: tools/.fal_raw/<id>/rig_input.glb: the mesh as Hunyuan made it, joined into one object, smooth shaded, decimated to
     RIG_TRIS triangles and the base colour map at RIG_TEX px (JPEG), so the file can go to fal inline (about
     1 MB). The map is only for the rigging call: process_fal_assets.py puts the original map (resized to
     2048 px) back on the rigged mesh, whose UVs are these.
Facing: glTF +Z (the OBJ's own front), turned by --yaw degrees about the vertical for any asset that needs it.
--preview: also renders tools/.fal_raw/<id>/rig_input_front.png and _side.png (Workbench, texture colours),
     front = looking at the model's +Z face, to check the facing before the rig is paid for.
"""
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
RAW = os.path.join(ROOT, "tools", ".fal_raw")
RIG_TRIS = 16000
RIG_TEX = 1024


def convert(aid, yaw_deg=0.0, preview=False):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    src = os.path.join(RAW, aid)
    bpy.ops.wm.obj_import(filepath=os.path.join(src, "model.obj"), forward_axis="NEGATIVE_Z", up_axis="Y")
    ms = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    for o in bpy.context.selected_objects: o.select_set(False)
    for o in ms: o.select_set(True)
    bpy.context.view_layer.objects.active = ms[0]
    if len(ms) > 1: bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    ob.name = aid
    ob.data.calc_loop_triangles()
    before = len(ob.data.loop_triangles)
    if before > RIG_TRIS:
        mod = ob.modifiers.new("decimate", "DECIMATE")
        mod.ratio = RIG_TRIS / before
        mod.use_collapse_triangulate = True
        bpy.ops.object.modifier_apply(modifier="decimate")
    ob.data.calc_loop_triangles()
    after = len(ob.data.loop_triangles)
    # the OBJ has no smoothing groups: imported flat, every triangle would be written with its own three
    # vertices; smooth, the file shares them (only UV seams split a vertex)
    bpy.ops.object.shade_smooth()
    # one material: the base colour map (the MTL names metallic, roughness and normal maps fal does not return)
    img = bpy.data.images.load(os.path.join(src, "texture.png"))
    full = tuple(img.size)
    img.scale(RIG_TEX, RIG_TEX)
    mat = bpy.data.materials.new(aid)
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = img
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Metallic"].default_value = 0.0
    bsdf.inputs["Roughness"].default_value = 0.8
    ob.data.materials.clear()
    ob.data.materials.append(mat)
    # facing and grounding: feet at 0, centred on the vertical axis
    if yaw_deg:
        ob.matrix_world = Matrix.Rotation(math.radians(yaw_deg), 4, "Z") @ ob.matrix_world
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    xs = [v.co for v in ob.data.vertices]
    lo = Vector((min(p.x for p in xs), min(p.y for p in xs), min(p.z for p in xs)))
    hi = Vector((max(p.x for p in xs), max(p.y for p in xs), max(p.z for p in xs)))
    off = Vector(((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, lo.z))
    for v in ob.data.vertices: v.co -= off
    out = os.path.join(src, "rig_input.glb")
    bpy.ops.export_scene.gltf(filepath=out, export_format="GLB", use_selection=False, export_yup=True,
                              export_animations=False, export_image_format="JPEG", export_jpeg_quality=90,
                              export_materials="EXPORT", export_texcoords=True, export_normals=True)
    size = hi - lo
    print(f"RIGINPUT {aid}: {out} {os.path.getsize(out) / 1e6:.2f} MB, triangles {before} -> {after}, "
          f"size x {size.x:.3f} y(depth) {size.y:.3f} z(up) {size.z:.3f}, map {full} -> {RIG_TEX}, yaw {yaw_deg:g}", flush=True)
    if preview: render_views(aid, ob, size, src)


def render_views(aid, ob, size, src):
    scn = bpy.context.scene
    scn.render.engine = "BLENDER_WORKBENCH"
    scn.display.shading.light = "STUDIO"
    scn.display.shading.color_type = "TEXTURE"
    scn.render.resolution_x = scn.render.resolution_y = 512
    scn.render.film_transparent = False
    scn.world = bpy.data.worlds.new("w")
    cam_data = bpy.data.cameras.new("cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = max(size.x, size.y, size.z) * 1.15
    cam = bpy.data.objects.new("cam", cam_data)
    scn.collection.objects.link(cam)
    scn.camera = cam
    mid = Vector((0, 0, size.z / 2))
    # glTF +Z (the front) is Blender -Y: the front view looks from -Y towards +Y
    for name, pos in (("front", Vector((0, -10, 0))), ("side", Vector((10, 0, 0)))):
        cam.location = mid + pos
        cam.rotation_euler = (mid - cam.location).to_track_quat("-Z", "Y").to_euler()
        scn.render.filepath = os.path.join(src, f"rig_input_{name}.png")
        bpy.ops.render.render(write_still=True)


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    yaw = {}
    if "--yaw" in argv:
        spec = argv[argv.index("--yaw") + 1]
        argv.remove(spec)
        yaw = {k: float(v) for k, v in (p.split("=") for p in spec.split(","))}
        argv.remove("--yaw")
    preview = "--preview" in argv
    ids = [a for a in argv if not a.startswith("--")]
    for aid in ids:
        convert(aid, yaw.get(aid, 0.0), preview)
