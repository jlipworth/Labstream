import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite("Download artifact lifecycle")
struct DownloadArtifactLifecycleTests {
    @Test func zeroWatermarkCompletesWithoutRangeTrap() async {
        let coordinator = DownloadArtifactLifecycleCoordinator()
        #expect(await coordinator.flush(
            through: .init(sequence: 0), timeout: 0.01) == .completed)
    }

    @Test func observedFailureDoesNotPoisonLaterWatermark() async throws {
        let coordinator = DownloadArtifactLifecycleCoordinator()
        let id = try #require(DownloadAttemptID(rawValue: "a"))
        let key = DownloadAttemptKey(ratingKey: "plex:item", attemptID: id)
        let first = coordinator.register(
            key: key, generation: 1, intentID: UUID(),
            preparedRevision: .init(revision: 1))
        coordinator.fail(first, .failed(
            revision: 1, stage: "commit", errorType: "Injected"))
        guard case .failed = await coordinator.flush(
            through: .init(sequence: first.sequence), timeout: 0.1) else {
            Issue.record("expected first failure")
            return
        }
        let retry = coordinator.register(
            key: key, generation: 1, intentID: first.intentID,
            preparedRevision: .init(revision: 2))
        coordinator.complete(retry)
        #expect(await coordinator.flush(
            through: .init(sequence: retry.sequence), timeout: 0.1) == .completed)
    }

    @Test func concurrentBoundaryWaitersObserveSameFailure() async throws {
        let coordinator = DownloadArtifactLifecycleCoordinator()
        let id = try #require(DownloadAttemptID(rawValue: "a"))
        let key = DownloadAttemptKey(ratingKey: "plex:concurrent", attemptID: id)
        let ticket = coordinator.register(
            key: key, generation: 1, intentID: UUID(),
            preparedRevision: .init(revision: 1))
        let watermark = coordinator.currentWatermark
        async let first = coordinator.flush(through: watermark, timeout: 1)
        async let second = coordinator.flush(through: watermark, timeout: 1)
        try await Task.sleep(for: .milliseconds(10))
        coordinator.failArtifact(ticket, errorType: "Injected")
        let results = await [first, second]
        #expect(results.allSatisfy {
            $0 == .failed(.artifact(errorType: "Injected"))
        })
    }

    @Test func ticketWaitIsNotMisattributedEarlierFailure() throws {
        let coordinator = DownloadArtifactLifecycleCoordinator()
        let id = try #require(DownloadAttemptID(rawValue: "a"))
        let key = DownloadAttemptKey(ratingKey: "plex:tickets", attemptID: id)
        let failed = coordinator.register(
            key: key, generation: 1, intentID: UUID(),
            preparedRevision: .init(revision: 1))
        coordinator.failArtifact(failed, errorType: "Earlier")
        let later = coordinator.register(
            key: key, generation: 2, intentID: UUID(),
            preparedRevision: .init(revision: 2))
        coordinator.complete(later)
        #expect(coordinator.waitSynchronously(for: later) == .completed)
        #expect(coordinator.waitSynchronously(for: failed)
                == .failed(.artifact(errorType: "Earlier")))
    }

    @Test func abandonedFailureIsBoundaryExemptButTicketVisible() async throws {
        let coordinator = DownloadArtifactLifecycleCoordinator()
        let id = try #require(DownloadAttemptID(rawValue: "a"))
        let key = DownloadAttemptKey(ratingKey: "plex:abandoned", attemptID: id)
        let dead = coordinator.register(
            key: key, generation: 1, intentID: UUID(),
            preparedRevision: .init(revision: 1))
        coordinator.failArtifact(dead, errorType: "Injected")
        guard case .failed = await coordinator.flush(
            through: .init(sequence: dead.sequence), timeout: 0.1) else {
            Issue.record("expected pre-abandonment boundary failure")
            return
        }
        coordinator.abandonIntent(dead.intentID)
        // The dead intent is never re-registered; boundaries must stop reporting it.
        #expect(await coordinator.flush(
            through: .init(sequence: dead.sequence), timeout: 0.1) == .completed)
        #expect(await coordinator.flush(
            through: coordinator.currentWatermark, timeout: 0.1) == .completed)
        // Ticket-scoped waiters still observe the recorded outcome.
        #expect(coordinator.waitSynchronously(for: dead)
                == .failed(.artifact(errorType: "Injected")))
    }

    @Test func abandonedPendingEntryDoesNotStallBoundary() async throws {
        let coordinator = DownloadArtifactLifecycleCoordinator()
        let id = try #require(DownloadAttemptID(rawValue: "a"))
        let key = DownloadAttemptKey(ratingKey: "plex:abandoned-pending", attemptID: id)
        let orphan = coordinator.register(
            key: key, generation: 1, intentID: UUID(),
            preparedRevision: .init(revision: 1))
        coordinator.abandonIntent(orphan.intentID)
        #expect(await coordinator.flush(
            through: .init(sequence: orphan.sequence), timeout: 0.1) == .completed)
    }

    @Test func completedRetryPrunesSupersededFailureFromOldWatermark() async throws {
        let coordinator = DownloadArtifactLifecycleCoordinator()
        let id = try #require(DownloadAttemptID(rawValue: "a"))
        let key = DownloadAttemptKey(ratingKey: "plex:pruned", attemptID: id)
        let first = coordinator.register(
            key: key, generation: 1, intentID: UUID(),
            preparedRevision: .init(revision: 1))
        coordinator.fail(first, .failed(
            revision: 1, stage: "commit", errorType: "Injected"))
        let retry = coordinator.register(
            key: key, generation: 1, intentID: first.intentID,
            preparedRevision: .init(revision: 2))
        coordinator.complete(retry)
        // The completed retry durably resolves the intent, so even a boundary that predates the
        // retry's registration observes the whole pruned chain as completed.
        #expect(await coordinator.flush(
            through: .init(sequence: first.sequence), timeout: 0.1) == .completed)
        #expect(coordinator.waitSynchronously(for: retry) == .completed)
    }

    @Test func resumeSubmissionReturnsBeforeArtifactWriteAndUsesPrivateSafeName() async throws {
        try await withDirectory { directory in
            let writeStarted = DispatchSemaphore(value: 0)
            let releaseWrite = DispatchSemaphore(value: 0)
            let filesystem = DownloadArtifactFilesystem(
                writeAuthArtifact: { data, url, _ in
                    writeStarted.signal()
                    releaseWrite.wait()
                    try data.write(to: url, options: .atomic)
                },
                removeItem: { url, fm in try fm.removeItem(at: url) },
                fileExists: { url, fm in fm.fileExists(atPath: url.path) }
            )
            let store = DownloadStore(
                baseDirectory: directory, artifactFilesystem: filesystem)
            let hostile = "attempt/../../raw token ? secret"
            let attempt = try #require(DownloadAttemptID(rawValue: hostile))
            let key = DownloadAttemptKey(ratingKey: "plex:resume-safe", attemptID: attempt)
            let media = directory.appendingPathComponent("resume-safe.mp4")
            let metadata = OfflineMetadata(
                ratingKey: key.ratingKey, title: "Resume", type: "movie",
                resumeMode: .staticByteRange)
            let record = DownloadRecord(
                ratingKey: key.ratingKey, attemptID: attempt, title: "Resume",
                localURL: media, status: .paused, metadata: metadata)
            guard case .committed = store.createAttemptOwnedRecord(record, attemptID: attempt) else {
                Issue.record("seed failed")
                return
            }

            let submission = store.submitResumeData(for: key, Data("blob".utf8))
            guard case .accepted(let ticket) = submission else {
                Issue.record("submission rejected")
                return
            }
            #expect(await signal(writeStarted, timeout: 1))
            #expect(store.record(for: key)?.metadata?.resumeDataRelativePath == nil)
            releaseWrite.signal()
            #expect(store.resolveSynchronously(.accepted(ticket: ticket)) == .applied)
            let relative = try #require(store.record(for: key)?.metadata?.resumeDataRelativePath)
            #expect(!relative.contains(hostile))
            #expect(!relative.contains("/"))
            #expect(try Data(contentsOf: directory.appendingPathComponent(relative))
                    == Data("blob".utf8))
        }
    }

    @Test func failedResumeGenerationCanBeRecoveredWithoutPoisoningFlush() async throws {
        final class Once: @unchecked Sendable {
            let lock = NSLock(); var failed = false
        }
        let once = Once()
        try await withDirectory { directory in
            let filesystem = DownloadArtifactFilesystem(
                writeAuthArtifact: { data, url, _ in
                    let fail = once.lock.withLock {
                        defer { once.failed = true }
                        return !once.failed
                    }
                    if fail { throw InjectedArtifactFailure() }
                    try data.write(to: url, options: .atomic)
                },
                removeItem: { url, fm in try fm.removeItem(at: url) },
                fileExists: { url, fm in fm.fileExists(atPath: url.path) }
            )
            let store = DownloadStore(
                baseDirectory: directory, artifactFilesystem: filesystem)
            let attempt = try #require(DownloadAttemptID(rawValue: "attempt"))
            let key = DownloadAttemptKey(ratingKey: "plex:resume-retry", attemptID: attempt)
            let record = DownloadRecord(
                ratingKey: key.ratingKey, attemptID: attempt, title: "Retry",
                localURL: directory.appendingPathComponent("retry.mp4"), status: .paused,
                metadata: OfflineMetadata(
                    ratingKey: key.ratingKey, title: "Retry", type: "movie",
                    resumeMode: .staticByteRange))
            guard case .committed = store.createAttemptOwnedRecord(record, attemptID: attempt) else {
                Issue.record("seed failed"); return
            }
            guard case .artifactWriteFailed = store.setResumeData(for: key, Data("blob".utf8)) else {
                Issue.record("expected injected write failure"); return
            }
            let watermark = store.currentArtifactLifecycleWatermark()
            let result = await store.flushLifecycleAndPersistence(
                through: store.currentPersistenceTicket(),
                artifactWatermark: watermark,
                timeout: 1)
            guard case .committed = result else {
                Issue.record("recovery flush failed: \(result)"); return
            }
            let relative = try #require(
                store.record(for: key)?.metadata?.resumeDataRelativePath)
            #expect(try Data(contentsOf: directory.appendingPathComponent(relative))
                    == Data("blob".utf8))
        }
    }

    @Test func resumeSubmissionRestartsFailedInactiveHead() async throws {
        try await withDirectory { directory in
            let seam = FailOnceThenSignalResumeWrite()
            let store = try seededStore(directory: directory, failure: seam.failure)
            let key = try resumeKey()
            guard case .artifactWriteFailed = store.setResumeData(
                for: key, Data("first".utf8)) else {
                Issue.record("expected injected write failure"); return
            }
            // The failed head stays durably queued but inactive. The successor submission is the
            // event that must rediscover and restart it (D1) — nothing else is running here.
            guard case .accepted(let second) = store.submitResumeData(
                for: key, Data("second".utf8)) else {
                Issue.record("second submission rejected"); return
            }
            guard await signal(seam.retried, timeout: 2) else {
                Issue.record("successor submission never restarted the failed head"); return
            }
            #expect(store.resolveSynchronously(.accepted(ticket: second)) == .applied)
            let relative = try #require(
                store.record(for: key)?.metadata?.resumeDataRelativePath)
            #expect(try Data(contentsOf: directory.appendingPathComponent(relative))
                    == Data("second".utf8))
        }
    }

    @Test func clearSubmissionRestartsFailedInactiveHead() async throws {
        try await withDirectory { directory in
            let seam = FailOnceThenSignalResumeWrite()
            let store = try seededStore(directory: directory, failure: seam.failure)
            let key = try resumeKey()
            guard case .artifactWriteFailed = store.setResumeData(
                for: key, Data("first".utf8)) else {
                Issue.record("expected injected write failure"); return
            }
            guard case .accepted(_, let clear) = store.submitClearResumeData(for: key) else {
                Issue.record("clear submission rejected"); return
            }
            guard await signal(seam.retried, timeout: 2) else {
                Issue.record("clear submission never restarted the failed head"); return
            }
            #expect(store.resolveArtifactSynchronously(clear) == .completed)
            #expect(store.record(for: key)?.metadata?.resumeDataRelativePath == nil)
            #expect(resumeArtifacts(in: directory).isEmpty)
        }
    }

    @Test func queuedReplaceThenClearComposesAgainstPublishedHead() async throws {
        try await withDirectory { directory in
            let gate = ResumeWriteGate()
            let store = try seededStore(directory: directory, writeGate: gate)
            let key = try resumeKey()
            guard case .accepted(let replace) = store.submitResumeData(
                for: key, Data("first".utf8), displayBytes: 5),
                  case .accepted(_, let clear) = store.submitClearResumeData(for: key) else {
                Issue.record("queue submission failed"); return
            }
            #expect(await signal(gate.started, timeout: 1))
            gate.release.signal()
            #expect(store.resolveSynchronously(.accepted(ticket: replace)) == .applied)
            #expect(store.resolveArtifactSynchronously(clear) == .completed)
            #expect(store.record(for: key)?.metadata?.resumeDataRelativePath == nil)
            #expect(resumeArtifacts(in: directory).isEmpty)
            #expect(DownloadStore(baseDirectory: directory)
                .record(for: key)?.metadata?.resumeDataRelativePath == nil)
        }
    }

    @Test func queuedReplaceThenReplaceDeletesIntermediateGeneration() async throws {
        try await withDirectory { directory in
            let gate = ResumeWriteGate()
            let store = try seededStore(directory: directory, writeGate: gate)
            let key = try resumeKey()
            guard case .accepted(let first) = store.submitResumeData(
                for: key, Data("first".utf8)),
                  case .accepted(let second) = store.submitResumeData(
                    for: key, Data("second".utf8)) else {
                Issue.record("queue submission failed"); return
            }
            #expect(await signal(gate.started, timeout: 1))
            gate.release.signal()
            #expect(store.resolveSynchronously(.accepted(ticket: first)) == .applied)
            #expect(store.resolveSynchronously(.accepted(ticket: second)) == .applied)
            let files = resumeArtifacts(in: directory)
            #expect(files.count == 1)
            #expect(try Data(contentsOf: #require(files.first)) == Data("second".utf8))
            let restored = DownloadStore(baseDirectory: directory)
            #expect(restored.resumeData(for: key) == Data("second".utf8))
            #expect(resumeArtifacts(in: directory).count == 1)
        }
    }

    @Test func failedHeadRetriesBeforeQueuedSuccessorWithoutPoisoningIt() async throws {
        try await withDirectory { directory in
            let gate = FailFirstResumeWriteGate()
            let store = DownloadStore(
                baseDirectory: directory, artifactFilesystem: gate.filesystem)
            let key = try resumeKey()
            let record = DownloadRecord(
                ratingKey: key.ratingKey, attemptID: key.attemptID, title: "Resume",
                localURL: directory.appendingPathComponent("compose.mp4"), status: .paused,
                metadata: OfflineMetadata(
                    ratingKey: key.ratingKey, title: "Resume", type: "movie",
                    resumeMode: .staticByteRange))
            guard case .committed = store.createAttemptOwnedRecord(
                record, attemptID: key.attemptID),
                  case .accepted(let first) = store.submitResumeData(
                    for: key, Data("first".utf8)) else {
                Issue.record("seed/first submission failed"); return
            }
            #expect(await signal(gate.started, timeout: 1))
            guard case .accepted = store.submitResumeData(
                for: key, Data("second".utf8)) else {
                Issue.record("successor submission failed"); return
            }
            gate.release.signal()
            guard case .artifactWriteFailed = store.resolveSynchronously(
                .accepted(ticket: first)) else {
                Issue.record("expected first process attempt failure"); return
            }
            let watermark = store.currentArtifactLifecycleWatermark()
            guard case .committed = await store.flushLifecycleAndPersistence(
                through: store.currentPersistenceTicket(),
                artifactWatermark: watermark,
                timeout: 1) else {
                Issue.record("head/successor retry did not drain"); return
            }
            #expect(store.resumeData(for: key) == Data("second".utf8))
            #expect(resumeArtifacts(in: directory).count == 1)
        }
    }

    @Test func replaceTerminalIndexFailureRestoresHeadThenDrainsQueuedSuccessor() async throws {
        try await withDirectory { directory in
            let index = ArmableTerminalIndexFailure()
            let seed = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try index.write(data, to: url) })
            let key = try resumeKey()
            let record = DownloadRecord(
                ratingKey: key.ratingKey, attemptID: key.attemptID, title: "Resume",
                localURL: directory.appendingPathComponent("terminal.mp4"), status: .paused,
                metadata: OfflineMetadata(
                    ratingKey: key.ratingKey, title: "Resume", type: "movie",
                    resumeMode: .staticByteRange))
            guard case .committed = seed.createAttemptOwnedRecord(record, attemptID: key.attemptID) else {
                Issue.record("seed failed"); return
            }
            #expect(seed.setResumeData(for: key, Data("old".utf8)) == .applied)
            let old = try #require(seed.record(for: key)?.metadata?.resumeDataRelativePath)
            let removal = TerminalRemovalGate(target: old, index: index)
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try index.write(data, to: url) },
                artifactFilesystem: removal.filesystem)
            guard case .accepted(let first) = store.submitResumeData(
                for: key, Data("first".utf8)) else {
                Issue.record("first submission failed"); return
            }
            #expect(await signal(removal.started, timeout: 1))
            guard case .accepted = store.submitResumeData(for: key, Data("second".utf8)) else {
                Issue.record("successor submission failed"); return
            }
            guard case .committed = await store.flushPersistence(
                through: store.currentPersistenceTicket(), timeout: 1) else {
                Issue.record("successor preparation did not commit"); return
            }
            removal.release.signal()
            let firstResult = store.resolveSynchronously(.accepted(ticket: first))
            guard case .persistenceFailed = firstResult else {
                Issue.record("expected terminal index failure, got \(firstResult)"); return
            }
            let watermark = store.currentArtifactLifecycleWatermark()
            guard case .committed = await store.flushLifecycleAndPersistence(
                through: store.currentPersistenceTicket(), artifactWatermark: watermark,
                timeout: 1) else {
                Issue.record("restored replace did not drain"); return
            }
            #expect(store.resumeData(for: key) == Data("second".utf8))
            #expect(resumeArtifacts(in: directory).count == 1)
        }
    }

    @Test func clearTerminalIndexFailureRestoresSameIntentForLaterWatermark() async throws {
        try await withDirectory { directory in
            let index = ArmableTerminalIndexFailure()
            let seed = try seededStore(directory: directory)
            let key = try resumeKey()
            #expect(seed.setResumeData(for: key, Data("old".utf8)) == .applied)
            let old = try #require(seed.record(for: key)?.metadata?.resumeDataRelativePath)
            let removal = TerminalRemovalGate(target: old, index: index)
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try index.write(data, to: url) },
                artifactFilesystem: removal.filesystem)
            guard case .accepted(_, let clear) = store.submitClearResumeData(for: key) else {
                Issue.record("clear submission failed"); return
            }
            #expect(await signal(removal.started, timeout: 1))
            removal.release.signal()
            guard case .failed(.persistence) = store.resolveArtifactSynchronously(clear) else {
                Issue.record("expected terminal clear failure"); return
            }
            let watermark = store.currentArtifactLifecycleWatermark()
            guard case .committed = await store.flushLifecycleAndPersistence(
                through: store.currentPersistenceTicket(), artifactWatermark: watermark,
                timeout: 1) else {
                Issue.record("restored clear did not drain"); return
            }
            #expect(store.record(for: key)?.metadata?.resumeDataRelativePath == nil)
        }
    }

    @Test func terminalRetirementBarrierNeverSchedulesSuccessorBeforeFailureRestore() async throws {
        try await withDirectory { directory in
            let seed = try seededStore(directory: directory)
            let key = try resumeKey()
            #expect(seed.setResumeData(for: key, Data("old".utf8)) == .applied)
            let old = try #require(seed.record(for: key)?.metadata?.resumeDataRelativePath)
            let index = BlockingTerminalIndexFailure()
            let removal = BlockingTerminalRemovalGate(target: old, index: index)
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try index.write(data, to: url) },
                artifactFilesystem: removal.filesystem)
            guard case .accepted(let first) = store.submitResumeData(
                for: key, Data("first".utf8)) else {
                Issue.record("first submission failed"); return
            }
            #expect(await signal(removal.started, timeout: 1))
            guard case .accepted = store.submitResumeData(
                for: key, Data("second".utf8)) else {
                Issue.record("successor submission failed"); return
            }
            guard case .committed = await store.flushPersistence(
                through: store.currentPersistenceTicket(), timeout: 1) else {
                Issue.record("successor preparation did not commit"); return
            }
            removal.release.signal()
            #expect(await signal(index.terminalStarted, timeout: 1))
            _ = store.currentArtifactLifecycleWatermark()
            try await Task.sleep(for: .milliseconds(30))
            #expect(removal.writeCount == 1)
            index.releaseTerminal.signal()
            guard case .persistenceFailed = store.resolveSynchronously(
                .accepted(ticket: first)) else {
                Issue.record("expected blocked terminal failure"); return
            }
            let retryWatermark = store.currentArtifactLifecycleWatermark()
            guard case .committed = await store.flushLifecycleAndPersistence(
                through: store.currentPersistenceTicket(),
                artifactWatermark: retryWatermark,
                timeout: 1) else {
                Issue.record("restored head/successor did not drain"); return
            }
            #expect(store.resumeData(for: key) == Data("second".utf8))
            #expect(removal.writeCount == 2)
        }
    }

    @Test func startupCleansOnlyAgedGenerationSiblingTemps() throws {
        try withDirectorySync { directory in
            let capture = CaptureFailingResumeWrite()
            do {
                let store = try seededStore(directory: directory, failure: capture.failure)
                let key = try resumeKey()
                guard case .artifactWriteFailed = store.setResumeData(
                    for: key, Data("blob".utf8)) else {
                    Issue.record("expected captured write failure"); return
                }
            }
            let destination = try #require(capture.destination)
            let oldTemp = directory.appendingPathComponent(
                ".\(destination.lastPathComponent).commit-\(UUID().uuidString)")
            let freshTemp = directory.appendingPathComponent(
                ".\(destination.lastPathComponent).commit-\(UUID().uuidString)")
            let unrelatedOld = directory.appendingPathComponent(
                ".not-a-resume.commit-\(UUID().uuidString)")
            let nearPatternOld = directory.appendingPathComponent(
                ".unrelated!.resume-\(String(repeating: "a", count: 24))-\(UUID().uuidString).commit-\(UUID().uuidString)")
            try Data("old".utf8).write(to: oldTemp)
            try Data("fresh".utf8).write(to: freshTemp)
            try Data("unrelated".utf8).write(to: unrelatedOld)
            try Data("near".utf8).write(to: nearPatternOld)
            let firstRelaunch = DownloadStore(baseDirectory: directory)
            _ = firstRelaunch.resolveArtifactSynchronouslyForTests(
                through: firstRelaunch.currentArtifactLifecycleWatermark())
            #expect(FileManager.default.fileExists(atPath: oldTemp.path))
            #expect(FileManager.default.fileExists(atPath: freshTemp.path))
            for url in [oldTemp, unrelatedOld, nearPatternOld] {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date().addingTimeInterval(-7_200)],
                    ofItemAtPath: url.path)
            }
            _ = DownloadStore(baseDirectory: directory)
            #expect(!FileManager.default.fileExists(atPath: oldTemp.path))
            #expect(FileManager.default.fileExists(atPath: freshTemp.path))
            #expect(FileManager.default.fileExists(atPath: unrelatedOld.path))
            #expect(FileManager.default.fileExists(atPath: nearPatternOld.path))
        }
    }

    @Test func reinitPreparedMissingGenerationPreservesPreviousAuthority() throws {
        try withDirectorySync { directory in
            let key = try resumeKey()
            // Publish an old generation using the live primitive first.
            let live = try seededStore(directory: directory)
            #expect(live.setResumeData(for: key, Data("old".utf8)) == .applied)
            let failure = ResumeFilesystemFailure(failWrite: true)
            let store = DownloadStore(
                baseDirectory: directory, artifactFilesystem: failure.filesystem)
            guard case .artifactWriteFailed = store.setResumeData(for: key, Data("new".utf8)) else {
                Issue.record("expected prepared write failure"); return
            }
            let restored = DownloadStore(baseDirectory: directory)
            let watermark = restored.currentArtifactLifecycleWatermark()
            _ = restored.resolveArtifactSynchronouslyForTests(through: watermark)
            #expect(restored.resumeData(for: key) == Data("old".utf8))
        }
    }

    @Test func reinitPublishedMissingGenerationRollsBackToDurablePredecessor() throws {
        try withDirectorySync { directory in
            let live = try seededStore(directory: directory)
            let key = try resumeKey()
            #expect(live.setResumeData(for: key, Data("old".utf8)) == .applied)
            let oldRelative = try #require(live.record(for: key)?.metadata?.resumeDataRelativePath)
            let failure = ResumeFilesystemFailure(failRemovalOf: oldRelative)
            let failing = DownloadStore(
                baseDirectory: directory, artifactFilesystem: failure.filesystem)
            guard case .artifactWriteFailed = failing.setResumeData(
                for: key, Data("new".utf8)) else {
                Issue.record("expected predecessor removal failure"); return
            }
            let newRelative = try #require(
                failing.record(for: key)?.metadata?.resumeDataRelativePath)
            #expect(newRelative != oldRelative)
            try FileManager.default.removeItem(
                at: directory.appendingPathComponent(newRelative))
            let restored = DownloadStore(baseDirectory: directory)
            let watermark = restored.currentArtifactLifecycleWatermark()
            _ = restored.resolveArtifactSynchronouslyForTests(through: watermark)
            #expect(restored.record(for: key)?.metadata?.resumeDataRelativePath == oldRelative)
            #expect(restored.resumeData(for: key) == Data("old".utf8))
        }
    }

    private func withDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    private func withDirectorySync(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func resumeKey() throws -> DownloadAttemptKey {
        DownloadAttemptKey(
            ratingKey: "plex:resume-compose",
            attemptID: try #require(DownloadAttemptID(rawValue: "attempt")))
    }

    private func seededStore(
        directory: URL,
        writeGate: ResumeWriteGate? = nil,
        failure: ResumeFilesystemFailure? = nil
    ) throws -> DownloadStore {
        let filesystem = writeGate?.filesystem ?? failure?.filesystem ?? .live
        let store = DownloadStore(baseDirectory: directory, artifactFilesystem: filesystem)
        let key = try resumeKey()
        if store.record(for: key) == nil {
            let record = DownloadRecord(
                ratingKey: key.ratingKey, attemptID: key.attemptID, title: "Resume",
                localURL: directory.appendingPathComponent("compose.mp4"), status: .paused,
                metadata: OfflineMetadata(
                    ratingKey: key.ratingKey, title: "Resume", type: "movie",
                    resumeMode: .staticByteRange))
            guard case .committed = store.createAttemptOwnedRecord(
                record, attemptID: key.attemptID) else {
                throw SeedFailure()
            }
        }
        return store
    }

    private func resumeArtifacts(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.contains(".resume-") }
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

private struct InjectedArtifactFailure: Error {}
private struct SeedFailure: Error {}

private final class ResumeWriteGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var hasBlocked = false
    lazy var filesystem = DownloadArtifactFilesystem(
        writeAuthArtifact: { [self] data, url, _ in
            let shouldBlock = lock.withLock {
                defer { hasBlocked = true }
                return !hasBlocked
            }
            if shouldBlock { started.signal(); release.wait() }
            try DownloadArtifactFileCommitter().commit(data, to: url)
        },
        removeItem: { url, fm in try fm.removeItem(at: url) },
        fileExists: { url, fm in fm.fileExists(atPath: url.path) })
}

private final class ResumeFilesystemFailure: @unchecked Sendable {
    let failWrite: Bool
    let failRemovalOf: String?
    let writeOverride: (@Sendable (Data, URL) throws -> Void)?
    init(failWrite: Bool = false, failRemovalOf: String? = nil,
         writeOverride: (@Sendable (Data, URL) throws -> Void)? = nil) {
        self.failWrite = failWrite
        self.failRemovalOf = failRemovalOf
        self.writeOverride = writeOverride
    }
    lazy var filesystem = DownloadArtifactFilesystem(
        writeAuthArtifact: { [self] data, url, _ in
            if let writeOverride { try writeOverride(data, url); return }
            if failWrite { throw InjectedArtifactFailure() }
            try DownloadArtifactFileCommitter().commit(data, to: url)
        },
        removeItem: { [self] url, fm in
            if url.lastPathComponent == failRemovalOf { throw InjectedArtifactFailure() }
            try fm.removeItem(at: url)
        },
        fileExists: { url, fm in fm.fileExists(atPath: url.path) })
}

private final class FailFirstResumeWriteGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var attempts = 0
    lazy var filesystem = DownloadArtifactFilesystem(
        writeAuthArtifact: { [self] data, url, _ in
            let attempt = lock.withLock { attempts += 1; return attempts }
            if attempt == 1 {
                started.signal(); release.wait()
                throw InjectedArtifactFailure()
            }
            try DownloadArtifactFileCommitter().commit(data, to: url)
        },
        removeItem: { url, fm in try fm.removeItem(at: url) },
        fileExists: { url, fm in fm.fileExists(atPath: url.path) })
}

