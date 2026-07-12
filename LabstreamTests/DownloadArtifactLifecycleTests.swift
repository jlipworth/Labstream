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

    private func withDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
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
