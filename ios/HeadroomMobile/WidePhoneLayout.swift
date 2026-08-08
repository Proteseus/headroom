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

/// Shared chrome for the three tab roots. Overview is a ScrollView of cards;
/// Attention and Activity are `.insetGrouped` lists. The system list inset is
/// 20pt on compact iPhone — keep the ScrollView on the same number so
/// switching tabs does not shift the gutters.
enum MobileHomeChrome {
    static let pageInset: CGFloat = 20
}
