import AppKit
import SwiftUI

/// Merged deploy / commit / Actions timeline. Pure function of the snapshot —
/// no state of its own.
struct ActivitySection: View {
    let items: [ActivityItem]
    @AppStorage("activityRowLimit")
    private var activityRowLimit = 8

    var body: some View {
        let rows = Array(items.prefix(max(3, min(activityRowLimit, 14))))
        if !rows.isEmpty {
            DataSection(title: HeadroomCopy.activity) {
                ForEach(rows) { item in
                    row(item)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: ActivityItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .fill(color(item))
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.subject ?? "Event")
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(context(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(item.ago ?? "—")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if item.status == "error", let error = item.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(HeadroomPalette.red)
                    .lineLimit(2)
                    .padding(.leading, 16)
            }
            if item.status == "error" || item.status == "canceled" {
                HStack {
                    Spacer()
                    if url(item) != nil {
                        Button {
                            open(item)
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .buttonStyle(.borderless)
                        .help("Open inspector")
                        .accessibilityLabel("Open inspector")
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { open(item) }
    }

    private func context(_ item: ActivityItem) -> String {
        var parts = [item.project ?? item.repo, item.branch, item.shortSHA]
            .compactMap { $0 }
        switch item.status {
        case "ready":
            parts.append(item.target == "production" ? "prod" : "preview")
        case "building": parts.append("building")
        case "running": parts.append("running")
        case "pushed": parts.append("pushed")
        case "local": parts.append("local")
        case "committed": parts.append("commit")
        case "canceled", "cancelled": parts.append("canceled")
        case "error", "failure":
            if item.errorMessage == nil { parts.append("failed") }
        default:
            if let status = item.status { parts.append(status) }
        }
        return parts.joined(separator: " · ")
    }

    private func color(_ item: ActivityItem) -> Color {
        // Same rule as firmware statusColor: red for bad, dim otherwise.
        switch item.status {
        case "error", "failure": HeadroomPalette.red
        default: HeadroomPalette.dim
        }
    }

    private func url(_ item: ActivityItem) -> URL? {
        let raw = item.inspectorURL ?? item.url
        guard let raw, !raw.isEmpty else { return nil }
        return URL(string: raw.contains("://") ? raw : "https://\(raw)")
    }

    private func open(_ item: ActivityItem) {
        guard let target = url(item) else { return }
        NSWorkspace.shared.open(target)
    }
}
