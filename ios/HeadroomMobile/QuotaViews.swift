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
                            ProviderSummaryRow(
                                provider: provider,
                                burndown: provider.orderedBurndown(
                                    from: burndown[provider.id]
                                )
                            )
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
                    ProviderSummaryRow(
                        provider: provider,
                        burndown: provider.orderedBurndown(
                            from: store.snapshot.burndown?[provider.id]
                        )
                    )
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
    /// The provider's burndown pools, for the pace dots. Empty is fine.
    var burndown: [Burndown] = []

    var body: some View {
        HStack(spacing: 16) {
            HeadroomRings(
                layers: provider.ringLayers(burndown: burndown),
                tint: provider.tint
            )
            .frame(width: 82, height: 82)
            .opacity(provider.isStale ? 0.4 : 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    ProviderMark(providerID: provider.id, size: 16)
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
                // Ahead of the headline, because a headline written from
                // frozen percentages is confidently wrong.
                if let stale = provider.staleNote {
                    Text(stale)
                        .font(.caption2)
                        .foregroundStyle(HeadroomPalette.amber)
                        .lineLimit(1)
                } else if provider.ok == false, let error = provider.error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(HeadroomPalette.amber)
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

    /// "Connected" is a claim about right now, and a provider whose numbers
    /// stopped arriving is in no position to make it. `ok` alone would let it.
    private var statusLabel: String {
        if let stale = provider.staleNote { return stale }
        return provider.ok == false ? HeadroomCopy.needsAttention : "Connected"
    }

    private var statusTint: Color {
        provider.ok == false || provider.isStale
            ? HeadroomPalette.amber
            : HeadroomPalette.green
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        HeadroomRings(
                            layers: provider.ringLayers(burndown: burndown),
                            tint: provider.tint
                        )
                        .frame(width: 112, height: 112)
                        .opacity(provider.isStale ? 0.4 : 1)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(provider.plan ?? "Plan unavailable")
                                .foregroundStyle(.secondary)
                            Text(statusLabel)
                                .foregroundStyle(statusTint)
                                .multilineTextAlignment(.trailing)
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

    private var axisDomain: BurndownChartAxis.Domain? {
        guard let start = pool.windowStart, let end = pool.windowEnd else {
            return nil
        }
        let now = (pool.actual ?? []).compactMap { pair -> Double? in
            pair.count >= 2 ? pair[0] : nil
        }.max() ?? Date().timeIntervalSince1970
        return BurndownChartAxis.domain(
            windowStart: start, windowEnd: end, now: now,
            // Reaches back toward the forgiven burn by a stub of the window
            // — see `historyFraction`.
            historyStart: pool.forgiven?.first?.first
        )
    }

    private var points: [BurndownPoint] {
        guard let domain = axisDomain else {
            return rawPoints(ideal: pool.ideal, actual: pool.actual,
                             projected: pool.croppedProjected,
                             forgiven: pool.forgiven)
        }
        // Clip series to the (possibly 7-day-capped) plot domain so monthly
        // pools don't smear past the weekday columns.
        let ideal = OverallBurndownChartMath.clipPolyline(
            pool.ideal ?? [],
            start: domain.startEpoch, end: domain.endEpoch
        )
        let actual = OverallBurndownChartMath.clipPolyline(
            pool.actual ?? [],
            start: domain.startEpoch, end: domain.endEpoch
        )
        let projected = OverallBurndownChartMath.clipPolyline(
            pool.croppedProjected,
            start: domain.startEpoch, end: domain.endEpoch
        )
        // The burn a grant wiped out, in the stub before the window. Never
        // fitted and never measured against the budget — it is spent.
        let forgiven = OverallBurndownChartMath.clipPolyline(
            pool.forgiven ?? [],
            start: domain.startEpoch, end: domain.endEpoch
        )
        return rawPoints(ideal: ideal, actual: actual, projected: projected,
                         forgiven: forgiven)
    }

    private func rawPoints(
        ideal: [[Double]]?,
        actual: [[Double]]?,
        projected: [[Double]]?,
        forgiven: [[Double]]? = nil
    ) -> [BurndownPoint] {
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
        return rows(ideal, series: "Budget")
            + rows(actual, series: "Actual")
            + rows(projected, series: "Projected")
            + rows(forgiven, series: "Forgiven")
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
                            pool.inDeficit == true
                                ? AnyShapeStyle(HeadroomPalette.amber)
                                : AnyShapeStyle(.secondary)
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
            } else if let domain = axisDomain {
                let nowDate = points
                    .filter { $0.series == "Actual" }
                    .map(\.date)
                    .max() ?? domain.end
                // Names sit at band centres, rules at the midnights between
                // them — a part-day column still gets its weekday.
                let dayColumns = BurndownChartAxis.dayColumns(
                    start: domain.start, end: domain.end
                )
                let dayLabels = dayColumns.map(\.mid)
                let dayRules = BurndownChartAxis.dayGridLines(
                    start: domain.start, end: domain.end
                )
                let hourDates = BurndownChartAxis.hourMarks(
                    start: domain.start, end: domain.end
                )

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
                    "Forgiven": tint.opacity(0.3),
                ])
                .chartXScale(domain: domain.start...domain.end)
                .chartYScale(domain: 0...100)
                .chartPlotStyle { $0.clipped() }
                .chartXAxis {
                    if domain.showsDayAxis {
                        AxisMarks(values: dayRules) { _ in
                            AxisGridLine()
                        }
                        AxisMarks(values: dayLabels) { value in
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(
                                        date,
                                        format: .dateTime.weekday(.abbreviated)
                                    )
                                    .foregroundStyle(
                                        date <= nowDate
                                            ? Color.secondary
                                            : Color.secondary.opacity(0.55)
                                    )
                                }
                            }
                        }
                    } else {
                        AxisMarks(values: hourDates) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(date, format: .dateTime.hour().minute())
                                        .foregroundStyle(Color.secondary)
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
    let forgiven: [OverallBurndownPoint]
    let renewsAt: Date?
    let resetsIn: String?

    /// Newest grant the chart is actually showing, for the caption that names
    /// the rule.
    func latestReset(
        in domain: OverallBurndownChartMath.Domain
    ) -> BurndownReset? {
        let visible = Set(OverallBurndownChartMath.preparedResets(
            pool.resets?.compactMap(\.t), domain: domain))
        return (pool.resets ?? [])
            .filter { $0.t.map(visible.contains) ?? false }
            .max { ($0.t ?? 0) < ($1.t ?? 0) }
    }
}

struct OverallBurndownChart: View {
    let providers: [QuotaProviderInfo]
    let snapshot: UsageSnapshot

    /// Raw series before domain clip — carries windowEnd for domain math.
    private var series: [OverallBurndownSeries] {
        providers.compactMap { provider in
            // Same pool the Mac card and the widget draw, from the same pool
            // set the provider's own bars use.
            let pool = snapshot.overviewBurndown(forProviderID: provider.id)
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
                forgiven: points(pool.forgiven, kind: "forgiven"),
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
                forgiven: chartPoints(
                    OverallBurndownChartMath.preparedActual(
                        entry.pool.forgiven, domain: domain
                    ),
                    idPrefix: "\(entry.id)-f"
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
                        // The run a grant wiped out, behind everything else.
                        // Faint and thin: history that stopped counting must
                        // never be mistaken for the live curve.
                        ForEach(entry.forgiven) { point in
                            LineMark(
                                x: .value("Time", point.date),
                                y: .value("Remaining", point.remaining),
                                series: .value(
                                    "Series", "\(entry.id)-forgiven"
                                )
                            )
                            .foregroundStyle(entry.provider.tint.opacity(0.3))
                            .lineStyle(StrokeStyle(
                                lineWidth: 2, lineJoin: .round
                            ))
                        }
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

                        // Resets already granted: solid, because this one
                        // happened. Without the mark the curve just restarts
                        // and a forgiven week reads as missing data.
                        ForEach(
                            OverallBurndownChartMath.preparedResets(
                                entry.pool.resets?.compactMap(\.t),
                                domain: domain
                            ),
                            id: \.self
                        ) { granted in
                            RuleMark(x: .value(
                                "Reset granted",
                                Date(timeIntervalSince1970: granted)
                            ))
                            .foregroundStyle(entry.provider.tint.opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 1))
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
                            // Names the solid rule. Newest only — the legend
                            // has one line to spare, not a history list.
                            if let granted = entry.latestReset(in: domain) {
                                let caption = HeadroomCopy.resetGranted(
                                    forgivenPct: granted.forgivenPct)
                                // A link only where the provider announces its
                                // grants somewhere. Opening it is the whole
                                // integration — nothing reads that page.
                                if let note = entry.provider.resetNoteURL
                                    .flatMap(URL.init(string:)) {
                                    Link(caption, destination: note)
                                        .font(.caption2)
                                        .monospacedDigit()
                                } else {
                                    Text(caption)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .monospacedDigit()
                                }
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
                                    day.burn(forProviderID: provider.id)
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
                                Text(HeadroomFormat.shortWeekday(isoDate: raw))
                            }
                        }
                    }
                }
                .frame(height: 170)
            }
        }
        .headroomCard()
    }

}
