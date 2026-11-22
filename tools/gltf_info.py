"""Read .glb / .gltf files without Blender or Godot: the JSON, the scene's bind-pose bounding box, skins,
animations (names and durations) and the textures each material uses.

    python3 tools/gltf_info.py <file.glb|.gltf> [...]       print a summary per file

Used by tools/verify_assets.py and tools/gate_check.py. The bounding box is the scene as a viewer shows it
before any animation: a plain mesh's POSITION min/max corners through its node's world matrix; a skinned
mesh skinned vertex by vertex through its joints' world matrices and inverse bind matrices (glTF: a
skinned mesh's own node transform takes no part).
"""
import json
import math
import os
import struct
import sys

COMP = {5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2), 5123: ("H", 2), 5125: ("I", 4), 5126: ("f", 4)}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16}


def load(path):
    """-> (gltf json, binary buffer 0 or None)."""
    data = open(path, "rb").read()
    if data[:4] == b"glTF":
        length = struct.unpack_from("<I", data, 8)[0]
        off, js, binchunk = 12, None, None
        while off < length:
            clen, ctype = struct.unpack_from("<II", data, off)
            chunk = data[off + 8: off + 8 + clen]
            if ctype == 0x4E4F534A: js = json.loads(chunk.decode("utf-8"))
            elif ctype == 0x004E4942: binchunk = chunk
            off += 8 + clen
        return js, binchunk
    js = json.loads(data.decode("utf-8"))
    binchunk = None
    if js.get("buffers") and "uri" in js["buffers"][0] and not js["buffers"][0]["uri"].startswith("data:"):
        bp = os.path.join(os.path.dirname(path), js["buffers"][0]["uri"])
        if os.path.exists(bp): binchunk = open(bp, "rb").read()
    return js, binchunk


def _mat_mul(a, b):            # column-major 4x4 as flat lists (glTF order)
    return [sum(a[k * 4 + r] * b[c * 4 + k] for k in range(4)) for c in range(4) for r in range(4)]


def _node_matrix(n):
    if "matrix" in n: return list(n["matrix"])
    t = n.get("translation", [0, 0, 0]); r = n.get("rotation", [0, 0, 0, 1]); s = n.get("scale", [1, 1, 1])
    x, y, z, w = r
    rot = [1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w), 0,
           2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w), 0,
           2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y), 0,
           0, 0, 0, 1]
    m = [rot[0] * s[0], rot[1] * s[0], rot[2] * s[0], 0, rot[4] * s[1], rot[5] * s[1], rot[6] * s[1], 0,
         rot[8] * s[2], rot[9] * s[2], rot[10] * s[2], 0, t[0], t[1], t[2], 1]
    return m


def world_matrices(js):
    """node index -> world matrix (flat, column-major), for the default scene."""
    nodes = js.get("nodes", [])
    out = {}
    def walk(i, parent):
        m = _mat_mul(parent, _node_matrix(nodes[i]))
        out[i] = m
        for c in nodes[i].get("children", []): walk(c, m)
    ident = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    scenes = js.get("scenes") or [{"nodes": list(range(len(nodes)))}]
    roots = scenes[js.get("scene", 0)].get("nodes", [])
    for r in roots: walk(r, ident)
    return out


def _xf(m, p):
    return [m[0] * p[0] + m[4] * p[1] + m[8] * p[2] + m[12], m[1] * p[0] + m[5] * p[1] + m[9] * p[2] + m[13],
            m[2] * p[0] + m[6] * p[1] + m[10] * p[2] + m[14]]


def read_accessor(js, binchunk, ai):
    a = js["accessors"][ai]
    fmt, size = COMP[a["componentType"]]
    n = NCOMP[a["type"]]
    bv = js["bufferViews"][a["bufferView"]]
    stride = bv.get("byteStride", size * n)
    base = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    out = []
    for i in range(a["count"]):
        out.append(struct.unpack_from("<" + fmt * n, binchunk, base + i * stride))
    return out


