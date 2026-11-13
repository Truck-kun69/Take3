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
    "grunt":   {"src": f"{KK}/Characters/gltf/Skeleton_Minion.glb", "action": "Idle", "height": 2.1, "tris": 560, "crystals": 3,
                "weapon": (f"{KK}/Assets/gltf/Skeleton_Blade.gltf", "handslot.r")},
    "runner":  {"src": f"{QB}/Dino.blend", "action": "Idle", "height": 1.5, "tris": 800, "crystals": 4},
    "brute":   {"src": f"{QB}/Yeti.blend", "action": "Idle", "height": 2.6, "tris": 900, "crystals": 6},
    "spitter": {"src": f"{QB}/Frog.blend", "action": "Idle", "height": 1.7, "tris": 520, "crystals": 3},
    "charger": {"src": f"{QB}/Demon.blend", "action": "Idle", "height": 1.8, "tris": 800, "crystals": 4},
    "breach":  {"src": f"{QB}/Alien.blend", "action": "Idle", "height": 1.8, "tris": 800, "crystals": 2},
    "goblin":  {"src": f"{QB}/MushroomKing.blend", "action": "Idle", "height": 1.9, "tris": 900, "crystals": 3},
    "splitter": {"src": f"{QL}/GreenSpikyBlob.gltf", "action": "Idle", "height": 2.0, "tris": 560, "crystals": 4},
    # Act V, the Drowned Cathedral: drowned dead and fish-men (models/foes/<kind>_4 replace <kind> in that act)
    "grunt_4": {"src": f"{KK}/Characters/gltf/Skeleton_Rogue.glb", "action": "Idle", "height": 2.1, "tris": 560, "crystals": 2,
                "weapon": (f"{KK}/Assets/gltf/Skeleton_Blade.gltf", "handslot.r")},
    "runner_4": {"src": f"{QB}/Fish.blend", "action": "Idle", "height": 1.6, "tris": 800, "crystals": 3},
    "mini":    {"src": f"{QL}/GreenBlob.gltf", "action": "Idle", "height": 1.0, "tris": 450, "crystals": 1},
}

LEG_L, LEG_R, ARM_L, ARM_R, HEAD, EYE, GLOW = 1, 2, 3, 4, 5, 6, 7

# Vertex animation: the packs' own clips, baked per foe into <kind>.vat (see bake_vat). slot -> action name.
CLIPS_QB = {"walk": "Walk", "attack": "Punch", "hit": "HitReact", "death": "Death", "spawn": "Jump_Land"}
CLIPS_QB_RUN = dict(CLIPS_QB, walk="Run")
CLIPS_BLOB = {"walk": "Walk", "attack": "Bite_Front", "hit": "HitRecieve", "death": "Death", "spawn": "Jump"}
CLIPS_KK = {"walk": "Walking_A", "attack": "1H_Melee_Attack_Chop", "hit": "Hit_A", "death": "Death_A", "spawn": "Spawn_Ground_Skeletons"}
CLIP_ORDER = ["walk", "attack", "hit", "death", "spawn"]
CLIP_LOOP = {"walk": True}
MAX_ROWS = 24                      # frames kept per clip (the shader interpolates between them)
SKIN = []                          # per baked vertex, in creation order: [(bone name, weight), ...]

def clips_for(kind, cfg):
    if "clips" in cfg: return cfg["clips"]
    if cfg["src"].startswith("KayKit"): return dict(CLIPS_KK, walk="Running_A") if kind == "grunt_4" else CLIPS_KK
    if "/Blob/" in cfg["src"]: return CLIPS_BLOB
    return CLIPS_QB_RUN if kind.split("_")[0] in ("runner", "charger") else CLIPS_QB


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
        pbone = ob.parent_bone if ob.parent_type == "BONE" else ""
        for v in src.verts:
            vmap[v.index] = out.verts.new(v.co)
            ws = []
            if v.index < len(me.vertices):
                ws = sorted(((names.get(g.group), g.weight) for g in me.vertices[v.index].groups if names.get(g.group) in bones and g.weight > 0.0),
                            key=lambda t: -t[1])[:4]
            if not ws and pbone: ws = [(pbone, 1.0)]
            SKIN.append(ws)
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
                SKIN.extend([[(slot, 1.0)]] * len(w.verts))
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
    T = Matrix.Scale(k, 4) @ Matrix.Translation((-cx, -cy, -z0)) @ Matrix.Rotation(rot, 4, "Z")
    return {p: (z - z0) * k for p, z in pivots.items()}, T


