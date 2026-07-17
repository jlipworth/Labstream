import Foundation
import PMSKit
import Darwin

/// Cheap, synchronous registration plus bounded waiting for filesystem-backed download
/// mutations. Registration always precedes filesystem work; the worker reports the terminal
/// index outcome when the operation is safe to release across a lifecycle boundary.
final class DownloadArtifactLifecycleCoordinator: @unchecked Sendable {
    struct Ticket: Sendable, Equatable {
        let sequence: UInt64
        let key: DownloadAttemptKey
        let generation: UInt64
        let intentID: UUID
        let preparedRevision: DownloadStore.PersistenceTicket
    }

    struct Watermark: Sendable, Equatable {
        let sequence: UInt64
    }

    enum FlushResult: Sendable, Equatable {
        case completed
        case failed(Failure)
        case timedOut(sequence: UInt64)
    }

    enum Failure: Sendable, Equatable {
        case persistence(DownloadStore.PersistenceFlushResult)
        case artifact(errorType: String)
    }

    private enum Outcome {
        case pending
        case completed
        case failed(Failure)
    }

    private let condition = NSCondition()
    private var nextSequence: UInt64 = 0
    private struct Entry {
        let intentID: UUID
        var outcome: Outcome
    }
    /// Live work only: pending attempts plus failures whose intent may still be retried. A
    /// sequence leaves this table when its chain completes, or when its intent is permanently
    /// abandoned (retired failed head, deleted row, resolved one-shot barrier) — abandonment and
    /// supersession park exact failures in `retiredFailures` so the table cannot grow per dead
    /// intent and boundary scans only ever walk live work.
    private var entries: [UInt64: Entry] = [:]
    /// Exact outcomes for failed attempts whose entries were retired (superseded by a completed
    /// retry, or permanently abandoned). Ticket-scoped waiters consult this when their sequence is
    /// gone from `entries`, so a delayed waiter still observes its own attempt's failure instead
    /// of inheriting a retry's success. Bounded FIFO; an evicted (ancient) ticket reads
    /// `.completed`, the same as any pruned completed chain.
    private var retiredFailures: [UInt64: Failure] = [:]
    private var retiredFailureOrder: [UInt64] = []
    private static let retiredFailureCap = 512

    func register(
        key: DownloadAttemptKey,
        generation: UInt64,
        intentID: UUID,
        preparedRevision: DownloadStore.PersistenceTicket
    ) -> Ticket {
        condition.lock()
        nextSequence += 1
        let sequence = nextSequence
        entries[sequence] = Entry(intentID: intentID, outcome: .pending)
        condition.unlock()
        return Ticket(
            sequence: sequence,
            key: key,
            generation: generation,
            intentID: intentID,
            preparedRevision: preparedRevision
        )
    }

    var currentWatermark: Watermark {
        condition.lock(); defer { condition.unlock() }
        return Watermark(sequence: nextSequence)
    }

    func complete(_ ticket: Ticket) {
        finish(ticket, outcome: .completed)
    }

    func fail(_ ticket: Ticket, _ failure: DownloadStore.PersistenceFlushResult) {
        finish(ticket, outcome: .failed(.persistence(failure)))
    }

    func failArtifact(_ ticket: Ticket, errorType: String) {
        finish(ticket, outcome: .failed(.artifact(errorType: errorType)))
    }

    private func finish(_ ticket: Ticket, outcome: Outcome) {
        condition.lock()
        guard var entry = entries[ticket.sequence], entry.intentID == ticket.intentID else {
            condition.unlock()
            return
        }
        if case .completed = outcome {
            // A completed newest attempt can never gate a boundary, and every older attempt for
            // the same intent is superseded by it, so the whole chain leaves the live table.
            // Superseded pending attempts read as completed (the intent is durably resolved);
            // superseded FAILED attempts keep their exact outcome in `retiredFailures` so a
            // delayed holder of the failed ticket is not misreported as successful.
            for (sequence, candidate) in entries
            where candidate.intentID == ticket.intentID && sequence <= ticket.sequence {
                entries.removeValue(forKey: sequence)
                if sequence != ticket.sequence, case .failed(let failure) = candidate.outcome {
                    retireFailureLocked(sequence: sequence, failure: failure)
                }
            }
        } else {
            entry.outcome = outcome
            entries[ticket.sequence] = entry
        }
        condition.broadcast()
        condition.unlock()
    }

