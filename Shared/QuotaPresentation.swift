import SwiftUI

/// How a provider from the host document reads on a ring, wherever it is drawn
/// — the Mac's overview, the phone's quota cards, and the widget cache both
/// apps write.
extension QuotaProviderInfo {
    /// Bands for the pools this provider actually reports, fastest window
    /// outermost.
    ///
    /// A pool with no percentage gets no band. The host ships every pool its
    /// registry declares for a provider, value or not — Codex on a plan with
    /// only a weekly window still carries an empty `session` — and a band
    /// drawn at nothing is indistinguishable from one at 0% used.
    ///
    /// - Parameter burndown: the provider's burndown pools, when the surface
    ///   has them. Their ideal line is the better pace, because it accounts
    ///   for resets the provider granted mid-window; the pool's own
    ///   window-elapsed pace stands in until the host has sampled.
    func ringLayers(burndown: [Burndown] = []) -> [HeadroomRingLayer] {
        let paceByPool = Dictionary(
            burndown.compactMap { pool -> (String, Double)? in
                guard let id = pool.pool, let pace = pool.pacePercent else {
                    return nil
                }
                return (id, pace)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let layers = visiblePools.compactMap { entry -> HeadroomRingLayer? in
            guard let percent = entry.pool.pct else { return nil }
            return HeadroomRingLayer(
                id: entry.pool.title ?? entry.id.capitalized,
                percent: percent,
                pacePercent: paceByPool[entry.id] ?? entry.pool.pacePct
            )
        }
        return Array(layers.prefix(HeadroomRingStyle.maximumLayerCount))
    }

    var tint: Color {
        HeadroomPalette.providerTint(id: id, accent: accent)
    }
}
