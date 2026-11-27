"""Retarget authored humanoid clips (KayKit's CC0 Rig_Medium library) onto a build_models.Rig.

Both skeletons stand upright facing the same way once the source is turned by A (found from the feet).
For each mapped bone, per frame:
    D  = A * Rs(t) * Rs(rest)^-1 * A^-1        the source bone's world rotation since its rest pose
    W  = D * Q^-1 * Rt(rest)                     the target bone's armature-space rotation
where Q is the shortest arc from the source's rest direction to the target's. A limb therefore points
where the source limb points whatever the two rest poses were (T-pose arms on one, A-pose on the
other). The torso uses Q = identity: both rests are upright, and a shortest arc between near-parallel
spines would add twist. Unmapped bones (neck) hold their rest relative to the parent; cape bones take
a small procedural pose per clip. The hips' height follows the source, scaled by leg length; sideways
and forward drift is removed so every clip plays in place.
"""
import math

import bpy
from mathutils import Matrix, Vector

MAP = {"hips": "hips", "spine": "spine", "chest": "chest", "head": "head",
       "upperarm.L": "upperarm.l", "forearm.L": "lowerarm.l", "hand.L": "wrist.l",
       "upperarm.R": "upperarm.r", "forearm.R": "lowerarm.r", "hand.R": "wrist.r",
       "thigh.L": "upperleg.l", "shin.L": "lowerleg.l", "foot.L": "foot.l",
       "thigh.R": "upperleg.r", "shin.R": "lowerleg.r", "foot.R": "foot.r"}
TORSO = {"hips", "spine", "chest", "head"}


def _rot(m):
    return m.to_3x3().normalized()


def _arc(a, b):
    """Shortest rotation taking direction a to direction b."""
    return a.normalized().rotation_difference(b.normalized()).to_matrix()


def _forward(arm_ob, foot, toe_or_tail):
    """Horizontal facing of a skeleton from its feet (armature space)."""
    f = Vector((0.0, 0.0, 0.0))
    for a, b in ((foot[0], toe_or_tail[0]), (foot[1], toe_or_tail[1])):
        d = b - a
        f += Vector((d.x, d.y, 0.0))
    return f.normalized()


def load_source(path):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    new = [o for o in bpy.data.objects if o not in before]
    arm = next(o for o in new if o.type == "ARMATURE")
    return arm, new


def _set_action(arm, name, frame):
    act = bpy.data.actions.get(name)
    arm.animation_data_create()
    arm.animation_data.action = act
    if hasattr(arm.animation_data, "action_slot") and arm.animation_data.action_slot is None and len(getattr(act, "slots", [])):
        arm.animation_data.action_slot = act.slots[0]
    bpy.context.scene.frame_set(frame)
    bpy.context.view_layer.update()
    return act