def grow_crystals(bm, face_part, n, height, seed):
    """Glowing shard crystals (part 7) on the upper back, pointing up and back."""
    rnd = random.Random(seed)
    col_l = bm.loops.layers.float_color["Col"]
    cand = [(v.co.copy(), v.index) for v in bm.verts if 0.45 * height < v.co.z < 0.85 * height]
    if not cand or n <= 0:
        return
    cand.sort(key=lambda c: c[0].x)
    back = cand[: max(8, len(cand) // 12)]           # the most rearward band
    for i in range(n):
        base, base_i = rnd.choice(back)
        size = height * rnd.uniform(0.12, 0.22)
        tilt = Euler((rnd.uniform(-0.6, 0.6), -0.7 - rnd.uniform(0, 0.5), rnd.uniform(0, math.pi)), "XYZ").to_matrix().to_4x4()
        c = bmesh.new()
        bmesh.ops.create_cone(c, cap_ends=True, cap_tris=True, segments=5, radius1=size * 0.22, radius2=0.0, depth=size)
        c.transform(Matrix.Translation(base + Vector((-size * 0.15, 0, size * 0.3))) @ tilt @ Matrix.Translation((0, 0, size * 0.45)))
        vm = {v: bm.verts.new(v.co) for v in c.verts}
        SKIN.extend([SKIN[base_i] if base_i < len(SKIN) else []] * len(c.verts))     # the whole crystal rides one body vertex
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
    # weld coincident vertices: per-face colour and part ids live on the corners, so nothing is lost, the
    # animation texture gets one column per real vertex, and its normals shade the body smoothly
    wb = bmesh.new()
    wb.from_mesh(ob.data)
    bmesh.ops.remove_doubles(wb, verts=wb.verts, dist=1e-4)
    wb.to_mesh(ob.data)
    wb.free()
    ob.data.shade_smooth()
    ob.data.color_attributes.active_color = ob.data.color_attributes["Col"]
    return ob


def bake_vat(kind, cfg, arm, ob, T, M0, src_pos, skin, path):
    """Vertex animation texture: the final (decimated) mesh re-skinned against the pack's skeleton and
    sampled through its own clips.
      Each final vertex takes the bone weights of the nearest baked source vertex. Its position in a
      frame is sum_b w_b * [T * B_b(frame) * B_b(bake pose)^-1 * T^-1] * p, so offsets from decimation,
      held weapons and grown crystals all ride their bones rigidly.
    File (little endian): "SVAT", u16 verts, u16 rows, u16 clips, u16 0; per clip: 8-byte name, u16 first
    row, u16 frames, f32 fps, u8 loop, 3 pad; positions rows*verts RGBA float16 (Godot axes); normals
    rows*verts RGBA8 (xyz * 0.5 + 0.5). Every clip carries one extra row (its first frame again when it
    loops, its last when it does not) so the shader can always blend row r with r + 1.
    The mesh's first UV channel is set to ((vertex + 0.5) / verts, 0.5): the texture column."""
    import struct
    from mathutils import kdtree
    me = ob.data
    n = len(me.vertices)
    kd = kdtree.KDTree(len(src_pos))
    for i, p in enumerate(src_pos): kd.insert(p, i)
    kd.balance()
    bone_ids = {b.name: i for i, b in enumerate(arm.pose.bones)}
    W = np.zeros((n, 4)); BI = np.zeros((n, 4), dtype=np.int64)
    P0 = np.ones((n, 4)); N0 = np.zeros((n, 3))
    for v in me.vertices:
        P0[v.index, :3] = v.co
        N0[v.index] = v.normal
        _, si, _ = kd.find(v.co)
        ws = [(bone_ids[b], w) for b, w in (skin[si] if si < len(skin) else []) if b in bone_ids]
        tot = sum(w for _, w in ws)
        for k, (b, w) in enumerate(ws[:4]):
            BI[v.index, k] = b; W[v.index, k] = w / tot
        if not ws: W[v.index, 0] = 0.0
    static = W.sum(axis=1) < 1e-6
    Ti = T.inverted()
    M0i = [M0[b.name].inverted() if b.name in M0 else Matrix.Identity(4) for b in arm.pose.bones]
    rows_p, rows_n, table = [], [], []
    fps_src = bpy.context.scene.render.fps
    for slot in CLIP_ORDER:
        act = bpy.data.actions.get(clips_for(kind, cfg).get(slot, ""))
        if act is None:
            print(f"  VAT {kind}: no clip for {slot}"); continue
        f0, f1 = int(act.frame_range[0]), int(act.frame_range[1])
        loop = CLIP_LOOP.get(slot, False)
        last = f1 - 1 if loop else f1
        step = max(1, math.ceil((last - f0 + 1) / MAX_ROWS))
        frames = list(range(f0, last + 1, step))
        first_row = len(rows_p)
        for fr in frames + [frames[0] if loop else frames[-1]]:
            pose(arm, act.name, fr)
            D = np.array([np.array(T @ (arm.matrix_world @ pb.matrix) @ M0i[i] @ Ti) for i, pb in enumerate(arm.pose.bones)])   # bones x 4 x 4
            P = np.zeros((n, 3)); Nn = np.zeros((n, 3))
            for k in range(4):
                Dk = D[BI[:, k]]                                                    # n x 4 x 4
                P += W[:, k:k + 1] * np.einsum("nij,nj->ni", Dk, P0)[:, :3]
                Nn += W[:, k:k + 1] * np.einsum("nij,nj->ni", Dk[:, :3, :3], N0)
            P[static] = P0[static, :3]; Nn[static] = N0[static]
            Nn /= np.maximum(1e-6, np.linalg.norm(Nn, axis=1, keepdims=True))
            rows_p.append(P); rows_n.append(Nn)
        table.append((slot, first_row, len(frames), fps_src / step, loop))
    if not rows_p:
        return
    Pa = np.array(rows_p); Na = np.array(rows_n)                                    # rows x n x 3, Blender axes
    pos = np.zeros((len(rows_p), n, 4), dtype=np.float16)
    pos[..., 0] = Pa[..., 0]; pos[..., 1] = Pa[..., 2]; pos[..., 2] = -Pa[..., 1]    # Blender (x, y, z) -> Godot (x, z, -y)
    nrm = np.zeros((len(rows_p), n, 4), dtype=np.uint8)
    nrm[..., 0] = np.clip((Na[..., 0] * 0.5 + 0.5) * 255.0, 0, 255); nrm[..., 1] = np.clip((Na[..., 2] * 0.5 + 0.5) * 255.0, 0, 255)
    nrm[..., 2] = np.clip((-Na[..., 1] * 0.5 + 0.5) * 255.0, 0, 255); nrm[..., 3] = 255
    with open(path, "wb") as f:
        f.write(b"SVAT" + struct.pack("<4H", n, len(rows_p), len(table), 0))
        for slot, first_row, cnt, fps, loop in table:
            f.write(slot.encode().ljust(8, b"\0") + struct.pack("<2Hf4B", first_row, cnt, fps, 1 if loop else 0, 0, 0, 0))
        f.write(pos.tobytes()); f.write(nrm.tobytes())
    uv = me.uv_layers["UVMap"].data
    for lo in me.loops: uv[lo.index].uv = ((lo.vertex_index + 0.5) / n, 0.5)
    pose(arm, cfg.get("action", "Idle"), cfg.get("frame", 1))
    print(f"  VAT {kind}: {n} verts x {len(rows_p)} rows, clips {[(t[0], t[2], round(t[3], 1)) for t in table]}, {os.path.getsize(path) // 1024} KB")


def build(kind, cfg, packs):
    arm, meshes = load(os.path.join(packs, cfg["src"]))
    SKIN.clear()
    pose(arm, cfg.get("action", "Idle"), cfg.get("frame", 1))
    M0 = {pb.name: (arm.matrix_world @ pb.matrix).copy() for pb in arm.pose.bones}     # the pose the mesh is baked in
    weapon = cfg.get("weapon")
    if weapon:
        weapon = (os.path.join(packs, weapon[0]), weapon[1])
    bm, face_part, pivots = bake(arm, meshes, weapon, eyes_from_dark=cfg["src"].startswith("quaternius"))
    pivots, T = orient_and_scale(bm, pivots, cfg["height"], cfg.get("forward", "-Y"))
    bm.verts.index_update()
    grow_crystals(bm, face_part, cfg.get("crystals", 0), cfg["height"], hash(kind) & 0xffff)
    bm.verts.ensure_lookup_table()
    src_pos = np.array([v.co[:] for v in bm.verts], dtype=np.float64)
    skin = list(SKIN)
    ob = split_decimate_join(bm, face_part, pivots, int(cfg["tris"] * (HI if "--hi" in sys.argv else 1.0)), kind)
    tris = sum(len(p.vertices) - 2 for p in ob.data.polygons)
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, kind + ".glb")
    if "--hi" not in sys.argv:
        bake_vat(kind, cfg, arm, ob, T, M0, src_pos, skin, os.path.join(OUT, kind + ".vat"))
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
