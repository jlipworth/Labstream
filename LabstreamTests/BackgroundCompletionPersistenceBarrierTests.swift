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
                identifiers: ["session"],
                flush: { await store.flushPersistence(through: ticket, timeout: 1) },
                release: { identifier in recorder.identifiers.append(identifier) }
            )
        }

        #expect(await writes.retryStarted.wait(timeout: 1))
        #expect(await MainActor.run { recorder.identifiers.isEmpty })
        writes.releaseRetry.signal()
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
            identifiers: ["failure"],
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
            identifiers: ["timeout"],
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
        let start = ContinuousClock.now
        let barrier = Task {
            await BackgroundCompletionPersistenceBarrier.flushThenRelease(
                identifiers: ["session"],
                flush: { await store.flushPersistence(through: ticket, timeout: 0.05) },
                observe: { _ in events.append("observed") },
                release: { _ in events.append("released") }
            )
        }

        #expect(await writes.retryStarted.wait(timeout: 1))
        let result = await barrier.value
        let elapsed = start.duration(to: .now)
        #expect(result == .timedOut(targetRevision: ticket.revision, committedRevision: 0))
        #expect(elapsed >= .milliseconds(40))
        #expect(elapsed < .seconds(2))
        #expect(events.values == ["observed", "released"])

        writes.releaseRetry.signal()
        #expect(await store.flushPersistence(through: ticket, timeout: 1)
            == .committed(revision: ticket.revision))
    }
}

@MainActor
private final class CompletionReleaseRecorder {
    var identifiers: [String] = []
}

private final class BlockingRetryWriter: @unchecked Sendable {
    let retryStarted = AsyncSemaphore()
    let releaseRetry = AsyncSemaphore()
    private let lock = NSLock()
    private var attempts = 0

    var attemptCount: Int { lock.withLock { attempts } }

    func write(_ data: Data, to url: URL) throws {
        let attempt = lock.withLock {
            attempts += 1
            return attempts
        }
        if attempt == 1 { throw InjectedBackgroundWriteFailure() }
        if attempt == 2 {
            retryStarted.signal()
            releaseRetry.waitSynchronously()
        }
        try data.write(to: url, options: .atomic)
    }
}

private struct InjectedBackgroundWriteFailure: Error {}

private final class AsyncSemaphore: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func signal() { semaphore.signal() }
    func waitSynchronously() { semaphore.wait() }

    func wait(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [semaphore] in
                continuation.resume(returning: semaphore.wait(timeout: .now() + timeout) == .success)
            }
        }
    }
}

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
