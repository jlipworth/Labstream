import Foundation
import PMSKit
import Testing
@testable import Labstream

struct DownloadStorePersistenceTests {
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

    @Test func freshStoreRestoresWriterBackedIndexAtSchemaV3() throws {
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
            #expect(index["schemaVersion"] as? Int == 3)

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
            #expect(relaunched.resetLegacyAttemptAfterTaskCancellation(key)
                == .committed(key, cleanupFailureCount: 0))
            #expect(relaunched.commitLegacyAttemptOwnershipMigration() == .notRequired)
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

    @Test func subtitleRepairPersistsThroughInjectedWriter() throws {
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

            #expect(writes.attemptCount == 1)
            let repairedTrack = try #require(
                repaired.records.first?.metadata?.offlineTextSubtitles?.first
            )
            #expect(repairedTrack.id == 7)
            #expect(repairedTrack.codec == "srt")
            #expect(repairedTrack.relativePath == subtitleURL.lastPathComponent)

            let restored = DownloadStore(baseDirectory: directory)
            #expect(restored.records.first?.metadata?.offlineTextSubtitles == [repairedTrack])
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
