"""Pack Shardfall vertex animation textures (godot/models/foes/*.vat) into the compact SVA2 format.

    python3 tools/vat_pack.py [files...]          convert SVAT files in place (default: every foe .vat)
    python3 tools/vat_pack.py --stats [files...]  print what a conversion would do, write nothing

SVAT (what tools/blender/import_packs.py bakes): per vertex per row 8 bytes of RGBA float16 position
(the alpha is always 0) and 4 bytes of RGBA8 normal; clips sampled at 12 to 30 fps.
SVA2 (what the game loads, Models.foe_vat):
    "SVA2", u16 verts, u16 rows, u16 clips, u16 0, u32 body size before compression
    per clip, 20 bytes: 8-byte name, u16 first row, u16 frames, f32 fps, u8 loop, 3 pad   (as SVAT)
    body, zlib (deflate): positions rows*verts RGB float16, then normals rows*verts RG8, octahedral
Clips are resampled to at most MAX_FPS, never below MIN_FPS: 24 and 30 fps clips to half their rate,
15 fps clips to 12 (each clip's duration is kept exactly: its fps is stored as frames / duration, and a
clip that does not loop keeps its first and last frames). Every clip still carries one extra row (its
first frame again when it loops, its last when it does not) so the shader can always blend row r with r + 1.
"""
import math
import os
import struct
import sys
import zlib

import numpy as np

MAX_FPS = 15.0
MIN_FPS = 12.0
HERE = os.path.dirname(os.path.abspath(__file__))
FOES = os.path.join(os.path.dirname(HERE), "godot", "models", "foes")


def read_svat(b):
    assert b[:4] == b"SVAT", "not an SVAT file"
    nv, rows, nc = struct.unpack_from("<HHH", b, 4)
    clips = []
    o = 12
    for _ in range(nc):
        name = b[o:o + 8].split(b"\0")[0].decode()
        first, frames, fps, loop = struct.unpack_from("<HHfB", b, o + 8)
        clips.append([name, first, frames, fps, loop])
        o += 20
    pos = np.frombuffer(b, dtype="<f2", count=rows * nv * 4, offset=o).reshape(rows, nv, 4)[..., :3].astype(np.float32)
    nrm = np.frombuffer(b, dtype=np.uint8, count=rows * nv * 4, offset=o + rows * nv * 8).reshape(rows, nv, 4)[..., :3]
    nrm = nrm.astype(np.float32) / 255.0 * 2.0 - 1.0
    nrm /= np.maximum(1e-6, np.linalg.norm(nrm, axis=-1, keepdims=True))      # 8-bit storage left them 0.99..1.01 long
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


def oct_encode(n):
    """Unit normals -> octahedral RG8 (Models.foe_vat / foe.gdshader decode them)."""
    n = n / np.maximum(1e-6, np.abs(n).sum(-1, keepdims=True))
    x, y, z = n[..., 0], n[..., 1], n[..., 2]
    sx = np.where(x >= 0.0, 1.0, -1.0)
    sy = np.where(y >= 0.0, 1.0, -1.0)
    ox = np.where(z < 0.0, (1.0 - np.abs(y)) * sx, x)
    oy = np.where(z < 0.0, (1.0 - np.abs(x)) * sy, y)
    return np.clip(np.round((np.stack([ox, oy], -1) * 0.5 + 0.5) * 255.0), 0, 255).astype(np.uint8)


def oct_decode(e):
    f = e.astype(np.float32) / 255.0 * 2.0 - 1.0
    v = np.stack([f[..., 0], f[..., 1], 1.0 - np.abs(f[..., 0]) - np.abs(f[..., 1])], -1)
    t = np.clip(-v[..., 2], 0.0, None)
    v[..., 0] += np.where(v[..., 0] >= 0.0, -t, t)
    v[..., 1] += np.where(v[..., 1] >= 0.0, -t, t)
    return v / np.linalg.norm(v, axis=-1, keepdims=True)


def pack(nv, clips, pos, nrm):
    """SVAT data -> SVA2 bytes (and a report)."""
    rows_p, rows_n, table = [], [], []
    for name, first, frames, fps, loop in clips:
        p, n, f2 = resample(pos[first:first + frames], nrm[first:first + frames], fps, loop)
        first2 = sum(len(r) for r in rows_p)
        extra = 0 if loop else len(p) - 1
        rows_p.append(np.concatenate([p, p[extra:extra + 1]]))
        rows_n.append(np.concatenate([n, n[extra:extra + 1]]))
        table.append((name, first2, len(p), f2, loop, frames, fps))
    P = np.concatenate(rows_p).astype(np.float16)
    N = oct_encode(np.concatenate(rows_n))
    body = P.tobytes() + N.tobytes()
    out = b"SVA2" + struct.pack("<4HI", nv, len(P), len(table), 0, len(body))
    for name, first2, cnt, f2, loop, _, _ in table:
        out += name.encode().ljust(8, b"\0") + struct.pack("<2Hf4B", first2, cnt, f2, 1 if loop else 0, 0, 0, 0)
    out += zlib.compress(body, 9)
    err = np.degrees(np.arccos(np.clip((oct_decode(N) * np.concatenate(rows_n)).sum(-1), -1.0, 1.0))).max()
    return out, table, len(P), err


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    stats = "--stats" in sys.argv
    files = args or sorted(os.path.join(FOES, f) for f in os.listdir(FOES) if f.endswith(".vat"))
    tot_in = tot_out = 0
    for path in files:
        b = open(path, "rb").read()
        if b[:4] != b"SVAT":
            print(f"{os.path.basename(path)}: already {b[:4].decode(errors='replace')}, skipped")
            continue
        nv, clips, pos, nrm = read_svat(b)
        out, table, rows, err = pack(nv, clips, pos, nrm)
        tot_in += len(b)
        tot_out += len(out)
        desc = ", ".join(f"{t[0]} {t[5]}@{t[6]:.0f}->{t[2]}@{t[3]:.1f}" for t in table)
        print(f"{os.path.basename(path):14s} {nv:5d} verts, rows {len(pos):3d} -> {rows:3d}, {len(b) / 1024:7.1f} KB -> {len(out) / 1024:6.1f} KB  "
              f"normal error <= {err:.1f} deg  [{desc}]")
        if not stats:
            with open(path, "wb") as f:
                f.write(out)
    if tot_in:
        print(f"total {tot_in / 1e6:.3f} MB -> {tot_out / 1e6:.3f} MB ({100.0 * (1.0 - tot_out / tot_in):.1f}% smaller)")


if __name__ == "__main__":
    main()
