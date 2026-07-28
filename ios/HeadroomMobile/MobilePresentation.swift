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
        Color(headroomHex: accent) ?? .cyan
    }
}

extension Color {
    init?(headroomHex: String?) {
        guard var value = headroomHex?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        value.removeAll(where: { $0 == "#" })
        guard value.count == 6, let rgb = Int(value, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255
        )
    }
}

func compactNumber(_ value: Int) -> String {
    if value >= 1_000_000 {
        return String(format: "%.1fM", Double(value) / 1_000_000)
    }
    if value >= 1_000 {
        return String(format: "%.1fk", Double(value) / 1_000)
    }
    return "\(value)"
}
