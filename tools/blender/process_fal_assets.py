"""Turn fal downloads (tools/.fal_raw/<id>/, written by tools/fal_assets.py) into Shardfall models.

    ~/toolchains/blender/blender -b --factory-startup --python tools/blender/process_fal_assets.py -- <id> [<id> ...]

hero, boss: rigged.glb (Meshy's rig on the Meshy model: Mixamo skeleton, PBR textures) and one
  clip_<name>.glb per clip (each the same rig with one action)
  -> godot/models/heroes|bosses/<id>.glb: one armature carrying every clip as a named action (heroes idle,
     walk, run, cast, roll, jump, die; bosses idle, walk, attack, slam, die). Root motion is taken out (the
     game moves the body): the hips keep their bob and sway but not their drift, and the jump keeps its
     crouches but not its lift (the game draws the arc). Scaled to 38 / 88 units tall, feet at y 0,
     facing +X (the game's forward), by a root node; nothing in the rig or the clips is rescaled.
foe: rigged.glb, clip_walk.glb, clip_run.glb (Meshy's basic rig on the Hunyuan mesh, sent as
  tools/blender/obj_to_glb.py's rig_input.glb) and texture.png (Rapid's base colour map, full size)
  -> godot/models/foes/<id>.glb: the mesh welded, smooth, decimated to FOE_TRIS, at its height, feet at 0,
     facing +X, the full base colour map (resized to 2048 px) on its UVs, UV2.x = the vertex's column in the
     animation texture; and godot/models/foes/<id>.vat:
     SVA3 (tools/vat_pack.py) with the walk cycle (the run cycle for runner and charger) baked from the rig.
prop: model.glb (Hunyuan Pro) -> godot/models/props/<id>.glb, welded (edges over 45 degrees kept sharp),
  decimated to its triangle budget, at its
  height (trees centred on the trunk, not the canopy), feet at 0.
Textures: every map the model brings is kept; larger than 2048 px is resized to 2048.
Prints one PROCESSED line per asset (height, triangles, clips, textures).
"""
import math
import os
import sys

import bpy
import numpy as np
from mathutils import Matrix, Quaternion, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
RAW = os.path.join(ROOT, "tools", ".fal_raw")
MODELS = os.path.join(ROOT, "godot", "models")
sys.path.insert(0, os.path.join(ROOT, "tools"))

KIND = {"warden": "hero", "spark": "hero", "ember": "hero", "storm": "hero", "tyrant": "boss", "herald": "boss",
        "grunt": "foe", "runner": "foe", "brute": "foe", "spitter": "foe", "charger": "foe",
        "tree": "prop", "tree_dead": "prop", "rock": "prop", "arch": "prop", "wall": "prop", "pillar": "prop",
        "bones": "prop", "bush": "prop"}
# world units (the game's): heroes 38 (the rig draws them at 1.3x), bosses 88, foes 24-42 (each at its
# base radius: the game scales an instance by radius / base radius), props per kind
HEIGHT = {"hero": 38.0, "boss": 88.0,
          "grunt": 30.0, "runner": 26.0, "brute": 42.0, "spitter": 27.0, "charger": 34.0,
          "tree": 130.0, "tree_dead": 125.0, "arch": 120.0, "wall": 65.0, "pillar": 95.0, "rock": 38.0, "bones": 22.0, "bush": 26.0}
# triangle budgets: a screen shows about nine chunks of dressing (~60 trees, ~200 bushes, ~90 boulders and
# ruins) plus 400 foes, on phones
TRIS = {"hero": 22000, "boss": 26000, "foe": 1800,
        "tree": 3500, "tree_dead": 3000, "arch": 4000, "wall": 2000, "pillar": 2000, "rock": 1200, "bones": 1200, "bush": 900}
HERO_CLIPS = ["idle", "walk", "run", "cast", "roll", "jump", "die"]
BOSS_CLIPS = ["idle", "walk", "attack", "slam", "die"]
LOOPED = {"idle", "walk", "run"}
FOE_LOCO = {"runner": "run", "charger": "run"}          # which basic clip is the foe's walk cycle
MAX_TEX = 2048


# ---------------------------------------------------------------- helpers
def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def import_glb(path):
    before = set(bpy.data.objects)
    acts_before = set(bpy.data.actions)
    bpy.ops.import_scene.gltf(filepath=path)
    new = [o for o in bpy.data.objects if o not in before]
    acts = [a for a in bpy.data.actions if a not in acts_before]
    return new, acts


