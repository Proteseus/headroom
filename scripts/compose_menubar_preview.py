#!/usr/bin/env python3
"""Compose a README menubar strip: fake macOS bar + Headroom meters + popover."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def font(size: int):
    for path in (
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
    ):
        if Path(path).exists():
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


def remaining_pcts(doc: dict) -> list[float | None]:
    """Claude / Codex / Cursor remaining % (menu bar fills by remaining)."""
    out: list[float | None] = []
    claude = None
    for k in ("session_pct", "week_pct"):
        v = doc.get(k)
        if v is not None and (claude is None or v > claude):
            claude = float(v)
    out.append(None if claude is None else max(0.0, 100.0 - claude))

    codex = doc.get("codex") or {}
    cx = None
    for k in ("session_pct", "week_pct"):
        v = codex.get(k)
        if v is not None and (cx is None or v > cx):
            cx = float(v)
    out.append(None if cx is None else max(0.0, 100.0 - cx))

    cursor = doc.get("cursor") or {}
    cur = cursor.get("total_pct")
    out.append(None if cur is None else max(0.0, 100.0 - float(cur)))
    return out


def render_icon(
    remainings: list[float | None],
    warning: bool,
    critical: bool,
    size: int = 72,
) -> Image.Image:
    """Match MeterIconRenderer: 3 horizontal bars + optional warning pip."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    canvas = 36  # Swift pixel canvas at 2x
    s = size / canvas

    bar_w = int(30 * s)
    bar_h = max(2, int(6 * s))
    gap = max(1, int(4 * s))
    bar_x = (size - bar_w) // 2
    stack_h = 3 * bar_h + 2 * gap
    stack_y = (size - stack_h) // 2

    for index, rem in enumerate(remainings):
        y = stack_y + index * (bar_h + gap)
        draw.rounded_rectangle(
            [bar_x, y, bar_x + bar_w, y + bar_h],
            radius=bar_h / 2,
            fill=(0, 0, 0, 70),
            outline=(0, 0, 0, 110),
            width=1,
        )
        if rem is None:
            continue
        fill_w = int(bar_w * max(0.0, min(rem, 100.0)) / 100.0)
        if fill_w > 0:
            draw.rounded_rectangle(
                [bar_x, y, bar_x + fill_w, y + bar_h],
                radius=bar_h / 2,
                fill=(0, 0, 0, 230),
            )

    if warning:
        pip = max(4, int(8 * s))
        px = int(26 * s)
        py = int(26 * s)
        color = (255, 59, 48, 255) if critical else (255, 149, 0, 255)
        draw.ellipse([px, py, px + pip, py + pip], fill=color)

    return img


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--popover", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--icon-out", default="")
    args = parser.parse_args()

    doc = json.loads(Path(args.fixture).read_text())
    attention = doc.get("attention") or {}
    level = attention.get("level")
    warning = level in ("warn", "critical")
    icon = render_icon(
        remaining_pcts(doc), warning, level == "critical", size=72
    )
    if args.icon_out:
        Path(args.icon_out).parent.mkdir(parents=True, exist_ok=True)
        icon.save(args.icon_out)

    popover = Image.open(args.popover).convert("RGBA")
    target_w = 420
    scale = target_w / popover.width
    pop_h = int(popover.height * scale)
    popover = popover.resize((target_w, pop_h), Image.Resampling.LANCZOS)

    bar_h = 36
    pad = 28
    width = max(popover.width + pad * 2, 520)
    height = bar_h + 16 + pop_h + pad

    canvas = Image.new("RGBA", (width, height), (245, 246, 248, 255))
    draw = ImageDraw.Draw(canvas)

    draw.rectangle([0, 0, width, bar_h], fill=(246, 246, 246, 255))
    draw.line([(0, bar_h), (width, bar_h)], fill=(210, 210, 210, 255), width=1)

    f = font(13)
    draw.text((16, 9), "Headroom", font=f, fill=(30, 30, 30, 220))

    time_label = "14:32"
    tw = draw.textlength(time_label, font=f)
    icon_size = 22
    icon_x = width - pad - int(tw) - 12 - icon_size
    time_x = width - pad - int(tw)
    draw.text((time_x, 9), time_label, font=f, fill=(30, 30, 30, 220))

    icon_r = icon.resize((icon_size, icon_size), Image.Resampling.NEAREST)
    canvas.paste(icon_r, (icon_x, (bar_h - icon_size) // 2), icon_r)
    draw.rectangle(
        [icon_x - 2, bar_h - 2, icon_x + icon_size + 2, bar_h],
        fill=(0, 122, 255, 255),
    )

    pop_x = max(pad, icon_x + icon_size // 2 - popover.width // 2)
    pop_x = min(pop_x, width - pad - popover.width)
    pop_y = bar_h + 14

    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle(
        [
            pop_x + 4,
            pop_y + 6,
            pop_x + popover.width + 4,
            pop_y + popover.height + 6,
        ],
        radius=16,
        fill=(0, 0, 0, 45),
    )
    canvas = Image.alpha_composite(canvas, shadow)

    mask = Image.new("L", popover.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, popover.width - 1, popover.height - 1], radius=14, fill=255
    )
    rounded = Image.new("RGBA", popover.size)
    rounded.paste(popover, (0, 0))
    rounded.putalpha(mask)
    canvas.paste(rounded, (pop_x, pop_y), rounded)
    ImageDraw.Draw(canvas).rounded_rectangle(
        [pop_x, pop_y, pop_x + popover.width - 1, pop_y + popover.height - 1],
        radius=14,
        outline=(0, 0, 0, 35),
        width=1,
    )

    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(args.out, quality=95)
    print(f"wrote {args.out} ({canvas.size[0]}×{canvas.size[1]})")


if __name__ == "__main__":
    main()
