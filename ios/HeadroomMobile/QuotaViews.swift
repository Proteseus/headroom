import Charts
import SwiftUI

struct QuotaOverviewCard: View {
    let providers: [QuotaProviderInfo]
    let burndown: [String: [String: Burndown]]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(HeadroomCopy.codingQuotas)
                .font(.headline)
            if providers.isEmpty {
                ContentUnavailableView(
                    "No quota data",
                    systemImage: "chart.pie.fill",
                    description: Text(HeadroomCopy.waitingForMacSync)
                )
            } else {
                ForEach(providers) { provider in
                    NavigationLink {
                        ProviderQuotaDetail(
                            provider: provider,
                            burndown: Array(
                                (burndown[provider.id] ?? [:]).values
                            )
                        )
                    } label: {
                        HStack(spacing: 10) {
                            ProviderSummaryRow(provider: provider)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if provider.id != providers.last?.id {
                        Divider()
                    }
                }
            }
        }
        .headroomCard()
    }
}

struct QuotasScreen: View {
    @ObservedObject var store: MobileUsageStore

    var body: some View {
        List {
            ForEach(store.visibleProviders) { provider in
                NavigationLink {
                    ProviderQuotaDetail(
                        provider: provider,
                        burndown: Array(
                            (store.snapshot.burndown?[provider.id] ?? [:]).values
                        )
                    )
                } label: {
                    ProviderSummaryRow(provider: provider)
                        .padding(.vertical, 6)
                }
            }
        }
        .overlay {
            if store.visibleProviders.isEmpty {
                ContentUnavailableView(
                    HeadroomCopy.noCodingSources,
                    systemImage: "chart.pie.fill"
                )
            }
        }
        .navigationTitle(HeadroomCopy.quotas)
        .refreshable { await store.refresh(forceServerSync: true) }
    }
}

private struct ProviderSummaryRow: View {
    let provider: QuotaProviderInfo

    var body: some View {
        HStack(spacing: 16) {
            HeadroomRings(layers: provider.ringLayers, tint: provider.tint)
            .frame(width: 82, height: 82)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(provider.displayTitle)
                        .font(.headline)
                    if let plan = provider.plan {
                        Text(plan)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(provider.visiblePools.prefix(3)), id: \.id) { item in
                    HStack {
                        Text(item.pool.title ?? item.id.capitalized)
                        Spacer()
                        Text(item.pool.pct.map { "\(Int($0.rounded()))%" } ?? "—")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if provider.ok == false, let error = provider.error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else if let headline = provider.headline {
                    Text(headline)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
    }
}

private struct ProviderQuotaDetail: View {
    let provider: QuotaProviderInfo
    let burndown: [Burndown]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        HeadroomRings(
                            layers: provider.ringLayers,
                            tint: provider.tint
                        )
                        .frame(width: 112, height: 112)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(provider.plan ?? "Plan unavailable")
                                .foregroundStyle(.secondary)
                            Text(provider.ok == false ? HeadroomCopy.needsAttention : "Connected")
                                .foregroundStyle(
                                    provider.ok == false ? Color.orange : Color.green
                                )
                        }
                        .font(.subheadline)
                    }

                    ForEach(provider.visiblePools, id: \.id) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(item.pool.title ?? item.id.capitalized)
                                    .fontWeight(.medium)
                                Spacer()
                                Text(item.pool.pct.map { "\(Int($0.rounded()))%" } ?? "—")
                                    .monospacedDigit()
                            }
                            ProgressView(value: min(max(item.pool.pct ?? 0, 0), 100), total: 100)
                                .tint(provider.tint)
                            HStack {
                                if let pace = item.pool.pacePct {
                                    Text("Pace \(Int(pace.rounded()))%")
                                }
                                Spacer()
                                if let reset = item.pool.resetsIn {
                                    Text("Resets \(reset)")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .headroomCard()

                ForEach(burndown.sorted {
                    ($0.windowS ?? 0) > ($1.windowS ?? 0)
                }) { pool in
                    BurndownChart(pool: pool, tint: provider.tint)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(provider.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BurndownPoint: Identifiable {
    let id: String
    let date: Date
    let remaining: Double
    let series: String
}

private struct BurndownChart: View {
    let pool: Burndown
    let tint: Color

    private var points: [BurndownPoint] {
        func rows(_ values: [[Double]]?, series: String) -> [BurndownPoint] {
            (values ?? []).enumerated().compactMap { index, pair in
                guard pair.count >= 2 else { return nil }
                return BurndownPoint(
                    id: "\(series)-\(index)",
                    date: Date(timeIntervalSince1970: pair[0]),
                    remaining: min(max(pair[1], 0), 100),
                    series: series
                )
            }
        }
        return rows(pool.ideal, series: "Budget")
            + rows(pool.actual, series: "Actual")
            + rows(pool.projected, series: "Projected")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(HeadroomCopy.poolBurndown(pool.poolTitle))
                        .font(.headline)
                    Text(pool.headline ?? pool.resetsIn.map { "Resets \($0)" } ?? "")
                        .font(.caption)
                        .foregroundStyle(
                            pool.inDeficit == true ? Color.orange : Color.secondary
                        )
                }
                Spacer()
                if let remaining = pool.remainingPct {
                    Text("\(Int(remaining.rounded()))% left")
                        .font(.subheadline.monospacedDigit())
                }
            }

            if points.isEmpty {
                Text(HeadroomCopy.noHistoryYet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
            } else {
                Chart(points) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Remaining", point.remaining)
                    )
                    .foregroundStyle(by: .value("Series", point.series))
                    .lineStyle(
                        StrokeStyle(
                            lineWidth: point.series == "Actual" ? 3 : 1.5,
                            dash: point.series == "Projected" ? [6, 2] : []
                        )
                    )
                }
                .chartForegroundStyleScale([
                    "Budget": Color.secondary.opacity(0.45),
                    "Actual": tint,
                    "Projected": tint.opacity(0.55),
                ])
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 50, 100]) {
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .frame(height: 190)
            }
        }
        .headroomCard()
    }
}

private struct OverallBurndownPoint: Identifiable {
    let id: String
    let date: Date
    let remaining: Double
}

private struct OverallBurndownSeries: Identifiable {
    let id: String
    let provider: QuotaProviderInfo
    let actual: [OverallBurndownPoint]
    let projected: [OverallBurndownPoint]
}

struct OverallBurndownChart: View {
    let providers: [QuotaProviderInfo]
    let burndown: [String: [String: Burndown]]

