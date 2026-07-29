import Foundation

/// The watch's copy of the widget snapshot.
///
/// Same payload and same app-group key as the phone's cache, but a different
/// container: an app group is scoped to one device, so nothing the phone writes
/// is readable here. The watch app writes this when WatchConnectivity delivers
/// a payload; the complications read it, exactly as the home-screen widgets
/// read the phone's.
enum WatchSnapshotCache {
    static func load() -> HeadroomWidgetSnapshot? {
        HeadroomWidgetSnapshot.cached()
    }

    /// Store raw bytes off the wire, after proving they decode. Returning the
    /// decoded value saves the caller a second pass, and returning nil says
    /// nothing was stored — a payload from a newer phone build that this watch
    /// cannot read must not replace one it can.
    @discardableResult
    static func save(_ data: Data) -> HeadroomWidgetSnapshot? {
        guard let decoded = try? JSONDecoder()
                .decode(HeadroomWidgetSnapshot.self, from: data),
              let defaults = HeadroomAppGroup.defaults()
        else { return nil }
        defaults.set(data, forKey: HeadroomAppGroup.snapshotKey)
        return decoded
    }
}
