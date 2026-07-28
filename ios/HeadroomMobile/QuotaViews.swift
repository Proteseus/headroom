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
                            burndown: provider.orderedBurndown(
                                from: burndown[provider.id]
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
            ArchivedDataNotice(store: store)
            ForEach(store.visibleProviders) { provider in
                NavigationLink {
                    ProviderQuotaDetail(
                        provider: provider,
                        burndown: provider.orderedBurndown(
                            from: store.snapshot.burndown?[provider.id]
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
    /// Already in `visiblePools` order — one chart per progress bar, same
    /// sequence. Do not re-sort here.
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

                ForEach(burndown) { pool in
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
            + rows(pool.croppedProjected, series: "Projected")
    }

    /// Full pool window — same axis Mac's Canvas uses, not the sample span.
    private var timeRange: ClosedRange<Date>? {
        guard let start = pool.windowStart, let end = pool.windowEnd,
              end > start else { return nil }
        return Date(timeIntervalSince1970: start)
            ... Date(timeIntervalSince1970: end)
    }

    /// Local midnights covered by the window (≥2 days), matching Mac.
    private var dayMarks: [Date] {
        guard let range = timeRange else { return [] }
        let start = range.lowerBound.timeIntervalSince1970
        let end = range.upperBound.timeIntervalSince1970
        guard end - start >= 2 * 24 * 60 * 60 else { return [] }
        let calendar = Calendar.current
        var days: [Date] = []
        var midnight = calendar.startOfDay(for: range.lowerBound)
        while midnight.timeIntervalSince1970 < end {
            days.append(midnight)
            guard let next = calendar.date(byAdding: .day, value: 1, to: midnight)
            else { break }
            midnight = next
        }
        return days
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
                let nowDate = points
                    .filter { $0.series == "Actual" }
                    .map(\.date)
                    .max() ?? .now
                let days = dayMarks
                // One mark per day when columns stay readable; otherwise weekly
                // (Mac drawBurndownCalendar — month windows otherwise moiré).
                let daily = days.count > 0 && days.count <= 14
                let axisDates = days.enumerated()
                    .filter { $0.offset % (daily ? 1 : 7) == 0 }
                    .map(\.element)

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
                .chartXScale(domain: timeRange ?? nowDate...nowDate)
                .chartYScale(domain: 0...100)
                .chartPlotStyle { $0.clipped() }
                .chartXAxis {
                    if axisDates.isEmpty {
                        AxisMarks(values: .automatic) { _ in
                            AxisGridLine()
                        }
                    } else {
                        AxisMarks(values: axisDates) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    if daily {
                                        Text(
                                            date,
                                            format: .dateTime.weekday(.abbreviated)
                                        )
                                        .foregroundStyle(
                                            date <= nowDate
                                                ? Color.secondary
                                                : Color.secondary.opacity(0.55)
                                        )
                                    } else {
                                        Text(
                                            date,
                                            format: .dateTime.month(.abbreviated).day()
                                        )
                                        .foregroundStyle(
                                            date <= nowDate
                                                ? Color.secondary
                                                : Color.secondary.opacity(0.55)
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
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
    let pool: Burndown
    let actual: [OverallBurndownPoint]
    let projected: [OverallBurndownPoint]
    let renewsAt: Date?
    let resetsIn: String?
}

struct OverallBurndownChart: View {
    let providers: [QuotaProviderInfo]
    let burndown: [String: [String: Burndown]]

    /// Raw series before domain clip — carries windowEnd for domain math.
    private var series: [OverallBurndownSeries] {
        providers.compactMap { provider in
            // Same pool set the provider's bars and charts draw, so the
            // overview line can never come from a pool the host hid.
            let pools = provider.orderedBurndown(from: burndown[provider.id])
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
                pool: pool,
                actual: actual,
                projected: points(pool.projected, kind: "projected"),
                renewsAt: pool.windowEnd.map {
                    Date(timeIntervalSince1970: $0)
                },
                resetsIn: pool.resetsIn
            )
        }
    }

    private var now: Date {
        series.flatMap(\.actual).map(\.date).max() ?? .now
    }

    private var domain: OverallBurndownChartMath.Domain {
        OverallBurndownChartMath.domain(now: now)
    }

    private func chartPoints(
        _ pairs: [[Double]],
        idPrefix: String
    ) -> [OverallBurndownPoint] {
        pairs.enumerated().compactMap { index, pair in
            guard pair.count >= 2 else { return nil }
            return OverallBurndownPoint(
                id: "\(idPrefix)-\(index)",
                date: Date(timeIntervalSince1970: pair[0]),
                remaining: min(max(pair[1], 0), 100)
            )
        }
    }

    /// Crop at reset/empty, then clip to the fixed 7-day domain.
    private func drawnSeries(
        in domain: OverallBurndownChartMath.Domain
    ) -> [OverallBurndownSeries] {
        series.map { entry in
            OverallBurndownSeries(
                id: entry.id,
                provider: entry.provider,
                pool: entry.pool,
                actual: chartPoints(
                    OverallBurndownChartMath.preparedActual(
                        entry.pool.actual, domain: domain
                    ),
                    idPrefix: "\(entry.id)-a"
                ),
                projected: chartPoints(
                    OverallBurndownChartMath.preparedProjection(
                        entry.pool.projected,
                        windowEnd: entry.pool.windowEnd,
                        domain: domain
                    ),
                    idPrefix: "\(entry.id)-p"
                ),
                renewsAt: entry.renewsAt,
                resetsIn: entry.resetsIn
            )
        }
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
                let domain = self.domain
                let nowDate = domain.now
                let range = domain.start...domain.end
                let drawn = drawnSeries(in: domain)
                Chart {
                    RuleMark(x: .value("Now", nowDate))
                        .foregroundStyle(Color.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1))

                    ForEach(drawn) { entry in
                        ForEach(entry.actual) { point in
                            LineMark(
                                x: .value("Time", point.date),
                                y: .value("Remaining", point.remaining),
                                series: .value("Series", entry.id)
                            )
                            .foregroundStyle(entry.provider.tint)
                            .lineStyle(StrokeStyle(
                                lineWidth: 3, lineJoin: .round
                            ))
                        }
                        if let last = entry.actual.last {
                            PointMark(
                                x: .value("Time", last.date),
                                y: .value("Remaining", last.remaining)
                            )
                            .foregroundStyle(entry.provider.tint)
                            .symbolSize(36)
                        }
                        ForEach(entry.projected) { point in
                            LineMark(
                                x: .value("Time", point.date),
                                y: .value("Remaining", point.remaining),
                                series: .value(
                                    "Series", "\(entry.id)-projected"
                                )
                            )
                            .foregroundStyle(entry.provider.tint.opacity(0.55))
                            .lineStyle(StrokeStyle(
                                lineWidth: 2,
                                lineJoin: .round,
                                dash: [6, 2]
                            ))
                        }
                        if let last = entry.projected.last {
                            PointMark(
                                x: .value("Time", last.date),
                                y: .value("Remaining", last.remaining)
                            )
                            .foregroundStyle(entry.provider.tint.opacity(0.7))
                            .symbolSize(last.remaining <= 0 ? 36 : 22)
                        }

                        // Reset rules last so they sit on top of the strokes.
                        if let renew = entry.renewsAt,
                           renew > nowDate,
                           renew >= range.lowerBound,
                           renew <= range.upperBound {
                            RuleMark(x: .value("Reset", renew))
                                .foregroundStyle(entry.provider.tint)
                                .lineStyle(StrokeStyle(
                                    lineWidth: 1.5,
                                    dash: [1.5, 2.5]
                                ))
                        }
                    }
                }
                .chartXScale(domain: range)
                .chartYScale(domain: 0...100)
                .chartPlotStyle { $0.clipped() }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                let calendar = Calendar.current
                                let isToday = calendar.isDate(
                                    date, inSameDayAs: nowDate
                                )
                                Text(
                                    date,
                                    format: .dateTime.weekday(.abbreviated)
                                )
                                .fontWeight(isToday ? .semibold : .regular)
                                .foregroundStyle(
                                    date <= nowDate
                                        ? Color.secondary
                                        : Color.secondary.opacity(0.55)
                                )
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(values: [0, 50, 100]) {
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .frame(height: 190)

                HStack(alignment: .top, spacing: 12) {
                    ForEach(drawn) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Label {
                                Text(entry.provider.displayTitle)
                                    .font(.caption2.weight(.medium))
                            } icon: {
                                Circle()
                                    .fill(entry.provider.tint)
                                    .frame(width: 7, height: 7)
                            }
                            if let resets = entry.resetsIn {
                                Text(HeadroomCopy.resets(resets))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
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
