#if os(macOS)
import AppKit
#endif
import SwiftUI

/// Shared LabeledContent row for API metadata detail pages.
/// Used by iPhone Activity push pages and the Mac menubar drill-in.
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
        let series = site.byDay ?? []
        List {
            Section("Site") {
                APIDetailMetaRow(title: "Domain", value: site.domain, monospaced: true)
                APIDetailMetaRow(title: "Window", value: site.windowLabel)
                if let error = site.error, !error.isEmpty {
                    LabeledContent("Error") {
                        Text(error)
                            .foregroundStyle(HeadroomPalette.orange)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            if !series.isEmpty {
                Section {
                    PlausibleTrafficChart(
                        days: series,
                        title: site.windowLabel,
                        tint: HeadroomPalette.providerTint(id: "plausible")
                    )
                    .padding(.vertical, 4)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
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
        }
        .serviceDetailChrome(
            title: site.domain,
            permalink: Permalink.url(from: site.dashboardURL)
        )
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
                            .foregroundStyle(HeadroomPalette.orange)
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
        }
        .serviceDetailChrome(
            title: project.displayName,
            permalink: Permalink.url(from: project.dashboardURL)
        )
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
            #if os(macOS)
            if let cwd = server.cwd {
                Section {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(
                            nil, inFileViewerRootedAtPath: cwd)
                    }
                }
            }
            #endif
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
                    #if os(iOS)
                    if !canStop {
                        Text("Stopping servers needs the Mac permission, and a fresh reading.")
                    }
                    #endif
                }
            }
        }
        .serviceDetailChrome(
            title: server.name ?? "Server",
            permalink: Permalink.localServer(server)
        )
    }
}

struct LocalBuildDetail: View {
    let build: LocalBuild
    let hostName: String

    var body: some View {
        List {
            Section("Build") {
                HStack {
                    Text("Status")
                    Spacer()
                    Circle()
                        .fill(HeadroomPalette.green)
                        .frame(width: 8, height: 8)
                    Text(HeadroomCopy.activityBuilding)
                        .foregroundStyle(.secondary)
                }
                APIDetailMetaRow(title: "Name", value: build.name)
                APIDetailMetaRow(title: "Host", value: hostName)
                APIDetailMetaRow(title: "Kind", value: build.kind, monospaced: true)
                APIDetailMetaRow(title: "Action", value: build.action)
                APIDetailMetaRow(title: "Scheme", value: build.scheme)
                APIDetailMetaRow(title: "Target", value: build.target)
                if let age = build.ageS {
                    APIDetailMetaRow(
                        title: "Age",
                        value: age < 60 ? "\(age)s" : "\(age / 60)m"
                    )
                }
                if let pid = build.pid {
                    APIDetailMetaRow(title: "PID", value: "\(pid)", monospaced: true)
                }
            }
            Section("Process") {
                APIDetailMetaRow(title: "Command", value: build.cmd, monospaced: true)
                APIDetailMetaRow(title: "Working directory", value: build.cwd, monospaced: true)
            }
            #if os(macOS)
            if let cwd = build.cwd {
                Section {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(
                            nil, inFileViewerRootedAtPath: cwd)
                    }
                }
            }
            #endif
        }
        .serviceDetailChrome(title: build.name ?? "Xcode")
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
        }
        .serviceDetailChrome(
            title: item.subject ?? style.label,
            permalink: Permalink.activity(item)
        )
    }
}
