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

    @Test("Truncation strikes persist, survive relaunch and are inherited by a Retry (B54)")
    func truncationStrikesSurviveRelaunchAndRetry() async throws {
        try await withAsyncDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            let first = try seed("plex:strike", status: .downloading,
                                 metadata: profiled("1080p"), in: store)
            #expect(store.recordTruncationStrike(for: first, outcomeID: "A-1") == 1)
            // A replayed outcome is not a second strike.
            #expect(store.recordTruncationStrike(for: first, outcomeID: "A-1") == 1)
            guard case .committed = await store.flushPersistence(
                through: store.currentPersistenceTicket(), timeout: 5) else {
                Issue.record("Expected the strike to commit"); return
            }

            // Relaunch keeps the strike.
            let relaunched = DownloadStore(baseDirectory: directory)
            #expect(relaunched.truncationStrikes(for: first) == 1)

            // Retry mints attempt B for the same source: the strike is inherited.
            let second = DownloadAttemptKey(ratingKey: first.ratingKey,
                                            attemptID: DownloadAttemptID(uuid: UUID()))
            #expect(relaunched.createAttemptOwnedRecord(
                record(second, metadata: profiled("1080p")), attemptID: second.attemptID,
                replacing: first.attemptID) == .committed(second))
            #expect(relaunched.truncationStrikes(for: second) == 1)
            #expect(relaunched.recordTruncationStrike(for: second, outcomeID: "B-1") == 2)

            // A proven profile change starts over.
            let third = DownloadAttemptKey(ratingKey: first.ratingKey,
                                           attemptID: DownloadAttemptID(uuid: UUID()))
            #expect(relaunched.createAttemptOwnedRecord(
                record(third, metadata: profiled("720p")), attemptID: third.attemptID,
                replacing: second.attemptID) == .committed(third))
            #expect(relaunched.truncationStrikes(for: third) == 0)
        }
    }

    @Test("Relaunch keeps a finished forward-only body for re-finalization (B10)")
    func relaunchKeepsFinishedForwardOnlyBody() throws {
        try withDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            var metadata = OfflineMetadata(ratingKey: "jellyfin:done", title: "Done", type: "movie")
            metadata.resumeMode = .liveForwardOnly
            let finished = try seed("jellyfin:done", status: .downloading, metadata: metadata,
                                    in: store)
            let body = try #require(store.attemptWorkingFileURL(for: finished))
            try Data(repeating: 7, count: 4_096).write(to: body)

            var lostMetadata = metadata
            lostMetadata.ratingKey = "jellyfin:lost"
            let lost = try seed("jellyfin:lost", status: .downloading, metadata: lostMetadata,
                                in: store)

            store.reconcile(liveRatingKeys: [],
                            snapshotRatingKeys: [finished.ratingKey, lost.ratingKey])

            #expect(store.lifecycleState(for: finished)?.lifecycle == .finalizing)
            #expect(store.record(for: finished)?.status == .downloading)
            #expect(FileManager.default.fileExists(atPath: body.path), "the body is never deleted")
            // Without a body nothing finished: unchanged from today, the row fails.
            #expect(store.record(for: lost)?.status == .failed)
        }
    }

    @Test("A persisted finalizing static row survives relaunch with its body")
    func relaunchKeepsFinalizingStaticRow() throws {
        try withDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            var metadata = OfflineMetadata(ratingKey: "plex:final", title: "Final", type: "movie")
            metadata.resumeMode = .staticByteRange
            let key = try seed("plex:final", status: .downloading, metadata: metadata, in: store)
            let body = try #require(store.attemptWorkingFileURL(for: key))
            try Data(repeating: 9, count: 2_048).write(to: body)
            _ = store.submitLifecycleEvent(.bodyAtWorking, for: key,
                                           facts: DownloadRowFacts(route: .staticRange))
            #expect(store.lifecycleState(for: key)?.lifecycle == .finalizing)

            store.reconcile(liveRatingKeys: [], snapshotRatingKeys: [key.ratingKey])

            #expect(store.lifecycleState(for: key)?.lifecycle == .finalizing)
            #expect(FileManager.default.fileExists(atPath: body.path))
        }
    }

    @Test("Relaunch keeps a static partial as the checkpoint even beside a resume manifest")
    func relaunchPrefersStaticPartialOverResumeManifest() throws {
        try withDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            var metadata = OfflineMetadata(ratingKey: "plex:ckpt", title: "Ckpt", type: "movie")
            metadata.resumeMode = .staticByteRange
            metadata.resumeDataRelativePath = "plex-ckpt.resume"   // manifest whose blob is gone
            let key = try seed("plex:ckpt", status: .downloading, metadata: metadata, in: store)
            let body = try #require(store.attemptWorkingFileURL(for: key))
            try Data(repeating: 3, count: 8_192).write(to: body)

            store.reconcile(liveRatingKeys: [], snapshotRatingKeys: [key.ratingKey])

            #expect(store.lifecycleState(for: key)?.lifecycle == .paused)
            #expect(store.record(for: key)?.bytes == 8_192)
            #expect(FileManager.default.fileExists(atPath: body.path), "the checkpoint is kept")
        }
    }

    @Test("A resume manifest whose blob is gone does not keep a paused live-stream row")
    func missingResumeBlobIsNotACheckpoint() throws {
        try withDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            var metadata = OfflineMetadata(ratingKey: "jellyfin:blob", title: "Blob", type: "movie")
            metadata.resumeMode = .liveForwardOnly
            metadata.resumeDataRelativePath = "jellyfin-blob.resume"
            let key = try seed("jellyfin:blob", status: .paused, metadata: metadata, in: store)

            store.reconcile(liveRatingKeys: [], snapshotRatingKeys: [key.ratingKey])
            #expect(store.record(for: key)?.status == .failed)

            // With the blob on disk the same row stays resumable.
            let kept = try seed("jellyfin:blob2", status: .paused, metadata: {
                var m = metadata; m.ratingKey = "jellyfin:blob2"
                m.resumeDataRelativePath = "jellyfin-blob2.resume"; return m
            }(), in: store)
            try Data([1, 2, 3]).write(to: directory.appendingPathComponent("jellyfin-blob2.resume"))
            store.reconcile(liveRatingKeys: [], snapshotRatingKeys: [kept.ratingKey])
            #expect(store.record(for: kept)?.status == .paused)
        }
    }

    @Test("A Retry that removes the failed row first still inherits its strikes; Delete does not")
    func retryRemovalCarriesStrikes() throws {
        try withDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            let first = try seed("plex:strike", status: .failed, metadata: profiled("1080p"),
                                 in: store)
            #expect(store.recordTruncationStrike(for: first, outcomeID: "A-1") == 1)
            guard case .removed = store.resolveRowDeletionSynchronously(
                store.submitRemoveForRetry(for: first)) else {
                Issue.record("Expected the retry removal to apply"); return
            }

            let second = DownloadAttemptKey(ratingKey: first.ratingKey,
                                            attemptID: DownloadAttemptID(uuid: UUID()))
            #expect(store.createAttemptOwnedRecord(
                record(second, metadata: profiled("1080p")), attemptID: second.attemptID)
                == .committed(second))
            #expect(store.truncationStrikes(for: second) == 1)

            // An ordinary removal (Delete) carries nothing, even with strikes on the row.
            #expect(store.recordTruncationStrike(for: second, outcomeID: "B-1") == 2)
            #expect(store.remove(for: second) == .applied)
            let third = DownloadAttemptKey(ratingKey: first.ratingKey,
                                           attemptID: DownloadAttemptID(uuid: UUID()))
            #expect(store.createAttemptOwnedRecord(
                record(third, metadata: profiled("1080p")), attemptID: third.attemptID)
                == .committed(third))
            #expect(store.truncationStrikes(for: third) == 0)
        }
    }

    @Test("Re-finalizing the same body after a relaunch replays its truncation, not a second strike")
    func refinalizedBodyReplaysItsOutcome() throws {
        try withDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            let key = try seed("plex:strike", status: .downloading, metadata: profiled("1080p"),
                               in: store)
            _ = store.submitLifecycleEvent(.bodyAtWorking, for: key,
                                           facts: DownloadRowFacts(route: .staticRange))
            let source = try #require(store.truncationSourceKey(for: key))
            let id = BackgroundDownloadSession.finalizeOutcomeID(for: key, bytes: 4_096)
            // A fresh finalizer run over the same bytes names the same outcome.
            #expect(id == BackgroundDownloadSession.finalizeOutcomeID(for: key, bytes: 4_096))
            #expect(id != BackgroundDownloadSession.finalizeOutcomeID(for: key, bytes: 4_097))

            guard case .accepted = store.submitLifecycleEvent(
                .finalizeOutcome(id: id, outcome: .truncated, source: source), for: key) else {
                Issue.record("Expected the first truncation to apply"); return
            }
            // Strike and verdict commit together.
            #expect(store.truncationStrikes(for: key) == 1)
            #expect(store.lifecycleState(for: key)?.lifecycle == .failed)

            _ = store.submitLifecycleEvent(.bodyAtWorking, for: key,
                                           facts: DownloadRowFacts(route: .staticRange))
            #expect(store.submitLifecycleEvent(
                .finalizeOutcome(id: id, outcome: .truncated, source: source), for: key)
                == .rejected(.replayed))
            #expect(store.truncationStrikes(for: key) == 1)
        }
    }

    @Test("A probe-miss publication records its unverified reason")
    func probeMissRecordsUnverifiedReason() throws {
        try withDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            let key = try seed("plex:miss", status: .downloading, in: store)
            _ = store.submitLifecycleEvent(.bodyAtWorking, for: key,
                                           facts: DownloadRowFacts(route: .staticRange))
            let source = try #require(store.truncationSourceKey(for: key))
            guard case .accepted(let effects, _) = store.submitLifecycleEvent(
                .finalizeOutcome(id: "miss", outcome: .unverified(reason: "probe_timeout"),
                                 source: source), for: key) else {
                Issue.record("Expected the probe miss to apply"); return
            }
            #expect(effects == [.publish(.unverified)])
            let state = try #require(store.lifecycleState(for: key))
            #expect(state.lifecycle == .finalizing, "lifecycle waits for the promotion commit")
            #expect(state.history.unverifiedReason == .probeMiss("probe_timeout"))
        }
    }

    @Test("Retry Recovery admits an index that was unreadable at launch once it reads cleanly (B16)")
    func retryRecoveryReprobesARepairedIndex() throws {
        try withDirectory { directory in
            let index = directory.appendingPathComponent("index.json")
            try Data("not-json".utf8).write(to: index)
            let store = DownloadStore(baseDirectory: directory)
            #expect(store.startupIndexAdmission() == .unreadableIndex)
            // Still unreadable: Retry keeps it blocked and leaves the bytes alone.
            #expect(store.reprobeBlockedIndex() == .unreadableIndex)
            #expect(try Data(contentsOf: index) == Data("not-json".utf8))

            // The bytes become readable (for example protected data unlocked, or a repair).
            let id = DownloadAttemptID(uuid: UUID())
            let row: [String: Any] = [
                "ratingKey": "plex:kept", "attemptID": id.rawValue, "title": "Kept",
                "relativePath": "kept.mp4", "bytes": 1, "progress": 1, "status": "complete",
                "metadata": ["ratingKey": "plex:kept", "title": "Kept", "type": "movie",
                             "downloadAttemptID": id.rawValue],
            ]
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 4, "rows": [row]])
                .write(to: index)
            #expect(store.reprobeBlockedIndex() == .current)
            #expect(store.record(for: "plex:kept")?.status == .complete)
        }
    }

    @Test("An indeterminate season commit is its own state and clears once memory re-commits (B21)")
    func indeterminateSeasonCommitRecovers() throws {
        try withDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            _ = try seed("plex:season", status: .complete, in: store)
            store.markSeasonCommitIndeterminateForTesting()
            #expect(store.startupIndexAdmission() == .seasonCommitIndeterminate)
            #expect(store.reprobeBlockedIndex() == .current)
            #expect(store.record(for: "plex:season")?.status == .complete)
        }
    }

    private func profiled(_ profile: String) -> OfflineMetadata {
        var metadata = OfflineMetadata(ratingKey: "plex:strike", title: "Item", type: "movie")
        metadata.requestedProfileLabel = profile
        metadata.backendServerID = "machine-1"
        return metadata
    }

    private func record(_ key: DownloadAttemptKey, metadata: OfflineMetadata) -> DownloadRecord {
        DownloadRecord(ratingKey: key.ratingKey, attemptID: key.attemptID, title: "Item",
                       localURL: URL(fileURLWithPath: "/dev/null"), status: .queued,
                       metadata: metadata)
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
