# Headroom rings

The rings are one indicator with the same meaning on macOS, iOS, widgets, the
menu bar, and the desk display.

- A provider uses at most two concentric bands.
- The fastest quota window is the outer band.
- The provider accent is the usage arc; arcs begin at 12 o'clock and grow
  clockwise.
- The track is the same accent mixed 20% over the surface.
- The usage arc has square ends.
- The fixed-width radial line is the expected usage at the current point in
  time. It crosses the band instead of following its curve, so it has the same
  shape on inner and outer rings. The distance between the arc and line shows
  whether usage is ahead of or behind pace.
- Missing data draws a track without inventing zero usage.

`Shared/HeadroomRings.swift` is the Swift implementation. The constants beside
`drawPaceRing` in `firmware/src/main.cpp` mirror it for the embedded display.

User-facing names for charts and sections live in [`docs/glossary.md`](glossary.md).
