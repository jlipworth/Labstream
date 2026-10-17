#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

/// P3a store pins: additive lifecycle/history in the v4 envelope, structural derivation for rows
/// written without them, and rollback compatibility with binaries that drop them (R2-3, R2-6).
@Suite("Download lifecycle store compatibility", .serialized)
struct DownloadLifecycleStoreTests {
    @Test("Lifecycle is written next to the derived status and survives a reload")
    func lifecycleIsPersisted() throws {
        try withDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            let key = try seed("plex:one", status: .paused, in: store)
            let index = try indexRows(directory)
            #expect(index.first?["lifecycle"] as? String == "paused")
            #expect(index.first?["status"] as? String == "paused")
            #expect(DownloadStore(baseDirectory: directory).lifecycleState(for: key)?.lifecycle
                    == .paused)
        }
    }

    @Test("A row re-encoded by an older binary derives its lifecycle structurally")
    func olderBinaryReencodeDerivesStructurally() throws {
        try withDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            let key = try seed("plex:two", status: .complete, in: store)
            // An older binary drops the unknown keys when it rewrites the row.
            try rewriteRows(directory) { row in
                row.removeValue(forKey: "lifecycle")
                row.removeValue(forKey: "history")
            }
            let reloaded = DownloadStore(baseDirectory: directory)
            #expect(reloaded.lifecycleState(for: key)?.lifecycle == .complete)
            #expect(reloaded.record(for: key)?.status == .complete)
        }
    }

    @Test("A status changed by an older binary wins over a stale lifecycle")
    func staleLifecycleYieldsToOlderBinaryStatus() throws {
        try withDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            let key = try seed("plex:three", status: .paused, in: store)
            try rewriteRows(directory) { row in row["status"] = "failed" }
            let reloaded = DownloadStore(baseDirectory: directory)
            #expect(reloaded.lifecycleState(for: key)?.lifecycle == .failed)
        }
    }

    @Test("A season row awaiting admission is planned and still projects .failed + flag")
    func plannedSeasonRowKeepsTheLegacyProjection() throws {
        try withDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            var metadata = OfflineMetadata(ratingKey: "plex:ep", title: "Ep", type: "episode")
            metadata.seasonPlannerPendingAdmission = true
            let key = try seed("plex:ep", status: .failed, metadata: metadata, in: store)
            #expect(store.lifecycleState(for: key)?.lifecycle == .planned)
            #expect(store.record(for: key)?.status == .failed)
            let index = try indexRows(directory)
            #expect(index.first?["status"] as? String == "failed")
            let metadataObject = index.first?["metadata"] as? [String: Any]
            #expect(metadataObject?["seasonPlannerPendingAdmission"] as? Bool == true)
            #expect(DownloadStore(baseDirectory: directory).lifecycleState(for: key)?.lifecycle
                    == .planned)
        }
    }

    @Test("A legacy status write keeps finalizing under .downloading")
    func legacyShimKeepsFinalizing() {
        #expect(DownloadStoreTestHooks.legacyLifecycle(
            for: .downloading, current: .finalizing, admissionPending: false) == .finalizing)
        #expect(DownloadStoreTestHooks.legacyLifecycle(
            for: .paused, current: .finalizing, admissionPending: false) == .paused)
        #expect(DownloadStoreTestHooks.legacyLifecycle(
            for: .failed, current: .planned, admissionPending: true) == .planned)
        #expect(DownloadStoreTestHooks.legacyLifecycle(
            for: .failed, current: .planned, admissionPending: false) == .failed)
    }

    @Test("Progress records bytes but never promotes a paused or failed row (B09)")
    func progressDoesNotPromotePausedRows() throws {
        try withDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            let paused = try seed("plex:paused", status: .paused, in: store)
            _ = store.submitProgress(for: paused, bytes: 500, progress: 0.5)
            #expect(store.record(for: paused)?.status == .paused)
            #expect(store.record(for: paused)?.bytes == 500)

            let queued = try seed("plex:queued", status: .queued, in: store)
            _ = store.submitProgress(for: queued, bytes: 10, progress: 0.1)
            #expect(store.lifecycleState(for: queued)?.lifecycle == .transferring)
            #expect(store.record(for: queued)?.status == .downloading)
        }
    }

    @Test("Lifecycle events persist history and reject illegal transitions without writing")
    func lifecycleEventsPersistHistory() async throws {
        try await withAsyncDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            let key = try seed("plex:event", status: .downloading, in: store)
            guard case .accepted(_, let ticket?) = store.submitLifecycleEvent(
                .transferInterrupted(.cancelledBySystem), for: key,
                facts: DownloadRowFacts(route: .staticRange)) else {
                Issue.record("Expected the interruption to apply"); return
            }
            guard case .committed = await store.flushPersistence(through: ticket, timeout: 5) else {
                Issue.record("Expected the revision to commit"); return
            }
            #expect(store.lifecycleState(for: key)?.history.pauseCause == .systemInterrupted)
            #expect(store.submitLifecycleEvent(
                .transferProgress, for: key, facts: DownloadRowFacts(route: .staticRange))
                == .rejected(.illegal))
            let reloaded = DownloadStore(baseDirectory: directory)
            #expect(reloaded.lifecycleState(for: key)?.history.pauseCause == .systemInterrupted)
            let stale = DownloadAttemptKey(ratingKey: key.ratingKey,
                                           attemptID: DownloadAttemptID(uuid: UUID()))
            #expect(store.submitLifecycleEvent(
                .pause(.user), for: stale, facts: DownloadRowFacts(route: .staticRange))
                == .staleOrMissing)
        }
    }

    // MARK: - Fixtures

    private func seed(_ ratingKey: String, status: DownloadStatus,
                      metadata: OfflineMetadata? = nil,
                      in store: DownloadStore) throws -> DownloadAttemptKey {
        let id = DownloadAttemptID(uuid: UUID())
        let key = DownloadAttemptKey(ratingKey: ratingKey, attemptID: id)
        let url = store.destinationURL(ratingKey: ratingKey, ext: "mp4")
        if status == .complete { try Data([1]).write(to: url) }
        let record = DownloadRecord(
            ratingKey: ratingKey, attemptID: id, title: "Item", localURL: url,
            bytes: status == .complete ? 1 : 0, progress: status == .complete ? 1 : 0,
            status: status,
            metadata: metadata ?? OfflineMetadata(ratingKey: ratingKey, title: "Item", type: "movie"))
        #expect(store.createAttemptOwnedRecord(record, attemptID: id) == .committed(key))
        return key
    }

    private func indexRows(_ directory: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: directory.appendingPathComponent("index.json"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["rows"] as? [[String: Any]])
    }

    private func rewriteRows(_ directory: URL, _ edit: (inout [String: Any]) -> Void) throws {
        let url = directory.appendingPathComponent("index.json")
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var rows = try #require(object["rows"] as? [[String: Any]])
        for index in rows.indices { edit(&rows[index]) }
        object["rows"] = rows
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func withAsyncDirectory(_ body: (URL) async throws -> Void) async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifecycle-store-\(UUID().uuidString)", isDirectory: true)
        let directory = parent.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try await body(directory)
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifecycle-store-\(UUID().uuidString)", isDirectory: true)
        let directory = parent.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try body(directory)
    }
}
#endif
