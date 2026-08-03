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
                    HeadroomCopy.telemetryLatestBuild,
                    value: latest.versions.first?.name ?? "—",
                    detail: latest.versions.first.map {
                        "\($0.count) \(HeadroomCopy.telemetryMacs)"
                    }
                        ?? HeadroomCopy.telemetryCommunityThreshold
                )
                telemetryMetric(
                    HeadroomCopy.telemetryServicesInUse,
                    value: String(latest.services.used.count),
                    detail: HeadroomCopy.telemetryLatestWeek
                )
            }

            communityWeeklyChart(stats.weeklyActiveMacs)

            if latest.versions.isEmpty {
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
                    HeadroomCopy.telemetryServiceMix,
                    items: latest.services.used,
                    total: latest.reportingMacs
                )
                communityModelRows(latest.modelShares)
                communityFeatureChips(latest.features)
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
            HStack(alignment: .bottom, spacing: 7) {
                ForEach(weeks) { week in
                    VStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                week.count == nil
                                    ? AnyShapeStyle(.quaternary)
                                    : AnyShapeStyle(HeadroomPalette.claude)
                            )
                            .frame(
                                maxWidth: .infinity,
                                minHeight: 4,
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
            .frame(height: 108, alignment: .bottom)
        }
    }

    @ViewBuilder
    func communityCountRows(
        _ title: String,
        items: [HeadroomCommunityStats.CountedItem],
        total: Int?
    ) -> some View {
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
                    .tint(HeadroomPalette.providerTint(id: item.name))
                    Text("\(item.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    func communityModelRows(
        _ items: [HeadroomCommunityStats.ModelShare]
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(HeadroomCopy.telemetryModelMix)
                .font(.callout.weight(.medium))
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Text(telemetryDisplayName(item.name.split(separator: ":").last.map(String.init) ?? item.name))
                        .font(.caption)
                        .frame(width: 80, alignment: .leading)
                    ProgressView(value: Double(item.share), total: 100)
                        .tint(HeadroomPalette.claude)
                    Text("\(item.share)%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    func communityFeatureChips(
        _ items: [HeadroomCommunityStats.Feature]
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(HeadroomCopy.telemetryFeatureAdoption)
                .font(.callout.weight(.medium))
            HStack(spacing: 6) {
                ForEach(items) { item in
                    Text("\(telemetryDisplayName(item.name)) \(item.adoption)%")
                        .font(.caption2)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.45), in: Capsule())
                }
            }
        }
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
                            .fill(HeadroomPalette.providerTint(id: id))
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
                        ? AnyShapeStyle(HeadroomPalette.green)
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
                                .tint(HeadroomPalette.providerTint(id: provider))
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
