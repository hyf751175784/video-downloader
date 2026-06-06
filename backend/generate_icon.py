#!/usr/bin/env python3
"""Generate a macOS-style squircle app icon for Video Downloader."""

import math, os, shutil, subprocess, sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "--quiet",
        "Pillow"], stdout=subprocess.DEVNULL)
    from PIL import Image, ImageDraw, ImageFilter

OUTPUT_DIR = Path(__file__).resolve().parent.parent / "VideoDownloader" / "Resources"
ICONSET = OUTPUT_DIR / "AppIcon.iconset"
ICNS = OUTPUT_DIR / "AppIcon.icns"
PREVIEW = OUTPUT_DIR / "AppIcon.preview.png"


def draw_icon(sz: int) -> Image.Image:
    """Draw the app icon at size x size."""
    m = int(sz * 0.04)  # margin
    r = int(sz * 0.222)  # squircle radius
    im = Image.new("RGBA", (sz, sz), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)

    # Squircle background with a diagonal blue/teal/amber capture wash.
    mask = Image.new("L", (sz, sz), 0)
    ImageDraw.Draw(mask).rounded_rectangle([m, m, sz - m, sz - m], radius=r, fill=255)
    bg = Image.new("RGBA", (sz, sz), (0, 0, 0, 0))
    bd = ImageDraw.Draw(bg)
    for y in range(m, sz - m):
        for x in range(m, sz - m, 2):
            t = ((x - m) + (y - m) * 0.75) / ((sz - 2 * m) * 1.75)
            blue = (31, 84, 182)
            teal = (0, 134, 146)
            amber = (235, 112, 36)
            if t < 0.50:
                k = t / 0.50
                col = tuple(int(blue[i] * (1 - k) + teal[i] * k) for i in range(3))
            else:
                k = (t - 0.50) / 0.50
                col = tuple(int(teal[i] * (1 - k) + amber[i] * k) for i in range(3))
            bd.line([(x, y), (x + 1, y)], fill=(*col, 255))

    # Reader-friendly depth at large sizes, still compact at 16px.
    glow_layer = Image.new("RGBA", (sz, sz), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow_layer)
    gd.ellipse([int(sz * -0.16), int(sz * -0.20), int(sz * 0.78), int(sz * 0.64)],
               fill=(255, 255, 255, 82))
    gd.ellipse([int(sz * 0.56), int(sz * 0.42), int(sz * 1.18), int(sz * 1.08)],
               fill=(255, 182, 86, 30))
    glow_layer = glow_layer.filter(ImageFilter.GaussianBlur(radius=max(1, int(sz * 0.085))))
    bg.alpha_composite(glow_layer)

    beam = Image.new("RGBA", (sz, sz), (0, 0, 0, 0))
    beam_d = ImageDraw.Draw(beam)
    beam_d.polygon([
        (int(sz * 0.08), int(sz * 0.18)),
        (int(sz * 0.90), int(sz * 0.03)),
        (int(sz * 0.98), int(sz * 0.18)),
        (int(sz * 0.18), int(sz * 0.36)),
    ], fill=(255, 255, 255, 34))
    bg.alpha_composite(beam)
    im.paste(bg, (0, 0), mask)

    # Subtle depth and gloss.
    overlay = Image.new("RGBA", (sz, sz), (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    for y in range(m, sz - m):
        ratio = (y - m) / (sz - 2 * m)
        if ratio < 0.4:
            a = int(42 * (1 - ratio / 0.4))
            od.line([(m, y), (sz - m, y)], fill=(255, 255, 255, a))
        elif ratio > 0.65:
            a = int(58 * (ratio - 0.65) / 0.35)
            od.line([(m, y), (sz - m, y)], fill=(0, 0, 0, a))
    im.alpha_composite(overlay)

    alpha = Image.new("L", (sz, sz), 0)
    ImageDraw.Draw(alpha).rounded_rectangle([m, m, sz - m, sz - m], radius=r, fill=255)
    alpha = alpha.filter(ImageFilter.GaussianBlur(radius=1.0))
    im.putalpha(alpha)
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([m + 1, m + 1, sz - m - 1, sz - m - 1],
                        radius=r, outline=(255, 255, 255, 150), width=max(1, int(sz * 0.005)))

    cx, cy = int(sz / 2), int(sz / 2)

    # Capture arcs, hinting at browser/network sniffing.
    arc = Image.new("RGBA", (sz, sz), (0, 0, 0, 0))
    ad = ImageDraw.Draw(arc)
    for i, alpha_v in enumerate([70, 42, 24]):
        pad = int(sz * (0.13 + i * 0.055))
        ad.arc([pad, pad, sz - pad, sz - pad], start=205, end=330,
               fill=(255, 255, 255, alpha_v), width=max(1, int(sz * 0.012)))
    for i, alpha_v in enumerate([56, 34]):
        pad = int(sz * (0.21 + i * 0.07))
        ad.arc([pad, pad, sz - pad, sz - pad], start=30, end=140,
               fill=(0, 238, 220, alpha_v), width=max(1, int(sz * 0.010)))
    for x, y, rr in [
        (cx - int(sz * 0.27), cy - int(sz * 0.22), int(sz * 0.013)),
        (cx + int(sz * 0.30), cy - int(sz * 0.13), int(sz * 0.010)),
        (cx + int(sz * 0.22), cy + int(sz * 0.24), int(sz * 0.012)),
    ]:
        ad.ellipse([x - rr, y - rr, x + rr, y + rr], fill=(255, 255, 255, 88))
    im.alpha_composite(arc)

    card_w, card_h = int(sz * 0.58), int(sz * 0.36)
    card_x0, card_y0 = cx - card_w // 2, cy - int(sz * 0.24)
    card_x1, card_y1 = card_x0 + card_w, card_y0 + card_h

    shadow = Image.new("RGBA", (sz, sz), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle([card_x0, card_y0 + int(sz * 0.035), card_x1, card_y1 + int(sz * 0.035)],
                         radius=int(sz * 0.055), fill=(0, 0, 0, 95))
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=max(2, int(sz * 0.018))))
    im.alpha_composite(shadow)

    # Player glass.
    d.rounded_rectangle([card_x0, card_y0, card_x1, card_y1],
                        radius=int(sz * 0.055), fill=(246, 252, 252, 255))
    d.rounded_rectangle([card_x0, card_y0, card_x1, card_y1],
                        radius=int(sz * 0.055), outline=(255, 255, 255, 255),
                        width=max(1, int(sz * 0.008)))
    d.rectangle([card_x0, card_y0, card_x1, card_y0 + int(sz * 0.07)], fill=(24, 33, 42, 255))
    d.line([(card_x0 + int(sz * 0.035), card_y1 - int(sz * 0.058)),
            (card_x1 - int(sz * 0.035), card_y1 - int(sz * 0.058))],
           fill=(218, 232, 232, 255), width=max(1, int(sz * 0.006)))

    # Window dots.
    dot_r = max(1, int(sz * 0.012))
    for i, col in enumerate([(255, 105, 92), (255, 189, 68), (0, 202, 95)]):
        x = card_x0 + int(sz * 0.055) + i * int(sz * 0.04)
        y = card_y0 + int(sz * 0.035)
        d.ellipse([x - dot_r, y - dot_r, x + dot_r, y + dot_r], fill=col)

    # Play triangle.
    tri = [
        (cx - int(sz * 0.045), cy - int(sz * 0.155)),
        (cx - int(sz * 0.045), cy - int(sz * 0.035)),
        (cx + int(sz * 0.065), cy - int(sz * 0.095)),
    ]
    d.polygon(tri, fill=(11, 118, 126, 255))
    d.polygon([
        (cx - int(sz * 0.030), cy - int(sz * 0.130)),
        (cx - int(sz * 0.030), cy - int(sz * 0.060)),
        (cx + int(sz * 0.032), cy - int(sz * 0.095)),
    ], fill=(50, 154, 160, 255))

    # Fragment track.
    seg_y = cy + int(sz * 0.045)
    seg_h = int(sz * 0.052)
    seg_gap = int(sz * 0.012)
    seg_w = int((card_w - sz * 0.18) / 5)
    start_x = cx - (seg_w * 5 + seg_gap * 4) // 2
    for i in range(5):
        x0 = start_x + i * (seg_w + seg_gap)
        color = (26, 93, 188, 255) if i < 2 else (0, 134, 146, 255) if i < 4 else (235, 112, 36, 255)
        d.rounded_rectangle([x0, seg_y, x0 + seg_w, seg_y + seg_h],
                            radius=int(sz * 0.014), fill=color)

    # Small media fragments leave the player and resolve into the download.
    frag = Image.new("RGBA", (sz, sz), (0, 0, 0, 0))
    fd = ImageDraw.Draw(frag)
    for i, (fx, fy, col) in enumerate([
        (0.31, 0.56, (255, 255, 255, 150)),
        (0.40, 0.61, (83, 220, 207, 160)),
        (0.59, 0.59, (255, 255, 255, 138)),
        (0.69, 0.55, (255, 173, 86, 150)),
    ]):
        x = int(sz * fx)
        y = int(sz * fy)
        w = int(sz * (0.030 - i * 0.002))
        fd.rounded_rectangle([x - w, y - w // 2, x + w, y + w // 2],
                             radius=max(1, int(sz * 0.006)), fill=col)
    frag = frag.filter(ImageFilter.GaussianBlur(radius=max(0.2, sz * 0.0015)))
    im.alpha_composite(frag)

    # Download arrow below the player with a compact success tray.
    sw = max(3, int(sz * 0.026))
    arrow_top = cy + int(sz * 0.115)
    arrow_tip = cy + int(sz * 0.265)
    d.line([(cx, arrow_top), (cx, arrow_tip - int(sz * 0.035))],
           fill=(255, 255, 255, 255), width=sw)
    d.line([
        (cx - int(sz * 0.055), arrow_tip - int(sz * 0.08)),
        (cx, arrow_tip),
        (cx + int(sz * 0.055), arrow_tip - int(sz * 0.08)),
    ], fill=(255, 255, 255, 255), width=sw)
    tray_y = arrow_tip + int(sz * 0.04)
    d.rounded_rectangle([cx - int(sz * 0.13), tray_y - int(sz * 0.020),
                         cx + int(sz * 0.13), tray_y + int(sz * 0.020)],
                        radius=int(sz * 0.020), fill=(255, 255, 255, 235))
    d.rounded_rectangle([cx - int(sz * 0.07), tray_y - int(sz * 0.006),
                         cx + int(sz * 0.07), tray_y + int(sz * 0.006)],
                        radius=int(sz * 0.006), fill=(0, 134, 146, 210))

    # Compatibility check badge.
    badge_cx = cx + int(sz * 0.205)
    badge_cy = cy + int(sz * 0.255)
    badge_r = int(sz * 0.052)
    d.ellipse([badge_cx - badge_r, badge_cy - badge_r,
               badge_cx + badge_r, badge_cy + badge_r],
              fill=(20, 190, 129, 242), outline=(255, 255, 255, 190),
              width=max(1, int(sz * 0.007)))
    d.line([
        (badge_cx - int(sz * 0.020), badge_cy),
        (badge_cx - int(sz * 0.005), badge_cy + int(sz * 0.018)),
        (badge_cx + int(sz * 0.027), badge_cy - int(sz * 0.022)),
    ], fill=(255, 255, 255, 255), width=max(1, int(sz * 0.010)))

    # Vignette.
    v_alpha = Image.new("L", (sz, sz), 0)
    v_pix = v_alpha.load()
    max_dist = math.sqrt((sz / 2) ** 2 + (sz / 2) ** 2)
    inner_frac = 0.65

    for y in range(m, sz - m):
        dy = y - sz / 2
        for x in range(m, sz - m):
            dx = x - sz / 2
            dist = math.sqrt(dx * dx + dy * dy) / max_dist
            if dist > inner_frac:
                a = int(min(50, 80 * (dist - inner_frac) / (1.0 - inner_frac)))
                v_pix[x, y] = a

    vignette = Image.new("RGBA", (sz, sz), (0, 0, 0, 0))
    vignette.putalpha(v_alpha)
    im.alpha_composite(vignette)

    return im


sz_map = {
    16: ["icon_16x16.png"],
    32: ["icon_16x16@2x.png", "icon_32x32.png"],
    64: ["icon_32x32@2x.png"],
    128: ["icon_128x128.png"],
    256: ["icon_128x128@2x.png", "icon_256x256.png"],
    512: ["icon_256x256@2x.png", "icon_512x512.png"],
    1024: ["icon_512x512@2x.png"],
}

if __name__ == "__main__":
    print("🎨 App Icon Generator\n")
    ICONSET.mkdir(parents=True, exist_ok=True)
    rendered = {}
    for sz, names in sz_map.items():
        if sz not in rendered:
            print(f"  {sz}×{sz}", end="  ", flush=True)
            rendered[sz] = draw_icon(sz)
            print("✓")
        for name in names:
            rendered[sz].save(ICONSET / name, "PNG")
    rendered[1024].save(PREVIEW, "PNG")

    n = len(list(ICONSET.glob("*.png")))
    print(f"\n  📁 {n} sizes → AppIcon.icns")
    try:
        subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS)],
                       check=True, capture_output=True)
    except subprocess.CalledProcessError:
        # Some stripped-down macOS toolchains reject valid iconsets. Pillow can
        # write a standards-compatible icns from the 1024 px master image.
        rendered[1024].save(ICNS, format="ICNS", sizes=[(16, 16), (32, 32), (64, 64),
                                                        (128, 128), (256, 256),
                                                        (512, 512), (1024, 1024)])
    print(f"  ✅ {os.path.getsize(ICNS)/1024:.0f} KB  →  {ICNS}")
    print(f"  🖼️  Preview →  {PREVIEW}")
    shutil.rmtree(ICONSET)
    print("  Done\n")
