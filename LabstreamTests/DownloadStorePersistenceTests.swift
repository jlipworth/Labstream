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

    @Test func v2NestedAttemptMigratesToDurableTopLevelV3AndSurvivesRelaunchBarrier() throws {
        try withTemporaryDirectory { directory in
            let key = "plex:legacy-active"
            let legacyID = "legacy-attempt"
            try writeLegacyIndex(
                schemaVersion: 2,
                rows: [legacyRow(ratingKey: key, status: "downloading", bytes: 42,
                                 nestedAttemptID: legacyID)],
                directory: directory
            )
            let store = DownloadStore(baseDirectory: directory)
            let expectedID = try #require(DownloadAttemptID(rawValue: legacyID))
            let expectedKey = DownloadAttemptKey(ratingKey: key, attemptID: expectedID)
            let result = store.commitLegacyAttemptOwnershipMigration()
            guard case .committed(let plan) = result else {
                Issue.record("Expected committed v2 migration, got \(result)")
                return
            }
            #expect(plan.taskCancellationAndReset == [expectedKey])

            let relaunched = DownloadStore(baseDirectory: directory)
            let relaunchedResult = relaunched.commitLegacyAttemptOwnershipMigration()
            guard case .committed(let relaunchedPlan) = relaunchedResult else {
                Issue.record("Expected durable reset barrier after relaunch, got \(relaunchedResult)")
                return
            }
            #expect(relaunchedPlan.taskCancellationAndReset == [expectedKey])
            #expect(relaunched.record(for: key)?.attemptID == expectedID)
        }
    }

    @Test func v1CompletedRowIsPreservedWithoutAttemptOwnership() throws {
        try withTemporaryDirectory { directory in
            let key = "plex:legacy-complete"
            try writeLegacyIndex(schemaVersion: nil,
                                 rows: [legacyRow(ratingKey: key, status: "complete", bytes: 99)],
                                 directory: directory)
            let store = DownloadStore(baseDirectory: directory)
            guard case .committed(let plan) = store.commitLegacyAttemptOwnershipMigration() else {
                Issue.record("Expected v1 envelope migration")
                return
            }
            #expect(plan.taskCancellationAndReset.isEmpty)
            #expect(plan.cleanupOnly.isEmpty)
            #expect(store.record(for: key)?.status == .complete)
            #expect(store.record(for: key)?.attemptID == nil)
        }
    }

    @Test func reconciledOwnerlessTerminalRowIsAdoptedInsteadOfGloballyBlockingV4() throws {
        try withTemporaryDirectory { directory in
            let ratingKey = "plex:ownerless-demoted"
            try writeLegacyIndex(
                schemaVersion: 4,
                rows: [legacyRow(ratingKey: ratingKey, status: "complete", bytes: 99)],
                directory: directory)
            let store = DownloadStore(baseDirectory: directory)
            store.reconcile(liveRatingKeys: [], snapshotRatingKeys: [ratingKey])
            #expect(store.status(for: ratingKey) == .failed)

            let fixedID = DownloadAttemptID(rawValue: "adopted-after-reconcile")!
            let relaunched = DownloadStore(baseDirectory: directory)
            guard case .committed(let plan) = relaunched.commitLegacyAttemptOwnershipMigration(
                idFactory: { _ in fixedID }) else {
                Issue.record("Expected ownerless reconciled row to enter safe reset")
                return
            }
            let key = DownloadAttemptKey(ratingKey: ratingKey, attemptID: fixedID)
            #expect(plan.taskCancellationAndReset == [key])
            #expect(relaunched.resetLegacyAttemptAfterTaskCancellation(key)
                == .committed(key, cleanupFailureCount: 0))
            #expect(relaunched.commitLegacyAttemptOwnershipMigration() == .notRequired)
        }
    }

    @Test func timedOutV4OwnerlessAdoptionRetryStillWaitsForDirtyCommit() async throws {
        try await withTemporaryDirectory { directory in
            let ratingKey = "plex:ownerless-timeout"
            try writeLegacyIndex(
                schemaVersion: 4,
                rows: [legacyRow(ratingKey: ratingKey, status: "failed", bytes: 12)],
                directory: directory)
            let writes = FirstBlockingAtomicWriteHarness()
            let retryFinished = DispatchSemaphore(value: 0)
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try writes.write(data, to: url) })
            let fixedID = DownloadAttemptID(rawValue: "ownerless-timeout-id")!
            let first = store.submitLegacyAttemptOwnershipMigration(idFactory: { _ in fixedID })
            #expect(await waitForSignal(writes.started, timeout: 1))
            guard case .failed(let timedOutPlan, .timedOut) = await store.resolve(first, timeout: 0.01)
            else {
                Issue.record("Expected bounded first adoption timeout")
                writes.release.signal()
                return
            }
            let key = DownloadAttemptKey(ratingKey: ratingKey, attemptID: fixedID)
            #expect(timedOutPlan.taskCancellationAndReset == [key])

            let retry = store.submitLegacyAttemptOwnershipMigration(idFactory: { _ in .generated() })
            Task.detached {
                _ = await store.resolve(retry, timeout: 1)
                retryFinished.signal()
            }
            #expect(!(await waitForSignal(retryFinished, timeout: 0.03)))
            writes.release.signal()
            #expect(await waitForSignal(retryFinished, timeout: 1))
            #expect(store.commitLegacyAttemptOwnershipMigration()
                == .committed(.init(taskCancellationAndReset: [key], cleanupOnly: [])))
        }
    }

    @Test func completedCleanupOnlyOwnershipIsReconstructedAfterRelaunch() throws {
        try withTemporaryDirectory { directory in
            let ratingKey = "jellyfin:legacy-cleanup"
            var row = legacyRow(ratingKey: ratingKey, status: "complete", bytes: 99)
            var metadata = try #require(row["metadata"] as? [String: Any])
            metadata["playSessionID"] = "cleanup-session"
            row["metadata"] = metadata
            try writeLegacyIndex(schemaVersion: 2, rows: [row], directory: directory)
            let fixedID = DownloadAttemptID(uuid: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!)
            let store = DownloadStore(baseDirectory: directory)
            guard case .committed(let plan) = store.commitLegacyAttemptOwnershipMigration(
                idFactory: { _ in fixedID }) else {
                Issue.record("Expected cleanup-only ownership migration")
                return
            }
            let expected = DownloadAttemptKey(ratingKey: ratingKey, attemptID: fixedID)
            #expect(plan.taskCancellationAndReset.isEmpty)
            #expect(plan.cleanupOnly == [expected])

            let relaunched = DownloadStore(baseDirectory: directory)
            guard case .committed(let relaunchedPlan) = relaunched.commitLegacyAttemptOwnershipMigration() else {
                Issue.record("Expected cleanup-only plan to survive relaunch")
                return
            }
            #expect(relaunchedPlan.taskCancellationAndReset.isEmpty)
            #expect(relaunchedPlan.cleanupOnly == [expected])
            #expect(relaunched.record(for: ratingKey)?.status == .complete)
        }
    }

    @Test func migrationCommitFailureRetriesSameIDWithoutDeletingPartial() throws {
        try withTemporaryDirectory { directory in
            let key = "plex:legacy-failure"
            let media = directory.appendingPathComponent("legacy.mp4")
            try Data(repeating: 7, count: 64).write(to: media)
            var row = legacyRow(ratingKey: key, status: "paused", bytes: 64)
            row["relativePath"] = media.lastPathComponent
            try writeLegacyIndex(schemaVersion: 2, rows: [row], directory: directory)
            let writes = AtomicWriteHarness(failFirstWrite: true)
            let store = DownloadStore(baseDirectory: directory,
                                      indexPersistence: .init { data, url in try writes.write(data, to: url) })
            let fixedID = DownloadAttemptID(uuid: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
            guard case .failed(let firstPlan, _) = store.commitLegacyAttemptOwnershipMigration(
                idFactory: { _ in fixedID }) else {
                Issue.record("Expected injected migration failure")
                return
            }
            #expect(firstPlan.taskCancellationAndReset.first?.attemptID == fixedID)
            #expect(FileManager.default.fileExists(atPath: media.path))
            guard case .committed(let secondPlan) = store.commitLegacyAttemptOwnershipMigration(
                idFactory: { _ in .generated() }) else {
                Issue.record("Expected dirty migration retry to commit")
                return
            }
            #expect(secondPlan.taskCancellationAndReset.first?.attemptID == fixedID)
            #expect(FileManager.default.fileExists(atPath: media.path))
        }
    }

    @Test func v3TopLevelNestedDisagreementFailsClosed() throws {
        try withTemporaryDirectory { directory in
            var row = legacyRow(ratingKey: "plex:shadow", status: "downloading", bytes: 1,
                                nestedAttemptID: "nested")
            row["attemptID"] = "top-level"
            try writeLegacyIndex(schemaVersion: 3, rows: [row], directory: directory)
            let store = DownloadStore(baseDirectory: directory)
            #expect(store.commitLegacyAttemptOwnershipMigration()
                == .malformedV3Rows(["plex:shadow"]))
        }
    }

    @Test func schemaV3NonterminalResetDiscardsStableResumeHeldAndWorkingButKeepsTerminalMedia() throws {
        try withTemporaryDirectory { directory in
            let activeKey = "plex:v3-partial"
            let completeKey = "plex:v3-complete"
            let attempt = "v3-attempt"
            let stable = directory.appendingPathComponent("partial.mp4")
            let resume = directory.appendingPathComponent("partial.resume")
            let held = directory.appendingPathComponent("partial.held")
            let completed = directory.appendingPathComponent("complete.mp4")
            for url in [stable, resume, held, completed] { try Data([1, 2, 3]).write(to: url) }
            var active = legacyRow(ratingKey: activeKey, status: "paused", bytes: 3,
                                   nestedAttemptID: attempt)
            active["attemptID"] = attempt
            active["relativePath"] = stable.lastPathComponent
            var metadata = try #require(active["metadata"] as? [String: Any])
            metadata["resumeDataRelativePath"] = resume.lastPathComponent
            metadata["heldRangeSegments"] = [[
                "offset": 0, "length": 3, "relativePath": held.lastPathComponent
            ]]
            active["metadata"] = metadata
            var complete = legacyRow(ratingKey: completeKey, status: "complete", bytes: 3)
            complete["relativePath"] = completed.lastPathComponent
            try writeLegacyIndex(schemaVersion: 3, rows: [active, complete], directory: directory)

            let store = DownloadStore(baseDirectory: directory)
            let id = try #require(DownloadAttemptID(rawValue: attempt))
            let key = DownloadAttemptKey(ratingKey: activeKey, attemptID: id)
            guard case .committed(let plan) = store.commitLegacyAttemptOwnershipMigration() else {
                Issue.record("Expected schema-v4 migration barrier")
                return
            }
            #expect(plan.taskCancellationAndReset == [key])
            // The durable working path exists in the row, but admission stays closed until reset.
            #expect(store.attemptWorkingFileLayout(for: key) == nil)
            let index = try #require(JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("index.json")))
                as? [String: Any])
            #expect(index["schemaVersion"] as? Int == 4)
            let rows = try #require(index["rows"] as? [[String: Any]])
            let activeOnDisk = try #require(rows.first { $0["ratingKey"] as? String == activeKey })
            let workingName = try #require(activeOnDisk["attemptWorkingRelativePath"] as? String)
            let working = directory.appendingPathComponent(workingName)
            try Data([4, 5, 6]).write(to: working)

            #expect(store.resetLegacyAttemptAfterTaskCancellation(key)
                == .committed(key, cleanupFailureCount: 0))
            for url in [stable, resume, held, working] {
                #expect(!FileManager.default.fileExists(atPath: url.path))
            }
            #expect(FileManager.default.fileExists(atPath: completed.path))
            #expect(store.record(for: completeKey)?.status == .complete)
            #expect(store.commitLegacyAttemptOwnershipMigration() == .notRequired)
        }
    }

    @Test func resetPhaseThreeFailureReloadsDurableCleanupBarrierAndRetries() throws {
        try withTemporaryDirectory { directory in
            let ratingKey = "plex:reset-retry"
            let media = directory.appendingPathComponent("reset-retry.mp4")
            try Data(repeating: 3, count: 32).write(to: media)
            var row = legacyRow(ratingKey: ratingKey, status: "paused", bytes: 32)
            row["relativePath"] = media.lastPathComponent
            try writeLegacyIndex(schemaVersion: 2, rows: [row], directory: directory)
            let writes = SelectedAtomicWriteFailureHarness(failingAttempts: [3])
            let store = DownloadStore(baseDirectory: directory,
                                      indexPersistence: .init { data, url in try writes.write(data, to: url) })
            let id = DownloadAttemptID(uuid: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
            guard case .committed(let plan) = store.commitLegacyAttemptOwnershipMigration(
                idFactory: { _ in id }), let key = plan.taskCancellationAndReset.first else {
                Issue.record("Expected committed migration plan")
                return
            }
            guard case .failed = store.resetLegacyAttemptAfterTaskCancellation(key) else {
                Issue.record("Expected injected phase-three persistence failure")
                return
            }
            #expect(!FileManager.default.fileExists(atPath: media.path))

            let relaunched = DownloadStore(baseDirectory: directory)
            guard case .committed(let retryPlan) = relaunched.commitLegacyAttemptOwnershipMigration(),
                  retryPlan.taskCancellationAndReset == [key] else {
                Issue.record("Expected durable reset barrier after phase-three crash")
                return
            }
            #expect(relaunched.resolveArtifactSynchronouslyForTests(
                through: relaunched.currentArtifactLifecycleWatermark()) == .completed)
            #expect(relaunched.resetLegacyAttemptAfterTaskCancellation(key)
                == .notPending)
            #expect(relaunched.commitLegacyAttemptOwnershipMigration() == .notRequired)
        }
    }

    @Test func legacyResetDoesNotDeletePathReferencedByAnotherCurrentRow() throws {
        try withTemporaryDirectory { directory in
            let shared = directory.appendingPathComponent("shared.resume")
            try Data([1, 2, 3]).write(to: shared)
            var a = legacyRow(ratingKey: "plex:shared-a", status: "paused", bytes: 3)
            var b = legacyRow(ratingKey: "plex:shared-b", status: "paused", bytes: 3)
            var metadataA = try #require(a["metadata"] as? [String: Any])
            var metadataB = try #require(b["metadata"] as? [String: Any])
            metadataA["resumeDataRelativePath"] = shared.lastPathComponent
            metadataB["resumeDataRelativePath"] = shared.lastPathComponent
            a["metadata"] = metadataA; b["metadata"] = metadataB
            try writeLegacyIndex(schemaVersion: 2, rows: [a, b], directory: directory)
            let store = DownloadStore(baseDirectory: directory)
            guard case .committed(let plan) = store.commitLegacyAttemptOwnershipMigration(),
                  plan.taskCancellationAndReset.count == 2 else {
                Issue.record("expected two reset owners"); return
            }
            let first = plan.taskCancellationAndReset.sorted { $0.ratingKey < $1.ratingKey }[0]
            #expect(store.resetLegacyAttemptAfterTaskCancellation(first)
                == .committed(first, cleanupFailureCount: 0))
            #expect(FileManager.default.fileExists(atPath: shared.path))
        }
    }

    @Test func legacyResetPreparedFailureDeletesNothingAndSameProcessRetryCompletes() throws {
        try withTemporaryDirectory { directory in
            let media = directory.appendingPathComponent("reset-prepared.mp4")
            try Data([1, 2]).write(to: media)
            var row = legacyRow(ratingKey: "plex:reset-prepared", status: "paused", bytes: 2)
            row["relativePath"] = media.lastPathComponent
            try writeLegacyIndex(schemaVersion: 2, rows: [row], directory: directory)
            let writes = SelectedAtomicWriteFailureHarness(failingAttempts: [2])
            let store = DownloadStore(baseDirectory: directory,
                indexPersistence: .init { data, url in try writes.write(data, to: url) })
            guard case .committed(let plan) = store.commitLegacyAttemptOwnershipMigration(),
                  let key = plan.taskCancellationAndReset.first else { return }
            guard case .failed = store.resetLegacyAttemptAfterTaskCancellation(key) else {
                Issue.record("expected prepared failure"); return
            }
            #expect(FileManager.default.fileExists(atPath: media.path))
            #expect(store.resetLegacyAttemptAfterTaskCancellation(key)
                == .committed(key, cleanupFailureCount: 0))
        }
    }

    @Test func legacyResetPartialDeletionFailureRetriesExactRemainingRecipe() throws {
        try withTemporaryDirectory { directory in
            let media = directory.appendingPathComponent("reset-partial.mp4")
            let resume = directory.appendingPathComponent("reset-partial.resume")
            try Data([1]).write(to: media); try Data([2]).write(to: resume)
            var row = legacyRow(ratingKey: "plex:reset-partial", status: "paused", bytes: 1)
            row["relativePath"] = media.lastPathComponent
            var metadata = try #require(row["metadata"] as? [String: Any])
            metadata["resumeDataRelativePath"] = resume.lastPathComponent
            row["metadata"] = metadata
            try writeLegacyIndex(schemaVersion: 2, rows: [row], directory: directory)
            let deletes = FailOneLegacyResetDelete(name: resume.lastPathComponent)
            let live = DownloadArtifactFilesystem.live
            let store = DownloadStore(baseDirectory: directory, artifactFilesystem: .init(
                writeAuthArtifact: live.writeAuthArtifact,
                removeItem: { url, fm in try deletes.remove(url, fm: fm) },
                fileExists: live.fileExists))
            guard case .committed(let plan) = store.commitLegacyAttemptOwnershipMigration(),
                  let key = plan.taskCancellationAndReset.first else { return }
            guard case .cleanupFailed(_, cleanupFailureCount: 1) =
                    store.resetLegacyAttemptAfterTaskCancellation(key) else {
                Issue.record("expected partial delete failure"); return
            }
            #expect(store.resetLegacyAttemptAfterTaskCancellation(key)
                == .committed(key, cleanupFailureCount: 0))
            #expect(!FileManager.default.fileExists(atPath: resume.path))
        }
    }

    @Test func legacyResetRelaunchesAfterDeletionBeforeTerminalWithoutHoldingStoreLock() async throws {
        try await withTemporaryDirectory { directory in
            let media = directory.appendingPathComponent("reset-hard-kill.mp4")
            try Data([9]).write(to: media)
            var row = legacyRow(ratingKey: "plex:reset-hard-kill", status: "paused", bytes: 1)
            row["relativePath"] = media.lastPathComponent
            try writeLegacyIndex(schemaVersion: 2, rows: [row], directory: directory)
            let writes = BlockingNthAtomicWriteHarness(3)
            let store = DownloadStore(baseDirectory: directory,
                indexPersistence: .init { data, url in try writes.write(data, to: url) })
            guard case .committed(let plan) = store.commitLegacyAttemptOwnershipMigration(),
                  let key = plan.taskCancellationAndReset.first else { return }
            let submission = store.submitLegacyResetAfterTaskCancellation(key)
            #expect(await waitForSignal(writes.started, timeout: 1))
            #expect(!FileManager.default.fileExists(atPath: media.path))
            let read = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { _ = store.records; read.signal() }
            #expect(await waitForSignal(read, timeout: 0.25))
            let relaunched = DownloadStore(baseDirectory: directory)
            #expect(relaunched.resolveArtifactSynchronouslyForTests(
                through: relaunched.currentArtifactLifecycleWatermark()) == .completed)
            writes.release.signal()
            #expect(await store.resolveLegacyReset(submission)
                == .committed(key, cleanupFailureCount: 0))
        }
    }

    @Test func legacyResetPostCancellationSubmissionJoinsRecoveredActiveHead() async throws {
        try await withTemporaryDirectory { directory in
            let media = directory.appendingPathComponent("reset-active-join.mp4")
            try Data([7]).write(to: media)
            var row = legacyRow(ratingKey: "plex:reset-active-join", status: "paused", bytes: 1)
            row["relativePath"] = media.lastPathComponent
            try writeLegacyIndex(schemaVersion: 2, rows: [row], directory: directory)

            let originalDelete = BlockingArtifactDelete(path: media.path)
            let live = DownloadArtifactFilesystem.live
            let original = DownloadStore(baseDirectory: directory, artifactFilesystem: .init(
                writeAuthArtifact: live.writeAuthArtifact,
                removeItem: { url, fm in try originalDelete.remove(url, fm: fm) },
                fileExists: live.fileExists))
            guard case .committed(let plan) = original.commitLegacyAttemptOwnershipMigration(),
                  let key = plan.taskCancellationAndReset.first else { return }
            let originalSubmission = original.submitLegacyResetAfterTaskCancellation(key)
            #expect(await waitForSignal(originalDelete.started, timeout: 1))

            let recoveredDelete = BlockingArtifactDelete(path: media.path)
            let recovered = DownloadStore(baseDirectory: directory, artifactFilesystem: .init(
                writeAuthArtifact: live.writeAuthArtifact,
                removeItem: { url, fm in try recoveredDelete.remove(url, fm: fm) },
                fileExists: live.fileExists))
            #expect(await waitForSignal(recoveredDelete.started, timeout: 1))
            guard case .accepted(let joined) = recovered.submitLegacyResetAfterTaskCancellation(key) else {
                Issue.record("expected post-cancellation submission to join recovered active head")
                recoveredDelete.release.signal(); originalDelete.release.signal(); return
            }
            recoveredDelete.release.signal()
            #expect(await recovered.resolveLegacyReset(.accepted(ticket: joined))
                == .committed(key, cleanupFailureCount: 0))
            originalDelete.release.signal()
            _ = await original.resolveLegacyReset(originalSubmission)
        }
    }

    @Test func legacyResetReservationRejectsConcurrentHeldBodyAdoption() async throws {
        try await withTemporaryDirectory { directory in
            let media = directory.appendingPathComponent("reset-reserved-adoption.mp4")
            try Data([8]).write(to: media)
            var legacy = legacyRow(ratingKey: "plex:reset-reserved", status: "paused", bytes: 1)
            legacy["relativePath"] = media.lastPathComponent
            try writeLegacyIndex(schemaVersion: 2, rows: [legacy], directory: directory)
            let blocker = BlockingArtifactDelete(path: media.path)
            let live = DownloadArtifactFilesystem.live
            let store = DownloadStore(baseDirectory: directory, artifactFilesystem: .init(
                writeAuthArtifact: live.writeAuthArtifact,
                removeItem: { url, fm in try blocker.remove(url, fm: fm) },
                fileExists: live.fileExists))
            let adopterID = DownloadAttemptID(uuid: UUID())
            let adopterRecord = makeRecord(
                ratingKey: "plex:adopter", title: "Adopter", directory: directory, bytes: 0,
                metadata: OfflineMetadata(ratingKey: "plex:adopter", title: "Adopter", type: "movie"))
            guard case .committed(let adopterKey) = store.createAttemptOwnedRecord(
                adopterRecord, attemptID: adopterID) else { return }
            guard case .committed(let plan) = store.commitLegacyAttemptOwnershipMigration(),
                  let resetKey = plan.taskCancellationAndReset.first(where: {
                      $0.ratingKey == "plex:reset-reserved"
                  }) else { return }
            let reset = store.submitLegacyResetAfterTaskCancellation(resetKey)
            #expect(await waitForSignal(blocker.started, timeout: 1))
            let segment = OfflineHeldRangeSegment(
                offset: 0, length: 1, relativePath: media.lastPathComponent)
            #expect(store.persistHeldRangeSegment(for: adopterKey, segment: segment)
                == .staleOrMissing)
            blocker.release.signal()
            #expect(await store.resolveLegacyReset(reset)
                == .committed(resetKey, cleanupFailureCount: 0))
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

    @Test func ownerlessTerminalDeletionUsesDurableLifecycleAndPreservesSharedArtifact() throws {
        try withTemporaryDirectory { directory in
            let shared = directory.appendingPathComponent("ownerless-shared.mp4")
            try Data([9]).write(to: shared)
            var ownerless = legacyRow(ratingKey: "plex:ownerless-delete", status: "complete", bytes: 1)
            ownerless["relativePath"] = shared.lastPathComponent
            var other = legacyRow(ratingKey: "plex:ownerless-other", status: "complete", bytes: 1)
            other["relativePath"] = shared.lastPathComponent
            try writeLegacyIndex(schemaVersion: 4, rows: [ownerless, other], directory: directory)
            let store = DownloadStore(baseDirectory: directory)
            store.remove(ratingKey: "plex:ownerless-delete")
            #expect(store.record(for: "plex:ownerless-delete") == nil)
            #expect(store.record(for: "plex:ownerless-other") != nil)
            #expect(FileManager.default.fileExists(atPath: shared.path))
        }
    }

    @Test func ownerlessTerminalPreparedFailureCanRetryInSameProcess() throws {
        try withTemporaryDirectory { directory in
            let media = directory.appendingPathComponent("ownerless-retry.mp4")
            try Data([1]).write(to: media)
            var row = legacyRow(ratingKey: "plex:ownerless-retry", status: "complete", bytes: 1)
            row["relativePath"] = media.lastPathComponent
            try writeLegacyIndex(schemaVersion: 4, rows: [row], directory: directory)
            let writes = SelectedAtomicWriteFailureHarness(failingAttempts: [1])
            let store = DownloadStore(baseDirectory: directory,
                indexPersistence: .init { data, url in try writes.write(data, to: url) })
            guard case .persistenceFailed = store.resolveRowDeletionSynchronously(
                store.submitOwnerlessTerminalRemoval(ratingKey: "plex:ownerless-retry")) else {
                Issue.record("expected prepared failure"); return
            }
            #expect(FileManager.default.fileExists(atPath: media.path))
            #expect(store.resolveRowDeletionSynchronously(
                store.submitOwnerlessTerminalRemoval(ratingKey: "plex:ownerless-retry"))
                != .staleOrMissing)
            #expect(store.record(for: "plex:ownerless-retry") == nil)
            #expect(!FileManager.default.fileExists(atPath: media.path))
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

    @Test func attemptOwnedRecordRejectsLegacyResetPendingRow() throws {
        try withTemporaryDirectory { directory in
            let ratingKey = "plex:legacy-pending"
            let previous = DownloadAttemptID(rawValue: "attempt-legacy")!
            let replacement = DownloadAttemptID(rawValue: "attempt-new")!
            try writeLegacyIndex(
                schemaVersion: 2,
                rows: [legacyRow(
                    ratingKey: ratingKey,
                    status: "downloading",
                    bytes: 42,
                    nestedAttemptID: previous.rawValue)],
                directory: directory)
            let store = DownloadStore(baseDirectory: directory)
            guard case .committed = store.commitLegacyAttemptOwnershipMigration() else {
                Issue.record("Expected migration to establish a pending reset barrier")
                return
            }
            let record = makeRecord(
                ratingKey: ratingKey, title: "Replacement", directory: directory, bytes: 0)
            #expect(store.createAttemptOwnedRecord(
                record, attemptID: replacement, replacing: previous)
                == .rejectedOwnership(
                    expectedPreviousOwner: DownloadAttemptKey(
                        ratingKey: ratingKey, attemptID: previous),
                    actualOwner: DownloadAttemptKey(ratingKey: ratingKey, attemptID: previous),
                    reason: .legacyResetPending))
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

    @Test func ownerlessPersistedSideAssetBundleFailsClosedOnLoad() throws {
        try withTemporaryDirectory { directory in
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
            var persistedMetadata = try #require(rows[0]["metadata"] as? [String: Any])
            persistedMetadata.removeValue(forKey: "sideAssetBundleOwner")
            rows[0]["metadata"] = persistedMetadata
            object["rows"] = rows
            try JSONSerialization.data(withJSONObject: object).write(to: indexURL, options: .atomic)

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

    @Test func ownerlessPlaybackFallbackRejectsActiveRows() throws {
        try withTemporaryDirectory { directory in
            let ratingKey = "plex:ownerless-active"
            let store = DownloadStore(baseDirectory: directory)
            store.upsert(DownloadRecord(
                ratingKey: ratingKey, title: "Ownerless",
                localURL: directory.appendingPathComponent("ownerless.mp4"), status: .queued,
                metadata: OfflineMetadata(ratingKey: ratingKey, title: "Ownerless", type: "movie")))

            #expect(!store.markCompleteIfUnverifiedOwnerlessTerminalRow(ratingKey: ratingKey))
            #expect(!store.setLocalPlaybackPositionForOwnerlessTerminalRow(
                ratingKey: ratingKey, positionMs: 5_000, durationMs: 60_000))
            #expect(store.record(for: ratingKey)?.status == .queued)
            #expect(store.record(for: ratingKey)?.metadata?.localPlaybackPositionMs == nil)
        }
    }

    @Test func ownerlessPlaybackFallbackPreservesLegacyTerminalRows() throws {
        try withTemporaryDirectory { directory in
            let ratingKey = "plex:ownerless-terminal"
            let store = DownloadStore(baseDirectory: directory)
            store.upsert(DownloadRecord(
                ratingKey: ratingKey, title: "Legacy Terminal",
                localURL: directory.appendingPathComponent("legacy-terminal.mp4"),
                status: .unverified,
                metadata: OfflineMetadata(
                    ratingKey: ratingKey, title: "Legacy Terminal", type: "movie")))

            #expect(store.markCompleteIfUnverifiedOwnerlessTerminalRow(ratingKey: ratingKey))
            #expect(store.setLocalPlaybackPositionForOwnerlessTerminalRow(
                ratingKey: ratingKey, positionMs: 7_000, durationMs: 60_000))
            let restored = DownloadStore(baseDirectory: directory)
            #expect(restored.record(for: ratingKey)?.attemptID == nil)
            #expect(restored.record(for: ratingKey)?.status == .complete)
            #expect(restored.record(for: ratingKey)?.metadata?.localPlaybackPositionMs == 7_000)
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

    private func legacyRow(ratingKey: String, status: String, bytes: Int,
                           nestedAttemptID: String? = nil) -> [String: Any] {
        var metadata: [String: Any] = [
            "ratingKey": ratingKey,
            "title": "Legacy",
            "type": "movie",
        ]
        if let nestedAttemptID { metadata["downloadAttemptID"] = nestedAttemptID }
        return [
            "ratingKey": ratingKey,
            "title": "Legacy",
            "relativePath": "legacy.mp4",
            "bytes": bytes,
            "progress": status == "complete" ? 1.0 : 0.5,
            "status": status,
            "metadata": metadata,
        ]
    }

    private func writeLegacyIndex(schemaVersion: Int?, rows: [[String: Any]],
                                  directory: URL) throws {
        let object: Any = schemaVersion.map { ["schemaVersion": $0, "rows": rows] } ?? rows
        try JSONSerialization.data(withJSONObject: object)
            .write(to: directory.appendingPathComponent("index.json"), options: .atomic)
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
