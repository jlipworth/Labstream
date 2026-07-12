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
    init(failWrite: Bool = false, failRemovalOf: String? = nil) {
        self.failWrite = failWrite; self.failRemovalOf = failRemovalOf
    }
    lazy var filesystem = DownloadArtifactFilesystem(
        writeAuthArtifact: { [self] data, url, _ in
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
