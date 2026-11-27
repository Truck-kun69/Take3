"""Rig and animate a generated humanoid with Meshy's auto-rigger, hosted on fal.

    python3 tools/fal/rig.py <out dir> <name> <model.glb> [action ids...]

Sends the GLB inline (data URI), asks for a standard skeleton and up to 10 clips from Meshy's
animation library (ids: docs.meshy.ai/en/api/animation-library), and saves
    <out>/<name>_rigged.glb            the skinned character in its bind pose
    <out>/<name>_walk.glb, _run.glb    the two clips every rig comes with
    <out>/<name>_a<id>.glb             one file per requested clip
Auth as gen3d.py: the cloud session's proxy adds the fal key for fal.run.
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen3d import call, fetch  # noqa: E402


def rig(out, name, glb, ids, height=1.8, template=None):
    os.makedirs(out, exist_ok=True)
    uri = "data:model/gltf-binary;base64," + base64.b64encode(open(glb, "rb").read()).decode()
    payload = {"model_url": uri, "height_meters": height, "enable_safety_checker": False}
    if template: payload["skeleton_template"] = template
    t0 = time.time()
    if ids:
        payload["animation_action_ids"] = [int(i) for i in ids][:10]
        res = call("fal-ai/meshy/rigging/multi-animation", payload, timeout=1500)
    else:
        res = call("fal-ai/meshy/rigging", payload, timeout=1500)
    json.dump(res, open(os.path.join(out, name + "_rig.json"), "w"), indent=1)
    fetch(res["rigged_character_glb"]["url"], os.path.join(out, name + "_rigged.glb"))
    ba = res.get("basic_animations") or {}
    for key, tag in (("walking_glb", "walk"), ("running_glb", "run")):
        if ba.get(key): fetch(ba[key]["url"], os.path.join(out, f"{name}_{tag}.glb"))
    for a in res.get("animations") or []:
        fetch(a["animation_glb"]["url"], os.path.join(out, f"{name}_a{a['action_id']}.glb"))
    print(f"RIG {name}: {time.time() - t0:.0f}s, clips {[a['action_id'] for a in res.get('animations') or []]} -> {out}", flush=True)


if __name__ == "__main__":
    rig(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:])
