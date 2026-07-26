import SwiftUI

/// The quota half of the popover: the three-ring overview, the single-provider
/// detail card, and the attention summary.

struct QuotaOverviewCard: View {
    let snapshot: UsageSnapshot
    /// Tapping a ring jumps to that provider's detail tab.
    let onSelect: (UsageProvider) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Coding quotas")
                .font(.headline)
            HStack(spacing: 10) {
                ForEach(UsageProvider.allCases, id: \.rawValue) { provider in
                    ProviderQuotaRing(
                        meter: snapshot.meter(for: provider),
                        rings: snapshot.burndownRings(for: provider),
                        tint: provider.tint
                    )
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(provider) }
                }
            }
            if let primary = snapshot.burndownPrimary, let headline = primary.headline {
                Text(headline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cardStyle()
    }
}

struct ProviderQuotaCard: View {
    let provider: UsageProvider
    let meter: ProviderMeter

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(provider.title)
                    .font(.headline)
                Spacer()
                Text(meter.plan ?? "—")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            QuotaRow(window: meter.primary, tint: provider.tint)
            QuotaRow(window: meter.secondary, tint: provider.tint)
            if let tertiary = meter.tertiary {
                QuotaRow(window: tertiary, tint: provider.tint)
            }
            if let pace = meter.paceLabel {
                HStack {
                    Text(pace)
                    Spacer()
                    if let runsOut = meter.runsOutIn {
                        Text("Runs out in \(runsOut)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let cost = meter.costLabel {
                Text(cost)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !meter.ok, let error = meter.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .cardStyle()
    }
}

struct AttentionCard: View {
    let snapshot: UsageSnapshot
    @AppStorage(AttentionAck.defaultsKey)
    private var dismissedFingerprint = ""

    var body: some View {
        let attention = snapshot.attention
        let reasons = attention?.reasons ?? []
        let showPip = AttentionAck.shouldShowPip(
            for: attention,
            dismissedFingerprint: dismissedFingerprint.isEmpty
                ? nil
                : dismissedFingerprint
        )
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Attention")
                    .font(.headline)
                Spacer()
                if showPip, let attention {
                    Button {
                        dismissedFingerprint = attention.fingerprint
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear attention")
                    .accessibilityLabel("Clear attention")
                } else if attention?.isWarning == true {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .help("Cleared until something new")
                        .accessibilityLabel("Attention cleared")
                } else {
                    Text(attention?.summary ?? "All clear")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(attentionTint(attention?.level))
                        .lineLimit(1)
                }
            }
            if !reasons.isEmpty {
                ForEach(reasons.prefix(5)) { reason in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(attentionTint(reason.level))
                            .frame(width: 7, height: 7)
                            .padding(.top, 4)
                        Text(reason.summary ?? "Needs attention")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            HStack(spacing: 10) {
                GlanceStat(
                    value: String(snapshot.local?.servers?.count ?? 0),
                    label: "servers"
                )
                GlanceStat(
                    value: snapshot.today?.costUSD.map(\.dollarLabel) ?? "—",
                    label: "Claude today"
                )
                GlanceStat(
                    value: snapshot.codex?.costLabel
                        ?? snapshot.codex?.costUSD.map(\.dollarLabel)
                        ?? "—",
                    label: "Codex"
                )
                GlanceStat(
                    value: snapshot.cursor?.costLabel ?? "—",
                    label: "Cursor"
                )
            }
        }
        .cardStyle()
    }
}

struct QuotaRow: View {
    let window: MeterWindow
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(window.title)
                .font(.body)
                .fontWeight(.medium)
            CodexBarProgressBar(
                percent: window.percent ?? 0,
                tint: tint,
                pacePercent: window.pacePercent,
                accessibilityLabel: "\(window.title) usage"
            )
            HStack {
                Text(window.percent.map { "\(Int($0.rounded()))%" } ?? "—")
                    .lineLimit(1)
                Spacer()
                if let reset = window.reset {
                    Text(reset)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .font(.footnote)
        }
    }
}

struct ProviderQuotaRing: View {
    let meter: ProviderMeter
    /// Pace layers, fastest window outermost. Empty until the host has
    /// sampled, so the single-ring path stays the fallback.
    var rings: [Burndown] = []
    let tint: Color

    private var headline: MeterWindow { meter.headline }

    /// Three rings at 72pt would be mush; two is the readable ceiling.
    private var layers: [Burndown] { Array(rings.prefix(2)) }

    private var windowCaption: String {
        if let reset = headline.reset, !reset.isEmpty {
            return "\(headline.title) · \(reset)"
        }
        return headline.title
    }

    var body: some View {
        VStack(spacing: 7) {
            Group {
                if layers.isEmpty {
                    QuotaRingCanvas(
                        percent: headline.percent,
                        pacePercent: headline.pacePercent,
                        tint: tint
                    )
                } else {
                    PaceRingsCanvas(rings: layers, tint: tint)
                }
            }
            .frame(width: 72, height: 72)
            Text(meter.provider.title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(tint)
            Text(windowCaption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .accessibilityElement(children: .combine)
        // The rings no longer carry a printed percentage, so state it here
        // rather than leaving VoiceOver with just a provider name.
        .accessibilityValue(
            headline.percent.map { "\(Int($0.rounded())) percent used" } ?? "unknown"
        )
    }
}

/// Concentric "pace layers": one ring per quota pool, fastest window outermost.
///
/// Each ring carries its own pace tick, so the gap between where the arc ends
/// and where the tick sits *is* the deficit. That is the whole point of the
/// glyph: two time horizons and their drift, readable without reading a number.
struct PaceRingsCanvas: View {
    let rings: [Burndown]
    let tint: Color
    /// Outermost stroke width; inner rings step down to stay legible.
    var lineWidth: CGFloat = 7
    var spacing: CGFloat = 4

    private func arcTint(_ ring: Burndown) -> Color {
        switch ring.kind {
        // Already spent reads as absence, not alarm.
        case .exhausted: tint.drained()
        // Behind pace, but still brand-colored — the caption carries the forecast.
        case .ahead: .orange
        case .ok, .critical: tint
        }
    }

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            var radius = min(size.width, size.height) / 2 - lineWidth / 2 - 1
            let width = lineWidth

            for ring in rings {
                guard radius > width else { break }
                let rect = CGRect(
                    x: center.x - radius, y: center.y - radius,
                    width: radius * 2, height: radius * 2
                )

                var track = Path()
                track.addEllipse(in: rect)
                // Tinted rather than neutral: two near-empty neutral tracks
                // merge into one thick border instead of reading as two rings.
                context.stroke(
                    track,
                    with: .color(tint.opacity(0.20)),
                    lineWidth: width
                )

                if let used = ring.usedPct {
                    var arc = Path()
                    arc.addArc(
                        center: center,
                        radius: radius,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(-90 + max(0, min(used, 100)) * 3.6),
                        clockwise: false
                    )
                    context.stroke(
                        arc,
                        with: .color(arcTint(ring)),
                        style: StrokeStyle(lineWidth: width, lineCap: .butt)
                    )
                }

                if let pace = ring.pacePercent {
                    let angle = -90 + max(0, min(pace, 100)) * 3.6
                    var tick = Path()
                    tick.addArc(
                        center: center,
                        radius: radius,
                        startAngle: .degrees(angle - 2.4),
                        endAngle: .degrees(angle + 2.4),
                        clockwise: false
                    )
                    context.stroke(
                        tick,
                        with: .color(.primary),
                        style: StrokeStyle(lineWidth: width + 3, lineCap: .butt)
                    )
                }

                radius -= width + spacing
            }
        }
    }
}

struct QuotaRingCanvas: View {
    let percent: Double?
    let pacePercent: Double?
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let lineWidth: CGFloat = 7
            let inset = lineWidth / 2 + 1
            let rect = CGRect(origin: .zero, size: size)
                .insetBy(dx: inset, dy: inset)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = rect.width / 2

            var track = Path()
            track.addEllipse(in: rect)
            context.stroke(
                track,
                with: .color(Color(nsColor: .tertiaryLabelColor).opacity(0.22)),
                lineWidth: lineWidth
            )

            if let percent {
                let fillTint = percent >= 100 ? tint.drained() : tint
                var usage = Path()
                usage.addArc(
                    center: center,
                    radius: radius,
                    startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + max(0, min(percent, 100)) * 3.6),
                    clockwise: false
                )
                context.stroke(
                    usage,
                    with: .color(fillTint),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
                )
            }

            if let pacePercent {
                let angle = -90 + max(0, min(pacePercent, 100)) * 3.6
                var tick = Path()
                tick.addArc(
                    center: center,
                    radius: radius,
                    startAngle: .degrees(angle - 2.8),
                    endAngle: .degrees(angle + 2.8),
                    clockwise: false
                )
                context.stroke(
                    tick,
                    with: .color(.primary),
                    style: StrokeStyle(lineWidth: lineWidth + 3, lineCap: .butt)
                )
            }
        }
    }
}
