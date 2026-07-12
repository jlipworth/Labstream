import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite("Download cleanup/index ordering")
struct DownloadCleanupOrderingTests {
    @Test func journalFailureDurablyReservesExactIntentAndRejectsReplacement() throws {
        try withDirectory { directory in
            let key = attemptKey("attempt-A")
            let store = DownloadStore(baseDirectory: directory)
            #expect(createRecord(store: store, key: key, persistedSession: nil))
            let candidate = try intent(key: key, session: "transient-session-A")
            let failedJournal = DownloadCleanupIntentJournal(
                directory: directory,
                persistence: failingJournalPersistence())

            guard case .deletionPending(let reserved, _) =
                    DownloadCleanupOrdering.prepareForDestructiveDeletion(
                        candidates: [candidate], key: key,
                        journal: failedJournal, store: store) else {
                Issue.record("Expected durable index fallback"); return
            }
            #expect(reserved == key)

            let relaunched = DownloadStore(baseDirectory: directory)
            #expect(relaunched.isDeletionPending(for: key))
            #expect(relaunched.deletionPendingCleanupIntents(for: key) == [candidate])
            let replacement = attemptKey("attempt-B")
            guard case .rejectedOwnership(_, let actual, let reason) = relaunched
                .createAttemptOwnedRecord(
                    record(for: replacement), attemptID: replacement.attemptID,
                    replacing: key.attemptID) else {
                Issue.record("Deletion reservation must reject replacement B"); return
            }
            #expect(actual == key)
            #expect(reason == .deletionPending)
        }
    }

    @Test func partialJournalCommitKeepsAllOperationsInIndexThenRetriesWithoutDuplicates() throws {
        try withDirectory { directory in
            let key = attemptKey("attempt-A")
            let store = DownloadStore(baseDirectory: directory)
            #expect(createRecord(store: store, key: key, persistedSession: "session-A"))
            let active = try intent(key: key, session: "session-A")
            let convert = try convertIntent(key: key, jobID: 42)
            let controller = JournalWriteController(failOnWrite: 2)
            let partialJournal = DownloadCleanupIntentJournal(
                directory: directory,
                persistence: controller.persistence)

            guard case .deletionPending =
                    DownloadCleanupOrdering.prepareForDestructiveDeletion(
                        candidates: [active, convert], key: key,
                        journal: partialJournal, store: store) else {
                Issue.record("Expected partial journal failure to reserve index authority"); return
            }
            #expect(try loadedJournal(directory) == [active])
            let relaunched = DownloadStore(baseDirectory: directory)
            let pending = try #require(relaunched.deletionPendingCleanupIntents(for: key))
            #expect(pending == [active, convert])

            let healthy = DownloadCleanupIntentJournal(directory: directory)
            guard case .ready(let durable) =
                    DownloadCleanupOrdering.prepareForDestructiveDeletion(
                        candidates: pending, key: key,
                        journal: healthy, store: relaunched) else {
                Issue.record("Expected retry to migrate every operation"); return
            }
            #expect(durable == [active, convert])
            #expect(try loadedJournal(directory) == [active, convert])
            #expect(relaunched.remove(for: key) == .staleOrMissing)
            #expect(relaunched.completePendingDeletion(for: key) == .applied)
            #expect(DownloadStore(baseDirectory: directory).record(for: key.ratingKey) == nil)
        }
    }

    @Test func indexFailureLeavesOriginalDurableRowAndCleanupMetadataRetryable() throws {
        try withDirectory { directory in
            let writer = IndexWriteController(failOnWrite: 2)
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try writer.write(data, to: url) })
            let key = attemptKey("attempt-A")
            #expect(createRecord(store: store, key: key, persistedSession: "session-A"))
            let candidate = try intent(key: key, session: "session-A")
            let failedJournal = DownloadCleanupIntentJournal(
                directory: directory,
                persistence: failingJournalPersistence())

            guard case .indexPersistenceFailed(let failedKey, _) =
                    DownloadCleanupOrdering.prepareForDestructiveDeletion(
                        candidates: [candidate], key: key,
                        journal: failedJournal, store: store) else {
                Issue.record("Expected index failure to stop deletion"); return
            }
            #expect(failedKey == key)