def retarget(rig, src, clips, cape=None, mirror=False):
    """clips: {name: (source action, loop, first frame or None, last frame or None)}.
    cape: {name: fn(t) -> {cape bone: (rx, ry, rz)}} in build_models' armature-axis convention.
    Returns {name: stride} = forward distance one foot travels on the ground per cycle (model units),
    for matching playback speed to ground speed."""
    tgt = rig.ob
    tb = tgt.data.bones
    sb = src.data.bones
    sw = src.matrix_world
    # facing: target feet point along foot bones; the source has toe bones
    t_fwd = _forward(tgt, (tb["foot.L"].head_local, tb["foot.R"].head_local), (tb["foot.L"].tail_local, tb["foot.R"].tail_local))
    s_fwd = _forward(src, (sw @ sb["foot.l"].head_local, sw @ sb["foot.r"].head_local), (sw @ sb["toes.l"].head_local, sw @ sb["toes.r"].head_local))
    ang = math.atan2(t_fwd.y, t_fwd.x) - math.atan2(s_fwd.y, s_fwd.x)
    A = Matrix.Rotation(ang, 3, "Z")
    # same handedness? the source's left shoulder must land on the target's left side
    s_left = A @ ((sw @ sb["upperarm.l"].head_local) - (sw @ sb["upperarm.r"].head_local))
    t_left = tb["upperarm.L"].head_local - tb["upperarm.R"].head_local
    swap = s_left.dot(t_left) < 0.0
    def sname(tn):
        n = MAP[tn]
        if swap != mirror and n[-2:] in (".l", ".r"):
            n = n[:-1] + ("r" if n[-1] == "l" else "l")
        return n
    swr = _rot(sw)
    Rs0 = {tn: A @ swr @ _rot(sb[sname(tn)].matrix_local) for tn in MAP}
    Rt0 = {b.name: _rot(b.matrix_local) for b in tb}
    Q = {}
    for tn in MAP:
        if tn in TORSO:
            Q[tn] = Matrix.Identity(3)
        else:
            Q[tn] = _arc(Rs0[tn].col[1], Rt0[tn].col[1])
    s_leg = (sw @ sb["upperleg.l"].head_local).z - (sw @ sb["foot.l"].head_local).z
    t_leg = tb["thigh.L"].head_local.z - tb["foot.L"].head_local.z
    k = t_leg / max(1e-6, s_leg)
    s_hips0 = sw @ sb["hips"].head_local
    order = [b.name for b in tb]                       # parents come first in a Rig
    strides = {}
    tgt.animation_data_create()
    for name, (action, loop, f_first, f_last) in clips.items():
        sact = bpy.data.actions.get(action)
        if sact is None:
            print(f"  retarget: no source clip {action}"); continue
        f0 = int(sact.frame_range[0]) if f_first is None else f_first
        f1 = int(sact.frame_range[1]) if f_last is None else f_last
        frames = list(range(f0, f1 + 1))
        samples = []
        for fr in frames:
            _set_action(src, action, fr)
            W = {}
            for tn in MAP:
                Rs = A @ swr @ _rot(src.pose.bones[sname(tn)].matrix)
                W[tn] = Rs @ Rs0[tn].inverted() @ Q[tn].inverted() @ Rt0[tn]
            hp = A @ ((sw @ src.pose.bones["hips"].head) - s_hips0) * k
            foot = A @ ((sw @ src.pose.bones[sname("foot.L")].head) - (sw @ src.pose.bones["hips"].head))
            samples.append((W, hp, foot))
        # in place: remove the linear drift of the hips over the clip, keep the bob
        d0, d1 = samples[0][1].copy(), samples[-1][1].copy()
        n = max(1, len(samples) - 1)
        # stride: how far a foot travels fore-aft relative to the hips (twice that per full cycle)
        xs = [s[2].dot(Vector((t_fwd.x, t_fwd.y, 0.0))) for s in samples]
        strides[name] = (max(xs) - min(xs)) * 2.0 * k
        act = bpy.data.actions.new(name)
        tgt.animation_data.action = act
        if hasattr(tgt.animation_data, "action_slot") and tgt.animation_data.action_slot is None and len(getattr(act, "slots", [])):
            tgt.animation_data.action_slot = act.slots[0]
        prevq = {}
        for i, (W, hp, _foot) in enumerate(samples):
            t = i / n
            drift = d0.lerp(d1, t)
            hp = Vector((hp.x - drift.x, hp.y - drift.y, hp.z))
            cp = cape[name](t) if cape and name in cape else {}
            world = {}
            for bn in order:
                b = tb[bn]
                pb = tgt.pose.bones[bn]
                Pw = world[b.parent.name] if b.parent else Matrix.Identity(3)
                rel = (Rt0[b.parent.name].inverted() @ Rt0[bn]) if b.parent else Rt0[bn]
                if bn in W:
                    Wb = W[bn]
                    q = (rel.inverted() @ Pw.inverted() @ Wb).to_quaternion()
                else:
                    e = cp.get(bn)
                    if e is not None:
                        from mathutils import Euler
                        R = Rt0[bn]
                        q = (R.inverted() @ Euler(e, "XYZ").to_matrix() @ R).to_quaternion()
                    else:
                        q = Matrix.Identity(3).to_quaternion()
                    Wb = Pw @ rel @ q.to_matrix()
                world[bn] = Wb
                if bn in prevq and prevq[bn].dot(q) < 0.0: q.negate()       # keep quaternions on one hemisphere: no flips between keys
                prevq[bn] = q.copy()
                pb.rotation_quaternion = q
                pb.location = (Rt0[bn].inverted() @ hp) if bn == "hips" else Vector((0.0, 0.0, 0.0))
                pb.keyframe_insert("rotation_quaternion", frame=i + 1)
                pb.keyframe_insert("location", frame=i + 1)
        tr = tgt.animation_data.nla_tracks.new()
        tr.name = name
        tr.strips.new(name, 1, act)
        act.use_fake_user = True
        tgt.animation_data.action = None
    for pb in tgt.pose.bones:
        pb.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
        pb.location = (0.0, 0.0, 0.0)
    return strides
