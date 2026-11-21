"""Generate Shardfall's heroes, bosses, foes and props on fal.ai, with a cost cap and a cache.

    python3 tools/fal_assets.py --canary                 # warden + tree only (the canary, about $2.65)
    python3 tools/fal_assets.py --all                    # every asset (run after the canary passed)
    python3 tools/fal_assets.py --only spark,rock         # some assets
    python3 tools/fal_assets.py --report                 # spend and status from the cache, no calls
    python3 tools/fal_assets.py --plan --all             # what --all would still spend, no calls

Steps per asset (each one call, each logged in tools/fal_cache.json):
  concept   fal-ai/flux/schnell, 768 x 1024 (characters) or 992 x 992 (props, foes): one megapixel, $0.003.
            Every prompt starts with the same dark-fantasy prefix (PREFIX) so the set shares one palette.
  model     heroes, bosses: fal-ai/meshy/v7.1/image-to-3d, textured with PBR maps, A-pose, symmetric,
            ~20-24k triangles ($1.20). props: fal-ai/hunyuan-3d/v3.1/pro/image-to-3d with PBR ($0.375 +
            $0.15). foes: fal-ai/hunyuan-3d/v3.1/rapid/image-to-3d with PBR ($0.225 + $0.15).
  rig       heroes, bosses: fal-ai/meshy/rigging/multi-animation on the textured model, Mixamo skeleton,
            one clip per Meshy library action id ($0.20 + $0.12 a clip); its walk and run come with the rig.
Prices are fal's published ones (model pages, Nov 2026); the cache records each call's price as
computed from them (fal returns no invoice per request).

Cache and cap: a call is written to the cache when it is submitted (endpoint, asset, step, request id,
arguments, price) and completed with its output URLs and local files. The cap ($19.50) counts every
submitted call: one that would take the total past it is not sent, and the run stops. A re-run reads the
cache: a finished step is not called again (its files are re-downloaded from the stored URLs if missing),
a submitted one is resumed by its request id. fal charges only requests that succeed; a failed call is
kept in the cache with its error and a price of 0.

Auth: the cloud session's network proxy adds the fal key for fal.run and queue.fal.run; elsewhere set
FAL_KEY (key_id:key_secret), sent as "Authorization: Key ...". Long jobs (Meshy, Hunyuan) go through
fal's queue (queue.fal.run): the synchronous host cuts Meshy off after 30 s.
Raw downloads land in tools/.fal_raw/<asset>/ (not in git); tools/blender/process_fal_assets.py turns
them into the game's models/ files.
"""
import datetime
import json
import os
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "fal_cache.json")
RAW = os.path.join(HERE, ".fal_raw")
CAP_USD = 19.50

PREFIX = ("dark gothic fantasy action RPG 3D game asset, Diablo IV / Path of Exile 2 aesthetic, realistic weathered PBR "
          "materials (aged iron, dark worn leather, muted linen, mossy granite, dark bark), grounded natural earth-tone "
          "colors, zero neon saturation, even neutral studio lighting, solid plain white background, full silhouette centered")
APOSE = ("full body from head to toe, strict symmetrical A-pose, arms straight and angled 45 degrees down away from the "
         "body, open empty hands, feet apart, front view, standing on flat ground")
STANCE = "full body from head to toe, neutral combat stance, front three-quarter view, standing on flat ground"
OBJECT = "single isolated object, three-quarter view from slightly above, whole object visible, nothing else in frame"

