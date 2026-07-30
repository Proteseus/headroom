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
import sys

from PIL import Image, ImageDraw

import gfx_font

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "host"))
import device_view

# Logical landscape canvas (what the board draws into).
W, H = 448, 368
PAD = 28

# sealNativeEdges() in firmware/src/main.cpp repaints the bottom rows of every
# frame in the frame's own background colour, covering a fringe on the panel's
# native right edge. Mirror it here — it is invisible on a full-bleed clear, but
# it means a layout that drifts below H - SEAL_ROWS loses its ink on the board,
# and the preview must lose it too rather than promise pixels the panel eats.
SEAL_ROWS = 20

COL_BG = (16, 14, 12)
COL_WHITE = (240, 238, 234)
COL_DIM = (120, 116, 110)
COL_RED = (175, 105, 100)
COL_CRT = (0, 214, 236)
COL_CRT_DIM = (150, 40, 120)
COL_CRT_YELLOW = (236, 214, 0)
COL_CRT_BG = (6, 4, 14)


# A "font" here is just an Arduino_GFX textSize — gfx_font blits the same 5×7
# bitmap glyphs the panel does, so the preview isn't a lookalike in Courier.
FONT1 = 1
FONT2 = 2
FONT3 = 3


def text_w(draw: ImageDraw.ImageDraw, s: str, font) -> int:
    return gfx_font.text_width(s, font)


def draw_text(draw: ImageDraw.ImageDraw, s: str, x: int, y: int, font, fill):
    gfx_font.draw_text(draw, s, x, y, font, fill)