def meshes(objs):
    return [o for o in objs if o.type == "MESH"]


def world_points(objs):
    dg = bpy.context.evaluated_depsgraph_get()
    pts = []
    for o in meshes(objs):
        ev = o.evaluated_get(dg)
        me = ev.to_mesh()
        mw = ev.matrix_world
        co = np.empty(len(me.vertices) * 3, dtype=np.float64)
        me.vertices.foreach_get("co", co)
        co = co.reshape(-1, 3)
        m = np.array(mw)
        pts.append(co @ m[:3, :3].T + m[:3, 3])
        ev.to_mesh_clear()
    return np.concatenate(pts) if pts else np.zeros((0, 3))


def tri_count(objs):
    n = 0
    for o in meshes(objs):
        o.data.calc_loop_triangles()
        n += len(o.data.loop_triangles)
    return n


def decimate(objs, budget):
    """Collapse-decimate to about `budget` triangles in total, before any armature deformation. A collapse pass
    can stop short (seams, small islands): up to three passes, each at the ratio still needed."""
    for _ in range(3):
        total = tri_count(objs)
        if total <= budget * 1.05: return total
        ratio = budget / total
        for o in meshes(objs):
            bpy.context.view_layer.objects.active = o
            for s in bpy.context.selected_objects: s.select_set(False)
            o.select_set(True)
            mod = o.modifiers.new("decimate", "DECIMATE")
            mod.ratio = ratio
            mod.use_collapse_triangulate = True
            while o.modifiers.find("decimate") > 0:                  # before the armature, so weights carry over
                bpy.ops.object.modifier_move_up(modifier="decimate")
            bpy.ops.object.modifier_apply(modifier="decimate")
    return tri_count(objs)


def weld(ob, sharp_deg=None):
    """Merge coincident vertices (1e-7 of the mesh's size) and drop loose ones. A generated mesh comes split
    along its UV charts (Hunyuan) or at every triangle's corners (a flat-shaded upload, back from the rig):
    split, a collapse decimation stops at the chart edges, and loose vertices count towards the height in
    Blender but are not exported. Smooth shaded after; with sharp_deg, edges folded more than that stay
    sharp (the exporter splits the normals there). UVs are per face corner, so the charts keep theirs."""
    import bmesh
    me = ob.data
    bm = bmesh.new()
    bm.from_mesh(me)
    span = max((max(v.co[k] for v in bm.verts) - min(v.co[k] for v in bm.verts)) for k in range(3))
    n0 = len(bm.verts)
    bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-7 * span)   # the same point written twice, not surfaces that touch
    nm = [e for e in bm.edges if len(e.link_faces) > 2]               # fused sheets (bones: skulls grown into
    if nm: bmesh.ops.split_edges(bm, edges=nm)                       # each other): apart, so the collapse runs
    loose_e = [e for e in bm.edges if not e.link_faces]
    if loose_e: bmesh.ops.delete(bm, geom=loose_e, context="EDGES")
    loose_v = [v for v in bm.verts if not v.link_faces]
    if loose_v: bmesh.ops.delete(bm, geom=loose_v, context="VERTS")
    for f in bm.faces: f.smooth = True
    if sharp_deg is not None:
        lim = math.radians(sharp_deg)
        for e in bm.edges:
            e.smooth = not (e.is_manifold and e.calc_face_angle(0.0) > lim)
    n1 = len(bm.verts)
    bm.to_mesh(me)
    bm.free()
    me.update()
    return n0, n1


def cap_textures(objs):
    """Resize any map over MAX_TEX; returns {image name: (w, h)} of the images the meshes use."""
    out = {}
    for o in meshes(objs):
        for slot in o.material_slots:
            m = slot.material
            if m is None or not m.use_nodes: continue
            for n in m.node_tree.nodes:
                if n.type == "TEX_IMAGE" and n.image is not None:
                    img = n.image
                    w, h = img.size
                    if max(w, h) > MAX_TEX:
                        k = MAX_TEX / max(w, h)
                        img.scale(int(w * k), int(h * k))
                    out[img.name] = tuple(img.size)
    return out