    /// Retire every attempt for a permanently abandoned intent. Abandonment is the store's durable
    /// statement that no retry will ever re-register this intentID (its failed head was retired
    /// ahead of a queued row deletion, its row was removed, or it was a resolved one-shot
    /// persistence barrier), so boundaries must not report its stale outcome — and must not wait
    /// on it — for the rest of the process. Attempts leave the live table entirely: failed ones
    /// park their exact outcome in `retiredFailures`, and still-pending ones resolve to a terminal
    /// abandonment failure so ticket-scoped waiters unblock instead of waiting forever on an
    /// intent that can no longer finish.
    func abandonIntent(_ intentID: UUID) {
        condition.lock()
        var changed = false
        for (sequence, entry) in entries where entry.intentID == intentID {
            entries.removeValue(forKey: sequence)
            switch entry.outcome {
            case .failed(let failure):
                retireFailureLocked(sequence: sequence, failure: failure)
            case .pending:
                retireFailureLocked(
                    sequence: sequence, failure: .artifact(errorType: "intentAbandoned"))
            case .completed:
                break
            }
            changed = true
        }
        if changed { condition.broadcast() }
        condition.unlock()
    }

    #if DEBUG
    /// Test-only visibility into retirement: live table must hold only in-flight/retryable work.
    var liveEntryCountForTesting: Int {
        condition.lock(); defer { condition.unlock() }
        return entries.count
    }

    /// Test-only visibility into the bounded retired-failure store.
    var retiredFailureCountForTesting: Int {
        condition.lock(); defer { condition.unlock() }
        return retiredFailures.count
    }
    #endif

    /// Fail and permanently abandon an attempt in a single transition, for intents that are dead
    /// the moment they fail (one-shot persistence barriers under a never-re-registered intentID).
    /// Fusing the two steps means no boundary waiter can wake between `fail` and `abandonIntent`
    /// and observe the intermediate failed-but-live entry. Ticket-scoped waiters still read the
    /// exact failure from `retiredFailures`.
    func failAndAbandonIntent(_ ticket: Ticket, _ failure: DownloadStore.PersistenceFlushResult) {
        condition.lock()
        for (sequence, entry) in entries where entry.intentID == ticket.intentID {
            entries.removeValue(forKey: sequence)
            switch entry.outcome {
            case .failed(let recorded):
                retireFailureLocked(sequence: sequence, failure: recorded)
            case .pending where sequence == ticket.sequence:
                retireFailureLocked(sequence: sequence, failure: .persistence(failure))
            case .pending:
                retireFailureLocked(
                    sequence: sequence, failure: .artifact(errorType: "intentAbandoned"))
            case .completed:
                break
            }
        }
        condition.broadcast()
        condition.unlock()
    }

    /// Caller must hold `condition`.
    private func retireFailureLocked(sequence: UInt64, failure: Failure) {
        if retiredFailures.updateValue(failure, forKey: sequence) == nil {
            retiredFailureOrder.append(sequence)
        }
        while retiredFailureOrder.count > Self.retiredFailureCap {
            retiredFailures.removeValue(forKey: retiredFailureOrder.removeFirst())
        }
    }

    func waitSynchronously(for ticket: Ticket) -> FlushResult {
        blockingWait(for: ticket, timeout: nil)
    }

    func waitSynchronously(through watermark: Watermark) -> FlushResult {
        blockingBoundaryWait(through: watermark, timeout: nil)
    }

