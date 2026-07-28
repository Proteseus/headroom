import AppKit
import SwiftUI

/// Listening local dev servers, with open / reveal / stop.
/// `pendingStop` is owned by the parent so the confirmation alert can be
/// attached to the popover root rather than to a row that may disappear.
struct ServersSection: View {
    @ObservedObject var store: UsageStore
    @Binding var pendingStop: LocalServer?

    @AppStorage("serverRowLimit")
    private var serverRowLimit = 5
    @AppStorage("confirmServerStops")
    private var confirmServerStops = true
    @State private var expandedID: String?

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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(server.reachable == false
                          ? HeadroomPalette.red
                          : HeadroomPalette.green)
                    .frame(width: 7, height: 7)
                Text(server.name ?? "Server")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let latency = server.latencyMS {
                    Text(verbatim: "\(latency)ms")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: ":\(server.port ?? 0)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if server.port != nil {
                    Button {
                        open(server)
                    } label: {
                        Image(systemName: "arrow.up.right")
                    }
                    .buttonStyle(.borderless)
                    .help("Open in browser")
                    .accessibilityLabel("Open")
                }
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
            .contentShape(Rectangle())
            .onTapGesture {
                expandedID = expandedID == server.id ? nil : server.id
            }
            if expandedID == server.id {
                detail(server)
            }
        }
    }

    @ViewBuilder
    private func detail(_ server: LocalServer) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary(server))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let cwd = server.cwd {
                    Text(cwd)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if server.cwd != nil {
                Button {
                    openFolder(server)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
                .accessibilityLabel("Folder")
            }
        }
        .padding(.leading, 15)
    }

    private func summary(_ server: LocalServer) -> String {
        let process = server.cmd ?? "process"
        let pid = server.pid.map { "PID \($0)" }
        let exposure = server.bind == "*" ? "LAN visible" : "local only"
        return [process, pid, exposure].compactMap { $0 }.joined(separator: " · ")
    }

    private func open(_ server: LocalServer) {
        guard let port = server.port,
              let url = URL(string: "http://127.0.0.1:\(port)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openFolder(_ server: LocalServer) {
        guard let cwd = server.cwd else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
    }

    private func requestStop(_ server: LocalServer) {
        if confirmServerStops {
            pendingStop = server
        } else {
            Task { await store.stopServer(server) }
        }
    }
}
