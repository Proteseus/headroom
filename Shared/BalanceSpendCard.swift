import SwiftUI

/// Prepaid account spend leaf — OpenRouter / AI Gateway.
///
/// History first: daily account use over the trailing window, then totals and
/// breakdowns. No ring, no depletion bar, no alarm colour — observed dollars
/// from the provider's own credits/analytics APIs.
struct BalanceSpendCard: View {
    let spend: BalanceSpend
    var remainingLabel: String? = nil
    var tint: Color = HeadroomPalette.dim

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let error = spend.reportError, !spend.hasFigures || (spend.periodUSD ?? 0) == 0 {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !spend.hasFigures {
                Text(HeadroomCopy.noSpendYet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                if let days = spend.byDay, !days.isEmpty {
                    dayChart(days)
                }
                figures
                if let models = spend.byModel, !models.isEmpty {
                    Divider().opacity(0.5)
                    modelBreakdown(models)
                }
                if let keys = spend.byKey, !keys.isEmpty {
                    Divider().opacity(0.5)
                    keyBreakdown(keys)
                }
                if let error = spend.reportError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(HeadroomCopy.accountUse)
                .font(.headline)
            Spacer()
            Text(HeadroomCopy.spendObserved)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var figures: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            if let today = spend.todayUSD {
                figure(today.dollarLabel, HeadroomCopy.spendToday)
            }
            if let period = spend.periodUSD, let days = spend.periodDays {
                figure(period.dollarLabel, HeadroomCopy.spendLastDays(days))
            }
            if let avg = spend.avgDailyUSD {
                figure(avg.dollarLabel, HeadroomCopy.spendPerDay)
            }
            if let remainingLabel {
                figure(remainingLabel, HeadroomCopy.balanceLeft)
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

    /// Full trailing window as a day chart — the reading this leaf exists for.
    private func dayChart(_ days: [BalanceSpendDay]) -> some View {
        let peak = max(days.compactMap(\.usd).max() ?? 0, 0.01)
        let period = spend.periodDays ?? days.count
        return VStack(alignment: .leading, spacing: 6) {
            Text(HeadroomCopy.spendLastDays(period))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(days) { day in
                    let height = CGFloat((day.usd ?? 0) / peak)
                    Capsule()
                        .fill(tint.opacity((day.usd ?? 0) > 0 ? 0.9 : 0.12))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(2, 72 * height))
                        .accessibilityLabel(day.day ?? "day")
                        .accessibilityValue((day.usd ?? 0).dollarLabel)
                }
            }
            .frame(height: 72)
            if let first = days.first?.day, let last = days.last?.day {
                HStack {
                    Text(shortDay(first))
                    Spacer()
                    Text(shortDay(last))
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            }
        }
    }

    private func shortDay(_ iso: String) -> String {
        // YYYY-MM-DD → M/D
        let parts = iso.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else { return iso }
        return "\(month)/\(day)"
    }

    private func modelBreakdown(_ models: [BalanceSpendModel]) -> some View {
        let total = max(models.compactMap(\.usd).reduce(0, +), 0.01)
        return VStack(alignment: .leading, spacing: 4) {
            Text(HeadroomCopy.spendByModel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(models) { row in
                HStack(spacing: 8) {
                    Text(row.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let requests = row.requests {
                        Text("\(requests)")
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    Text((row.usd ?? 0).dollarLabel)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.caption)
                GeometryReader { geo in
                    Capsule()
                        .fill(tint.opacity(0.35))
                        .frame(
                            width: geo.size.width
                                * CGFloat((row.usd ?? 0) / total),
                            height: 3
                        )
                }
                .frame(height: 3)
            }
        }
    }

    private func keyBreakdown(_ keys: [BalanceSpendKey]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(HeadroomCopy.spendByKey)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(keys) { row in
                HStack {
                    Text(row.name ?? "—")
                        .lineLimit(1)
                    Spacer()
                    if let monthly = row.usdMonthly {
                        Text(monthly.dollarLabel + " / mo")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else if let daily = row.usdDaily {
                        Text(daily.dollarLabel + " today")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .font(.caption)
            }
        }
    }
}

/// Compact day sparkline for the Usage overview grid — account use, not a
/// remaining-credits depletion mark.
struct BalanceSpendSparkline: View {
    let days: [BalanceSpendDay]
    var tint: Color = HeadroomPalette.dim
    var diameter: CGFloat = 72

    var body: some View {
        let recent = Array(days.suffix(14))
        let peak = max(recent.compactMap(\.usd).max() ?? 0, 0.01)
        return HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(recent) { day in
                let height = CGFloat((day.usd ?? 0) / peak)
                Capsule()
                    .fill(tint.opacity((day.usd ?? 0) > 0 ? 0.9 : 0.15))
                    .frame(maxWidth: .infinity)
                    .frame(height: max(2, (diameter * 0.55) * height))
            }
        }
        .frame(width: diameter * 0.85, height: diameter * 0.55)
        .frame(width: diameter, height: diameter)
    }
}
