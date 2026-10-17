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
    private let workerQueue = DispatchQueue(label: "org.labstream.download-store-work", qos: .utility)

    let timeoutResult: Result?
    init(timeoutResult: Result? = nil, _ operation: @escaping @Sendable () -> Result) {
        self.timeoutResult = timeoutResult
        workerQueue.async { [self] in
            let value = operation()
            condition.lock()
            result = value
            condition.broadcast()
            condition.unlock()
        }
    }

    /// Worker-only compatibility for code that has no typed expiry value. Production store
    /// boundaries use the typed overload below; the frozen P6.1 bridge remains source-compatible.
    func resolve(deadline: DownloadStoreDeadline) async -> Result {
        if let timeoutResult { return await observe(deadline: deadline) ?? timeoutResult }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                condition.lock()
                while result == nil { condition.wait() }
                let value = result!
                condition.unlock()
                continuation.resume(returning: value)
            }
        }
    }

    /// Expiry releases only this waiter. The worker retains its epoch until physical completion.
    private func observedResult() -> Result? {
        condition.lock(); defer { condition.unlock() }
        return result
    }

    func observe(deadline: DownloadStoreDeadline) async -> Result? {
        while true {
            if let result = observedResult() { return result }
            guard deadline.remaining > 0 else { return nil }
            do { try await Task.sleep(for: .seconds(min(deadline.remaining, 0.01))) }
            catch { return nil }
        }
    }

    func resolve(deadline: DownloadStoreDeadline, timedOut: @escaping @Sendable () -> Result) async -> Result {
        await observe(deadline: deadline) ?? timedOut()
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

    /// Every typed boundary keeps its original monotonic deadline. Expiry returns a typed timeout
    /// without cancelling the submitted operation, its durable intent or its physical path lease.
    func resolve(_ submission: AttemptMutationSubmission,
                 deadline: DownloadStoreDeadline) async -> AttemptMutationResult {
        switch submission {
        case .staleOrMissing: return .staleOrMissing
        case .accepted(let change, let ticket):
            if let ticket {
                let proof = await flushPersistence(through: ticket, deadline: deadline)
                guard case .committed = proof else { return .persistenceFailed(proof) }
            }
            return change == .applied ? .applied : .noChange
        }
    }

    func resolve(_ submission: AttemptResumeDataSubmission,
                 deadline: DownloadStoreDeadline) async -> AttemptResumeDataWriteResult {
        switch submission {
        case .staleOrMissing: return .staleOrMissing
        case .artifactWriteFailed(let errorType): return .artifactWriteFailed(errorType: errorType)
        case .accepted(let ticket):
            switch await resolveArtifact(ticket, deadline: deadline) {
            case .completed: return .applied
            case .failed(.persistence(let failure)): return .persistenceFailed(failure)
            case .failed(.artifact(let errorType)): return .artifactWriteFailed(errorType: errorType)
            case .timedOut: return .persistenceFailed(timeoutFailure(ticket.preparedRevision))
            }
        }
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
        await resolveArtifactDeadline(ticket, deadline: deadline)
    }

    func resolveValidatedPromotion(_ submission: AttemptValidatedPromotionSubmission,
                                  deadline: DownloadStoreDeadline) async -> AttemptValidatedPromotionResult {
        await resolveValidatedPromotionDeadline(submission, deadline: deadline)
    }

    func resolveStaticCheckpoint(_ submission: AttemptStaticCheckpointSubmission,
                                 deadline: DownloadStoreDeadline) async -> AttemptStaticRangeCheckpointResetResult {
        await resolveStaticCheckpointDeadline(submission, deadline: deadline)
    }

    func resolveRowDeletion(_ submission: RowDeletionSubmission,
                            deadline: DownloadStoreDeadline) async -> RowDeletionResult {
        await resolveRowDeletionDeadline(submission, deadline: deadline)
    }

    /// Captures the exact proposed successor and expected predecessor; no dependent network work
    /// is authorized until resolve returns committed and the caller rechecks current authority.
    func submitAttemptOwnedRecord(_ record: DownloadRecord, attemptID: DownloadAttemptID,
                                  replacing expectedPreviousOwner: DownloadAttemptID? = nil) -> SeedSubmission {
        let generation = mutationGeneration(for: record.ratingKey)
        return DownloadStoreWork(timeoutResult: .failed(
            DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: attemptID),
            timeoutFailure(currentPersistenceTicket()))) { self.createAttemptOwnedRecordOnWorker(
                record, attemptID: attemptID, replacing: expectedPreviousOwner, expectedGeneration: generation) }
    }

    func resolve(_ submission: SeedSubmission,
                 deadline: DownloadStoreDeadline) async -> AttemptRecordCreateResult {
        await submission.resolve(deadline: deadline, timedOut: {
            submission.timeoutResult!
        })
    }

    /// Compare-clear keeps the exact expected server handle across every suspension.
    func submitClearPlaySessionID(for key: DownloadAttemptKey,
                                  expectedPlaySessionID: String) -> CompareClearSubmission {
        DownloadStoreWork { self.clearPlaySessionIDOnWorker(for: key, expectedPlaySessionID: expectedPlaySessionID) }
    }

    func resolve(_ submission: CompareClearSubmission,
                 deadline: DownloadStoreDeadline) async -> AttemptCompareClearResult {
        await submission.resolve(deadline: deadline, timedOut: {
            .persistenceFailed(self.timeoutFailure(self.currentPersistenceTicket()))
        })
    }

    func submitReprobeBlockedIndex() -> RecoverySubmission {
        let epoch = beginStartupReprobe()
        return DownloadStoreWork { self.reprobeBlockedIndexOnWorker(epoch: epoch) }
    }

    func resolve(_ submission: RecoverySubmission,
                 deadline: DownloadStoreDeadline) async -> RecoveryResolution {
        if let result = await submission.observe(deadline: deadline) { return .observed(result) }
        return .timedOut(epoch: submission.epoch)
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
        if let result = await submission.observe(deadline: deadline) { return .observed(result) }
        return .timedOut(epoch: submission.epoch)
    }

    func submitReconcile(liveRatingKeys: Set<String>, snapshotRatingKeys: Set<String>) -> ReconcileSubmission {
        DownloadStoreWork {
            self.reconcileOnWorker(liveRatingKeys: liveRatingKeys, snapshotRatingKeys: snapshotRatingKeys)
            return self.flushPersistenceSynchronouslyForP6Adapter()
        }
    }

    func resolve(_ submission: ReconcileSubmission,
                 deadline: DownloadStoreDeadline) async -> PersistenceFlushResult {
        await submission.resolve(deadline: deadline, timedOut: {
            self.timeoutFailure(self.currentPersistenceTicket())
        })
    }

    func createAttemptOwnedRecordAsync(_ record: DownloadRecord, attemptID: DownloadAttemptID,
                                       replacing expectedPreviousOwner: DownloadAttemptID? = nil) async -> AttemptRecordCreateResult {
        await resolve(submitAttemptOwnedRecord(record, attemptID: attemptID, replacing: expectedPreviousOwner), deadline: .after(30))
    }

    func clearPlaySessionIDAsync(for key: DownloadAttemptKey, expectedPlaySessionID: String) async -> AttemptCompareClearResult {
        await resolve(submitClearPlaySessionID(for: key, expectedPlaySessionID: expectedPlaySessionID), deadline: .after(30))
    }

    func clearResumeDataAsync(for key: DownloadAttemptKey, clearDisplayBytes: Bool = true) async -> AttemptMutationResult {
        await resolve(submitClearResumeData(for: key, clearDisplayBytes: clearDisplayBytes), deadline: .after(30))
    }

    func setPlaySessionIDAsync(for key: DownloadAttemptKey, _ playSessionID: String) async -> AttemptMutationResult {
        guard !playSessionID.isEmpty else { return .noChange }
        return await updateMetadataAsync(for: key) { $0.playSessionID = playSessionID }
    }

    func setLocalPlaybackPositionAsync(for key: DownloadAttemptKey, positionMs: Int, durationMs: Int?) async -> AttemptMutationResult {
        await updateMetadataAsync(for: key) { meta in
            meta.localPlaybackPositionMs = OfflinePlaybackPositionPolicy.standard.persistedPositionMs(
                currentMs: positionMs, durationMs: durationMs ?? meta.duration)
        }
    }

    func markCompleteIfUnverifiedAsync(for key: DownloadAttemptKey) async -> AttemptUnverifiedPromotionResult {
        await DownloadStoreWork { self.markCompleteIfUnverifiedOnWorker(for: key) }.resolve(
            deadline: .after(30), timedOut: { .persistenceFailed(self.timeoutFailure(self.currentPersistenceTicket())) })
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
