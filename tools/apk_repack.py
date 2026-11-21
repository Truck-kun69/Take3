"""Shrink an exported APK without touching what is in it, before it is aligned and signed again.

    python3 tools/apk_repack.py <in.apk> <out.apk> [--cache DIR]

Godot's Android exporter stores .ctex (and .scn) entries uncompressed so they can be memory-mapped, and
deflates everything else with zlib. For this game that leaves about 11 MB of ETC2 ground textures stored
raw. This rewrites the APK entry by entry, byte-identical contents:
  - stored assets/**.ctex are deflated when that saves at least 3% (ETC2 blocks shrink 10-90%);
    Godot reads them through the Android asset manager, which inflates them on open;
  - deflated entries of 1 MB or more (the engine library, classes.dex) are recompressed with zopfli,
    a slower search for a smaller standard deflate stream (about 4% smaller), when the `zopfli` Python
    package is installed; the result is cached under --cache by the entry's SHA-256, since the engine
    library only changes with the Godot version;
  - everything else (resources.arsc, the manifest, res/, other assets) is copied as it was, stored or
    deflated; the old signature (META-INF/*.SF / .RSA / .MF and the APK signing block) is dropped.
The output is unaligned and unsigned: run zipalign -p 4 and apksigner sign on it (tools/build_android.sh).
"""
import hashlib
import os
import struct
import sys
import zipfile
import zlib

try:
    import zopfli.zlib as _zopfli
except ImportError:                       # zlib only: the engine library is left as Godot deflated it
    _zopfli = None

MIN_GAIN = 0.03
ZOPFLI_MIN = 1 << 20


def _deflate(data):
    c = zlib.compressobj(9, zlib.DEFLATED, -15, 9)
    return c.compress(data) + c.flush()


def _zopfli_deflate(data, cache):
    key = hashlib.sha256(data).hexdigest()
    path = os.path.join(cache, key + ".deflate") if cache else ""
    if path and os.path.exists(path):
        with open(path, "rb") as f:
            return f.read()
    out = _zopfli.compress(data, numiterations=1)[2:-4]        # zlib stream -> raw deflate
    assert zlib.decompress(out, -15) == data
    if path:
        os.makedirs(cache, exist_ok=True)
        with open(path + ".tmp", "wb") as f:
            f.write(out)
        os.replace(path + ".tmp", path)
    return out


def repack(src, dst, cache=""):
    zin = zipfile.ZipFile(src)
    entries = []
    report = {"ctex": [0, 0], "zopfli": [0, 0]}
    for info in zin.infolist():
        name = info.filename
        if name.startswith("META-INF/") and name.rsplit(".", 1)[-1].upper() in ("SF", "RSA", "DSA", "EC", "MF"):
            continue
        data = zin.read(name)
        method, payload = info.compress_type, None
        if method == zipfile.ZIP_STORED:
            payload = data
            if name.startswith("assets/") and name.endswith(".ctex") and len(data) > 4096:
                d = _deflate(data)
                if len(d) <= len(data) * (1.0 - MIN_GAIN):
                    report["ctex"][0] += len(data); report["ctex"][1] += len(d)
                    method, payload = zipfile.ZIP_DEFLATED, d
        elif method == zipfile.ZIP_DEFLATED:
            with open(src, "rb") as f:                      # the entry's own deflate stream, as exported
                f.seek(info.header_offset)
                h = f.read(30)
                n, e = struct.unpack("<HH", h[26:30])
                f.seek(info.header_offset + 30 + n + e)
                payload = f.read(info.compress_size)
            if _zopfli is not None and len(data) >= ZOPFLI_MIN:
                z = _zopfli_deflate(data, cache)
                if len(z) < len(payload):
                    report["zopfli"][0] += len(payload); report["zopfli"][1] += len(z)
                    payload = z
        else:
            raise SystemExit(f"{name}: compression method {method} not handled")
        entries.append((info, method, payload, zlib.crc32(data) & 0xFFFFFFFF, len(data)))

    with open(dst, "wb") as out:
        central = b""
        for info, method, payload, crc, size in entries:
            name = info.filename.encode("utf-8")
            flags = 0x800 if any(c > 127 for c in name) else 0
            dos_time = (info.date_time[3] << 11) | (info.date_time[4] << 5) | (info.date_time[5] // 2)
            dos_date = ((info.date_time[0] - 1980) << 9) | (info.date_time[1] << 5) | info.date_time[2]
            offset = out.tell()
            out.write(struct.pack("<IHHHHHIIIHH", 0x04034B50, 20, flags, method, dos_time, dos_date, crc, len(payload), size, len(name), 0))
            out.write(name)
            out.write(payload)
            central += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, info.create_version | (info.create_system << 8), 20, flags, method,
                                   dos_time, dos_date, crc, len(payload), size, len(name), 0, 0, 0, info.internal_attr,
                                   info.external_attr, offset) + name
        cd_offset = out.tell()
        out.write(central)
        out.write(struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(entries), len(entries), len(central), cd_offset, 0))
    # the rewritten archive must hold exactly what the exported one did
    zout = zipfile.ZipFile(dst)
    assert zout.testzip() is None
    kept = [i for i in zin.infolist() if not (i.filename.startswith("META-INF/") and i.filename.rsplit(".", 1)[-1].upper() in ("SF", "RSA", "DSA", "EC", "MF"))]
    assert [i.filename for i in zout.infolist()] == [i.filename for i in kept]
    for a, b in zip(kept, zout.infolist()):
        assert a.CRC == b.CRC and a.file_size == b.file_size, a.filename
    return report


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    cache = ""
    if "--cache" in sys.argv:
        cache = sys.argv[sys.argv.index("--cache") + 1]
        args.remove(cache)
    src, dst = args[0], args[1]
    r = repack(src, dst, cache)
    c, z = r["ctex"], r["zopfli"]
    print(f"repack: textures {c[0] / 1e6:.2f} -> {c[1] / 1e6:.2f} MB deflated; "
          + (f"zopfli {z[0] / 1e6:.2f} -> {z[1] / 1e6:.2f} MB" if _zopfli is not None else "zopfli not installed (pip install zopfli)")
          + f"; {os.path.getsize(src) / 1e6:.2f} -> {os.path.getsize(dst) / 1e6:.2f} MB before alignment and signing")


if __name__ == "__main__":
    main()
