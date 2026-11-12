#!/usr/bin/env python3
"""Render the Silverside DMG window background.

Writes background.png (660x400 @72dpi) and background@2x.png (1320x800 @144dpi).
dmgbuild picks up the @2x file automatically and merges both into a HiDPI TIFF.

Scene: the read side of a CD seen at a grazing angle fills the lower third like a
planet's limb; a tilted orbit arcs above it, passing through the two icon slots,
with an arrow riding the orbit from the app to Applications.

The default "light" theme matches the light site (#e6dec9 with faint rings) and
keeps the area behind Finder's icon labels light enough for black text.

Usage: python3 make_dmg_background.py [outdir] [--theme light|dark] [--guides]
  --guides also writes background-guides.png with the label boxes outlined.
It needs numpy and Pillow; make dist does not run it, and uses the PNGs in App/DMG.
"""
import argparse
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

# --- Layout, in points (1x). Keep in sync with dmg_settings.py --------------
W, H = 660, 400
APP_POS = (180, 180)    # icon centres, as dmgbuild's icon_locations
APPS_POS = (480, 180)
ICON = 128
# Finder's labels: centred under each icon, ~13 pt tall, baseline area near y=262
LABELS = [(APP_POS[0], 262, 100), (APPS_POS[0], 262, 80)]   # (cx, cy, width)

DISC_C = (330, 458)     # disc centre (below the window)
DISC_RX, DISC_RY = 520, 175   # disc foreshortened to an ellipse
ORBIT_C = (330, 300)
ORBIT_RX = 300
# Orbit ry chosen so the orbit passes exactly through both icon centres.
_u = (APP_POS[0] - ORBIT_C[0]) / ORBIT_RX
ORBIT_RY = (ORBIT_C[1] - APP_POS[1]) / math.sqrt(1 - _u * _u)

S = 4                   # master supersampling factor relative to 1x
MW, MH = W * S, H * S

ACCENT = [(0x8b, 0x6c, 0xf6), (0x4f, 0x8c, 0xf7), (0x3f, 0xc8, 0xd8),
          (0xf2, 0xb0, 0x5a), (0xf2, 0x6d, 0x8f)]


def hexrgb(h):
    return np.array([int(h[i:i + 2], 16) for i in (1, 3, 5)], float) / 255


THEMES = {
    "light": dict(
        sky_top=hexrgb("#ebe4d1"), sky_low=hexrgb("#e3d9c3"),
        ring=-0.022,                 # rings slightly darker than the sky, like the site
        glow=0.10, glow_mode="tint",
        stars=0,
        disc_base=(0.66, 0.16), disc_sheen=0.10,
        fan_mix=0.42, fan_gain=0.60,
        streak=0.35, rim_tone=hexrgb("#b9ae98"), edge=0.28, edge_dark=0.30,
        corner_shade=0.18,
        orbit=(110, 92, 70, 95), arrow_glow=0.30,
        head_color=ACCENT[-1],
    ),
    "dark": dict(
        sky_top=hexrgb("#13100d"), sky_low=hexrgb("#2b2219"),
        ring=0.018,
        glow=0.16, glow_mode="add",
        stars=38,
        disc_base=(0.27, 0.18), disc_sheen=0.10,
        fan_mix=0.45, fan_gain=0.62,
        streak=0.55, rim_tone=hexrgb("#2b2219") * 0.6, edge=0.45, edge_dark=0.0,
        corner_shade=0.35,
        orbit=(232, 222, 201, 46), arrow_glow=0.55,
        head_color=ACCENT[-1],
    ),
}


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def spectrum(h):
    """Vectorized hue -> RGB."""
    h = np.mod(h, 1.0)
    r = np.clip(np.abs(h * 6 - 3) - 1, 0, 1)
    g = np.clip(2 - np.abs(h * 6 - 2), 0, 1)
    b = np.clip(2 - np.abs(h * 6 - 4), 0, 1)
    return np.stack([r, g, b], -1)


