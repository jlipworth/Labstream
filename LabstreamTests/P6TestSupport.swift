#if !os(tvOS)
import Foundation
import PMSKit
import Synchronization
import Testing
@testable import Labstream

/// A production scheduling acknowledgement, without a timer racing a loaded executor.
final class P6Acknowledgement<Value: Sendable>: @unchecked Sendable {
    private struct State {
        var value: Value?
        var waiters: [CheckedContinuation<Value, Never>] = []
    }
    private let state = Mutex(State())
    func signal(_ value: Value) {
        let waiters = state.withLock { state -> [CheckedContinuation<Value, Never>] in
            guard state.value == nil else { return [] }
            state.value = value
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume(returning: value) }
    }
    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            let value = state.withLock { state -> Value? in
                if let value = state.value { return value }
                state.waiters.append(continuation)
                return nil
            }
            if let value { continuation.resume(returning: value) }
        }
    }
}

/// Dedicated semaphore gates are released independently of MainActor, even after assertion failure.
final class P6Hold: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let acknowledgement = P6Acknowledgement<Bool>()
    let release = DispatchSemaphore(value: 0)
    private let armed = Mutex(false)
    func arm() { armed.withLock { $0 = true } }
    func hit() {
        guard armed.withLock({ value in let old = value; value = false; return old }) else { return }
        entered.signal()
        acknowledgement.signal(true)
        _ = release.wait(timeout: .now() + 10)
    }
}

func p6Signal(_ signal: DispatchSemaphore, seconds: Double = 2) async -> Bool {
    await withCheckedContinuation { continuation in
        Thread.detachNewThread { continuation.resume(returning: signal.wait(timeout: .now() + seconds) == .success) }
    }
}

final class P6Fixture: @unchecked Sendable {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("p6-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func store(filesystem: DownloadStoreFilesystem = .live,
               index: DownloadStore.IndexPersistence = .live,
               promotion: DownloadPromotionFilesystem = .live,
               checkpoint: DownloadStaticCheckpointFilesystem = .live) -> DownloadStore {
        DownloadStore(baseDirectory: directory, indexPersistence: index,
                      checkpointFilesystem: checkpoint, promotionFilesystem: promotion,
                      storeFilesystem: filesystem)
    }
    func record(_ suffix: String = "a", status: DownloadStatus = .downloading,
                mode: DownloadResumeMode = .staticByteRange, ratingKey: String = "plex:fixture", filename: String = "fixture.mp4") -> DownloadRecord {
        let id = DownloadAttemptID(rawValue: "attempt-\(suffix)")!
        var metadata = OfflineMetadata(ratingKey: ratingKey, title: "Fixture", type: "movie")
        metadata.resumeMode = mode
        return DownloadRecord(ratingKey: ratingKey, attemptID: id, title: "Fixture",
                              localURL: directory.appendingPathComponent(filename),
                              status: status, metadata: metadata)
    }
    @discardableResult
    func seed(_ store: DownloadStore, status: DownloadStatus = .downloading,
              mode: DownloadResumeMode = .staticByteRange) throws -> DownloadAttemptKey {
        let record = record(status: status, mode: mode)
        let key = DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: record.attemptID!)
        try #require(store.createAttemptOwnedRecord(record, attemptID: key.attemptID) == .committed(key))
        return key
    }
    func working(_ store: DownloadStore, _ key: DownloadAttemptKey) throws -> URL {
        let url = try #require(store.attemptWorkingFileURL(for: key))
        try Data([1, 2, 3]).write(to: url)
        return url
    }
}

/// Both threads are ready before the held syscall begins. Completion before release is a
/// lock-exclusion assertion, not an I/O throughput measurement; every gate has a cleanup bound.
func p6ExpectReadableWhileHeld(_ store: DownloadStore, key: DownloadAttemptKey,
                               hold: P6Hold, phase: String = "P6.3") async throws {
    let done = DispatchSemaphore(value: 0)
    let ready = DispatchSemaphore(value: 0)
    let begin = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        ready.signal()
        begin.wait()
        _ = store.record(for: key)
        done.signal()
    }
    try #require(await p6Signal(ready))
    begin.signal()
    let readable = await p6Signal(done)
        #expect(readable)
    hold.release.signal()
    if !readable { try #require(await p6Signal(done)) }
}
#endif
