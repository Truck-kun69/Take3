import os, sys, glob
from PIL import Image, ImageOps
import numpy as np
src, out = sys.argv[1], sys.argv[2]
S = 512
def find(d, *keys):
    for k in keys:
        g = [f for f in glob.glob(os.path.join(src, d, "*")) if k in os.path.basename(f)]
        if g: return g[0]
    return None
def L(p): return Image.open(p).convert("L").resize((S, S), Image.LANCZOS) if p else None
# name: (dir, desaturate?, metal default). Metals are lifted and capped at 0.6 metalness: the game's
# scenes are dark, and a fully metallic surface with nothing bright to reflect renders black.
LIFT = {"steel": (0.44, 2.2), "chain": (0.5, 1.3)}
MCAP = {"steel": 0.6, "gold": 0.65, "chain": 0.55}
SETS = {
    "steel":   ("acg_Metal027", False, 1.0),
    "gold":    ("acg_Metal048A", False, 1.0),
    "leather": ("ph_brown_leather", False, 0.0),
    "cloth":   ("ph_hessian_230", True, 0.0),
    "velvet":  ("ph_velour_velvet", True, 0.0),
    "chain":   ("acg_Chainmail004", False, 1.0),
    "stone":   ("ph_rock_face_03", True, 0.0),
    "wood":    ("acg_Wood066", False, 0.0),
}
for name, (d, desat, metal) in SETS.items():
    col = Image.open(find(d, "_Color", "_diff_", "_albedo_")).convert("RGB").resize((S, S), Image.LANCZOS)
    if desat:   # neutral grey with the original value structure, mean ~0.62, so a glTF base colour factor tints it
        g = np.asarray(ImageOps.grayscale(col), dtype=np.float32) / 255.0
        g = 0.62 + (g - g.mean()) * 1.4
        col = Image.fromarray((np.clip(g, 0, 1) * 255).astype(np.uint8)).convert("RGB")
    if name in LIFT:
        a = np.asarray(col, dtype=np.float32) / 255.0
        g = a.mean(axis=2, keepdims=True)
        tgt, con = LIFT[name]
        a = tgt + (g - g.mean()) * con + (a - g) * 0.3
        col = Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8))
    col.save(os.path.join(out, f"{name}_col.jpg"), quality=86)
    nrm = Image.open(find(d, "_NormalGL", "_nor_gl_")).convert("RGB").resize((S, S), Image.LANCZOS)
    nrm.save(os.path.join(out, f"{name}_nrm.jpg"), quality=90)
    arm = find(d, "_arm_")
    if arm:
        orm = Image.open(arm).convert("RGB").resize((S, S), Image.LANCZOS)
    else:
        r = L(find(d, "_Roughness", "_rough_"))
        m = L(find(d, "_Metalness"))
        if m is None: m = Image.new("L", (S, S), int(metal * 255))
        ao = L(find(d, "_AmbientOcclusion")) or Image.new("L", (S, S), 255)
        orm = Image.merge("RGB", (ao, r, m))
    if name in MCAP:
        o = np.asarray(orm, dtype=np.float32)
        o[..., 2] = np.minimum(o[..., 2], MCAP[name] * 255)
        orm = Image.fromarray(o.astype(np.uint8))
    orm.save(os.path.join(out, f"{name}_orm.jpg"), quality=88)
    print(name, "ok")