# id: (kind, description). The descriptions keep each hero's look from the earlier sets.
ASSETS = {
    "warden": ("hero", "a grizzled armored knight warden in battered dented steel plate armor over rusted chainmail, a tattered "
                       "dark red tabard, a closed great helm with a narrow visor slit, worn leather straps and belts, a short torn "
                       "dark red cape, a longsword sheathed on his back"),
    "spark": ("hero", "a gaunt frost sorcerer in a deep hood and a long dark blue coat with a frayed hem and a fur-trimmed collar, "
                      "frost-rimed leather bracers and boots, a pale hollow face half hidden in the hood's shadow"),
    "ember": ("hero", "a fierce witch in a crooked wide-brimmed pointed black hat and a long tattered crimson robe, singed and "
                      "soot-stained at the hem, a leather corset with tarnished brass buckles, an ash-smudged face, dark red hair"),
    "storm": ("hero", "a scarred barbarian storm shaman with a horned brass helmet and a braided beard, a heavy dark fur mantle "
                      "over a dented bronze breastplate and a rusted chainmail shirt, leather bracers etched with faint violet "
                      "lightning runes, a chainmail and leather kilt, fur boots"),
    "tyrant": ("boss", "a towering horned tyrant warlord, gaunt and monstrous, in blackened scorched iron plate armor with a "
                       "ribcage-shaped breastplate and a dull ember glow inside it, curved black horns, a ragged dark cloak, "
                       "clawed iron gauntlets, hulking shoulders"),
    "herald": ("boss", "a tall gaunt robed herald, a hollow cracked porcelain-white mask with a jagged crystal crown, long "
                       "tattered pale grey and faded violet vestments, thin long arms, rusted chains hanging from the waist"),
    "grunt": ("foe", "a rotting undead foot soldier in rusted dented armor scraps and torn grey cloth, hunched, gaunt grey skin"),
    "runner": ("foe", "a lean emaciated ghoul with long clawed arms and mottled grey-green skin, a tattered loincloth, leaning "
                      "forward"),
    "brute": ("foe", "a hulking ogre brute with thick arms and a heavy gut, crude rusted iron pauldrons, thick leather straps, "
                     "a scarred grey hide"),
    "spitter": ("foe", "a hunched bloated plague cultist with a swollen throat sac, tattered dark hooded robes, a stained "
                       "leather apron, sickly pale skin"),
    "charger": ("foe", "a horned bull-headed beastman with massive shoulders, iron rings on its curved horns, matted dark fur and "
                       "leather wraps, hooves"),
    "tree": ("prop", "a tall gnarled old oak tree with a thick dark bark trunk, twisted branches and a sparse dark green canopy, "
                     "roots gripping the earth"),
    "tree_dead": ("prop", "a dead gnarled leafless tree with a twisted black trunk and claw-like bare branches, roots gripping "
                          "a little earth"),
    "rock": ("prop", "a large weathered mossy granite boulder with deep cracks and patches of lichen"),
    "arch": ("prop", "a ruined gothic stone archway, two cracked stone pillars joined by a broken pointed arch, moss in the "
                     "cracks, fallen stones at the base"),
    "wall": ("prop", "a ruined section of old fieldstone wall, low and long, a crumbling uneven top, mossy granite blocks"),
    "pillar": ("prop", "a broken weathered gothic stone pillar with carved runes, a crumbled jagged top and fallen chunks at "
                       "its base"),
    "bones": ("prop", "a low pile of old yellowed human skulls, ribs and scattered long bones lying flat on the ground"),
    "bush": ("prop", "a dense low thorny shrub with small dark green leaves and a few dead twigs, round and wider than tall"),
}
CANARY = ["warden", "tree"]

# Meshy animation library action ids (docs.meshy.ai/en/api/animation-library); walk and run come with the rig
HERO_CLIPS = {"idle": 0, "roll": 158, "jump": 466, "hit": 178, "die": 189}
HERO_CAST = {"warden": 131, "spark": 125, "ember": 129, "storm": 130}         # mage_soell_cast_2 / Charged_Spell_Cast / ...
BOSS_CLIPS = {"idle": 0, "attack": 92, "slam": 127, "die": 189}             # Double_Combo_Attack, Charged_Ground_Slam
RIG_HEIGHT_M = {"hero": 1.8, "boss": 2.6}


def clips_for(aid):
    kind = ASSETS[aid][0]
    if kind == "hero":
        d = dict(HERO_CLIPS); d["cast"] = HERO_CAST[aid]
        return d
    return dict(BOSS_CLIPS) if kind == "boss" else {}


