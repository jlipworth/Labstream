import Foundation
import Testing
@testable import Labstream

struct RevisionedPersistenceWriterTests {
    @Test func coalescesQueuedFullSnapshotsToNewestRevision() async {
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let commits = LockedBox<[Int]>([])
        let writer = RevisionedPersistenceWriter<Int>(
            encode: { value in
                if value == 1 {
                    firstStarted.signal()
                    releaseFirst.wait()
                }
                return Data(String(value).utf8)
            },
            commit: { data in
                commits.withValue { $0.append(Int(String(decoding: data, as: UTF8.self))!) }
            }
        )

        writer.submit(revision: 1, snapshot: 1)
        #expect(await waitForSignal(firstStarted))
        writer.submit(revision: 2, snapshot: 2)
        writer.submit(revision: 3, snapshot: 3)
        releaseFirst.signal()

        #expect(await writer.flush(through: 3, timeout: 1) == .committed(revision: 3))
        #expect(commits.value == [3])
    }

    @Test func failedNewestSnapshotStaysDirtyAndFlushRetriesIt() async {
        let attempts = LockedBox(0)
        let writer = RevisionedPersistenceWriter<Int>(
            encode: { Data(String($0).utf8) },
            commit: { _ in
                let attempt = attempts.withValue { value in
                    value += 1
                    return value
                }
                if attempt <= 2 { throw TestFailure.expected }
            }
        )

        writer.submit(revision: 1, snapshot: 1)
        #expect(await eventually { writer.state.dirtyRevision == 1 })
        let first = await writer.flush(through: 1, timeout: 1)
        guard case .failed(let failure) = first else {
            Issue.record("Expected an observable failed flush, got \(first)")
            return
        }
        #expect(failure.revision == 1)
        #expect(failure.stage == .commit)
        #expect(!failure.errorType.contains("expected"))
        #expect(writer.state.dirtyRevision == 1)

        #expect(await writer.flush(through: 1, timeout: 1) == .committed(revision: 1))
        #expect(writer.state.dirtyRevision == nil)
    }

    @Test func newerSnapshotSupersedesFailedDirtyRevision() async {
        let shouldFail = LockedBox(true)
        let commits = LockedBox<[Int]>([])
        let writer = RevisionedPersistenceWriter<Int>(
            encode: { Data(String($0).utf8) },
            commit: { data in
                if shouldFail.withValue({ value in defer { value = false }; return value }) {
                    throw TestFailure.expected
                }
                commits.withValue { $0.append(Int(String(decoding: data, as: UTF8.self))!) }
            }
        )

        writer.submit(revision: 1, snapshot: 1)
        #expect(await eventually { writer.state.dirtyRevision == 1 })
        writer.submit(revision: 2, snapshot: 2)

        #expect(await writer.flush(through: 2, timeout: 1) == .committed(revision: 2))
        #expect(commits.value == [2])
        #expect(writer.state.dirtyRevision == nil)
    }

    @Test func encodeFailureIsObservableAndRetried() async {
        let attempts = LockedBox(0)
        let writer = RevisionedPersistenceWriter<Int>(
            encode: { value in
                let attempt = attempts.withValue { count in
                    count += 1
                    return count
                }
                if attempt <= 2 { throw TestFailure.expected }
                return Data(String(value).utf8)
            },
            commit: { _ in }
        )

        writer.submit(revision: 1, snapshot: 1)
        #expect(await eventually { writer.state.dirtyRevision == 1 })
        let result = await writer.flush(through: 1, timeout: 1)
        guard case .failed(let failure) = result else {
            Issue.record("Expected encode failure, got \(result)")
            return
        }
        #expect(failure.stage == .encode)
        #expect(await writer.flush(through: 1, timeout: 1) == .committed(revision: 1))
    }

    @Test func timeoutDoesNotAbandonInFlightCommit() async {
        let writeStarted = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)
        let writer = makeWriter(commits: LockedBox([])) { _ in
            writeStarted.signal()
            releaseWrite.wait()
        }

        writer.submit(revision: 1, snapshot: 1)
        #expect(await waitForSignal(writeStarted))
        #expect(await writer.flush(through: 1, timeout: 0.02)
            == .timedOut(targetRevision: 1, committedRevision: 0))
        releaseWrite.signal()
        #expect(await writer.flush(through: 1, timeout: 1) == .committed(revision: 1))
    }

    @Test func ignoresLateSubmissionOlderThanNewestAcceptedRevision() async {
        let commits = LockedBox<[Int]>([])
        let writer = makeWriter(commits: commits)
        writer.submit(revision: 2, snapshot: 2)
        writer.submit(revision: 1, snapshot: 1)

        #expect(await writer.flush(through: 2, timeout: 1) == .committed(revision: 2))
        #expect(commits.value == [2])
        #expect(writer.state.newestSubmittedRevision == 2)
    }

    @Test func invalidTimeoutsReturnImmediatelyWithoutAbandoningTarget() async {
        let writer = makeWriter(commits: LockedBox([]))
        #expect(await writer.flush(through: 1, timeout: -Double.infinity)
            == .timedOut(targetRevision: 1, committedRevision: 0))
        #expect(await writer.flush(through: 1, timeout: Double.nan)
            == .timedOut(targetRevision: 1, committedRevision: 0))
        #expect(await writer.flush(through: 1, timeout: Double.infinity)
            == .timedOut(targetRevision: 1, committedRevision: 0))
    }

    private func makeWriter(
        commits: LockedBox<[Int]>,
        beforeCommit: @escaping @Sendable (Int) -> Void = { _ in }
    ) -> RevisionedPersistenceWriter<Int> {
        RevisionedPersistenceWriter<Int>(
            encode: { Data(String($0).utf8) },
            commit: { data in
                let value = Int(String(decoding: data, as: UTF8.self))!
                beforeCommit(value)
                commits.withValue { $0.append(value) }
            }
        )
    }

    private func waitForSignal(_ semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 1) == .success)
            }
        }
    }

    private func eventually(_ predicate: @escaping @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }

    private enum TestFailure: Error {
        case expected
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    @discardableResult
    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }
        return body(&storage)
    }
}
