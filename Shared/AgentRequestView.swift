import SwiftUI

/// The agent's request, drawn field by field as the provider sent it.
///
/// The host owns which fields exist, their order, their labels and their
/// bounds (`host/agent_request.py`). This view owns only how a `kind` looks.
/// An unknown kind falls through to plain text, so a tool nobody has seen
/// before is still readable without shipping an app update.
///
/// Two rules this view will not bend: a value the host clipped says so, and a
/// field the host dropped is counted out loud. Approving a prefix of a command
/// while believing it is the whole command is the failure worth designing out.
struct AgentRequestView: View {
    let fields: [AgentRequestField]
    @State private var expanded = false

    /// Values below this fit a feed row; above it they earn a disclosure.
    private static let inlineLimit = 80
    private static let collapsedLines = 3

    var body: some View {
        if !fields.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                header
                ForEach(visibleFields) { field in
                    fieldView(field)
                }
                if let omitted = fields.compactMap(\.omittedFields).max(),
                   omitted > 0 {
                    Text(HeadroomCopy.agentFieldsOmitted(omitted))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text(HeadroomCopy.agentRequest)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if hasCollapsibleContent {
                Button(expanded
                       ? HeadroomCopy.hideFullRequest
                       : HeadroomCopy.showFullRequest) {
                    expanded.toggle()
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(HeadroomPalette.claude)
            }
        }
    }

    /// Collapsed, only the fields that identify the request are shown. The
    /// bulk — file contents, replacement bodies — waits behind the toggle.
    private var visibleFields: [AgentRequestField] {
        expanded ? fields : fields.filter { !isBulk($0) }
    }

    private var hasCollapsibleContent: Bool {
        fields.contains { isBulk($0) || isMultiline($0) }
    }

    private func isBulk(_ field: AgentRequestField) -> Bool {
        field.kind == "code" || field.kind == "json"
    }

    /// A choice draws as its own list of pills, so its newlines are structure
    /// rather than length — expanding would change nothing.
    private func isMultiline(_ field: AgentRequestField) -> Bool {
        guard field.kind != "choice" else { return false }
        return field.value.contains("\n") || field.value.count > Self.inlineLimit
    }

    @ViewBuilder
    private func fieldView(_ field: AgentRequestField) -> some View {
        if field.kind == "choice" {
            // The options Claude is offering. Presented, not tapped: no hook
            // can return the selection, so a button here would be a lie. You
            // pick on the Mac; the pills make the choices easy to scan while
            // still wrapping long labels safely.
            VStack(alignment: .leading, spacing: 2) {
                label(field)
                ForEach(
                    Array(field.value.split(separator: "\n").enumerated()),
                    id: \.offset
                ) { _, option in
                    Text(String(option))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                }
            }
        } else if isMultiline(field) || isBulk(field) {
            VStack(alignment: .leading, spacing: 2) {
                label(field)
                Text(field.value)
                    .font(.caption.monospaced())
                    .foregroundStyle(tint(field))
                    .lineLimit(expanded ? nil : Self.collapsedLines)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                truncationNotice(field)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                label(field)
                Text(field.value)
                    .font(monospaced(field) ? .caption.monospaced() : .caption)
                    .foregroundStyle(tint(field))
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
        }
    }

    private func label(_ field: AgentRequestField) -> some View {
        Text(field.label)
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private func truncationNotice(_ field: AgentRequestField) -> some View {
        if field.wasTruncated {
            Text(HeadroomCopy.agentValueShortened)
                .font(.caption2)
                .foregroundStyle(HeadroomPalette.amber)
        }
    }

    private func monospaced(_ field: AgentRequestField) -> Bool {
        ["command", "code", "path", "json"].contains(field.kind)
    }

    /// An Edit is a before and an after. Tinting the pair is the only way the
    /// two monospaced blocks read as a replacement rather than two strings.
    private func tint(_ field: AgentRequestField) -> Color {
        switch field.key {
        case "old_string": return HeadroomPalette.red
        case "new_string", "new_source": return HeadroomPalette.green
        default: return .secondary
        }
    }
}
