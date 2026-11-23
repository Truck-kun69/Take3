"""Rebake the green (roughness) channel of the five generated foes' ORM maps from linear light, in place.

    python3 tools/rebake_foe_orm.py           # rewrite the maps that differ (then re-import)
    python3 tools/rebake_foe_orm.py --check   # exit 1 if any map is not the linear-light bake

process_fal_assets.bake_foe_maps packs ORM as R ambient occlusion, G roughness = 0.45 + 0.45 x (1 - AO) plus
(0.5 - lightness(albedo)) x 0.2 clamped to 0.40-0.92, B no metal. Before 0.10.0 the lightness was the sRGB
codes weighted 0.3/0.59/0.11 (no linearisation). The fixed bake needs tools/.fal_raw/ and Blender; but every
input of the green channel ships with the model: R is the baked occlusion and the albedo sits in the same .glb
on the same UVs. Recomputing the old formula from them reproduces the shipped green channel within 1/255 (8-bit
rounding), so this recomputes it with the fixed one (pipeline_math.lightness) and writes the result
everywhere the map lives:
  - the image embedded in models/foes/<kind>.glb (the binary chunk is rebuilt around the new bytes);
  - models/foes/<kind>_baked_orm.png, the copy the importer extracted (byte-identical to the embedded one);
  - the md5 in that copy's .import (generator_parameters: the importer's hash of the decoded pixels), so the
    importer keeps the copy and its texel budget instead of extracting it again.
R and B are untouched.
"""
import hashlib
import io
import os
import re
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "blender"))
from glb_io import load, replace_view, save, view_bytes  # noqa: E402
from pipeline_math import lightness  # noqa: E402

FOES = ("grunt", "runner", "brute", "spitter", "charger")
DIR = os.path.join(os.path.dirname(HERE), "godot", "models", "foes")


def _images(js):
    return {im.get("name"): im for im in js.get("images", [])}


def rebaked(orm_png, albedo_png):
    """(new PNG bytes, max change of G in 1/255) for one ORM map."""
    orm = Image.open(io.BytesIO(orm_png)).convert("RGB")
    a = np.asarray(orm).copy()
    alb = np.asarray(Image.open(io.BytesIO(albedo_png)).convert("RGB").resize(orm.size, Image.BOX)).astype(np.float32) / 255.0
    ao = a[..., 0].astype(np.float32) / 255.0
    g = np.clip(0.45 + 0.45 * (1.0 - ao) + (0.5 - lightness(alb)) * 0.2, 0.40, 0.92)
    g8 = np.round(g * 255.0).astype(np.uint8)
    delta = int(np.abs(g8.astype(int) - a[..., 1].astype(int)).max())
    a[..., 1] = g8
    buf = io.BytesIO()
    Image.fromarray(a, "RGB").save(buf, "PNG", optimize=True)
    return buf.getvalue(), delta, a


def run(check):
    bad = 0
    for k in FOES:
        glb = os.path.join(DIR, k + ".glb")
        js, binchunk = load(glb)
        ims = _images(js)
        orm_bv, alb_bv = ims["baked_orm"]["bufferView"], ims["albedo_2048"]["bufferView"]
        old = view_bytes(js, binchunk, orm_bv)
        new, delta, pix = rebaked(old, view_bytes(js, binchunk, alb_bv))
        if delta == 0:
            print(f"{k}: ORM green channel already the linear-light bake")
            continue
        if check:
            bad += 1
            print(f"{k}: ORM green channel off the linear-light bake by up to {delta}/255")
            continue
        save(glb, js, replace_view(js, binchunk, orm_bv, new))
        png = os.path.join(DIR, f"{k}_baked_orm.png")
        open(png, "wb").write(new)
        imp = png + ".import"
        txt = open(imp).read()
        md5 = hashlib.md5(pix.tobytes()).hexdigest()
        txt2 = re.sub(r'("md5": ")[0-9a-f]+(")', lambda m: m.group(1) + md5 + m.group(2), txt)
        if txt2 == txt and md5 not in txt: raise SystemExit(f"{imp}: no generator md5 to update")
        open(imp, "w").write(txt2)
        js2, bin2 = load(glb)
        assert view_bytes(js2, bin2, _images(js2)["baked_orm"]["bufferView"]) == new
        print(f"{k}: ORM green channel rebaked from linear light (changed by up to {delta}/255); .glb, extracted copy and import md5 updated")
    return bad


if __name__ == "__main__":
    sys.exit(1 if run("--check" in sys.argv) else 0)
