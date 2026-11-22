"""The asset overhaul's gate: every check must pass for exit code 0.

    python3 tools/gate_check.py              # all checks, then the release APK build
    python3 tools/gate_check.py --no-apk     # all checks without the build

1. tools/fal_cache.json exists, total spend <= $20.00; every hero, boss, foe and prop .glb exists, > 100 KB
2. every .glb parsed (struct + json): heroes have a skin and the 7 clips (idle, walk, run, cast/attack,
   roll/dodge, jump, die/death) longer than 0.2 s; every material of a prop, foe or boss has a
   baseColorTexture; bounding-box height and min_y printed for each, inside its range, feet at 0
3. code: no JumpTuck in scripts/; no "pal * 4.0" in the terrain shader; prop_mat never on a PBR prop
   (every "material_override = prop_mat" guarded by Models.has_pbr); High-tier phones at 3D scale 1.0
4. textures: the imported .ctex headers of every terrain and hero texture: none 256 px or smaller
5. godot --headless --quit: no ERROR / SCRIPT ERROR / WARNING line; tests/gate_chunk.tscn: every dressed
   640 x 640 chunk (5 acts x 3 chunks) holds >= 150 prop instances, PBR props unshaded by prop_mat
6. the release APK: built by tools/build_android.sh, path and size printed
"""
import glob
import json
import os
import re
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GD = os.path.join(ROOT, "godot")
GODOT = os.path.expanduser(os.environ.get("GODOT", "/root/toolchains/godot/godot"))
if not os.path.exists(GODOT): GODOT = os.path.expanduser("~/toolchains/godot/godot")
sys.path.insert(0, HERE)
import gltf_info  # noqa: E402
import verify_assets  # noqa: E402

FAILS = []


def check(ok, msg):
    print(("PASS  " if ok else "FAIL  ") + msg, flush=True)
    if not ok: FAILS.append(msg)


def section(t):
    print(f"\n== {t}", flush=True)


