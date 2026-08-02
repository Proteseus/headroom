import SwiftUI

/// Landscape (and unfolded foldable) iPhones report a regular *width* with a
/// compact *height*. That is the canvas worth splitting down the middle —
/// quotas beside charts, feed beside services — the same gate Septena uses
/// for Today's dial rail. iPad stays out: it already has room for a single
/// readable column, and a mid-page HStack fights that.
enum WidePhoneLayout {
    @MainActor
    static func isActive(
        _ horizontalSizeClass: UserInterfaceSizeClass?
    ) -> Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
            && horizontalSizeClass == .regular
        #else
        false
        #endif
    }
}
