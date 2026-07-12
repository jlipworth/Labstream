import Foundation
import PMSKit

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
    private var outcomes: [UInt64: Outcome] = [:]

    func register(
        key: DownloadAttemptKey,
        generation: UInt64,
        intentID: UUID,
        preparedRevision: DownloadStore.PersistenceTicket
    ) -> Ticket {
        condition.lock()
        nextSequence += 1
        let sequence = nextSequence
        outcomes[sequence] = .pending
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
        guard outcomes[ticket.sequence] != nil else {
            condition.unlock()
            return
        }
        outcomes[ticket.sequence] = outcome
        condition.broadcast()
        condition.unlock()
    }

    func waitSynchronously(through watermark: Watermark) -> FlushResult {
        blockingWait(through: watermark, timeout: nil)
    }

    func flush(through watermark: Watermark, timeout: TimeInterval) async -> FlushResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                continuation.resume(returning: blockingWait(
                    through: watermark,
                    timeout: max(0, timeout)
                ))
            }
        }
    }

    private func blockingWait(through watermark: Watermark, timeout: TimeInterval?) -> FlushResult {
        condition.lock()
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            var pending = false
            let sequences = watermark.sequence == 0 ? [] : Array(1...watermark.sequence)
            for sequence in sequences where outcomes[sequence] != nil {
                switch outcomes[sequence]! {
                case .pending:
                    pending = true
                case .completed:
                    continue
                case .failed(let failure):
                    // The durable row intent remains retry authority. Retire this process attempt
                    // after reporting it once so a newly registered retry is not poisoned forever.
                    outcomes.removeValue(forKey: sequence)
                    condition.unlock()
                    return .failed(failure)
                }
            }
            if !pending {
                for sequence in sequences { outcomes.removeValue(forKey: sequence) }
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

    static let live = Self(
        writeAuthArtifact: { data, url, fileManager in
            try CredentialArtifactStorage.writeAuthArtifact(data, to: url, fileManager: fileManager)
        },
        removeItem: { url, fileManager in try fileManager.removeItem(at: url) },
        fileExists: { url, fileManager in fileManager.fileExists(atPath: url.path) }
    )
}
