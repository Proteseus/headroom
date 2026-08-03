import SwiftUI

/// The firmware `COL_*` palette, shared by macOS, iOS, and the widget.
///
/// These RGB triples are the same ones `firmware/src/main.cpp` paints with and
/// the same ones the host advertises as `accent` hexes in the source registry.
/// Every surface reads them from here so a status green on the phone is the
/// status green on the device. Platform-specific bridging (AppKit `NSColor`
/// for the menu bar) extends this enum next to the code that needs it.
enum HeadroomPalette {
    /// A 0-255 triple, before any colour space is chosen for it.
    typealias RGB = (r: CGFloat, g: CGFloat, b: CGFloat)

    /// The provider triples, kept as numbers rather than only as `Color`.
    ///
    /// The watch renders these same numbers in Display P3 to sit closer to the
    /// board, whose panel is unmanaged and therefore paints them against much
    /// wider primaries (`watch/Shared/WatchPalette.swift`). Two spellings of
    /// one colour is exactly the drift this file exists to prevent, so the
    /// triple is the source and both spellings are derived from it.
    static let claudeRGB: RGB = (217, 119, 87)   // COL_CLAUDE #D97757
    static let openaiRGB: RGB = (16, 163, 127)   // COL_OPENAI #10A37F
    static let cursorRGB: RGB = (120, 155, 200)  // COL_CURSOR #789BC8
    static let dimRGB: RGB = (120, 116, 110)     // COL_DIM

