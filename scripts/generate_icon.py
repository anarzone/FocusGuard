#!/usr/bin/env python3
"""
Render a polished AppIcon for FocusGuard.

Design intent:
  • macOS-style squircle (super-ellipse n≈5)
  • Clean vertical gradient: vibrant azure top → deep cobalt bottom
  • Subtle top inner-light (gives a glassy curvature read without a 'stain')
  • Crisp white shield, slightly elevated with a tight drop shadow
  • Single accent stripe down the shield centre (pulse/heartbeat motif —
    a nod to "tracking" and the menu-bar dot)

Output:
  Writes 10 PNGs into FocusGuard/Resources/Assets.xcassets/AppIcon.appiconset/
"""

from PIL import Image, ImageDraw, ImageFilter
import os
import math

ASSET_DIR = os.path.join(
    os.path.dirname(__file__), "..",
    "FocusGuard/Resources/Assets.xcassets/AppIcon.appiconset"
)

SIZES = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

# Colour palette
TOP    = (0x5A, 0xC8, 0xFA)   # systemBlue.lighter — sky azure
BOTTOM = (0x00, 0x32, 0xA0)   # deep cobalt
ACCENT = (0x34, 0xC7, 0x59)   # systemGreen — focus-state accent
INNER_SHADOW_ALPHA = 60
DROP_SHADOW_ALPHA  = 90


def squircle_mask(size: int, n: float = 5.0) -> Image.Image:
    """macOS squircle |x|^n + |y|^n = r^n. Apple uses n≈5 for app icons."""
    mask = Image.new("L", (size, size), 0)
    px = mask.load()
    cx = cy = (size - 1) / 2
    r = size / 2
    for y in range(size):
        ny = abs(y - cy) / r
        if ny > 1:
            continue
        if ny ** n > 1:
            continue
        for x in range(size):
            nx = abs(x - cx) / r
            v = nx ** n + ny ** n
            if v <= 0.97:
                px[x, y] = 255
            elif v <= 1.0:
                # 3% AA band
                px[x, y] = int(255 * (1.0 - v) / 0.03)
    return mask


def vertical_gradient(size: int, top_rgb, bottom_rgb) -> Image.Image:
    """Linear gradient top→bottom."""
    img = Image.new("RGBA", (size, 1))
    px = img.load()
    for x in range(size):
        # single column won't work; do row-major
        pass
    # Build a 1-pixel-wide column then resize horizontally — fast.
    col = Image.new("RGBA", (1, size))
    cpx = col.load()
    for y in range(size):
        t = y / max(1, size - 1)
        r = int(top_rgb[0] + (bottom_rgb[0] - top_rgb[0]) * t)
        g = int(top_rgb[1] + (bottom_rgb[1] - top_rgb[1]) * t)
        b = int(top_rgb[2] + (bottom_rgb[2] - top_rgb[2]) * t)
        cpx[0, y] = (r, g, b, 255)
    return col.resize((size, size), Image.NEAREST)


def shield_polygon(size: int, scale: float = 1.0):
    """
    Stylized shield silhouette inscribed in the squircle.
    Width ~ 52% of icon, height ~ 66%. Slightly upward-biased so the pointed
    bottom doesn't feel cramped.
    """
    cx = size / 2
    cy = size * 0.50
    w = size * 0.52 * scale
    h = size * 0.66 * scale
    top    = (cx,                       cy - h / 2)
    luc    = (cx - w / 2,               cy - h / 2 + h * 0.05)
    lmc    = (cx - w / 2 + w * 0.06,    cy + h * 0.20)
    bottom = (cx,                       cy + h / 2)
    rmc    = (cx + w / 2 - w * 0.06,    cy + h * 0.20)
    ruc    = (cx + w / 2,               cy - h / 2 + h * 0.05)
    return [top, luc, lmc, bottom, rmc, ruc]


