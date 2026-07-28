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

    static func paceLineWidth(for side: CGFloat) -> CGFloat {
        max(1, side * 2 / 72)
    }

    static func paceOvershoot(for side: CGFloat) -> CGFloat {
        max(0.75, side * 1.5 / 72)
    }
}

/// Headroom's canonical quota indicator.
///
/// The accent arc is usage. The contrasting line is where an even burn would
/// be now, making the gap between the two the useful signal.
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
                    side: side,
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
        side: CGFloat,
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
            var usage = Path()
            usage.addArc(
                center: center,
                radius: radius,
                startAngle: .degrees(-90),
                endAngle: .degrees(-90 + sweep),
                clockwise: false
            )
            context.stroke(
                usage,
                with: .color(tint),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
            )
        }

        if let pacePercent = layer.pacePercent {
            let angle = -90 + max(0, min(pacePercent, 100)) * 3.6
            let radians = angle * .pi / 180
            let overshoot = HeadroomRingStyle.paceOvershoot(for: side)
            let innerRadius = radius - lineWidth / 2 - overshoot
            let outerRadius = radius + lineWidth / 2 + overshoot
            let unitX = CGFloat(cos(radians))
            let unitY = CGFloat(sin(radians))
            var indicator = Path()
            indicator.move(to: CGPoint(
                x: center.x + unitX * innerRadius,
                y: center.y + unitY * innerRadius
            ))
            indicator.addLine(to: CGPoint(
                x: center.x + unitX * outerRadius,
                y: center.y + unitY * outerRadius
            ))
            context.stroke(
                indicator,
                with: .color(indicatorColor),
                style: StrokeStyle(
                    lineWidth: HeadroomRingStyle.paceLineWidth(for: side),
                    lineCap: .butt
                )
            )
        }
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
