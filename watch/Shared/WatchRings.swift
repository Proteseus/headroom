import SwiftUI

/// The combined dial: one band per source, outside-in, pinned order.
///
/// The phone and Mac spend a provider's two bands on its two quota windows —
/// fast outside, slow inside (`docs/rings.md`). A watch face has room for one
/// glyph, not three, so this is the other axis of the same idea: Claude, Codex,
/// Cursor as concentric bands, each filled to the pool that binds it. Position
/// identifies the source — first provider outermost — the way left-to-right
/// order does on Activity and on the board.
///
/// A complication renders `.accented` by default: the system throws the view's
/// own colours away and repaints it in whatever tint the watch face wears.
/// `.widgetAccentable(false)` opts out of that, so the brand hues reach the
/// face intact and a source is identified by colour as well as by position —
/// the same reading the app, the widgets and the Mac give it.
///
/// That is also why this draws in one pass. The two-pass split it used to need
/// existed only to keep the pace dot out of the tint group; with real colour
/// the dot contrasts against its band on its own.
struct WatchRingsGlyph: View {
    let providers: [HeadroomWidgetSnapshot.Provider]

    private var layers: [HeadroomRingLayer] {
        guard !providers.isEmpty else {
            return [HeadroomRingLayer.empty]
        }
        // Snapshot order is the pinned Sources order. First layer is outermost
        // in `HeadroomRings`, so provider 1 reads as the outer band.
        return providers.map { provider in
            HeadroomRingLayer(
                id: provider.id,
                // The band is the whole of what this dial says about a
                // provider — there is no label beside it — so it speaks the
                // full title rather than the "Work" the face has room to draw.
                name: provider.spokenTitle,
                percent: provider.percent,
                // The binding pool's pace, which is the pool the band is
                // filled to. Falls back to the provider's own layers when the
                // wire carried them.
                pacePercent: provider.pace,
                tint: provider.watchTint
            )
        }
    }

    var body: some View {
        HeadroomRings(
            layers: layers,
            tint: .primary,
            indicatorColor: .primary,
            profile: .watch
        )
        .widgetAccentable(false)
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
