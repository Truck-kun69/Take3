"""Shardfall model builder: rigged, animated heroes and bosses, generated in headless Blender.

    ~/toolchains/blender/blender -b --factory-startup --python tools/blender/build_models.py -- [ids...]

ids: warden spark ember storm tyrant guardian herald (default: all). Output goes to the game's model
slots as glTF with shared external textures:
    godot/models/heroes/<id>.gltf   clips idle run cast roll hit die
    godot/models/bosses/<id>.gltf   clips idle walk attack hit die
    godot/models/textures/*.jpg     CC0 PBR sets (ambientCG, Poly Haven), packed by tools/blender/pack_textures.py

Conventions match godot/models/README.md: +X forward, +Y up in Godot (Z up here), feet at 0, game
units (a hero is ~50 tall). Bodies are Skin-modifier sculpts bound with automatic weights; armour,
weapons and props are rigid parts bound 100% to one bone; capes and skirts get hand-painted weights.
Materials whose name starts with "glow" are emissive; the game pulses them on casts and attacks.
"""
import bpy
import bmesh
import math
import os
import sys
from mathutils import Euler, Matrix, Quaternion, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
MODELS = os.path.join(ROOT, "godot", "models")
TEX = os.path.join(MODELS, "textures")
FPS = 24
TILE = 9.0          # world units per texture repeat


# ================================================================== scene + materials
_imgs = {}


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    _imgs.clear()
    bpy.context.scene.render.fps = FPS


def img(name, srgb):
    key = (name, srgb)
    if key not in _imgs:
        im = bpy.data.images.load(os.path.join(TEX, name), check_existing=True)
        im.colorspace_settings.name = "sRGB" if srgb else "Non-Color"
        _imgs[key] = im
    return _imgs[key]