def render_master(th):
    ys, xs = np.mgrid[0:MH, 0:MW].astype(np.float64)
    x = (xs + 0.5) / S
    y = (ys + 0.5) / S

    # Disc-plane coordinates: undo the foreshortening so the disc is a unit circle.
    u = (x - DISC_C[0]) / DISC_RX
    v = (y - DISC_C[1]) / DISC_RY
    r = np.sqrt(u * u + v * v)
    theta = np.arctan2(v, u)            # -pi/2 points straight "up" the screen

    # ---- Sky -----------------------------------------------------------------
    t = smoothstep(0, H * 0.85, y)[..., None]
    img = th["sky_top"] * (1 - t) + th["sky_low"] * t
    # concentric rings in the same perspective as the disc (site motif)
    ring = 0.5 + 0.5 * np.cos(r * DISC_RX / 22 * 2 * np.pi)
    ring = smoothstep(0.92, 1.0, ring) * smoothstep(1.0, 1.15, r) * (1 - smoothstep(1.2, 2.6, r))
    img = img + ring[..., None] * th["ring"]
    # atmosphere: a soft iridescent glow hugging the limb
    glow = np.exp(-np.clip(r - 1.0, 0, None) / 0.07) * (r > 1.0)
    gh = 0.62 + (theta + np.pi / 2) * 0.22
    gcol = spectrum(gh) * 0.55 + 0.45
    if th["glow_mode"] == "add":
        img = img + glow[..., None] * gcol * th["glow"]
    else:   # tint toward the pastel colour without darkening
        a = (glow * th["glow"] * 2.2)[..., None]
        img = img * (1 - a) + (0.5 * img + 0.5 * gcol) * a
    rng = np.random.default_rng(7)
    for _ in range(th["stars"]):
        sx, sy = rng.uniform(10, W - 10), rng.uniform(8, H * 0.6)
        if math.hypot(sx - APP_POS[0], sy - APP_POS[1]) < 95: continue
        if math.hypot(sx - APPS_POS[0], sy - APPS_POS[1]) < 95: continue
        a = rng.uniform(0.04, 0.16)
        d2 = ((x - sx) ** 2 + (y - sy) ** 2)
        img = img + (np.exp(-d2 / (2 * 0.45 ** 2)) * a)[..., None]

    # ---- Disc surface ----------------------------------------------------------
    b0, b1 = th["disc_base"]
    base = b0 + b1 * smoothstep(0.35, 0.98, r) + th["disc_sheen"] * smoothstep(0.90, 0.96, r)
    surf = np.stack([base * 1.01, base * 0.995, base * 0.97], -1)
    # specular streak toward the viewer + diffraction fans either side, in
    # spectral order outward: violet -> blue -> green -> yellow -> red, then a fainter 2nd order
    d = theta + np.pi / 2
    ad = np.abs(d)
    streak = np.exp(-(ad / 0.035) ** 2) * smoothstep(0.38, 0.9, r)
    o1 = smoothstep(0.06, 0.12, ad) * (1 - smoothstep(0.62, 0.78, ad))
    o2 = 0.5 * smoothstep(0.80, 0.90, ad) * (1 - smoothstep(1.35, 1.55, ad))
    fan = o1 + o2
    pos1 = np.clip((ad - 0.09) / 0.62, 0, 1)
    pos2 = np.clip((ad - 0.85) / 0.62, 0, 1)
    hue = np.where(ad < 0.80, 0.78 - 0.78 * pos1, 0.78 - 0.78 * pos2) + (r - 0.7) * 0.10
    irid = spectrum(hue)
    fan_amt = (0.55 * fan * smoothstep(0.3, 0.7, r))[..., None]
    surf = surf * (1 - fan_amt * th["fan_mix"]) + irid * fan_amt * th["fan_gain"]
    surf = surf + streak[..., None] * th["streak"]
    # track grooves and the lead-out boundary
    grooves = 0.5 + 0.5 * np.sin(r * DISC_RY * 2 * np.pi / 2.6)
    surf = surf * (1 - 0.035 * grooves[..., None])
    leadout = smoothstep(0.885, 0.895, r) * (1 - smoothstep(0.955, 0.965, r))
    surf = surf * (1 - 0.08 * leadout[..., None])
    # clear polycarbonate rim, then a polished edge (with a thin dark line on light skies)
    rim = smoothstep(0.962, 0.972, r)[..., None]
    surf = surf * (1 - 0.55 * rim) + rim * th["rim_tone"] * 0.55
    edge = np.exp(-((r - 0.993) / 0.0045) ** 2)[..., None]
    surf = surf + edge * th["edge"]
    outline = np.exp(-((r - 1.0) / 0.004) ** 2)[..., None]
    surf = surf * (1 - outline * th["edge_dark"])
    shade = 1 - th["corner_shade"] * smoothstep(0.55, 1.0, np.abs(u))
    surf = surf * shade[..., None]

    aa = np.clip((1.0 - r) * DISC_RY * S, 0, 1)[..., None]   # antialiased limb
    img = img * (1 - aa) + surf * aa
    return np.clip(img, 0, 1), r


def orbit_point(t):
    return (ORBIT_C[0] + ORBIT_RX * math.cos(t), ORBIT_C[1] + ORBIT_RY * math.sin(t))


def angle_at_x(px):
    return 2 * math.pi - math.acos((px - ORBIT_C[0]) / ORBIT_RX)   # upper half


def lerp_color(stops, f):
    f = min(max(f, 0), 1) * (len(stops) - 1)
    i = min(int(f), len(stops) - 2)
    a, b = stops[i], stops[i + 1]
    k = f - i
    return tuple(int(a[j] + (b[j] - a[j]) * k) for j in range(3))