            let relaunched = DownloadStore(baseDirectory: directory)
            #expect(!relaunched.isDeletionPending(for: key))
            #expect(relaunched.record(for: key.ratingKey)?.metadata?.playSessionID == "session-A")
            #expect(relaunched.record(for: key.ratingKey) != nil)
        }
    }

    private func attemptKey(_ attempt: String) -> DownloadAttemptKey {
        DownloadAttemptKey(
            ratingKey: "emby:item",
            attemptID: DownloadAttemptID(rawValue: attempt)!)
    }

    private func record(
        for key: DownloadAttemptKey,
        persistedSession: String? = nil,
        localURL: URL = URL(fileURLWithPath: "/tmp/item.mp4")
    ) -> DownloadRecord {
        DownloadRecord(
            ratingKey: key.ratingKey,
            attemptID: key.attemptID,
            title: "Item",
            localURL: localURL,
            status: .failed,
            metadata: OfflineMetadata(
                ratingKey: key.ratingKey,
                title: "Item",
                type: "movie",
                backendKind: .emby,
                backendBaseURLString: "https://emby.example",
                backendServerID: "server-1",
                backendUserID: "user-1",
                playSessionID: persistedSession))
    }

    private func createRecord(
        store: DownloadStore,
        key: DownloadAttemptKey,
        persistedSession: String?
    ) -> Bool {
        let value = record(
            for: key,
            persistedSession: persistedSession,
            localURL: store.destinationURL(ratingKey: key.ratingKey, ext: "mp4"))
        guard case .committed(let actual) = store.createAttemptOwnedRecord(
            value, attemptID: key.attemptID) else { return false }
        return actual == key
    }

    private func intent(
        key: DownloadAttemptKey,
        session: String
    ) throws -> DurableDownloadCleanupIntent {
        try #require(DurableDownloadCleanupIntent(
            id: UUID(uuidString: session == "session-A"
                ? "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
                : "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!,
            attemptKey: key,
            backend: .emby,
            server: serverIdentity(),
            operation: .activeEncoding(playSessionID: session)))
    }

    private func convertIntent(
        key: DownloadAttemptKey,
        jobID: Int
    ) throws -> DurableDownloadCleanupIntent {
        try #require(DurableDownloadCleanupIntent(
            id: UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!,
            attemptKey: key,
            backend: .emby,
            server: serverIdentity(),
            operation: .embyConvert(.knownJob(jobID: jobID))))
    }

    private func serverIdentity() -> DurableDownloadCleanupIntent.ServerIdentity {
        DurableDownloadCleanupIntent.ServerIdentity(
            baseURL: URL(string: "https://emby.example")!,
            serverID: "server-1",
            userID: "user-1")!
    }

    private func failingJournalPersistence() -> DownloadCleanupIntentJournal.Persistence {
        .init(
            read: liveRead,
            encode: { try JSONEncoder().encode($0) },
            atomicWrite: { _, _ in throw OrderingFailure() })
    }

    private func loadedJournal(_ directory: URL) throws -> [DurableDownloadCleanupIntent] {
        guard case .loaded(let values) = DownloadCleanupIntentJournal(directory: directory).load()
        else { throw OrderingFailure() }
        return values
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "download-cleanup-ordering-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private var liveRead: @Sendable (URL) throws -> Data? {
        { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try Data(contentsOf: url)
        }
    }
}

private struct OrderingFailure: Error {}

private final class JournalWriteController: @unchecked Sendable {
    private let lock = NSLock()
    private let failOnWrite: Int
    private var writes = 0

    init(failOnWrite: Int) { self.failOnWrite = failOnWrite }

    var persistence: DownloadCleanupIntentJournal.Persistence {
        .init(
            read: { url in
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return try Data(contentsOf: url)
            },
            encode: { try JSONEncoder().encode($0) },
            atomicWrite: { [self] data, url in
                let shouldFail = lock.withLock {
                    writes += 1
                    return writes == failOnWrite
                }
                if shouldFail { throw OrderingFailure() }
                try data.write(to: url, options: .atomic)
            })
    }
}

private final class IndexWriteController: @unchecked Sendable {
    private let lock = NSLock()
    private let failOnWrite: Int
    private var writes = 0

    init(failOnWrite: Int) { self.failOnWrite = failOnWrite }

    func write(_ data: Data, to url: URL) throws {
        let shouldFail = lock.withLock {
            writes += 1
            return writes == failOnWrite
        }
        if shouldFail { throw OrderingFailure() }
        try data.write(to: url, options: .atomic)
    }
}
