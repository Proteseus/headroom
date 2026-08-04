import SwiftUI

/// OpenRouter / AI Gateway on Activity — observed account use, not a ring.
struct BalanceSpendSection: View {
    let provider: QuotaProviderInfo?
    let meter: ProviderMeter

    @ViewBuilder
    var body: some View {
        if let provider, provider.enabled != false {
            DataSection(title: provider.displayTitle, iconID: provider.id) {
                if let spend = meter.spend,
                   spend.hasFigures || spend.reportError != nil {
                    BalanceSpendCard(
                        spend: spend,
                        remainingLabel: meter.balanceLabel,
                        tint: provider.tint
                    )
                } else if let balance = meter.balanceLabel {
                    BalanceRow(
                        label: balance,
                        level: meter.balanceLevel,
                        tint: provider.tint
                    )
                } else if let error = meter.displayError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(HeadroomPalette.orange)
                } else if let status = meter.statusNote {
                    Label(
                        status,
                        systemImage: meter.needsSignIn
                            ? "person.badge.key"
                            : "exclamationmark.arrow.circlepath"
                    )
                    .font(.caption)
                    .foregroundStyle(
                        meter.statusAlarming
                            ? HeadroomPalette.orange : Color.secondary)
                } else {
                    Text(HeadroomCopy.noSpendYet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
