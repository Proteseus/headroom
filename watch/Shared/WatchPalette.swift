import SwiftUI

/// The shared palette, rendered in Display P3 instead of sRGB.
///
/// The numbers are not changed here and must not be — `HeadroomPalette` stays
/// the single source for what colour a provider is. What changes is the space
/// those numbers are read in, and only on the watch.
///
/// The reason is the board. `firmware/src/main.cpp` paints the identical
/// triples, but an ESP32 panel is unmanaged: the raw RGB565 value drives the
/// OLED subpixels against primaries far wider than sRGB, so #D97757 lands
/// noticeably more saturated there than the colour-managed sRGB version does on
/// a screen. Reading the same numbers as P3 coordinates puts the wrist close to
/// what the desk shows, which is the whole point of one palette.
///
/// Deliberately watch-only. On a Mac the same move would overshoot on every
/// external sRGB monitor, and the Mac is not trying to match the board from
/// across the room.
enum WatchPalette {
    static func p3(_ triple: HeadroomPalette.RGB) -> Color {
        Color(
            .displayP3,
            red: triple.r / 255,
            green: triple.g / 255,
            blue: triple.b / 255
        )
    }
}

extension HeadroomWidgetSnapshot.Provider {
    /// `tint`, in the wider space. Every watch surface uses this in place of
    /// `tint`; the widgets and the Mac keep the sRGB one.
    var watchTint: Color {
        WatchPalette.p3(
            HeadroomPalette.providerComponents(id: id, accent: accent)
        )
    }
}
