import Foundation
import PMSKit
import Testing
@testable import Labstream

struct BackgroundCompletionPersistenceBarrierTests {
    @Test func dirtyRevisionRetriesBeforeHandlerRelease() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-completion-flush-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writes = BlockingRetryWriter()
        let store = DownloadStore(
            baseDirectory: directory,
            indexPersistence: .init { data, url in try writes.write(data, to: url) }
        )
        store.upsert(DownloadRecord(
            ratingKey: "plex:background",
            title: "Background",
            localURL: directory.appendingPathComponent("background.mp4"),
            status: .complete
        ))
        #expect(writes.attemptCount == 1)

        let ticket = store.currentPersistenceTicket()
        let recorder = await MainActor.run { CompletionReleaseRecorder() }
        let barrier = Task {
            await BackgroundCompletionPersistenceBarrier.flushThenRelease(
                releases: ["session"],
                flush: { await store.flushPersistence(through: ticket, timeout: 30) },
                release: { identifier in recorder.identifiers.append(identifier) }
            )
        }

        await writes.waitUntilRetryStarted()
        #expect(await MainActor.run { recorder.identifiers.isEmpty })
        writes.releaseRetry()
        #expect(await barrier.value == .committed(revision: ticket.revision))
        #expect(await MainActor.run { recorder.identifiers == ["session"] })
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("index.json").path
        ))
    }

    @Test func failureAndTimeoutRemainObservableButReleaseHandlers() async {
        let recorder = await MainActor.run { CompletionReleaseRecorder() }
        let observed = LockedResultBox()
        let failure = DownloadStore.PersistenceFlushResult.failed(
            revision: 4,
            stage: "commit",
            errorType: "InjectedFailure"
        )

        #expect(await BackgroundCompletionPersistenceBarrier.flushThenRelease(
            releases: ["failure"],
            flush: { failure },
            observe: { observed.value = $0 },
            release: { recorder.identifiers.append($0) }
        ) == failure)
        #expect(observed.value == failure)

        let timeout = DownloadStore.PersistenceFlushResult.timedOut(
            targetRevision: 5,
            committedRevision: 3
        )
        #expect(await BackgroundCompletionPersistenceBarrier.flushThenRelease(
            releases: ["timeout"],
            flush: { timeout },
            release: { recorder.identifiers.append($0) }
        ) == timeout)
        #expect(await MainActor.run { recorder.identifiers == ["failure", "timeout"] })
    }

    @Test func blockedRetryTimesOutBeforeReleaseAndCanStillCommitLater() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-completion-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writes = BlockingRetryWriter()
        let store = DownloadStore(
            baseDirectory: directory,
            indexPersistence: .init { data, url in try writes.write(data, to: url) }
        )
        store.upsert(DownloadRecord(
            ratingKey: "plex:timeout",
            title: "Timeout",
            localURL: directory.appendingPathComponent("timeout.mp4"),
            status: .complete
        ))
        let ticket = store.currentPersistenceTicket()
        let events = LockedEventBox()
        let barrier = Task {
            await BackgroundCompletionPersistenceBarrier.flushThenRelease(
                releases: ["session"],
                flush: { await store.flushPersistence(through: ticket, timeout: 0.05) },
                observe: { _ in events.append("observed") },
                release: { _ in events.append("released") }
            )
        }

        await writes.waitUntilRetryStarted()
        let result = await barrier.value
        #expect(result == .timedOut(targetRevision: ticket.revision, committedRevision: 0))
        #expect(events.values == ["observed", "released"])

        writes.releaseRetry()
        #expect(await store.flushPersistence(through: ticket, timeout: 1)
            == .committed(revision: ticket.revision))
    }
}

@MainActor
private final class CompletionReleaseRecorder {
    var identifiers: [String] = []
}

private final class BlockingRetryWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    private var retryStarted = false
    private var retryStartWaiter: CheckedContinuation<Void, Never>?
    private let retryReleaseCondition = NSCondition()
    private var isRetryReleased = false

    var attemptCount: Int { lock.withLock { attempts } }

    func write(_ data: Data, to url: URL) throws {
        let attempt = lock.withLock {
            attempts += 1
            return attempts
        }
        if attempt == 1 { throw InjectedBackgroundWriteFailure() }
        if attempt == 2 {
            noteRetryStarted()
            retryReleaseCondition.lock()
            while !isRetryReleased { retryReleaseCondition.wait() }
            retryReleaseCondition.unlock()
        }
        try data.write(to: url, options: .atomic)
    }

    func waitUntilRetryStarted() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if retryStarted { return true }
                precondition(retryStartWaiter == nil)
                retryStartWaiter = continuation
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func releaseRetry() {
        retryReleaseCondition.lock()
        isRetryReleased = true
        retryReleaseCondition.broadcast()
        retryReleaseCondition.unlock()
    }

    private func noteRetryStarted() {
        let waiter = lock.withLock {
            retryStarted = true
            defer { retryStartWaiter = nil }
            return retryStartWaiter
        }
        waiter?.resume()
    }
}

private struct InjectedBackgroundWriteFailure: Error {}

private final class LockedResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: DownloadStore.PersistenceFlushResult?

    var value: DownloadStore.PersistenceFlushResult? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class LockedEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}
