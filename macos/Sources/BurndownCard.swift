import SwiftUI

/// The burndown: what an even spend would leave you against what you actually
/// have, plus where the current pace lands.
///
/// Read it as a sprint burndown. The straight line is the budget, falling from
/// full at the window's start to zero at its reset. The drawn curve is reality.
/// Below the line means burning faster than the window can afford; the dashed
/// tail is where that pace ends up if nothing changes.

struct BurndownCard: View {
    let provider: UsageProvider
    let rings: [Burndown]

    /// Longest window first here: the weekly shape is the one worth a chart,
    /// while a 5h session is mostly noise at this size.
    private var charted: [Burndown] {
        rings.sorted {
            ($0.windowS ?? 0) > ($1.windowS ?? 0)
        }
    }

    var body: some View {
        if charted.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("Burndown")
                    .font(.headline)
                ForEach(charted) { pool in
                    BurndownPlot(pool: pool, tint: provider.tint)
                }
            }
            .cardStyle()
        }
    }
}

/// All providers on one chart, against a single budget line.
///
/// Averaging the pools would be meaningless: 50% of a Claude window is not 50%
/// of a Cursor billing cycle, and the windows differ in both length and start
/// time, so they share no time axis. Normalising both axes fixes that. X is the
/// fraction of each pool's own window that has elapsed, Y is percent remaining,
/// so one diagonal is every pool's budget and the curves are directly
/// comparable: whichever sits lowest is the one being overspent.
struct OverviewBurndownCard: View {
    let snapshot: UsageSnapshot

    private struct Series: Identifiable {
        let id: String
        let provider: UsageProvider
        let pool: Burndown
        let points: [CGPoint]   // x in 0…1, y in remaining percent
    }

    /// One pool per provider: the longest window, matching what the board
    /// charts. A 5h session is too short to say anything at this size.
    private var series: [Series] {
        UsageProvider.allCases.compactMap { provider in
            let pools = snapshot.burndownRings(for: provider)
            guard let pool = pools.max(by: {
                ($0.windowS ?? 0) < ($1.windowS ?? 0)
            }),
                let start = pool.windowStart,
                let span = pool.windowS, span > 0
            else { return nil }

            let points = (pool.actual ?? []).compactMap { pair -> CGPoint? in
                guard pair.count >= 2 else { return nil }
                return CGPoint(
                    x: CGFloat(min(max((pair[0] - start) / span, 0), 1)),
                    y: CGFloat(max(0, min(pair[1], 100)))
                )
            }
            guard !points.isEmpty else { return nil }
            return Series(
                id: provider.rawValue, provider: provider,
                pool: pool, points: points
            )
        }
    }

    var body: some View {
        let all = series
        if all.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Burndown")
                        .font(.headline)
                    Spacer()
                    Text("window elapsed")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Canvas { context, size in
                    var budget = Path()
                    budget.move(to: CGPoint(x: 0, y: 0))
                    budget.addLine(to: CGPoint(x: size.width, y: size.height))
                    context.stroke(
                        budget,
                        with: .color(.secondary.opacity(0.45)),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                    )

                    for entry in all {
                        let scaled = entry.points.map {
                            CGPoint(
                                x: $0.x * size.width,
                                y: size.height - ($0.y / 100) * size.height
                            )
                        }
                        guard let first = scaled.first else { continue }
                        let tint = entry.pool.kind == .exhausted
                            ? entry.provider.tint.drained()
                            : entry.provider.tint
                        if scaled.count >= 2 {
                            var line = Path()
                            line.move(to: first)
                            for point in scaled.dropFirst() {
                                line.addLine(to: point)
                            }
                            context.stroke(
                                line,
                                with: .color(tint),
                                style: StrokeStyle(lineWidth: 2, lineJoin: .round)
                            )
                        }
                        if let last = scaled.last {
                            let dot = Path(ellipseIn: CGRect(
                                x: last.x - 3, y: last.y - 3,
                                width: 6, height: 6))
                            context.fill(dot, with: .color(tint))
                        }
                    }
                }
                .frame(height: 92)

                HStack(spacing: 12) {
                    ForEach(all) { entry in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(entry.pool.kind == .exhausted
                                      ? entry.provider.tint.drained()
                                      : entry.provider.tint)
                                .frame(width: 7, height: 7)
                            Text(entry.provider.title)
                                .font(.caption2)
                            if let delta = entry.pool.deltaPct {
                                Text(delta >= 0
                                     ? "+\(Int(delta.rounded()))"
                                     : "\(Int(delta.rounded()))")
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(
                                        delta < 0 ? Color.orange : .secondary)
                            }
                        }
                    }
                    Spacer()
                }
            }
            .cardStyle()
        }
    }
}

struct BurndownPlot: View {
    let pool: Burndown
    let tint: Color

    private var statusTint: Color {
        switch pool.kind {
        case .exhausted: tint.drained()
        case .critical: .red
        case .ahead: .orange
        case .ok: tint
        }
    }

