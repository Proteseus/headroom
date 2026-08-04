import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

extension Color {
    /// Desaturated brand color for exhausted quota — never alarm red.
    ///
    /// Both apps drain the same way so an exhausted pool reads identically
    /// on the Mac and the phone; the firmware mirrors the idea with
    /// `dimToward` (docs/glossary.md, "Colour").
    func drained(
        saturationScale: CGFloat = 0.38,
        brightnessScale: CGFloat = 0.78
    ) -> Color {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        #if canImport(AppKit)
        guard let rgb = NSColor(self).usingColorSpace(.deviceRGB) else {
            return opacity(0.45)
        }
        rgb.getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        )
        #elseif canImport(UIKit)
        guard UIColor(self).getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        ) else {
            return opacity(0.45)
        }
        #else
        return opacity(0.45)
        #endif
        return Color(
            hue: hue,
            saturation: saturation * saturationScale,
            brightness: min(1, brightness * brightnessScale + 0.12),
            opacity: alpha
        )
    }
}