    private var series: [OverallBurndownSeries] {
        providers.compactMap { provider in
            let pools = Array((burndown[provider.id] ?? [:]).values)
            let pool: Burndown?
            if provider.id == "cursor" {
                pool = pools.first(where: { $0.pool == "total" })
                    ?? pools.max {
                        ($0.windowS ?? 0) < ($1.windowS ?? 0)
                    }
            } else {
                pool = pools.max {
                    ($0.windowS ?? 0) < ($1.windowS ?? 0)
                }
            }
            guard let pool else { return nil }

            func points(
                _ values: [[Double]]?,
                kind: String
            ) -> [OverallBurndownPoint] {
                (values ?? []).enumerated().compactMap { index, pair in
                    guard pair.count >= 2 else { return nil }
                    return OverallBurndownPoint(
                        id: "\(provider.id)-\(kind)-\(index)",
                        date: Date(timeIntervalSince1970: pair[0]),
                        remaining: min(max(pair[1], 0), 100)
                    )
                }
            }

            let actual = points(pool.actual, kind: "actual")
            guard !actual.isEmpty else { return nil }
            return OverallBurndownSeries(
                id: provider.id,
                provider: provider,
                actual: actual,
                projected: points(pool.projected, kind: "projected")
            )
        }
    }

    private var calendarRange: ClosedRange<Date> {
        let now = series.flatMap(\.actual).map(\.date).max() ?? .now
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(
            byAdding: .day, value: -3, to: today
        ) ?? today
        let end = calendar.date(
            byAdding: .day, value: 7, to: start
        ) ?? start.addingTimeInterval(7 * 24 * 60 * 60)
        return start...end
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(HeadroomCopy.overallBurndown)
                    .font(.headline)
                Spacer()
                Text(HeadroomCopy.overallBurndownSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if series.isEmpty {
                Text(HeadroomCopy.noHistoryYet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
            } else {
                Chart {
                    ForEach(series) { entry in
                        ForEach(entry.actual) { point in
                            LineMark(
                                x: .value("Time", point.date),
                                y: .value("Remaining", point.remaining),
                                series: .value("Series", entry.id)
                            )
                            .foregroundStyle(entry.provider.tint)
                            .lineStyle(StrokeStyle(lineWidth: 3, lineJoin: .round))
                        }
                        ForEach(entry.projected) { point in
                            LineMark(
                                x: .value("Time", point.date),
                                y: .value("Remaining", point.remaining),
                                series: .value("Series", "\(entry.id)-projected")
                            )
                            .foregroundStyle(entry.provider.tint.opacity(0.55))
                            .lineStyle(StrokeStyle(
                                lineWidth: 2,
                                lineJoin: .round,
                                dash: [6, 2]
                            ))
                        }
                    }
                }
                .chartXScale(domain: calendarRange)
                .chartYScale(domain: 0...100)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) {
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                    }
                }
                .chartYAxis {
                    AxisMarks(values: [0, 50, 100]) {
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .frame(height: 190)

                HStack(spacing: 12) {
                    ForEach(series) { entry in
                        Label {
                            Text(entry.provider.displayTitle)
                                .font(.caption2)
                        } icon: {
                            Circle()
                                .fill(entry.provider.tint)
                                .frame(width: 7, height: 7)
                        }
                    }
                }
            }
        }
        .headroomCard()
    }
}

struct DailyBurnChart: View {
    let days: [DailyBurnDay]
    let providers: [QuotaProviderInfo]

    private var visibleDays: [DailyBurnDay] { Array(days.suffix(7)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(HeadroomCopy.dailyBurn)
                    .font(.headline)
                Spacer()
                Text(HeadroomCopy.dailyBurnUnit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if visibleDays.isEmpty || providers.isEmpty {
                Text(HeadroomCopy.noBurnHistoryYet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            } else {
                Chart {
                    ForEach(visibleDays) { day in
                        ForEach(providers) { provider in
                            BarMark(
                                x: .value("Day", day.date),
                                y: .value(
                                    "Burn",
                                    day.burns?[provider.id] ?? legacyBurn(
                                        day: day, provider: provider.id
                                    )
                                )
                            )
                            .foregroundStyle(
                                by: .value("Provider", provider.displayTitle)
                            )
                        }
                    }
                }
                .chartForegroundStyleScale(
                    domain: providers.map(\.displayTitle),
                    range: providers.map(\.tint)
                )
                .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
                .chartXAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let raw = value.as(String.self) {
                                Text(shortDay(raw))
                            }
                        }
                    }
                }
                .frame(height: 170)
            }
        }
        .headroomCard()
    }

    private func legacyBurn(day: DailyBurnDay, provider: String) -> Double {
        switch provider {
        case "claude": day.claude ?? 0
        case "codex": day.codex ?? 0
        case "cursor": day.cursor ?? 0
        default: 0
        }
    }

    private func shortDay(_ value: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value) else { return String(value.suffix(5)) }
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }
}
