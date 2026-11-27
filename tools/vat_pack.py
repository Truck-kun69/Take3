"""Pack Shardfall vertex animation textures (godot/models/foes/*.vat) into the compact SVA3 format.

    python3 tools/vat_pack.py [files...]          convert SVAT or SVA2 files in place (default: every foe .vat)
    python3 tools/vat_pack.py --stats [files...]  print what a conversion would do, write nothing

SVAT (what tools/blender/import_packs.py bakes): per vertex per row 8 bytes of RGBA float16 position
(the alpha is always 0) and 4 bytes of RGBA8 normal; clips sampled at 12 to 30 fps.
SVA2 (the previous shipped form): positions RGB float16, normals octahedral RG8, deflated.
SVA3 (what the game loads, Models.foe_vat):
    "SVA3", u16 verts, u16 rows, u16 clips, u16 0, u32 body size before compression
    f32 x 3 position minimum, f32 x 3 position extent (the clip set's bounding box, Godot axes)
    per clip, 20 bytes: 8-byte name, u16 first row, u16 frames, f32 fps, u8 loop, 3 pad   (as SVAT)
    body, zlib (deflate):
      positions rows*verts RGBA8: each axis quantised to 10 bits over the bounding box, q = round((p - min)
        / extent * 1023); R, G, B = the top 8 bits of x, y, z; A = the low 2 bits of x | y << 2 | z << 4.
        One texel per vertex per row, decoded in foe.gdshader (vat_p): one fetch, as before.
      normals rows*verts RG8, octahedral at 7 bits per axis (each byte = round(k * 255 / 127), k 0..127).
Precision: 10 bits over the box is at most 0.07% of a foe's height off (about 0.1 px on a 150 px foe on a
2400 px phone screen); the normals at most about 1.5 degrees.
Clips (SVAT input only) are resampled to at most MAX_FPS, never below MIN_FPS: 24 and 30 fps clips to half
their rate, 15 fps clips to 12 (each clip's duration is kept exactly: its fps is stored as frames /
duration, and a clip that does not loop keeps its first and last frames). Every clip still carries one
extra row (its first frame again when it loops, its last when it does not) so the shader can always
blend row r with r + 1.
"""
import math
import os
import struct
import sys
import zlib

import numpy as np

MAX_FPS = 15.0
MIN_FPS = 12.0
POS_BITS = 10
NRM_BITS = 7
HERE = os.path.dirname(os.path.abspath(__file__))
FOES = os.path.join(os.path.dirname(HERE), "godot", "models", "foes")


def _clip_table(b, o, nc):
    clips = []
    for _ in range(nc):
        name = b[o:o + 8].split(b"\0")[0].decode()
        first, frames, fps, loop = struct.unpack_from("<HHfB", b, o + 8)
        clips.append([name, first, frames, fps, loop])
        o += 20
    return clips, o


def read_svat(b):
    assert b[:4] == b"SVAT", "not an SVAT file"
    nv, rows, nc = struct.unpack_from("<HHH", b, 4)
    clips, o = _clip_table(b, 12, nc)
    pos = np.frombuffer(b, dtype="<f2", count=rows * nv * 4, offset=o).reshape(rows, nv, 4)[..., :3].astype(np.float32)
    nrm = np.frombuffer(b, dtype=np.uint8, count=rows * nv * 4, offset=o + rows * nv * 8).reshape(rows, nv, 4)[..., :3]
    nrm = nrm.astype(np.float32) / 255.0 * 2.0 - 1.0
    nrm /= np.maximum(1e-6, np.linalg.norm(nrm, axis=-1, keepdims=True))      # 8-bit storage left them 0.99..1.01 long
    return nv, clips, pos, nrm


def read_sva2(b):
    assert b[:4] == b"SVA2", "not an SVA2 file"
    nv, rows, nc, _, raw = struct.unpack_from("<4HI", b, 4)
    clips, o = _clip_table(b, 16, nc)
    body = zlib.decompress(b[o:])
    assert len(body) == raw == rows * nv * 8
    pos = np.frombuffer(body, dtype="<f2", count=rows * nv * 3).reshape(rows, nv, 3).astype(np.float32)
    nrm = oct_decode(np.frombuffer(body, dtype=np.uint8, offset=rows * nv * 6).reshape(rows, nv, 2), 8)
    return nv, clips, pos, nrm


