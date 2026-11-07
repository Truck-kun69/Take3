#!/usr/bin/env python3
"""Generate Shardfall's art kit (deterministic, re-runnable):

  godot/ui/logo.png          the SHARDFALL logo: forged-bronze Roman capitals with bevel, fractures and
                              an ember glow, a falling rift crystal behind, and the RIFT SURVIVORS subtitle
  tools/emblem.png           the falling-shard emblem (source of godot/icon.png)
  godot/icon.png             512x512 app icon
  godot/ui/panel.png         9-slice panel: dark weathered slate with a double bronze rim and corner filigree
  godot/ui/btn_*.png         9-slice buttons: normal, hover (ember glow), pressed (inset), disabled
  godot/ui/card.png          9-slice card frame (neutral silver, tinted per rarity/type in Godot)
  godot/ui/tile.png          9-slice selectable tile (hero / stage tiles)
  godot/ui/divider.png       ornamental rule with a centre diamond
  godot/ui/orb_frame.png     ring frame for the HUD globes
  godot/ui/slot.png          action-bar slot frame
  godot/ui/bar.png           9-slice frame for boss / xp bars

    python3 tools/make_art.py
"""
import math
import pathlib
import random

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
FONTS = ROOT / "godot" / "fonts"
OUT = ROOT / "godot" / "ui"
OUT.mkdir(parents=True, exist_ok=True)
rng = random.Random(7)
np_rng = np.random.default_rng(7)

BRONZE_D = (58, 38, 20)
BRONZE = (150, 104, 52)
BRONZE_L = (226, 182, 108)
GOLD_HI = (255, 236, 186)
SLATE = (17, 16, 20)
SLATE_L = (34, 31, 36)
EMBER = (255, 112, 40)
RIFT = (120, 210, 255)
RIFT_V = (176, 120, 255)


def font(name, size):
    return ImageFont.truetype(str(FONTS / name), size)


def arr(img):
    return np.asarray(img, dtype=np.float32) / 255.0


def to_img(a, mode="RGBA"):
    return Image.fromarray(np.clip(a * 255.0, 0, 255).astype(np.uint8), mode)


def noise(w, h, scale, octaves=4, seed=0):
    """Smooth value noise in [0, 1] (bilinear upsampled random grids)."""
    r = np.random.default_rng(seed)
    out = np.zeros((h, w), np.float32)
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        gw, gh = max(2, int(w / scale) + 2), max(2, int(h / scale) + 2)
        g = Image.fromarray((r.random((gh, gw)) * 255).astype(np.uint8), "L").resize((w, h), Image.BICUBIC)
        out += arr(g) * amp
        tot += amp
        amp *= 0.5
        scale /= 2.0
    return out / tot


def bevel(mask, depth=6.0, light=(-0.6, -0.8), blur=4):
    """Lighting from a blurred alpha mask: >0 lit edges, <0 shaded edges."""
    m = arr(mask.filter(ImageFilter.GaussianBlur(blur)))
    gy, gx = np.gradient(m)
    return np.clip(-(gx * light[0] + gy * light[1]) * depth, -1, 1)


def glow(mask, radius, color, strength=1.0):
    g = arr(mask.filter(ImageFilter.GaussianBlur(radius))) * strength
    out = np.zeros(g.shape + (4,), np.float32)
    out[..., 0], out[..., 1], out[..., 2] = color[0] / 255, color[1] / 255, color[2] / 255
    out[..., 3] = np.clip(g, 0, 1)
    return to_img(out)