def forward_from_rig(arm):
    """The character's facing in world XY: from the feet to the toes (Mixamo LeftFoot -> LeftToeBase)."""
    bones = arm.data.bones
    def find(*names):
        for b in bones:
            low = b.name.lower()
            if any(low.endswith(n) for n in names): return b
        return None
    feet = [find("leftfoot"), find("rightfoot")]
    toes = [find("lefttoebase", "lefttoe"), find("righttoebase", "righttoe")]
    v = Vector((0, 0, 0))
    for f, t in zip(feet, toes):
        if f is not None and t is not None:
            v += (arm.matrix_world @ t.head_local) - (arm.matrix_world @ f.head_local)
    v.z = 0.0
    if v.length < 1e-6: return Vector((0, -1, 0))                    # glTF +Z (Blender -Y): how generators face
    return v.normalized()


def place(root, objs, height, center_xy=None):
    """Scale root so the meshes stand `height` tall, then move it so their feet are at z 0 and
    `center_xy` (default: the bounding box centre) is at the origin."""
    bpy.context.view_layer.update()
    p = world_points(objs)
    h = float(p[:, 2].max() - p[:, 2].min())
    root.scale = Vector((height / h,) * 3)
    bpy.context.view_layer.update()
    p = world_points(objs)
    c = center_xy(p) if center_xy else (0.5 * (p[:, 0].min() + p[:, 0].max()), 0.5 * (p[:, 1].min() + p[:, 1].max()))
    root.location = Vector((root.location.x - c[0], root.location.y - c[1], root.location.z - float(p[:, 2].min())))
    bpy.context.view_layer.update()
    p = world_points(objs)
    return float(p[:, 2].max() - p[:, 2].min()), float(p[:, 2].min())


def make_root(name, objs, yaw):
    root = bpy.data.objects.new(name, None)
    bpy.context.scene.collection.objects.link(root)
    root.rotation_euler = (0.0, 0.0, yaw)
    for o in objs:
        if o.parent is None:
            o.parent = root
    bpy.context.view_layer.update()
    return root


def strip_root_motion(arm, act, name):
    """Hips: no drift across the clip on the horizontal axes; the jump loses its lift (keeps its crouches)."""
    hips = next((b for b in arm.data.bones if b.name.lower().endswith("hips")), None)
    if hips is None: return
    dp = f'pose.bones["{hips.name}"].location'
    basis = arm.matrix_world.to_3x3() @ hips.matrix_local.to_3x3()
    for fc in act.fcurves:
        if fc.data_path != dp or len(fc.keyframe_points) < 2: continue
        axis = basis @ Vector([1.0 if i == fc.array_index else 0.0 for i in range(3)])
        up = axis.z
        kp = fc.keyframe_points
        f0, f1 = kp[0].co.x, kp[-1].co.x
        v0, v1 = kp[0].co.y, kp[-1].co.y
        for k in kp:
            if abs(up) < 0.7:                                       # horizontal: remove the drift, keep the sway
                t = (k.co.x - f0) / max(1e-6, f1 - f0)
                d = (v1 - v0) * t + v0
                k.co.y -= d; k.handle_left.y -= d; k.handle_right.y -= d
            elif name == "jump":                                     # vertical: only below standing height survives
                lift = (k.co.y - v0) * (1 if up > 0 else -1)
                if lift > 0:
                    d = lift * (1 if up > 0 else -1)
                    k.co.y -= d; k.handle_left.y -= d; k.handle_right.y -= d
        fc.update()


def export(path, objs_root, animations):
    for o in bpy.context.selected_objects: o.select_set(False)
    def sel(o):
        o.select_set(True)
        for c in o.children: sel(c)
    sel(objs_root)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True, export_yup=True,
                              export_animations=animations, export_animation_mode="ACTIONS", export_force_sampling=True,
                              export_skins=True, export_morph=False, export_image_format="AUTO", export_materials="EXPORT",
                              export_texcoords=True, export_normals=True, export_tangents=False, export_apply=False)


def purge():
    for _ in range(3): bpy.ops.outliner.orphans_purge(do_local_ids=True, do_linked_ids=True, do_recursive=True)


