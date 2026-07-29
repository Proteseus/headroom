import SwiftUI

// How the cached widget snapshot becomes something to draw. Compiled by the
// widget extensions and the watch complication — the three surfaces that read
// the cache rather than the model layer — so a provider's tint, its ring
// layers, and which of them is the one worth naming are decided once.

extension HeadroomWidgetSnapshot.Provider {
    var ringLayers: [HeadroomRingLayer] {
        if let layers, !layers.isEmpty {
            return layers.map {
                HeadroomRingLayer(
                    id: $0.id,
                    percent: $0.percent,
                    pacePercent: $0.pacePercent
                )
            }
        }
        return [HeadroomRingLayer(id: title, percent: percent, pacePercent: nil)]
    }

    var tint: Color {
        HeadroomPalette.providerTint(id: id, accent: accent)
    }

    /// A spent pool recedes rather than warns — the same reading the Mac gives
    /// it, minus the AppKit colour surgery `Color.drained()` needs.
    var burndownTint: Color {
        burndown?.exhausted == true ? tint.opacity(0.45) : tint
    }

    /// Where this provider's forecast reaches empty, if it does so inside the
    /// charted week. The series is already cropped at empty before it is
    /// written, so a last point at zero *is* the crossing.
    var emptiesAt: Double? {
        guard let last = burndown?.projected.last, last.count >= 2,
              last[1] <= 0
        else { return nil }
        return last[0]
    }
}

extension HeadroomWidgetSnapshot {
    /// The provider the wrist should name when it can only name one.
    ///
    /// Whichever forecast runs dry first, because that is the one that changes
    /// what you do next. With nothing running dry it falls back to the most
    /// spent, which is the same provider the meters lead with everywhere else.
    var bindingProvider: Provider? {
        let emptying = providers
            .compactMap { provider in provider.emptiesAt.map { ($0, provider) } }
            .min { $0.0 < $1.0 }
        return emptying?.1 ?? providers.max { $0.percent < $1.percent }
    }

    /// Providers with enough history to draw a line.
    var charted: [Provider] {
        providers.filter { $0.burndown != nil }
    }
}
