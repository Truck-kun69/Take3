"""The texel budget for generated models: which imported maps stay 2048 px and which import at 1024.

    python3 tools/texture_budget.py           # write process/size_limit into the .import files (then re-import)
    python3 tools/texture_budget.py --check   # verify the imported .ctex sizes against it (exit 1 on a miss)

Every one is VRAM-compressed (compress/mode=2: ETC2/ASTC on phones, S3TC on desktop).
Kept at 2048 px: every map of the heroes and bosses, and the albedo of the large landmarks (tree,
tree_dead, arch) and of the foes. Imported at 1024 px: the normal and ORM maps of every prop and foe, and
the albedo of small ground clutter (rock, wall, pillar, bones, bush). The source files keep their full size;
only the imported (VRAM-compressed) copy is limited. Nothing goes under 1024.
"""
import glob
import os
import re
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GD = os.path.join(ROOT, "godot")
LANDMARKS = ("tree_dead", "tree", "arch")              # longest first: "tree_dead" before "tree"
CLUTTER = ("rock", "wall", "pillar", "bones", "bush")


def rule(rel):
    """models/<dir>/<file> -> (size limit, why) or None for a texture outside the generated set."""
    d, f = rel.split("/")[1], os.path.basename(rel)
    base = f.lower()
    is_normal = "normal" in base
    is_orm = "roughness" in base or "metallic" in base or "orm" in base
    if d in ("heroes", "bosses"):
        return (0, "hero/boss: full size")
    if d == "foes":
        if not any(base.startswith(k + "_") for k in ("grunt", "runner", "brute", "spitter", "charger")): return None
        return (1024, "foe normal/ORM") if (is_normal or is_orm) else (0, "foe albedo: full size")
    if d == "props":
        kind = next((k for k in LANDMARKS + CLUTTER if base.startswith(k + "_")), None)
        if kind is None: return None
        if is_normal or is_orm: return (1024, "prop normal/ORM")
        return (0, "landmark albedo: full size") if kind in LANDMARKS else (1024, "clutter albedo")
    return None


def imports():
    for imp in sorted(glob.glob(os.path.join(GD, "models", "*", "*.import"))):
        txt = open(imp).read()
        if 'importer="texture"' not in txt: continue
        rel = os.path.relpath(imp, GD)[:-len(".import")]
        r = rule(rel)
        if r is not None: yield imp, rel, txt, r


def ctex_sizes(txt):
    out = []
    for dest in sorted(set(re.findall(r'"res://(\.godot/imported/[^"]+\.ctex)"', txt))):
        f = os.path.join(GD, dest)
        if os.path.exists(f):
            w, h = struct.unpack_from("<II", open(f, "rb").read(16), 8)
            out.append((dest.split(".")[-2], w, h))
    return out


def apply():
    n = 0
    for imp, rel, txt, (limit, why) in imports():
        t2 = re.sub(r"process/size_limit=\d+", f"process/size_limit={limit}", txt)
        if t2 != txt:
            open(imp, "w").write(t2)
            n += 1
    print(f"texture_budget: {n} import files changed (re-import to apply)")


def check():
    """Every imported copy at its budget: a 1024-limited map at exactly 1024 px, a full-size one at 2048."""
    bad = 0
    rows = 0
    for imp, rel, txt, (limit, why) in imports():
        want = limit if limit else 2048
        if "compress/mode=2" not in txt:                              # phones need block-compressed maps
            bad += 1
            print(f"BUDGET FAIL {rel}: not VRAM-compressed (compress/mode=2)")
        for fmt, w, h in ctex_sizes(txt):
            rows += 1
            if max(w, h) != want:
                bad += 1
                print(f"BUDGET FAIL {rel} ({fmt}) {w}x{h}: {why}, wanted {want}")
    print(f"texture_budget: {rows} imported files checked, {bad} off budget")
    return bad


if __name__ == "__main__":
    if "--check" in sys.argv:
        sys.exit(1 if check() else 0)
    apply()