# ---------------------------------------------------------------- prices (USD, fal's published prices)
def price(endpoint, payload):
    if endpoint == "fal-ai/flux/schnell":
        sz = payload["image_size"]
        mp = sz["width"] * sz["height"] / 1e6
        return 0.003 * max(1, -(-mp // 1)) * payload.get("num_images", 1)
    if endpoint == "fal-ai/meshy/v7.1/image-to-3d":
        p = 1.20 if payload.get("should_texture", True) else 0.80
        if payload.get("enable_rigging"): p += 0.20
        if payload.get("enable_animation"): p += 0.12
        return p
    if endpoint == "fal-ai/meshy/rigging/multi-animation":
        return 0.20 + 0.12 * len(payload["animation_action_ids"])
    if endpoint == "fal-ai/hunyuan-3d/v3.1/pro/image-to-3d":
        return 0.375 + (0.15 if payload.get("enable_pbr") else 0) + (0.15 if "face_count" in payload else 0)
    if endpoint == "fal-ai/hunyuan-3d/v3.1/rapid/image-to-3d":
        return 0.225 + (0.15 if payload.get("enable_pbr") else 0)
    raise SystemExit(f"no price for {endpoint}: add it before calling")


# ---------------------------------------------------------------- cache
def load_cache():
    if os.path.exists(CACHE):
        return json.load(open(CACHE))
    return {"cap_usd": CAP_USD, "calls": []}


def save_cache(c):
    c["cap_usd"] = CAP_USD
    c["total_usd"] = round(sum(x["cost_usd"] for x in c["calls"]), 4)
    tmp = CACHE + ".tmp"
    json.dump(c, open(tmp, "w"), indent=1)
    os.replace(tmp, CACHE)


def spent(c):
    return sum(x["cost_usd"] for x in c["calls"])


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------- fal transport
def _req(url, data=None, method="GET", timeout=120):
    r = urllib.request.Request(url, data=json.dumps(data).encode() if data is not None else None, method=method,
                               headers={"Content-Type": "application/json", "User-Agent": "shardfall-fal-assets"})
    if os.environ.get("FAL_KEY"):
        r.add_header("Authorization", "Key " + os.environ["FAL_KEY"])
    with urllib.request.urlopen(r, timeout=timeout) as resp:
        return json.loads(resp.read())


def fetch(url, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "shardfall-fal-assets"}), timeout=600) as r:
                data = r.read()
            open(path + ".part", "wb").write(data)
            os.replace(path + ".part", path)
            return path
        except (urllib.error.URLError, TimeoutError) as e:
            if attempt == 3: raise
            time.sleep(5 * (attempt + 1))


