import SwiftUI

@main
struct HeadroomMobileApp: App {
    @StateObject private var store = MobileUsageStore()

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
        }
    }
}
