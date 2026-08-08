import SwiftUI

/// The other Macs signed into the same shared folder.
///
/// Deliberately read-only and deliberately unmerged. Each row is that Mac's
/// own answer with its own age next to it, because two Macs are allowed to
/// disagree — one of them was asleep — and a single reconciled number would
/// hide which. The row exists to answer "is something waiting for me over
/// there", not to let you act on it from here.
///
/// Absent entirely on a single-Mac install: an empty "Other Macs" heading is a
/// worse answer than no heading.
struct MachinesSection: View {
    let machines: [MachineSummary]

    var body: some View {
        if !machines.isEmpty {
            DataSection(title: HeadroomCopy.otherMacs) {
                ForEach(machines) { machine in
                    row(machine)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ machine: MachineSummary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: machine.board == true
                      ? "desktopcomputer.and.macbook"
                      : "macbook")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(machine.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if machine.needsYou {
                    Circle()
                        .fill(HeadroomPalette.orange)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("Needs you")
                }
                Spacer()
                Text(machine.lastSeenLabel)
                    .font(.caption2)
                    .foregroundStyle(machine.stale == true ? .tertiary : .secondary)
            }
            if let activity = machine.activityLabel {
                Text(activity)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 20)
            }
            if let providers = machine.providers, !providers.isEmpty {
                meters(providers)
                    .padding(.leading, 20)
            }
        }
        // A Mac that has not checked in for a while is dimmed rather than
        // hidden: "the laptop is closed" is information, and dropping the row
        // would read as the Mac never having existed.
        .opacity(machine.stale == true ? 0.55 : 1)
    }

    private func meters(_ providers: [MachineProvider]) -> some View {
        HStack(spacing: 10) {
            ForEach(providers) { provider in
                HStack(spacing: 4) {
                    Circle()
                        .fill(HeadroomPalette.color(hex: provider.accent)
                              ?? Color.secondary)
                        .frame(width: 5, height: 5)
                    Text(provider.title ?? provider.id ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(provider.pctLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.primary)
                }
            }
            Spacer()
        }
    }
}

extension MachineProvider {
    /// "62%", or an em space when that Mac had no reading to report — a dash
    /// would read as zero remaining, which is the opposite of unknown.
    var pctLabel: String {
        guard let pct else { return "\u{2003}" }
        return "\(Int(pct.rounded()))%"
    }
}
