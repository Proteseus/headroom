import SwiftUI
import WatchKit

@main
struct HeadroomWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchDelegate.self) private var delegate
    @StateObject private var link = WatchLink.shared

    var body: some Scene {
        WindowGroup {
            WatchRootView(link: link)
        }
    }
}

/// The session has to be live before the first frame, not on the first view.
///
/// A complication transfer wakes this app in the background with no window
/// ever built, and if nothing has claimed `WCSession.delegate` by then the
/// payload that did the waking is dropped.
final class WatchDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        Task { @MainActor in WatchLink.shared.activate() }
    }
}
