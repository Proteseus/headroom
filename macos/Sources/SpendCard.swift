import SwiftUI

/// What the tokens were worth, over the window the host keeps.
///
/// The host has computed this since 1.0 — per day, per model, 400 days of
/// retention — and until now exactly one string of it reached a screen. This
/// card is the rest.
///
/// Every figure is **estimated**: local token counts priced by
/// `host/pricing.py`, never a provider's bill. On a subscription plan there is
/// no bill to contradict it, which makes this the cheapest possible place to
/// establish the habit of saying so. It stops being free the moment a real API
/// account is attached. See docs/metering.md decision 3.
///
/// No alarm colour anywhere in here on purpose. Spend is not a warning: the
/// number being large is information, not a fault, and a red total would make
/// a normal week look like an incident.
struct SpendCard: View {
    let history: UsageHistory?
    let today: TokenBucket?

    private var hasAnything: Bool {
        (history?.totalCostUSD ?? 0) > 0 || (today?.costUSD ?? 0) > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !hasAnything {
                Text(HeadroomCopy.noSpendYet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
            } else {
                figures
                if let models = history?.topModels, !models.isEmpty {
                    Divider()
                    modelBreakdown(models)
                }
                if let unpriced = history?.unpricedModels, !unpriced.isEmpty {
                    unpricedNote(unpriced)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(HeadroomCopy.spend)
                .font(.headline)
            Spacer()
            // Not a tooltip. A reader who sees the number has seen this.
            Text(HeadroomCopy.spendEstimated)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var figures: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            if let todayCost = today?.costUSD {
                figure(todayCost.dollarLabel, HeadroomCopy.spendToday)
            }
            if let total = history?.totalCostUSD, let days = history?.activeDays {
                figure(total.dollarLabel, "\(days)d")
            }
            if let avg = history?.avgCostPerActiveDay {
                figure(avg.dollarLabel, HeadroomCopy.spendPerActiveDay)
            }
            Spacer(minLength: 0)
        }
    }

    private func figure(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Share of tokens, not of dollars. The host tracks tokens per model and
    /// cost only in aggregate, and deriving a per-model dollar split from a
    /// token split would silently assume every model costs the same — which is
    /// the one thing the price table exists to say is false.
    private func modelBreakdown(_ models: [HistoryModel]) -> some View {
        let total = max(models.compactMap(\.tokens).reduce(0, +), 1)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(models.enumerated()), id: \.offset) { _, row in
                if let name = row.model {
                    HStack {
                        Text(name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(sharePct(row.tokens ?? 0, of: total))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func sharePct(_ value: Double, of total: Double) -> String {
        String(format: "%.0f%%", 100 * value / total)
    }

    private func unpricedNote(_ models: [String]) -> some View {
        // Secondary, not a warning colour. It means the price table is behind,
        // which is a maintenance fact about this build rather than a problem
        // with the reader's account.
        Text("\(HeadroomCopy.spendUnpriced): \(models.joined(separator: ", "))")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}