# ---------------------------------------------------------------- rigged characters (heroes, bosses, foe rigs)
def load_rig(aid, clips):
    src = os.path.join(RAW, aid)
    objs, acts = import_glb(os.path.join(src, "rigged.glb"))
    arm = next(o for o in objs if o.type == "ARMATURE")
    for a in acts: bpy.data.actions.remove(a)                       # the bind file's own animation, if any
    # Meshy's rig files carry a stray helper mesh (an unparented icosphere): keep only what the rig deforms
    for o in [o for o in objs if o.type == "MESH" and not any(m.type == "ARMATURE" for m in o.modifiers)]:
        objs.remove(o)
        bpy.data.objects.remove(o, do_unlink=True)
    got = {}
    for name in clips:
        f = os.path.join(src, f"clip_{name}.glb")
        if not os.path.exists(f):
            raise SystemExit(f"{aid}: missing clip file {f}")
        cobjs, cacts = import_glb(f)
        carm = next(o for o in cobjs if o.type == "ARMATURE")
        act = carm.animation_data.action if carm.animation_data and carm.animation_data.action else (cacts[0] if cacts else None)
        if act is None: raise SystemExit(f"{aid}: {f} has no animation")
        act.name = name
        act.use_fake_user = True
        for a in cacts:
            if a is not act: bpy.data.actions.remove(a)
        for o in cobjs: bpy.data.objects.remove(o, do_unlink=True)
        got[name] = act
    purge()
    return objs, arm, got


def process_character(aid):
    kind = KIND[aid]
    clips = HERO_CLIPS if kind == "hero" else BOSS_CLIPS
    reset()
    objs, arm, acts = load_rig(aid, clips)
    arm.animation_data_create()
    for name, act in acts.items():
        arm.animation_data.action = act
        strip_root_motion(arm, act, name)
    arm.animation_data.action = acts["idle"]
    arm.data.pose_position = "REST"
    tris = decimate(meshes(objs), TRIS[kind])
    texs = cap_textures(objs)
    fwd = forward_from_rig(arm)
    yaw = -math.atan2(fwd.y, fwd.x)                                   # turn the facing onto +X
    root = make_root(aid, objs, yaw)
    h, min_z = place(root, meshes(objs), HEIGHT[kind])
    arm.data.pose_position = "POSE"
    arm.animation_data.action = None                                 # every clip exports as its own animation
    bpy.context.scene.frame_set(1)
    out = os.path.join(MODELS, "heroes" if kind == "hero" else "bosses", aid + ".glb")
    export(out, root, True)
    ranges = {n: round((a.frame_range[1] - a.frame_range[0]) / bpy.context.scene.render.fps, 2) for n, a in acts.items()}
    print(f"PROCESSED {aid}: {out} height {h:.2f} min_z {min_z:.3f} tris {tris} clips {ranges} textures {texs} "
          f"facing was {tuple(round(x, 2) for x in fwd)}", flush=True)


