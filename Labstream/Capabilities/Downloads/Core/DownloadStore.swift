import Foundation
import CryptoKit
import Darwin
import PMSKit

// `DownloadStatus`, `OfflineMetadata`, and `DownloadRecord` — the pure, Codable value
// types persisted on each offline row, plus the `reconciledStatus` transition table —
// live in PMSKit (`Downloads/OfflineDownloadModels.swift`) so the silent-data-loss-on-
// upgrade surface is testable without an app test target.

/// Persisted index of `ratingKey -> local file` for offline content.
///
/// The on-disk JSON stores the file's path *relative* to the Application Support
/// directory (`relativePath`); `records` re-hydrates absolute `localURL`s against
/// the live container at load time so a moved sandbox doesn't orphan files.
///
/// This is a plain (non-actor) class guarded by an internal lock; `DownloadManager`
/// is the only writer and drives it from the `@MainActor`, but the background
/// `URLSession` delegate can call in from a delegate queue, so writes are locked.
final class DownloadStore: @unchecked Sendable {
    #if DEBUG
    /// Submission acknowledgement only; invoked under the row lock, so tests must not reenter.
    var persistenceDidSubmitForP6Testing: (@Sendable (PersistenceTicket) -> Void)?
    /// Admission acknowledgement under the row lock; the hook must not reenter the store.
    var pathLeaseAdmissionForP6Testing: (@Sendable (DownloadAttemptKey, DownloadPathLease.Purpose) -> Void)?
    #endif
    private static let unsupportedRootCleanupQueue = DispatchQueue(
        label: "org.labstream.Labstream.download-unsupported-root-cleanup", qos: .utility)

    // One reservation table excludes physical writers, handoffs, publication and cleanup.
    // Only physical completion releases a lease; a persistence waiter's timeout does not.
    func tryAcquirePathLease(for key: DownloadAttemptKey, relativePaths: Set<String>,
                             purpose: DownloadPathLease.Purpose) -> DownloadPathLeaseResult {
        lock.lock(); defer { lock.unlock() }
        #if DEBUG
        pathLeaseAdmissionForP6Testing?(key, purpose)
        #endif
        guard !relativePaths.isEmpty, relativePaths.allSatisfy(Self.isSafeOneLevelRelativePath) else {
            return .invalidPath
        }
        guard let row = rows[key.ratingKey], row.attemptID == key.attemptID else { return .staleOrMissing }
        if purpose == .append || purpose == .sideCacheWrite {
            guard !row.deletionPending, !Self.hasPendingRowDeletion(row) else { return .staleOrMissing }
        }
        guard relativePaths.allSatisfy({ reservedArtifactDeletionPaths[$0] == nil && reservedHeldBodyDeletionPaths[$0] == nil }) else { return .busy }
        let lease = DownloadPathLease(id: UUID(), key: key, relativePaths: relativePaths, purpose: purpose)
        for path in relativePaths { reservedArtifactDeletionPaths[path] = lease.id }
        return .acquired(lease)
    }

    func acquirePathLease(for key: DownloadAttemptKey, relativePaths: Set<String>,
                          purpose: DownloadPathLease.Purpose,
                          deadline: DownloadStoreDeadline) async -> DownloadPathLeaseResult {
        while true {
            let result = tryAcquirePathLease(for: key, relativePaths: relativePaths, purpose: purpose)
            guard result == .busy else { return result }
            guard deadline.remaining > 0 else { return .timedOut }
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { return .timedOut }
        }
    }

    func releasePathLease(_ lease: DownloadPathLease) {
        lock.lock(); defer { lock.unlock() }
        for path in lease.relativePaths where reservedArtifactDeletionPaths[path] == lease.id {
            reservedArtifactDeletionPaths.removeValue(forKey: path)
        }
    }

    #if DEBUG
    /// Exercise the production explicit recovery edge and capture the epochs it registered before
    /// any resolver consumes a result. No fixture-only outcome manufacture or loader bypass.
    func recoverArtifactTicketsForP6Testing() -> [DownloadArtifactLifecycleCoordinator.Ticket] {
        recoverPendingArtifactIntents()
    }

    func drainArtifactWorkerForP6Testing() async {
        await withCheckedContinuation { continuation in
            artifactWorkerQueue.async { continuation.resume() }
        }
    }

    var artifactEntryCountsForP6Testing: (live: Int, retired: Int) {
        (artifactLifecycle.liveEntryCountForTesting, artifactLifecycle.retiredFailureCountForTesting)
    }
    #endif

    // Worker-only bridge for the additive reconcile adapter. Never call on an executor/callback.
    func flushPersistenceSynchronouslyForP6Adapter() -> PersistenceFlushResult {
        waitForPersistence(through: currentPersistenceTicket()).result
    }

    struct IndexPersistence: Sendable {
        let read: @Sendable (URL) throws -> Data
        let atomicWrite: @Sendable (Data, URL) throws -> Void