def _np_mat(m):
    import numpy as np
    return np.array(m, dtype=np.float64).reshape(4, 4).T          # column-major list -> row-major 4x4


def bbox(js, binchunk=None):
    """World-space AABB of the scene as written (node transforms, no animation): (min xyz, max xyz) or None.
    Plain meshes: POSITION min/max corners through the node's world matrix. Skinned meshes: every vertex
    skinned exactly (sum of weight x joint world x inverse bind matrix), as a viewer draws the file."""
    import numpy as np
    wm = world_matrices(js)
    lo = [math.inf] * 3; hi = [-math.inf] * 3
    def grow(p):
        for k in range(3):
            lo[k] = min(lo[k], float(p[k])); hi[k] = max(hi[k], float(p[k]))
    for ni, m in wm.items():
        node = js["nodes"][ni]
        if "mesh" not in node: continue
        skin = js["skins"][node["skin"]] if "skin" in node else None
        for prim in js["meshes"][node["mesh"]]["primitives"]:
            att = prim["attributes"]
            if skin is not None and binchunk is not None and "JOINTS_0" in att and "WEIGHTS_0" in att:
                pos = np.array(read_accessor(js, binchunk, att["POSITION"]), dtype=np.float64)
                jnt = np.array(read_accessor(js, binchunk, att["JOINTS_0"]), dtype=np.int64)
                wgt = np.array(read_accessor(js, binchunk, att["WEIGHTS_0"]), dtype=np.float64)
                if js["accessors"][att["WEIGHTS_0"]].get("normalized"):
                    wgt = wgt / {5121: 255.0, 5123: 65535.0}.get(js["accessors"][att["WEIGHTS_0"]]["componentType"], 1.0)
                ibm = read_accessor(js, binchunk, skin["inverseBindMatrices"]) if "inverseBindMatrices" in skin else \
                    [[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]] * len(skin["joints"])
                jm = np.stack([_np_mat(wm.get(j, m)) @ _np_mat(ibm[i]) for i, j in enumerate(skin["joints"])])
                ph = np.concatenate([pos, np.ones((len(pos), 1))], 1)
                out = np.zeros((len(pos), 4))
                for c in range(4):
                    out += wgt[:, c:c + 1] * np.einsum("nij,nj->ni", jm[jnt[:, c]], ph)
                grow(out[:, :3].min(0)); grow(out[:, :3].max(0))
                continue
            pa = js["accessors"][att["POSITION"]]
            if "min" not in pa: continue
            mn, mx = pa["min"], pa["max"]
            for cx in (mn[0], mx[0]):
                for cy in (mn[1], mx[1]):
                    for cz in (mn[2], mx[2]):
                        grow(_xf(m, [cx, cy, cz]))
    if lo[0] == math.inf: return None
    return lo, hi


def animations(js, binchunk=None):
    """[(name, duration seconds)]: duration = the largest sampler input max."""
    out = []
    for an in js.get("animations", []):
        d = 0.0
        for s in an.get("samplers", []):
            a = js["accessors"][s["input"]]
            if "max" in a: d = max(d, float(a["max"][0]))
            elif binchunk is not None: d = max(d, max(v[0] for v in read_accessor(js, binchunk, s["input"])))
        out.append((an.get("name", ""), d))
    return out


def material_textures(js):
    """[(material name, {slot: image size or '?'})] for baseColor / normal / metallicRoughness / occlusion / emissive."""
    out = []
    for m in js.get("materials", []):
        slots = {}
        pbr = m.get("pbrMetallicRoughness", {})
        for slot, ref in (("baseColor", pbr.get("baseColorTexture")), ("metallicRoughness", pbr.get("metallicRoughnessTexture")),
                          ("normal", m.get("normalTexture")), ("occlusion", m.get("occlusionTexture")), ("emissive", m.get("emissiveTexture"))):
            if ref is not None: slots[slot] = ref.get("index")
        out.append((m.get("name", ""), slots))
    return out