/// First auth-artifact write throws; every later write commits normally and the second attempt
/// signals `retried`. Models a transient filesystem fault that leaves a failed-but-queued
/// inactive head for a successor submission to restart.
private final class FailOnceThenSignalResumeWrite: @unchecked Sendable {
    let retried = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var attempts = 0
    lazy var failure = ResumeFilesystemFailure(writeOverride: { [self] data, url in
        let attempt = lock.withLock { attempts += 1; return attempts }
        if attempt == 1 { throw InjectedArtifactFailure() }
        try DownloadArtifactFileCommitter().commit(data, to: url)
        if attempt == 2 { retried.signal() }
    })
}

private final class ArmableTerminalIndexFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var hasFailed = false
    func armOnce() { lock.withLock { armed = true } }
    func write(_ data: Data, to url: URL) throws {
        let fail = lock.withLock {
            guard armed, !hasFailed else { return false }
            hasFailed = true
            return true
        }
        if fail { throw InjectedArtifactFailure() }
        try DownloadIndexFileCommitter().commit(data, to: url)
    }
}

private final class TerminalRemovalGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let target: String
    private let index: ArmableTerminalIndexFailure
    private let lock = NSLock()
    private var blocked = false
    init(target: String, index: ArmableTerminalIndexFailure) {
        self.target = target; self.index = index
    }
    lazy var filesystem = DownloadArtifactFilesystem(
        writeAuthArtifact: { data, url, _ in
            try DownloadArtifactFileCommitter().commit(data, to: url)
        },
        removeItem: { [self] url, fm in
            let shouldBlock = lock.withLock {
                guard url.lastPathComponent == target, !blocked else { return false }
                blocked = true
                return true
            }
            if shouldBlock {
                started.signal(); release.wait(); index.armOnce()
            }
            try fm.removeItem(at: url)
        },
        fileExists: { url, fm in fm.fileExists(atPath: url.path) })
}

