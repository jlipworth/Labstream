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
    private static let unsupportedRootCleanupQueue = DispatchQueue(
        label: "com.jlipworth.Labstream.download-unsupported-root-cleanup", qos: .utility)

    struct IndexPersistence: Sendable {
        let atomicWrite: @Sendable (Data, URL) throws -> Void

        static let live = IndexPersistence { data, url in
            try DownloadIndexFileCommitter().commit(data, to: url)
        }
    }

    struct PersistenceTicket: Sendable, Equatable {
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

    struct EmbyConvertCleanupTombstone: Codable, Sendable, Equatable, Identifiable {
        let id: UUID
        let ratingKey: String
        let metadata: OfflineMetadata
    }

    struct EmbyCleanupPersistence: Sendable {
        let read: @Sendable (URL) throws -> Data?
        let encode: @Sendable ([EmbyConvertCleanupTombstone]) throws -> Data
        let atomicWrite: @Sendable (Data, URL) throws -> Void

        static let live = Self(
            read: { url in
                do {
                    return try Data(contentsOf: url)
                } catch {
                    let failure = error as NSError
                    if failure.domain == NSCocoaErrorDomain,
                       failure.code == CocoaError.Code.fileReadNoSuchFile.rawValue {
                        return nil
                    }
                    throw error
                }
            },
            encode: { try JSONEncoder().encode($0) },
            atomicWrite: { data, url in try data.write(to: url, options: .atomic) }
        )
    }

    struct EmbyCleanupPersistenceFailure: Error, Sendable, Equatable {
        enum Stage: String, Sendable, Equatable {
            case read
            case decode
            case encode
            case commit
        }

        let stage: Stage
        let errorType: String
    }

    enum EmbyCleanupLoadResult: Sendable, Equatable {
        case loaded([EmbyConvertCleanupTombstone])
        case failed(EmbyCleanupPersistenceFailure)
    }

    enum EmbyCleanupAddResult: Sendable, Equatable {
        case committed(EmbyConvertCleanupTombstone)
        case failed(EmbyCleanupPersistenceFailure)
    }

    enum EmbyCleanupRemoveResult: Sendable, Equatable {
        case committed(removed: Bool)
        case failed(EmbyCleanupPersistenceFailure)
    }

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
        case staleOrMissing
    }

    enum AttemptValidatedPromotionSubmission: Sendable, Equatable {
        case accepted(ticket: DownloadArtifactLifecycleCoordinator.Ticket)
        case immediate(AttemptValidatedPromotionResult)
    }

    struct HeldRangeSegmentRemovalResult: Sendable, Equatable {
        let removed: OfflineHeldRangeSegment?
        let ticket: PersistenceTicket
        let persistence: PersistenceFlushResult

        var committed: Bool {
            guard case .committed(let revision) = persistence else { return false }
            return revision >= ticket.revision
        }
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

    struct HeldRangeSegmentsTakeResult: Sendable, Equatable {
        let removed: [OfflineHeldRangeSegment]
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
        var status: DownloadStatus
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
            status = try c.decode(DownloadStatus.self, forKey: .status)
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
            decodedTopLevelAttemptIDPresent = topLevelAttemptID != nil
            decodedAttemptIdentityDisagrees = topLevelAttemptID != nil
                && nestedAttemptID != nil
                && topLevelAttemptID != nestedAttemptID
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
            self.status = status
            self.metadata = metadata
            self.deletionPending = deletionPending
            self.deletionPendingCleanupIntents = deletionPendingCleanupIntents
            self.heldRangeBodyDeletionIntents = heldRangeBodyDeletionIntents
            self.artifactGeneration = artifactGeneration
            self.sideAssetGeneration = sideAssetGeneration
            self.pendingArtifactIntents = pendingArtifactIntents
            self.decodedTopLevelAttemptIDPresent = attemptID != nil
            self.decodedAttemptIdentityDisagrees = false
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

    private var rows: [String: Row] = [:]          // ratingKey -> Row
    private var sideAssetHydrationCache: [String: HydratedSideAssets] = [:] // guarded by `lock`
    private var lastProgressPersist = Date.distantPast   // guarded by `lock`
    private let baseDirectory: URL                  // Application Support/Downloads
    /// A sweep may race side-cache writers which create their attempt-private file before the
    /// corresponding metadata mutation. Only files inventoried at Store initialization can be
    /// startup orphans; a later launch can collect newly-born files if no row ever adopts them.
    private var startupStagingInventory: Set<String>
    private let indexURL: URL                        // baseDirectory/index.json
    private let embyCleanupURL: URL                  // durable orphan-prevention queue
    private let cleanupAuthorityDirectory: URL       // survives destructive Downloads-root reset
    private let fileManager: FileManager
    private let embyCleanupPersistence: EmbyCleanupPersistence
    private let indexWriter: RevisionedPersistenceWriter<[Row]>
    private let rootIndexPersistence: IndexPersistence
    private let artifactFilesystem: DownloadArtifactFilesystem
    private let checkpointFilesystem: DownloadStaticCheckpointFilesystem
    private let promotionFilesystem: DownloadPromotionFilesystem
    private let artifactLifecycle = DownloadArtifactLifecycleCoordinator()
    private let artifactWorkerQueue = DispatchQueue(
        label: "com.visionplay.download-artifact-lifecycle", qos: .utility)
    private var nextPersistenceRevision: UInt64 = 0 // guarded by `lock`
    private var startupSchemaProbe: DownloadIndexCoding.StartupProbe // guarded by `lock`
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
    private var staticCheckpointOutcomes: [UUID: AttemptStaticRangeCheckpointResetResult] = [:]
    private var staticCheckpointAwaitingResultIDs: Set<UUID> = []
    private var promotionOutcomes: [UUID: AttemptValidatedPromotionResult] = [:]
    private var promotionAwaitingResultIDs: Set<UUID> = []
    private struct RowDeletionTicketEpoch: Hashable {
        let intentID: UUID
        let preparedRevision: UInt64
        init(_ ticket: DownloadArtifactLifecycleCoordinator.Ticket) {
            intentID = ticket.intentID
            preparedRevision = ticket.preparedRevision.revision
        }
    }
    private var rowDeletionOutcomes: [RowDeletionTicketEpoch: RowDeletionResult] = [:]
    /// Accepted deletion submissions are independently resolvable even when several callers join
    /// one active lifecycle ticket (double-tap Delete, coalesced startup recovery). Retain the
    /// broadcast outcome until every accepted waiter has consumed it.
    private var rowDeletionWaiterCounts: [RowDeletionTicketEpoch: Int] = [:]

    /// - Parameter baseDirectory: where media files + the index live. Defaults to
    ///   `Application Support/Labstream/Downloads`, created if missing.
    init(baseDirectory: URL? = nil,
         fileManager: FileManager = .default,
         indexPersistence: IndexPersistence = .live,
         embyCleanupPersistence: EmbyCleanupPersistence? = nil,
         artifactFilesystem: DownloadArtifactFilesystem = .live,
         checkpointFilesystem: DownloadStaticCheckpointFilesystem = .live,
         promotionFilesystem: DownloadPromotionFilesystem = .live) {
        self.fileManager = fileManager
        self.embyCleanupPersistence = embyCleanupPersistence ?? .live
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
        var startupProbe: DownloadIndexCoding.StartupProbe
        var startupIndexData: Data?
        if fileManager.fileExists(atPath: indexURL.path) {
            do {
                let data = try Data(contentsOf: indexURL)
                startupIndexData = data
                startupProbe = DownloadIndexCoding.startupProbe(data: data)
            } catch {
                startupProbe = .unreadable
            }
        } else if fileManager.fileExists(atPath: pendingQuarantine.path) {
            // A prior rollback was interrupted after the opaque root was quarantined. Never
            // classify the absent live root as a new empty library; retry from the durable pending
            // quarantine after task drainage.
            startupProbe = .unsupported(schemaVersion: nil)
        } else {
            startupProbe = .missing
        }
        if startupProbe == .current, let startupIndexData {
            let decoded = DownloadIndexCoding.decode(Row.self, from: startupIndexData)
            let keys = decoded.rows.map(\.ratingKey)
            if decoded.skippedRowCount > 0 || Set(keys).count != keys.count {
                startupProbe = .unreadable
            }
        }
        self.startupSchemaProbe = startupProbe
        self.startupStagingInventory = Set(
            ((startupProbe == .missing || startupProbe == .current)
                ? ((try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []) : [])
                .filter(Self.isAttemptStagingRelativePath))
        self.indexURL = indexURL
        let authority = dir.deletingLastPathComponent().appendingPathComponent(
            ".\(dir.lastPathComponent)-download-authority", isDirectory: true)
        self.cleanupAuthorityDirectory = authority
        self.embyCleanupURL = authority.appendingPathComponent("emby-convert-cleanup.json")
        self.indexWriter = RevisionedPersistenceWriter<[Row]>(
            encode: { rows in try DownloadIndexCoding.encode(rows) },
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
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: authority, withIntermediateDirectories: true)
            try Self.syncDirectory(dir.deletingLastPathComponent())
            try moveCleanupAuthorityFilesOutOfVersionedRoot()
        } catch {
            startupSchemaProbe = .unreadable
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
        try? DownloadArtifactFileCommitter.cleanupAbandonedResumeTemps(
            in: dir,
            fileManager: fileManager)
        load()
        startupArtifactCleanupIntentIDs = Set(
            rows.values.flatMap { $0.pendingArtifactIntents.map(\.id) })
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
        lock.lock(); defer { lock.unlock() }
        return readEmbyCleanupTombstonesLocked()
    }

    @discardableResult
    func addEmbyConvertCleanupTombstone(ratingKey: String, metadata: OfflineMetadata)
        -> EmbyCleanupAddResult {
        addEmbyConvertCleanupTombstone(EmbyConvertCleanupTombstone(
            id: UUID(), ratingKey: ratingKey, metadata: metadata
        ))
    }

    /// Persist an EXISTING tombstone value (same id). Used to retry the durable write for
    /// tombstones that were deferred in memory after a delete()-time persist failure.
    @discardableResult
    func addEmbyConvertCleanupTombstone(_ tombstone: EmbyConvertCleanupTombstone)
        -> EmbyCleanupAddResult {
        lock.lock()
        var values: [EmbyConvertCleanupTombstone]
        switch readEmbyCleanupTombstonesLocked() {
        case .loaded(let loaded):
            values = loaded
        case .failed(let failure):
            lock.unlock()
            return .failed(failure)
        }
        guard !values.contains(where: { $0.id == tombstone.id }) else {
            lock.unlock()
            return .committed(tombstone)
        }
        let expectedIDs = EmbyConvertRecoveryPolicy.appendingCleanupTombstoneID(
            tombstone.id, to: values.map(\.id))
        values.append(tombstone)
        assert(values.map(\.id) == expectedIDs)
        let data: Data
        do {
            data = try embyCleanupPersistence.encode(values)
        } catch {
            lock.unlock()
            return .failed(Self.embyCleanupFailure(stage: .encode, error: error))
        }
        do {
            try embyCleanupPersistence.atomicWrite(data, embyCleanupURL)
        } catch {
            // An injected/filesystem commit can throw after the atomic replacement happened.
            // Re-read while still serialized: this generated UUID is exact proof that add won.
            if case .loaded(let durable) = readEmbyCleanupTombstonesLocked(),
               durable.contains(where: { $0.id == tombstone.id }) {
                lock.unlock()
                return .committed(tombstone)
            }
            lock.unlock()
            return .failed(Self.embyCleanupFailure(stage: .commit, error: error))
        }
        lock.unlock()
        return .committed(tombstone)
    }

    @discardableResult
    func removeEmbyConvertCleanupTombstone(id: UUID) -> EmbyCleanupRemoveResult {
        lock.lock()
        var values: [EmbyConvertCleanupTombstone]
        switch readEmbyCleanupTombstonesLocked() {
        case .loaded(let loaded):
            values = loaded
        case .failed(let failure):
            lock.unlock()
            return .failed(failure)
        }
        let oldCount = values.count
        values.removeAll { $0.id == id }
        guard values.count != oldCount else {
            lock.unlock()
            return .committed(removed: false)
        }
        let data: Data
        do {
            data = try embyCleanupPersistence.encode(values)
        } catch {
            lock.unlock()
            return .failed(Self.embyCleanupFailure(stage: .encode, error: error))
        }
        do {
            try embyCleanupPersistence.atomicWrite(data, embyCleanupURL)
        } catch {
            // Likewise, absence of this exact UUID after a thrown replace proves removal won.
            if case .loaded(let durable) = readEmbyCleanupTombstonesLocked(),
               !durable.contains(where: { $0.id == id }) {
                lock.unlock()
                return .committed(removed: true)
            }
            lock.unlock()
            return .failed(Self.embyCleanupFailure(stage: .commit, error: error))
        }
        lock.unlock()
        return .committed(removed: true)
    }

    private func readEmbyCleanupTombstonesLocked() -> EmbyCleanupLoadResult {
        let data: Data
        do {
            guard let loaded = try embyCleanupPersistence.read(embyCleanupURL) else {
                return .loaded([])
            }
            data = loaded
        } catch {
            return .failed(EmbyCleanupPersistenceFailure(
                stage: .read,
                errorType: String(reflecting: type(of: error))
            ))
        }
        do {
            return .loaded(try JSONDecoder().decode(
                [EmbyConvertCleanupTombstone].self, from: data
            ))
        } catch {
            return .failed(EmbyCleanupPersistenceFailure(
                stage: .decode,
                errorType: String(reflecting: type(of: error))
            ))
        }
    }

    private static func embyCleanupFailure(
        stage: EmbyCleanupPersistenceFailure.Stage,
        error: any Error
    ) -> EmbyCleanupPersistenceFailure {
        EmbyCleanupPersistenceFailure(
            stage: stage,
            errorType: String(reflecting: type(of: error))
        )
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
              let working = row.attemptWorkingRelativePath,
              Self.isSafeOneLevelRelativePath(row.relativePath),
              working == Self.attemptStagingRelativePath(
                for: key, stableRelativePath: row.relativePath) else { return nil }
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
            promotionAwaitingResultIDs.insert(head.id)
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
        rows[key.ratingKey] = row
        let prepared = enqueueAttemptPersistenceLocked()
        let ticket = artifactLifecycle.register(
            key: key, generation: intent.generation, intentID: intent.id,
            preparedRevision: prepared)
        artifactLifecycleTickets[intent.id] = ticket
        promotionAwaitingResultIDs.insert(intent.id)
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
                promotionAwaitingResultIDs.remove(ticket.intentID)
                return promotionOutcomes.removeValue(forKey: ticket.intentID)
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
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                continuation.resume(returning: resolveValidatedPromotionSynchronously(submission))
            }
        }
    }

    private func recordPromotionOutcomeLocked(
        _ result: AttemptValidatedPromotionResult,
        intentID: UUID
    ) {
        guard promotionAwaitingResultIDs.contains(intentID) else { return }
        promotionOutcomes[intentID] = result
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
            rows[ticket.key.ratingKey] = capturing
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
                        errorType: String(reflecting: type(of: error))), intentID: intent.id)
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
                        errorType: String(reflecting: type(of: error))), intentID: intent.id)
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
            lock.withLock { recordPromotionOutcomeLocked(.sourceMissing, intentID: intent.id) }
            failArtifactLifecycle(ticket, errorType: "promotionSourceMissing"); return
        }

        lock.lock()
        guard var row = rows[ticket.key.ratingKey], row.attemptID == ticket.key.attemptID,
              row.pendingArtifactIntents.first?.id == intent.id else {
            lock.unlock(); completeArtifactLifecycle(ticket); return
        }
        row.bytes = bytes
        row.progress = 1
        row.status = terminalStatus
        row.attemptWorkingRelativePath = nil
        artifactRetirementKeys.insert(ticket.key)
        let retiring = row.pendingArtifactIntents.removeFirst()
        rows[ticket.key.ratingKey] = row
        let terminal = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let terminalOutcome = waitForPersistence(through: terminal)
        guard terminalOutcome.result.committed(through: terminal) else {
            lock.lock()
            if var restored = rows[ticket.key.ratingKey], restored.attemptID == ticket.key.attemptID {
                restored.pendingArtifactIntents.insert(retiring, at: 0)
                rows[ticket.key.ratingKey] = restored
                _ = enqueueAttemptPersistenceLocked()
            }
            artifactRetirementKeys.remove(ticket.key)
            recordPromotionOutcomeLocked(
                .persistenceFailed(ticket.key, terminalOutcome.result), intentID: intent.id)
            lock.unlock()
            failArtifactLifecycle(ticket, terminalOutcome.result); return
        }
        lock.withLock {
            artifactRetirementKeys.remove(ticket.key)
            recordPromotionOutcomeLocked(.promoted(
                ticket.key, bytes: bytes, status: terminalStatus), intentID: intent.id)
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
        row.status = .failed
        rows[ticket.key.ratingKey] = row
        let terminal = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let terminalOutcome = waitForPersistence(through: terminal)
        guard terminalOutcome.result.committed(through: terminal) else {
            lock.lock()
            if var restored = rows[ticket.key.ratingKey],
               restored.attemptID == ticket.key.attemptID,
               !restored.pendingArtifactIntents.contains(where: { $0.id == retiring.id }) {
                restored.pendingArtifactIntents.insert(retiring, at: 0)
                rows[ticket.key.ratingKey] = restored
                _ = enqueueAttemptPersistenceLocked()
            }
            artifactRetirementKeys.remove(ticket.key)
            recordPromotionOutcomeLocked(
                .persistenceFailed(ticket.key, terminalOutcome.result), intentID: intent.id)
            lock.unlock()
            failArtifactLifecycle(ticket, terminalOutcome.result); return
        }
        lock.withLock {
            artifactRetirementKeys.remove(ticket.key)
            startupArtifactCleanupIntentIDs.remove(retiring.id)
            recordPromotionOutcomeLocked(.sourceMissing, intentID: intent.id)
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
        current.status = terminalStatus
        current.attemptWorkingRelativePath = nil
        current.pendingValidatedPromotionStatus = nil
        rows[key.ratingKey] = current
        let ticket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let persistence = waitForPersistence(through: ticket)
        guard persistence.result.committed(through: persistence.ticket) else {
            return .persistenceFailed(key, persistence.result)
        }
        return .promoted(key, bytes: bytes, status: terminalStatus)
    }

    private func workingRelativePath(for row: Row, key: DownloadAttemptKey) -> String? {
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
              stagingURL.standardizedFileURL == expectedStaging.standardizedFileURL else {
            return .invalidPath
        }
        lock.lock(); defer { lock.unlock() }
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID else {
            return .staleOrMissingOwner
        }
        if let expectedSideAssetSource,
           row.metadata?.sideAssetSourceIdentity != expectedSideAssetSource {
            return .staleOrMissingOwner
        }
        guard !Self.hasPendingRowDeletion(row) else { return .staleOrMissingOwner }
        guard reservedArtifactDeletionPaths[stableURL.lastPathComponent] == nil else {
            return .staleOrMissingOwner
        }
        guard fileManager.fileExists(atPath: stagingURL.path) else { return .sourceMissing }
        let result = stagingURL.withUnsafeFileSystemRepresentation { source in
            stableURL.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination else { return -1 }
                return Int(Darwin.rename(source, destination))
            }
        }
        guard result == 0 else {
            return .failed(errorType: String(reflecting: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)))
        }
        if expectedSideAssetSource != nil {
            row.sideAssetGeneration &+= 1
            rows[key.ratingKey] = row
            sideAssetHydrationCache.removeValue(forKey: key.ratingKey)
        }
        return .promoted
    }

    /// Conservative startup inventory: only recognized staging files not attributable to a
    /// currently-owned row (or explicitly supplied live reference) are returned.
    func unreferencedAttemptStagingURLs(
        additionalReferencedRelativePaths: Set<String> = []
    ) -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return unreferencedAttemptStagingURLsLocked(
            additionalReferencedRelativePaths: additionalReferencedRelativePaths)
    }

    /// Delete startup-orphan staging while holding the same lock as promotion. Unrelated files and
    /// staging attributable to a current owner are never selected.
    @discardableResult
    func sweepUnreferencedAttemptStaging(
        additionalReferencedRelativePaths: Set<String> = []
    ) -> AttemptStagingSweepResult {
        lock.lock(); defer { lock.unlock() }
        let candidates = unreferencedAttemptStagingURLsLocked(
            additionalReferencedRelativePaths: additionalReferencedRelativePaths)
        var removed: [String] = []
        var failed: [String] = []
        for url in candidates {
            do {
                try fileManager.removeItem(at: url)
                removed.append(url.lastPathComponent)
            } catch {
                failed.append(url.lastPathComponent)
            }
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

    private func unreferencedAttemptStagingURLsLocked(
        additionalReferencedRelativePaths: Set<String>
    ) -> [URL] {
        var referenced = additionalReferencedRelativePaths.filter(Self.isAttemptStagingRelativePath)
        for row in rows.values {
            guard let attemptID = row.attemptID else { continue }
            let key = DownloadAttemptKey(ratingKey: row.ratingKey, attemptID: attemptID)
            // Held range bodies are already persisted at exact-attempt staging paths (they are
            // private checkpoints, not public side assets). Keep every manifest-owned body live
            // during the generic startup staging sweep.
            for held in row.metadata?.heldRangeSegments ?? []
                where Self.isAttemptStagingRelativePath(held.relativePath) {
                referenced.insert(held.relativePath)
            }
            let stablePaths = [row.relativePath] + sideAssetRelativePaths(for: row.metadata)
            for stablePath in stablePaths where Self.isSafeOneLevelRelativePath(stablePath) {
                referenced.insert(Self.attemptStagingRelativePath(
                    for: key, stableRelativePath: stablePath))
            }
        }
        let urls = (try? fileManager.contentsOfDirectory(
            at: baseDirectory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsSubdirectoryDescendants])) ?? []
        return urls.filter { url in
            let name = url.lastPathComponent
            guard Self.isAttemptStagingRelativePath(name), !referenced.contains(name) else {
                return false
            }
            guard startupStagingInventory.contains(name),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { return false }
            return true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
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

    /// Replace the manifest entry at an offset. `persisted` means the in-memory row accepted the
    /// replacement; only `committed` permits the caller to delete the previous body. A failed
    /// attempt remains dirty and may commit on a later mutation/flush.
    @discardableResult
    func persistHeldRangeSegment(ratingKey: String,
                                 segment: OfflineHeldRangeSegment)
        -> (persisted: Bool, committed: Bool, previous: OfflineHeldRangeSegment?) {
        guard Self.isSafeOneLevelRelativePath(segment.relativePath),
              segment.offset >= 0, segment.length > 0 else { return (false, false, nil) }
        lock.lock()
        guard var row = rows[ratingKey], !Self.hasPendingRowDeletion(row),
              var metadata = row.metadata else {
            lock.unlock()
            return (false, false, nil)
        }
        guard reservedHeldBodyDeletionPaths[segment.relativePath] == nil else {
            lock.unlock()
            return (false, false, nil)
        }
        guard reservedArtifactDeletionPaths[segment.relativePath] == nil else {
            lock.unlock(); return (false, false, nil)
        }
        var segments = metadata.heldRangeSegments ?? []
        let previous = segments.first { $0.offset == segment.offset }
        segments.removeAll { $0.offset == segment.offset }
        segments.append(segment)
        metadata.heldRangeSegments = segments.sorted { $0.offset < $1.offset }
        row.metadata = metadata
        rows[ratingKey] = row
        lock.unlock()
        let attempt = persist()
        let committed: Bool
        if case .committed(let revision) = attempt.result {
            committed = revision >= attempt.ticket.revision
        } else {
            committed = false
        }
        return (true, committed, previous)
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
        rows[key.ratingKey] = row
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
        rows[key.ratingKey] = row
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
        rows[key.ratingKey] = row
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
        rows[key.ratingKey] = row
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
        guard candidates.allSatisfy({ reservedHeldBodyDeletionPaths[$0] == nil }) else {
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
        rows[ticket.key.ratingKey] = terminalRow
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
                rows[ticket.key.ratingKey] = restored
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
            rows[ratingKey] = row
            if let start = tuple.2 { staged.append((key, start.0, start.1)) }
        }
        lock.unlock()
        for (_, intent, ticket) in staged {
            scheduleArtifactLifecycle(ticket: ticket, intent: intent)
        }
    }

    @discardableResult
    func removeHeldRangeSegment(ratingKey: String, offset: Int) -> HeldRangeSegmentRemovalResult {
        let batch = removeHeldRangeSegments(ratingKey: ratingKey, offsets: [offset])
        return HeldRangeSegmentRemovalResult(
            removed: batch.removed.first,
            ticket: batch.ticket,
            persistence: batch.persistence
        )
    }

    /// Batch variant: remove several manifest entries with one index persist while returning the
    /// exact durability outcome. A no-op still proves/retries a dirty prior removal.
    @discardableResult
    func removeHeldRangeSegments(
        ratingKey: String,
        offsets: [Int]
    ) -> HeldRangeSegmentsRemovalResult {
        let offsetSet = Set(offsets)
        lock.lock()
        var removed: [OfflineHeldRangeSegment] = []
        if !offsetSet.isEmpty,
           var row = rows[ratingKey],
           !Self.hasPendingRowDeletion(row),
           var metadata = row.metadata,
           let segments = metadata.heldRangeSegments {
            removed = segments.filter { offsetSet.contains($0.offset) }
            if !removed.isEmpty {
                let remaining = segments.filter { !offsetSet.contains($0.offset) }
                metadata.heldRangeSegments = remaining.isEmpty ? nil : remaining
                row.metadata = metadata
                rows[ratingKey] = row
            }
        }
        lock.unlock()
        // Even a no-op must prove the current full snapshot: a prior failed removal already
        // changed memory, so absence alone is not proof that the durable manifest was cleared.
        let attempt = removed.isEmpty ? proveCleanupNoOpDurable() : persist()
        return HeldRangeSegmentsRemovalResult(
            removed: removed,
            deferredRelativePaths: [],
            ticket: attempt.ticket,
            persistence: attempt.result
        )
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
                rows[key.ratingKey] = row
            }
        }
        let safeCandidates = Set(candidates.filter(Self.isSafeOneLevelRelativePath))
        let manifestPaths = Set(removed.map(\.relativePath).filter(Self.isSafeOneLevelRelativePath))
        let deferred = Set(row.heldRangeBodyDeletionIntents)
            .union(safeCandidates)
            .union(manifestPaths)
        row.heldRangeBodyDeletionIntents = deferred.sorted()
        rows[key.ratingKey] = row
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
    func takeHeldRangeSegments(ratingKey: String) -> HeldRangeSegmentsTakeResult {
        lock.lock()
        var removed: [OfflineHeldRangeSegment] = []
        if var row = rows[ratingKey], !Self.hasPendingRowDeletion(row),
           var metadata = row.metadata {
            removed = metadata.heldRangeSegments ?? []
            if !removed.isEmpty {
                metadata.heldRangeSegments = nil
                row.metadata = metadata
                rows[ratingKey] = row
            }
        }
        lock.unlock()
        // As above, retry a dirty prior take even when this call sees no in-memory manifests.
        let attempt = removed.isEmpty ? proveCleanupNoOpDurable() : persist()
        return HeldRangeSegmentsTakeResult(
            removed: removed,
            ticket: attempt.ticket,
            persistence: attempt.result
        )
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
        rows[key.ratingKey] = row
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
        let currentlyReferenced = heldRangeManifestRelativePathsLocked()
        let protectedByManifest = Set(row.heldRangeBodyDeletionIntents)
            .intersection(provenPaths)
            .intersection(currentlyReferenced)
        let candidates = row.heldRangeBodyDeletionIntents
            .filter { provenPaths.contains($0) }
            .filter(Self.isSafeOneLevelRelativePath)
            .filter { !currentlyReferenced.contains($0) }
        var removed: [String] = []
        var failed: [String] = []
        for relativePath in candidates {
            let url = baseDirectory.appendingPathComponent(relativePath)
            do {
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
                removed.append(relativePath)
            } catch {
                failed.append(relativePath)
            }
        }
        let completed = Set(removed).union(protectedByManifest)
        row.heldRangeBodyDeletionIntents.removeAll { completed.contains($0) }
        rows[key.ratingKey] = row
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
        rows[key.ratingKey] = row
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
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[key.ratingKey], row.attemptID == key.attemptID,
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
              let attributes = try? fileManager.attributesOfItem(atPath: destination.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.uint64Value ?? 0) > 0 else { return nil }
        return relative
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
        let snapshot = Array(rows.values)
        lock.unlock()

        let referenced = OfflineDownloadFileInventory.referencedRelativePaths(
            mainRelativePaths: snapshot.map(\.relativePath),
            metadata: snapshot.map(\.metadata)
        )
        let files = directoryFileSnapshots()
        return OfflineDownloadFileInventory.audit(directoryFiles: files,
                                                  referencedRelativePaths: referenced,
                                                  inFlightRelativePaths: inFlightRelativePaths)
    }

    /// Absolute local URL for a completed download, if indexed AND present on disk.
    func localURL(for ratingKey: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[ratingKey], row.status == .complete || row.status == .unverified else { return nil }
        let url = baseDirectory.appendingPathComponent(row.relativePath)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Absolute local Plex BIF cache URL for a completed download, if present on disk.
    func plexBIFURL(for ratingKey: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[ratingKey], row.status == .complete || row.status == .unverified else { return nil }
        return resolvedDownloadAssetURL(row.metadata?.plexBIFRelativePath)
    }

    /// Absolute local Emby BIF cache URL for a completed download, if present on disk.
    func embyBIFURL(for ratingKey: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[ratingKey], row.status == .complete || row.status == .unverified else { return nil }
        return resolvedDownloadAssetURL(row.metadata?.embyBIFRelativePath)
    }

    /// Absolute local Jellyfin trickplay playlist URL for a completed download, if present on disk.
    func jellyfinTrickPlayPlaylistURL(for ratingKey: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[ratingKey], row.status == .complete || row.status == .unverified else { return nil }
        return resolvedDownloadAssetURL(row.metadata?.jellyfinTrickPlayPlaylistRelativePath)
    }

    /// Absolute cached per-chapter image URLs (chapter index → file) for a completed download,
    /// limited to files that still exist on disk (#88/#89).
    func chapterImageURLs(for ratingKey: String) -> [Int: URL] {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[ratingKey], row.status == .complete || row.status == .unverified else { return [:] }
        return Self.resolvedChapterImageURLs(row.metadata?.chapterImageRelativePaths,
                                             baseDirectory: baseDirectory,
                                             fileManager: fileManager)
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
            let attrs = try? fileManager.attributesOfItem(atPath: url.path)
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
        guard let urls = try? fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
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
        guard let raw = (try? fileManager.attributesOfItem(atPath: url.path)[.size]) else {
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
        fileSize(at: baseDirectory.appendingPathComponent(relativePath))
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
    /// snapshot. No row becomes visible to admission unless the complete plan is durable.
    func applySeasonPlanAtomically(
        newRecords records: [DownloadRecord],
        retryAttempts: [DownloadAttemptKey]
    ) -> SeasonPlanStoreApplyResult {
        guard !records.isEmpty || !retryAttempts.isEmpty else {
            return .applied(inserted: 0, retried: 0)
        }
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
              }) else {
            lock.unlock()
            return .staleInput
        }
        var candidateRows = rows
        var candidateHydrationCache = sideAssetHydrationCache
        for record in records {
            guard let attemptID = record.attemptID else { continue }
            let relativePath = record.localURL.lastPathComponent
            var metadata = record.metadata
            metadata?.downloadAttemptID = attemptID.rawValue
            candidateRows[record.ratingKey] = Row(
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
            candidateHydrationCache.removeValue(forKey: record.ratingKey)
        }
        for key in retryAttempts {
            guard var row = candidateRows[key.ratingKey], var metadata = row.metadata else { continue }
            metadata.seasonPlannerPendingAdmission = true
            row.metadata = metadata
            candidateRows[key.ratingKey] = row
        }
        // Submit the candidate snapshot without publishing it in memory. Holding the Store lock
        // through the writer outcome makes validation + persistence + publication one transaction;
        // no concurrent mutation can observe or build on rows that have not committed.
        let oldIndexData = try? Data(contentsOf: indexURL)
        let oldIndexWasMissing = oldIndexData == nil && !fileManager.fileExists(atPath: indexURL.path)
        let candidateSnapshot = Array(candidateRows.values)
        guard let candidateData = try? DownloadIndexCoding.encode(candidateSnapshot) else {
            lock.unlock()
            return .persistenceFailed
        }
        nextPersistenceRevision += 1
        let ticket = PersistenceTicket(revision: nextPersistenceRevision)
        indexWriter.submit(revision: ticket.revision, snapshot: candidateSnapshot)
        let writerResult = indexWriter.waitSynchronouslyForOutcome(through: ticket.revision)
        let persistenceResult = Self.mapPersistenceResult(writerResult)
        guard persistenceResult.committed(through: ticket) else {
            // Atomic replacement can succeed and then surface an error. If the exact candidate is
            // already durable, publish it rather than letting a later old-memory snapshot erase it.
            if (try? Data(contentsOf: indexURL)) == candidateData {
                rows = candidateRows
                sideAssetHydrationCache = candidateHydrationCache
                lock.unlock()
                return .applied(inserted: records.count, retried: retryAttempts.count)
            }
            // Supersede the writer's dirty candidate with the unchanged authoritative rows. Even
            // if this compensating write fails, any future writer flush now retries old authority,
            // not an unreported season plan.
            nextPersistenceRevision += 1
            let rollbackTicket = PersistenceTicket(revision: nextPersistenceRevision)
            indexWriter.submit(revision: rollbackTicket.revision, snapshot: Array(rows.values))
            let rollbackResult = indexWriter.waitSynchronouslyForOutcome(
                through: rollbackTicket.revision)
            if Self.mapPersistenceResult(rollbackResult).committed(through: rollbackTicket) {
                lock.unlock()
                return .persistenceFailed
            }
            let durableBytes = try? Data(contentsOf: indexURL)
            if durableBytes == candidateData {
                // Make the candidate the writer's newest dirty authority as well as memory/disk
                // authority, so a later flush cannot replay the failed rollback over it.
                nextPersistenceRevision += 1
                indexWriter.submit(
                    revision: nextPersistenceRevision, snapshot: candidateSnapshot)
                rows = candidateRows
                sideAssetHydrationCache = candidateHydrationCache
                lock.unlock()
                return .applied(inserted: records.count, retried: retryAttempts.count)
            }
            if durableBytes == oldIndexData
                || (oldIndexWasMissing && !fileManager.fileExists(atPath: indexURL.path)) {
                lock.unlock()
                return .persistenceFailed
            }
            // Neither authority can be proven. Mark startup admission unreadable so the manager
            // can stop the queue rather than report an ordinary save failure and continue.
            startupSchemaProbe = .unreadable
            lock.unlock()
            return .persistenceIndeterminate
        }
        rows = candidateRows
        sideAssetHydrationCache = candidateHydrationCache
        lock.unlock()
        return .applied(inserted: records.count, retried: retryAttempts.count)
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
    func createAttemptOwnedRecord(
        _ record: DownloadRecord,
        attemptID: DownloadAttemptID,
        replacing expectedPreviousOwner: DownloadAttemptID? = nil
    ) -> AttemptRecordCreateResult {
        let key = DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: attemptID)
        lock.lock()
        let existing = rows[record.ratingKey]
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
        if !incomingPaths.allSatisfy({ reservedArtifactDeletionPaths[$0] == nil }) {
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
        if existing?.attemptID != attemptID,
           let expectedPreviousOwner,
           previous?.metadata?.resolvedResumeMode(ratingKey: record.ratingKey) == .staticByteRange,
           metadata?.resolvedResumeMode(ratingKey: record.ratingKey) == .staticByteRange,
           let previous,
           let oldWorkingRelative = workingRelativePath(
                for: previous,
                key: DownloadAttemptKey(
                    ratingKey: record.ratingKey, attemptID: expectedPreviousOwner)) {
            let oldWorkingURL = baseDirectory.appendingPathComponent(oldWorkingRelative)
            let newWorkingURL = baseDirectory.appendingPathComponent(newWorkingRelative)
            if let durableBytes = fileSize(at: oldWorkingURL), durableBytes > 0 {
                do {
                    if fileManager.fileExists(atPath: newWorkingURL.path) {
                        try fileManager.removeItem(at: newWorkingURL)
                    }
                    try fileManager.copyItem(at: oldWorkingURL, to: newWorkingURL)
                    oldWorkingURLToRemove = oldWorkingURL
                    inheritedDurableBytes = durableBytes
                } catch {
                    lock.unlock()
                    return .rejectedOwnership(
                        expectedPreviousOwner: expectedKey,
                        actualOwner: existingKey,
                        reason: .checkpointHandoffFailed
                    )
                }
            }
        }
        let effectiveBytes = inheritedDurableBytes ?? record.bytes
        let effectiveProgress = inheritedDurableBytes.map {
            Self.progressForDurableBytes(
                $0,
                expectedBytes: previous.flatMap { Self.expectedBytesEstimate(row: $0) })
        } ?? record.progress
        rows[record.ratingKey] = Row(
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
        sideAssetHydrationCache.removeValue(forKey: record.ratingKey)
        let ticket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let persistence = waitForPersistence(through: ticket)
        guard persistence.result.committed(through: persistence.ticket) else {
            return .failed(key, persistence.result)
        }
        if let oldWorkingURLToRemove {
            try? fileManager.removeItem(at: oldWorkingURLToRemove)
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

    /// Record the locally-cached Plex BIF path (relative to the base dir) on a row's
    /// metadata snapshot (#78). No-op if the row or metadata is gone.
    func setPlexBIFRelativePath(ratingKey: String, _ relativePath: String) {
        updateMetadata(ratingKey: ratingKey) { $0.plexBIFRelativePath = relativePath }
    }

    func setEmbyBIFRelativePath(ratingKey: String, _ relativePath: String) {
        updateMetadata(ratingKey: ratingKey) { $0.embyBIFRelativePath = relativePath }
    }

    /// Record locally-cached Jellyfin trickplay assets (#79). Relative paths only; the playlist
    /// itself is sanitized before writing, so no token-bearing URLs are persisted.
    func setJellyfinTrickPlayRelativePaths(ratingKey: String, playlist: String, tiles: [String]) {
        updateMetadata(ratingKey: ratingKey) {
            $0.jellyfinTrickPlayPlaylistRelativePath = playlist
            $0.jellyfinTrickPlayTileRelativePaths = tiles
        }
    }

    /// Record locally-cached per-chapter image paths (#88/#89), keyed by chapter index. Relative
    /// paths only. No-op for an empty map or a missing row/metadata.
    func setChapterImageRelativePaths(ratingKey: String, _ relativePathsByIndex: [Int: String]) {
        guard !relativePathsByIndex.isEmpty else { return }
        updateMetadata(ratingKey: ratingKey) { $0.chapterImageRelativePaths = relativePathsByIndex }
    }

    func setOfflineTextSubtitles(ratingKey: String, _ tracks: [OfflineTextSubtitleTrack]) {
        guard !tracks.isEmpty else { return }
        updateMetadata(ratingKey: ratingKey) { $0.offlineTextSubtitles = tracks }
    }

    /// Persist the last local-file playback position for a completed offline row (#146).
    ///
    /// This intentionally updates `localPlaybackPositionMs`, not the captured server `viewOffset`,
    /// so offline progress stays per downloaded row/version and online timeline semantics remain
    /// untouched. The pure policy clamps negatives/over-duration values and resets near-EOF
    /// positions to 0 so reopening does not land on a final frame.
    @discardableResult
    func setLocalPlaybackPosition(
        for key: DownloadAttemptKey,
        positionMs: Int,
        durationMs: Int?
    ) -> AttemptMutationResult {
        updateMetadata(for: key) { meta in
            let effectiveDuration = durationMs ?? meta.duration
            meta.localPlaybackPositionMs = OfflinePlaybackPositionPolicy.standard
                .persistedPositionMs(currentMs: positionMs, durationMs: effectiveDuration)
        }
    }

    /// #84: persist the server-minted `PlaySessionId` for a transcoded JF/Emby (or Plex optimize)
    /// job so a hard app kill can still tear the encoder down on next launch. Status-change-grade:
    /// persists immediately (not throttled). No-op if the row/metadata is gone.
    @discardableResult
    func setPlaySessionID(
        for key: DownloadAttemptKey,
        _ playSessionID: String
    ) -> AttemptMutationResult {
        guard !playSessionID.isEmpty else { return .noChange }
        return updateMetadata(for: key) { $0.playSessionID = playSessionID }
    }

    /// Clear only the exact server encoder handle that a confirmed teardown executed. A delayed
    /// cleanup for attempt A/session X must not clear attempt B or even a newer session Y owned by
    /// the same attempt after renegotiation.
    @discardableResult
    func clearPlaySessionID(
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
        rows[key.ratingKey] = row
        let ticket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let persistence = waitForPersistence(through: ticket)
        return persistence.result.committed(through: persistence.ticket)
            ? .cleared : .persistenceFailed(persistence.result)
    }

    /// #84: persist the authoritative media-source id chosen for this download so a retry can
    /// re-issue the request without re-deriving it. No-op if the row/metadata is gone.
    func setMediaSourceID(ratingKey: String, _ mediaSourceID: String) {
        updateMetadata(ratingKey: ratingKey) { $0.mediaSourceID = mediaSourceID }
    }

    /// Persist the exact static resource size once a byte-range transfer discovers it. Rows may
    /// relaunch/reattach while the active bytes are still in URLSession's temp file; keeping this
    /// denominator durable lets the Offline UI continue to show percent/ETA from live Range bytes
    /// instead of falling back to a spinner + 0% caption.
    func setSourcePartSizeIfMissing(ratingKey: String, _ size: Int?) {
        setSourcePartSize(ratingKey: ratingKey, size, onlyIfMissing: true)
    }

    func setSourcePartSize(ratingKey: String, _ size: Int?) {
        setSourcePartSize(ratingKey: ratingKey, size, onlyIfMissing: false)
    }

    @discardableResult
    func setSourcePartSizeIfMissing(
        for key: DownloadAttemptKey,
        _ size: Int?
    ) -> AttemptMutationResult {
        setSourcePartSize(for: key, size, onlyIfMissing: true)
    }

    @discardableResult
    func setSourcePartSize(
        for key: DownloadAttemptKey,
        _ size: Int?
    ) -> AttemptMutationResult {
        setSourcePartSize(for: key, size, onlyIfMissing: false)
    }

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
        updateMetadata(for: key) { metadata in
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

    private func setSourcePartSize(ratingKey: String, _ size: Int?, onlyIfMissing: Bool) {
        guard let size, size > 0 else { return }
        lock.lock()
        let existing = rows[ratingKey]?.metadata?.sourcePartSize ?? 0
        lock.unlock()
        // Range progress delegates see the same Content-Range denominator on every callback.
        // Avoid rewriting metadata/index JSON, invalidating caches, and notifying refresh paths
        // when the value is already durable.
        guard existing != size else { return }
        guard !onlyIfMissing || existing <= 0 else { return }
        updateMetadata(ratingKey: ratingKey) { meta in
            if meta.sourcePartSize != size,
               (!onlyIfMissing || (meta.sourcePartSize ?? 0) <= 0) {
                meta.sourcePartSize = size
            }
        }
    }

    /// #95: persist a URLSession resume blob for a recoverably-interrupted download and record
    /// its relative path on the row's metadata, so a manual Resume (even after relaunch) can
    /// continue from the byte offset via `downloadTask(withResumeData:)`. The blob is written as
    /// a sibling `.resume` file (it can be large). No-op if the row/metadata is gone.
    func setResumeData(ratingKey: String, _ data: Data, displayBytes: Int? = nil) {
        // H9: `updateMetadata` is a no-op when a row carries no metadata snapshot (a
        // legacy pre-D5 row). Writing the blob first and only then discovering the path
        // can't be recorded would orphan a potentially large `.resume` file on disk. Bail
        // BEFORE writing when there's nothing to record it on — resume was already
        // unavailable for such a row, so this only avoids the leak, it changes no behavior.
        lock.lock()
        let canRecordPath = rows[ratingKey].map {
            $0.metadata != nil && !Self.hasPendingRowDeletion($0)
        } ?? false
        lock.unlock()
        guard canRecordPath else {
            NSLog("DownloadStore: skipping resume-data persist for %@ — row has no metadata to record its path on",
                  ratingKey)
            return
        }
        let url = resumeDataDestinationURL(ratingKey: ratingKey)
        do {
            try CredentialArtifactStorage.writeAuthArtifact(data, to: url, fileManager: fileManager)
        } catch {
            NSLog("DownloadStore: failed to persist resume data for %@ (%@)",
                  ratingKey, DiagnosticRedactor.safeErrorSummary(error))
            return
        }
        updateMetadata(ratingKey: ratingKey) {
            $0.resumeDataRelativePath = url.lastPathComponent
            if let displayBytes, displayBytes > 0 {
                $0.resumeDisplayBytes = max(displayBytes, $0.resumeDisplayBytes ?? 0)
            }
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
        rows[key.ratingKey] = row
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
        guard let relative, !relative.isEmpty else { return nil }
        return try? Data(contentsOf: baseDirectory.appendingPathComponent(relative))
    }

    func resumeData(for key: DownloadAttemptKey) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[key.ratingKey], row.attemptID == key.attemptID else { return nil }
        let relative = row.metadata?.resumeDataRelativePath
        guard let relative, !relative.isEmpty,
              Self.isSafeOneLevelRelativePath(relative) else { return nil }
        return try? Data(contentsOf: baseDirectory.appendingPathComponent(relative))
    }

    /// #95: whether a row has a persisted resume blob ON DISK (used by launch reconciliation to
    /// decide if a `.paused` row stays resumable). FS-checked without reading the blob.
    func hasResumeData(ratingKey: String) -> Bool {
        lock.lock()
        let relative = rows[ratingKey]?.metadata?.resumeDataRelativePath
        lock.unlock()
        guard let relative, !relative.isEmpty else { return false }
        return fileManager.fileExists(atPath: baseDirectory.appendingPathComponent(relative).path)
    }

    func hasResumeData(for key: DownloadAttemptKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[key.ratingKey], row.attemptID == key.attemptID,
              let relative = row.metadata?.resumeDataRelativePath,
              !relative.isEmpty, Self.isSafeOneLevelRelativePath(relative) else { return false }
        return fileManager.fileExists(
            atPath: baseDirectory.appendingPathComponent(relative).path)
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
        rows[key.ratingKey] = row
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
            rows[ticket.key.ratingKey] = publishing
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
        rows[ticket.key.ratingKey] = row
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
            rows[ticket.key.ratingKey] = capturing
            let captureTicket = enqueueAttemptPersistenceLocked()
            lock.unlock()
            let capture = waitForPersistence(through: captureTicket)
            guard capture.result.committed(through: captureTicket) else {
                failArtifactLifecycle(ticket, capture.result)
                return
            }
        }
        if let capturedRelative, Self.isSafeOneLevelRelativePath(capturedRelative) {
            let url = baseDirectory.appendingPathComponent(capturedRelative)
            do {
                var removed = false
                if artifactFilesystem.fileExists(url, fileManager) {
                    try artifactFilesystem.removeItem(url, fileManager)
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
        rows[ticket.key.ratingKey] = clearing
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
        rows[ticket.key.ratingKey] = row
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
                rows[ticket.key.ratingKey] = row
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
            artifactLifecycleTickets.removeValue(forKey: ticket.intentID)
            if staticCheckpointOutcomes[ticket.intentID] == nil {
                staticCheckpointAwaitingResultIDs.remove(ticket.intentID)
            }
        }
        artifactLifecycle.complete(ticket)
        recoverPendingArtifactIntents()
    }

    private func failArtifactLifecycle(
        _ ticket: DownloadArtifactLifecycleCoordinator.Ticket,
        _ failure: PersistenceFlushResult
    ) {
        let advanceDeletion = retireFailedHeadBeforeQueuedRowDeletion(ticket)
        lock.withLock {
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
            activeArtifactIntentIDs.remove(ticket.intentID)
            artifactLifecycleTickets.removeValue(forKey: ticket.intentID)
            staticCheckpointAwaitingResultIDs.remove(ticket.intentID)
            staticCheckpointOutcomes.removeValue(forKey: ticket.intentID)
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
        rows[ticket.key.ratingKey] = row
        let transition = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let outcome = waitForPersistence(through: transition)
        guard outcome.result.committed(through: transition) else {
            lock.lock()
            if var restored = rows[ticket.key.ratingKey],
               restored.attemptID == ticket.key.attemptID,
               !restored.pendingArtifactIntents.contains(where: { $0.id == failed.id }) {
                restored.pendingArtifactIntents.insert(failed, at: 0)
                rows[ticket.key.ratingKey] = restored
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
        }
        // The retired head is permanently dead — nothing ever re-registers its intentID — so its
        // failed coordinator entry must stop gating lifecycle boundaries. The caller still records
        // the failure on the ticket for its own synchronous waiters.
        artifactLifecycle.abandonIntent(failed.id)
        return true
    }

    private func recoverPendingArtifactIntents() {
        lock.lock()
        let pending: [(DownloadAttemptKey, Row.ArtifactIntent)] = rows.values.compactMap { row -> (DownloadAttemptKey, Row.ArtifactIntent)? in
            guard let attemptID = row.attemptID else { return nil }
            let key = DownloadAttemptKey(ratingKey: row.ratingKey, attemptID: attemptID)
            guard !artifactRetirementKeys.contains(key) else { return nil }
            guard let head = row.pendingArtifactIntents.first,
                  !activeArtifactIntentIDs.contains(head.id) else { return nil }
            return (key, head)
        }
        activeArtifactIntentIDs.formUnion(pending.map { $0.1.id })
        let scheduled = pending.map { key, intent -> (DownloadAttemptKey, Row.ArtifactIntent, DownloadArtifactLifecycleCoordinator.Ticket) in
            let ticket = artifactLifecycleTickets[intent.id] ?? artifactLifecycle.register(
                key: key, generation: intent.generation, intentID: intent.id,
                preparedRevision: .init(revision: 0))
            artifactLifecycleTickets[intent.id] = ticket
            return (key, intent, ticket)
        }
        lock.unlock()
        for (_, intent, ticket) in scheduled {
            scheduleArtifactLifecycle(ticket: ticket, intent: intent)
        }
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
        updateMetadata(for: key) { $0.rangeValidator = validator }
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
        updateMetadata(for: key) { $0.rangeValidator = nil }
    }

    func downloadAttemptIdentity(ratingKey: String) -> DownloadAttemptID? {
        lock.lock(); defer { lock.unlock() }
        return rows[ratingKey]?.attemptID
    }

    /// Startup accepts only a fully current exact-attempt snapshot. Unsupported schemas are reset
    /// as one opaque root; malformed current rows are retained byte-for-byte and fail closed.
    func startupIndexAdmission() -> StartupIndexAdmission {
        lock.lock(); defer { lock.unlock() }
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

    private static func hasAsyncCleanupEvidence(_ row: Row) -> Bool {
        guard let metadata = row.metadata else { return false }
        return metadata.playSessionID?.isEmpty == false
            || metadata.embyConvertJobID != nil
            || metadata.hasEmbyConvertCrashWindowIdentity
            || metadata.resumeDataRelativePath?.isEmpty == false
            || !(metadata.heldRangeSegments?.isEmpty ?? true)
    }

    /// #169: reset persisted static byte-range progress to the bytes that are actually durable in
    /// the partial file. The current in-flight static Range task body lives in an OS temp
    /// until `didFinishDownloadingTo`; progress callbacks may have published those optimistic bytes
    /// for UI smoothness, but pause/error/reconcile paths must checkpoint from this file size only.
    @discardableResult
    func resetStaticRangeProgressToDurableCheckpoint(ratingKey: String,
                                                     expectedBytes explicitExpectedBytes: Int? = nil) -> Int {
        lock.lock()
        guard var row = rows[ratingKey] else { lock.unlock(); return 0 }
        let backend = row.metadata?.resolvedBackendKind(ratingKey: row.ratingKey)
            ?? DownloadBackendKind(ratingKeyPrefix: row.ratingKey)
        let mode = row.metadata?.resolvedResumeMode(ratingKey: row.ratingKey)
            ?? DownloadResumeMode.resolved(
                backend: backend,
                lane: row.metadata?.resolvedDownloadLane() ?? .original)
        guard mode == .staticByteRange else {
            let bytes = row.bytes
            lock.unlock()
            return bytes
        }
        let durableBytes = fileSize(relativePath: row.relativePath) ?? 0
        let expectedBytes = explicitExpectedBytes ?? Self.expectedBytesEstimate(row: row)
        let progress = Self.progressForDurableBytes(durableBytes, expectedBytes: expectedBytes)
        var changed = false
        // The resume display watermark represents temp bytes owned by a URLSession resume blob.
        // Once no blob remains (durable fallback discarded it, adoption rejected it as stale, or a
        // restart never produced one), those temp bytes are gone — keeping the watermark would
        // over-report progress until live bytes caught back up. The pause path persists the blob
        // BEFORE resetting, so legitimate watermarks survive this.
        if row.metadata?.resumeDisplayBytes != nil,
           (row.metadata?.resumeDataRelativePath ?? "").isEmpty {
            row.metadata?.resumeDisplayBytes = nil
            changed = true
        }
        if row.bytes != durableBytes || abs(row.progress - progress) > 0.000_001 {
            row.bytes = durableBytes
            row.progress = progress
            changed = true
        }
        guard changed else {
            lock.unlock()
            return durableBytes
        }
        rows[ratingKey] = row
        lock.unlock()
        persist()
        return durableBytes
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
        rows[key.ratingKey] = row
        let prepared = enqueueAttemptPersistenceLocked()
        let ticket = artifactLifecycle.register(
            key: key, generation: intent.generation, intentID: intent.id,
            preparedRevision: prepared)
        artifactLifecycleTickets[intent.id] = ticket
        staticCheckpointAwaitingResultIDs.insert(intent.id)
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
        case .accepted(let ticket):
            let outcome = artifactLifecycle.waitSynchronously(for: ticket)
            if let result = lock.withLock({ () -> AttemptStaticRangeCheckpointResetResult? in
                staticCheckpointAwaitingResultIDs.remove(ticket.intentID)
                return staticCheckpointOutcomes.removeValue(forKey: ticket.intentID)
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
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                continuation.resume(returning: resolveStaticCheckpointSynchronously(submission))
            }
        }
    }

    private func recordStaticCheckpointOutcomeLocked(
        _ result: AttemptStaticRangeCheckpointResetResult,
        intentID: UUID
    ) {
        guard staticCheckpointAwaitingResultIDs.contains(intentID) else { return }
        staticCheckpointOutcomes[intentID] = result
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
                    rows[ticket.key.ratingKey] = row
                }
                recordStaticCheckpointOutcomeLocked(
                    .persistenceFailed(bytes: durable, prepared.result), intentID: intent.id)
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
        rows[ticket.key.ratingKey] = row
        let terminal = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let terminalOutcome = waitForPersistence(through: terminal)
        guard terminalOutcome.result.committed(through: terminal) else {
            lock.lock()
            if var restored = rows[ticket.key.ratingKey], restored.attemptID == ticket.key.attemptID {
                restored.pendingArtifactIntents.insert(retiring, at: 0)
                rows[ticket.key.ratingKey] = restored
                _ = enqueueAttemptPersistenceLocked()
            }
            artifactRetirementKeys.remove(ticket.key)
            recordStaticCheckpointOutcomeLocked(
                .persistenceFailed(bytes: durable, terminalOutcome.result), intentID: intent.id)
            lock.unlock()
            failArtifactLifecycle(ticket, terminalOutcome.result); return
        }
        lock.withLock {
            artifactRetirementKeys.remove(ticket.key)
            recordStaticCheckpointOutcomeLocked((reconstructed
                || oldBytes != durable || abs(oldProgress - progress) > 0.000_001)
                ? .applied(bytes: durable) : .unchanged(bytes: durable), intentID: intent.id)
        }
        completeArtifactLifecycle(ticket)
    }

    /// Every local path for which a row still has durable ownership or lifecycle authority.
    /// Destructive workers use this for cross-row exclusion, including paths captured only by a
    /// pending intent rather than ordinary published metadata.
    private func artifactPathsReferenced(by row: Row) -> Set<String> {
        var result: Set<String> = [row.relativePath]
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
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[key.ratingKey], row.attemptID == key.attemptID,
              row.metadata?.resolvedResumeMode(ratingKey: row.ratingKey) == .staticByteRange else {
            return nil
        }
        // Terminal promotion consumes and nils the attempt-private working path. Integrity audits
        // must stat the published stable body for completed/unverified rows; nonterminal resume
        // paths continue to trust only the private exact-attempt checkpoint.
        if row.status == .complete || row.status == .unverified {
            return fileSize(relativePath: row.relativePath) ?? 0
        }
        guard let workingRelative = workingRelativePath(for: row, key: key) else { return nil }
        return fileSize(relativePath: workingRelative) ?? 0
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
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[key.ratingKey], row.attemptID == key.attemptID,
              row.metadata?.resolvedResumeMode(ratingKey: row.ratingKey) == .staticByteRange,
              row.status != .complete, row.status != .unverified else { return nil }
        let resumeRelative = row.metadata?.resumeDataRelativePath
        let resumeURL = resumeRelative.flatMap { relative in
            Self.isSafeOneLevelRelativePath(relative)
                ? baseDirectory.appendingPathComponent(relative) : nil
        }
        let held = row.metadata?.heldRangeSegments ?? []
        guard let workingRelative = workingRelativePath(for: row, key: key) else { return nil }
        return StaticRangeRecoveryEvidence(
            ratingKey: row.ratingKey,
            status: row.status,
            durableBytes: fileSize(relativePath: workingRelative) ?? 0,
            resumeManifestRecorded: resumeRelative?.isEmpty == false,
            resumeBlobPresent: resumeURL.map { fileManager.fileExists(atPath: $0.path) } ?? false,
            resumeBlobBytes: resumeURL.flatMap(fileSize(at:)) ?? 0,
            heldBodyCount: held.count,
            heldBodyBytes: held.reduce(0) { $0 + max(0, $1.length) }
        )
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
        guard newlyReferenced.allSatisfy({ reservedArtifactDeletionPaths[$0] == nil }) else {
            lock.unlock(); return
        }
        row.metadata = meta
        rows[ratingKey] = row
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
    func updateMetadata(
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
        guard newlyReferenced.allSatisfy({ reservedArtifactDeletionPaths[$0] == nil }) else {
            lock.unlock(); return .staleOrMissing
        }
        row.metadata = metadata
        rows[key.ratingKey] = row
        sideAssetHydrationCache.removeValue(forKey: key.ratingKey)
        let ticket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        return .accepted(change: .applied, ticket: ticket)
    }

    /// Remove only the short-lived Sync-list crash-window markers. The server job id and File
    /// source snapshot have independent lifetimes and must remain available for polling/pickup.
    func clearEmbyConvertRecovery(ratingKey: String) {
        updateMetadata(ratingKey: ratingKey) {
            $0.clearEmbyConvertRecoveryIdentity()
        }
    }

    /// Forget a Sync job id that reached a TERMINAL server state (Failed/Cancelled/404/410), so a
    /// retry creates a fresh job instead of resuming polling a dead one.
    func clearEmbyConvertJobID(ratingKey: String) {
        updateMetadata(ratingKey: ratingKey) {
            $0.embyConvertJobID = nil
        }
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
        var statusChanged = false
        if row.status == .queued || row.status == .paused || row.status == .failed {
            row.status = .downloading
            statusChanged = true
        }
        rows[ratingKey] = row
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
        let statusChanged = row.status == .queued || row.status == .paused || row.status == .failed
        if statusChanged { row.status = .downloading }
        let changed = row.bytes != bytes || row.progress != progress || statusChanged
        guard changed else {
            lock.unlock()
            return .accepted(change: .noChange, ticket: nil)
        }
        row.bytes = bytes
        row.progress = progress
        rows[key.ratingKey] = row
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

    /// Set the explicit lifecycle status for a row (D2). No-op if the row is gone.
    func setStatus(ratingKey: String, _ status: DownloadStatus) {
        lock.lock()
        guard var row = rows[ratingKey] else { lock.unlock(); return }
        let previousStatus = row.status
        let bytes = row.bytes
        let progress = row.progress
        row.status = status
        rows[ratingKey] = row
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
        row.status = status
        rows[key.ratingKey] = row
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

    /// Promote a previously byte-complete but probe-inconclusive row once a later validation or
    /// actual local playback proves the file is usable. No-op for already-complete/active/failed rows
    /// so callers can safely invoke this from reconnect and playback-progress paths.
    @discardableResult
    func markCompleteIfUnverified(
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
        row.status = .complete
        rows[key.ratingKey] = row
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
    func reconcile(liveRatingKeys: Set<String>, snapshotRatingKeys: Set<String>) {
        lock.lock()
        var changed = false
        for (key, var row) in rows {
            // A deletion-pending row is a sealed recovery capsule. Reconcile must not demote it,
            // rewrite its checkpoint counters, or delete main/resume artifacts while the cleanup
            // journal is unavailable; cleanup migration is the only path allowed to unseal it.
            guard !row.deletionPending else { continue }
            // A row with pending artifact intents is owned by the durable artifact queue: intent
            // replay runs asynchronously on the artifact worker queue with no ordering barrier
            // against this reconcile, and a staged `.validatedPromotion` head leaves the row
            // `.downloading` while the working file IS the fully-validated body. Demoting the row
            // or deleting its working/resume files here would destroy the intent's source, so
            // replay/abandonment is the only authority allowed to resolve these rows.
            guard row.pendingArtifactIntents.isEmpty else { continue }
            guard DownloadStatus.reconcileEligible(ratingKey: key,
                                                   snapshotRatingKeys: snapshotRatingKeys) else { continue }
            let hasLiveTask = liveRatingKeys.contains(key)
            let isTerminal = row.status == .complete || row.status == .unverified
            let evidenceURL: URL? = {
                if isTerminal { return baseDirectory.appendingPathComponent(row.relativePath) }
                guard let attemptID = row.attemptID,
                      let working = workingRelativePath(
                        for: row,
                        key: DownloadAttemptKey(ratingKey: row.ratingKey, attemptID: attemptID))
                else { return nil }
                return baseDirectory.appendingPathComponent(working)
            }()
            let partialBytes = evidenceURL.flatMap(fileSize(at:)) ?? 0
            let fileExists = evidenceURL.map {
                partialBytes > 0 || fileManager.fileExists(atPath: $0.path)
            } ?? false
            // #95: does a persisted resume blob survive for this row? A `.paused` row stays
            // resumable only while it does (checked WITHOUT reading the blob).
            let resumeRelative = row.metadata?.resumeDataRelativePath
            let hasResumeData = (resumeRelative?.isEmpty == false)
                && fileManager.fileExists(
                    atPath: baseDirectory.appendingPathComponent(resumeRelative!).path)
            let resumeMode = row.metadata?.resolvedResumeMode(ratingKey: row.ratingKey)
                ?? DownloadResumeMode.resolved(
                    backend: row.metadata?.resolvedBackendKind(ratingKey: row.ratingKey)
                        ?? DownloadBackendKind(ratingKeyPrefix: row.ratingKey),
                    lane: row.metadata?.resolvedDownloadLane() ?? .original)
            let hasServerPrepCheckpoint = resumeMode == .serverPrepThenStatic
                && row.status == .paused
                && (row.metadata?.optimizeTargetName?.isEmpty == false
                    || row.metadata?.embyConvertJobID != nil)
            let hasAppRangeCheckpoint = resumeMode == .staticByteRange
                && (row.status == .paused || row.status == .queued || row.status == .downloading)
                && partialBytes > 0
            let staticRangeExpectedBytes = Self.expectedBytesEstimate(row: row)
            let staticRangeProgress = Self.progressForDurableBytes(
                partialBytes,
                expectedBytes: staticRangeExpectedBytes
            )
            // Only Plex has a server-side "prepare then static download" optimize queue that can
            // resume after relaunch. Jellyfin AND Emby transcoded rows are LIVE streams from a
            // URLSession task (Emby additionally renders via a server FFmpeg encoder), so a
            // missing task means the render is gone — they must demote to retryable `.failed`, not
            // resume as `.queued`. Hence both backend prefixes are excluded here.
            let isPlexServerPrepOptimizedJob = !hasLiveTask
                && (row.status == .queued || row.status == .downloading)
                && resumeMode == .serverPrepThenStatic
                && row.metadata?.optimizeTargetName?.isEmpty == false
                && !row.ratingKey.hasPrefix("jellyfin:")
                && !row.ratingKey.hasPrefix("emby:")
            let hasLiveStaticRangeTask = hasLiveTask
                && resumeMode == .staticByteRange
                && (row.status == .paused || row.status == .queued || row.status == .downloading)
            let newStatus: DownloadStatus
            if isPlexServerPrepOptimizedJob {
                newStatus = .queued
            } else if hasLiveStaticRangeTask {
                // A reattached background Range task is authoritative live work. Do not park the row
                // as `.paused` merely because a durable partial exists: that made the UI offer Resume
                // while nsurlsessiond was still delivering callbacks, allowing a duplicate Range task
                // to start at the same checkpoint.
                newStatus = .downloading
            } else if hasServerPrepCheckpoint || hasAppRangeCheckpoint {
                newStatus = .paused
            } else {
                newStatus = DownloadStatus.reconciledStatus(
                    current: row.status, fileExists: fileExists,
                    hasLiveTask: hasLiveTask, hasResumeData: hasResumeData,
                    canRestartFromStaticCheckpoint: resumeMode == .staticByteRange)
            }
            let shouldResetOptimizedProgress = isPlexServerPrepOptimizedJob
                && (row.bytes != 0 || row.progress != 0)
            let shouldResetRangeProgress = hasAppRangeCheckpoint
                && (row.bytes != partialBytes || abs(row.progress - staticRangeProgress) > 0.000_001)
            let shouldResetMissingRangeProgress = resumeMode == .staticByteRange
                && !hasLiveTask
                && !hasAppRangeCheckpoint
                && (row.status == .paused || row.status == .queued
                    || row.status == .downloading || row.status == .failed)
                && (row.bytes != 0 || row.progress != 0)
            guard newStatus != row.status
                    || shouldResetOptimizedProgress
                    || shouldResetRangeProgress
                    || shouldResetMissingRangeProgress else { continue }
            // A non-live queued/downloading row that we're demoting to `.failed` may have left a
            // partial file behind. Delete it so dead bytes don't sit invisibly on disk — a retry
            // rebuilds the file from scratch regardless. #95: but a row that STAYS resumable
            // (`.paused` with a surviving resume blob) must KEEP its partial, or the resume data
            // is useless; only delete when we're actually demoting to a non-resumable terminal state.
            let isStayingResumable = (newStatus == .paused)
            if (row.status == .queued || row.status == .downloading || row.status == .paused)
                && !hasLiveTask && !isStayingResumable {
                if let evidenceURL { try? fileManager.removeItem(at: evidenceURL) }
                if resumeRelative?.isEmpty == false {
                    try? fileManager.removeItem(
                        at: baseDirectory.appendingPathComponent(resumeRelative!))
                }
            }
            row.status = newStatus
            if isPlexServerPrepOptimizedJob {
                row.bytes = 0
                row.progress = 0
            } else if hasAppRangeCheckpoint {
                row.bytes = partialBytes
                row.progress = staticRangeProgress
            } else if shouldResetMissingRangeProgress {
                row.bytes = 0
                row.progress = 0
            }
            rows[key] = row
            changed = true
        }
        lock.unlock()
        if changed { persist() }
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

    private func submitRemove(
        for key: DownloadAttemptKey,
        requiresDeletionPending: Bool
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
        rows[key.ratingKey] = row
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
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                continuation.resume(returning: resolveRowDeletionSynchronously(submission))
            }
        }
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
        let removed = rows.removeValue(forKey: ticket.key.ratingKey)!
        sideAssetHydrationCache.removeValue(forKey: ticket.key.ratingKey)
        let terminal = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let outcome = waitForPersistence(through: terminal)
        guard outcome.result.committed(through: terminal) else {
            let epoch = RowDeletionTicketEpoch(ticket)
            lock.lock()
            if rows[ticket.key.ratingKey] == nil { rows[ticket.key.ratingKey] = removed }
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

    private func load() {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: indexURL) else { return }
        // #135 H8: decode the index row-by-row so a single corrupt/forward-incompatible
        // row can't drop the user's whole offline library (the old all-or-nothing
        // `decode([Row].self)` did exactly that). A non-zero skip is logged rather than
        // swallowed — silent truncation is the failure mode this guards against.
        let result = DownloadIndexCoding.decode(Row.self, from: data)
        if result.skippedRowCount > 0 {
            NSLog("DownloadStore: skipped %d corrupt offline-index row(s) on load (schemaVersion %d); %d row(s) preserved",
                  result.skippedRowCount, result.schemaVersion, result.rows.count)
        }
        var normalizedPreparedStaticRows = 0
        var fencedSideAssetRows = 0
        var retiredSideAssetPaths: Set<String> = []
        rows = Dictionary(uniqueKeysWithValues: result.rows.map { row in
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
                if metadata.hasCachedSideAssets,
                   expectedOwner == nil || metadata.sideAssetBundleOwner != expectedOwner {
                    retiredSideAssetPaths.formUnion(sideAssetRelativePaths(for: metadata))
                    metadata.clearCachedSideAssets()
                    fencedSideAssetRows += 1
                } else if !metadata.hasCachedSideAssets,
                          metadata.sideAssetBundleOwner != nil {
                    metadata.sideAssetBundleOwner = nil
                    fencedSideAssetRows += 1
                }
                repaired.metadata = metadata
            }
            return (repaired.ratingKey, repaired)
        })
        if !retiredSideAssetPaths.isEmpty {
            var stillReferenced: Set<String> = []
            for row in rows.values {
                stillReferenced.formUnion(artifactPathsReferenced(by: row))
            }
            for path in retiredSideAssetPaths.subtracting(stillReferenced) {
                try? fileManager.removeItem(at: baseDirectory.appendingPathComponent(path))
            }
        }
        // Never let a best-effort cache repair stamp a pre-v4 snapshot as v4 before the startup
        // migration has durably closed admission and marked every nonterminal partial for reset.
        // The repaired values are already in memory and ride along with the migration snapshot.
        if normalizedPreparedStaticRows > 0 || fencedSideAssetRows > 0,
           startupSchemaProbe == .current {
            lock.unlock()
            persist()
            lock.lock()
        }
    }

    /// Relaunch recovery for the second half of the held-manifest/body transaction. A persisted
    /// intent proves the corresponding manifest-removal snapshot committed before the prior
    /// process died. Deletion is idempotent; failures keep the path in the row for the next launch.
    private func recoverDeferredHeldRangeBodyDeletions() {
        lock.lock()
        var changed = false
        let globallyReferenced = heldRangeManifestRelativePathsLocked()
        for (ratingKey, original) in rows {
            guard !original.heldRangeBodyDeletionIntents.isEmpty else { continue }
            var row = original
            var completed = Set<String>()
            for relativePath in row.heldRangeBodyDeletionIntents {
                guard Self.isSafeOneLevelRelativePath(relativePath) else { continue }
                if globallyReferenced.contains(relativePath) {
                    // Another durable manifest owns this shared/pathological reference now. Clear
                    // A's deletion claim without touching the body; the manifest remains authority.
                    completed.insert(relativePath)
                    continue
                }
                let url = baseDirectory.appendingPathComponent(relativePath)
                do {
                    if fileManager.fileExists(atPath: url.path) {
                        try fileManager.removeItem(at: url)
                    }
                    completed.insert(relativePath)
                } catch {}
            }
            guard !completed.isEmpty else { continue }
            row.heldRangeBodyDeletionIntents.removeAll { completed.contains($0) }
            rows[ratingKey] = row
            changed = true
        }
        guard changed else { lock.unlock(); return }
        let ticket = enqueuePersistenceLocked()
        lock.unlock()
        // If clearing the already-executed intents fails, the next launch safely replays them.
        _ = waitForPersistence(through: ticket)
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
        indexWriter.submit(revision: ticket.revision, snapshot: Array(rows.values))
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
            recoverPendingArtifactIntents()
        }
        return attempt
    }

    /// A cleanup repeated after its failed write sees no manifest in memory, but the absence is
    /// durable only once that dirty full snapshot commits. Avoid a redundant write for an already
    /// committed no-op; otherwise submit a new full snapshot so the call returns real proof.
    private func proveCleanupNoOpDurable() -> PersistenceAttempt {
        let ticket = currentPersistenceTicket()
        let state = indexWriter.state
        if state.dirtyRevision == nil, state.committedRevision >= ticket.revision {
            return PersistenceAttempt(
                ticket: ticket,
                result: .committed(revision: state.committedRevision)
            )
        }
        return persist()
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
        async let index = flushPersistence(through: ticket, timeout: timeout)
        async let artifacts = artifactLifecycle.flush(
            through: artifactWatermark, timeout: timeout)
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
        _ result: RevisionedPersistenceWriter<[Row]>.FlushResult
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
