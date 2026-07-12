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
        /// The intent is permanently dead (retired failed head, deleted row, resolved one-shot
        /// barrier) and will never be re-registered. Ticket waits still observe the recorded
        /// outcome; boundary waits must stop gating on it or one abandonment poisons every
        /// subsequent boundary for the rest of the process.
        var abandoned = false
    }
    private var entries: [UInt64: Entry] = [:]

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
            // the same intent is superseded by it, so the whole chain is prunable. Ticket waits
            // treat a pruned entry as completed. This keeps the entry table bounded by pending
            // and unresolved-failed work instead of growing per registration forever.
            for (sequence, candidate) in entries
            where candidate.intentID == ticket.intentID && sequence <= ticket.sequence {
                entries.removeValue(forKey: sequence)
            }
        } else {
            entry.outcome = outcome
            entries[ticket.sequence] = entry
        }
        condition.broadcast()
        condition.unlock()
    }

    /// Mark every attempt for a permanently abandoned intent as boundary-exempt. Abandonment is
    /// the store's durable statement that no retry will ever re-register this intentID (its failed
    /// head was retired ahead of a queued row deletion, its row was removed, or it was a resolved
    /// one-shot persistence barrier), so boundaries must not report its stale outcome — and must
    /// not wait on it — for the rest of the process. The entries stay so ticket-scoped waiters can
    /// still observe the recorded failure.
    func abandonIntent(_ intentID: UUID) {
        condition.lock()
        var changed = false
        for (sequence, entry) in entries where entry.intentID == intentID && !entry.abandoned {
            var abandoned = entry
            abandoned.abandoned = true
            entries[sequence] = abandoned
            changed = true
        }
        if changed { condition.broadcast() }
        condition.unlock()
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
                condition.unlock()
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
            let candidates = entries
                .filter { $0.key <= watermark.sequence && !$0.value.abandoned }
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
