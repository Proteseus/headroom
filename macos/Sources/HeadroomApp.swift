import AppKit
import SwiftUI

@main
struct HeadroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: UsageStore?
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let store = UsageStore()
        self.store = store
        statusController = StatusItemController(store: store)
        store.start()
    }
}

private struct SettingsView: View {
    @AppStorage("usageEndpoint")
    private var endpoint = "http://127.0.0.1:8737/usage"

    var body: some View {
        Form {
            TextField("Usage endpoint", text: $endpoint)
                .textFieldStyle(.roundedBorder)
            Text("The menu-bar app reads the same JSON endpoint as the ESP32.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 430)
    }
}

