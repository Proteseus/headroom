import Foundation

/// User-facing control for the ESP32's optional USB CDC fallback.
///
/// Wi-Fi remains the normal transport. When enabled, the host also claims the
/// first matching `/dev/cu.usbmodem*` or `/dev/cu.usbserial*` device it finds.
/// Keeping this in UserDefaults lets both host supervisors (launchd and the
/// app-owned child) receive the same setting.
enum HeadroomUSB {
    static let defaultsKey = "headroomUSBFallbackEnabled"
    static let environmentKey = "HEADROOM_ENABLE_USB"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static var detectedPorts: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names
            .filter {
                $0.hasPrefix("cu.usbmodem") || $0.hasPrefix("cu.usbserial")
            }
            .sorted()
            .map { "/dev/\($0)" }
    }

    static var detectedPortLabel: String {
        detectedPorts.first ?? "Not detected"
    }
}
