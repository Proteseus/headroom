#!/usr/bin/env python3
"""Max Headroom boot art for the ESP32 panel — source of truth for the sprite.

Two jobs, one sprite:
  --emit-header   write firmware/src/boot_max.h (4bpp packed, what the board draws)
  --out DIR       render preview PNGs + an animated GIF of the whole sequence

The firmware never hand-edits boot_max.h; change build_sprite() here and re-emit.

The sprite is built from polygons at sprite resolution rather than hand-authored
run tables — the proportions that carry the likeness (long face, high quiff,
narrow lenses) are much easier to tune as coordinates than as pixel runs.

Text goes through gfx_font, which blits the same classic 5x7 glyphs Arduino_GFX
draws, at the same 6x8 x textSize metrics — so the previews are not a lookalike
in Courier.
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path

from PIL import Image, ImageDraw

import gfx_font

# Logical landscape canvas (what the board draws into).
W, H = 448, 368
PAD = 28

# ---------------------------------------------------------------- sprite ----
SW, SH = 52, 50

# Inks. 0 is transparent. Void is a real ink, not a hole, so the lenses and the
# open mouth stay black instead of letting the backdrop show through.
VOID, SUIT, SKIN, LITE, HAIR, EDGE = 1, 2, 3, 4, 5, 6
N_INK = 7


def build_sprite() -> list[list[int]]:
    im = Image.new("P", (SW, SH), 0)
    d = ImageDraw.Draw(im)

    # Skull first, hairline carved by drawing the hair over it. A straight top
    # edge here would give a flat-topped helmet; the hair polygon does the work.
    # Jaw stays square — the reference face is planes, not an egg.
    d.polygon([(15, 4), (37, 4), (40, 13), (40, 26),
               (38, 35), (34, 42), (30, 47), (22, 47),
               (18, 42), (14, 35), (12, 26), (12, 13)], fill=SKIN)

    # The quiff: rises off the brow, sweeps up and back, short at the sides.
    # The lower edge is the hairline, sitting high enough to leave a forehead.
    d.polygon([(11, 18), (11, 9), (14, 3), (20, 0), (28, 0), (36, 2),
               (41, 7), (42, 14), (42, 19), (38, 14), (30, 12),
               (22, 13), (15, 16)], fill=HAIR)

    # Wayfarers: two narrow lenses inset from the cheekbones, joined by a
    # bridge. These stay VOID and are the only face left — they read as
    # graphic, not expressive, which is the whole point of the redesign.
    d.rectangle([14, 20, 23, 25], fill=VOID)
    d.rectangle([28, 20, 37, 25], fill=VOID)
    d.rectangle([24, 21, 27, 22], fill=VOID)
    d.rectangle([12, 20, 13, 22], fill=VOID)    # temple arms
    d.rectangle([38, 20, 39, 22], fill=VOID)

    # A flat mouth line, not a grin. Enough to place the face, no attitude.
    d.rectangle([21, 36, 31, 36], fill=VOID)

    # No neck, no shoulders. Shoulders under a floating silhouette read as a
    # pedestal, and Max was never anything but a head on a screen anyway.

    grid = [[im.getpixel((x, y)) for x in range(SW)] for y in range(SH)]
    return outline(grid)


def outline(grid: list[list[int]]) -> list[list[int]]:
    """Dilate the silhouette by one pixel of EDGE ink.

    Against the radiating backdrop he otherwise dissolves into the stripes.
    Baking the halo into the sprite keeps it free at runtime — the alternative
    is blitting the whole sprite four more times per frame as a shadow.
    """
    out = [r[:] for r in grid]
    for y in range(SH):
        for x in range(SW):
            if grid[y][x]:
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1),
                           (1, 1), (1, -1), (-1, 1), (-1, -1)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < SW and 0 <= ny < SH and grid[ny][nx]:
                    out[y][x] = EDGE
                    break
    return out


SPRITE = build_sprite()

# ---------------------------------------------------------------- copper ----
# The silhouette isn't painted, it's a window onto a copper bar field: one
# colour per screen scanline, scrolling. Nothing inside the head is drawn as
# itself, which is what keeps it an effect rather than a portrait.
COPPER_BAND = 30
COPPER_HUES = [(255, 60, 180), (60, 220, 255), (120, 255, 150), (255, 205, 70)]


def build_copper(hues=None, band: int = COPPER_BAND) -> list[tuple[int, int, int]]:
    tab = []
    for r, g, b in (hues or COPPER_HUES):
        for i in range(band):
            # Triangle ramp, gamma-bent so the bright core is a thin hot line.
            v = (1 - abs(i / (band - 1) * 2 - 1)) ** 0.65
            tab.append((int(r * v), int(g * v), int(b * v)))
    return tab


COPPER = build_copper()

# --------------------------------------------------------------- palettes ---
# CHROMA ships. AMBER stays inside the existing boot palette and is kept
# renderable so the two can be compared without a reflash.
CHROMA = {
    "bg": (6, 4, 14),
    VOID: (0, 0, 0),
    EDGE: (255, 255, 255),
    "copper": COPPER,
    "text": (255, 255, 255),
    "text_mid": (150, 190, 235),
    "text_low": (40, 70, 150),
    "ghost_c": (0, 190, 210),
    "ghost_m": (215, 30, 130),
    # Radiating backdrop — kept dim so the copper head stays the bright thing.
    "rays": [(64, 12, 46), (0, 52, 64), (26, 58, 30), (72, 56, 14)],
}

AMBER = {
    "bg": (10, 6, 2),
    VOID: (0, 0, 0),
    EDGE: (255, 236, 190),
    "copper": build_copper([(255, 180, 40), (255, 120, 20),
                            (255, 220, 120), (190, 90, 15)]),
    "text": (255, 236, 190),
    "text_mid": (190, 130, 40),
    "text_low": (90, 55, 12),
    "ghost_c": (0, 150, 170),
    "ghost_m": (190, 40, 40),
    "rays": [(56, 34, 8), (36, 22, 5), (68, 44, 10), (24, 15, 3)],
}

# The panel's own CRT tax: one dimmed row per sprite pixel.
DIM = 0.55

# --------------------------------------------------------------- geometry ---
SCALE = 5
HEAD_X = (W - SW * SCALE) // 2   # symmetric: logo above, scroller below
HEAD_Y = 60
# Vanishing point sits behind his head, so the rays fan out past him and open
# up toward the left where the title sits.
VP = (HEAD_X + SW * SCALE // 2, 150)
RAY_COUNT = 26
RAY_R = 760
RAY_DUTY = 0.22   # fraction of each slot that is lit; the rest stays black
BAR_Y, BAR_H = 18, 52
SCROLL_Y = H - 44
TEAR_BANDS = [(96, 22, 14), (168, 16, -22), (250, 12, 9)]


def dim(c):
    return (int(c[0] * DIM), int(c[1] * DIM), int(c[2] * DIM))


# ----------------------------------------------------------------- render ---
def blank(pal) -> Image.Image:
    return Image.new("RGB", (W, H), pal["bg"])


def rays(img, pal, phase: float = 0.0, squeeze: float = 1.0) -> None:
    """Wedges radiating from a vanishing point — the show's standing backdrop.

    squeeze < 1 flattens them toward mid-screen for the roll-out.
    """
    d = ImageDraw.Draw(img)
    vx, vy = VP[0], H // 2 + (VP[1] - H // 2) * squeeze
    step = 2 * math.pi / RAY_COUNT
    for i in range(RAY_COUNT):
        a0 = phase + i * step
        a1 = a0 + step * RAY_DUTY
        pts = [(vx, vy)]
        for a in (a0, a1):
            pts.append((vx + RAY_R * math.cos(a),
                        vy + RAY_R * math.sin(a) * squeeze))
        d.polygon(pts, fill=pal["rays"][i % len(pal["rays"])])


def ink_color(pal, ink: int, screen_y: int, copper_phase: int):
    """Every ink except the lenses and the outline resolves to copper.

    The face detail is gone from the sprite, so this collapses hair, skin and
    shoulders into one moving surface — a mask over the bar field, not a
    painted figure.
    """
    if ink == VOID:
        return pal[VOID]
    if ink == EDGE:
        return pal[EDGE]
    tab = pal["copper"]
    # The quiff runs half a band out of phase with the face. One continuous
    # field turned the whole silhouette into a smooth egg — the phase break is
    # what puts the hairline back without drawing a hairline.
    if ink == HAIR:
        screen_y += COPPER_BAND // 2
    return tab[(screen_y + copper_phase) % len(tab)]


def head(img, pal, x0, y0, sx=SCALE, sy=SCALE, shear=0, rows=SH, tint=None,
         copper_phase=0) -> None:
    """Blit the sprite one screen scanline at a time.

    Per-scanline rather than per-sprite-block because the copper colour changes
    every screen row — drawing a 5px block in one colour would quantise the
    bars to the sprite grid and kill the gradient.

    shear — pixels of lean across the full height (the idle bob)
    rows  — how many sprite rows to draw, top down (the wipe-in)
    tint  — force every ink to one colour (the chroma-split ghosts)
    """
    d = ImageDraw.Draw(img)
    for r in range(min(rows, SH)):
        lean = (shear * (2 * r - SH)) // (2 * SH)
        c = 0
        spans = []
        while c < SW:
            ink = SPRITE[r][c]
            run = 1
            while c + run < SW and SPRITE[r][c + run] == ink:
                run += 1
            if ink:
                spans.append((c + lean, run, ink))
            c += run
        for sub in range(sy):
            py = y0 + r * sy + sub
            last = sub == sy - 1 and sy > 1
            for cx, run, ink in spans:
                col = tint or ink_color(pal, ink, py, copper_phase)
                if last:                       # the panel's own scanline gap
                    col = dim(col)
                d.rectangle([x0 + cx * sx, py, x0 + (cx + run) * sx - 1, py],
                            fill=col)


def tear(img, pal, bands) -> None:
    """Displace horizontal slices — the signature Max stutter."""
    for top, height, dx in bands:
        band = img.crop((0, top, W, top + height))
        img.paste(pal["bg"], (0, top, W, top + height))
        img.paste(band, (dx, top))


def chrome_text(img, pal, s, x, y, size) -> None:
    """Three passes at one-pixel offsets — the cheap bitmap-font chrome bevel.

    A real gradient fill needs a mask the panel can't afford; stacking dark,
    mid and bright copies gets the same read for the price of three blits.
    """
    d = ImageDraw.Draw(img)
    gfx_font.draw_text(d, s, x, y + 2, size, pal["text_low"])
    gfx_font.draw_text(d, s, x, y + 1, size, pal["text_mid"])
    gfx_font.draw_text(d, s, x, y, size, pal["text"])


SCROLL_TEXT = ("HEADROOM ... 20 MINUTES INTO THE FUTURE ... "
               "C-C-CATCH THE WAVE ... ")


def scroller(img, pal, offset: int, y: int, size: int = 2, amp: int = 8) -> None:
    """Sine scroller: per-character vertical offset off a travelling wave."""
    d = ImageDraw.Draw(img)
    # Own band, so the wave never fights the silhouette behind it.
    d.rectangle([0, y - amp - 4, W - 1, y + amp + 8 * size], fill=pal["bg"])
    cell = 6 * size
    span = len(SCROLL_TEXT) * cell
    first = offset // cell
    for i in range(W // cell + 2):
        ch = SCROLL_TEXT[(first + i) % len(SCROLL_TEXT)]
        if ch == " ":
            continue
        x = i * cell - (offset % cell)
        wave = math.sin((offset + x) * 0.021)
        gfx_font.draw_text(d, ch, x, y + int(wave * amp), size, pal["text"])
    del span


def title(img, pal, stutter=False, phase=0) -> None:
    """Wordmark over the head, chrome-bevelled, with the scroller beneath.

    No panel behind it — a solid plate reads as a UI card, and this is meant
    to read as an intro screen.
    """
    word = "H-H-HEADROOM" if stutter else "HEADROOM"
    chrome_text(img, pal, word, (W - gfx_font.text_width(word, 4)) // 2,
                BAR_Y + 6, 4)
    scroller(img, pal, phase, SCROLL_Y)


# ----------------------------------------------------------------- frames ---
def f_strike(pal, sliver):
    img = blank(pal)
    d = ImageDraw.Draw(img)
    mid = H // 2
    d.rectangle([0, mid - sliver, W - 1, mid + sliver], fill=pal["rays"][0])
    d.line([0, mid, W - 1, mid], fill=(255, 255, 255))
    return img


def f_wipe(pal, phase, rows, cop=0):
    img = blank(pal)
    rays(img, pal, phase)
    head(img, pal, HEAD_X, HEAD_Y, rows=rows, copper_phase=cop)
    return img


def f_head(pal, shear=0, phase=0.0, cop=0):
    img = blank(pal)
    rays(img, pal, phase)
    head(img, pal, HEAD_X, HEAD_Y, shear=shear, copper_phase=cop)
    return img


def f_stutter(pal, phase=0.0, cop=0, scroll=0):
    img = blank(pal)
    rays(img, pal, phase)
    head(img, pal, HEAD_X - 4, HEAD_Y, shear=-4, tint=pal["ghost_c"])
    head(img, pal, HEAD_X + 4, HEAD_Y, shear=-4, tint=pal["ghost_m"])
    head(img, pal, HEAD_X, HEAD_Y, shear=-4, copper_phase=cop)
    title(img, pal, stutter=True, phase=scroll)
    tear(img, pal, TEAR_BANDS)
    return img


def f_title(pal, shear=3, phase=0.0, bar=0, cop=0):
    img = f_head(pal, shear=shear, phase=phase, cop=cop)
    title(img, pal, phase=bar)
    return img


def f_roll(pal, squeeze, cop=0):
    img = blank(pal)
    rays(img, pal, 0.2, squeeze)
    sy = max(1, int(SCALE * squeeze))
    head(img, pal, HEAD_X, (H - SH * sy) // 2, sy=sy, copper_phase=cop)
    d = ImageDraw.Draw(img)
    d.line([0, H // 2, W - 1, H // 2], fill=(255, 255, 255))
    return img


def f_rom(pal):
    """Where the sequence hands back: the existing amber ROM checklist."""
    img = Image.new("RGB", (W, H), (12, 8, 4))
    d = ImageDraw.Draw(img)
    ink, faint = (232, 168, 48), (140, 90, 28)
    inner = PAD + 3
    d.rectangle([PAD, PAD, W - PAD - 1, H - PAD - 1], outline=ink)
    d.rectangle([inner, inner, W - inner - 1, H - inner - 1], outline=faint)
    d.rectangle([inner + 1, inner + 1, W - inner - 2, inner + 26], fill=(28, 18, 8))
    gfx_font.draw_text(d, "HEADROOM", PAD + 10, PAD + 8, 2, ink)
    gfx_font.draw_text(d, "ROM", W - PAD - 42, PAD + 8, 2, faint)
    d.line([inner + 1, PAD + 30, W - inner - 2, PAD + 30], fill=ink)
    y = PAD + 42
    for label, status in [("CPU", "ESP32-S3"), ("HEAP", "212KB"), ("PSRAM", "OK"),
                          ("DISPLAY", "448x368"), ("PANEL", "OK"), ("TOUCH", "OK"),
                          ("RADIO", "3 AP")]:
        gfx_font.draw_text(d, label, PAD + 10, y, 2, ink)
        sw = gfx_font.text_width(status, 2)
        gfx_font.draw_text(d, status, W - PAD - 10 - sw, y, 2, ink)
        dx = PAD + 10 + gfx_font.text_width(label, 2) + 4
        while dx + 12 <= W - PAD - 14 - sw:
            gfx_font.draw_text(d, ".", dx, y, 2, faint)
            dx += 14
        y += 20
    for sy in range(PAD + 36, H - PAD - 4, 3):
        d.line([PAD + 4, sy, W - PAD - 4, sy], fill=(18, 12, 4))
    return img


# The backdrop rotates by this much per frame — slow enough to read as a sweep.
RAY_STEP = 0.035
COP_STEP = 5   # copper scroll per frame


def sequence(pal) -> list[tuple[str, Image.Image, int]]:
    """(label, frame, hold_ms) — the boot as it plays, matching the firmware."""
    seq = [("black", blank(pal), 200)]
    for i, sliver in enumerate((1, 4, 10, 24)):
        seq.append((f"strike {i}", f_strike(pal, sliver), 40))
    for i, rows in enumerate((11, 21, 31, 41, 51, SH)):
        seq.append((f"wipe {i}", f_wipe(pal, i * RAY_STEP, rows, i * COP_STEP), 50))
    for i, shear in enumerate((0, 2, 3, 2, 0, -2, -3)):
        seq.append((f"idle {i}", f_head(pal, shear, (6 + i) * RAY_STEP,
                                        (6 + i) * COP_STEP), 70))
    for i in range(3):
        seq.append((f"stutter {i}", f_stutter(pal, (13 + i) * RAY_STEP,
                                              (13 + i) * COP_STEP, i * 5), 70))
    seq.append(("settle", f_head(pal, -3, 16 * RAY_STEP, 16 * COP_STEP), 60))
    for i in range(14):
        seq.append((f"title {i}", f_title(pal, 2 if i % 4 < 2 else 3,
                                          (17 + i) * RAY_STEP, 40 + i * 5,
                                          (17 + i) * COP_STEP), 100))
    for i, sq in enumerate((0.7, 0.4, 0.16, 0.05)):
        seq.append((f"roll {i}", f_roll(pal, sq, 31 * COP_STEP), 45))
    seq.append(("rom", f_rom(pal), 1400))
    return seq


def sheet(frames, cols: int) -> Image.Image:
    gap, cap = 14, 22
    rows = (len(frames) + cols - 1) // cols
    out = Image.new("RGB", (cols * W + (cols + 1) * gap,
                            rows * (H + cap) + (rows + 1) * gap), (24, 22, 20))
    d = ImageDraw.Draw(out)
    for i, (name, img) in enumerate(frames):
        cx = gap + (i % cols) * (W + gap)
        cy = gap + (i // cols) * (H + cap + gap)
        out.paste(img, (cx, cy))
        gfx_font.draw_text(d, name.upper(), cx, cy + H + 5, 1, (170, 165, 158))
    return out


# ----------------------------------------------------------------- header ---
HEADER_TOP = """\
// Generated by scripts/render_esp32_boot.py — do not edit by hand.
// Max Headroom boot mask: {w}x{h}, one nibble per pixel, high nibble first.
// Inks: 0 transparent, 1 void (lenses, mouth), 5 hair, 6 edge; anything else
// is silhouette. Only VOID and EDGE are painted as themselves — the rest is a
// window onto the copper table below.
#pragma once
#include <Arduino.h>
#include <pgmspace.h>

