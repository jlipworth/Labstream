import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite("DownloadStore attempt-owned checkpoints")
struct DownloadStoreAttemptOwnedCheckpointTests {
    @Test @MainActor func orderedAsyncCoordinatorDeliversOverlappingSameKeyCompletions() async {
        let coordinator = OrderedAsyncWorkCoordinator<String, Int>()
        let (stream, continuation) = AsyncStream.makeStream(of: Int.self)
        coordinator.enqueue(key: "same-owner", operation: { 1 }) {
            continuation.yield($0)
        }
        coordinator.enqueue(key: "same-owner", operation: { 2 }) {
            continuation.yield($0)
            continuation.finish()
        }
        var received: [Int] = []
        for await value in stream { received.append(value) }
        #expect(received == [1, 2])
    }

    @Test func staticCheckpointStatRunsOffStoreLock() async throws {
        try await withStoreAsync { initial, directory in
            let owner = key("plex:checkpoint-off-lock", "attempt-a")
            let media = directory.appendingPathComponent("checkpoint-off-lock.mp4")
            #expect(created(initial, key: owner, media: media, bytes: 90, progress: 0.9))
            let working = try #require(initial.attemptWorkingFileURL(for: owner))
            try Data([1, 2, 3]).write(to: working)
            let gate = BlockCheckpointStat()
            let live = DownloadStaticCheckpointFilesystem.live
            let store = DownloadStore(
                baseDirectory: directory,
                checkpointFilesystem: .init(
                    exists: live.exists,
                    size: { url in gate.size(url, using: live.size) },
                    durableCopy: live.durableCopy))
            guard case .accepted(let ticket) = store.submitStaticRangeCheckpointReset(
                for: owner, expectedBytes: 100) else {
                Issue.record("checkpoint submission rejected"); return
            }
            #expect(await signal(gate.started, timeout: 1))
            let readerFinished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                _ = store.record(for: owner)
                readerFinished.signal()
            }
            #expect(await signal(readerFinished, timeout: 0.25))
            gate.release.signal()
            #expect(store.resolveStaticCheckpointSynchronously(.accepted(ticket: ticket))
                == .applied(bytes: 3))
            #expect(store.record(for: owner)?.bytes == 3)
        }
    }

    @Test func delayedStaticCheckpointResolversRetainAllTypedOutcomesPast128() async throws {
        try await withStoreAsync { store, directory in
            let owner = key("plex:checkpoint-many-results", "attempt-a")
            let media = directory.appendingPathComponent("checkpoint-many-results.mp4")
            #expect(created(store, key: owner, media: media))
            let working = try #require(store.attemptWorkingFileURL(for: owner))
            try Data([1]).write(to: working)
            let submissions = (1...140).map {
                store.submitStaticRangeCheckpointReset(for: owner, expectedBytes: $0 + 1)
            }
            guard case .committed = await store.flushLifecycleAndPersistence(
                through: store.currentPersistenceTicket(),
                artifactWatermark: store.currentArtifactLifecycleWatermark(), timeout: 5) else {
                Issue.record("checkpoint queue did not drain"); return
            }
            #expect(store.staticCheckpointOutcomeCountForTests() == 140)
            for submission in submissions {
                switch store.resolveStaticCheckpointSynchronously(submission) {
                case .applied(bytes: 1), .unchanged(bytes: 1): break
                default: Issue.record("typed checkpoint outcome was lost")
                }
            }
            #expect(store.staticCheckpointOutcomeCountForTests() == 0)
        }
    }

    @Test func overlappingStaticCheckpointResolversCompleteInOrderForSameOwner() async throws {
        try await withStoreAsync { initial, directory in
            let owner = key("plex:checkpoint-overlap", "attempt-a")
            let media = directory.appendingPathComponent("checkpoint-overlap.mp4")
            #expect(created(initial, key: owner, media: media, bytes: 9, progress: 0.9))
            let working = try #require(initial.attemptWorkingFileURL(for: owner))
            try Data([1, 2, 3]).write(to: working)
            let gate = BlockCheckpointStat()
            let live = DownloadStaticCheckpointFilesystem.live
            let store = DownloadStore(
                baseDirectory: directory,
                checkpointFilesystem: .init(
                    exists: live.exists,
                    size: { url in gate.size(url, using: live.size) },
                    durableCopy: live.durableCopy))
            let first = store.submitStaticRangeCheckpointReset(for: owner, expectedBytes: 10)
            let second = store.submitStaticRangeCheckpointReset(for: owner, expectedBytes: 20)
            #expect(await signal(gate.started, timeout: 1))
            async let firstResult = store.resolveStaticCheckpoint(first)
            async let secondResult = store.resolveStaticCheckpoint(second)
            gate.release.signal()
            gate.release.signal()
            #expect(await firstResult == .applied(bytes: 3))
            #expect(await secondResult == .applied(bytes: 3))
            #expect(store.record(for: owner)?.progress == 0.15)
            #expect(store.staticCheckpointOutcomeCountForTests() == 0)
        }
    }

    @Test func staticCheckpointSubmissionRejectsDeletionReservation() throws {
        try withStore { store, directory in
            let owner = key("emby:checkpoint-delete-fence", "attempt-a")
            let media = directory.appendingPathComponent("checkpoint-delete-fence.mp4")
            #expect(created(store, key: owner, media: media))
            let server = try #require(DurableDownloadCleanupIntent.ServerIdentity(
                baseURL: URL(string: "https://emby.example")!,
                serverID: "server-1", userID: "user-1"))
            let cleanup = try #require(DurableDownloadCleanupIntent(
                id: UUID(), attemptKey: owner, backend: .emby, server: server,
                operation: .activeEncoding(playSessionID: "session-1")))
            #expect(store.markDeletionPending(for: owner, cleanupIntents: [cleanup]) == .applied)
            #expect(store.submitStaticRangeCheckpointReset(for: owner) == .staleOrMissing)
        }
    }

    @Test func staticCheckpointSubmissionRejectsPromotionReservation() async throws {
        try await withStoreAsync { initial, directory in
            let owner = key("plex:checkpoint-promotion-fence", "attempt-a")
            let media = directory.appendingPathComponent("checkpoint-promotion-fence.mp4")
            #expect(created(initial, key: owner, media: media))
            let working = try #require(initial.attemptWorkingFileURL(for: owner))
            try Data([1, 2]).write(to: working)
            let gate = BlockFirstHeldIndexWrite()
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try gate.write(data, to: url) })
            let promotion = store.submitValidatedPromotion(
                for: owner, terminalStatus: .complete)
            #expect(store.submitStaticRangeCheckpointReset(for: owner) == .staleOrMissing)
            gate.release.signal()
            #expect(await store.resolveValidatedPromotion(promotion)
                == .promoted(owner, bytes: 2, status: .complete))
        }
    }

    @Test func terminalCheckpointCopyRunsOffStoreLockAndRecoversAfterCopyFailure() async throws {
        try await withStoreAsync { initial, directory in
            let owner = key("plex:checkpoint-copy-recovery", "attempt-a")
            let stable = directory.appendingPathComponent("checkpoint-copy-recovery.mp4")
            #expect(created(initial, key: owner, media: stable))
            let working = try #require(initial.attemptWorkingFileURL(for: owner))
            try Data([4, 5, 6, 7]).write(to: working)
            #expect(initial.promoteValidatedAttempt(for: owner, terminalStatus: .complete)
                == .promoted(owner, bytes: 4, status: .complete))

            let gate = BlockCheckpointCopy(failAfterRelease: true)
            let live = DownloadStaticCheckpointFilesystem.live
            let failing = DownloadStore(
                baseDirectory: directory,
                checkpointFilesystem: .init(
                    exists: live.exists,
                    size: live.size,
                    durableCopy: { source, destination, temporary in
                        try gate.copy(source, destination, temporary)
                    }))
            guard case .accepted(let ticket) = failing.submitStaticRangeCheckpointReset(
                for: owner, expectedBytes: 10) else {
                Issue.record("terminal checkpoint submission rejected"); return
            }
            #expect(await signal(gate.started, timeout: 1))
            let readerFinished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                _ = failing.record(for: owner)
                readerFinished.signal()
            }
            #expect(await signal(readerFinished, timeout: 0.25))
            gate.release.signal()
            guard failing.resolveStaticCheckpointSynchronously(.accepted(ticket: ticket))
                    == .staleOrMissing else {
                Issue.record("expected injected copy failure"); return
            }

            // The prepared copy recipe survived the process boundary. Launch recovery retries the
            // idempotent copy, publishes the exact-attempt working path, and retains stable bytes.
            let relaunched = DownloadStore(baseDirectory: directory)
            #expect(relaunched.resolveArtifactSynchronouslyForTests(
                through: relaunched.currentArtifactLifecycleWatermark()) == .completed)
            #expect(relaunched.record(for: owner)?.bytes == 4)
            #expect(relaunched.record(for: owner)?.progress == 0.4)
            #expect(relaunched.staticCheckpointOutcomeCountForTests() == 0)
            let reconstructed = try #require(
                relaunched.attemptStagingURL(for: owner, stableURL: stable))
            #expect(FileManager.default.fileExists(atPath: reconstructed.path))
            #expect(FileManager.default.fileExists(atPath: stable.path))
            #expect(relaunched.setStatus(for: owner, .failed) == .applied)
            #expect(relaunched.attemptWorkingFileURL(for: owner) == reconstructed)
        }
    }

    @Test func staticCheckpointTerminalFailureRestartsThroughSameProcessSuccessor() async throws {
        try await withStoreAsync { initial, directory in
            let owner = key("plex:checkpoint-terminal-retry", "attempt-a")
            let media = directory.appendingPathComponent("checkpoint-terminal-retry.mp4")
            #expect(created(initial, key: owner, media: media, bytes: 9, progress: 0.9))
            let working = try #require(initial.attemptWorkingFileURL(for: owner))
            try Data([1, 2]).write(to: working)
            let writes = FailNthIndexWrite(2)
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try writes.write(data, to: url) })
            let first = store.submitStaticRangeCheckpointReset(for: owner, expectedBytes: 10)
            guard case .persistenceFailed(bytes: 2, _) =
                    store.resolveStaticCheckpointSynchronously(first) else {
                Issue.record("expected terminal snapshot failure"); return
            }
            let successor = store.submitStaticRangeCheckpointReset(for: owner, expectedBytes: 20)
            #expect(await store.resolveStaticCheckpoint(successor) == .applied(bytes: 2))
            #expect(store.record(for: owner)?.bytes == 2)
            #expect(store.record(for: owner)?.progress == 0.1)
        }
    }

    @Test func copiedTerminalCheckpointReplaysAfterPreTerminalCommitCrash() throws {
        try withStore { initial, directory in
            let owner = key("plex:checkpoint-post-copy-crash", "attempt-a")
            let stable = directory.appendingPathComponent("checkpoint-post-copy-crash.mp4")
            #expect(created(initial, key: owner, media: stable))
            let working = try #require(initial.attemptWorkingFileURL(for: owner))
            try Data([3, 4, 5]).write(to: working)
            #expect(initial.promoteValidatedAttempt(for: owner, terminalStatus: .complete)
                == .promoted(owner, bytes: 3, status: .complete))
            let writes = FailNthIndexWrite(2)
            let failing = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try writes.write(data, to: url) })
            guard case .persistenceFailed(bytes: 3, _) =
                    failing.resetStaticRangeProgressToDurableCheckpoint(
                        for: owner, expectedBytes: 10) else {
                Issue.record("expected post-copy terminal failure"); return
            }
            let reconstructed = try #require(
                failing.attemptStagingURL(for: owner, stableURL: stable))
            #expect(FileManager.default.fileExists(atPath: reconstructed.path))
            #expect(FileManager.default.fileExists(atPath: stable.path))

            let relaunched = DownloadStore(baseDirectory: directory)
            #expect(relaunched.resolveArtifactSynchronouslyForTests(
                through: relaunched.currentArtifactLifecycleWatermark()) == .completed)
            #expect(relaunched.record(for: owner)?.bytes == 3)
            #expect(relaunched.record(for: owner)?.progress == 0.3)
            #expect(relaunched.staticCheckpointOutcomeCountForTests() == 0)
        }
    }

    @Test func relaunchReplaysPreparedCheckpointWhileOriginalWorkerIsBlockedPostCopy() async throws {
        try await withStoreAsync { initial, directory in
            let owner = key("plex:checkpoint-hard-kill-window", "attempt-a")
            let stable = directory.appendingPathComponent("checkpoint-hard-kill-window.mp4")
            #expect(created(initial, key: owner, media: stable))
            let working = try #require(initial.attemptWorkingFileURL(for: owner))
            try Data([6, 7, 8, 9]).write(to: working)
            #expect(initial.promoteValidatedAttempt(for: owner, terminalStatus: .complete)
                == .promoted(owner, bytes: 4, status: .complete))
            let gate = BlockAfterCheckpointCopy()
            let live = DownloadStaticCheckpointFilesystem.live
            let original = DownloadStore(
                baseDirectory: directory,
                checkpointFilesystem: .init(
                    exists: live.exists, size: live.size,
                    durableCopy: { source, destination, temporary in
                        try gate.copy(source, destination, temporary, using: live.durableCopy)
                    }))
            let submission = original.submitStaticRangeCheckpointReset(
                for: owner, expectedBytes: 10)
            #expect(await signal(gate.copied, timeout: 1))

            // Disk still contains only the prepared recipe: the original worker has copied the
            // body but cannot enqueue its terminal row. A fresh process must replay that recipe.
            let relaunched = DownloadStore(baseDirectory: directory)
            #expect(relaunched.resolveArtifactSynchronouslyForTests(
                through: relaunched.currentArtifactLifecycleWatermark()) == .completed)
            #expect(relaunched.record(for: owner)?.bytes == 4)
            #expect(relaunched.record(for: owner)?.progress == 0.4)
            gate.release.signal()
            switch await original.resolveStaticCheckpoint(submission) {
            case .applied(bytes: 4), .unchanged(bytes: 4): break
            default: Issue.record("original worker did not retire idempotently")
            }
            #expect(DownloadStore(baseDirectory: directory).record(for: owner)?.bytes == 4)
        }
    }

    @Test func heldSuccessorRestartsFailedResumeQueueHeadWithOperationDispatcher() async throws {
        try await withStoreAsync { initial, directory in
            let owner = key("plex:mixed-artifact-retry", "attempt-a")
            let media = directory.appendingPathComponent("mixed-artifact-retry.mp4")
            #expect(created(initial, key: owner, media: media))
            let writes = FailFirstIndexWrite()
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try writes.write(data, to: url) })

            guard case .accepted(let failedResume) = store.submitResumeData(
                for: owner, Data("resume-after-retry".utf8), displayBytes: 18) else {
                Issue.record("resume submission rejected"); return
            }
            guard case .failed(.persistence) = store.resolveArtifactSynchronously(failedResume) else {
                Issue.record("expected prepared resume persistence failure"); return
            }

            let segment = OfflineHeldRangeSegment(
                offset: 32, length: 3, relativePath: "mixed-artifact-held.body")
            try Data([7, 8, 9]).write(
                to: directory.appendingPathComponent(segment.relativePath))
            guard case .accepted(let successor) = store.submitHeldRangeSegment(
                for: owner, segment: segment) else {
                Issue.record("held successor rejected"); return
            }
            guard case .completed = store.resolveArtifactSynchronously(successor.ticket) else {
                Issue.record("mixed queue did not drain after successor submission"); return
            }
            #expect(store.resumeData(for: owner) == Data("resume-after-retry".utf8))
            #expect(store.record(for: owner)?.metadata?.heldRangeSegments == [segment])
        }
    }

    @Test func heldReplanRestartsHeadAfterTerminalRetirementFailure() async throws {
        try await withStoreAsync { initial, directory in
            let owner = key("plex:held-terminal-replan", "attempt-a")
            let media = directory.appendingPathComponent("held-terminal-replan.mp4")
            #expect(created(initial, key: owner, media: media))
            let old = OfflineHeldRangeSegment(
                offset: 64, length: 2, relativePath: "held-terminal-old.body")
            try Data([1, 2]).write(to: directory.appendingPathComponent(old.relativePath))
            guard case .accepted = initial.persistHeldRangeSegment(for: owner, segment: old) else {
                Issue.record("old seed failed"); return
            }

            // R1 prepares the replacement; R2 is its terminal intent retirement and fails.
            let writes = FailNthIndexWrite(2)
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try writes.write(data, to: url) })
            let first = OfflineHeldRangeSegment(
                offset: 64, length: 2, relativePath: "held-terminal-first.body")
            try Data([3, 4]).write(to: directory.appendingPathComponent(first.relativePath))
            guard case .accepted(let failed) = store.submitHeldRangeSegment(
                for: owner, segment: first) else {
                Issue.record("first replacement rejected"); return
            }
            guard case .failed(.persistence) = store.resolveArtifactSynchronously(failed.ticket) else {
                Issue.record("expected terminal retirement persistence failure"); return
            }

            // This is the production replan shape: append a newer manifest revision. It must
            // restart the restored inactive head before the successor can run.
            let replanned = OfflineHeldRangeSegment(
                offset: 64, length: 2, relativePath: "held-terminal-replanned.body")
            try Data([5, 6]).write(
                to: directory.appendingPathComponent(replanned.relativePath))
            guard case .accepted(let successor) = store.submitHeldRangeSegment(
                for: owner, segment: replanned) else {
                Issue.record("replanned replacement rejected"); return
            }
            guard case .completed = store.resolveArtifactSynchronously(successor.ticket) else {
                Issue.record("terminal-failed held queue did not drain after replan"); return
            }
            #expect(store.record(for: owner)?.metadata?.heldRangeSegments == [replanned])
            #expect(!FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(old.relativePath).path))
            #expect(!FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(first.relativePath).path))
            #expect(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(replanned.relativePath).path))
        }
    }

    @Test func heldReplacementLifecycleReturnsBeforePreparedCommitAndCoversTerminalClear() async throws {
        try await withStoreAsync { initial, directory in
            let owner = key("plex:held-ticket", "attempt-a")
            let media = directory.appendingPathComponent("held-ticket.mp4")
            #expect(created(initial, key: owner, media: media))
            let old = OfflineHeldRangeSegment(
                offset: 64, length: 4, relativePath: "held-old.body")
            try Data([1, 2, 3, 4]).write(
                to: directory.appendingPathComponent(old.relativePath))
            guard case .accepted = initial.persistHeldRangeSegment(for: owner, segment: old) else {
                Issue.record("old seed failed"); return
            }
            let gate = BlockFirstHeldIndexWrite()
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try gate.write(data, to: url) })
            let next = OfflineHeldRangeSegment(
                offset: 64, length: 4, relativePath: "held-next.body")
            try Data([5, 6, 7, 8]).write(
                to: directory.appendingPathComponent(next.relativePath))
            guard case .accepted(let submission) = store.submitHeldRangeSegment(
                for: owner, segment: next) else {
                Issue.record("submission rejected"); return
            }
            #expect(await signal(gate.started, timeout: 1))
            #expect(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(old.relativePath).path))
            gate.release.signal()
            #expect(store.resolveArtifactSynchronously(submission.ticket) == .completed)
            #expect(!FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(old.relativePath).path))
            #expect(store.record(for: owner)?.metadata?.heldRangeSegments == [next])
            #expect(store.deferredHeldRangeBodyDeletionRelativePaths(for: owner)?.isEmpty == true)
        }
    }
    @Test func staleAttemptCannotReadOrMutateReplacementCheckpointState() throws {
        try withStore { store, directory in
            let a = key("plex:checkpoint", "attempt-a")
            let b = key("plex:checkpoint", "attempt-b")
            let media = directory.appendingPathComponent("checkpoint.mp4")
            try Data(repeating: 7, count: 7).write(to: media)
            #expect(created(store, key: a, media: media))
            #expect(created(store, key: b, media: media, replacing: a.attemptID))
            let workingB = try #require(store.attemptWorkingFileURL(for: b))
            try Data(repeating: 8, count: 4).write(to: workingB)

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
            #expect(store.durableStaticRangeCheckpointSize(for: b) == 4)
            #expect(store.staticRangeRecoveryEvidence(for: b)?.durableBytes == 4)
        }
    }

    @Test func terminalStaticAuditReadsPublishedStableBodyAfterWorkingPathIsConsumed() throws {
        try withStore { store, directory in
            let owner = key("plex:terminal-audit", "attempt-a")
            let stable = directory.appendingPathComponent("terminal-audit.mp4")
            #expect(created(store, key: owner, media: stable))
            #expect(store.setSourcePartSize(for: owner, 10) == .applied)
            let working = try #require(store.attemptWorkingFileURL(for: owner))
            try Data(repeating: 4, count: 4).write(to: working)

            #expect(store.promoteValidatedAttempt(for: owner, terminalStatus: .complete)
                == .promoted(owner, bytes: 4, status: .complete))
            #expect(store.attemptWorkingFileURL(for: owner) == nil)
            #expect(store.durableStaticRangeCheckpointSize(for: owner) == 4)
            #expect(store.sourceExactBytes(for: owner) == 10)
            #expect(store.resetStaticRangeProgressToDurableCheckpoint(
                for: owner, expectedBytes: 10) == .applied(bytes: 4))
            #expect(store.setStatus(for: owner, .failed) == .applied)
            #expect(store.durableStaticRangeCheckpointSize(for: owner) == 4)
            #expect(FileManager.default.fileExists(atPath: stable.path))
        }
    }

    @Test func staticRetryHandsDurableCheckpointToNewExactOwner() throws {
        try withStore { store, directory in
            let a = key("plex:handoff", "attempt-a")
            let b = key("plex:handoff", "attempt-b")
            let stable = directory.appendingPathComponent("handoff.mp4")
            #expect(created(store, key: a, media: stable))
            #expect(store.setSourcePartSize(for: a, 10) == .applied)
            let workingA = try #require(store.attemptWorkingFileURL(for: a))
            try Data([1, 2, 3, 4]).write(to: workingA)
            let metadata = OfflineMetadata(
                ratingKey: b.ratingKey, title: "Item", type: "movie",
                sourcePartSize: 10, resumeMode: .staticByteRange)
            let replacement = DownloadRecord(
                ratingKey: b.ratingKey, attemptID: b.attemptID, title: "Item",
                localURL: stable, status: .queued, metadata: metadata)

            #expect(store.createAttemptOwnedRecord(
                replacement, attemptID: b.attemptID, replacing: a.attemptID) == .committed(b))
            let workingB = try #require(store.attemptWorkingFileURL(for: b))
            #expect(try Data(contentsOf: workingB) == Data([1, 2, 3, 4]))
            #expect(!FileManager.default.fileExists(atPath: workingA.path))
            #expect(store.record(for: b)?.bytes == 4)
            #expect(store.record(for: b)?.progress == 0.4)
            #expect(store.durableStaticRangeCheckpointSize(for: b) == 4)
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

    @Test func reconciliationIgnoresStableJunkForNonterminalAttemptEvidence() throws {
        try withStore { store, directory in
            let owner = key("plex:reconcile-working", "attempt-a")
            let stable = directory.appendingPathComponent("reconcile-working.mp4")
            try Data(repeating: 9, count: 17).write(to: stable)
            #expect(created(store, key: owner, media: stable, bytes: 99, progress: 0.9))

            store.reconcile(liveRatingKeys: [], snapshotRatingKeys: [owner.ratingKey])

            let row = try #require(store.record(for: owner))
            #expect(row.status == .failed)
            #expect(row.bytes == 0)
            #expect(row.progress == 0)
            #expect(FileManager.default.fileExists(atPath: stable.path))
            #expect(store.staticRangeRecoveryEvidence(for: owner)?.durableBytes == 0)
        }
    }

    @Test func resumeWriteReportsIndexFaultAndLaterFullSnapshotCommitsIt() async throws {
        try await withStoreAsync { initial, directory in
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
            // No artifact is touched before its prepared intent commits.
            #expect(store.resumeData(for: owner) == nil)
            #expect(DownloadStore(baseDirectory: directory).resumeData(for: owner) == nil)

            #expect(store.setRangeValidator(for: owner, "retry-barrier") == .applied)
            let watermark = store.currentArtifactLifecycleWatermark()
            guard case .committed = await store.flushLifecycleAndPersistence(
                through: store.currentPersistenceTicket(),
                artifactWatermark: watermark,
                timeout: 1) else {
                Issue.record("Expected artifact retry to commit")
                return
            }
            let restored = DownloadStore(baseDirectory: directory)
            #expect(restored.resumeData(for: owner) == Data("resume".utf8))
            #expect(restored.rangeValidator(for: owner) == "retry-barrier")
            #expect(writes.count >= 2)
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

            guard case .purged(let refused) = store.completeDeferredHeldRangeBodyDeletions(
                for: owner, removal: failed.removal) else {
                Issue.record("Expected fail-closed completion result"); return
            }
            #expect(refused.removedRelativePaths.isEmpty)
            #expect(FileManager.default.fileExists(atPath: body.path))

            guard case .purged(let retry) =
                    store.retryDeferredHeldRangeBodyDeletions(for: owner) else {
                Issue.record("Expected deferred deletion retry")
                return
            }
            #expect(retry.removal.committed)
            #expect(retry.removedRelativePaths == [segment.relativePath])
            #expect(DownloadStore(baseDirectory: directory)
                .record(for: owner)?.metadata?.heldRangeSegments == nil)
            #expect(!FileManager.default.fileExists(atPath: body.path))
            #expect(DownloadStore(baseDirectory: directory)
                .deferredHeldRangeBodyDeletionRelativePaths(for: owner) == [])
        }
    }

    @Test func failedHeldPurgeBlocksReplacementUntilExactOwnerCleanupCompletes() throws {
        try withStore { initial, directory in
            let a = key("plex:held-replacement-race", "attempt-a")
            let b = key("plex:held-replacement-race", "attempt-b")
            let media = directory.appendingPathComponent("held-replacement-race.mp4")
            let segment = OfflineHeldRangeSegment(
                offset: 64, length: 4, relativePath: "held-replacement-a.body")
            let bodyA = directory.appendingPathComponent(segment.relativePath)
            #expect(created(initial, key: a, media: media))
            try Data([1, 2, 3, 4]).write(to: bodyA)
            guard case .accepted = initial.persistHeldRangeSegment(for: a, segment: segment) else {
                Issue.record("Expected A manifest"); return
            }

            let writes = FailFirstIndexWrite()
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try writes.write(data, to: url) })
            guard case .purged(let failed) = store.purgeHeldRangeSegments(for: a) else {
                Issue.record("Expected staged A purge"); return
            }
            #expect(!failed.removal.committed)
            #expect(FileManager.default.fileExists(atPath: bodyA.path))

            let metadataB = OfflineMetadata(
                ratingKey: b.ratingKey, title: "B", type: "movie", resumeMode: .staticByteRange)
            let recordB = DownloadRecord(
                ratingKey: b.ratingKey, attemptID: b.attemptID, title: "B", localURL: media,
                status: .queued, metadata: metadataB)
            guard case .rejectedOwnership(_, _, let reason) = store.createAttemptOwnedRecord(
                recordB, attemptID: b.attemptID, replacing: a.attemptID) else {
                Issue.record("Expected pending deletion to block B"); return
            }
            #expect(reason == .heldBodyDeletionPending)

            guard case .purged(let completed) =
                    store.retryDeferredHeldRangeBodyDeletions(for: a) else {
                Issue.record("Expected A cleanup retry"); return
            }
            #expect(completed.removal.committed)
            #expect(!FileManager.default.fileExists(atPath: bodyA.path))
            #expect(store.createAttemptOwnedRecord(
                recordB, attemptID: b.attemptID, replacing: a.attemptID) == .committed(b))

            let bodyB = directory.appendingPathComponent("held-replacement-b.body")
            try Data([8, 8, 8, 8]).write(to: bodyB)
            let segmentB = OfflineHeldRangeSegment(
                offset: 64, length: 4, relativePath: bodyB.lastPathComponent)
            guard case .accepted = store.persistHeldRangeSegment(for: b, segment: segmentB) else {
                Issue.record("Expected B manifest"); return
            }
            #expect(store.retryDeferredHeldRangeBodyDeletions(for: a) == .staleOrMissing)
            #expect(FileManager.default.fileExists(atPath: bodyB.path))
            #expect(store.record(for: b)?.metadata?.heldRangeSegments == [segmentB])
        }
    }

    @Test func relaunchCompletesDurableHeldBodyDeletionIntentIdempotently() throws {
        try withStore { store, directory in
            let owner = key("jellyfin:held-crash", "attempt-a")
            let media = directory.appendingPathComponent("held-crash.mkv")
            let segment = OfflineHeldRangeSegment(
                offset: 96, length: 3, relativePath: "held-crash-a.body")
            let body = directory.appendingPathComponent(segment.relativePath)
            #expect(created(store, key: owner, media: media))
            try Data([7, 8, 9]).write(to: body)
            guard case .accepted = store.persistHeldRangeSegment(for: owner, segment: segment) else {
                Issue.record("Expected manifest"); return
            }

            // Simulate death after the manifest-removal + deletion-intent snapshot commits but
            // before the process executes the filesystem half of the transaction.
            guard case .accepted(let staged) = store.takeHeldRangeSegments(
                for: owner, deletingRelativePaths: [segment.relativePath]) else {
                Issue.record("Expected staged deletion"); return
            }
            #expect(staged.committed)
            #expect(FileManager.default.fileExists(atPath: body.path))
            #expect(store.deferredHeldRangeBodyDeletionRelativePaths(for: owner)
                == [segment.relativePath])

            let relaunched = DownloadStore(baseDirectory: directory)
            _ = relaunched.resolveArtifactSynchronouslyForTests(through: relaunched.currentArtifactLifecycleWatermark())
            #expect(!FileManager.default.fileExists(atPath: body.path))
            #expect(relaunched.record(for: owner)?.metadata?.heldRangeSegments == nil)
            #expect(relaunched.deferredHeldRangeBodyDeletionRelativePaths(for: owner) == [])

            // A second launch proves missing-body cleanup is idempotent and does not recreate
            // authority or perturb the exact owner.
            let second = DownloadStore(baseDirectory: directory)
            #expect(second.ownsAttempt(owner))
            #expect(second.deferredHeldRangeBodyDeletionRelativePaths(for: owner) == [])
        }
    }

    @Test func failedIntentClearReplaysMissingBodyCleanupAfterRelaunch() throws {
        try withStore { initial, directory in
            let owner = key("emby:held-clear-crash", "attempt-a")
            let media = directory.appendingPathComponent("held-clear-crash.mkv")
            let segment = OfflineHeldRangeSegment(
                offset: 128, length: 2, relativePath: "held-clear-crash-a.body")
            let body = directory.appendingPathComponent(segment.relativePath)
            #expect(created(initial, key: owner, media: media))
            try Data([4, 2]).write(to: body)
            guard case .accepted = initial.persistHeldRangeSegment(for: owner, segment: segment) else {
                Issue.record("Expected manifest"); return
            }

            let writes = FailNthIndexWrite(2)
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try writes.write(data, to: url) })
            guard case .purged(let purge) = store.purgeHeldRangeSegments(for: owner) else {
                Issue.record("Expected purge"); return
            }
            #expect(purge.removal.committed)
            #expect(purge.removedRelativePaths == [segment.relativePath])
            #expect(!FileManager.default.fileExists(atPath: body.path))
            #expect(writes.count == 2)

            // Disk still has the intent because clearing it faulted after body deletion. Relaunch
            // treats the absent file as idempotent success and durably clears only A's authority.
            let relaunched = DownloadStore(baseDirectory: directory)
            _ = relaunched.resolveArtifactSynchronouslyForTests(through: relaunched.currentArtifactLifecycleWatermark())
            #expect(relaunched.ownsAttempt(owner))
            #expect(relaunched.deferredHeldRangeBodyDeletionRelativePaths(for: owner) == [])
            #expect(!FileManager.default.fileExists(atPath: body.path))
        }
    }

    @Test func deferredDeletionNeverTouchesBodyReferencedByAnotherRowManifest() throws {
        try withStore { store, directory in
            let a = key("plex:shared-held-a", "attempt-a")
            let b = key("plex:shared-held-b", "attempt-b")
            let mediaA = directory.appendingPathComponent("shared-held-a.mp4")
            let mediaB = directory.appendingPathComponent("shared-held-b.mp4")
            #expect(created(store, key: a, media: mediaA))
            #expect(created(store, key: b, media: mediaB))
            let shared = OfflineHeldRangeSegment(
                offset: 64, length: 4, relativePath: "pathologically-shared-held.body")
            let body = directory.appendingPathComponent(shared.relativePath)
            try Data([3, 3, 3, 3]).write(to: body)
            guard case .accepted = store.persistHeldRangeSegment(for: a, segment: shared),
                  case .accepted = store.persistHeldRangeSegment(for: b, segment: shared) else {
                Issue.record("Expected both characterized manifests"); return
            }

            guard case .accepted(let staged) = store.removeHeldRangeSegments(
                for: a, offsets: [shared.offset],
                deletingRelativePaths: [shared.relativePath]) else {
                Issue.record("Expected A staged removal"); return
            }
            #expect(staged.committed)
            guard case .purged(let completed) = store.completeDeferredHeldRangeBodyDeletions(
                for: a, removal: staged) else {
                Issue.record("Expected A completion"); return
            }
            #expect(completed.failedRelativePaths.isEmpty)
            #expect(completed.removedRelativePaths.isEmpty)
            #expect(store.deferredHeldRangeBodyDeletionRelativePaths(for: a) == [])
            #expect(FileManager.default.fileExists(atPath: body.path))
            #expect(store.record(for: b)?.metadata?.heldRangeSegments == [shared])

            let relaunched = DownloadStore(baseDirectory: directory)
            #expect(FileManager.default.fileExists(atPath: body.path))
            #expect(relaunched.record(for: b)?.metadata?.heldRangeSegments == [shared])
            #expect(relaunched.deferredHeldRangeBodyDeletionRelativePaths(for: a) == [])
        }
    }

    @Test func delayedCommittedRemovalCannotPublishOrDeleteLaterFailedRemoval() throws {
        try withStore { initial, directory in
            let owner = key("plex:held-revision-race", "attempt-a")
            let media = directory.appendingPathComponent("held-revision-race.mp4")
            #expect(created(initial, key: owner, media: media))
            let x = OfflineHeldRangeSegment(
                offset: 64, length: 2, relativePath: "held-r1-x.body")
            let y = OfflineHeldRangeSegment(
                offset: 128, length: 2, relativePath: "held-r2-y.body")
            let bodyX = directory.appendingPathComponent(x.relativePath)
            let bodyY = directory.appendingPathComponent(y.relativePath)
            try Data([1, 1]).write(to: bodyX)
            try Data([2, 2]).write(to: bodyY)
            guard case .accepted = initial.persistHeldRangeSegment(for: owner, segment: x),
                  case .accepted = initial.persistHeldRangeSegment(for: owner, segment: y) else {
                Issue.record("Expected initial manifests"); return
            }

            let writes = FailNthIndexWrite(2)
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try writes.write(data, to: url) })
            guard case .accepted(let r1) = store.removeHeldRangeSegments(
                for: owner, offsets: [x.offset], deletingRelativePaths: [x.relativePath]) else {
                Issue.record("Expected R1"); return
            }
            #expect(r1.committed)
            guard case .accepted(let r2) = store.removeHeldRangeSegments(
                for: owner, offsets: [y.offset], deletingRelativePaths: [y.relativePath]) else {
                Issue.record("Expected R2"); return
            }
            #expect(!r2.committed)
            #expect(writes.count == 2)

            // R1 is delayed until after failed R2 changed the in-memory full snapshot. It must not
            // delete Y or submit a cleanup snapshot that silently publishes R2's manifest removal.
            guard case .purged(let delayed) = store.completeDeferredHeldRangeBodyDeletions(
                for: owner, removal: r1) else {
                Issue.record("Expected deferred R1 completion"); return
            }
            #expect(delayed.removedRelativePaths.isEmpty)
            #expect(writes.count == 2)
            #expect(FileManager.default.fileExists(atPath: bodyY.path))

            let relaunched = DownloadStore(baseDirectory: directory)
            _ = relaunched.resolveArtifactSynchronouslyForTests(through: relaunched.currentArtifactLifecycleWatermark())
            #expect(relaunched.record(for: owner)?.metadata?.heldRangeSegments == [y])
            #expect(FileManager.default.fileExists(atPath: bodyY.path))
            // R1 itself was durable, so relaunch may idempotently finish X only.
            #expect(!FileManager.default.fileExists(atPath: bodyX.path))
        }
    }

    @Test func checkpointResetReportsFaultWithoutBlessingStaleOwner() throws {
        try withStore { initial, directory in
            let owner = key("plex:reset-fault", "attempt-a")
            let media = directory.appendingPathComponent("reset-fault.mp4")
            try Data([1, 2, 3]).write(to: media)
            #expect(created(initial, key: owner, media: media, bytes: 99, progress: 0.99))
            let working = try #require(initial.attemptWorkingFileURL(for: owner))
            try Data([4, 5]).write(to: working)
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
            #expect(bytes == 2)
            #expect(DownloadStore(baseDirectory: directory).record(for: owner)?.bytes == 99)
            #expect(store.setRangeValidator(for: owner, "retry") == .applied)
            #expect(DownloadStore(baseDirectory: directory).record(for: owner)?.bytes == 2)
        }
    }

    @Test func reconcileDoesNotDestroyValidatedBodyBehindPendingPromotionIntent() async throws {
        try await withStoreAsync { initial, directory in
            let owner = key("jellyfin:promotion-reconcile-race", "attempt-a")
            let stable = directory.appendingPathComponent("promotion-reconcile-race.mp4")
            #expect(createdLiveForwardOnly(initial, key: owner, media: stable))
            let working = try #require(initial.attemptWorkingFileURL(for: owner))
            try Data("validated".utf8).write(to: working)

            // Durable prepared `.validatedPromotion` head with the process "hard-killed" before
            // source capture: park the original store's stat and abandon it mid-flight.
            let originalGate = BlockFirstPromotionStat()
            let live = DownloadPromotionFilesystem.live
            let original = DownloadStore(
                baseDirectory: directory,
                promotionFilesystem: .init(
                    exists: live.exists,
                    size: { url in originalGate.size(url, using: live.size) },
                    fullSyncSource: live.fullSyncSource,
                    renameReplacing: live.renameReplacing,
                    syncParentDirectory: live.syncParentDirectory))
            let submission = original.submitValidatedPromotion(for: owner, terminalStatus: .complete)
            #expect(await signal(originalGate.started, timeout: 1))

            // Relaunch: intent replay is scheduled but parked at its own stat — the async
            // replay-vs-reconcile window. Reconcile must not demote the liveForwardOnly row
            // to `.failed` or delete the working file that IS the fully-validated body.
            let replayGate = BlockFirstPromotionStat()
            let relaunched = DownloadStore(
                baseDirectory: directory,
                promotionFilesystem: .init(
                    exists: live.exists,
                    size: { url in replayGate.size(url, using: live.size) },
                    fullSyncSource: live.fullSyncSource,
                    renameReplacing: live.renameReplacing,
                    syncParentDirectory: live.syncParentDirectory))
            #expect(await signal(replayGate.started, timeout: 1))
            relaunched.reconcile(liveRatingKeys: [], snapshotRatingKeys: [owner.ratingKey])
            #expect(relaunched.status(for: owner.ratingKey) == .downloading)
            #expect(FileManager.default.fileExists(atPath: working.path))

            replayGate.release.signal()
            #expect(relaunched.resolveArtifactSynchronouslyForTests(
                through: relaunched.currentArtifactLifecycleWatermark()) == .completed)
            #expect(relaunched.record(for: owner)?.status == .complete)
            #expect(relaunched.record(for: owner)?.bytes == 9)
            originalGate.release.signal()
            _ = await original.resolveValidatedPromotion(submission)
        }
    }

    @Test func promotionIntentWithPermanentlyMissingSourceAbandonsAndAdmitsRetry() async throws {
        try await withStoreAsync { initial, directory in
            let owner = key("jellyfin:promotion-missing-source", "attempt-a")
            let stable = directory.appendingPathComponent("promotion-missing-source.mp4")
            #expect(createdLiveForwardOnly(initial, key: owner, media: stable))
            let working = try #require(initial.attemptWorkingFileURL(for: owner))
            try Data("validated".utf8).write(to: working)
            let gate = BlockFirstPromotionStat()
            let live = DownloadPromotionFilesystem.live
            let original = DownloadStore(
                baseDirectory: directory,
                promotionFilesystem: .init(
                    exists: live.exists,
                    size: { url in gate.size(url, using: live.size) },
                    fullSyncSource: live.fullSyncSource,
                    renameReplacing: live.renameReplacing,
                    syncParentDirectory: live.syncParentDirectory))
            let submission = original.submitValidatedPromotion(for: owner, terminalStatus: .complete)
            #expect(await signal(gate.started, timeout: 1))
            // The validated body is destroyed while the durable prepared intent is at head.
            // No replay can ever publish it: the head must abandon (row demoted to retryable
            // `.failed`) instead of looping `.sourceMissing` and wedging every retry behind
            // `.artifactLifecyclePending`.
            try FileManager.default.removeItem(at: working)

            let relaunched = DownloadStore(baseDirectory: directory)
            #expect(relaunched.resolveArtifactSynchronouslyForTests(
                through: relaunched.currentArtifactLifecycleWatermark()) == .completed)
            #expect(relaunched.record(for: owner)?.status == .failed)
            let retry = key(owner.ratingKey, "attempt-b")
            #expect(created(relaunched, key: retry, media: stable, replacing: owner.attemptID))
            gate.release.signal()
            _ = await original.resolveValidatedPromotion(submission)
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

    /// Jellyfin/Emby transcode lanes: a live encoder stream whose reconcile path demotes
    /// non-live rows to `.failed` and deletes the working file — the D2 destruction lane.
    private func createdLiveForwardOnly(
        _ store: DownloadStore,
        key: DownloadAttemptKey,
        media: URL
    ) -> Bool {
        let metadata = OfflineMetadata(
            ratingKey: key.ratingKey,
            title: "Item",
            type: "movie",
            resumeMode: .liveForwardOnly)
        let record = DownloadRecord(
            ratingKey: key.ratingKey,
            attemptID: key.attemptID,
            title: "Item",
            localURL: media,
            bytes: 0,
            progress: 0,
            status: .downloading,
            metadata: metadata)
        if case .committed(let actual) = store.createAttemptOwnedRecord(
            record, attemptID: key.attemptID) {
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

    private func withStoreAsync(
        _ body: (DownloadStore, URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attempt-checkpoint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(DownloadStore(baseDirectory: directory), directory)
    }

    private func signal(_ semaphore: DispatchSemaphore, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: semaphore.wait(
                    timeout: .now() + timeout) == .success)
            }
        }
    }
}

