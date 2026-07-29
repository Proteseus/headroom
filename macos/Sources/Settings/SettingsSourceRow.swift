import SwiftUI

struct DragReorder: ViewModifier {
    let enabled: Bool
    let id: String
    let onTargeted: (Bool) -> Void
    let onDrop: (String) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .draggable(id) {
                    // Dragging the row itself would drag the live toggle.
                    Label(id.capitalized, systemImage: "line.3.horizontal")
                        .padding(6)
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let dragged = items.first else { return false }
                    onDrop(dragged)
                    return true
                } isTargeted: { targeted in
                    onTargeted(targeted)
                }
        } else {
            content
        }
    }
}

struct SourceRow: View {
    let source: SyncSource
    let isBusy: Bool
    var isDraggable = false
    var isDropTarget = false
    let onToggle: (Bool) -> Void
    let onRefresh: () -> Void
    /// -1 up, +1 down. Keyboard / VoiceOver equivalent of the drag.
    var onNudge: ((Int) -> Void)?
    /// nil restores the registry color. Absent on rows with no brand dot.
    var onAccent: ((String?) -> Void)?

    @State private var isPickingColor = false

    private var enabled: Bool { source.enabled ?? true }

    var body: some View {
        HStack(spacing: 10) {
            if isDraggable {
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("Drag to reorder")
                    .accessibilityHidden(true)
            }

            // Brand fill, health as the ring around it — one dot, both facts.
            // Without a brand the fill *is* the health color, so nothing is
            // lost on rows the registry gives no accent.
            Button {
                guard canPickColor else { return }
                isPickingColor = true
            } label: {
                Circle()
                    .fill(brandColor ?? statusColor)
                    .frame(width: 9, height: 9)
                    .overlay {
                        if brandColor != nil {
                            Circle()
                                .strokeBorder(statusColor, lineWidth: 1.5)
                                .frame(width: 15, height: 15)
                        }
                    }
                    .frame(width: 16, height: 16)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canPickColor)
            .help(canPickColor ? "Change color" : statusLabel)
            .accessibilityLabel(
                canPickColor ? "\(statusLabel). Change color" : statusLabel)
            .popover(isPresented: $isPickingColor, arrowEdge: .bottom) {
                AccentPicker(
                    title: source.title ?? source.id,
                    defaultHex: source.accentDefault,
                    currentHex: source.accent,
                    onPick: { onAccent?($0) }
                )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(source.title ?? source.id)
                Text(secondaryLine)
                    .font(.caption)
                    .foregroundStyle(
                        source.ok == true || !enabled
                            ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(HeadroomPalette.amber)
                    )
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                onRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(isBusy || !enabled)
            .help("Force refresh")

            Toggle(
                "Enabled",
                isOn: Binding(
                    get: { enabled },
                    set: { onToggle($0) }
                )
            )
            .labelsHidden()
            .disabled(isBusy)
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .opacity(enabled ? 1 : 0.55)
        .accessibilityElement(children: .combine)
        // Drag is the affordance; these keep reordering reachable without a
        // pointer, and give the drop target a visible insertion line.
        .accessibilityAction(named: "Move up") { onNudge?(-1) }
        .accessibilityAction(named: "Move down") { onNudge?(1) }
        .overlay(alignment: .top) {
            if isDropTarget {
                Rectangle()
                    .fill(HeadroomPalette.green)
                    .frame(height: 2)
                    .offset(y: -4)
            }
        }
    }

    private var secondaryLine: String {
        var parts: [String] = []
        if let detail = source.detail ?? source.hint ?? source.error {
            parts.append(detail)
        }
        if let age = source.ageS {
            parts.append(ageLabel(age))
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    /// Color is not the only carrier of health — VoiceOver gets it in words.
    private var statusLabel: String {
        if !enabled { return "Off" }
        if source.ok != true { return "Error" }
        return source.stale == true ? "Stale" : "Healthy"
    }

    /// Health: green / amber / red, the same words the rest of the app uses.
    private var statusColor: Color {
        if !enabled { return HeadroomPalette.dim }
        if source.ok == true {
            return source.stale == true ? HeadroomPalette.amber : HeadroomPalette.green
        }
        return HeadroomPalette.red
    }

    /// The row's accent — Settings override when set, else the registry's —
    /// so a row is identifiable at a glance in a list eight providers long.
    /// Rows with no brand keep the status color: health then reads off the
    /// fill exactly as it used to.
    private var brandColor: Color? {
        guard enabled else { return nil }
        return HeadroomPalette.color(hex: source.accent)
    }

    /// Providers only. A dev-tool row has no brand color to start from and no
    /// ring anywhere else to keep in sync — its dot is the health light, and
    /// repainting that would be repainting the status.
    private var canPickColor: Bool {
        onAccent != nil && source.accentDefault != nil
    }

    private func ageLabel(_ age: Int) -> String {
        let stale = source.stale == true
        if age < 5 {
            return stale ? "stale · just now" : "just now"
        }
        if age < 60 {
            return stale ? "\(age)s stale" : "\(age)s ago"
        }
        let minutes = age / 60
        return stale ? "\(minutes)m stale" : "\(minutes)m ago"
    }
}
