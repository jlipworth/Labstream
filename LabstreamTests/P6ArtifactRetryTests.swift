#if !os(tvOS)
import Foundation
import PMSKit
import Synchronization
import Testing
@testable import Labstream

@Suite(.downloadTestFiles)
struct P6ArtifactRetryTests {
    @Test("P6-pin-11 600 explicit failures of one durable head use bounded bookkeeping")
    func failedHeadGrowth() async throws {
        let fixture = try P6Fixture()
        let initial = fixture.store()
        let key = try fixture.seed(initial)
        let live = DownloadArtifactFilesystem.live
        let store = DownloadTestFiles.store(baseDirectory: fixture.directory, artifactFilesystem: .init(
            writeAuthArtifact: { _, _, _ in throw CocoaError(.fileWriteUnknown) },
            removeItem: live.removeItem, fileExists: live.fileExists))
        let submission = store.submitResumeData(for: key, Data([1]))
        guard case .accepted(let first) = submission else { Issue.record("first head rejected"); return }
        guard case .failed(.artifact) = await store.resolveArtifact(first, deadline: .after(30)) else { Issue.record("first head did not fail"); return }
        // Every retry is the real recovery dispatcher for the SAME durable intent; no successor
        // is appended and the head never succeeds. Its prepared recipe remains on disk.
        for _ in 2...600 {
            let retry = try #require(store.recoverArtifactTicketsForP6Testing().first { $0.intentID == first.intentID })
            #expect(retry.intentID == first.intentID)
            guard case .failed(.artifact) = await store.resolveArtifact(retry, deadline: .after(30)) else { Issue.record("retry did not fail"); return }
        }
        let counts = store.artifactEntryCountsForP6Testing
        #expect(counts.live <= 1)

        #expect(counts.retired <= 512)
        let index = try Data(contentsOf: fixture.directory.appendingPathComponent("index.json"))
        #expect(String(decoding: index, as: UTF8.self).contains(first.intentID.uuidString))
    }

    @Test("P6-pin-02 amendment: registered exact waiter survives the 512 retirement cap")
    func registeredWaiterRetention() async throws {
        let hold = P6Hold()
        let coordinator = DownloadArtifactLifecycleCoordinator(resolutionWillRead: { _ in hold.hit() })
        let key = DownloadAttemptKey(ratingKey: "plex:fixture", attemptID: .generated())
        let first = coordinator.register(key: key, generation: 1, intentID: UUID(), preparedRevision: .init(revision: 1))
        coordinator.failArtifact(first, errorType: "Original")
        hold.arm()
        defer { hold.release.signal() }
        // Synchronous coordinator waits belong on a dedicated thread, never the cooperative
        // executor whose scheduling this test is trying to observe.
        let resultAcknowledgement = P6Acknowledgement<DownloadArtifactLifecycleCoordinator.FlushResult>()
        Thread.detachNewThread { resultAcknowledgement.signal(coordinator.waitSynchronously(for: first)) }
        try #require(await hold.acknowledgement.wait())
        coordinator.abandonIntent(first.intentID)
        for round in 2...601 {
            let ticket = coordinator.register(key: key, generation: 1, intentID: UUID(), preparedRevision: .init(revision: UInt64(round)))
            coordinator.failArtifact(ticket, errorType: "Other")
            coordinator.abandonIntent(ticket.intentID)
        }
        #expect(coordinator.retiredFailureCountForTesting == 512)
        hold.release.signal()
        let result = await resultAcknowledgement.wait()
        #expect(result == .failed(.artifact(errorType: "Original")))

    }

