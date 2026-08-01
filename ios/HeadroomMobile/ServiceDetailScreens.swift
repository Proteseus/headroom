import SwiftUI

/// Shared LabeledContent row for API metadata detail pages.
struct APIDetailMetaRow: View {
    let title: String
    let value: String?
    var monospaced: Bool = false

    var body: some View {
        if let value, !value.isEmpty {
            LabeledContent(title) {
                Text(value)
                    .font(monospaced ? .body.monospaced() : .body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

// MARK: - Plausible

struct PlausibleSiteDetail: View {
    let site: PlausibleSite

    var body: some View {
        List {
            Section("Site") {
                APIDetailMetaRow(title: "Domain", value: site.domain, monospaced: true)
                APIDetailMetaRow(title: "Window", value: site.windowLabel)
                if let error = site.error, !error.isEmpty {
                    LabeledContent("Error") {
                        Text(error)
                            .foregroundStyle(HeadroomPalette.amber)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            Section("Traffic") {
                intRow("Live now", site.realtime)
                intRow("Visitors · \(site.windowLabel)", site.visitorsToday)
                intRow("Pageviews · \(site.windowLabel)", site.pageviewsToday)
                intRow("Visitors · 7d", site.visitors7d)
                intRow("Pageviews · 7d", site.pageviews7d)
                if let bounce = site.bounceRate7d {
                    APIDetailMetaRow(
                        title: "Bounce rate · 7d",
                        value: "\(Int(bounce.rounded()))%"
                    )
                }
                if let duration = site.visitDuration7d {
                    APIDetailMetaRow(
                        title: "Visit duration · 7d",
                        value: Self.durationLabel(duration)
                    )
                }
            }
            if let raw = site.dashboardURL, let url = URL(string: raw) {
                Section {
                    Link("Open in Plausible", destination: url)
                }
            }
        }
        .navigationTitle(site.domain)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func intRow(_ title: String, _ value: Int?) -> some View {
        if let value {
            LabeledContent(title) {
                Text(HeadroomFormat.compact(value))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private static func durationLabel(_ seconds: Int) -> String {
        if seconds >= 60 {
            return "\(seconds / 60)m \(seconds % 60)s"
        }
        return "\(seconds)s"
    }
}

// MARK: - PostHog

struct PostHogProjectDetail: View {
    let project: PostHogProject

    var body: some View {
        List {
            Section("Project") {
                APIDetailMetaRow(title: "Name", value: project.displayName)
                APIDetailMetaRow(title: "ID", value: project.id, monospaced: true)
                APIDetailMetaRow(title: "Window", value: project.windowLabel)
                if let error = project.error, !error.isEmpty {
                    LabeledContent("Error") {
                        Text(error)
                            .foregroundStyle(HeadroomPalette.amber)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            Section("Events") {
                intRow("Live now", project.realtime)
                intRow("Events · \(project.windowLabel)", project.eventsToday)
                intRow("Users · \(project.windowLabel)", project.usersToday)
                intRow("Events · 7d", project.events7d)
                intRow("Users · 7d", project.users7d)
            }
            if let raw = project.dashboardURL, let url = URL(string: raw) {
                Section {
                    Link("Open in PostHog", destination: url)
                }
            }
        }
        .navigationTitle(project.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func intRow(_ title: String, _ value: Int?) -> some View {
        if let value {
            LabeledContent(title) {
                Text(HeadroomFormat.compact(value))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Local server

struct LocalServerDetail: View {
    let server: LocalServer
    let hostName: String
    let canStop: Bool
    let isStopping: Bool
    var onStop: () -> Void

    var body: some View {
        List {
            Section("Server") {
                HStack {
                    Text("Reachable")
                    Spacer()
                    Circle()
                        .fill(server.reachable == false
                              ? HeadroomPalette.red
                              : HeadroomPalette.green)
                        .frame(width: 8, height: 8)
                    Text(server.reachable == false ? "No" : "Yes")
                        .foregroundStyle(.secondary)
                }
                APIDetailMetaRow(title: "Name", value: server.name)
                APIDetailMetaRow(title: "Host", value: hostName)
                if let port = server.port {
                    APIDetailMetaRow(title: "Port", value: "\(port)", monospaced: true)
                }
                APIDetailMetaRow(title: "Bind", value: server.bind, monospaced: true)
                if let pid = server.pid {
                    APIDetailMetaRow(title: "PID", value: "\(pid)", monospaced: true)
                }
                if let latency = server.latencyMS {
                    APIDetailMetaRow(title: "Latency", value: "\(latency) ms")
                }
            }
            Section("Process") {
                APIDetailMetaRow(title: "Command", value: server.cmd, monospaced: true)
                APIDetailMetaRow(title: "Working directory", value: server.cwd, monospaced: true)
            }
            if server.pid != nil {
                Section {
                    Button("Stop server", role: .destructive) {
                        onStop()
                    }
                    .disabled(!canStop || isStopping)
                    if isStopping {
                        ProgressView()
                    }
                } footer: {
                    if !canStop {
                        Text("Stopping servers needs the Mac permission, and a fresh reading.")
                    }
                }
            }
        }
        .navigationTitle(server.name ?? "Server")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Activity feed

struct ActivityItemDetail: View {
    let item: ActivityItem

    var body: some View {
        let style = ActivityStatusStyle.resolve(item.status)
        List {
            Section("Event") {
                HStack {
                    Text("Status")
                    Spacer()
                    Image(systemName: style.symbol)
                        .foregroundStyle(.secondary)
                    Text(style.label)
                        .foregroundStyle(.secondary)
                }
                APIDetailMetaRow(title: "Subject", value: item.subject)
                APIDetailMetaRow(title: "Kind", value: item.kind)
                APIDetailMetaRow(title: "When", value: item.ago)
                if let error = item.errorMessage, !error.isEmpty {
                    LabeledContent("Error") {
                        Text(error)
                            .foregroundStyle(HeadroomPalette.red)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
            }
            Section("Coordinates") {
                APIDetailMetaRow(title: "Repo", value: item.repo, monospaced: true)
                APIDetailMetaRow(title: "Project", value: item.project)
                APIDetailMetaRow(title: "Branch", value: item.branch, monospaced: true)
                APIDetailMetaRow(title: "SHA", value: item.sha ?? item.shortSHA, monospaced: true)
                APIDetailMetaRow(title: "Target", value: item.target)
                APIDetailMetaRow(title: "Author", value: item.author.map {
                    $0.hasPrefix("@") ? $0 : "@\($0)"
                })
                if let number = item.number {
                    APIDetailMetaRow(title: "Number", value: "#\(number)")
                }
                APIDetailMetaRow(title: "ID", value: item.id, monospaced: true)
            }
            if primaryURL != nil || inspectorURL != nil {
                Section {
                    if let url = primaryURL {
                        Link("Open", destination: url)
                    }
                    if let url = inspectorURL, url != primaryURL {
                        Link("Inspector", destination: url)
                    }
                }
            }
        }
        .navigationTitle(item.subject ?? style.label)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var primaryURL: URL? {
        Self.url(from: item.url)
    }

    private var inspectorURL: URL? {
        Self.url(from: item.inspectorURL)
    }

    private static func url(from raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        return URL(string: raw.contains("://") ? raw : "https://\(raw)")
    }
}