private final class CaptureFailingResumeWrite: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: URL?
    var destination: URL? { lock.withLock { captured } }
    lazy var failure = ResumeFilesystemFailure(writeOverride: { [self] _, url in
        lock.withLock { captured = url }
        throw InjectedArtifactFailure()
    })
}

private final class BlockingTerminalIndexFailure: @unchecked Sendable {
    let terminalStarted = DispatchSemaphore(value: 0)
    let releaseTerminal = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var armed = false
    private var failed = false
    func arm() { lock.withLock { armed = true } }
    func write(_ data: Data, to url: URL) throws {
        let shouldBlock = lock.withLock {
            guard armed, !failed else { return false }
            failed = true
            return true
        }
        if shouldBlock {
            terminalStarted.signal()
            releaseTerminal.wait()
            throw InjectedArtifactFailure()
        }
        try DownloadIndexFileCommitter().commit(data, to: url)
    }
}

private final class BlockingTerminalRemovalGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let target: String
    private let index: BlockingTerminalIndexFailure
    private let lock = NSLock()
    private var blocked = false
    private var writes = 0
    var writeCount: Int { lock.withLock { writes } }
    init(target: String, index: BlockingTerminalIndexFailure) {
        self.target = target; self.index = index
    }
    lazy var filesystem = DownloadArtifactFilesystem(
        writeAuthArtifact: { [self] data, url, _ in
            lock.withLock { writes += 1 }
            try DownloadArtifactFileCommitter().commit(data, to: url)
        },
        removeItem: { [self] url, fm in
            let shouldBlock = lock.withLock {
                guard url.lastPathComponent == target, !blocked else { return false }
                blocked = true
                return true
            }
            if shouldBlock {
                started.signal(); release.wait(); index.arm()
            }
            try fm.removeItem(at: url)
        },
        fileExists: { url, fm in fm.fileExists(atPath: url.path) })
}
