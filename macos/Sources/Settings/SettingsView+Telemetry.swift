import AppKit
import SwiftUI

extension SettingsView {
    var telemetryPane: some View {
        Form {
            telemetrySection
            if telemetryEnabled {
                communityPulseSection
            }
        }
        .formStyle(.grouped)
        .task {
            await reloadTelemetryPreview()
            await reloadCommunityStats()
        }
    }

    var telemetrySection: some View {
        Section {
            Toggle(
                HeadroomCopy.telemetryToggle,
                isOn: $telemetryEnabled
            )
            .onChange(of: telemetryEnabled) { _, enabled in
                HeadroomTelemetry.setEnabled(enabled)
                if !enabled {
                    telemetryPreview = nil
                    telemetryCopyMessage = nil
                }
            }

            DisclosureGroup(HeadroomCopy.telemetryWhatIsShared) {
                Text(HeadroomCopy.telemetrySharedDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(HeadroomCopy.telemetryNeverSharedDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link(
                    HeadroomCopy.telemetryViewSource,
                    destination: HeadroomTelemetry.sourceURL
                )
                .font(.caption)
            }

            if telemetryEnabled {
                DisclosureGroup(HeadroomCopy.telemetryVisualizer) {
                    telemetryVisualizer
                }
            }
        } header: {
            Text(HeadroomCopy.telemetryHeader)
        } footer: {
            Text(HeadroomCopy.telemetryFooter)
        }
    }

    @ViewBuilder
    var communityPulseSection: some View {
        Section {
            if communityStatsLoading {
                ProgressView(HeadroomCopy.telemetryCommunityLoading)
                    .controlSize(.small)
            } else if let communityStats,
                      let latest = communityStats.latest {
                communityPulseView(communityStats, latest: latest)
            } else if communityStatsMessage != nil {
                Text(HeadroomCopy.telemetryCommunityUnavailable)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(HeadroomCopy.telemetryCommunityGrowing)
                        .font(.callout.weight(.medium))
                    Text(HeadroomCopy.telemetryCommunityThreshold)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                Button {
                    Task { await reloadCommunityStats() }
                } label: {
                    Label(
                        HeadroomCopy.telemetryRefreshCommunity,
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.borderless)
                Link(
                    HeadroomCopy.telemetryCommunityPulse,
                    destination: HeadroomTelemetry.communityURL
                )
                .font(.caption)
            }
        } header: {
            Text(HeadroomCopy.telemetryCommunityHeader)
        } footer: {
            Text(HeadroomCopy.telemetryCommunityFooter)
        }
    }

    @ViewBuilder
    func communityPulseView(
        _ stats: HeadroomCommunityStats,
        latest: HeadroomCommunityStats.Latest
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                telemetryMetric(
                    HeadroomCopy.telemetryWeeklyActive,
                    value: latest.reportingMacs.map(String.init)
                        ?? HeadroomCopy.telemetryCommunityGrowing,
                    detail: latest.period
                )
                telemetryMetric(
                    HeadroomCopy.telemetryWeekOverWeek,
                    value: communityWeekDeltaLabel(stats.weeklyActiveMacs),
                    detail: communityWeekDeltaDetail(stats.weeklyActiveMacs)
                )
                telemetryMetric(
                    HeadroomCopy.telemetryLatestBuild,
                    value: latest.versions.first?.name ?? "—",
                    detail: latest.versions.first.map {
                        "\($0.count) \(HeadroomCopy.telemetryMacs)"
                    }
                        ?? HeadroomCopy.telemetryCommunityThreshold
                )
                telemetryMetric(
                    HeadroomCopy.telemetryTopArchitecture,
                    value: latest.architectures.first?.name ?? "—",
                    detail: latest.architectures.first.map {
                        "\($0.count) \(HeadroomCopy.telemetryMacs)"
                    }
                        ?? HeadroomCopy.telemetryCommunityThreshold
                )
            }

            communityWeeklyChart(stats.weeklyActiveMacs)

            if latest.versions.isEmpty,
               latest.architectures.isEmpty,
               latest.macosMajors.isEmpty,
               latest.services.enabled.isEmpty,
               latest.services.used.isEmpty,
               latest.services.healthy.isEmpty,
               latest.modelShares.isEmpty,
               latest.features.isEmpty {
                Text(HeadroomCopy.telemetryCommunityThreshold)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                communityCountRows(
                    HeadroomCopy.telemetryBuildSpread,
                    items: latest.versions,
                    total: latest.reportingMacs
                )
                communityCountRows(
                    HeadroomCopy.telemetryArchitectureMix,
                    items: latest.architectures,
                    total: latest.reportingMacs
                )
                communityCountRows(
                    HeadroomCopy.telemetryMacOSMix,
                    items: latest.macosMajors.map {
                        HeadroomCommunityStats.CountedItem(
                            name: "macOS \($0.name)",
                            count: $0.count
                        )
                    },
                    total: latest.reportingMacs
                )
                communityServiceSections(latest.services, total: latest.reportingMacs)
                communityModelRows(latest.modelShares)
                communityFeatureRows(latest.features)
            }
        }
    }

    @ViewBuilder
    func communityWeeklyChart(
        _ weeks: [HeadroomCommunityStats.WeeklyActive]
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(HeadroomCopy.telemetryWeeklyActive)
                .font(.callout.weight(.medium))
            let maximum = max(1, weeks.compactMap(\.count).max() ?? 1)
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(weeks) { week in
                    VStack(spacing: 4) {
                        Text(
                            week.count.map(String.init)
                                ?? "·"
                        )
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(
                                week.count == nil
                                    ? Color.primary.opacity(0.12)
                                    : Color.primary.opacity(0.55)
                            )
                            .frame(
                                maxWidth: .infinity,
                                minHeight: 3,
                                maxHeight: 88 * CGFloat(
                                    Double(week.count ?? 0) / Double(maximum)
                                )
                            )
                        Text(String(week.period.suffix(2)))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 118, alignment: .bottom)
        }
    }

    @ViewBuilder
    func communityCountRows(
        _ title: String,
        items: [HeadroomCommunityStats.CountedItem],
        total: Int?
    ) -> some View {
        if items.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.callout.weight(.medium))
                ForEach(items) { item in
                    HStack(spacing: 8) {
                        Text(telemetryDisplayName(item.name))
                            .font(.caption)
                            .frame(width: 80, alignment: .leading)
                            .lineLimit(1)
                        ProgressView(
                            value: Double(item.count),
                            total: Double(max(total ?? item.count, 1))
                        )
                        .progressViewStyle(.linear)
                        .tint(Color.primary.opacity(0.55))
                        Text("\(item.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 32, alignment: .trailing)
                    }
                }
            }
        }
    }

    @ViewBuilder
    func communityServiceSections(
        _ services: HeadroomCommunityStats.Services,
        total: Int?
    ) -> some View {
        let sections: [(String, [HeadroomCommunityStats.CountedItem])] = [
            (HeadroomCopy.telemetryServicesEnabled, services.enabled),
            (HeadroomCopy.telemetryServicesUsed, services.used),
            (HeadroomCopy.telemetryServicesHealthy, services.healthy),
        ]
        if sections.allSatisfy(\.1.isEmpty) {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(HeadroomCopy.telemetryServiceMix)
                    .font(.callout.weight(.medium))
                ForEach(sections, id: \.0) { label, items in
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(label.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                            ForEach(items) { item in
                                HStack(spacing: 8) {
                                    Text(telemetryDisplayName(item.name))
                                        .font(.caption)
                                        .frame(width: 80, alignment: .leading)
                                        .lineLimit(1)
                                    ProgressView(
                                        value: Double(item.count),
                                        total: Double(max(total ?? item.count, 1))
                                    )
                                    .progressViewStyle(.linear)
                                    .tint(Color.primary.opacity(0.45))
                                    Text("\(item.count)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 32, alignment: .trailing)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    func communityModelRows(
        _ items: [HeadroomCommunityStats.ModelShare]
    ) -> some View {
        if items.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 7) {
                Text(HeadroomCopy.telemetryModelMix)
                    .font(.callout.weight(.medium))
                ForEach(items) { item in
                    let parts = item.name.split(separator: ":").map(String.init)
                    let label = parts.count > 1
                        ? "\(telemetryDisplayName(parts[0])) · \(telemetryDisplayName(parts[1]))"
                        : telemetryDisplayName(item.name)
                    HStack(spacing: 8) {
                        Text(label)
                            .font(.caption)
                            .frame(width: 110, alignment: .leading)
                            .lineLimit(1)
                        ProgressView(value: Double(item.share), total: 100)
                            .progressViewStyle(.linear)
                            .tint(Color.primary.opacity(0.55))
                        Text("\(item.share)%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
    }

    @ViewBuilder
    func communityFeatureRows(
        _ items: [HeadroomCommunityStats.Feature]
    ) -> some View {
        if items.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 7) {
                Text(HeadroomCopy.telemetryFeatureAdoption)
                    .font(.callout.weight(.medium))
                ForEach(items) { item in
                    HStack(spacing: 8) {
                        Text(telemetryDisplayName(item.name))
                            .font(.caption)
                            .frame(width: 110, alignment: .leading)
                            .lineLimit(1)
                        ProgressView(value: Double(item.adoption), total: 100)
                            .progressViewStyle(.linear)
                            .tint(Color.primary.opacity(0.55))
                        Text("\(item.adoption)%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
    }

    func communityWeekDelta(
        _ weeks: [HeadroomCommunityStats.WeeklyActive]
    ) -> Int? {
        let published = weeks.compactMap(\.count)
        guard published.count >= 2 else { return nil }
        return published[published.count - 1] - published[published.count - 2]
    }

    func communityWeekDeltaLabel(
        _ weeks: [HeadroomCommunityStats.WeeklyActive]
    ) -> String {
        guard let delta = communityWeekDelta(weeks) else { return "—" }
        return delta > 0 ? "+\(delta)" : "\(delta)"
    }

    func communityWeekDeltaDetail(
        _ weeks: [HeadroomCommunityStats.WeeklyActive]
    ) -> String {
        communityWeekDelta(weeks) == nil
            ? HeadroomCopy.telemetryNeedPriorWeek
            : HeadroomCopy.telemetryLatestWeek
    }

    @ViewBuilder
    var telemetryVisualizer: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(
                    telemetryPreview == nil
                        ? HeadroomCopy.telemetryWaitingForPreview
                        : HeadroomCopy.telemetryPreviewReady,
                    systemImage: telemetryPreview == nil
                        ? "circle.dashed"
                        : "checkmark.circle"
                )
                .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await reloadTelemetryPreview() }
                } label: {
                    if telemetryPreviewLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(
                            HeadroomCopy.telemetryRefreshPreview,
                            systemImage: "arrow.clockwise"
                        )
                    }
                }
                .buttonStyle(.borderless)
                .disabled(telemetryPreviewLoading || !telemetryEnabled)
            }

            if let preview = telemetryPreview, telemetryEnabled {
                telemetrySummary(preview)
                telemetryProviders(preview)
                telemetryModels(preview)
                telemetryFeatures(preview)

                HStack(spacing: 12) {
                    Button(HeadroomCopy.telemetryCopyPayload) {
                        copyTelemetryPayload(preview)
                    }
                    .buttonStyle(.bordered)
                    if let telemetryCopyMessage {
                        Text(telemetryCopyMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if !telemetryEnabled {
                Text(HeadroomCopy.telemetryPreviewOff)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if telemetryPreviewLoading {
                ProgressView(HeadroomCopy.telemetryBuildingPreview)
                    .controlSize(.small)
            } else {
                Text(HeadroomCopy.telemetryPreviewUnavailable)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    func telemetrySummary(_ preview: HeadroomTelemetryBatch) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                telemetryMetric(
                    HeadroomCopy.telemetryApp,
                    value: preview.app.version,
                    detail: "build \(preview.app.build)"
                )
                telemetryMetric(
                    HeadroomCopy.telemetryHost,
                    value: preview.app.hostVersion ?? HeadroomCopy.notAvailable,
                    detail: HeadroomCopy.telemetryHostVersionDetail
                )
                telemetryMetric(
                    HeadroomCopy.telemetryPeriod,
                    value: preview.period,
                    detail: HeadroomCopy.telemetryWeeklyDetail
                )
            }

            HStack(spacing: 8) {
                telemetryMetric(
                    HeadroomCopy.telemetryMac,
                    value: "macOS \(preview.app.macOSMajor)",
                    detail: preview.app.architecture
                )
                telemetryMetric(
                    HeadroomCopy.telemetryLastSent,
                    value: telemetryLastSubmittedLabel,
                    detail: telemetryPendingLabel
                )
            }
        }
    }

    @ViewBuilder
    func telemetryMetric(_ label: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    func telemetryProviders(_ preview: HeadroomTelemetryBatch) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(HeadroomCopy.telemetryServices)
                .font(.callout.weight(.medium))
            let ids = Set(
                preview.providers.enabled
                    + preview.providers.used
                    + preview.providers.healthy
            ).sorted()
            if ids.isEmpty {
                Text(HeadroomCopy.telemetryNoServices)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ids, id: \.self) { id in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.primary.opacity(0.45))
                            .frame(width: 8, height: 8)
                        Text(telemetryDisplayName(id))
                            .font(.caption)
                        Spacer()
                        telemetryFlag(
                            HeadroomCopy.telemetryEnabled,
                            preview.providers.enabled.contains(id)
                        )
                        telemetryFlag(
                            HeadroomCopy.telemetryUsed,
                            preview.providers.used.contains(id)
                        )
                        telemetryFlag(
                            HeadroomCopy.telemetryHealthy,
                            preview.providers.healthy.contains(id)
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    func telemetryFlag(_ label: String, _ on: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: on ? "checkmark" : "minus")
                .font(.caption2.weight(.bold))
                .foregroundStyle(
                    on
                        ? AnyShapeStyle(.primary.opacity(0.7))
                        : AnyShapeStyle(.tertiary)
                )
            Text(label)
                .font(.caption2)
                .foregroundStyle(
                    on
                        ? AnyShapeStyle(.secondary)
                        : AnyShapeStyle(.tertiary)
                )
        }
        .help(label)
    }

    @ViewBuilder
    func telemetryModels(_ preview: HeadroomTelemetryBatch) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(HeadroomCopy.telemetryModels)
                .font(.callout.weight(.medium))
            if preview.models.isEmpty {
                Text(HeadroomCopy.telemetryNoModels)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(preview.models.keys.sorted(), id: \.self) { provider in
                    ForEach(
                        (preview.models[provider] ?? [:]).sorted {
                            if $0.value != $1.value { return $0.value > $1.value }
                            return $0.key < $1.key
                        },
                        id: \.key
                    ) { family, share in
                        HStack(spacing: 8) {
                            Text(telemetryDisplayName(provider))
                                .font(.caption)
                                .frame(width: 64, alignment: .leading)
                            Text(family.capitalized)
                                .font(.caption)
                                .frame(width: 58, alignment: .leading)
                            ProgressView(value: Double(share), total: 100)
                                .progressViewStyle(.linear)
                                .tint(Color.primary.opacity(0.55))
                            Text("\(share)%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    func telemetryFeatures(_ preview: HeadroomTelemetryBatch) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(HeadroomCopy.telemetryFeatures)
                .font(.callout.weight(.medium))
            if preview.features.isEmpty {
                Text(HeadroomCopy.telemetryNoFeatures)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ForEach(preview.features.keys.sorted(), id: \.self) { key in
                        Text("\(telemetryDisplayName(key)): \(preview.features[key] == true ? HeadroomCopy.on : HeadroomCopy.off)")
                            .font(.caption2)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.quaternary.opacity(0.45), in: Capsule())
                    }
                }
            }
        }
    }

    var telemetryLastSubmittedLabel: String {
        UserDefaults.standard.string(
            forKey: HeadroomTelemetry.lastSubmittedPeriodKey
        ) ?? HeadroomCopy.telemetryNever
    }

    var telemetryPendingLabel: String {
        HeadroomTelemetry.loadPendingBatch() == nil
            ? HeadroomCopy.telemetryNoPending
            : HeadroomCopy.telemetryPending
    }

    func reloadTelemetryPreview() async {
        guard telemetryEnabled else {
            telemetryPreview = nil
            return
        }
        telemetryPreviewLoading = true
        telemetryCopyMessage = nil
        telemetryPreview = await TelemetryCoordinator.shared.preview()
        telemetryPreviewLoading = false
    }

    func reloadCommunityStats() async {
        guard telemetryEnabled else {
            communityStats = nil
            return
        }
        communityStatsLoading = true
        communityStatsMessage = nil
        defer { communityStatsLoading = false }
        do {
            var request = URLRequest(url: HeadroomTelemetry.communityAPIURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 8
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            communityStats = try JSONDecoder().decode(
                HeadroomCommunityStats.self,
                from: data
            )
        } catch {
            communityStats = nil
            communityStatsMessage = error.localizedDescription
        }
    }

    func copyTelemetryPayload(_ preview: HeadroomTelemetryBatch) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(preview),
              let string = String(data: data, encoding: .utf8)
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        telemetryCopyMessage = HeadroomCopy.telemetryCopied
    }

    func telemetryDisplayName(_ id: String) -> String {
        id.split { $0 == "-" || $0 == "_" }
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}
