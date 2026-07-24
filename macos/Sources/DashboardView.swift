import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: UsageStore
    @AppStorage("selectedProvider")
    private var selectedProviderRaw = UsageProvider.codex.rawValue
    @AppStorage("selectedDashboard")
    private var selectedDashboardRaw = DashboardSelection.overview.rawValue
    @AppStorage("activityRowLimit")
    private var activityRowLimit = 8
    @AppStorage("serverRowLimit")
    private var serverRowLimit = 5
    @AppStorage("confirmServerStops")
    private var confirmServerStops = true
    @AppStorage("supabaseFavoriteRefs")
    private var supabaseFavoriteRefsRaw = ""
    @AppStorage("supabaseRowLimit")
    private var supabaseRowLimit = 6
    @AppStorage("dismissedAttentionFingerprint")
    private var dismissedAttentionFingerprint = ""
    @State private var serverToStop: LocalServer?
    @State private var expandedServerID: String?
    @State private var expandedSupabaseRef: String?
    @State private var showAllSupabaseProjects = false

    private var selectedProvider: UsageProvider {
        UsageProvider(rawValue: selectedProviderRaw) ?? .codex
    }

    private var meter: ProviderMeter {
        store.snapshot.meter(for: selectedProvider)
    }

    private var selectedDashboard: DashboardSelection {
        DashboardSelection(rawValue: selectedDashboardRaw) ?? .overview
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    providerSwitcher
                    if selectedDashboard == .overview {
                        quotaOverview
                        DailyBurnCard(days: store.snapshot.byDay ?? [])
                        attentionCard
                    } else {
                        quotaCard
                    }
                    activityTimeline
                    supabaseProjects
                    servers
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 390, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(item: $serverToStop) { server in
            Alert(
                title: Text("Stop \(server.name ?? "server")?"),
                message: Text("This terminates the local process."),
                primaryButton: .destructive(Text("Stop")) {
                    Task { await store.stopServer(server) }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Headroom")
                    .font(.headline)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Circle()
                    .fill(headerDotColor)
                    .frame(width: 7, height: 7)
            }
        }
        .padding(16)
    }

    private var headerDotColor: Color {
        if store.errorMessage != nil { return .orange }
        if AttentionAck.shouldShowPip(for: store.snapshot.attention) {
            if store.snapshot.attention?.isCritical == true { return .red }
            return .orange
        }
        return .green
    }

    private var providerSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(DashboardSelection.allCases, id: \.rawValue) { selection in
                let isSelected = selectedDashboardRaw == selection.rawValue
                Button {
                    selectedDashboardRaw = selection.rawValue
                    if let provider = selection.provider {
                        selectedProviderRaw = provider.rawValue
                    }
                } label: {
                    Text(selection.title)
                        .font(.caption.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                        .background {
                            if isSelected {
                                Capsule(style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.06), radius: 1, y: 0.5)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            Color(nsColor: .separatorColor).opacity(0.35),
            in: Capsule(style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dashboard")
    }

    private var quotaOverview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Coding quotas")
                .font(.headline)
            HStack(spacing: 10) {
                ForEach(UsageProvider.allCases, id: \.rawValue) { provider in
                    ProviderQuotaRing(
                        meter: store.snapshot.meter(for: provider),
                        tint: provider.tint
                    )
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedProviderRaw = provider.rawValue
                        selectedDashboardRaw = provider.rawValue
                    }
                }
            }
        }
        .cardStyle()
    }

    private var quotaCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(selectedProvider.title)
                    .font(.headline)
                Spacer()
                Text(meter.plan ?? "—")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            QuotaRow(
                title: meter.primary.title,
                percent: meter.primary.percent,
                pacePercent: meter.primary.pacePercent,
                reset: meter.primary.reset,
                tint: selectedProvider.tint
            )
            QuotaRow(
                title: meter.secondary.title,
                percent: meter.secondary.percent,
                pacePercent: meter.secondary.pacePercent,
                reset: meter.secondary.reset,
                tint: selectedProvider.tint
            )
            if let tertiary = meter.tertiary {
                QuotaRow(
                    title: tertiary.title,
                    percent: tertiary.percent,
                    pacePercent: tertiary.pacePercent,
                    reset: tertiary.reset,
                    tint: selectedProvider.tint
                )
            }
            if let pace = meter.paceLabel {
                HStack {
                    Text(pace)
                    Spacer()
                    if let runsOut = meter.runsOutIn {
                        Text("Runs out in \(runsOut)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let cost = meter.costLabel {
                Text(cost)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !meter.ok, let error = meter.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .cardStyle()
    }

    private var attentionCard: some View {
        let attention = store.snapshot.attention
        let reasons = attention?.reasons ?? []
        let showPip = AttentionAck.shouldShowPip(
            for: attention,
            dismissedFingerprint: dismissedAttentionFingerprint.isEmpty
                ? nil
                : dismissedAttentionFingerprint
        )
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Attention")
                    .font(.headline)
                Spacer()
                if showPip, let attention {
                    Button {
                        dismissedAttentionFingerprint = attention.fingerprint
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear attention")
                    .accessibilityLabel("Clear attention")
                } else if attention?.isWarning == true {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .help("Cleared until something new")
                        .accessibilityLabel("Attention cleared")
                } else {
                    Text(attention?.summary ?? "All clear")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(attentionTint(attention?.level))
                        .lineLimit(1)
                }
            }
            if !reasons.isEmpty {
                ForEach(reasons.prefix(5)) { reason in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(attentionTint(reason.level))
                            .frame(width: 7, height: 7)
                            .padding(.top, 4)
                        Text(reason.summary ?? "Needs attention")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            HStack(spacing: 10) {
                GlanceStat(
                    value: String(store.snapshot.local?.servers?.count ?? 0),
                    label: "servers"
                )
                GlanceStat(
                    value: store.snapshot.today?.costUSD.map(\.dollarLabel)
                        ?? "—",
                    label: "Claude today"
                )
                GlanceStat(
                    value: store.snapshot.codex?.costLabel
                        ?? store.snapshot.codex?.costUSD.map(\.dollarLabel)
                        ?? "—",
                    label: "Codex"
                )
                GlanceStat(
                    value: store.snapshot.cursor?.costLabel ?? "—",
                    label: "Cursor"
                )
            }
        }
        .cardStyle()
    }

    private func attentionTint(_ level: String?) -> Color {
        switch level {
        case "critical": .red
        case "warn": .orange
        default: .green
        }
    }

    @ViewBuilder
    private var supabaseProjects: some View {
        let data = store.snapshot.supabase
        let allProjects = data?.projects ?? []
        let favorites = supabaseFavoriteRefs
        let attention = allProjects.filter {
            $0.healthy == false || favorites.contains($0.ref)
        }
        let preferred = attention.isEmpty ? allProjects : attention
        let limit = max(1, min(supabaseRowLimit, 20))
        let rows = showAllSupabaseProjects
            ? allProjects
            : Array(preferred.prefix(limit))

        DataSection(title: "Supabase") {
            if data?.configured != true {
                HStack {
                    Text(data?.error ?? "Connect Supabase to monitor projects.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    SettingsLink {
                        Image(systemName: "link")
                    }
                    .buttonStyle(.borderless)
                    .help("Open Settings to connect")
                    .accessibilityLabel("Connect Supabase")
                }
            } else if data?.ok != true {
                Text(data?.error ?? "Supabase unavailable")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("\(data?.projectCount ?? allProjects.count) projects")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(rows, id: \.ref) { (project: SupabaseProject) in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(project.healthy == true ? .green : .red)
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(project.name ?? project.ref)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                let context = supabaseProjectContext(project)
                                if !context.isEmpty {
                                    Text(context)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Button {
                                toggleSupabaseFavorite(project.ref)
                            } label: {
                                Image(systemName: favorites.contains(project.ref)
                                    ? "pin.fill" : "pin")
                            }
                            .buttonStyle(.borderless)
                            .help(favorites.contains(project.ref)
                                ? "Unpin project" : "Pin project")
                            .accessibilityLabel(favorites.contains(project.ref)
                                ? "Unpin" : "Pin")
                            Button {
                                openSupabaseProject(project)
                            } label: {
                                Image(systemName: "arrow.up.right")
                            }
                            .buttonStyle(.borderless)
                            .help("Open in Supabase")
                            .accessibilityLabel("Open")
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            let ref = project.ref
                            expandedSupabaseRef = expandedSupabaseRef == ref ? nil : ref
                        }
                        if expandedSupabaseRef == project.ref {
                            Text(supabaseServiceSummary(project))
                                .font(.caption)
                                .foregroundStyle(
                                    project.healthy == true
                                        ? AnyShapeStyle(.secondary)
                                        : AnyShapeStyle(Color.red)
                                )
                                .padding(.leading, 15)
                        }
                    }
                }

                if allProjects.count > limit {
                    Button {
                        showAllSupabaseProjects.toggle()
                    } label: {
                        Label(
                            showAllSupabaseProjects
                                ? "Show attention only"
                                : "Show all",
                            systemImage: showAllSupabaseProjects
                                ? "line.3.horizontal.decrease"
                                : "ellipsis.circle"
                        )
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private var activityTimeline: some View {
        let rows = Array((store.snapshot.activity ?? [])
            .prefix(max(3, min(activityRowLimit, 14))))
        if !rows.isEmpty {
            DataSection(title: "GitHub") {
                ForEach(rows) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .top, spacing: 9) {
                            Circle()
                                .fill(activityColor(item))
                                .frame(width: 7, height: 7)
                                .padding(.top, 5)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.subject ?? "Event")
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text(activityContext(item))
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
                                .foregroundStyle(.orange)
                                .lineLimit(2)
                                .padding(.leading, 16)
                        }
                        if item.status == "error" || item.status == "canceled" {
                            HStack {
                                Spacer()
                                if activityURL(item) != nil {
                                    Button {
                                        openActivity(item)
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
                    .onTapGesture {
                        openActivity(item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var servers: some View {
        let rows = Array((store.snapshot.local?.servers ?? [])
            .prefix(max(1, min(serverRowLimit, 8))))
        if !rows.isEmpty {
            DataSection(title: "Local servers") {
                ForEach(rows) { server in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(server.reachable == false ? .red : .green)
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
                                    openServer(server)
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
                                    .foregroundStyle(.red)
                                    .help("Stop server")
                                    .accessibilityLabel("Stop")
                                }
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            expandedServerID = expandedServerID == server.id
                                ? nil : server.id
                        }
                        if expandedServerID == server.id {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(serverDetail(server))
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
                                        openServerFolder(server)
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
                    }
                }
            }
        }
    }

    private func activityContext(_ item: ActivityItem) -> String {
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

    private func activityColor(_ item: ActivityItem) -> Color {
        switch item.status {
        case "ready": .green
        case "building", "running": .orange
        case "error", "failure": .orange
        case "canceled", "cancelled": .secondary
        case "pushed": .blue
        case "local": .purple
        default: .secondary
        }
    }

    private func activityURL(_ item: ActivityItem) -> URL? {
        let raw = item.inspectorURL ?? item.url
        guard let raw, !raw.isEmpty else { return nil }
        return URL(string: raw.contains("://") ? raw : "https://\(raw)")
    }

    private func openActivity(_ item: ActivityItem) {
        guard let url = activityURL(item) else { return }
        NSWorkspace.shared.open(url)
    }

    private func openServer(_ server: LocalServer) {
        guard let port = server.port,
              let url = URL(string: "http://127.0.0.1:\(port)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openServerFolder(_ server: LocalServer) {
        guard let cwd = server.cwd else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
    }

    private func requestStop(_ server: LocalServer) {
        if confirmServerStops {
            serverToStop = server
        } else {
            Task { await store.stopServer(server) }
        }
    }

    private func serverDetail(_ server: LocalServer) -> String {
        let process = server.cmd ?? "process"
        let pid = server.pid.map { "PID \($0)" }
        let exposure = server.bind == "*" ? "LAN visible" : "local only"
        return [process, pid, exposure].compactMap { $0 }.joined(separator: " · ")
    }

    private var supabaseFavoriteRefs: Set<String> {
        Set(supabaseFavoriteRefsRaw.split(separator: ",").map(String.init))
    }

    private func toggleSupabaseFavorite(_ ref: String) {
        var values = supabaseFavoriteRefs
        if values.contains(ref) {
            values.remove(ref)
        } else {
            values.insert(ref)
        }
        supabaseFavoriteRefsRaw = values.sorted().joined(separator: ",")
    }

    private func supabaseProjectContext(_ project: SupabaseProject) -> String {
        // Green/red dot already signals health — only add detail when unhealthy.
        let detail: String? = project.healthy == true
            ? nil
            : ((project.unhealthyServices ?? []).isEmpty
               ? project.status
               : (project.unhealthyServices ?? []).joined(separator: ", "))
        return [detail, project.region].compactMap { $0 }.joined(separator: " · ")
    }

    private func supabaseServiceSummary(_ project: SupabaseProject) -> String {
        let services = project.services ?? []
        if services.isEmpty {
            return project.healthError ?? project.status ?? "No service detail"
        }
        let unhealthy = services.filter { $0.healthy != true }.map(\.name)
        if unhealthy.isEmpty {
            return services.map(\.name).joined(separator: " · ")
        }
        return unhealthy.joined(separator: " · ") + " down"
    }

    private func openSupabaseProject(_ project: SupabaseProject) {
        guard let raw = project.dashboardURL,
              let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)
            .help("Refresh")
            .accessibilityLabel("Refresh")
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Settings")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("Quit")
            .accessibilityLabel("Quit")
        }
        .font(.body)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var statusLine: String {
        if let error = store.errorMessage {
            return error
        }
        if let attention = store.snapshot.attention,
           AttentionAck.shouldShowPip(for: attention) {
            return attention.summary ?? "Needs attention"
        }
        if let stale = worstStaleSource {
            let age = stale.ageS ?? 0
            let minutes = max(1, age / 60)
            let title = stale.title ?? stale.id
            return "\(title) · \(minutes)m stale"
        }
        if let lastRefresh = store.lastRefresh {
            return "Updated \(lastRefresh.formatted(.relative(presentation: .named)))"
        }
        return "Connecting to localhost:8737"
    }

    private var worstStaleSource: SyncSource? {
        (store.snapshot.sources ?? [])
            .filter { ($0.enabled ?? true) && $0.stale == true }
            .sorted { ($0.ageS ?? 0) > ($1.ageS ?? 0) }
            .first
    }

}

private extension UsageProvider {
    var tint: Color {
        switch self {
        case .claude: Color(red: 204 / 255, green: 124 / 255, blue: 94 / 255)
        case .codex: Color(red: 73 / 255, green: 163 / 255, blue: 176 / 255)
        case .cursor: Color(red: 0 / 255, green: 191 / 255, blue: 165 / 255)
        }
    }
}

private struct QuotaRow: View {
    let title: String
    let percent: Double?
    let pacePercent: Double?
    let reset: String?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.body)
                .fontWeight(.medium)
            CodexBarProgressBar(
                percent: percent ?? 0,
                tint: tint,
                pacePercent: pacePercent,
                paceOnTop: (percent ?? 0) <= (pacePercent ?? 100),
                accessibilityLabel: "\(title) usage"
            )
            HStack {
                Text(percent.map { "\(Int($0.rounded()))%" } ?? "—")
                    .lineLimit(1)
                Spacer()
                if let reset {
                    Text(reset)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .font(.footnote)
        }
    }
}

private struct ProviderQuotaRing: View {
    let meter: ProviderMeter
    let tint: Color

    private var headline: MeterWindow { meter.headline }

    private var windowCaption: String {
        if let reset = headline.reset, !reset.isEmpty {
            return "\(headline.title) · \(reset)"
        }
        return headline.title
    }

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                QuotaRingCanvas(
                    percent: headline.percent,
                    pacePercent: headline.pacePercent,
                    tint: tint
                )
                Text(headline.percent.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }
            .frame(width: 72, height: 72)
            Text(meter.provider.title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(tint)
            Text(windowCaption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct QuotaRingCanvas: View {
    let percent: Double?
    let pacePercent: Double?
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let lineWidth: CGFloat = 7
            let inset = lineWidth / 2 + 1
            let rect = CGRect(origin: .zero, size: size)
                .insetBy(dx: inset, dy: inset)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = rect.width / 2

            var track = Path()
            track.addEllipse(in: rect)
            context.stroke(
                track,
                with: .color(Color(nsColor: .tertiaryLabelColor).opacity(0.22)),
                lineWidth: lineWidth
            )

            if let percent {
                let fillTint = percent >= 100 ? tint.drained() : tint
                var usage = Path()
                usage.addArc(
                    center: center,
                    radius: radius,
                    startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + max(0, min(percent, 100)) * 3.6),
                    clockwise: false
                )
                context.stroke(
                    usage,
                    with: .color(fillTint),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
                )
            }

            if let pacePercent {
                let angle = -90 + max(0, min(pacePercent, 100)) * 3.6
                var tick = Path()
                tick.addArc(
                    center: center,
                    radius: radius,
                    startAngle: .degrees(angle - 2.8),
                    endAngle: .degrees(angle + 2.8),
                    clockwise: false
                )
                context.stroke(
                    tick,
                    with: .color(.primary),
                    style: StrokeStyle(lineWidth: lineWidth + 3, lineCap: .butt)
                )
            }
        }
    }
}

private struct GlanceStat: View {
    let value: String
    let label: String
    var tint: Color = .primary

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct DataSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            VStack(spacing: 10) {
                content
            }
        }
        .cardStyle()
    }
}

private extension View {
    func cardStyle() -> some View {
        padding(14)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.primary.opacity(0.07))
            }
    }
}

private enum DashboardSelection: String, CaseIterable {
    case overview
    case claude
    case codex
    case cursor

    var title: String {
        switch self {
        case .overview: "Overview"
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }

    var provider: UsageProvider? {
        UsageProvider(rawValue: rawValue)
    }
}
