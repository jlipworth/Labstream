import Foundation
import PMSKit
import Synchronization
import Testing
@testable import Labstream

struct DownloadStorePersistenceTests {
    @Test func seasonPlanRowsCommitInOneDurableSnapshot() throws {
        try withTemporaryDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            let records = ["episode-1", "episode-2"].map { key in
                DownloadRecord(
                    ratingKey: key, attemptID: .generated(), title: key,
                    localURL: directory.appendingPathComponent("\(key).mp4"),
                    status: .queued,
                    metadata: OfflineMetadata(
                        ratingKey: key, title: key, type: "episode",
                        seasonPlannerPendingAdmission: true))
            }
            #expect(store.createSeasonPlannedRecordsAtomically(records))
            let restored = DownloadStore(baseDirectory: directory)
            #expect(Set(restored.records.map(\.ratingKey)) == ["episode-1", "episode-2"])
            #expect(restored.records.allSatisfy {
                $0.metadata?.seasonPlannerPendingAdmission == true && $0.status == .queued
            })
        }
    }

    @Test func seasonPlanPersistenceFailureStartsWithNoPartialRows() throws {
        try withTemporaryDirectory { directory in
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
            let record = DownloadRecord(
                ratingKey: "episode-fail", attemptID: .generated(), title: "Episode",
                localURL: directory.appendingPathComponent("episode-fail.mp4"),
                status: .queued,
                metadata: OfflineMetadata(ratingKey: "episode-fail", title: "Episode",
                                          type: "episode", seasonPlannerPendingAdmission: true))
            #expect(!store.createSeasonPlannedRecordsAtomically([record]))
            #expect(store.records.isEmpty)
        }
    }

    @Test func seasonPlanNewRowsAndExactRetriesCommitInOneSnapshot() throws {
        try withTemporaryDirectory { directory in
            let retryID = DownloadAttemptID.generated()
            let retryKey = DownloadAttemptKey(ratingKey: "episode-retry", attemptID: retryID)
            let store = DownloadStore(baseDirectory: directory)
            let failed = DownloadRecord(
                ratingKey: retryKey.ratingKey, attemptID: retryID, title: "Retry",
                localURL: directory.appendingPathComponent("retry.mp4"), status: .failed,
                metadata: OfflineMetadata(ratingKey: retryKey.ratingKey, title: "Retry", type: "episode"))
            #expect(store.createAttemptOwnedRecord(failed, attemptID: retryID) == .committed(retryKey))
            let inserted = DownloadRecord(
                ratingKey: "episode-new", attemptID: .generated(), title: "New",
                localURL: directory.appendingPathComponent("new.mp4"), status: .queued,
                metadata: OfflineMetadata(ratingKey: "episode-new", title: "New", type: "episode",
                                          seasonPlannerPendingAdmission: true))

            #expect(store.applySeasonPlanAtomically(
                newRecords: [inserted], retryAttempts: [retryKey]) == .applied(inserted: 1, retried: 1))
            let restored = DownloadStore(baseDirectory: directory)
            #expect(restored.record(for: inserted.ratingKey)?.metadata?.seasonPlannerPendingAdmission == true)
            #expect(restored.record(for: retryKey.ratingKey)?.metadata?.seasonPlannerPendingAdmission == true)
        }
    }

    @Test func seasonPlanStaleRetryRejectsEveryMutation() throws {
        try withTemporaryDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            let inserted = DownloadRecord(
                ratingKey: "episode-new", attemptID: .generated(), title: "New",
                localURL: directory.appendingPathComponent("new.mp4"), status: .queued,
                metadata: OfflineMetadata(ratingKey: "episode-new", title: "New", type: "episode",
                                          seasonPlannerPendingAdmission: true))
            let stale = DownloadAttemptKey(ratingKey: "episode-retry", attemptID: .generated())

            #expect(store.applySeasonPlanAtomically(
                newRecords: [inserted], retryAttempts: [stale]) == .staleInput)
            #expect(store.records.isEmpty)
        }
    }

    @Test func seasonPlanPostReplaceFailurePublishesTheExactDurableCandidate() throws {
        try withTemporaryDirectory { directory in
            let writes = PostReplaceFailureHarness()
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try writes.write(data, to: url) })
            let inserted = DownloadRecord(
                ratingKey: "episode-ambiguous", attemptID: .generated(), title: "Ambiguous",
                localURL: directory.appendingPathComponent("ambiguous.mp4"), status: .queued,
                metadata: OfflineMetadata(ratingKey: "episode-ambiguous", title: "Ambiguous",
                                          type: "episode", seasonPlannerPendingAdmission: true))

            #expect(store.applySeasonPlanAtomically(
                newRecords: [inserted], retryAttempts: []) == .applied(inserted: 1, retried: 0))
            #expect(store.record(for: inserted.ratingKey) != nil)
            #expect(DownloadStore(baseDirectory: directory).record(for: inserted.ratingKey) != nil)
        }
    }

    /// The failure compensation runs off-lock: the withdrawn plan must remove inserted rows and
    /// restore the retry row's prior admission flag, in memory and in durable authority.
    @Test func seasonPlanPersistenceFailureRestoresRetryRowAndRemovesInsertedRow() throws {
        try withTemporaryDirectory { directory in
            let retryID = DownloadAttemptID.generated()
            let retryKey = DownloadAttemptKey(ratingKey: "episode-retry", attemptID: retryID)
            let seed = DownloadStore(baseDirectory: directory)
            let failed = DownloadRecord(
                ratingKey: retryKey.ratingKey, attemptID: retryID, title: "Retry",
                localURL: directory.appendingPathComponent("retry.mp4"), status: .failed,
                metadata: OfflineMetadata(ratingKey: retryKey.ratingKey, title: "Retry", type: "episode"))
            #expect(seed.createAttemptOwnedRecord(failed, attemptID: retryID) == .committed(retryKey))

            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
            let inserted = DownloadRecord(
                ratingKey: "episode-new", attemptID: .generated(), title: "New",
                localURL: directory.appendingPathComponent("new.mp4"), status: .queued,
                metadata: OfflineMetadata(ratingKey: "episode-new", title: "New", type: "episode",
                                          seasonPlannerPendingAdmission: true))

            #expect(store.applySeasonPlanAtomically(
                newRecords: [inserted], retryAttempts: [retryKey]) == .persistenceFailed)
            #expect(store.record(for: inserted.ratingKey) == nil)
            let retryRow = try #require(store.record(for: retryKey.ratingKey))
            #expect(retryRow.status == .failed)
            #expect(retryRow.metadata?.seasonPlannerPendingAdmission == nil)

            let restored = DownloadStore(baseDirectory: directory)
            #expect(restored.record(for: inserted.ratingKey) == nil)
            #expect(restored.record(for: retryKey.ratingKey)?.metadata?.seasonPlannerPendingAdmission == nil)
        }
    }

    /// The store lock must be free while the season plan awaits durability: readers see the plan
    /// atomically the moment it is submitted, and reads complete while the index write is stuck.
    @Test func seasonPlanDurabilityWaitDoesNotHoldTheStoreLock() async throws {
        try await withTemporaryDirectory { directory in
            let writes = FirstBlockingAtomicWriteHarness()
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try writes.write(data, to: url) })
            let inserted = DownloadRecord(
                ratingKey: "episode-blocked", attemptID: .generated(), title: "Blocked",
                localURL: directory.appendingPathComponent("blocked.mp4"), status: .queued,
                metadata: OfflineMetadata(ratingKey: "episode-blocked", title: "Blocked",
                                          type: "episode", seasonPlannerPendingAdmission: true))
            let applyReturned = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                _ = store.applySeasonPlanAtomically(newRecords: [inserted], retryAttempts: [])
                applyReturned.signal()
            }
            #expect(await waitForSignal(writes.started, timeout: 5))

            let readCompleted = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                #expect(store.record(for: inserted.ratingKey)?.status == .queued)
                readCompleted.signal()
            }
            #expect(await waitForSignal(readCompleted, timeout: 5))
            // The apply is still parked on the blocked write, not returned early.
            #expect(await waitForSignal(applyReturned, timeout: 0) == false)

            writes.release.signal()
            #expect(await waitForSignal(applyReturned, timeout: 5))
            #expect(DownloadStore(baseDirectory: directory)
                .record(for: inserted.ratingKey)?.status == .queued)
        }
    }

    @Test func mutationDoesNotReturnBeforeAtomicWriteAttemptFinishes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-store-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writeStarted = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)
        let mutationReturned = DispatchSemaphore(value: 0)
        let store = DownloadStore(
            baseDirectory: directory,
            indexPersistence: .init { data, url in
                writeStarted.signal()
                releaseWrite.wait()
                try data.write(to: url, options: .atomic)
            }
        )
        let record = makeRecord(
            ratingKey: "plex:blocked",
            title: "Blocked Write",
            directory: directory,
            bytes: 10
        )

        DispatchQueue.global(qos: .utility).async {
            store.upsert(record)
            mutationReturned.signal()
        }

        #expect(await waitForSignal(writeStarted, timeout: 1))
        #expect(!(await waitForSignal(mutationReturned, timeout: 0.02)))
        releaseWrite.signal()
        #expect(await waitForSignal(mutationReturned, timeout: 1))
    }

    @Test func freshStoreRestoresWriterBackedIndexAtSchemaV4() throws {
        try withTemporaryDirectory { directory in
            let record = makeRecord(
                ratingKey: "plex:item-1",
                title: "First Item",
                directory: directory,
                bytes: 1_024
            )

            let store = DownloadStore(baseDirectory: directory)
            store.upsert(record)

            let indexData = try Data(contentsOf: directory.appendingPathComponent("index.json"))
            let index = try #require(
                JSONSerialization.jsonObject(with: indexData) as? [String: Any]
            )
            #expect(index["schemaVersion"] as? Int == 4)

            let restored = DownloadStore(baseDirectory: directory)
            let restoredRecord = try #require(
                restored.records.first { $0.ratingKey == record.ratingKey }
            )
            #expect(restored.records.count == 1)
            #expect(restoredRecord.title == record.title)
            #expect(restoredRecord.localURL == record.localURL)
            #expect(restoredRecord.bytes == record.bytes)
            #expect(restoredRecord.status == record.status)
            #expect(restoredRecord.metadata == record.metadata)
        }
    }

    @Test func relaunchNormalizesAndPersistsLegacyPlexPreparedStaticLane() throws {
        try withTemporaryDirectory { directory in
            let ratingKey = "12345"
            let legacyHandoff = makeRecord(
                ratingKey: ratingKey,
                title: "Rendered Movie",
                directory: directory,
                bytes: 512,
                metadata: OfflineMetadata(
                    ratingKey: ratingKey,
                    title: "Rendered Movie",
                    type: "movie",
                    optimizeTargetName: "8 Mbps 1080p",
                    backendKind: .plex,
                    downloadLane: .optimize,
                    resumeMode: .staticByteRange,
                    serverPreparedVersion: true
                )
            )
            DownloadStore(baseDirectory: directory).upsert(legacyHandoff)

            let repaired = DownloadStore(baseDirectory: directory)
            #expect(repaired.record(for: ratingKey)?.metadata?.downloadLane == .original)
            #expect(repaired.record(for: ratingKey)?.metadata?.isServerPreparedVersion == true)

            // The repair is durable, not merely a presentation-time interpretation.
            let relaunched = DownloadStore(baseDirectory: directory)
            #expect(relaunched.record(for: ratingKey)?.metadata?.downloadLane == .original)
        }
    }

    @Test func rowDeletionPreparedFailurePreservesRowAndFileThenExactRetryRemovesBoth() throws {
        try withTemporaryDirectory { directory in
            let id = DownloadAttemptID(uuid: UUID())
            let key = DownloadAttemptKey(ratingKey: "plex:row-delete-prepared", attemptID: id)
            let record = makeRecord(ratingKey: key.ratingKey, title: "Delete", directory: directory,
                                    bytes: 4, metadata: OfflineMetadata(
                                        ratingKey: key.ratingKey, title: "Delete", type: "movie"))
            try Data([1, 2, 3, 4]).write(to: record.localURL)
            let writes = SelectedAtomicWriteFailureHarness(failingAttempts: [2])
            let store = DownloadStore(baseDirectory: directory,
                indexPersistence: .init { data, url in try writes.write(data, to: url) })
            #expect(store.createAttemptOwnedRecord(record, attemptID: id) == .committed(key))
            guard case .persistenceFailed = store.remove(for: key) else {
                Issue.record("expected prepared deletion persistence failure"); return
            }
            #expect(store.record(for: key) != nil)
            #expect(FileManager.default.fileExists(atPath: record.localURL.path))
            #expect(store.remove(for: key) == .applied)
            #expect(store.record(for: key) == nil)
            #expect(!FileManager.default.fileExists(atPath: record.localURL.path))
        }
    }

    @Test func joinedRowDeletionWaitersReceiveSameSuccessOutcome() async throws {
        try await withTemporaryDirectory { directory in
            let id = DownloadAttemptID(uuid: UUID())
            let key = DownloadAttemptKey(ratingKey: "plex:row-delete-joined", attemptID: id)
            let record = makeRecord(ratingKey: key.ratingKey, title: "Joined", directory: directory,
                                    bytes: 1, metadata: OfflineMetadata(
                                        ratingKey: key.ratingKey, title: "Joined", type: "movie"))
            try Data([1]).write(to: record.localURL)
            let blocker = BlockingArtifactDelete(path: record.localURL.path)
            let live = DownloadArtifactFilesystem.live
            let store = DownloadStore(baseDirectory: directory, artifactFilesystem: .init(
                writeAuthArtifact: live.writeAuthArtifact,
                removeItem: { url, fm in try blocker.remove(url, fm: fm) },
                fileExists: live.fileExists))
            #expect(store.createAttemptOwnedRecord(record, attemptID: id) == .committed(key))
            let first = store.submitRemove(for: key)
            #expect(await waitForSignal(blocker.started, timeout: 1))
            let second = store.submitRemove(for: key)
            guard case .accepted(let firstTicket) = first,
                  case .accepted(let secondTicket) = second else {
                blocker.release.signal(); Issue.record("expected joined deletion tickets"); return
            }
            #expect(firstTicket == secondTicket)
            blocker.release.signal()
            async let a = store.resolveRowDeletion(first)
            async let b = store.resolveRowDeletion(second)
            let outcomes = await [a, b]
            #expect(outcomes == [.removed(key), .removed(key)])
        }
    }

    @Test func joinedRowDeletionWaitersReceiveSameArtifactFailure() async throws {
        try await withTemporaryDirectory { directory in
            let id = DownloadAttemptID(uuid: UUID())
            let key = DownloadAttemptKey(ratingKey: "plex:row-delete-joined-failure", attemptID: id)
            let record = makeRecord(ratingKey: key.ratingKey, title: "Joined", directory: directory,
                                    bytes: 1, metadata: OfflineMetadata(
                                        ratingKey: key.ratingKey, title: "Joined", type: "movie"))
            try Data([1]).write(to: record.localURL)
            let blocker = BlockingFailingArtifactDelete(path: record.localURL.path)
            let live = DownloadArtifactFilesystem.live
            let store = DownloadStore(baseDirectory: directory, artifactFilesystem: .init(
                writeAuthArtifact: live.writeAuthArtifact,
                removeItem: { url, fm in try blocker.remove(url, fm: fm) },
                fileExists: live.fileExists))
            #expect(store.createAttemptOwnedRecord(record, attemptID: id) == .committed(key))
            let first = store.submitRemove(for: key)
            #expect(await waitForSignal(blocker.started, timeout: 1))
            let second = store.submitRemove(for: key)
            blocker.release.signal()
            async let a = store.resolveRowDeletion(first)
            async let b = store.resolveRowDeletion(second)
            let outcomes = await [a, b]
            #expect(outcomes == [
                .cleanupFailed(key, cleanupFailureCount: 1),
                .cleanupFailed(key, cleanupFailureCount: 1),
            ])
            #expect(store.record(for: key) != nil)
        }
    }

    @Test func rowDeletionRetryEpochDoesNotOverwriteUnresolvedFailure() async throws {
        try await withTemporaryDirectory { directory in
            let id = DownloadAttemptID(uuid: UUID())
            let key = DownloadAttemptKey(ratingKey: "plex:row-delete-retry-epoch", attemptID: id)
            let record = makeRecord(ratingKey: key.ratingKey, title: "Retry epoch",
                                    directory: directory, bytes: 1, metadata: OfflineMetadata(
                                        ratingKey: key.ratingKey, title: "Retry epoch", type: "movie"))
            try Data([1]).write(to: record.localURL)
            let blocker = BlockingFailOnceArtifactDelete(path: record.localURL.path)
            let live = DownloadArtifactFilesystem.live
            let store = DownloadStore(baseDirectory: directory, artifactFilesystem: .init(
                writeAuthArtifact: live.writeAuthArtifact,
                removeItem: { url, fm in try blocker.remove(url, fm: fm) },
                fileExists: live.fileExists))
            #expect(store.createAttemptOwnedRecord(record, attemptID: id) == .committed(key))
            let failedAttempt = store.submitRemove(for: key)
            #expect(await waitForSignal(blocker.started, timeout: 1))
            let failedBoundary = store.currentArtifactLifecycleWatermark()
            blocker.release.signal()
            guard case .failed(.artifact) = store.resolveArtifactSynchronouslyForTests(
                through: failedBoundary) else {
                Issue.record("expected first lifecycle attempt to fail"); return
            }

            let retryAttempt = store.submitRemove(for: key)
            guard case .accepted(let failedTicket) = failedAttempt,
                  case .accepted(let retryTicket) = retryAttempt else {
                Issue.record("expected both lifecycle attempts"); return
            }
            #expect(failedTicket.intentID == retryTicket.intentID)
            #expect(failedTicket.preparedRevision != retryTicket.preparedRevision)

            // Resolve in reverse epoch order: success B must not overwrite unresolved failure A.
            #expect(await store.resolveRowDeletion(retryAttempt) == .removed(key))
            #expect(await store.resolveRowDeletion(failedAttempt)
                == .cleanupFailed(key, cleanupFailureCount: 1))
        }
    }

    @Test func pendingRowDeletionRejectsEveryArtifactSuccessorAndPathAdoption() async throws {
        try await withTemporaryDirectory { directory in
            let id = DownloadAttemptID(uuid: UUID())
            let key = DownloadAttemptKey(ratingKey: "plex:row-delete-terminal-barrier", attemptID: id)
            let metadata = OfflineMetadata(ratingKey: key.ratingKey, title: "Barrier", type: "movie",
                                           resumeMode: .staticByteRange)
            let record = makeRecord(ratingKey: key.ratingKey, title: "Barrier", directory: directory,
                                    bytes: 1, metadata: metadata)
            try Data([1]).write(to: record.localURL)
            let blocker = BlockingArtifactDelete(path: record.localURL.path)
            let live = DownloadArtifactFilesystem.live
            let store = DownloadStore(baseDirectory: directory, artifactFilesystem: .init(
                writeAuthArtifact: live.writeAuthArtifact,
                removeItem: { url, fm in try blocker.remove(url, fm: fm) },
                fileExists: live.fileExists))
            #expect(store.createAttemptOwnedRecord(record, attemptID: id) == .committed(key))
            let deletion = store.submitRemove(for: key)
            #expect(await waitForSignal(blocker.started, timeout: 1))
            let terminalWatermark = store.currentArtifactLifecycleWatermark()

            #expect(store.attemptWorkingFileLayout(for: key) == nil)
            #expect(store.attemptWorkingFileURL(for: key) == nil)
            #expect(store.submitResumeData(for: key, Data([2])) == .staleOrMissing)
            #expect(store.submitClearResumeData(for: key) == .staleOrMissing)
            let held = OfflineHeldRangeSegment(offset: 0, length: 1, relativePath: "late-held.body")
            #expect(store.submitHeldRangeSegment(for: key, segment: held) == .staleOrMissing)
            #expect(store.submitHeldRangeSegmentsRemoval(for: key, offsets: nil) == .staleOrMissing)
            #expect(store.takeHeldRangeSegments(for: key) == .staleOrMissing)
            #expect(store.submitStaticRangeCheckpointReset(for: key) == .staleOrMissing)
            #expect(store.submitMetadata(for: key) { $0.posterRelativePath = "late-poster.jpg" }
                == .staleOrMissing)
            let stable = directory.appendingPathComponent("late-side.jpg")
            let staging = try #require(store.attemptStagingURL(for: key, stableURL: stable))
            try Data([3]).write(to: staging)
            #expect(store.promoteAttemptStagingFile(for: key, stagingURL: staging, to: stable)
                == .staleOrMissingOwner)
            try? FileManager.default.removeItem(at: staging) // production promotion owns this defer

            #expect(store.currentArtifactLifecycleWatermark() == terminalWatermark)
            #expect(store.metadata(for: key.ratingKey)?.posterRelativePath == nil)
            #expect(!FileManager.default.fileExists(atPath: stable.path))
            blocker.release.signal()
            #expect(await store.resolveRowDeletion(deletion) == .removed(key))
        }
    }

    @Test(arguments: [false, true])
    func rowDeletionQueuedBehindResumePredecessorAdvancesAfterSuccessOrFailure(
        predecessorFails: Bool
    ) async throws {
        try await withTemporaryDirectory { directory in
            let id = DownloadAttemptID(uuid: UUID())
            let key = DownloadAttemptKey(ratingKey: "plex:delete-behind-resume-\(predecessorFails)",
                                         attemptID: id)
            let record = makeRecord(ratingKey: key.ratingKey, title: "Queued delete",
                                    directory: directory, bytes: 1, metadata: OfflineMetadata(
                                        ratingKey: key.ratingKey, title: "Queued delete", type: "movie"))
            try Data([1]).write(to: record.localURL)
            let blocker = BlockingArtifactWrite(shouldFail: predecessorFails)
            let live = DownloadArtifactFilesystem.live
            let store = DownloadStore(baseDirectory: directory, artifactFilesystem: .init(
                writeAuthArtifact: { data, url, fm in try blocker.write(data, url: url, fm: fm) },
                removeItem: live.removeItem, fileExists: live.fileExists,
                syncParentDirectory: live.syncParentDirectory))
            #expect(store.createAttemptOwnedRecord(record, attemptID: id) == .committed(key))
            let predecessor = store.submitResumeData(for: key, Data([4, 5]))
            #expect(await waitForSignal(blocker.started, timeout: 1))
            let deletion = store.submitRemove(for: key)
            guard case .accepted = deletion else {
                blocker.release.signal(); Issue.record("terminal deletion must queue"); return
            }
            let joinedDeletion = store.submitRemove(for: key)
            guard case .accepted(let firstDeletionTicket) = deletion,
                  case .accepted(let joinedDeletionTicket) = joinedDeletion else {
                blocker.release.signal(); Issue.record("repeat delete must join terminal tail"); return
            }
            #expect(firstDeletionTicket == joinedDeletionTicket)
            #expect(!store.ownsAttempt(key))
            #expect(store.submitResumeData(for: key, Data([6])) == .staleOrMissing)
            blocker.release.signal()
            async let firstOutcome = store.resolveRowDeletion(deletion)
            async let joinedOutcome = store.resolveRowDeletion(joinedDeletion)
            #expect(await [firstOutcome, joinedOutcome] == [.removed(key), .removed(key)])
            if predecessorFails {
                guard case .accepted(let ticket) = predecessor else { return }
                guard case .failed(.artifact) = store.resolveArtifactSynchronously(ticket) else {
                    Issue.record("expected predecessor artifact failure"); return
                }
            }
            #expect(store.record(for: key) == nil)
            // D3: the retired failed head (and the deleted row) are permanently abandoned —
            // their coordinator entries must not poison every later lifecycle boundary.
            #expect(store.resolveArtifactSynchronouslyForTests(
                through: store.currentArtifactLifecycleWatermark()) == .completed)
        }
    }

    @Test func failedNoChangeResumeClearBarrierDoesNotPoisonLaterBoundaries() throws {
        try withTemporaryDirectory { directory in
            let id = DownloadAttemptID(uuid: UUID())
            let key = DownloadAttemptKey(ratingKey: "plex:clear-noop-barrier", attemptID: id)
            let record = makeRecord(ratingKey: key.ratingKey, title: "Clear", directory: directory,
                                    bytes: 1, metadata: OfflineMetadata(
                                        ratingKey: key.ratingKey, title: "Clear", type: "movie"))
            try Data([1]).write(to: record.localURL)
            let writes = SelectedAtomicWriteFailureHarness(failingAttempts: [2])
            let store = DownloadStore(baseDirectory: directory,
                indexPersistence: .init { data, url in try writes.write(data, to: url) })
            #expect(store.createAttemptOwnedRecord(record, attemptID: id) == .committed(key))
            // No resume blob exists, so the clear takes the no-change branch: a one-shot
            // persistence barrier under a random intentID that is never re-registered.
            guard case .persistenceFailed = store.clearResumeData(for: key) else {
                Issue.record("expected one-shot barrier persistence failure"); return
            }
            // D3: the abandoned one-shot failure must not poison every later boundary.
            #expect(store.resolveArtifactSynchronouslyForTests(
                through: store.currentArtifactLifecycleWatermark()) == .completed)
        }
    }

    @Test func rowDeletionDirectorySyncFailureRetainsIntentForRelaunch() throws {
        try withTemporaryDirectory { directory in
            let id = DownloadAttemptID(uuid: UUID())
            let key = DownloadAttemptKey(ratingKey: "plex:delete-dir-sync", attemptID: id)
            let record = makeRecord(ratingKey: key.ratingKey, title: "Sync", directory: directory,
                                    bytes: 1, metadata: OfflineMetadata(
                                        ratingKey: key.ratingKey, title: "Sync", type: "movie"))
            try Data([1]).write(to: record.localURL)
            let live = DownloadArtifactFilesystem.live
            let store = DownloadStore(baseDirectory: directory, artifactFilesystem: .init(
                writeAuthArtifact: live.writeAuthArtifact, removeItem: live.removeItem,
                fileExists: live.fileExists,
                syncParentDirectory: { _ in throw CocoaError(.fileWriteOutOfSpace) }))
            #expect(store.createAttemptOwnedRecord(record, attemptID: id) == .committed(key))
            guard case .cleanupFailed = store.resolveRowDeletionSynchronously(
                store.submitRemove(for: key)) else {
                Issue.record("directory sync must fail deletion lifecycle"); return
            }
            #expect(store.record(for: key) != nil)
            #expect(!FileManager.default.fileExists(atPath: record.localURL.path))
            let relaunched = DownloadStore(baseDirectory: directory)
            #expect(relaunched.resolveArtifactSynchronouslyForTests(
                through: relaunched.currentArtifactLifecycleWatermark()) == .completed)
            #expect(relaunched.record(for: key) == nil)
        }
    }

    @Test func rowDeletionTransitionFailureIsObservableAndRetryRestartsPredecessor() async throws {
        try await withTemporaryDirectory { directory in
            let id = DownloadAttemptID(uuid: UUID())
            let key = DownloadAttemptKey(ratingKey: "plex:delete-transition-retry", attemptID: id)
            let record = makeRecord(ratingKey: key.ratingKey, title: "Transition",
                                    directory: directory, bytes: 1, metadata: OfflineMetadata(
                                        ratingKey: key.ratingKey, title: "Transition", type: "movie"))
            try Data([1]).write(to: record.localURL)
            let writes = SelectedAtomicWriteFailureHarness(failingAttempts: [4])
            let artifactWrite = BlockingFailOnceArtifactWrite()
            let live = DownloadArtifactFilesystem.live
            let store = DownloadStore(baseDirectory: directory,
                indexPersistence: .init { data, url in try writes.write(data, to: url) },
                artifactFilesystem: .init(
                    writeAuthArtifact: { data, url, fm in
                        try artifactWrite.write(data, url: url, fm: fm)
                    }, removeItem: live.removeItem, fileExists: live.fileExists,
                    syncParentDirectory: live.syncParentDirectory))
            #expect(store.createAttemptOwnedRecord(record, attemptID: id) == .committed(key))
            _ = store.submitResumeData(for: key, Data([8]))
            #expect(await waitForSignal(artifactWrite.started, timeout: 1))
            let deletion = store.submitRemove(for: key)
            artifactWrite.release.signal()
            guard case .persistenceFailed = await store.resolveRowDeletion(deletion) else {
                Issue.record("terminal waiter must observe failed head transition"); return
            }
            let retry = store.submitRemove(for: key)
            #expect(await store.resolveRowDeletion(retry) == .removed(key))
            #expect(store.record(for: key) == nil)
        }
    }

    @Test(arguments: [false, true])
    func rowDeletionQueuedBehindHeldPredecessorAdvances(predecessorFails: Bool) async throws {
        try await withTemporaryDirectory { directory in
            let id = DownloadAttemptID(uuid: UUID())
            let key = DownloadAttemptKey(ratingKey: "plex:delete-behind-held-\(predecessorFails)",
                                         attemptID: id)
            let record = makeRecord(ratingKey: key.ratingKey, title: "Held", directory: directory,
                                    bytes: 1, metadata: OfflineMetadata(
                                        ratingKey: key.ratingKey, title: "Held", type: "movie"))
            try Data([1]).write(to: record.localURL)
            let heldURL = directory.appendingPathComponent("queued-held.body")
            try Data([2]).write(to: heldURL)
            let blocker = BlockingFailOnceArtifactDelete(path: heldURL.path,
                                                         shouldFail: predecessorFails)
            let live = DownloadArtifactFilesystem.live
            let store = DownloadStore(baseDirectory: directory, artifactFilesystem: .init(
                writeAuthArtifact: live.writeAuthArtifact,
                removeItem: { url, fm in try blocker.remove(url, fm: fm) },
                fileExists: live.fileExists, syncParentDirectory: live.syncParentDirectory))
            #expect(store.createAttemptOwnedRecord(record, attemptID: id) == .committed(key))
            let segment = OfflineHeldRangeSegment(offset: 0, length: 1,
                                                  relativePath: heldURL.lastPathComponent)
            guard case .accepted = store.persistHeldRangeSegment(for: key, segment: segment) else { return }
            _ = store.submitHeldRangeSegmentsRemoval(for: key, offsets: nil)
            #expect(await waitForSignal(blocker.started, timeout: 1))
            let deletion = store.submitRemove(for: key)
            blocker.release.signal()
            #expect(await store.resolveRowDeletion(deletion) == .removed(key))
        }
    }

    @Test func heldBodyDirectorySyncFailureRetainsIntentForRelaunch() throws {
        try withTemporaryDirectory { directory in
            let id = DownloadAttemptID(uuid: UUID())
            let key = DownloadAttemptKey(ratingKey: "plex:held-dir-sync", attemptID: id)
            let record = makeRecord(ratingKey: key.ratingKey, title: "Held sync", directory: directory,
                                    bytes: 1, metadata: OfflineMetadata(
                                        ratingKey: key.ratingKey, title: "Held sync", type: "movie"))
            let heldURL = directory.appendingPathComponent("held-dir-sync.body")
            try Data([1]).write(to: heldURL)
            let live = DownloadArtifactFilesystem.live
            let store = DownloadStore(baseDirectory: directory, artifactFilesystem: .init(
                writeAuthArtifact: live.writeAuthArtifact, removeItem: live.removeItem,
                fileExists: live.fileExists,
                syncParentDirectory: { _ in throw CocoaError(.fileWriteOutOfSpace) }))
            #expect(store.createAttemptOwnedRecord(record, attemptID: id) == .committed(key))
            let segment = OfflineHeldRangeSegment(offset: 0, length: 1,
                                                  relativePath: heldURL.lastPathComponent)
            guard case .accepted = store.persistHeldRangeSegment(for: key, segment: segment) else { return }
            _ = store.submitHeldRangeSegmentsRemoval(for: key, offsets: nil)
            guard case .failed(.artifact) = store.resolveArtifactSynchronouslyForTests(
                through: store.currentArtifactLifecycleWatermark()) else {
                Issue.record("held deletion must fail closed on directory sync"); return
            }
            #expect(store.deferredHeldRangeBodyDeletionRelativePaths(for: key) == [heldURL.lastPathComponent])
            let relaunched = DownloadStore(baseDirectory: directory)
            #expect(relaunched.resolveArtifactSynchronouslyForTests(
                through: relaunched.currentArtifactLifecycleWatermark()) == .completed)
            #expect(relaunched.deferredHeldRangeBodyDeletionRelativePaths(for: key) == [])
        }
    }

    @Test(arguments: [false, true])
    func rowDeletionQueuedBehindStaticPredecessorAdvances(predecessorFails: Bool) async throws {
        try await withTemporaryDirectory { directory in
            let id = DownloadAttemptID(uuid: UUID())
            let key = DownloadAttemptKey(ratingKey: "plex:delete-behind-static-\(predecessorFails)",
                                         attemptID: id)
            var record = makeRecord(ratingKey: key.ratingKey, title: "Static", directory: directory,
                                    bytes: 1, metadata: OfflineMetadata(
                                        ratingKey: key.ratingKey, title: "Static", type: "movie",
                                        resumeMode: .staticByteRange))
            record.status = .complete; record.progress = 1
            try Data([1]).write(to: record.localURL)
            let copy = BlockingCheckpointCopy(shouldFail: predecessorFails)
            let liveCheckpoint = DownloadStaticCheckpointFilesystem.live
            let store = DownloadStore(baseDirectory: directory, checkpointFilesystem: .init(
                exists: liveCheckpoint.exists, size: liveCheckpoint.size,
                durableCopy: { source, destination, temporary in
                    try copy.copy(source, destination, temporary)
                }))
            #expect(store.createAttemptOwnedRecord(record, attemptID: id) == .committed(key))
            _ = store.submitStaticRangeCheckpointReset(for: key)
            #expect(await waitForSignal(copy.started, timeout: 1))
            let deletion = store.submitRemove(for: key)
            copy.release.signal()
            #expect(await store.resolveRowDeletion(deletion) == .removed(key))
        }
    }

    @Test func rowDeletionFailureRetainsDurableIntentAndRelaunchRetries() throws {
        try withTemporaryDirectory { directory in
            let id = DownloadAttemptID(uuid: UUID())
            let key = DownloadAttemptKey(ratingKey: "plex:row-delete-retry", attemptID: id)
            let record = makeRecord(ratingKey: key.ratingKey, title: "Delete", directory: directory,
                                    bytes: 2, metadata: OfflineMetadata(
                                        ratingKey: key.ratingKey, title: "Delete", type: "movie"))
            try Data([5, 6]).write(to: record.localURL)
            let deletes = FailOneLegacyResetDelete(name: record.localURL.lastPathComponent)
            let live = DownloadArtifactFilesystem.live
            let store = DownloadStore(baseDirectory: directory, artifactFilesystem: .init(
                writeAuthArtifact: live.writeAuthArtifact,
                removeItem: { url, fm in try deletes.remove(url, fm: fm) },
                fileExists: live.fileExists))
            #expect(store.createAttemptOwnedRecord(record, attemptID: id) == .committed(key))
            guard case .persistenceFailed = store.remove(for: key) else {
                Issue.record("expected artifact failure mapping"); return
            }
            #expect(store.record(for: key) != nil)
            let relaunched = DownloadStore(baseDirectory: directory)
            #expect(relaunched.resolveArtifactSynchronouslyForTests(
                through: relaunched.currentArtifactLifecycleWatermark()) == .completed)
            #expect(relaunched.record(for: key) == nil)
            #expect(!FileManager.default.fileExists(atPath: record.localURL.path))
        }
    }

    @Test func newAttemptRecordWritesMatchingTopLevelAndNestedShadow() throws {
        try withTemporaryDirectory { directory in
            let ratingKey = "plex:new-v3"
            let id = DownloadAttemptID(uuid: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!)
            let record = makeRecord(
                ratingKey: ratingKey,
                title: "New v3",
                directory: directory,
                bytes: 0,
                metadata: OfflineMetadata(ratingKey: ratingKey, title: "New v3", type: "movie")
            )
            #expect(DownloadStore(baseDirectory: directory)
                .createAttemptOwnedRecord(record, attemptID: id)
                == .committed(DownloadAttemptKey(ratingKey: ratingKey, attemptID: id)))
            let data = try Data(contentsOf: directory.appendingPathComponent("index.json"))
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let rows = try #require(object["rows"] as? [[String: Any]])
            let row = try #require(rows.first)
            let metadata = try #require(row["metadata"] as? [String: Any])
            #expect(row["attemptID"] as? String == id.rawValue)
            #expect(metadata["downloadAttemptID"] as? String == id.rawValue)
        }
    }

    @Test func attemptOwnedRecordReplacementIsExactCompareAndSwap() throws {
        try withTemporaryDirectory { directory in
            let ratingKey = "plex:cas"
            let first = DownloadAttemptID(rawValue: "attempt-A")!
            let second = DownloadAttemptID(rawValue: "attempt-B")!
            let stale = DownloadAttemptID(rawValue: "attempt-stale")!
            let store = DownloadStore(baseDirectory: directory)
            let record = makeRecord(
                ratingKey: ratingKey, title: "CAS", directory: directory, bytes: 0,
                metadata: OfflineMetadata(ratingKey: ratingKey, title: "CAS", type: "movie"))

            #expect(store.createAttemptOwnedRecord(record, attemptID: first)
                == .committed(DownloadAttemptKey(ratingKey: ratingKey, attemptID: first)))
            // Same-ID replay is the persistence-retry path and remains idempotent.
            #expect(store.createAttemptOwnedRecord(record, attemptID: first)
                == .committed(DownloadAttemptKey(ratingKey: ratingKey, attemptID: first)))
            #expect(store.createAttemptOwnedRecord(record, attemptID: second, replacing: first)
                == .committed(DownloadAttemptKey(ratingKey: ratingKey, attemptID: second)))

            #expect(store.createAttemptOwnedRecord(record, attemptID: stale, replacing: first)
                == .rejectedOwnership(
                    expectedPreviousOwner: DownloadAttemptKey(ratingKey: ratingKey, attemptID: first),
                    actualOwner: DownloadAttemptKey(ratingKey: ratingKey, attemptID: second),
                    reason: .ownerMismatch))
            #expect(store.record(for: ratingKey)?.attemptID == second)
        }
    }

    @Test func replacementAttemptRetiresEveryPredecessorSideAsset() throws {
        try withTemporaryDirectory { directory in
            let ratingKey = "plex:side-source-replacement"
            let attemptA = DownloadAttemptID(rawValue: "attempt-A")!
            let attemptB = DownloadAttemptID(rawValue: "attempt-B")!
            let paths = [
                "poster.jpg", "plex.bif", "emby.bif", "trickplay.m3u8", "tile.jpg",
                "chapter.jpg", "subtitle.srt",
            ]
            for path in paths {
                try Data([0x1]).write(to: directory.appendingPathComponent(path))
            }
            let subtitles = [OfflineTextSubtitleTrack(
                id: 1, displayName: "English", codec: "srt", relativePath: "subtitle.srt")]
            let metadataA = OfflineMetadata(
                ratingKey: ratingKey, title: "Source A", type: "movie", sourcePartID: 10,
                posterRelativePath: "poster.jpg", plexBIFRelativePath: "plex.bif",
                embyBIFRelativePath: "emby.bif",
                jellyfinTrickPlayPlaylistRelativePath: "trickplay.m3u8",
                jellyfinTrickPlayTileRelativePaths: ["tile.jpg"],
                chapterImageRelativePaths: [0: "chapter.jpg"],
                offlineTextSubtitles: subtitles, backendKind: .plex)
            let destination = directory.appendingPathComponent("movie.mp4")
            let store = DownloadStore(baseDirectory: directory)
            #expect(store.createAttemptOwnedRecord(
                DownloadRecord(ratingKey: ratingKey, attemptID: attemptA, title: "Source A",
                               localURL: destination, status: .queued, metadata: metadataA),
                attemptID: attemptA) == .committed(
                    DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptA)))
            #expect(store.metadata(for: ratingKey)?.sideAssetBundleOwner?.attemptID
                == attemptA.rawValue)

            let metadataB = OfflineMetadata(
                ratingKey: ratingKey, title: "Source B", type: "movie", sourcePartID: 20,
                backendKind: .plex)
            #expect(store.createAttemptOwnedRecord(
                DownloadRecord(ratingKey: ratingKey, attemptID: attemptB, title: "Source B",
                               localURL: destination, status: .queued, metadata: metadataB),
                attemptID: attemptB, replacing: attemptA) == .committed(
                    DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptB)))

            let replacement = try #require(store.metadata(for: ratingKey))
            #expect(!replacement.hasCachedSideAssets)
            #expect(replacement.sideAssetBundleOwner == nil)
            #expect(paths.allSatisfy {
                !FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent($0).path)
            })
        }
    }

    @Test func selectedSourceChangeWithinAttemptClearsAndRetiresBundle() throws {
        try withTemporaryDirectory { directory in
            let ratingKey = "jellyfin:source-change"
            let attempt = DownloadAttemptID(rawValue: "attempt-current")!
            let key = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attempt)
            let poster = directory.appendingPathComponent("source-change.poster.jpg")
            try Data([0x1]).write(to: poster)
            let metadata = OfflineMetadata(
                ratingKey: ratingKey, title: "Source A", type: "movie",
                posterRelativePath: poster.lastPathComponent, backendKind: .jellyfin,
                mediaSourceID: "source-a")
            let store = DownloadStore(baseDirectory: directory)
            #expect(store.createAttemptOwnedRecord(
                DownloadRecord(ratingKey: ratingKey, attemptID: attempt, title: "Source A",
                               localURL: directory.appendingPathComponent("source-change.mp4"),
                               status: .queued, metadata: metadata),
                attemptID: attempt) == .committed(key))

            #expect(store.updateMetadata(for: key) { $0.mediaSourceID = "source-b" } == .applied)

            let changed = try #require(store.metadata(for: ratingKey))
            #expect(changed.mediaSourceID == "source-b")
            #expect(!changed.hasCachedSideAssets)
            #expect(changed.sideAssetBundleOwner == nil)
            #expect(!FileManager.default.fileExists(atPath: poster.path))
        }
    }

    @Test func delayedOldSourceSideAssetCannotPublishAfterSameAttemptRenegotiation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("side-source-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ratingKey = "jellyfin:source-race"
        let attempt = DownloadAttemptID(rawValue: "attempt-current")!
        let key = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attempt)
        let store = DownloadStore(baseDirectory: directory)
        let metadata = OfflineMetadata(
            ratingKey: ratingKey, title: "Source A", type: "movie",
            backendKind: .jellyfin, mediaSourceID: "source-a")
        #expect(store.createAttemptOwnedRecord(
            DownloadRecord(ratingKey: ratingKey, attemptID: attempt, title: "Source A",
                           localURL: directory.appendingPathComponent("source-race.mp4"),
                           status: .queued, metadata: metadata),
            attemptID: attempt) == .committed(key))
        let capturedSource = try #require(store.sideAssetSourceIdentity(for: key))
        let destination = store.posterDestinationURL(ratingKey: ratingKey)
        let staging = try #require(store.attemptStagingURL(for: key, stableURL: destination))
        let releaseOldFetch = DispatchSemaphore(value: 0)
        let oldFetchFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .utility).async {
            releaseOldFetch.wait()
            try? Data([0xA]).write(to: staging)
            _ = store.promoteSideAssetStagingFile(
                for: key, expectedSource: capturedSource,
                stagingURL: staging, to: destination)
            _ = store.updateMetadata(for: key, expectedSideAssetSource: capturedSource) {
                $0.posterRelativePath = destination.lastPathComponent
            }
            oldFetchFinished.signal()
        }

        #expect(store.updateMetadata(for: key) { $0.mediaSourceID = "source-b" } == .applied)
        releaseOldFetch.signal()
        #expect(await waitForSignal(oldFetchFinished, timeout: 1))

        #expect(store.metadata(for: ratingKey)?.mediaSourceID == "source-b")
        #expect(store.metadata(for: ratingKey)?.posterRelativePath == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func delayedPlexOptimizeSideAssetCannotPublishAfterPreparedSourceChange() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("side-plex-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ratingKey = "plex:optimize-source-race"
        let attempt = DownloadAttemptID(rawValue: "attempt-current")!
        let key = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attempt)
        let store = DownloadStore(baseDirectory: directory)
        let metadata = OfflineMetadata(
            ratingKey: ratingKey, title: "Original", type: "movie", sourcePartID: 10,
            backendKind: .plex, downloadLane: .optimize)
        #expect(store.createAttemptOwnedRecord(
            DownloadRecord(ratingKey: ratingKey, attemptID: attempt, title: "Original",
                           localURL: directory.appendingPathComponent("optimize-race.mp4"),
                           status: .queued, metadata: metadata),
            attemptID: attempt) == .committed(key))
        let capturedSource = try #require(store.sideAssetSourceIdentity(for: key))
        let destination = store.plexBIFDestinationURL(ratingKey: ratingKey)
        let staging = try #require(store.attemptStagingURL(for: key, stableURL: destination))
        let releaseOldFetch = DispatchSemaphore(value: 0)
        let oldFetchFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .utility).async {
            releaseOldFetch.wait()
            try? Data([0xB]).write(to: staging)
            _ = store.promoteSideAssetStagingFile(
                for: key, expectedSource: capturedSource,
                stagingURL: staging, to: destination)
            _ = store.updateMetadata(for: key, expectedSideAssetSource: capturedSource) {
                $0.plexBIFRelativePath = destination.lastPathComponent
            }
            oldFetchFinished.signal()
        }

        #expect(store.updateMetadata(for: key) {
            $0.sourcePartID = 20
            $0.serverPreparedVersion = true
        } == .applied)
        releaseOldFetch.signal()
        #expect(await waitForSignal(oldFetchFinished, timeout: 1))

        #expect(store.metadata(for: ratingKey)?.sourcePartID == 20)
        #expect(store.metadata(for: ratingKey)?.serverPreparedVersion == true)
        #expect(store.metadata(for: ratingKey)?.plexBIFRelativePath == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func samePathSideAssetPromotionInvalidatesExactHydrationGeneration() throws {
        try withTemporaryDirectory { directory in
            let ratingKey = "plex:hydration-generation"
            let attempt = DownloadAttemptID(rawValue: "attempt-current")!
            let key = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attempt)
            let store = DownloadStore(baseDirectory: directory)
            let metadata = OfflineMetadata(
                ratingKey: ratingKey, title: "Hydration", type: "movie", backendKind: .plex)
            #expect(store.createAttemptOwnedRecord(
                DownloadRecord(
                    ratingKey: ratingKey, attemptID: attempt, title: "Hydration",
                    localURL: directory.appendingPathComponent("hydration.mp4"),
                    status: .complete, metadata: metadata),
                attemptID: attempt) == .committed(key))
            let source = try #require(store.sideAssetSourceIdentity(for: key))
            let destination = store.plexBIFDestinationURL(ratingKey: ratingKey)

            func promote(_ bytes: Data) throws {
                let staging = try #require(store.attemptStagingURL(
                    for: key, stableURL: destination))
                try bytes.write(to: staging)
                #expect(store.promoteSideAssetStagingFile(
                    for: key, expectedSource: source,
                    stagingURL: staging, to: destination) == .promoted)
            }

            try promote(Data(repeating: 0xA, count: 8))
            #expect(store.updateMetadata(for: key, expectedSideAssetSource: source) {
                $0.plexBIFRelativePath = destination.lastPathComponent
            } == .applied)
            #expect(store.records.first?.sideAssetBytes == 8) // populate hydration cache

            try promote(Data(repeating: 0xB, count: 31)) // identical stable path
            #expect(store.records.first?.sideAssetBytes == 31)
        }
    }

    @Test func attemptOwnedRecordRejectsMissingExpectedAndUnownedExistingRows() throws {
        try withTemporaryDirectory { directory in
            let expected = DownloadAttemptID(rawValue: "attempt-expected")!
            let replacement = DownloadAttemptID(rawValue: "attempt-new")!
            let missingStore = DownloadStore(baseDirectory: directory)
            let missingRecord = makeRecord(
                ratingKey: "plex:missing", title: "Missing", directory: directory, bytes: 0)
            #expect(missingStore.createAttemptOwnedRecord(
                missingRecord, attemptID: replacement, replacing: expected)
                == .rejectedOwnership(
                    expectedPreviousOwner: DownloadAttemptKey(
                        ratingKey: "plex:missing", attemptID: expected),
                    actualOwner: nil,
                    reason: .missingExpectedOwner))

            let unowned = makeRecord(
                ratingKey: "plex:unowned", title: "Unowned", directory: directory, bytes: 0)
            missingStore.upsert(unowned)
            #expect(missingStore.createAttemptOwnedRecord(unowned, attemptID: replacement)
                == .rejectedOwnership(
                    expectedPreviousOwner: nil,
                    actualOwner: nil,
                    reason: .ownerMismatch))
        }
    }

    @Test func failedAttemptCreateCanRetryOnlyWithSameOwner() throws {
        try withTemporaryDirectory { directory in
            let writes = AtomicWriteHarness(failFirstWrite: true)
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try writes.write(data, to: url) })
            let ratingKey = "plex:retry-create"
            let attempt = DownloadAttemptID(rawValue: "attempt-retry")!
            let record = makeRecord(
                ratingKey: ratingKey, title: "Retry", directory: directory, bytes: 0)

            guard case .failed(let failedKey, _) = store.createAttemptOwnedRecord(
                record, attemptID: attempt) else {
                Issue.record("Expected injected first commit failure")
                return
            }
            #expect(failedKey == DownloadAttemptKey(ratingKey: ratingKey, attemptID: attempt))
            #expect(store.createAttemptOwnedRecord(record, attemptID: attempt)
                == .committed(DownloadAttemptKey(ratingKey: ratingKey, attemptID: attempt)))
        }
    }

    @Test func staleAttemptCannotMutateOrRemoveReplacementAttempt() throws {
        try withTemporaryDirectory { directory in
            let ratingKey = "plex:attempt-isolation"
            let attemptA = DownloadAttemptID(rawValue: "attempt-A")!
            let attemptB = DownloadAttemptID(rawValue: "attempt-B")!
            let keyA = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptA)
            let keyB = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptB)
            let metadata = OfflineMetadata(
                ratingKey: ratingKey, title: "Isolation", type: "movie", summary: "original")
            let record = makeRecord(
                ratingKey: ratingKey,
                title: "Isolation",
                directory: directory,
                bytes: 0,
                metadata: metadata)
            let store = DownloadStore(baseDirectory: directory)

            #expect(store.createAttemptOwnedRecord(record, attemptID: attemptA) == .committed(keyA))
            #expect(store.createAttemptOwnedRecord(
                record, attemptID: attemptB, replacing: attemptA) == .committed(keyB))
            try Data(repeating: 0xB, count: 32).write(to: record.localURL)

            #expect(!store.ownsAttempt(keyA))
            #expect(store.ownsAttempt(keyB))
            #expect(store.record(for: keyA) == nil)
            #expect(store.record(for: keyB)?.attemptID == attemptB)

            #expect(store.setStatus(for: keyA, .complete) == .staleOrMissing)
            #expect(store.updateProgress(for: keyA, bytes: 9_999, progress: 1) == .staleOrMissing)
            #expect(store.updateMetadata(for: keyA) { $0.summary = "stale mutation" }
                == .staleOrMissing)
            #expect(store.remove(for: keyA) == .staleOrMissing)
            #expect(FileManager.default.fileExists(atPath: record.localURL.path))

            #expect(store.setStatus(for: keyB, .queued) == .applied)
            #expect(store.updateProgress(for: keyB, bytes: 16, progress: 0.5) == .applied)
            #expect(store.updateMetadata(for: keyB) { $0.summary = "current mutation" } == .applied)
            let current = try #require(store.record(for: keyB))
            #expect(current.status == .downloading)
            #expect(current.bytes == 16)
            #expect(current.progress == 0.5)
            #expect(current.metadata?.summary == "current mutation")
            #expect(current.metadata?.downloadAttemptID == attemptB.rawValue)

            #expect(store.remove(for: keyB) == .applied)
            #expect(store.record(for: ratingKey) == nil)
            #expect(!FileManager.default.fileExists(atPath: record.localURL.path))
        }
    }

    @Test func playSessionCompareClearRequiresExactAttemptAndExpectedValue() throws {
        try withTemporaryDirectory { directory in
            let ratingKey = "emby:compare-clear"
            let attemptA = DownloadAttemptID(rawValue: "attempt-A")!
            let attemptB = DownloadAttemptID(rawValue: "attempt-B")!
            let keyA = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptA)
            let keyB = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptB)
            var metadata = OfflineMetadata(
                ratingKey: ratingKey, title: "Compare clear", type: "movie")
            metadata.playSessionID = "session-A"
            let record = makeRecord(
                ratingKey: ratingKey,
                title: "Compare clear",
                directory: directory,
                bytes: 0,
                metadata: metadata)
            let store = DownloadStore(baseDirectory: directory)

            #expect(store.createAttemptOwnedRecord(record, attemptID: attemptA) == .committed(keyA))
            #expect(store.clearPlaySessionID(
                for: keyA, expectedPlaySessionID: "other"
            ) == .expectedValueMismatch)
            #expect(store.metadata(for: ratingKey)?.playSessionID == "session-A")

            var replacement = record
            replacement.attemptID = attemptB
            replacement.metadata?.downloadAttemptID = attemptB.rawValue
            replacement.metadata?.playSessionID = "session-B"
            #expect(store.createAttemptOwnedRecord(
                replacement, attemptID: attemptB, replacing: attemptA
            ) == .committed(keyB))
            #expect(store.clearPlaySessionID(
                for: keyA, expectedPlaySessionID: "session-A"
            ) == .staleOrMissing)
            #expect(store.clearPlaySessionID(
                for: keyB, expectedPlaySessionID: "session-A"
            ) == .expectedValueMismatch)
            #expect(store.metadata(for: ratingKey)?.playSessionID == "session-B")
            #expect(store.clearPlaySessionID(
                for: keyB, expectedPlaySessionID: "session-B"
            ) == .cleared)
            #expect(store.clearPlaySessionID(
                for: keyB, expectedPlaySessionID: "session-B"
            ) == .alreadyAbsent)
        }
    }

    @Test func conditionalRemovalSerializesStablePathAgainstReplacementSeed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attempt-remove-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ratingKey = "plex:remove-race"
        let attemptA = DownloadAttemptID(rawValue: "attempt-A")!
        let attemptB = DownloadAttemptID(rawValue: "attempt-B")!
        let keyA = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptA)
        let fileURL = directory.appendingPathComponent("remove-race.mp4")
        let fileManager = BlockingRemovalFileManager(blockedPath: fileURL.path)
        let store = DownloadStore(baseDirectory: directory, fileManager: fileManager)
        let record = DownloadRecord(
            ratingKey: ratingKey,
            title: "Remove race",
            localURL: fileURL,
            status: .downloading,
            metadata: OfflineMetadata(ratingKey: ratingKey, title: "Remove race", type: "movie"))
        #expect(store.createAttemptOwnedRecord(record, attemptID: attemptA) == .committed(keyA))
        try Data(repeating: 0xA, count: 32).write(to: fileURL)

        let removeReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            _ = store.remove(for: keyA)
            removeReturned.signal()
        }
        #expect(await waitForSignal(fileManager.removalStarted, timeout: 1))

        let replacementReturned = DispatchSemaphore(value: 0)
        let replacementResult = Mutex<DownloadStore.AttemptRecordCreateResult?>(nil)
        DispatchQueue.global(qos: .utility).async {
            let result = store.createAttemptOwnedRecord(
                record, attemptID: attemptB, replacing: attemptA)
            replacementResult.withLock { $0 = result }
            replacementReturned.signal()
        }
        // Off-lock deletion keeps the Store responsive, but its reservation must reject B rather
        // than allowing B to publish the same stable path under A's cleanup tail.
        #expect(await waitForSignal(replacementReturned, timeout: 1))
        #expect(replacementResult.withLock { $0 } == .rejectedOwnership(
            expectedPreviousOwner: keyA,
            actualOwner: keyA,
            reason: .artifactLifecyclePending))
        fileManager.allowRemoval.signal()
        #expect(await waitForSignal(removeReturned, timeout: 1))
        #expect(store.record(for: ratingKey) == nil)

        // After A is fully removed, a fresh B seed/write is safe from A's cleanup tail.
        let keyB = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptB)
        #expect(store.createAttemptOwnedRecord(record, attemptID: attemptB) == .committed(keyB))
        try Data(repeating: 0xB, count: 32).write(to: fileURL)
        #expect(store.ownsAttempt(keyB))
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func failedAtomicWriteIsRecoveredByLaterFullStateMutation() throws {
        try withTemporaryDirectory { directory in
            let writes = AtomicWriteHarness(failFirstWrite: true)
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in
                    try writes.write(data, to: url)
                }
            )

            store.upsert(makeRecord(
                ratingKey: "plex:item-1",
                title: "First Item",
                directory: directory,
                bytes: 100
            ))

            #expect(writes.attemptCount == 1)
            #expect(!FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("index.json").path
            ))

            store.upsert(makeRecord(
                ratingKey: "plex:item-2",
                title: "Second Item",
                directory: directory,
                bytes: 200
            ))

            #expect(writes.attemptCount == 2)
            let restored = DownloadStore(baseDirectory: directory)
            #expect(Set(restored.records.map(\.ratingKey)) == ["plex:item-1", "plex:item-2"])
            #expect(Dictionary(uniqueKeysWithValues: restored.records.map { ($0.ratingKey, $0.bytes) }) == [
                "plex:item-1": 100,
                "plex:item-2": 200,
            ])
        }
    }

    @Test func failedHeldManifestReplacementRetainsBothBodiesUntilLaterCommit() throws {
        try withTemporaryDirectory { directory in
            let ratingKey = "plex:held-replacement"
            let oldManifest = OfflineHeldRangeSegment(
                offset: 64,
                length: 64,
                relativePath: "old-held-body"
            )
            let newManifest = OfflineHeldRangeSegment(
                offset: 64,
                length: 64,
                relativePath: "new-held-body"
            )
            let oldBody = directory.appendingPathComponent(oldManifest.relativePath)
            let newBody = directory.appendingPathComponent(newManifest.relativePath)
            try Data(repeating: 1, count: oldManifest.length).write(to: oldBody)
            try Data(repeating: 2, count: newManifest.length).write(to: newBody)

            let initial = DownloadStore(baseDirectory: directory)
            initial.upsert(makeRecord(
                ratingKey: ratingKey,
                title: "Held Replacement",
                directory: directory,
                bytes: 0,
                metadata: OfflineMetadata(
                    ratingKey: ratingKey,
                    title: "Held Replacement",
                    type: "movie",
                    resumeMode: .staticByteRange,
                    heldRangeSegments: [oldManifest]
                )
            ))

            let writes = AtomicWriteHarness(failFirstWrite: true)
            let replacing = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try writes.write(data, to: url) }
            )
            let result = replacing.persistHeldRangeSegment(
                ratingKey: ratingKey,
                segment: newManifest
            )

            #expect(result.persisted)
            #expect(!result.committed)
            #expect(result.previous == oldManifest)
            #expect(FileManager.default.fileExists(atPath: oldBody.path))
            #expect(FileManager.default.fileExists(atPath: newBody.path))
            #expect(DownloadStore(baseDirectory: directory)
                .records.first?.metadata?.heldRangeSegments == [oldManifest])

            replacing.setStatus(ratingKey: ratingKey, .downloading)
            #expect(writes.attemptCount == 2)
            #expect(DownloadStore(baseDirectory: directory)
                .records.first?.metadata?.heldRangeSegments == [newManifest])
            #expect(FileManager.default.fileExists(atPath: oldBody.path))
            #expect(FileManager.default.fileExists(atPath: newBody.path))
        }
    }

    @Test func failedHeldManifestRemovalIsObservableAndNoOpRetryCommitsIt() throws {
        try withTemporaryDirectory { directory in
            let ratingKey = "plex:held-remove"
            let segment = OfflineHeldRangeSegment(
                offset: 64, length: 64, relativePath: "held-remove-body"
            )
            let initial = DownloadStore(baseDirectory: directory)
            initial.upsert(makeRecord(
                ratingKey: ratingKey,
                title: "Held Remove",
                directory: directory,
                bytes: 0,
                metadata: OfflineMetadata(
                    ratingKey: ratingKey,
                    title: "Held Remove",
                    type: "movie",
                    resumeMode: .staticByteRange,
                    heldRangeSegments: [segment]
                )
            ))

            let writes = AtomicWriteHarness(failFirstWrite: true)
            let removing = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try writes.write(data, to: url) }
            )
            let failed = removing.removeHeldRangeSegment(
                ratingKey: ratingKey, offset: segment.offset
            )

            #expect(failed.removed == segment)
            #expect(!failed.committed)
            #expect(DownloadStore(baseDirectory: directory)
                .record(for: ratingKey)?.metadata?.heldRangeSegments == [segment])

            let retriedNoOp = removing.removeHeldRangeSegment(
                ratingKey: ratingKey, offset: segment.offset
            )
            #expect(retriedNoOp.removed == nil)
            #expect(retriedNoOp.committed)
            #expect(writes.attemptCount == 2)
            #expect(DownloadStore(baseDirectory: directory)
                .record(for: ratingKey)?.metadata?.heldRangeSegments == nil)

            let alreadyDurableNoOp = removing.removeHeldRangeSegment(
                ratingKey: ratingKey, offset: segment.offset
            )
            #expect(alreadyDurableNoOp.committed)
            #expect(writes.attemptCount == 2)
        }
    }

    @Test func failedHeldManifestTakeIsObservableAndNoOpRetryCommitsIt() throws {
        try withTemporaryDirectory { directory in
            let ratingKey = "plex:held-take"
            let segments = [
                OfflineHeldRangeSegment(offset: 64, length: 64, relativePath: "held-take-1"),
                OfflineHeldRangeSegment(offset: 128, length: 64, relativePath: "held-take-2"),
            ]
            let initial = DownloadStore(baseDirectory: directory)
            initial.upsert(makeRecord(
                ratingKey: ratingKey,
                title: "Held Take",
                directory: directory,
                bytes: 0,
                metadata: OfflineMetadata(
                    ratingKey: ratingKey,
                    title: "Held Take",
                    type: "movie",
                    resumeMode: .staticByteRange,
                    heldRangeSegments: segments
                )
            ))

            let writes = AtomicWriteHarness(failFirstWrite: true)
            let taking = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try writes.write(data, to: url) }
            )
            let failed = taking.takeHeldRangeSegments(ratingKey: ratingKey)

            #expect(failed.removed == segments)
            #expect(!failed.committed)
            #expect(DownloadStore(baseDirectory: directory)
                .record(for: ratingKey)?.metadata?.heldRangeSegments == segments)

            let retriedNoOp = taking.takeHeldRangeSegments(ratingKey: ratingKey)
            #expect(retriedNoOp.removed.isEmpty)
            #expect(retriedNoOp.committed)
            #expect(writes.attemptCount == 2)
            #expect(DownloadStore(baseDirectory: directory)
                .record(for: ratingKey)?.metadata?.heldRangeSegments == nil)
        }
    }

    @Test func zeroByteStaticPauseRemainsRestartableAcrossStoreReconcile() throws {
        try withTemporaryDirectory { directory in
            let staticKey = "plex:static-zero"
            let liveKey = "jellyfin:live-zero"
            let store = DownloadStore(baseDirectory: directory)
            store.upsert(makeRecord(
                ratingKey: staticKey,
                title: "Static Zero",
                directory: directory,
                bytes: 0,
                metadata: OfflineMetadata(
                    ratingKey: staticKey,
                    title: "Static Zero",
                    type: "movie",
                    resumeMode: .staticByteRange
                )
            ))
            store.upsert(makeRecord(
                ratingKey: liveKey,
                title: "Live Zero",
                directory: directory,
                bytes: 0,
                metadata: OfflineMetadata(
                    ratingKey: liveKey,
                    title: "Live Zero",
                    type: "movie",
                    resumeMode: .liveForwardOnly
                )
            ))

            let restored = DownloadStore(baseDirectory: directory)
            restored.reconcile(
                liveRatingKeys: [],
                snapshotRatingKeys: [staticKey, liveKey]
            )

            #expect(restored.status(for: staticKey) == .paused)
            #expect(restored.status(for: liveKey) == .failed)
            let afterRelaunch = DownloadStore(baseDirectory: directory)
            #expect(afterRelaunch.status(for: staticKey) == .paused)
            #expect(afterRelaunch.status(for: liveKey) == .failed)
        }
    }

    @Test func ownerlessSubtitleFileIsNotAdoptedOnLoad() throws {
        try withTemporaryDirectory { directory in
            let ratingKey = "plex:item-1"
            let initial = DownloadStore(baseDirectory: directory)
            initial.upsert(makeRecord(
                ratingKey: ratingKey,
                title: "Subtitle Item",
                directory: directory,
                bytes: 300,
                metadata: OfflineMetadata(
                    ratingKey: ratingKey,
                    title: "Subtitle Item",
                    type: "movie"
                )
            ))

            let subtitleURL = initial.textSubtitleDestinationURL(
                ratingKey: ratingKey,
                streamID: 7,
                ext: "srt"
            )
            try Data("1\n00:00:00,000 --> 00:00:01,000\nHello\n".utf8).write(to: subtitleURL)

            let writes = AtomicWriteHarness()
            let repaired = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in
                    try writes.write(data, to: url)
                }
            )

            #expect(writes.attemptCount == 0)
            #expect(repaired.records.first?.metadata?.offlineTextSubtitles == nil)

            let restored = DownloadStore(baseDirectory: directory)
            #expect(restored.records.first?.metadata?.offlineTextSubtitles == nil)
        }
    }

    /// Seed one complete owned row with a cached poster, then mutate its persisted row JSON
    /// (mimicking an index written by an older build) before the store under test loads it.
    private func seedOwnedPosterRow(
        directory: URL,
        mutatingPersistedRow mutate: (inout [String: Any]) -> Void
    ) throws -> (ratingKey: String, attempt: DownloadAttemptID, poster: URL) {
        let ratingKey = "plex:ownerless-assets"
        let attempt = DownloadAttemptID(rawValue: "attempt-current")!
        let poster = directory.appendingPathComponent("ownerless.poster.jpg")
        try Data([0x1]).write(to: poster)
        let seed = DownloadStore(baseDirectory: directory)
        #expect(seed.createAttemptOwnedRecord(DownloadRecord(
            ratingKey: ratingKey, attemptID: attempt, title: "Ownerless",
            localURL: directory.appendingPathComponent("ownerless.mp4"), status: .complete,
            metadata: OfflineMetadata(
                ratingKey: ratingKey, title: "Ownerless", type: "movie",
                posterRelativePath: poster.lastPathComponent, backendKind: .plex)),
            attemptID: attempt) == .committed(
                DownloadAttemptKey(ratingKey: ratingKey, attemptID: attempt)))
        let indexURL = directory.appendingPathComponent("index.json")
        let data = try Data(contentsOf: indexURL)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var rows = try #require(object["rows"] as? [[String: Any]])
        var row = rows[0]
        mutate(&row)
        rows[0] = row
        object["rows"] = rows
        try JSONSerialization.data(withJSONObject: object).write(to: indexURL, options: .atomic)
        return (ratingKey, attempt, poster)
    }

    /// The pre-`sideAssetBundleOwner` schema (still version 4) persisted cached side assets with
    /// no owner. A row whose sole top-level attempt exists must adopt that owner on first load —
    /// not delete the user's posters/trickplay/chapters/subtitles.
    @Test func legacyOwnerlessSideAssetBundleWithAttemptIsAdoptedOnLoad() throws {
        try withTemporaryDirectory { directory in
            let (ratingKey, attempt, poster) = try seedOwnedPosterRow(directory: directory) { row in
                guard var metadata = row["metadata"] as? [String: Any] else { return }
                metadata.removeValue(forKey: "sideAssetBundleOwner")
                row["metadata"] = metadata
            }

            let restored = DownloadStore(baseDirectory: directory)

            let metadata = try #require(restored.metadata(for: ratingKey))
            #expect(metadata.posterRelativePath == poster.lastPathComponent)
            #expect(metadata.sideAssetBundleOwner == OfflineSideAssetBundleOwner(
                attemptID: attempt.rawValue, source: metadata.sideAssetSourceIdentity))
            #expect(FileManager.default.fileExists(atPath: poster.path))
            let relaunched = DownloadStore(baseDirectory: directory)
            let durable = try #require(relaunched.metadata(for: ratingKey))
            #expect(durable.posterRelativePath == poster.lastPathComponent)
            #expect(durable.sideAssetBundleOwner == OfflineSideAssetBundleOwner(
                attemptID: attempt.rawValue, source: durable.sideAssetSourceIdentity))
        }
    }

    @Test func mismatchedSideAssetBundleOwnerStillFailsClosedOnLoad() throws {
        try withTemporaryDirectory { directory in
            let (ratingKey, _, poster) = try seedOwnedPosterRow(directory: directory) { row in
                guard var metadata = row["metadata"] as? [String: Any],
                      var owner = metadata["sideAssetBundleOwner"] as? [String: Any] else { return }
                owner["attemptID"] = "attempt-mismatched"
                metadata["sideAssetBundleOwner"] = owner
                row["metadata"] = metadata
            }

            let restored = DownloadStore(baseDirectory: directory)

            let metadata = try #require(restored.metadata(for: ratingKey))
            #expect(!metadata.hasCachedSideAssets)
            #expect(metadata.sideAssetBundleOwner == nil)
            #expect(!FileManager.default.fileExists(atPath: poster.path))
            let relaunched = DownloadStore(baseDirectory: directory)
            #expect(relaunched.metadata(for: ratingKey)?.posterRelativePath == nil)
        }
    }

    @Test func ownerlessSideAssetBundleWithoutAttemptStillFailsClosedOnLoad() throws {
        try withTemporaryDirectory { directory in
            let (ratingKey, _, poster) = try seedOwnedPosterRow(directory: directory) { row in
                row.removeValue(forKey: "attemptID")
                guard var metadata = row["metadata"] as? [String: Any] else { return }
                metadata.removeValue(forKey: "sideAssetBundleOwner")
                metadata.removeValue(forKey: "downloadAttemptID")
                row["metadata"] = metadata
            }

            let restored = DownloadStore(baseDirectory: directory)

            let metadata = try #require(restored.metadata(for: ratingKey))
            #expect(!metadata.hasCachedSideAssets)
            #expect(metadata.sideAssetBundleOwner == nil)
            #expect(!FileManager.default.fileExists(atPath: poster.path))
            let relaunched = DownloadStore(baseDirectory: directory)
            #expect(relaunched.metadata(for: ratingKey)?.posterRelativePath == nil)
        }
    }

    @Test func stalePlaybackAttemptCannotPromoteOrMoveReplacementPosition() throws {
        try withTemporaryDirectory { directory in
            let ratingKey = "plex:playback-owner"
            let attemptA = DownloadAttemptID(rawValue: "attempt-a")!
            let attemptB = DownloadAttemptID(rawValue: "attempt-b")!
            let keyA = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptA)
            let keyB = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptB)
            let store = DownloadStore(baseDirectory: directory)
            let metadata = OfflineMetadata(ratingKey: ratingKey, title: "Playback", type: "movie")
            let destination = directory.appendingPathComponent("playback.mp4")
            guard case .committed = store.createAttemptOwnedRecord(
                DownloadRecord(ratingKey: ratingKey, attemptID: attemptA, title: "Playback",
                               localURL: destination, status: .unverified, metadata: metadata),
                attemptID: attemptA) else {
                Issue.record("attempt A seed failed")
                return
            }
            guard case .committed = store.createAttemptOwnedRecord(
                DownloadRecord(ratingKey: ratingKey, attemptID: attemptB, title: "Playback",
                               localURL: destination, status: .complete, metadata: metadata),
                attemptID: attemptB, replacing: attemptA) else {
                Issue.record("attempt B replacement failed")
                return
            }

            #expect(store.markCompleteIfUnverified(for: keyA) == .staleOrMissing)
            #expect(store.setLocalPlaybackPosition(
                for: keyA, positionMs: 12_000, durationMs: 60_000) == .staleOrMissing)
            #expect(store.record(for: keyB)?.status == .complete)
            #expect(store.record(for: keyB)?.metadata?.localPlaybackPositionMs == nil)
        }
    }

    @Test func exactPlaybackPromotionIsConditionalAndDurable() throws {
        try withTemporaryDirectory { directory in
            let ratingKey = "plex:conditional-promotion"
            let attempt = DownloadAttemptID(rawValue: "attempt")!
            let key = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attempt)
            let metadata = OfflineMetadata(ratingKey: ratingKey, title: "Conditional", type: "movie")
            let store = DownloadStore(baseDirectory: directory)
            guard case .committed = store.createAttemptOwnedRecord(
                DownloadRecord(ratingKey: ratingKey, attemptID: attempt, title: "Conditional",
                               localURL: directory.appendingPathComponent("conditional.mp4"),
                               status: .queued, metadata: metadata),
                attemptID: attempt) else {
                Issue.record("attempt seed failed")
                return
            }

            #expect(store.markCompleteIfUnverified(for: key) == .notUnverified)
            #expect(store.setStatus(for: key, .unverified) == .applied)
            #expect(store.markCompleteIfUnverified(for: key) == .promoted)
            #expect(store.markCompleteIfUnverified(for: key) == .notUnverified)
            #expect(store.setLocalPlaybackPosition(
                for: key, positionMs: 15_000, durationMs: 60_000) == .applied)

            let restored = DownloadStore(baseDirectory: directory)
            #expect(restored.record(for: key)?.status == .complete)
            #expect(restored.record(for: key)?.metadata?.localPlaybackPositionMs == 15_000)
        }
    }

    private func makeRecord(
        ratingKey: String,
        title: String,
        directory: URL,
        bytes: Int,
        metadata: OfflineMetadata? = nil
    ) -> DownloadRecord {
        DownloadRecord(
            ratingKey: ratingKey,
            title: title,
            localURL: directory.appendingPathComponent("\(ratingKey.replacingOccurrences(of: ":", with: "_")).mp4"),
            bytes: bytes,
            progress: 0.5,
            status: .paused,
            metadata: metadata
        )
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-store-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func withTemporaryDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-store-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    private func waitForSignal(_ semaphore: DispatchSemaphore, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + timeout) == .success)
            }
        }
    }
}

