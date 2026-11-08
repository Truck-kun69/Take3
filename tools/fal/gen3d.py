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
    # Act V, the Drowned Cathedral (props named <kind>_4 replace that kind in stage 4)
    "pillar_4": "a broken gothic cathedral column of pale limestone, encrusted with barnacles and hanging dark seaweed, "
                "a cracked carved capital, rubble at its base",
    "rock_4": "a broken rotting wooden church pew, waterlogged and black with age, one end collapsed, low and wide",
    "tree_4": "a tall wrought iron church candelabra with seven lit candles, wax dripping, rusted and crooked, thin and tall",
}


def call(model, payload, timeout=900, retries=2):
    """POST to fal's synchronous endpoint. 502 'upstream request failed' is transient on fal's side (and
    TRELLIS 2 at 1024 failed every time in Nov 2026, so heroes use 512): retried with backoff."""
    for attempt in range(retries + 1):
        req = urllib.request.Request(f"https://fal.run/{model}", data=json.dumps(payload).encode(), method="POST",
                                     headers={"Content-Type": "application/json"})
        if os.environ.get("FAL_KEY"):
            req.add_header("Authorization", "Key " + os.environ["FAL_KEY"])
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            body = e.read()[:400]
            if e.code in (502, 503, 504) and attempt < retries:
                time.sleep(10 * (attempt + 1))
                continue
            raise SystemExit(f"{model}: HTTP {e.code}: {body!r}")


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


# ---------------------------------------------------------------- realistic heroes
# Concepts are painted in an A-pose with empty hands so the mesh can be rigged (tools/blender/
# realistic_heroes.py finds the joints with a pose detector) and the weapon is generated apart.
HERO_STYLE = ("full body photorealistic 3D character render, standing in a relaxed A-pose with both arms straight and "
              "angled 35 degrees away from the body, open empty hands, feet shoulder width apart, front view, symmetrical, "
              "entire body visible from head to toe, plain flat light grey background, soft even studio lighting, "
              "dark fantasy, grim and grimy, battle-worn, mud-caked, dried blood, scratched and dented, realistic human "
              "proportions, highly detailed PBR materials, in the style of Path of Exile 2 and Diablo IV, no weapon, no text")
HEROES = {
    "warden": "a grizzled armored knight in battered dented steel plate armor over rusted chainmail, a tattered dark red "
              "tabard, a closed great helm with a narrow visor slit, worn leather straps and belts, a short torn dark red cape",
    "spark": "a gaunt frost sorcerer in a deep hood and a long dark blue coat with a frayed hem and a fur-trimmed collar, "
             "frost-rimed leather bracers and boots, a pale hollow face half hidden in the hood's shadow",
    "ember": "a fierce witch in a crooked wide-brimmed pointed black hat and a long tattered crimson robe, singed and "
             "soot-stained at the hem, a leather corset with tarnished brass buckles, an ash-smudged face, wild dark red hair",
    # large areas of tattooed bare skin came back from TRELLIS as dark patches (critique pass 3): armoured instead
    "storm": "a scarred barbarian storm shaman with a horned brass helmet and a braided beard, a heavy dark fur mantle "
             "over a dented bronze breastplate and a rusted chainmail shirt, leather bracers etched with glowing violet "
             "lightning runes, a chainmail and leather kilt, fur boots, grime and old blood",
}
BOSS_STYLE = HERO_STYLE.replace("realistic human proportions", "towering and gaunt, monstrous proportions")
BOSSES = {
    "tyrant_4": "the Tide Bishop, a towering drowned bishop in rotted waterlogged ecclesiastical vestments of faded gold and "
                "sea green, a tall cracked mitre crusted with barnacles, a pallid bloated face with dead white eyes, seaweed and "
                "fishing nets tangled on the robes, kelp hanging from the sleeves, water dripping",
}
WEAPONS = {
    "warden_sword": "a battered steel longsword with a worn leather grip and a dented crossguard, nicks along the blade, lying flat",
    "warden_shield": "a dented heater shield of steel and wood with a faded dark red field and a scratched gold border, front view",
    "spark_staff": "a tall gnarled pale wooden staff topped with jagged glowing ice-blue crystals bound by tarnished silver claws, vertical",
    "ember_staff": "a tall blackened wooden staff topped with an iron lantern cage holding a glowing ember, soot-stained, vertical",
    "storm_staff": "a tall dark iron staff topped with a brass two-pronged fork cradling a glowing violet crystal, vertical",
    "tyrant_4_crozier": "a tall corroded bronze bishop's crozier, the crook curled like a nautilus shell, barnacles and green "
                        "verdigris, a glowing sea-green lantern hanging from the crook, vertical",
}


def hero_concepts(out, name, seeds=(11, 23)):
    meta = {}
    desc, style = (BOSSES[name], BOSS_STYLE) if name in BOSSES else (HEROES[name], HERO_STYLE)
    for sd in seeds:
        r = call("fal-ai/flux/dev", {"prompt": f"{desc}, {style}", "image_size": {"width": 768, "height": 1024},
                                     "num_inference_steps": 28, "guidance_scale": 3.5, "num_images": 1, "seed": sd,
                                     "output_format": "jpeg", "enable_safety_checker": True})
        url = r["images"][0]["url"]
        fetch(url, os.path.join(out, f"{name}_{sd}.jpg"))
        meta[str(sd)] = url
        print(f"CONCEPT {name} seed {sd} -> {out}/{name}_{sd}.jpg", flush=True)
    json.dump(meta, open(os.path.join(out, f"{name}_concepts.json"), "w"))


def model_from(out, name, image_url, resolution=512, decimate=40000, texture=1024):
    t0 = time.time()
    res = call("fal-ai/trellis-2", {"image_url": image_url, "resolution": resolution, "seed": 7, "texture_size": texture,
                                    "decimation_target": decimate, "remesh": True})
    fetch(res["model_glb"]["url"], os.path.join(out, name + ".glb"))
    print(f"MODEL {name}: {time.time() - t0:.0f}s -> {out}/{name}.glb ({os.path.getsize(os.path.join(out, name + '.glb')) / 1e6:.1f} MB)", flush=True)


def weapon(out, name):
    img = call("fal-ai/flux/dev", {"prompt": f"{WEAPONS[name]}, {STYLE}", "image_size": "square_hd", "num_inference_steps": 28,
                                   "num_images": 1, "seed": 5, "output_format": "jpeg"})
    url = img["images"][0]["url"]
    fetch(url, os.path.join(out, name + ".jpg"))
    model_from(out, name, url, resolution=512, decimate=20000, texture=1024)


if __name__ == "__main__":
    # gen3d.py <out> [props...] | gen3d.py hero-concepts <out> <hero...> | gen3d.py hero-model <out> <hero> <seed>
    # | gen3d.py weapon <out> <weapon...>
    if sys.argv[1] == "hero-concepts":
        out = sys.argv[2]; os.makedirs(out, exist_ok=True)
        for n in sys.argv[3:] or list(HEROES): hero_concepts(out, n)       # heroes or BOSSES keys
    elif sys.argv[1] == "hero-model":
        out, n, sd = sys.argv[2], sys.argv[3], sys.argv[4]
        model_from(out, n, json.load(open(os.path.join(out, f"{n}_concepts.json")))[sd])
    elif sys.argv[1] == "weapon":
        out = sys.argv[2]; os.makedirs(out, exist_ok=True)
        for n in sys.argv[3:] or list(WEAPONS): weapon(out, n)
    else:
        out = sys.argv[1]
        os.makedirs(out, exist_ok=True)
        for n in sys.argv[2:] or list(ASSETS):
            gen(out, n)