        init(read: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) },
             atomicWrite: @escaping @Sendable (Data, URL) throws -> Void) {
            self.read = read
            self.atomicWrite = atomicWrite
        }

        static let live = IndexPersistence { data, url in
            try DownloadIndexFileCommitter().commit(data, to: url)
        }
    }

    struct PersistenceTicket: Sendable, Hashable {
        let revision: UInt64
    }

    enum PersistenceFlushResult: Sendable, Equatable {
        case committed(revision: UInt64)
        case failed(revision: UInt64, stage: String, errorType: String)
        case timedOut(targetRevision: UInt64, committedRevision: UInt64)

        fileprivate func committed(through ticket: PersistenceTicket) -> Bool {
            guard case .committed(let revision) = self else { return false }
            return revision >= ticket.revision
        }
    }

    /// Durable file layout for the media body owned by one download attempt. `stableURL` is the
    /// URL published by `DownloadRecord`; transfer callbacks must write/checkpoint `workingURL`
    /// and promote it only after re-validating exact ownership.
    struct AttemptWorkingFileLayout: Sendable, Equatable {
        let key: DownloadAttemptKey
        let stableURL: URL
        let workingURL: URL
    }

    enum StartupIndexAdmission: Sendable, Equatable {
        case current
        /// The on-disk root belongs to a non-current schema. It is intentionally not decoded or
        /// mutated; startup must first drain every OS task, then replace the root as one unit.
        case requiresDestructiveReset(schemaVersion: Int?)
        /// Unknown/corrupt bytes are not assumed to be legacy. Keep them for diagnosis and stop.
        case unreadableIndex
        case malformedCurrentRows([String])
        /// B21: a season plan's commit could not be proven either way. Memory is consistent (the
        /// plan was withdrawn); re-committing it resolves the block.
        case seasonCommitIndeterminate
    }

    enum AttemptRecordCreateResult: Sendable, Equatable {
        case committed(DownloadAttemptKey)
        case rejectedOwnership(
            expectedPreviousOwner: DownloadAttemptKey?,
            actualOwner: DownloadAttemptKey?,
            reason: AttemptRecordCreateRejection
        )
        case failed(DownloadAttemptKey, PersistenceFlushResult)
    }

    enum AttemptRecordCreateRejection: String, Sendable, Equatable {
        case missingExpectedOwner
        case ownerMismatch
        case validatedPromotionPending
        case deletionPending
        case heldBodyDeletionPending
        case artifactLifecyclePending
        case checkpointHandoffFailed
    }

    enum AttemptMutationResult: Sendable, Equatable {
        case applied
        case noChange
        case staleOrMissing
        /// The guarded in-memory mutation remains authoritative and its full snapshot stays dirty,
        /// matching the store writer's existing semantics. Callers must not create dependent
        /// external work until a later mutation/flush proves the snapshot committed.
        case persistenceFailed(PersistenceFlushResult)
    }

    /// Result of a lock-linearized exact-attempt mutation whose full snapshot has been accepted
    /// by the revisioned writer but whose I/O has deliberately not been awaited. Lifecycle code
    /// uses this form so a wedged filesystem cannot wedge URLSession's delegate queue before the
    /// bounded background-completion flush. Existing synchronous APIs remain compatibility
    /// wrappers over the same submission.
    enum AttemptMutationSubmission: Sendable, Equatable {
        case accepted(change: AttemptMutationChange, ticket: PersistenceTicket?)
        case staleOrMissing
    }

    enum AttemptMutationChange: Sendable, Equatable {
        case applied
        case noChange
    }

    enum AttemptUnverifiedPromotionResult: Sendable, Equatable {
        case promoted
        case notUnverified
        case staleOrMissing
        case persistenceFailed(PersistenceFlushResult)
    }

    enum AttemptCompareClearResult: Sendable, Equatable {
        case cleared
        case alreadyAbsent
        case expectedValueMismatch
        case staleOrMissing
        case persistenceFailed(PersistenceFlushResult)
    }

    enum AttemptStagingPromotionResult: Sendable, Equatable {
        case promoted
        case staleOrMissingOwner
        case invalidPath
        case sourceMissing
        case failed(errorType: String)
    }

    enum AttemptValidatedPromotionResult: Sendable, Equatable {
        case promoted(DownloadAttemptKey, bytes: Int, status: DownloadStatus)
        case staleOrMissingOwner
        case resetPending
        case invalidWorkingLayout
        case sourceMissing
        case invalidTerminalStatus
        case renameFailed(errorType: String)
        case persistenceFailed(DownloadAttemptKey, PersistenceFlushResult)
    }

    struct AttemptStagingSweepResult: Sendable, Equatable {
        let removedRelativePaths: [String]
        let failedRelativePaths: [String]
    }

    enum RowDeletionResult: Sendable, Equatable {
        case removed(DownloadAttemptKey)
        case staleOrMissing
        case cleanupFailed(DownloadAttemptKey, cleanupFailureCount: Int)
        case persistenceFailed(DownloadAttemptKey, PersistenceFlushResult)
    }

    enum RowDeletionSubmission: Sendable, Equatable {
        case accepted(ticket: DownloadArtifactLifecycleCoordinator.Ticket)
        case immediate(RowDeletionResult)
    }

    private struct PersistenceAttempt {
        let ticket: PersistenceTicket
        let result: PersistenceFlushResult
    }

    private func awaitAttemptMutationSubmission(
        _ submission: AttemptMutationSubmission
    ) -> AttemptMutationResult {
        switch submission {
        case .staleOrMissing:
            return .staleOrMissing
        case .accepted(let change, nil):
            return change == .applied ? .applied : .noChange
        case .accepted(let change, let ticket?):
            let persistence = waitForPersistence(through: ticket)
            guard persistence.result.committed(through: ticket) else {
                return .persistenceFailed(persistence.result)
            }
            return change == .applied ? .applied : .noChange
        }
    }

    /// Compatibility bridge for orchestration code that selects blocking versus bounded lifecycle
    /// behavior from its execution context. Never call this from a pending background-session
    /// delivery; that path must carry the ticket to `flushPersistence` instead.
    func resolveSynchronously(
        _ submission: AttemptMutationSubmission
    ) -> AttemptMutationResult {
        awaitAttemptMutationSubmission(submission)
    }

    func resolveSynchronously(
        _ submission: AttemptResumeDataSubmission
    ) -> AttemptResumeDataWriteResult {
        switch submission {
        case .staleOrMissing:
            return .staleOrMissing
        case .artifactWriteFailed(let errorType):
            return .artifactWriteFailed(errorType: errorType)
        case .accepted(let ticket):
            switch artifactLifecycle.waitSynchronously(for: ticket) {
            case .completed:
                return .applied
            case .failed(.persistence(let failure)):
                return .persistenceFailed(failure)
            case .failed(.artifact(let errorType)):
                return .artifactWriteFailed(errorType: errorType)
            case .timedOut:
                preconditionFailure("an unbounded artifact lifecycle wait cannot time out")
            }
        }
    }

    func resolveArtifactSynchronously(
        _ ticket: DownloadArtifactLifecycleCoordinator.Ticket
    ) -> DownloadArtifactLifecycleCoordinator.FlushResult {
        artifactLifecycle.waitSynchronously(for: ticket)
    }

    func resolveArtifactSynchronouslyForTests(
        through watermark: DownloadArtifactLifecycleCoordinator.Watermark
    ) -> DownloadArtifactLifecycleCoordinator.FlushResult {
        artifactLifecycle.waitSynchronously(through: watermark)
    }

    // Compatibility aliases keep the Store-facing API stable while the Emby cleanup file has its
    // own persistence owner and lock.
    typealias EmbyConvertCleanupTombstone = EmbyConvertCleanupJournal.Tombstone
    typealias EmbyCleanupPersistence = EmbyConvertCleanupJournal.Persistence
    typealias EmbyCleanupLoadResult = EmbyConvertCleanupJournal.LoadResult
    typealias EmbyCleanupRemoveResult = EmbyConvertCleanupJournal.RemoveResult

    struct StaticRangeRecoveryEvidence: Sendable, Equatable {
        let ratingKey: String
        let status: DownloadStatus
        let durableBytes: Int
        let resumeManifestRecorded: Bool
        let resumeBlobPresent: Bool
        let resumeBlobBytes: Int
        let heldBodyCount: Int
        let heldBodyBytes: Int
    }

    enum AttemptResumeDataWriteResult: Sendable, Equatable {
        case applied
        case staleOrMissing
        case artifactWriteFailed(errorType: String)
        case persistenceFailed(PersistenceFlushResult)
    }

    enum AttemptResumeDataSubmission: Sendable, Equatable {
        case accepted(ticket: DownloadArtifactLifecycleCoordinator.Ticket)
        case staleOrMissing
        case artifactWriteFailed(errorType: String)
    }

    enum AttemptArtifactMutationSubmission: Sendable, Equatable {
        case accepted(change: AttemptMutationChange, ticket: DownloadArtifactLifecycleCoordinator.Ticket)
        case staleOrMissing
    }

    enum AttemptHeldRangeSegmentPersistResult: Sendable, Equatable {
        case accepted(
            previous: OfflineHeldRangeSegment?,
            ticket: PersistenceTicket,
            persistence: PersistenceFlushResult
        )
        case invalidSegment
        case staleOrMissing
    }

    struct AttemptHeldRangeLifecycleSubmission: Sendable, Equatable {
        let previous: OfflineHeldRangeSegment?
        let removed: [OfflineHeldRangeSegment]
        let deferredRelativePaths: [String]
        let ticket: DownloadArtifactLifecycleCoordinator.Ticket
    }

    enum AttemptHeldRangeLifecycleSubmissionResult: Sendable, Equatable {
        case accepted(AttemptHeldRangeLifecycleSubmission)
        case invalidSegment
        case staleOrMissing
    }

    enum AttemptHeldRangeSegmentsRemovalResult: Sendable, Equatable {
        case accepted(HeldRangeSegmentsRemovalResult)
        case staleOrMissing
    }

    struct AttemptHeldRangePurgeResult: Sendable, Equatable {
        let removal: HeldRangeSegmentsRemovalResult
        let removedRelativePaths: [String]
        let failedRelativePaths: [String]
    }

    enum AttemptHeldRangeSegmentsPurgeResult: Sendable, Equatable {
        case purged(AttemptHeldRangePurgeResult)
        case staleOrMissing
    }

    enum AttemptStaticRangeCheckpointResetResult: Sendable, Equatable {
        case applied(bytes: Int)
        case unchanged(bytes: Int)
        case notStatic(bytes: Int)
        case staleOrMissing
        case persistenceFailed(bytes: Int, PersistenceFlushResult)
    }

    enum AttemptStaticCheckpointSubmission: Sendable, Equatable {
        case accepted(ticket: DownloadArtifactLifecycleCoordinator.Ticket)
        case notStatic(bytes: Int)
        /// The current owner's body is condemned (P3a): zero usable bytes, already applied to
        /// the row. Callers schedule a restart from zero exactly as for an empty checkpoint.
        case condemned(PersistenceTicket)
        case staleOrMissing
    }

    enum AttemptValidatedPromotionSubmission: Sendable, Equatable {
        case accepted(ticket: DownloadArtifactLifecycleCoordinator.Ticket)
        case immediate(AttemptValidatedPromotionResult)
    }

    struct HeldRangeSegmentsRemovalResult: Sendable, Equatable {
        let removed: [OfflineHeldRangeSegment]
        /// Every exact-attempt held body whose deletion is part of the same durable snapshot as
        /// the manifest removal. These paths remain in the row until filesystem deletion succeeds.
        let deferredRelativePaths: [String]
        let ticket: PersistenceTicket
        let persistence: PersistenceFlushResult

        var committed: Bool {
            guard case .committed(let revision) = persistence else { return false }
            return revision >= ticket.revision
        }
    }

    /// Codable row as persisted on disk (relative path, not absolute URL).
    private struct Row: Codable, Sendable {
        enum ArtifactIntentPhase: String, Codable, Sendable {
            case prepared
            case publishedAwaitingPriorDeletion
            case clearTargetCaptured
            case promotionSourceCaptured
        }

        enum ArtifactIntentOperation: Codable, Sendable, Equatable {
            // Operational rollback boundary: an older binary whose exhaustive Codable enum lacks
            // newer cases cannot read an index while such an artifact intent is pending. Release
            // rollback must therefore drain artifact lifecycle tickets before installing that
            // binary; the terminal snapshot removes the case from the persisted row.
            case replaceResumeBlob(
                newRelativePath: String,
                previousRelativePath: String?,
                displayBytes: Int?
            )
            case clearResumeBlob(relativePath: String?, clearDisplayBytes: Bool)
            case heldBodyDeletion(relativePaths: [String])
            case staticCheckpoint(
                workingRelativePath: String,
                stableSourceRelativePath: String?,
                copyTempRelativePath: String?,
                expectedBytes: Int?,
                reconstructedTerminal: Bool
            )
            case validatedPromotion(
                workingRelativePath: String,
                stableRelativePath: String,
                terminalStatus: DownloadStatus,
                sourceBytes: Int?
            )
            case rowDeletion(
                relativePaths: [String],
                requiresDeletionPending: Bool,
                persistedOwnershipFlag: Bool
            )
        }

        struct ArtifactIntent: Codable, Sendable, Equatable {
            let id: UUID
            let attemptID: DownloadAttemptID
            let generation: UInt64
            var phase: ArtifactIntentPhase
            var operation: ArtifactIntentOperation
        }

        let ratingKey: String
        var attemptID: DownloadAttemptID?
        let title: String
        let relativePath: String
        /// Exact attempt-owned media body. This is deliberately separate from `relativePath`:
        /// readers always see the stable publication URL while in-flight evidence stays private.
        var attemptWorkingRelativePath: String?
        /// Durable proof that this exact attempt already passed validation and is allowed to
        /// publish its working body. This closes the crash window between rename and terminal row
        /// commit without guessing that arbitrary bytes at the stable path belong to this attempt.
        var pendingValidatedPromotionStatus: DownloadStatus?
        var bytes: Int
        var progress: Double
        /// P3a: where the attempt is. Authoritative; `status` is derived from it.
        var lifecycle: DownloadLifecycle
        /// P3a: facts no status can hold (truncation strikes, unverified reason, pause cause).
        var history: DownloadAttemptHistory
        /// Derived for older binaries, diagnostics and the UI. The setter is the temporary P3a
        /// legacy shim: a status write maps onto lifecycle without losing what status cannot
        /// express (finalizing, planned). Call sites move to reducer events; the shim is removed
        /// by the end of P3a.
        var status: DownloadStatus {
            // P4: `planned` (waiting for an admission lane) projects as `.queued`, as the legacy
            // season-pending rows did.
            get { lifecycle.derivedStatus }
            set { lifecycle = Self.legacyLifecycle(for: newValue, current: lifecycle,
                                                   admissionPending: admissionPending) }
        }
        /// The legacy season-planner flag. P4 no longer writes it: a row carrying it is absorbed
        /// into lifecycle `planned` plus an admission intent on load (`absorbLegacyAdmissionFlag`).
        var admissionPending: Bool { metadata?.seasonPlannerPendingAdmission == true }

        /// P4.8: the legacy season flag becomes lifecycle and history. Authoritative facts win: a
        /// deleting, finalizing, transferring, paused-by-user or finished row keeps its lifecycle,
        /// and only a pending first start becomes `planned`.
        mutating func absorbLegacyAdmissionFlag(promotionPending: Bool) {
            guard metadata?.seasonPlannerPendingAdmission == true else { return }
            metadata?.seasonPlannerPendingAdmission = nil
            guard !deletionPending, !promotionPending else { return }
            // Transfer or server-job evidence means the start already began: a stale flag never
            // routes that attempt back through a first start (its retry resumes the work).
            let started = hasStartEvidence
            switch lifecycle {
            case .admitted, .planned:
                if started {
                    if lifecycle == .planned { lifecycle = .admitted }
                } else {
                    // Queued and flagged: the first start never began.
                    lifecycle = .planned
                    history.admissionIntent = history.admissionIntent ?? .seasonPlanned
                }
            case .failed:
                // A failed row the planner queued for retry stays failed until its retry runs.
                history.admissionIntent = history.admissionIntent ?? .retryRequested
            case .paused:
                // Paused while waiting (B65): Resume re-requests the same first start. A paused
                // row with work resumes through its ordinary retry instead.
                if !started { history.admissionIntent = history.admissionIntent ?? .seasonPlanned }
            case .serverPrep, .transferring, .finalizing, .complete, .unverified:
                break
            }
        }

        /// Bytes, a resume blob, held range bodies, a server-prepared handoff, a Plex queue item or
        /// an Emby Convert job: proof that this attempt's start already ran.
        var hasStartEvidence: Bool {
            if bytes > 0 || !heldRangeBodyDeletionIntents.isEmpty { return true }
            guard let metadata else { return false }
            return metadata.resumeDataRelativePath != nil
                || !(metadata.heldRangeSegments ?? []).isEmpty
                || metadata.optimizeQueueTitle != nil
                || metadata.embyConvertJobID != nil
                || metadata.hasEmbyConvertRecoveryIdentity
                || (metadata.serverPreparedVersion == true && metadata.optimizeTargetName != nil)
        }
        // D5: snapshot of the source item + the locally-cached poster path. Both are
        // optional and decoded with `decodeIfPresent` so rows written before D5 load.
        var metadata: OfflineMetadata?
        /// A user requested deletion while required server-cleanup authority could not move into
        /// the independent journal. The row and its exact metadata remain the durable fallback
        /// until a later retry journals every operation and completes destructive deletion.
        var deletionPending: Bool
        /// Exact, credential-free cleanup operations captured at delete time. This includes a
        /// transient in-memory PlaySessionId that may not yet have reached ordinary row metadata.
        var deletionPendingCleanupIntents: [DurableDownloadCleanupIntent]
        /// Exact-attempt held bodies whose manifests have been removed in the same index
        /// transaction, but whose filesystem deletion has not yet been completed. Keeping this
        /// authority in schema-v4's row makes a failed/ambiguous commit and relaunch recoverable.
        var heldRangeBodyDeletionIntents: [String]
        /// Ordered, exact-attempt filesystem mutations. Optional/defaulted schema-v4 additions:
        /// old rows decode unchanged, while a hard kill can replay the durable prepared phase.
        var artifactGeneration: UInt64
        /// In-process/persisted revision for exact side-asset bytes. Every successful atomic
        /// side-asset promotion advances it, including same-path repair replacements.
        var sideAssetGeneration: UInt64
        var pendingArtifactIntents: [ArtifactIntent]
        /// Decode-only evidence used to require the current top-level owner and reject any
        /// disagreement with metadata's redundant exact-attempt shadow. Absent from CodingKeys.
        var decodedTopLevelAttemptIDPresent: Bool
        var decodedAttemptIdentityDisagrees: Bool

        private enum CodingKeys: String, CodingKey {
            case ratingKey, attemptID, title, relativePath, attemptWorkingRelativePath
            case pendingValidatedPromotionStatus
            case bytes, progress, status, metadata
            case lifecycle, history
            case deletionPending
            case deletionPendingCleanupIntents
            case heldRangeBodyDeletionIntents
            case artifactGeneration
            case sideAssetGeneration
            case pendingArtifactIntents
        }

        // Current-schema rows require an explicit lifecycle state. Missing status is malformed;
        // startup admission then retains the canonical bytes and fails closed.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ratingKey = try c.decode(String.self, forKey: .ratingKey)
            let topLevelAttemptID = try c.decodeIfPresent(DownloadAttemptID.self, forKey: .attemptID)
            title = try c.decode(String.self, forKey: .title)
            relativePath = try c.decode(String.self, forKey: .relativePath)
            attemptWorkingRelativePath = try c.decodeIfPresent(
                String.self, forKey: .attemptWorkingRelativePath)
            pendingValidatedPromotionStatus = try c.decodeIfPresent(
                DownloadStatus.self, forKey: .pendingValidatedPromotionStatus)
            bytes = try c.decode(Int.self, forKey: .bytes)
            progress = try c.decode(Double.self, forKey: .progress)
            let decodedStatus = try c.decode(DownloadStatus.self, forKey: .status)
            metadata = try c.decodeIfPresent(OfflineMetadata.self, forKey: .metadata)
            let nestedAttemptID = metadata?.downloadAttemptID.flatMap(DownloadAttemptID.init(rawValue:))
            attemptID = topLevelAttemptID
            deletionPending = try c.decodeIfPresent(Bool.self, forKey: .deletionPending) ?? false
            deletionPendingCleanupIntents = try c.decodeIfPresent(
                [DurableDownloadCleanupIntent].self,
                forKey: .deletionPendingCleanupIntents) ?? []
            heldRangeBodyDeletionIntents = try c.decodeIfPresent(
                [String].self, forKey: .heldRangeBodyDeletionIntents) ?? []
            artifactGeneration = try c.decodeIfPresent(
                UInt64.self, forKey: .artifactGeneration) ?? 0
            sideAssetGeneration = try c.decodeIfPresent(
                UInt64.self, forKey: .sideAssetGeneration) ?? 0
            pendingArtifactIntents = try c.decodeIfPresent(
                [ArtifactIntent].self, forKey: .pendingArtifactIntents) ?? []
            // R2-6: a row without lifecycle (written before P3a, or re-encoded by an older binary)
            // derives it structurally from status alone. A lifecycle that disagrees with the
            // status an older binary wrote afterwards also yields to that status, structurally.
            let decodedLifecycle = try c.decodeIfPresent(DownloadLifecycle.self, forKey: .lifecycle)
            let admission = metadata?.seasonPlannerPendingAdmission == true
            let promotionPending = pendingArtifactIntents.first.map {
                if case .validatedPromotion = $0.operation { return true }
                return false
            } ?? false
            if let decodedLifecycle, decodedLifecycle.derivedStatus == decodedStatus
                || (decodedLifecycle == .planned && decodedStatus == .failed) {
                lifecycle = decodedLifecycle
            } else {
                lifecycle = DownloadLifecycle.structural(
                    from: decodedStatus, admissionPending: admission,
                    finalizingEvidence: promotionPending)
            }
            history = try c.decodeIfPresent(DownloadAttemptHistory.self, forKey: .history) ?? .empty
            // P3a/P3b projected a flagged retry row as `planned` + `.failed`; it is a failed
            // attempt waiting for its retry, which the flag absorption below records as an intent.
            if lifecycle == .planned, decodedStatus == .failed, admission { lifecycle = .failed }
            decodedTopLevelAttemptIDPresent = topLevelAttemptID != nil
            decodedAttemptIdentityDisagrees = topLevelAttemptID != nil
                && nestedAttemptID != nil
                && topLevelAttemptID != nestedAttemptID
            absorbLegacyAdmissionFlag(promotionPending: promotionPending)
        }

        init(ratingKey: String, attemptID: DownloadAttemptID? = nil,
             title: String, relativePath: String,
             attemptWorkingRelativePath: String? = nil,
             pendingValidatedPromotionStatus: DownloadStatus? = nil,
             bytes: Int, progress: Double, status: DownloadStatus,
             metadata: OfflineMetadata? = nil,
             deletionPending: Bool = false,
             deletionPendingCleanupIntents: [DurableDownloadCleanupIntent] = [],
             heldRangeBodyDeletionIntents: [String] = [],
             artifactGeneration: UInt64 = 0,
             sideAssetGeneration: UInt64 = 0,
             pendingArtifactIntents: [ArtifactIntent] = []) {
            self.ratingKey = ratingKey
            self.attemptID = attemptID
            self.title = title
            self.relativePath = relativePath
            self.attemptWorkingRelativePath = attemptWorkingRelativePath
            self.pendingValidatedPromotionStatus = pendingValidatedPromotionStatus
            self.bytes = bytes
            self.progress = progress
            self.metadata = metadata
            // P4.8: the flag is absorbed below from the status itself (a failed flagged row
            // waits for its retry), not by the P3a structural `planned` mapping.
            self.lifecycle = Self.legacyLifecycle(for: status, current: nil, admissionPending: false)
            self.history = .empty
            self.deletionPending = deletionPending
            self.deletionPendingCleanupIntents = deletionPendingCleanupIntents
            self.heldRangeBodyDeletionIntents = heldRangeBodyDeletionIntents
            self.artifactGeneration = artifactGeneration
            self.sideAssetGeneration = sideAssetGeneration
            self.pendingArtifactIntents = pendingArtifactIntents
            self.decodedTopLevelAttemptIDPresent = attemptID != nil
            self.decodedAttemptIdentityDisagrees = false
            absorbLegacyAdmissionFlag(promotionPending: false)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(ratingKey, forKey: .ratingKey)
            try c.encodeIfPresent(attemptID, forKey: .attemptID)
            try c.encode(title, forKey: .title)
            try c.encode(relativePath, forKey: .relativePath)
            try c.encodeIfPresent(attemptWorkingRelativePath, forKey: .attemptWorkingRelativePath)
            try c.encodeIfPresent(
                pendingValidatedPromotionStatus, forKey: .pendingValidatedPromotionStatus)
            try c.encode(bytes, forKey: .bytes)
            try c.encode(progress, forKey: .progress)
            try c.encode(status, forKey: .status)
            try c.encode(lifecycle, forKey: .lifecycle)
            if history != .empty { try c.encode(history, forKey: .history) }
            try c.encodeIfPresent(metadata, forKey: .metadata)
            if deletionPending { try c.encode(true, forKey: .deletionPending) }
            if !deletionPendingCleanupIntents.isEmpty {
                try c.encode(
                    deletionPendingCleanupIntents,
                    forKey: .deletionPendingCleanupIntents)
            }
            if !heldRangeBodyDeletionIntents.isEmpty {
                try c.encode(heldRangeBodyDeletionIntents, forKey: .heldRangeBodyDeletionIntents)
            }
            if artifactGeneration > 0 {
                try c.encode(artifactGeneration, forKey: .artifactGeneration)
            }
            if sideAssetGeneration > 0 {
                try c.encode(sideAssetGeneration, forKey: .sideAssetGeneration)
            }
            if !pendingArtifactIntents.isEmpty {
                try c.encode(pendingArtifactIntents, forKey: .pendingArtifactIntents)
            }
        }

        /// The P3a legacy shim mapping (Appendix C): a status write keeps the lifecycle detail it
        /// cannot express — `finalizing` stays finalizing under `.downloading`, and a failed
        /// season row awaiting admission is `planned`.
        static func legacyLifecycle(
            for status: DownloadStatus,
            current: DownloadLifecycle?,
            admissionPending: Bool
        ) -> DownloadLifecycle {
            if let current, current.derivedStatus == status
                || (current == .planned && status == .failed && admissionPending) {
                return current
            }
            return DownloadLifecycle.structural(
                from: status, admissionPending: admissionPending, finalizingEvidence: false)
        }
    }

    /// Minimum spacing between index rewrites driven by progress callbacks.
    private static let progressPersistInterval: TimeInterval = 1

    private let lock = NSLock()
    private struct HydratedSideAssets {
        let attemptID: DownloadAttemptID?
        let source: OfflineSideAssetSourceIdentity?
        let generation: UInt64
        var posterURL: URL?
        var plexBIFURL: URL?
        var embyBIFURL: URL?
        var jellyfinTrickPlayPlaylistURL: URL?
        var chapterImageURLs: [Int: URL]
        var sideAssetBytes: Int
    }

    private var rowMutationGenerations: [String: UInt64] = [:]
    private func setRowLocked(_ row: Row, for ratingKey: String) {
        rowMutationGenerations[ratingKey, default: 0] &+= 1
        rows[ratingKey] = row
    }
    private var rows: [String: Row] = [:]          // ratingKey -> Row
    /// Truncation strikes of a row a Retry removed before seeding its replacement, keyed by
    /// rating key (guarded by `lock`). The replacement inherits them like an in-place
    /// replacement would (R2-5), with the same in-process lifetime the pre-P3a session counter
    /// had. Only `submitRemoveForRetry` stashes strikes; a Delete or a cancel never does.
    private var retiredTruncation: [String: (attemptID: DownloadAttemptID?,
                                             truncation: DownloadTruncationHistory)] = [:]
    private struct SideAssetPublicationOwner {
        let key: DownloadAttemptKey
        let source: OfflineSideAssetSourceIdentity
    }
    /// A rename is already a physical publication before its metadata continuation resumes.
    /// Keep that current-source authority visible to retirement and deletion reservations.
    private var sideAssetPublicationOwners: [String: SideAssetPublicationOwner] = [:] // guarded by `lock`
    private var sideAssetHydrationCache: [String: HydratedSideAssets] = [:] // guarded by `lock`
    private var lastProgressPersist = Date.distantPast   // guarded by `lock`
    private let baseDirectory: URL                  // Application Support/Downloads
    /// A sweep may race side-cache writers which create their attempt-private file before the
    /// corresponding metadata mutation. Only files inventoried at Store initialization can be
    /// startup orphans; a later launch can collect newly-born files if no row ever adopts them.
    private var startupStagingIdentities: [String: CondemnedFileIdentity] = [:]
    private var startupStagingInventory: Set<String>
    private let indexURL: URL                        // baseDirectory/index.json
    private let cleanupAuthorityDirectory: URL       // survives destructive Downloads-root reset
    private let fileManager: FileManager
    private let embyCleanupJournal: EmbyConvertCleanupJournal
    private let indexWriter: RevisionedPersistenceWriter<IndexSnapshot>
    /// One persisted index revision: its rows and the schema version they are written as (P3b).
    /// The version is captured with the snapshot under `lock`, so every snapshot enqueued after
    /// `stampSchemaV5()` is v5 and every earlier one keeps the loaded version.
    private struct IndexSnapshot: Sendable {
        let schemaVersion: Int
        let rows: [Row]
    }
    /// The version snapshots are encoded with (guarded by `lock`). An existing index keeps the
    /// version it was loaded with (v4 until upgraded); a new or reset index is current.
    private var indexSchemaVersion = DownloadIndexCoding.currentSchemaVersion
    /// The version the index was loaded with, for the manager's upgrade decision.
    private var loadedSchemaVersion = DownloadIndexCoding.currentSchemaVersion
    private let rootIndexPersistence: IndexPersistence
    private let artifactFilesystem: DownloadArtifactFilesystem
    private let storeFilesystem: DownloadStoreFilesystem
    private let checkpointFilesystem: DownloadStaticCheckpointFilesystem
    private let promotionFilesystem: DownloadPromotionFilesystem
    private let artifactLifecycle = DownloadArtifactLifecycleCoordinator()
    private let artifactWorkerQueue = DispatchQueue(
        label: "com.visionplay.download-artifact-lifecycle", qos: .utility)
    private var nextPersistenceRevision: UInt64 = 0 // guarded by `lock`
    private var startupSchemaProbe: DownloadIndexCoding.StartupProbe // guarded by `lock`
    private let startupReprobeWorkerLock = NSLock()
    private var startupReprobeEpoch = UUID() // guarded by `lock`
    private var seasonCommitIndeterminate = false // guarded by `lock`
    #if DEBUG
    /// Runs after reconcile's demotion commits and before its fenced deletions (race pins).
    var reconcileBeforeDeletionsForTesting: (() -> Void)?
    #endif
    private var failedArtifactPreparedRevisions: [UUID: UInt64] = [:]
    private var failedArtifactIOIntentIDs: Set<UUID> = []
    private var activeArtifactIntentIDs: Set<UUID> = [] // guarded by `lock`
    private var pendingResumeArtifactData: [UUID: Data] = [:] // guarded by `lock`
    private var artifactLifecycleTickets: [UUID: DownloadArtifactLifecycleCoordinator.Ticket] = [:]
    private var startupArtifactCleanupIntentIDs: Set<UUID> = [] // guarded by `lock`
    /// Exact rows between in-memory intent retirement and its terminal index outcome. Recovery
    /// must not schedule the successor until success, or until failure restores the retired head.
    private var artifactRetirementKeys: Set<DownloadAttemptKey> = [] // guarded by `lock`
    private var reservedHeldBodyDeletionPaths: [String: UUID] = [:] // guarded by `lock`
    /// Paths selected for an off-lock destructive lifecycle step. Keeping this reservation under
    /// the store lock closes the snapshot/delete race where another row could adopt a path after
    /// cross-row references were inspected but before the filesystem operation ran.
    private var reservedArtifactDeletionPaths: [String: UUID] = [:] // guarded by `lock`
    private var staticCheckpointOutcomes: [DownloadArtifactLifecycleCoordinator.Ticket: AttemptStaticRangeCheckpointResetResult] = [:]
    private var staticCheckpointAwaitingResultIDs: Set<DownloadArtifactLifecycleCoordinator.Ticket> = []
    private var promotionOutcomes: [DownloadArtifactLifecycleCoordinator.Ticket: AttemptValidatedPromotionResult] = [:]
    private var promotionAwaitingResultIDs: Set<DownloadArtifactLifecycleCoordinator.Ticket> = []
    private struct RowDeletionTicketEpoch: Hashable {
        let ticket: DownloadArtifactLifecycleCoordinator.Ticket
        init(_ ticket: DownloadArtifactLifecycleCoordinator.Ticket) { self.ticket = ticket }
    }
    private var rowDeletionOutcomes: [RowDeletionTicketEpoch: RowDeletionResult] = [:]
    /// Accepted deletion submissions are independently resolvable even when several callers join
    /// one active lifecycle ticket (double-tap Delete, coalesced startup recovery). Retain the
    /// broadcast outcome until every accepted waiter has consumed it.
    private var rowDeletionWaiterCounts: [RowDeletionTicketEpoch: Int] = [:]

    private(set) var initialStartupSubmission: RecoverySubmission?

    /// - Parameter baseDirectory: where media files + the index live. Defaults to
    ///   `Application Support/Labstream/Downloads`, created if missing.
    init(baseDirectory: URL? = nil,
         fileManager: FileManager = .default,
         indexPersistence: IndexPersistence = .live,
         embyCleanupPersistence: EmbyCleanupPersistence? = nil,
         artifactFilesystem: DownloadArtifactFilesystem = .live,
         checkpointFilesystem: DownloadStaticCheckpointFilesystem = .live,
         promotionFilesystem: DownloadPromotionFilesystem = .live,
         storeFilesystem: DownloadStoreFilesystem = .live,
         startupOnWorker: Bool = false,
         startupRepairWillBegin: @escaping @Sendable () -> Void = {}) {
        self.storeFilesystem = storeFilesystem
        self.fileManager = fileManager
        self.artifactFilesystem = artifactFilesystem
        self.checkpointFilesystem = checkpointFilesystem
        self.promotionFilesystem = promotionFilesystem
        self.rootIndexPersistence = indexPersistence
        let appSupport = (try? fileManager.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil,
                                                create: true))
            ?? fileManager.temporaryDirectory
        let dir = baseDirectory ?? appSupport
            .appendingPathComponent("Labstream", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
        self.baseDirectory = dir
        let indexURL = dir.appendingPathComponent("index.json")
        let pendingQuarantine = dir.deletingLastPathComponent().appendingPathComponent(
            ".\(dir.lastPathComponent)-unsupported-reset-pending", isDirectory: true)
        let (startupProbe, startupIndexData) = Self.classifyIndex(
            at: indexURL, pendingQuarantine: pendingQuarantine,
            read: indexPersistence.read, fileManager: fileManager)
        self.startupSchemaProbe = startupProbe
        self.startupStagingInventory = Self.stagingInventory(
            in: dir, probe: startupProbe, fileManager: fileManager)
        self.indexURL = indexURL
        let authority = dir.deletingLastPathComponent().appendingPathComponent(
            ".\(dir.lastPathComponent)-download-authority", isDirectory: true)
        self.cleanupAuthorityDirectory = authority
        self.embyCleanupJournal = EmbyConvertCleanupJournal(
            directory: authority,
            persistence: embyCleanupPersistence ?? .live)
        self.indexWriter = RevisionedPersistenceWriter<IndexSnapshot>(
            encode: { snapshot in
                try DownloadIndexCoding.encode(snapshot.rows, schemaVersion: snapshot.schemaVersion)
            },
            commit: { data in try indexPersistence.atomicWrite(data, indexURL) },
            failureObserver: { failure in
                NSLog("DownloadStore: index %@ failed at revision %llu (%@)",
                      failure.stage.rawValue,
                      failure.revision,
                      failure.errorType)
            }
        )
        // Probe above is deliberately the first filesystem interaction that can affect admission.
        // Unsupported/unreadable roots remain byte-for-byte untouched until the session drain.
        guard startupProbe == .missing || startupProbe == .current else { return }
        if startupOnWorker {
            initialStartupSubmission = RecoverySubmission { [self] in
                startupReprobeWorkerLock.lock()
                defer { startupReprobeWorkerLock.unlock() }
                startupRepairWillBegin()
                captureStartupStagingIdentities()
                completeAdmissibleStartup(probe: startupProbe, indexData: startupIndexData)
                return startupIndexAdmission()
            }
        } else {
            captureStartupStagingIdentities()
            completeAdmissibleStartup(probe: startupProbe, indexData: startupIndexData)
        }
    }

    private func captureStartupStagingIdentities() {
        var identities: [String: CondemnedFileIdentity] = [:]
        for path in startupStagingInventory {
            identities[path] = condemnedFileIdentity(at: baseDirectory.appendingPathComponent(path))
        }
        lock.withLock { startupStagingIdentities = identities }
    }

    /// Classify the on-disk index without mutating anything (the first admission decision).
    private static func classifyIndex(
        at indexURL: URL,
        pendingQuarantine: URL,
        read: (URL) throws -> Data?,
        fileManager: FileManager
    ) -> (DownloadIndexCoding.StartupProbe, Data?) {
        var probe: DownloadIndexCoding.StartupProbe
        var indexData: Data?
        if fileManager.fileExists(atPath: indexURL.path) {
            do {
                let data = try read(indexURL)
                indexData = data
                probe = DownloadIndexCoding.startupProbe(data: data)
            } catch {
                probe = .unreadable
            }
        } else if fileManager.fileExists(atPath: pendingQuarantine.path) {
            // A prior rollback was interrupted after the opaque root was quarantined. Never
            // classify the absent live root as a new empty library; retry from the durable pending
            // quarantine after task drainage.
            probe = .unsupported(schemaVersion: nil)
        } else {
            probe = .missing
        }
        if probe == .current, let indexData {
            let decoded = DownloadIndexCoding.decode(Row.self, from: indexData)
            let keys = decoded.rows.map(\.ratingKey)
            if decoded.skippedRowCount > 0 || Set(keys).count != keys.count {
                probe = .unreadable
            }
        }
        return (probe, indexData)
    }

    private static func stagingInventory(
        in dir: URL, probe: DownloadIndexCoding.StartupProbe, fileManager: FileManager
    ) -> Set<String> {
        Set(((probe == .missing || probe == .current)
             ? ((try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []) : [])
            .filter(Self.isAttemptStagingRelativePath))
    }

    /// The admissible-startup tail: directories, authority migration, protection, temp sweeps,
    /// load, and artifact recovery. Runs on the startup worker in production, or from `reprobeBlockedIndex` once an index
    /// that was unreadable at launch reads cleanly (B16).
    private func completeAdmissibleStartup(
        probe startupProbe: DownloadIndexCoding.StartupProbe, indexData startupIndexData: Data?
    ) {
        let dir = baseDirectory
        let authority = cleanupAuthorityDirectory
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: authority, withIntermediateDirectories: true)
            try Self.syncDirectory(dir.deletingLastPathComponent())
            try moveCleanupAuthorityFilesOutOfVersionedRoot()
        } catch {
            lock.withLock { startupSchemaProbe = .unreadable }
            return
        }
        // Exclude the offline cache from iCloud/device backups and give newly-created
        // auth-adjacent artifacts a protected parent directory.
        try? CredentialArtifactStorage.applyProtectionAndBackupExclusion(
            to: self.baseDirectory,
            protection: CredentialArtifactStorage.authArtifactProtection,
            fileManager: fileManager)
        try? DownloadIndexFileCommitter.cleanupAbandonedTemps(
            for: indexURL,
            fileManager: fileManager)
        // B18: the cleanup-authority directory carries the same protection and backup exclusion as
        // the media root, including directories created by older builds, and its journals' own
        // abandoned commit temps are swept like the index's.
        try? CredentialArtifactStorage.applyProtectionAndBackupExclusion(
            to: authority,
            protection: CredentialArtifactStorage.authArtifactProtection,
            fileManager: fileManager)
        for name in ["download-cleanup-intents.json", "emby-convert-cleanup.json"] {
            try? DownloadIndexFileCommitter.cleanupAbandonedTemps(
                for: authority.appendingPathComponent(name),
                fileManager: fileManager)
        }
        try? DownloadArtifactFileCommitter.cleanupAbandonedResumeTemps(
            in: dir,
            fileManager: fileManager)
        // B15: decode the exact bytes the probe classified. A second read could fail transiently
        // and admit an empty `.current` store whose next snapshot overwrites the real index.
        load(indexData: startupProbe == .current ? startupIndexData : nil)
        lock.withLock {
            startupArtifactCleanupIntentIDs = Set(
                rows.values.flatMap { $0.pendingArtifactIntents.map(\.id) })
        }
        stageHeldBodyDeletionJobs()
        recoverPendingArtifactIntents()
        Self.scheduleUnsupportedRootReclamation(
            parent: dir.deletingLastPathComponent(),
            rootName: dir.lastPathComponent,
            fileManager: fileManager)
    }

    var startupIndexProbe: DownloadIndexCoding.StartupProbe {
        lock.withLock { startupSchemaProbe }
    }

    /// Server-cleanup intent must not share the versioned media root. A destructive schema reset
    /// quarantines `directory`, while this sibling durability domain remains addressable.
    var durableCleanupAuthorityDirectory: URL { cleanupAuthorityDirectory }

    enum UnsupportedRootResetResult: Sendable, Equatable {
        case reset(quarantineName: String)
        case notRequired
        case failed(stage: String, errorType: String)
    }

    /// Called only after the background session has reached an empty task-list fixed point.
    /// The old tree is never traversed: rename quarantines it atomically, parent fsync makes that
    /// namespace transition durable, and an independently durable empty v4 envelope is installed.
    func replaceUnsupportedRootWithCurrentEmptyStore() -> UnsupportedRootResetResult {
        guard case .unsupported = lock.withLock({ startupSchemaProbe }) else {
            return .notRequired
        }
        let parent = baseDirectory.deletingLastPathComponent()
        let quarantine = parent.appendingPathComponent(
            ".\(baseDirectory.lastPathComponent)-unsupported-reset-pending", isDirectory: true)
        var quarantined = false
        do {
            try fileManager.createDirectory(
                at: cleanupAuthorityDirectory, withIntermediateDirectories: true)
            try Self.syncDirectory(parent)
            try moveCleanupAuthorityFilesOutOfVersionedRoot()
            if fileManager.fileExists(atPath: baseDirectory.path) {
                if fileManager.fileExists(atPath: quarantine.path) {
                    let archived = parent.appendingPathComponent(
                        ".\(baseDirectory.lastPathComponent)-retired-\(UUID().uuidString)",
                        isDirectory: true)
                    try fileManager.moveItem(at: quarantine, to: archived)
                    try Self.syncDirectory(parent)
                }
                try fileManager.moveItem(at: baseDirectory, to: quarantine)
            } else {
                guard fileManager.fileExists(atPath: quarantine.path) else {
                    throw CocoaError(.fileNoSuchFile)
                }
            }
            quarantined = true
            try Self.syncDirectory(parent)
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: false)
            try CredentialArtifactStorage.applyProtectionAndBackupExclusion(
                to: baseDirectory,
                protection: CredentialArtifactStorage.authArtifactProtection,
                fileManager: fileManager)
            try rootIndexPersistence.atomicWrite(DownloadIndexCoding.encode([Row]()), indexURL)
            try Self.syncDirectory(parent)
            lock.withLock {
                for key in rows.keys { rowMutationGenerations[key, default: 0] &+= 1 }
                rows.removeAll()
                sideAssetHydrationCache.removeAll()
                startupStagingInventory.removeAll()
                startupSchemaProbe = .current
            }
            Self.scheduleUnsupportedRootReclamation(
                parent: parent, rootName: baseDirectory.lastPathComponent,
                fileManager: fileManager)
            return .reset(quarantineName: quarantine.lastPathComponent)
        } catch {
            var rollbackFailed = false
            if quarantined {
                do {
                    if fileManager.fileExists(atPath: baseDirectory.path) {
                        try fileManager.removeItem(at: baseDirectory)
                    }
                    try fileManager.moveItem(at: quarantine, to: baseDirectory)
                    try Self.syncDirectory(parent)
                } catch {
                    // The deterministic pending path is retained. A relaunched Store recognizes
                    // it and retries instead of treating the absent live root as empty.
                    rollbackFailed = true
                }
            }
            return .failed(
                stage: rollbackFailed ? "rollback_to_pending_quarantine"
                    : (quarantined ? "install_current_root" : "quarantine_root"),
                errorType: String(reflecting: type(of: error)))
        }
    }

    private static func syncDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Quarantine names are themselves the durable reclamation journal. They are created only
    /// after every old OS task has drained, and are eligible for recursive deletion only while a
    /// separately validated current root exists. Relaunch repeats the sweep after an interrupted
    /// removal, so old multi-gigabyte roots cannot remain invisible forever.
    private static func scheduleUnsupportedRootReclamation(
        parent: URL,
        rootName: String,
        fileManager: FileManager
    ) {
        let pendingName = ".\(rootName)-unsupported-reset-pending"
        let archivePrefix = ".\(rootName)-retired-"
        unsupportedRootCleanupQueue.async {
            guard fileManager.fileExists(
                atPath: parent.appendingPathComponent(rootName, isDirectory: true).path),
                  let candidates = try? fileManager.contentsOfDirectory(
                    at: parent, includingPropertiesForKeys: nil)
                    .filter({ $0.lastPathComponent == pendingName
                        || $0.lastPathComponent.hasPrefix(archivePrefix) }) else { return }
            var removedAny = false
            for candidate in candidates {
                do {
                    try fileManager.removeItem(at: candidate)
                    removedAny = true
                } catch {
                    // The durable quarantine name remains for the next launch/sweep.
                }
            }
            if removedAny { try? syncDirectory(parent) }
        }
    }

    /// These queues have independent server-cleanup authority and must survive replacement of the
    /// versioned media root. Migration is exact-file only and runs before root quarantine (and,
    /// for a current root, before either queue is opened). Conflicting durable bytes fail closed.
    private func moveCleanupAuthorityFilesOutOfVersionedRoot() throws {
        for name in ["download-cleanup-intents.json", "emby-convert-cleanup.json"] {
            let source = baseDirectory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = cleanupAuthorityDirectory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: destination.path) {
                guard try Data(contentsOf: source) == Data(contentsOf: destination) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try fileManager.removeItem(at: source)
            } else {
                try fileManager.moveItem(at: source, to: destination)
                try CredentialArtifactStorage.applyProtectionAndBackupExclusion(
                    to: destination,
                    protection: CredentialArtifactStorage.authArtifactProtection,
                    fileManager: fileManager)
            }
            try Self.syncDirectory(baseDirectory)
            try Self.syncDirectory(cleanupAuthorityDirectory)
            try Self.syncDirectory(baseDirectory.deletingLastPathComponent())
        }
    }

    /// Missing means an empty queue. Read/decode failures remain distinct so no later mutation can
    /// mistake an unreadable canonical queue for empty and erase orphan-cleanup intent.
    func loadEmbyConvertCleanupTombstones() -> EmbyCleanupLoadResult {
        embyCleanupJournal.load()
    }

    @discardableResult
    func removeEmbyConvertCleanupTombstone(id: UUID) -> EmbyCleanupRemoveResult {
        embyCleanupJournal.remove(id: id)
    }

    /// The directory media files should be written into.
    var directory: URL { baseDirectory }

    /// Build the on-disk destination for a given ratingKey + container extension.
    func destinationURL(ratingKey: String, ext: String) -> URL {
        let safeRatingKey = Self.safeFilenameComponent(ratingKey)
        let safeExt = Self.safeExtension(ext)
        return baseDirectory.appendingPathComponent("\(safeRatingKey).\(safeExt)")
    }

    /// Deterministic same-directory staging home for one attempt's media or side asset. The full
    /// SHA-256 covers the unsanitized ownership key and final relative path, so legacy arbitrary
    /// attempt tokens cannot collide merely because their path-safe spellings would be equal.
    func attemptStagingURL(for key: DownloadAttemptKey, stableURL: URL) -> URL? {
        guard let stableRelativePath = stableRelativePath(for: stableURL) else { return nil }
        return baseDirectory.appendingPathComponent(
            Self.attemptStagingRelativePath(for: key, stableRelativePath: stableRelativePath))
    }

    /// Return the persisted media layout only for the exact current owner. Unlike
    /// `attemptStagingURL(for:stableURL:)`, this does not derive authority from caller input.
    /// It is therefore the API background-session checkpoint/evidence/reconcile paths should use.
    func attemptWorkingFileLayout(for key: DownloadAttemptKey) -> AttemptWorkingFileLayout? {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[key.ratingKey], row.attemptID == key.attemptID,
              !Self.hasPendingRowDeletion(row),
              row.status != .complete, row.status != .unverified,
              let working = workingRelativePath(for: row, key: key) else { return nil }
        return AttemptWorkingFileLayout(
            key: key,
            stableURL: baseDirectory.appendingPathComponent(row.relativePath),
            workingURL: baseDirectory.appendingPathComponent(working)
        )
    }

    func attemptWorkingFileURL(for key: DownloadAttemptKey) -> URL? {
        attemptWorkingFileLayout(for: key)?.workingURL
    }

    /// Publish a caller-validated body through the durable artifact queue. Validation remains the
    /// caller's authority; this operation only publishes the already-validated exact-attempt file.
    @discardableResult
    func promoteValidatedAttempt(
        for key: DownloadAttemptKey,
        terminalStatus: DownloadStatus
    ) -> AttemptValidatedPromotionResult {
        resolveValidatedPromotionSynchronously(submitValidatedPromotion(
            for: key, terminalStatus: terminalStatus))
    }

    func submitValidatedPromotion(
        for key: DownloadAttemptKey,
        terminalStatus: DownloadStatus
    ) -> AttemptValidatedPromotionSubmission {
        guard terminalStatus == .complete || terminalStatus == .unverified else {
            return .immediate(.invalidTerminalStatus)
        }
        lock.lock()
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID else {
            lock.unlock(); return .immediate(.staleOrMissingOwner)
        }
        guard !row.deletionPending else {
            lock.unlock(); return .immediate(.resetPending)
        }
        if let head = row.pendingArtifactIntents.first,
           case .validatedPromotion(_, _, let pendingStatus, _) = head.operation,
           pendingStatus == terminalStatus,
           !activeArtifactIntentIDs.contains(head.id),
           !artifactRetirementKeys.contains(key) {
            let prepared = enqueueAttemptPersistenceLocked()
            let ticket = artifactLifecycle.register(
                key: key, generation: head.generation, intentID: head.id,
                preparedRevision: prepared)
            artifactLifecycleTickets[head.id] = ticket
            promotionAwaitingResultIDs.insert(ticket)
            activeArtifactIntentIDs.insert(head.id)
            lock.unlock()
            scheduleArtifactLifecycle(ticket: ticket, intent: head)
            return .accepted(ticket: ticket)
        }
        guard row.pendingArtifactIntents.isEmpty,
              row.pendingValidatedPromotionStatus == nil else {
            lock.unlock(); return .immediate(.resetPending)
        }
        guard let working = workingRelativePath(for: row, key: key) else {
            lock.unlock(); return .immediate(.invalidWorkingLayout)
        }
        guard Self.isSafeOneLevelRelativePath(row.relativePath) else {
            lock.unlock(); return .immediate(.invalidWorkingLayout)
        }
        guard reservedArtifactDeletionPaths[working] == nil,
              reservedArtifactDeletionPaths[row.relativePath] == nil else {
            lock.unlock(); return .immediate(.resetPending)
        }
        row.artifactGeneration += 1
        let intent = Row.ArtifactIntent(
            id: UUID(), attemptID: key.attemptID, generation: row.artifactGeneration,
            phase: .prepared,
            operation: .validatedPromotion(
                workingRelativePath: working,
                stableRelativePath: row.relativePath,
                terminalStatus: terminalStatus,
                sourceBytes: nil))
        row.pendingArtifactIntents.append(intent)
        setRowLocked(row, for: key.ratingKey)
        let prepared = enqueueAttemptPersistenceLocked()
        let ticket = artifactLifecycle.register(
            key: key, generation: intent.generation, intentID: intent.id,
            preparedRevision: prepared)
        artifactLifecycleTickets[intent.id] = ticket
        promotionAwaitingResultIDs.insert(ticket)
        activeArtifactIntentIDs.insert(intent.id)
        lock.unlock()
        scheduleArtifactLifecycle(ticket: ticket, intent: intent)
        return .accepted(ticket: ticket)
    }

    func resolveValidatedPromotionSynchronously(
        _ submission: AttemptValidatedPromotionSubmission
    ) -> AttemptValidatedPromotionResult {
        switch submission {
        case .immediate(let result): return result
        case .accepted(let ticket):
            let lifecycle = artifactLifecycle.waitSynchronously(for: ticket)
            if let result = lock.withLock({ () -> AttemptValidatedPromotionResult? in
                promotionAwaitingResultIDs.remove(ticket)
                return promotionOutcomes.removeValue(forKey: ticket)
            }) {
                return result
            }
            switch lifecycle {
            case .completed: return .staleOrMissingOwner
            case .failed(.persistence(let failure)): return .persistenceFailed(ticket.key, failure)
            case .failed(.artifact(let errorType)): return .renameFailed(errorType: errorType)
            case .timedOut: return .staleOrMissingOwner
            }
        }
    }

    func resolveValidatedPromotion(
        _ submission: AttemptValidatedPromotionSubmission
    ) async -> AttemptValidatedPromotionResult {
        await resolveValidatedPromotionDeadline(submission, deadline: .after(30))
    }

    private func recordPromotionOutcomeLocked(
        _ result: AttemptValidatedPromotionResult,
        ticket: DownloadArtifactLifecycleCoordinator.Ticket
    ) {
        guard promotionAwaitingResultIDs.contains(ticket) else { return }
        promotionOutcomes[ticket] = result
    }

    private func executeValidatedPromotion(
        ticket: DownloadArtifactLifecycleCoordinator.Ticket,
        intent: Row.ArtifactIntent
    ) {
        guard case .validatedPromotion(
            let working, let stable, let terminalStatus, let capturedBytes) = intent.operation,
              Self.isSafeOneLevelRelativePath(working),
              Self.isSafeOneLevelRelativePath(stable),
              terminalStatus == .complete || terminalStatus == .unverified else {
            failArtifactLifecycle(ticket, errorType: "invalidValidatedPromotionIntent"); return
        }
        let prepared = waitForPersistence(through: ticket.preparedRevision)
        guard prepared.result.committed(through: ticket.preparedRevision) else {
            failArtifactLifecycle(ticket, prepared.result); return
        }
        lock.lock()
        guard let current = rows[ticket.key.ratingKey],
              current.attemptID == ticket.key.attemptID,
              current.pendingArtifactIntents.first?.id == intent.id,
              current.relativePath == stable else {
            lock.unlock(); completeArtifactLifecycle(ticket); return
        }
        lock.unlock()

        guard case .acquired(let lease) = tryAcquirePathLease(for: ticket.key,
            relativePaths: [working, stable], purpose: .artifact) else {
            failArtifactLifecycle(ticket, errorType: "pathBusy"); return
        }
        defer { releasePathLease(lease) }
        let workingURL = baseDirectory.appendingPathComponent(working)
        let stableURL = baseDirectory.appendingPathComponent(stable)
        let provenBytes: Int
        if let capturedBytes {
            provenBytes = capturedBytes
        } else {
            guard let bytes = promotionFilesystem.size(workingURL), bytes > 0 else {
                // Pre-capture the rename cannot have run, so a missing working body is
                // permanently unrecoverable: no replay can ever repair it. Abandon the intent
                // (durably demoting the row to retryable `.failed`) instead of leaving a head
                // that wedges every future retry behind `.artifactLifecyclePending`.
                abandonUnrecoverablePromotion(ticket: ticket, intent: intent)
                return
            }
            lock.lock()
            guard var capturing = rows[ticket.key.ratingKey],
                  capturing.attemptID == ticket.key.attemptID,
                  capturing.pendingArtifactIntents.first?.id == intent.id else {
                lock.unlock(); completeArtifactLifecycle(ticket); return
            }
            capturing.pendingArtifactIntents[0].phase = .promotionSourceCaptured
            capturing.pendingArtifactIntents[0].operation = .validatedPromotion(
                workingRelativePath: working, stableRelativePath: stable,
                terminalStatus: terminalStatus, sourceBytes: bytes)
            setRowLocked(capturing, for: ticket.key.ratingKey)
            let captured = enqueueAttemptPersistenceLocked()
            lock.unlock()
            let capturedOutcome = waitForPersistence(through: captured)
            guard capturedOutcome.result.committed(through: captured) else {
                failArtifactLifecycle(ticket, capturedOutcome.result); return
            }
            provenBytes = bytes
        }
        let workingExisted = promotionFilesystem.exists(workingURL)
        if workingExisted {
            do {
                try promotionFilesystem.fullSyncSource(workingURL)
                try promotionFilesystem.renameReplacing(workingURL, stableURL)
                try promotionFilesystem.syncParentDirectory(stableURL)
            }
            catch {
                lock.withLock {
                    recordPromotionOutcomeLocked(.renameFailed(
                        errorType: String(reflecting: type(of: error))), ticket: ticket)
                }
                failArtifactLifecycle(ticket, errorType: String(reflecting: type(of: error))); return
            }
        } else {
            // Recovery may observe the post-rename/pre-directory-sync crash window. The prepared
            // exact-attempt recipe proves why stable may be authoritative, but the directory entry
            // still must be made durable before any terminal row can publish it.
            do { try promotionFilesystem.syncParentDirectory(stableURL) }
            catch {
                lock.withLock {
                    recordPromotionOutcomeLocked(.renameFailed(
                        errorType: String(reflecting: type(of: error))), ticket: ticket)
                }
                failArtifactLifecycle(ticket, errorType: String(reflecting: type(of: error))); return
            }
        }
        guard let bytes = promotionFilesystem.size(stableURL), bytes == provenBytes else {
            if !workingExisted {
                // Both bodies are gone (or stable no longer matches the captured proof) and no
                // rename ran this pass, so no replay can ever publish this intent. Abandon it so
                // the row fails retryably instead of wedging behind the queued head forever.
                abandonUnrecoverablePromotion(ticket: ticket, intent: intent)
                return
            }
            // The rename just succeeded, so stable SHOULD hold the proven body: treat the
            // mismatch as transient/fail-closed and keep the durable intent — the next replay
            // observes the renamed body and can still publish.
            lock.withLock { recordPromotionOutcomeLocked(.sourceMissing, ticket: ticket) }
            failArtifactLifecycle(ticket, errorType: "promotionSourceMissing"); return
        }

        lock.lock()
        guard var row = rows[ticket.key.ratingKey], row.attemptID == ticket.key.attemptID,
              row.pendingArtifactIntents.first?.id == intent.id else {
            lock.unlock(); completeArtifactLifecycle(ticket); return
        }
        row.bytes = bytes
        row.progress = 1
        Self.applyPromotionTerminal(terminalStatus, on: &row)
        row.attemptWorkingRelativePath = nil
        artifactRetirementKeys.insert(ticket.key)
        let retiring = row.pendingArtifactIntents.removeFirst()
        setRowLocked(row, for: ticket.key.ratingKey)
        let terminal = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let terminalOutcome = waitForPersistence(through: terminal)
        guard terminalOutcome.result.committed(through: terminal) else {
            lock.lock()
            if var restored = rows[ticket.key.ratingKey], restored.attemptID == ticket.key.attemptID {
                restored.pendingArtifactIntents.insert(retiring, at: 0)
                setRowLocked(restored, for: ticket.key.ratingKey)
                _ = enqueueAttemptPersistenceLocked()
            }
            artifactRetirementKeys.remove(ticket.key)
            recordPromotionOutcomeLocked(
                .persistenceFailed(ticket.key, terminalOutcome.result), ticket: ticket)
            lock.unlock()
            failArtifactLifecycle(ticket, terminalOutcome.result); return
        }
        lock.withLock {
            artifactRetirementKeys.remove(ticket.key)
            recordPromotionOutcomeLocked(.promoted(
                ticket.key, bytes: bytes, status: terminalStatus), ticket: ticket)
        }
        completeArtifactLifecycle(ticket)
    }

    /// Abandon a validated promotion whose source body is permanently gone: neither the working
    /// file nor a proven stable body exists, so replaying the durable intent can never succeed.
    /// Without this path the intent stays queued at head forever — `createAttemptOwnedRecord`
    /// rejects every retry with `.artifactLifecyclePending` and the row is wedged until a manual
    /// delete. Retire the intent behind the same retirement barrier as a successful terminal
    /// snapshot and demote the row to retryable `.failed` in the same durable transition.
    private func abandonUnrecoverablePromotion(
        ticket: DownloadArtifactLifecycleCoordinator.Ticket,
        intent: Row.ArtifactIntent
    ) {
        lock.lock()
        guard var row = rows[ticket.key.ratingKey], row.attemptID == ticket.key.attemptID,
              row.pendingArtifactIntents.first?.id == intent.id else {
            lock.unlock(); completeArtifactLifecycle(ticket); return
        }
        artifactRetirementKeys.insert(ticket.key)
        let retiring = row.pendingArtifactIntents.removeFirst()
        Self.reduceLocked(row.lifecycle == .finalizing
                          ? .promotionAbandoned : .transferFailed(.internalError), on: &row)
        setRowLocked(row, for: ticket.key.ratingKey)
        let terminal = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let terminalOutcome = waitForPersistence(through: terminal)
        guard terminalOutcome.result.committed(through: terminal) else {
            lock.lock()
            if var restored = rows[ticket.key.ratingKey],
               restored.attemptID == ticket.key.attemptID,
               !restored.pendingArtifactIntents.contains(where: { $0.id == retiring.id }) {
                restored.pendingArtifactIntents.insert(retiring, at: 0)
                setRowLocked(restored, for: ticket.key.ratingKey)
                _ = enqueueAttemptPersistenceLocked()
            }
            artifactRetirementKeys.remove(ticket.key)
            recordPromotionOutcomeLocked(
                .persistenceFailed(ticket.key, terminalOutcome.result), ticket: ticket)
            lock.unlock()
            failArtifactLifecycle(ticket, terminalOutcome.result); return
        }
        lock.withLock {
            artifactRetirementKeys.remove(ticket.key)
            startupArtifactCleanupIntentIDs.remove(retiring.id)
            recordPromotionOutcomeLocked(.sourceMissing, ticket: ticket)
        }
        AppDiagnostics.record(.downloads, "downloads.promotion_abandoned_source_missing", fields: [
            "download_id": .identifier(ticket.key.ratingKey),
        ])
        completeArtifactLifecycle(ticket)
    }

    /// Finish a promotion proven by a durable validated intent after a hard kill. If the working
    /// body still exists the kill preceded rename; otherwise a stable body is accepted only because
    /// the exact attempt's intent was committed first. No playback/size heuristic grants ownership.
    @discardableResult
    func recoverPendingValidatedPromotion(
        for key: DownloadAttemptKey
    ) -> AttemptValidatedPromotionResult {
        lock.lock()
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID else {
            lock.unlock(); return .staleOrMissingOwner
        }
        guard let terminalStatus = row.pendingValidatedPromotionStatus,
              terminalStatus == .complete || terminalStatus == .unverified,
              let workingRelative = workingRelativePath(for: row, key: key) else {
            lock.unlock(); return .invalidWorkingLayout
        }
        let stableRelative = row.relativePath
        lock.unlock()

        let workingURL = baseDirectory.appendingPathComponent(workingRelative)
        let stableURL = baseDirectory.appendingPathComponent(stableRelative)
        if promotionFilesystem.exists(workingURL) {
            do {
                try promotionFilesystem.fullSyncSource(workingURL)
                try promotionFilesystem.renameReplacing(workingURL, stableURL)
                try promotionFilesystem.syncParentDirectory(stableURL)
            } catch {
                return .renameFailed(errorType: String(reflecting: type(of: error)))
            }
        } else {
            do { try promotionFilesystem.syncParentDirectory(stableURL) }
            catch { return .renameFailed(errorType: String(reflecting: type(of: error))) }
        }
        guard let bytes = promotionFilesystem.size(stableURL), bytes > 0 else {
            return .sourceMissing
        }
        lock.lock()
        guard var current = rows[key.ratingKey], current.attemptID == key.attemptID,
              current.pendingValidatedPromotionStatus == terminalStatus,
              current.attemptWorkingRelativePath == workingRelative,
              current.relativePath == stableRelative else {
            lock.unlock(); return .staleOrMissingOwner
        }
        current.bytes = bytes
        current.progress = 1
        Self.reduceLocked(.promotionRecovered(Self.terminalLifecycle(terminalStatus)), on: &current)
        current.attemptWorkingRelativePath = nil
        current.pendingValidatedPromotionStatus = nil
        setRowLocked(current, for: key.ratingKey)
        let ticket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let persistence = waitForPersistence(through: ticket)
        guard persistence.result.committed(through: persistence.ticket) else {
            return .persistenceFailed(key, persistence.result)
        }
        return .promoted(key, bytes: bytes, status: terminalStatus)
    }

    /// The exact attempt's working body path. A condemned body (P3a `bodyCondemned`) has none:
    /// every checkpoint reader, checkpoint write, recovery finalization and promotion goes through
    /// here, so bytes a failed rename/delete left behind are invisible to all of them.
    private func workingRelativePath(for row: Row, key: DownloadAttemptKey) -> String? {
        guard !row.history.isBodyCondemned else { return nil }
        return uncheckedWorkingRelativePath(for: row, key: key)
    }

    /// The working path ignoring condemnation; only condemnation itself needs it.
    private func uncheckedWorkingRelativePath(for row: Row, key: DownloadAttemptKey) -> String? {
        guard Self.isSafeOneLevelRelativePath(row.relativePath) else { return nil }
        let expected = Self.attemptStagingRelativePath(
            for: key, stableRelativePath: row.relativePath)
        return row.attemptWorkingRelativePath == expected ? expected : nil
    }

    /// Atomically promote only while `key` is still the exact row owner. The ownership check and
    /// POSIX rename share the store lock with attempt create/remove, so stale attempt A cannot pass
    /// the check, let B take ownership, and then replace or delete B's stable file.
    @discardableResult
    func promoteAttemptStagingFile(for key: DownloadAttemptKey,
                                   stagingURL: URL,
                                   to stableURL: URL) -> AttemptStagingPromotionResult {
        promoteAttemptStagingFile(
            for: key, expectedSideAssetSource: nil, stagingURL: stagingURL, to: stableURL)
    }

    /// Side-asset publication requires both the exact attempt and the source identity captured
    /// before the fetch began. This closes same-attempt renegotiation races (notably Plex optimize
    /// and Jellyfin/Emby source replacement) where an old response arrives after metadata moved on.
    @discardableResult
    func promoteSideAssetStagingFile(
        for key: DownloadAttemptKey,
        expectedSource: OfflineSideAssetSourceIdentity,
        stagingURL: URL,
        to stableURL: URL
    ) -> AttemptStagingPromotionResult {
        promoteAttemptStagingFile(
            for: key, expectedSideAssetSource: expectedSource,
            stagingURL: stagingURL, to: stableURL)
    }

    private func promoteAttemptStagingFile(
        for key: DownloadAttemptKey,
        expectedSideAssetSource: OfflineSideAssetSourceIdentity?,
        stagingURL: URL,
        to stableURL: URL
    ) -> AttemptStagingPromotionResult {
        guard stableRelativePath(for: stableURL) != nil,
              let expectedStaging = attemptStagingURL(for: key, stableURL: stableURL),
              stagingURL.standardizedFileURL == expectedStaging.standardizedFileURL else { return .invalidPath }
        guard case .acquired(let lease) = tryAcquirePathLease(for: key,
            relativePaths: [stagingURL.lastPathComponent, stableURL.lastPathComponent], purpose: .artifact)
        else { return .staleOrMissingOwner }
        defer { releasePathLease(lease) }
        let snapshot = lock.withLock { () -> (UInt64, UInt64)? in
            guard let row = rows[key.ratingKey], row.attemptID == key.attemptID,
                  !Self.hasPendingRowDeletion(row),
                  expectedSideAssetSource == nil || row.metadata?.sideAssetSourceIdentity == expectedSideAssetSource else { return nil }
            return (rowMutationGenerations[key.ratingKey, default: 0], row.sideAssetGeneration)
        }
        guard let snapshot else { return .staleOrMissingOwner }
        guard storeFilesystem.exists(atPath: stagingURL.path, using: fileManager) else { return .sourceMissing }
        storeFilesystem.before(.rename, stagingURL)
        guard lock.withLock({ rowMutationGenerations[key.ratingKey, default: 0] == snapshot.0 }) else { return .staleOrMissingOwner }
        guard storeFilesystem.rename(stagingURL, stableURL) == 0 else {
            return .failed(errorType: String(reflecting: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)))
        }
        let current = lock.withLock { () -> Bool in
            guard var row = rows[key.ratingKey], row.attemptID == key.attemptID,
                  !Self.hasPendingRowDeletion(row), row.sideAssetGeneration == snapshot.1,
                  expectedSideAssetSource == nil || row.metadata?.sideAssetSourceIdentity == expectedSideAssetSource else { return false }
            if expectedSideAssetSource != nil {
                row.sideAssetGeneration &+= 1
                sideAssetPublicationOwners[stableURL.lastPathComponent] = SideAssetPublicationOwner(
                    key: key, source: expectedSideAssetSource!)
                setRowLocked(row, for: key.ratingKey)
                sideAssetHydrationCache.removeValue(forKey: key.ratingKey)
            }
            return true
        }
        if !current {
            // This lease excludes a newer publication. Retire only an unreferenced obsolete result.
            if lock.withLock({ !rows.values.contains { artifactPathsReferenced(by: $0).contains(stableURL.lastPathComponent) } }) {
                try? storeFilesystem.removeItem(at: stableURL, using: fileManager)
            }
            return .staleOrMissingOwner
        }
        return .promoted
    }

    /// Retire an obsolete private side-cache staging path even after its owner was replaced.
    /// Reservation is path-scoped; current manifests, derived staging and live writers win.
    func discardSideAssetStaging(at url: URL, for key: DownloadAttemptKey) {
        guard url.deletingLastPathComponent().standardizedFileURL == baseDirectory.standardizedFileURL,
              Self.isAttemptStagingRelativePath(url.lastPathComponent) else { return }
        let path = url.lastPathComponent
        let reservation = UUID()
        let claimed = lock.withLock { () -> Bool in
            // A current attempt may reuse this deterministic path for another source generation.
            // A stale tail cannot distinguish that new writer's bytes from its own. Successful
            // publication consumed its file already; defer failed current-owner staging to a
            // subsequent write/startup inventory instead of removing a successor's staging.
            guard rows[key.ratingKey]?.attemptID != key.attemptID,
                  reservedArtifactDeletionPaths[path] == nil, reservedHeldBodyDeletionPaths[path] == nil,
                  !stagingReferencesLocked(additional: []).contains(path) else { return false }
            reservedArtifactDeletionPaths[path] = reservation
            return true
        }
        guard claimed else { return }
        defer { lock.withLock { if reservedArtifactDeletionPaths[path] == reservation { reservedArtifactDeletionPaths.removeValue(forKey: path) } } }
        try? storeFilesystem.removeItem(at: url, using: fileManager)
    }

    /// Conservative startup inventory: only recognized staging files not attributable to a
    /// currently-owned row (or explicitly supplied live reference) are returned.
    func unreferencedAttemptStagingURLs(
        additionalReferencedRelativePaths: Set<String> = []
    ) -> [URL] {
        let inventory = lock.withLock { startupStagingInventory }
        storeFilesystem.before(.enumerate, baseDirectory)
        let urls = (try? fileManager.contentsOfDirectory(at: baseDirectory,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsSubdirectoryDescendants])) ?? []
        let regular = urls.filter { inventory.contains($0.lastPathComponent)
            && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        return lock.withLock {
            let references = stagingReferencesLocked(additional: additionalReferencedRelativePaths)
            return regular.filter { !references.contains($0.lastPathComponent)
                && reservedArtifactDeletionPaths[$0.lastPathComponent] == nil }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }

    @discardableResult
    func sweepUnreferencedAttemptStaging(
        additionalReferencedRelativePaths: Set<String> = []
    ) -> AttemptStagingSweepResult {
        let candidates = unreferencedAttemptStagingURLs(additionalReferencedRelativePaths: additionalReferencedRelativePaths)
        var removed: [String] = []
        var failed: [String] = []
        for url in candidates {
            let name = url.lastPathComponent
            guard let identity = condemnedFileIdentity(at: url) else { continue }
            let reservation = UUID()
            let reserved = lock.withLock { () -> Bool in
                guard !stagingReferencesLocked(additional: additionalReferencedRelativePaths).contains(name),
                      reservedArtifactDeletionPaths[name] == nil,
                      startupStagingIdentities[name] == identity else { return false }
                reservedArtifactDeletionPaths[name] = reservation
                return true
            }
            guard reserved else { continue }
            defer { lock.withLock { if reservedArtifactDeletionPaths[name] == reservation { reservedArtifactDeletionPaths.removeValue(forKey: name) } } }
            do {
                guard condemnedFileIdentity(at: url) == identity else { continue }
                try storeFilesystem.removeItem(at: url, using: fileManager)
                removed.append(name)
            } catch { failed.append(name) }
        }
        return .init(removedRelativePaths: removed.sorted(), failedRelativePaths: failed.sorted())
    }

    private func stableRelativePath(for url: URL) -> String? {
        let standardized = url.standardizedFileURL
        guard standardized.deletingLastPathComponent() == baseDirectory.standardizedFileURL,
              Self.isSafeOneLevelRelativePath(standardized.lastPathComponent),
              !Self.isAttemptStagingRelativePath(standardized.lastPathComponent) else { return nil }
        return standardized.lastPathComponent
    }

    private static func attemptStagingRelativePath(for key: DownloadAttemptKey,
                                                   stableRelativePath: String) -> String {
        let identity = "\(key.ratingKey.utf8.count):\(key.ratingKey)\u{0}"
            + "\(key.attemptID.rawValue.utf8.count):\(key.attemptID.rawValue)\u{0}"
            + stableRelativePath
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return ".attempt-stage-v1-\(digest).stage"
    }

    private static func isAttemptStagingRelativePath(_ value: String) -> Bool {
        let prefix = ".attempt-stage-v1-"
        let suffix = ".stage"
        guard value.hasPrefix(prefix), value.hasSuffix(suffix) else { return false }
        let start = value.index(value.startIndex, offsetBy: prefix.count)
        let end = value.index(value.endIndex, offsetBy: -suffix.count)
        let digest = value[start..<end]
        return digest.count == 64 && digest.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private func stagingReferencesLocked(additional: Set<String>) -> Set<String> {
        var referenced = additional
        for row in rows.values {
            referenced.formUnion(artifactPathsReferenced(by: row))
            guard let attemptID = row.attemptID else { continue }
            let key = DownloadAttemptKey(ratingKey: row.ratingKey, attemptID: attemptID)
            for stable in [row.relativePath] + sideAssetRelativePaths(for: row.metadata)
                where Self.isSafeOneLevelRelativePath(stable) {
                referenced.insert(Self.attemptStagingRelativePath(for: key, stableRelativePath: stable))
            }
        }
        return referenced
    }

    private static func safeFilenameComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let result = String(scalars)
        return result.isEmpty ? UUID().uuidString : result
    }

    private static func safeExtension(_ value: String,
                                      allowed: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "ts", "webm"],
                                      fallback: String = "mp4") -> String {
        let lowered = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let alnum = lowered.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
        return alnum && allowed.contains(lowered) ? lowered : fallback
    }

    private static func safeSubtitleExtension(_ value: String) -> String {
        safeExtension(value, allowed: ["srt", "vtt"], fallback: "vtt")
    }

    /// Build the on-disk destination for a ratingKey's cached poster (D5). Kept as a
    /// sibling of the media file so `remove` (which deletes the whole base dir entry)
    /// and the relative-path convention both apply uniformly.
    func posterDestinationURL(ratingKey: String) -> URL {
        baseDirectory.appendingPathComponent("\(Self.safeFilenameComponent(ratingKey)).poster.jpg")
    }

    /// Build the on-disk destination for a ratingKey's cached Plex BIF trick-play index (#78).
    func plexBIFDestinationURL(ratingKey: String) -> URL {
        baseDirectory.appendingPathComponent("\(Self.safeFilenameComponent(ratingKey)).plex-sd.bif")
    }

    /// Selected-source Emby BIF cache. Auth and source identity stay in the request/metadata; the
    /// filename is stable, token-free, and owned by the same attempt lifecycle as other side assets.
    func embyBIFDestinationURL(ratingKey: String) -> URL {
        baseDirectory.appendingPathComponent("\(Self.safeFilenameComponent(ratingKey)).emby.bif")
    }

    func jellyfinTrickPlayPlaylistDestinationURL(ratingKey: String) -> URL {
        baseDirectory.appendingPathComponent("\(Self.safeFilenameComponent(ratingKey)).jf-trickplay.m3u8")
    }

    func jellyfinTrickPlayTileDestinationURL(ratingKey: String, index: Int) -> URL {
        baseDirectory.appendingPathComponent("\(Self.safeFilenameComponent(ratingKey)).jf-trickplay-\(index).jpg")
    }

    /// On-disk destination for a ratingKey's cached per-chapter image (#88/#89). Keyed by the
    /// chapter index so the offline Chapters rail and the Emby offline scrubber can both resolve a
    /// chapter back to its cached JPEG. Filename carries no token (the auth lives in the request).
    func chapterImageDestinationURL(ratingKey: String, index: Int) -> URL {
        baseDirectory.appendingPathComponent("\(Self.safeFilenameComponent(ratingKey)).chapter-\(index).jpg")
    }

    func textSubtitleDestinationURL(ratingKey: String, streamID: Int, ext: String) -> URL {
        baseDirectory.appendingPathComponent("\(Self.safeFilenameComponent(ratingKey)).sub-\(streamID).\(Self.safeSubtitleExtension(ext))")
    }

    /// #95: on-disk destination for a ratingKey's persisted URLSession resume blob, kept as a
    /// sibling of the media file so the relative-path convention and `remove` cleanup apply.
    func resumeDataDestinationURL(ratingKey: String) -> URL {
        baseDirectory.appendingPathComponent("\(Self.safeFilenameComponent(ratingKey)).resume")
    }

    /// Durable home for an out-of-order static Range body. A UUID prevents a replacement body
    /// from aliasing the manifest/file still visible to a concurrent drain.
    func heldRangeSegmentDestinationURL(ratingKey: String, offset: Int) -> URL {
        baseDirectory.appendingPathComponent(
            "\(Self.safeFilenameComponent(ratingKey)).range-held-\(max(0, offset))-\(UUID().uuidString)"
        )
    }

    func heldRangeSegmentURL(relativePath: String) -> URL? {
        guard Self.isSafeOneLevelRelativePath(relativePath) else { return nil }
        return baseDirectory.appendingPathComponent(relativePath)
    }

    /// Attempt-owned counterpart. Ownership and manifest replacement share the store lock so a
    /// delayed body from A cannot attach itself to replacement attempt B.
    @discardableResult
    func persistHeldRangeSegment(
        for key: DownloadAttemptKey,
        segment: OfflineHeldRangeSegment
    ) -> AttemptHeldRangeSegmentPersistResult {
        lock.lock()
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID,
              !row.deletionPending,
              !Self.hasPendingRowDeletion(row),
              row.pendingValidatedPromotionStatus == nil,
              reservedHeldBodyDeletionPaths[segment.relativePath] == nil,
              reservedArtifactDeletionPaths[segment.relativePath] == nil,
              var metadata = row.metadata else {
            lock.unlock()
            return .staleOrMissing
        }
        guard Self.isSafeOneLevelRelativePath(segment.relativePath),
              segment.offset >= 0, segment.length > 0 else {
            lock.unlock()
            return .invalidSegment
        }
        var segments = metadata.heldRangeSegments ?? []
        let previous = segments.first { $0.offset == segment.offset }
        segments.removeAll { $0.offset == segment.offset }
        segments.append(segment)
        metadata.heldRangeSegments = segments.sorted { $0.offset < $1.offset }
        metadata.downloadAttemptID = key.attemptID.rawValue
        row.metadata = metadata
        setRowLocked(row, for: key.ratingKey)
        let ticket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let persistence = waitForPersistence(through: ticket)
        return .accepted(
            previous: previous,
            ticket: persistence.ticket,
            persistence: persistence.result
        )
    }

    func submitHeldRangeSegment(
        for key: DownloadAttemptKey,
        segment: OfflineHeldRangeSegment,
        deletingRelativePaths candidates: [String] = []
    ) -> AttemptHeldRangeLifecycleSubmissionResult {
        lock.lock()
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID,
              !row.deletionPending,
              !Self.hasPendingRowDeletion(row),
              row.pendingValidatedPromotionStatus == nil,
              reservedHeldBodyDeletionPaths[segment.relativePath] == nil,
              reservedArtifactDeletionPaths[segment.relativePath] == nil,
              var metadata = row.metadata else {
            lock.unlock(); return .staleOrMissing
        }
        guard Self.isSafeOneLevelRelativePath(segment.relativePath),
              segment.offset >= 0, segment.length > 0 else {
            lock.unlock(); return .invalidSegment
        }
        var segments = metadata.heldRangeSegments ?? []
        let previous = segments.first { $0.offset == segment.offset }
        segments.removeAll { $0.offset == segment.offset }
        segments.append(segment)
        metadata.heldRangeSegments = segments.sorted { $0.offset < $1.offset }
        metadata.downloadAttemptID = key.attemptID.rawValue
        row.metadata = metadata
        let paths = Set(row.heldRangeBodyDeletionIntents)
            .union(candidates.filter(Self.isSafeOneLevelRelativePath))
            .union(previous.map { [$0.relativePath] } ?? [])
            .filter(Self.isSafeOneLevelRelativePath).sorted()
        row.heldRangeBodyDeletionIntents = paths
        let (_, ticket, start) = appendHeldLifecycleIntentLocked(
            row: &row, key: key, relativePaths: paths)
        setRowLocked(row, for: key.ratingKey)
        lock.unlock()
        if let start { scheduleArtifactLifecycle(ticket: start.1, intent: start.0) }
        return .accepted(.init(
            previous: previous, removed: [], deferredRelativePaths: paths, ticket: ticket))
    }

    func submitHeldRangeSegmentsRemoval(
        for key: DownloadAttemptKey,
        offsets: [Int]?,
        deletingRelativePaths candidates: [String] = []
    ) -> AttemptHeldRangeLifecycleSubmissionResult {
        lock.lock()
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID,
              !row.deletionPending,
              !Self.hasPendingRowDeletion(row),
              row.pendingValidatedPromotionStatus == nil,
              var metadata = row.metadata else {
            lock.unlock(); return .staleOrMissing
        }
        let existing = metadata.heldRangeSegments ?? []
        let removed: [OfflineHeldRangeSegment]
        if let offsets {
            let set = Set(offsets)
            removed = existing.filter { set.contains($0.offset) }
            let remaining = existing.filter { !set.contains($0.offset) }
            metadata.heldRangeSegments = remaining.isEmpty ? nil : remaining
        } else {
            removed = existing
            metadata.heldRangeSegments = nil
        }
        metadata.downloadAttemptID = key.attemptID.rawValue
        row.metadata = metadata
        let paths = Set(row.heldRangeBodyDeletionIntents)
            .union(candidates.filter(Self.isSafeOneLevelRelativePath))
            .union(removed.map(\.relativePath).filter(Self.isSafeOneLevelRelativePath))
            .sorted()
        row.heldRangeBodyDeletionIntents = paths
        let (_, ticket, start) = appendHeldLifecycleIntentLocked(
            row: &row, key: key, relativePaths: paths)
        setRowLocked(row, for: key.ratingKey)
        lock.unlock()
        if let start { scheduleArtifactLifecycle(ticket: start.1, intent: start.0) }
        return .accepted(.init(
            previous: nil, removed: removed, deferredRelativePaths: paths, ticket: ticket))
    }

    private func appendHeldLifecycleIntentLocked(
        row: inout Row,
        key: DownloadAttemptKey,
        relativePaths: [String]
    ) -> (
        Row.ArtifactIntent,
        DownloadArtifactLifecycleCoordinator.Ticket,
        (Row.ArtifactIntent, DownloadArtifactLifecycleCoordinator.Ticket)?
    ) {
        row.artifactGeneration += 1
        let intent = Row.ArtifactIntent(
            id: UUID(), attemptID: key.attemptID,
            generation: row.artifactGeneration, phase: .prepared,
            operation: .heldBodyDeletion(relativePaths: relativePaths))
        row.pendingArtifactIntents.append(intent)
        setRowLocked(row, for: key.ratingKey)
        let prepared = enqueueAttemptPersistenceLocked()
        let ticket = artifactLifecycle.register(
            key: key, generation: intent.generation, intentID: intent.id,
            preparedRevision: prepared)
        artifactLifecycleTickets[intent.id] = ticket
        let start = activateArtifactHeadLocked(
            row: row, key: key, appendedIntent: intent, appendedTicket: ticket)
        return (intent, ticket, start)
    }

    private func activateArtifactHeadLocked(
        row: Row,
        key: DownloadAttemptKey,
        appendedIntent: Row.ArtifactIntent,
        appendedTicket: DownloadArtifactLifecycleCoordinator.Ticket
    ) -> (Row.ArtifactIntent, DownloadArtifactLifecycleCoordinator.Ticket)? {
        guard !artifactRetirementKeys.contains(key),
              let head = row.pendingArtifactIntents.first,
              !activeArtifactIntentIDs.contains(head.id) else { return nil }
        let headTicket: DownloadArtifactLifecycleCoordinator.Ticket
        if head.id == appendedIntent.id {
            headTicket = appendedTicket
        } else {
            headTicket = artifactLifecycle.register(
                key: key, generation: head.generation, intentID: head.id,
                preparedRevision: .init(revision: 0))
            artifactLifecycleTickets[head.id] = headTicket
        }
        activeArtifactIntentIDs.insert(head.id)
        return (head, headTicket)
    }

    /// Schedule a durable queue head according to its operation. Successor submissions can be the
    /// event that discovers an inactive predecessor after a failed lifecycle attempt, so they must
    /// restart that predecessor rather than assuming the newly appended operation owns the head.
    private func scheduleArtifactLifecycle(
        ticket: DownloadArtifactLifecycleCoordinator.Ticket,
        intent: Row.ArtifactIntent
    ) {
        artifactWorkerQueue.async { [weak self] in
            guard let self else { return }
            switch intent.operation {
            case .replaceResumeBlob:
                let data = self.lock.withLock { self.pendingResumeArtifactData[intent.id] }
                self.executeResumeReplacement(ticket: ticket, data: data)
            case .clearResumeBlob:
                self.executeResumeClear(ticket: ticket)
            case .heldBodyDeletion:
                self.executeHeldLifecycle(ticket: ticket, intent: intent)
            case .staticCheckpoint:
                self.executeStaticCheckpoint(ticket: ticket, intent: intent)
            case .validatedPromotion:
                self.executeValidatedPromotion(ticket: ticket, intent: intent)
            case .rowDeletion:
                self.executeRowDeletion(ticket: ticket, intent: intent)
            }
        }
    }

    private func executeHeldLifecycle(
        ticket: DownloadArtifactLifecycleCoordinator.Ticket,
        intent: Row.ArtifactIntent
    ) {
        let prepared = waitForPersistence(through: ticket.preparedRevision)
        guard prepared.result.committed(through: ticket.preparedRevision) else {
            failArtifactLifecycle(ticket, prepared.result); return
        }
        // Observe, but never submit, later R2. A terminal clear may carry current memory only after
        // every already-submitted revision through this point is independently durable.
        let latest = currentPersistenceTicket()
        let latestOutcome = waitForPersistence(through: latest)
        guard latestOutcome.result.committed(through: latest) else {
            failArtifactLifecycle(ticket, latestOutcome.result); return
        }
        guard case .heldBodyDeletion(let provenPaths) = intent.operation else {
            failArtifactLifecycle(ticket, errorType: "invalidHeldLifecycleIntent"); return
        }
        lock.lock()
        guard let row = rows[ticket.key.ratingKey], row.attemptID == ticket.key.attemptID,
              row.pendingArtifactIntents.first?.id == intent.id else {
            lock.unlock(); completeArtifactLifecycle(ticket); return
        }
        let referenced = heldRangeManifestRelativePathsLocked()
        let proven = Set(provenPaths)
        let protected = Set(row.heldRangeBodyDeletionIntents)
            .intersection(proven).intersection(referenced)
        let candidates = row.heldRangeBodyDeletionIntents
            .filter { proven.contains($0) && Self.isSafeOneLevelRelativePath($0) }
            .filter { !referenced.contains($0) }
        guard candidates.allSatisfy({ reservedHeldBodyDeletionPaths[$0] == nil && reservedArtifactDeletionPaths[$0] == nil }) else {
            lock.unlock()
            failArtifactLifecycle(ticket, errorType: "heldPathReserved")
            return
        }
        for path in candidates { reservedHeldBodyDeletionPaths[path] = intent.id }
        lock.unlock()

        var deleted = Set<String>()
        var deletionError: String?
        for path in candidates {
            let url = baseDirectory.appendingPathComponent(path)
            do {
                if artifactFilesystem.fileExists(url, fileManager) {
                    try artifactFilesystem.removeItem(url, fileManager)
                }
                deleted.insert(path)
            } catch {
                deletionError = String(reflecting: type(of: error))
            }
        }
        if deletionError == nil, !candidates.isEmpty {
            do { try artifactFilesystem.syncParentDirectory(
                baseDirectory.appendingPathComponent(candidates[0])) }
            catch { deletionError = String(reflecting: type(of: error)) }
        }

        lock.lock()
        guard deletionError == nil,
              var terminalRow = rows[ticket.key.ratingKey],
              terminalRow.attemptID == ticket.key.attemptID,
              terminalRow.pendingArtifactIntents.first?.id == intent.id else {
            for path in candidates where reservedHeldBodyDeletionPaths[path] == intent.id {
                reservedHeldBodyDeletionPaths.removeValue(forKey: path)
            }
            lock.unlock()
            if let deletionError { failArtifactLifecycle(ticket, errorType: deletionError) }
            else { completeArtifactLifecycle(ticket) }
            return
        }
        let completed = deleted.union(protected)
        terminalRow.heldRangeBodyDeletionIntents.removeAll { completed.contains($0) }
        artifactRetirementKeys.insert(ticket.key)
        let retiringIntent = terminalRow.pendingArtifactIntents.removeFirst()
        setRowLocked(terminalRow, for: ticket.key.ratingKey)
        let terminalTicket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let terminal = waitForPersistence(through: terminalTicket)
        guard terminal.result.committed(through: terminalTicket) else {
            lock.lock()
            if var restored = rows[ticket.key.ratingKey],
               restored.attemptID == ticket.key.attemptID {
                restored.pendingArtifactIntents.insert(retiringIntent, at: 0)
                restored.heldRangeBodyDeletionIntents = Set(
                    restored.heldRangeBodyDeletionIntents).union(completed).sorted()
                setRowLocked(restored, for: ticket.key.ratingKey)
                _ = enqueueAttemptPersistenceLocked()
            }
            for path in candidates where reservedHeldBodyDeletionPaths[path] == intent.id {
                reservedHeldBodyDeletionPaths.removeValue(forKey: path)
            }
            artifactRetirementKeys.remove(ticket.key)
            lock.unlock()
            failArtifactLifecycle(ticket, terminal.result)
            return
        }
        lock.withLock {
            for path in candidates where reservedHeldBodyDeletionPaths[path] == intent.id {
                reservedHeldBodyDeletionPaths.removeValue(forKey: path)
            }
            artifactRetirementKeys.remove(ticket.key)
        }
        completeArtifactLifecycle(ticket)
    }

    func stageHeldBodyDeletionJobs() {
        lock.lock()
        var staged: [(DownloadAttemptKey, Row.ArtifactIntent, DownloadArtifactLifecycleCoordinator.Ticket)] = []
        for (ratingKey, original) in Array(rows) {
            guard let attemptID = original.attemptID,
                  !original.heldRangeBodyDeletionIntents.isEmpty,
                  !Self.hasPendingRowDeletion(original),
                  !original.pendingArtifactIntents.contains(where: {
                    if case .heldBodyDeletion = $0.operation { return true }
                    return false
                  }) else { continue }
            var row = original
            let key = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID)
            let paths = row.heldRangeBodyDeletionIntents
            let tuple = appendHeldLifecycleIntentLocked(
                row: &row, key: key, relativePaths: paths)
            setRowLocked(row, for: ratingKey)
            if let start = tuple.2 { staged.append((key, start.0, start.1)) }
        }
        lock.unlock()
        for (_, intent, ticket) in staged {
            scheduleArtifactLifecycle(ticket: ticket, intent: intent)
        }
    }

    @discardableResult
    func removeHeldRangeSegment(
        for key: DownloadAttemptKey,
        offset: Int
    ) -> AttemptHeldRangeSegmentsRemovalResult {
        removeHeldRangeSegments(for: key, offsets: [offset])
    }

    /// Exact-owner removal retains the legacy durability rule: even an accepted no-op retries a
    /// dirty prior full-snapshot write. A stale attempt never gets to prove or mutate B's state.
    @discardableResult
    func removeHeldRangeSegments(
        for key: DownloadAttemptKey,
        offsets: [Int],
        deletingRelativePaths candidates: [String] = []
    ) -> AttemptHeldRangeSegmentsRemovalResult {
        let offsetSet = Set(offsets)
        lock.lock()
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID,
              !row.deletionPending,
              !Self.hasPendingRowDeletion(row),
              row.pendingValidatedPromotionStatus == nil,
              var metadata = row.metadata else {
            lock.unlock()
            return .staleOrMissing
        }
        var removed: [OfflineHeldRangeSegment] = []
        if !offsetSet.isEmpty, let segments = metadata.heldRangeSegments {
            removed = segments.filter { offsetSet.contains($0.offset) }
            if !removed.isEmpty {
                let remaining = segments.filter { !offsetSet.contains($0.offset) }
                metadata.heldRangeSegments = remaining.isEmpty ? nil : remaining
                metadata.downloadAttemptID = key.attemptID.rawValue
                row.metadata = metadata
                setRowLocked(row, for: key.ratingKey)
            }
        }
        let safeCandidates = Set(candidates.filter(Self.isSafeOneLevelRelativePath))
        let manifestPaths = Set(removed.map(\.relativePath).filter(Self.isSafeOneLevelRelativePath))
        let deferred = Set(row.heldRangeBodyDeletionIntents)
            .union(safeCandidates)
            .union(manifestPaths)
        row.heldRangeBodyDeletionIntents = deferred.sorted()
        setRowLocked(row, for: key.ratingKey)
        let ticket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let persistence = waitForPersistence(through: ticket)
        return .accepted(HeldRangeSegmentsRemovalResult(
            removed: removed,
            deferredRelativePaths: deferred.sorted(),
            ticket: persistence.ticket,
            persistence: persistence.result
        ))
    }

    @discardableResult
    func takeHeldRangeSegments(
        for key: DownloadAttemptKey,
        deletingRelativePaths candidates: [String] = []
    ) -> AttemptHeldRangeSegmentsRemovalResult {
        lock.lock()
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID,
              !Self.hasPendingRowDeletion(row),
              var metadata = row.metadata else {
            lock.unlock()
            return .staleOrMissing
        }
        let removed = metadata.heldRangeSegments ?? []
        if !removed.isEmpty {
            metadata.heldRangeSegments = nil
            metadata.downloadAttemptID = key.attemptID.rawValue
            row.metadata = metadata
        }
        let deferred = Set(row.heldRangeBodyDeletionIntents)
            .union(candidates.filter(Self.isSafeOneLevelRelativePath))
            .union(removed.map(\.relativePath).filter(Self.isSafeOneLevelRelativePath))
        row.heldRangeBodyDeletionIntents = deferred.sorted()
        setRowLocked(row, for: key.ratingKey)
        let ticket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let persistence = waitForPersistence(through: ticket)
        return .accepted(HeldRangeSegmentsRemovalResult(
            removed: removed,
            deferredRelativePaths: deferred.sorted(),
            ticket: persistence.ticket,
            persistence: persistence.result
        ))
    }

    /// Complete a previously staged held-body deletion. The owner check and filesystem mutations
    /// share the Store lock, so a stale attempt A can never race a replacement B into reusing a
    /// path. Missing files count as idempotent success. Failed deletes retain their durable intent.
    @discardableResult
    func retryDeferredHeldRangeBodyDeletions(
        for key: DownloadAttemptKey
    ) -> AttemptHeldRangeSegmentsPurgeResult {
        // First prove the current full snapshot. A prior failed manifest-removal write may have
        // staged intents only in memory; no body may be touched until that snapshot is durable.
        lock.lock()
        guard let row = rows[key.ratingKey], row.attemptID == key.attemptID else {
            lock.unlock()
            return .staleOrMissing
        }
        let ticket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let persistence = waitForPersistence(through: ticket)
        let removal = HeldRangeSegmentsRemovalResult(
            removed: [], deferredRelativePaths: row.heldRangeBodyDeletionIntents,
            ticket: persistence.ticket, persistence: persistence.result)
        guard removal.committed else {
            return .purged(AttemptHeldRangePurgeResult(
                removal: removal, removedRelativePaths: [], failedRelativePaths: []))
        }
        return completeDeferredHeldRangeBodyDeletions(for: key, removal: removal)
    }

    @discardableResult
    func completeDeferredHeldRangeBodyDeletions(
        for key: DownloadAttemptKey,
        removal: HeldRangeSegmentsRemovalResult
    ) -> AttemptHeldRangeSegmentsPurgeResult {
        guard removal.committed else {
            return .purged(AttemptHeldRangePurgeResult(
                removal: removal, removedRelativePaths: [], failedRelativePaths: []))
        }
        lock.lock()
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID else {
            lock.unlock()
            return .staleOrMissing
        }
        // A committed result proves only the snapshot captured by its exact ticket. If a later
        // mutation is already staged (especially a failed R2), clearing R1 would submit the
        // CURRENT full row and accidentally commit R2 before its bodies are eligible for deletion.
        // Defer instead; retryDeferredHeldRangeBodyDeletions will prove the latest snapshot first.
        guard nextPersistenceRevision == removal.ticket.revision else {
            lock.unlock()
            return .purged(AttemptHeldRangePurgeResult(
                removal: removal, removedRelativePaths: [], failedRelativePaths: []))
        }
        let provenPaths = Set(removal.deferredRelativePaths)
        let currentlyReferenced = Set(rows.values.flatMap { candidate -> Set<String> in
            if candidate.ratingKey == key.ratingKey {
                return Set(candidate.metadata?.heldRangeSegments?.map(\.relativePath) ?? [])
            }
            return artifactPathsReferenced(by: candidate)
        })
        let protectedByManifest = Set(row.heldRangeBodyDeletionIntents).intersection(provenPaths).intersection(currentlyReferenced)
        let candidates = row.heldRangeBodyDeletionIntents.filter {
            provenPaths.contains($0) && Self.isSafeOneLevelRelativePath($0)
                && !currentlyReferenced.contains($0) && reservedArtifactDeletionPaths[$0] == nil && reservedHeldBodyDeletionPaths[$0] == nil
        }
        let reservation = UUID()
        for path in candidates { reservedArtifactDeletionPaths[path] = reservation }
        lock.unlock()
        defer {
            lock.withLock {
                for path in candidates where reservedArtifactDeletionPaths[path] == reservation { reservedArtifactDeletionPaths.removeValue(forKey: path) }
            }
        }
        var removed: [String] = []
        var failed: [String] = []
        for relativePath in candidates {
            let url = baseDirectory.appendingPathComponent(relativePath)
            do {
                if storeFilesystem.exists(atPath: url.path, using: fileManager) { try storeFilesystem.removeItem(at: url, using: fileManager) }
                removed.append(relativePath)
            } catch { failed.append(relativePath) }
        }
        lock.lock()
        guard let current = rows[key.ratingKey], current.attemptID == key.attemptID else {
            lock.unlock(); return .staleOrMissing
        }
        row = current
        let completed = Set(removed).union(protectedByManifest)
        row.heldRangeBodyDeletionIntents.removeAll { completed.contains($0) }
        setRowLocked(row, for: key.ratingKey)
        let cleanupTicket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        // A failed clear is harmless: the durable intent replays idempotently on relaunch.
        _ = waitForPersistence(through: cleanupTicket)
        return .purged(AttemptHeldRangePurgeResult(
            removal: removal,
            removedRelativePaths: removed.sorted(),
            failedRelativePaths: failed.sorted()))
    }

    /// Remove the exact owner's manifest first and delete bodies only after that absence is proven
    /// durable. On an index fault no body is deleted, preserving the only durable checkpoint.
    @discardableResult
    func purgeHeldRangeSegments(
        for key: DownloadAttemptKey
    ) -> AttemptHeldRangeSegmentsPurgeResult {
        guard case .accepted(let removal) = takeHeldRangeSegments(for: key) else {
            return .staleOrMissing
        }
        guard removal.committed else {
            return .purged(AttemptHeldRangePurgeResult(
                removal: removal,
                removedRelativePaths: [],
                failedRelativePaths: []
            ))
        }
        return completeDeferredHeldRangeBodyDeletions(for: key, removal: removal)
    }

    var referencedHeldRangeSegmentRelativePaths: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(rows.values.flatMap { row in
            (row.metadata?.heldRangeSegments?.map(\.relativePath) ?? [])
                + row.heldRangeBodyDeletionIntents
        }.filter(Self.isSafeOneLevelRelativePath))
    }

    func deferredHeldRangeBodyDeletionRelativePaths(
        for key: DownloadAttemptKey
    ) -> [String]? {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[key.ratingKey], row.attemptID == key.attemptID else { return nil }
        return row.heldRangeBodyDeletionIntents
    }

    /// Re-resolve a stored relative cache path to an absolute URL that exists on disk.
    private func resolvedDownloadAssetURL(_ relative: String?) -> URL? {
        guard let relative, Self.isSafeOneLevelRelativePath(relative) else { return nil }
        let url = baseDirectory.appendingPathComponent(relative)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Fast hot-path side-asset URL hydration. Trust safe persisted one-level relative paths and
    /// avoid a filesystem stat. Cold playback accessors still call `resolvedDownloadAssetURL` when
    /// they must prove the file exists before opening it.
    private func fastResolvedDownloadAssetURL(_ relative: String?) -> URL? {
        guard let relative, Self.isSafeOneLevelRelativePath(relative) else { return nil }
        return baseDirectory.appendingPathComponent(relative)
    }

    /// Current records, absolute URLs re-resolved against the live container.
    ///
    /// This is a hot UI/startup path: `DownloadManager.refreshRecords()` may read it repeatedly while
    /// SwiftUI is creating the scene. Keep hydration cheap and avoid stat'ing every poster, BIF,
    /// trickplay tile, chapter image, and subtitle on each read; large headset libraries can carry
    /// enough sidecars to trip the scene-create watchdog.
    var records: [DownloadRecord] {
        lock.lock()
        let snapshot = Array(rows.values)
        lock.unlock()
        let hydrated = snapshot.map(hydratedRecord)
        return OfflineDownloadSort.sorted(hydrated)
    }

    /// Hydrate one indexed row without sorting or touching unrelated rows. Copy the value while
    /// holding the lock, then resolve its side assets after unlocking just like `records` does.
    func record(for ratingKey: String) -> DownloadRecord? {
        lock.lock()
        let row = rows[ratingKey]
        lock.unlock()
        return row.map(hydratedRecord)
    }

    func ownsAttempt(_ key: DownloadAttemptKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[key.ratingKey], row.attemptID == key.attemptID else { return false }
        return !Self.hasPendingRowDeletion(row)
    }

    /// P3b (rev 8): may new work start or continue for this exact attempt? Ownership alone is not
    /// enough: a deletion-pending capsule still owns its row and files (cleanup authority), but
    /// admits no transfer, finalizer, prep or season work.
    func attemptAdmitsWork(_ key: DownloadAttemptKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return attemptAdmitsWorkLocked(key)
    }

    /// Lock-held variant for store transactions (season apply) that already hold `lock`.
    private func attemptAdmitsWorkLocked(_ key: DownloadAttemptKey) -> Bool {
        guard let row = rows[key.ratingKey], row.attemptID == key.attemptID else { return false }
        return !Self.hasPendingRowDeletion(row) && !row.deletionPending
    }

    /// P3b (rev 9): phase-aware admission for a start chain that minted `attemptID` before the
    /// store owns it. Before the seed the key must be empty or held by the exact expected
    /// previous owner, which must itself admit work; after the seed the exact attempt must admit
    /// work. `createAttemptOwnedRecord`'s compare-and-swap stays authoritative.
    func startChainAdmits(ratingKey: String, attemptID: DownloadAttemptID,
                          expectedPreviousOwner: DownloadAttemptID?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[ratingKey] else { return true }
        guard let owner = row.attemptID else {
            // A legacy terminal row without an owner is replaced by an unowned compare-and-swap.
            return expectedPreviousOwner == nil && !row.deletionPending
                && !Self.hasPendingRowDeletion(row)
        }
        if owner == attemptID || owner == expectedPreviousOwner {
            return attemptAdmitsWorkLocked(DownloadAttemptKey(ratingKey: ratingKey, attemptID: owner))
        }
        return false
    }

    /// Where an attempt's row stands for server-cleanup eligibility (P2.2). Absence in memory is
    /// not proof of deletion: `executeRowDeletion` drops the row before its terminal revision
    /// commits and restores it if that commit fails, so that window and any staged deletion read
    /// as `.retiring`. `.unknown` covers a store whose index could not be opened as current, where
    /// an empty row map says nothing about what is durable.
    enum CleanupDisposition: Sendable, Equatable {
        case present(DownloadRecord)
        case retiring
        case committedAbsent
        case unknown
    }

    func cleanupDisposition(for key: DownloadAttemptKey) -> CleanupDisposition {
        lock.lock()
        guard startupSchemaProbe == .current || startupSchemaProbe == .missing else {
            lock.unlock()
            return .unknown
        }
        if artifactRetirementKeys.contains(key) {
            lock.unlock()
            return .retiring
        }
        guard let row = rows[key.ratingKey], row.attemptID == key.attemptID else {
            lock.unlock()
            return .committedAbsent
        }
        let stagedDeletion = row.deletionPending || row.pendingArtifactIntents.contains {
            if case .rowDeletion = $0.operation { return true }
            return false
        }
        lock.unlock()
        return stagedDeletion ? .retiring : .present(hydratedRecord(row))
    }

    /// What a truncation strike is counted against (R2-5). Unknown components stay nil so that
    /// only a proven change resets the count.
    static func truncationSourceKey(ratingKey: String, metadata: OfflineMetadata?)
        -> DownloadSourceKey {
        func nonEmpty(_ value: String?) -> String? {
            value?.isEmpty == false ? value : nil
        }
        return DownloadSourceKey(
            server: nonEmpty(metadata?.backendServerID) ?? nonEmpty(metadata?.backendBaseURLString),
            account: nonEmpty(metadata?.backendUserID),
            backend: metadata?.backendKind?.rawValue,
            item: ratingKey,
            source: nonEmpty(metadata?.mediaSourceID) ?? metadata?.sourcePartID.map(String.init),
            profile: nonEmpty(metadata?.requestedProfileLabel) ?? nonEmpty(metadata?.optimizeTargetName))
    }

    /// The exact attempt's truncation source key; nil for a stale or missing attempt.
    func truncationSourceKey(for key: DownloadAttemptKey) -> DownloadSourceKey? {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[key.ratingKey], row.attemptID == key.attemptID else { return nil }
        return Self.truncationSourceKey(ratingKey: key.ratingKey, metadata: row.metadata)
    }

    /// Persist one truncation strike for the exact attempt (deduplicated by `outcomeID`) and
    /// return the strike count it now carries; nil for a stale or missing attempt.
    func recordTruncationStrike(for key: DownloadAttemptKey, outcomeID: String) -> Int? {
        lock.lock()
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID else {
            lock.unlock()
            return nil
        }
        let (history, recorded) = row.history.recordingTruncation(
            outcomeID: outcomeID,
            source: Self.truncationSourceKey(ratingKey: key.ratingKey, metadata: row.metadata))
        if recorded {
            row.history = history
            setRowLocked(row, for: key.ratingKey)
            _ = enqueueAttemptPersistenceLocked()
        }
        let strikes = row.history.truncation?.strikes ?? 0
        lock.unlock()
        return strikes
    }

    func truncationStrikes(for key: DownloadAttemptKey) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[key.ratingKey], row.attemptID == key.attemptID else { return 0 }
        return row.history.truncation?.strikes ?? 0
    }

    /// A complete verdict, or a user cancel that re-downloads from scratch, clears the strikes.
    func clearTruncationStrikes(for key: DownloadAttemptKey) {
        lock.lock()
        if retiredTruncation[key.ratingKey]?.attemptID == key.attemptID {
            retiredTruncation.removeValue(forKey: key.ratingKey)
        }
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID,
              row.history.truncation != nil else {
            lock.unlock()
            return
        }
        row.history.truncation = nil
        setRowLocked(row, for: key.ratingKey)
        _ = enqueueAttemptPersistenceLocked()
        lock.unlock()
    }

    /// P3b: true while the index was loaded as v4 and has not been stamped v5 in this process.
    /// Until the stamp commits, the v4 file holds the latest committed v4 state (possibly with
    /// some removals already barriered or done); a relaunch reclassifies what remains. The manager runs the upgrade pass exactly when this holds.
    var requiresSchemaUpgrade: Bool {
        lock.withLock { loadedSchemaVersion < DownloadIndexCoding.currentSchemaVersion
            && indexSchemaVersion < DownloadIndexCoding.currentSchemaVersion }
    }

    /// P3b candidates, fixed when the upgrade pass starts (maintainer decision "keep partials"):
    /// every owned row that is not complete, unverified or paused on the static-range route, and
    /// is not already being deleted or publishing a legacy validated promotion.
    func schemaUpgradeCandidates() -> [DownloadAttemptKey] {
        lock.lock(); defer { lock.unlock() }
        return rows.values.compactMap { row -> DownloadAttemptKey? in
            guard let attemptID = row.attemptID else { return nil }
            switch row.lifecycle {
            case .complete, .unverified: return nil
            case .paused where row.metadata?.resolvedResumeMode(ratingKey: row.ratingKey)
                == .staticByteRange: return nil
            default: break
            }
            guard row.pendingValidatedPromotionStatus == nil, !row.deletionPending,
                  !Self.hasPendingRowDeletion(row) else { return nil }
            return DownloadAttemptKey(ratingKey: row.ratingKey, attemptID: attemptID)
        }.sorted { $0.ratingKey < $1.ratingKey }
    }

    /// P3b rescue rule (rev 10): a candidate is spared only if transport has since completed it.
    func schemaUpgradeRescues(_ key: DownloadAttemptKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[key.ratingKey], row.attemptID == key.attemptID else { return true }
        return row.lifecycle == .complete || row.lifecycle == .unverified
    }

    /// P3b stamp: every snapshot enqueued from now on is v5. Unverified rows without a recorded
    /// reason get `migratedUnknown` in the same snapshot. Not awaited by the caller: a failed
    /// commit stays dirty for the ordinary writer, and a crash leaves the latest committed v4
    /// state (no row created after the upgrade), so the next launch reclassifies what remains.
    @discardableResult
    func stampSchemaV5() -> PersistenceTicket {
        lock.lock(); defer { lock.unlock() }
        for (ratingKey, var row) in rows
        where row.lifecycle == .unverified && row.history.unverifiedReason == nil {
            row.history.unverifiedReason = .migratedUnknown
            setRowLocked(row, for: ratingKey)
        }
        indexSchemaVersion = DownloadIndexCoding.currentSchemaVersion
        return enqueuePersistenceLocked()
    }

    /// The exact attempt's P3a lifecycle and history.
    func lifecycleState(for key: DownloadAttemptKey) -> DownloadLifecycleState? {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[key.ratingKey], row.attemptID == key.attemptID else { return nil }
        return DownloadLifecycleState(lifecycle: row.lifecycle, history: row.history)
    }

    func isDeletionPending(for key: DownloadAttemptKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[key.ratingKey], row.attemptID == key.attemptID else { return false }
        return row.deletionPending
    }

    func isDeletionPending(ratingKey: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return rows[ratingKey]?.deletionPending == true
    }

    func deletionPendingCleanupIntents(
        for key: DownloadAttemptKey
    ) -> [DurableDownloadCleanupIntent]? {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[key.ratingKey], row.attemptID == key.attemptID,
              row.deletionPending else { return nil }
        return row.deletionPendingCleanupIntents
    }

    /// Reserve exact row metadata as the durable cleanup authority before a failed journal write
    /// can lead to destructive local deletion. Repeating after an ambiguous index failure retries
    /// the dirty full snapshot and returns success only once the pending bit is proven durable.
    @discardableResult
    func markDeletionPending(
        for key: DownloadAttemptKey,
        cleanupIntents: [DurableDownloadCleanupIntent]
    ) -> AttemptMutationResult {
        awaitAttemptMutationSubmission(
            submitDeletionPending(for: key, cleanupIntents: cleanupIntents)
        )
    }

    /// Nonblocking reservation half of deletion ordering. Destructive work still must not start
    /// until a bounded flush proves this exact ticket committed.
    @discardableResult
    func submitDeletionPending(
        for key: DownloadAttemptKey,
        cleanupIntents: [DurableDownloadCleanupIntent]
    ) -> AttemptMutationSubmission {
        guard !cleanupIntents.isEmpty,
              cleanupIntents.allSatisfy({ $0.attemptKey == key }) else {
            return .staleOrMissing
        }
        lock.lock()
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID,
              row.pendingValidatedPromotionStatus == nil else {
            lock.unlock()
            return .staleOrMissing
        }
        if row.deletionPending {
            // The first durable reservation is authoritative. A retry may rebuild candidates with
            // fresh UUIDs; never replace exact crash-recovery authority once captured.
            let ticket = enqueueAttemptPersistenceLocked()
            lock.unlock()
            return .accepted(change: .noChange, ticket: ticket)
        }
        row.deletionPending = true
        row.deletionPendingCleanupIntents = cleanupIntents
        setRowLocked(row, for: key.ratingKey)
        let ticket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        return .accepted(change: .applied, ticket: ticket)
    }

    func record(for key: DownloadAttemptKey) -> DownloadRecord? {
        lock.lock()
        let row = rows[key.ratingKey]?.attemptID == key.attemptID ? rows[key.ratingKey] : nil
        lock.unlock()
        return row.map(hydratedRecord)
    }

    /// Reuse only a non-empty regular side-asset file that the exact live attempt already owns in
    /// metadata. A deterministic destination on disk is not sufficient by itself: an orphan or a
    /// previous attempt may have left the same filename behind. Keeping this check attempt-scoped
    /// lets retry/handoff hydration skip durable successes without adopting stale files.
    func reusableSideAssetRelativePath(for key: DownloadAttemptKey,
                                       destination: URL) -> String? {
        let snapshot = lock.withLock { (rows[key.ratingKey], rowMutationGenerations[key.ratingKey, default: 0]) }
        guard let row = snapshot.0, row.attemptID == key.attemptID,
              !row.deletionPending else { return nil }
        guard let metadata = row.metadata,
              metadata.sideAssetBundleOwner == OfflineSideAssetBundleOwner(
                attemptID: key.attemptID.rawValue,
                source: metadata.sideAssetSourceIdentity) else { return nil }
        let relative = destination.lastPathComponent
        guard Self.isSafeOneLevelRelativePath(relative),
              destination.deletingLastPathComponent().standardizedFileURL
                == baseDirectory.standardizedFileURL,
              sideAssetRelativePaths(for: metadata).contains(relative),
              let attributes = try? storeFilesystem.attributes(atPath: destination.path, using: fileManager),
              attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.uint64Value ?? 0) > 0 else { return nil }
        return lock.withLock {
            rowMutationGenerations[key.ratingKey, default: 0] == snapshot.1 ? relative : nil
        }
    }

    /// Raw persisted metadata for callers that do not need a hydrated `DownloadRecord`.
    func metadata(for ratingKey: String) -> OfflineMetadata? {
        lock.lock(); defer { lock.unlock() }
        return rows[ratingKey]?.metadata
    }

    func sideAssetSourceIdentity(
        for key: DownloadAttemptKey
    ) -> OfflineSideAssetSourceIdentity? {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[key.ratingKey], row.attemptID == key.attemptID,
              !Self.hasPendingRowDeletion(row) else { return nil }
        return row.metadata?.sideAssetSourceIdentity
    }

    /// Persisted media duration in milliseconds, without hydrating the row.
    func duration(for ratingKey: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return rows[ratingKey]?.metadata?.duration
    }

    /// O(1) row ownership/membership check that does not hydrate or sort the Offline library.
    func contains(ratingKey: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return rows[ratingKey] != nil
    }

    /// The set of indexed ratingKeys, WITHOUT touching the filesystem. Use this when
    /// you only need to test membership (e.g. reattach matching) and don't want the
    /// per-row poster `fileExists` cost that `records` pays.
    var allRatingKeys: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(rows.keys)
    }

    /// Lightweight status lookup for delegate/IO race decisions that must not pay the full
    /// `records` hydration cost (poster/chapter/trickplay file stats) just to distinguish a user
    /// pause from a delete/cancel.
    func status(for ratingKey: String) -> DownloadStatus? {
        lock.lock(); defer { lock.unlock() }
        return rows[ratingKey]?.status
    }

    private func hydratedRecord(_ row: Row) -> DownloadRecord {
        let sideAssets = hydratedSideAssets(for: row)
        return DownloadRecord(ratingKey: row.ratingKey,
                              attemptID: row.attemptID,
                              title: row.title,
                              localURL: baseDirectory.appendingPathComponent(row.relativePath),
                              bytes: row.bytes,
                              progress: row.progress,
                              status: row.status,
                              metadata: row.metadata,
                              lifecycle: row.lifecycle,
                              admissionIntent: row.history.admissionIntent,
                              posterURL: sideAssets.posterURL,
                              plexBIFURL: sideAssets.plexBIFURL,
                              embyBIFURL: sideAssets.embyBIFURL,
                              jellyfinTrickPlayPlaylistURL: sideAssets.jellyfinTrickPlayPlaylistURL,
                              chapterImageURLs: sideAssets.chapterImageURLs,
                              sideAssetBytes: sideAssets.sideAssetBytes)
    }

    /// Absolute destinations for indexed rows, regardless of status. Used when rebinding
    /// background URLSession tasks after relaunch: the persisted row knows the real extension
    /// (`.mp4`, `.mkv`, etc.), while a resumed task URL may not carry enough information.
    var destinationsByRatingKey: [String: URL] {
        lock.lock(); defer { lock.unlock() }
        return rows.mapValues { baseDirectory.appendingPathComponent($0.relativePath) }
    }

    /// Privacy-safe storage accounting for diagnostics/settings (#171). This reports aggregate
    /// bytes and conservative orphan candidates only; it does not delete anything.
    func storageAudit(inFlightRelativePaths: Set<String> = []) -> OfflineDownloadStorageAudit {
        lock.lock()
        let referenced = Set(rows.values.flatMap { artifactPathsReferenced(by: $0) })
            .union(reservedArtifactDeletionPaths.keys).union(reservedHeldBodyDeletionPaths.keys)
        lock.unlock()
        let files = directoryFileSnapshots()
        return OfflineDownloadFileInventory.audit(directoryFiles: files,
                                                  referencedRelativePaths: referenced,
                                                  inFlightRelativePaths: inFlightRelativePaths)
    }

    /// Absolute local URL for a completed download, if indexed AND present on disk.
    func localURL(for ratingKey: String) -> URL? {
        let snapshot = lock.withLock { (rows[ratingKey], rowMutationGenerations[ratingKey, default: 0]) }
        guard let row = snapshot.0, row.status == .complete || row.status == .unverified else { return nil }
        guard Self.isSafeOneLevelRelativePath(row.relativePath) else { return nil }
        let url = baseDirectory.appendingPathComponent(row.relativePath)
        let value = fileManager.fileExists(atPath: url.path) ? url : nil
        return lock.withLock { rowMutationGenerations[ratingKey, default: 0] == snapshot.1 ? value : nil }
    }

    /// Absolute local Plex BIF cache URL for a completed download, if present on disk.
    func plexBIFURL(for ratingKey: String) -> URL? {
        let snapshot = lock.withLock { (rows[ratingKey], rowMutationGenerations[ratingKey, default: 0]) }
        guard let row = snapshot.0, row.status == .complete || row.status == .unverified else { return nil }
        let value = resolvedDownloadAssetURL(row.metadata?.plexBIFRelativePath)
        return lock.withLock { rowMutationGenerations[ratingKey, default: 0] == snapshot.1 ? value : nil }
    }

    /// Absolute local Emby BIF cache URL for a completed download, if present on disk.
    func embyBIFURL(for ratingKey: String) -> URL? {
        let snapshot = lock.withLock { (rows[ratingKey], rowMutationGenerations[ratingKey, default: 0]) }
        guard let row = snapshot.0, row.status == .complete || row.status == .unverified else { return nil }
        let value = resolvedDownloadAssetURL(row.metadata?.embyBIFRelativePath)
        return lock.withLock { rowMutationGenerations[ratingKey, default: 0] == snapshot.1 ? value : nil }
    }

    /// Absolute local Jellyfin trickplay playlist URL for a completed download, if present on disk.
    func jellyfinTrickPlayPlaylistURL(for ratingKey: String) -> URL? {
        let snapshot = lock.withLock { (rows[ratingKey], rowMutationGenerations[ratingKey, default: 0]) }
        guard let row = snapshot.0, row.status == .complete || row.status == .unverified else { return nil }
        let value = resolvedDownloadAssetURL(row.metadata?.jellyfinTrickPlayPlaylistRelativePath)
        return lock.withLock { rowMutationGenerations[ratingKey, default: 0] == snapshot.1 ? value : nil }
    }

    /// Absolute cached per-chapter image URLs (chapter index → file) for a completed download,
    /// limited to files that still exist on disk (#88/#89).
    func chapterImageURLs(for ratingKey: String) -> [Int: URL] {
        let snapshot = lock.withLock { (rows[ratingKey], rowMutationGenerations[ratingKey, default: 0]) }
        guard let row = snapshot.0, row.status == .complete || row.status == .unverified else { return [:] }
        let value = Self.resolvedChapterImageURLs(row.metadata?.chapterImageRelativePaths,
                                             baseDirectory: baseDirectory,
                                             fileManager: fileManager)
        return lock.withLock { rowMutationGenerations[ratingKey, default: 0] == snapshot.1 ? value : [:] }
    }

    private static func resolvedChapterImageURLs(_ relatives: [Int: String]?,
                                                 baseDirectory: URL,
                                                 fileManager: FileManager) -> [Int: URL] {
        guard let relatives else { return [:] }
        var out: [Int: URL] = [:]
        for (index, relative) in relatives where isSafeOneLevelRelativePath(relative) {
            let url = baseDirectory.appendingPathComponent(relative)
            if fileManager.fileExists(atPath: url.path) { out[index] = url }
        }
        return out
    }

    private static func fastResolvedChapterImageURLs(_ relatives: [Int: String]?,
                                                     baseDirectory: URL) -> [Int: URL] {
        guard let relatives else { return [:] }
        var out: [Int: URL] = [:]
        for (index, relative) in relatives where isSafeOneLevelRelativePath(relative) {
            out[index] = baseDirectory.appendingPathComponent(relative)
        }
        return out
    }

    private static func isSafeOneLevelRelativePath(_ relative: String) -> Bool {
        !relative.isEmpty
            && !relative.contains("/")
            && !relative.contains("\\")
            && !relative.contains("\0")
            && relative != "."
            && relative != ".."
    }

    private func sideAssetRelativePaths(for metadata: OfflineMetadata?) -> [String] {
        guard let metadata else { return [] }
        var relatives: [String] = []
        relatives.append(contentsOf: [
            metadata.posterRelativePath,
            metadata.plexBIFRelativePath,
            metadata.embyBIFRelativePath,
            metadata.jellyfinTrickPlayPlaylistRelativePath,
        ].compactMap { $0 })
        relatives.append(contentsOf: metadata.jellyfinTrickPlayTileRelativePaths ?? [])
        relatives.append(contentsOf: Array(metadata.chapterImageRelativePaths?.values ?? Dictionary<Int, String>().values))
        relatives.append(contentsOf: metadata.offlineTextSubtitles?.map(\.relativePath) ?? [])
        return relatives.filter(Self.isSafeOneLevelRelativePath)
    }

    /// Best-effort physical retirement after the replacement metadata snapshot is durable. The
    /// exact current attempt is revalidated under the same lock used by promotion, and paths are
    /// reserved while deleting so no later row mutation can republish a predecessor bundle. A
    /// crash or filesystem error may leave an unreferenced orphan, but can never make it playable;
    /// the ordinary storage inventory remains the conservative orphan cleanup authority.
    private func retireUnreferencedSideAssets(
        _ relativePaths: Set<String>,
        confirmingCurrentOwner key: DownloadAttemptKey
    ) {
        let requested = relativePaths.filter(Self.isSafeOneLevelRelativePath)
        guard !requested.isEmpty else { return }
        let retirementID = UUID()
        let candidates: [String]? = lock.withLock { () -> [String]? in
            guard rows[key.ratingKey]?.attemptID == key.attemptID else { return nil }
            var referenced: Set<String> = []
            for row in rows.values { referenced.formUnion(artifactPathsReferenced(by: row)) }
            let selected = requested.filter {
                !referenced.contains($0) && reservedArtifactDeletionPaths[$0] == nil
            }
            for path in selected { reservedArtifactDeletionPaths[path] = retirementID }
            return Array(selected)
        }
        guard let candidates else { return }
        for path in candidates {
            try? fileManager.removeItem(at: baseDirectory.appendingPathComponent(path))
        }
        lock.withLock {
            for path in candidates where reservedArtifactDeletionPaths[path] == retirementID {
                reservedArtifactDeletionPaths.removeValue(forKey: path)
            }
        }
    }

    private func hydratedSideAssets(for row: Row) -> HydratedSideAssets {
        let ratingKey = row.ratingKey
        let metadata = row.metadata
        let attemptID = row.attemptID
        let source = metadata?.sideAssetSourceIdentity
        let generation = row.sideAssetGeneration
        lock.lock()
        if let cached = sideAssetHydrationCache[ratingKey],
           cached.attemptID == attemptID,
           cached.source == source,
           cached.generation == generation {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let relatives = sideAssetRelativePaths(for: metadata)
        let sideAssetBytes = relatives.reduce(0) { total, relative in
            let url = baseDirectory.appendingPathComponent(relative)
            let attrs = try? storeFilesystem.attributes(atPath: url.path, using: fileManager)
            return total + ((attrs?[.size] as? NSNumber)?.intValue ?? 0)
        }
        let hydrated = HydratedSideAssets(
            attemptID: attemptID,
            source: source,
            generation: generation,
            posterURL: fastResolvedDownloadAssetURL(metadata?.posterRelativePath),
            plexBIFURL: fastResolvedDownloadAssetURL(metadata?.plexBIFRelativePath),
            embyBIFURL: fastResolvedDownloadAssetURL(metadata?.embyBIFRelativePath),
            jellyfinTrickPlayPlaylistURL: fastResolvedDownloadAssetURL(metadata?.jellyfinTrickPlayPlaylistRelativePath),
            chapterImageURLs: Self.fastResolvedChapterImageURLs(metadata?.chapterImageRelativePaths,
                                                               baseDirectory: baseDirectory),
            sideAssetBytes: sideAssetBytes
        )
        lock.lock()
        if let current = rows[ratingKey],
           current.attemptID == attemptID,
           current.metadata?.sideAssetSourceIdentity == source,
           current.sideAssetGeneration == generation {
            sideAssetHydrationCache[ratingKey] = hydrated
        }
        lock.unlock()
        return hydrated
    }

    private func directoryFileSnapshots() -> [OfflineDownloadFileSnapshot] {
        storeFilesystem.before(.enumerate, baseDirectory)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsSubdirectoryDescendants]
        ) else { return [] }
        return urls.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return OfflineDownloadFileSnapshot(relativePath: url.lastPathComponent, byteCount: size)
        }
    }

    private func fileSize(at url: URL) -> Int? {
        guard let raw = (try? storeFilesystem.attributes(atPath: url.path, using: fileManager)[.size]) else {
            return nil
        }
        if let number = raw as? NSNumber {
            return number.intValue
        }
        if let int = raw as? Int {
            return int
        }
        if let int64 = raw as? Int64 {
            return Int(int64)
        }
        return nil
    }

    private func fileSize(relativePath: String) -> Int? {
        guard Self.isSafeOneLevelRelativePath(relativePath) else { return nil }
        return fileSize(at: baseDirectory.appendingPathComponent(relativePath))
    }

    /// The source's EXACT byte size when the row knows it (static-lane Content-Length /
    /// `sourcePartSize`), or nil. Unlike `expectedBytesEstimate` this never falls back to the
    /// ratio-derived estimate — callers use it to judge byte-completeness, where an estimate
    /// would misfire. Nil for non-static lanes: enqueue metadata records the SOURCE part size on
    /// every lane, but a transcode's finished output is legitimately smaller than its source, so
    /// only a byte-for-byte static download may be measured against this.
    func sourceExactBytes(ratingKey: String) -> Int? {
        // `rows` is shared with URLSession delegate callbacks; even read-only dictionary lookups
        // must take the lock while downloads are actively mutating the store. A headset crash
        // (Labstream-2026-07-08-235111.ips) showed this racing the range progress delegate during
        // the completed-size audit, corrupting the dictionary bridge and aborting in
        // `Dictionary._Variant.lookup`.
        lock.lock()
        let row = rows[ratingKey]
        lock.unlock()
        guard let row,
              let metadata = row.metadata,
              metadata.resolvedResumeMode(ratingKey: ratingKey) == .staticByteRange,
              let size = metadata.sourcePartSize, size > 0 else { return nil }
        return size
    }

    /// Exact-owner source size. A stale/reset-pending caller receives nil rather than observing a
    /// replacement row that happens to share its rating key.
    func sourceExactBytes(for key: DownloadAttemptKey) -> Int? {
        lock.lock()
        let row = rows[key.ratingKey]
        lock.unlock()
        guard let row, row.attemptID == key.attemptID,
              let metadata = row.metadata,
              metadata.resolvedResumeMode(ratingKey: key.ratingKey) == .staticByteRange,
              let size = metadata.sourcePartSize, size > 0 else { return nil }
        return size
    }

    func sourcePartSize(for key: DownloadAttemptKey) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[key.ratingKey], row.attemptID == key.attemptID,
              let size = row.metadata?.sourcePartSize,
              size > 0 else { return nil }
        return size
    }

    private static func expectedBytesEstimate(row: Row) -> Int? {
        if let sourcePartSize = row.metadata?.sourcePartSize, sourcePartSize > 0 {
            return sourcePartSize
        }
        guard row.bytes > 0, row.progress > 0.0001 else { return nil }
        let expected = Int((Double(row.bytes) / min(row.progress, 1.0)).rounded())
        return expected > 0 ? expected : nil
    }

    private static func progressForDurableBytes(_ bytes: Int, expectedBytes: Int?) -> Double {
        guard let expectedBytes, expectedBytes > 0 else { return 0 }
        return min(1.0, Double(bytes) / Double(expectedBytes))
    }

    /// Insert/replace a record. `localURL` must live under `baseDirectory`.
    ///
    /// D5: preserves an already-stored `metadata` snapshot if the incoming record
    /// doesn't carry one — the pipeline upserts the same row several times (seed,
    /// then with the resolved destination) and we don't want a later, leaner upsert
    /// to wipe the metadata/poster captured earlier.
    func upsert(_ record: DownloadRecord) {
        lock.lock()
        let rel = record.localURL.lastPathComponent
        let existing = rows[record.ratingKey]
        let incomingAttemptID = record.attemptID ?? existing?.attemptID
        var incomingPaths: Set<String> = [rel]
        incomingPaths.formUnion(sideAssetRelativePaths(for: record.metadata))
        if let resume = record.metadata?.resumeDataRelativePath { incomingPaths.insert(resume) }
        incomingPaths.formUnion((record.metadata?.heldRangeSegments ?? []).map(\.relativePath))
        if record.status != .complete && record.status != .unverified,
           let incomingAttemptID {
            incomingPaths.insert(Self.attemptStagingRelativePath(
                for: DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: incomingAttemptID),
                stableRelativePath: rel))
        }
        // Legacy/unconditional writers may not erase a validated-publication or deletion
        // reservation. A deletion-pending row is the only durable cleanup authority when the
        // standalone journal is unavailable.
        guard existing?.pendingValidatedPromotionStatus == nil,
              existing?.deletionPending != true,
              existing?.heldRangeBodyDeletionIntents.isEmpty != false,
              existing?.pendingArtifactIntents.isEmpty != false,
              incomingPaths.allSatisfy({ reservedArtifactDeletionPaths[$0] == nil }) else {
            lock.unlock()
            return
        }
        let attemptID = record.attemptID ?? existing?.attemptID
        var metadata = record.metadata ?? existing?.metadata
        let previousSideAssetPaths = Set(sideAssetRelativePaths(for: existing?.metadata))
        if var incoming = record.metadata, let previous = existing?.metadata {
            incoming.preserveCachedSideAssets(
                from: previous, attemptID: attemptID?.rawValue)
            metadata = incoming
        }
        if let attemptID {
            if existing == nil {
                metadata?.claimCachedSideAssets(attemptID: attemptID.rawValue)
            } else {
                metadata?.fenceCachedSideAssets(to: attemptID.rawValue)
            }
            metadata?.downloadAttemptID = attemptID.rawValue
        } else {
            metadata?.clearCachedSideAssets()
        }
        let retiredSideAssetPaths = previousSideAssetPaths
            .subtracting(sideAssetRelativePaths(for: metadata))
        rowMutationGenerations[record.ratingKey, default: 0] &+= 1
        rows[record.ratingKey] = Row(ratingKey: record.ratingKey,
                                     attemptID: attemptID,
                                     title: record.title,
                                     relativePath: rel,
                                     attemptWorkingRelativePath: (record.status == .complete
                                        || record.status == .unverified) ? nil : attemptID.map {
                                        Self.attemptStagingRelativePath(
                                            for: DownloadAttemptKey(
                                                ratingKey: record.ratingKey, attemptID: $0),
                                            stableRelativePath: rel) },
                                     bytes: record.bytes,
                                     progress: record.progress,
                                     status: record.status,
                                     metadata: metadata,
                                     heldRangeBodyDeletionIntents: existing?.heldRangeBodyDeletionIntents ?? [],
                                     sideAssetGeneration: existing?.sideAssetGeneration ?? 0)
        sideAssetHydrationCache.removeValue(forKey: record.ratingKey)
        lock.unlock()
        let persistence = persist()
        if persistence.result.committed(through: persistence.ticket), let attemptID {
            retireUnreferencedSideAssets(
                retiredSideAssetPaths,
                confirmingCurrentOwner: DownloadAttemptKey(
                    ratingKey: record.ratingKey, attemptID: attemptID))
        }
    }

    enum SeasonPlanStoreApplyResult: Sendable, Equatable {
        case applied(inserted: Int, retried: Int)
        case staleInput
        case persistenceFailed
        case persistenceIndeterminate
    }

    /// Atomically publish new rows and mark exact failed attempts for retry in one schema-v4
    /// snapshot. The complete plan becomes visible to readers in one locked mutation whose full
    /// snapshot is submitted under the same lock hold, so no reader observes a partial plan and
    /// no other writer's snapshot interleaves with it. Waiting for durability happens after the
    /// lock is released (see `enqueueAttemptPersistenceLocked`); callers must not admit
    /// network/server work for the plan unless this returns `.applied`, and a failed outcome is
    /// compensated conditionally so concurrent mutations made during the wait survive.
    func applySeasonPlanAtomically(
        newRecords records: [DownloadRecord],
        retryAttempts: [DownloadAttemptKey]
    ) -> SeasonPlanStoreApplyResult {
        guard !records.isEmpty || !retryAttempts.isEmpty else {
            return .applied(inserted: 0, retried: 0)
        }
        // Pre-plan authority is captured before the lock: it only classifies a failed rollback,
        // and that classification tolerates a stale copy (a mismatch degrades to indeterminate).
        let oldIndexData = try? Data(contentsOf: indexURL)
        let oldIndexWasMissing = oldIndexData == nil && !fileManager.fileExists(atPath: indexURL.path)
        lock.lock()
        let keys = records.map(\.ratingKey)
        let retryKeys = retryAttempts.map(\.ratingKey)
        guard Set(keys).count == keys.count,
              Set(retryKeys).count == retryKeys.count,
              Set(keys).isDisjoint(with: Set(retryKeys)),
              records.allSatisfy({ $0.attemptID != nil && rows[$0.ratingKey] == nil }),
              retryAttempts.allSatisfy({ key in
                  guard let row = rows[key.ratingKey] else { return false }
                  return row.attemptID == key.attemptID
                      && row.status == .failed
                      && row.metadata != nil
                      // P3b: a row being deleted (barrier or capsule) is never re-planned.
                      && attemptAdmitsWorkLocked(key)
              }) else {
            lock.unlock()
            return .staleInput
        }
        var priorRetryAdmissionIntents: [DownloadAttemptKey: DownloadAdmissionIntent?] = [:]
        for record in records {
            guard let row = Self.seasonPlannedRow(for: record) else { continue }
            setRowLocked(row, for: record.ratingKey)
            sideAssetHydrationCache.removeValue(forKey: record.ratingKey)
        }
        for key in retryAttempts {
            guard var row = rows[key.ratingKey] else { continue }
            // updateValue, not subscript assignment: a nil prior intent must be stored as an entry
            // holding nil (restore-to-nil), which the subscript setter would instead drop.
            priorRetryAdmissionIntents.updateValue(row.history.admissionIntent, forKey: key)
            // P4: a failed row the planner includes waits for an admission lane as a retry.
            row.history.admissionIntent = .retryRequested
            setRowLocked(row, for: key.ratingKey)
        }
        let candidateSnapshot = IndexSnapshot(schemaVersion: indexSchemaVersion, rows: Array(rows.values))
        nextPersistenceRevision += 1
        let ticket = PersistenceTicket(revision: nextPersistenceRevision)
        indexWriter.submit(revision: ticket.revision, snapshot: candidateSnapshot)
        lock.unlock()

        let writerResult = indexWriter.waitSynchronouslyForOutcome(through: ticket.revision)
        if Self.mapPersistenceResult(writerResult).committed(through: ticket) {
            return .applied(inserted: records.count, retried: retryAttempts.count)
        }
        // Atomic replacement can succeed and then surface an error. Encoding is deterministic
        // (`sortedKeys` over the exact submitted snapshot value), so byte equality proves the
        // candidate is already durable; keep the published plan rather than compensating it away.
        let candidateData = try? DownloadIndexCoding.encode(
            candidateSnapshot.rows, schemaVersion: candidateSnapshot.schemaVersion)
        if let candidateData, (try? Data(contentsOf: indexURL)) == candidateData {
            return .applied(inserted: records.count, retried: retryAttempts.count)
        }
        // Genuine failure: withdraw exactly the plan's own effects. Every compensation is
        // conditional on the exact attempt so mutations that interleaved during the off-lock
        // wait are never clobbered, then the rollback snapshot supersedes the writer's dirty
        // candidate so a future flush retries current authority, not an unreported season plan.
        lock.lock()
        withdrawSeasonPlanLocked(records: records, priorRetryAdmissionIntents: priorRetryAdmissionIntents)
        let rollbackTicket = enqueuePersistenceLocked()
        lock.unlock()
        let rollbackResult = indexWriter.waitSynchronouslyForOutcome(through: rollbackTicket.revision)
        if Self.mapPersistenceResult(rollbackResult).committed(through: rollbackTicket) {
            return .persistenceFailed
        }
        let durableBytes = try? Data(contentsOf: indexURL)
        if let candidateData, durableBytes == candidateData {
            // The plan is durable after all. Re-publish it (conditionally, for the same reason as
            // above) and make current memory the writer's newest dirty authority so a later flush
            // cannot replay the failed rollback over the durable candidate.
            lock.lock()
            for record in records {
                guard rows[record.ratingKey] == nil,
                      let row = Self.seasonPlannedRow(for: record) else { continue }
                setRowLocked(row, for: record.ratingKey)
                sideAssetHydrationCache.removeValue(forKey: record.ratingKey)
            }
            for key in retryAttempts {
                guard var row = rows[key.ratingKey], row.attemptID == key.attemptID,
                      row.lifecycle == .failed else { continue }
                row.history.admissionIntent = .retryRequested
                setRowLocked(row, for: key.ratingKey)
            }
            _ = enqueuePersistenceLocked()
            lock.unlock()
            return .applied(inserted: records.count, retried: retryAttempts.count)
        }
        if durableBytes == oldIndexData
            || (oldIndexWasMissing && !fileManager.fileExists(atPath: indexURL.path)) {
            return .persistenceFailed
        }
        // Neither authority can be proven. Mark startup admission unreadable so the manager
        // can stop the queue rather than report an ordinary save failure and continue.
        lock.lock()
        seasonCommitIndeterminate = true
        lock.unlock()
        return .persistenceIndeterminate
    }

    private static func seasonPlannedRow(for record: DownloadRecord) -> Row? {
        guard let attemptID = record.attemptID else { return nil }
        let relativePath = record.localURL.lastPathComponent
        var metadata = record.metadata
        metadata?.downloadAttemptID = attemptID.rawValue
        return Row(
            ratingKey: record.ratingKey,
            attemptID: attemptID,
            title: record.title,
            relativePath: relativePath,
            attemptWorkingRelativePath: Self.attemptStagingRelativePath(
                for: DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: attemptID),
                stableRelativePath: relativePath),
            bytes: 0,
            progress: 0,
            status: record.status,
            metadata: metadata,
            heldRangeBodyDeletionIntents: [])
    }

    /// Must be called with `lock` held. Removes the plan's inserted rows and restores retry rows'
    /// prior admission intents, each only while the row still belongs to the plan's exact attempt
    /// and still carries the plan's own change (a concurrent pause, retry or delete wins).
    private func withdrawSeasonPlanLocked(
        records: [DownloadRecord],
        priorRetryAdmissionIntents: [DownloadAttemptKey: DownloadAdmissionIntent?]
    ) {
        for record in records {
            guard let attemptID = record.attemptID,
                  rows[record.ratingKey]?.attemptID == attemptID else { continue }
            rowMutationGenerations[record.ratingKey, default: 0] &+= 1
            rows.removeValue(forKey: record.ratingKey)
            sideAssetHydrationCache.removeValue(forKey: record.ratingKey)
        }
        for (key, priorIntent) in priorRetryAdmissionIntents {
            guard var row = rows[key.ratingKey], row.attemptID == key.attemptID,
                  row.lifecycle == .failed,
                  row.history.admissionIntent == .retryRequested else { continue }
            row.history.admissionIntent = priorIntent
            setRowLocked(row, for: key.ratingKey)
        }
    }

    /// Compatibility wrapper for callers that only create new rows.
    func createSeasonPlannedRecordsAtomically(_ records: [DownloadRecord]) -> Bool {
        guard case .applied = applySeasonPlanAtomically(
            newRecords: records, retryAttempts: []) else { return false }
        return true
    }

    /// Create (or retry persistence of) a row owned by one exact attempt. A different existing
    /// owner is never overwritten. `.failed` means the in-memory full snapshot remains dirty, but
    /// the caller must not create/register URLSession work until a later call returns `.committed`.
    @discardableResult
    func createAttemptOwnedRecordOnWorker(
        _ record: DownloadRecord,
        attemptID: DownloadAttemptID,
        replacing expectedPreviousOwner: DownloadAttemptID? = nil,
        expectedGeneration: UInt64? = nil
    ) -> AttemptRecordCreateResult {
        let key = DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: attemptID)
        var handoffLease: DownloadPathLease?
        defer { if let handoffLease { releasePathLease(handoffLease) } }
        lock.lock()
        let existing = rows[record.ratingKey]
        if let expectedGeneration, rowMutationGenerations[record.ratingKey, default: 0] != expectedGeneration {
            lock.unlock()
            return .rejectedOwnership(expectedPreviousOwner: expectedPreviousOwner.map {
                DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: $0)
            }, actualOwner: existing?.attemptID.map {
                DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: $0)
            }, reason: .ownerMismatch)
        }
        let expectedKey = expectedPreviousOwner.map {
            DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: $0)
        }
        let existingKey = existing?.attemptID.map {
            DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: $0)
        }
        let relativePath = record.localURL.lastPathComponent
        var incomingPaths: Set<String> = [relativePath]
        incomingPaths.insert(Self.attemptStagingRelativePath(
            for: key, stableRelativePath: relativePath))
        incomingPaths.formUnion(sideAssetRelativePaths(for: record.metadata))
        if let resume = record.metadata?.resumeDataRelativePath { incomingPaths.insert(resume) }
        incomingPaths.formUnion((record.metadata?.heldRangeSegments ?? []).map(\.relativePath))
        if !incomingPaths.allSatisfy({ Self.isSafeOneLevelRelativePath($0) && reservedArtifactDeletionPaths[$0] == nil }) {
            lock.unlock()
            return .rejectedOwnership(
                expectedPreviousOwner: expectedKey,
                actualOwner: existingKey,
                reason: .artifactLifecyclePending
            )
        }
        if existing?.pendingValidatedPromotionStatus != nil {
            lock.unlock()
            return .rejectedOwnership(
                expectedPreviousOwner: expectedKey,
                actualOwner: existingKey,
                reason: .validatedPromotionPending
            )
        }
        if existing?.deletionPending == true {
            lock.unlock()
            return .rejectedOwnership(
                expectedPreviousOwner: expectedKey,
                actualOwner: existingKey,
                reason: .deletionPending
            )
        }
        if existing?.heldRangeBodyDeletionIntents.isEmpty == false {
            lock.unlock()
            return .rejectedOwnership(
                expectedPreviousOwner: expectedKey,
                actualOwner: existingKey,
                reason: .heldBodyDeletionPending
            )
        }
        if existing?.pendingArtifactIntents.isEmpty == false {
            lock.unlock()
            return .rejectedOwnership(
                expectedPreviousOwner: expectedKey,
                actualOwner: existingKey,
                reason: .artifactLifecyclePending
            )
        }
        // Same-ID replay is the only retry allowed after an ambiguous/failed commit. Otherwise a
        // replacement must compare-and-swap the exact owner captured when the start was acquired.
        if existing?.attemptID != attemptID {
            let rejection: AttemptRecordCreateRejection?
            if existing == nil, expectedPreviousOwner != nil {
                rejection = .missingExpectedOwner
            } else if let expectedPreviousOwner,
                      existing?.attemptID == expectedPreviousOwner {
                rejection = nil
            } else if existing == nil, expectedPreviousOwner == nil {
                rejection = nil
            } else {
                rejection = .ownerMismatch
            }
            if let rejection {
                lock.unlock()
                return .rejectedOwnership(
                    expectedPreviousOwner: expectedKey,
                    actualOwner: existingKey,
                    reason: rejection
                )
            }
        }
        let rel = record.localURL.lastPathComponent
        let previous = existing
        var metadata = record.metadata ?? previous?.metadata
        let previousSideAssetPaths = Set(sideAssetRelativePaths(for: previous?.metadata))
        if var incoming = record.metadata, let oldMetadata = previous?.metadata {
            incoming.preserveCachedSideAssets(
                from: oldMetadata, attemptID: attemptID.rawValue)
            metadata = incoming
        }
        if previous == nil {
            metadata?.claimCachedSideAssets(attemptID: attemptID.rawValue)
        } else {
            metadata?.fenceCachedSideAssets(to: attemptID.rawValue)
        }
        metadata?.downloadAttemptID = attemptID.rawValue
        let retiredSideAssetPaths = previousSideAssetPaths
            .subtracting(sideAssetRelativePaths(for: metadata))
        let newWorkingRelative = Self.attemptStagingRelativePath(
            for: key, stableRelativePath: rel)
        var oldWorkingURLToRemove: URL?
        var inheritedDurableBytes: Int?
        // A manual Retry/launch resume intentionally changes attempt identity. For a static-range
        // row, ownership can change without throwing away its multi-GB durable checkpoint: clone
        // the old private body to the new private path before committing the new owner. The old
        // body remains until the new index snapshot is durable, so a failed/ambiguous commit is
        // safe for both the current process and relaunch.
        // A body finalization condemned as truncated is never a checkpoint (P3a): Retry
        // downloads again from zero even while that body's deletion waits for its commit.
        if existing?.attemptID != attemptID,
           let expectedPreviousOwner,
           previous?.history.lastFailure != .truncated,
           previous?.history.isBodyCondemned != true,
           previous?.metadata?.resolvedResumeMode(ratingKey: record.ratingKey) == .staticByteRange,
           metadata?.resolvedResumeMode(ratingKey: record.ratingKey) == .staticByteRange,
           let previous,
           let oldWorkingRelative = workingRelativePath(
                for: previous,
                key: DownloadAttemptKey(
                    ratingKey: record.ratingKey, attemptID: expectedPreviousOwner)) {
            let oldKey = DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: expectedPreviousOwner)
            let temporary = ".\(newWorkingRelative).checkpoint-\(UUID().uuidString)"
            let paths: Set<String> = [oldWorkingRelative, newWorkingRelative, temporary]
            let capturedGeneration = rowMutationGenerations[record.ratingKey, default: 0]
            lock.unlock()
            // A busy physical writer conservatively defers Retry; a timed-out caller never owns
            // that writer's lease. No partial clone can install a successor.
            guard case .acquired(let lease) = tryAcquirePathLease(for: oldKey, relativePaths: paths,
                                                                 purpose: .checkpointHandoff) else {
                return .rejectedOwnership(expectedPreviousOwner: expectedKey, actualOwner: existingKey,
                                          reason: .checkpointHandoffFailed)
            }
            handoffLease = lease
            let oldWorkingURL = baseDirectory.appendingPathComponent(oldWorkingRelative)
            let newWorkingURL = baseDirectory.appendingPathComponent(newWorkingRelative)
            let identity = condemnedFileIdentity(at: oldWorkingURL)
            var copied = false
            do {
                if let identity, identity.size > 0 {
                    storeFilesystem.before(.copy, oldWorkingURL)
                    guard condemnedFileIdentity(at: oldWorkingURL) == identity else { throw CocoaError(.fileReadUnknown) }
                    try checkpointFilesystem.durableCopy(oldWorkingURL, newWorkingURL,
                        baseDirectory.appendingPathComponent(temporary))
                    copied = true
                    oldWorkingURLToRemove = oldWorkingURL
                    inheritedDurableBytes = Int(clamping: identity.size)
                }
            } catch {
                return .rejectedOwnership(expectedPreviousOwner: expectedKey, actualOwner: existingKey,
                                          reason: .checkpointHandoffFailed)
            }
            lock.lock()
            guard rows[record.ratingKey]?.attemptID == expectedPreviousOwner,
                  rows[record.ratingKey]?.deletionPending == false,
                  rows[record.ratingKey]?.pendingArtifactIntents.isEmpty == true,
                  rowMutationGenerations[record.ratingKey, default: 0] == capturedGeneration else {
                let actual = rows[record.ratingKey]?.attemptID.map { DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: $0) }
                lock.unlock()
                if copied { try? storeFilesystem.removeItem(at: newWorkingURL, using: fileManager) }
                return .rejectedOwnership(expectedPreviousOwner: expectedKey, actualOwner: actual, reason: .ownerMismatch)
            }
        }
        let effectiveBytes = inheritedDurableBytes ?? record.bytes
        let effectiveProgress = inheritedDurableBytes.map {
            Self.progressForDurableBytes(
                $0,
                expectedBytes: previous.flatMap { Self.expectedBytesEstimate(row: $0) })
        } ?? record.progress
        var newRow = Row(
            ratingKey: record.ratingKey,
            attemptID: attemptID,
            title: record.title,
            relativePath: rel,
            attemptWorkingRelativePath: newWorkingRelative,
            bytes: effectiveBytes,
            progress: effectiveProgress,
            status: record.status,
            metadata: metadata,
        )
        // R2-5: a replacement attempt inherits truncation strikes for the same source in this
        // same transaction, so a Retry cannot reset the two-strike park (B54).
        let retired = retiredTruncation.removeValue(forKey: record.ratingKey)
        if let inheritedFrom = existing?.history
            ?? retired.map({ DownloadAttemptHistory(truncation: $0.truncation) }) {
            newRow.history = inheritedFrom.inherited(
                by: Self.truncationSourceKey(ratingKey: record.ratingKey, metadata: metadata))
        }
        setRowLocked(newRow, for: record.ratingKey)
        sideAssetHydrationCache.removeValue(forKey: record.ratingKey)
        let ticket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let persistence = waitForPersistence(through: ticket)
        guard persistence.result.committed(through: persistence.ticket) else {
            return .failed(key, persistence.result)
        }
        if let oldWorkingURLToRemove,
           lock.withLock({ !rows.values.contains { artifactPathsReferenced(by: $0).contains(oldWorkingURLToRemove.lastPathComponent) } }) {
            try? storeFilesystem.removeItem(at: oldWorkingURLToRemove, using: fileManager)
        }
        retireUnreferencedSideAssets(retiredSideAssetPaths, confirmingCurrentOwner: key)
        return .committed(key)
    }

    /// Record the locally-cached poster path (relative to the base dir) on a row's
    /// metadata snapshot (D5). No-op if the row or its metadata is gone — a missing
    /// poster is never a download failure.
    func setPosterRelativePath(ratingKey: String, _ relativePath: String) {
        updateMetadata(ratingKey: ratingKey) {
            $0.recordCachedPoster(relativePath: relativePath)
        }
    }

    /// Persist the last local-file playback position for a completed offline row (#146).
    ///
    /// This intentionally updates `localPlaybackPositionMs`, not the captured server `viewOffset`,
    /// so offline progress stays per downloaded row/version and online timeline semantics remain
    /// untouched. The pure policy clamps negatives/over-duration values and resets near-EOF
    /// positions to 0 so reopening does not land on a final frame.
    #if DEBUG
    @discardableResult
    func setLocalPlaybackPosition(
        for key: DownloadAttemptKey,
        positionMs: Int,
        durationMs: Int?
    ) -> AttemptMutationResult {
        updateMetadataOnWorker(for: key) { meta in
            let effectiveDuration = durationMs ?? meta.duration
            meta.localPlaybackPositionMs = OfflinePlaybackPositionPolicy.standard
                .persistedPositionMs(currentMs: positionMs, durationMs: effectiveDuration)
        }
    }
    #endif

    /// #84: persist the server-minted `PlaySessionId` for a transcoded JF/Emby (or Plex optimize)
    /// job so a hard app kill can still tear the encoder down on next launch. Status-change-grade:
    /// persists immediately (not throttled). No-op if the row/metadata is gone.
    #if DEBUG
    @discardableResult
    func setPlaySessionID(
        for key: DownloadAttemptKey,
        _ playSessionID: String
    ) -> AttemptMutationResult {
        guard !playSessionID.isEmpty else { return .noChange }
        return updateMetadataOnWorker(for: key) { $0.playSessionID = playSessionID }
    }
    #endif

    /// Clear only the exact server encoder handle that a confirmed teardown executed. A delayed
    /// cleanup for attempt A/session X must not clear attempt B or even a newer session Y owned by
    /// the same attempt after renegotiation.
    @discardableResult
    func clearPlaySessionIDOnWorker(
        for key: DownloadAttemptKey,
        expectedPlaySessionID: String
    ) -> AttemptCompareClearResult {
        lock.lock()
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID,
              var metadata = row.metadata else {
            lock.unlock()
            return .staleOrMissing
        }
        guard let current = metadata.playSessionID else {
            let ticket = enqueueAttemptPersistenceLocked()
            lock.unlock()
            let persistence = waitForPersistence(through: ticket)
            return persistence.result.committed(through: persistence.ticket)
                ? .alreadyAbsent : .persistenceFailed(persistence.result)
        }
        guard current == expectedPlaySessionID else {
            let ticket = enqueueAttemptPersistenceLocked()
            lock.unlock()
            let persistence = waitForPersistence(through: ticket)
            return persistence.result.committed(through: persistence.ticket)
                ? .expectedValueMismatch : .persistenceFailed(persistence.result)
        }
        metadata.playSessionID = nil
        metadata.downloadAttemptID = key.attemptID.rawValue
        row.metadata = metadata
        setRowLocked(row, for: key.ratingKey)
        let ticket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let persistence = waitForPersistence(through: ticket)
        return persistence.result.committed(through: persistence.ticket)
            ? .cleared : .persistenceFailed(persistence.result)
    }

    @discardableResult
    func setSourcePartSize(
        for key: DownloadAttemptKey,
        _ size: Int?
    ) -> AttemptMutationResult {
        setSourcePartSize(for: key, size, onlyIfMissing: false)
    }

    /// Persist the exact static resource size once a byte-range transfer discovers it. Rows may
    /// relaunch/reattach while active bytes are still in the network temporary file; keeping this
    /// denominator durable lets Offline continue showing percent and ETA from live range bytes.
    @discardableResult
    func submitSourcePartSizeIfMissing(
        for key: DownloadAttemptKey,
        _ size: Int?
    ) -> AttemptMutationSubmission {
        submitSourcePartSize(for: key, size, onlyIfMissing: true)
    }

    @discardableResult
    func submitSourcePartSize(
        for key: DownloadAttemptKey,
        _ size: Int?
    ) -> AttemptMutationSubmission {
        submitSourcePartSize(for: key, size, onlyIfMissing: false)
    }

    private func setSourcePartSize(
        for key: DownloadAttemptKey,
        _ size: Int?,
        onlyIfMissing: Bool
    ) -> AttemptMutationResult {
        updateMetadataOnWorker(for: key) { metadata in
            guard let size, size > 0 else { return }
            let existing = metadata.sourcePartSize ?? 0
            guard existing != size, !onlyIfMissing || existing <= 0 else { return }
            metadata.sourcePartSize = size
        }
    }

    private func submitSourcePartSize(
        for key: DownloadAttemptKey,
        _ size: Int?,
        onlyIfMissing: Bool
    ) -> AttemptMutationSubmission {
        submitMetadata(for: key) { metadata in
            guard let size, size > 0 else { return }
            let existing = metadata.sourcePartSize ?? 0
            guard existing != size, !onlyIfMissing || existing <= 0 else { return }
            metadata.sourcePartSize = size
        }
    }

    /// Write the artifact before recording its manifest, matching the legacy orphan-avoidance
    /// ordering. The ownership check, artifact replacement, and in-memory manifest mutation are
    /// serialized under the store lock so stale attempt A cannot overwrite B's resume blob.
    @discardableResult
    func setResumeData(
        for key: DownloadAttemptKey,
        _ data: Data,
        displayBytes: Int? = nil
    ) -> AttemptResumeDataWriteResult {
        switch submitResumeData(for: key, data, displayBytes: displayBytes) {
        case .staleOrMissing:
            return .staleOrMissing
        case .artifactWriteFailed(let errorType):
            return .artifactWriteFailed(errorType: errorType)
        case .accepted(let ticket):
            return resolveSynchronously(.accepted(ticket: ticket))
        }
    }

    @discardableResult
    func submitResumeData(
        for key: DownloadAttemptKey,
        _ data: Data,
        displayBytes: Int? = nil
    ) -> AttemptResumeDataSubmission {
        lock.lock()
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID,
              !row.deletionPending,
              !Self.hasPendingRowDeletion(row),
              row.pendingValidatedPromotionStatus == nil,
              row.metadata != nil else {
            lock.unlock()
            return .staleOrMissing
        }
        row.artifactGeneration += 1
        let generation = row.artifactGeneration
        let intentID = UUID()
        let attemptDigest = SHA256.hash(data: Data(key.attemptID.rawValue.utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        let relative = "\(Self.safeFilenameComponent(key.ratingKey)).resume-\(attemptDigest)-\(intentID.uuidString)"
        let intent = Row.ArtifactIntent(
            id: intentID,
            attemptID: key.attemptID,
            generation: generation,
            phase: .prepared,
            operation: .replaceResumeBlob(
                newRelativePath: relative,
                // The correct predecessor is the value published when this queued intent reaches
                // the head, not the possibly stale value visible at submission time.
                previousRelativePath: nil,
                displayBytes: displayBytes
            )
        )
        row.pendingArtifactIntents.append(intent)
        setRowLocked(row, for: key.ratingKey)
        let prepared = enqueueAttemptPersistenceLocked()
        let ticket = artifactLifecycle.register(
            key: key,
            generation: generation,
            intentID: intentID,
            preparedRevision: prepared
        )
        pendingResumeArtifactData[intentID] = data
        artifactLifecycleTickets[intentID] = ticket
        let start = activateArtifactHeadLocked(
            row: row, key: key, appendedIntent: intent, appendedTicket: ticket)
        lock.unlock()
        if let start { scheduleArtifactLifecycle(ticket: start.1, intent: start.0) }
        return .accepted(ticket: ticket)
    }

    /// #95: the persisted resume blob for a row, if present on disk. `nil` when the row has no
    /// recorded resume path or the file is gone.
    func resumeData(ratingKey: String) -> Data? {
        lock.lock()
        let relative = rows[ratingKey]?.metadata?.resumeDataRelativePath
        lock.unlock()
        guard let relative, Self.isSafeOneLevelRelativePath(relative) else { return nil }
        return try? storeFilesystem.read(baseDirectory.appendingPathComponent(relative))
    }

    func resumeData(for key: DownloadAttemptKey) -> Data? {
        let snapshot = lock.withLock { rows[key.ratingKey] }
        guard let row = snapshot, row.attemptID == key.attemptID,
              let relative = row.metadata?.resumeDataRelativePath,
              Self.isSafeOneLevelRelativePath(relative) else { return nil }
        let data = try? storeFilesystem.read(baseDirectory.appendingPathComponent(relative))
        return lock.withLock {
            guard let current = rows[key.ratingKey], current.attemptID == key.attemptID,
                  current.artifactGeneration == row.artifactGeneration,
                  current.metadata?.resumeDataRelativePath == relative,
                  current.metadata?.sideAssetSourceIdentity == row.metadata?.sideAssetSourceIdentity else { return nil }
            return data
        }
    }

    /// #95: whether a row has a persisted resume blob ON DISK (used by launch reconciliation to
    /// decide if a `.paused` row stays resumable). FS-checked without reading the blob.
    func hasResumeData(ratingKey: String) -> Bool {
        lock.lock()
        let relative = rows[ratingKey]?.metadata?.resumeDataRelativePath
        lock.unlock()
        guard let relative, Self.isSafeOneLevelRelativePath(relative) else { return false }
        return fileManager.fileExists(atPath: baseDirectory.appendingPathComponent(relative).path)
    }

    func hasResumeData(for key: DownloadAttemptKey) -> Bool {
        let snapshot = lock.withLock { (rows[key.ratingKey], rowMutationGenerations[key.ratingKey, default: 0]) }
        guard let row = snapshot.0, row.attemptID == key.attemptID,
              let relative = row.metadata?.resumeDataRelativePath,
              Self.isSafeOneLevelRelativePath(relative) else { return false }
        let exists = storeFilesystem.exists(atPath: baseDirectory.appendingPathComponent(relative).path, using: fileManager)
        return lock.withLock { rowMutationGenerations[key.ratingKey, default: 0] == snapshot.1 && exists }
    }

    /// #95: URLSession resume blobs are only safe for byte-range-resumable sources. Jellyfin/Emby
    /// encoder-served lanes (`.optimize` and `.compatibleRemux`) are forward-only streams with no
    /// stable validator, so even a resume blob can 200-full-restart or 416. Surface those
    /// interruptions as a clean restart-required failure instead of a misleading "Paused — tap to
    /// resume" row. Static original/existing-version downloads remain resumable.
    func supportsPersistedResumeData(ratingKey: String) -> Bool {
        lock.lock()
        let row = rows[ratingKey]
        lock.unlock()
        guard let row else { return false }
        let backend = row.metadata?.resolvedBackendKind(ratingKey: row.ratingKey)
            ?? DownloadBackendKind(ratingKeyPrefix: row.ratingKey)
        let mode = row.metadata?.resolvedResumeMode(ratingKey: row.ratingKey)
            ?? DownloadResumeMode.resolved(backend: backend, lane: .original)
        return mode != .liveForwardOnly
    }

    /// #95: drop a row's persisted resume blob + its recorded path once it's consumed (a resume
    /// task was created) or invalidated (a clean restart). No-op if the row/metadata is gone.
    func resumeDisplayBytes(ratingKey: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return rows[ratingKey]?.metadata?.resumeDisplayBytes
    }

    func resumeDisplayBytes(for key: DownloadAttemptKey) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[key.ratingKey], row.attemptID == key.attemptID else { return nil }
        return row.metadata?.resumeDisplayBytes
    }

    func clearResumeData(ratingKey: String, clearDisplayBytes: Bool = true) {
        lock.lock()
        let relative = rows[ratingKey]?.metadata?.resumeDataRelativePath
        lock.unlock()
        if let relative, !relative.isEmpty {
            try? fileManager.removeItem(at: baseDirectory.appendingPathComponent(relative))
        }
        updateMetadata(ratingKey: ratingKey) {
            $0.resumeDataRelativePath = nil
            if clearDisplayBytes {
                $0.resumeDisplayBytes = nil
            }
        }
    }

    @discardableResult
    func clearResumeData(
        for key: DownloadAttemptKey,
        clearDisplayBytes: Bool = true
    ) -> AttemptMutationResult {
        switch submitClearResumeData(for: key, clearDisplayBytes: clearDisplayBytes) {
        case .staleOrMissing:
            return .staleOrMissing
        case .accepted(let change, let ticket):
            switch artifactLifecycle.waitSynchronously(for: ticket) {
            case .completed:
                return change == .applied ? .applied : .noChange
            case .failed(.persistence(let failure)):
                return .persistenceFailed(failure)
            case .failed(.artifact(let errorType)):
                return .persistenceFailed(.failed(
                    revision: ticket.preparedRevision.revision,
                    stage: "artifact",
                    errorType: errorType
                ))
            case .timedOut:
                preconditionFailure("an unbounded artifact lifecycle wait cannot time out")
            }
        }
    }

    @discardableResult
    func submitClearResumeData(
        for key: DownloadAttemptKey,
        clearDisplayBytes: Bool = true
    ) -> AttemptArtifactMutationSubmission {
        lock.lock()
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID,
              !row.deletionPending,
              !Self.hasPendingRowDeletion(row),
              row.pendingValidatedPromotionStatus == nil,
              let metadata = row.metadata else {
            lock.unlock()
            return .staleOrMissing
        }
        let relative = metadata.resumeDataRelativePath
        let hadDisplayBytes = metadata.resumeDisplayBytes != nil
        let changed = relative != nil
            || (clearDisplayBytes && hadDisplayBytes)
            || !row.pendingArtifactIntents.isEmpty
        guard changed else {
            let ticket = enqueueAttemptPersistenceLocked()
            lock.unlock()
            let lifecycle = artifactLifecycle.register(
                key: key,
                generation: row.artifactGeneration,
                intentID: UUID(),
                preparedRevision: ticket
            )
            artifactWorkerQueue.async { [weak self] in
                guard let self else { return }
                let outcome = self.waitForPersistence(through: ticket)
                if outcome.result.committed(through: ticket) {
                    self.artifactLifecycle.complete(lifecycle)
                } else {
                    // One-shot persistence barrier with a random intentID: no retry ever
                    // re-registers it, so the failure is recorded and abandoned in one atomic
                    // transition — a boundary waiter must never observe the intermediate
                    // failed-but-live entry. The ticket waiter above still reads the failure.
                    self.artifactLifecycle.failAndAbandonIntent(lifecycle, outcome.result)
                }
            }
            return .accepted(change: .noChange, ticket: lifecycle)
        }
        row.artifactGeneration += 1
        let generation = row.artifactGeneration
        let intentID = UUID()
        let intent = Row.ArtifactIntent(
            id: intentID,
            attemptID: key.attemptID,
            generation: generation,
            phase: .prepared,
            operation: .clearResumeBlob(
                // Captured durably only when this intent becomes the serialized head.
                relativePath: nil,
                clearDisplayBytes: clearDisplayBytes
            )
        )
        row.pendingArtifactIntents.append(intent)
        setRowLocked(row, for: key.ratingKey)
        let prepared = enqueueAttemptPersistenceLocked()
        let ticket = artifactLifecycle.register(
            key: key,
            generation: generation,
            intentID: intentID,
            preparedRevision: prepared
        )
        artifactLifecycleTickets[intentID] = ticket
        let start = activateArtifactHeadLocked(
            row: row, key: key, appendedIntent: intent, appendedTicket: ticket)
        lock.unlock()
        if let start { scheduleArtifactLifecycle(ticket: start.1, intent: start.0) }
        // Resume clear has a filesystem lifecycle ticket, unlike ordinary row-only mutations.
        // Its source-compatible wrapper below waits for this ticket when required.
        return .accepted(change: .applied, ticket: ticket)
    }

    private func executeResumeReplacement(
        ticket: DownloadArtifactLifecycleCoordinator.Ticket,
        data: Data?
    ) {
        let prepared = waitForPersistence(through: ticket.preparedRevision)
        guard prepared.result.committed(through: ticket.preparedRevision) else {
            failArtifactLifecycle(ticket, prepared.result)
            return
        }
        lock.lock()
        guard let row = rows[ticket.key.ratingKey],
              row.attemptID == ticket.key.attemptID else {
            lock.unlock()
            completeArtifactLifecycle(ticket)
            return
        }
        guard let intent = row.pendingArtifactIntents.first,
              intent.id == ticket.intentID,
              intent.generation == ticket.generation,
              case .replaceResumeBlob(let newRelative, let previousRelative, let displayBytes)
                = intent.operation else {
            lock.unlock()
            failArtifactLifecycle(ticket, errorType: "blockedByPriorArtifactIntent")
            return
        }
        lock.unlock()

        let newURL = baseDirectory.appendingPathComponent(newRelative)
        let shouldCleanupStartupTemps = lock.withLock {
            startupArtifactCleanupIntentIDs.remove(ticket.intentID) != nil
        }
        if shouldCleanupStartupTemps {
            // Startup-only and age-gated: never unlink a fresh sibling a live writer may own.
            try? DownloadIndexFileCommitter.cleanupAbandonedTemps(for: newURL)
        }
        if !artifactFilesystem.fileExists(newURL, fileManager) {
            if intent.phase == .publishedAwaitingPriorDeletion {
                rollbackMissingPublishedResume(
                    ticket: ticket,
                    newRelative: newRelative,
                    previousRelative: previousRelative)
                return
            }
            guard let data else {
                // A kill before the generation-private write leaves the previous published blob
                // authoritative. Abandon only this prepared intent.
                finishMissingRecoveredResumeReplacement(ticket: ticket)
                return
            }
            do {
                try artifactFilesystem.writeAuthArtifact(data, newURL, fileManager)
            } catch {
                failArtifactLifecycle(
                    ticket, errorType: String(reflecting: type(of: error)))
                return
            }
        }

        var predecessor = previousRelative
        if intent.phase == .prepared {
            lock.lock()
            guard var publishing = rows[ticket.key.ratingKey],
                  publishing.attemptID == ticket.key.attemptID,
                  !publishing.pendingArtifactIntents.isEmpty,
                  publishing.pendingArtifactIntents[0].id == ticket.intentID,
                  var metadata = publishing.metadata else {
                lock.unlock()
                completeArtifactLifecycle(ticket)
                return
            }
            // Serialize composition at execution: this is the artifact actually published by the
            // retired predecessor intent, not the stale path visible when this one was submitted.
            predecessor = metadata.resumeDataRelativePath
            metadata.resumeDataRelativePath = newRelative
            if let displayBytes, displayBytes > 0 {
                metadata.resumeDisplayBytes = max(displayBytes, metadata.resumeDisplayBytes ?? 0)
            }
            metadata.downloadAttemptID = ticket.key.attemptID.rawValue
            publishing.metadata = metadata
            publishing.pendingArtifactIntents[0].operation = .replaceResumeBlob(
                newRelativePath: newRelative,
                previousRelativePath: predecessor,
                displayBytes: displayBytes)
            publishing.pendingArtifactIntents[0].phase = .publishedAwaitingPriorDeletion
            setRowLocked(publishing, for: ticket.key.ratingKey)
            let publishTicket = enqueueAttemptPersistenceLocked()
            lock.unlock()
            let publication = waitForPersistence(through: publishTicket)
            guard publication.result.committed(through: publishTicket) else {
                failArtifactLifecycle(ticket, publication.result)
                return
            }
        }

        if let predecessor,
           predecessor != newRelative,
           Self.isSafeOneLevelRelativePath(predecessor) {
            let oldURL = baseDirectory.appendingPathComponent(predecessor)
            do {
                var removed = false
                if artifactFilesystem.fileExists(oldURL, fileManager) {
                    try artifactFilesystem.removeItem(oldURL, fileManager)
                    removed = true
                }
                if removed { try artifactFilesystem.syncParentDirectory(oldURL) }
            } catch {
                failArtifactLifecycle(
                    ticket, errorType: String(reflecting: type(of: error)))
                return
            }
        }
        finishArtifactIntent(ticket)
    }

    private func finishMissingRecoveredResumeReplacement(
        ticket: DownloadArtifactLifecycleCoordinator.Ticket
    ) {
        finishArtifactIntent(ticket)
    }

    private func rollbackMissingPublishedResume(
        ticket: DownloadArtifactLifecycleCoordinator.Ticket,
        newRelative: String,
        previousRelative: String?
    ) {
        let restoredRelative: String? = previousRelative.flatMap { relative in
            guard Self.isSafeOneLevelRelativePath(relative),
                  artifactFilesystem.fileExists(
                    baseDirectory.appendingPathComponent(relative), fileManager) else { return nil }
            return relative
        }
        lock.lock()
        guard var row = rows[ticket.key.ratingKey],
              row.attemptID == ticket.key.attemptID,
              !row.pendingArtifactIntents.isEmpty,
              row.pendingArtifactIntents[0].id == ticket.intentID,
              var metadata = row.metadata else {
            lock.unlock()
            completeArtifactLifecycle(ticket)
            return
        }
        if metadata.resumeDataRelativePath == newRelative {
            metadata.resumeDataRelativePath = restoredRelative
            if restoredRelative == nil { metadata.resumeDisplayBytes = nil }
            row.metadata = metadata
        }
        artifactRetirementKeys.insert(ticket.key)
        let retiringIntent = row.pendingArtifactIntents.removeFirst()
        setRowLocked(row, for: ticket.key.ratingKey)
        let rollbackTicket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let rollback = waitForPersistence(through: rollbackTicket)
        finishOrRestoreArtifactIntent(
            ticket: ticket,
            retiringIntent: retiringIntent,
            terminalTicket: rollbackTicket,
            outcome: rollback.result)
    }

    private func executeResumeClear(ticket: DownloadArtifactLifecycleCoordinator.Ticket) {
        let prepared = waitForPersistence(through: ticket.preparedRevision)
        guard prepared.result.committed(through: ticket.preparedRevision) else {
            failArtifactLifecycle(ticket, prepared.result)
            return
        }
        lock.lock()
        guard let row = rows[ticket.key.ratingKey],
              row.attemptID == ticket.key.attemptID else {
            lock.unlock()
            completeArtifactLifecycle(ticket)
            return
        }
        guard let intent = row.pendingArtifactIntents.first,
              intent.id == ticket.intentID,
              case .clearResumeBlob(let relative, let clearDisplayBytes) = intent.operation else {
            lock.unlock()
            failArtifactLifecycle(ticket, errorType: "blockedByPriorArtifactIntent")
            return
        }
        lock.unlock()
        var capturedRelative = relative
        if intent.phase == .prepared {
            lock.lock()
            guard var capturing = rows[ticket.key.ratingKey],
                  capturing.attemptID == ticket.key.attemptID,
                  !capturing.pendingArtifactIntents.isEmpty,
                  capturing.pendingArtifactIntents[0].id == ticket.intentID else {
                lock.unlock()
                completeArtifactLifecycle(ticket)
                return
            }
            capturedRelative = capturing.metadata?.resumeDataRelativePath
            capturing.pendingArtifactIntents[0].operation = .clearResumeBlob(
                relativePath: capturedRelative,
                clearDisplayBytes: clearDisplayBytes)
            capturing.pendingArtifactIntents[0].phase = .clearTargetCaptured
            setRowLocked(capturing, for: ticket.key.ratingKey)
            let captureTicket = enqueueAttemptPersistenceLocked()
            lock.unlock()
            let capture = waitForPersistence(through: captureTicket)
            guard capture.result.committed(through: captureTicket) else {
                failArtifactLifecycle(ticket, capture.result)
                return
            }
        }
        if let capturedRelative, Self.isSafeOneLevelRelativePath(capturedRelative) {
            guard case .acquired(let lease) = tryAcquirePathLease(for: ticket.key,
                relativePaths: [capturedRelative], purpose: .artifact) else {
                failArtifactLifecycle(ticket, errorType: "pathBusy"); return
            }
            defer { releasePathLease(lease) }
            let shared = lock.withLock { rows.values.contains {
                $0.ratingKey != ticket.key.ratingKey && artifactPathsReferenced(by: $0).contains(capturedRelative)
            } }
            let url = baseDirectory.appendingPathComponent(capturedRelative)
            do {
                var removed = false
                if !shared, artifactFilesystem.fileExists(url, fileManager) {
                    try storeFilesystem.removeItem(at: url, using: fileManager, fallback: artifactFilesystem.removeItem)
                    removed = true
                }
                if removed { try artifactFilesystem.syncParentDirectory(url) }
            } catch {
                failArtifactLifecycle(
                    ticket, errorType: String(reflecting: type(of: error)))
                return
            }
        }
        lock.lock()
        guard var clearing = rows[ticket.key.ratingKey],
              clearing.attemptID == ticket.key.attemptID,
              !clearing.pendingArtifactIntents.isEmpty,
              clearing.pendingArtifactIntents[0].id == ticket.intentID,
              var metadata = clearing.metadata else {
            lock.unlock()
            completeArtifactLifecycle(ticket)
            return
        }
        // Compare-clear: a queued/newer generation may already publish a different path.
        if metadata.resumeDataRelativePath == capturedRelative {
            metadata.resumeDataRelativePath = nil
            if clearDisplayBytes { metadata.resumeDisplayBytes = nil }
            metadata.downloadAttemptID = ticket.key.attemptID.rawValue
            clearing.metadata = metadata
        }
        artifactRetirementKeys.insert(ticket.key)
        let retiringIntent = clearing.pendingArtifactIntents.removeFirst()
        setRowLocked(clearing, for: ticket.key.ratingKey)
        let terminal = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let outcome = waitForPersistence(through: terminal)
        finishOrRestoreArtifactIntent(
            ticket: ticket,
            retiringIntent: retiringIntent,
            terminalTicket: terminal,
            outcome: outcome.result)
    }

    private func finishArtifactIntent(_ ticket: DownloadArtifactLifecycleCoordinator.Ticket) {
        lock.lock()
        guard var row = rows[ticket.key.ratingKey],
              row.attemptID == ticket.key.attemptID,
              !row.pendingArtifactIntents.isEmpty,
              row.pendingArtifactIntents[0].id == ticket.intentID else {
            lock.unlock()
            completeArtifactLifecycle(ticket)
            return
        }
        artifactRetirementKeys.insert(ticket.key)
        let retiringIntent = row.pendingArtifactIntents.removeFirst()
        setRowLocked(row, for: ticket.key.ratingKey)
        let terminal = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let outcome = waitForPersistence(through: terminal)
        finishOrRestoreArtifactIntent(
            ticket: ticket,
            retiringIntent: retiringIntent,
            terminalTicket: terminal,
            outcome: outcome.result)
    }

    private func finishOrRestoreArtifactIntent(
        ticket: DownloadArtifactLifecycleCoordinator.Ticket,
        retiringIntent: Row.ArtifactIntent,
        terminalTicket: PersistenceTicket,
        outcome: PersistenceFlushResult
    ) {
        guard outcome.committed(through: terminalTicket) else {
            // The terminal snapshot may have failed before or after replacement. Keep the exact
            // intent as current in-memory retry authority and submit a restoring snapshot; a later
            // same-intent coordinator attempt then supersedes this reported process failure.
            lock.lock()
            if var row = rows[ticket.key.ratingKey],
               row.attemptID == ticket.key.attemptID,
               !row.pendingArtifactIntents.contains(where: { $0.id == retiringIntent.id }) {
                row.pendingArtifactIntents.insert(retiringIntent, at: 0)
                setRowLocked(row, for: ticket.key.ratingKey)
                _ = enqueueAttemptPersistenceLocked()
            }
            artifactRetirementKeys.remove(ticket.key)
            lock.unlock()
            failArtifactLifecycle(ticket, outcome)
            return
        }
        _ = lock.withLock { artifactRetirementKeys.remove(ticket.key) }
        completeArtifactLifecycle(ticket)
    }

    private func completeArtifactLifecycle(
        _ ticket: DownloadArtifactLifecycleCoordinator.Ticket
    ) {
        lock.withLock {
            activeArtifactIntentIDs.remove(ticket.intentID)
            pendingResumeArtifactData.removeValue(forKey: ticket.intentID)
            failedArtifactPreparedRevisions.removeValue(forKey: ticket.intentID)
            failedArtifactIOIntentIDs.remove(ticket.intentID)
            artifactLifecycleTickets.removeValue(forKey: ticket.intentID)
            if staticCheckpointOutcomes[ticket] == nil {
                staticCheckpointAwaitingResultIDs.remove(ticket)
            }
        }
        artifactLifecycle.complete(ticket)
        recoverPendingArtifactIntents(successorOf: ticket.key)
    }

    private func failArtifactLifecycle(
        _ ticket: DownloadArtifactLifecycleCoordinator.Ticket,
        _ failure: PersistenceFlushResult
    ) {
        let advanceDeletion = retireFailedHeadBeforeQueuedRowDeletion(ticket)
        lock.withLock {
            if case .failed(let revision, _, _) = failure, ticket.preparedRevision.revision > 0,
               revision <= ticket.preparedRevision.revision {
                failedArtifactPreparedRevisions[ticket.intentID] = ticket.preparedRevision.revision
            } else { failedArtifactIOIntentIDs.insert(ticket.intentID) }
            activeArtifactIntentIDs.remove(ticket.intentID)
            artifactLifecycleTickets.removeValue(forKey: ticket.intentID)
        }
        artifactLifecycle.fail(ticket, failure)
        if advanceDeletion { recoverPendingArtifactIntents() }
    }

    private func failArtifactLifecycle(
        _ ticket: DownloadArtifactLifecycleCoordinator.Ticket,
        errorType: String
    ) {
        let advanceDeletion = retireFailedHeadBeforeQueuedRowDeletion(ticket)
        lock.withLock {
            failedArtifactIOIntentIDs.insert(ticket.intentID)
            activeArtifactIntentIDs.remove(ticket.intentID)
            artifactLifecycleTickets.removeValue(forKey: ticket.intentID)
            staticCheckpointAwaitingResultIDs.remove(ticket)
            staticCheckpointOutcomes.removeValue(forKey: ticket)
        }
        artifactLifecycle.failArtifact(ticket, errorType: errorType)
        if advanceDeletion { recoverPendingArtifactIntents() }
    }

    /// A queued row deletion safely supersedes a failed predecessor: its durable recipe captured
    /// every predecessor path, and no later successor can be admitted. Commit removal of the failed
    /// head before activating the terminal intent so a hard kill observes one unambiguous head.
    private func retireFailedHeadBeforeQueuedRowDeletion(
        _ ticket: DownloadArtifactLifecycleCoordinator.Ticket
    ) -> Bool {
        lock.lock()
        guard var row = rows[ticket.key.ratingKey], row.attemptID == ticket.key.attemptID,
              row.pendingArtifactIntents.first?.id == ticket.intentID,
              row.pendingArtifactIntents.dropFirst().contains(where: {
                  if case .rowDeletion = $0.operation { return true }
                  return false
              }) else {
            lock.unlock(); return false
        }
        artifactRetirementKeys.insert(ticket.key)
        let failed = row.pendingArtifactIntents.removeFirst()
        setRowLocked(row, for: ticket.key.ratingKey)
        let transition = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let outcome = waitForPersistence(through: transition)
        guard outcome.result.committed(through: transition) else {
            lock.lock()
            if var restored = rows[ticket.key.ratingKey],
               restored.attemptID == ticket.key.attemptID,
               !restored.pendingArtifactIntents.contains(where: { $0.id == failed.id }) {
                restored.pendingArtifactIntents.insert(failed, at: 0)
                setRowLocked(restored, for: ticket.key.ratingKey)
                _ = enqueueAttemptPersistenceLocked()
            }
            artifactRetirementKeys.remove(ticket.key)
            let deletionIntent = rows[ticket.key.ratingKey]?.pendingArtifactIntents.first(where: {
                if case .rowDeletion = $0.operation { return true }
                return false
            })
            let deletionTicket = deletionIntent.flatMap { artifactLifecycleTickets[$0.id] }
            if let deletionTicket {
                let epoch = RowDeletionTicketEpoch(deletionTicket)
                if (rowDeletionWaiterCounts[epoch] ?? 0) > 0 {
                    rowDeletionOutcomes[epoch] = .persistenceFailed(
                        deletionTicket.key, outcome.result)
                }
                artifactLifecycleTickets.removeValue(forKey: deletionTicket.intentID)
                activeArtifactIntentIDs.remove(deletionTicket.intentID)
            }
            lock.unlock()
            if let deletionTicket { artifactLifecycle.fail(deletionTicket, outcome.result) }
            return false
        }
        lock.withLock {
            artifactRetirementKeys.remove(ticket.key)
            pendingResumeArtifactData.removeValue(forKey: failed.id)
            startupArtifactCleanupIntentIDs.remove(failed.id)
            failedArtifactPreparedRevisions.removeValue(forKey: failed.id)
            failedArtifactIOIntentIDs.remove(failed.id)
        }
        // The retired head is permanently dead — nothing ever re-registers its intentID — so its
        // failed coordinator entry must stop gating lifecycle boundaries. The caller still records
        // the failure on the ticket for its own synchronous waiters.
        artifactLifecycle.abandonIntent(failed.id)
        return true
    }

    @discardableResult
    private func recoverPendingArtifactIntents(explicit: Bool = true, successorOf completedKey: DownloadAttemptKey? = nil) -> [DownloadArtifactLifecycleCoordinator.Ticket] {
        lock.lock()
        let pending: [(DownloadAttemptKey, Row.ArtifactIntent)] = rows.values.compactMap { row -> (DownloadAttemptKey, Row.ArtifactIntent)? in
            guard let attemptID = row.attemptID else { return nil }
            let key = DownloadAttemptKey(ratingKey: row.ratingKey, attemptID: attemptID)
            guard completedKey == nil || key == completedKey else { return nil }
            guard !artifactRetirementKeys.contains(key) else { return nil }
            guard let head = row.pendingArtifactIntents.first,
                  !activeArtifactIntentIDs.contains(head.id) else { return nil }
            if !explicit {
                guard !failedArtifactIOIntentIDs.contains(head.id),
                      let failedRevision = failedArtifactPreparedRevisions[head.id],
                      indexWriter.state.committedRevision >= failedRevision else { return nil }
            }
            failedArtifactPreparedRevisions.removeValue(forKey: head.id)
            failedArtifactIOIntentIDs.remove(head.id)
            return (key, head)
        }
        activeArtifactIntentIDs.formUnion(pending.map { $0.1.id })
        let scheduled = pending.map { key, intent -> (DownloadAttemptKey, Row.ArtifactIntent, DownloadArtifactLifecycleCoordinator.Ticket) in
            let ticket = artifactLifecycleTickets[intent.id] ?? artifactLifecycle.register(
                key: key, generation: intent.generation, intentID: intent.id,
                preparedRevision: .init(revision: 0))
            artifactLifecycleTickets[intent.id] = ticket
            switch intent.operation {
            case .staticCheckpoint:
                if staticCheckpointAwaitingResultIDs.contains(where: { $0.intentID == intent.id }) {
                    staticCheckpointAwaitingResultIDs.insert(ticket)
                }
            case .validatedPromotion:
                if promotionAwaitingResultIDs.contains(where: { $0.intentID == intent.id }) {
                    promotionAwaitingResultIDs.insert(ticket)
                }
            default: break
            }
            return (key, intent, ticket)
        }
        lock.unlock()
        for (_, intent, ticket) in scheduled {
            scheduleArtifactLifecycle(ticket: ticket, intent: intent)
        }
        // Return the lock-linearized registrations, even if a fast physical failure has already
        // removed its live ticket. Observers must never resample the mutable live map for epochs.
        return scheduled.map { $0.2 }
    }

    /// #169: the HTTP validator (`ETag`/`Last-Modified`) for a static byte-range download, captured
    /// from the first successful range body and sent as `If-Range` on later requests so a server-side resource change is
    /// detected (200 full-replace) instead of silently corrupting the partial.
    func rangeValidator(ratingKey: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return rows[ratingKey]?.metadata?.rangeValidator
    }

    func rangeValidator(for key: DownloadAttemptKey) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[key.ratingKey], row.attemptID == key.attemptID else { return nil }
        return row.metadata?.rangeValidator
    }

    func setRangeValidator(ratingKey: String, _ validator: String) {
        updateMetadata(ratingKey: ratingKey) { $0.rangeValidator = validator }
    }

    @discardableResult
    func setRangeValidator(
        for key: DownloadAttemptKey,
        _ validator: String
    ) -> AttemptMutationResult {
        updateMetadataOnWorker(for: key) { $0.rangeValidator = validator }
    }

    @discardableResult
    func submitRangeValidator(
        for key: DownloadAttemptKey,
        _ validator: String?
    ) -> AttemptMutationSubmission {
        submitMetadata(for: key) { $0.rangeValidator = validator }
    }

    func clearRangeValidator(ratingKey: String) {
        updateMetadata(ratingKey: ratingKey) { $0.rangeValidator = nil }
    }

    @discardableResult
    func clearRangeValidator(for key: DownloadAttemptKey) -> AttemptMutationResult {
        updateMetadataOnWorker(for: key) { $0.rangeValidator = nil }
    }

    func downloadAttemptIdentity(ratingKey: String) -> DownloadAttemptID? {
        lock.lock(); defer { lock.unlock() }
        return rows[ratingKey]?.attemptID
    }

    /// Startup accepts only a fully current exact-attempt snapshot. Unsupported schemas are reset
    /// as one opaque root; malformed current rows are retained byte-for-byte and fail closed.
    func startupIndexAdmission() -> StartupIndexAdmission {
        lock.lock(); defer { lock.unlock() }
        if seasonCommitIndeterminate { return .seasonCommitIndeterminate }
        switch startupSchemaProbe {
        case .unsupported(let schemaVersion):
            return .requiresDestructiveReset(schemaVersion: schemaVersion)
        case .unreadable:
            return .unreadableIndex
        case .missing:
            return .current
        case .current:
            break
        }
        let malformed = rows.values.filter { row in
            guard !row.decodedAttemptIdentityDisagrees,
                  row.decodedTopLevelAttemptIDPresent,
                  let attemptID = row.attemptID else { return true }
            guard row.status != .complete && row.status != .unverified else { return false }
            return row.attemptWorkingRelativePath != Self.attemptStagingRelativePath(
                for: DownloadAttemptKey(ratingKey: row.ratingKey, attemptID: attemptID),
                stableRelativePath: row.relativePath)
        }.map(\.ratingKey).sorted()
        return malformed.isEmpty ? .current : .malformedCurrentRows(malformed)
    }

    /// Retry Recovery (B16, B21): re-examine a blocked admission in process instead of returning
    /// the probe cached at launch.
    /// - An indeterminate season commit re-commits the (consistent) in-memory index; once that
    ///   commits, disk and memory agree again.
    /// - An index that was unreadable at launch, before any row was loaded, is classified again;
    ///   if it now reads as current or missing, the normal startup tail runs.
    func beginStartupReprobe() -> UUID {
        lock.withLock {
            let epoch = UUID()
            startupReprobeEpoch = epoch
            return epoch
        }
    }

    func reprobeBlockedIndexOnWorker(epoch: UUID? = nil) -> StartupIndexAdmission {
        let epoch = epoch ?? beginStartupReprobe()
        // Serialize physical startup tails without occupying the store lock. A newer submitted
        // epoch invalidates an older observation even if its waiter has already timed out.
        startupReprobeWorkerLock.lock()
        defer { startupReprobeWorkerLock.unlock() }
        lock.lock()
        guard startupReprobeEpoch == epoch else { lock.unlock(); return startupIndexAdmission() }
        let indeterminate = seasonCommitIndeterminate
        let unreadableAtLaunch = startupSchemaProbe == .unreadable && rows.isEmpty
        lock.unlock()
        if indeterminate {
            lock.lock()
            let ticket = enqueuePersistenceLocked()
            lock.unlock()
            if Self.mapPersistenceResult(indexWriter.waitSynchronouslyForOutcome(
                through: ticket.revision)).committed(through: ticket) {
                lock.withLock { if startupReprobeEpoch == epoch { seasonCommitIndeterminate = false } }
            }
        } else if unreadableAtLaunch {
            let pendingQuarantine = baseDirectory.deletingLastPathComponent().appendingPathComponent(
                ".\(baseDirectory.lastPathComponent)-unsupported-reset-pending", isDirectory: true)
            let (probe, data) = Self.classifyIndex(
                at: indexURL, pendingQuarantine: pendingQuarantine,
                read: rootIndexPersistence.read, fileManager: fileManager)
            let inventory = Self.stagingInventory(in: baseDirectory, probe: probe, fileManager: fileManager)
            var identities: [String: CondemnedFileIdentity] = [:]
            for path in inventory { identities[path] = condemnedFileIdentity(at: baseDirectory.appendingPathComponent(path)) }
            let current = lock.withLock { () -> Bool in
                guard startupReprobeEpoch == epoch, rows.isEmpty, startupSchemaProbe == .unreadable else { return false }
                startupSchemaProbe = probe
                startupStagingInventory = inventory
                startupStagingIdentities = identities
                return true
            }
            guard current else { return startupIndexAdmission() }
            if probe == .current || probe == .missing {
                completeAdmissibleStartup(probe: probe, indexData: data)
            }
        }
        return startupIndexAdmission()
    }

    @discardableResult
    func resetStaticRangeProgressToDurableCheckpoint(
        for key: DownloadAttemptKey,
        expectedBytes explicitExpectedBytes: Int? = nil
    ) -> AttemptStaticRangeCheckpointResetResult {
        resolveStaticCheckpointSynchronously(submitStaticRangeCheckpointReset(
            for: key, expectedBytes: explicitExpectedBytes))
    }

    func submitStaticRangeCheckpointReset(
        for key: DownloadAttemptKey,
        expectedBytes explicitExpectedBytes: Int? = nil
    ) -> AttemptStaticCheckpointSubmission {
        lock.lock()
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID,
              !row.deletionPending,
              !Self.hasPendingRowDeletion(row),
              row.pendingValidatedPromotionStatus == nil else {
            lock.unlock(); return .staleOrMissing
        }
        guard !row.pendingArtifactIntents.contains(where: {
            if case .validatedPromotion = $0.operation { return true }
            return false
        }) else {
            lock.unlock(); return .staleOrMissing
        }
        let backend = row.metadata?.resolvedBackendKind(ratingKey: row.ratingKey)
            ?? DownloadBackendKind(ratingKeyPrefix: row.ratingKey)
        let mode = row.metadata?.resolvedResumeMode(ratingKey: row.ratingKey)
            ?? DownloadResumeMode.resolved(
                backend: backend, lane: row.metadata?.resolvedDownloadLane() ?? .original)
        guard mode == .staticByteRange else {
            let bytes = row.bytes; lock.unlock(); return .notStatic(bytes: bytes)
        }
        let reconstructed = row.status == .complete || row.status == .unverified
        let working: String
        let stable: String?
        let temporary: String?
        if reconstructed {
            working = Self.attemptStagingRelativePath(
                for: key, stableRelativePath: row.relativePath)
            stable = row.relativePath
            temporary = ".\(working).checkpoint-\(UUID().uuidString)"
        } else if row.history.isBodyCondemned {
            // Never read or rewrite the condemned bytes; the usable checkpoint is empty.
            row.bytes = 0
            row.progress = 0
            setRowLocked(row, for: key.ratingKey)
            let ticket = enqueueAttemptPersistenceLocked()
            lock.unlock(); return .condemned(ticket)
        } else {
            guard let existing = workingRelativePath(for: row, key: key) else {
                lock.unlock(); return .staleOrMissing
            }
            working = existing; stable = nil; temporary = nil
        }
        let lifecyclePaths = [working, stable, temporary].compactMap { $0 }
        guard lifecyclePaths.allSatisfy({ reservedArtifactDeletionPaths[$0] == nil }) else {
            lock.unlock(); return .staleOrMissing
        }
        row.artifactGeneration += 1
        let intent = Row.ArtifactIntent(
            id: UUID(), attemptID: key.attemptID, generation: row.artifactGeneration,
            phase: .prepared,
            operation: .staticCheckpoint(
                workingRelativePath: working,
                stableSourceRelativePath: stable,
                copyTempRelativePath: temporary,
                expectedBytes: explicitExpectedBytes ?? Self.expectedBytesEstimate(row: row),
                reconstructedTerminal: reconstructed))
        row.pendingArtifactIntents.append(intent)
        setRowLocked(row, for: key.ratingKey)
        let prepared = enqueueAttemptPersistenceLocked()
        let ticket = artifactLifecycle.register(
            key: key, generation: intent.generation, intentID: intent.id,
            preparedRevision: prepared)
        artifactLifecycleTickets[intent.id] = ticket
        staticCheckpointAwaitingResultIDs.insert(ticket)
        let start = activateArtifactHeadLocked(
            row: row, key: key, appendedIntent: intent, appendedTicket: ticket)
        lock.unlock()
        if let start { scheduleArtifactLifecycle(ticket: start.1, intent: start.0) }
        return .accepted(ticket: ticket)
    }

    func resolveStaticCheckpointSynchronously(
        _ submission: AttemptStaticCheckpointSubmission
    ) -> AttemptStaticRangeCheckpointResetResult {
        switch submission {
        case .staleOrMissing: return .staleOrMissing
        case .notStatic(let bytes): return .notStatic(bytes: bytes)
        case .condemned(let ticket):
            let persistence = waitForPersistence(through: ticket)
            return persistence.result.committed(through: persistence.ticket)
                ? .applied(bytes: 0) : .persistenceFailed(bytes: 0, persistence.result)
        case .accepted(let ticket):
            let outcome = artifactLifecycle.waitSynchronously(for: ticket)
            if let result = lock.withLock({ () -> AttemptStaticRangeCheckpointResetResult? in
                staticCheckpointAwaitingResultIDs.remove(ticket)
                return staticCheckpointOutcomes.removeValue(forKey: ticket)
            }) {
                return result
            }
            switch outcome {
            case .completed: return .staleOrMissing
            case .failed(.persistence(let failure)):
                return .persistenceFailed(bytes: 0, failure)
            case .failed(.artifact), .timedOut: return .staleOrMissing
            }
        }
    }

    func resolveStaticCheckpoint(
        _ submission: AttemptStaticCheckpointSubmission
    ) async -> AttemptStaticRangeCheckpointResetResult {
        await resolveStaticCheckpointDeadline(submission, deadline: .after(30))
    }

    private func recordStaticCheckpointOutcomeLocked(
        _ result: AttemptStaticRangeCheckpointResetResult,
        ticket: DownloadArtifactLifecycleCoordinator.Ticket
    ) {
        guard staticCheckpointAwaitingResultIDs.contains(ticket) else { return }
        staticCheckpointOutcomes[ticket] = result
    }

    func staticCheckpointOutcomeCountForTests() -> Int {
        lock.withLock { staticCheckpointOutcomes.count }
    }

    private func executeStaticCheckpoint(
        ticket: DownloadArtifactLifecycleCoordinator.Ticket,
        intent: Row.ArtifactIntent
    ) {
        guard case .staticCheckpoint(
            let working, let stable, let temporary, let expected, let reconstructed) = intent.operation
        else { failArtifactLifecycle(ticket, errorType: "invalidStaticCheckpointIntent"); return }
        guard Self.isSafeOneLevelRelativePath(working),
              stable.map(Self.isSafeOneLevelRelativePath) ?? true,
              temporary.map(Self.isSafeOneLevelRelativePath) ?? true else {
            failArtifactLifecycle(ticket, errorType: "invalidStaticCheckpointLayout"); return
        }
        let prepared = waitForPersistence(through: ticket.preparedRevision)
        guard prepared.result.committed(through: ticket.preparedRevision) else {
            // A nonterminal stat is observational and preserves the legacy dirty-snapshot retry
            // behavior even when intent preparation fails. Terminal reconstruction remains
            // fail-closed: no copy occurs until the exact copy recipe is durable.
            let durable = reconstructed ? 0 : checkpointFilesystem.size(
                baseDirectory.appendingPathComponent(working)) ?? 0
            lock.withLock {
                if !reconstructed,
                   var row = rows[ticket.key.ratingKey],
                   row.attemptID == ticket.key.attemptID,
                   row.pendingArtifactIntents.first?.id == intent.id {
                    row.bytes = durable
                    row.progress = Self.progressForDurableBytes(durable, expectedBytes: expected)
                    if row.metadata?.resumeDisplayBytes != nil,
                       (row.metadata?.resumeDataRelativePath ?? "").isEmpty {
                        row.metadata?.resumeDisplayBytes = nil
                    }
                    setRowLocked(row, for: ticket.key.ratingKey)
                }
                recordStaticCheckpointOutcomeLocked(
                    .persistenceFailed(bytes: durable, prepared.result), ticket: ticket)
            }
            failArtifactLifecycle(ticket, prepared.result); return
        }
        lock.lock()
        guard let current = rows[ticket.key.ratingKey],
              current.attemptID == ticket.key.attemptID,
              current.pendingArtifactIntents.first?.id == intent.id else {
            lock.unlock(); completeArtifactLifecycle(ticket); return
        }
        lock.unlock()
        guard case .acquired(let lease) = tryAcquirePathLease(for: ticket.key,
            relativePaths: Set([working, stable, temporary].compactMap { $0 }), purpose: .artifact) else {
            failArtifactLifecycle(ticket, errorType: "pathBusy"); return
        }
        defer { releasePathLease(lease) }
        let workingURL = baseDirectory.appendingPathComponent(working)
        if reconstructed, !checkpointFilesystem.exists(workingURL) {
            guard let stable, let temporary else {
                failArtifactLifecycle(ticket, errorType: "invalidStaticCheckpointLayout"); return
            }
            do {
                try checkpointFilesystem.durableCopy(
                    baseDirectory.appendingPathComponent(stable), workingURL,
                    baseDirectory.appendingPathComponent(temporary))
            } catch {
                failArtifactLifecycle(ticket, errorType: String(reflecting: type(of: error))); return
            }
        }
        let durable = checkpointFilesystem.size(workingURL) ?? 0
        lock.lock()
        guard var row = rows[ticket.key.ratingKey], row.attemptID == ticket.key.attemptID,
              row.pendingArtifactIntents.first?.id == intent.id else {
            lock.unlock(); completeArtifactLifecycle(ticket); return
        }
        let oldBytes = row.bytes
        let oldProgress = row.progress
        let progress = Self.progressForDurableBytes(durable, expectedBytes: expected)
        if reconstructed { row.attemptWorkingRelativePath = working }
        if row.metadata?.resumeDisplayBytes != nil,
           (row.metadata?.resumeDataRelativePath ?? "").isEmpty {
            row.metadata?.resumeDisplayBytes = nil
        }
        row.bytes = durable; row.progress = progress
        artifactRetirementKeys.insert(ticket.key)
        let retiring = row.pendingArtifactIntents.removeFirst()
        setRowLocked(row, for: ticket.key.ratingKey)
        let terminal = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let terminalOutcome = waitForPersistence(through: terminal)
        guard terminalOutcome.result.committed(through: terminal) else {
            lock.lock()
            if var restored = rows[ticket.key.ratingKey], restored.attemptID == ticket.key.attemptID {
                restored.pendingArtifactIntents.insert(retiring, at: 0)
                setRowLocked(restored, for: ticket.key.ratingKey)
                _ = enqueueAttemptPersistenceLocked()
            }
            artifactRetirementKeys.remove(ticket.key)
            recordStaticCheckpointOutcomeLocked(
                .persistenceFailed(bytes: durable, terminalOutcome.result), ticket: ticket)
            lock.unlock()
            failArtifactLifecycle(ticket, terminalOutcome.result); return
        }
        lock.withLock {
            artifactRetirementKeys.remove(ticket.key)
            recordStaticCheckpointOutcomeLocked((reconstructed
                || oldBytes != durable || abs(oldProgress - progress) > 0.000_001)
                ? .applied(bytes: durable) : .unchanged(bytes: durable), ticket: ticket)
        }
        completeArtifactLifecycle(ticket)
    }

    /// Every local path for which a row still has durable ownership or lifecycle authority.
    /// Destructive workers use this for cross-row exclusion, including paths captured only by a
    /// pending intent rather than ordinary published metadata.
    private func artifactPathsReferenced(by row: Row) -> Set<String> {
        var result: Set<String> = [row.relativePath]
        for (path, owner) in sideAssetPublicationOwners
            where row.attemptID == owner.key.attemptID && row.ratingKey == owner.key.ratingKey
                && row.metadata?.sideAssetSourceIdentity == owner.source {
            result.insert(path)
        }
        if let working = row.attemptWorkingRelativePath { result.insert(working) }
        result.formUnion(sideAssetRelativePaths(for: row.metadata))
        if let resume = row.metadata?.resumeDataRelativePath { result.insert(resume) }
        result.formUnion((row.metadata?.heldRangeSegments ?? []).map(\.relativePath))
        result.formUnion(row.heldRangeBodyDeletionIntents)
        for intent in row.pendingArtifactIntents {
            switch intent.operation {
            case .replaceResumeBlob(let new, let previous, _):
                result.insert(new)
                if let previous { result.insert(previous) }
            case .clearResumeBlob(let relative, _):
                if let relative { result.insert(relative) }
            case .heldBodyDeletion(let paths):
                result.formUnion(paths)
            case .staticCheckpoint(let working, let stable, let temporary, _, _):
                result.insert(working)
                if let stable { result.insert(stable) }
                if let temporary { result.insert(temporary) }
            case .validatedPromotion(let working, let stable, _, _):
                result.insert(working)
                result.insert(stable)
            case .rowDeletion(let paths, _, _):
                result.formUnion(paths)
            }
        }
        return result
    }

    /// Row deletion is a terminal queue barrier: no successor artifact or newly-referenced path
    /// can be admitted behind it because successful execution removes the row.
    private static func hasPendingRowDeletion(_ row: Row) -> Bool {
        row.pendingArtifactIntents.contains { intent in
            if case .rowDeletion = intent.operation { return true }
            return false
        }
    }

    func durableStaticRangeCheckpointSize(ratingKey: String) -> Int {
        lock.lock()
        let row = rows[ratingKey]
        lock.unlock()
        guard let row,
              row.metadata?.resolvedResumeMode(ratingKey: row.ratingKey) == .staticByteRange else {
            return 0
        }
        return fileSize(relativePath: row.relativePath) ?? 0
    }

    func durableStaticRangeCheckpointSize(for key: DownloadAttemptKey) -> Int? {
        let snapshot = lock.withLock { (rows[key.ratingKey], rowMutationGenerations[key.ratingKey, default: 0]) }
        guard let row = snapshot.0, row.attemptID == key.attemptID,
              row.metadata?.resolvedResumeMode(ratingKey: row.ratingKey) == .staticByteRange else { return nil }
        let bytes: Int?
        if row.status == .complete || row.status == .unverified {
            bytes = Self.isSafeOneLevelRelativePath(row.relativePath) ? fileSize(relativePath: row.relativePath) ?? 0 : nil
        } else if row.history.isBodyCondemned {
            bytes = 0
        } else {
            bytes = workingRelativePath(for: row, key: key).map { fileSize(relativePath: $0) ?? 0 }
        }
        return lock.withLock { rowMutationGenerations[key.ratingKey, default: 0] == snapshot.1 ? bytes : nil }
    }

    /// #169: ratingKeys for static byte-range rows that were ACTIVELY transferring (`.downloading`/
    /// `.queued`) — NOT user-paused — when the app died. A row may have zero durable bytes if the
    /// first background range body was still in the OS temp file; it is still a system-interrupted active
    /// download and should restart from byte 0 rather than waiting for a manual tap.
    /// Must be read BEFORE `reconcile`, which parks them `.paused` (conflating them with a deliberate
    /// user pause). The launch auto-resume uses this to continue interrupted downloads after a process
    /// kill without overriding a row the user actually paused. Durable checkpoint size is still read
    /// from the file system by reconciliation/resume; optimistic row bytes are never used here.
    func interruptedStaticByteRangeKeys() -> [String] {
        lock.lock(); let snapshot = Array(rows.values); lock.unlock()
        return snapshot.compactMap { row in
            guard row.status == .downloading || row.status == .queued,
                  row.metadata?.resolvedResumeMode(ratingKey: row.ratingKey) == .staticByteRange else { return nil }
            return row.ratingKey
        }
    }

    /// Launch/device-test evidence for every nonterminal static row. This reads file metadata only;
    /// it never opens the potentially large resume/held bodies.
    func staticRangeRecoveryEvidence() -> [StaticRangeRecoveryEvidence] {
        lock.lock()
        let snapshot = Array(rows.values)
        lock.unlock()
        return snapshot.compactMap { row in
            guard row.metadata?.resolvedResumeMode(ratingKey: row.ratingKey) == .staticByteRange,
                  row.status != .complete, row.status != .unverified,
                  let attemptID = row.attemptID else { return nil }
            let key = DownloadAttemptKey(ratingKey: row.ratingKey, attemptID: attemptID)
            guard let workingRelative = workingRelativePath(for: row, key: key) else { return nil }
            let resumeRelative = row.metadata?.resumeDataRelativePath
            let resumeURL = resumeRelative.flatMap { relative in
                Self.isSafeOneLevelRelativePath(relative)
                    ? baseDirectory.appendingPathComponent(relative) : nil
            }
            let resumeBytes = resumeURL.flatMap(fileSize(at:)) ?? 0
            let held = row.metadata?.heldRangeSegments ?? []
            return StaticRangeRecoveryEvidence(
                ratingKey: row.ratingKey,
                status: row.status,
                durableBytes: fileSize(relativePath: workingRelative) ?? 0,
                resumeManifestRecorded: resumeRelative?.isEmpty == false,
                resumeBlobPresent: resumeURL.map { fileManager.fileExists(atPath: $0.path) } ?? false,
                resumeBlobBytes: resumeBytes,
                heldBodyCount: held.count,
                heldBodyBytes: held.reduce(0) { $0 + max(0, $1.length) }
            )
        }
    }

    func staticRangeRecoveryEvidence(
        for key: DownloadAttemptKey
    ) -> StaticRangeRecoveryEvidence? {
        let snapshot = lock.withLock { (rows[key.ratingKey], rowMutationGenerations[key.ratingKey, default: 0]) }
        guard let row = snapshot.0, row.attemptID == key.attemptID,
              row.metadata?.resolvedResumeMode(ratingKey: row.ratingKey) == .staticByteRange,
              row.status != .complete, row.status != .unverified else { return nil }
        let resumeRelative = row.metadata?.resumeDataRelativePath
        let resumeURL = resumeRelative.flatMap { relative in
            Self.isSafeOneLevelRelativePath(relative)
                ? baseDirectory.appendingPathComponent(relative) : nil
        }
        let held = row.metadata?.heldRangeSegments ?? []
        guard let workingRelative = workingRelativePath(for: row, key: key) else { return nil }
        let evidence = StaticRangeRecoveryEvidence(
            ratingKey: row.ratingKey,
            status: row.status,
            durableBytes: fileSize(relativePath: workingRelative) ?? 0,
            resumeManifestRecorded: resumeRelative?.isEmpty == false,
            resumeBlobPresent: resumeURL.map { fileManager.fileExists(atPath: $0.path) } ?? false,
            resumeBlobBytes: resumeURL.flatMap(fileSize(at:)) ?? 0,
            heldBodyCount: held.count,
            heldBodyBytes: held.reduce(0) { $0 + max(0, $1.length) }
        )
        return lock.withLock { rowMutationGenerations[key.ratingKey, default: 0] == snapshot.1 ? evidence : nil }
    }

    private func updateMetadata(ratingKey: String, mutate: (inout OfflineMetadata) -> Void) {
        lock.lock()
        guard var row = rows[ratingKey], !Self.hasPendingRowDeletion(row),
              var meta = row.metadata else { lock.unlock(); return }
        let oldMeta = meta
        let previousSideAssetPaths = Set(sideAssetRelativePaths(for: oldMeta))
        mutate(&meta)
        let mutatedSideAssetPaths = Set(sideAssetRelativePaths(for: meta))
        if meta.sideAssetSourceIdentity != oldMeta.sideAssetSourceIdentity,
           !previousSideAssetPaths.isEmpty {
            meta.clearCachedSideAssets()
        } else if let attemptID = row.attemptID {
            if mutatedSideAssetPaths != previousSideAssetPaths {
                meta.claimCachedSideAssets(attemptID: attemptID.rawValue)
            } else {
                meta.fenceCachedSideAssets(to: attemptID.rawValue)
            }
        } else if !mutatedSideAssetPaths.isEmpty {
            meta.clearCachedSideAssets()
        }
        guard meta != oldMeta else { lock.unlock(); return }
        var proposed = row
        proposed.metadata = meta
        let newlyReferenced = artifactPathsReferenced(by: proposed)
            .subtracting(artifactPathsReferenced(by: row))
        guard newlyReferenced.allSatisfy({ Self.isSafeOneLevelRelativePath($0) && reservedArtifactDeletionPaths[$0] == nil }) else {
            lock.unlock(); return
        }
        row.metadata = meta
        setRowLocked(row, for: ratingKey)
        sideAssetHydrationCache.removeValue(forKey: ratingKey)
        lock.unlock()
        let persistence = persist()
        if persistence.result.committed(through: persistence.ticket),
           let attemptID = row.attemptID {
            let retired = previousSideAssetPaths
                .subtracting(sideAssetRelativePaths(for: meta))
            retireUnreferencedSideAssets(
                retired,
                confirmingCurrentOwner: DownloadAttemptKey(
                    ratingKey: ratingKey, attemptID: attemptID))
        }
    }

    /// Attempt-conditional metadata mutation. The top-level attempt ID remains authoritative and
    /// its rollback shadow cannot be changed by a metadata closure.
    @discardableResult
    private func updateMetadataOnWorker(
        for key: DownloadAttemptKey,
        expectedSideAssetSource: OfflineSideAssetSourceIdentity? = nil,
        mutate: (inout OfflineMetadata) -> Void
    ) -> AttemptMutationResult {
        let previousPaths = record(for: key).map {
            Set(sideAssetRelativePaths(for: $0.metadata))
        } ?? []
        let result = awaitAttemptMutationSubmission(submitMetadata(
            for: key, expectedSideAssetSource: expectedSideAssetSource, mutate: mutate))
        if result == .applied || result == .noChange,
           let current = record(for: key) {
            let retired = previousPaths
                .subtracting(sideAssetRelativePaths(for: current.metadata))
            retireUnreferencedSideAssets(retired, confirmingCurrentOwner: key)
        }
        return result
    }

    func updateMetadataAsync(for key: DownloadAttemptKey,
                             expectedSideAssetSource: OfflineSideAssetSourceIdentity? = nil,
                             isolation: isolated (any Actor)? = #isolation,
                             mutate: (inout OfflineMetadata) -> Void) async -> AttemptMutationResult {
        let previous = lock.withLock { Set(sideAssetRelativePaths(for: rows[key.ratingKey]?.metadata)) }
        let submission = submitMetadata(for: key, expectedSideAssetSource: expectedSideAssetSource, mutate: mutate)
        let result = await resolve(submission, deadline: .after(30))
        if result == .applied || result == .noChange {
            let retired = lock.withLock { previous.subtracting(sideAssetRelativePaths(for: rows[key.ratingKey]?.metadata)) }
            _ = await DownloadStoreWork { self.retireUnreferencedSideAssets(retired, confirmingCurrentOwner: key); return true }
                .resolve(deadline: .after(30), timedOut: { false })
        }
        return result
    }

    /// Nonblocking exact-attempt metadata admission used by background delegate and teardown
    /// lifecycle paths. The synchronous compatibility API above awaits this same ticket.
    @discardableResult
    func submitMetadata(
        for key: DownloadAttemptKey,
        expectedSideAssetSource: OfflineSideAssetSourceIdentity? = nil,
        mutate: (inout OfflineMetadata) -> Void
    ) -> AttemptMutationSubmission {
        lock.lock()
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID,
              !Self.hasPendingRowDeletion(row),
              var metadata = row.metadata else {
            lock.unlock()
            return .staleOrMissing
        }
        if let expectedSideAssetSource,
           metadata.sideAssetSourceIdentity != expectedSideAssetSource {
            lock.unlock()
            return .staleOrMissing
        }
        let previous = metadata
        let previousSideAssetPaths = Set(sideAssetRelativePaths(for: previous))
        mutate(&metadata)
        let mutatedSideAssetPaths = Set(sideAssetRelativePaths(for: metadata))
        if metadata.sideAssetSourceIdentity != previous.sideAssetSourceIdentity,
           !previousSideAssetPaths.isEmpty {
            metadata.clearCachedSideAssets()
        } else {
            if mutatedSideAssetPaths != previousSideAssetPaths {
                metadata.claimCachedSideAssets(attemptID: key.attemptID.rawValue)
            } else {
                metadata.fenceCachedSideAssets(to: key.attemptID.rawValue)
            }
        }
        metadata.downloadAttemptID = key.attemptID.rawValue
        guard metadata != previous else {
            let ticket = enqueueAttemptPersistenceLocked()
            lock.unlock()
            return .accepted(change: .noChange, ticket: ticket)
        }
        var proposed = row
        proposed.metadata = metadata
        let newlyReferenced = artifactPathsReferenced(by: proposed)
            .subtracting(artifactPathsReferenced(by: row))
        guard newlyReferenced.allSatisfy({ Self.isSafeOneLevelRelativePath($0) && reservedArtifactDeletionPaths[$0] == nil }) else {
            lock.unlock(); return .staleOrMissing
        }
        row.metadata = metadata
        setRowLocked(row, for: key.ratingKey)
        sideAssetHydrationCache.removeValue(forKey: key.ratingKey)
        let ticket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        return .accepted(change: .applied, ticket: ticket)
    }

    /// Update transfer progress for an in-flight download. Moving any bytes from a task still owned by
    /// the session means the transfer is live, so we promote any non-terminal transfer row to
    /// `.downloading` here (D2: the UI distinguishes "waiting on server" from "actively transferring").
    ///
    /// Disk writes are throttled: the in-memory row updates on every callback (the
    /// UI reads live progress from `records`), but the JSON index is rewritten at
    /// most once per second. The session delegate fires `didWriteData` many times a
    /// second on fast transfers, and re-encoding the index each time thrashes I/O
    /// for no benefit — stale persisted progress is harmless because `reconcile`
    /// distrusts any non-live `.downloading` row at relaunch anyway, and the
    /// terminal `setStatus` always persists.
    func updateProgress(ratingKey: String, bytes: Int, progress: Double) {
        lock.lock()
        guard var row = rows[ratingKey] else { lock.unlock(); return }
        row.bytes = bytes
        row.progress = progress
        let previousStatus = row.status
        let previousLifecycle = row.lifecycle
        Self.reduceLocked(.transferProgress, on: &row)
        let statusChanged = row.lifecycle != previousLifecycle
        setRowLocked(row, for: ratingKey)
        let now = Date()
        let shouldPersist = statusChanged
            || now.timeIntervalSince(lastProgressPersist) >= Self.progressPersistInterval
        if shouldPersist { lastProgressPersist = now }
        lock.unlock()
        if statusChanged {
            AppDiagnostics.record(.downloads, "downloads.status_transition", fields: [
                "download_id": .identifier(ratingKey),
                "from": .label(previousStatus.rawValue),
                "to": .label(DownloadStatus.downloading.rawValue),
                "bytes_exact": .int(bytes),
                "progress_percent": .int(Int((progress * 100).rounded(.down))),
                "source": .label("progress"),
            ])
        }
        if shouldPersist { persist() }
    }

    @discardableResult
    func updateProgress(
        for key: DownloadAttemptKey,
        bytes: Int,
        progress: Double
    ) -> AttemptMutationResult {
        awaitAttemptMutationSubmission(
            submitProgress(for: key, bytes: bytes, progress: progress)
        )
    }

    /// Nonblocking exact-attempt progress admission for URLSession/lifecycle paths. The live row
    /// always changes immediately. Throttled samples intentionally carry no persistence ticket;
    /// status-changing or cadence-selected samples carry the exact accepted revision.
    @discardableResult
    func submitProgress(
        for key: DownloadAttemptKey,
        bytes: Int,
        progress: Double
    ) -> AttemptMutationSubmission {
        lock.lock()
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID else {
            lock.unlock()
            return .staleOrMissing
        }
        let previousStatus = row.status
        // P3a/B09: progress is the `transferProgress` event. It may move an admitted row to
        // transferring, but never promotes a paused, failed or finalizing row; those only record
        // their bytes (`checkpointAdvanced`).
        let previousLifecycle = row.lifecycle
        if case .applied(let next, _) = DownloadLifecycleReducer.reduce(
            DownloadLifecycleState(lifecycle: row.lifecycle, history: row.history),
            .transferProgress, facts: DownloadRowFacts(route: .staticRange)) {
            row.lifecycle = next.lifecycle
            row.history = next.history
        }
        let statusChanged = row.lifecycle != previousLifecycle
        let changed = row.bytes != bytes || row.progress != progress || statusChanged
        guard changed else {
            lock.unlock()
            return .accepted(change: .noChange, ticket: nil)
        }
        row.bytes = bytes
        row.progress = progress
        setRowLocked(row, for: key.ratingKey)
        let now = Date()
        let shouldPersist = statusChanged
            || now.timeIntervalSince(lastProgressPersist) >= Self.progressPersistInterval
        if shouldPersist { lastProgressPersist = now }
        let ticket = shouldPersist ? enqueueAttemptPersistenceLocked() : nil
        lock.unlock()
        if statusChanged {
            AppDiagnostics.record(.downloads, "downloads.status_transition", fields: [
                "download_id": .identifier(key.ratingKey),
                "from": .label(previousStatus.rawValue),
                "to": .label(DownloadStatus.downloading.rawValue),
                "bytes_exact": .int(bytes),
                "progress_percent": .int(Int((progress * 100).rounded(.down))),
                "source": .label("progress_attempt"),
            ])
        }
        return .accepted(change: .applied, ticket: ticket)
    }

    enum LifecycleEventSubmission: Sendable, Equatable {
        case accepted(effects: [DownloadLifecycleEffect], ticket: PersistenceTicket?)
        case rejected(DownloadLifecycleTransition.Rejection)
        case staleOrMissing
    }

    /// Apply a reducer event to a row the caller holds under the lock. Events whose result never
    /// depends on route or body facts use this; a rejected event leaves the row unchanged.
    @discardableResult
    private static func reduceLocked(_ event: DownloadLifecycleEvent, on row: inout Row) -> Bool {
        guard case .applied(let next, _) = DownloadLifecycleReducer.reduce(
            DownloadLifecycleState(lifecycle: row.lifecycle, history: row.history),
            event, facts: DownloadRowFacts(route: .staticRange)) else { return false }
        row.lifecycle = next.lifecycle
        row.history = next.history
        return true
    }

    fileprivate static func terminalLifecycle(_ status: DownloadStatus) -> DownloadLifecycle {
        status == .unverified ? .unverified : .complete
    }

    /// The validated-promotion terminal snapshot: a finalizing row commits through
    /// `promotionCommitted`; any other row (legacy or revalidation) through `promotionRecovered`.
    private static func applyPromotionTerminal(_ status: DownloadStatus, on row: inout Row) {
        let terminal = terminalLifecycle(status)
        if !reduceLocked(.promotionCommitted(terminal), on: &row) {
            reduceLocked(.promotionRecovered(terminal), on: &row)
        }
    }

    /// Snapshot row authority, observe files off-lock and reject observations overtaken by a
    /// row mutation. Session-owned facts (a live task) come from the caller.
    func lifecycleFacts(for key: DownloadAttemptKey, liveTask: Bool = false) -> DownloadRowFacts {
        for _ in 0..<3 {
            let snapshot = lock.withLock { (rows[key.ratingKey], rowMutationGenerations[key.ratingKey, default: 0]) }
            guard let row = snapshot.0, row.attemptID == key.attemptID else {
                return DownloadRowFacts(route: .staticRange)
            }
            let facts = observeLifecycleFacts(row: row, key: key, liveTask: liveTask)
            if lock.withLock({ rowMutationGenerations[key.ratingKey, default: 0] == snapshot.1 }) { return facts }
        }
        return DownloadRowFacts(route: .staticRange, pendingArtifactHead: true)
    }

    private func observeLifecycleFacts(row: Row, key: DownloadAttemptKey, liveTask: Bool, observeFiles: Bool = true)
        -> DownloadRowFacts {
        let metadata = row.metadata
        let resumeMode = metadata?.resolvedResumeMode(ratingKey: row.ratingKey)
        let backend = metadata?.resolvedBackendKind(ratingKey: row.ratingKey)
            ?? DownloadBackendKind(ratingKeyPrefix: row.ratingKey)
        let route: DownloadRowFacts.Route
        switch (resumeMode, backend) {
        case (.serverPrepThenStatic?, .emby):
            route = .embyConvert(hasJobOrIdentity: metadata?.embyConvertJobID != nil
                                 || metadata?.hasEmbyConvertCrashWindowIdentity == true)
        case (.serverPrepThenStatic?, _): route = .plexPrep
        case (.liveForwardOnly?, _): route = .forwardOnly
        default: route = .staticRange
        }
        let workingBytes = (observeFiles ? workingRelativePath(for: row, key: key) : nil)
            .flatMap { fileSize(at: baseDirectory.appendingPathComponent($0)) } ?? 0
        let resumeRelative = metadata?.resumeDataRelativePath
        let checkpoint: DownloadRowFacts.Checkpoint
        // Pre-P3a reconcile precedence: an app-owned static partial is the checkpoint whether or
        // not a resume manifest also exists, and a manifest counts only while its blob survives.
        if row.history.isBodyCondemned {
            checkpoint = .none   // a condemned body is never a checkpoint
        } else if route == .staticRange, workingBytes > 0 {
            checkpoint = .durablePartial(bytes: workingBytes)
        } else if observeFiles, let resumeRelative, Self.isSafeOneLevelRelativePath(resumeRelative),
                  fileManager.fileExists(
                      atPath: baseDirectory.appendingPathComponent(resumeRelative).path) {
            checkpoint = .resumeBlob
        } else {
            checkpoint = .none
        }
        let body: DownloadRowFacts.Body
        if observeFiles && (row.lifecycle.isTerminal || row.status == .complete || row.status == .unverified) {
            body = Self.isSafeOneLevelRelativePath(row.relativePath) && fileManager.fileExists(
                atPath: baseDirectory.appendingPathComponent(row.relativePath).path)
                ? .published : .none
        } else if workingBytes > 0, row.lifecycle == .finalizing || route == .forwardOnly {
            // A forward-only body reaches the working path only once its transfer finished.
            body = .workingComplete
        } else {
            body = .none
        }
        return DownloadRowFacts(
            route: route, checkpoint: checkpoint, body: body,
            pendingArtifactHead: !row.pendingArtifactIntents.isEmpty,
            deletionPending: row.deletionPending, liveTask: liveTask)
    }

    /// Convenience for call sites whose event does not depend on session-owned facts.
    @discardableResult
    func submitLifecycleEvent(
        _ event: DownloadLifecycleEvent,
        for key: DownloadAttemptKey,
        liveTask: Bool = false
    ) -> LifecycleEventSubmission {
        if event == .relaunchObserved {
            for _ in 0..<3 {
                let snapshot = lock.withLock { (rows[key.ratingKey], rowMutationGenerations[key.ratingKey, default: 0]) }
                guard let row = snapshot.0, row.attemptID == key.attemptID else { return .staleOrMissing }
                let facts = observeLifecycleFacts(row: row, key: key, liveTask: liveTask)
                lock.lock()
                guard rowMutationGenerations[key.ratingKey, default: 0] == snapshot.1 else { lock.unlock(); continue }
                return submitLifecycleEventLocked(event, for: key, facts: facts)
            }
            return .staleOrMissing
        }
        lock.lock()
        guard let row = rows[key.ratingKey], row.attemptID == key.attemptID else { lock.unlock(); return .staleOrMissing }
        let facts = observeLifecycleFacts(row: row, key: key, liveTask: liveTask, observeFiles: false)
        return submitLifecycleEventLocked(event, for: key, facts: facts)
    }

    /// The P3a way to change an exact attempt's lifecycle: run the pure reducer under the store
    /// lock, persist the new lifecycle and history in one revision, and return the committed
    /// effects for the caller to execute. A rejected event changes nothing.
    @discardableResult
    func submitLifecycleEvent(
        _ event: DownloadLifecycleEvent,
        for key: DownloadAttemptKey,
        facts: DownloadRowFacts
    ) -> LifecycleEventSubmission {
        lock.lock()
        return submitLifecycleEventLocked(event, for: key, facts: facts)
    }

    private func submitLifecycleEventLocked(_ event: DownloadLifecycleEvent, for key: DownloadAttemptKey,
                                            facts: DownloadRowFacts) -> LifecycleEventSubmission {
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID else {
            lock.unlock()
            return .staleOrMissing
        }
        let previousStatus = row.status
        switch DownloadLifecycleReducer.reduce(
            DownloadLifecycleState(lifecycle: row.lifecycle, history: row.history),
            event, facts: facts) {
        case .rejected(let rejection):
            lock.unlock()
            return .rejected(rejection)
        case .applied(let next, let effects):
            row.lifecycle = next.lifecycle
            row.history = next.history
            setRowLocked(row, for: key.ratingKey)
            let ticket = enqueueAttemptPersistenceLocked()
            let bytes = row.bytes
            let progress = row.progress
            let status = row.status
            lock.unlock()
            if previousStatus != status {
                AppDiagnostics.record(.downloads, "downloads.status_transition", fields: [
                    "download_id": .identifier(key.ratingKey),
                    "from": .label(previousStatus.rawValue),
                    "to": .label(status.rawValue),
                    "bytes_exact": .int(bytes),
                    "progress_percent": .int(Int((progress * 100).rounded(.down))),
                    "source": .label("lifecycle_event"),
                ])
            }
            return .accepted(effects: effects, ticket: ticket)
        }
    }

    #if DEBUG
    // P3a: test fixtures only. Production status changes go through `submitLifecycleEvent`;
    // `scripts/ci-hygiene.sh` rejects any non-fixture status write.
    /// Set the explicit lifecycle status for a row (D2). No-op if the row is gone.
    func setStatus(ratingKey: String, _ status: DownloadStatus) {
        lock.lock()
        guard var row = rows[ratingKey] else { lock.unlock(); return }
        let previousStatus = row.status
        let bytes = row.bytes
        let progress = row.progress
        row.status = status // P3a-legacy-fixture
        setRowLocked(row, for: ratingKey)
        lock.unlock()
        if previousStatus != status {
            AppDiagnostics.record(.downloads, "downloads.status_transition", fields: [
                "download_id": .identifier(ratingKey),
                "from": .label(previousStatus.rawValue),
                "to": .label(status.rawValue),
                "bytes_exact": .int(bytes),
                "progress_percent": .int(Int((progress * 100).rounded(.down))),
                "source": .label("setStatus"),
            ])
        }
        persist()
    }

    @discardableResult
    func setStatus(
        for key: DownloadAttemptKey,
        _ status: DownloadStatus
    ) -> AttemptMutationResult {
        awaitAttemptMutationSubmission(submitStatus(for: key, status))
    }

    /// Nonblocking exact-attempt lifecycle transition. Even an unchanged status submits a full
    /// snapshot so a prior dirty transition is retried and the returned ticket is real proof for
    /// the enclosing bounded completion barrier.
    @discardableResult
    func submitStatus(
        for key: DownloadAttemptKey,
        _ status: DownloadStatus
    ) -> AttemptMutationSubmission {
        lock.lock()
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID else {
            lock.unlock()
            return .staleOrMissing
        }
        let previousStatus = row.status
        guard previousStatus != status else {
            let ticket = enqueueAttemptPersistenceLocked()
            lock.unlock()
            return .accepted(change: .noChange, ticket: ticket)
        }
        let bytes = row.bytes
        let progress = row.progress
        row.status = status // P3a-legacy-fixture
        setRowLocked(row, for: key.ratingKey)
        let ticket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        AppDiagnostics.record(.downloads, "downloads.status_transition", fields: [
            "download_id": .identifier(key.ratingKey),
            "from": .label(previousStatus.rawValue),
            "to": .label(status.rawValue),
            "bytes_exact": .int(bytes),
            "progress_percent": .int(Int((progress * 100).rounded(.down))),
            "source": .label("setStatus_attempt"),
        ])
        return .accepted(change: .applied, ticket: ticket)
    }
    #endif

    /// Promote a previously byte-complete but probe-inconclusive row once a later validation or
    /// actual local playback proves the file is usable. No-op for already-complete/active/failed rows
    /// so callers can safely invoke this from reconnect and playback-progress paths.
    @discardableResult
    func markCompleteIfUnverifiedOnWorker(
        for key: DownloadAttemptKey
    ) -> AttemptUnverifiedPromotionResult {
        lock.lock()
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID else {
            lock.unlock()
            return .staleOrMissing
        }
        guard row.status == .unverified else {
            lock.unlock()
            return .notUnverified
        }
        Self.reduceLocked(.localPlaybackProgressed, on: &row)
        setRowLocked(row, for: key.ratingKey)
        let ticket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        AppDiagnostics.record(.downloads, "downloads.unverified_promoted", fields: [
            "download_id": .identifier(key.ratingKey),
            "source": .label("local_playback"),
        ])
        let persistence = waitForPersistence(through: ticket)
        return persistence.result.committed(through: persistence.ticket)
            ? .promoted : .persistenceFailed(persistence.result)
    }

    /// Reconcile persisted rows against disk at launch (D2).
    ///
    /// A row left `.queued`/`.downloading` from a previous run whose task did NOT
    /// survive relaunch can't usually be trusted: it was never validated/marked
    /// `.complete`, so even a file on disk may be partial. We mark such rows `.failed`
    /// (retryable) rather than letting the UI spin forever on a dead transfer.
    ///
    /// Plex optimized/download-prep rows are the exception: Plex may still be
    /// rendering the compatible file and the app must resume polling after relaunch.
    /// We reset their local transfer counters and keep them `.queued`; any partial
    /// local file is removed so the eventual compatible part starts from a clean
    /// download. Jellyfin optimized rows are NOT server-prep rows: they stream from a
    /// live URLSession task, so if that task is gone they must stay retryable-failed.
    ///
    /// A `.complete` row whose file has since vanished is likewise demoted to `.failed`.
    /// `liveRatingKeys` are the ratingKeys the background session reattached to —
    /// genuinely still in flight and left untouched. `snapshotRatingKeys` are the rows that
    /// existed when the task snapshot was requested: rows seeded on the main actor after that
    /// point are skipped entirely, or a brand-new `.queued` row (or a static row mid retry
    /// rebuild) would be demoted against a snapshot that predates it.
    /// Relaunch/foreground recovery (P3a): each eligible row's facts go through the reducer's
    /// `relaunchObserved`. Lifecycle and byte accounting change under the lock; file deletions are
    /// durable decisions executed after it is released (st-41).
    /// Take a working body a failure verdict condemned off its working path at once (P3a).
    /// The atomic rename gives it a fresh attempt-staging name that no row references, so it can
    /// never again be a checkpoint, a recovery source or a Retry clone, whatever later happens
    /// to the row. Returns the condemned URL, or nil when the attempt no longer owns that path.
    func condemnWorkingBody(at url: URL, for key: DownloadAttemptKey) -> URL? {
        let condemned = baseDirectory.appendingPathComponent(Self.attemptStagingRelativePath(
            for: key, stableRelativePath: "condemned-\(UUID().uuidString)"))
        guard url.deletingLastPathComponent().standardizedFileURL == baseDirectory.standardizedFileURL,
              case .acquired(let lease) = tryAcquirePathLease(for: key,
                relativePaths: [url.lastPathComponent, condemned.lastPathComponent], purpose: .reconcile) else { return nil }
        defer { releasePathLease(lease) }
        let generation = lock.withLock { () -> UInt64? in
            guard let row = rows[key.ratingKey], row.attemptID == key.attemptID,
                  uncheckedWorkingRelativePath(for: row, key: key) == url.lastPathComponent,
                  !rows.values.contains(where: { $0.ratingKey != key.ratingKey && artifactPathsReferenced(by: $0).contains(url.lastPathComponent) }) else { return nil }
            return rowMutationGenerations[key.ratingKey, default: 0]
        }
        guard let generation, let identity = condemnedFileIdentity(at: url) else { return nil }
        storeFilesystem.before(.rename, url)
        guard condemnedFileIdentity(at: url) == identity,
              lock.withLock({ rowMutationGenerations[key.ratingKey, default: 0] == generation }) else { return nil }
        guard storeFilesystem.rename(url, condemned) == 0 else {
            let renameErrno = errno
            let deleted = (try? storeFilesystem.removeItem(at: url, using: fileManager)) != nil
            AppDiagnostics.record(.downloads, "downloads.condemn_rename_failed", fields: [
                "download_id": .identifier(key.ratingKey), "errno": .int(Int(renameErrno)), "deleted_in_place": .bool(deleted)])
            return nil
        }
        return condemned
    }

    /// Delete a condemned body once its verdict's revision commits, or after `timeout` if it
    /// cannot: the body is no longer anyone's checkpoint, and keeping multi-GB bytes while the
    /// index cannot be written (often a full volume) only makes that worse. An unchanged file
    /// identity is required. Returns whether the verdict was proven committed first.
    @discardableResult
    func deleteCondemnedBody(
        at condemned: URL,
        afterCommitOf ticket: PersistenceTicket?,
        timeout: TimeInterval = 30
    ) async -> Bool {
        let identity = condemnedFileIdentity(at: condemned)
        var committed = false
        if let ticket, case .committed(let revision) = await flushPersistence(
            through: ticket, timeout: timeout) {
            committed = revision >= ticket.revision
        }
        // Bounded retries: the name is unreferenced and absent from this launch's staging
        // inventory, so nothing else in this process would reclaim it.
        for attempt in 0..<3 {
            guard let identity, condemnedFileIdentity(at: condemned) == identity else { break }
            if (try? fileManager.removeItem(at: condemned)) != nil { break }
            if attempt == 2 {
                AppDiagnostics.record(.downloads, "downloads.condemned_body_delete_failed", fields: [
                    "bytes": .bytes(Int(clamping: identity.size)),
                ])
            } else {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        return committed
    }

    /// The identity of a file reconcile condemned: inode, size and modification time.
    struct CondemnedFileIdentity: Equatable {
        let fileNumber: UInt64
        let size: UInt64
        let modified: Date
    }

    private func condemnedFileIdentity(at url: URL) -> CondemnedFileIdentity? {
        guard let attributes = try? storeFilesystem.attributes(atPath: url.path, using: fileManager),
              let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return CondemnedFileIdentity(fileNumber: fileNumber, size: size, modified: modified)
    }

    func reconcileOnWorker(liveRatingKeys: Set<String>, snapshotRatingKeys: Set<String>) {
        let candidates = lock.withLock { Array(rows.keys).filter { snapshotRatingKeys.contains($0) } }
        for ratingKey in candidates {
            for _ in 0..<3 {
                let snapshot = lock.withLock { (rows[ratingKey], rowMutationGenerations[ratingKey, default: 0]) }
                guard var row = snapshot.0, !row.deletionPending, row.pendingArtifactIntents.isEmpty,
                      DownloadStatus.reconcileEligible(ratingKey: ratingKey, snapshotRatingKeys: snapshotRatingKeys) else { break }
                let key = DownloadAttemptKey(ratingKey: ratingKey,
                    attemptID: row.attemptID ?? DownloadAttemptID(rawValue: "unowned-legacy-row")!)
                let hasLiveTask = liveRatingKeys.contains(ratingKey)
                let facts = observeLifecycleFacts(row: row, key: key, liveTask: hasLiveTask)
                guard case .applied(let next, let effects) = DownloadLifecycleReducer.reduce(
                    DownloadLifecycleState(lifecycle: row.lifecycle, history: row.history), .relaunchObserved, facts: facts) else { break }
                let working = workingRelativePath(for: row, key: key).map { baseDirectory.appendingPathComponent($0) }
                let partialBytes = working.flatMap(fileSize(at:)) ?? 0
                var deletions: [(URL, CondemnedFileIdentity?, Bool)] = []
                for effect in effects {
                    switch effect {
                    case .resetBytesToZero: row.bytes = 0; row.progress = 0
                    case .resetBytesToDurableCheckpoint:
                        row.bytes = partialBytes
                        row.progress = Self.progressForDurableBytes(partialBytes, expectedBytes: Self.expectedBytesEstimate(row: row))
                    case .deleteWorkingBody:
                        if let working, let identity = condemnedFileIdentity(at: working) { deletions.append((working, identity, false)) }
                    case .clearResumeBlob:
                        if let relative = row.metadata?.resumeDataRelativePath, Self.isSafeOneLevelRelativePath(relative) {
                            let url = baseDirectory.appendingPathComponent(relative)
                            deletions.append((url, condemnedFileIdentity(at: url), true))
                        }
                    default: break
                    }
                }
                if case .staticRange = facts.route, !hasLiveTask, partialBytes == 0,
                   next.lifecycle != .complete, next.lifecycle != .unverified, next.lifecycle != .finalizing {
                    row.bytes = 0; row.progress = 0
                }
                lock.lock()
                guard rowMutationGenerations[ratingKey, default: 0] == snapshot.1 else { lock.unlock(); continue }
                let previous = rows[ratingKey]!
                let changed = next != DownloadLifecycleState(lifecycle: previous.lifecycle, history: previous.history)
                    || row.bytes != previous.bytes || abs(row.progress - previous.progress) > 0.000_001
                guard changed || !deletions.isEmpty else { lock.unlock(); break }
                row.lifecycle = next.lifecycle; row.history = next.history
                setRowLocked(row, for: ratingKey)
                let generation = rowMutationGenerations[ratingKey, default: 0]
                let ticket = enqueueAttemptPersistenceLocked()
                lock.unlock()
                guard waitForPersistence(through: ticket).result.committed(through: ticket) else { break }
                #if DEBUG
                reconcileBeforeDeletionsForTesting?()
                #endif
                for (url, identity, resume) in deletions {
                    let eligible = lock.withLock { () -> Bool in
                        guard let current = rows[ratingKey], current.attemptID == row.attemptID,
                              current.lifecycle == next.lifecycle, !current.deletionPending,
                              current.pendingArtifactIntents.isEmpty,
                              rowMutationGenerations[ratingKey, default: 0] == generation,
                              !rows.values.contains(where: { $0.ratingKey != ratingKey && artifactPathsReferenced(by: $0).contains(url.lastPathComponent) }) else { return false }
                        return true
                    }
                    guard eligible, condemnedFileIdentity(at: url) == identity else { continue }
                    if resume {
                        // The serialized clear recipe retains the reference on failure and replays
                        // after a crash. Never unlink the blob behind a live manifest.
                        _ = clearResumeData(for: key)
                    } else {
                        guard case .acquired(let lease) = tryAcquirePathLease(for: key,
                            relativePaths: [url.lastPathComponent], purpose: .reconcile) else { continue }
                        defer { releasePathLease(lease) }
                        guard condemnedFileIdentity(at: url) == identity,
                              lock.withLock({ rowMutationGenerations[ratingKey, default: 0] == generation }) else { continue }
                        try? storeFilesystem.removeItem(at: url, using: fileManager)
                    }
                }
                break
            }
        }
    }

    /// Attempt-conditional removal. A stale finalizer/delete for attempt A cannot remove attempt B
    /// or any of B's files, even when both attempts reuse the same rating key and stable paths.
    @discardableResult
    func remove(for key: DownloadAttemptKey) -> AttemptMutationResult {
        rowDeletionMutationResult(resolveRowDeletionSynchronously(
            submitRemove(for: key, requiresDeletionPending: false)))
    }

    /// Destructive half of the cleanup-ordering protocol. Only the Manager calls this after every
    /// exact pending operation is independently durable in the cleanup journal. Ordinary retry,
    /// finalizer, and abandoned-seed removal APIs cannot bypass a deletion reservation.
    @discardableResult
    func completePendingDeletion(for key: DownloadAttemptKey) -> AttemptMutationResult {
        rowDeletionMutationResult(resolveRowDeletionSynchronously(
            submitRemove(for: key, requiresDeletionPending: true)))
    }

    /// Nonblocking destructive half. This is legal only after the independent cleanup journal is
    /// durable; a failed index commit leaves the deletion-pending capsule dirty for launch retry.
    @discardableResult
    func submitCompletePendingDeletion(
        for key: DownloadAttemptKey
    ) -> RowDeletionSubmission {
        submitRemove(for: key, requiresDeletionPending: true)
    }

    func submitRemove(for key: DownloadAttemptKey) -> RowDeletionSubmission {
        submitRemove(for: key, requiresDeletionPending: false)
    }

    /// Retry's replace-by-removal: like `submitRemove`, and the replacement seeded next inherits
    /// this attempt's truncation strikes (R2-5).
    func submitRemoveForRetry(for key: DownloadAttemptKey) -> RowDeletionSubmission {
        submitRemove(for: key, requiresDeletionPending: false, retainingTruncation: true)
    }

    private func submitRemove(
        for key: DownloadAttemptKey,
        requiresDeletionPending: Bool,
        retainingTruncation: Bool = false
    ) -> RowDeletionSubmission {
        lock.lock()
        guard var existing = rows[key.ratingKey], existing.attemptID == key.attemptID,
              existing.pendingValidatedPromotionStatus == nil,
              existing.deletionPending == requiresDeletionPending else {
            lock.unlock()
            return .immediate(.staleOrMissing)
        }
        if let deletion = existing.pendingArtifactIntents.first(where: {
            guard case .rowDeletion(_, let pendingRequired, _) = $0.operation else { return false }
            return pendingRequired == requiresDeletionPending
        }) {
            if let ticket = artifactLifecycleTickets[deletion.id] {
                rowDeletionWaiterCounts[RowDeletionTicketEpoch(ticket), default: 0] += 1
                lock.unlock(); return .accepted(ticket: ticket)
            }
            let prepared = enqueueAttemptPersistenceLocked()
            let ticket = artifactLifecycle.register(key: key, generation: deletion.generation,
                intentID: deletion.id, preparedRevision: prepared)
            artifactLifecycleTickets[deletion.id] = ticket
            rowDeletionWaiterCounts[RowDeletionTicketEpoch(ticket), default: 0] += 1
            let start = activateArtifactHeadLocked(
                row: existing, key: key, appendedIntent: deletion, appendedTicket: ticket)
            lock.unlock()
            if let start { scheduleArtifactLifecycle(ticket: start.1, intent: start.0) }
            return .accepted(ticket: ticket)
        }
        if retainingTruncation, let truncation = existing.history.truncation {
            retiredTruncation[key.ratingKey] = (key.attemptID, truncation)
        }
        return stageRowDeletionLocked(row: &existing, key: key,
                                      requiresDeletionPending: requiresDeletionPending)
    }

    private func stageRowDeletionLocked(row: inout Row, key: DownloadAttemptKey,
                                        requiresDeletionPending: Bool) -> RowDeletionSubmission {
        var paths = artifactPathsReferenced(by: row)
        let stable = [row.relativePath] + sideAssetRelativePaths(for: row.metadata)
        for path in stable where Self.isSafeOneLevelRelativePath(path) {
            paths.insert(Self.attemptStagingRelativePath(for: key, stableRelativePath: path))
        }
        let safe = paths.filter(Self.isSafeOneLevelRelativePath).sorted()
        row.artifactGeneration += 1
        let intent = Row.ArtifactIntent(id: UUID(), attemptID: key.attemptID,
            generation: row.artifactGeneration, phase: .prepared,
            operation: .rowDeletion(relativePaths: safe,
                                    requiresDeletionPending: requiresDeletionPending,
                                    persistedOwnershipFlag: false))
        row.pendingArtifactIntents.append(intent)
        setRowLocked(row, for: key.ratingKey)
        let prepared = enqueueAttemptPersistenceLocked()
        let ticket = artifactLifecycle.register(key: key, generation: intent.generation,
            intentID: intent.id, preparedRevision: prepared)
        artifactLifecycleTickets[intent.id] = ticket
        rowDeletionWaiterCounts[RowDeletionTicketEpoch(ticket), default: 0] += 1
        let start = activateArtifactHeadLocked(
            row: row, key: key, appendedIntent: intent, appendedTicket: ticket)
        lock.unlock()
        if let start { scheduleArtifactLifecycle(ticket: start.1, intent: start.0) }
        return .accepted(ticket: ticket)
    }

    func resolveRowDeletionSynchronously(_ submission: RowDeletionSubmission) -> RowDeletionResult {
        switch submission {
        case .immediate(let result): return result
        case .accepted(let ticket):
            let lifecycle = artifactLifecycle.waitSynchronously(for: ticket)
            let epoch = RowDeletionTicketEpoch(ticket)
            let stored = lock.withLock { () -> RowDeletionResult? in
                let result = rowDeletionOutcomes[epoch]
                let remaining = max(0, (rowDeletionWaiterCounts[epoch] ?? 1) - 1)
                if remaining == 0 {
                    rowDeletionWaiterCounts.removeValue(forKey: epoch)
                    rowDeletionOutcomes.removeValue(forKey: epoch)
                } else {
                    rowDeletionWaiterCounts[epoch] = remaining
                }
                return result
            }
            if let stored { return stored }
            switch lifecycle {
            case .completed: return .staleOrMissing
            case .failed(.persistence(let failure)):
                return .persistenceFailed(ticket.key, failure)
            case .failed(.artifact):
                return .cleanupFailed(ticket.key, cleanupFailureCount: 1)
            case .timedOut: return .staleOrMissing
            }
        }
    }

    func resolveRowDeletion(_ submission: RowDeletionSubmission) async -> RowDeletionResult {
        await resolveRowDeletionDeadline(submission, deadline: .after(30))
    }

    private func rowDeletionMutationResult(_ result: RowDeletionResult) -> AttemptMutationResult {
        switch result {
        case .removed: return .applied
        case .staleOrMissing: return .staleOrMissing
        case .persistenceFailed(_, let failure): return .persistenceFailed(failure)
        case .cleanupFailed(_, let count):
            return .persistenceFailed(.failed(revision: 0, stage: "artifact",
                errorType: "rowDeletionCleanupFailed_\(count)"))
        }
    }

    private func executeRowDeletion(ticket: DownloadArtifactLifecycleCoordinator.Ticket,
                                    intent: Row.ArtifactIntent) {
        guard case .rowDeletion(let paths, let requiresPending, _) = intent.operation,
              paths.allSatisfy(Self.isSafeOneLevelRelativePath) else {
            failArtifactLifecycle(ticket, errorType: "invalidRowDeletionIntent"); return
        }
        let prepared = waitForPersistence(through: ticket.preparedRevision)
        guard prepared.result.committed(through: ticket.preparedRevision) else {
            failArtifactLifecycle(ticket, prepared.result); return
        }
        let candidates = lock.withLock { () -> [String]? in
            guard let row = rows[ticket.key.ratingKey], row.attemptID == ticket.key.attemptID,
                  row.deletionPending == requiresPending,
                  row.pendingArtifactIntents.first?.id == intent.id else { return nil }
            var others: Set<String> = []
            for other in rows.values where other.ratingKey != ticket.key.ratingKey {
                others.formUnion(artifactPathsReferenced(by: other))
            }
            let selected = paths.filter { !others.contains($0) }
            guard selected.allSatisfy({ reservedArtifactDeletionPaths[$0] == nil }) else {
                return nil
            }
            for path in selected { reservedArtifactDeletionPaths[path] = intent.id }
            return selected
        }
        guard let candidates else {
            failArtifactLifecycle(ticket, errorType: "rowDeletionReservationFailed"); return
        }
        let release = {
            self.lock.withLock {
                for path in candidates where self.reservedArtifactDeletionPaths[path] == intent.id {
                    self.reservedArtifactDeletionPaths.removeValue(forKey: path)
                }
            }
        }
        var failures = 0
        for path in candidates {
            let url = baseDirectory.appendingPathComponent(path)
            do { try artifactFilesystem.removeItem(url, fileManager) }
            catch where artifactFilesystem.fileExists(url, fileManager) { failures += 1 }
            catch {}
        }
        if failures == 0, !candidates.isEmpty {
            do { try artifactFilesystem.syncParentDirectory(
                baseDirectory.appendingPathComponent(candidates[0])) }
            catch { failures = 1 }
        }
        guard failures == 0 else {
            let epoch = RowDeletionTicketEpoch(ticket)
            lock.withLock {
                if (rowDeletionWaiterCounts[epoch] ?? 0) > 0 {
                    rowDeletionOutcomes[epoch] = .cleanupFailed(
                        ticket.key, cleanupFailureCount: failures)
                }
            }
            release(); failArtifactLifecycle(ticket, errorType: "rowDeletionCleanupFailed"); return
        }
        lock.lock()
        guard let row = rows[ticket.key.ratingKey], row.attemptID == ticket.key.attemptID,
              row.pendingArtifactIntents.first?.id == intent.id else {
            lock.unlock(); release(); completeArtifactLifecycle(ticket); return
        }
        artifactRetirementKeys.insert(ticket.key)
        rowMutationGenerations[ticket.key.ratingKey, default: 0] &+= 1
        let removed = rows.removeValue(forKey: ticket.key.ratingKey)!
        sideAssetPublicationOwners = sideAssetPublicationOwners.filter { $0.value.key.ratingKey != ticket.key.ratingKey }
        sideAssetHydrationCache.removeValue(forKey: ticket.key.ratingKey)
        let terminal = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let outcome = waitForPersistence(through: terminal)
        guard outcome.result.committed(through: terminal) else {
            let epoch = RowDeletionTicketEpoch(ticket)
            lock.lock()
            if rows[ticket.key.ratingKey] == nil { setRowLocked(removed, for: ticket.key.ratingKey) }
            artifactRetirementKeys.remove(ticket.key)
            _ = enqueueAttemptPersistenceLocked()
            if (rowDeletionWaiterCounts[epoch] ?? 0) > 0 {
                rowDeletionOutcomes[epoch] = .persistenceFailed(ticket.key, outcome.result)
            }
            lock.unlock(); release(); failArtifactLifecycle(ticket, outcome.result); return
        }
        let epoch = RowDeletionTicketEpoch(ticket)
        // Any intent still queued on the removed row can never run again — its intentID is gone
        // with the row — so abandon its coordinator entries (pending or failed) and drop the
        // store-side bookkeeping, or one deleted row poisons/stalls every later boundary.
        let orphanedIntentIDs = removed.pendingArtifactIntents.map(\.id)
            .filter { $0 != ticket.intentID }
        lock.withLock {
            artifactRetirementKeys.remove(ticket.key)
            for intentID in orphanedIntentIDs {
                activeArtifactIntentIDs.remove(intentID)
                pendingResumeArtifactData.removeValue(forKey: intentID)
                artifactLifecycleTickets.removeValue(forKey: intentID)
                startupArtifactCleanupIntentIDs.remove(intentID)
            }
            if (rowDeletionWaiterCounts[epoch] ?? 0) > 0 {
                rowDeletionOutcomes[epoch] = .removed(ticket.key)
            }
        }
        for intentID in orphanedIntentIDs { artifactLifecycle.abandonIntent(intentID) }
        release(); completeArtifactLifecycle(ticket)
    }

    // MARK: - Persistence

    #if DEBUG
    func updateMetadata(for key: DownloadAttemptKey,
                        expectedSideAssetSource: OfflineSideAssetSourceIdentity? = nil,
                        mutate: (inout OfflineMetadata) -> Void) -> AttemptMutationResult {
        updateMetadataOnWorker(for: key, expectedSideAssetSource: expectedSideAssetSource, mutate: mutate)
    }
    #endif

    #if DEBUG
    // Untouched fixture entry points retain their old synchronous contract. Production manager
    // callers use submit/resolve; the physical implementations above run only on workers.
    func createAttemptOwnedRecord(_ record: DownloadRecord, attemptID: DownloadAttemptID,
                                  replacing expectedPreviousOwner: DownloadAttemptID? = nil) -> AttemptRecordCreateResult {
        createAttemptOwnedRecordOnWorker(record, attemptID: attemptID, replacing: expectedPreviousOwner)
    }
    func clearPlaySessionID(for key: DownloadAttemptKey, expectedPlaySessionID: String) -> AttemptCompareClearResult {
        clearPlaySessionIDOnWorker(for: key, expectedPlaySessionID: expectedPlaySessionID)
    }
    func markCompleteIfUnverified(for key: DownloadAttemptKey) -> AttemptUnverifiedPromotionResult {
        markCompleteIfUnverifiedOnWorker(for: key)
    }
    func reprobeBlockedIndex() -> StartupIndexAdmission { reprobeBlockedIndexOnWorker() }
    func reconcile(liveRatingKeys: Set<String>, snapshotRatingKeys: Set<String>) {
        reconcileOnWorker(liveRatingKeys: liveRatingKeys, snapshotRatingKeys: snapshotRatingKeys)
    }
    #endif

    func mutationGeneration(for ratingKey: String) -> UInt64 {
        lock.withLock { rowMutationGenerations[ratingKey, default: 0] }
    }

    func timeoutFailure(_ ticket: PersistenceTicket) -> PersistenceFlushResult {
        .timedOut(targetRevision: ticket.revision, committedRevision: indexWriter.state.committedRevision)
    }

    func resolveArtifactDeadline(_ ticket: DownloadArtifactLifecycleCoordinator.Ticket,
                                deadline: DownloadStoreDeadline) async -> DownloadArtifactLifecycleCoordinator.FlushResult {
        await artifactLifecycle.resolve(for: ticket, deadline: deadline)
    }

    func resolveValidatedPromotionDeadline(_ submission: AttemptValidatedPromotionSubmission,
                                          deadline: DownloadStoreDeadline) async -> AttemptValidatedPromotionResult {
        switch submission {
        case .immediate(let result): return result
        case .accepted(let ticket):
            let outcome = await artifactLifecycle.resolve(for: ticket, deadline: deadline)
            let stored = lock.withLock {
                promotionAwaitingResultIDs.remove(ticket)
                return promotionOutcomes.removeValue(forKey: ticket)
            }
            if case .timedOut = outcome { return .persistenceFailed(ticket.key, timeoutFailure(ticket.preparedRevision)) }
            if let stored { return stored }
            switch outcome {
            case .completed: return .staleOrMissingOwner
            case .failed(.persistence(let failure)): return .persistenceFailed(ticket.key, failure)
            case .failed(.artifact(let errorType)): return .renameFailed(errorType: errorType)
            case .timedOut: return .persistenceFailed(ticket.key, timeoutFailure(ticket.preparedRevision))
            }
        }
    }

    func resolveStaticCheckpointDeadline(_ submission: AttemptStaticCheckpointSubmission,
                                        deadline: DownloadStoreDeadline) async -> AttemptStaticRangeCheckpointResetResult {
        switch submission {
        case .staleOrMissing: return .staleOrMissing
        case .notStatic(let bytes): return .notStatic(bytes: bytes)
        case .condemned(let ticket):
            let result = await flushPersistence(through: ticket, deadline: deadline)
            if case .committed = result { return .applied(bytes: 0) }
            return .persistenceFailed(bytes: 0, result)
        case .accepted(let ticket):
            let outcome = await artifactLifecycle.resolve(for: ticket, deadline: deadline)
            let stored = lock.withLock {
                staticCheckpointAwaitingResultIDs.remove(ticket)
                return staticCheckpointOutcomes.removeValue(forKey: ticket)
            }
            if case .timedOut = outcome { return .persistenceFailed(bytes: 0, timeoutFailure(ticket.preparedRevision)) }
            if let stored { return stored }
            switch outcome {
            case .completed: return .staleOrMissing
            case .failed(.persistence(let failure)): return .persistenceFailed(bytes: 0, failure)
            case .failed(.artifact(let errorType)):
                return .persistenceFailed(bytes: 0, .failed(revision: ticket.preparedRevision.revision, stage: "artifact", errorType: errorType))
            case .timedOut: return .persistenceFailed(bytes: 0, timeoutFailure(ticket.preparedRevision))
            }
        }
    }

    func resolveRowDeletionDeadline(_ submission: RowDeletionSubmission,
                                    deadline: DownloadStoreDeadline) async -> RowDeletionResult {
        switch submission {
        case .immediate(let result): return result
        case .accepted(let ticket):
            let outcome = await artifactLifecycle.resolve(for: ticket, deadline: deadline)
            let stored = lock.withLock { () -> RowDeletionResult? in
                let epoch = RowDeletionTicketEpoch(ticket)
                let result = rowDeletionOutcomes[epoch]
                let remaining = max(0, (rowDeletionWaiterCounts[epoch] ?? 1) - 1)
                if remaining == 0 {
                    rowDeletionWaiterCounts.removeValue(forKey: epoch)
                    rowDeletionOutcomes.removeValue(forKey: epoch)
                } else { rowDeletionWaiterCounts[epoch] = remaining }
                return result
            }
            if case .timedOut = outcome { return .persistenceFailed(ticket.key, timeoutFailure(ticket.preparedRevision)) }
            if let stored { return stored }
            switch outcome {
            case .completed: return .staleOrMissing
            case .failed(.persistence(let failure)): return .persistenceFailed(ticket.key, failure)
            case .failed(.artifact): return .cleanupFailed(ticket.key, cleanupFailureCount: 1)
            case .timedOut: return .persistenceFailed(ticket.key, timeoutFailure(ticket.preparedRevision))
            }
        }
    }

    private func load(indexData: Data?) {
        lock.lock(); defer { lock.unlock() }
        guard let data = indexData else { return }
        // #135 H8: decode the index row-by-row so a single corrupt/forward-incompatible
        // row can't drop the user's whole offline library (the old all-or-nothing
        // `decode([Row].self)` did exactly that). A non-zero skip is logged rather than
        // swallowed — silent truncation is the failure mode this guards against.
        let result = DownloadIndexCoding.decode(Row.self, from: data)
        indexSchemaVersion = result.schemaVersion
        loadedSchemaVersion = result.schemaVersion
        if result.skippedRowCount > 0 {
            NSLog("DownloadStore: skipped %d corrupt offline-index row(s) on load (schemaVersion %d); %d row(s) preserved",
                  result.skippedRowCount, result.schemaVersion, result.rows.count)
        }
        var seen: Set<String> = []
        guard result.rows.allSatisfy({ seen.insert($0.ratingKey).inserted }) else {
            startupSchemaProbe = .unreadable
            rows = [:]
            return
        }
        var normalizedPreparedStaticRows = 0
        var fencedSideAssetRows = 0
        var adoptedSideAssetRows = 0
        var retiredSideAssetPaths: Set<String> = []
        var loaded: [String: Row] = [:]
        for row in result.rows {
            var repaired = row
            if PreparedStaticLaneNormalizationPolicy.normalize(
                metadata: &repaired.metadata, ratingKey: repaired.ratingKey) {
                normalizedPreparedStaticRows += 1
                NSLog("DownloadStore: normalized legacy Plex prepared-static lane for %@",
                      row.ratingKey)
            }
            if var metadata = repaired.metadata {
                let expectedOwner = repaired.attemptID.map {
                    OfflineSideAssetBundleOwner(
                        attemptID: $0.rawValue, source: metadata.sideAssetSourceIdentity)
                }
                if metadata.hasCachedSideAssets {
                    if let expectedOwner, metadata.sideAssetBundleOwner == nil {
                        // One-time adoption of the pre-owner schema: rows written before
                        // `sideAssetBundleOwner` existed decode with a nil owner, and the row's
                        // sole top-level attempt is the only attempt that can have produced these
                        // assets. Stamp that owner instead of deleting the user's cached
                        // posters/trickplay/chapters/subtitles on first launch after update.
                        metadata.sideAssetBundleOwner = expectedOwner
                        adoptedSideAssetRows += 1
                        NSLog("DownloadStore: adopted legacy ownerless side-asset bundle for %@",
                              row.ratingKey)
                    } else if expectedOwner == nil
                                || metadata.sideAssetBundleOwner != expectedOwner {
                        retiredSideAssetPaths.formUnion(sideAssetRelativePaths(for: metadata))
                        metadata.clearCachedSideAssets()
                        fencedSideAssetRows += 1
                    }
                } else if metadata.sideAssetBundleOwner != nil {
                    metadata.sideAssetBundleOwner = nil
                    fencedSideAssetRows += 1
                }
                repaired.metadata = metadata
            }
            loaded[repaired.ratingKey] = repaired
        }
        rows = loaded
        if !retiredSideAssetPaths.isEmpty {
            var stillReferenced: Set<String> = []
            for row in rows.values {
                stillReferenced.formUnion(artifactPathsReferenced(by: row))
            }
            let paths = retiredSideAssetPaths.subtracting(stillReferenced)
            let reservation = UUID()
            let selected = paths.filter { reservedArtifactDeletionPaths[$0] == nil }
            for path in selected { reservedArtifactDeletionPaths[path] = reservation }
            lock.unlock()
            for path in selected { try? storeFilesystem.removeItem(at: baseDirectory.appendingPathComponent(path), using: fileManager) }
            lock.lock()
            for path in selected where reservedArtifactDeletionPaths[path] == reservation { reservedArtifactDeletionPaths.removeValue(forKey: path) }
        }
        // Never let a best-effort cache repair stamp a pre-v4 snapshot as v4 before the startup
        // migration has durably closed admission and marked every nonterminal partial for reset.
        // The repaired values are already in memory and ride along with the migration snapshot.
        if normalizedPreparedStaticRows > 0 || fencedSideAssetRows > 0 || adoptedSideAssetRows > 0,
           startupSchemaProbe == .current {
            lock.unlock()
            persist()
            lock.lock()
        }
    }

    /// Must be called with `lock` held. Cross-row protection is deliberate: malformed/imported
    /// indexes can share a relative path, and exact attempt A must never delete a body still named
    /// by any current manifest (including a different rating key).
    private func heldRangeManifestRelativePathsLocked() -> Set<String> {
        Set(rows.values.flatMap { $0.metadata?.heldRangeSegments?.map(\.relativePath) ?? [] }
            .filter(Self.isSafeOneLevelRelativePath))
    }

    @discardableResult
    private func persist() -> PersistenceAttempt {
        lock.lock()
        let ticket = enqueuePersistenceLocked()
        lock.unlock()
        return waitForPersistence(through: ticket)
    }

    /// Linearize an attempt-conditional mutation and submit its full-state revision while the
    /// ownership check and row mutation are still protected by `lock`. Waiting happens after the
    /// lock is released. A later full snapshot may subsume this revision: `.applied` therefore
    /// means A linearized before overlapping B, not that A remains the current owner or that A's
    /// exact encoded bytes necessarily reached disk. Any dependent external work must perform a
    /// fresh exact-owner admission immediately before it starts.
    private func enqueueAttemptPersistenceLocked() -> PersistenceTicket {
        enqueuePersistenceLocked()
    }

    private func enqueuePersistenceLocked() -> PersistenceTicket {
        nextPersistenceRevision += 1
        let ticket = PersistenceTicket(revision: nextPersistenceRevision)
        indexWriter.submit(revision: ticket.revision, snapshot: IndexSnapshot(
            schemaVersion: indexSchemaVersion, rows: Array(rows.values)))
        #if DEBUG
        persistenceDidSubmitForP6Testing?(ticket)
        #endif
        return ticket
    }

    private func waitForPersistence(through ticket: PersistenceTicket) -> PersistenceAttempt {
        let result = indexWriter.waitSynchronouslyForOutcome(through: ticket.revision)
        let attempt = PersistenceAttempt(
            ticket: ticket,
            result: Self.mapPersistenceResult(result)
        )
        if attempt.result.committed(through: ticket) {
            // A later full snapshot is also the retry barrier for a prepared artifact whose first
            // index attempt failed. Registration remains cheap; filesystem work stays off-lock.
            recoverPendingArtifactIntents(explicit: false)
        }
        return attempt
    }

    func flushPersistence(
        through ticket: PersistenceTicket? = nil,
        timeout: TimeInterval
    ) async -> PersistenceFlushResult {
        let target: UInt64
        if let ticket {
            target = ticket.revision
        } else {
            target = lock.withLock { nextPersistenceRevision }
        }
        return Self.mapPersistenceResult(
            await indexWriter.flush(through: target, timeout: timeout)
        )
    }

    func flushPersistence(through ticket: PersistenceTicket,
                          deadline: DownloadStoreDeadline) async -> PersistenceFlushResult {
        Self.mapPersistenceResult(await indexWriter.flush(through: ticket.revision, deadline: deadline))
    }

    func currentArtifactLifecycleWatermark() -> DownloadArtifactLifecycleCoordinator.Watermark {
        // A prior filesystem/index failure leaves the durable row intent in place. Register a
        // fresh worker attempt before capturing the next lifecycle boundary's watermark.
        recoverPendingArtifactIntents()
        return artifactLifecycle.currentWatermark
    }

    /// Flush index-only and filesystem-backed lifecycle work concurrently so the OS completion
    /// handler still has one bounded budget rather than two serial timeout windows.
    func flushLifecycleAndPersistence(
        through ticket: PersistenceTicket,
        artifactWatermark: DownloadArtifactLifecycleCoordinator.Watermark,
        timeout: TimeInterval
    ) async -> PersistenceFlushResult {
        let deadline = DownloadStoreDeadline.after(timeout)
        async let index = flushPersistence(through: ticket, deadline: deadline)
        async let artifacts = artifactLifecycle.flush(through: artifactWatermark, deadline: deadline)
        let (indexResult, artifactResult) = await (index, artifacts)
        switch artifactResult {
        case .completed:
            return indexResult
        case .failed(.persistence(let failure)):
            return failure
        case .failed(.artifact(let errorType)):
            return .failed(
                revision: ticket.revision,
                stage: "artifact",
                errorType: errorType
            )
        case .timedOut:
            let committed: UInt64
            if case .committed(let revision) = indexResult { committed = revision }
            else { committed = 0 }
            return .timedOut(
                targetRevision: ticket.revision,
                committedRevision: committed
            )
        }
    }

    /// Exact latest revision accepted before a lifecycle boundary begins its flush.
    func currentPersistenceTicket() -> PersistenceTicket {
        lock.withLock { PersistenceTicket(revision: nextPersistenceRevision) }
    }

    private static func mapPersistenceResult(
        _ result: RevisionedPersistenceWriter<IndexSnapshot>.FlushResult
    ) -> PersistenceFlushResult {
        switch result {
        case .committed(let revision):
            return .committed(revision: revision)
        case .failed(let failure):
            return .failed(
                revision: failure.revision,
                stage: failure.stage.rawValue,
                errorType: failure.errorType
            )
        case .timedOut(let targetRevision, let committedRevision):
            return .timedOut(
                targetRevision: targetRevision,
                committedRevision: committedRevision
            )
        }
    }
}

#if DEBUG
/// Exposes the private row's P3a legacy-shim mapping to tests.
enum DownloadStoreTestHooks {
    static func legacyLifecycle(for status: DownloadStatus, current: DownloadLifecycle?,
                                admissionPending: Bool) -> DownloadLifecycle {
        DownloadStore.legacyLifecycleForTesting(
            for: status, current: current, admissionPending: admissionPending)
    }
}

extension DownloadStore {
    func markSeasonCommitIndeterminateForTesting() {
        lock.withLock { seasonCommitIndeterminate = true }
    }

    static func legacyLifecycleForTesting(for status: DownloadStatus, current: DownloadLifecycle?,
                                          admissionPending: Bool) -> DownloadLifecycle {
        Row.legacyLifecycle(for: status, current: current, admissionPending: admissionPending)
    }
}
#endif