def main(build_apk=True):
    # 1 ----------------------------------------------------------------
    section("1. fal cache and asset files")
    cpath = os.path.join(HERE, "fal_cache.json")
    check(os.path.exists(cpath), "tools/fal_cache.json exists")
    if os.path.exists(cpath):
        c = json.load(open(cpath))
        total = sum(x["cost_usd"] for x in c["calls"])
        calls = len([x for x in c["calls"] if x["status"] == "done"])
        check(total <= 20.00, f"total fal spend ${total:.3f} (<= $20.00) over {calls} completed calls")
    for aid, kind in verify_assets.KIND.items():
        p = verify_assets.path_of(aid)
        ok = os.path.exists(p) and os.path.getsize(p) > 100_000
        check(ok, f"{os.path.relpath(p, ROOT)} " + (f"{os.path.getsize(p) / 1e6:.2f} MB" if os.path.exists(p) else "missing"))
    # 2 ----------------------------------------------------------------
    section("2. GLB contents (struct + json)")
    for aid, kind in verify_assets.KIND.items():
        p = verify_assets.path_of(aid)
        if not os.path.exists(p): continue
        s = gltf_info.summary(p)
        lo, hi = verify_assets.range_of(aid)
        print(f"      {aid:10s} {kind:5s} height {s['height']:7.2f}  min_y {s['min_y']:7.3f}  tris {s['triangles']:6d}  "
              f"skins {s['skins']} joints {s['joints']}  clips {[n for n, d in s['animations']]}")
        check(lo <= s["height"] <= hi and abs(s["min_y"]) <= 0.5, f"{aid}: height {s['height']:.2f} in {lo:g}-{hi:g}, min_y {s['min_y']:.3f}")
        if kind == "hero":
            names = {n.lower(): d for n, d in s["animations"]}
            check(s["skins"] > 0 and s["joints"] > 0, f"{aid}: skin with {s['joints']} joints")
            for alts in verify_assets.CLIPS["hero"]:
                hit = next((a for a in alts if a in names), None)
                check(hit is not None and names[hit] > 0.2, f"{aid}: clip {'/'.join(alts)} " + (f"{names[hit]:.2f} s" if hit else "missing"))
        else:
            mats = s["materials"]
            ok = len(mats) > 0 and all("baseColor" in sl for _, sl in mats)
            check(ok, f"{aid}: baseColorTexture on every material ({[sorted(sl) for _, sl in mats]})")
    # 3 ----------------------------------------------------------------
    section("3. code")
    tuck = subprocess.run(["grep", "-rn", "JumpTuck", os.path.join(GD, "scripts")], capture_output=True, text=True).stdout.strip()
    check(tuck == "", "JumpTuck: 0 matches in scripts/" + ("" if not tuck else f" ({len(tuck.splitlines())} found)"))
    terr = open(os.path.join(GD, "shaders", "3d", "terrain.gdshader")).read()
    check("pal * 4.0" not in terr, "'pal * 4.0': 0 matches in shaders/3d/terrain.gdshader")
    wv = open(os.path.join(GD, "scripts", "render3d", "world_view_3d.gd")).read().splitlines()
    uses = [(i + 1, l.strip()) for i, l in enumerate(wv) if "material_override = prop_mat" in l]
    guarded = all("not Models.has_pbr(" in l for _, l in uses)
    check(len(uses) > 0 and guarded, f"prop_mat only on props without PBR: {uses}")
    mg = open(os.path.join(GD, "scripts", "main.gd")).read()
    m = re.search(r"if mobile: return \[([0-9.]+), ([0-9.]+), ([0-9.]+)\]", mg)
    check(m is not None and float(m.group(3)) == 1.0 and float(m.group(2)) == 1.0,
          "main.gd auto_render_scale: phones Low/Medium/High = " + (", ".join(m.groups()) if m else "?") + " (High and Medium 1.0)")
    # 4 ----------------------------------------------------------------
    section("4. imported texture sizes (.ctex headers)")
    small = 0
    count = 0
    for imp in sorted(glob.glob(os.path.join(GD, "textures", "terrain", "*.import")) + glob.glob(os.path.join(GD, "models", "heroes", "**", "*.import"), recursive=True)):
        txt = open(imp).read()
        if 'importer="texture"' not in txt: continue
        for dest in re.findall(r'"res://(\.godot/imported/[^"]+\.ctex)"', txt):
            f = os.path.join(GD, dest)
            if not os.path.exists(f):
                check(False, f"{dest} missing (run the import)"); continue
            b = open(f, "rb").read(16)
            w, h = struct.unpack_from("<II", b, 8)
            count += 1
            if min(w, h) <= 256:
                small += 1
                print(f"      {os.path.relpath(imp, GD)[:-7]} -> {w}x{h}  <= 256")
            else:
                print(f"      {os.path.relpath(imp, GD)[:-7]} -> {w}x{h}  ({os.path.basename(dest).split('.')[-2]})")
    check(count > 0 and small == 0, f"{count} imported terrain and hero textures, {small} at 256 px or less")
    # 5 ----------------------------------------------------------------
    section("5. engine: headless boot and the chunk dressing count")
    r = subprocess.run([GODOT, "--headless", "--path", GD, "--quit"], capture_output=True, text=True, timeout=600)
    errs = [l for l in (r.stdout + r.stderr).splitlines() if re.match(r"^(ERROR|SCRIPT ERROR|WARNING|USER ERROR)", l)]
    for l in errs[:10]: print("      " + l)
    check(r.returncode == 0 and not errs, f"godot --headless --quit: exit {r.returncode}, {len(errs)} error or warning lines")
    r = subprocess.run([GODOT, "--headless", "--path", GD, "res://tests/gate_chunk.tscn"], capture_output=True, text=True, timeout=900)
    out = r.stdout + r.stderr
    for l in out.splitlines():
        if l.startswith("GATE") or "SCRIPT ERROR" in l: print("      " + l)
    script_errs = [l for l in out.splitlines() if l.startswith("SCRIPT ERROR") or "Parse Error" in l]
    check(r.returncode == 0 and "GATE engine checks: PASS" in out and not script_errs,
          f"tests/gate_chunk.tscn: exit {r.returncode}, every chunk >= 150 instances, {len(script_errs)} script errors")
    # 6 ----------------------------------------------------------------
    if build_apk:
        section("6. Android APK")
        r = subprocess.run(["bash", os.path.join(HERE, "build_android.sh")], capture_output=True, text=True, timeout=3600)
        apk = os.path.join(ROOT, "build", "shardfall.apk")
        tail = (r.stdout + r.stderr).strip().splitlines()[-6:]
        for l in tail: print("      " + l)
        ok = r.returncode == 0 and os.path.exists(apk)
        check(ok, f"APK {apk}: " + (f"{os.path.getsize(apk)} bytes = {os.path.getsize(apk) / 1e6:.2f} MB" if os.path.exists(apk) else "missing"))
    print(f"\ngate_check: {len(FAILS)} failed check(s)")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main(build_apk="--no-apk" not in sys.argv))
