"""The texel budget for every model texture: which imported maps stay 2048 px and which import at 1024.

    python3 tools/texture_budget.py           # write process/size_limit into the .import files (then re-import)
    python3 tools/texture_budget.py --check   # verify the imported .ctex sizes against it (exit 1 on a miss)

Every one is VRAM-compressed (compress/mode=2: ETC2/ASTC on phones, S3TC on desktop).
Kept at 2048 px: every map of the heroes and bosses (sub-folders included: Act V's Tide Bishop keeps its maps
in bosses/tyrant_4_tex/), and the albedo of the large landmarks (tree, tree_dead, arch).
Imported at 1024 px: every foe map (albedo, normal, ORM: a swarm foe is a few dozen pixels tall on a phone),
the normal and ORM maps of every prop, the albedo of small ground clutter (rock, wall, pillar, bones, bush),
and the shared tiling sets in models/textures/. The source files keep their full size; only the imported
(VRAM-compressed) copy is limited. Nothing goes under 1024.

The scan is recursive (models/**). A texture under models/{heroes,bosses,foes,props} that no rule covers is
a failure in both modes, never a silent skip: a new asset gets a budget before it ships.
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
FOES = ("grunt", "runner", "brute", "spitter", "charger")
SCOPE = ("heroes", "bosses", "foes", "props")          # the generated sets: no rule here is a failure


def rule(rel):
    """models/<dir>/[sub/]<file> -> (size limit, why), or None when no rule covers it."""
    d, f = rel.split("/")[1], os.path.basename(rel)
    base = f.lower()
    is_normal = "normal" in base or "nrm" in base
    is_orm = "roughness" in base or "metallic" in base or "orm" in base
    if d in ("heroes", "bosses"):
        return (0, "hero/boss: full size")
    if d == "foes":
        if not any(base.startswith(k + "_") for k in FOES): return None
        return (1024, "foe normal/ORM") if (is_normal or is_orm) else (1024, "foe albedo")
    if d in ("props", "props_hi"):
        kind = next((k for k in LANDMARKS + CLUTTER if base.startswith(k + "_")), None)
        if kind is None: return None
        if is_normal or is_orm: return (1024, "prop normal/ORM")
        return (0, "landmark albedo: full size") if kind in LANDMARKS else (1024, "clutter albedo")
    if d == "textures":
        return (1024, "shared tiling set")
    return None


def scan():
    """Every texture import under models/** (recursive): (import file, res-relative path, text, rule or None)."""
    for imp in sorted(glob.glob(os.path.join(GD, "models", "**", "*.import"), recursive=True)):
        txt = open(imp).read()
        if 'importer="texture"' not in txt: continue
        rel = os.path.relpath(imp, GD)[:-len(".import")]
        yield imp, rel, txt, rule(rel)


def imports():
    """The budgeted textures: every model texture a rule covers."""
    for imp, rel, txt, r in scan():
        if r is not None: yield imp, rel, txt, r


def unmatched():
    """Model textures no rule covers ([(rel, in SCOPE)]). In SCOPE that is a failure; outside it a skip."""
    return [(rel, rel.split("/")[1] in SCOPE) for _, rel, _, r in scan() if r is None]


def model_ctex():
    """Every imported .ctex of every texture under models/** (the count the budget rows must reach)."""
    n = 0
    for _, _, txt, _ in scan():
        n += len(set(re.findall(r'"res://(\.godot/imported/[^"]+\.ctex)"', txt)))
    return n


def ctex_sizes(txt):
    out = []
    for dest in sorted(set(re.findall(r'"res://(\.godot/imported/[^"]+\.ctex)"', txt))):
        f = os.path.join(GD, dest)
        if os.path.exists(f):
            w, h = struct.unpack_from("<II", open(f, "rb").read(16), 8)
            out.append((dest.split(".")[-2], w, h))
    return out


def apply():
    miss = [rel for rel, scoped in unmatched() if scoped]
    for rel in miss: print(f"BUDGET FAIL {rel}: no budget rule covers it (add one to texture_budget.rule)")
    if miss: sys.exit(1)
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
    skipped = 0
    for rel, scoped in unmatched():
        if scoped:
            bad += 1
            print(f"BUDGET FAIL {rel}: no budget rule covers it")
        else:
            skipped += 1
            print(f"BUDGET SKIP {rel}: outside models/{{{','.join(SCOPE)}}}, no rule")
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
    total = model_ctex()
    if rows != total:
        bad += 1
        print(f"BUDGET FAIL {rows} rows checked but models/** holds {total} imported .ctex files")
    print(f"texture_budget: {rows} imported files checked of {total}, {skipped} skipped, {bad} off budget")
    return bad


if __name__ == "__main__":
    if "--check" in sys.argv:
        sys.exit(1 if check() else 0)
    apply()
