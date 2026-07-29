import Foundation
import WatchConnectivity

/// The phone's half of the watch link.
///
/// Headroom has no cloud. The Mac is the source, the phone is the only thing
/// that can reach it over the LAN, and the watch can reach neither — an app
/// group is per-device, so the watch cannot read the cache the phone just
/// wrote for its own widget either. So the phone forwards that same
/// `HeadroomWidgetSnapshot` over WatchConnectivity and the watch writes it into
/// *its* app group, where the complications read it exactly like the home
/// screen widgets read the phone's.
///
/// Two channels, because neither is enough alone:
///
///   * `updateApplicationContext` is unbudgeted and latest-value-wins, but it
///     is only delivered while the watch app itself runs. It is what makes the
///     watch app current the moment you raise your wrist.
///   * `transferCurrentComplicationUserInfo` wakes the watch extension so a
///     complication can change without the app being opened — and is capped at
///     around 50 a day. Spending one on a snapshot that moved a percent would
///     burn the budget by lunchtime, so it is reserved for payloads that
///     actually change what the wrist says.
@MainActor
final class WatchBridge: NSObject {
    static let shared = WatchBridge()

    /// What the last complication transfer said, so the next one can be judged
    /// against it rather than against the last thing merely displayed.
    private var lastPushed: HeadroomWidgetSnapshot?

    /// How far a provider has to move before it is worth one of the day's
    /// transfers. Below this the ring redraws at the same angle to the eye.
    private static let materialShift = 5.0

    private override init() { super.init() }

    /// Safe to call more than once — scenePhase hands us `.active` repeatedly.
    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.delegate == nil else { return }
        session.delegate = self
        session.activate()
    }

    /// Forward a freshly cached snapshot to the watch.
    func push(_ snapshot: HeadroomWidgetSnapshot) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated,
              let data = try? JSONEncoder().encode(snapshot)
        else { return }

        // Unbudgeted, and harmless when no watch app is running — WC keeps the
        // latest value and delivers it at launch.
        try? session.updateApplicationContext([HeadroomAppGroup.watchPayloadKey: data])

        guard session.isComplicationEnabled,
              session.remainingComplicationUserInfoTransfers > 0,
              isWorthWaking(snapshot)
        else { return }
        session.transferCurrentComplicationUserInfo([HeadroomAppGroup.watchPayloadKey: data])
        lastPushed = snapshot
    }

    /// Whether this snapshot says something the face is not already saying.
    ///
    /// First payload of a session always qualifies; after that it takes a
    /// changed attention level, a provider appearing or leaving, or one of them
    /// moving `materialShift` points.
    private func isWorthWaking(_ snapshot: HeadroomWidgetSnapshot) -> Bool {
        guard let last = lastPushed else { return true }
        if last.attentionLevel != snapshot.attentionLevel { return true }
        let before = Dictionary(
            last.providers.map { ($0.id, $0.percent) },
            uniquingKeysWith: { first, _ in first }
        )
        if before.count != snapshot.providers.count { return true }
        return snapshot.providers.contains { provider in
            guard let was = before[provider.id] else { return true }
            return abs(was - provider.percent) >= Self.materialShift
        }
    }
}

// The delegate callbacks arrive off the main thread and carry no state we
// keep, so they stay nonisolated. Reactivation after a watch swap is the only
// one with work to do, and `activate()` is the framework's own requirement.
extension WatchBridge: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
}