def queue_call(c, key, endpoint, payload, asset, step):
    """Submit (or resume) one queued fal call; returns its output JSON. Logged in the cache."""
    entry = next((x for x in c["calls"] if x["key"] == key), None)
    if entry and entry["status"] == "done":
        return entry["output"]
    if entry is None or entry["status"] == "failed":
        cost = round(price(endpoint, payload), 4)
        if spent(c) + cost > CAP_USD + 1e-9:
            save_cache(c)
            raise SystemExit(f"CAP: {key} would cost ${cost:.3f}, total ${spent(c) + cost:.3f} > ${CAP_USD:.2f}; stopped before calling")
        if entry is not None:                         # a failed call is kept; the retry is a new entry
            entry["key"] = key + f"#failed{int(time.time())}"
        try:
            sub = _req(f"https://queue.fal.run/{endpoint}", payload, "POST", timeout=120)
        except urllib.error.HTTPError as e:
            body = e.read()[:500].decode(errors="replace")
            c["calls"].append({"key": key + f"#rejected{int(time.time())}", "asset": asset, "step": step, "endpoint": endpoint,
                               "status": "failed", "cost_usd": 0.0, "error": f"submit HTTP {e.code}: {body}",
                               "submitted_at": now(), "args": _loggable(payload)})
            save_cache(c)
            raise SystemExit(f"{key}: submit refused, HTTP {e.code}: {body}")
        entry = {"key": key, "asset": asset, "step": step, "endpoint": endpoint, "request_id": sub["request_id"],
                 "status_url": sub["status_url"], "response_url": sub["response_url"], "status": "submitted",
                 "cost_usd": cost, "submitted_at": now(), "args": _loggable(payload)}
        c["calls"].append(entry)
        save_cache(c)
        print(f"  submitted {key}: {endpoint} ${cost:.3f} (request {sub['request_id']}; total ${spent(c):.3f})", flush=True)
    # poll
    t0 = time.time()
    while True:
        try:
            st = _req(entry["status_url"], timeout=60)
        except urllib.error.HTTPError as e:
            if e.code in (500, 502, 503, 504): time.sleep(10); continue
            raise
        s = st.get("status")
        if s == "COMPLETED": break
        if time.time() - t0 > 3600:
            raise SystemExit(f"{key}: still {s} after an hour; re-run later to resume request {entry['request_id']}")
        time.sleep(8)
    try:
        out = _req(entry["response_url"], timeout=120)
    except urllib.error.HTTPError as e:
        body = e.read()[:800].decode(errors="replace")
        entry["status"] = "failed"; entry["cost_usd"] = 0.0; entry["error"] = f"result HTTP {e.code}: {body}"
        entry["finished_at"] = now()
        save_cache(c)
        raise SystemExit(f"{key}: failed, HTTP {e.code}: {body}")
    entry["status"] = "done"
    entry["output"] = out
    entry["finished_at"] = now()
    entry["seconds"] = round(time.time() - t0)
    save_cache(c)
    print(f"  done {key} in {entry['seconds']}s", flush=True)
    return out


def _loggable(payload):
    """The arguments without inline data URIs (a GLB sent inline would bloat the cache)."""
    return {k: (v if not (isinstance(v, str) and v.startswith("data:")) else f"<data uri, {len(v)} chars>") for k, v in payload.items()}


def download(c, key, urls, dest):
    """urls: {name: url} -> files under dest; noted in the cache entry (output_urls, local_paths)."""
    entry = next(x for x in c["calls"] if x["key"] == key)
    files = {}
    for name, url in urls.items():
        ext = os.path.splitext(url.split("?")[0])[1] or ".bin"
        path = os.path.join(dest, name + ext)
        if not os.path.exists(path): fetch(url, path)
        files[name] = path
    entry["output_urls"] = dict(urls)
    entry["local_paths"] = {n: os.path.relpath(p, os.path.dirname(HERE)) for n, p in files.items()}
    save_cache(c)
    return files


# ---------------------------------------------------------------- steps
def concept(c, aid):
    kind, desc = ASSETS[aid]
    pose = APOSE if kind in ("hero", "boss") else STANCE if kind == "foe" else OBJECT
    size = {"width": 768, "height": 1024} if kind in ("hero", "boss", "foe") else {"width": 992, "height": 992}
    payload = {"prompt": f"{PREFIX}, {desc}, {pose}", "image_size": size, "num_inference_steps": 4, "num_images": 1,
               "seed": 17, "output_format": "jpeg", "enable_safety_checker": False}
    key = f"{aid}/concept"
    out = queue_call(c, key, "fal-ai/flux/schnell", payload, aid, "concept")
    url = out["images"][0]["url"]
    download(c, key, {"concept": url}, os.path.join(RAW, aid))
    return url


def model(c, aid, image_url):
    kind = ASSETS[aid][0]
    if kind in ("hero", "boss"):
        ep = "fal-ai/meshy/v7.1/image-to-3d"
        payload = {"image_url": image_url, "should_texture": True, "enable_pbr": True, "pose_mode": "a-pose",
                   "symmetry_mode": "on", "topology": "triangle", "target_polycount": 20000 if kind == "hero" else 24000,
                   "should_remesh": True, "enable_safety_checker": False}
    elif kind == "prop":
        ep = "fal-ai/hunyuan-3d/v3.1/pro/image-to-3d"
        payload = {"input_image_url": image_url, "enable_pbr": True, "generate_type": "Normal"}
    else:
        ep = "fal-ai/hunyuan-3d/v3.1/rapid/image-to-3d"
        payload = {"input_image_url": image_url, "enable_pbr": True}
    key = f"{aid}/model"
    out = queue_call(c, key, ep, payload, aid, "model")
    download(c, key, {"model": out["model_glb"]["url"]}, os.path.join(RAW, aid))
    return out["model_glb"]["url"]


