"""Pure helpers for process_fal_assets.py: no bpy, so the gate and plain python3 can test them.

snap_window   the hero trim window on whole frames, its length inside TRIM's range, clamped inward
srgb_to_linear, lightness   colour math for the foe ORM bake (luminance from linear light, not sRGB codes)
pick_object_slot            the action slot a clip must play through on an armature object (Blender 4.4+)
lifted_name                 one file per lifted albedo, so two lifted maps never overwrite each other
"""
import math

import numpy as np


def snap_window(mid, half, lo, hi, fps, first, last):
    """(f0, f1), whole frames, for a window centred near `mid` with half-length `half` (frames).

    Its span is whole frames and inside [lo, hi] seconds: int(clip(round(2 half), ceil(lo fps), floor(hi fps))),
    so a cast trimmed to 0.65 s at 24 fps keeps 16 frames (0.667 s) and never 15 (0.625 s, which a float
    window rounded on export). Inward clamping: a window that sticks out of the clip [first, last] slides
    back inside at the same length; it shortens only when the clip itself is shorter than the span."""
    first_i, last_i = int(math.ceil(first - 1e-6)), int(math.floor(last + 1e-6))
    span = int(np.clip(round(2 * half), math.ceil(lo * fps - 1e-9), math.floor(hi * fps + 1e-9)))
    span = max(1, min(span, last_i - first_i))
    f0 = int(round(mid - span / 2.0))
    f0 = max(first_i, min(f0, last_i - span))
    return f0, f0 + span


def srgb_to_linear(c):
    """IEC 61966-2-1 decode: sRGB-encoded values in 0..1 -> linear light."""
    c = np.asarray(c, np.float32)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4).astype(np.float32)


def lightness(rgb_srgb):
    """Perceptual lightness 0..1 (CIE L*/100) of sRGB-encoded rows [..., 3]: linearised first, then the
    Rec.709 luminance Y, then L*. A mid-grey albedo (sRGB 0.466, Y 0.184) sits at 0.5, black at 0, white at 1."""
    lin = srgb_to_linear(np.asarray(rgb_srgb, np.float32)[..., :3])
    y = lin @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    lstar = np.where(y > (6.0 / 29.0) ** 3, 116.0 * np.cbrt(y) - 16.0, y * (29.0 / 3.0) ** 3)
    return np.clip(lstar / 100.0, 0.0, 1.0).astype(np.float32)


def pick_object_slot(slots):
    """The slot an armature object plays an action through: target_id_type OBJECT (a clip imported on another
    armature brings that armature's OBJECT slot; any other slot type would leave the rig frozen). An
    unassigned slot (UNSPECIFIED) is taken only when the action has no OBJECT slot. None when neither exists."""
    slots = list(slots)
    for want in ("OBJECT", "UNSPECIFIED"):
        for s in slots:
            if getattr(s, "target_id_type", "") == want: return s
    return None


def lifted_name(done):
    """The file a lifted albedo is saved as: numbered by how many maps this prop has lifted before it."""
    return f"albedo_lifted_{len(done)}.png"