private final class BlockingRemovalFileManager: FileManager, @unchecked Sendable {
    let removalStarted = DispatchSemaphore(value: 0)
    let allowRemoval = DispatchSemaphore(value: 0)
    private let blockedPath: String

    init(blockedPath: String) {
        self.blockedPath = blockedPath
        super.init()
    }

    override func removeItem(at URL: URL) throws {
        if URL.path == blockedPath {
            removalStarted.signal()
            allowRemoval.wait()
        }
        try super.removeItem(at: URL)
    }
}

private struct InjectedAtomicWriteFailure: Error {}

private final class PostReplaceFailureHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true

    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        let fail = lock.withLock {
            defer { shouldFail = false }
            return shouldFail
        }
        if fail { throw InjectedAtomicWriteFailure() }
    }
}

private final class AtomicWriteHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFailNextWrite: Bool
    private var attempts = 0

    init(failFirstWrite: Bool = false) {
        shouldFailNextWrite = failFirstWrite
    }

    var attemptCount: Int {
        lock.withLock { attempts }
    }

    func write(_ data: Data, to url: URL) throws {
        let shouldFail = lock.withLock {
            attempts += 1
            defer { shouldFailNextWrite = false }
            return shouldFailNextWrite
        }
        if shouldFail { throw InjectedAtomicWriteFailure() }
        try data.write(to: url, options: .atomic)
    }
}

