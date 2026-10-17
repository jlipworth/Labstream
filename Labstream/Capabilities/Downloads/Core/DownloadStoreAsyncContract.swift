import Foundation
import PMSKit

/// P6.1 shared contract. Time is monotonic and a deadline never slides at an adapter boundary.
/// A timeout abandons only a waiter: the submitted write, intent, lease and physical worker live on.
struct DownloadStoreDeadline: Sendable, Equatable {
    let uptimeNanoseconds: UInt64

    static func after(_ seconds: TimeInterval) -> Self {
        let now = DispatchTime.now().uptimeNanoseconds
        let delta = UInt64(min(max(0, seconds.isFinite ? seconds : 0) * 1_000_000_000,
                               Double(UInt64.max - now) / 2))
        return Self(uptimeNanoseconds: now + delta)
    }

    var remaining: TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        return uptimeNanoseconds > now ? Double(uptimeNanoseconds - now) / 1_000_000_000 : 0
    }
}

/// An exact, process-local submission epoch for worker observations/seed/compare-clear adapters.
/// Acceptance is NOT a durability or ownership proof. Never serialize this value into the index.
/// P6.2/P6.3 replace the compatibility worker with cheap lock-linearized submissions.
final class DownloadStoreWork<Result: Sendable>: @unchecked Sendable {
    let epoch = UUID()
    private let condition = NSCondition()
    private var result: Result?

    init(_ operation: @escaping @Sendable () -> Result) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let value = operation()
            condition.lock()
            result = value
            condition.broadcast()
            condition.unlock()
        }
    }

    private func wait() -> Result {
        condition.lock(); defer { condition.unlock() }
        while result == nil { condition.wait() }
        return result!
    }

    /// P6.1 adapter only: retains this exact epoch but does not yet enforce deadline expiry.
    /// P6.3 must add waiter deregistration without cancelling the worker or losing its late result.
    func resolve(deadline: DownloadStoreDeadline) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                continuation.resume(returning: wait())
            }
        }
    }
}

extension DownloadStore {
    typealias SeedSubmission = DownloadStoreWork<AttemptRecordCreateResult>
    typealias CompareClearSubmission = DownloadStoreWork<AttemptCompareClearResult>
    typealias RecoverySubmission = DownloadStoreWork<StartupIndexAdmission>
    enum RecoveryResolution: Sendable, Equatable {
        case observed(StartupIndexAdmission)
        case timedOut(epoch: UUID)
    }
    enum LifecycleObservationResolution: Sendable, Equatable {
        case observed(LifecycleEventSubmission)
        case timedOut(epoch: UUID)
    }
    typealias LifecycleObservationSubmission = DownloadStoreWork<LifecycleEventSubmission>
    typealias ReconcileSubmission = DownloadStoreWork<PersistenceFlushResult>

    /// All deadline overloads below are P6.1 compatibility adapters, not the P6.3 bounded fix.
    /// Existing typed results remain intact. P6.3 maps expiry to their persistenceFailed(.timedOut)
    /// case; artifact expiry is .timedOut(sequence:). It must never map expiry to stale/success.
    /// P6.3 must key promotion/checkpoint outcomes by the full accepted Ticket (sequence, owner,
    /// generation, intentID, preparedRevision), not intentID alone. Retry B must not consume A.
    func resolve(_ submission: AttemptMutationSubmission,
                 deadline: DownloadStoreDeadline) async -> AttemptMutationResult {
        await DownloadStoreWork { self.resolveSynchronously(submission) }.resolve(deadline: deadline)
    }

    func resolve(_ submission: AttemptResumeDataSubmission,
                 deadline: DownloadStoreDeadline) async -> AttemptResumeDataWriteResult {
        await DownloadStoreWork { self.resolveSynchronously(submission) }.resolve(deadline: deadline)
    }

    func resolve(_ submission: AttemptArtifactMutationSubmission,
                 deadline: DownloadStoreDeadline) async -> AttemptMutationResult {
        switch submission {
        case .staleOrMissing: return .staleOrMissing
        case .accepted(let change, let ticket):
            switch await resolveArtifact(ticket, deadline: deadline) {
            case .completed: return change == .applied ? .applied : .noChange
            case .failed(.persistence(let failure)): return .persistenceFailed(failure)
            case .failed(.artifact(let errorType)):
                return .persistenceFailed(.failed(revision: ticket.preparedRevision.revision,
                                                 stage: "artifact", errorType: errorType))
            case .timedOut:
                return .persistenceFailed(.timedOut(targetRevision: ticket.preparedRevision.revision,
                                                    committedRevision: 0))
            }
        }
    }

    func resolveArtifact(_ ticket: DownloadArtifactLifecycleCoordinator.Ticket,
                         deadline: DownloadStoreDeadline) async -> DownloadArtifactLifecycleCoordinator.FlushResult {
        await artifactResolutionAdapter(ticket, deadline: deadline)
    }

