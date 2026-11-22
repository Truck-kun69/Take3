"""Check generated models against what the game needs: PBR textures, a skeleton, the clips, the world scale.

    python3 tools/verify_assets.py <id> [<id> ...]        # e.g. warden tree
    python3 tools/verify_assets.py --all

For each asset, the processed file in godot/models (tools/blender/process_fal_assets.py output):
  - exists and is over 100 KB
  - every material has a baseColor texture; heroes, bosses and props also a normal map; each texture's
    image is 1024-2048 px
  - heroes and bosses: a skin with joints; every clip present, longer than 0.2 s
    (heroes idle, walk, run, cast or attack, roll or dodge, jump, die or death; bosses idle, walk, attack,
    slam, die or death)
  - height (bind-pose bounding box) in the asset's range and feet at y = 0 (|min_y| <= 0.5 units)
  - foes: the .vat beside it is SVA3, its vertex count matches the mesh's VAT column count, the walk clip is there
  - props and foes: every mesh node at the identity transform (the game's MultiMesh draws the bare mesh)
Prints one line per check and exits 1 if any fails.
"""
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import gltf_info  # noqa: E402

KIND = {"warden": "hero", "spark": "hero", "ember": "hero", "storm": "hero", "tyrant": "boss", "herald": "boss",
        "grunt": "foe", "runner": "foe", "brute": "foe", "spitter": "foe", "charger": "foe",
        "tree": "prop", "tree_dead": "prop", "rock": "prop", "arch": "prop", "wall": "prop", "pillar": "prop",
        "bones": "prop", "bush": "prop"}
DIRS = {"hero": "heroes", "boss": "bosses", "foe": "foes", "prop": "props"}
RANGE = {"hero": (34.0, 44.0), "boss": (83.0, 93.0), "foe": (24.0, 42.0),
         "tree": (115.0, 145.0), "tree_dead": (115.0, 145.0), "arch": (114.0, 126.0), "wall": (61.0, 69.0),
         "pillar": (90.0, 100.0), "rock": (36.0, 40.0), "bones": (20.5, 23.5), "bush": (24.5, 27.5)}
CLIPS = {"hero": [("idle",), ("walk",), ("run",), ("cast", "attack"), ("roll", "dodge"), ("jump",), ("die", "death")],
         "boss": [("idle",), ("walk",), ("attack",), ("slam",), ("die", "death")]}


def path_of(aid):
    return os.path.join(ROOT, "godot", "models", DIRS[KIND[aid]], aid + ".glb")


def range_of(aid):
    k = KIND[aid]
    return RANGE.get(aid, RANGE.get(k))


def check(aid):
    """-> list of (ok, message)."""
    k = KIND[aid]
    p = path_of(aid)
    res = []
    if not os.path.exists(p):
        return [(False, f"{aid}: {os.path.relpath(p, ROOT)} missing")]
    size = os.path.getsize(p)
    res.append((size > 100_000, f"{aid}: {os.path.relpath(p, ROOT)} {size / 1e6:.2f} MB (> 0.10 MB)"))
    s = gltf_info.summary(p)
    # textures
    mats = s["materials"]
    res.append((len(mats) > 0, f"{aid}: {len(mats)} material(s)"))
    for name, sizes in mats:
        need = ["baseColor"] + (["normal"] if k != "foe" else [])
        missing = [n for n in need if n not in sizes]
        res.append((not missing, f"{aid}: material {name!r} has {sorted(sizes)}" + (f", missing {missing}" if missing else "")))
        for slot, wh in sizes.items():
            ok = wh is not None and 1024 <= max(wh) <= 2048
            res.append((ok, f"{aid}: {name!r} {slot} texture {wh}"))
    # skeleton and clips
    if k in ("hero", "boss"):
        res.append((s["skins"] > 0 and s["joints"] > 0, f"{aid}: {s['skins']} skin(s), {s['joints']} joints"))
        names = {n.lower(): d for n, d in s["animations"]}
        for alts in CLIPS[k]:
            hit = next((a for a in alts if a in names), None)
            d = names.get(hit, 0.0) if hit else 0.0
            res.append((hit is not None and d > 0.2, f"{aid}: clip {'/'.join(alts)}: " + (f"{hit} {d:.2f} s" if hit else "missing")))
    # scale
    lo, hi = range_of(aid)
    h, my = s["height"], s["min_y"]
    res.append((h is not None and lo <= h <= hi, f"{aid}: height {h:.2f} units (wanted {lo:g}-{hi:g})"))
    res.append((my is not None and abs(my) <= 0.5, f"{aid}: min_y {my:.3f} (feet at 0)"))
    if k == "foe":
        vp = p[:-4] + ".vat"
        if not os.path.exists(vp):
            res.append((False, f"{aid}: {os.path.relpath(vp, ROOT)} missing"))
        else:
            b = open(vp, "rb").read()
            nv, rows, nc = struct.unpack_from("<HHH", b, 4)
            names = [b[40 + 20 * i: 48 + 20 * i].split(b"\0")[0].decode() for i in range(nc)]
            res.append((b[:4] == b"SVA3" and "walk" in names, f"{aid}: {os.path.basename(vp)} {b[:4].decode()} {nv} verts {rows} rows clips {names}"))
            js, binchunk = gltf_info.load(p)
            cols = set()
            for m in js["meshes"]:
                for pr in m["primitives"]:
                    if "TEXCOORD_1" in pr["attributes"]:
                        for uv in gltf_info.read_accessor(js, binchunk, pr["attributes"]["TEXCOORD_1"]):
                            cols.add(int(uv[0] * nv))
            res.append((len(cols) == nv and max(cols) == nv - 1, f"{aid}: UV2 indexes {len(cols)} VAT columns of {nv}"))
    if k in ("prop", "foe"):
        # the game draws these through a MultiMesh of the first mesh, without node transforms: every mesh
        # node must sit at the identity, or the drawn size is not the size measured here
        js, _ = gltf_info.load(p)
        ident = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        wm = gltf_info.world_matrices(js)
        off = [js["nodes"][i].get("name", str(i)) for i, m in wm.items() if "mesh" in js["nodes"][i]
               and max(abs(a - b) for a, b in zip(m, ident)) > 1e-5]
        res.append((not off, f"{aid}: mesh nodes at the identity transform" + (f" (not: {off})" if off else "")))
    res.append((True, f"{aid}: {s['triangles']} triangles"))
    return res


def main(ids):
    bad = 0
    for aid in ids:
        for ok, msg in check(aid):
            print(("PASS " if ok else "FAIL ") + msg)
            bad += 0 if ok else 1
    print(f"verify_assets: {len(ids)} asset(s), {bad} failed check(s)")
    return 1 if bad else 0


if __name__ == "__main__":
    a = sys.argv[1:]
    ids = list(KIND) if a == ["--all"] else a
    unknown = [i for i in ids if i not in KIND]
    if unknown: raise SystemExit(f"unknown: {unknown}")
    sys.exit(main(ids))