    @Test("P6-pin-11 an unrelated successful index commit does not retry a failed artifact head")
    func unrelatedCommitDoesNotRetry() async throws {
        let fixture = try P6Fixture()
        let initial = fixture.store()
        let key = try fixture.seed(initial)
        let attempts = Mutex(0)
        let filesystem = DownloadArtifactFilesystem(
            writeAuthArtifact: { _, _, _ in attempts.withLock { $0 += 1 }; throw CocoaError(.fileWriteUnknown) },
            removeItem: DownloadArtifactFilesystem.live.removeItem,
            fileExists: DownloadArtifactFilesystem.live.fileExists)
        let store = DownloadTestFiles.store(baseDirectory: fixture.directory, artifactFilesystem: filesystem)
        let submission = store.submitResumeData(for: key, Data([1]))
        guard case .artifactWriteFailed = await store.resolve(submission, deadline: .after(30)) else { Issue.record("head did not fail"); return }
        let before = attempts.withLock { $0 }
        let other = fixture.record("other", status: .paused, ratingKey: "plex:other")
        _ = store.createAttemptOwnedRecord(other, attemptID: other.attemptID!)
        // Queue acknowledgement observes already-scheduled work without explicitly requesting
        // recovery (capturing currentArtifactLifecycleWatermark would itself be a retry trigger).
        await store.drainArtifactWorkerForP6Testing()
        let after = attempts.withLock { $0 }
        #expect(after == before)

    }
    @Test("unrelated successful artifact completion preserves a failed head's suppression")
    func unrelatedArtifactDoesNotRetryFailedHead() async throws {
        let fixture = try P6Fixture()
        let initial = fixture.store()
        let key = try fixture.seed(initial)
        let other = fixture.record("other", status: .paused, ratingKey: "plex:other", filename: "other.mp4")
        try #require(initial.createAttemptOwnedRecord(other, attemptID: other.attemptID!) == .committed(
            .init(ratingKey: other.ratingKey, attemptID: other.attemptID!)))
        let attempts = Mutex(0)
        let live = DownloadArtifactFilesystem.live
        let store = DownloadTestFiles.store(baseDirectory: fixture.directory, artifactFilesystem: .init(
            writeAuthArtifact: { data, url, manager in
                if data == Data([1]) {
                    attempts.withLock { $0 += 1 }
                    throw CocoaError(.fileWriteUnknown)
                }
                try live.writeAuthArtifact(data, url, manager)
            }, removeItem: live.removeItem, fileExists: live.fileExists))
        guard case .artifactWriteFailed = await store.resolve(store.submitResumeData(for: key, Data([1])), deadline: .after(2)) else {
            Issue.record("head did not fail"); return
        }
        let before = attempts.withLock { $0 }
        let otherKey = DownloadAttemptKey(ratingKey: other.ratingKey, attemptID: other.attemptID!)
        #expect(await store.resolve(store.submitResumeData(for: otherKey, Data([2])), deadline: .after(2)) == .applied)
        await store.drainArtifactWorkerForP6Testing()
        #expect(attempts.withLock { $0 } == before)
        // Explicit recovery still retries the failed head.
        let retry = try #require(store.recoverArtifactTicketsForP6Testing().first { $0.key == key })
        _ = await store.resolveArtifact(retry, deadline: .after(2))
        #expect(attempts.withLock { $0 } == before + 1)
    }

    @Test("a retry beyond a captured watermark still gates its unresolved durable intent")
    func retryPreservesBoundaryAuthority() async {
        let coordinator = DownloadArtifactLifecycleCoordinator()
        let key = DownloadAttemptKey(ratingKey: "plex:fixture", attemptID: .generated())
        let intent = UUID()
        let first = coordinator.register(key: key, generation: 1, intentID: intent, preparedRevision: .init(revision: 1))
        coordinator.failArtifact(first, errorType: "Original")
        let watermark = coordinator.currentWatermark
        let retry = coordinator.register(key: key, generation: 1, intentID: intent, preparedRevision: .init(revision: 2))
        #expect(await coordinator.flush(through: watermark, timeout: 0.01) == .timedOut(sequence: watermark.sequence))
        coordinator.complete(retry)
        #expect(await coordinator.flush(through: watermark, timeout: 0.01) == .completed)
        #expect(coordinator.waitSynchronously(for: first) == .failed(.artifact(errorType: "Original")))
    }

}
#endif