def read_sva3(b):
    """The decoded positions and normals of an SVA3 file (what the shader reconstructs)."""
    assert b[:4] == b"SVA3", "not an SVA3 file"
    nv, rows, nc, _, raw = struct.unpack_from("<4HI", b, 4)
    lo = np.array(struct.unpack_from("<3f", b, 16), dtype=np.float32)
    ext = np.array(struct.unpack_from("<3f", b, 28), dtype=np.float32)
    clips, o = _clip_table(b, 40, nc)
    body = zlib.decompress(b[o:])
    assert len(body) == raw == rows * nv * 6
    px = np.frombuffer(body, dtype=np.uint8, count=rows * nv * 4).reshape(rows, nv, 4).astype(np.uint32)
    a = px[..., 3]
    q = px[..., :3] * 4 + np.stack([a & 3, (a >> 2) & 3, (a >> 4) & 3], -1)
    pos = lo + q.astype(np.float32) / 1023.0 * ext
    nrm = oct_decode(np.frombuffer(body, dtype=np.uint8, offset=rows * nv * 4).reshape(rows, nv, 2), 8)
    return nv, clips, pos, nrm


def target_fps(fps):
    if fps >= 2.0 * MIN_FPS: return fps * 0.5          # 24 -> 12, 30 -> 15
    if fps > MAX_FPS: return MAX_FPS
    if fps > MIN_FPS: return MIN_FPS                    # 15 -> 12
    return fps                                         # 12 and below: as baked


def resample(frames_p, frames_n, fps, loop):
    """frames_*: the clip's own rows (without its extra row). Returns new rows and the stored fps."""
    cnt = len(frames_p)
    want = target_fps(fps)
    if want >= fps or cnt < 3:
        return frames_p, frames_n, fps
    if loop:                                          # a cycle of cnt frames, cnt / fps seconds long
        k = max(2, math.ceil(cnt * want / fps - 1e-6))           # rounded up: never below the target rate
        t = np.arange(k) * (cnt / k)
        new_fps = k * fps / cnt
    else:                                             # first to last frame, (cnt - 1) / fps seconds
        k = max(2, math.ceil((cnt - 1) * want / fps - 1e-6) + 1)
        t = np.arange(k) * ((cnt - 1) / (k - 1))
        new_fps = (k - 1) * fps / (cnt - 1)
    i0 = np.floor(t).astype(int)
    f = (t - i0)[:, None, None]
    i1 = (i0 + 1) % cnt if loop else np.minimum(i0 + 1, cnt - 1)
    i0 = np.minimum(i0, cnt - 1)
    p = frames_p[i0] * (1.0 - f) + frames_p[i1] * f
    n = frames_n[i0] * (1.0 - f) + frames_n[i1] * f
    n /= np.maximum(1e-6, np.linalg.norm(n, axis=-1, keepdims=True))
    return p, n, new_fps


def oct_encode(n, bits=8):
    """Unit normals -> octahedral RG8 at `bits` per axis (Models.foe_vat / foe.gdshader decode e / 255)."""
    n = n / np.maximum(1e-6, np.abs(n).sum(-1, keepdims=True))
    x, y, z = n[..., 0], n[..., 1], n[..., 2]
    sx = np.where(x >= 0.0, 1.0, -1.0)
    sy = np.where(y >= 0.0, 1.0, -1.0)
    ox = np.where(z < 0.0, (1.0 - np.abs(y)) * sx, x)
    oy = np.where(z < 0.0, (1.0 - np.abs(x)) * sy, y)
    top = (1 << bits) - 1
    k = np.clip(np.round((np.stack([ox, oy], -1) * 0.5 + 0.5) * top), 0, top)
    return np.round(k * 255.0 / top).astype(np.uint8)


def oct_decode(e, bits=8):
    f = e.astype(np.float32) / 255.0 * 2.0 - 1.0
    v = np.stack([f[..., 0], f[..., 1], 1.0 - np.abs(f[..., 0]) - np.abs(f[..., 1])], -1)
    t = np.clip(-v[..., 2], 0.0, None)
    v[..., 0] += np.where(v[..., 0] >= 0.0, -t, t)
    v[..., 1] += np.where(v[..., 1] >= 0.0, -t, t)
    return v / np.linalg.norm(v, axis=-1, keepdims=True)


