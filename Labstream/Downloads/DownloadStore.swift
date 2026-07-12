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

    struct IndexPersistence: Sendable {
        let atomicWrite: @Sendable (Data, URL) throws -> Void

        static let live = IndexPersistence { data, url in
            try data.write(to: url, options: .atomic)
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

    struct LegacyAttemptMigrationPlan: Sendable, Equatable {
        /// Pre-v3 rows that may still have an OS task or partial artifacts. The coordinator must
        /// cancel legacy tasks before invoking `resetLegacyAttemptAfterTaskCancellation`.
        let taskCancellationAndReset: [DownloadAttemptKey]
        /// Completed/unverified rows retain their media. An ID is assigned only when durable
        /// cleanup evidence means asynchronous ownership can still exist.
        let cleanupOnly: [DownloadAttemptKey]
    }

    /// Durable file layout for the media body owned by one download attempt. `stableURL` is the
    /// URL published by `DownloadRecord`; transfer callbacks must write/checkpoint `workingURL`
    /// and promote it only after re-validating exact ownership.
    struct AttemptWorkingFileLayout: Sendable, Equatable {
        let key: DownloadAttemptKey
        let stableURL: URL
        let workingURL: URL
    }

    enum AttemptOwnershipMigrationResult: Sendable, Equatable {
        case notRequired
        case committed(LegacyAttemptMigrationPlan)
        case failed(LegacyAttemptMigrationPlan, PersistenceFlushResult)
        /// A v3 active/cleanup-bearing row without top-level ownership is malformed. Never repair
        /// this as though it were legacy: doing so could bless an unrelated live task.
        case malformedV3Rows([String])
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
        case legacyResetPending
        case validatedPromotionPending
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

    enum LegacyAttemptResetResult: Sendable, Equatable {
        case committed(DownloadAttemptKey, cleanupFailureCount: Int)
        case cleanupFailed(DownloadAttemptKey, cleanupFailureCount: Int)
        case staleOrMissing
        case notPending
        case failed(DownloadAttemptKey, PersistenceFlushResult)
    }

    private struct PersistenceAttempt {
        let ticket: PersistenceTicket
        let result: PersistenceFlushResult
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

    enum AttemptHeldRangeSegmentPersistResult: Sendable, Equatable {
        case accepted(
            previous: OfflineHeldRangeSegment?,
            ticket: PersistenceTicket,
            persistence: PersistenceFlushResult
        )
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
        /// Durable migration barrier. While true, legacy OS tasks must be cancelled and this row's
        /// partial artifacts reset before background callback admission may open.
        var legacyResetPending: Bool
        var legacyResetArtifactRelativePaths: [String]?
        /// Decode-only evidence used to distinguish a valid v3 owner from the nested v2 fallback.
        /// This field is deliberately absent from CodingKeys.
        var decodedTopLevelAttemptIDPresent: Bool
        var decodedAttemptIdentityDisagrees: Bool

        private enum CodingKeys: String, CodingKey {
            case ratingKey, attemptID, title, relativePath, attemptWorkingRelativePath
            case pendingValidatedPromotionStatus
            case bytes, progress, status, metadata
            case legacyResetPending
            case legacyResetArtifactRelativePaths
        }

        // Backward-compatible decoding: rows written before D2 lack `status`.
        // Infer it from the old progress signal so existing libraries keep
        // working — a finished-looking row maps to `.complete`, anything else
        // to `.queued` (launch reconciliation then re-checks it against disk).
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
            status = try c.decodeIfPresent(DownloadStatus.self, forKey: .status)
                ?? DownloadStatus.migratedStatus(forLegacyProgress: progress)
            metadata = try c.decodeIfPresent(OfflineMetadata.self, forKey: .metadata)
            let nestedAttemptID = metadata?.downloadAttemptID.flatMap(DownloadAttemptID.init(rawValue:))
            attemptID = topLevelAttemptID ?? nestedAttemptID
            legacyResetPending = try c.decodeIfPresent(Bool.self, forKey: .legacyResetPending) ?? false
            legacyResetArtifactRelativePaths = try c.decodeIfPresent(
                [String].self, forKey: .legacyResetArtifactRelativePaths)
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
             legacyResetPending: Bool = false,
             legacyResetArtifactRelativePaths: [String]? = nil) {
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
            self.legacyResetPending = legacyResetPending
            self.legacyResetArtifactRelativePaths = legacyResetArtifactRelativePaths
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
            if legacyResetPending { try c.encode(true, forKey: .legacyResetPending) }
            try c.encodeIfPresent(legacyResetArtifactRelativePaths,
                                  forKey: .legacyResetArtifactRelativePaths)
        }
    }

    /// Minimum spacing between index rewrites driven by progress callbacks.
    private static let progressPersistInterval: TimeInterval = 1

    private let lock = NSLock()
    private struct HydratedSideAssets {
        var posterURL: URL?
        var plexBIFURL: URL?
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
    private let startupStagingInventory: Set<String>
    private let indexURL: URL                        // baseDirectory/index.json
    private let embyCleanupURL: URL                  // durable orphan-prevention queue
    private let fileManager: FileManager
    private let embyCleanupPersistence: EmbyCleanupPersistence
    private let indexWriter: RevisionedPersistenceWriter<[Row]>
    private var nextPersistenceRevision: UInt64 = 0 // guarded by `lock`
    private var loadedSchemaVersion = DownloadIndexCoding.currentSchemaVersion // guarded by `lock`
    private var pendingLegacyAttemptResetKeys: Set<DownloadAttemptKey> = [] // guarded by `lock`
    private var pendingLegacyResetArtifacts: [DownloadAttemptKey: Set<URL>] = [:] // guarded by `lock`

    /// - Parameter baseDirectory: where media files + the index live. Defaults to
    ///   `Application Support/Labstream/Downloads`, created if missing.
    init(baseDirectory: URL? = nil,
         fileManager: FileManager = .default,
         indexPersistence: IndexPersistence = .live,
         embyCleanupPersistence: EmbyCleanupPersistence? = nil) {
        self.fileManager = fileManager
        self.embyCleanupPersistence = embyCleanupPersistence ?? .live
        let appSupport = (try? fileManager.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil,
                                                create: true))
            ?? fileManager.temporaryDirectory
        let dir = baseDirectory ?? appSupport
            .appendingPathComponent("Labstream", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
        self.baseDirectory = dir
        self.startupStagingInventory = Set(
            ((try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter(Self.isAttemptStagingRelativePath))
        let indexURL = dir.appendingPathComponent("index.json")
        self.indexURL = indexURL
        self.embyCleanupURL = dir.appendingPathComponent("emby-convert-cleanup.json")
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
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        // Exclude the offline cache from iCloud/device backups and give newly-created
        // auth-adjacent artifacts a protected parent directory.
        try? CredentialArtifactStorage.applyProtectionAndBackupExclusion(
            to: self.baseDirectory,
            protection: CredentialArtifactStorage.authArtifactProtection,
            fileManager: fileManager)
        load()
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
              !row.legacyResetPending,
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

    /// Publish a caller-validated media body as one linearized Store operation. A validated intent
    /// is committed before rename, then rename, terminal row mutation, and terminal snapshot
    /// submission occur under the ownership lock. The intent is the durable proof used after a
    /// hard kill; arbitrary pre-existing bytes at the stable path are never inferred to belong to A.
    @discardableResult
    func promoteValidatedAttempt(
        for key: DownloadAttemptKey,
        terminalStatus: DownloadStatus
    ) -> AttemptValidatedPromotionResult {
        guard terminalStatus == .complete || terminalStatus == .unverified else {
            return .invalidTerminalStatus
        }
        lock.lock()
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID else {
            lock.unlock()
            return .staleOrMissingOwner
        }
        guard !row.legacyResetPending else {
            lock.unlock()
            return .resetPending
        }
        guard row.pendingValidatedPromotionStatus == nil
                || row.pendingValidatedPromotionStatus == terminalStatus else {
            lock.unlock()
            return .invalidTerminalStatus
        }
        guard let workingRelative = workingRelativePath(for: row, key: key) else {
            lock.unlock()
            return .invalidWorkingLayout
        }
        let workingURL = baseDirectory.appendingPathComponent(workingRelative)
        let stableURL = baseDirectory.appendingPathComponent(row.relativePath)
        guard let bytes = fileSize(at: workingURL) else {
            lock.unlock()
            return .sourceMissing
        }
        // The pending intent is also an in-memory ownership reservation. Replacement/delete paths
        // refuse it, allowing the slow durability wait and rename to happen without blocking every
        // unrelated Store reader behind NSLock.
        row.pendingValidatedPromotionStatus = terminalStatus
        rows[key.ratingKey] = row
        let intentTicket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let intentPersistence = waitForPersistence(through: intentTicket)
        guard intentPersistence.result.committed(through: intentPersistence.ticket) else {
            return .persistenceFailed(key, intentPersistence.result)
        }
        if let renameError = renameReplacing(source: workingURL, destination: stableURL) {
            return .renameFailed(errorType: renameError)
        }
        lock.lock()
        guard var committedRow = rows[key.ratingKey],
              committedRow.attemptID == key.attemptID,
              committedRow.pendingValidatedPromotionStatus == terminalStatus else {
            lock.unlock()
            // The reservation should make this unreachable. Preserve the durable intent so launch
            // recovery, rather than an ownership guess, decides what may publish.
            return .staleOrMissingOwner
        }
        committedRow.bytes = bytes
        committedRow.progress = 1
        committedRow.status = terminalStatus
        // A terminal row publishes only the stable file. Dropping the now-consumed private path
        // keeps staging inventory honest and prevents a later caller from treating a missing
        // working body as terminal evidence.
        committedRow.attemptWorkingRelativePath = nil
        committedRow.pendingValidatedPromotionStatus = nil
        rows[key.ratingKey] = committedRow
        let ticket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let persistence = waitForPersistence(through: ticket)
        guard persistence.result.committed(through: persistence.ticket) else {
            return .persistenceFailed(key, persistence.result)
        }
        return .promoted(key, bytes: bytes, status: terminalStatus)
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
            lock.unlock()
            return .staleOrMissingOwner
        }
        guard !row.legacyResetPending else {
            lock.unlock()
            return .resetPending
        }
        guard let terminalStatus = row.pendingValidatedPromotionStatus,
              terminalStatus == .complete || terminalStatus == .unverified,
              let workingRelative = workingRelativePath(for: row, key: key) else {
            lock.unlock()
            return .invalidWorkingLayout
        }
        let workingURL = baseDirectory.appendingPathComponent(workingRelative)
        let stableURL = baseDirectory.appendingPathComponent(row.relativePath)
        if fileManager.fileExists(atPath: workingURL.path),
           let renameError = renameReplacing(source: workingURL, destination: stableURL) {
            lock.unlock()
            return .renameFailed(errorType: renameError)
        }
        guard let bytes = fileSize(at: stableURL), bytes > 0 else {
            lock.unlock()
            return .sourceMissing
        }
        row.bytes = bytes
        row.progress = 1
        row.status = terminalStatus
        row.attemptWorkingRelativePath = nil
        row.pendingValidatedPromotionStatus = nil
        rows[key.ratingKey] = row
        let ticket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let persistence = waitForPersistence(through: ticket)
        guard persistence.result.committed(through: persistence.ticket) else {
            return .persistenceFailed(key, persistence.result)
        }
        return .promoted(key, bytes: bytes, status: terminalStatus)
    }

    /// `nil` means success; otherwise the returned value is a privacy-safe error type.
    private func renameReplacing(source: URL, destination: URL) -> String? {
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return -1 }
                return Int(Darwin.rename(sourcePath, destinationPath))
            }
        }
        guard result != 0 else { return nil }
        return String(reflecting: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
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
        guard stableRelativePath(for: stableURL) != nil,
              let expectedStaging = attemptStagingURL(for: key, stableURL: stableURL),
              stagingURL.standardizedFileURL == expectedStaging.standardizedFileURL else {
            return .invalidPath
        }
        lock.lock(); defer { lock.unlock() }
        guard rows[key.ratingKey]?.attemptID == key.attemptID else {
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
        guard var row = rows[ratingKey], var metadata = row.metadata else {
            lock.unlock()
            return (false, false, nil)
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
              !row.legacyResetPending, var metadata = row.metadata else {
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
        offsets: [Int]
    ) -> AttemptHeldRangeSegmentsRemovalResult {
        let offsetSet = Set(offsets)
        lock.lock()
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID,
              !row.legacyResetPending, var metadata = row.metadata else {
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
        let ticket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let persistence = waitForPersistence(through: ticket)
        return .accepted(HeldRangeSegmentsRemovalResult(
            removed: removed,
            ticket: persistence.ticket,
            persistence: persistence.result
        ))
    }

    @discardableResult
    func takeHeldRangeSegments(ratingKey: String) -> HeldRangeSegmentsTakeResult {
        lock.lock()
        var removed: [OfflineHeldRangeSegment] = []
        if var row = rows[ratingKey], var metadata = row.metadata {
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
        for key: DownloadAttemptKey
    ) -> AttemptHeldRangeSegmentsRemovalResult {
        lock.lock()
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID,
              !row.legacyResetPending, var metadata = row.metadata else {
            lock.unlock()
            return .staleOrMissing
        }
        let removed = metadata.heldRangeSegments ?? []
        if !removed.isEmpty {
            metadata.heldRangeSegments = nil
            metadata.downloadAttemptID = key.attemptID.rawValue
            row.metadata = metadata
            rows[key.ratingKey] = row
        }
        let ticket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let persistence = waitForPersistence(through: ticket)
        return .accepted(HeldRangeSegmentsRemovalResult(
            removed: removed,
            ticket: persistence.ticket,
            persistence: persistence.result
        ))
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
        let relativePaths = removal.removed.map(\.relativePath)
            .filter(Self.isSafeOneLevelRelativePath)
            .sorted()
        // The index commit wait releases the store lock. Re-check before touching shared files,
        // then keep ownership stable through deletion so B cannot adopt a path between check/use.
        lock.lock()
        guard let row = rows[key.ratingKey], row.attemptID == key.attemptID,
              !row.legacyResetPending else {
            lock.unlock()
            return .purged(AttemptHeldRangePurgeResult(
                removal: removal,
                removedRelativePaths: [],
                failedRelativePaths: relativePaths
            ))
        }
        var removed: [String] = []
        var failed: [String] = []
        for relativePath in relativePaths {
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
        lock.unlock()
        return .purged(AttemptHeldRangePurgeResult(
            removal: removal,
            removedRelativePaths: removed.sorted(),
            failedRelativePaths: failed.sorted()
        ))
    }

    var referencedHeldRangeSegmentRelativePaths: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(rows.values.flatMap { row in
            row.metadata?.heldRangeSegments?.map(\.relativePath) ?? []
        }.filter(Self.isSafeOneLevelRelativePath))
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
        return rows[key.ratingKey]?.attemptID == key.attemptID
    }

    func record(for key: DownloadAttemptKey) -> DownloadRecord? {
        lock.lock()
        let row = rows[key.ratingKey]?.attemptID == key.attemptID ? rows[key.ratingKey] : nil
        lock.unlock()
        return row.map(hydratedRecord)
    }

    /// Raw persisted metadata for callers that do not need a hydrated `DownloadRecord`.
    func metadata(for ratingKey: String) -> OfflineMetadata? {
        lock.lock(); defer { lock.unlock() }
        return rows[ratingKey]?.metadata
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
        let sideAssets = hydratedSideAssets(ratingKey: row.ratingKey, metadata: row.metadata)
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
            metadata.jellyfinTrickPlayPlaylistRelativePath,
        ].compactMap { $0 })
        relatives.append(contentsOf: metadata.jellyfinTrickPlayTileRelativePaths ?? [])
        relatives.append(contentsOf: Array(metadata.chapterImageRelativePaths?.values ?? Dictionary<Int, String>().values))
        relatives.append(contentsOf: metadata.offlineTextSubtitles?.map(\.relativePath) ?? [])
        return relatives.filter(Self.isSafeOneLevelRelativePath)
    }

    private func hydratedSideAssets(ratingKey: String, metadata: OfflineMetadata?) -> HydratedSideAssets {
        lock.lock()
        if let cached = sideAssetHydrationCache[ratingKey] {
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
            posterURL: fastResolvedDownloadAssetURL(metadata?.posterRelativePath),
            plexBIFURL: fastResolvedDownloadAssetURL(metadata?.plexBIFRelativePath),
            jellyfinTrickPlayPlaylistURL: fastResolvedDownloadAssetURL(metadata?.jellyfinTrickPlayPlaylistRelativePath),
            chapterImageURLs: Self.fastResolvedChapterImageURLs(metadata?.chapterImageRelativePaths,
                                                               baseDirectory: baseDirectory),
            sideAssetBytes: sideAssetBytes
        )
        lock.lock()
        sideAssetHydrationCache[ratingKey] = hydrated
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
        guard let row, row.attemptID == key.attemptID, !row.legacyResetPending,
              let metadata = row.metadata,
              metadata.resolvedResumeMode(ratingKey: key.ratingKey) == .staticByteRange,
              let size = metadata.sourcePartSize, size > 0 else { return nil }
        return size
    }

    func sourcePartSize(for key: DownloadAttemptKey) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard let row = rows[key.ratingKey], row.attemptID == key.attemptID,
              !row.legacyResetPending, let size = row.metadata?.sourcePartSize,
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
        // Legacy/unconditional writers may not erase a validated-publication reservation.
        guard existing?.pendingValidatedPromotionStatus == nil else {
            lock.unlock()
            return
        }
        let attemptID = record.attemptID ?? existing?.attemptID
        var metadata = record.metadata ?? existing?.metadata
        if var incoming = record.metadata, let previous = existing?.metadata {
            incoming.preserveCachedSideAssets(from: previous)
            metadata = incoming
        }
        if let attemptID { metadata?.downloadAttemptID = attemptID.rawValue }
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
                                     legacyResetPending: existing?.legacyResetPending ?? false,
                                     legacyResetArtifactRelativePaths: existing?.legacyResetArtifactRelativePaths)
        sideAssetHydrationCache.removeValue(forKey: record.ratingKey)
        lock.unlock()
        persist()
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
        if existing?.legacyResetPending == true {
            lock.unlock()
            return .rejectedOwnership(
                expectedPreviousOwner: expectedKey,
                actualOwner: existingKey,
                reason: .legacyResetPending
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
        if var incoming = record.metadata, let oldMetadata = previous?.metadata {
            incoming.preserveCachedSideAssets(from: oldMetadata)
            metadata = incoming
        }
        metadata?.downloadAttemptID = attemptID.rawValue
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
            legacyResetPending: previous?.legacyResetPending ?? false,
            legacyResetArtifactRelativePaths: previous?.legacyResetArtifactRelativePaths
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
        return .committed(key)
    }

    /// Record the locally-cached poster path (relative to the base dir) on a row's
    /// metadata snapshot (D5). No-op if the row or its metadata is gone — a missing
    /// poster is never a download failure.
    func setPosterRelativePath(ratingKey: String, _ relativePath: String) {
        updateMetadata(ratingKey: ratingKey) { $0.posterRelativePath = relativePath }
    }

    /// Record the locally-cached Plex BIF path (relative to the base dir) on a row's
    /// metadata snapshot (#78). No-op if the row or metadata is gone.
    func setPlexBIFRelativePath(ratingKey: String, _ relativePath: String) {
        updateMetadata(ratingKey: ratingKey) { $0.plexBIFRelativePath = relativePath }
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

    /// Compatibility for completed v1/v2 rows that legitimately have no asynchronous owner.
    /// Active ownerless rows are never eligible: they must pass startup ownership migration first.
    @discardableResult
    func setLocalPlaybackPositionForOwnerlessTerminalRow(
        ratingKey: String,
        positionMs: Int,
        durationMs: Int?
    ) -> Bool {
        lock.lock()
        guard var row = rows[ratingKey], row.attemptID == nil,
              row.status == .complete || row.status == .unverified,
              var metadata = row.metadata else {
            lock.unlock()
            return false
        }
        let effectiveDuration = durationMs ?? metadata.duration
        metadata.localPlaybackPositionMs = OfflinePlaybackPositionPolicy.standard
            .persistedPositionMs(currentMs: positionMs, durationMs: effectiveDuration)
        row.metadata = metadata
        rows[ratingKey] = row
        let ticket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        return waitForPersistence(through: ticket).result.committed(through: ticket)
    }

    /// #84: persist the server-minted `PlaySessionId` for a transcoded JF/Emby (or Plex optimize)
    /// job so a hard app kill can still tear the encoder down on next launch. Status-change-grade:
    /// persists immediately (not throttled). No-op if the row/metadata is gone.
    func setPlaySessionID(ratingKey: String, _ playSessionID: String) {
        updateMetadata(ratingKey: ratingKey) { $0.playSessionID = playSessionID }
    }

    @discardableResult
    func setPlaySessionID(
        for key: DownloadAttemptKey,
        _ playSessionID: String
    ) -> AttemptMutationResult {
        guard !playSessionID.isEmpty else { return .noChange }
        return updateMetadata(for: key) { $0.playSessionID = playSessionID }
    }

    /// #84: clear the persisted `PlaySessionId` after the encoder has been torn down (the launch
    /// sweep is idempotent — clearing prevents it from firing twice). No-op if the row is gone.
    func clearPlaySessionID(ratingKey: String) {
        updateMetadata(ratingKey: ratingKey) { $0.playSessionID = nil }
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
              !row.legacyResetPending, var metadata = row.metadata else {
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
        let canRecordPath = rows[ratingKey]?.metadata != nil
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
        lock.lock()
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID,
              !row.legacyResetPending, var metadata = row.metadata else {
            lock.unlock()
            return .staleOrMissing
        }
        let url = resumeDataDestinationURL(ratingKey: key.ratingKey)
        do {
            try CredentialArtifactStorage.writeAuthArtifact(data, to: url, fileManager: fileManager)
        } catch {
            lock.unlock()
            return .artifactWriteFailed(errorType: String(reflecting: type(of: error)))
        }
        metadata.resumeDataRelativePath = url.lastPathComponent
        if let displayBytes, displayBytes > 0 {
            metadata.resumeDisplayBytes = max(displayBytes, metadata.resumeDisplayBytes ?? 0)
        }
        metadata.downloadAttemptID = key.attemptID.rawValue
        row.metadata = metadata
        rows[key.ratingKey] = row
        let ticket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let persistence = waitForPersistence(through: ticket)
        return persistence.result.committed(through: persistence.ticket)
            ? .applied : .persistenceFailed(persistence.result)
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
        guard let row = rows[key.ratingKey], row.attemptID == key.attemptID,
              !row.legacyResetPending else { return nil }
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
              !row.legacyResetPending,
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
        guard let row = rows[key.ratingKey], row.attemptID == key.attemptID,
              !row.legacyResetPending else { return nil }
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
        lock.lock()
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID,
              !row.legacyResetPending, var metadata = row.metadata else {
            lock.unlock()
            return .staleOrMissing
        }
        let relative = metadata.resumeDataRelativePath
        if let relative, !relative.isEmpty, Self.isSafeOneLevelRelativePath(relative) {
            try? fileManager.removeItem(at: baseDirectory.appendingPathComponent(relative))
        }
        let hadDisplayBytes = metadata.resumeDisplayBytes != nil
        let changed = relative != nil || (clearDisplayBytes && hadDisplayBytes)
        guard changed else {
            let ticket = enqueueAttemptPersistenceLocked()
            lock.unlock()
            let persistence = waitForPersistence(through: ticket)
            return persistence.result.committed(through: persistence.ticket)
                ? .noChange : .persistenceFailed(persistence.result)
        }
        metadata.resumeDataRelativePath = nil
        if clearDisplayBytes { metadata.resumeDisplayBytes = nil }
        metadata.downloadAttemptID = key.attemptID.rawValue
        row.metadata = metadata
        rows[key.ratingKey] = row
        let ticket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let persistence = waitForPersistence(through: ticket)
        return persistence.result.committed(through: persistence.ticket)
            ? .applied : .persistenceFailed(persistence.result)
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
        guard let row = rows[key.ratingKey], row.attemptID == key.attemptID,
              !row.legacyResetPending else { return nil }
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

    func clearRangeValidator(ratingKey: String) {
        updateMetadata(ratingKey: ratingKey) { $0.rangeValidator = nil }
    }

    @discardableResult
    func clearRangeValidator(for key: DownloadAttemptKey) -> AttemptMutationResult {
        updateMetadata(for: key) { $0.rangeValidator = nil }
    }

    /// The row's current download-attempt token (see `OfflineMetadata.downloadAttemptID`).
    func downloadAttemptID(ratingKey: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return rows[ratingKey]?.attemptID?.rawValue
    }

    func downloadAttemptIdentity(ratingKey: String) -> DownloadAttemptID? {
        lock.lock(); defer { lock.unlock() }
        return rows[ratingKey]?.attemptID
    }

    /// First writer wins: concurrent task-creation paths for one attempt must all end up
    /// stamping the same token.
    func mintDownloadAttemptIDIfMissing(ratingKey: String, _ attemptID: String) {
        guard let typed = DownloadAttemptID(rawValue: attemptID) else { return }
        lock.lock()
        guard var row = rows[ratingKey], row.attemptID == nil else { lock.unlock(); return }
        row.attemptID = typed
        row.decodedTopLevelAttemptIDPresent = true
        row.decodedAttemptIdentityDisagrees = false
        // Retain the nested rollout field until every callback reader has migrated. Top-level is
        // authoritative in v3; this mirror exists only for downgrade/dual-read compatibility.
        if row.metadata?.downloadAttemptID == nil { row.metadata?.downloadAttemptID = typed.rawValue }
        rows[ratingKey] = row
        lock.unlock()
        persist()
    }

    /// Upgrade a pre-v4 index without admitting background callbacks. Existing tokens
    /// are preserved verbatim; rows that need ownership but have no token receive one. The whole
    /// snapshot must commit before the returned keys may be used to cancel legacy OS tasks.
    @discardableResult
    func commitLegacyAttemptOwnershipMigration(
        idFactory: (String) -> DownloadAttemptID = { _ in .generated() }
    ) -> AttemptOwnershipMigrationResult {
        lock.lock()
        let shadowDisagreements = rows.values
            .filter(\.decodedAttemptIdentityDisagrees)
            .map(\.ratingKey)
            .sorted()
        if !shadowDisagreements.isEmpty {
            lock.unlock()
            return .malformedV3Rows(shadowDisagreements)
        }
        if loadedSchemaVersion >= DownloadIndexCoding.currentSchemaVersion {
            // `reconcile` may legitimately demote a legacy ownerless terminal row after its stable
            // file disappears. That produces an ownerless `.failed` v4 row; treating it as generic
            // corruption globally wedges every download forever. Adopt only truly ownerless rows
            // (no top-level or nested token), then run the same fail-safe artifact reset barrier as
            // a pre-v4 partial. Rows carrying ambiguous/mismatched identity still fail closed below.
            var adoptedReset: [DownloadAttemptKey] = []
            var adoptedCleanupOnly: [DownloadAttemptKey] = []
            for ratingKey in rows.keys.sorted() {
                guard var row = rows[ratingKey],
                      Self.requiresAttemptOwnership(row),
                      row.attemptID == nil,
                      !row.decodedTopLevelAttemptIDPresent else { continue }
                let attemptID = idFactory(ratingKey)
                row.attemptID = attemptID
                row.decodedTopLevelAttemptIDPresent = true
                row.metadata?.downloadAttemptID = attemptID.rawValue
                let key = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID)
                if row.status == .complete || row.status == .unverified {
                    adoptedCleanupOnly.append(key)
                } else {
                    row.attemptWorkingRelativePath = Self.attemptStagingRelativePath(
                        for: key, stableRelativePath: row.relativePath)
                    row.legacyResetPending = true
                    adoptedReset.append(key)
                }
                rows[ratingKey] = row
            }
            if !adoptedReset.isEmpty || !adoptedCleanupOnly.isEmpty {
                let plan = LegacyAttemptMigrationPlan(
                    taskCancellationAndReset: adoptedReset,
                    cleanupOnly: adoptedCleanupOnly)
                let ticket = enqueueAttemptPersistenceLocked()
                lock.unlock()
                let persistence = waitForPersistence(through: ticket)
                guard persistence.result.committed(through: persistence.ticket) else {
                    return .failed(plan, persistence.result)
                }
                lock.lock()
                pendingLegacyAttemptResetKeys.formUnion(adoptedReset)
                lock.unlock()
                return .committed(plan)
            }
            let malformed = rows.values
                .filter {
                    guard Self.requiresAttemptOwnership($0) else { return false }
                    guard $0.decodedTopLevelAttemptIDPresent else { return true }
                    guard $0.status != .complete && $0.status != .unverified else { return false }
                    guard let attemptID = $0.attemptID else { return true }
                    return $0.attemptWorkingRelativePath != Self.attemptStagingRelativePath(
                        for: DownloadAttemptKey(ratingKey: $0.ratingKey, attemptID: attemptID),
                        stableRelativePath: $0.relativePath)
                }
                .map(\.ratingKey)
                .sorted()
            let pending = rows.values.compactMap { row -> DownloadAttemptKey? in
                guard row.legacyResetPending, let attemptID = row.attemptID else { return nil }
                return DownloadAttemptKey(ratingKey: row.ratingKey, attemptID: attemptID)
            }.sorted { $0.ratingKey < $1.ratingKey }
            let cleanupOnly = rows.values.compactMap { row -> DownloadAttemptKey? in
                guard (row.status == .complete || row.status == .unverified),
                      Self.hasAsyncCleanupEvidence(row),
                      let attemptID = row.attemptID else { return nil }
                return DownloadAttemptKey(ratingKey: row.ratingKey, attemptID: attemptID)
            }.sorted { $0.ratingKey < $1.ratingKey }
            pendingLegacyAttemptResetKeys.formUnion(pending)
            lock.unlock()
            if !malformed.isEmpty { return .malformedV3Rows(malformed) }
            if !pending.isEmpty || !cleanupOnly.isEmpty {
                return .committed(LegacyAttemptMigrationPlan(
                    taskCancellationAndReset: pending,
                    cleanupOnly: cleanupOnly
                ))
            }
            return .notRequired
        }

        var reset: [DownloadAttemptKey] = []
        var cleanupOnly: [DownloadAttemptKey] = []
        for ratingKey in rows.keys.sorted() {
            guard var row = rows[ratingKey], Self.requiresAttemptOwnership(row) else { continue }
            if row.attemptID == nil { row.attemptID = idFactory(ratingKey) }
            guard let attemptID = row.attemptID else { continue }
            row.decodedTopLevelAttemptIDPresent = true
            // Mirror only during migration for safe rollback/dual-read. Top-level authority lives
            // in `Row.attemptID` and later mutations must compare that typed value.
            if row.metadata?.downloadAttemptID == nil {
                row.metadata?.downloadAttemptID = attemptID.rawValue
            }
            // Schema v4 makes the private media body durable and addressable without trusting a
            // callback-supplied URL. It is written in the same migration barrier that closes
            // admission for every nonterminal schema-v3 partial.
            if row.status != .complete && row.status != .unverified {
                row.attemptWorkingRelativePath = Self.attemptStagingRelativePath(
                    for: DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID),
                    stableRelativePath: row.relativePath)
            }
            rows[ratingKey] = row
            let key = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID)
            if row.status == .complete || row.status == .unverified {
                cleanupOnly.append(key)
            } else {
                row.legacyResetPending = true
                rows[ratingKey] = row
                reset.append(key)
            }
        }
        let plan = LegacyAttemptMigrationPlan(
            taskCancellationAndReset: reset,
            cleanupOnly: cleanupOnly
        )
        lock.unlock()

        // Even an empty plan must commit the v4 envelope. Otherwise a completed-only old library
        // would be reclassified as legacy on every launch.
        let persistence = persist()
        guard persistence.result.committed(through: persistence.ticket) else {
            return .failed(plan, persistence.result)
        }
        lock.lock()
        loadedSchemaVersion = DownloadIndexCoding.currentSchemaVersion
        pendingLegacyAttemptResetKeys.formUnion(reset)
        lock.unlock()
        return .committed(plan)
    }

    /// Complete the approved legacy policy after the coordinator has enumerated and cancelled all
    /// pre-v4 tasks. The reset is attempt-conditional and the index commit happens before any file
    /// is deleted, so a persistence failure cannot destroy the only durable checkpoint.
    @discardableResult
    func resetLegacyAttemptAfterTaskCancellation(
        _ key: DownloadAttemptKey
    ) -> LegacyAttemptResetResult {
        lock.lock()
        guard pendingLegacyAttemptResetKeys.contains(key) else {
            lock.unlock()
            return .notPending
        }
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID else {
            lock.unlock()
            return .staleOrMissing
        }
        var relativeArtifacts = Set(row.legacyResetArtifactRelativePaths ?? [])
        relativeArtifacts.insert(row.relativePath)
        if let relative = row.attemptWorkingRelativePath,
           Self.isAttemptStagingRelativePath(relative) {
            relativeArtifacts.insert(relative)
        }
        // Schema-v3 staging was derived rather than persisted. Reconstruct every recognized
        // media/side-asset staging name while the old owner is still known so none remains
        // artificially "referenced" by this failed row after migration.
        for stablePath in ([row.relativePath] + sideAssetRelativePaths(for: row.metadata))
            where Self.isSafeOneLevelRelativePath(stablePath) {
            relativeArtifacts.insert(Self.attemptStagingRelativePath(
                for: key, stableRelativePath: stablePath))
        }
        if let relative = row.metadata?.resumeDataRelativePath,
           Self.isSafeOneLevelRelativePath(relative) {
            relativeArtifacts.insert(relative)
        }
        for held in row.metadata?.heldRangeSegments ?? []
            where Self.isSafeOneLevelRelativePath(held.relativePath) {
            relativeArtifacts.insert(held.relativePath)
        }
        let artifacts = Set(relativeArtifacts.filter(Self.isSafeOneLevelRelativePath)
            .map { baseDirectory.appendingPathComponent($0) })
        pendingLegacyResetArtifacts[key] = artifacts
        row.bytes = 0
        row.progress = 0
        row.status = .failed
        row.metadata?.resumeDataRelativePath = nil
        row.metadata?.resumeDisplayBytes = nil
        row.metadata?.heldRangeSegments = nil
        row.metadata?.rangeValidator = nil
        row.legacyResetPending = true
        row.legacyResetArtifactRelativePaths = relativeArtifacts.sorted()
        rows[key.ratingKey] = row
        sideAssetHydrationCache.removeValue(forKey: key.ratingKey)
        let ticket = enqueueAttemptPersistenceLocked()
        lock.unlock()

        let persistence = waitForPersistence(through: ticket)
        guard persistence.result.committed(through: persistence.ticket) else {
            return .failed(key, persistence.result)
        }

        var failureCount = 0
        for url in artifacts {
            do { try fileManager.removeItem(at: url) }
            catch where fileManager.fileExists(atPath: url.path) { failureCount += 1 }
            catch {}
        }
        guard failureCount == 0 else {
            return .cleanupFailed(key, cleanupFailureCount: failureCount)
        }

        lock.lock()
        guard var committedRow = rows[key.ratingKey], committedRow.attemptID == key.attemptID else {
            lock.unlock()
            return .staleOrMissing
        }
        committedRow.legacyResetPending = false
        committedRow.legacyResetArtifactRelativePaths = nil
        rows[key.ratingKey] = committedRow
        let cleanupTicket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let cleanupPersistence = waitForPersistence(through: cleanupTicket)
        guard cleanupPersistence.result.committed(through: cleanupPersistence.ticket) else {
            return .failed(key, cleanupPersistence.result)
        }
        lock.lock()
        pendingLegacyResetArtifacts.removeValue(forKey: key)
        pendingLegacyAttemptResetKeys.remove(key)
        lock.unlock()
        return .committed(key, cleanupFailureCount: 0)
    }

    private static func requiresAttemptOwnership(_ row: Row) -> Bool {
        if row.status != .complete && row.status != .unverified { return true }
        return hasAsyncCleanupEvidence(row)
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
        lock.lock()
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID,
              !row.legacyResetPending else {
            lock.unlock()
            return .staleOrMissing
        }
        let backend = row.metadata?.resolvedBackendKind(ratingKey: row.ratingKey)
            ?? DownloadBackendKind(ratingKeyPrefix: row.ratingKey)
        let mode = row.metadata?.resolvedResumeMode(ratingKey: row.ratingKey)
            ?? DownloadResumeMode.resolved(
                backend: backend,
                lane: row.metadata?.resolvedDownloadLane() ?? .original)
        guard mode == .staticByteRange else {
            let bytes = row.bytes
            lock.unlock()
            return .notStatic(bytes: bytes)
        }
        let reconstructedTerminalCheckpoint = row.status == .complete || row.status == .unverified
        let workingRelative: String
        if reconstructedTerminalCheckpoint {
            // The completed-size audit found a truncated published static body. Reconstitute an
            // exact-attempt private checkpoint before the manager demotes the row, while retaining
            // the stable copy until that demotion commits. A crash in between is therefore
            // retryable and never destroys the only bytes.
            workingRelative = Self.attemptStagingRelativePath(
                for: key, stableRelativePath: row.relativePath)
            let stableURL = baseDirectory.appendingPathComponent(row.relativePath)
            let workingURL = baseDirectory.appendingPathComponent(workingRelative)
            if !fileManager.fileExists(atPath: workingURL.path),
               fileManager.fileExists(atPath: stableURL.path) {
                do { try fileManager.copyItem(at: stableURL, to: workingURL) }
                catch {
                    lock.unlock()
                    return .staleOrMissing
                }
            }
            row.attemptWorkingRelativePath = workingRelative
        } else {
            guard let existingWorking = workingRelativePath(for: row, key: key) else {
                lock.unlock()
                return .staleOrMissing
            }
            workingRelative = existingWorking
        }
        // Keep ownership stable through the stat of the exact attempt-private body.
        let durableBytes = fileSize(relativePath: workingRelative) ?? 0
        let expectedBytes = explicitExpectedBytes ?? Self.expectedBytesEstimate(row: row)
        let progress = Self.progressForDurableBytes(durableBytes, expectedBytes: expectedBytes)
        var changed = reconstructedTerminalCheckpoint
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
            let ticket = enqueueAttemptPersistenceLocked()
            lock.unlock()
            let persistence = waitForPersistence(through: ticket)
            return persistence.result.committed(through: persistence.ticket)
                ? .unchanged(bytes: durableBytes)
                : .persistenceFailed(bytes: durableBytes, persistence.result)
        }
        rows[key.ratingKey] = row
        let ticket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let persistence = waitForPersistence(through: ticket)
        return persistence.result.committed(through: persistence.ticket)
            ? .applied(bytes: durableBytes)
            : .persistenceFailed(bytes: durableBytes, persistence.result)
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
              !row.legacyResetPending,
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
              !row.legacyResetPending,
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
        guard var row = rows[ratingKey], var meta = row.metadata else { lock.unlock(); return }
        let oldMeta = meta
        mutate(&meta)
        guard meta != oldMeta else { lock.unlock(); return }
        row.metadata = meta
        rows[ratingKey] = row
        sideAssetHydrationCache.removeValue(forKey: ratingKey)
        lock.unlock()
        persist()
    }

    /// Attempt-conditional metadata mutation. The top-level attempt ID remains authoritative and
    /// its rollback shadow cannot be changed by a metadata closure.
    @discardableResult
    func updateMetadata(
        for key: DownloadAttemptKey,
        mutate: (inout OfflineMetadata) -> Void
    ) -> AttemptMutationResult {
        lock.lock()
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID,
              !row.legacyResetPending, var metadata = row.metadata else {
            lock.unlock()
            return .staleOrMissing
        }
        let previous = metadata
        mutate(&metadata)
        metadata.downloadAttemptID = key.attemptID.rawValue
        guard metadata != previous else {
            let ticket = enqueueAttemptPersistenceLocked()
            lock.unlock()
            let persistence = waitForPersistence(through: ticket)
            return persistence.result.committed(through: persistence.ticket)
                ? .noChange : .persistenceFailed(persistence.result)
        }
        row.metadata = metadata
        rows[key.ratingKey] = row
        sideAssetHydrationCache.removeValue(forKey: key.ratingKey)
        let ticket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let persistence = waitForPersistence(through: ticket)
        return persistence.result.committed(through: persistence.ticket)
            ? .applied : .persistenceFailed(persistence.result)
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
        lock.lock()
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID,
              !row.legacyResetPending else {
            lock.unlock()
            return .staleOrMissing
        }
        let previousStatus = row.status
        let statusChanged = row.status == .queued || row.status == .paused || row.status == .failed
        if statusChanged { row.status = .downloading }
        let changed = row.bytes != bytes || row.progress != progress || statusChanged
        guard changed else {
            lock.unlock()
            return .noChange
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
        guard let ticket else { return .applied }
        let persistence = waitForPersistence(through: ticket)
        return persistence.result.committed(through: persistence.ticket)
            ? .applied : .persistenceFailed(persistence.result)
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
        lock.lock()
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID,
              !row.legacyResetPending else {
            lock.unlock()
            return .staleOrMissing
        }
        let previousStatus = row.status
        guard previousStatus != status else {
            let ticket = enqueueAttemptPersistenceLocked()
            lock.unlock()
            let persistence = waitForPersistence(through: ticket)
            return persistence.result.committed(through: persistence.ticket)
                ? .noChange : .persistenceFailed(persistence.result)
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
        let persistence = waitForPersistence(through: ticket)
        return persistence.result.committed(through: persistence.ticket)
            ? .applied : .persistenceFailed(persistence.result)
    }

    /// Promote a previously byte-complete but probe-inconclusive row once a later validation or
    /// actual local playback proves the file is usable. No-op for already-complete/active/failed rows
    /// so callers can safely invoke this from reconnect and playback-progress paths.
    @discardableResult
    func markCompleteIfUnverified(
        for key: DownloadAttemptKey
    ) -> AttemptUnverifiedPromotionResult {
        lock.lock()
        guard var row = rows[key.ratingKey], row.attemptID == key.attemptID,
              !row.legacyResetPending else {
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

    /// Compatibility for terminal v1/v2 rows that intentionally remained ownerless during the
    /// schema-v3 migration. The status check and nil-owner proof share the Store lock.
    @discardableResult
    func markCompleteIfUnverifiedOwnerlessTerminalRow(ratingKey: String) -> Bool {
        lock.lock()
        guard var row = rows[ratingKey], row.attemptID == nil,
              row.status == .unverified else {
            lock.unlock()
            return false
        }
        row.status = .complete
        rows[ratingKey] = row
        let ticket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        AppDiagnostics.record(.downloads, "downloads.unverified_promoted", fields: [
            "download_id": .identifier(ratingKey),
            "source": .label("local_playback_legacy"),
        ])
        let persistence = waitForPersistence(through: ticket)
        return persistence.result.committed(through: persistence.ticket)
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

    /// Remove a record and delete its backing file.
    func remove(ratingKey: String) {
        lock.lock()
        guard rows[ratingKey]?.pendingValidatedPromotionStatus == nil else {
            lock.unlock()
            return
        }
        let row = rows.removeValue(forKey: ratingKey)
        sideAssetHydrationCache.removeValue(forKey: ratingKey)
        lock.unlock()
        if let row {
            let url = baseDirectory.appendingPathComponent(row.relativePath)
            // The row is already gone from the index, so a failed delete would
            // permanently orphan the file — log it rather than vanish silently.
            do { try fileManager.removeItem(at: url) }
            catch where fileManager.fileExists(atPath: url.path) {
                NSLog("DownloadStore: failed to delete media for %@ (%@); local file orphaned",
                      ratingKey, DiagnosticRedactor.safeErrorSummary(error))
            } catch {} // already absent — nothing to clean up
            // D5/#78: also delete cached side assets so a removed download leaves nothing behind.
            var assets = [row.metadata?.posterRelativePath,
                          row.metadata?.plexBIFRelativePath,
                          row.metadata?.jellyfinTrickPlayPlaylistRelativePath,
                          row.metadata?.resumeDataRelativePath].compactMap { $0 }
            assets.append(contentsOf: row.metadata?.jellyfinTrickPlayTileRelativePaths ?? [])
            assets.append(contentsOf: Array(row.metadata?.chapterImageRelativePaths?.values ?? Dictionary<Int, String>().values))
            assets.append(contentsOf: row.metadata?.offlineTextSubtitles?.map(\.relativePath) ?? [])
            assets.append(contentsOf: row.metadata?.heldRangeSegments?.map(\.relativePath) ?? [])
            for asset in assets where Self.isSafeOneLevelRelativePath(asset) {
                try? fileManager.removeItem(at: baseDirectory.appendingPathComponent(asset))
            }
        }
        persist()
    }

    /// Attempt-conditional removal. A stale finalizer/delete for attempt A cannot remove attempt B
    /// or any of B's files, even when both attempts reuse the same rating key and stable paths.
    @discardableResult
    func remove(for key: DownloadAttemptKey) -> AttemptMutationResult {
        lock.lock()
        guard let existing = rows[key.ratingKey], existing.attemptID == key.attemptID,
              !existing.legacyResetPending,
              existing.pendingValidatedPromotionStatus == nil else {
            lock.unlock()
            return .staleOrMissing
        }
        // Keep ownership and stable-path deletion in one critical section. If the row were removed
        // and the lock released first, attempt B could seed/write the same stable paths before A's
        // delayed cleanup ran, letting A delete B's file despite the initial ID check.
        deleteArtifacts(for: existing)
        _ = rows.removeValue(forKey: key.ratingKey)
        sideAssetHydrationCache.removeValue(forKey: key.ratingKey)
        let ticket = enqueueAttemptPersistenceLocked()
        lock.unlock()
        let persistence = waitForPersistence(through: ticket)
        return persistence.result.committed(through: persistence.ticket)
            ? .applied : .persistenceFailed(persistence.result)
    }

    private func deleteArtifacts(for row: Row) {
        let url = baseDirectory.appendingPathComponent(row.relativePath)
        do { try fileManager.removeItem(at: url) }
        catch where fileManager.fileExists(atPath: url.path) {
            NSLog("DownloadStore: failed to delete media for %@ (%@); local file orphaned",
                  row.ratingKey, DiagnosticRedactor.safeErrorSummary(error))
        } catch {}
        var assets = [row.metadata?.posterRelativePath,
                      row.metadata?.plexBIFRelativePath,
                      row.metadata?.jellyfinTrickPlayPlaylistRelativePath,
                      row.metadata?.resumeDataRelativePath].compactMap { $0 }
        assets.append(contentsOf: row.metadata?.jellyfinTrickPlayTileRelativePaths ?? [])
        assets.append(contentsOf: Array(
            row.metadata?.chapterImageRelativePaths?.values ?? Dictionary<Int, String>().values))
        assets.append(contentsOf: row.metadata?.offlineTextSubtitles?.map(\.relativePath) ?? [])
        assets.append(contentsOf: row.metadata?.heldRangeSegments?.map(\.relativePath) ?? [])
        for asset in assets where Self.isSafeOneLevelRelativePath(asset) {
            try? fileManager.removeItem(at: baseDirectory.appendingPathComponent(asset))
        }
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
        loadedSchemaVersion = result.schemaVersion
        if result.skippedRowCount > 0 {
            NSLog("DownloadStore: skipped %d corrupt offline-index row(s) on load (schemaVersion %d); %d row(s) preserved",
                  result.skippedRowCount, result.schemaVersion, result.rows.count)
        }
        var repairedSubtitleRows = 0
        rows = Dictionary(uniqueKeysWithValues: result.rows.map { row in
            var repaired = row
            if repaired.metadata?.offlineTextSubtitles?.isEmpty ?? true,
               let tracks = cachedSubtitleTracksFromDisk(ratingKey: row.ratingKey),
               !tracks.isEmpty {
                repaired.metadata?.offlineTextSubtitles = tracks
                repairedSubtitleRows += 1
                NSLog("DownloadStore: repaired %d cached offline subtitle track(s) for %@",
                      tracks.count, row.ratingKey)
            }
            return (repaired.ratingKey, repaired)
        })
        // Never let a best-effort cache repair stamp a pre-v4 snapshot as v4 before the startup
        // migration has durably closed admission and marked every nonterminal partial for reset.
        // The repaired values are already in memory and ride along with the migration snapshot.
        if repairedSubtitleRows > 0,
           loadedSchemaVersion >= DownloadIndexCoding.currentSchemaVersion {
            lock.unlock()
            persist()
            lock.lock()
        }
    }

    private func cachedSubtitleTracksFromDisk(ratingKey: String) -> [OfflineTextSubtitleTrack]? {
        let safePrefix = "\(Self.safeFilenameComponent(ratingKey)).sub-"
        guard let urls = try? fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let tracks: [OfflineTextSubtitleTrack] = urls.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix(safePrefix),
                  let ext = name.split(separator: ".").last.map(String.init)?.lowercased(),
                  ["srt", "vtt"].contains(ext),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { return nil }
            let idStart = name.index(name.startIndex, offsetBy: safePrefix.count)
            let idEnd = name.index(name.endIndex, offsetBy: -(".\(ext)".count))
            guard idStart < idEnd,
                  let streamID = Int(name[idStart..<idEnd]) else { return nil }
            return OfflineTextSubtitleTrack(id: streamID,
                                            displayName: "Subtitle \(streamID)",
                                            codec: ext,
                                            relativePath: name)
        }.sorted { $0.id < $1.id }
        return tracks.isEmpty ? nil : tracks
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
        return PersistenceAttempt(
            ticket: ticket,
            result: Self.mapPersistenceResult(result)
        )
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
