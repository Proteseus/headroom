#!/usr/bin/env python3
"""Frame iOS simulator captures into App Store 6.7\" slides (1290×2796).

Reads docs/screenshots/ios-*.png (device captures) and writes marketing
frames to docs/appstore/screenshots/ with a short headline above the phone UI.
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

# iPhone 6.7" App Store requirement
W, H = 1290, 2796

# Dark charcoal matching the Headroom icon / desk vibe — not purple AI sludge.
BG = (18, 18, 20)
FG = (245, 243, 239)
MUTED = (160, 158, 152)

SLIDES = [
    ("ios-overview.png", "01-overview.png", "Your quotas,\none glance"),
    ("ios-activity.png", "02-activity.png", "CI and deploys\nwithout another tab"),
    ("ios-services.png", "03-services.png", "Supabase, Plausible,\nlocal ports"),
]


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    candidates = [
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/Library/Fonts/SF-Pro-Display-Bold.otf" if bold else "/Library/Fonts/SF-Pro-Display-Regular.otf",
    ]
    for path in candidates:
        try:
            return ImageFont.truetype(path, size=size, index=0)
        except OSError:
            continue
    return ImageFont.load_default()


def fit_device(shot: Image.Image, max_w: int, max_h: int) -> Image.Image:
    shot = shot.convert("RGBA")
    scale = min(max_w / shot.width, max_h / shot.height)
    new = (max(1, int(shot.width * scale)), max(1, int(shot.height * scale)))
    return shot.resize(new, Image.Resampling.LANCZOS)


def frame(shot_path: Path, headline: str) -> Image.Image:
    canvas = Image.new("RGB", (W, H), BG)
    draw = ImageDraw.Draw(canvas)

    title_font = font(72, bold=True)
    # Headline block in the upper third.
    lines = headline.split("\n")
    y = 160
    for line in lines:
        bbox = draw.textbbox((0, 0), line, font=title_font)
        tw = bbox[2] - bbox[0]
        draw.text(((W - tw) / 2, y), line, fill=FG, font=title_font)
        y += 86

    # Device capture fills the remaining vertical space with side margins.
    shot = Image.open(shot_path)
    device = fit_device(shot, max_w=W - 120, max_h=H - y - 120)
    x = (W - device.width) // 2
    dy = y + 40
    # Soft rounded “bezel” plate behind the capture.
    plate = Image.new("RGBA", (device.width + 28, device.height + 28), (0, 0, 0, 0))
    plate_draw = ImageDraw.Draw(plate)
    plate_draw.rounded_rectangle(
        (0, 0, plate.width - 1, plate.height - 1),
        radius=48,
        fill=(32, 32, 36, 255),
    )
    canvas.paste(plate, (x - 14, dy - 14), plate)
    if device.mode == "RGBA":
        canvas.paste(device, (x, dy), device)
    else:
        canvas.paste(device, (x, dy))
    return canvas


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--shots-dir", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    args = parser.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)

    written = 0
    for src_name, out_name, headline in SLIDES:
        src = args.shots_dir / src_name
        if not src.exists():
            # Fall back: reuse overview so we still ship ≥1 framed slide.
            alt = args.shots_dir / "ios-overview.png"
            if not alt.exists():
                print(f"skip {src_name} (missing)")
                continue
            print(f"warn: {src_name} missing — framing overview as {out_name}")
            src = alt
        out = args.out_dir / out_name
        frame(src, headline).save(out, optimize=True)
        print(f"wrote {out} ({W}x{H})")
        written += 1

    if written == 0:
        raise SystemExit("no screenshots framed")


if __name__ == "__main__":
    main()