# ---------------------------------------------------------------- foes: rigged mesh -> static mesh + vertex animation
# ---------------------------------------------------------------- foes: the clips Meshy's basic rig lacks
# Meshy's basic rig brings walk and run; the game plays five clips per foe (spawn, attack, a flinch, death,
# the walk). The other four are keyed here on the rig's Mixamo skeleton, forward kinematics at 24 fps.
# Per clip: (last frame, {frame: {bone: [(axis, degrees), ...]}}). Axes are the character's own: "l" lateral
# (towards its right; + tips an upright bone backwards and swings a hanging one forwards), "u" up (+ turns
# it to its left), "f" forward (+ tips an upright bone to its right, swings a hanging left arm outwards).
# "hips" takes {"pivot": degrees} (the whole body about the lateral axis through the ground below the hips:
# + topples it backwards) and {"move": (forward, right, up)} in heights.
FOE_CLIPS = ["walk", "attack", "hit", "death", "spawn"]
AUTHORED = {
    "attack": (14, {                                                   # wind up overhead, chop, recover
        0: {},
        5: {"spine1": [("l", 8), ("u", -20)], "spine2": [("l", 6), ("u", -12)], "head": [("l", 6)],
            "rightarm": [("l", 150), ("f", -20)], "rightforearm": [("l", 45)], "leftarm": [("l", 25), ("f", 15)]},
        9: {"spine1": [("l", -18), ("u", 16)], "spine2": [("l", -10), ("u", 10)], "head": [("l", -8)],
            "rightarm": [("l", 45), ("f", -10)], "rightforearm": [("l", 10)], "leftarm": [("l", -15)],
            "hips": {"move": (0.06, 0.0, -0.03)}},
        14: {}}),
    "hit": (8, {                                                       # struck in the chest: recoil, return
        0: {},
        2: {"spine1": [("l", 14)], "spine2": [("l", 10)], "head": [("l", 16), ("u", 8)],
            "leftarm": [("f", 18)], "rightarm": [("f", -18)], "hips": {"move": (-0.03, 0.0, 0.0)}},
        8: {}}),
    "death": (23, {                                                    # knees give, topples backwards, lies
        0: {},
        6: {"spine1": [("l", -12)], "head": [("l", -10)], "leftupleg": [("l", 12)], "rightupleg": [("l", 10)],
            "leftleg": [("l", -25)], "rightleg": [("l", -20)], "hips": {"pivot": 10, "move": (0.0, 0.0, -0.05)}},
        16: {"spine1": [("l", 10)], "head": [("l", 20)], "leftarm": [("f", 50), ("l", 30)], "rightarm": [("f", -50), ("l", 30)],
             "leftupleg": [("l", 20)], "rightupleg": [("l", 26)], "leftleg": [("l", -30)], "rightleg": [("l", -36)],
             "hips": {"pivot": 82, "move": (0.0, 0.0, 0.08)}},
        20: {"spine1": [("l", 6)], "head": [("l", 14)], "leftarm": [("f", 62), ("l", 24)], "rightarm": [("f", -60), ("l", 26)],
             "leftupleg": [("l", 16)], "rightupleg": [("l", 20)], "leftleg": [("l", -22)], "rightleg": [("l", -28)],
             "hips": {"pivot": 89, "move": (0.0, 0.0, 0.13)}},
        23: {"spine1": [("l", 4)], "head": [("l", 12)], "leftarm": [("f", 65), ("l", 20)], "rightarm": [("f", -64), ("l", 22)],
             "leftupleg": [("l", 14)], "rightupleg": [("l", 18)], "leftleg": [("l", -20)], "rightleg": [("l", -26)],
             "hips": {"pivot": 86, "move": (0.0, 0.0, 0.11)}}}),
    "spawn": (17, {                                                    # claws its way up out of the ground
        0: {"spine1": [("l", -25)], "head": [("l", 10)], "leftarm": [("l", 120)], "rightarm": [("l", 120)],
            "leftupleg": [("l", 50)], "rightupleg": [("l", 50)], "leftleg": [("l", -70)], "rightleg": [("l", -70)],
            "hips": {"move": (0.0, 0.0, -0.95)}},
        9: {"spine1": [("l", -20)], "head": [("l", 4)], "leftarm": [("l", 90), ("f", 10)], "rightarm": [("l", 95), ("f", -10)],
            "leftupleg": [("l", 35)], "rightupleg": [("l", 35)], "leftleg": [("l", -50)], "rightleg": [("l", -50)],
            "hips": {"move": (0.0, 0.0, -0.35)}},
        17: {}}),
}


def author_foe_clips(arm):
    """AUTHORED -> {name: action} on this rig (its own rest pose is the stance every key starts from)."""
    pbs = {pb.name.split(":")[-1].lower(): pb for pb in arm.pose.bones}
    inv = arm.matrix_world.to_3x3().inverted()
    up = (inv @ Vector((0, 0, 1))).normalized()
    feet = [(pbs.get(a), pbs.get(b)) for a, b in (("leftfoot", "lefttoebase"), ("rightfoot", "righttoebase"))]
    fwd = Vector((0, 0, 0))
    for a, b in feet:
        if a is not None and b is not None: fwd += b.bone.head_local - a.bone.head_local
    fwd -= up * fwd.dot(up)
    fwd = fwd.normalized() if fwd.length > 1e-9 else (inv @ Vector((0, -1, 0))).normalized()
    lat = fwd.cross(up).normalized()
    axes = {"l": lat, "u": up, "f": fwd}
    zs = [b.head_local.dot(up) for b in arm.data.bones] + [b.tail_local.dot(up) for b in arm.data.bones]
    H = max(zs) - min(zs)
    ground = min(zs)
    hips = pbs.get("hips")
    out = {}
    for name, (last, keys) in AUTHORED.items():
        act = bpy.data.actions.new(name)
        act.use_fake_user = True
        arm.animation_data.action = act
        used = sorted({b for k in keys.values() for b in k if b != "hips"})
        for fr, k in sorted(keys.items()):
            for bn in used:
                pb = pbs.get(bn)
                if pb is None: continue
                pb.rotation_mode = "QUATERNION"
                q = Quaternion()
                rest = pb.bone.matrix_local.to_3x3().inverted()
                for ax, deg in k.get(bn, []):
                    q = q @ Quaternion((rest @ axes[ax]).normalized(), math.radians(deg))
                pb.rotation_quaternion = q
                pb.keyframe_insert("rotation_quaternion", frame=fr, group=pb.name)
            if hips is not None:
                h = k.get("hips", {})
                M = hips.bone.matrix_local
                head = M.to_translation()
                piv = head - up * (head.dot(up) - ground)
                R = Matrix.Rotation(math.radians(h.get("pivot", 0.0)), 4, lat)
                mf, ml, mu = h.get("move", (0.0, 0.0, 0.0))
                X = Matrix.Translation((fwd * mf + lat * ml + up * mu) * H) @ Matrix.Translation(piv) @ R @ Matrix.Translation(-piv) @ M
                basis = M.inverted() @ X
                hips.rotation_mode = "QUATERNION"
                hips.location = basis.to_translation()
                hips.rotation_quaternion = basis.to_quaternion()
                hips.keyframe_insert("location", frame=fr, group=hips.name)
                hips.keyframe_insert("rotation_quaternion", frame=fr, group=hips.name)
        for pb in arm.pose.bones:                                     # the next clip starts from the rest pose
            pb.location = (0, 0, 0); pb.rotation_quaternion = Quaternion(); pb.rotation_euler = (0, 0, 0)
        out[name] = act
    arm.animation_data.action = None
    return out


