import SwiftUI

struct ActivityScreen: View {
    @ObservedObject var store: MobileUsageStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            ForEach(store.snapshot.activity ?? []) { item in
                Button {
                    open(item)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(statusColor(item.status))
                            .frame(width: 8, height: 8)
                            .padding(.top, 6)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.subject ?? "Event")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(context(item))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            if let error = item.errorMessage,
                               item.status == "error" || item.status == "failure" {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .lineLimit(3)
                            }
                        }
                        Spacer()
                        Text(item.ago ?? "")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .disabled(url(item) == nil)
            }
        }
        .overlay {
            if (store.snapshot.activity ?? []).isEmpty {
                ContentUnavailableView(
                    HeadroomCopy.noActivityYet,
                    systemImage: "bolt.horizontal.circle"
                )
            }
        }
        .navigationTitle(HeadroomCopy.activity)
        .refreshable { await store.refresh(forceServerSync: true) }
    }

    private func context(_ item: ActivityItem) -> String {
        var parts = [item.project ?? item.repo, item.branch, item.shortSHA]
            .compactMap { $0 }
        if let status = item.status {
            parts.append(status)
        }
        return parts.joined(separator: " · ")
    }

    private func statusColor(_ status: String?) -> Color {
        switch status {
        case "error", "failure": .red
        case "building", "running": .orange
        case "ready", "pushed", "committed": .green
        default: .secondary
        }
    }

    private func url(_ item: ActivityItem) -> URL? {
        guard let raw = item.inspectorURL ?? item.url, !raw.isEmpty else { return nil }
        return URL(string: raw.contains("://") ? raw : "https://\(raw)")
    }

    private func open(_ item: ActivityItem) {
        if let target = url(item) {
            openURL(target)
        }
    }
}
