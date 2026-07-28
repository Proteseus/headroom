import SwiftUI

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
