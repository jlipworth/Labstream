import Foundation
import PMSKit
import Synchronization
import Testing
@testable import Labstream

/// P2 commit 2 pins: the store's cleanup disposition, Plex server-scoped intents built only from
/// persisted authority, and the Plex-only legacy quarantine re-import with its receipt barrier.
@Suite("Cleanup authority contracts", .serialized)
struct CleanupAuthorityContractTests {
    // MARK: - Store disposition

    @Test("A present row reports present; a staged deletion reports retiring")
    func presentAndPendingDeletion() async throws {
        try await withDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            let key = try seed("plex:present", in: store, directory: directory)
            guard case .present(let record) = store.cleanupDisposition(for: key) else {
                Issue.record("Expected present"); return
            }
            #expect(record.status == .complete)
            let server = try #require(DurableDownloadCleanupIntent.ServerIdentity(
                baseURL: URL(string: "https://plex.example.internal:32400")!,
                serverID: "machine-1", userID: nil))
            let intent = try #require(DurableDownloadCleanupIntent(
                attemptKey: key, backend: .plex, server: server,
                operation: .plexOptimize(queueTitle: "Labstream marker"),
                provenance: .rowDeletion, plexCreate: .confirmed))
            #expect(store.markDeletionPending(for: key, cleanupIntents: [intent]) == .applied)
            #expect(store.cleanupDisposition(for: key) == .retiring)
        }
    }

    @Test("The removal window and a failed removal are retiring, never committed-absent")
    func removalWindowIsNotAbsence() async throws {
        try await withDirectory { directory in
            let gate = TerminalSnapshotGate()
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try gate.write(data, to: url) })
            let key = try seed("plex:window", in: store, directory: directory)
            gate.arm(ratingKey: key.ratingKey)

            let deletion = store.submitRemove(for: key)
            #expect(await gate.waitUntilBlocked())
            // The row is already gone from memory, but its removal has not committed.
            #expect(store.cleanupDisposition(for: key) == .retiring)
            gate.releaseFailing()
            guard case .persistenceFailed = await store.resolveRowDeletion(deletion) else {
                Issue.record("Expected the terminal commit to fail"); return
            }
            #expect(store.cleanupDisposition(for: key) != .committedAbsent)

            let retry = store.submitRemove(for: key)
            #expect(await store.resolveRowDeletion(retry) == .removed(key))
            #expect(store.cleanupDisposition(for: key) == .committedAbsent)
        }
    }

    @Test("Another attempt on the same item does not make the intent's attempt present")
    func replacedAttemptIsAbsent() async throws {
        try await withDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            let current = try seed("plex:replaced", in: store, directory: directory)
            let older = DownloadAttemptKey(
                ratingKey: current.ratingKey, attemptID: DownloadAttemptID(uuid: UUID()))
            #expect(store.cleanupDisposition(for: older) == .committedAbsent)
        }
    }

    // MARK: - Plex intent builder

    @Test("Plex intents use persisted server authority and carry no user")
    func plexIntentUsesPersistedAuthority() throws {
        let key = DownloadAttemptKey(ratingKey: "plex:1", attemptID: DownloadAttemptID(uuid: UUID()))
        var metadata = OfflineMetadata(ratingKey: "plex:1", title: "Item", type: "movie")
        metadata.backendKind = .plex
        metadata.optimizeQueueTitle = "Labstream marker 1"
        #expect(DownloadManager.makePlexOptimizeCleanupIntent(
            attemptKey: key, metadata: metadata, create: .confirmed) == nil,
            "no persisted server authority means no intent, never the live session's")

        metadata.backendBaseURLString = "https://plex.example.internal:32400"
        metadata.backendServerID = "machine-1"
        metadata.backendUserID = "ignored-for-plex"
        let intent = try #require(DownloadManager.makePlexOptimizeCleanupIntent(
            attemptKey: key, metadata: metadata, create: .unresolved, provenance: .rowDeletion))
        #expect(intent.operation == .plexOptimize(queueTitle: "Labstream marker 1"))
        #expect(intent.server.serverID == "machine-1")
        #expect(intent.server.userID == nil)
        #expect(intent.plexCreate == .unresolved)
        #expect(intent.provenance == .rowDeletion)
    }

    // MARK: - Legacy quarantine re-import

    @Test("Only Plex elements are re-imported from a legacy quarantine, and the file is receipted")
    func legacyQuarantineImportsOnlyPlex() throws {
        try withSyncDirectory { directory in
            let journal = DownloadCleanupIntentJournal(directory: directory)
            let known = try jellyfinIntent("attempt-known")
            let plex = try plexIntent("attempt-plex")
            // An older build kept `known` in its canonical queue, finished it, and removed it.
            // Its quarantine still holds a copy; re-importing that copy would resurrect it.
            let legacy = directory.appendingPathComponent(
                DownloadCleanupIntentJournal.legacyQuarantinePrefix + "A.json")
            var unknown = try jsonObject(plex)
            unknown["operationType"] = "futureOperation"
            try JSONSerialization.data(withJSONObject: [
                try jsonObject(known), try jsonObject(plex), unknown,
            ]).write(to: legacy)

            let outcome = journal.importLegacyQuarantinedPlexIntents()
            #expect(outcome.importedCount == 1)
            #expect(outcome.blockedIDs.isEmpty)
            #expect(!outcome.blocksAllPlex)
            guard case .loaded(let values) = journal.load() else {
                Issue.record("Expected a readable queue"); return
            }
            #expect(values == [plex])
            #expect(!FileManager.default.fileExists(atPath: legacy.path))
            let receipt = directory.appendingPathComponent(
                DownloadCleanupIntentJournal.importedPrefix + "A.json")
            // The receipt keeps every original element, including the undecodable one.
            let receiptElements = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [Any])
            #expect(receiptElements.count == 3)

            // A second pass finds no candidates, so a drained intent can never come back.
            #expect(journal.remove(id: plex.id, attemptKey: plex.attemptKey,
                                   operation: plex.operation) == .committed(removed: true))
            #expect(journal.importLegacyQuarantinedPlexIntents().importedCount == 0)
            guard case .loaded(let after) = journal.load() else { return }
            #expect(after.isEmpty)
        }
    }

    @Test("This build's own repair evidence is never an import candidate")
    func ownRepairIsNotImported() throws {
        try withSyncDirectory { directory in
            let plex = try plexIntent("attempt-repaired")
            let canonical = directory.appendingPathComponent("download-cleanup-intents.json")
            try JSONSerialization.data(withJSONObject: [
                try jsonObject(plex), ["operationType": "garbage"],
            ]).write(to: canonical)
            let journal = DownloadCleanupIntentJournal(directory: directory)
            guard case .loaded(let repaired) = journal.load() else {
                Issue.record("Expected element repair"); return
            }
            #expect(repaired == [plex])
            #expect(journal.remove(id: plex.id, attemptKey: plex.attemptKey,
                                   operation: plex.operation) == .committed(removed: true))
            #expect(journal.importLegacyQuarantinedPlexIntents().importedCount == 0)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(names.contains { $0.hasPrefix(DownloadCleanupIntentJournal.rejectedPrefix) })
        }
    }

    @Test("An unparseable legacy quarantine blocks every Plex intent until it can be processed")
    func unreadableLegacyBlocksPlex() throws {
        try withSyncDirectory { directory in
            let legacy = directory.appendingPathComponent(
                DownloadCleanupIntentJournal.legacyQuarantinePrefix + "B.json")
            try Data("not json".utf8).write(to: legacy)
            let outcome = DownloadCleanupIntentJournal(directory: directory)
                .importLegacyQuarantinedPlexIntents()
            #expect(outcome.blocksAllPlex)
            #expect(FileManager.default.fileExists(atPath: legacy.path))
        }
    }

    @Test("A receipt that cannot be made durable blocks the imported IDs")
    func failedReceiptBlocksImportedIDs() throws {
        try withSyncDirectory { directory in
            let plex = try plexIntent("attempt-receipt")
            let legacy = directory.appendingPathComponent(
                DownloadCleanupIntentJournal.legacyQuarantinePrefix + "C.json")
            try JSONSerialization.data(withJSONObject: [try jsonObject(plex)]).write(to: legacy)
            let journal = DownloadCleanupIntentJournal(
                directory: directory,
                persistence: .init(
                    read: { url in
                        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                        return try Data(contentsOf: url)
                    },
                    encode: { try JSONEncoder().encode($0) },
                    commit: DurableJournalCommit.liveCommit,
                    syncDirectory: { url in
                        if url.lastPathComponent.hasPrefix(DownloadCleanupIntentJournal.importedPrefix) {
                            throw CocoaError(.fileWriteUnknown)
                        }
                    }))
            let outcome = journal.importLegacyQuarantinedPlexIntents()
            #expect(outcome.blockedIDs == [plex.id])
        }
    }

    // MARK: - Fixtures

    private func seed(_ ratingKey: String, in store: DownloadStore, directory: URL) throws
        -> DownloadAttemptKey {
        let id = DownloadAttemptID(uuid: UUID())
        let key = DownloadAttemptKey(ratingKey: ratingKey, attemptID: id)
        let url = store.destinationURL(ratingKey: ratingKey, ext: "mp4")
        try Data([1]).write(to: url)
        let record = DownloadRecord(
            ratingKey: ratingKey, attemptID: id, title: "Item", localURL: url, bytes: 1,
            progress: 1, status: .complete,
            metadata: OfflineMetadata(ratingKey: ratingKey, title: "Item", type: "movie"))
        #expect(store.createAttemptOwnedRecord(record, attemptID: id) == .committed(key))
        return key
    }

    private func jellyfinIntent(_ attempt: String) throws -> DurableDownloadCleanupIntent {
        let attemptID = try #require(DownloadAttemptID(rawValue: attempt))
        let server = try #require(DurableDownloadCleanupIntent.ServerIdentity(
            baseURL: URL(string: "https://media.example")!, serverID: "server-1", userID: "user-1"))
        return try #require(DurableDownloadCleanupIntent(
            attemptKey: DownloadAttemptKey(ratingKey: "jellyfin:item", attemptID: attemptID),
            backend: .jellyfin, server: server,
            operation: .activeEncoding(playSessionID: "session-\(attempt)"),
            provenance: .rowDeletion))
    }

    private func plexIntent(_ attempt: String) throws -> DurableDownloadCleanupIntent {
        let attemptID = try #require(DownloadAttemptID(rawValue: attempt))
        let server = try #require(DurableDownloadCleanupIntent.ServerIdentity(
            baseURL: URL(string: "https://plex.example.internal:32400")!,
            serverID: "machine-1", userID: nil))
        return try #require(DurableDownloadCleanupIntent(
            attemptKey: DownloadAttemptKey(ratingKey: "plex:item", attemptID: attemptID),
            backend: .plex, server: server,
            operation: .plexOptimize(queueTitle: "Labstream marker \(attempt)"),
            provenance: .rowDeletion, plexCreate: .confirmed))
    }

    private func jsonObject(_ intent: DurableDownloadCleanupIntent) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(intent)) as? [String: Any])
    }

    private func withSyncDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanup-authority-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanup-disposition-\(UUID().uuidString)", isDirectory: true)
        let directory = parent.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try await body(directory)
    }
}

/// Blocks the first index write whose snapshot no longer contains the armed row (the terminal
/// revision of its deletion), then fails it on release.
private final class TerminalSnapshotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armedKey: String?
    private var blocked = false
    private let release = DispatchSemaphore(value: 0)

    func arm(ratingKey: String) { lock.withLock { armedKey = ratingKey } }

    func write(_ data: Data, to url: URL) throws {
        let shouldBlock = lock.withLock { () -> Bool in
            guard let armedKey, !blocked,
                  !String(decoding: data, as: UTF8.self).contains(armedKey) else { return false }
            blocked = true
            return true
        }
        if shouldBlock {
            release.wait()
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try data.write(to: url, options: .atomic)
    }

    func waitUntilBlocked() async -> Bool {
        for _ in 0..<300 {
            if lock.withLock({ blocked }) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func releaseFailing() { release.signal() }
}