def metal_fill(mask, top, mid, bot, hi, grain=0.08, seed=1):
    """Forged metal: vertical tri-gradient across the glyph band, brushed streaks, grain, bevel light."""
    w, h = mask.size
    a = arr(mask)
    ys = np.where(a.max(axis=1) > 0.1)[0]
    y0, y1 = (ys.min(), ys.max()) if len(ys) else (0, h)
    t = np.clip((np.arange(h)[:, None] - y0) / max(1, (y1 - y0)), 0, 1).repeat(w, axis=1)
    top, mid, bot, hi = [np.array(c, np.float32) / 255 for c in (top, mid, bot, hi)]
    col = np.where((t < 0.45)[..., None], top + (mid - top) * (t / 0.45)[..., None],
                   mid + (bot - mid) * ((t - 0.45) / 0.55)[..., None])
    col += (hi - col) * (np.exp(-((t - 0.32) ** 2) / 0.004))[..., None] * 0.55        # bright horizon band
    streak = noise(w, h, 3, 2, seed)[:, :]
    streak = np.array(Image.fromarray((streak * 255).astype(np.uint8)).resize((w, max(2, h // 18))).resize((w, h)), np.float32) / 255
    col *= (1 - grain) + grain * 2 * streak[..., None]
    b = bevel(mask, 9.0, blur=3)
    col += (b * 0.75)[..., None] * np.where((b > 0)[..., None], 1.0 - col, col)
    out = np.dstack([np.clip(col, 0, 1), a])
    return to_img(out)


def fractures(draw_size, mask, count, seed):
    """Dark hairline cracks clipped to the glyphs."""
    r = random.Random(seed)
    w, h = draw_size
    cr = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(cr)
    for _ in range(count):
        x, y = r.uniform(0, w), r.uniform(h * 0.2, h * 0.8)
        ang = r.uniform(0, math.tau)
        pts = [(x, y)]
        for _ in range(r.randint(3, 7)):
            ang += r.uniform(-0.9, 0.9)
            ln = r.uniform(6, 26) * w / 1600
            x, y = x + math.cos(ang) * ln, y + math.sin(ang) * ln
            pts.append((x, y))
        d.line(pts, fill=255, width=max(1, int(2 * w / 1600)))
    return ImageChops.multiply(cr, mask)


def crystal(w, h, cx, cy, length, width, tilt, seed):
    """A faceted rift crystal (long bipyramid) with internal glow, as an RGBA layer."""
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    ca, sa = math.cos(tilt), math.sin(tilt)
    def P(u, v):
        return (cx + u * ca - v * sa, cy + u * sa + v * ca)
    top, bot = P(0, -length * 0.62), P(0, length * 0.38)
    l, rgt = P(-width / 2, -length * 0.06), P(width / 2, -length * 0.06)
    lc, rc = P(-width * 0.18, length * 0.02), P(width * 0.2, -length * 0.1)
    facets = [
        ([top, l, lc], (70, 120, 210)), ([top, lc, rc], (150, 220, 255)), ([top, rc, rgt], (100, 150, 240)),
        ([bot, l, lc], (40, 60, 140)), ([bot, lc, rc], (90, 140, 230)), ([bot, rc, rgt], (60, 80, 170)),
    ]
    for pts, c in facets:
        d.polygon(pts, fill=c + (255,))
    for a, b in [(top, l), (top, rgt), (bot, l), (bot, rgt), (top, lc), (top, rc), (lc, rc), (bot, lc), (bot, rc)]:
        d.line([a, b], fill=(220, 245, 255, 200), width=max(1, int(w / 700)))
    core = Image.new("L", (w, h), 0)
    ImageDraw.Draw(core).ellipse([cx - width * 0.22, cy - length * 0.18, cx + width * 0.22, cy + length * 0.08], fill=255)
    layer = Image.alpha_composite(layer, glow(core, w / 120, (235, 250, 255), 1.2))
    return layer


# ============================================================================ logo
def make_logo():
    W, H = 2400, 1150
    canvas = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    # rift crystal falling behind the word, with a light trail and fragments (art pass 1: was clipped and thin)
    cx, cy = W * 0.5, H * 0.47
    trail = Image.new("L", (W, H), 0)
    td = ImageDraw.Draw(trail)
    for i in range(36):
        k = i / 35
        tx, ty = cx - 230 + 230 * k, cy - 470 + 300 * k
        td.ellipse([tx - 8 - 30 * k, ty - 10, tx + 8 + 30 * k, ty + 10], fill=int(150 * k))
    canvas = Image.alpha_composite(canvas, glow(trail, 30, RIFT, 1.0))
    halo = Image.new("L", (W, H), 0)
    ImageDraw.Draw(halo).ellipse([cx - 150, cy - 200, cx + 150, cy + 160], fill=255)
    canvas = Image.alpha_composite(canvas, glow(halo, 90, RIFT_V, 0.45))
    canvas = Image.alpha_composite(canvas, glow(halo, 36, RIFT, 0.4))
    canvas = Image.alpha_composite(canvas, crystal(W, H, cx, cy - 10, 700, 210, 0.42, 3))
    frag = ImageDraw.Draw(canvas)
    for i in range(26):
        a = rng.uniform(0, math.tau)
        d = rng.uniform(160, 520)
        x, y = cx + math.cos(a) * d * 1.6, cy + math.sin(a) * d * 0.55
        s = rng.uniform(4, 16)
        frag.polygon([(x, y - s * 1.6), (x + s * 0.6, y), (x, y + s), (x - s * 0.6, y)], fill=(170, 225, 255, int(rng.uniform(90, 220))))
    # the word
    f = font("cinzel-latin-900-normal.woff2", 300)
    word = "SHARDFALL"
    track = 22
    widths = [f.getbbox(ch)[2] - f.getbbox(ch)[0] for ch in word]
    total = sum(widths) + track * (len(word) - 1)
    x0, y0 = (W - total) / 2, H * 0.28
    mask = Image.new("L", (W, H), 0)
    md = ImageDraw.Draw(mask)
    x = x0
    for ch, cw in zip(word, widths):
        bb = f.getbbox(ch)
        md.text((x - bb[0], y0), ch, font=f, fill=255)
        x += cw + track
    big = mask.filter(ImageFilter.MaxFilter(15))
    outline = mask.filter(ImageFilter.MaxFilter(7))
    canvas = Image.alpha_composite(canvas, glow(big, 40, EMBER, 0.75))
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    shadow.putalpha(big.filter(ImageFilter.GaussianBlur(10)).point(lambda v: int(v * 0.9)))
    canvas = Image.alpha_composite(canvas, ImageChops.offset(shadow, 0, 14))
    rim = Image.new("RGBA", (W, H), (14, 9, 6, 255))
    rim.putalpha(outline)
    canvas = Image.alpha_composite(canvas, rim)
    metal = metal_fill(mask, (255, 230, 170), (196, 140, 64), (92, 52, 22), GOLD_HI, grain=0.12, seed=2)
    canvas = Image.alpha_composite(canvas, metal)
    cracks = fractures((W, H), mask, 70, 5)
    crack_layer = Image.new("RGBA", (W, H), (30, 14, 6, 255))
    crack_layer.putalpha(cracks)
    canvas = Image.alpha_composite(canvas, crack_layer)
    ember_crack = Image.new("RGBA", (W, H), (255, 150, 60, 255))
    ember_crack.putalpha(cracks.filter(ImageFilter.GaussianBlur(1.2)).point(lambda v: int(v * 0.45)))
    canvas = Image.alpha_composite(canvas, ember_crack)
    # subtitle flanked by ornamental rules
    sf = font("cinzel-latin-700-normal.woff2", 74)
    sub = "R I F T   S U R V I V O R S"
    sb = sf.getbbox(sub)
    sw = sb[2] - sb[0]
    sy = H * 0.64
    sub_mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(sub_mask).text(((W - sw) / 2 - sb[0], sy), sub, font=sf, fill=255)
    canvas = Image.alpha_composite(canvas, glow(sub_mask.filter(ImageFilter.MaxFilter(5)), 12, (0, 0, 0), 0.9))
    canvas = Image.alpha_composite(canvas, metal_fill(sub_mask, (240, 236, 226), (186, 176, 160), (110, 100, 90), (255, 255, 255), 0.05, 4))
    od = ImageDraw.Draw(canvas)
    ly = sy + (sb[3] - sb[1]) / 2 + sb[1]
    for side in (-1, 1):
        xa = W / 2 + side * (sw / 2 + 40)
        xb = W / 2 + side * (sw / 2 + 420)
        od.line([(xa, ly), (xb, ly)], fill=BRONZE_L + (230,), width=4)
        od.line([(xa, ly + 9), (xb - side * 90, ly + 9)], fill=BRONZE + (170,), width=2)
        for xx, s in ((xa - side * 2, 15), (xb, 11)):
            od.polygon([(xx, ly - s), (xx + s, ly), (xx, ly + s), (xx - s, ly)], fill=BRONZE_L + (255,), outline=BRONZE_D + (255,))
    bbox = canvas.getbbox()
    canvas = canvas.crop((max(0, bbox[0] - 30), max(0, bbox[1] - 30), min(W, bbox[2] + 30), min(H, bbox[3] + 30)))
    # 1400px is plenty for the title screen (shown at most ~700px wide) and keeps the web build under 16 MB
    canvas.resize((1400, round(1400 * canvas.size[1] / canvas.size[0])), Image.LANCZOS).save(OUT / "logo.png", optimize=True)
    return canvas


# ============================================================================ emblem / icon
def make_emblem(size=512):
    S = size * 2
    im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    c = S / 2
    d.ellipse([S * 0.04, S * 0.04, S * 0.96, S * 0.96], fill=(16, 14, 20, 255))
    ring = Image.new("L", (S, S), 0)
    rd = ImageDraw.Draw(ring)
    rd.ellipse([S * 0.05, S * 0.05, S * 0.95, S * 0.95], outline=255, width=int(S * 0.045))
    rd.ellipse([S * 0.13, S * 0.13, S * 0.87, S * 0.87], outline=255, width=int(S * 0.012))
    for k in range(8):
        a = k * math.tau / 8
        x, y = c + math.cos(a) * S * 0.455, c + math.sin(a) * S * 0.455
        s = S * 0.035
        rd.polygon([(x, y - s), (x + s, y), (x, y + s), (x - s, y)], fill=255)
    im = Image.alpha_composite(im, glow(ring, S / 90, EMBER, 0.6))
    im = Image.alpha_composite(im, metal_fill(ring, (250, 220, 160), (180, 125, 60), (80, 46, 20), GOLD_HI, 0.1, 9))
    halo = Image.new("L", (S, S), 0)
    ImageDraw.Draw(halo).ellipse([c - S * 0.2, c - S * 0.2, c + S * 0.2, c + S * 0.2], fill=255)
    im = Image.alpha_composite(im, glow(halo, S / 14, RIFT_V, 0.6))
    im = Image.alpha_composite(im, crystal(S, S, c, c + S * 0.06, S * 0.62, S * 0.17, 0.18, 4))
    im = im.resize((size, size), Image.LANCZOS)
    im.save(ROOT / "tools" / "emblem.png", optimize=True)     # source for the app icon; not shipped in the game pack
    return im


# ============================================================================ 9-slice frames
def slate(w, h, seed, base=SLATE, light=SLATE_L):
    n = noise(w, h, 40, 5, seed)
    fine = noise(w, h, 3, 2, seed + 1)
    t = np.clip(n * 0.8 + fine * 0.2, 0, 1)
    b, l = np.array(base, np.float32) / 255, np.array(light, np.float32) / 255
    col = b + (l - b) * t[..., None]
    yy, xx = np.mgrid[0:h, 0:w]
    vig = 1.0 - 0.35 * (((xx / w - 0.5) * 2) ** 2 + ((yy / h - 0.5) * 2) ** 2) ** 1.3
    col *= np.clip(vig, 0.55, 1.0)[..., None]
    return to_img(np.dstack([col, np.ones((h, w), np.float32)]))


def rim_mask(w, h, inset, width, notch=0):
    m = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(m)
    if notch:
        n = notch
        pts = [(inset + n, inset), (w - inset - n, inset), (w - inset, inset + n), (w - inset, h - inset - n),
               (w - inset - n, h - inset), (inset + n, h - inset), (inset, h - inset - n), (inset, inset + n)]
        d.polygon(pts, outline=255, width=width)
    else:
        d.rectangle([inset, inset, w - inset - 1, h - inset - 1], outline=255, width=width)
    return m


def bronze_layer(mask, seed, bright=1.0):
    return metal_fill(mask, tuple(int(min(255, c * bright)) for c in BRONZE_L), BRONZE, BRONZE_D, GOLD_HI, 0.12, seed)


def corner_filigree(size, seed):
    """One corner ornament (top-left); mirrored for the others."""
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    s = size
    d.line([(4, s * 0.62), (4, 4), (s * 0.62, 4)], fill=255, width=max(3, s // 18))
    d.arc([s * 0.1, s * 0.1, s * 0.62, s * 0.62], 180, 270, fill=255, width=max(2, s // 26))
    d.polygon([(s * 0.16, s * 0.04), (s * 0.27, s * 0.16), (s * 0.16, s * 0.28), (s * 0.05, s * 0.16)], fill=255)
    d.ellipse([s * 0.13, s * 0.13, s * 0.2, s * 0.2], fill=0)
    for k in range(3):
        r = s * (0.36 + k * 0.1)
        d.line([(r, 4), (r, 4 + s * 0.06)], fill=255, width=2)
        d.line([(4, r), (4 + s * 0.06, r)], fill=255, width=2)
    return m


def make_panel(name="panel.png", W=256, H=256, inset=6, seed=11, corner=84):
    base = slate(W, H, seed)
    d = Image.new("L", (W, H), 0)
    ImageDraw.Draw(d).rectangle([0, 0, W - 1, H - 1], fill=255)
    base.putalpha(d)
    outer = rim_mask(W, H, inset, 5)
    inner = rim_mask(W, H, inset + 10, 2)
    rim = ImageChops.lighter(outer, inner)
    c = corner_filigree(corner, seed)
    for flip_x, flip_y in ((0, 0), (1, 0), (0, 1), (1, 1)):
        cc = c
        if flip_x: cc = cc.transpose(Image.FLIP_LEFT_RIGHT)
        if flip_y: cc = cc.transpose(Image.FLIP_TOP_BOTTOM)
        rim.paste(255, (inset + 2 if not flip_x else W - corner - inset - 2, inset + 2 if not flip_y else H - corner - inset - 2), cc)
    cd = ImageDraw.Draw(rim)                                  # top crest (art pass 1: frame read as generic)
    cx = W / 2
    cd.polygon([(cx - 26, inset), (cx, inset - 4), (cx + 26, inset), (cx, inset + 20)], fill=255)
    cd.line([(cx - 60, inset + 5), (cx + 60, inset + 5)], fill=255, width=3)
    inner_shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    inner_shadow.putalpha(rim_mask(W, H, inset + 12, 14).filter(ImageFilter.GaussianBlur(8)).point(lambda v: int(v * 0.5)))
    out = Image.alpha_composite(base, inner_shadow)
    out = Image.alpha_composite(out, glow(rim, 2, (0, 0, 0), 1.0))
    out = Image.alpha_composite(out, bronze_layer(rim, seed))
    out.save(OUT / name, optimize=True)


def make_buttons(W=192, H=64):
    notch = 10
    for state in ("normal", "hover", "pressed", "disabled"):
        base_col = {"normal": (30, 27, 30), "hover": (44, 30, 24), "pressed": (16, 14, 16), "disabled": (24, 24, 26)}[state]
        light = {"normal": (50, 44, 46), "hover": (78, 48, 32), "pressed": (26, 22, 24), "disabled": (32, 32, 34)}[state]
        body = slate(W, H, 21, base_col, light)
        shape = Image.new("L", (W, H), 0)
        n = notch
        ImageDraw.Draw(shape).polygon([(n + 2, 2), (W - n - 3, 2), (W - 3, n + 2), (W - 3, H - n - 3), (W - n - 3, H - 3), (n + 2, H - 3), (2, H - n - 3), (2, n + 2)], fill=255)
        body.putalpha(shape)
        a = arr(body)
        yy = np.linspace(0, 1, H)[:, None]
        shade = (0.25 - yy * 0.5) if state != "pressed" else (yy * 0.3 - 0.15)
        a[..., :3] = np.clip(a[..., :3] * (1 + shade[..., None] * 0.6), 0, 1)
        body = to_img(a)
        if state == "hover":
            hot = Image.new("L", (W, H), 0)
            ImageDraw.Draw(hot).ellipse([W * 0.1, H * 0.45, W * 0.9, H * 1.4], fill=255)
            hot = ImageChops.multiply(hot, shape)
            body = Image.alpha_composite(body, glow(hot, 14, EMBER, 0.55))
        rim = rim_mask(W, H, 2, 3, notch)
        rim2 = rim_mask(W, H, 7, 1, notch - 4)
        rim = ImageChops.lighter(rim, rim2)
        bright = {"normal": 1.0, "hover": 1.25, "pressed": 0.8, "disabled": 0.55}[state]
        lay = bronze_layer(rim, 23, bright)
        if state == "disabled":
            g = lay.convert("LA").convert("RGBA")
            g.putalpha(lay.getchannel("A"))
            lay = g
        out = Image.alpha_composite(body, lay)
        out.save(OUT / f"btn_{state}.png", optimize=True)


def make_card(W=200, H=280):
    """Neutral silver frame (modulated per card type in Godot) over dark slate, with a top crest."""
    base = slate(W, H, 31, (20, 19, 23), (40, 38, 44))
    rim = ImageChops.lighter(rim_mask(W, H, 4, 4), rim_mask(W, H, 11, 1))
    d = ImageDraw.Draw(rim)
    cx = W / 2
    d.polygon([(cx - 22, 4), (cx, -6 + 4), (cx + 22, 4), (cx, 22)], fill=255)
    d.polygon([(cx - 22, H - 5), (cx, H - 22), (cx + 22, H - 5)], fill=255)
    c = corner_filigree(40, 3)
    for fx, fy in ((0, 0), (1, 0), (0, 1), (1, 1)):
        cc = c.transpose(Image.FLIP_LEFT_RIGHT) if fx else c
        cc = cc.transpose(Image.FLIP_TOP_BOTTOM) if fy else cc
        rim.paste(255, (6 if not fx else W - 46, 6 if not fy else H - 46), cc)
    silver = metal_fill(rim, (250, 250, 250), (180, 180, 186), (90, 90, 98), (255, 255, 255), 0.1, 33)
    out = Image.alpha_composite(base, glow(rim, 2, (0, 0, 0), 1.0))
    out = Image.alpha_composite(out, silver)
    out.save(OUT / "card.png", optimize=True)


def make_tile(W=160, H=120):
    base = slate(W, H, 41, (18, 17, 21), (34, 31, 36))
    rim = ImageChops.lighter(rim_mask(W, H, 3, 3, 8), rim_mask(W, H, 8, 1, 6))
    out = Image.alpha_composite(base, glow(rim, 2, (0, 0, 0), 1.0))
    out = Image.alpha_composite(out, metal_fill(rim, (250, 250, 250), (175, 175, 180), (80, 80, 88), (255, 255, 255), 0.1, 43))
    out.save(OUT / "tile.png", optimize=True)


def make_divider(W=640, H=28):
    m = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(m)
    cy = H / 2
    d.line([(20, cy), (W - 20, cy)], fill=255, width=2)
    d.line([(80, cy + 5), (W / 2 - 30, cy + 5)], fill=180, width=1)
    d.line([(W / 2 + 30, cy + 5), (W - 80, cy + 5)], fill=180, width=1)
    s = 10
    d.polygon([(W / 2, cy - s), (W / 2 + s, cy), (W / 2, cy + s), (W / 2 - s, cy)], fill=255)
    for x in (20, W - 20):
        d.polygon([(x, cy - 5), (x + 5, cy), (x, cy + 5), (x - 5, cy)], fill=255)
    out = Image.alpha_composite(Image.new("RGBA", (W, H), (0, 0, 0, 0)), glow(m, 2, (0, 0, 0), 1))
    out = Image.alpha_composite(out, bronze_layer(m, 51, 1.2))
    out.save(OUT / "divider.png", optimize=True)


def make_orb_frame(S=256):
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    d.ellipse([10, 10, S - 10, S - 10], outline=255, width=12)
    d.ellipse([26, 26, S - 26, S - 26], outline=255, width=2)
    for k in range(4):
        a = k * math.tau / 4 + math.pi / 4
        x, y = S / 2 + math.cos(a) * (S / 2 - 16), S / 2 + math.sin(a) * (S / 2 - 16)
        d.polygon([(x, y - 14), (x + 14, y), (x, y + 14), (x - 14, y)], fill=255)
    out = Image.alpha_composite(Image.new("RGBA", (S, S), (0, 0, 0, 0)), glow(m, 5, (0, 0, 0), 1))
    out = Image.alpha_composite(out, bronze_layer(m, 61, 1.1))
    # glass sheen on the upper left, drawn over the liquid by Godot
    sheen = Image.new("L", (S, S), 0)
    ImageDraw.Draw(sheen).ellipse([S * 0.24, S * 0.16, S * 0.6, S * 0.42], fill=120)
    sheen = sheen.filter(ImageFilter.GaussianBlur(10))
    sl = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    sl.putalpha(sheen)
    out = Image.alpha_composite(out, sl)
    out.save(OUT / "orb_frame.png", optimize=True)


def make_slot(S=96):
    base = slate(S, S, 71, (14, 13, 16), (28, 26, 30))
    rim = ImageChops.lighter(rim_mask(S, S, 3, 4, 10), rim_mask(S, S, 9, 1, 7))
    out = Image.alpha_composite(base, glow(rim, 2, (0, 0, 0), 1))
    out = Image.alpha_composite(out, bronze_layer(rim, 73))
    out.save(OUT / "slot.png", optimize=True)


def make_bar(W=256, H=40):
    base = Image.new("RGBA", (W, H), (8, 6, 8, 220))
    rim = ImageChops.lighter(rim_mask(W, H, 2, 3, 8), rim_mask(W, H, 6, 1, 6))
    out = Image.alpha_composite(base, bronze_layer(rim, 81))
    m = Image.new("L", (W, H), 255)
    ImageDraw.Draw(m).rectangle([0, 0, W - 1, H - 1], fill=255)
    out.save(OUT / "bar.png", optimize=True)


if __name__ == "__main__":
    logo = make_logo()
    logo.resize((760, round(760 * logo.size[1] / logo.size[0])), Image.LANCZOS).save(ROOT / "tools" / "web_logo.png", optimize=True)  # web loading screen
    emb = make_emblem(512)
    icon = emb.resize((512, 512), Image.LANCZOS)
    icon.save(ROOT / "godot" / "icon.png", optimize=True)
    make_panel()
    make_buttons()
    make_card()
    make_tile()
    make_divider()
    make_orb_frame()
    make_slot()
    make_bar()
    print("logo", logo.size, "->", OUT)