def process_foe(aid):
    import vat_pack
    reset()
    loco = FOE_LOCO.get(aid, "walk")
    objs, arm, acts = load_rig(aid, [loco])
    act = acts[loco]
    arm.animation_data_create()
    arm.animation_data.action = act
    strip_root_motion(arm, act, loco)
    arm.data.pose_position = "REST"
    ms = meshes(objs)
    if len(ms) > 1:                                                  # one mesh: one column per vertex
        for o in bpy.context.selected_objects: o.select_set(False)
        for o in ms: o.select_set(True)
        bpy.context.view_layer.objects.active = ms[0]
        bpy.ops.object.join()
        ms = [ms[0]]
    ob = ms[0]
    welded = weld(ob)
    tris = decimate([ob], TRIS["foe"])
    # the rig call carried a 1024 px copy of the base colour map (tools/blender/obj_to_glb.py); the mesh keeps
    # its UVs, so Rapid's own map goes back on, resized to MAX_TEX
    full = os.path.join(RAW, aid, "texture.png")
    if os.path.exists(full):
        img = bpy.data.images.load(full)
        img.name = aid + "_albedo"
        for slot in ob.material_slots:
            if slot.material is None or not slot.material.use_nodes: continue
            for n in slot.material.node_tree.nodes:
                if n.type == "TEX_IMAGE": n.image = img
    texs = cap_textures([ob])
    fwd = forward_from_rig(arm)
    root = make_root(aid, objs, -math.atan2(fwd.y, fwd.x))
    h, min_z = place(root, [ob], HEIGHT[aid])
    # the vertex animation: every frame of every clip, evaluated through the rig, in the root's space: the
    # walk cycle (Meshy's, looped) and the four keyed clips (played once)
    arm.data.pose_position = "POSE"
    scn = bpy.context.scene
    acts_all = {"walk": act, **author_foe_clips(arm)}
    nv = len(ob.data.vertices)
    rows_p, rows_n, table = [], [], []
    fps = scn.render.fps / max(1, scn.frame_step)
    dg = bpy.context.evaluated_depsgraph_get()
    for name in FOE_CLIPS:
        a = acts_all[name]
        arm.animation_data.action = a
        f0, f1 = int(a.frame_range[0]), int(a.frame_range[1])
        frames = list(range(f0, f1)) if name == "walk" else list(range(f0, f1 + 1))   # looped: the last is the first
        first = len(rows_p)
        for fr in frames:
            scn.frame_set(fr)
            dg.update()
            ev = ob.evaluated_get(dg)
            me = ev.to_mesh()
            if len(me.vertices) != nv:
                raise SystemExit(f"{aid}: evaluated mesh has {len(me.vertices)} vertices, expected {nv}")
            m = np.array(ev.matrix_world)
            co = np.empty(nv * 3); me.vertices.foreach_get("co", co); co = co.reshape(-1, 3) @ m[:3, :3].T + m[:3, 3]
            no = np.empty(nv * 3); me.vertices.foreach_get("normal", no); no = no.reshape(-1, 3) @ m[:3, :3].T
            no /= np.maximum(1e-6, np.linalg.norm(no, axis=1, keepdims=True))
            rows_p.append(np.stack([co[:, 0], co[:, 2], -co[:, 1]], 1))   # Blender (x, y, z) -> Godot (x, z, -y)
            rows_n.append(np.stack([no[:, 0], no[:, 2], -no[:, 1]], 1))
            ev.to_mesh_clear()
        table.append([name, first, len(frames), fps, 1 if name == "walk" else 0])
    arm.animation_data.action = act
    f0 = int(act.frame_range[0])
    frames = rows_p
    P = np.array(rows_p, dtype=np.float32); N = np.array(rows_n, dtype=np.float32)
    data, desc, rows, perr, nerr = vat_pack.pack(nv, table, P, N)
    vat_path = os.path.join(MODELS, "foes", aid + ".vat")
    open(vat_path, "wb").write(data)
    # the static mesh: rest pose, transforms applied, a second UV layer holding each vertex's VAT column
    scn.frame_set(f0)
    arm.data.pose_position = "REST"
    bpy.context.view_layer.update()
    for mod in list(ob.modifiers):
        if mod.type == "ARMATURE": ob.modifiers.remove(mod)
    mw = ob.matrix_world.copy()
    ob.parent = None
    ob.matrix_world = mw
    for o in bpy.context.selected_objects: o.select_set(False)
    ob.select_set(True); bpy.context.view_layer.objects.active = ob
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    ob.vertex_groups.clear()
    vat_uv = ob.data.uv_layers.new(name="VAT")
    for lo in ob.data.loops: vat_uv.data[lo.index].uv = ((lo.vertex_index + 0.5) / nv, 0.5)
    ob.name = aid
    for o in list(bpy.data.objects):
        if o is not ob: bpy.data.objects.remove(o, do_unlink=True)
    out = os.path.join(MODELS, "foes", aid + ".glb")
    for o in bpy.context.selected_objects: o.select_set(False)
    ob.select_set(True)
    bpy.ops.export_scene.gltf(filepath=out, export_format="GLB", use_selection=True, export_yup=True, export_animations=False,
                              export_skins=False, export_image_format="AUTO", export_materials="EXPORT", export_texcoords=True,
                              export_normals=True, export_tangents=False)
    print(f"PROCESSED {aid}: {out} height {h:.2f} min_z {min_z:.3f} welded {welded[0]} -> {welded[1]} verts, tris {tris} verts {nv} vat {vat_path} "
          f"({len(frames)} frames at {fps:.0f} fps, {desc}, position error <= {100 * perr:.3f}%) textures {texs}", flush=True)