    private func artifactResolutionAdapter(_ ticket: DownloadArtifactLifecycleCoordinator.Ticket,
                                          deadline: DownloadStoreDeadline) async
        -> DownloadArtifactLifecycleCoordinator.FlushResult {
        await DownloadStoreWork { self.resolveArtifactSynchronously(ticket) }.resolve(deadline: deadline)
    }

    func resolveValidatedPromotion(_ submission: AttemptValidatedPromotionSubmission,
                                  deadline: DownloadStoreDeadline) async -> AttemptValidatedPromotionResult {
        await resolveValidatedPromotion(submission)
    }

    func resolveStaticCheckpoint(_ submission: AttemptStaticCheckpointSubmission,
                                 deadline: DownloadStoreDeadline) async -> AttemptStaticRangeCheckpointResetResult {
        await resolveStaticCheckpoint(submission)
    }

    func resolveRowDeletion(_ submission: RowDeletionSubmission,
                            deadline: DownloadStoreDeadline) async -> RowDeletionResult {
        await resolveRowDeletion(submission)
    }

    /// Captures the exact proposed successor and expected predecessor; no dependent network work
    /// is authorized until resolve returns committed and the caller rechecks current authority.
    func submitAttemptOwnedRecord(_ record: DownloadRecord, attemptID: DownloadAttemptID,
                                  replacing expectedPreviousOwner: DownloadAttemptID? = nil) -> SeedSubmission {
        DownloadStoreWork { self.createAttemptOwnedRecord(
            record, attemptID: attemptID, replacing: expectedPreviousOwner) }
    }

    func resolve(_ submission: SeedSubmission,
                 deadline: DownloadStoreDeadline) async -> AttemptRecordCreateResult {
        await submission.resolve(deadline: deadline)
    }

    /// Compare-clear keeps the exact expected server handle across every suspension.
    func submitClearPlaySessionID(for key: DownloadAttemptKey,
                                  expectedPlaySessionID: String) -> CompareClearSubmission {
        DownloadStoreWork { self.clearPlaySessionID(for: key, expectedPlaySessionID: expectedPlaySessionID) }
    }

    func resolve(_ submission: CompareClearSubmission,
                 deadline: DownloadStoreDeadline) async -> AttemptCompareClearResult {
        await submission.resolve(deadline: deadline)
    }

    func submitReprobeBlockedIndex() -> RecoverySubmission {
        DownloadStoreWork { self.reprobeBlockedIndex() }
    }

    func resolve(_ submission: RecoverySubmission,
                 deadline: DownloadStoreDeadline) async -> RecoveryResolution {
        .observed(await submission.resolve(deadline: deadline))
    }

    /// Disk-dependent observations run on a worker; Pause/Delete install their immediate fences
    /// synchronously before using this adapter. P6.3 must compare the captured row generation
    /// before applying facts; P6.2 must recheck authority after resolving the resulting commit.
    func submitObservedLifecycleEvent(_ event: DownloadLifecycleEvent, for key: DownloadAttemptKey,
                                      liveTask: Bool = false) -> LifecycleObservationSubmission {
        DownloadStoreWork { self.submitLifecycleEvent(event, for: key, liveTask: liveTask) }
    }

    func resolve(_ submission: LifecycleObservationSubmission,
                 deadline: DownloadStoreDeadline) async -> LifecycleObservationResolution {
        .observed(await submission.resolve(deadline: deadline))
    }

    func submitReconcile(liveRatingKeys: Set<String>, snapshotRatingKeys: Set<String>) -> ReconcileSubmission {
        DownloadStoreWork {
            self.reconcile(liveRatingKeys: liveRatingKeys, snapshotRatingKeys: snapshotRatingKeys)
            return self.flushPersistenceSynchronouslyForP6Adapter()
        }
    }

    func resolve(_ submission: ReconcileSubmission,
                 deadline: DownloadStoreDeadline) async -> PersistenceFlushResult {
        await submission.resolve(deadline: deadline)
    }

    /// Session callbacks return onto the existing range queue. Callers must check exact attempt,
    /// train epoch and halt fence THERE before append/refill/publication; acceptance is insufficient.
    func resolve(_ submission: AttemptMutationSubmission, deadline: DownloadStoreDeadline,
                 returningOn queue: DispatchQueue,
                 completion: @escaping @Sendable (AttemptMutationResult) -> Void) {
        Task {
            let result = await resolve(submission, deadline: deadline)
            queue.async { completion(result) }
        }
    }
}

/// Completion adapter shared by every typed resolve family above (resume/artifact/promotion/
/// checkpoint/deletion/seed/compare-clear/recovery). It returns on the caller's serialization
/// queue without blocking that queue or introducing a structured-task race with a stuck syscall.
/// The operation closure captures its exact submission and ORIGINAL deadline.
enum DownloadStoreCallback {
    static func resolve<Result: Sendable>(returningOn queue: DispatchQueue,
        operation: @escaping @Sendable () async -> Result,
        completion: @escaping @Sendable (Result) -> Void) {
        Task {
            let result = await operation()
            queue.async { completion(result) }
        }
    }
}