def encode_pos(P):
    """Positions (rows x verts x 3) -> (RGBA8 texels, minimum, extent)."""
    flat = P.reshape(-1, 3)
    lo = flat.min(0).astype(np.float32)
    ext = np.maximum(flat.max(0) - lo, 1e-6).astype(np.float32)
    q = np.clip(np.round((P - lo) / ext * 1023.0), 0, 1023).astype(np.uint32)
    px = np.empty(P.shape[:2] + (4,), dtype=np.uint8)
    px[..., :3] = q >> 2
    px[..., 3] = (q[..., 0] & 3) | ((q[..., 1] & 3) << 2) | ((q[..., 2] & 3) << 4)
    return px, lo, ext


def write_sva3(nv, table, P, Nrm):
    """table: (name, first row, rows, fps, loop) per clip; P, Nrm: rows x verts x 3. Returns bytes, errors."""
    px, lo, ext = encode_pos(P)
    N = oct_encode(Nrm, NRM_BITS)
    body = px.tobytes() + N.tobytes()
    out = b"SVA3" + struct.pack("<4HI", nv, len(P), len(table), 0, len(body))
    out += struct.pack("<3f", *lo) + struct.pack("<3f", *ext)
    for name, first2, cnt, f2, loop in table:
        out += name.encode().ljust(8, b"\0") + struct.pack("<2Hf4B", first2, cnt, f2, 1 if loop else 0, 0, 0, 0)
    out += zlib.compress(body, 9)
    # what the shader will reconstruct, against what went in
    _, _, P3, N3 = read_sva3(out)
    perr = float(np.abs(P3 - P).max() / max(1e-6, float(ext[1])))                # of the box's height
    nerr = float(np.degrees(np.arccos(np.clip((N3 * Nrm).sum(-1), -1.0, 1.0))).max())
    return out, perr, nerr


def pack(nv, clips, pos, nrm):
    """SVAT data -> SVA3 bytes (and a report): clips resampled, then quantised."""
    rows_p, rows_n, table, desc = [], [], [], []
    for name, first, frames, fps, loop in clips:
        p, n, f2 = resample(pos[first:first + frames], nrm[first:first + frames], fps, loop)
        first2 = sum(len(r) for r in rows_p)
        extra = 0 if loop else len(p) - 1
        rows_p.append(np.concatenate([p, p[extra:extra + 1]]))
        rows_n.append(np.concatenate([n, n[extra:extra + 1]]))
        table.append((name, first2, len(p), f2, loop))
        desc.append(f"{name} {frames}@{fps:.0f}->{len(p)}@{f2:.1f}")
    P = np.concatenate(rows_p).astype(np.float32)
    N = np.concatenate(rows_n)
    out, perr, nerr = write_sva3(nv, table, P, N)
    return out, desc, len(P), perr, nerr


def repack_sva2(b):
    """An SVA2 file (already resampled) -> SVA3 bytes: the same rows and clips, requantised."""
    nv, clips, P, N = read_sva2(b)
    table = [(c[0], c[1], c[2], c[3], c[4]) for c in clips]
    out, perr, nerr = write_sva3(nv, table, P, N)
    return out, [f"{c[0]} {c[2]}@{c[3]:.1f}" for c in clips], len(P), perr, nerr


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    stats = "--stats" in sys.argv
    files = args or sorted(os.path.join(FOES, f) for f in os.listdir(FOES) if f.endswith(".vat"))
    tot_in = tot_out = 0
    for path in files:
        b = open(path, "rb").read()
        if b[:4] == b"SVAT":
            nv = struct.unpack_from("<H", b, 4)[0]
            out, desc, rows, perr, nerr = pack(*read_svat(b))
        elif b[:4] == b"SVA2":
            nv = struct.unpack_from("<H", b, 4)[0]
            out, desc, rows, perr, nerr = repack_sva2(b)
        else:
            print(f"{os.path.basename(path)}: already {b[:4].decode(errors='replace')}, skipped")
            continue
        tot_in += len(b)
        tot_out += len(out)
        print(f"{os.path.basename(path):14s} {nv:5d} verts, {rows:3d} rows, {len(b) / 1024:7.1f} KB -> {len(out) / 1024:6.1f} KB  "
              f"position error <= {100.0 * perr:.3f}% of its height, normal <= {nerr:.1f} deg  [{', '.join(desc)}]")
        if not stats:
            with open(path, "wb") as f:
                f.write(out)
    if tot_in:
        print(f"total {tot_in / 1e6:.3f} MB -> {tot_out / 1e6:.3f} MB ({100.0 * (1.0 - tot_out / tot_in):.1f}% smaller)")


if __name__ == "__main__":
    main()
