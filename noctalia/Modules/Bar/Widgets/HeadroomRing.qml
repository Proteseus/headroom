import QtQuick
import QtQuick.Shapes
import Quickshell
import qs.Commons

// HeadroomRing.qml — the canonical Headroom quota glyph, ported from
// Shared/HeadroomRings.swift.
//
// Concentric bands, outside-in: longer windows first. Most providers use two
// bands; OpenCode Go uses three (month, week, 5h). Each band draws:
//   - a track at `tint` with 20% opacity (HeadroomRingStyle.trackOpacity)
//   - a usage arc with round caps, sweep = pct * 3.6 degrees (min 2 deg)
//   - a pace dot riding the band at pacePct, in `indicatorColor` — the gap
//     between arc and dot is the signal (burning ahead / behind schedule).
//
// Two-band geometry mirrors the Swift constants. Three-band glyphs tighten
// the strokes and gutters so every circle remains legible at bar size:
//   lineWidth = max(3, side * 7/72)
//   spacing   = max(2, side * 4/72)
//   radius    = side/2 - lineWidth/2 - 1, then inward by lineWidth+spacing
Item {
  id: root

  // Each layer: { id, name, percent (0-100 used), pacePercent (0-100) }
  // Ordered outside-in by the caller (longer window first).
  property var layers: []
  // Provider tint. Passed in so the host accent hex / builtin firmware
  // triple is resolved once by the caller, exactly like QuotaPresentation.
  property color tint: Color.mOnSurface
  // Pace dot color — primary on every surface the original draws.
  property color indicatorColor: Color.mOnSurface
  // Diameter in logical pixels.
  property int diameter: 24
  // Set true when the provider has no reading yet (draws the empty band).
  property bool unavailable: false

  implicitWidth: diameter
  implicitHeight: diameter

  // Repaint when inputs change. Declared on the root (where the properties
  // live) and routed to the canvas — change handlers inside the canvas would
  // need the properties to exist on the canvas itself.
  onLayersChanged: canvas.requestPaint()
  onTintChanged: canvas.requestPaint()
  onIndicatorColorChanged: canvas.requestPaint()
  onDiameterChanged: canvas.requestPaint()
  onUnavailableChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent

    onPaint: {
      const ctx = getContext("2d");
      ctx.reset();
      const side = root.diameter;
      const layers = root.unavailable ? [] : root.layers;
      const dense = layers.length >= 3;
      const lineWidth = dense ? Math.max(1.5, side * 5 / 72)
                              : Math.max(3, side * 7 / 72);
      const spacing = dense ? Math.max(1, side * 2 / 72)
                            : Math.max(2, side * 4 / 72);
      const center = side / 2;
      let radius = side / 2 - lineWidth / 2 - 1;

      if (layers.length === 0) {
        // The one empty band a glyph draws when it has nothing to show.
        drawTrack(ctx, center, center, radius, lineWidth);
        return;
      }

      for (let i = 0; i < layers.length; ++i) {
        if (radius <= lineWidth) break;
        const layer = layers[i];
        drawTrack(ctx, center, center, radius, lineWidth);
        if (layer.percent !== null && layer.percent !== undefined) {
          drawUsage(ctx, center, center, radius, lineWidth, layer.percent);
        }
        if (layer.pacePercent !== null && layer.pacePercent !== undefined) {
          drawPaceDot(ctx, center, center, radius, lineWidth, layer.pacePercent);
        }
        radius -= lineWidth + spacing;
      }
    }

    function drawTrack(ctx, cx, cy, r, lw) {
      ctx.beginPath();
      ctx.arc(cx, cy, r, 0, Math.PI * 2);
      ctx.lineWidth = lw;
      ctx.strokeStyle = Qt.rgba(root.tint.r, root.tint.g, root.tint.b, 0.20);
      ctx.stroke();
    }

    function drawUsage(ctx, cx, cy, r, lw, percent) {
      const clamped = Math.max(0, Math.min(percent, 100));
      let sweep = clamped * 3.6;
      if (clamped > 0) sweep = Math.max(sweep, 2); // minimumSweepDegrees
      const cap = lw / 2 / r * 180 / Math.PI; // capInsetDegrees
      if (cap * 2 < sweep) {
        ctx.beginPath();
        ctx.arc(cx, cy, r, (-90 + cap) * Math.PI / 180,
                (-90 + sweep - cap) * Math.PI / 180, false);
        ctx.lineWidth = lw;
        ctx.lineCap = "round";
        ctx.strokeStyle = root.tint;
        ctx.stroke();
      } else if (sweep > 0) {
        // Shorter than its own two caps: paint the cap itself.
        const angle = (-90 + sweep / 2) * Math.PI / 180;
        ctx.beginPath();
        ctx.arc(cx + Math.cos(angle) * r, cy + Math.sin(angle) * r,
                lw / 2, 0, Math.PI * 2);
        ctx.fillStyle = root.tint;
        ctx.fill();
      }
    }

    function drawPaceDot(ctx, cx, cy, r, lw, pacePercent) {
      const angle = (-90 + Math.max(0, Math.min(pacePercent, 100)) * 3.6)
                    * Math.PI / 180;
      const d = Math.max(2, lw * 5 / 7); // paceDotDiameter
      ctx.beginPath();
      ctx.arc(cx + Math.cos(angle) * r, cy + Math.sin(angle) * r, d / 2, 0, Math.PI * 2);
      ctx.fillStyle = root.indicatorColor;
      ctx.fill();
    }
  }
}
