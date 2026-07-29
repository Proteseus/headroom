import AppKit
import SwiftUI

/// The Liquid Glass layer for the welcome window, in one file so the
/// availability gates live in a single place.
///
/// `glassEffect`, `Glass`, `GlassEffectContainer` and `.buttonStyle(.glass)`
/// are all macOS 26.0+, and this app deploys to macOS 14. Every helper here
/// therefore ships two looks: real glass on 26 and later, and a material-and-
/// hairline approximation below it. The fallback is not a downgrade to flat —
/// it is the same layout with `.ultraThinMaterial` doing the refracting.
enum WelcomeGlass {
    /// True when the running system can actually draw Liquid Glass. Layout
    /// that only makes sense over real glass keys off this.
    static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

// MARK: - Window base

/// `NSVisualEffectView` behind the whole window. Glass needs something with
/// depth underneath it or it reads as a grey rectangle, and on macOS the
/// vibrancy view is what the system itself puts there.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// A soft wash of the product palette under the glass.
///
/// Liquid Glass refracts what is behind it, so a window with a uniform
/// background gets uniform, lifeless glass. These are wide, low-opacity pools
/// of the same accents the meters use, which is what gives the panels their
/// colour shifts as they move down the window.
struct WelcomeBackdrop: View {
    var body: some View {
        ZStack {
            VisualEffectBackground()
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack {
                    wash(HeadroomPalette.claude, at: CGPoint(x: w * 0.12, y: h * 0.08),
                         radius: max(w, h) * 0.55)
                    wash(HeadroomPalette.green, at: CGPoint(x: w * 0.95, y: h * 0.28),
                         radius: max(w, h) * 0.5)
                    wash(HeadroomPalette.cursor, at: CGPoint(x: w * 0.75, y: h * 1.02),
                         radius: max(w, h) * 0.6)
                }
                .blur(radius: 24)
            }
        }
        .ignoresSafeArea()
    }

    private func wash(_ color: Color, at point: CGPoint, radius: CGFloat) -> some View {
        RadialGradient(
            colors: [color.opacity(0.22), color.opacity(0)],
            center: .init(x: point.x / max(radius, 1), y: point.y / max(radius, 1)),
            startRadius: 0,
            endRadius: radius
        )
        .frame(width: radius * 2, height: radius * 2)
        .position(point)
    }
}

// MARK: - Panels

/// A floating glass panel. `tint` colours the glass itself on 26 and later,
/// rather than painting a background behind it.
struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 16
    var tint: Color?
    var interactive: Bool = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            content.glassEffect(
                Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.28), .white.opacity(0.06),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
                )
                .overlay(shape.fill(tint?.opacity(0.14) ?? .clear))
                .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
        }
    }
}

extension View {
    /// Glass panel with the window's standard corner radius.
    func glassPanel(
        cornerRadius: CGFloat = 16,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(
            GlassPanel(
                cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }

    /// `.glass` / `.glassProminent` where they exist, bordered below.
    func glassButton(prominent: Bool = false) -> some View {
        modifier(GlassButtonStyleModifier(prominent: prominent))
    }

    /// Wraps a group of glass shapes so they merge and separate as they move
    /// past each other. A no-op below macOS 26.
    @ViewBuilder
    func glassGroup(spacing: CGFloat? = nil) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}

private struct GlassButtonStyleModifier: ViewModifier {
    var prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            if prominent {
                content.buttonStyle(.borderedProminent)
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }
}

/// The rail's moving selection. One glass shape with a stable id, so on 26 and
/// later it flows from row to row instead of cross-fading in place.
struct GlassSelection: View {
    var namespace: Namespace.ID
    var cornerRadius: CGFloat = 11

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(Glass.regular.interactive(), in: shape)
                .glassEffectID("welcome.rail.selection", in: namespace)
        } else {
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.strokeBorder(.white.opacity(0.2), lineWidth: 0.8))
        }
    }
}
