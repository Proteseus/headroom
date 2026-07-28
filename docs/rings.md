# Headroom rings

The rings are one indicator with the same meaning on macOS, iOS, widgets, the
menu bar, and the desk display.

- A provider uses at most two concentric bands.
- The fastest quota window is the outer band.
- The provider accent is the usage arc; arcs begin at 12 o'clock and grow
  clockwise.
- The track is the same accent mixed 20% over the surface.
- The usage arc has round ends. The cap is half the band thickness, and the arc
  is pulled in by that much at each end, so the painted arc still covers exactly
  the percentage used.
- The dot is the expected usage at the current point in time. It rides inside
  the band and is sized off the band thickness, so it is the same dot on inner
  and outer rings. The distance between the arc and the dot shows whether usage
  is ahead of or behind pace.
- Missing data draws a track without inventing zero usage.

`Shared/HeadroomRings.swift` is the Swift implementation. The constants beside
`drawPaceRing` in `firmware/src/main.cpp` mirror it for the embedded display.
The app icon is the same glyph without pace dots — three bands at 90 / 60 / 30
percent, rendered by `scripts/render_icon.py` into both asset catalogs and the
App Store PNG.

User-facing names for charts and sections live in [`docs/glossary.md`](glossary.md).