    static let claude = rgb(claudeRGB)
    static let openai = rgb(openaiRGB)
    static let cursor = rgb(cursorRGB)
    static let dim = rgb(dimRGB)
    static let vercel = rgb(240, 238, 234)  // COL_VERCEL
    static let git = rgb(155, 85, 200)      // COL_GIT
    static let local = rgb(70, 175, 165)    // COL_LOCAL
    static let green = rgb(95, 155, 115)    // COL_GREEN
    /// In flight / soft caution — building, syncing, stale archive. Not alarm.
    static let amber = rgb(195, 155, 85)    // COL_AMBER
    /// Actionable warn — Attention `warn`, needs-sign-in, review/mention rows.
    /// Yellower and hotter than Claude's coral so the two don't collapse at
    /// menu-bar pip size; same stop as the Settings accent named Orange.
    static let orange = rgb(217, 138, 60)   // COL_ORANGE
    static let red = rgb(175, 105, 100)     // COL_RED

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255)
    }

    static func rgb(_ triple: RGB) -> Color {
        rgb(triple.r, triple.g, triple.b)
    }

    /// Split a host `#RRGGBB` / `RRGGBB` accent into 0-255 components.
    /// Nil on anything that isn't six hex digits, so a garbage accent falls
    /// back to the palette instead of painting black.
    static func components(hex: String?) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        guard var raw = hex?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        raw.removeAll(where: { $0 == "#" })
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else { return nil }
        return (
            CGFloat((value >> 16) & 0xFF),
            CGFloat((value >> 8) & 0xFF),
            CGFloat(value & 0xFF)
        )
    }

    /// Parse host `#RRGGBB` / `RRGGBB` accents. Nil on garbage.
    static func color(hex: String?) -> Color? {
        guard let parts = components(hex: hex) else { return nil }
        return rgb(parts.r, parts.g, parts.b)
    }

    /// Attention level from the host (`critical` / `warn` / anything else).
    static func attention(_ level: String?) -> Color {
        switch level {
        case "critical": red
        case "warn": orange
        default: green
        }
    }

    /// Link/attention dot for the surfaces that also have to say "stale".
    /// Saved-but-not-live outranks the level: a green dot over an hour-old
    /// payload reads as "all good right now", which is the one thing it
    /// cannot promise. Stale stays soft amber — not current, not a shout.
    static func status(level: String?, isStale: Bool) -> Color {
        isStale ? amber : attention(level)
    }

    /// Built-in tint for the providers that shipped before the host sent
    /// accents. Keyed by registry id rather than the legacy `UsageProvider`
    /// enum so the widget, which does not compile the full model layer, can
    /// still resolve one.
    static func builtinTint(id: String) -> Color? {
        builtinComponents(id: id).map(rgb)
    }

    static func builtinComponents(id: String) -> RGB? {
        switch id {
        case "claude": claudeRGB
        case "codex": openaiRGB
        case "cursor": cursorRGB
        default: nil
        }
    }

    /// Provider brand color: the host registry accent when it sent one,
    /// otherwise the built-in firmware triple, otherwise dim.
    static func providerTint(id: String, accent: String? = nil) -> Color {
        rgb(providerComponents(id: id, accent: accent))
    }

    /// The same resolution as `providerTint`, stopping at the numbers.
    ///
    /// For surfaces that have to render the triple in a colour space of their
    /// own choosing instead of taking the sRGB `Color` — which today means the
    /// watch, and nothing else.
    static func providerComponents(id: String, accent: String? = nil) -> RGB {
        components(hex: accent) ?? builtinComponents(id: id) ?? dimRGB
    }

    /// One swatch in the Settings color grid.
    struct AccentChoice: Identifiable, Hashable, Sendable {
        let name: String
        let hex: String

        var id: String { hex }
        var color: Color { HeadroomPalette.color(hex: hex) ?? dim }
    }

    /// The colors Settings offers for a source, past its shipped one.
    ///
    /// Curated rather than a system color well on purpose. These read on a
    /// light Mac, a dark Mac, and the board's near-black background, and they
    /// stay distinguishable from each other at 9pt — which is the size the
    /// dot they paint actually is. A free picker gets you a source you can't
    /// find in the list and a ring that vanishes in dark mode.
    ///
    /// Six per row at 24: a full hue wheel plus four neutrals for the rows
    /// you want present but quiet. The host stores whatever `#RRGGBB` it is
    /// given, so hand-edited `sources.json` colors keep working.
    static let accentChoices: [AccentChoice] = [
        AccentChoice(name: "Red", hex: "#D05353"),
        AccentChoice(name: "Coral", hex: "#E0705A"),
        AccentChoice(name: "Orange", hex: "#D98A3C"),
        AccentChoice(name: "Amber", hex: "#C7A03F"),
        AccentChoice(name: "Olive", hex: "#9FA84A"),
        AccentChoice(name: "Lime", hex: "#7FB050"),

        AccentChoice(name: "Green", hex: "#5FA36B"),
        AccentChoice(name: "Emerald", hex: "#3EA982"),
        AccentChoice(name: "Teal", hex: "#34A5A0"),
        AccentChoice(name: "Cyan", hex: "#3FA3BE"),
        AccentChoice(name: "Sky", hex: "#4F97D4"),
        AccentChoice(name: "Blue", hex: "#5B7FD4"),

        AccentChoice(name: "Indigo", hex: "#6F6FD0"),
        AccentChoice(name: "Violet", hex: "#8A6BD1"),
        AccentChoice(name: "Purple", hex: "#A371F7"),
        AccentChoice(name: "Orchid", hex: "#B96AC4"),
        AccentChoice(name: "Magenta", hex: "#C95FA8"),
        AccentChoice(name: "Pink", hex: "#D46A90"),

        AccentChoice(name: "Rose", hex: "#D2687A"),
        AccentChoice(name: "Rust", hex: "#B5705A"),
        AccentChoice(name: "Sand", hex: "#B39A78"),
        AccentChoice(name: "Stone", hex: "#94908A"),
        AccentChoice(name: "Slate", hex: "#7E8894"),
        AccentChoice(name: "Graphite", hex: "#6E7378"),
    ]

    /// Case-insensitive `#RRGGBB` compare, so a stored `#d97757` still reads
    /// as the same swatch the grid drew.
    static func sameAccent(_ lhs: String?, _ rhs: String?) -> Bool {
        func normal(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            return value.replacingOccurrences(of: "#", with: "").uppercased()
        }
        return normal(lhs) == normal(rhs)
    }
}
