import Foundation

/// The last `/attention/events` payload the phone received, held on disk so
/// the Attention queue still has something to draw after a cold launch when
/// the Mac is asleep or unreachable.
///
/// Rollup reasons and activity failures already ride inside
/// ``MobileSnapshotArchive`` (they live on `/usage`). Coding-agent events are
/// a separate poll, so without this they vanished the moment the process died
/// even though the rest of the screen came back from the usage archive.
///
/// Events are Codable end-to-end, so we re-encode them rather than splicing
/// raw bytes the way the usage archive does — there is no decode-only model
/// here that would drop fields on a round trip.
enum MobileAgentAttentionArchive {
    static func save(_ events: [AgentAttentionEvent], capturedAt: Date = .now) {
        guard let url = fileURL else { return }
        let envelope = Envelope(
            capturedAt: capturedAt.timeIntervalSince1970,
            events: events
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    static func load() -> [AgentAttentionEvent]? {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return nil }
        return envelope.events
    }

    /// Drop the cache when it stops describing the Mac we are pointed at — a
    /// re-pair to a different host, or an unpair.
    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private struct Envelope: Codable {
        let capturedAt: TimeInterval
        let events: [AgentAttentionEvent]
    }

    private static var fileURL: URL? {
        HeadroomAppGroup.containerURL()?
            .appendingPathComponent("last-attention-events.json")
    }
}
