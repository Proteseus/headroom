import SwiftUI

/// The quota half of the popover: the ring overview, the single-provider
/// detail card, and the attention summary.

struct QuotaOverviewCard: View {
    let snapshot: UsageSnapshot
    /// Tapping a ring jumps to that provider's detail tab.
    let onSelect: (String) -> Void

    /// Width of the ring area, measured rather than assumed: the popover is
    /// fixed at 390 but the screenshot renderer and the settings preview are
    /// not, and a row of fixed-size rings overflows a narrower host silently.
    /// Seeded with the popover's card interior (390 less the 16pt scroll
    /// inset and 14pt card padding on each side) so the first frame is already
    /// right in the common case instead of laying out wide and snapping back.
    @State private var rowWidth: CGFloat = 330

    private static let ringSpacing: CGFloat = 10
    private static let maximumRingDiameter: CGFloat = 72
    /// Below this a ring stops reading as two bands with a pace dot, so the
    /// row wraps instead of shrinking further.
    private static let minimumRingCell: CGFloat = 54

    private var providers: [QuotaProviderInfo] { snapshot.visibleQuotaProviders }

    /// Columns that fit the measured width, balanced across however many rows
    /// that takes — six providers read as 3+3, not 5+1.
    private var ringColumns: Int {
        let count = providers.count
        guard count > 1, rowWidth > 0 else { return max(1, count) }
        let cellStride = Self.minimumRingCell + Self.ringSpacing
        let fits = max(1, Int((rowWidth + Self.ringSpacing) / cellStride))
        let perRow = min(count, fits)
        let rows = Int((Double(count) / Double(perRow)).rounded(.up))
        return Int((Double(count) / Double(max(1, rows))).rounded(.up))
    }

    private var ringDiameter: CGFloat {
        guard rowWidth > 0 else { return Self.maximumRingDiameter }
        let columns = CGFloat(ringColumns)
        let cell = (rowWidth - Self.ringSpacing * (columns - 1)) / columns
        return min(Self.maximumRingDiameter, max(24, cell))
    }

    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 24), spacing: Self.ringSpacing),
            count: ringColumns
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(HeadroomCopy.codingQuotas)
                .font(.headline)
            if providers.isEmpty {
                Text(HeadroomCopy.noCodingSources)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                LazyVGrid(columns: gridColumns, spacing: 14) {
                    ForEach(providers) { provider in
                        ProviderQuotaRing(
                            provider: provider,
                            meter: snapshot.meter(for: provider),
                            rings: snapshot.burndownRings(forProviderID: provider.id),
                            tint: snapshot.tint(forProviderID: provider.id),
                            diameter: ringDiameter
                        )
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(provider.id) }
                    }
                }
                .measuredWidth($rowWidth)
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
    let meter: ProviderMeter
    var tint: Color? = nil

    private var brand: Color {
        tint
            ?? UsageProvider(rawValue: meter.id)?.tint
            ?? HeadroomPalette.dim
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 6) {
                ProviderMark(providerID: meter.id, size: 14)
                Text(meter.title)
                    .font(.headline)
                Spacer()
                Text(meter.plan ?? "—")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            QuotaRow(window: meter.primary, tint: brand)
            QuotaRow(window: meter.secondary, tint: brand)
            if let tertiary = meter.tertiary {
                QuotaRow(window: tertiary, tint: brand)
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
            if let credits = meter.resetCreditsLabel {
                HStack {
                    Text(credits)
                    Spacer()
                    if let expiry = meter.resetCreditsExpiryLabel {
                        Text(expiry)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
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
            // Above the error, and shown even though `ok` is true: every bar
            // on this card is a number the Mac stopped being able to refresh.
            if let status = meter.statusNote {
                Label(
                    status,
                    systemImage: meter.needsSignIn
                        ? "person.badge.key"
                        : "exclamationmark.arrow.circlepath"
                )
                .font(.caption)
                .foregroundStyle(HeadroomPalette.amber)
            }
            // Not gated on `ok`. The host holds `ok` true while it replays the
            // last good bars, so gating here hid the message on exactly the
            // failures that had one worth reading — including the one that
            // named the command to run.
            if let error = meter.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(HeadroomPalette.amber)
                    .lineLimit(2)
            }
        }
        .cardStyle()
    }
}

struct AttentionCard: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        let attention = store.snapshot.attention
        let reasons = attention?.reasons ?? []
        let showPip = attention?.isWarning == true
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(HeadroomCopy.attention)
                    .font(.headline)
                Spacer()
                if showPip {
                    Button {
                        Task { await store.acknowledgeAttention() }
                    } label: {
                        Label(HeadroomCopy.clearAttention, systemImage: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Clear this warning on every Headroom surface")
                    .accessibilityLabel("Clear attention")
                } else if attention?.isWarning == true {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .help("Cleared until something new")
                        .accessibilityLabel("Attention cleared")
                } else {
                    Text(attention?.summary ?? HeadroomCopy.allClear)
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
                        Text(reason.summary ?? HeadroomCopy.needsAttention)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
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
    let provider: QuotaProviderInfo
    let meter: ProviderMeter
    /// This provider's burndown pools, which sharpen the pace dot. Empty
    /// until the host has sampled, when the pools' own pace stands in.
    var rings: [Burndown] = []
    let tint: Color
    /// Set by the overview grid, which shrinks the glyph rather than let a
    /// row of them push past the popover.
    var diameter: CGFloat = 72

    private var headline: MeterWindow { meter.headline }

    private var ringLayers: [HeadroomRingLayer] {
        let layers = provider.ringLayers(burndown: rings)
        guard layers.isEmpty else { return layers }
        // A host predating the pool registry ships no pools, which leaves the
        // headline window as the only thing there is to draw.
        return [
            HeadroomRingLayer(
                id: headline.id ?? "headline",
                name: headline.title,
                percent: headline.percent,
                pacePercent: headline.pacePercent
            ),
        ]
    }

    /// The countdown is computed against the wall clock, so it keeps ticking
    /// over numbers that stopped moving hours ago — the one part of this
    /// glyph that actively insists a frozen meter is live. When the host says
    /// the fetch is failing, the age of the data replaces it.
    private var windowCaption: String {
        if let note = provider.statusNote { return note }
        if let reset = headline.reset, !reset.isEmpty {
            return "\(headline.title) · \(reset)"
        }
        return headline.title
    }

    var body: some View {
        VStack(spacing: 7) {
            HeadroomRings(layers: ringLayers, tint: tint)
            .frame(width: diameter, height: diameter)
            // Drained of colour, because the gap between arc and pace dot is
            // the reading, and on frozen numbers that reading is fiction.
            .opacity(provider.readingSuspect ? 0.4 : 1)
            Text(meter.title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(windowCaption)
                .font(.caption2)
                .foregroundStyle(provider.readingSuspect ? HeadroomPalette.amber : .secondary)
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
