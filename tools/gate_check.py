"""The release gate: every check must pass for exit code 0.

    python3 tools/gate_check.py              # all checks, then the release APK build
    python3 tools/gate_check.py --no-apk     # all checks without the build

1. tools/fal_cache.json: the total spend is exactly the $18.904 of the asset overhaul (0.9.9 calls nothing);
   every hero, boss, foe and prop .glb exists, > 100 KB
2. every .glb parsed (struct + json), its height and min_y printed and in range (feet at 0):
   heroes: a skin with joints and the 7 clips (idle, walk, run, cast/attack, roll/dodge, jump, die/death),
   each > 0.2 s, and the trimmed ones short: cast <= 1.10 s, roll <= 0.80 s, jump <= 1.00 s;
   bosses: a skin with joints and the 5 clips (idle, walk, attack, slam, die/death), each > 0.2 s;
   foes: albedo, normal and ORM maps, the baked normal and ORM images not blank (each of their R and G
   channels' pixel standard deviation >= 3.0), and a walk cycle that moves (its .vat: > 2 units of travel);
   props: a baseColorTexture on every material
3. code: no JumpTuck in scripts/; no "pal * 4.0" in the terrain shader; prop_mat never on a PBR prop; High
   and Medium phones at 3D scale 1.0; no web branch (OS.has_feature("web")) in scripts/
4. textures: the imported .ctex headers of everything under textures/terrain and models/{heroes, bosses,
   foes, props}: none 256 px or smaller; and the texel budget (tools/texture_budget.py --check)
5. engine: godot --headless --quit with no ERROR / WARNING line; tests/gate_chunk.tscn (models as the game
   resolves them, chunk dressing on Low, Medium and High, solids the same on every tier); the unit tests
   (tests/tests.tscn -- unit) with 0 failed, the 0.9.9 remediation and 0.10.0 voice groups printed; neither
   gate_chunk nor the unit run leaves an object alive at exit (an undisposed World is a reference cycle)
6. voice (godot/data/voice_manifest.json, tools/gen_voices.py; nothing calls ElevenLabs or fal): the dry run exits 0
   with the network shut off; 61 lines, a valid schema, the 4 exiles on distinct voices and distinct
   stability/style; the validator refuses six broken copies of the manifest; no line's text is repeated in a
   script; the ffmpeg chain's selftest; and the drop-in end to end: a clip encoded at narrator/act_0_0.ogg,
   imported by Godot, plays instead of the chime at its own length (removed again before the APK is built); the
   clips present add up to at most 2.5 MB
7. the single Android APK, the only build: export_presets.cfg holds one preset, Android
   (com.shardfall.riftsurvivors: no Web, no Lite); no web build tools (tools/build_web.sh, pack_web.py) and
   no web renderer override in project.godot; tools/build_android.sh has no lite mode; built, its size and
   the .ctex bytes inside printed, the voice manifest inside it
"""
import glob
import io
import json
import os
import re
import copy
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GD = os.path.join(ROOT, "godot")
GODOT = os.path.expanduser(os.environ.get("GODOT", "/root/toolchains/godot/godot"))
if not os.path.exists(GODOT): GODOT = os.path.expanduser("~/toolchains/godot/godot")
sys.path.insert(0, HERE)
import gltf_info  # noqa: E402
import texture_budget  # noqa: E402
import vat_pack  # noqa: E402
import verify_assets  # noqa: E402
import gen_voices  # noqa: E402

EXPECTED_SPEND = 18.904
HERO_MAX = {"cast": 1.10, "roll": 0.80, "jump": 1.00}
FAILS = []


def check(ok, msg):
    print(("PASS  " if ok else "FAIL  ") + msg, flush=True)
    if not ok: FAILS.append(msg)


def section(t):
    print(f"\n== {t}", flush=True)


def _image(js, binchunk, tex_index):
    from PIL import Image
    img = js["images"][js["textures"][tex_index]["source"]]
    bv = js["bufferViews"][img["bufferView"]]
    data = binchunk[bv.get("byteOffset", 0): bv.get("byteOffset", 0) + bv["byteLength"]]
    return img.get("name", "?"), Image.open(io.BytesIO(data)).convert("RGB")


def _clips(aid, s, alts_list):
    names = {n.lower(): d for n, d in s["animations"]}
    check(s["skins"] > 0 and s["joints"] > 0, f"{aid}: skin with {s['joints']} joints")
    for alts in alts_list:
        hit = next((a for a in alts if a in names), None)
        check(hit is not None and names[hit] > 0.2, f"{aid}: clip {'/'.join(alts)} " + (f"{names[hit]:.2f} s" if hit else "missing"))
    return names


