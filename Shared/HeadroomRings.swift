import SwiftUI

/// One quota pool in the Headroom rings glyph.
///
/// Layers are ordered outside-in. Every surface uses at most two: the fastest
/// quota window first, followed by the slower window.
struct HeadroomRingLayer: Identifiable, Sendable {
    let id: String
    let percent: Double?
    let pacePercent: Double?
}

/// The visual contract shared by macOS, iOS, widgets, and mirrored in firmware.
enum HeadroomRingStyle {
    static let maximumLayerCount = 2
    static let trackOpacity = 0.20
    static let strokeRatio = 7.0 / 72.0
    static let spacingRatio = 4.0 / 72.0
    static let minimumSweepDegrees = 2.0

    /// The pace dot rides inside the band, leaving a sliver of it on each side
    /// so the dot never overhangs into the gap between two rings.
    static func paceDotDiameter(for lineWidth: CGFloat) -> CGFloat {
        max(2, lineWidth * 5 / 7)
    }

    /// How far a round cap bulges past the end of an arc, in degrees.
    ///
    /// The cap adds half a stroke at each end. Pulling the drawn arc in by
    /// that much keeps the painted sweep equal to the real one, so the gap to
    /// the pace dot still reads as the deficit.
    static func capInsetDegrees(lineWidth: CGFloat, radius: CGFloat) -> Double {
        guard radius > 0 else { return 0 }
        return Double(lineWidth / 2 / radius) * 180 / .pi
    }
}

/// Headroom's canonical quota indicator.
///
/// The accent arc is usage. The contrasting dot is where an even burn would be
/// now, making the gap between the two the useful signal.
struct HeadroomRings: View {
    let layers: [HeadroomRingLayer]
    let tint: Color
    var indicatorColor: Color = .primary

    private var visibleLayers: [HeadroomRingLayer] {
        let values = Array(layers.prefix(HeadroomRingStyle.maximumLayerCount))
        return values.isEmpty
            ? [HeadroomRingLayer(id: "unavailable", percent: nil, pacePercent: nil)]
            : values
    }

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let lineWidth = max(3, side * HeadroomRingStyle.strokeRatio)
            let spacing = max(2, side * HeadroomRingStyle.spacingRatio)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            var radius = side / 2 - lineWidth / 2 - 1

            for layer in visibleLayers {
                guard radius > lineWidth else { break }
                draw(
                    layer,
                    radius: radius,
                    lineWidth: lineWidth,
                    center: center,
                    context: &context
                )
                radius -= lineWidth + spacing
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func draw(
        _ layer: HeadroomRingLayer,
        radius: CGFloat,
        lineWidth: CGFloat,
        center: CGPoint,
        context: inout GraphicsContext
    ) {
        let rect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        var track = Path()
        track.addEllipse(in: rect)
        context.stroke(
            track,
            with: .color(tint.opacity(HeadroomRingStyle.trackOpacity)),
            lineWidth: lineWidth
        )

        if let percent = layer.percent {
            let clamped = max(0, min(percent, 100))
            var sweep = clamped * 3.6
            if clamped > 0 {
                sweep = max(sweep, HeadroomRingStyle.minimumSweepDegrees)
            }
            let cap = HeadroomRingStyle.capInsetDegrees(
                lineWidth: lineWidth,
                radius: radius
            )
            if cap * 2 < sweep {
                var usage = Path()
                usage.addArc(
                    center: center,
                    radius: radius,
                    startAngle: .degrees(-90 + cap),
                    endAngle: .degrees(-90 + sweep - cap),
                    clockwise: false
                )
                context.stroke(
                    usage,
                    with: .color(tint),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
            } else if sweep > 0 {
                // Shorter than its own two caps: a zero-length stroked arc is
                // not reliably drawn, so paint the cap itself.
                context.fill(dot(at: -90 + sweep / 2, radius: radius, center: center,
                                 diameter: lineWidth), with: .color(tint))
            }
        }

        if let pacePercent = layer.pacePercent {
            let angle = -90 + max(0, min(pacePercent, 100)) * 3.6
            context.fill(
                dot(
                    at: angle,
                    radius: radius,
                    center: center,
                    diameter: HeadroomRingStyle.paceDotDiameter(for: lineWidth)
                ),
                with: .color(indicatorColor)
            )
        }
    }

    /// A dot centred on the band at `angle`.
    private func dot(
        at angle: Double,
        radius: CGFloat,
        center: CGPoint,
        diameter: CGFloat
    ) -> Path {
        let radians = angle * .pi / 180
        let point = CGPoint(
            x: center.x + CGFloat(cos(radians)) * radius,
            y: center.y + CGFloat(sin(radians)) * radius
        )
        return Path(ellipseIn: CGRect(
            x: point.x - diameter / 2,
            y: point.y - diameter / 2,
            width: diameter,
            height: diameter
        ))
    }

    private var accessibilitySummary: String {
        visibleLayers.map { layer in
            guard let percent = layer.percent else {
                return "\(layer.id) unavailable"
            }
            var value = "\(layer.id) \(Int(percent.rounded())) percent used"
            if let pace = layer.pacePercent {
                value += ", \(Int(pace.rounded())) percent pace"
            }
            return value
        }
        .joined(separator: ", ")
    }
}
