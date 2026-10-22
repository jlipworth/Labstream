#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

/// P3a store pins: additive lifecycle/history in the v4 envelope, structural derivation for rows
/// written without them, and rollback compatibility with binaries that drop them (R2-3, R2-6).
@Suite("Download lifecycle store compatibility", .downloadTestFiles, .serialized)
struct DownloadLifecycleStoreTests {
    @Test("Lifecycle is written next to the derived status and survives a reload")
    func lifecycleIsPersisted() throws {
        try withDirectory { directory in
            let store = DownloadTestFiles.store(baseDirectory: directory)
            let key = try seed("plex:one", status: .paused, in: store)
            let index = try indexRows(directory)
            #expect(index.first?["lifecycle"] as? String == "paused")
            #expect(index.first?["status"] as? String == "paused")
            #expect(DownloadTestFiles.store(baseDirectory: directory).lifecycleState(for: key)?.lifecycle
                    == .paused)
        }
    }

    @Test("A row re-encoded by an older binary derives its lifecycle structurally")
    func olderBinaryReencodeDerivesStructurally() throws {
        try withDirectory { directory in
            let store = DownloadTestFiles.store(baseDirectory: directory)
            let key = try seed("plex:two", status: .complete, in: store)
            // An older binary drops the unknown keys when it rewrites the row.
            try rewriteRows(directory) { row in
                row.removeValue(forKey: "lifecycle")
                row.removeValue(forKey: "history")
            }
            let reloaded = DownloadTestFiles.store(baseDirectory: directory)
            #expect(reloaded.lifecycleState(for: key)?.lifecycle == .complete)
            #expect(reloaded.record(for: key)?.status == .complete)
        }
    }

    @Test("A status changed by an older binary wins over a stale lifecycle")
    func staleLifecycleYieldsToOlderBinaryStatus() throws {
        try withDirectory { directory in
            let store = DownloadTestFiles.store(baseDirectory: directory)
            let key = try seed("plex:three", status: .paused, in: store)
            try rewriteRows(directory) { row in row["status"] = "failed" }
            let reloaded = DownloadTestFiles.store(baseDirectory: directory)
            #expect(reloaded.lifecycleState(for: key)?.lifecycle == .failed)
        }
    }

    /// P4.8: the legacy season flag is absorbed on load and no longer written. A queued first
    /// start becomes `planned` (shown `.queued`); a failed row the planner queued for retry stays
    /// failed with a `retryRequested` intent; a paused row keeps its pause (B65).
    @Test("The legacy season flag becomes lifecycle and an admission intent")
    func legacySeasonFlagIsAbsorbedIntoLifecycle() throws {
        try withDirectory { directory in
            let store = DownloadTestFiles.store(baseDirectory: directory)
            var metadata = OfflineMetadata(ratingKey: "plex:ep", title: "Ep", type: "episode")
            metadata.seasonPlannerPendingAdmission = true
            let queued = try seed("plex:ep", status: .queued, metadata: metadata, in: store)
            var retryMetadata = OfflineMetadata(ratingKey: "plex:retry", title: "Ep", type: "episode")
            retryMetadata.seasonPlannerPendingAdmission = true
            let failed = try seed("plex:retry", status: .failed, metadata: retryMetadata, in: store)
            var pausedMetadata = OfflineMetadata(ratingKey: "plex:paused", title: "Ep", type: "episode")
            pausedMetadata.seasonPlannerPendingAdmission = true
            let paused = try seed("plex:paused", status: .paused, metadata: pausedMetadata, in: store)

            #expect(store.lifecycleState(for: queued)?.lifecycle == .planned)
            #expect(store.lifecycleState(for: queued)?.history.admissionIntent == .seasonPlanned)
            #expect(store.record(for: queued)?.status == .queued)
            #expect(store.lifecycleState(for: failed)?.lifecycle == .failed)
            #expect(store.lifecycleState(for: failed)?.history.admissionIntent == .retryRequested)
            #expect(store.lifecycleState(for: paused)?.lifecycle == .paused)
            #expect(store.lifecycleState(for: paused)?.history.admissionIntent == .seasonPlanned)
            for row in try indexRows(directory) {
                let metadataObject = row["metadata"] as? [String: Any]
                #expect(metadataObject?["seasonPlannerPendingAdmission"] == nil)
            }
            let reloaded = DownloadTestFiles.store(baseDirectory: directory)
            #expect(reloaded.lifecycleState(for: queued)?.lifecycle == .planned)
            #expect(reloaded.lifecycleState(for: failed)?.history.admissionIntent == .retryRequested)
        }
    }

    /// P4.8 precedence: a stale flag on a row whose start already ran (bytes, a Plex queue item)
    /// never sends it back through a first start.
    @Test("A stale season flag never overrides start evidence")
    func staleFlagNeverOverridesStartEvidence() throws {
        try withDirectory { directory in
            let store = DownloadTestFiles.store(baseDirectory: directory)
            var queued = OfflineMetadata(ratingKey: "plex:prep", title: "Ep", type: "episode")
            queued.seasonPlannerPendingAdmission = true
            queued.optimizeQueueTitle = "Ep [Labstream 0000]"
            let prep = try seed("plex:prep", status: .queued, metadata: queued, in: store)
            var paused = OfflineMetadata(ratingKey: "plex:partial", title: "Ep", type: "episode")
            paused.seasonPlannerPendingAdmission = true
            paused.resumeDataRelativePath = "partial.resume"
            let partial = try seed("plex:partial", status: .paused, metadata: paused, in: store)
            #expect(store.lifecycleState(for: prep)?.lifecycle == .admitted)
            #expect(store.lifecycleState(for: prep)?.history.admissionIntent == nil)
            #expect(store.lifecycleState(for: partial)?.lifecycle == .paused)
            #expect(store.lifecycleState(for: partial)?.history.admissionIntent == nil)
        }
    }

    /// A P3b index wrote a flagged retry row as `planned` + `.failed`; it loads as a failed row
    /// waiting for its retry.
    @Test("A P3b planned retry row loads as failed with a retry request")
    func p3bPlannedRetryRowLoadsAsFailedWaiting() throws {
        try withDirectory { directory in
            let store = DownloadTestFiles.store(baseDirectory: directory)
            let key = try seed("plex:ep", status: .failed,
                               metadata: OfflineMetadata(ratingKey: "plex:ep", title: "Ep",
                                                         type: "episode"), in: store)
            try rewriteRows(directory) { row in
                row["lifecycle"] = "planned"
                var metadata = row["metadata"] as? [String: Any] ?? [:]
                metadata["seasonPlannerPendingAdmission"] = true
                row["metadata"] = metadata
            }
            let reloaded = DownloadTestFiles.store(baseDirectory: directory)
            #expect(reloaded.lifecycleState(for: key)?.lifecycle == .failed)
            #expect(reloaded.lifecycleState(for: key)?.history.admissionIntent == .retryRequested)
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
            let store = DownloadTestFiles.store(baseDirectory: directory)
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
            let store = DownloadTestFiles.store(baseDirectory: directory)
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
            let reloaded = DownloadTestFiles.store(baseDirectory: directory)
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
            let store = DownloadTestFiles.store(baseDirectory: directory)
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
            let relaunched = DownloadTestFiles.store(baseDirectory: directory)
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
            let store = DownloadTestFiles.store(baseDirectory: directory)
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
            let store = DownloadTestFiles.store(baseDirectory: directory)
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
            let store = DownloadTestFiles.store(baseDirectory: directory)
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
            let store = DownloadTestFiles.store(baseDirectory: directory)
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

    @Test("Reconcile deletes only the exact bytes it condemned, never bytes written meanwhile")
    func reconcileDeletionIsFencedByFileIdentity() throws {
        try withDirectory { directory in
            var metadata = OfflineMetadata(ratingKey: "plex:race", title: "Race", type: "movie")
            metadata.resumeMode = .staticByteRange
            // Control: an empty condemned working file is deleted with its failed row.
            let control = DownloadTestFiles.store(baseDirectory: directory)
            let controlKey = try seed("plex:race", status: .downloading, metadata: metadata,
                                      in: control)
            let controlBody = try #require(control.attemptWorkingFileURL(for: controlKey))
            try Data().write(to: controlBody)
            control.reconcile(liveRatingKeys: [], snapshotRatingKeys: [controlKey.ratingKey])
            #expect(control.record(for: controlKey)?.status == .failed)
            #expect(!FileManager.default.fileExists(atPath: controlBody.path))

            // Race: Range I/O writes the file between the commit and the deletion.
            var raceMetadata = metadata
            raceMetadata.ratingKey = "plex:race2"
            let key = try seed("plex:race2", status: .downloading, metadata: raceMetadata,
                               in: control)
            let body = try #require(control.attemptWorkingFileURL(for: key))
            try Data().write(to: body)
            control.reconcileBeforeDeletionsForTesting = {
                try? Data(repeating: 5, count: 4_096).write(to: body)
            }
            control.reconcile(liveRatingKeys: [], snapshotRatingKeys: [key.ratingKey])
            #expect(control.record(for: key)?.status == .failed)
            #expect((try? Data(contentsOf: body))?.count == 4_096, "new bytes are never deleted")
        }
    }

    @Test("A condemned truncated body leaves its working path at once and never seeds a Retry")
    func condemnedTruncatedBodyNeverSeedsARetry() async throws {
        try await withAsyncDirectory { directory in
            final class SwitchableWriter: @unchecked Sendable {
                var failing = false
            }
            let writer = SwitchableWriter()
            let store = DownloadTestFiles.store(
                baseDirectory: directory,
                indexPersistence: .init(atomicWrite: { data, url in
                    if writer.failing { throw CocoaError(.fileWriteOutOfSpace) }
                    try data.write(to: url, options: .atomic)
                }))
            var metadata = profiled("1080p")
            metadata.resumeMode = .staticByteRange
            let key = try seed("plex:strike", status: .downloading, metadata: metadata, in: store)
            let body = try #require(store.attemptWorkingFileURL(for: key))
            try Data(repeating: 4, count: 8_192).write(to: body)
            _ = store.submitLifecycleEvent(.bodyAtWorking, for: key,
                                           facts: DownloadRowFacts(route: .staticRange))
            let source = try #require(store.truncationSourceKey(for: key))

            // The verdict cannot persist; the body is condemned anyway and leaves the path.
            writer.failing = true
            guard case .accepted(_, let ticket) = store.submitLifecycleEvent(
                .finalizeOutcome(id: "t#body-8192", outcome: .truncated, source: source),
                for: key) else {
                Issue.record("Expected the truncation verdict to apply"); return
            }
            #expect(store.lifecycleState(for: key)?.history.lastFailure == .truncated)
            let condemned = try #require(store.condemnWorkingBody(at: body, for: key))
            #expect(!FileManager.default.fileExists(atPath: body.path))
            #expect(FileManager.default.fileExists(atPath: condemned.path))

            // A later failure overwrites the reason; the body still cannot come back.
            writer.failing = false
            _ = store.submitLifecycleEvent(.retryRejected(.sourceMissing), for: key,
                                           facts: DownloadRowFacts(route: .staticRange))
            let retry = DownloadAttemptKey(ratingKey: key.ratingKey,
                                           attemptID: DownloadAttemptID(uuid: UUID()))
            #expect(store.createAttemptOwnedRecord(
                record(retry, metadata: metadata), attemptID: retry.attemptID,
                replacing: key.attemptID) == .committed(retry))
            #expect(store.record(for: retry)?.bytes == 0)
            let retryBody = try #require(store.attemptWorkingFileURL(for: retry))
            #expect(!FileManager.default.fileExists(atPath: retryBody.path))
            #expect(store.truncationStrikes(for: retry) == 1, "the strike itself is inherited")

            // The unproven verdict still frees the space once its bounded wait ends.
            _ = await store.deleteCondemnedBody(at: condemned, afterCommitOf: ticket, timeout: 1)
            #expect(!FileManager.default.fileExists(atPath: condemned.path))
        }
    }

    @Test("A condemned body that could not be moved still never seeds a Retry")
    func condemnationFenceHoldsWithoutTheRename() async throws {
        try await withAsyncDirectory { directory in
            let store = DownloadTestFiles.store(baseDirectory: directory)
            var metadata = profiled("1080p")
            metadata.resumeMode = .staticByteRange
            let key = try seed("plex:strike", status: .downloading, metadata: metadata, in: store)
            let body = try #require(store.attemptWorkingFileURL(for: key))
            try Data(repeating: 4, count: 8_192).write(to: body)
            _ = store.submitLifecycleEvent(.bodyAtWorking, for: key,
                                           facts: DownloadRowFacts(route: .staticRange))
            let source = try #require(store.truncationSourceKey(for: key))
            _ = store.submitLifecycleEvent(
                .finalizeOutcome(id: "t#body-8192", outcome: .truncated, source: source), for: key)
            // No rename happened (as if it failed); a later failure overwrites the reason.
            _ = store.submitLifecycleEvent(.retryRejected(.sourceMissing), for: key,
                                           facts: DownloadRowFacts(route: .staticRange))
            #expect(FileManager.default.fileExists(atPath: body.path))
            #expect(store.lifecycleFacts(for: key).checkpoint == .none)
            // Every same-attempt reader sees no body: no checkpoint, no recovery evidence, no
            // promotion source.
            // An empty usable checkpoint (not a missing owner), so backend-ready resume restarts.
            #expect(store.durableStaticRangeCheckpointSize(for: key) == 0)
            #expect(store.attemptWorkingFileURL(for: key) == nil)
            #expect(store.attemptWorkingFileLayout(for: key) == nil)
            // A deferred Retry still gets a usable answer: an empty checkpoint, applied to the
            // row, so the restart-from-zero intent survives (never "stale owner").
            #expect(await store.resolveStaticCheckpoint(
                store.submitStaticRangeCheckpointReset(for: key), deadline: .after(30)) == .applied(bytes: 0))
            #expect(store.record(for: key)?.bytes == 0)
            #expect(FileManager.default.fileExists(atPath: body.path), "condemned bytes untouched")
            #expect(store.staticRangeRecoveryEvidence().allSatisfy { $0.ratingKey != key.ratingKey })
            if case .immediate = store.submitValidatedPromotion(
                for: key, terminalStatus: .unverified) {} else {
                Issue.record("a condemned body must never be promoted")
            }

            let retry = DownloadAttemptKey(ratingKey: key.ratingKey,
                                           attemptID: DownloadAttemptID(uuid: UUID()))
            #expect(store.createAttemptOwnedRecord(
                record(retry, metadata: metadata), attemptID: retry.attemptID,
                replacing: key.attemptID) == .committed(retry))
            #expect(store.record(for: retry)?.bytes == 0)
            let retryBody = try #require(store.attemptWorkingFileURL(for: retry))
            #expect(!FileManager.default.fileExists(atPath: retryBody.path))
        }
    }

    @Test("A committed truncation verdict deletes exactly the condemned body")
    func committedTruncationDeletesTheCondemnedBody() async throws {
        try await withAsyncDirectory { directory in
            let store = DownloadTestFiles.store(baseDirectory: directory)
            let key = try seed("plex:strike", status: .downloading, metadata: profiled("1080p"),
                               in: store)
            let body = try #require(store.attemptWorkingFileURL(for: key))
            try Data(repeating: 4, count: 4_096).write(to: body)
            _ = store.submitLifecycleEvent(.bodyAtWorking, for: key,
                                           facts: DownloadRowFacts(route: .staticRange))
            let source = try #require(store.truncationSourceKey(for: key))
            guard case .accepted(_, let ticket) = store.submitLifecycleEvent(
                .finalizeOutcome(id: "t#body-4096", outcome: .truncated, source: source),
                for: key) else {
                Issue.record("Expected the truncation verdict to apply"); return
            }
            // A stale owner cannot condemn the path.
            let stale = DownloadAttemptKey(ratingKey: key.ratingKey,
                                           attemptID: DownloadAttemptID(uuid: UUID()))
            #expect(store.condemnWorkingBody(at: body, for: stale) == nil)
            let condemned = try #require(store.condemnWorkingBody(at: body, for: key))
            #expect(await store.deleteCondemnedBody(at: condemned, afterCommitOf: ticket))
            #expect(!FileManager.default.fileExists(atPath: condemned.path))
        }
    }

    @Test("A Retry that removes the failed row first still inherits its strikes; Delete does not")
    func retryRemovalCarriesStrikes() throws {
        try withDirectory { directory in
            let store = DownloadTestFiles.store(baseDirectory: directory)
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
            let store = DownloadTestFiles.store(baseDirectory: directory)
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

            // The condemned body can never re-enter finalization to be counted again.
            #expect(store.submitLifecycleEvent(.bodyAtWorking, for: key,
                                               facts: DownloadRowFacts(route: .staticRange))
                == .rejected(.illegal))
            #expect(store.submitLifecycleEvent(
                .finalizeOutcome(id: id, outcome: .truncated, source: source), for: key)
                == .rejected(.illegal))
            #expect(store.truncationStrikes(for: key) == 1)
        }
    }

    @Test("A probe-miss publication records its unverified reason")
    func probeMissRecordsUnverifiedReason() throws {
        try withDirectory { directory in
            let store = DownloadTestFiles.store(baseDirectory: directory)
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
            let store = DownloadTestFiles.store(baseDirectory: directory)
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
            let store = DownloadTestFiles.store(baseDirectory: directory)
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
        let parent = DownloadTestFiles.temporaryDirectory
            .appendingPathComponent("lifecycle-store-\(UUID().uuidString)", isDirectory: true)
        let directory = parent.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try await body(directory)
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let parent = DownloadTestFiles.temporaryDirectory
            .appendingPathComponent("lifecycle-store-\(UUID().uuidString)", isDirectory: true)
        let directory = parent.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try body(directory)
    }
}
#endif
