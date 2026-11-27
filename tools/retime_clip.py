"""Stretch one animation of a .glb to a whole-frame length, in place, without Blender.

    python3 tools/retime_clip.py godot/models/heroes/warden.glb cast --min 0.65 [--fps 24]

0.10.0: process_fal_assets.trim_window used to cut on fractional frames, and the exporter rounded three
heroes' casts (warden, spark, ember) down to 15 frames at 24 fps = 0.625 s, under the 0.65 s a cast needs to
read. The pipeline now snaps to whole frames (pipeline_math.snap_window: ceil(0.65 x 24) = 16 frames), but
re-running it needs tools/.fal_raw/ and Blender. This applies the same result to the shipped files: every
keyframe time of the clip scales by target / length, target = ceil(min x fps) / fps (16 frames, 0.667 s), so
the motion is the same, 6.7% slower. Only that clip changes: its time (input) accessors are written as new
accessors at the end of the binary chunk, because the exporter shares identical time tracks between clips
(the 16-key 0.625 s track is the cast's, the run's and the roll's at once). A clip already at least `min`
long is left alone (exit 0, "unchanged"), so running it twice is harmless.
"""
import argparse
import math
import struct
import sys

from glb_io import load, save

FLOAT = 5126


def read_times(js, binchunk, ai):
    acc = js["accessors"][ai]
    if acc["componentType"] != FLOAT or acc["type"] != "SCALAR": raise SystemExit(f"accessor {ai}: not float scalar times")
    bv = js["bufferViews"][acc["bufferView"]]
    if bv.get("buffer", 0) != 0: raise SystemExit(f"accessor {ai}: times outside the binary chunk")
    stride = bv.get("byteStride", 4)
    base = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    return [struct.unpack_from("<f", binchunk, base + i * stride)[0] for i in range(acc["count"])]


def clip_length(js, binchunk, anim):
    return max(max(read_times(js, binchunk, s["input"])) for s in anim["samplers"])


def retime(path, name, min_s, fps):
    js, binchunk = load(path)
    anim = next((a for a in js.get("animations", []) if a.get("name") == name), None)
    if anim is None: raise SystemExit(f"{path}: no animation '{name}'")
    if any(s.get("interpolation", "LINEAR") == "CUBICSPLINE" for s in anim["samplers"]):
        raise SystemExit(f"{path}: '{name}' has cubic-spline samplers (their tangents would need rescaling too)")
    length = clip_length(js, binchunk, anim)
    if length >= min_s - 1e-6:
        print(f"{path}: {name} {length:.3f} s, unchanged (>= {min_s:.2f})")
        return length
    target = math.ceil(min_s * fps - 1e-9) / fps
    k = target / length
    new_acc = {}
    for s in anim["samplers"]:
        ai = s["input"]
        if ai not in new_acc:
            t = [round(x * k, 6) for x in read_times(js, binchunk, ai)]
            t[-1] = target if abs(t[-1] - target) < 1e-3 else t[-1]
            binchunk += b"\0" * (-len(binchunk) % 4)
            off = len(binchunk)
            binchunk += struct.pack(f"<{len(t)}f", *t)
            js["bufferViews"].append({"buffer": 0, "byteOffset": off, "byteLength": 4 * len(t)})
            js["accessors"].append({"bufferView": len(js["bufferViews"]) - 1, "componentType": FLOAT, "count": len(t),
                                    "type": "SCALAR", "min": [min(t)], "max": [max(t)]})
            new_acc[ai] = len(js["accessors"]) - 1
        s["input"] = new_acc[ai]
    save(path, js, binchunk)
    js2, bin2 = load(path)
    after = clip_length(js2, bin2, next(a for a in js2["animations"] if a.get("name") == name))
    others = {a["name"]: round(clip_length(js2, bin2, a), 3) for a in js2["animations"] if a.get("name") != name}
    print(f"{path}: {name} {length:.3f} s -> {after:.3f} s ({round(after * fps)} frames at {fps} fps, x{k:.4f}); "
          f"{len(new_acc)} time tracks split off; other clips unchanged: {others}")
    return after


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("glb")
    ap.add_argument("clip")
    ap.add_argument("--min", type=float, required=True, help="shortest length in seconds")
    ap.add_argument("--fps", type=float, default=24.0)
    a = ap.parse_args()
    sys.exit(0 if retime(a.glb, a.clip, a.min, a.fps) >= a.min - 1e-6 else 1)
