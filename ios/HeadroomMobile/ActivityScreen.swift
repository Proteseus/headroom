import SwiftUI

/// What the Mac has been doing, and what it is running: the merged deploy /
/// commit / Actions feed above the service panels that used to be a tab of
/// their own.
///
/// Nothing on this screen is waiting for an answer. Rows that failed live on
/// `AttentionScreen`, which is also the one place that decides which those are
/// — this screen takes the complement, so the two can't disagree.
struct ActivityScreen: View {
    @ObservedObject var store: MobileUsageStore
    /// Tapping the "N need attention" line jumps to the tab holding them,
    /// rather than reprinting the rows it just moved away.
    var showAttention: () -> Void
    @State private var serverToStop: LocalServer?
    @State private var controlError: String?

    var body: some View {
        let waiting = AttentionScreen.failures(in: store.snapshot).count
        let rows = (store.snapshot.activity ?? []).filter {
            !ActivityStatusStyle.resolve($0.status).needsAttention
        }
        List {
            ArchivedDataNotice(store: store)
            if waiting > 0 {
                Button(action: showAttention) {
                    HStack {
                        Label(
                            HeadroomCopy.needsAttention(count: waiting),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(HeadroomPalette.red)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            Section(HeadroomCopy.recentActivity) {
                if rows.isEmpty {
                    Text(HeadroomCopy.noActivityYet)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { ActivityRow(item: $0) }
                }
            }
            ServiceSections(store: store) { serverToStop = $0 }
        }
        .navigationTitle(HeadroomCopy.activity)
        .refreshable { await store.refresh(forceServerSync: true) }
        .confirmationDialog(
            "Stop \(serverToStop?.name ?? "server")?",
            isPresented: Binding(
                get: { serverToStop != nil },
                set: { if !$0 { serverToStop = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Stop server", role: .destructive) {
                guard let server = serverToStop else { return }
                serverToStop = nil
                Task { await authenticateAndStop(server) }
            }
            Button("Cancel", role: .cancel) { serverToStop = nil }
        } message: {
            Text("Stops the process on your Mac.")
        }
        .alert(
            "Couldn’t complete action",
            isPresented: Binding(
                get: { controlError != nil },
                set: { if !$0 { controlError = nil } }
            )
        ) {
            Button("OK") { controlError = nil }
        } message: {
            Text(controlError ?? "")
        }
    }

    @MainActor
    private func authenticateAndStop(_ server: LocalServer) async {
        do {
            try await MobileControlAuthorizer.authorize(
                reason: "Stop \(server.name ?? "this server") on your Mac"
            )
            await store.stopServer(server)
        } catch {
            controlError = error.localizedDescription
        }
    }
}

/// One feed row, drawn the same on both tabs. Status vocabulary comes from
/// `Shared/ActivityStatus.swift` so the phone and the Mac card can't drift
/// into different ideas of green.
struct ActivityRow: View {
    let item: ActivityItem
    @Environment(\.openURL) private var openURL

    var body: some View {
        let style = ActivityStatusStyle.resolve(item.status)
        Button {
            if let target = url { openURL(target) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: style.symbol)
                    .font(.footnote)
                    .foregroundStyle(style.tint)
                    .frame(width: 16)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.subject ?? "Event")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(caption(style))
                        .font(.caption)
                        .foregroundStyle(style.needsAttention
                                         ? AnyShapeStyle(style.tint)
                                         : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                    if style.needsAttention, let error = item.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(HeadroomPalette.red)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 6)
                Text(item.ago ?? "")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
    }

    /// "Failed · headroom · Release · main · 1901f54" — state first, then the
    /// coordinates. Matches the Mac card word for word.
    private func caption(_ style: ActivityStatusStyle) -> String {
        var parts = [style.label]
        let repo = leafName(item.repo)
        if let repo { parts.append(repo) }
        if let project = item.project, project != repo { parts.append(project) }
        if let branch = item.branch { parts.append(branch) }
        if let sha = item.shortSHA { parts.append(sha) }
        if item.status == "ready" {
            parts.append(item.target == "production" ? "prod" : "preview")
        }
        return parts.joined(separator: " · ")
    }

    /// `owner/name` → `name`. The owner is the same on every row here.
    private func leafName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.split(separator: "/").last.map(String.init)
    }

    private var url: URL? {
        guard let raw = item.inspectorURL ?? item.url, !raw.isEmpty else { return nil }
        return URL(string: raw.contains("://") ? raw : "https://\(raw)")
    }
}
