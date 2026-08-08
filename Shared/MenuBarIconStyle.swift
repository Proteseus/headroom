import Foundation

/// How the macOS menu-bar glyph (and later the ESP32 glance) reads focus
/// providers. Remaining is fuel left; Pace is over/under even spend.
enum MenuBarIconStyle: String, CaseIterable, Sendable {
    case remaining
    case pace

    static let defaultsKey = "menuBarIconStyle"

    /// Softness of the pace curve. A delta of this many points maps near
    /// halfway to the edge (`tanh(1) ≈ 0.76`); small gaps stay readable and
    /// large ones asymptote instead of clipping.
    static let paceScale: Double = 8

    static var current: MenuBarIconStyle {
        MenuBarIconStyle(
            rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        ) ?? .remaining
    }

    /// Maps `used% − pace%` onto (−1, +1) for vertical placement.
    static func paceOffset(
        used: Double,
        pace: Double,
        scale: Double = paceScale
    ) -> Double {
        guard scale > 0 else { return 0 }
        return tanh((used - pace) / scale)
    }
}
