import Foundation
import SwiftUI
import WatchConnectivity
import WidgetKit

/// The watch's half of the link to the phone.
///
/// Receive-only. The watch never asks for anything — it cannot reach the Mac,
/// and a request would only wake a phone that pushes on its own next fetch
/// anyway. Both WatchConnectivity channels land in the same place: decode,
/// write the app group, reload the complications.
@MainActor
final class WatchLink: NSObject, ObservableObject {
    static let shared = WatchLink()

    @Published private(set) var snapshot: HeadroomWidgetSnapshot?

    private override init() {
        super.init()
        snapshot = WatchSnapshotCache.load()
    }

    /// Safe to call repeatedly — both the delegate adaptor and the scene may
    /// reach it on the same launch.
    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.delegate == nil else { return }
        session.delegate = self
        session.activate()
        // Whatever context WC has been holding since before this launch.
        adopt(payload(session.receivedApplicationContext))
    }

    fileprivate func adopt(_ data: Data?) {
        guard let data, let decoded = WatchSnapshotCache.save(data) else { return }
        snapshot = decoded
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// Pull the payload out on the delegate's own thread. WC hands back a
/// `[String: Any]`, which cannot cross into the main actor; `Data` can.
private func payload(_ dictionary: [String: Any]) -> Data? {
    dictionary[HeadroomAppGroup.watchPayloadKey] as? Data
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        let data = payload(applicationContext)
        Task { @MainActor in WatchLink.shared.adopt(data) }
    }

    /// Where `transferCurrentComplicationUserInfo` arrives — the channel that
    /// wakes this app in the background so a face can change unopened.
    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        let data = payload(userInfo)
        Task { @MainActor in WatchLink.shared.adopt(data) }
    }
}
