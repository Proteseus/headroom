import AppKit
import SwiftUI

// `Color.drained()` lives in Shared/DrainedColor.swift — both apps drain
// exhausted quota the same way.

/// Adapted from the MIT-licensed `UsageProgressBar` in steipete/CodexBar.
/// Geometry matches its 6pt capsule; the pace mark is Headroom's ring-style
/// dot rather than CodexBar's punched stripe.
struct CodexBarProgressBar: View {
    let percent: Double
    let tint: Color
    let pacePercent: Double?
    let accessibilityLabel: String

    var body: some View {
        Canvas { context, size in
            let fillWidth = size.width * renderedFillPercent / 100
            let cornerRadius = size.height / 2
            let cornerSize = CGSize(width: cornerRadius, height: cornerRadius)
            let rect = CGRect(origin: .zero, size: size)
            let fillTint = clampedPercent >= 100 ? tint.drained() : tint

            context.clip(to: Path(rect))
            let track = Path {
                $0.addRoundedRect(in: rect, cornerSize: cornerSize)
            }
            context.fill(
                track,
                with: .color(Color(nsColor: .tertiaryLabelColor).opacity(0.22))
            )

            if fillWidth > 0 {
                let fillRect = CGRect(
                    x: 0,
                    y: 0,
                    width: min(fillWidth, size.width),
                    height: size.height
                )
                let fill = Path {
                    $0.addRoundedRect(in: fillRect, cornerSize: cornerSize)
                }
                context.fill(fill, with: .color(fillTint))
            }

            if let pacePercent {
                let paceX = size.width * clamped(pacePercent) / 100
                let diameter = HeadroomRingStyle.paceDotDiameter(
                    for: size.height
                )
                let radius = diameter / 2
                let cx = min(
                    max(paceX, radius),
                    size.width - radius
                )
                let cy = size.height / 2
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: cx - radius,
                        y: cy - radius,
                        width: diameter,
                        height: diameter
                    )),
                    // Same neutral pace mark the quota rings use.
                    with: .color(.primary)
                )
            }
        }
        .frame(height: 6)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue("\(Int(clampedPercent.rounded())) percent")
    }

    private var clampedPercent: Double {
        min(100, max(0, percent))
    }

    private var renderedFillPercent: Double {
        let displayPercent = Int(clampedPercent.rounded())
        if displayPercent <= 0 { return 0 }
        if displayPercent >= 100 { return 100 }
        return clampedPercent
    }

    private func clamped(_ value: Double) -> Double {
        min(100, max(0, value))
    }
}
