import SwiftUI

/// The color grid behind the dot on a Settings source row.
///
/// Rows are found by color before they are read — eight providers deep, the
/// dot is what tells Claude from Codex at a glance. The shipped colors are
/// brand colors, which is a good default and a bad rule: two Claude accounts
/// are the same brand, and a Cursor blue next to a Sky blue is two rows you
/// have to read to tell apart. So the color is a preference, stored per
/// source on the host and resolved there, and "Default" is always one tap
/// away rather than something to remember the hex of.
struct AccentPicker: View {
    let title: String
    /// The registry's shipped color — what "Default" paints. Always set:
    /// only provider rows open this picker.
    let defaultHex: String?
    /// What the row is painted now, override or not.
    let currentHex: String?
    /// nil restores the default.
    let onPick: (String?) -> Void
    /// What the default swatch means — "Default" on a provider, "Derived shade"
    /// on an extra account whose auto color follows the provider base.
    var defaultLabel: String = "Default"

    @Environment(\.dismiss) private var dismiss

    private static let columns = Array(
        repeating: GridItem(.fixed(28), spacing: 8), count: 6)

    private var isDefault: Bool {
        HeadroomPalette.sameAccent(currentHex, defaultHex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            Button {
                onPick(nil)
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Swatch(
                        color: HeadroomPalette.color(hex: defaultHex)
                            ?? HeadroomPalette.dim,
                        isSelected: isDefault
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(defaultLabel)
                        Text(defaultHex ?? "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isDefault
                    ? "\(defaultLabel) color, selected"
                    : "\(defaultLabel) color")

            Divider()

            LazyVGrid(columns: Self.columns, spacing: 8) {
                ForEach(HeadroomPalette.accentChoices) { choice in
                    Button {
                        onPick(choice.hex)
                        dismiss()
                    } label: {
                        Swatch(
                            color: choice.color,
                            isSelected: !isDefault
                                && HeadroomPalette.sameAccent(
                                    currentHex, choice.hex)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(choice.name)
                    .accessibilityLabel(choice.name)
                }
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}

private struct Swatch: View {
    let color: Color
    let isSelected: Bool

    var body: some View {
        Circle()
            .fill(color)
            .overlay {
                Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 1)
            }
            .frame(width: 22, height: 22)
            // A ring rather than a checkmark: at 22pt a glyph fights the
            // color it sits on, and half these swatches are mid-tones where
            // neither black nor white reads.
            .padding(3)
            .overlay {
                if isSelected {
                    Circle().strokeBorder(.primary.opacity(0.75), lineWidth: 2)
                }
            }
            .frame(width: 28, height: 28)
    }
}
