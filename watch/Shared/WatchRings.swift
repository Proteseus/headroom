import SwiftUI

/// The combined dial: one band per source, outside-in, most spent first.
///
/// The phone and Mac spend a provider's two bands on its two quota windows —
/// fast outside, slow inside (`docs/rings.md`). A watch face has room for one
/// glyph, not three, so this is the other axis of the same idea: Claude, Codex,
/// Cursor as concentric bands, each filled to the pool that binds it. Position
/// identifies the source, exactly as it does on Activity.
///
/// It draws in two passes on purpose. A complication renders `.accented`,
/// where the system flattens the view to a single tint unless part of it is
/// moved into a second group — so the bands take the accent and the pace dots
/// keep the contrasting colour. Collapsed into one pass, the dot would land on
/// an arc of its own colour and the gap between them, which is the whole
/// reading, would disappear.
struct WatchRingsGlyph: View {
    let providers: [HeadroomWidgetSnapshot.Provider]
    /// Off inside a complication, where a second tone is all the system gives
    /// us and the bands have first claim on it. On in the app, which renders
    /// full colour and can afford the brand hues.
    var tinted = false

    private var layers: [HeadroomRingLayer] {
        let ordered = providers.sorted { $0.percent > $1.percent }
        guard !ordered.isEmpty else {
            return [HeadroomRingLayer(id: "unavailable", percent: nil, pacePercent: nil)]
        }
        return ordered.map { provider in
            HeadroomRingLayer(
                id: provider.title,
                percent: provider.percent,
                // The binding pool's pace, which is the pool the band is
                // filled to. Falls back to the provider's own layers when the
                // wire carried them.
                pacePercent: provider.pace,
                tint: tinted ? provider.tint : nil
            )
        }
    }

    var body: some View {
        ZStack {
            HeadroomRings(
                layers: layers,
                tint: tinted ? .primary : .white,
                profile: .watch,
                pass: .bands
            )
            .widgetAccentable()

            HeadroomRings(
                layers: layers,
                tint: .clear,
                indicatorColor: .primary,
                profile: .watch,
                pass: .pace
            )
        }
    }
}

extension HeadroomWidgetSnapshot.Provider {
    /// Pace for the pool the combined band is filled to.
    ///
    /// `percent` is the worst of the provider's pools, so the matching pace is
    /// that same pool's — not the outermost layer's, which may be a different
    /// window entirely.
    var pace: Double? {
        layers?.first { $0.percent == percent }?.pacePercent
            ?? layers?.first?.pacePercent
    }
}