private final class FirstBlockingAtomicWriteHarness: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var attempts = 0

    func write(_ data: Data, to url: URL) throws {
        let attempt = lock.withLock { attempts += 1; return attempts }
        if attempt == 1 {
            started.signal()
            release.wait()
        }
        try data.write(to: url, options: .atomic)
    }
}

private final class SelectedAtomicWriteFailureHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let failingAttempts: Set<Int>
    private var attempts = 0

    init(failingAttempts: Set<Int>) { self.failingAttempts = failingAttempts }

    func write(_ data: Data, to url: URL) throws {
        let attempt = lock.withLock { attempts += 1; return attempts }
        if failingAttempts.contains(attempt) { throw InjectedAtomicWriteFailure() }
        try data.write(to: url, options: .atomic)
    }
}

private final class BlockingNthAtomicWriteHarness: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let blockedAttempt: Int
    private var attempts = 0
    init(_ blockedAttempt: Int) { self.blockedAttempt = blockedAttempt }
    func write(_ data: Data, to url: URL) throws {
        let attempt = lock.withLock { attempts += 1; return attempts }
        if attempt == blockedAttempt { started.signal(); release.wait() }
        try data.write(to: url, options: .atomic)
    }
}

private final class FailOneLegacyResetDelete: @unchecked Sendable {
    private let lock = NSLock()
    private let name: String
    private var failed = false
    init(name: String) { self.name = name }
    func remove(_ url: URL, fm: FileManager) throws {
        let shouldFail = lock.withLock {
            guard url.lastPathComponent == name, !failed else { return false }
            failed = true; return true
        }
        if shouldFail { throw CocoaError(.fileWriteOutOfSpace) }
        try fm.removeItem(at: url)
    }
}

