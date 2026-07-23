import AppKit
import SwiftUI

extension Color {
    /// Desaturated brand color for exhausted quota — never alarm red.
    func drained(
        saturationScale: CGFloat = 0.38,
        brightnessScale: CGFloat = 0.78
    ) -> Color {
        let ns = NSColor(self)
        guard let rgb = ns.usingColorSpace(.deviceRGB) else {
            return opacity(0.45)
        }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        )
        return Color(
            hue: hue,
            saturation: saturation * saturationScale,
            brightness: min(1, brightness * brightnessScale + 0.12),
            opacity: alpha
        )
    }
}

/// Adapted from the MIT-licensed `UsageProgressBar` in steipete/CodexBar.
/// Geometry intentionally matches its 6pt capsule and punched pace stripe.
struct CodexBarProgressBar: View {
    let percent: Double
    let tint: Color
    let pacePercent: Double?
    let paceOnTop: Bool
    let accessibilityLabel: String

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Canvas { context, size in
            let scale = max(displayScale, 1)
            let fillWidth = size.width * renderedFillPercent / 100
            let paceWidth = size.width * clamped(pacePercent) / 100
            let tipWidth = max(25, size.height * 6.5)
            let stripeWidth: CGFloat = 2
            let stripeSpan = stripeWidth * 3
            let stripeInset = 1 / scale
            let tipOffset = paceWidth - tipWidth + stripeSpan / 2 + stripeInset
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

            if pacePercent != nil {
                let stripes = paceStripePaths(
                    size: CGSize(width: tipWidth, height: size.height),
                    scale: scale
                )
                let shift = CGAffineTransform(translationX: tipOffset, y: 0)

                context.blendMode = .destinationOut
                context.fill(
                    stripes.punched.applying(shift),
                    with: .color(.white.opacity(0.9))
                )
                context.blendMode = .normal
                context.fill(
                    stripes.center.applying(shift),
                    with: .color(paceOnTop ? .green : tint.drained())
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

    private func clamped(_ value: Double?) -> Double {
        guard let value else { return 0 }
        return min(100, max(0, value))
    }

    private func paceStripePaths(
        size: CGSize,
        scale: CGFloat
    ) -> (punched: Path, center: Path) {
        let extend = size.height * 2
        let align: (CGFloat) -> CGFloat = {
            ($0 * scale).rounded() / scale
        }
        let stripeWidth: CGFloat = 2
        let punchWidth = stripeWidth * 3
        let anchorX = align(size.width - 1 / scale)
        let minY = align(-extend)
        let maxY = align(size.height + extend)
        let punchLeft = anchorX - punchWidth

        var punched = Path()
        punched.addRect(
            CGRect(
                x: punchLeft,
                y: minY,
                width: punchWidth,
                height: maxY - minY
            )
        )

        var center = Path()
        center.addRect(
            CGRect(
                x: align(punchLeft + (punchWidth - stripeWidth) / 2),
                y: minY,
                width: stripeWidth,
                height: maxY - minY
            )
        )
        return (punched, center)
    }
}