# ---------------------------------------------------------------- props
def trunk_center(p):
    low = p[p[:, 2] < p[:, 2].min() + 0.08 * (p[:, 2].max() - p[:, 2].min())]
    return (float(np.median(low[:, 0])), float(np.median(low[:, 1])))


def rebake(aid, hi, budget):
    """For a surface the collapse cannot bring down (Hunyuan's skull pile: one closed surface with thousands of
    tiny tunnels, genus ~3700, and a collapse keeps every one): a voxel remesh closes them, that is decimated
    to the budget and unwrapped, and its maps are baked from the original surface with Cycles (base colour,
    tangent-space normal, roughness; 2048 px; non-metal). Returns the new mesh object; `hi` is removed."""
    scn = bpy.context.scene
    co = np.array([v.co for v in hi.data.vertices])
    span = float((co.max(0) - co.min(0)).max())
    lo = hi.copy()
    lo.data = hi.data.copy()
    lo.name = aid
    scn.collection.objects.link(lo)
    for o in bpy.context.selected_objects: o.select_set(False)
    lo.select_set(True)
    bpy.context.view_layer.objects.active = lo
    rm = lo.modifiers.new("remesh", "REMESH")
    rm.mode = "VOXEL"
    rm.voxel_size = span / 150.0
    bpy.ops.object.modifier_apply(modifier="remesh")
    decimate([lo], budget)
    for poly in lo.data.polygons: poly.use_smooth = True
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=math.radians(66.0), island_margin=0.004)
    bpy.ops.object.mode_set(mode="OBJECT")
    lo.data.materials.clear()
    mat = bpy.data.materials.new(aid + "_baked")
    mat.use_nodes = True
    lo.data.materials.append(mat)
    nt = mat.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    imgs = {}
    for name, colour in (("albedo", "sRGB"), ("normal", "Non-Color"), ("roughness", "Non-Color")):
        img = bpy.data.images.new(f"{aid}_{name}", MAX_TEX, MAX_TEX, alpha=False)
        img.colorspace_settings.name = colour
        node = nt.nodes.new("ShaderNodeTexImage")
        node.image = img
        imgs[name] = (img, node)
    scn.render.engine = "CYCLES"
    scn.cycles.device = "CPU"
    scn.cycles.samples = 4
    for o in bpy.context.selected_objects: o.select_set(False)
    hi.select_set(True)
    lo.select_set(True)
    bpy.context.view_layer.objects.active = lo
    reach = dict(use_selected_to_active=True, cage_extrusion=0.02 * span, max_ray_distance=0.06 * span, margin=8)
    for name, kind, extra in (("albedo", "DIFFUSE", {"pass_filter": {"COLOR"}}), ("normal", "NORMAL", {"normal_space": "TANGENT"}),
                              ("roughness", "ROUGHNESS", {})):
        img, node = imgs[name]
        nt.nodes.active = node
        bpy.ops.object.bake(type=kind, **reach, **extra)
        img.filepath_raw = os.path.join(RAW, aid, f"baked_{name}.png")
        img.file_format = "PNG"
        img.save()
    nt.links.new(imgs["albedo"][1].outputs["Color"], bsdf.inputs["Base Color"])
    nt.links.new(imgs["roughness"][1].outputs["Color"], bsdf.inputs["Roughness"])
    nm = nt.nodes.new("ShaderNodeNormalMap")
    nt.links.new(imgs["normal"][1].outputs["Color"], nm.inputs["Color"])
    nt.links.new(nm.outputs["Normal"], bsdf.inputs["Normal"])
    bsdf.inputs["Metallic"].default_value = 0.0
    lo.parent = hi.parent
    lo.matrix_world = hi.matrix_world.copy()
    bpy.data.objects.remove(hi, do_unlink=True)
    return lo