    private var footnote: String {
        var parts: [String] = []
        if let rate = pool.burnRatePct, let unit = pool.rateUnit {
            parts.append("burning \(rate.rateLabel)%/\(unit)")
        }
        if let allowance = pool.allowancePct, let unit = pool.rateUnit {
            parts.append("budget \(allowance.rateLabel)%/\(unit)")
        }
        if let samples = pool.samples, parts.isEmpty {
            parts.append("\(samples) sample\(samples == 1 ? "" : "s") so far")
        }
        if pool.isEstimated {
            parts.append("estimated from recent usage")
        } else if let samples = pool.samples, !parts.isEmpty {
            parts.append("\(samples) samples")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(pool.poolTitle)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let reset = pool.resetsIn {
                    Text(reset)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            BurndownCanvas(pool: pool, tint: statusTint)
                .frame(height: 84)

            if let headline = pool.headline {
                Text(headline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !footnote.isEmpty {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }
}

struct BurndownCanvas: View {
    let pool: Burndown
    let tint: Color

    var body: some View {
        Canvas { context, size in
            guard let start = pool.windowStart,
                  let end = pool.windowEnd,
                  end > start
            else { return }

            let span = end - start
            func x(_ t: Double) -> CGFloat {
                CGFloat((t - start) / span) * size.width
            }
            // Remaining percent, so 100 is the top and exhaustion is the floor.
            func y(_ pct: Double) -> CGFloat {
                size.height - CGFloat(max(0, min(pct, 100)) / 100) * size.height
            }

            let actual = (pool.actual ?? []).compactMap { pair -> CGPoint? in
                guard pair.count >= 2 else { return nil }
                return CGPoint(x: x(pair[0]), y: y(pair[1]))
            }

            // --- budget line: full at the window's start, zero at its reset
            var ideal = Path()
            ideal.move(to: CGPoint(x: x(start), y: y(100)))
            ideal.addLine(to: CGPoint(x: x(end), y: y(0)))
            context.stroke(
                ideal,
                with: .color(.secondary.opacity(0.45)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )

            // --- drift: the gap between the budget and reality
            if actual.count >= 2, let first = actual.first, let last = actual.last {
                var drift = Path()
                drift.move(to: first)
                for point in actual.dropFirst() { drift.addLine(to: point) }
                drift.addLine(to: CGPoint(x: last.x, y: y(idealAt(last.x, size: size))))
                drift.addLine(to: CGPoint(x: first.x, y: y(idealAt(first.x, size: size))))
                drift.closeSubpath()
                context.fill(drift, with: .color(tint.opacity(0.16)))
            }

            // --- what actually happened
            if actual.count >= 2 {
                var line = Path()
                line.move(to: actual[0])
                for point in actual.dropFirst() { line.addLine(to: point) }
                context.stroke(
                    line,
                    with: .color(tint),
                    style: StrokeStyle(lineWidth: 2, lineJoin: .round)
                )
            }

            // --- where this pace lands
            let projected = (pool.projected ?? []).compactMap { pair -> CGPoint? in
                guard pair.count >= 2 else { return nil }
                return CGPoint(x: x(pair[0]), y: y(pair[1]))
            }
            if projected.count >= 2 {
                var forecast = Path()
                forecast.move(to: projected[0])
                for point in projected.dropFirst() { forecast.addLine(to: point) }
                // An estimate off token history should look provisional next
                // to a projection fitted from real samples: finer dots, less
                // weight. Same claim, visibly less certainty.
                context.stroke(
                    forecast,
                    with: .color(tint.opacity(pool.isEstimated ? 0.45 : 0.7)),
                    style: StrokeStyle(
                        lineWidth: pool.isEstimated ? 1 : 1.5,
                        dash: pool.isEstimated ? [1.5, 3] : [4, 3]
                    )
                )
                // Mark the wall if the pace hits it before the reset.
                if pool.exhaustsBeforeReset == true, let hit = projected.last {
                    let dot = Path(ellipseIn: CGRect(
                        x: hit.x - 3, y: hit.y - 3, width: 6, height: 6))
                    context.fill(dot, with: .color(.red))
                }
            }

            // --- now
            if let last = actual.last {
                var marker = Path()
                marker.move(to: CGPoint(x: last.x, y: 0))
                marker.addLine(to: CGPoint(x: last.x, y: size.height))
                context.stroke(
                    marker,
                    with: .color(.secondary.opacity(0.25)),
                    lineWidth: 1
                )
                let dot = Path(ellipseIn: CGRect(
                    x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5))
                context.fill(dot, with: .color(tint))
            }
        }
        .accessibilityLabel(pool.headline ?? "Burndown")
    }

    /// Budget line height at a given x, in remaining percent.
    private func idealAt(_ px: CGFloat, size: CGSize) -> Double {
        guard size.width > 0 else { return 100 }
        return 100 * (1 - Double(px / size.width))
    }
}

extension Double {
    /// Rates span three orders of magnitude across pools; mirror of
    /// burndown._fmt_rate so both surfaces round the same way.
    var rateLabel: String {
        if self >= 10 { return String(format: "%.0f", self) }
        if self >= 1 { return String(format: "%.1f", self) }
        let raw = String(format: "%.2f", self)
        return raw.hasSuffix("0") ? String(raw.dropLast()) : raw
    }
}
