import Foundation

/// Serializes full-state persistence snapshots without running encoding or I/O under the
/// caller's state lock. Higher revisions subsume lower ones, so queued obsolete snapshots can
/// be coalesced safely.
final class RevisionedPersistenceWriter<Snapshot: Sendable>: @unchecked Sendable {
    enum FailureStage: String, Sendable {
        case encode
        case commit
    }

    struct Failure: Error, Sendable, Equatable {
        let revision: UInt64
        let stage: FailureStage
        /// Type-only on purpose: persistence diagnostics must not retain paths or private text.
        let errorType: String
    }

    enum FlushResult: Sendable, Equatable {
        case committed(revision: UInt64)
        case failed(Failure)
        case timedOut(targetRevision: UInt64, committedRevision: UInt64)
    }

    struct State: Sendable, Equatable {
        let newestSubmittedRevision: UInt64
        let committedRevision: UInt64
        let dirtyRevision: UInt64?
    }

    private struct Submission: Sendable {
        let revision: UInt64
        let snapshot: Snapshot
    }

    private let condition = NSCondition()
    private let workerQueue: DispatchQueue
    private let diagnosticsQueue: DispatchQueue
    private let encode: @Sendable (Snapshot) throws -> Data
    private let commit: @Sendable (Data) throws -> Void
    private let failureObserver: @Sendable (Failure) -> Void

    private var newestSubmittedRevision: UInt64 = 0
    private var committedRevision: UInt64 = 0
    private var pending: Submission?
    private var dirty: Submission?
    private var workerRunning = false
    private var lastFailure: Failure?
    private var outcomeGeneration: UInt64 = 0

    init(
        label: String = "com.visionplay.download-index-writer",
        encode: @escaping @Sendable (Snapshot) throws -> Data,
        commit: @escaping @Sendable (Data) throws -> Void,
        failureObserver: @escaping @Sendable (Failure) -> Void = { _ in }
    ) {
        workerQueue = DispatchQueue(label: label, qos: .utility)
        diagnosticsQueue = DispatchQueue(label: "\(label).diagnostics", qos: .utility)
        self.encode = encode
        self.commit = commit
        self.failureObserver = failureObserver
    }

    /// Registration is synchronous and cheap. Encoding and commit always happen on the worker.
    func submit(revision: UInt64, snapshot: Snapshot) {
        condition.lock()
        guard revision > newestSubmittedRevision else {
            condition.unlock()
            return
        }
        newestSubmittedRevision = revision
        pending = Submission(revision: revision, snapshot: snapshot)
        startWorkerIfNeededLocked()
        condition.unlock()
    }

    func flush(through targetRevision: UInt64, timeout: TimeInterval) async -> FlushResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                continuation.resume(returning: blockingFlush(
                    through: targetRevision,
                    timeout: timeout
                ))
            }
        }
    }

    /// Transitional compatibility for call sites that already perform synchronous disk I/O.
    /// This intentionally has no timeout: the old path returned only after its encode/write
    /// attempt finished. New lifecycle boundaries should use the bounded async API instead.
    func waitSynchronouslyForOutcome(through targetRevision: UInt64) -> FlushResult {
        condition.lock()
        while committedRevision < targetRevision {
            if let failure = lastFailure,
               failure.revision >= targetRevision,
               !workerRunning {
                condition.unlock()
                return .failed(failure)
            }
            condition.wait()
        }
        let revision = committedRevision
        condition.unlock()
        return .committed(revision: revision)
    }

    var state: State {
        condition.lock(); defer { condition.unlock() }
        return State(
            newestSubmittedRevision: newestSubmittedRevision,
            committedRevision: committedRevision,
            dirtyRevision: dirty?.revision
        )
    }

    private func blockingFlush(through targetRevision: UInt64, timeout: TimeInterval) -> FlushResult {
        condition.lock()
        if committedRevision >= targetRevision {
            let revision = committedRevision
            condition.unlock()
            return .committed(revision: revision)
        }

        let startingOutcome = outcomeGeneration
        if !workerRunning, let dirty {
            pending = dirty
            startWorkerIfNeededLocked()
        }
        let boundedTimeout = timeout.isFinite ? max(0, timeout) : 0
        let start = DispatchTime.now().uptimeNanoseconds
        let timeoutNanoseconds = UInt64(min(
            boundedTimeout * 1_000_000_000,
            Double(UInt64.max - start)
        ))
        let deadline = start + timeoutNanoseconds

        while committedRevision < targetRevision {
            if outcomeGeneration > startingOutcome,
               let failure = lastFailure,
               failure.revision >= targetRevision,
               !workerRunning {
                condition.unlock()
                return .failed(failure)
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                let committed = committedRevision
                condition.unlock()
                return .timedOut(
                    targetRevision: targetRevision,
                    committedRevision: committed
                )
            }
            let remaining = Double(deadline - now) / 1_000_000_000
            _ = condition.wait(until: Date().addingTimeInterval(min(remaining, 0.05)))
        }

        let revision = committedRevision
        condition.unlock()
        return .committed(revision: revision)
    }

    private func startWorkerIfNeededLocked() {
        guard !workerRunning else { return }
        workerRunning = true
        workerQueue.async { [self] in runWorker() }
    }

    private func runWorker() {
        while true {
            condition.lock()
            guard let submission = pending else {
                workerRunning = false
                condition.broadcast()
                condition.unlock()
                return
            }
            pending = nil
            condition.unlock()

            do {
                let data: Data
                do { data = try encode(submission.snapshot) }
                catch { throw StagedFailure(stage: .encode, underlying: error) }

                // If a newer full snapshot arrived while this one encoded, the older bytes must
                // never replace the index. A revision accepted after the opaque atomic commit has
                // begun may still follow it, but the serial worker guarantees the newer revision
                // is the final replacement.
                condition.lock()
                let wasSuperseded = submission.revision < newestSubmittedRevision
                condition.unlock()
                if wasSuperseded { continue }

                do { try commit(data) }
                catch { throw StagedFailure(stage: .commit, underlying: error) }

                condition.lock()
                committedRevision = max(committedRevision, submission.revision)
                // A worker always takes the newest accepted pending snapshot. Any retained dirty
                // snapshot is therefore this revision or an older full-state snapshot.
                dirty = nil
                lastFailure = nil
                outcomeGeneration &+= 1
                condition.broadcast()
                condition.unlock()
            } catch let staged as StagedFailure {
                let failure = Failure(
                    revision: submission.revision,
                    stage: staged.stage,
                    errorType: String(reflecting: type(of: staged.underlying))
                )
                condition.lock()
                if pending == nil || pending!.revision <= submission.revision {
                    dirty = submission
                }
                lastFailure = failure
                outcomeGeneration &+= 1
                let shouldStop = pending == nil
                if shouldStop { workerRunning = false }
                condition.broadcast()
                condition.unlock()
                diagnosticsQueue.async { [failureObserver] in failureObserver(failure) }
                if shouldStop { return }
            } catch {
                assertionFailure("Unexpected persistence writer error: \(type(of: error))")
            }
        }
    }

    private struct StagedFailure: Error {
        let stage: FailureStage
        let underlying: any Error
    }
}