def draw_centered(draw: ImageDraw.ImageDraw, s: str, y: int, font, fill):
    draw_text(draw, s, (W - text_w(draw, s, font)) // 2, y, font, fill)


def clip_fit(draw, s: str, max_w: int, font) -> str:
    if text_w(draw, s, font) <= max_w:
        return s
    out = s
    while out:
        out = out[:-1]
        if text_w(draw, out, font) <= max_w:
            return out
    return ""


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


def draw_round_arc(draw, cx, cy, r, thick, start_deg, sweep_deg, fill, steps=64):
    """Usage arc with half-round ends. Mirror of fillRoundArc() in main.cpp."""
    mid = r - thick / 2
    cap = thick / 2
    cap_deg = math.degrees(cap / mid)
    s = start_deg + cap_deg
    e = start_deg + sweep_deg - cap_deg
    if e > s:
        draw_arc(draw, cx, cy, r, thick, s, e, fill, steps=steps)
    else:
        s = e = start_deg + sweep_deg / 2
    for a in (math.radians(s), math.radians(e)):
        px = cx + mid * math.cos(a)
        py = cy + mid * math.sin(a)
        draw.ellipse([px - cap, py - cap, px + cap, py + cap], fill=fill)


def dim(color, factor):
    """Blend toward the background. Mirror of dimToward() in main.cpp."""
    return tuple(
        int(bg + (c - bg) * factor + 0.5) for c, bg in zip(color, COL_BG)
    )


def draw_pace_ring(draw, cx, cy, r, thick, pct, pace_pct, accent):
    """One ring band. Mirror of drawPaceRing() in firmware/src/main.cpp."""
    # A neutral track at 0% is indistinguishable from background, so two empty
    # rings merge into one dark blob. Tinting the track keeps each ring legible
    # as a ring even before any of it fills.
    draw_arc(draw, cx, cy, r, thick, -90, 270, dim(accent, 0.20), steps=90)
    if pct is not None and pct >= 0:
        p = min(100.0, float(pct))
        sweep = p * 3.6
        if p > 0 and sweep < 2:
            sweep = 2
        # Round-cap even at 100% so the two ends meet as a ")(" seam at 12
        # o'clock — same as SwiftUI StrokeStyle(.round), not a solid fill.
        draw_round_arc(draw, cx, cy, r, thick, -90, sweep, accent,
                       steps=max(8, int(sweep)))
    if pace_pct is not None and pace_pct >= 0:
        pp = min(100.0, float(pace_pct))
        a = math.radians(-90 + pp * 3.6)
        mid = r - thick / 2
        dot = round(thick * 5 / 14)
        px = cx + mid * math.cos(a)
        py = cy + mid * math.sin(a)
        draw.ellipse([px - dot, py - dot, px + dot, py + dot], fill=COL_WHITE)


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


def parse_accent(value: str | None):
    if isinstance(value, str) and len(value) == 7 and value.startswith("#"):
        try:
            return tuple(int(value[i:i + 2], 16) for i in (1, 3, 5))
        except ValueError:
            pass
    return COL_DIM


def shape_demo_burndown(device: dict):
    """Give screenshot fixtures the staged curves used by the Apple previews.

    The fixture carries real schema but intentionally fake readings. Its weekly
    projections currently share one timestamp, which is useful for contracts
    but collapses to a vertical stroke on the board. Marketing screenshots use
    three distinct stories instead: steady spend, a late cliff, and a gentle
    plateau. Keep that presentation-only shaping here, after the real device
    projection, so arbitrary /usage captures still render literally.
    """
    providers = (device.get("providers") or [])[:3]
    burns = device.get("burndown") or {}
    ready = [
        burns.get(provider.get("id"), {})
        for provider in providers
        if (burns.get(provider.get("id"), {}).get("pts") or [])
    ]
    if not ready:
        return

    now = max(int(burn["pts"][-1][0]) for burn in ready)
    day = 86400
    profiles = (
        # Steady spend, with the small pauses visible in the Mac screenshot.
        (
            ((-3.0, 100), (-2.72, 92), (-2.35, 92), (-1.82, 84),
             (-1.48, 84), (-1.02, 76), (-0.55, 70), (0.0, None)),
            3.20,
            -29,
            3.25,
            False,
        ),
        # Quiet most of the week, then a sharp late burn and early exhaustion.
        (
            ((-3.0, 100), (-1.25, 100), (-0.72, 96), (-0.38, 96),
             (-0.16, 82), (0.0, None)),
            0.48,
            -100,
            3.70,
            True,
        ),
        # A measured drop followed by a long, shallow forecast.
        (
            ((-3.0, 100), (-2.20, 100), (-1.78, 85), (-0.62, 85),
             (0.0, None)),
            3.20,
            -6,
            4.00,
            False,
        ),
    )

    for index, provider in enumerate(providers):
        burn = burns.get(provider.get("id"), {})
        if not burn.get("pts"):
            continue
        remaining = float(burn["pts"][-1][1])
        actual, forecast_days, forecast_delta, reset_days, warn = profiles[
            min(index, len(profiles) - 1)
        ]
        burn["pts"] = [
            [int(now + offset * day), remaining if value is None else value]
            for offset, value in actual
        ]
        forecast_remaining = max(0.0, remaining + forecast_delta)
        burn["proj"] = [
            [now, remaining],
            [int(now + forecast_days * day), forecast_remaining],
        ]
        burn["t1"] = int(now + reset_days * day)
        burn["warn"] = warn


def timezone_offset_seconds(updated: str) -> int:
    if len(updated) < 5 or updated[-5] not in "+-":
        return 0
    try:
        offset = int(updated[-4:-2]) * 3600 + int(updated[-2:]) * 60
    except ValueError:
        return 0
    return -offset if updated[-5] == "-" else offset


def clip_burn_segment(ta, ra, tb, rb, t_lo, t_hi):
    if ta == tb:
        return None
    if ta > tb:
        ta, tb, ra, rb = tb, ta, rb, ra
    if tb < t_lo or ta > t_hi:
        return None
    oa, ora, ob, orb = ta, ra, tb, rb
    span = tb - ta
    if ta < t_lo:
        u = (t_lo - ta) / span
        oa, ora = t_lo, ra + u * (rb - ra)
    if tb > t_hi:
        u = (t_hi - ta) / span
        ob, orb = t_hi, ra + u * (rb - ra)
    return oa, ora, ob, orb


def stroke_dashed(draw, p0, p1, fill):
    x0, y0 = p0
    x1, y1 = p1
    dx, dy = x1 - x0, y1 - y0
    adx, ady = abs(dx), abs(dy)
    length = adx + ady // 2 if adx > ady else ady + adx // 2
    if length < 1:
        return
    for i in range(0, length, 12):
        i1 = min(length, i + 3)
        a = (x0 + dx * i // length, y0 + dy * i // length)
        b = (x0 + dx * i1 // length, y0 + dy * i1 // length)
        draw.line([a, b], fill=fill, width=3)


def draw_overall_series(draw, burn, accent, x, y, w, h, t_lo, t_hi):
    points = burn.get("pts") or []
    if not points or t_hi <= t_lo:
        return
    span = t_hi - t_lo

    def px(t):
        if t <= t_lo:
            return x
        if t >= t_hi:
            return x + w - 1
        return x + int((t - t_lo) * (w - 1) / span)

    def py(remaining):
        remaining = max(0.0, min(100.0, float(remaining)))
        return y + h - 1 - int(remaining * (h - 1) / 100.0)

    line = accent
    for a, b in zip(points, points[1:]):
        clipped = clip_burn_segment(
            int(a[0]), float(a[1]), int(b[0]), float(b[1]), t_lo, t_hi
        )
        if clipped:
            ta, ra, tb, rb = clipped
            draw.line(
                [(px(ta), py(ra)), (px(tb), py(rb))],
                fill=line,
                width=3,
            )

    projected = burn.get("proj") or []
    if len(projected) == 2:
        p0t, p0r = int(projected[0][0]), float(projected[0][1])
        p1t, p1r = int(projected[1][0]), float(projected[1][1])
        reset = int(burn.get("t1") or 0)
        if reset > 0 and p1t > reset and p1t > p0t:
            u = (reset - p0t) / (p1t - p0t)
            p1t, p1r = reset, p0r + u * (p1r - p0r)
        p0r, p1r = max(0.0, p0r), max(0.0, p1r)
        if abs(p1r - p0r) > 0.5 or burn.get("warn"):
            clipped = clip_burn_segment(
                p0t, p0r, p1t, p1r, t_lo, t_hi
            )
            if clipped:
                ta, ra, tb, rb = clipped
                p0, p1 = (px(ta), py(ra)), (px(tb), py(rb))
                if abs(p1r - p0r) > 0.5:
                    stroke_dashed(draw, p0, p1, line)
                if tb == p1t:
                    radius = 3 if burn.get("warn") and p1r <= 0.5 else 2
                    draw.ellipse(
                        [p1[0] - radius, p1[1] - radius,
                         p1[0] + radius, p1[1] + radius],
                        fill=line,
                    )

    reset = int(burn.get("t1") or 0)
    if t_lo < reset < t_hi:
        reset_x = px(reset)
        for yy in range(y + 1, y + h - 1, 4):
            draw.line(
                [(reset_x, yy), (reset_x, min(yy + 1, y + h - 2))],
                fill=accent,
            )

    for t, remaining in reversed(points):
        if t_lo <= int(t) <= t_hi:
            nx, ny = px(int(t)), py(float(remaining))
            draw.ellipse([nx - 3, ny - 3, nx + 3, ny + 3], fill=line)
            draw.ellipse(
                [nx - 4, ny - 4, nx + 4, ny + 4],
                outline=COL_BG,
            )
            break


def draw_glance_burndown(draw, providers, burns, updated, mid_y, low_bottom):
    span = W - PAD * 2
    ready = [
        burns.get(provider.get("id"), {})
        for provider in providers
        if (burns.get(provider.get("id"), {}).get("pts") or [])
    ]
    if not ready:
        draw_text(draw, "Collecting history", PAD + 8, mid_y + 36,
                  FONT2, COL_DIM)
        return

    now_t = max(int(burn["pts"][-1][0]) for burn in ready)
    axis_h = 12
    row_h = 16
    legend_h = len(providers) * row_h + 2
    chart_y = mid_y + 6
    chart_h = low_bottom - legend_h - axis_h - chart_y
    chart_x, chart_w = PAD, span

    tz = timezone_offset_seconds(updated)
    local_now = now_t + tz
    local_day = local_now - local_now % 86400
    today_utc = local_day - tz
    t_lo = today_utc - 3 * 86400
    t_hi = t_lo + 7 * 86400

    track = dim(COL_WHITE, 0.35)
    grid = dim(COL_WHITE, 0.22)
    draw.rectangle(
        [chart_x, chart_y, chart_x + chart_w - 1, chart_y + chart_h - 1],
        outline=track,
    )
    draw.line(
        [(chart_x + 1, chart_y + chart_h // 2),
         (chart_x + chart_w - 2, chart_y + chart_h // 2)],
        fill=grid,
    )

    weekdays = ("Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat")
    start_weekday = (local_day // 86400 + 4) % 7
    axis_y = chart_y + chart_h + 2
    for day in range(7):
        day_t = t_lo + day * 86400
        day_x = chart_x + int((day_t - t_lo) * (chart_w - 1) / (t_hi - t_lo))
        if day:
            draw.line(
                [(day_x, chart_y + 1), (day_x, chart_y + chart_h - 2)],
                fill=grid,
            )
        weekday = weekdays[(start_weekday - 3 + day + 70) % 7]
        draw_text(draw, weekday, day_x + 2, axis_y, FONT1, COL_DIM)

    if t_lo < now_t < t_hi:
        now_x = chart_x + int((now_t - t_lo) * (chart_w - 1) / (t_hi - t_lo))
        draw.line(
            [(now_x, chart_y + 1), (now_x, chart_y + chart_h - 2)],
            fill=dim(COL_WHITE, 0.45),
        )

    for provider in providers:
        burn = burns.get(provider.get("id"), {})
        draw_overall_series(
            draw,
            burn,
            parse_accent(provider.get("accent")),
            chart_x,
            chart_y,
            chart_w,
            chart_h,
            t_lo,
            t_hi,
        )

    legend_y = low_bottom - legend_h + 1
    text_x = PAD + 14
    text_width = span - 14
    for index, provider in enumerate(providers):
        row_y = legend_y + index * row_h
        burn = burns.get(provider.get("id"), {})
        accent = parse_accent(provider.get("accent"))
        draw.ellipse(
            [PAD, row_y + 3, PAD + 6, row_y + 9],
            fill=accent if burn.get("pts") else COL_DIM,
        )
        verdict = burn.get("verdict")
        if verdict:
            label = clip_fit(draw, str(verdict), text_width, FONT2)
            draw_text(draw, label, text_x, row_y, FONT2, COL_DIM)
        elif burn.get("pts"):
            remaining = float(burn["pts"][-1][1])
            draw_text(draw, f"{int(remaining + 0.5)}%",
                      text_x, row_y, FONT2, accent)
        else:
            draw_text(draw, "-", text_x, row_y, FONT2, COL_DIM)


def seal_edges(img: Image.Image, bg) -> Image.Image:
    """Repaint the bottom band the way the panel does, in the frame's own bg."""
    ImageDraw.Draw(img).rectangle([0, H - SEAL_ROWS, W - 1, H - 1], fill=bg)
    return img


def render_glance(
    doc: dict,
    link_via: str = "wifi",
    link_error_minutes: int | None = None,
    demo_burndown: bool = False,
) -> Image.Image:
    # Feed the same trimmed payload to the preview that the ESP32 receives.
    device = device_view.build(doc)
    if demo_burndown:
        shape_demo_burndown(device)
    providers = (device.get("providers") or [])[:3]
    burns = device.get("burndown") or {}
    updated = str(device.get("updated") or "")

    img = Image.new("RGB", (W, H), COL_BG)
    draw = ImageDraw.Draw(img)
    draw_text(draw, "Headroom", PAD, PAD, FONT3, COL_WHITE)

    mode_name = "Burndown"
    chip_x = PAD + 152
    chip_w = text_w(draw, mode_name, FONT2) + 16
    draw.rounded_rectangle(
        [chip_x - 8, PAD + 2, chip_x - 8 + chip_w - 1, PAD + 25],
        radius=6,
        outline=COL_DIM,
    )
    draw_text(draw, mode_name, chip_x, PAD + 6, FONT2, COL_DIM)

    when = updated[11:16] if len(updated) >= 16 else ""
    if when:
        draw_text(
            draw,
            when,
            W - PAD - text_w(draw, when, FONT2),
            PAD + 6,
            FONT2,
            COL_DIM,
        )
    if link_error_minutes is not None:
        # 2px red frame — mirrors drawHostErrorBorder() on the board.
        draw.rectangle([0, 0, W - 1, H - 1], outline=COL_RED)
        draw.rectangle([1, 1, W - 2, H - 2], outline=COL_RED)

    span = W - PAD * 2
    slot = span // len(providers) if providers else span
    ring_r = 32
    ring_cy = PAD + 74
    mid_y = ring_cy + ring_r + 48
    low_bottom = H - PAD - 15

    for index, provider in enumerate(providers):
        layers = [
            (pool.get("p"), pool.get("c"))
            for pool in (provider.get("pools") or [])[:2]
            if pool.get("p") is not None
        ] if provider.get("ok") else []
        draw_quota_ring(
            draw,
            PAD + index * slot + slot // 2,
            ring_cy,
            ring_r,
            layers,
            parse_accent(provider.get("accent")),
            str(provider.get("title") or provider.get("id") or "?"),
        )

    draw.line([(PAD, mid_y), (PAD + span - 1, mid_y)],
              fill=COL_DIM, width=1)
    if providers:
        draw_glance_burndown(
            draw, providers, burns, updated, mid_y, low_bottom
        )

    draw_link_glyph(
        draw,
        W - PAD,
        H - PAD,
        link_via=link_via,
        error_minutes=link_error_minutes,
    )
    return seal_edges(img, COL_BG)


def draw_link_glyph(
    draw: ImageDraw.ImageDraw,
    right_x: int,
    bottom_y: int,
    link_via: str = "wifi",
    error_minutes: int | None = None,
):
    """Mirror drawLinkGlyph(), including its last-good age on failure."""
    glyph_w, glyph_h = 18, 15
    gx = right_x - glyph_w
    gy = bottom_y - glyph_h
    color = COL_DIM if error_minutes is None else COL_CRT_YELLOW

    if error_minutes is not None:
        age = f"{max(0, error_minutes)}m"
        draw_text(
            draw,
            age,
            gx - 6 - text_w(draw, age, FONT2),
            gy,
            FONT2,
            color,
        )

    if link_via == "usb":
        # SF Symbol-style cable.connector: tip, housing, cable.
        cx = gx + glyph_w // 2
        tip = tuple(int(c + (w - c) * 0.55 + 0.5)
                    for c, w in zip(color, COL_WHITE))
        draw.rounded_rectangle([cx - 4, gy, cx + 3, gy + 2],
                               radius=1, fill=tip)
        draw.rounded_rectangle([cx - 5, gy + 3, cx + 4, gy + 9],
                               radius=2, fill=color)
        draw.rounded_rectangle([cx - 1, gy + 10, cx, gy + 14],
                               radius=1, fill=color)
        return

    cx = gx + glyph_w // 2
    cy = bottom_y - 2
    draw.arc([cx - 12, cy - 12, cx + 12, cy + 12],
             start=225, end=315, fill=color, width=2)
    draw.arc([cx - 7, cy - 7, cx + 7, cy + 7],
             start=225, end=315, fill=color, width=2)
    draw.ellipse([cx - 1, cy - 2, cx + 1, cy], fill=color)


def render_no_host() -> Image.Image:
    """Mirror drawNetDiag() for reviewing its type scale and CMYK palette."""
    img = Image.new("RGB", (W, H), COL_CRT_BG)
    draw = ImageDraw.Draw(img)
    draw.rectangle(
        [PAD, PAD, W - PAD - 1, H - PAD - 1],
        outline=COL_CRT_DIM,
    )
    draw_centered(draw, "NO HOST", PAD + 10, FONT2, COL_CRT_YELLOW)

    x = PAD + 12
    xv = x + 6 * FONT2 * 6
    y = PAD + 42
    step = 20
    max_chars = (W - PAD - 4 - xv) // (6 * FONT2)

    def row(label: str, value: str, color):
        nonlocal y
        draw_text(draw, label, x, y, FONT2, COL_CRT_DIM)
        draw_text(draw, value[:max_chars], xv, y, FONT2, color)
        y += step

    row("WIFI", "Studio", COL_CRT)
    row("IP", "192.168.1.42  -58dBm", COL_CRT)
    row("HOST", "headroom.local:8787", COL_CRT)
    row("ADDR", "unresolved", COL_CRT_YELLOW)
    row("TOKEN", "set", COL_CRT)
    row("LAST", "never", COL_CRT_YELLOW)
    row("WHY", "connection refused", COL_CRT_YELLOW)

    draw_centered(
        draw,
        "START HOST ON MAC, THEN WAIT",
        H - PAD - 24,
        FONT2,
        COL_CRT_DIM,
    )
    return seal_edges(img, COL_CRT_BG)


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
    parser.add_argument("--input", help="Path to /usage JSON (glance state)")
    parser.add_argument("--out", required=True, help="Output PNG path")
    parser.add_argument(
        "--state",
        choices=("glance", "no-host"),
        default="glance",
        help="Panel state to render",
    )
    parser.add_argument(
        "--link-via",
        choices=("wifi", "usb"),
        default="wifi",
        help="Last successful glance connection",
    )
    parser.add_argument(
        "--link-error-minutes",
        type=int,
        help="Render a failed glance connection with this last-good age",
    )
    parser.add_argument(
        "--demo-burndown",
        action="store_true",
        help="Shape screenshot-only burndown stories like the Apple previews",
    )
    parser.add_argument("--raw", action="store_true", help="Skip device bezel")
    parser.add_argument("--scale", type=int, default=3)
    args = parser.parse_args()

    if args.state == "no-host":
        panel = render_no_host()
    else:
        if not args.input:
            parser.error("--input is required for the glance state")
        doc = json.loads(Path(args.input).read_text())
        panel = render_glance(
            doc,
            link_via=args.link_via,
            link_error_minutes=args.link_error_minutes,
            demo_burndown=args.demo_burndown,
        )
    out = panel if args.raw else frame_device(panel, scale=args.scale)
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    out.save(args.out)
    print(f"wrote {args.out} ({out.size[0]}×{out.size[1]})")


if __name__ == "__main__":
    main()
