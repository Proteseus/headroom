import CloudKit
import Foundation
import Security

/// Carries machine records between CloudKit and the local host. Nothing else.
///
/// The merge, the whitelist of what may be shared, and the rule for who wins
/// all live in the Python host (`icloud_sync.py`, `shared_prefs.py`) where they
/// are tested. This type fetches records, posts them to `/machines/sync`, and
/// saves back the one record the host says this Mac should publish. It holds no
/// opinion about the contents and must not gain one — two implementations of
/// last-writer-wins would eventually disagree, and the bug would surface as
/// settings quietly reverting on one Mac.
///
/// **Why the app and not the host.** A folder in iCloud Drive lives under
/// `~/Library/Mobile Documents`, which is TCC-protected. The host is a
/// LaunchAgent, and a daemon can create and write files there while being
/// refused `listdir` — so every Mac publishes happily and none can enumerate.
/// CloudKit is reached through an entitlement instead, and entitlements are not
/// subject to TCC. The app is the only half that can hold one.
@MainActor
final class MachineCloudSync {
    /// Matches `com.apple.developer.icloud-container-identifiers`.
    static let containerID = "iCloud.com.centaur-labs.headroom"
    static let recordType = "Machine"
    /// One field, holding the same JSON the folder transport writes. CloudKit
    /// schema migrations are forever; a blob the host owns end to end is not.
    static let payloadKey = "payload"
    static let updatedKey = "updated"

    /// Records older than this are ignored on the way in and deleted on the way
    /// out. Mirrors `icloud_sync.FORGET_S` — a Mac you stopped using should
    /// fall off the list without anyone deleting a record by hand.
    static let forgetInterval: TimeInterval = 30 * 24 * 3600

    /// Whether this build may touch CloudKit at all.
    ///
    /// **Check this before constructing one.** `CKContainer(identifier:)` on a
    /// binary whose signature does not carry the matching entitlement raises an
    /// Objective-C exception, which Swift cannot catch — so it is not a failed
    /// call that degrades, it is the process dying. Every local build is in
    /// exactly that position: `CODE_SIGNING_ALLOWED=NO` compiles this file and
    /// signs nothing, and scripts/build-app.sh only merges the iCloud
    /// entitlements when a provisioning profile is supplied.
    ///
    /// So the entitlement is read off our own signature first. A build without
    /// it reports multi-Mac as unavailable and carries on being a menu bar app.
    static let isAvailable: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task, "com.apple.developer.icloud-services" as CFString, nil)
        return value != nil
    }()

    private let database: CKDatabase
    private let endpoint: String
    private var subscribed = false

    /// Returns nil when this build cannot reach CloudKit. Never force it.
    init?(endpoint: String) {
        guard Self.isAvailable else { return nil }
        self.endpoint = endpoint
        database = CKContainer(identifier: Self.containerID).privateCloudDatabase
    }

    private var client: HeadroomClient { HeadroomClient(endpoint: endpoint) }

    /// One round: pull every machine record, hand them to the host, save ours.
    ///
    /// Deliberately a full fetch rather than a change-token delta. The record
    /// count is the number of Macs a person owns, the payload is a few KB, and
    /// a delta would need its token persisted and invalidated correctly for a
    /// saving that does not exist at this scale.
    @discardableResult
    func run() async -> Result<MultiMacRoundSummary, Error> {
        do {
            let peers = try await fetchPeers()
            let round = try await client.syncMachines(records: peers)
            try await save(id: round.recordID, payload: round.recordJSON)
            return .success(MultiMacRoundSummary(
                peers: round.peerCount, adopted: round.adopted.count))
        } catch {
            return .failure(error)
        }
    }

    /// Payload strings exactly as stored. Never parsed on this side.
    private func fetchPeers() async throws -> [String] {
        let query = CKQuery(
            recordType: Self.recordType, predicate: NSPredicate(value: true))
        let cutoff = Date().addingTimeInterval(-Self.forgetInterval)
        var out: [String] = []
        var cursor: CKQueryOperation.Cursor?

        repeat {
            let page: (
                matchResults: [(CKRecord.ID, Result<CKRecord, Error>)],
                queryCursor: CKQueryOperation.Cursor?
            )
            if let cursor {
                page = try await database.records(continuingMatchFrom: cursor)
            } else {
                page = try await database.records(matching: query)
            }
            let (results, next) = (page.matchResults, page.queryCursor)
            for (_, result) in results {
                // One unreadable record must not lose the round. A partial
                // failure here is a record written by a newer build, or one
                // mid-conflict; the others are still worth merging.
                guard let record = try? result.get(),
                      let modified = record.modificationDate ?? record.creationDate,
                      modified > cutoff,
                      let blob = record[Self.payloadKey] as? String
                else { continue }
                out.append(blob)
            }
            cursor = next
        } while cursor != nil
        return out
    }

    private func save(id: String, payload blob: String) async throws {
        let recordID = CKRecord.ID(recordName: id)
        // Fetch-then-modify rather than a blind save: CloudKit rejects a save
        // that carries no change tag for an existing record, and this Mac is
        // the only writer of its own record, so there is nothing to merge.
        let ck: CKRecord
        if let existing = try? await database.record(for: recordID) {
            ck = existing
        } else {
            ck = CKRecord(recordType: Self.recordType, recordID: recordID)
        }
        if ck[Self.payloadKey] as? String == blob { return }
        ck[Self.payloadKey] = blob as CKRecordValue
        ck[Self.updatedKey] = Date() as CKRecordValue
        _ = try await database.save(ck)
    }

    /// Ask CloudKit to wake us when another Mac writes. Best-effort: without it
    /// the app's own poll still closes the loop, just at its own pace.
    func subscribeIfNeeded() async {
        guard !subscribed else { return }
        subscribed = true
        let subscription = CKQuerySubscription(
            recordType: Self.recordType,
            predicate: NSPredicate(value: true),
            subscriptionID: "machine-changes",
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        let info = CKSubscription.NotificationInfo()
        // Silent: this is a cue to sync, not something to interrupt anyone with.
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try? await database.save(subscription)
    }

}

struct MultiMacRoundSummary: Sendable {
    var peers: Int
    var adopted: Int
}