def rig(c, aid, model_url):
    clips = clips_for(aid)
    kind = ASSETS[aid][0]
    ids = list(clips.values())
    payload = {"model_url": model_url, "animation_action_ids": ids, "height_meters": RIG_HEIGHT_M[kind],
               "skeleton_template": "mixamo", "include_fingers": False, "enable_safety_checker": False}
    key = f"{aid}/rig"
    out = queue_call(c, key, "fal-ai/meshy/rigging/multi-animation", payload, aid, "rig")
    urls = {"rigged": out["rigged_character_glb"]["url"]}
    ba = out.get("basic_animations") or {}
    if ba.get("walking_glb"): urls["clip_walk"] = ba["walking_glb"]["url"]
    if ba.get("running_glb"): urls["clip_run"] = ba["running_glb"]["url"]
    by_id = {v: k for k, v in clips.items()}
    for a in out.get("animations") or []:
        nm = by_id.get(int(a["action_id"]), f"a{a['action_id']}")
        urls[f"clip_{nm}"] = a["animation_glb"]["url"]
    download(c, key, urls, os.path.join(RAW, aid))
    return urls


def plan(c, ids):
    """What generating these assets would still cost (steps not yet done in the cache)."""
    done = {x["key"] for x in c["calls"] if x["status"] in ("done", "submitted")}
    total = 0.0
    for aid in ids:
        kind = ASSETS[aid][0]
        steps = [("concept", price("fal-ai/flux/schnell", {"image_size": {"width": 768, "height": 1024}}))]
        if kind in ("hero", "boss"):
            steps.append(("model", 1.20))
            steps.append(("rig", 0.20 + 0.12 * len(clips_for(aid))))
        elif kind == "prop":
            steps.append(("model", 0.525))
        else:
            steps.append(("model", 0.375))
        for s, p in steps:
            if f"{aid}/{s}" not in done: total += p
    return total


def run(ids):
    c = load_cache()
    need = plan(c, ids)
    print(f"spent so far ${spent(c):.3f}; these assets still need about ${need:.3f}; cap ${CAP_USD:.2f}", flush=True)
    if spent(c) + need > CAP_USD + 1e-9:
        raise SystemExit(f"CAP: ${spent(c):.3f} + ${need:.3f} > ${CAP_USD:.2f}; nothing sent")
    for aid in ids:
        kind = ASSETS[aid][0]
        print(f"== {aid} ({kind})", flush=True)
        img = concept(c, aid)
        murl = model(c, aid, img)
        if kind in ("hero", "boss"):
            rig(c, aid, murl)
    print(f"total spent ${spent(c):.3f} of ${CAP_USD:.2f}", flush=True)


def report():
    c = load_cache()
    for x in c["calls"]:
        print(f"{x['key']:28s} {x['status']:9s} ${x['cost_usd']:.3f}  {x['endpoint']}  {x.get('seconds', '')}")
    print(f"total ${spent(c):.3f} of ${CAP_USD:.2f}")


if __name__ == "__main__":
    a = sys.argv[1:]
    if "--report" in a:
        report(); sys.exit(0)
    if "--canary" in a: ids = list(CANARY)
    elif "--all" in a: ids = list(ASSETS)
    elif "--only" in a: ids = a[a.index("--only") + 1].split(",")
    else: raise SystemExit(__doc__)
    bad = [i for i in ids if i not in ASSETS]
    if bad: raise SystemExit(f"unknown assets: {bad}")
    if "--plan" in a:
        c = load_cache(); print(f"spent ${spent(c):.3f}; {','.join(ids)} would add ${plan(c, ids):.3f}"); sys.exit(0)
    run(ids)