static const int16_t MAX_W = {w};
static const int16_t MAX_H = {h};
static const int16_t MAX_STRIDE = {stride};
static const uint8_t MAX_INK_VOID = {void_ink};
static const uint8_t MAX_INK_HAIR = {hair_ink};
static const uint8_t MAX_INK_EDGE = {edge_ink};

// Copper bar field: one RGB565 per screen scanline, wrapping. Second table is
// the same ramp at {dim:.0%} for the panel's scanline gap.
static const int16_t MAX_COPPER_N = {ncop};
static const int16_t MAX_COPPER_BAND = {band};

static const uint8_t MAX_PIX[] PROGMEM = {{
"""


def rgb565(c) -> int:
    r, g, b = c
    return ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)


def emit_header(path: Path) -> None:
    stride = (SW + 1) // 2
    rows = []
    for r in SPRITE:
        packed = [(r[i] << 4) | (r[i + 1] if i + 1 < SW else 0)
                  for i in range(0, SW, 2)]
        rows.append("  " + "".join(f"0x{b:02X}," for b in packed))

    def table(name, cols):
        out = [f"\nstatic const uint16_t {name}[] PROGMEM = {{"]
        for i in range(0, len(cols), 8):
            out.append("  " + "".join(f"0x{rgb565(c):04X}," for c in cols[i:i + 8]))
        out.append("};")
        return "\n".join(out)

    cop = CHROMA["copper"]
    text = (HEADER_TOP.format(w=SW, h=SH, stride=stride, void_ink=VOID,
                              hair_ink=HAIR, edge_ink=EDGE, dim=DIM,
                              ncop=len(cop), band=COPPER_BAND)
            + "\n".join(rows) + "\n};\n"
            + table("MAX_COPPER", cop) + "\n"
            + table("MAX_COPPER_DIM", [dim(c) for c in cop]) + "\n")
    path.write_text(text)
    print(f"wrote {path} ({stride * SH} B mask + {len(cop) * 4} B copper)")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, help="directory for preview PNGs + GIF")
    ap.add_argument("--emit-header", type=Path, help="path for boot_max.h")
    ap.add_argument("--palette", choices=("chroma", "amber"), default="chroma")
    args = ap.parse_args()

    if args.emit_header:
        emit_header(args.emit_header)

    if args.out:
        pal = CHROMA if args.palette == "chroma" else AMBER
        args.out.mkdir(parents=True, exist_ok=True)
        keys = [("1 strike", f_strike(pal, 10)),
                ("2 wipe", f_wipe(pal, 0.1, 31, 20)),
                ("3 head", f_head(pal, 2, 0.2, 40)),
                ("4 stutter", f_stutter(pal, 0.3, 60, 30)),
                ("5 title", f_title(pal, 3, 0.4, 90, 80)),
                ("6 roll", f_roll(pal, 0.22, 100)),
                ("7 rom", f_rom(pal))]
        for name, img in keys:
            img.save(args.out / f"boot-{name.replace(' ', '-')}.png")
        sheet(keys, 2).save(args.out / "boot-sheet.png")
        seq = sequence(pal)
        gif = [f.convert("P", palette=Image.ADAPTIVE, colors=96) for _, f, _ in seq]
        gif[0].save(args.out / "boot.gif", save_all=True, append_images=gif[1:],
                    duration=[ms for _, _, ms in seq], loop=0, disposal=2)
        print(f"wrote previews to {args.out}")


if __name__ == "__main__":
    main()
