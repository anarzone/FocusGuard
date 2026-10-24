#!/usr/bin/env python3
"""Draws the extension's PNG icons (store/extension-page icons and the
toolbar's default glyph) from the shield used everywhere else.

    python3 scripts/make-icons.py      # needs Pillow

The toolbar glyph is redrawn live by src/lib/icon.js; these are only what
shows before the background has run.
"""
from pathlib import Path

from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parent.parent / "icons"
INDIGO = (97, 85, 245, 255)
TILE = (221, 216, 255, 255)
WHITE = (255, 255, 255, 255)
GREY = (142, 142, 147, 255)


def cubic(p0, p1, p2, p3, steps=24):
    for i in range(1, steps + 1):
        t = i / steps
        u = 1 - t
        yield (u**3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t**3 * p3[0],
               u**3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t**3 * p3[1])


def shield_points():
    """The shield path from the canvas, in 16-unit glyph space."""
    pts = [(8.0, 1.6), (13.1, 3.7), (13.1, 7.4)]
    pts += cubic((13.1, 7.4), (13.1, 10.5), (11.0, 13.2), (8.0, 14.4))
    pts += cubic((8.0, 14.4), (5.0, 13.2), (2.9, 10.5), (2.9, 7.4))
    pts += [(2.9, 3.7)]
    return pts


def app_icon(size):
    """A light indigo tile with a white shield half filled with indigo."""
    ss = 8
    big = size * ss
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    pad = big * 0.125 if size >= 48 else 0  # store icons keep a margin
    tile = big - 2 * pad
    d.rounded_rectangle([pad, pad, pad + tile, pad + tile], radius=tile * 0.23, fill=TILE)
    scale = tile / 16 * 0.78
    off = pad + (tile - 16 * scale) / 2
    pts = [(off + x * scale, off + y * scale) for x, y in shield_points()]
    d.polygon(pts, fill=WHITE)
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).polygon(pts, fill=255)
    fill_top = off + 5.9 * scale
    band = Image.new("L", (big, big), 0)
    ImageDraw.Draw(band).rectangle([0, fill_top, big, big], fill=255)
    from PIL import ImageChops
    img.paste(Image.new("RGBA", (big, big), INDIGO), (0, 0), ImageChops.multiply(mask, band))
    return img.resize((size, size), Image.LANCZOS)


def toolbar_glyph(size):
    """The ready outline in mid grey, readable on light and dark toolbars."""
    ss = 8
    big = size * ss
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    scale = big / 16
    pts = [(x * scale, y * scale) for x, y in shield_points()]
    d.line(pts + [pts[0]], fill=GREY, width=int(1.4 * scale), joint="curve")
    return img.resize((size, size), Image.LANCZOS)


def main():
    OUT.mkdir(exist_ok=True)
    for size in (16, 32, 48, 128):
        app_icon(size).save(OUT / f"icon{size}.png")
    for size in (16, 32):
        toolbar_glyph(size).save(OUT / f"toolbar{size}.png")
    print("wrote", ", ".join(sorted(p.name for p in OUT.glob("*.png"))))


if __name__ == "__main__":
    main()
