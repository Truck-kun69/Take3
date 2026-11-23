"""Minimal glTF 2.0 binary (.glb) read and write, for the in-place asset fixes (retime_clip, rebake_foe_orm)."""
import json
import struct

GLB_MAGIC = 0x46546C67
JSON_CHUNK = 0x4E4F534A
BIN_CHUNK = 0x004E4942


def load(path):
    """-> (json dict, bytearray of the BIN chunk)."""
    data = open(path, "rb").read()
    magic, version, length = struct.unpack_from("<III", data, 0)
    if magic != GLB_MAGIC or version != 2: raise SystemExit(f"{path}: not a glTF 2.0 binary")
    off, js, binchunk = 12, None, b""
    while off < length:
        clen, ctype = struct.unpack_from("<II", data, off)
        chunk = data[off + 8: off + 8 + clen]
        if ctype == JSON_CHUNK: js = json.loads(chunk.decode("utf-8"))
        elif ctype == BIN_CHUNK: binchunk = chunk
        off += 8 + clen
    return js, bytearray(binchunk)


def save(path, js, binchunk):
    bb = bytes(binchunk) + b"\0" * (-len(binchunk) % 4)
    if js.get("buffers"): js["buffers"][0]["byteLength"] = len(bb)
    jb = json.dumps(js, separators=(",", ":")).encode("utf-8")
    jb += b" " * (-len(jb) % 4)
    total = 12 + 8 + len(jb) + 8 + len(bb)
    out = struct.pack("<III", GLB_MAGIC, 2, total) + struct.pack("<II", len(jb), JSON_CHUNK) + jb + struct.pack("<II", len(bb), BIN_CHUNK) + bb
    open(path, "wb").write(out)


def view_bytes(js, binchunk, bv_index):
    bv = js["bufferViews"][bv_index]
    o = bv.get("byteOffset", 0)
    return bytes(binchunk[o: o + bv["byteLength"]])


def replace_view(js, binchunk, bv_index, data):
    """A new BIN chunk with buffer view `bv_index` holding `data` (any length): every view is copied in offset
    order, 4-byte aligned, and its byteOffset rewritten. Views must not overlap. -> the new bytearray."""
    order = sorted(range(len(js["bufferViews"])), key=lambda i: js["bufferViews"][i].get("byteOffset", 0))
    end = -1
    for i in order:
        bv = js["bufferViews"][i]
        if bv.get("buffer", 0) != 0: raise SystemExit("only single-buffer .glb files are supported")
        if bv.get("byteOffset", 0) < end: raise SystemExit(f"buffer view {i} overlaps the one before it")
        end = bv.get("byteOffset", 0) + bv["byteLength"]
    out = bytearray()
    for i in order:
        bv = js["bufferViews"][i]
        chunk = bytes(data) if i == bv_index else view_bytes(js, binchunk, i)
        out += b"\0" * (-len(out) % 4)
        bv["byteOffset"] = len(out)
        bv["byteLength"] = len(chunk)
        out += chunk
    return out
