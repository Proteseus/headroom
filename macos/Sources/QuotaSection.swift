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
    let subscriptionPricing: SubscriptionPricing?
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
            ForEach(
                Array(meter.displayableWindows.enumerated()), id: \.offset
            ) { _, window in
                QuotaRow(window: window, tint: brand)
            }
            if let balance = meter.balanceLabel {
                BalanceRow(
                    label: balance,
                    level: meter.balanceLevel,
                    tint: brand
                )
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
            if let subscriptionPricing {
                SubscriptionPricingView(
                    pricing: subscriptionPricing,
                    currentPlan: meter.plan)
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
                .foregroundStyle(
                    meter.statusAlarming
                        ? HeadroomPalette.amber : Color.secondary)
            }
            // Not gated on `ok`. The host holds `ok` true while it replays the
            // last good bars, so gating here hid the message on exactly the
            // failures that had one worth reading — including the one that
            // named the command to run. Rate-limit prose is folded into the
            // status note above, so `displayError` drops it.
            if let error = meter.displayError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(
                        meter.statusAlarming
                            ? HeadroomPalette.amber : Color.secondary)
                    .lineLimit(2)
            }
        }
        .cardStyle()
    }
}

private struct SubscriptionPricingView: View {
    let pricing: SubscriptionPricing
    let currentPlan: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Subscription price")
                    .font(.caption.weight(.medium))
                Spacer()
                if let url = pricing.url.flatMap(URL.init(string:)) {
                    Link("Source", destination: url)
                        .font(.caption2)
                }
            }
            if let price = pricing.currentPrice(for: currentPlan) {
                HStack(spacing: 8) {
                    Text(currentPlan ?? price.title)
                        .lineLimit(1)
                    Spacer()
                    Text(price.compactPrice)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.caption2)
            } else if let currentPlan {
                HStack(spacing: 8) {
                    Text(currentPlan)
                        .lineLimit(1)
                    Spacer()
                    Text("See provider")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
            } else {
                Text(HeadroomCopy.planUnknown)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let checked = pricing.checked {
                Text("List prices · checked \(checked)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 2)
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

/// Prepaid balance: a bar that drains as credits go, dollars under it.
/// Not a ring — docs/metering.md decision 2.
struct BalanceRow: View {
    let label: String
    var level: Double?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Balance")
                .font(.body)
                .fontWeight(.medium)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(tint)
                        .frame(
                            width: geo.size.width
                                * CGFloat(max(0, min(level ?? 0, 1)))
                        )
                }
            }
            .frame(height: 8)
            .accessibilityLabel("Balance remaining")
            .accessibilityValue(label)
            Text(label)
                .font(.footnote)
                .monospacedDigit()
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
        // Balance-only providers have no window bands. Draw spent fraction so
        // the arc empties as credits go — still not a pace ring, just a glance
        // mark that matches the depletion bar on the detail card.
        if let balance = provider.primaryBalance, let level = balance.level {
            return [
                HeadroomRingLayer(
                    id: "balance",
                    name: "Balance",
                    percent: (1 - level) * 100,
                    pacePercent: nil
                ),
            ]
        }
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
        if let balance = provider.primaryBalance?.balanceRemainingLabel {
            return balance
        }
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
                .foregroundStyle(
                    provider.statusAlarming ? HeadroomPalette.amber : .secondary)
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