def main(build_apk=True):
    import numpy as np
    # 1 ----------------------------------------------------------------
    section("1. fal cache and asset files")
    cpath = os.path.join(HERE, "fal_cache.json")
    check(os.path.exists(cpath), "tools/fal_cache.json exists")
    if os.path.exists(cpath):
        c = json.load(open(cpath))
        total = sum(x["cost_usd"] for x in c["calls"])
        calls = len([x for x in c["calls"] if x["status"] == "done"])
        check(abs(total - EXPECTED_SPEND) < 1e-6, f"total fal spend ${total:.3f} over {calls} completed calls: unchanged from ${EXPECTED_SPEND:.3f} (no new calls)")
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
            names = _clips(aid, s, verify_assets.CLIPS["hero"])
            for clip, mx in HERO_MAX.items():
                d = names.get(clip, 99.0)
                check(d <= mx, f"{aid}: {clip} trimmed to {d:.2f} s (<= {mx:.2f})")
        elif kind == "boss":
            _clips(aid, s, verify_assets.CLIPS["boss"])
            mats = s["materials"]
            check(len(mats) > 0 and all("baseColor" in sl for _, sl in mats), f"{aid}: baseColorTexture on every material")
        elif kind == "foe":
            js, binchunk = gltf_info.load(p)
            m = js["materials"][0]
            pbr = m.get("pbrMetallicRoughness", {})
            have = {"albedo": "baseColorTexture" in pbr, "normal": "normalTexture" in m, "orm": "metallicRoughnessTexture" in pbr}
            check(all(have.values()), f"{aid}: albedo, normal and ORM maps ({', '.join(k for k, v in have.items() if v)})")
            for slot, ref in (("normal", m.get("normalTexture")), ("orm", pbr.get("metallicRoughnessTexture"))):
                if ref is None: continue
                name, im = _image(js, binchunk, ref["index"])
                px = np.asarray(im, dtype=np.float32).reshape(-1, 3)
                sd = px.std(0)
                check(min(sd[0], sd[1]) >= 3.0, f"{aid}: baked {slot} '{name}' {im.size[0]}x{im.size[1]} not blank: pixel std R {sd[0]:.1f} G {sd[1]:.1f} B {sd[2]:.1f} (RGB {px.std():.1f})")
            nv, clips, P, N = vat_pack.read_sva3(open(p[:-4] + ".vat", "rb").read())
            walk = next(cl for cl in clips if cl[0] == "walk")
            seg = P[walk[1]: walk[1] + walk[2]]
            travel = float(np.abs(seg - seg[0]).max())
            check(travel > 2.0, f"{aid}: walk cycle moves ({travel:.2f} units of vertex travel over {walk[2]} frames)")
        else:
            mats = s["materials"]
            check(len(mats) > 0 and all("baseColor" in sl for _, sl in mats), f"{aid}: baseColorTexture on every material ({[sorted(sl) for _, sl in mats]})")
    # 3 ----------------------------------------------------------------
    section("3. code")
    tuck = subprocess.run(["grep", "-rn", "JumpTuck", os.path.join(GD, "scripts")], capture_output=True, text=True).stdout.strip()
    check(tuck == "", "JumpTuck: 0 matches in scripts/" + ("" if not tuck else f" ({len(tuck.splitlines())} found)"))
    terr = open(os.path.join(GD, "shaders", "3d", "terrain.gdshader")).read()
    check("pal * 4.0" not in terr, "'pal * 4.0': 0 matches in shaders/3d/terrain.gdshader")
    wv = open(os.path.join(GD, "scripts", "render3d", "world_view_3d.gd")).read().splitlines()
    uses = [(i + 1, l.strip()) for i, l in enumerate(wv) if "material_override = prop_mat" in l]
    check(len(uses) > 0 and all("not Models.has_pbr(" in l for _, l in uses), f"prop_mat only on props without PBR: {uses}")
    mg = open(os.path.join(GD, "scripts", "main.gd")).read()
    m = re.search(r"if mobile: return \[([0-9.]+), ([0-9.]+), ([0-9.]+)\]", mg)
    check(m is not None and float(m.group(3)) == 1.0 and float(m.group(2)) == 1.0,
          "main.gd auto_render_scale: phones Low/Medium/High = " + (", ".join(m.groups()) if m else "?") + " (High and Medium 1.0)")
    webf = subprocess.run(["grep", "-rn", 'has_feature("web")', os.path.join(GD, "scripts")], capture_output=True, text=True).stdout.strip()
    check(webf == "", 'OS.has_feature("web"): 0 matches in scripts/ (the APK is the only build)' + ("" if not webf else f" ({len(webf.splitlines())} found)"))
    # 4 ----------------------------------------------------------------
    section("4. imported texture sizes (.ctex headers)")
    dirs = ["textures/terrain", "models/heroes", "models/bosses", "models/foes", "models/props"]
    small = 0
    count = 0
    for d in dirs:
        sizes = []
        for imp in sorted(glob.glob(os.path.join(GD, d, "**", "*.import"), recursive=True)):
            txt = open(imp).read()
            if 'importer="texture"' not in txt: continue
            for dest in sorted(set(re.findall(r'"res://(\.godot/imported/[^"]+\.ctex)"', txt))):
                f = os.path.join(GD, dest)
                if not os.path.exists(f):
                    check(False, f"{dest} missing (run the import)"); continue
                w, h = struct.unpack_from("<II", open(f, "rb").read(16), 8)
                sizes.append(min(w, h))
                if min(w, h) <= 256:
                    small += 1
                    print(f"      {os.path.relpath(imp, GD)[:-7]} -> {w}x{h}  <= 256")
        count += len(sizes)
        print(f"      {d + '/':17s} {len(sizes):3d} imported files, {min(sizes) if sizes else 0}-{max(sizes) if sizes else 0} px")
    check(count > 0 and small == 0, f"{count} imported texture files across terrain, heroes, bosses, foes and props; {small} at 256 px or less")
    rows = 0
    off = 0
    for imp, rel, txt, (limit, why) in texture_budget.imports():
        want = limit if limit else 2048
        if "compress/mode=2" not in txt:
            off += 1
            print(f"      not VRAM-compressed: {rel}")
        for fmt, w, h in texture_budget.ctex_sizes(txt):
            rows += 1
            if max(w, h) != want:
                off += 1
                print(f"      off budget: {rel} ({fmt}) {w}x{h}, wanted {want} ({why})")
    check(rows > 0 and off == 0, f"texel budget: {rows} imported files, all VRAM-compressed, {off} off it (2048: heroes, bosses, landmark and foe albedo; 1024: prop and foe normal/ORM, clutter albedo)")
    # 5 ----------------------------------------------------------------
    section("5. engine: headless boot, chunk dressing, unit tests")
    r = subprocess.run([GODOT, "--headless", "--path", GD, "--quit"], capture_output=True, text=True, timeout=600)
    errs = [l for l in (r.stdout + r.stderr).splitlines() if re.match(r"^(ERROR|SCRIPT ERROR|WARNING|USER ERROR)", l)]
    for l in errs[:10]: print("      " + l)
    check(r.returncode == 0 and not errs, f"godot --headless --quit: exit {r.returncode}, {len(errs)} error or warning lines")
    r = subprocess.run([GODOT, "--headless", "--path", GD, "res://tests/gate_chunk.tscn"], capture_output=True, text=True, timeout=1800)
    out = r.stdout + r.stderr
    for l in out.splitlines():
        if l.startswith("GATE") or "SCRIPT ERROR" in l: print("      " + l)
    script_errs = [l for l in out.splitlines() if l.startswith("SCRIPT ERROR") or "Parse Error" in l]
    check(r.returncode == 0 and "GATE engine checks: PASS" in out and not script_errs,
          f"tests/gate_chunk.tscn: exit {r.returncode}, {len(script_errs)} script errors")
    leak = next((l.strip() for l in out.splitlines() if "leaked at exit" in l), "")
    check(not leak, "tests/gate_chunk.tscn: no objects left alive at exit" + (f" ({leak})" if leak else ""))
    env = dict(os.environ, TESTS_VERBOSE="1")
    r = subprocess.run([GODOT, "--headless", "--path", GD, "res://tests/tests.tscn", "--", "unit"], capture_output=True, text=True, timeout=1800, env=env)
    out = r.stdout + r.stderr
    lines = out.splitlines()
    for grp in ("== 0.9.9 remediation", "== 0.10.0 voice"):
        if grp in lines:
            i = lines.index(grp)
            for l in lines[i:]:
                if l.startswith("==") and l != grp: break
                if l.strip(): print("      " + l)
    fails = [l for l in lines if l.strip().startswith("FAIL:")]
    for l in fails[:10]: print("      " + l)
    tot = next((l for l in lines if re.match(r"^== \d+ passed, \d+ failed ==$", l)), "no totals line")
    print("      " + tot)
    check(r.returncode == 0 and ", 0 failed ==" in tot and not fails, f"unit tests: {tot.strip('= ')}")
    leak = next((l.strip() for l in lines if "leaked at exit" in l), "")
    check(not leak, "unit tests: no objects left alive at exit" + (f" ({leak})" if leak else ""))
    # 6 ----------------------------------------------------------------
    section("6. voice: manifest, generator, drop-in (no ElevenLabs or fal calls)")
    dead = "http://127.0.0.1:9"                       # the dry run gets no way out: a network call would fail it
    env = dict(os.environ, ELEVENLABS_API_KEY="", FAL_KEY="", HTTPS_PROXY=dead, HTTP_PROXY=dead, https_proxy=dead, http_proxy=dead)
    r = subprocess.run([sys.executable, os.path.join(HERE, "gen_voices.py"), "--dry-run"], capture_output=True, text=True, timeout=120, env=env)
    for l in (r.stdout + r.stderr).rstrip().splitlines(): print("      " + l)
    check(r.returncode == 0 and "ERROR" not in r.stdout, f"gen_voices.py --dry-run: exit {r.returncode} with the network shut off and no keys")
    man = gen_voices.load_manifest()
    err, _ = gen_voices.validate(man)
    check(len(man.get("lines", [])) == 61 and not err, f"voice_manifest.json: {len(man.get('lines', []))} lines (61), schema valid ({len(err)} errors)")
    heroes = [man["casting"][h] for h in gen_voices.HEROES]
    envs = [c["voice_id_env"] for c in heroes]
    profs = [(c["stability"], c["style"]) for c in heroes]
    check(len(set(envs)) == 4 and len(set(profs)) == 4, f"the 4 exiles: distinct voices {envs}, distinct stability/style {profs}")
    # the validator is not vacuous: each broken copy of the manifest must be refused
    def broken(fn):
        m = copy.deepcopy(man)
        fn(m)
        return len(gen_voices.validate(m)[0])
    muts = {
        "a line missing": lambda m: m["lines"].pop(),
        "Sparkcaller cast like the Warden": lambda m: m["casting"]["spark"].update(stability=m["casting"]["warden"]["stability"], style=m["casting"]["warden"]["style"]),
        "two speakers on one voice": lambda m: m["casting"]["herald"].update(voice_id_env=m["casting"]["tyrant"]["voice_id_env"]),
        "a cast bark at priority 2": lambda m: next(l for l in m["lines"] if l["cue"] == "cast").update(priority=2),
        "a 12-word bark": lambda m: next(l for l in m["lines"] if l["cue"] == "cast").update(text="one two three four five six seven eight nine ten eleven twelve"),
        "a clip off its canonical path": lambda m: m["lines"][0].update(file="res://audio/voices/elsewhere.ogg"),
    }
    caught = {k: broken(f) for k, f in muts.items()}
    check(all(n > 0 for n in caught.values()), "the validator refuses every broken copy: " + ", ".join(f"{k} ({n})" for k, n in caught.items()))
    # every line's words live in the manifest only: none is repeated in a script
    src = ""
    for f in glob.glob(os.path.join(GD, "scripts", "**", "*.gd"), recursive=True): src += open(f).read()
    dup = [l["id"] for l in man["lines"] if l["text"][:32] in src]
    check(not dup, f"no voice line's text is written into a script ({len(dup)} found{': ' + ', '.join(dup[:5]) if dup else ''})")
    r = subprocess.run([sys.executable, os.path.join(HERE, "gen_voices.py"), "--selftest"], capture_output=True, text=True, timeout=300, env=env)
    for l in (r.stdout + r.stderr).rstrip().splitlines(): print("      " + l)
    check(r.returncode == 0, "gen_voices.py --selftest: ffmpeg trims, normalises to -16 LUFS / -1 dBTP and encodes 44.1 kHz mono Vorbis")
    # drop-in, end to end: a clip at a real line's path is imported by Godot and played at its own length
    target = os.path.join(GD, "audio", "voices", "narrator", "act_0_0.ogg")
    made = not os.path.exists(target)
    try:
        if made:
            with tempfile.TemporaryDirectory() as d:
                wav = os.path.join(d, "probe.wav")
                gen_voices._ffmpeg(["-loglevel", "error", "-y", "-f", "lavfi", "-i", "aevalsrc='0.05*sin(2*PI*120*t)*(1+0.5*sin(2*PI*3*t))':s=44100:d=2.2", wav])
                gen_voices.encode(wav, target)
        subprocess.run([GODOT, "--headless", "--path", GD, "--import"], capture_output=True, text=True, timeout=900)
        r = subprocess.run([GODOT, "--headless", "--path", GD, "res://tests/tests.tscn", "--", "voice_dropin"], capture_output=True, text=True, timeout=300,
                           env=dict(os.environ, TESTS_VERBOSE="1"))
        out = r.stdout + r.stderr
        for l in out.splitlines():
            if l.strip().startswith(("ok:", "FAIL:")): print("      " + l.strip())
        check(r.returncode == 0 and ", 0 failed ==" in out, "drop-in: a clip from gen_voices.py at narrator/act_0_0.ogg, imported by Godot, plays instead of the chime at its own length")
    finally:
        if made:
            for f in (target, target + ".import"):
                if os.path.exists(f): os.remove(f)
            for dd in (os.path.dirname(target), os.path.dirname(os.path.dirname(target))):
                if os.path.isdir(dd) and not os.listdir(dd): os.rmdir(dd)
            subprocess.run([GODOT, "--headless", "--path", GD, "--import"], capture_output=True, text=True, timeout=900)
    present = [gen_voices.ogg_path(l) for l in man["lines"] if os.path.exists(gen_voices.ogg_path(l))]
    size = sum(os.path.getsize(p) for p in present)
    check(size <= 2.5e6, f"voice pack: {len(present)} of {len(man['lines'])} clips in godot/audio/voices, {size / 1e6:.2f} MB (at most 2.5 MB)")
    vc = gen_voices.load_cache()
    check(True, f"voice spend ${gen_voices.spend(vc):.3f} over {len(vc.get('calls', {}))} calls (tools/voice_cache.json); fal's ledger is section 1")
    # 7 ----------------------------------------------------------------
    if build_apk:
        section("7. Android APK (one build)")
        pre = open(os.path.join(GD, "export_presets.cfg")).read()
        blocks = re.split(r"^\[preset\.\d+\]$", pre, flags=re.M)[1:]
        names = [re.search(r'^name="([^"]*)"', b, re.M).group(1) for b in blocks]
        plats = [re.search(r'^platform="([^"]*)"', b, re.M).group(1) for b in blocks]
        ids = re.findall(r'^package/unique_name="([^"]*)"', pre, re.M)
        check(names == ["Android"] and plats == ["Android"] and ids == ["com.shardfall.riftsurvivors"] and "Lite" not in pre,
              f"export_presets.cfg: presets {names} on {plats}, app ids {ids} (one APK: no Web, no Shardfall Lite)")
        webt = [f for f in ("tools/build_web.sh", "tools/pack_web.py") if os.path.exists(os.path.join(ROOT, f))]
        pg = open(os.path.join(GD, "project.godot")).read()
        check(not webt and ".web=" not in pg,
              "no web build: " + (f"{webt} still there" if webt else "no tools/build_web.sh or tools/pack_web.py") +
              (", a web override in project.godot" if ".web=" in pg else ", no web override in project.godot"))
        bs = open(os.path.join(HERE, "build_android.sh")).read()
        check(re.search(r"\blite\b", bs, re.I) is None, "tools/build_android.sh: no lite mode")
        r = subprocess.run(["bash", os.path.join(HERE, "build_android.sh")], capture_output=True, text=True, timeout=3600)
        apk = os.path.join(ROOT, "build", "shardfall.apk")
        tail = [l for l in (r.stdout + r.stderr).strip().splitlines() if not l.startswith("Picked up JAVA_TOOL_OPTIONS")][-4:]
        for l in tail: print("      " + l)
        ok = r.returncode == 0 and os.path.exists(apk)
        if ok:
            z = zipfile.ZipFile(apk)
            ct = [i for i in z.infolist() if i.filename.endswith(".ctex")]
            packed = sum(i.compress_size for i in ct)
            raw = sum(i.file_size for i in ct)
            print(f"      .ctex inside the APK: {len(ct)} files, {packed / 1e6:.2f} MB as stored ({raw / 1e6:.2f} MB unpacked)")
            names = z.namelist()
            vo = [n for n in names if "/audio/voices/" in n and not n.endswith(".import")]
            check(any(n.endswith("data/voice_manifest.json") for n in names) and not any("/tests/" in n for n in names),
                  f"the APK carries data/voice_manifest.json ({len(vo)} voice clip files) and none of tests/")
        check(ok, f"APK {apk}: " + (f"{os.path.getsize(apk)} bytes = {os.path.getsize(apk) / 1e6:.2f} MB" if os.path.exists(apk) else "missing"))
    print(f"\ngate_check: {len(FAILS)} failed check(s)")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main(build_apk="--no-apk" not in sys.argv))