def material(name, tex=None, color=(1, 1, 1), rough=0.6, metal=0.0, emis=None, estr=0.0, nstr=1.0):
    """PBR material. tex = texture set name in godot/models/textures (col/nrm/orm); color tints it
    (exported as glTF baseColorFactor). Without tex, a flat colour with scalar roughness/metallic."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    b = nt.nodes["Principled BSDF"]
    c = (color[0], color[1], color[2], 1.0)
    if tex:
        ti = nt.nodes.new("ShaderNodeTexImage")
        ti.image = img(f"{tex}_col.jpg", True)
        if tuple(color) != (1, 1, 1):
            mix = nt.nodes.new("ShaderNodeMix")
            mix.data_type = "RGBA"
            mix.blend_type = "MULTIPLY"
            mix.inputs[0].default_value = 1.0
            nt.links.new(ti.outputs["Color"], mix.inputs[6])
            mix.inputs[7].default_value = c
            nt.links.new(mix.outputs[2], b.inputs["Base Color"])
        else:
            nt.links.new(ti.outputs["Color"], b.inputs["Base Color"])
        to = nt.nodes.new("ShaderNodeTexImage")
        to.image = img(f"{tex}_orm.jpg", False)
        sep = nt.nodes.new("ShaderNodeSeparateColor")
        nt.links.new(to.outputs["Color"], sep.inputs["Color"])
        nt.links.new(sep.outputs["Green"], b.inputs["Roughness"])
        nt.links.new(sep.outputs["Blue"], b.inputs["Metallic"])
        tn = nt.nodes.new("ShaderNodeTexImage")
        tn.image = img(f"{tex}_nrm.jpg", False)
        nm = nt.nodes.new("ShaderNodeNormalMap")
        nm.inputs["Strength"].default_value = nstr
        nt.links.new(tn.outputs["Color"], nm.inputs["Color"])
        nt.links.new(nm.outputs["Normal"], b.inputs["Normal"])
    else:
        b.inputs["Base Color"].default_value = c
        b.inputs["Roughness"].default_value = rough
        b.inputs["Metallic"].default_value = metal
    if emis is not None:
        b.inputs["Emission Color"].default_value = (emis[0], emis[1], emis[2], 1.0)
        b.inputs["Emission Strength"].default_value = estr
    return m


# ================================================================== mesh parts
class Part:
    """Geometry built with bmesh in world space, plus the bone weights for its vertices."""
    def __init__(self, bm, mat, bone=None, weights=None, smooth=True, sharp=40.0):
        self.bm, self.mat, self.bone, self.weights, self.smooth, self.sharp = bm, mat, bone, weights, smooth, sharp


def _xf(loc=(0, 0, 0), size=(1, 1, 1), rot=(0, 0, 0)):
    return Matrix.Translation(Vector(loc)) @ Euler(rot, "XYZ").to_matrix().to_4x4() @ Matrix.Diagonal((*size, 1.0))


def shape(kind, loc, size, rot=(0, 0, 0), seg=12, rings=8, taper=1.0, open_ends=False):
    """Primitive with unit extent scaled by size (full lengths). kinds: box sphere hemi cyl cone tube
    oct prism torus. taper scales the top (+Z) end of cyl/box."""
    bm = bmesh.new()
    if kind == "box":
        bmesh.ops.create_cube(bm, size=1.0)
    elif kind in ("sphere", "hemi"):
        bmesh.ops.create_uvsphere(bm, u_segments=seg, v_segments=rings, radius=0.5)
        if kind == "hemi":
            bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.co.z < -1e-4], context="VERTS")
    elif kind in ("cyl", "cone", "tube"):
        r2 = 0.0 if kind == "cone" else 0.5 * taper
        bmesh.ops.create_cone(bm, cap_ends=not (open_ends or kind == "tube"), cap_tris=False, segments=seg,
                              radius1=0.5, radius2=max(r2, 0.0), depth=1.0)
    elif kind == "oct":
        bmesh.ops.create_uvsphere(bm, u_segments=4, v_segments=2, radius=0.5)
    elif kind == "prism":
        bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=True, segments=5, radius1=0.5, radius2=0.18, depth=1.0)
    elif kind == "torus":
        # ring in the XY plane, tube radius 0.12 of the unit ring
        R, r, n, m = 0.44, 0.06, seg, 6
        verts = []
        for i in range(n):
            a = 2 * math.pi * i / n
            ring = []
            for j in range(m):
                b = 2 * math.pi * j / m
                ring.append(bm.verts.new(((R + r * math.cos(b)) * math.cos(a), (R + r * math.cos(b)) * math.sin(a), r * math.sin(b))))
            verts.append(ring)
        for i in range(n):
            for j in range(m):
                bm.faces.new((verts[i][j], verts[(i + 1) % n][j], verts[(i + 1) % n][(j + 1) % m], verts[i][(j + 1) % m]))
    if kind == "box" and taper != 1.0:
        for v in bm.verts:
            if v.co.z > 0:
                v.co.x *= taper
                v.co.y *= taper
    bm.transform(_xf(loc, size, rot))
    bm.normal_update()
    return bm


def ring(center, radius, tube, rot=(0, 0, 0), seg=48, m=8):
    """Torus with absolute major radius and tube radius (shape('torus') scales the tube with the ring)."""
    bm = bmesh.new()
    rows = []
    for i in range(seg):
        a = 2 * math.pi * i / seg
        rows.append([bm.verts.new(((radius + tube * math.cos(b)) * math.cos(a), (radius + tube * math.cos(b)) * math.sin(a), tube * math.sin(b)))
                     for b in [2 * math.pi * j / m for j in range(m)]])
    for i in range(seg):
        for j in range(m):
            bm.faces.new((rows[i][j], rows[(i + 1) % seg][j], rows[(i + 1) % seg][(j + 1) % m], rows[i][(j + 1) % m]))
    bm.transform(Matrix.Translation(Vector(center)) @ Euler(rot, "XYZ").to_matrix().to_4x4())
    bm.normal_update()
    return bm


def deform(bm, fn):
    for v in bm.verts:
        v.co = Vector(fn(v.co.copy()))
    bm.normal_update()
    return bm


def strip(points, widths, normal_side=(0, 1, 0), segs=6, thick=0.25):
    """A cloth strip (cape, tabard, skirt panel) along a polyline of centre points; widths per point.
    Built as a thin two-sided slab so it shades from both sides."""
    bm = bmesh.new()
    side = Vector(normal_side).normalized()
    rows = []
    for p, w in zip(points, widths):
        p = Vector(p)
        rows.append([bm.verts.new(p + side * (w * (i / segs - 0.5))) for i in range(segs + 1)])
    for r in range(len(rows) - 1):
        for i in range(segs):
            bm.faces.new((rows[r][i], rows[r][i + 1], rows[r + 1][i + 1], rows[r + 1][i]))
    bmesh.ops.solidify(bm, geom=bm.faces[:], thickness=thick)
    bm.normal_update()
    return bm


def skin_body(nodes, edges, root="pelvis", subsurf=2):
    """Organic body from a joint graph: nodes {name: (pos, (rx, ry))}, edges [(a, b)]."""
    me = bpy.data.meshes.new("body_skin")
    names = list(nodes)
    me.from_pydata([nodes[n][0] for n in names], [(names.index(a), names.index(b)) for a, b in edges], [])
    ob = bpy.data.objects.new("body_skin", me)
    bpy.context.scene.collection.objects.link(ob)
    sk = ob.modifiers.new("skin", "SKIN")
    sk.use_smooth_shade = True
    for i, n in enumerate(names):
        d = me.skin_vertices[0].data[i]
        d.radius = nodes[n][1]
        d.use_root = (n == root)
    ss = ob.modifiers.new("sub", "SUBSURF")
    ss.levels = subsurf
    ss.render_levels = subsurf
    dg = bpy.context.evaluated_depsgraph_get()
    bm = bmesh.new()
    bm.from_object(ob, dg)
    bpy.data.objects.remove(ob)
    bpy.data.meshes.remove(me)
    bm.normal_update()
    return bm


# ================================================================== skeleton
class Rig:
    """Armature from (name, head, tail, parent) tuples; pose helpers take rotations in armature axes
    (X forward, Y left, Z up) about each bone's head, whatever the bone's own roll."""
    def __init__(self, name, bones):
        arm = bpy.data.armatures.new(name + "_rig")
        self.ob = bpy.data.objects.new(name, arm)
        bpy.context.scene.collection.objects.link(self.ob)
        bpy.context.view_layer.objects.active = self.ob
        bpy.ops.object.mode_set(mode="EDIT")
        for n, h, t, p in bones:
            eb = arm.edit_bones.new(n)
            eb.head, eb.tail = Vector(h), Vector(t)
            eb.roll = 0.0
            if p: eb.parent = arm.edit_bones[p]
        bpy.ops.object.mode_set(mode="OBJECT")
        self.rest = {b.name: b.matrix_local.to_3x3() for b in arm.bones}
        for pb in self.ob.pose.bones:
            pb.rotation_mode = "QUATERNION"
        self.names = [b[0] for b in bones]
        self.base = {}      # bone -> (rx, ry, rz) added to every pose: corrects a rest pose that isn't the clips' (A-pose arms)

    def clip(self, name, frames, pose_fn, loop=False):
        """pose_fn(t in 0..1) -> {bone: (rx, ry, rz) or ((rx, ry, rz), (x, y, z))} in armature axes."""
        ob = self.ob
        ob.animation_data_create()
        act = bpy.data.actions.new(name)
        ob.animation_data.action = act
        for f in range(frames + 1):
            t = 0.0 if (loop and f == frames) else f / frames      # loops end exactly on their first pose
            pose = pose_fn(t)
            for pb in ob.pose.bones:
                v = pose.get(pb.name, (0, 0, 0))
                rot, loc = (v if isinstance(v[0], (tuple, list)) else (v, (0, 0, 0)))
                if pb.name in self.base:
                    rot = tuple(r + o for r, o in zip(rot, self.base[pb.name]))
                R = self.rest[pb.name]
                q = (R.inverted() @ Euler(rot, "XYZ").to_matrix() @ R).to_quaternion()
                pb.rotation_quaternion = q
                pb.location = R.inverted() @ Vector(loc)
                pb.keyframe_insert("rotation_quaternion", frame=f + 1)
                pb.keyframe_insert("location", frame=f + 1)
        # keep the action: one NLA track per clip, so the glTF exporter writes every clip by name
        tr = ob.animation_data.nla_tracks.new()
        tr.name = name
        tr.strips.new(name, 1, act)
        act.use_fake_user = True
        ob.animation_data.action = None


def bind(rig, parts, body_bm=None, body_mat=None, exclude_auto=()):
    """Join parts into one skinned mesh. The body gets automatic (heat) weights; every Part brings
    its own: a single bone (rigid) or a weight function co -> {bone: w}."""
    meshes = []
    mats = []

    def add_mat(m):
        if m not in mats: mats.append(m)
        return mats.index(m)

    obs = []
    if body_bm is not None:
        me = bpy.data.meshes.new("body")
        body_bm.to_mesh(me)
        ob = bpy.data.objects.new("body", me)
        bpy.context.scene.collection.objects.link(ob)
        ob.data.materials.append(body_mat)
        cube_uv(ob.data)
        # automatic weights against the deforming bones only
        for b in rig.ob.data.bones:
            b.use_deform = b.name not in exclude_auto
        bpy.ops.object.select_all(action="DESELECT")
        ob.select_set(True)
        rig.ob.select_set(True)
        bpy.context.view_layer.objects.active = rig.ob
        bpy.ops.object.parent_set(type="ARMATURE_AUTO")
        for b in rig.ob.data.bones:
            b.use_deform = True
        obs.append(ob)
    for i, p in enumerate(parts):
        me = bpy.data.meshes.new(f"part{i}")
        p.bm.to_mesh(me)
        ob = bpy.data.objects.new(f"part{i}", me)
        bpy.context.scene.collection.objects.link(ob)
        ob.data.materials.append(p.mat)
        cube_uv(ob.data)
        if p.smooth:
            me.shade_smooth()
            me.set_sharp_from_angle(angle=math.radians(p.sharp))
        else:
            me.shade_flat()
        groups = {}
        for v in me.vertices:
            w = {p.bone: 1.0} if p.weights is None else p.weights(v.co)
            for bn, wt in w.items():
                if wt <= 0: continue
                g = groups.get(bn) or ob.vertex_groups.new(name=bn)
                groups[bn] = g
                g.add([v.index], wt, "REPLACE")
        obs.append(ob)
    bpy.ops.object.select_all(action="DESELECT")
    for ob in obs: ob.select_set(True)
    bpy.context.view_layer.objects.active = obs[0]
    bpy.ops.object.join()
    mesh_ob = bpy.context.view_layer.objects.active
    mesh_ob.name = rig.ob.name + "_mesh"
    mesh_ob.parent = rig.ob
    mod = mesh_ob.modifiers.get("Armature") or mesh_ob.modifiers.new("Armature", "ARMATURE")
    mod.object = rig.ob
    # merge duplicate material slots created by joining
    return mesh_ob


def cube_uv(me):
    """World-scale box projection: consistent texel density on every part, no seams to author."""
    if not me.uv_layers:
        me.uv_layers.new(name="UVMap")
    uv = me.uv_layers.active.data
    for poly in me.polygons:
        n = poly.normal
        ax = max(range(3), key=lambda k: abs(n[k]))
        a, b = [(1, 2), (0, 2), (0, 1)][ax]
        for li in poly.loop_indices:
            co = me.vertices[me.loops[li].vertex_index].co
            uv[li].uv = (co[a] / TILE, co[b] / TILE)


def export(rig, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.ops.object.select_all(action="DESELECT")
    rig.ob.select_set(True)
    for c in rig.ob.children: c.select_set(True)
    bpy.ops.export_scene.gltf(
        filepath=path, export_format="GLTF_SEPARATE", export_texture_dir="../textures",
        use_selection=True, export_yup=True, export_apply=False, export_animations=True,
        export_animation_mode="NLA_TRACKS", export_force_sampling=True, export_frame_step=1,
        export_def_bones=False, export_skins=True, export_image_format="AUTO",
        export_materials="EXPORT", export_tangents=False, export_morph=False, export_lights=False,
        export_cameras=False)
    print("EXPORTED", path)


# ================================================================== humanoid
def ease(t): return t * t * (3 - 2 * t)
def S(x): return math.sin(x)
def C(x): return math.cos(x)
def fwd(a): return (0.0, -a, 0.0)       # swing a hanging limb forward
def lean(a): return (0.0, a, 0.0)       # tip an upright bone forward


def humanoid(H=50.0, bulk=1.0, hunch=0.0, legs=1.0, arms=1.0):
    """Joint positions (Z up, X forward, Y left), skin radii, bones. H = standing height."""
    s = H / 50.0
    def P(x, y, z): return Vector((x * s, y * s, z * s))
    J = {
        "root": P(0, 0, 0), "pelvis": P(0, 0, 25.5), "spine": P(0.2 + hunch * 1.5, 0, 30.5), "chest": P(0.3 + hunch * 3.0, 0, 35.2),
        "collar": P(0.3 + hunch * 4.0, 0, 38.4), "neck": P(0.5 + hunch * 5.0, 0, 40.6 - hunch * 1.0), "head": P(0.7 + hunch * 6.0, 0, 43.2 - hunch * 1.5),
        "top": P(0.7 + hunch * 6.0, 0, 48.6 - hunch * 1.5),
    }
    for side, sy in (("L", 1), ("R", -1)):
        J[f"shoulder.{side}"] = P(0.2 + hunch * 4.0, sy * 5.8 * bulk, 38.2)
        J[f"elbow.{side}"] = P(-0.6 + hunch * 3.0, sy * 7.6 * bulk, 38.2 - 7.0 * arms)
        J[f"wrist.{side}"] = P(0.6 + hunch * 3.0, sy * 8.3 * bulk, 38.2 - 13.4 * arms)
        J[f"hand.{side}"] = P(1.1 + hunch * 3.0, sy * 8.5 * bulk, 38.2 - 16.2 * arms)
        J[f"hip.{side}"] = P(0, sy * 2.9 * bulk, 24.4)
        J[f"knee.{side}"] = P(1.0, sy * 3.1 * bulk, 24.4 - 11.0 * legs)
        J[f"ankle.{side}"] = P(-0.2, sy * 3.2 * bulk, 2.6)
        J[f"toe.{side}"] = P(3.6, sy * 3.2 * bulk, 0.7)
    bones = [
        ("root", J["root"], J["root"] + Vector((0, 0, 6 * s)), None),
        ("hips", J["pelvis"], J["spine"], "root"),
        ("spine", J["spine"], J["chest"], "hips"),
        ("chest", J["chest"], J["neck"], "spine"),
        ("neck", J["neck"], J["head"], "chest"),
        ("head", J["head"], J["top"], "neck"),
    ]
    for side in ("L", "R"):
        bones += [
            (f"upperarm.{side}", J[f"shoulder.{side}"], J[f"elbow.{side}"], "chest"),
            (f"forearm.{side}", J[f"elbow.{side}"], J[f"wrist.{side}"], f"upperarm.{side}"),
            (f"hand.{side}", J[f"wrist.{side}"], J[f"hand.{side}"], f"forearm.{side}"),
            (f"thigh.{side}", J[f"hip.{side}"], J[f"knee.{side}"], "hips"),
            (f"shin.{side}", J[f"knee.{side}"], J[f"ankle.{side}"], f"thigh.{side}"),
            (f"foot.{side}", J[f"ankle.{side}"], J[f"toe.{side}"], f"shin.{side}"),
        ]
    # three-segment cape chain hanging behind the shoulders
    c0 = J["collar"] + Vector((-3.2 * s * bulk, 0, 0.6 * s))
    bones += [("cape1", c0, c0 + Vector((-0.6 * s, 0, -9 * s)), "chest"),
              ("cape2", c0 + Vector((-0.6 * s, 0, -9 * s)), c0 + Vector((-1.0 * s, 0, -18 * s)), "cape1"),
              ("cape3", c0 + Vector((-1.0 * s, 0, -18 * s)), c0 + Vector((-1.2 * s, 0, -27 * s)), "cape2")]
    b = bulk * s
    R = {
        "pelvis": (4.0 * b, 4.6 * b), "spine": (3.5 * b, 4.1 * b), "chest": (4.3 * b, 5.0 * b), "collar": (3.6 * b, 4.6 * b),
        "neck": (1.55 * s, 1.55 * s), "head": (2.9 * s, 2.9 * s), "top": (1.5 * s, 1.5 * s),
    }
    for side in ("L", "R"):
        R.update({f"shoulder.{side}": (1.9 * b, 1.9 * b), f"elbow.{side}": (1.35 * b, 1.35 * b), f"wrist.{side}": (1.0 * b, 1.0 * b),
                  f"hand.{side}": (1.15 * b, 1.15 * b), f"hip.{side}": (2.5 * b, 2.5 * b), f"knee.{side}": (1.75 * b, 1.75 * b),
                  f"ankle.{side}": (1.2 * b, 1.2 * b), f"toe.{side}": (0.95 * b, 0.95 * b)})
    nodes = {n: (J[n], R[n]) for n in R}
    edges = [("pelvis", "spine"), ("spine", "chest"), ("chest", "collar"), ("collar", "neck"), ("neck", "head"), ("head", "top")]
    for side in ("L", "R"):
        edges += [("collar", f"shoulder.{side}"), (f"shoulder.{side}", f"elbow.{side}"), (f"elbow.{side}", f"wrist.{side}"),
                  (f"wrist.{side}", f"hand.{side}"), ("pelvis", f"hip.{side}"), (f"hip.{side}", f"knee.{side}"),
                  (f"knee.{side}", f"ankle.{side}"), (f"ankle.{side}", f"toe.{side}")]
    return J, nodes, edges, bones, s


def mid(a, b, k=0.5): return a.lerp(b, k)


def limb_part(kind, a, b, radius, mat, bone, k0=0.0, k1=1.0, seg=10, taper=1.0, flat=False):
    """A primitive spanning a bone segment from a to b (fractions k0..k1), radius across."""
    p0, p1 = a.lerp(b, k0), a.lerp(b, k1)
    d = p1 - p0
    q = Vector((0, 0, 1)).rotation_difference(d.normalized())
    bm = shape(kind, (0, 0, 0), (radius * 2, radius * 2 * (0.8 if flat else 1.0), d.length), seg=seg, taper=taper)
    bm.transform(Matrix.Translation((p0 + p1) / 2) @ q.to_matrix().to_4x4())
    return Part(bm, mat, bone)


# ------------------------------------------------------------------ clips
def hero_clips(rig, weapon_side="R", two_hand=False, s=1.0, cape=True, stride=0.75):
    W = weapon_side
    O = "L" if W == "R" else "R"
    sgn = {"L": 1.0, "R": -1.0}
    def arm_out(side, a): return (sgn[side] * a, 0.0, 0.0)
    def add(*rs): return tuple(sum(r[i] for r in rs) for i in range(3))
    rest_arm = 0.12

    def idle(t):
        ph = 2 * math.pi * t
        br = S(ph)
        return {
            "spine": lean(0.03 + 0.02 * br), "chest": lean(-0.02 * br), "head": add(lean(-0.03 * br), (0, 0, 0.12 * S(ph * 0.5 + 1))),
            f"upperarm.{O}": add(arm_out(O, rest_arm + 0.03 * br), fwd(0.05)), f"forearm.{O}": fwd(0.25),
            f"upperarm.{W}": add(arm_out(W, rest_arm), fwd(0.15)), f"forearm.{W}": fwd(0.55 + 0.03 * br),
            "thigh.L": fwd(0.03), "thigh.R": fwd(-0.04), "shin.L": fwd(-0.05), "shin.R": fwd(-0.03),
            "cape1": fwd(-0.06 - 0.03 * S(ph + 0.5)), "cape2": fwd(-0.04 * S(ph + 1.2)), "cape3": fwd(-0.05 * S(ph + 2.0)),
            "root": ((0, 0, 0), (0, 0, -0.25 * s * (0.5 + 0.5 * br))),
        }

    def run(t):
        ph = 2 * math.pi * t
        sw = S(ph)
        kl = 0.3 + 1.1 * max(0.0, -S(ph + 0.6))
        kr = 0.3 + 1.1 * max(0.0, S(ph + 0.6))
        return {
            "hips": ((0, 0, -0.12 * sw)), "spine": add(lean(0.16), (0, 0, 0.1 * sw)), "chest": (0, 0, 0.12 * sw), "head": lean(-0.12),
            "thigh.L": fwd(stride * sw + 0.1), "thigh.R": fwd(-stride * sw + 0.1), "shin.L": fwd(-kl), "shin.R": fwd(-kr),
            "foot.L": fwd(0.25 * max(0.0, -sw)), "foot.R": fwd(0.25 * max(0.0, sw)),
            f"upperarm.{O}": add(arm_out(O, 0.15), fwd(-0.55 * sw * sgn[O])), f"forearm.{O}": fwd(0.7),
            f"upperarm.{W}": add(arm_out(W, 0.15), fwd(0.25 + (-0.25 if two_hand else -0.35) * sw * sgn[W])), f"forearm.{W}": fwd(0.8),
            "cape1": fwd(-0.55 - 0.08 * S(2 * ph)), "cape2": fwd(-0.18 - 0.1 * S(2 * ph + 1.0)), "cape3": fwd(-0.12 - 0.14 * S(2 * ph + 2.0)),
            "root": ((0, 0, 0), (0, 0, s * (0.9 * abs(sw) - 0.9))),
        }

    def cast(t):
        k = S(math.pi * min(1.0, t * 1.7)) if t < 0.59 else max(0.0, 1.0 - (t - 0.59) / 0.41) * 1.0
        k = max(0.0, k)
        return {
            "spine": add(lean(0.12 * k), (0, 0, -0.35 * k * sgn[W])), "chest": (0, 0, -0.15 * k * sgn[W]), "head": (0, 0, 0.3 * k * sgn[W]),
            f"upperarm.{W}": add(arm_out(W, 0.15 + 0.1 * k), fwd(0.15 + 1.25 * k)), f"forearm.{W}": fwd(0.55 - 0.45 * k),
            f"upperarm.{O}": add(arm_out(O, 0.15 + 0.35 * k), fwd(0.05 - 0.45 * k)), f"forearm.{O}": fwd(0.3 + 0.4 * k),
            "thigh.L": fwd(0.25 * k * sgn["L"] * sgn[W] * -1), "thigh.R": fwd(-0.2 * k * sgn["L"] * sgn[W] * -1), "shin.R": fwd(-0.25 * k), "shin.L": fwd(-0.15 * k),
            "cape1": fwd(-0.15 - 0.15 * k), "cape2": fwd(-0.1 * k),
            "root": ((0, 0, 0), (0, 0, -0.9 * s * k)),
        }

    def roll(t):
        e = ease(t)
        tuck = S(math.pi * t)
        return {
            "hips": lean(2 * math.pi * e),
            "spine": lean(0.6 * tuck), "chest": lean(0.4 * tuck), "head": lean(0.5 * tuck),
            "thigh.L": fwd(1.7 * tuck), "thigh.R": fwd(1.6 * tuck), "shin.L": fwd(-2.2 * tuck), "shin.R": fwd(-2.1 * tuck),
            "upperarm.L": fwd(1.1 * tuck), "upperarm.R": fwd(1.1 * tuck), "forearm.L": fwd(1.3 * tuck), "forearm.R": fwd(1.3 * tuck),
            "cape1": fwd(-0.8 * tuck), "cape2": fwd(-0.4 * tuck), "cape3": fwd(-0.3 * tuck),
            "root": ((0, 0, 0), (0, 0, -12.5 * s * tuck)),
        }

    def hit(t):
        k = S(math.pi * t) * (1.0 - 0.3 * t)
        return {
            "spine": lean(-0.32 * k), "chest": lean(-0.15 * k), "head": add(lean(-0.45 * k), (0.15 * k, 0, 0)),
            "upperarm.L": add(arm_out("L", 0.12 + 0.35 * k), fwd(0.2 * k)), "upperarm.R": add(arm_out("R", 0.12 + 0.35 * k), fwd(0.25 * k)),
            "forearm.L": fwd(0.3 + 0.5 * k), "forearm.R": fwd(0.55 + 0.4 * k), "shin.L": fwd(-0.3 * k), "shin.R": fwd(-0.2 * k),
            "cape1": fwd(0.3 * k), "root": ((0, 0, 0), (-1.8 * s * k, 0, -0.6 * s * k)),
        }

    def die(t):
        a = min(1.0, t / 0.35)
        b = ease(min(1.0, max(0.0, (t - 0.2) / 0.6)))
        bounce = S(math.pi * min(1.0, max(0.0, (t - 0.8) / 0.2))) * 0.06
        return {
            "root": ((0, -math.pi / 2 * b + bounce, 0), (-2.5 * s * b, 0, -1.5 * s * a)),
            "thigh.L": fwd(0.6 * a - 0.3 * b), "thigh.R": fwd(0.9 * a - 0.2 * b), "shin.L": fwd(-1.1 * a + 0.6 * b), "shin.R": fwd(-1.4 * a + 0.5 * b),
            "spine": lean(0.35 * a - 0.4 * b), "head": add(lean(-0.5 * b), (0, 0, 0.6 * b)),
            "upperarm.L": add(arm_out("L", 0.2 + 1.1 * b), fwd(0.3 * a)), "upperarm.R": add(arm_out("R", 0.2 + 0.9 * b), fwd(0.4 * a)),
            "forearm.L": fwd(0.6 * a - 0.4 * b), "forearm.R": fwd(0.8 * a - 0.3 * b),
            "cape1": fwd(0.5 * b), "cape2": fwd(0.3 * b),
        }

    rig.clip("idle", 48, idle, loop=True)
    rig.clip("run", 16, run, loop=True)
    rig.clip("cast", 12, cast)
    rig.clip("roll", 13, roll)
    rig.clip("hit", 8, hit)
    rig.clip("die", 30, die)


def cape_weights(J, s):
    """Cape cloth: chest at the collar, then down the cape chain by height."""
    z0 = J["collar"].z
    def w(co):
        d = (z0 - co.z) / (9.0 * s)
        if d < 0.25: return {"chest": 1.0 - d * 2, "cape1": d * 2 + 0.5}
        seg = min(2.0, max(0.0, d - 0.25))
        i = int(seg)
        f = seg - i
        names = ["cape1", "cape2", "cape3"]
        out = {names[i]: 1.0 - f}
        if i + 1 < 3: out[names[i + 1]] = f
        return out
    return w


def skirt_weights(J, s):
    """Robe and tasset cloth: hips at the waist, sliding toward each thigh lower down, so a stride
    pushes the near side without tearing the hem."""
    zt = J["pelvis"].z
    zk = J["knee.L"].z
    def w(co):
        k = min(1.0, max(0.0, (zt - co.z) / max(1e-3, zt - zk)))
        side = "thigh.L" if co.y > 0 else "thigh.R"
        lat = min(1.0, abs(co.y) / (4.5 * s))
        tw = k * (0.25 + 0.45 * lat)
        return {"hips": 1.0 - tw, side: tw}
    return w


# ================================================================== heroes
def V(x, y, z): return Vector((x, y, z))


def helm_parts(J, s, mat, trim, visor_mat):
    h = J["head"]
    out = [
        Part(shape("cyl", h + V(0.1, 0, 1.6) * s, V(7.0, 6.6, 7.2) * s, seg=16, taper=0.92), mat, "head", sharp=50),
        Part(shape("hemi", h + V(0.1, 0, 5.2) * s, V(6.5, 6.1, 4.2) * s, seg=16, rings=8), mat, "head"),
        Part(shape("box", h + V(3.25, 0, 2.2) * s, V(0.6, 4.6, 0.7) * s), visor_mat, "head", smooth=False),      # eye slit
        Part(shape("box", h + V(3.1, 0, 0.3) * s, V(0.5, 0.5, 3.6) * s), trim, "head", smooth=False),           # nasal ridge
        Part(deform(shape("box", h + V(0, 0, 7.2) * s, V(7.6, 0.8, 1.6) * s), lambda c: c + V(0, 0, -0.04 * (c.x - h.x) ** 2 / s)), trim, "head", smooth=False),  # crest
    ]
    for k in range(5):     # breathing holes
        out.append(Part(shape("box", h + V(3.3, 1.1 + 0.4 * k - 1.0, -0.8) * s, V(0.4, 0.18, 0.18) * s), visor_mat, "head", smooth=False))
    return out


def pauldron(J, s, side, mat, trim, size=1.0, lames=3):
    sy = 1 if side == "L" else -1
    sh = J[f"shoulder.{side}"]
    out = []
    for i in range(lames):
        k = 1.0 - i * 0.16
        c = sh + V(0.0, sy * (0.6 + i * 0.7), 1.4 - i * 1.7) * s
        out.append(Part(shape("hemi", c, V(6.4 * k, 6.0 * k, 4.6 * k) * s * size, rot=(sy * (0.55 + 0.18 * i), 0, 0), seg=14, rings=6),
                        mat if i else trim, f"upperarm.{side}", sharp=60))
    out.append(Part(shape("torus", sh + V(0, sy * 0.6, 1.6) * s, V(6.6, 6.2, 6) * s * size, rot=(sy * 0.55 + math.pi / 2 * 0, 0, 0), seg=18), trim, f"upperarm.{side}"))
    return out


def cape_part(J, s, mat, width=(11.0, 15.0), length=34.0, back=3.4, segs=8):
    c0 = J["collar"] + V(-back, 0, 0.8) * s
    pts, ws = [], []
    n = 7
    for i in range(n + 1):
        k = i / n
        pts.append(c0 + V(-1.4 * k - 0.6 * math.sin(k * math.pi), 0, -length * k) * s)
        ws.append((width[0] + (width[1] - width[0]) * k) * s)
    bm = strip(pts, ws, segs=segs, thick=0.35 * s)
    # drape: curl the edges forward around the shoulders and the body
    def curl(c):
        dy = abs(c.y) / (width[1] * 0.5 * s)
        return c + V(2.2 * s * dy * dy, 0, 0)
    deform(bm, curl)
    return Part(bm, mat, weights=cape_weights(J, s))


def skirt_part(J, s, mat, r_top, r_bot, z_top, z_bot, seg=18, back_only=False, front_open=0.0):
    bm = shape("tube", V(0, 0, (z_top + z_bot) / 2) * s, V(1, 1, 1), seg=seg)
    # rebuild as a proper frustum with rows so it bends with the thighs
    bm.free()
    bm = bmesh.new()
    rows = []
    nrow = 5
    for r in range(nrow + 1):
        k = r / nrow
        z = (z_top + (z_bot - z_top) * k) * s
        rad = (r_top + (r_bot - r_top) * k) * s
        ring = []
        for i in range(seg):
            a = 2 * math.pi * i / seg
            ring.append(bm.verts.new((math.cos(a) * rad + 0.6 * s, math.sin(a) * rad, z)))
        rows.append(ring)
    for r in range(nrow):
        for i in range(seg):
            a = 2 * math.pi * (i + 0.5) / seg
            if front_open > 0 and math.cos(a) > 1.0 - front_open: continue
            bm.faces.new((rows[r][i], rows[r][(i + 1) % seg], rows[r + 1][(i + 1) % seg], rows[r + 1][i]))
    bmesh.ops.solidify(bm, geom=bm.faces[:], thickness=0.3 * s)
    bm.normal_update()
    return Part(bm, mat, weights=skirt_weights(J, s))


def staff_part(J, s, side, mat, length=50.0, z0=2.0, x_off=0.4):
    hnd = J[f"hand.{side}"]
    base = V(hnd.x + x_off * s, hnd.y, z0 * s)
    return Part(shape("cyl", base + V(0, 0, length * s / 2), V(1.0, 1.0, length) * s, seg=8, taper=0.8), mat, f"hand.{side}"), base + V(0, 0, length * s)


def build_warden():
    reset()
    J, nodes, edges, bones, s = humanoid(50, bulk=1.12)
    rig = Rig("warden", bones)
    steel = material("steel_warden", "steel", (0.82, 0.85, 0.92), nstr=1.6)
    gold = material("gold_warden", "gold", (1.0, 0.78, 0.42))
    leather = material("leather_warden", "leather")
    chain = material("chain_warden", "chain", (0.75, 0.75, 0.8))
    tabard = material("tabard_warden", "velvet", (0.5, 0.07, 0.08))
    capem = material("cape_warden", "velvet", (0.32, 0.04, 0.05))
    visor = material("visor", color=(0.02, 0.02, 0.02), rough=0.9)
    glow = material("glow_warden", color=(1.0, 0.8, 0.45), emis=(1.0, 0.72, 0.3), estr=4.0)
    P = []
    P += helm_parts(J, s, steel, gold, visor)
    P.append(Part(shape("cyl", J["neck"] + V(0, 0, 0.2), V(5.0, 5.0, 2.6) * s, seg=14, taper=1.1), steel, "neck"))
    # cuirass: rounded breastplate with a ridge, two belly lames, back plate
    ch = J["chest"]
    P.append(Part(deform(shape("sphere", ch + V(0.9, 0, 0.6) * s, V(10.6, 12.6, 11.4) * s, seg=18, rings=10),
                         lambda c: c + V(-0.35 * max(0.0, ch.x - c.x), 0, 0)), steel, "chest"))
    P.append(Part(shape("box", ch + V(5.6, 0, 0.8) * s, V(0.7, 0.6, 9.0) * s, rot=(0, -0.1, 0)), gold, "chest", smooth=False))
    for i, z in enumerate((-4.2, -6.4)):
        P.append(Part(shape("cyl", J["spine"] + V(0.6, 0, z + 4.4) * s, V(10.2 - i * 0.4, 11.0 - i * 0.4, 2.3) * s, seg=18, taper=1.05), steel, "spine"))
    P.append(Part(shape("torus", J["pelvis"] + V(0.6, 0, 1.4) * s, V(11.6, 11.6, 12) * s, seg=20), leather, "hips"))
    P.append(Part(shape("box", J["pelvis"] + V(5.6, 0, 1.4) * s, V(0.8, 2.6, 2.0) * s), gold, "hips", smooth=False))
    for sd in ("L", "R"):
        P += pauldron(J, s, sd, steel, gold, 1.05, 3)
        P.append(limb_part("cyl", J[f"shoulder.{sd}"], J[f"elbow.{sd}"], 2.05 * s, steel, f"upperarm.{sd}", 0.35, 0.95, taper=0.9))
        P.append(limb_part("cyl", J[f"elbow.{sd}"], J[f"wrist.{sd}"], 1.75 * s, steel, f"forearm.{sd}", 0.15, 0.95, taper=1.15))
        P.append(Part(shape("sphere", J[f"elbow.{sd}"], V(3.0, 3.0, 3.0) * s, seg=10, rings=6), gold, f"upperarm.{sd}"))
        P.append(Part(shape("box", J[f"hand.{sd}"] + V(0.2, 0, 0.6) * s, V(2.8, 2.4, 3.6) * s, taper=0.8), steel, f"hand.{sd}", sharp=35))
        P.append(limb_part("cyl", J[f"hip.{sd}"], J[f"knee.{sd}"], 2.75 * s, steel, f"thigh.{sd}", 0.3, 0.92, taper=0.85))
        P.append(Part(shape("sphere", J[f"knee.{sd}"] + V(1.0, 0, 0) * s, V(3.6, 3.4, 3.4) * s, seg=10, rings=6), gold, f"shin.{sd}"))
        P.append(limb_part("cyl", J[f"knee.{sd}"], J[f"ankle.{sd}"], 2.15 * s, steel, f"shin.{sd}", 0.1, 0.9, taper=0.8))
        P.append(Part(shape("box", mid(J[f"ankle.{sd}"], J[f"toe.{sd}"]) + V(0.2, 0, 0.6) * s, V(6.4, 3.0, 2.6) * s, taper=0.7), steel, f"foot.{sd}", sharp=35))
    # mail skirt and the tabard over it
    P.append(skirt_part(J, s, chain, 5.4, 6.6, 24.0, 15.5, seg=18))
    for side_x, w in ((1, 1.0), (-1, 0.9)):
        pts = [J["pelvis"] + V(side_x * 5.0, 0, 1.0) * s + V(side_x * 0.5 * k, 0, -11.5 * k) * s for k in (0, 0.33, 0.66, 1.0)]
        P.append(Part(strip(pts, [6.0 * s * w] * 4, segs=4, thick=0.4 * s), tabard, weights=skirt_weights(J, s)))
        P.append(Part(strip([p + V(side_x * 0.25 * s, 0, -12.2 * s) for p in pts[:1]] + [pts[-1] + V(side_x * 0.25 * s, 0, -0.6 * s)], [6.4 * s * w] * 2, segs=2, thick=0.5 * s), gold, weights=skirt_weights(J, s)))
    P.append(cape_part(J, s, capem, width=(12.0, 16.5), length=33.0, back=4.6))
    # longsword in the right hand, point down and forward; a heater shield on the left forearm
    hr = J["hand.R"]
    blade_dir = V(0.35, 0, -1).normalized()
    q = Vector((0, 0, 1)).rotation_difference(-blade_dir)
    def along(bm, off):
        bm.transform(Matrix.Translation(hr + off) @ q.to_matrix().to_4x4())
        return bm
    P.append(Part(along(shape("box", (0, 0, -10.5 * s), V(0.5, 2.2, 21.0) * s, taper=0.15), V(0, 0, 0)), steel, "hand.R", sharp=20))
    P.append(Part(along(shape("box", (0, 0, -10.5 * s), V(0.62, 0.35, 19.0) * s, taper=0.2), V(0, 0, 0)), glow, "hand.R", smooth=False))
    P.append(Part(along(shape("box", (0, 0, 0.4 * s), V(1.0, 6.4, 0.9) * s), V(0, 0, 0)), gold, "hand.R", smooth=False))
    P.append(Part(along(shape("cyl", (0, 0, 2.4 * s), V(1.0, 1.0, 3.8) * s, seg=8), V(0, 0, 0)), leather, "hand.R"))
    P.append(Part(along(shape("sphere", (0, 0, 4.6 * s), V(1.6, 1.6, 1.6) * s, seg=8, rings=5), V(0, 0, 0)), gold, "hand.R"))
    fl = J["forearm.L" if False else "wrist.L"].lerp(J["elbow.L"], 0.45)
    shield = shape("box", (0, 0, 0), V(1.0, 10.0, 13.0) * s, taper=1.0)
    deform(shield, lambda c: V(c.x - 0.04 * c.y ** 2 / s, c.y * (1.0 if c.z > -2 * s else max(0.15, 1.0 - (-2 * s - c.z) / (5.5 * s))), c.z))
    shield.transform(Matrix.Translation(fl + V(0.8, 2.6, -0.5) * s) @ Euler((0, 0, math.pi / 2 - 0.25), "XYZ").to_matrix().to_4x4())
    P.append(Part(shield, steel, "forearm.L", sharp=30))
    boss = shape("hemi", (0, 0, 0), V(3.4, 3.4, 1.8) * s, rot=(-math.pi / 2, 0, 0), seg=12, rings=5)
    boss.transform(Matrix.Translation(fl + V(0.4, 3.4, 0.3) * s) @ Euler((0, 0, -0.25), "XYZ").to_matrix().to_4x4())
    P.append(Part(boss, gold, "forearm.L"))
    mesh = bind(rig, P, skin_body(nodes, edges), chain, exclude_auto=("cape1", "cape2", "cape3", "root"))
    hero_clips(rig, "R", s=s)
    export(rig, os.path.join(MODELS, "heroes", "warden.gltf"))


def shell(center, size, cut, mat, bone, seg=16, rings=10):
    """Sphere shell with the verts where cut(local) is true removed (hoods, open helms)."""
    bm = shape("sphere", (0, 0, 0), size, seg=seg, rings=rings)
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if cut(v.co)], context="VERTS")
    bmesh.ops.solidify(bm, geom=bm.faces[:], thickness=-0.35)
    bm.transform(Matrix.Translation(center))
    bm.normal_update()
    return Part(bm, mat, bone)


def boots_gloves(J, s, P, boot, glove, cuff=None, cuff_mat=None):
    for sd in ("L", "R"):
        P.append(Part(shape("box", mid(J[f"ankle.{sd}"], J[f"toe.{sd}"]) + V(0.3, 0, 0.8) * s, V(6.2, 2.8, 2.8) * s, taper=0.75), boot, f"foot.{sd}", sharp=40))
        P.append(limb_part("cyl", J[f"knee.{sd}"], J[f"ankle.{sd}"], 1.75 * s, boot, f"shin.{sd}", 0.55, 1.0, taper=0.95))
        if cuff:
            P.append(limb_part("cyl", J[f"knee.{sd}"], J[f"ankle.{sd}"], 2.3 * s, cuff_mat, f"shin.{sd}", 0.5, 0.62, taper=1.0))
        P.append(Part(shape("box", J[f"hand.{sd}"] + V(0.2, 0, 0.6) * s, V(2.4, 2.1, 3.2) * s, taper=0.8), glove, f"hand.{sd}", sharp=35))


def crystal_cluster(P, at, mat, bone, s, big=4.0, n=3, seed=0.0):
    P.append(Part(shape("oct", at, V(big * 0.75, big * 0.75, big * 1.9) * s), mat, bone, smooth=False))
    for i in range(n):
        a = seed + 2 * math.pi * i / n
        off = V(math.cos(a) * 2.6, math.sin(a) * 2.6, -1.4) * s
        P.append(Part(shape("oct", at + off, V(big * 0.3, big * 0.3, big * 0.9) * s, rot=(0.5 * math.sin(a), 0.5 * math.cos(a), 0)), mat, bone, smooth=False))


def build_spark():
    reset()
    J, nodes, edges, bones, s = humanoid(50, bulk=0.95)
    rig = Rig("spark", bones)
    coat = material("coat_spark", "velvet", (0.08, 0.22, 0.62))
    coat_d = material("hood_spark", "velvet", (0.05, 0.13, 0.4))
    inner = material("robe_spark", "cloth", (0.72, 0.78, 0.86))
    fur = material("fur_spark", "cloth", (0.86, 0.9, 0.95), nstr=2.0)
    leather = material("leather_spark", "leather", (0.75, 0.75, 0.8))
    silver = material("silver_spark", "steel", (0.85, 0.9, 1.0), nstr=1.4)
    wood = material("wood_spark", "wood", (0.7, 0.75, 0.85))
    shadow = material("shadow", color=(0.01, 0.01, 0.015), rough=1.0)
    ice = material("glow_spark", color=(0.75, 0.95, 1.0), emis=(0.35, 0.85, 1.0), estr=4.5)
    P = []
    h = J["head"]
    P.append(shell(h + V(-0.4, 0, 1.0) * s, V(7.6, 7.2, 8.4) * s, lambda c: c.x > 1.4 * s and c.z < 2.6 * s, coat_d, "head"))
    tip = shape("cone", (0, 0, 0), V(3.6, 3.0, 7.0) * s, rot=(0, -2.3, 0), seg=10)
    tip.transform(Matrix.Translation(h + V(-4.2, 0, 2.6) * s))
    P.append(Part(tip, coat_d, "head"))
    P.append(Part(shape("sphere", h + V(0.9, 0, 0.3) * s, V(5.0, 5.2, 6.2) * s, seg=12, rings=8), shadow, "head"))
    for sy in (1, -1):
        P.append(Part(shape("sphere", h + V(3.2, sy * 0.95, 0.9) * s, V(0.7, 0.7, 0.45) * s, seg=8, rings=4), ice, "head"))
    P.append(Part(shape("sphere", J["collar"] + V(-0.2, 0, 0.6) * s, V(13.0, 14.5, 4.6) * s, seg=20, rings=8), fur, "chest"))
    P.append(Part(shape("sphere", J["collar"] + V(-0.6, 0, 2.4) * s, V(10.5, 11.5, 3.6) * s, seg=18, rings=6), fur, "chest"))
    for sy in (1, -1):
        P.append(Part(shape("sphere", J["collar"] + V(3.6, sy * 3.2, 0.4) * s, V(1.4, 1.4, 1.4) * s, seg=8, rings=5), silver, "chest"))
    P.append(skirt_part(J, s, coat, 5.0, 8.6, 25.0, 2.8, seg=20, front_open=0.22))
    P.append(skirt_part(J, s, inner, 4.5, 6.6, 23.0, 3.6, seg=16))
    P.append(Part(shape("torus", J["pelvis"] + V(0.5, 0, 1.4) * s, V(10.8, 10.8, 10) * s, seg=20), leather, "hips"))
    P.append(Part(shape("box", J["pelvis"] + V(5.2, 0, 1.4) * s, V(0.7, 2.2, 1.8) * s), silver, "hips", smooth=False))
    pts = [J["pelvis"] + V(5.4, -1.6, 0.6) * s + V(0.4 * k, 0, -10 * k) * s for k in (0, 0.5, 1.0)]
    P.append(Part(strip(pts, [2.2 * s] * 3, segs=2, thick=0.3 * s), inner, weights=skirt_weights(J, s)))
    for sd in ("L", "R"):
        P.append(limb_part("cyl", J[f"elbow.{sd}"], J[f"wrist.{sd}"], 1.55 * s, silver, f"forearm.{sd}", 0.45, 0.98, taper=1.1))
        P.append(limb_part("cyl", J[f"elbow.{sd}"], J[f"wrist.{sd}"], 1.9 * s, coat, f"forearm.{sd}", 0.0, 0.45, taper=1.25))
    boots_gloves(J, s, P, leather, leather)
    stf, top = staff_part(J, s, "R", wood, 52.0)
    P.append(stf)
    P.append(Part(shape("torus", top + V(0, 0, -0.5) * s, V(6.0, 6.0, 6.0) * s, rot=(0, math.pi / 2, 0), seg=16), silver, "hand.R"))
    for i in range(3):
        a = 2 * math.pi * i / 3
        P.append(Part(shape("cone", top + V(math.cos(a) * 1.6, math.sin(a) * 1.6, 2.4) * s, V(0.8, 0.8, 5.6) * s, rot=(0.35 * math.sin(a), -0.35 * math.cos(a), 0), seg=6), silver, "hand.R"))
    crystal_cluster(P, top + V(0, 0, 4.4) * s, ice, "hand.R", s, big=3.6, n=3)
    mesh = bind(rig, P, skin_body(nodes, edges), coat, exclude_auto=("cape1", "cape2", "cape3", "root"))
    hero_clips(rig, "R", s=s)
    export(rig, os.path.join(MODELS, "heroes", "spark.gltf"))


def build_ember():
    reset()
    J, nodes, edges, bones, s = humanoid(48, bulk=0.92)
    rig = Rig("ember", bones)
    robe = material("robe_ember", "velvet", (0.42, 0.07, 0.07))
    dark = material("hat_ember", "velvet", (0.12, 0.05, 0.06))
    skin = material("skin_ember", color=(0.74, 0.52, 0.42), rough=0.55)
    hair = material("hair_ember", "cloth", (0.28, 0.08, 0.06), nstr=2.0)
    leather = material("leather_ember", "leather", (0.55, 0.42, 0.38))
    gold = material("gold_ember", "gold", (1.0, 0.72, 0.38))
    wood = material("wood_ember", "wood", (0.55, 0.42, 0.36))
    fire = material("glow_ember", color=(1.0, 0.7, 0.35), emis=(1.0, 0.45, 0.12), estr=5.0)
    P = []
    h = J["head"]
    P.append(Part(shape("sphere", h + V(0.9, 0, 0.0) * s, V(4.6, 4.8, 5.8) * s, seg=14, rings=10), skin, "head"))
    for sy in (1, -1):
        P.append(Part(shape("sphere", h + V(3.25, sy * 0.95, 0.5) * s, V(0.6, 0.7, 0.42) * s, seg=8, rings=4), fire, "head"))
    P.append(Part(shape("sphere", h + V(-0.8, 0, 0.6) * s, V(5.8, 6.2, 6.4) * s, seg=14, rings=8), hair, "head"))
    P.append(Part(shape("sphere", h + V(0.9, 0, 2.3) * s, V(5.0, 6.0, 2.6) * s, seg=12, rings=6), hair, "head"))       # fringe
    P.append(Part(shape("box", h + V(3.1, 0, -1.4) * s, V(0.3, 1.2, 0.25) * s), material("lips", color=(0.45, 0.12, 0.12), rough=0.5), "head", smooth=False))
    pts = [h + V(-2.4, 0, -0.5) * s + V(-0.8 * k, 0, -13 * k) * s for k in (0, 0.5, 1.0)]
    P.append(Part(strip(pts, [6.0 * s, 5.4 * s, 3.4 * s], segs=4, thick=0.8 * s), hair, weights=lambda c: {"head": 1.0} if c.z > J["neck"].z else {"chest": 1.0}))
    brim = shape("cyl", h + V(0, 0, 3.9) * s, V(17.5, 17.5, 0.5) * s, seg=28)
    deform(brim, lambda c: c + V(0, 0, 0.012 * ((c.x - h.x) ** 2 + (c.y - h.y) ** 2) / s - 0.6 * s))
    P.append(Part(brim, dark, "head"))
    crown = shape("cone", h + V(-0.2, 0, 10.4) * s, V(7.4, 7.4, 13.0) * s, seg=16)
    z0 = h.z + 3.9 * s
    deform(crown, lambda c: c + V(-0.07 * max(0.0, c.z - z0) ** 2 / s, 0, 0))
    P.append(Part(crown, dark, "head"))
    P.append(Part(shape("cyl", h + V(-0.2, 0, 5.0) * s, V(7.0, 7.0, 1.4) * s, seg=16), leather, "head"))
    P.append(Part(shape("box", h + V(3.3, 0, 5.0) * s, V(0.5, 1.6, 1.4) * s), gold, "head", smooth=False))
    P.append(Part(shape("cyl", mid(J["spine"], J["chest"]) + V(0.4, 0, 0) * s, V(9.4, 10.4, 9.0) * s, seg=16, taper=1.15), leather, "spine"))
    for k in range(4):
        P.append(Part(shape("box", mid(J["spine"], J["chest"]) + V(4.9, 0, -3.0 + 2.0 * k) * s, V(0.4, 2.4, 0.35) * s), gold, "spine", smooth=False))
    P.append(skirt_part(J, s, robe, 5.0, 10.5, 25.0, 1.4, seg=22))
    hem = shape("tube", V(0.6, 0, 2.0) * s, V(21.4, 21.4, 1.2) * s, seg=22)
    P.append(Part(hem, gold, weights=skirt_weights(J, s)))
    for sd in ("L", "R"):
        P.append(limb_part("cyl", J[f"elbow.{sd}"], J[f"wrist.{sd}"], 1.7 * s, robe, f"forearm.{sd}", 0.05, 1.0, taper=1.8))
        P.append(Part(shape("sphere", J[f"shoulder.{sd}"] + V(0, 0, 0.6) * s, V(4.6, 4.6, 4.0) * s, seg=12, rings=6), robe, f"upperarm.{sd}"))
    boots_gloves(J, s, P, leather, skin)
    P.append(cape_part(J, s, dark, width=(10.0, 13.0), length=22.0, back=3.8))
    stf, top = staff_part(J, s, "R", wood, 50.0)
    P.append(stf)
    P.append(Part(shape("tube", top + V(0, 0, 3.0) * s, V(5.0, 5.0, 6.0) * s, seg=8, taper=0.7), gold, "hand.R"))
    for i in range(4):
        a = math.pi / 4 + math.pi / 2 * i
        P.append(Part(shape("box", top + V(math.cos(a) * 2.3, math.sin(a) * 2.3, 3.0) * s, V(0.5, 0.5, 6.4) * s), gold, "hand.R", smooth=False))
    P.append(Part(shape("cone", top + V(0, 0, 7.0) * s, V(4.0, 4.0, 2.6) * s, seg=8), gold, "hand.R"))
    P.append(Part(shape("sphere", top + V(0, 0, 3.0) * s, V(3.4, 3.4, 3.8) * s, seg=10, rings=6), fire, "hand.R"))
    mesh = bind(rig, P, skin_body(nodes, edges), robe, exclude_auto=("cape1", "cape2", "cape3", "root"))
    hero_clips(rig, "R", s=s)
    export(rig, os.path.join(MODELS, "heroes", "ember.gltf"))


def horn(base, s, side, length=11.0, r=1.5, curl=0.9):
    """A ridged horn sweeping out, up and back from base."""
    bm = shape("cone", (0, 0, length / 2 * s), V(r * 2, r * 2, length) * s, seg=10)
    def bend(c):
        k = c.z / (length * s)
        return V(-curl * 6.0 * k * k * s, side * (c.y * 0 + 0) + c.y, c.z)
    deform(bm, bend)
    bm.transform(Matrix.Translation(base) @ Euler((side * -0.75, -0.5, 0), "XYZ").to_matrix().to_4x4())
    return bm


def build_storm():
    reset()
    J, nodes, edges, bones, s = humanoid(52, bulk=1.12)
    rig = Rig("storm", bones)
    skin = material("skin_storm", color=(0.58, 0.4, 0.32), rough=0.5)
    brass = material("brass_storm", "gold", (0.78, 0.56, 0.32), nstr=1.4)
    hornm = material("horn_storm", "stone", (0.9, 0.85, 0.74))
    fur = material("fur_storm", "cloth", (0.36, 0.31, 0.29), nstr=2.2)
    leather = material("leather_storm", "leather", (0.6, 0.5, 0.45))
    chain = material("chain_storm", "chain", (0.62, 0.62, 0.7))
    pants = material("wraps_storm", "cloth", (0.2, 0.17, 0.24))
    capem = material("cape_storm", "velvet", (0.2, 0.09, 0.3))
    shaft = material("shaft_storm", "steel", (0.34, 0.33, 0.4))
    spark = material("glow_storm", color=(0.85, 0.75, 1.0), emis=(0.62, 0.42, 1.0), estr=5.0)
    P = []
    h = J["head"]
    P.append(shell(h + V(0.0, 0, 1.6) * s, V(7.2, 7.0, 7.2) * s, lambda c: c.z < -0.4 * s or (c.x > 2.2 * s and c.z < 1.4 * s), brass, "head"))
    for sy in (1, -1):
        P.append(Part(shape("box", h + V(1.6, sy * 3.0, -0.6) * s, V(3.6, 0.8, 4.2) * s, rot=(sy * 0.15, 0, 0)), brass, "head", sharp=30))
        P.append(Part(horn(h + V(-0.4, sy * 3.0, 3.6) * s, s, sy, 8.5, 1.25, 1.1), hornm, "head"))
        P.append(Part(shape("sphere", h + V(2.9, sy * 1.0, 0.7) * s, V(0.55, 0.6, 0.35) * s, seg=8, rings=4), spark, "head"))
    P.append(Part(shape("box", h + V(3.4, 0, 2.2) * s, V(0.5, 1.0, 3.6) * s), brass, "head", smooth=False))
    P.append(Part(shape("sphere", J["collar"] + V(-0.6, 0, 0.8) * s, V(15.5, 17.0, 6.6) * s, seg=20, rings=8), fur, "chest"))
    for sy in (1, -1):
        st = shape("box", J["chest"] + V(4.2, 0, 0) * s, V(0.6, 1.6, 15.0) * s, rot=(sy * 0.75, 0, 0))
        P.append(Part(st, leather, "chest", smooth=False))
    P.append(Part(shape("cyl", J["chest"] + V(4.7, 0, 0) * s, V(3.4, 3.4, 0.8) * s, rot=(0, math.pi / 2, 0), seg=12), brass, "chest"))
    P.append(Part(shape("cyl", J["chest"] + V(5.0, 0, 0) * s, V(1.8, 1.8, 0.6) * s, rot=(0, math.pi / 2, 0), seg=8), spark, "chest"))
    P += pauldron(J, s, "L", brass, brass, 1.2, 2)
    P.append(Part(shape("cyl", J["spine"] + V(0.5, 0, 0.6) * s, V(9.4, 10.2, 5.4) * s, seg=16, taper=1.05), pants, "spine"))      # belly wraps
    P.append(Part(shape("torus", J["pelvis"] + V(0.6, 0, 1.4) * s, V(11.8, 11.8, 12) * s, seg=20), leather, "hips"))
    P.append(skirt_part(J, s, chain, 5.2, 6.4, 24.0, 16.0, seg=18))
    for i in range(7):
        a = -math.pi * 0.8 + i * math.pi * 1.6 / 6
        c = J["pelvis"] + V(0.6 + math.cos(a) * 5.6, math.sin(a) * 5.6, -4.0) * s
        bmk = shape("box", c, V(0.4, 2.6, 10.0) * s, rot=(0, 0, a))
        P.append(Part(bmk, leather, weights=skirt_weights(J, s), smooth=False))
    for sd in ("L", "R"):
        P.append(limb_part("cyl", J[f"elbow.{sd}"], J[f"wrist.{sd}"], 1.9 * s, brass, f"forearm.{sd}", 0.35, 0.98, taper=1.12))
        P.append(limb_part("cyl", J[f"elbow.{sd}"], J[f"wrist.{sd}"], 1.95 * s, spark, f"forearm.{sd}", 0.62, 0.68))
        P.append(limb_part("cyl", J[f"hip.{sd}"], J[f"knee.{sd}"], 2.7 * s, pants, f"thigh.{sd}", 0.2, 1.0, taper=0.85))
        P.append(limb_part("cyl", J[f"knee.{sd}"], J[f"ankle.{sd}"], 2.0 * s, pants, f"shin.{sd}", 0.0, 0.6, taper=0.9))
    boots_gloves(J, s, P, leather, leather, cuff=True, cuff_mat=fur)
    P.append(cape_part(J, s, capem, width=(13.0, 17.0), length=32.0, back=5.0))
    stf, top = staff_part(J, s, "R", shaft, 56.0)
    P.append(stf)
    for sy in (1, -1):
        pr = shape("cone", (0, 0, 3.5 * s), V(1.4, 1.4, 7.0) * s, seg=6)
        deform(pr, lambda c, sy=sy: c + V(0, sy * 0.09 * c.z ** 2 / s, 0))
        pr.transform(Matrix.Translation(top + V(0, sy * 1.0, -1.0) * s))
        P.append(Part(pr, brass, "hand.R"))
    P.append(Part(shape("torus", top + V(0, 0, -1.4) * s, V(4.0, 4.0, 4.0) * s, seg=12), brass, "hand.R"))
    crystal_cluster(P, top + V(0, 0, 3.0) * s, spark, "hand.R", s, big=3.0, n=0)
    mesh = bind(rig, P, skin_body(nodes, edges), skin, exclude_auto=("cape1", "cape2", "cape3", "root"))
    hero_clips(rig, "R", s=s)
    export(rig, os.path.join(MODELS, "heroes", "storm.gltf"))


# ================================================================== bosses
def boss_clips(rig, s, wings=True, heavy=1.0):
    def add(*rs): return tuple(sum(r[i] for r in rs) for i in range(3))
    def arm_out(side, a): return ((1.0 if side == "L" else -1.0) * a, 0.0, 0.0)

    def idle(t):
        ph = 2 * math.pi * t
        br = S(ph)
        return {
            "spine": lean(0.12 + 0.04 * br), "chest": lean(0.05 - 0.04 * br), "neck": lean(-0.1), "head": add(lean(-0.08 * br), (0, 0, 0.2 * S(ph * 0.5))),
            "upperarm.L": add(arm_out("L", 0.3 + 0.04 * br), fwd(0.15)), "upperarm.R": add(arm_out("R", 0.3 + 0.04 * br), fwd(0.25)),
            "forearm.L": fwd(0.4), "forearm.R": fwd(0.55),
            "thigh.L": fwd(0.15), "thigh.R": fwd(-0.1), "shin.L": fwd(-0.25), "shin.R": fwd(-0.12),
            "wing.L": (0.15 + 0.12 * br, 0, 0.1 * br), "wing.R": (-0.15 - 0.12 * br, 0, -0.1 * br),
            "root": ((0, 0, 0), (0, 0, -0.5 * s * (0.5 + 0.5 * br))),
        }

    def walk(t):
        ph = 2 * math.pi * t
        sw = S(ph)
        return {
            "hips": (0.06 * sw, 0, -0.15 * sw), "spine": add(lean(0.2), (0, 0, 0.12 * sw)), "chest": add((0, 0, 0.1 * sw), lean(0.05)),
            "head": lean(-0.15),
            "thigh.L": fwd(0.55 * sw + 0.1), "thigh.R": fwd(-0.55 * sw + 0.1),
            "shin.L": fwd(-(0.25 + 0.8 * max(0.0, -S(ph + 0.5)))), "shin.R": fwd(-(0.25 + 0.8 * max(0.0, S(ph + 0.5)))),
            "upperarm.L": add(arm_out("L", 0.35), fwd(-0.4 * sw)), "upperarm.R": add(arm_out("R", 0.35), fwd(0.4 * sw + 0.2)),
            "forearm.L": fwd(0.5), "forearm.R": fwd(0.6),
            "wing.L": (0.2 + 0.25 * S(ph * 2), 0, 0.15), "wing.R": (-0.2 - 0.25 * S(ph * 2), 0, -0.15),
            "root": ((0, 0, 0), (0, 0, s * heavy * (1.3 * abs(sw) - 1.6))),
        }

    def attack(t):
        # wind-up (0..0.45), slam (0.45..0.6), recover
        up = ease(min(1.0, t / 0.45))
        down = ease(min(1.0, max(0.0, (t - 0.45) / 0.15)))
        rec = ease(min(1.0, max(0.0, (t - 0.7) / 0.3)))
        raise_ = up * (1.0 - down)
        slam = down * (1.0 - rec)
        return {
            "spine": lean(-0.35 * raise_ + 0.55 * slam), "chest": lean(-0.2 * raise_ + 0.25 * slam), "head": lean(0.2 * raise_ - 0.2 * slam),
            "upperarm.L": add(arm_out("L", 0.3), fwd(2.7 * raise_ + 0.9 * slam)), "upperarm.R": add(arm_out("R", 0.3), fwd(2.8 * raise_ + 1.0 * slam)),
            "forearm.L": fwd(0.9 * raise_ + 0.1), "forearm.R": fwd(0.9 * raise_ + 0.1),
            "thigh.L": fwd(0.35 * slam), "thigh.R": fwd(-0.25 * slam), "shin.L": fwd(-0.6 * slam), "shin.R": fwd(-0.3 * slam),
            "wing.L": (0.6 * raise_, 0, 0.3 * raise_), "wing.R": (-0.6 * raise_, 0, -0.3 * raise_),
            "root": ((0, 0, 0), (0, 0, s * (1.2 * raise_ - 3.0 * slam))),
        }

    def hit(t):
        k = S(math.pi * t)
        return {"spine": lean(-0.25 * k), "head": lean(-0.35 * k), "upperarm.L": arm_out("L", 0.3 + 0.4 * k), "upperarm.R": arm_out("R", 0.3 + 0.4 * k),
                "wing.L": (0.5 * k, 0, 0), "wing.R": (-0.5 * k, 0, 0), "root": ((0, 0, 0), (-2.0 * s * k, 0, 0))}

    def die(t):
        a = ease(min(1.0, t / 0.4))
        b = ease(min(1.0, max(0.0, (t - 0.35) / 0.55)))
        return {
            "thigh.L": fwd(1.4 * a), "thigh.R": fwd(1.3 * a), "shin.L": fwd(-2.0 * a), "shin.R": fwd(-1.9 * a),
            "spine": lean(0.3 * a + 0.5 * b), "head": lean(0.3 * b),
            "upperarm.L": add(arm_out("L", 0.4 + 0.6 * b), fwd(0.5 * b)), "upperarm.R": add(arm_out("R", 0.4 + 0.6 * b), fwd(0.6 * b)),
            "wing.L": (0.9 * b, 0, -0.4 * b), "wing.R": (-0.9 * b, 0, 0.4 * b),
            "root": ((0, math.pi / 2 * 0.9 * b, 0), (2.0 * s * b, 0, -11.0 * s * a)),
        }

    rig.clip("idle", 48, idle, loop=True)
    rig.clip("walk", 32, walk, loop=True)
    rig.clip("attack", 34, attack)
    rig.clip("hit", 8, hit)
    rig.clip("die", 44, die)


def shape_between(kind, a, b, radius, seg=8):
    d = b - a
    bm = shape(kind, (0, 0, 0), (radius * 2, radius * 2, d.length), seg=seg)
    bm.transform(Matrix.Translation((a + b) / 2) @ Vector((0, 0, 1)).rotation_difference(d.normalized()).to_matrix().to_4x4())
    return bm


def wing_part(root, side, s, mat, bone_mat, span=34.0):
    """Bat wing: three finger bones fanning out from the wrist, membrane between them."""
    sy = 1 if side == "L" else -1
    wrist = root + V(-4.0, sy * span * 0.42, 9.0) * s
    tips = [root + V(-6.0 - 4 * i, sy * span * (0.95 - 0.13 * i), 13.0 - 9.0 * i) * s for i in range(4)]
    parts = [Part(shape_between("cyl", root, wrist, 1.1 * s), bone_mat, f"wing.{side}")]
    for tp in tips:
        parts.append(Part(shape_between("cone", wrist, tp, 0.7 * s), bone_mat, f"wing.{side}"))
    bm = bmesh.new()
    vr, vw = bm.verts.new(root), bm.verts.new(wrist)
    vt = [bm.verts.new(p) for p in tips]
    vb = bm.verts.new(root + V(-2.0, sy * 3.0, -10.0) * s)
    for i in range(len(vt) - 1):
        bm.faces.new((vw, vt[i], vt[i + 1]))
    bm.faces.new((vr, vw, vt[-1], vb))
    bmesh.ops.solidify(bm, geom=bm.faces[:], thickness=0.4 * s)
    bm.normal_update()
    parts.append(Part(bm, mat, f"wing.{side}", smooth=False))
    return parts


def boss_skeleton(H, bulk, hunch):
    J, nodes, edges, bones, s = humanoid(H, bulk=bulk, hunch=hunch, legs=1.05, arms=1.15)
    bones = [b for b in bones if not b[0].startswith("cape")]
    back = J["collar"] + V(-4.0 * bulk, 0, 0.5) * s
    for side, sy in (("L", 1), ("R", -1)):
        root = back + V(0, sy * 2.6, 0) * s
        bones.append((f"wing.{side}", root, root + V(-3.0, sy * 12.0, 6.0) * s, "chest"))
    return J, nodes, edges, bones, s, back


def build_tyrant():
    reset()
    J, nodes, edges, bones, s, back = boss_skeleton(125, 1.45, 0.7)
    rig = Rig("tyrant", bones)
    hide = material("hide_tyrant", "leather", (0.46, 0.17, 0.13), nstr=1.8)
    membrane = material("wing_tyrant", "leather", (0.22, 0.07, 0.07), nstr=1.2)
    iron = material("iron_tyrant", "steel", (0.34, 0.31, 0.34), nstr=1.6)
    bone = material("bone_tyrant", "stone", (0.86, 0.8, 0.68))
    cloth = material("loin_tyrant", "cloth", (0.22, 0.13, 0.11), nstr=2.0)
    glow = material("glow_tyrant", color=(1.0, 0.62, 0.3), emis=(1.0, 0.45, 0.15), estr=5.0)
    P = []
    h = J["head"]
    P.append(Part(shape("sphere", h + V(0.6, 0, 0.6) * s, V(6.4, 6.0, 6.6) * s, seg=16, rings=10), bone, "head"))
    P.append(Part(shape("box", h + V(2.2, 0, -2.6) * s, V(3.8, 4.4, 2.0) * s, taper=1.2), bone, "head", sharp=35))
    for t in range(5):
        P.append(Part(shape("cone", h + V(3.9, -1.6 + t * 0.8, -1.8) * s, V(0.5, 0.5, 1.4) * s, rot=(math.pi, 0, 0), seg=5), bone, "head"))
    for sy in (1, -1):
        P.append(Part(shape("sphere", h + V(3.3, sy * 1.3, 1.0) * s, V(1.2, 1.3, 0.8) * s, seg=8, rings=4), glow, "head"))
        P.append(Part(horn(h + V(-0.6, sy * 2.4, 2.6) * s, s, sy, 13.0, 1.9, 1.6), bone, "head"))
    # furnace ribcage: horizontal rib arcs around the chest with a glowing core showing between them
    ch = J["chest"]
    P.append(Part(shape("sphere", ch + V(3.6, 0, 0.4) * s, V(5.4, 7.0, 7.6) * s, seg=12, rings=8), glow, "chest"))
    for r in range(4):
        rib = shape("torus", ch + V(1.4, 0, -2.6 + r * 1.9) * s, V(12.8 - abs(r - 1.5) * 0.9, 13.6 - abs(r - 1.5) * 0.9, 14) * s, seg=20)
        bmesh.ops.delete(rib, geom=[v for v in rib.verts if v.co.x > (ch.x + 6.0 * s) and abs(v.co.y) < 1.6 * s], context="VERTS")
        P.append(Part(rib, bone, "chest"))
    for k in range(6):
        P.append(Part(shape("cone", J["spine"].lerp(J["neck"], k / 5) + V(-4.6 - 0.4 * k, 0, 0) * s, V(1.4, 1.0, 4.2) * s, rot=(0, -1.9, 0), seg=6), bone, "chest" if k > 2 else "spine"))
    for sd, sy in (("L", 1), ("R", -1)):
        sh = J[f"shoulder.{sd}"]
        P.append(Part(shape("hemi", sh + V(0, sy * 0.8, 1.6) * s, V(8.0, 7.6, 5.6) * s, rot=(sy * 0.5, 0, 0), seg=14, rings=6), iron, f"upperarm.{sd}"))
        for k in range(3):
            P.append(Part(shape("cone", sh + V(-1.5 + k * 1.6, sy * (1.8 + 0.4 * k), 4.6 - 0.3 * k) * s, V(1.4, 1.4, 5.0 - k) * s, rot=(sy * -0.45, -0.3, 0), seg=6), bone, f"upperarm.{sd}"))
        P.append(limb_part("cyl", J[f"elbow.{sd}"], J[f"wrist.{sd}"], 2.0 * s, iron, f"forearm.{sd}", 0.25, 0.95, taper=1.2))
        P.append(limb_part("cyl", J[f"knee.{sd}"], J[f"ankle.{sd}"], 2.3 * s, iron, f"shin.{sd}", 0.05, 0.85, taper=0.85))
        P.append(Part(shape("sphere", J[f"knee.{sd}"] + V(1.2, 0, 0) * s, V(3.6, 3.4, 3.4) * s, seg=10, rings=6), iron, f"shin.{sd}"))
        P.append(Part(shape("cone", J[f"knee.{sd}"] + V(2.6, 0, 0.6) * s, V(1.2, 1.2, 3.4) * s, rot=(0, 1.3, 0), seg=6), bone, f"shin.{sd}"))
        for c in range(3):
            P.append(Part(shape("cone", J[f"toe.{sd}"] + V(0.8, (c - 1) * 1.0, -0.2) * s, V(0.9, 0.9, 2.6) * s, rot=(0, 1.6, 0), seg=5), bone, f"foot.{sd}"))
    for c in range(4):
        P.append(Part(shape("cone", J["hand.L"] + V(1.0, 0.5 + (c - 1.5) * 0.7, -1.4) * s, V(0.7, 0.7, 3.6) * s, rot=(0, 2.6, 0), seg=5), bone, "hand.L"))
    # cleaver in the right hand
    hr = J["hand.R"]
    q = Vector((0, 0, 1)).rotation_difference(-V(0.4, 0, -1).normalized()).to_matrix().to_4x4()
    blade = shape("box", (0, 0, -13.0 * s), V(1.1, 9.0, 26.0) * s)
    deform(blade, lambda c: V(c.x, c.y + (2.5 * s if c.y > 0 and c.z < -20 * s else 0), c.z))
    blade.transform(Matrix.Translation(hr) @ q)
    P.append(Part(blade, iron, "hand.R", smooth=False))
    edge = shape("box", (0, 4.6 * s, -14.0 * s), V(1.3, 0.6, 24.0) * s)
    edge.transform(Matrix.Translation(hr) @ q)
    P.append(Part(edge, glow, "hand.R", smooth=False))
    grip = shape("cyl", (0, 0, 3.0 * s), V(1.4, 1.4, 7.0) * s, seg=8)
    grip.transform(Matrix.Translation(hr) @ q)
    P.append(Part(grip, cloth, "hand.R"))
    # belt, loincloth, wings
    P.append(Part(shape("torus", J["pelvis"] + V(0.8, 0, 1.2) * s, V(15.6, 15.6, 16) * s, seg=22), iron, "hips"))
    P.append(Part(shape("sphere", J["pelvis"] + V(7.4, 0, 1.2) * s, V(3.2, 3.0, 3.4) * s, seg=10, rings=6), bone, "hips"))
    for sx in (1, -1):
        pts = [J["pelvis"] + V(sx * 6.2, 0, -0.4) * s + V(sx * 0.6 * k, 0, -13.0 * k) * s for k in (0, 0.5, 1.0)]
        P.append(Part(strip(pts, [8.0 * s, 7.6 * s, 6.2 * s], segs=4, thick=0.5 * s), cloth, weights=skirt_weights(J, s)))
    for sd, sy in (("L", 1), ("R", -1)):
        P += wing_part(back + V(0, sy * 2.6, 0) * s, sd, s, membrane, bone)
    bind(rig, P, skin_body(nodes, edges), hide, exclude_auto=("wing.L", "wing.R", "root"))
    boss_clips(rig, s)
    export(rig, os.path.join(MODELS, "bosses", "tyrant.gltf"))


def build_guardian():
    reset()
    J, nodes, edges, bones, s, back = boss_skeleton(115, 1.6, 0.35)
    rig = Rig("guardian", bones)
    stone = material("stone_guardian", "stone", (0.5, 0.5, 0.58), nstr=2.0)
    dark = material("stone_dark_guardian", "stone", (0.28, 0.27, 0.33), nstr=2.0)
    iron = material("iron_guardian", "steel", (0.4, 0.38, 0.45), nstr=1.4)
    glow = material("glow_guardian", color=(0.75, 0.9, 1.0), emis=(0.5, 0.8, 1.0), estr=5.0)
    P = []
    h = J["head"]
    P.append(Part(shape("box", h + V(0.4, 0, 0.8) * s, V(6.2, 6.6, 6.0) * s, taper=0.8), dark, "head", sharp=30))
    P.append(Part(shape("sphere", h + V(3.4, 0, 1.0) * s, V(1.4, 2.6, 1.0) * s, seg=10, rings=4), glow, "head"))
    P.append(Part(shape("box", J["chest"] + V(0.6, 0, 0.4) * s, V(11.5, 14.5, 11.0) * s, taper=1.15), stone, "chest", sharp=30))
    P.append(Part(shape("oct", J["chest"] + V(6.4, 0, 0.6) * s, V(6.4, 6.4, 9.0) * s), glow, "chest", smooth=False))
    P.append(Part(shape("box", J["spine"] + V(0.4, 0, 0) * s, V(9.0, 11.0, 6.0) * s, taper=1.1), dark, "spine", sharp=30))
    for sd, sy in (("L", 1), ("R", -1)):
        sh = J[f"shoulder.{sd}"]
        P.append(Part(shape("box", sh + V(0, sy * 1.2, 1.4) * s, V(8.0, 7.0, 7.0) * s, rot=(sy * 0.3, 0, 0.2)), stone, f"upperarm.{sd}", sharp=30))
        for k in range(4):
            P.append(Part(shape("prism", sh + V(-2.4 + 1.4 * k, sy * (1.0 + 0.8 * k), 5.5 + 1.0 * (k % 2)) * s, V(3.4, 3.4, 11.0 - 1.5 * k) * s, rot=(sy * -0.45, -0.3 + 0.2 * k, k * 1.3)), glow, f"upperarm.{sd}", smooth=False))
        for k in range(3):
            P.append(Part(shape("prism", mid(J[f"elbow.{sd}"], J[f"wrist.{sd}"]) + V(-2.4, sy * (1.6 + 0.4 * k), -2.0 + 2.4 * k) * s, V(2.2, 2.2, 6.0) * s, rot=(sy * -1.1, -0.8, k)), glow, f"forearm.{sd}", smooth=False))
        P.append(limb_part("box", J[f"elbow.{sd}"], J[f"wrist.{sd}"], 2.6 * s, stone, f"forearm.{sd}", 0.0, 1.0, taper=1.3))
        P.append(Part(shape("box", J[f"hand.{sd}"] + V(0.4, 0, -0.6) * s, V(6.4, 6.0, 6.4) * s), dark, f"hand.{sd}", sharp=30))
        P.append(limb_part("box", J[f"hip.{sd}"], J[f"knee.{sd}"], 3.2 * s, stone, f"thigh.{sd}", 0.15, 0.95, taper=0.85))
        P.append(limb_part("box", J[f"knee.{sd}"], J[f"ankle.{sd}"], 2.8 * s, dark, f"shin.{sd}", 0.05, 1.0, taper=1.15))
        P.append(Part(shape("box", mid(J[f"ankle.{sd}"], J[f"toe.{sd}"]) + V(0.5, 0, 0.8) * s, V(7.4, 4.4, 3.2) * s), stone, f"foot.{sd}", sharp=30))
        P.append(limb_part("cyl", J[f"elbow.{sd}"], J[f"wrist.{sd}"], 2.9 * s, iron, f"forearm.{sd}", 0.4, 0.55))
    for k in range(5):
        P.append(Part(shape("prism", J["chest"] + V(-6.0, (k - 2) * 2.8, 3.0 + 1.4 * (k % 2)) * s, V(3.6, 3.6, 13.0 - abs(k - 2) * 2.0) * s, rot=(0.3 * (k - 2), -0.6, k * 1.1)), glow, "chest", smooth=False))
    P.append(Part(shape("torus", J["pelvis"] + V(0.6, 0, 1.0) * s, V(15.0, 15.0, 14) * s, seg=20), iron, "hips"))
    bind(rig, P, skin_body(nodes, edges), dark, exclude_auto=("wing.L", "wing.R", "root"))
    boss_clips(rig, s, heavy=1.4)
    export(rig, os.path.join(MODELS, "bosses", "guardian.gltf"))


def build_herald():
    """The pinnacle: a floating crystal star. Three counter-rotating rings each carry four shards on
    their own bones, so attacks can fling them outward and the death can scatter them."""
    reset()
    Z = 70.0
    core = V(0, 0, Z)
    bones = [("root", V(0, 0, 0), V(0, 0, 10), None), ("core", core, core + V(0, 0, 30), "root")]
    radii = (44.0, 54.0, 64.0)
    tilts = ((0.25, 0.0), (-0.35, 0.6), (0.15, -0.9))
    shard_pos = {}
    for r in range(3):
        bones.append((f"ring{r}", core, core + V(0, 0, 20), "core"))
        for k in range(4):
            a = 2 * math.pi * (k + r * 0.33) / 4
            tx, ty = tilts[r]
            p = core + (Euler((tx, ty, 0), "XYZ").to_matrix() @ V(math.cos(a) * radii[r], math.sin(a) * radii[r], 0))
            shard_pos[(r, k)] = p
            bones.append((f"shard{r}_{k}", p, p + V(0, 0, 12), f"ring{r}"))
    rig = Rig("herald", bones)
    crys = material("crystal_herald", color=(0.3, 0.16, 0.68), rough=0.1, metal=0.2, emis=(0.4, 0.16, 0.9), estr=0.35)     # faint inner light: the arena is dark
    glow = material("glow_herald", color=(0.95, 0.85, 1.0), emis=(0.72, 0.45, 1.0), estr=5.0)
    gold = material("gold_herald", "gold", (0.9, 0.75, 0.55), nstr=1.2)
    P = []
    # a cage of five tall crystal blades around a glowing heart, so the core reads from any angle
    P.append(Part(shape("oct", core, V(24, 24, 46)), glow, "core", smooth=False))
    for k in range(5):
        a = 2 * math.pi * k / 5
        P.append(Part(shape("oct", core + V(math.cos(a) * 17, math.sin(a) * 17, 0), V(11, 11, 88), rot=(-0.18 * math.sin(a), 0.18 * math.cos(a), a)), crys, "core", smooth=False))
    for k in range(8):
        a = 2 * math.pi * k / 8
        P.append(Part(shape("prism", core + V(math.cos(a) * 16, math.sin(a) * 16, 30), V(6, 6, 26), rot=(-0.5 * math.sin(a), 0.5 * math.cos(a), a)), crys, "core", smooth=False))
        P.append(Part(shape("prism", core + V(math.cos(a) * 16, math.sin(a) * 16, -30), V(5, 5, 18), rot=(math.pi + 0.5 * math.sin(a), -0.5 * math.cos(a), a)), crys, "core", smooth=False))
    P.append(Part(ring(core + V(0, 0, 44), 20, 1.4), glow, "core"))
    for r in range(3):
        tx, ty = tilts[r]
        P.append(Part(ring(core, radii[r], 1.6, rot=(tx, ty, 0), seg=56), gold, f"ring{r}"))
        for k in range(4):
            p = shard_pos[(r, k)]
            P.append(Part(shape("oct", p, V(10, 10, 26), rot=(0.4, 0.3 * k, 0)), crys, f"shard{r}_{k}", smooth=False))
            P.append(Part(shape("oct", p, V(4, 4, 11), rot=(0.4, 0.3 * k, 0)), glow, f"shard{r}_{k}", smooth=False))
    bind(rig, P)

    def ringrot(r, ang):
        tx, ty = tilts[r]
        ax = Euler((tx, ty, 0), "XYZ").to_matrix() @ V(0, 0, 1)     # spin about the ring's own tilted axis
        return tuple(Quaternion(ax, ang).to_euler("XYZ"))

    def base(t, spin=1.0):
        d = {"core": ((0, 0, 0.6 * math.sin(2 * math.pi * t)), (0, 0, 6.0 * math.sin(2 * math.pi * t)))}
        for r in range(3):
            d[f"ring{r}"] = ringrot(r, (1 if r % 2 == 0 else -1) * 2 * math.pi * t * spin)
        return d

    def attack(t):
        d = base(t, 1.5)
        k = math.sin(math.pi * min(1.0, t * 1.4))
        for r in range(3):
            for kk in range(4):
                p = shard_pos[(r, kk)] - core
                d[f"shard{r}_{kk}"] = ((0, 0, 3.0 * k), tuple(p.normalized() * 26.0 * k))
        d["core"] = ((0, 0, 0), (0, 0, -8.0 * k))
        return d

    def hit(t):
        d = base(t * 0.1)
        k = math.sin(math.pi * t)
        d["core"] = ((0.2 * k, 0, 0), (-4.0 * k, 0, 0))
        return d

    def die(t):
        d = base(t * 0.5)
        e = ease(t)
        for r in range(3):
            for kk in range(4):
                p = shard_pos[(r, kk)] - core
                d[f"shard{r}_{kk}"] = ((2.0 * e, 1.5 * e, 0), tuple(p.normalized() * 60.0 * e + V(0, 0, -Z * e * e)))
        d["core"] = ((0.8 * e, 0, 0), (0, 0, -Z * 0.75 * e * e))
        return d

    rig.clip("idle", 96, base, loop=True)
    rig.clip("walk", 96, base, loop=True)
    rig.clip("attack", 30, attack)
    rig.clip("hit", 8, hit)
    rig.clip("die", 48, die)
    export(rig, os.path.join(MODELS, "bosses", "herald.gltf"))



BUILDERS = {"warden": build_warden, "spark": build_spark, "ember": build_ember, "storm": build_storm,
            "tyrant": build_tyrant, "guardian": build_guardian, "herald": build_herald}


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    # The shipped heroes are the realistic ones from tools/blender/realistic_heroes.py; the procedural
    # heroes here are built only when named, so a default run never overwrites them.
    for k in (argv or ["tyrant", "guardian", "herald"]):
        BUILDERS[k]()