    func flush(through watermark: Watermark, timeout: TimeInterval) async -> FlushResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                continuation.resume(returning: blockingBoundaryWait(
                    through: watermark,
                    timeout: max(0, timeout)
                ))
            }
        }
    }

    private func blockingWait(for ticket: Ticket, timeout: TimeInterval?) -> FlushResult {
        condition.lock()
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            guard let entry = entries[ticket.sequence], entry.intentID == ticket.intentID else {
                // Retired sequences resolve to their exact recorded failure; a pruned completed
                // chain (or an evicted ancient failure) reads as completed.
                let retired = retiredFailures[ticket.sequence]
                condition.unlock()
                if let retired { return .failed(retired) }
                return .completed
            }
            switch entry.outcome {
            case .completed:
                condition.unlock()
                return .completed
            case .failed(let failure):
                condition.unlock()
                return .failed(failure)
            case .pending:
                break
            }
            if let deadline {
                guard Date() < deadline else {
                    condition.unlock()
                    return .timedOut(sequence: ticket.sequence)
                }
                _ = condition.wait(until: min(deadline, Date().addingTimeInterval(0.05)))
            } else {
                condition.wait()
            }
        }
    }

    /// A boundary observes the newest process attempt for each durable intent at or below its
    /// immutable watermark. Registering a retry supersedes only the older attempt for that same
    /// intent; unrelated failures remain visible. Outcomes are not destructively consumed by
    /// waiters, so concurrent waiters over one watermark receive the same result — though a
    /// completed retry or an explicit abandonment may upgrade what a still-blocked waiter
    /// eventually observes, because the underlying intent is then durably resolved or dead.
    private func blockingBoundaryWait(
        through watermark: Watermark,
        timeout: TimeInterval?
    ) -> FlushResult {
        condition.lock()
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            // `entries` holds live work only — abandoned/superseded attempts were retired — so
            // one dead intent can no longer poison every later boundary, and the scan cost is
            // bounded by in-flight and retryable-failed attempts.
            let candidates = entries.filter { $0.key <= watermark.sequence }
            var latestByIntent: [UUID: (sequence: UInt64, outcome: Outcome)] = [:]
            for (sequence, entry) in candidates {
                if sequence > (latestByIntent[entry.intentID]?.sequence ?? 0) {
                    latestByIntent[entry.intentID] = (sequence, entry.outcome)
                }
            }
            var pending = false
            for value in latestByIntent.values {
                switch value.outcome {
                case .pending:
                    pending = true
                case .completed:
                    continue
                case .failed(let failure):
                    condition.unlock()
                    return .failed(failure)
                }
            }
            if !pending {
                condition.unlock()
                return .completed
            }
            if let deadline {
                guard Date() < deadline else {
                    condition.unlock()
                    return .timedOut(sequence: watermark.sequence)
                }
                _ = condition.wait(until: min(deadline, Date().addingTimeInterval(0.05)))
            } else {
                condition.wait()
            }
        }
    }
}

/// Filesystem seam for deterministic artifact ordering/fault tests. The live write primitive
/// applies the same protection and backup-exclusion policy as the legacy resume path.
struct DownloadArtifactFilesystem: Sendable {
    let writeAuthArtifact: @Sendable (Data, URL, FileManager) throws -> Void
    let removeItem: @Sendable (URL, FileManager) throws -> Void
    let fileExists: @Sendable (URL, FileManager) -> Bool
    let syncParentDirectory: @Sendable (URL) throws -> Void

    init(
        writeAuthArtifact: @escaping @Sendable (Data, URL, FileManager) throws -> Void,
        removeItem: @escaping @Sendable (URL, FileManager) throws -> Void,
        fileExists: @escaping @Sendable (URL, FileManager) -> Bool,
        syncParentDirectory: @escaping @Sendable (URL) throws -> Void = Self.liveDirectorySync
    ) {
        self.writeAuthArtifact = writeAuthArtifact
        self.removeItem = removeItem
        self.fileExists = fileExists
        self.syncParentDirectory = syncParentDirectory
    }

    private static let liveDirectorySync: @Sendable (URL) throws -> Void = { child in
        let descriptor = Darwin.open(child.deletingLastPathComponent().path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }

    static let live = Self(
        writeAuthArtifact: { data, url, fileManager in
            try DownloadArtifactFileCommitter().commit(data, to: url)
        },
        removeItem: { url, fileManager in try fileManager.removeItem(at: url) },
        fileExists: { url, fileManager in fileManager.fileExists(atPath: url.path) },
        syncParentDirectory: liveDirectorySync
    )
}
