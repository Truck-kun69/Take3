"""Turn rigged CC0 creatures (KayKit, Quaternius) into Shardfall swarm meshes.

    ~/toolchains/blender/blender -b --factory-startup --python tools/blender/import_packs.py -- <packs dir> [kinds...]

<packs dir> holds the downloaded packs (see docs/MODELS.md):
    KayKit-Character-Pack-Skeletons-1.0/   (git clone of KayKit-Game-Assets/...)
    quaternius_monsters/Big/Blends/*.blend  (Quaternius "Ultimate Monsters")

The swarm is instanced (hundreds of foes, one draw call per kind) and animated by the foe shader,
not by skeletons, so each creature is baked into the format godot/models/README.md describes:
  1. pose it (a frame of its own Idle clip) and bake the deformed mesh
  2. colour: sample its texture atlas into vertex colours (the shader reads COLOR)
  3. limbs: each face takes its dominant bone's part id (legs 1/2, arms 3/4, head 5, eyes 6) and
     that limb's joint height, written to the second UV channel (UV2 in Godot)
  4. lore: a few glowing crystal shards (part 7) grow from the upper back: these are shard-touched
  5. face +X, feet at 0, scaled to the procedural foe's height; decimated per part to a budget
Output: godot/models/foes/<kind>.glb (the slot picks it up; delete it to get the procedural foe back).
"""
import bpy
import bmesh
import math
import os
import random
import sys
import numpy as np
from mathutils import Euler, Matrix, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(os.path.dirname(HERE)), "godot", "models", "foes")
# --hi: the High graphics tier's variants (Quality.high: Android, desktop) -> models/foes_hi, at HI x the budget
HI = 2.0
if "--hi" in sys.argv:
    OUT += "_hi"
KK = "KayKit-Character-Pack-Skeletons-1.0/addons/kaykit_character_pack_skeletons"
QB = "quaternius_monsters/Big/Blends"
QL = "quaternius_monsters/Blob/glTF"

# kind -> source, pose, size (procedural foe height), triangle budget, shard crystals, extras
FOES = {
    "grunt":   {"src": f"{KK}/Characters/gltf/Skeleton_Minion.glb", "action": "Idle", "height": 2.1, "tris": 1000, "crystals": 3,
                "weapon": (f"{KK}/Assets/gltf/Skeleton_Blade.gltf", "handslot.r")},
    "runner":  {"src": f"{QB}/Dino.blend", "action": "Idle", "height": 1.5, "tris": 800, "crystals": 4},
    "brute":   {"src": f"{QB}/Yeti.blend", "action": "Idle", "height": 2.6, "tris": 900, "crystals": 6},
    "spitter": {"src": f"{QB}/Frog.blend", "action": "Idle", "height": 1.7, "tris": 800, "crystals": 3},
    "charger": {"src": f"{QB}/Demon.blend", "action": "Idle", "height": 1.8, "tris": 800, "crystals": 4},
    "breach":  {"src": f"{QB}/Alien.blend", "action": "Idle", "height": 1.8, "tris": 800, "crystals": 2},
    "goblin":  {"src": f"{QB}/MushroomKing.blend", "action": "Idle", "height": 1.9, "tris": 900, "crystals": 3},
    "splitter": {"src": f"{QL}/GreenSpikyBlob.gltf", "action": "Idle", "height": 2.0, "tris": 800, "crystals": 4},
    # Act V, the Drowned Cathedral: drowned dead and fish-men (models/foes/<kind>_4 replace <kind> in that act)
    "grunt_4": {"src": f"{KK}/Characters/gltf/Skeleton_Rogue.glb", "action": "Idle", "height": 2.1, "tris": 1000, "crystals": 2,
                "weapon": (f"{KK}/Assets/gltf/Skeleton_Blade.gltf", "handslot.r")},
    "runner_4": {"src": f"{QB}/Fish.blend", "action": "Idle", "height": 1.6, "tris": 800, "crystals": 3},
    "mini":    {"src": f"{QL}/GreenBlob.gltf", "action": "Idle", "height": 1.0, "tris": 450, "crystals": 1},
}

LEG_L, LEG_R, ARM_L, ARM_R, HEAD, EYE, GLOW = 1, 2, 3, 4, 5, 6, 7