private final class BlockFirstHeldIndexWrite: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    func write(_ data: Data, to url: URL) throws {
        let first = lock.withLock { count += 1; return count == 1 }
        if first { started.signal(); release.wait() }
        try DownloadIndexFileCommitter().commit(data, to: url)
    }
}

private final class BlockFirstPromotionStat: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var blocked = false

    func size(_ url: URL, using body: @Sendable (URL) -> Int?) -> Int? {
        let first = lock.withLock {
            if blocked { return false }
            blocked = true
            return true
        }
        if first { started.signal(); release.wait() }
        return body(url)
    }
}

private final class BlockCheckpointStat: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func size(_ url: URL, using body: @Sendable (URL) -> Int?) -> Int? {
        started.signal()
        release.wait()
        return body(url)
    }
}

private final class BlockCheckpointCopy: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let failAfterRelease: Bool

    init(failAfterRelease: Bool) { self.failAfterRelease = failAfterRelease }

    func copy(_ source: URL, _ destination: URL, _ temporary: URL) throws {
        started.signal()
        release.wait()
        if failAfterRelease { throw CocoaError(.fileWriteOutOfSpace) }
        try DownloadStaticCheckpointFilesystem.live.durableCopy(source, destination, temporary)
    }
}

private final class BlockAfterCheckpointCopy: @unchecked Sendable {
    let copied = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func copy(
        _ source: URL,
        _ destination: URL,
        _ temporary: URL,
        using body: @Sendable (URL, URL, URL) throws -> Void
    ) throws {
        try body(source, destination, temporary)
        copied.signal()
        release.wait()
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

private final class FailNthIndexWrite: @unchecked Sendable {
    private let lock = NSLock()
    private let failure: Int
    private(set) var count = 0

    init(_ failure: Int) { self.failure = failure }

    func write(_ data: Data, to url: URL) throws {
        let shouldFail = lock.withLock {
            count += 1
            return count == failure
        }
        if shouldFail { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: url, options: .atomic)
    }
}
