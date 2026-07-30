#!/usr/bin/env python3
"""Render the Headroom app icon and write every size the catalogs reference.

The icon is the ring glyph itself: three provider bands at 90 / 60 / 30 percent,
same 20% tinted track and round-ended usage arc as `Shared/HeadroomRings.swift`
and `drawPaceRing()` in the firmware. No pace ticks — at icon sizes a hairline
reads as a defect.

The Mac icon sits on Apple's icon grid — an 824-of-1024 rounded square with
transparent margins — because macOS does not round anything for you. A
full-bleed square is drawn as a full-bleed square, which in a Dock of rounded
tiles reads as a bug. iPhone, Watch and the App Store PNG stay square and
opaque: those masks are applied by the system and by App Store Connect, which
rejects alpha outright.

    ./scripts/render_icon.py            # rewrite the catalogs + App Store PNG
    ./scripts/render_icon.py --out /tmp/preview.png   # one file, nothing else
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent

# Canonical geometry, in 1024-pixel units.
SIDE = 1024
BG = (28, 28, 30)
TRACK_MIX = 0.20
THICK = 70
GAP = 40
OUTER_RADIUS = 360

# Apple's macOS icon grid: the artwork occupies 824 of the 1024-pixel canvas and
# the rest is clear. The corner is the continuous "squircle" the Dock, Finder
# and Launchpad all use, approximated by a superellipse of this exponent — near
# enough that no corner reads differently beside a system icon, and a lot less
# machinery than a bezier reconstruction of Apple's curve.
MACOS_TILE = 824
SQUIRCLE_EXPONENT = 5.0

# Accent + percent per band, outside in. The live rings keep provider brand
# accents; the icon uses process CMY so the three arcs stay distinct at every
# catalog size instead of collapsing into muddy terracotta / teal / periwinkle.
BANDS = [
    ((255, 214, 0), 90.0),    # Yellow
    ((0, 200, 220), 60.0),    # Cyan
    ((230, 45, 140), 30.0),   # Magenta
]

# macOS catalog filenames by pixel size. A @2x slot holds twice its nominal
# size, so most pixel sizes serve two names — 256 pixels is both
# icon_256x256.png and icon_128x128@2x.png.
MACOS_ICONS = {
    16: ["icon_16x16.png"],
    32: ["icon_32x32.png", "icon_16x16@2x.png"],
    64: ["icon_32x32@2x.png"],
    128: ["icon_128x128.png"],
    256: ["icon_256x256.png", "icon_128x128@2x.png"],
    512: ["icon_512x512.png", "icon_256x256@2x.png"],
    1024: ["icon_512x512@2x.png"],
}
MACOS_DIR = ROOT / "macos/Assets.xcassets/AppIcon.appiconset"
IOS_ICON = ROOT / "ios/HeadroomMobile/Assets.xcassets/AppIcon.appiconset/HeadroomIcon.png"
WATCH_ICON = ROOT / "watch/HeadroomWatch/Assets.xcassets/AppIcon.appiconset/HeadroomIcon.png"
APPSTORE_ICON = ROOT / "docs/appstore/icon-1024.png"

SUPERSAMPLE = 4


def mix(color, factor):
    """Blend toward the background. Mirror of dimToward() in main.cpp."""
    return tuple(int(round(b + (c - b) * factor)) for c, b in zip(color, BG))


def band(draw, cx, cy, radius, thick, sweep_deg, color):
    """Track plus a round-ended usage arc, drawn as one filled outline."""
    outer = radius
    inner = radius - thick
    draw.ellipse([cx - outer, cy - outer, cx + outer, cy + outer],
                 fill=mix(color, TRACK_MIX))
    draw.ellipse([cx - inner, cy - inner, cx + inner, cy + inner], fill=BG)
    if sweep_deg <= 0:
        return

    mid = radius - thick / 2
    cap = thick / 2
    cap_deg = math.degrees(cap / mid)
    start, end = -90 + cap_deg, -90 + sweep_deg - cap_deg
    if end > start:
        draw.pieslice([cx - outer, cy - outer, cx + outer, cy + outer],
                      start, end, fill=color)
        draw.ellipse([cx - inner, cy - inner, cx + inner, cy + inner], fill=BG)
    else:
        start = end = -90 + sweep_deg / 2
    for angle in (math.radians(start), math.radians(end)):
        px = cx + mid * math.cos(angle)
        py = cy + mid * math.sin(angle)
        draw.ellipse([px - cap, py - cap, px + cap, py + cap], fill=color)


def render(side: int = SIDE) -> Image.Image:
    scale = side * SUPERSAMPLE / SIDE
    canvas = int(SIDE * scale)
    image = Image.new("RGB", (canvas, canvas), BG)
    draw = ImageDraw.Draw(image)
    centre = canvas / 2
    radius = OUTER_RADIUS
    for color, percent in BANDS:
        band(draw, centre, centre, radius * scale, THICK * scale,
             percent * 3.6, color)
        radius -= THICK + GAP
    return image.resize((side, side), Image.LANCZOS)


def squircle_mask(side: int) -> Image.Image:
    """Alpha mask of the continuous rounded square, drawn oversized then down."""
    high = side * SUPERSAMPLE
    mask = Image.new("L", (high, high), 0)
    radius = high / 2
    power = 2.0 / SQUIRCLE_EXPONENT
    points = []
    for step in range(720):
        angle = 2 * math.pi * step / 720
        cos, sin = math.cos(angle), math.sin(angle)
        x = math.copysign(abs(cos) ** power, cos)
        y = math.copysign(abs(sin) ** power, sin)
        points.append((radius + x * radius, radius + y * radius))
    ImageDraw.Draw(mask).polygon(points, fill=255)
    return mask.resize((side, side), Image.LANCZOS)


def macos_icon(side: int) -> Image.Image:
    """The glyph on Apple's grid: rounded tile, clear margin, nothing baked in.

    No drop shadow. macOS 26 lights and shadows the tile itself, and a shadow in
    the artwork shows up as a second one under the system's.
    """
    tile_side = max(1, round(side * MACOS_TILE / SIDE))
    tile = render(tile_side).convert("RGBA")
    tile.putalpha(squircle_mask(tile_side))
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    offset = (side - tile_side) // 2
    canvas.paste(tile, (offset, offset), tile)
    return canvas


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", help="Write a single PNG here instead of the catalogs")
    parser.add_argument("--size", type=int, default=SIDE, help="Size for --out")
    parser.add_argument("--square", action="store_true",
                        help="With --out: the full-bleed iPhone artwork, not the Mac tile")
    args = parser.parse_args()

    if args.out:
        image = render(args.size) if args.square else macos_icon(args.size)
        image.save(args.out)
        print(f"wrote {args.out} ({args.size}×{args.size})")
        return

    written = []
    for size, names in MACOS_ICONS.items():
        image = macos_icon(size)
        for name in names:
            image.save(MACOS_DIR / name, format="PNG")
            written.append(MACOS_DIR / name)
    full = render(SIDE)
    for path in (IOS_ICON, WATCH_ICON, APPSTORE_ICON):
        full.save(path)
        written.append(path)
    for path in written:
        print(f"wrote {path.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