def part_of_bone(name):
    """Part id from a bone name, for both KayKit (upperleg.l) and Quaternius (UpperLeg.L) rigs."""
    n = name.lower()
    side = "l" if n.endswith((".l", "_l")) else ("r" if n.endswith((".r", "_r")) else "")
    if any(k in n for k in ("leg", "foot", "toe", "heel")) and side:
        return LEG_L if side == "l" else LEG_R
    if any(k in n for k in ("arm", "hand", "wrist", "shoulder", "pinky", "middle", "index", "thumb", "finger")) and side:
        return ARM_L if side == "l" else ARM_R
    if n == "head" or n.startswith("head") and not side:
        return HEAD
    return 0


def pivot_bone(part, bones):
    """The joint a limb swings from: hip, shoulder or neck."""
    want = {LEG_L: ("upperleg.l",), LEG_R: ("upperleg.r",), ARM_L: ("upperarm.l", "shoulder.l"), ARM_R: ("upperarm.r", "shoulder.r"), HEAD: ("head",)}.get(part, ())
    for w in want:
        for b in bones:
            if b.name.lower() == w:
                return b
    return None


def load(path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    if path.endswith(".blend"):
        bpy.ops.wm.open_mainfile(filepath=path)
    else:
        bpy.ops.import_scene.gltf(filepath=path)
    arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
    meshes = [o for o in bpy.data.objects if o.type == "MESH" and o.parent == arm]
    return arm, meshes


def pose(arm, action_name, frame=1):
    act = bpy.data.actions.get(action_name)
    if act is None:
        return
    arm.animation_data_create()
    arm.animation_data.action = act
    if hasattr(arm.animation_data, "action_slot") and arm.animation_data.action_slot is None and len(getattr(act, "slots", [])):
        arm.animation_data.action_slot = act.slots[0]
    bpy.context.scene.frame_set(frame)
    bpy.context.view_layer.update()


def to_linear(c):
    """Texture pixels are sRGB; vertex colours are linear. Writing one as the other washes colours out."""
    return tuple(x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c)


def image_sampler(mat):
    """Returns f(uv) -> rgb from the material's base-colour texture, or its flat colour."""
    if mat is None or not mat.use_nodes:
        return lambda uv: (0.7, 0.7, 0.7)
    tex = next((n for n in mat.node_tree.nodes if n.type == "TEX_IMAGE" and n.image), None)
    bsdf = next((n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
    if tex is None:
        c = bsdf.inputs["Base Color"].default_value if bsdf else (0.7, 0.7, 0.7, 1)
        return lambda uv: (c[0], c[1], c[2])
    im = tex.image
    w, h = im.size
    px = np.empty(w * h * 4, dtype=np.float32)
    im.pixels.foreach_get(px)
    px = px.reshape(h, w, 4)
    def f(uv):
        x = int((uv[0] % 1.0) * (w - 1))
        y = int((uv[1] % 1.0) * (h - 1))
        return tuple(px[y, x, :3])
    return f


def grade(rgb, sat=0.72, val=0.8):
    """Pull the packs' bright toy palette toward Shardfall's grim one before the shader's own grading."""
    l = 0.3 * rgb[0] + 0.59 * rgb[1] + 0.11 * rgb[2]
    return tuple(max(0.0, min(1.0, (l + (c - l) * sat) * val)) for c in rgb)


def bake(arm, meshes, weapon=None, eyes_from_dark=False):
    """Posed, coloured, part-tagged geometry as one bmesh in armature-world space.
    Returns (bm, part per face, pivot height per part)."""
    dg = bpy.context.evaluated_depsgraph_get()
    out = bmesh.new()
    col_l = out.loops.layers.float_color.new("Col")
    face_part = []
    bones = arm.pose.bones
    for ob in meshes:
        if not ob.visible_get() and ob.hide_render:
            continue
        me = ob.data
        names = {g.index: g.name for g in ob.vertex_groups}
        vpart = []
        for v in me.vertices:
            best, bw = None, 0.0
            for g in v.groups:
                if g.weight > bw:
                    best, bw = names.get(g.group), g.weight
            vpart.append(part_of_bone(best) if best else 0)
        mats = list(me.materials)
        samplers = [image_sampler(m) for m in mats]
        glow_mat = [m is not None and ("glow" in m.name.lower() or "eye" in m.name.lower()) for m in mats]
        src = bmesh.new()
        src.from_object(ob, dg)
        src.transform(ob.matrix_world)
        uvl = src.loops.layers.uv.active
        vmap = {}
        for v in src.verts:
            vmap[v.index] = out.verts.new(v.co)
        for f in src.faces:
            try:
                nf = out.faces.new([vmap[v.index] for v in f.verts])
            except ValueError:
                continue
            counts = {}
            for v in f.verts:
                p = vpart[v.index] if v.index < len(vpart) else 0
                counts[p] = counts.get(p, 0) + 1
            p = max(counts, key=counts.get)
            mi = f.material_index if f.material_index < len(mats) else 0
            if mats and glow_mat[mi]:
                p = EYE
            # one colour per face, sampled at the face's UV centroid: per-corner samples straddle palette
            # swatches once the mesh is decimated, and the swarm read as speckled confetti (polish pass)
            if mats and uvl:
                cu = sum((lo[uvl].uv for lo in f.loops), Vector((0.0, 0.0))) / len(f.loops)
                c1 = samplers[mi](cu)
                cols = [c1] * len(f.loops)
            else:
                cols = [(0.7, 0.7, 0.7)] * len(f.loops)
            lum = sum(0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2] for c in cols) / len(cols)
            if p == HEAD and lum < 0.13 and eyes_from_dark:
                p = EYE                     # pupils and maw: lit from inside, like the procedural foes' eyes
            face_part.append(p)
            for lo_new, rgb in zip(nf.loops, cols):
                lo_new[col_l] = (*to_linear(grade(rgb)), 1.0)
        src.free()
    pivots = {}
    for part in (LEG_L, LEG_R, ARM_L, ARM_R, HEAD):
        b = pivot_bone(part, bones)
        if b is not None:
            pivots[part] = (arm.matrix_world @ b.head).z
    if weapon:
        wpath, slot = weapon
        before = set(bpy.data.objects)
        bpy.ops.import_scene.gltf(filepath=wpath)
        wobs = [o for o in bpy.data.objects if o not in before and o.type == "MESH"]
        pb = bones.get(slot)
        if pb is not None:
            M = arm.matrix_world @ pb.matrix
            for wo in wobs:
                w = bmesh.new()
                w.from_mesh(wo.data)
                w.transform(M @ wo.matrix_world)
                samp = image_sampler(wo.data.materials[0] if wo.data.materials else None)
                wuv = w.loops.layers.uv.active
                part = ARM_R if slot.endswith("r") else ARM_L
                vm = {v.index: out.verts.new(v.co) for v in w.verts}
                for f in w.faces:
                    nf = out.faces.new([vm[v.index] for v in f.verts])
                    face_part.append(part)
                    for lo_new, lo in zip(nf.loops, f.loops):
                        rgb = samp(lo[wuv].uv) if wuv else (0.6, 0.6, 0.6)
                        lo_new[col_l] = (*to_linear(grade(rgb)), 1.0)
                w.free()
    out.faces.ensure_lookup_table()
    return out, face_part, pivots


def orient_and_scale(bm, pivots, height, forward="-Y"):
    """Rotate so the creature faces +X, put the feet on 0 and scale to height."""
    rot = {"-Y": math.pi / 2, "+Y": -math.pi / 2, "+X": 0.0, "-X": math.pi}[forward]
    bm.transform(Matrix.Rotation(rot, 4, "Z"))
    zs = [v.co.z for v in bm.verts]
    z0, z1 = min(zs), max(zs)
    k = height / max(1e-4, z1 - z0)
    xs = [v.co.x for v in bm.verts]
    ys = [v.co.y for v in bm.verts]
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    bm.transform(Matrix.Scale(k, 4) @ Matrix.Translation((-cx, -cy, -z0)))
    return {p: (z - z0) * k for p, z in pivots.items()}


def grow_crystals(bm, face_part, n, height, seed):
    """Glowing shard crystals (part 7) on the upper back, pointing up and back."""
    rnd = random.Random(seed)
    col_l = bm.loops.layers.float_color["Col"]
    cand = [v.co.copy() for v in bm.verts if 0.45 * height < v.co.z < 0.85 * height]
    if not cand or n <= 0:
        return
    cand.sort(key=lambda c: c.x)
    back = cand[: max(8, len(cand) // 12)]           # the most rearward band
    for i in range(n):
        base = rnd.choice(back)
        size = height * rnd.uniform(0.12, 0.22)
        tilt = Euler((rnd.uniform(-0.6, 0.6), -0.7 - rnd.uniform(0, 0.5), rnd.uniform(0, math.pi)), "XYZ").to_matrix().to_4x4()
        c = bmesh.new()
        bmesh.ops.create_cone(c, cap_ends=True, cap_tris=True, segments=5, radius1=size * 0.22, radius2=0.0, depth=size)
        c.transform(Matrix.Translation(base + Vector((-size * 0.15, 0, size * 0.3))) @ tilt @ Matrix.Translation((0, 0, size * 0.45)))
        vm = {v: bm.verts.new(v.co) for v in c.verts}
        for f in c.faces:
            nf = bm.faces.new([vm[v] for v in f.verts])
            face_part.append(GLOW)
            for lo in nf.loops:
                lo[col_l] = (0.75, 0.9, 1.0, 1.0)
        c.free()


def split_decimate_join(bm, face_part, pivots, tris, name):
    """One object per part, decimated to its share of the budget, joined, with UV2 = (part, pivot)."""
    total = sum(len(f.verts) - 2 for f in bm.faces)
    ratio = min(1.0, tris / max(1, total))
    obs = []
    bm.faces.ensure_lookup_table()
    for part in sorted(set(face_part)):
        sub = bm.copy()
        sub.faces.ensure_lookup_table()
        kill = [f for i, f in enumerate(sub.faces) if face_part[i] != part]
        bmesh.ops.delete(sub, geom=kill, context="FACES")
        bmesh.ops.delete(sub, geom=[v for v in sub.verts if not v.link_faces], context="VERTS")
        me = bpy.data.meshes.new(f"{name}_{part}")
        sub.to_mesh(me)
        sub.free()
        ob = bpy.data.objects.new(me.name, me)
        bpy.context.scene.collection.objects.link(ob)
        if ratio < 1.0 and part not in (EYE, GLOW):
            bpy.context.view_layer.objects.active = ob
            # first merge coplanar facets (lossless on faceted low-poly), then collapse to the budget
            pl = ob.modifiers.new("planar", "DECIMATE")
            pl.decimate_type = "DISSOLVE"
            pl.angle_limit = math.radians(4.0)
            pl.delimit = {"NORMAL"}
            bpy.ops.object.modifier_apply(modifier="planar")
            tri = ob.modifiers.new("tri", "TRIANGULATE")
            bpy.ops.object.modifier_apply(modifier="tri")
            now = sum(len(p.vertices) - 2 for p in ob.data.polygons)
            share = max(24, int(len([f for f in face_part if f == part]) * ratio))
            if now > share:
                d = ob.modifiers.new("dec", "DECIMATE")
                d.ratio = share / now
                d.use_collapse_triangulate = True
                bpy.ops.object.modifier_apply(modifier="dec")
        me = ob.data
        me.uv_layers.new(name="UVMap")
        uv2 = me.uv_layers.new(name="UV2")
        for lo in uv2.data:
            lo.uv = (float(part), pivots.get(part, 0.0))
        obs.append(ob)
    bpy.ops.object.select_all(action="DESELECT")
    for ob in obs: ob.select_set(True)
    bpy.context.view_layer.objects.active = obs[0]
    bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    ob.name = name
    ob.data.shade_flat()                       # the packs are faceted low-poly; keep the facets crisp
    ob.data.color_attributes.active_color = ob.data.color_attributes["Col"]
    return ob


def build(kind, cfg, packs):
    arm, meshes = load(os.path.join(packs, cfg["src"]))
    pose(arm, cfg.get("action", "Idle"), cfg.get("frame", 1))
    weapon = cfg.get("weapon")
    if weapon:
        weapon = (os.path.join(packs, weapon[0]), weapon[1])
    bm, face_part, pivots = bake(arm, meshes, weapon, eyes_from_dark=cfg["src"].startswith("quaternius"))
    pivots = orient_and_scale(bm, pivots, cfg["height"], cfg.get("forward", "-Y"))
    grow_crystals(bm, face_part, cfg.get("crystals", 0), cfg["height"], hash(kind) & 0xffff)
    # drop the source scene, keep only the baked result
    for o in list(bpy.data.objects): bpy.data.objects.remove(o)
    ob = split_decimate_join(bm, face_part, pivots, int(cfg["tris"] * (HI if "--hi" in sys.argv else 1.0)), kind)
    tris = sum(len(p.vertices) - 2 for p in ob.data.polygons)
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, kind + ".glb")
    bpy.ops.object.select_all(action="DESELECT")
    ob.select_set(True)
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True, export_yup=True,
                              export_vertex_color="ACTIVE", export_active_vertex_color_when_no_material=True,
                              export_materials="NONE", export_animations=False, export_skins=False, export_normals=True)
    print(f"FOE {kind}: {tris} tris, parts {sorted(set(face_part))}, pivots { {k: round(v, 2) for k, v in pivots.items()} } -> {path}")


if __name__ == "__main__":
    argv = [a for a in (sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []) if a != "--hi"]
    packs = argv[0]
    for k in (argv[1:] or list(FOES)):
        build(k, FOES[k], packs)
