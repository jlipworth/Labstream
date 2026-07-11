import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite("DownloadStore attempt-owned checkpoints")
struct DownloadStoreAttemptOwnedCheckpointTests {
    @Test func staleAttemptCannotReadOrMutateReplacementCheckpointState() throws {
        try withStore { store, directory in
            let a = key("plex:checkpoint", "attempt-a")
            let b = key("plex:checkpoint", "attempt-b")
            let media = directory.appendingPathComponent("checkpoint.mp4")
            try Data(repeating: 7, count: 7).write(to: media)
            #expect(created(store, key: a, media: media))
            #expect(created(store, key: b, media: media, replacing: a.attemptID))

            #expect(store.setResumeData(for: b, Data("owner-b".utf8), displayBytes: 12)
                    == .applied)
            #expect(store.setRangeValidator(for: b, "etag-b") == .applied)
            #expect(store.setSourcePartSize(for: b, 70) == .applied)

            #expect(store.setResumeData(for: a, Data("stale-a".utf8)) == .staleOrMissing)
            #expect(store.clearResumeData(for: a) == .staleOrMissing)
            #expect(store.setRangeValidator(for: a, "etag-a") == .staleOrMissing)
            #expect(store.clearRangeValidator(for: a) == .staleOrMissing)
            #expect(store.setSourcePartSize(for: a, 999) == .staleOrMissing)
            #expect(store.resetStaticRangeProgressToDurableCheckpoint(for: a)
                    == .staleOrMissing)

            #expect(store.resumeData(for: a) == nil)
            #expect(!store.hasResumeData(for: a))
            #expect(store.resumeDisplayBytes(for: a) == nil)
            #expect(store.rangeValidator(for: a) == nil)
            #expect(store.sourcePartSize(for: a) == nil)
            #expect(store.sourceExactBytes(for: a) == nil)
            #expect(store.durableStaticRangeCheckpointSize(for: a) == nil)
            #expect(store.staticRangeRecoveryEvidence(for: a) == nil)

