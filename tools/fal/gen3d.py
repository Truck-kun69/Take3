"""Concept image (FLUX schnell) -> 3D model (TRELLIS 2) on fal.ai, for Shardfall props and creatures.

    python3 tools/fal/gen3d.py <out dir> <name> [<name> ...]      # names from ASSETS below

Auth: in a cloud session the network proxy adds the fal key to requests for fal.run; locally, set
FAL_KEY (key_id:key_secret) and it is sent as "Authorization: Key ...". Outputs per asset:
<out>/<name>.jpg (the concept) and <out>/<name>.glb (TRELLIS 2 mesh, PBR textured), then
tools/blender/import_props.py turns the glb into a game prop.
Cost (late 2026): FLUX schnell about $0.003 an image, TRELLIS 2 $0.25 at 512 / $0.30 at 1024.
"""
import json
import os
import sys
import time
import urllib.request

STYLE = ("dark fantasy action RPG game prop, single isolated object, centered, full object visible, "
         "three-quarter view from slightly above, plain flat light grey studio background, soft even lighting, "
         "stylized realistic, hand-painted PBR textures, no text, no people")
ASSETS = {
    "crystal": "a cluster of jagged glowing violet and ice-blue crystal shards bursting out of a small base of dark cracked rock",
    "pillar": "a ruined broken gothic stone pillar with carved runes, crumbled jagged top and fallen chunks at its base",
    "tree": "a dead gnarled leafless tree with a twisted black trunk and claw-like bare branches, roots gripping a little earth",
    "rock": "a large weathered grey boulder with deep cracks, lichen and a few small crystal shards in the cracks",
    "bones": "a low pile of old human skulls, ribs and scattered long bones lying flat on the ground",
}


def call(model, payload, timeout=900):
    req = urllib.request.Request(f"https://fal.run/{model}", data=json.dumps(payload).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    if os.environ.get("FAL_KEY"):
        req.add_header("Authorization", "Key " + os.environ["FAL_KEY"])
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        raise SystemExit(f"{model}: HTTP {e.code}: {e.read()[:400]!r}")


def fetch(url, path):
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "shardfall-gen3d"}), timeout=300) as r:
        open(path, "wb").write(r.read())


def gen(out, name, resolution=512):
    t0 = time.time()
    img = call("fal-ai/flux/schnell", {"prompt": f"{ASSETS[name]}, {STYLE}", "image_size": "square_hd",
                                       "num_inference_steps": 4, "num_images": 1, "seed": 7, "output_format": "jpeg"})
    url = img["images"][0]["url"]
    fetch(url, os.path.join(out, name + ".jpg"))
    t1 = time.time()
    res = call("fal-ai/trellis-2", {"image_url": url, "resolution": resolution, "seed": 7, "texture_size": 1024,
                                    "decimation_target": 20000, "remesh": True})
    fetch(res["model_glb"]["url"], os.path.join(out, name + ".glb"))
    print(f"GEN {name}: image {t1 - t0:.0f}s, model {time.time() - t1:.0f}s -> {out}/{name}.glb "
          f"({os.path.getsize(os.path.join(out, name + '.glb')) / 1e6:.1f} MB)", flush=True)


if __name__ == "__main__":
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for n in sys.argv[2:] or list(ASSETS):
        gen(out, n)