def image_size(js, binchunk, tex_index, base_dir=""):
    """(w, h) of a texture's image (PNG/JPEG/WebP header), or None."""
    try:
        src = js["textures"][tex_index].get("source")
        if src is None:
            src = js["textures"][tex_index].get("extensions", {}).get("EXT_texture_webp", {}).get("source")
        img = js["images"][src]
        if "bufferView" in img:
            bv = js["bufferViews"][img["bufferView"]]
            data = binchunk[bv.get("byteOffset", 0): bv.get("byteOffset", 0) + bv["byteLength"]]
        else:
            data = open(os.path.join(base_dir, img["uri"]), "rb").read()
    except Exception:
        return None
    if data[:8] == b"\x89PNG\r\n\x1a\n": return struct.unpack(">II", data[16:24])
    if data[:2] == b"\xff\xd8":
        i = 2
        while i < len(data) - 9:
            if data[i] != 0xFF: i += 1; continue
            marker = data[i + 1]
            if marker in (0xC0, 0xC1, 0xC2):
                h, w = struct.unpack(">HH", data[i + 5: i + 9]); return (w, h)
            i += 2 + struct.unpack(">H", data[i + 2: i + 4])[0]
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        if data[12:16] == b"VP8 ": return (struct.unpack("<H", data[26:28])[0] & 0x3FFF, struct.unpack("<H", data[28:30])[0] & 0x3FFF)
        if data[12:16] == b"VP8L":
            b = struct.unpack("<I", data[21:25])[0]; return ((b & 0x3FFF) + 1, ((b >> 14) & 0x3FFF) + 1)
        if data[12:16] == b"VP8X": return (int.from_bytes(data[24:27], "little") + 1, int.from_bytes(data[27:30], "little") + 1)
    return None


def triangles(js):
    n = 0
    for m in js.get("meshes", []):
        for p in m["primitives"]:
            if "indices" in p: n += js["accessors"][p["indices"]]["count"] // 3
            else: n += js["accessors"][p["attributes"]["POSITION"]]["count"] // 3
    return n


def summary(path):
    js, binchunk = load(path)
    bb = bbox(js, binchunk)
    skins = js.get("skins", [])
    joints = sum(len(s.get("joints", [])) for s in skins)
    mats = material_textures(js)
    tex = []
    for name, slots in mats:
        sizes = {k: image_size(js, binchunk, v, os.path.dirname(path)) for k, v in slots.items()}
        tex.append((name, sizes))
    return {"file": path, "bytes": os.path.getsize(path), "bbox": bb, "height": (bb[1][1] - bb[0][1]) if bb else None,
            "min_y": bb[0][1] if bb else None, "skins": len(skins), "joints": joints, "animations": animations(js, binchunk),
            "materials": tex, "triangles": triangles(js),
            "bones": [js["nodes"][j].get("name", "") for s in skins for j in s.get("joints", [])]}


if __name__ == "__main__":
    for p in sys.argv[1:]:
        s = summary(p)
        bb = s["bbox"]
        print(f"{p}: {s['bytes'] / 1e6:.2f} MB, {s['triangles']} triangles")
        if bb:
            print(f"  bbox min ({bb[0][0]:.3f}, {bb[0][1]:.3f}, {bb[0][2]:.3f}) max ({bb[1][0]:.3f}, {bb[1][1]:.3f}, {bb[1][2]:.3f})"
                  f"  height {s['height']:.3f}  min_y {s['min_y']:.3f}")
        print(f"  skins {s['skins']}, joints {s['joints']}")
        print(f"  animations {[(n, round(d, 2)) for n, d in s['animations']]}")
        for name, sizes in s["materials"]:
            print(f"  material {name!r}: {sizes}")
