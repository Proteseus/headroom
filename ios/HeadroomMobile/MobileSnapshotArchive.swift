import Foundation

/// The last `/usage` payload the phone actually received, held on disk so the
/// app still has something to draw when the Mac is asleep, off the network, or
/// simply not answering.
///
/// Only the most recent payload is kept, because the recent history the UI
/// draws — `burndown`, `byDay`, `activity` — already lives *inside* that
/// payload. The host keeps 14 days of samples and hands back the windowed view
/// on every fetch, so a second on-device time series would be a copy that can
/// only drift from it.
///
/// The raw bytes are stored rather than a re-encoded model: `UsageSnapshot` is
/// decode-only, and the host keeps adding fields, so a round trip through our
/// own encoder would silently drop everything this build does not model yet.
enum MobileSnapshotArchive {
    struct Entry: Sendable {
        var snapshot: UsageSnapshot
        /// When the phone received the payload — not the host's `updated`
        /// field. This is the honest answer to "how old is what I'm reading".
        var capturedAt: Date
    }

    static func save(_ payload: Data, capturedAt: Date = .now) {
        guard let url = fileURL, !payload.isEmpty else { return }
        // Splice the payload in verbatim instead of re-encoding it — see the
        // note above about fields this build does not model yet.
        var envelope = Data(
            #"{"capturedAt":\#(capturedAt.timeIntervalSince1970),"usage":"#.utf8
        )
        envelope.append(payload)
        envelope.append(Data("}".utf8))
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? envelope.write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    static func load() -> Entry? {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return nil }
        return Entry(
            snapshot: envelope.usage,
            capturedAt: Date(timeIntervalSince1970: envelope.capturedAt)
        )
    }

    /// Drop the cache when it stops describing the Mac we are pointed at — a
    /// re-pair to a different host, or an unpair.
    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private struct Envelope: Decodable {
        let capturedAt: TimeInterval
        let usage: UsageSnapshot
    }

    private static var fileURL: URL? {
        HeadroomAppGroup.containerURL()?
            .appendingPathComponent("last-usage.json")
    }
}

extension MobileHeadroomClient {
    /// Fetch and archive in one step, so every path that reaches the Mac —
    /// foreground refresh, pull to refresh, background task — leaves the
    /// offline cache warm rather than only the one that happened to remember.
    func fetchAndArchiveUsage() async throws -> UsageSnapshot {
        let (snapshot, payload) = try await fetchUsagePayload()
        MobileSnapshotArchive.save(payload)
        return snapshot
    }
}
