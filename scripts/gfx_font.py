"""The classic 5x7 bitmap font Arduino_GFX draws with by default.

The firmware never calls setFont(), so every string on the ESP32 panel is this
face at setTextSize(2) or (3). Rendering README previews in a desktop monospace
TTF made the screenshots look like a different device, so the glyph table lives
here and scripts/render_esp32_preview.py blits it pixel-for-pixel.

Glyph data is the "classic" fixed-space 5x7 font from Adafruit-GFX
(font/glcdfont.h, BSD licence, Copyright (c) 2012 Adafruit Industries),
codepoints 0x20-0x7F only. See THIRD_PARTY_NOTICES.md.

Metrics copied from Arduino_GFX::drawChar's glcdfont branch: a cell is
6*size wide by 8*size tall, the glyph is 5 columns x 8 rows with bit 0 at the
top, and each set bit paints a size x size block. getTextBounds returns
len * 6 * size, trailing spacer column included.
"""

from __future__ import annotations

import base64

FIRST = 0x20
LAST = 0x7F
CELL_W = 6
CELL_H = 8

_GLYPHS = base64.b64decode(
    "AAAAAAAAAF8AAAAHAAcAFH8UfxQkKn8qEiMTCGRiNklWIFAACAcDAAAcIkEAAEEiHAAq"
    "HH8cKggIPggIAIBwMAAICAgICAAAYGAAIBAIBAI+UUlFPgBCf0AAcklJSUYhQUlNMxgU"
    "En8QJ0VFRTk8SklJMUEhEQkHNklJSTZGSUkpHgAAFAAAAEA0AAAACBQiQRQUFBQUAEEi"
    "FAgCAVkJBj5BXVlOfBIREnx/SUlJNj5BQUEif0FBQT5/SUlJQX8JCQkBPkFBUXN/CAgI"
    "fwBBf0EAIEBBPwF/CBQiQX9AQEBAfwIcAn9/BAgQfz5BQUE+fwkJCQY+QVEhXn8JGSlG"
    "JklJSTIDAX8BAz9AQEA/HyBAIB8/QDhAP2MUCBRjAwR4BANhWUlNQwB/QUFBAgQIECAA"
    "QUFBfwQCAQIEQEBAQEAAAwcIACBUVHhAfyhERDg4REREKDhERCh/OFRUVBgACH4JAhik"
    "pJx4fwgEBHgARH1AACBAQD0AfxAoRAAAQX9AAHwEeAR4fAgEBHg4REREOPwYJCQYGCQk"
    "GPx8CAQECEhUVFQkBAQ/RCQ8QEAgfBwgQCAcPEAwQDxEKBAoREyQkJB8RGRUTEQACDZB"
    "AAAAdwAAAEE2CAACAQIEAjwmIyY8"
)


def text_width(s: str, size: int) -> int:
    """Width in pixels, matching gfx->getTextBounds(s, ...).w."""
    return len(s) * CELL_W * size


def text_height(size: int) -> int:
    return CELL_H * size


def draw_text(draw, s: str, x: int, y: int, size: int, fill) -> None:
    """Blit `s` with its top-left cell corner at (x, y), like setCursor+print."""
    cx = x
    for ch in s:
        code = ord(ch)
        if code < FIRST or code > LAST:
            code = ord("?")
        off = (code - FIRST) * 5
        for col in range(5):
            bits = _GLYPHS[off + col]
            if not bits:
                continue
            px = cx + col * size
            for row in range(8):
                if bits >> row & 1:
                    py = y + row * size
                    draw.rectangle([px, py, px + size - 1, py + size - 1], fill=fill)
        cx += CELL_W * size