def process_prop(aid):
    reset()
    objs, acts = import_glb(os.path.join(RAW, aid, "model.glb"))
    for a in acts: bpy.data.actions.remove(a)
    ms = meshes(objs)
    welded = [weld(o, 45.0) for o in ms]
    if len(ms) > 1:
        for o in bpy.context.selected_objects: o.select_set(False)
        for o in ms: o.select_set(True)
        bpy.context.view_layer.objects.active = ms[0]
        bpy.ops.object.join()
        objs = [o for o in objs if o.name in bpy.data.objects]
        ms = [ms[0]]
    src = ms[0].copy()                                               # the full surface, kept in case the
    src.data = ms[0].data.copy()                                     # collapse stalls and the maps are baked
    tris = decimate(ms, TRIS[aid])
    baked = False
    if tris > 1.5 * TRIS[aid]:
        stalled = ms[0]
        bpy.context.scene.collection.objects.link(src)
        src.parent = stalled.parent
        src.matrix_world = stalled.matrix_world.copy()
        objs.remove(stalled)
        bpy.data.objects.remove(stalled, do_unlink=True)
        lo = rebake(aid, src, TRIS[aid])
        objs.append(lo)
        ms = [lo]
        tris = tri_count(ms)
        baked = True
    else:
        bpy.data.meshes.remove(src.data)
    texs = cap_textures(ms)
    root = make_root(aid, objs, 0.0)
    h, min_z = place(root, ms, HEIGHT[aid], trunk_center if aid.startswith("tree") else None)
    # the game draws props through a MultiMesh of the file's first mesh, without its node transforms:
    # the placement goes into the vertices, the mesh node is left at the identity
    for o in ms:
        mw = o.matrix_world.copy()
        o.parent = None
        o.matrix_world = mw
    for o in bpy.context.selected_objects: o.select_set(False)
    for o in ms: o.select_set(True)
    bpy.context.view_layer.objects.active = ms[0]
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    for o in list(bpy.data.objects):
        if o not in ms: bpy.data.objects.remove(o, do_unlink=True)
    out = os.path.join(MODELS, "props", aid + ".glb")
    for o in ms: o.select_set(True)
    bpy.ops.export_scene.gltf(filepath=out, export_format="GLB", use_selection=True, export_yup=True, export_animations=False,
                              export_skins=False, export_morph=False, export_image_format="AUTO", export_materials="EXPORT",
                              export_texcoords=True, export_normals=True, export_tangents=False, export_apply=False)
    print(f"PROCESSED {aid}: {out} height {h:.2f} min_z {min_z:.3f} welded {sum(a for a, b in welded)} -> {sum(b for a, b in welded)} verts, "
          f"tris {tris}{' (remeshed, maps baked from the full surface)' if baked else ''} textures {texs}", flush=True)


if __name__ == "__main__":
    ids = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    for aid in ids:
        k = KIND[aid]
        if k in ("hero", "boss"): process_character(aid)
        elif k == "foe": process_foe(aid)
        else: process_prop(aid)