private final class BlockingArtifactDelete: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let path: String
    init(path: String) { self.path = path }
    func remove(_ url: URL, fm: FileManager) throws {
        if url.path == path { started.signal(); release.wait() }
        try fm.removeItem(at: url)
    }
}

private final class BlockingFailingArtifactDelete: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let path: String
    init(path: String) { self.path = path }
    func remove(_ url: URL, fm: FileManager) throws {
        if url.path == path {
            started.signal(); release.wait()
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try fm.removeItem(at: url)
    }
}

private final class BlockingFailOnceArtifactDelete: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let path: String
    private let injectFailure: Bool
    private var failed = false
    init(path: String, shouldFail: Bool = true) {
        self.path = path; self.injectFailure = shouldFail
    }
    func remove(_ url: URL, fm: FileManager) throws {
        let shouldFail = lock.withLock { () -> Bool in
            guard url.path == path, !failed else { return false }
            failed = true; return true
        }
        if shouldFail {
            started.signal(); release.wait()
            if injectFailure { throw CocoaError(.fileWriteOutOfSpace) }
        }
        try fm.removeItem(at: url)
    }
}

private final class BlockingCheckpointCopy: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let shouldFail: Bool
    init(shouldFail: Bool) { self.shouldFail = shouldFail }
    func copy(_ source: URL, _ destination: URL, _ temporary: URL) throws {
        started.signal(); release.wait()
        if shouldFail { throw CocoaError(.fileWriteOutOfSpace) }
        try DownloadStaticCheckpointFilesystem.live.durableCopy(source, destination, temporary)
    }
}

private final class BlockingArtifactWrite: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let shouldFail: Bool
    init(shouldFail: Bool) { self.shouldFail = shouldFail }
    func write(_ data: Data, url: URL, fm: FileManager) throws {
        started.signal(); release.wait()
        if shouldFail { throw CocoaError(.fileWriteOutOfSpace) }
        try DownloadArtifactFilesystem.live.writeAuthArtifact(data, url, fm)
    }
}

private final class BlockingFailOnceArtifactWrite: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var failed = false
    func write(_ data: Data, url: URL, fm: FileManager) throws {
        let shouldFail = lock.withLock { () -> Bool in
            guard !failed else { return false }
            failed = true; return true
        }
        if shouldFail {
            started.signal(); release.wait()
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try DownloadArtifactFilesystem.live.writeAuthArtifact(data, url, fm)
    }
}
