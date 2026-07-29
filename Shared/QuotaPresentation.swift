import SwiftUI

/// How a provider from the host document reads on a ring, wherever it is drawn
/// — the phone's quota cards, and the widget cache both apps write.
extension QuotaProviderInfo {
    var ringLayers: [HeadroomRingLayer] {
        visiblePools.prefix(HeadroomRingStyle.maximumLayerCount).map {
            HeadroomRingLayer(
                id: $0.pool.title ?? $0.id.capitalized,
                percent: $0.pool.pct,
                pacePercent: $0.pool.pacePct
            )
        }
    }

    var tint: Color {
        HeadroomPalette.providerTint(id: id, accent: accent)
    }
}
