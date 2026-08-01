import SwiftUI

/// One quota pool in the Headroom rings glyph.
///
/// Layers are ordered outside-in. Most surfaces use at most two: the longer
/// quota window first (week), then the shorter (session). The watch's combined
/// dial spends its bands on providers instead, which is what `tint` is for —
/// one glyph, one hue per band.
struct HeadroomRingLayer: Identifiable, Sendable {
    /// Stable identity — a pool id, a provider id. Never spoken or drawn.
    let id: String
    /// What this band is called out loud.
    ///
    /// Speech is a text-only surface, so this is the host's full `title`
    /// (`Claude · Work`) wherever a band stands for a provider, not the `label`
    /// the glyph draws beside its mark. Where the bands are one provider's
    /// pools, it is the pool's title and the provider is named next to the
    /// glyph — see `docs/glossary.md`, "Sources (host registry titles)".
    ///
    /// It has no default on purpose. A band that arrives without a name would
    /// fall back to `id` and speak `claude:work` as "claude colon work", which
    /// is the thing this exists to stop.
    let name: String
    let percent: Double?
    let pacePercent: Double?
    /// Band colour when one glyph mixes providers. Nil falls back to the view's
    /// `tint`, which is every surface that draws a single provider.
    var tint: Color?

    init(
        id: String,
        name: String,
        percent: Double?,
        pacePercent: Double?,
        tint: Color? = nil
    ) {
        self.id = id
        self.name = name
        self.percent = percent
        self.pacePercent = pacePercent
        self.tint = tint
    }

    /// The one empty band a glyph draws when it has nothing to show.
    ///
    /// Shared with the watch, which reaches the same state by its own route.
    /// Spoken it is "Quotas, no reading" — the id used to stand in for the name
    /// here too, which named nothing at all. The state word follows the rest of
    /// the product rather than saying "unavailable", which the glossary guard
    /// rejects and which named a failure where the fact is that no number has
    /// arrived yet.
    static let empty = HeadroomRingLayer(
        id: "unavailable",
        name: HeadroomCopy.quotas,
        percent: nil,
        pacePercent: nil
    )
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

/// Band proportions for one family of surfaces.
///
/// `standard` is the shipped look on Mac, iPhone, and the home-screen widgets.
/// The watch needs its own because it draws a third band at a third of the
/// diameter, where the shipped ratios leave the inner ring too thin to read.
struct HeadroomRingProfile: Sendable {
    var maximumLayerCount = HeadroomRingStyle.maximumLayerCount
    var strokeRatio = HeadroomRingStyle.strokeRatio
    var spacingRatio = HeadroomRingStyle.spacingRatio
    var minimumStroke: CGFloat = 3
    var minimumSpacing: CGFloat = 2

    static let standard = HeadroomRingProfile()

    /// One band per provider on a complication-sized dial. Thicker bands so a
    /// 30pt circular still reads, tighter gaps so the third band clears the
    /// `radius > lineWidth` floor instead of being dropped.
    static let watch = HeadroomRingProfile(
        maximumLayerCount: 3,
        strokeRatio: 8.0 / 72.0,
        spacingRatio: 3.0 / 72.0,
        minimumStroke: 2,
        minimumSpacing: 1.5
    )
}

/// Which half of the glyph to paint.
///
/// Every surface draws `.all` in one pass. The split exists for a caller that
/// has to spread the glyph across two tint groups — the watch complication did
/// until it opted out of face tinting with `.widgetAccentable(false)` and got
/// its real colours back (`docs/watch.md`).
enum HeadroomRingPass: Sendable {
    case all
    case bands
    case pace

    var drawsBands: Bool { self != .pace }
    var drawsPace: Bool { self != .bands }
}

/// Headroom's canonical quota indicator.
///
/// The accent arc is usage. The contrasting dot is where an even burn would be
/// now, making the gap between the two the useful signal.
struct HeadroomRings: View {
    let layers: [HeadroomRingLayer]
    let tint: Color
    var indicatorColor: Color = .primary
    var profile: HeadroomRingProfile = .standard
    var pass: HeadroomRingPass = .all

    private var visibleLayers: [HeadroomRingLayer] {
        let values = Array(layers.prefix(profile.maximumLayerCount))
        return values.isEmpty
            ? [HeadroomRingLayer.empty]
            : values
    }

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let lineWidth = max(
                profile.minimumStroke, side * profile.strokeRatio
            )
            let spacing = max(
                profile.minimumSpacing, side * profile.spacingRatio
            )
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
        // The pace pass is the same glyph a second time. Letting it keep a
        // label would make VoiceOver read every ring twice.
        .accessibilityLabel(pass == .pace ? "" : accessibilitySummary)
        .accessibilityHidden(pass == .pace)
    }

    private func draw(
        _ layer: HeadroomRingLayer,
        radius: CGFloat,
        lineWidth: CGFloat,
        center: CGPoint,
        context: inout GraphicsContext
    ) {
        let bandTint = layer.tint ?? tint
        let rect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        if pass.drawsBands {
            var track = Path()
            track.addEllipse(in: rect)
            context.stroke(
                track,
                with: .color(bandTint.opacity(HeadroomRingStyle.trackOpacity)),
                lineWidth: lineWidth
            )
        }

        if pass.drawsBands, let percent = layer.percent {
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
                    with: .color(bandTint),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
            } else if sweep > 0 {
                // Shorter than its own two caps: a zero-length stroked arc is
                // not reliably drawn, so paint the cap itself.
                context.fill(dot(at: -90 + sweep / 2, radius: radius, center: center,
                                 diameter: lineWidth), with: .color(bandTint))
            }
        }

        if pass.drawsPace, let pacePercent = layer.pacePercent {
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

    /// Spoken in the order the glossary fixes for every surface: name, then
    /// value, then state.
    ///
    /// `layer.name` is the band's own title, which is the model change the copy
    /// pass named and deferred — until it landed this read `layer.id` and spoke
    /// a named extra login as "claude colon work".
    ///
    /// "Unavailable" stays gone, here as in the service rows: it named a
    /// failure where the honest fact is that there is no number yet.
    private var accessibilitySummary: String {
        visibleLayers.map { layer in
            guard let percent = layer.percent else {
                return "\(layer.name), no reading"
            }
            var value = "\(layer.name), \(Int(percent.rounded())) percent used"
            if let pace = layer.pacePercent {
                value += ", \(Int(pace.rounded())) percent pace"
            }
            return value
        }
        .joined(separator: ", ")
    }
}