def render(size: int) -> Image.Image:
    mask = squircle_mask(size)

    # ── Layer 1: vertical gradient base ──────────────────────────────────
    base = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    grad = vertical_gradient(size, TOP, BOTTOM)
    base.paste(grad, (0, 0), mask)

    # ── Layer 2: top inner light (very subtle) ───────────────────────────
    light = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ld = ImageDraw.Draw(light)
    ld.ellipse(
        [(-size * 0.4, -size * 0.55), (size * 1.4, size * 0.30)],
        fill=(255, 255, 255, 55),
    )
    light = light.filter(ImageFilter.GaussianBlur(size * 0.04))
    light_masked = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    light_masked.paste(light, (0, 0), mask)
    base = Image.alpha_composite(base, light_masked)

    # ── Layer 3: bottom inner shadow (slight depth, NOT a smear) ─────────
    inner = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    id_ = ImageDraw.Draw(inner)
    id_.ellipse(
        [(-size * 0.3, size * 0.75), (size * 1.3, size * 1.6)],
        fill=(0, 0, 0, INNER_SHADOW_ALPHA),
    )
    inner = inner.filter(ImageFilter.GaussianBlur(size * 0.05))
    inner_masked = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    inner_masked.paste(inner, (0, 0), mask)
    base = Image.alpha_composite(base, inner_masked)

    # ── Layer 4: shield drop shadow ──────────────────────────────────────
    pts = shield_polygon(size)
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).polygon(pts, fill=(0, 0, 0, DROP_SHADOW_ALPHA))
    shadow = shadow.filter(ImageFilter.GaussianBlur(size * 0.018))
    offset = max(1, int(size * 0.010))
    shadow_off = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow_off.paste(shadow, (0, offset))
    shadow_masked = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow_masked.paste(shadow_off, (0, 0), mask)
    base = Image.alpha_composite(base, shadow_masked)

    # ── Layer 5: shield body (white with very faint vertical gradient) ───
    shield_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(shield_layer).polygon(pts, fill=(255, 255, 255, 255))

    # Add a tiny vertical fade so the shield isn't dead-flat white.
    fade = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    fd = ImageDraw.Draw(fade)
    for y in range(size):
        t = y / max(1, size - 1)
        # Top: pure white. Bottom: 96% white.
        a = int(0 + 24 * t)  # darkening alpha
        fd.line([(0, y), (size, y)], fill=(0, 0, 0, a))
    # Mask the fade by the shield polygon.
    shield_only = Image.new("L", (size, size), 0)
    ImageDraw.Draw(shield_only).polygon(pts, fill=255)
    fade_masked = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    fade_masked.paste(fade, (0, 0), shield_only)
    shield_layer = Image.alpha_composite(shield_layer, fade_masked)

    base = Image.alpha_composite(base, shield_layer)

    # ── Layer 6: accent vertical pulse line (subtle focus motif) ─────────
    cx = size / 2
    line_w = max(2, int(size * 0.018))
    line_top = size * 0.28
    line_bot = size * 0.72
    pulse = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pd = ImageDraw.Draw(pulse)
    pd.rounded_rectangle(
        [(cx - line_w / 2, line_top), (cx + line_w / 2, line_bot)],
        radius=line_w / 2,
        fill=(*ACCENT, 230),
    )
    # Soft halo behind the pulse to lift it visually.
    halo = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    hd = ImageDraw.Draw(halo)
    hd.rounded_rectangle(
        [(cx - line_w * 1.6, line_top - line_w * 0.6),
         (cx + line_w * 1.6, line_bot + line_w * 0.6)],
        radius=line_w * 1.6,
        fill=(*ACCENT, 80),
    )
    halo = halo.filter(ImageFilter.GaussianBlur(line_w * 1.0))
    base = Image.alpha_composite(base, halo)
    base = Image.alpha_composite(base, pulse)

    # ── Layer 7: top highlight gloss on the shield ───────────────────────
    gloss = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(gloss)
    gd.ellipse(
        [(size * 0.22, size * 0.10), (size * 0.78, size * 0.42)],
        fill=(255, 255, 255, 140),
    )
    gloss = gloss.filter(ImageFilter.GaussianBlur(size * 0.04))
    # Confine gloss to inside the shield silhouette.
    gloss_masked = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gloss_masked.paste(gloss, (0, 0), shield_only)
    base = Image.alpha_composite(base, gloss_masked)

    return base


ICNS_PATH = os.path.join(
    os.path.dirname(__file__), "..",
    "FocusGuard/Resources/AppIcon.icns"
)


def build_icns(master: Image.Image) -> None:
    """
    Write a complete .icns directly via Apple's `iconutil` from a temp iconset.
    Why: the asset-catalog compiler dropped chunks ic08/09/10/14 in our build,
    leaving Quick Look + Finder without large-size renditions. iconutil produces
    a properly-formed icns with every chunk; macOS's IconServices is happy.
    """
    import subprocess, tempfile

    iconset_sizes = [
        (16,   "icon_16x16.png"),
        (32,   "icon_16x16@2x.png"),
        (32,   "icon_32x32.png"),
        (64,   "icon_32x32@2x.png"),
        (128,  "icon_128x128.png"),
        (256,  "icon_128x128@2x.png"),
        (256,  "icon_256x256.png"),
        (512,  "icon_256x256@2x.png"),
        (512,  "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]
    with tempfile.TemporaryDirectory() as tmp:
        iconset_dir = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset_dir)
        for size, name in iconset_sizes:
            img = master if size == 1024 else master.resize((size, size), Image.LANCZOS)
            img.save(os.path.join(iconset_dir, name))
        os.makedirs(os.path.dirname(ICNS_PATH), exist_ok=True)
        subprocess.run(
            ["iconutil", "-c", "icns", iconset_dir, "-o", ICNS_PATH],
            check=True
        )
    print(f"Wrote complete icns to {ICNS_PATH}")


def main():
    print("Rendering 1024 master…")
    master = render(1024)

    # Asset catalog PNGs (kept for Xcode compatibility / future tooling).
    seen = {}
    for size, name in SIZES:
        if size not in seen:
            seen[size] = master if size == 1024 else master.resize((size, size), Image.LANCZOS)
        seen[size].save(os.path.join(ASSET_DIR, name))
    print(f"Wrote {len(SIZES)} asset-catalog PNGs to {ASSET_DIR}")

    # Authoritative .icns — this is what gets baked into the .app bundle.
    build_icns(master)


if __name__ == "__main__":
    main()