def draw_overlays(img_arr, disc_r, th):
    base = Image.fromarray((img_arr * 255 + 0.5).astype(np.uint8), "RGB")
    layer = Image.new("RGBA", (MW, MH), (0, 0, 0, 0))
    dr = ImageDraw.Draw(layer)

    # faint full orbit (dashed), hidden where it passes over the disc
    n = 720
    for i in range(n):
        if i % 6 >= 3:
            continue
        p0 = orbit_point(2 * math.pi * i / n)
        p1 = orbit_point(2 * math.pi * (i + 1) / n)
        dr.line([(p0[0] * S, p0[1] * S), (p1[0] * S, p1[1] * S)],
                fill=th["orbit"], width=int(1.1 * S))
    mask_disc = (disc_r > 0.985) * 255
    layer.putalpha(Image.fromarray(np.minimum(np.array(layer.getchannel("A")),
                                              mask_disc).astype(np.uint8)))

    # the arrow: a gradient arc along the orbit from app to Applications
    gap = ICON / 2 + 16
    ta = angle_at_x(APP_POS[0] + gap)
    tb = angle_at_x(APPS_POS[0] - gap)
    head_len = 15
    tb_shaft = tb - (head_len * 0.6) / math.hypot(ORBIT_RX, ORBIT_RY) * 1.4
    steps = 400
    pts_shaft = [orbit_point(ta + (tb_shaft - ta) * i / steps) for i in range(steps + 1)]
    shaft = Image.new("L", (MW, MH), 0)
    ImageDraw.Draw(shaft).line([(px * S, py * S) for px, py in pts_shaft],
                               fill=255, width=int(3.2 * S), joint="curve")
    x0, x1 = pts_shaft[0][0] * S, orbit_point(tb)[0] * S
    grad = np.zeros((MH, MW, 4), np.uint8)
    f = np.clip((np.arange(MW) - x0) / (x1 - x0), 0, 1)
    grad[..., :3] = np.array([lerp_color(ACCENT, fi) for fi in f], np.uint8)[None]
    fade = np.clip(0.25 + f * 2.5, 0, 1)                 # fade in from the app side
    grad[..., 3] = (np.array(shaft, np.float32) * fade[None, :]).astype(np.uint8)
    arrow = Image.fromarray(grad, "RGBA")
    da = ImageDraw.Draw(arrow)
    tip = orbit_point(tb)
    tx, ty = -ORBIT_RX * math.sin(tb), ORBIT_RY * math.cos(tb)
    L = math.hypot(tx, ty); tx, ty = tx / L, ty / L
    nx, ny = -ty, tx
    w = 8.5
    back = (tip[0] - tx * head_len, tip[1] - ty * head_len)
    notch = (tip[0] - tx * head_len * 0.72, tip[1] - ty * head_len * 0.72)
    pts = [tip, (back[0] + nx * w, back[1] + ny * w), notch,
           (back[0] - nx * w, back[1] - ny * w)]
    da.polygon([(px * S, py * S) for px, py in pts], fill=th["head_color"] + (255,))

    glow = arrow.filter(ImageFilter.GaussianBlur(5 * S))
    ga = np.array(glow.getchannel("A")).astype(np.float32) * th["arrow_glow"]
    glow.putalpha(Image.fromarray(ga.astype(np.uint8)))

    out = base.convert("RGBA")
    out = Image.alpha_composite(out, layer)
    out = Image.alpha_composite(out, glow)
    out = Image.alpha_composite(out, arrow)
    return out.convert("RGB")


def label_contrast(lo):
    """Worst-case WCAG contrast of black text against each label box."""
    a = np.asarray(lo, float) / 255
    lin = np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)
    Y = lin @ np.array([0.2126, 0.7152, 0.0722])
    res = []
    for cx, cy, w in LABELS:
        box = Y[int(cy - 9):int(cy + 9), int(cx - w / 2 - 6):int(cx + w / 2 + 6)]
        res.append((box.min() + 0.05) / 0.05)   # black text has luminance 0
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("outdir", nargs="?", default=".")
    ap.add_argument("--theme", choices=THEMES, default="light")
    ap.add_argument("--guides", action="store_true")
    args = ap.parse_args()
    th = THEMES[args.theme]
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    arr, r = render_master(th)
    master = draw_overlays(arr, r, th)
    hi = master.resize((W * 2, H * 2), Image.LANCZOS)
    lo = master.resize((W, H), Image.LANCZOS)
    hi.save(outdir / "background@2x.png", dpi=(144, 144), optimize=True)
    lo.save(outdir / "background.png", dpi=(72, 72), optimize=True)
    c = ", ".join(f"{v:.1f}:1" for v in label_contrast(lo))
    print(f"{args.theme}: wrote {outdir}/background.png and background@2x.png; "
          f"black-label contrast (worst pixel) {c}")

    if args.guides:
        g = hi.convert("RGBA")
        d = ImageDraw.Draw(g)
        for cx, cy, w in LABELS:
            d.rectangle(((cx - w / 2) * 2, (cy - 7) * 2, (cx + w / 2) * 2, (cy + 7) * 2),
                        outline=(255, 0, 0, 255), width=2)
        for cx, cy in (APP_POS, APPS_POS):
            d.rectangle(((cx - 64) * 2, (cy - 64) * 2, (cx + 64) * 2, (cy + 64) * 2),
                        outline=(0, 120, 255, 255), width=2)
        g.convert("RGB").save(outdir / "background-guides.png")


if __name__ == "__main__":
    main()
