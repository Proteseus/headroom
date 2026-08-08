import AppKit
import SwiftUI

/// Listening local dev servers. Row tap opens the shared detail page; the
/// link glyph opens localhost, stop stays on the row. `pendingStop` is owned
/// by the parent so the confirmation alert can sit on the popover root.
struct ServersSection: View {
    @ObservedObject var store: UsageStore
    @Binding var pendingStop: LocalServer?
    @Binding var selection: ServiceDetailSelection?

    @AppStorage("serverRowLimit")
    private var serverRowLimit = 5
    @AppStorage("confirmServerStops")
    private var confirmServerStops = true

    var body: some View {
        let rows = Array((store.snapshot.local?.servers ?? [])
            .prefix(max(1, min(serverRowLimit, 8))))
        if !rows.isEmpty {
            DataSection(title: HeadroomCopy.localServers) {
                ForEach(rows) { server in
                    row(server)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ server: LocalServer) -> some View {
        HStack(spacing: 8) {
            Button {
                selection = .server(server.id)
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(server.reachable == false
                              ? HeadroomPalette.red
                              : HeadroomPalette.green)
                        .frame(width: 7, height: 7)
                    Text(server.name ?? "Server")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let latency = server.latencyMS {
                        Text(verbatim: "\(latency)ms")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(verbatim: ":\(server.port ?? 0)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    ServiceDetailChevron()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show server detail")
            PermalinkButton(url: Permalink.localServer(server))
            if server.pid != nil {
                if store.stoppingServerID == server.id {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 18, height: 18)
                } else {
                    Button {
                        requestStop(server)
                    } label: {
                        Image(systemName: "stop.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(HeadroomPalette.red)
                    .help("Stop server")
                    .accessibilityLabel("Stop")
                }
            }
        }
    }

    private func requestStop(_ server: LocalServer) {
        if confirmServerStops {
            pendingStop = server
        } else {
            Task { await store.stopServer(server) }
        }
    }
}