            #expect(store.resumeData(for: b) == Data("owner-b".utf8))
            #expect(store.rangeValidator(for: b) == "etag-b")
            #expect(store.sourcePartSize(for: b) == 70)
            #expect(store.sourceExactBytes(for: b) == 70)
            #expect(store.durableStaticRangeCheckpointSize(for: b) == 7)
            #expect(store.staticRangeRecoveryEvidence(for: b)?.durableBytes == 7)
        }
    }

    @Test func heldManifestOperationsAreExactAttemptScoped() throws {
        try withStore { store, directory in
            let a = key("jellyfin:held", "attempt-a")
            let b = key("jellyfin:held", "attempt-b")
            let media = directory.appendingPathComponent("held.mkv")
            #expect(created(store, key: a, media: media))
            #expect(created(store, key: b, media: media, replacing: a.attemptID))
            let segment = OfflineHeldRangeSegment(
                offset: 64, length: 4, relativePath: "held-owner-b.body")
            let body = directory.appendingPathComponent(segment.relativePath)
            try Data([1, 2, 3, 4]).write(to: body)
            guard case .accepted = store.persistHeldRangeSegment(for: b, segment: segment) else {
                Issue.record("Expected B manifest persist")
                return
            }

            #expect(store.persistHeldRangeSegment(for: a, segment: segment) == .staleOrMissing)
            #expect(store.removeHeldRangeSegment(for: a, offset: segment.offset)
                    == .staleOrMissing)
            #expect(store.takeHeldRangeSegments(for: a) == .staleOrMissing)
            #expect(store.purgeHeldRangeSegments(for: a) == .staleOrMissing)
            #expect(store.record(for: b)?.metadata?.heldRangeSegments == [segment])
            #expect(FileManager.default.fileExists(atPath: body.path))

            guard case .purged(let purge) = store.purgeHeldRangeSegments(for: b) else {
                Issue.record("Expected B purge")
                return
            }
            #expect(purge.removal.committed)
            #expect(purge.removedRelativePaths == [segment.relativePath])
            #expect(purge.failedRelativePaths.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: body.path))
        }
    }

    @Test func resumeWriteReportsIndexFaultAndLaterFullSnapshotCommitsIt() throws {
        try withStore { initial, directory in
            let owner = key("emby:resume-fault", "attempt-a")
            let media = directory.appendingPathComponent("resume-fault.mp4")
            #expect(created(initial, key: owner, media: media))
            let writes = FailFirstIndexWrite()
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try writes.write(data, to: url) })

            guard case .persistenceFailed = store.setResumeData(
                for: owner, Data("resume".utf8), displayBytes: 6) else {
                Issue.record("Expected observable resume manifest failure")
                return
            }
            #expect(store.resumeData(for: owner) == Data("resume".utf8))
            #expect(DownloadStore(baseDirectory: directory).resumeData(for: owner) == nil)

            #expect(store.setRangeValidator(for: owner, "retry-barrier") == .applied)
            let restored = DownloadStore(baseDirectory: directory)
            #expect(restored.resumeData(for: owner) == Data("resume".utf8))
            #expect(restored.rangeValidator(for: owner) == "retry-barrier")
            #expect(writes.count == 2)
        }
    }

    @Test func heldPurgeDoesNotDeleteBodyBeforeManifestCommit() throws {
        try withStore { initial, directory in
            let owner = key("plex:purge-fault", "attempt-a")
            let media = directory.appendingPathComponent("purge-fault.mp4")
            let segment = OfflineHeldRangeSegment(
                offset: 128, length: 3, relativePath: "purge-fault.body")
            let body = directory.appendingPathComponent(segment.relativePath)
            #expect(created(initial, key: owner, media: media))
            try Data([4, 5, 6]).write(to: body)
            guard case .accepted = initial.persistHeldRangeSegment(
                for: owner, segment: segment) else {
                Issue.record("Expected initial manifest")
                return
            }
            let writes = FailFirstIndexWrite()
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try writes.write(data, to: url) })

            guard case .purged(let failed) = store.purgeHeldRangeSegments(for: owner) else {
                Issue.record("Expected accepted purge")
                return
            }
            #expect(!failed.removal.committed)
            #expect(failed.removedRelativePaths.isEmpty)
            #expect(FileManager.default.fileExists(atPath: body.path))
            #expect(DownloadStore(baseDirectory: directory)
                .record(for: owner)?.metadata?.heldRangeSegments == [segment])

            guard case .accepted(let retry) = store.takeHeldRangeSegments(for: owner) else {
                Issue.record("Expected no-op durability retry")
                return
            }
            #expect(retry.committed)
            #expect(DownloadStore(baseDirectory: directory)
                .record(for: owner)?.metadata?.heldRangeSegments == nil)
            #expect(FileManager.default.fileExists(atPath: body.path))
        }
    }

    @Test func checkpointResetReportsFaultWithoutBlessingStaleOwner() throws {
        try withStore { initial, directory in
            let owner = key("plex:reset-fault", "attempt-a")
            let media = directory.appendingPathComponent("reset-fault.mp4")
            try Data([1, 2, 3]).write(to: media)
            #expect(created(initial, key: owner, media: media, bytes: 99, progress: 0.99))
            let writes = FailFirstIndexWrite()
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try writes.write(data, to: url) })

            guard case .persistenceFailed(let bytes, _) =
                    store.resetStaticRangeProgressToDurableCheckpoint(
                        for: owner, expectedBytes: 100) else {
                Issue.record("Expected observable checkpoint reset failure")
                return
            }
            #expect(bytes == 3)
            #expect(DownloadStore(baseDirectory: directory).record(for: owner)?.bytes == 99)
            #expect(store.setRangeValidator(for: owner, "retry") == .applied)
            #expect(DownloadStore(baseDirectory: directory).record(for: owner)?.bytes == 3)
        }
    }

    @Test func legacyResetBarrierRejectsCheckpointOwnership() throws {
        try withStore { _, directory in
            let ratingKey = "plex:reset-pending"
            let attemptID = "legacy-attempt"
            let object: [String: Any] = [
                "schemaVersion": 2,
                "rows": [[
                    "ratingKey": ratingKey,
                    "title": "Legacy",
                    "relativePath": "legacy.mp4",
                    "bytes": 4,
                    "progress": 0.5,
                    "status": "downloading",
                    "metadata": [
                        "ratingKey": ratingKey,
                        "title": "Legacy",
                        "type": "movie",
                        "downloadAttemptID": attemptID,
                        "resumeMode": "staticByteRange",
                        "rangeValidator": "legacy-etag",
                        "sourcePartSize": 8,
                    ],
                ]],
            ]
            try JSONSerialization.data(withJSONObject: object).write(
                to: directory.appendingPathComponent("index.json"), options: .atomic)
            let store = DownloadStore(baseDirectory: directory)
            guard case .committed(let plan) = store.commitLegacyAttemptOwnershipMigration(),
                  let pending = plan.taskCancellationAndReset.first else {
                Issue.record("Expected a pending legacy reset owner")
                return
            }

            #expect(store.setResumeData(for: pending, Data([1])) == .staleOrMissing)
            #expect(store.clearResumeData(for: pending) == .staleOrMissing)
            #expect(store.setRangeValidator(for: pending, "new") == .staleOrMissing)
            #expect(store.setSourcePartSize(for: pending, 9) == .staleOrMissing)
            #expect(store.takeHeldRangeSegments(for: pending) == .staleOrMissing)
            #expect(store.resetStaticRangeProgressToDurableCheckpoint(for: pending)
                    == .staleOrMissing)
            #expect(store.rangeValidator(for: pending) == nil)
            #expect(store.sourcePartSize(for: pending) == nil)
            #expect(store.staticRangeRecoveryEvidence(for: pending) == nil)
        }
    }

    private func key(_ ratingKey: String, _ attempt: String) -> DownloadAttemptKey {
        DownloadAttemptKey(
            ratingKey: ratingKey,
            attemptID: DownloadAttemptID(rawValue: attempt)!)
    }

    private func created(
        _ store: DownloadStore,
        key: DownloadAttemptKey,
        media: URL,
        replacing: DownloadAttemptID? = nil,
        bytes: Int = 0,
        progress: Double = 0
    ) -> Bool {
        let metadata = OfflineMetadata(
            ratingKey: key.ratingKey,
            title: "Item",
            type: "movie",
            resumeMode: .staticByteRange)
        let record = DownloadRecord(
            ratingKey: key.ratingKey,
            attemptID: key.attemptID,
            title: "Item",
            localURL: media,
            bytes: bytes,
            progress: progress,
            status: .downloading,
            metadata: metadata)
        if case .committed(let actual) = store.createAttemptOwnedRecord(
            record, attemptID: key.attemptID, replacing: replacing) {
            return actual == key
        }
        return false
    }

    private func withStore(
        _ body: (DownloadStore, URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attempt-checkpoint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(DownloadStore(baseDirectory: directory), directory)
    }
}

private final class FailFirstIndexWrite: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0

    func write(_ data: Data, to url: URL) throws {
        let shouldFail = lock.withLock {
            count += 1
            return count == 1
        }
        if shouldFail { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: url, options: .atomic)
    }
}
