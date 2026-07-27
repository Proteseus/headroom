#!/usr/bin/env python3
"""Render a faithful ESP32 Headroom glance preview (logical 448×368).

Matches firmware/src/main.cpp drawGlancePage palette + layout closely enough
for README screenshots. Text goes through gfx_font, which blits the same
classic 5×7 glyphs Arduino_GFX draws, at the same 6×8 × textSize metrics.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

from PIL import Image, ImageDraw

import gfx_font

# Logical landscape canvas (what the board draws into).
W, H = 448, 368
PAD = 28

COL_BG = (16, 14, 12)
COL_CLAUDE = (217, 119, 87)
COL_OPENAI = (16, 163, 127)
COL_CURSOR = (120, 155, 200)
COL_LOCAL = (70, 175, 165)
COL_WHITE = (240, 238, 234)
COL_DIM = (120, 116, 110)
COL_BAR = (42, 40, 38)
COL_GREEN = (95, 155, 115)
COL_AMBER = (195, 155, 85)
COL_RED = (175, 105, 100)
COL_BLACK = (0, 0, 0)


# A "font" here is just an Arduino_GFX textSize — gfx_font blits the same 5×7
# bitmap glyphs the panel does, so the preview isn't a lookalike in Courier.
FONT2 = 2
FONT3 = 3


def text_w(draw: ImageDraw.ImageDraw, s: str, font) -> int:
    return gfx_font.text_width(s, font)


def draw_text(draw: ImageDraw.ImageDraw, s: str, x: int, y: int, font, fill):
    gfx_font.draw_text(draw, s, x, y, font, fill)


def status_color(status: str):
    # Match firmware + Mac: red for bad, dim otherwise; words qualify.
    if status in ("error", "failure"):
        return COL_RED
    return COL_DIM


def git_hours_ago(ago: str | None) -> str:
    if not ago:
        return "-"
    days = hours = 0
    i = 0
    s = ago
    while i < len(s):
        while i < len(s) and s[i] == " ":
            i += 1
        if i >= len(s):
            break
        j = i
        while j < len(s) and s[j].isdigit():
            j += 1
        if j == i:
            break
        v = int(s[i:j])
        if j < len(s) and s[j] in "dD":
            days = v
            i = j + 1
        elif j < len(s) and s[j] in "hH":
            hours = v
            i = j + 1
        elif j < len(s) and s[j] in "mM":
            i = j + 1
        else:
            break
    return f"{days * 24 + hours}h"


def clip_fit(draw, s: str, max_w: int, font) -> str:
    if text_w(draw, s, font) <= max_w:
        return s
    out = s
    while out:
        out = out[:-1]
        if text_w(draw, out, font) <= max_w:
            return out
    return ""


def draw_name_ago(draw, x, y, col_w, name, ago, name_col, ago_col):
    aw = text_w(draw, ago, FONT2)
    gap = text_w(draw, " ", FONT2)  # one space before the age
    clipped = clip_fit(draw, name, col_w - aw - gap, FONT2)
    draw_text(draw, clipped, x, y, FONT2, name_col)
    draw_text(draw, ago, x + col_w - aw, y, FONT2, ago_col)


def draw_arc(draw, cx, cy, r, thick, start_deg, end_deg, fill, steps=64):
    """Approximate fillArc (outer r → inner r-thick) from start to end degrees."""
    if end_deg <= start_deg:
        return
    outer = []
    inner = []
    for i in range(steps + 1):
        t = i / steps
        a = math.radians(start_deg + (end_deg - start_deg) * t)
        outer.append((cx + r * math.cos(a), cy + r * math.sin(a)))
        ri = r - thick
        inner.append((cx + ri * math.cos(a), cy + ri * math.sin(a)))
    poly = outer + list(reversed(inner))
    draw.polygon(poly, fill=fill)


def dim(color, factor):
    """Blend toward the background. Mirror of dimToward() in main.cpp."""
    return tuple(
        int(bg + (c - bg) * factor) for c, bg in zip(color, COL_BG)
    )


def draw_pace_ring(draw, cx, cy, r, thick, pct, pace_pct, accent):
    """One ring band. Mirror of drawPaceRing() in firmware/src/main.cpp."""
    # A neutral track at 0% is indistinguishable from background, so two empty
    # rings merge into one dark blob. Tinting the track keeps each ring legible
    # as a ring even before any of it fills.
    draw_arc(draw, cx, cy, r, thick, -90, 270, dim(accent, 0.30), steps=90)
    if pct is not None and pct >= 0:
        p = min(100.0, float(pct))
        sweep = p * 3.6
        if p > 0 and sweep < 2:
            sweep = 2
        if p >= 100 or sweep >= 359:
            draw_arc(draw, cx, cy, r, thick, -90, 270, accent, steps=90)
        else:
            draw_arc(draw, cx, cy, r, thick, -90, -90 + sweep, accent,
                     steps=max(8, int(sweep)))
    if pace_pct is not None and pace_pct >= 0:
        pp = min(100.0, float(pace_pct))
        a = -90 + pp * 3.6
        draw_arc(draw, cx, cy, r + 1, thick + 2, a - 2.8, a + 2.8, COL_WHITE,
                 steps=6)
    draw_arc(draw, cx, cy, r + 1, thick + 2, -90 - 2.6, -90 + 2.6, COL_BLACK,
             steps=4)


def draw_quota_ring(draw, cx, cy, r, layers, accent, label):
    """Concentric pace layers. Mirror of drawQuotaRing() in main.cpp."""
    thick, gap = 6, 4
    if not layers:
        draw_pace_ring(draw, cx, cy, r, thick, None, None, accent)
    else:
        rr = r
        for pct, pace in layers[:2]:
            draw_pace_ring(draw, cx, cy, rr, thick, pct, pace, accent)
            rr = rr - thick - gap
    tw = text_w(draw, label, FONT2)
    draw_text(draw, label, cx - tw // 2, cy + r + 8, FONT2, accent)


def pace_layers(provider: dict | None, cursor_total: bool = False):
    """Mirror of providerLayers() in main.cpp: fastest window outermost."""
    if not provider or not provider.get("ok", True):
        return []
    out = []
    if cursor_total and provider.get("total_pct") is not None:
        out.append((provider.get("total_pct"), provider.get("total_pace_pct")))
        if provider.get("api_pct") is not None:
            out.append((provider.get("api_pct"), provider.get("api_pace_pct")))
        return out
    for pct_k, pace_k in (("session_pct", "session_pace_pct"),
                          ("week_pct", "week_pace_pct")):
        if provider.get(pct_k) is not None:
            out.append((provider.get(pct_k), provider.get(pace_k)))
    return out


def hottest(provider: dict | None, cursor_total: bool = False):
    if not provider or not provider.get("ok", True):
        return None, None
    if cursor_total and provider.get("total_pct") is not None:
        return provider.get("total_pct"), provider.get("total_pace_pct")
    best = -1.0
    pace = None
    for pct_k, pace_k in (("session_pct", "session_pace_pct"), ("week_pct", "week_pace_pct")):
        pct = provider.get(pct_k)
        if pct is not None and pct > best:
            best = float(pct)
            pace = provider.get(pace_k)
    if best < 0:
        return None, None
    return best, pace


def render_glance(doc: dict) -> Image.Image:
    img = Image.new("RGB", (W, H), COL_BG)
    draw = ImageDraw.Draw(img)

    draw_text(draw, "Headroom", PAD, PAD, FONT3, COL_WHITE)
    updated = doc.get("updated") or ""
    when = updated[11:16] if len(updated) >= 16 else ""
    if when:
        tw = text_w(draw, when, FONT2)
        draw_text(draw, when, W - PAD - tw, PAD + 6, FONT2, COL_DIM)

    span = W - PAD * 2
    slot = span // 3
    ring_r = 32
    ring_cy = PAD + 74
    mid_y = ring_cy + ring_r + 48
    foot_y = H - PAD - 6

    claude = {
        "ok": doc.get("quota_ok", True),
        "session_pct": doc.get("session_pct"),
        "session_pace_pct": doc.get("session_pace_pct"),
        "week_pct": doc.get("week_pct"),
        "week_pace_pct": doc.get("week_pace_pct"),
    }
    providers = [
        (pace_layers(claude), COL_CLAUDE, "Claude"),
        (pace_layers(doc.get("codex")), COL_OPENAI, "Codex"),
        (pace_layers(doc.get("cursor"), cursor_total=True), COL_CURSOR, "Cursor"),
    ]
    for i, (layers, accent, label) in enumerate(providers):
        cx = PAD + i * slot + slot // 2
        draw_quota_ring(draw, cx, ring_cy, ring_r, layers, accent, label)

    draw.line([(PAD, mid_y), (PAD + span, mid_y)], fill=COL_DIM, width=1)

    local_w = 78
    wide_w = (span - local_w) // 2
    low_w = [wide_w, span - local_w - wide_w, local_w]
    low_x = [PAD, PAD + low_w[0], PAD + low_w[0] + low_w[1]]
    low_top = mid_y + 6
    low_bottom = foot_y - 4
    col_pad = 4
    dot_r = 5
    row_h = 20
    text_x = 14
    low_max = 6

    # Vercel
    x = low_x[0] + col_pad
    col_w = low_w[0] - col_pad * 2
    y = low_top
    draw_text(draw, "Vercel", x, y, FONT2, COL_WHITE)
    y += 22
    vercel = doc.get("vercel") or {}
    deps = vercel.get("deployments") or []
    if vercel.get("ok") and deps:
        for d in deps[:low_max]:
            if y > low_bottom - 18:
                break
            draw.ellipse(
                [x, y + 8 - dot_r, x + 2 * dot_r, y + 8 + dot_r],
                fill=status_color(d.get("status") or ""),
            )
            draw_name_ago(
                draw,
                x + text_x,
                y,
                col_w - text_x,
                d.get("project") or "?",
                git_hours_ago(d.get("ago")),
                COL_WHITE,
                COL_DIM,
            )
            y += row_h
    else:
        draw_text(draw, "-" if vercel.get("ok") else "down", x, y, FONT2, COL_DIM)

    # Git
    x = low_x[1] + col_pad
    col_w = low_w[1] - col_pad * 2
    y = low_top
    draw_text(draw, "Git", x, y, FONT2, COL_WHITE)
    y += 22
    git = doc.get("git") or {}
    commits = git.get("commits") or []
    if git.get("ok") and commits:
        for c in commits[:low_max]:
            if y > low_bottom - 18:
                break
            repo = c.get("repo") or "?"
            if "/" in repo:
                repo = repo.rsplit("/", 1)[-1]
            draw_name_ago(
                draw, x, y, col_w, repo, git_hours_ago(c.get("ago")), COL_WHITE, COL_DIM
            )
            y += row_h
    else:
        draw_text(draw, "-" if git.get("ok") else "down", x, y, FONT2, COL_DIM)

    # Local
    x = low_x[2] + col_pad
    col_w = low_w[2] - col_pad * 2
    y = low_top
    draw_text(draw, "Local", x, y, FONT2, COL_WHITE)
    y += 22
    local = doc.get("local") or {}
    servers = local.get("servers") or []
    if local.get("ok") and servers:
        for s in servers[:low_max]:
            if y > low_bottom - 18:
                break
            draw.ellipse(
                [x, y + 8 - dot_r, x + 2 * dot_r, y + 8 + dot_r],
                fill=COL_LOCAL,
            )
            port = s.get("port")
            label = f":{port}" if port else "-"
            draw_text(draw, label, x + text_x, y, FONT2, COL_WHITE)
            y += row_h
    else:
        draw_text(draw, "none" if local.get("ok") else "down", x, y, FONT2, COL_DIM)

    sources = doc.get("sources") or []
    if sources:
        src_r = 3
        gap = 12
        total_w = len(sources) * gap - (gap - 2 * src_r)
        sx = PAD + (span - total_w) // 2
        for src in sources:
            if not src.get("enabled"):
                col = COL_DIM
            elif not src.get("ok"):
                col = COL_RED
            elif src.get("stale"):
                col = COL_AMBER
            else:
                col = COL_GREEN
            draw.ellipse(
                [sx, foot_y + 2 - src_r, sx + 2 * src_r, foot_y + 2 + src_r],
                fill=col,
            )
            sx += gap

    return img


def frame_device(panel: Image.Image, scale: int = 3) -> Image.Image:
    """Drop the landscape panel into a rounded AMOLED-style bezel."""
    panel = panel.resize((W * scale, H * scale), Image.Resampling.NEAREST)
    bezel = 18 * scale
    radius = 28 * scale
    outer_w = panel.width + bezel * 2
    outer_h = panel.height + bezel * 2
    # Transparent canvas with soft desk shadow
    canvas = Image.new("RGBA", (outer_w + 40, outer_h + 48), (0, 0, 0, 0))
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle(
        [24, 28, 24 + outer_w, 28 + outer_h],
        radius=radius + 4,
        fill=(0, 0, 0, 70),
    )
    canvas = Image.alpha_composite(canvas, shadow)

    device = Image.new("RGBA", (outer_w, outer_h), (0, 0, 0, 0))
    dd = ImageDraw.Draw(device)
    dd.rounded_rectangle(
        [0, 0, outer_w - 1, outer_h - 1],
        radius=radius,
        fill=(8, 8, 8, 255),
    )
    dd.rounded_rectangle(
        [bezel - 4, bezel - 4, outer_w - bezel + 3, outer_h - bezel + 3],
        radius=radius - 8,
        fill=(0, 0, 0, 255),
    )
    # Panel with rounded clip
    mask = Image.new("L", panel.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, panel.width - 1, panel.height - 1],
        radius=12 * scale,
        fill=255,
    )
    rounded = Image.new("RGBA", panel.size)
    rounded.paste(panel.convert("RGBA"), (0, 0))
    rounded.putalpha(mask)
    device.paste(rounded, (bezel, bezel), rounded)
    canvas.paste(device, (16, 12), device)
    return canvas


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, help="Path to /usage JSON")
    parser.add_argument("--out", required=True, help="Output PNG path")
    parser.add_argument("--raw", action="store_true", help="Skip device bezel")
    parser.add_argument("--scale", type=int, default=3)
    args = parser.parse_args()

    doc = json.loads(Path(args.input).read_text())
    panel = render_glance(doc)
    out = panel if args.raw else frame_device(panel, scale=args.scale)
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    out.save(args.out)
    print(f"wrote {args.out} ({out.size[0]}×{out.size[1]})")


if __name__ == "__main__":
    main()
