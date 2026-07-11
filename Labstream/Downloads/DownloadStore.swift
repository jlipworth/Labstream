import Foundation
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

    struct StaticRangeRecoveryEvidence: Sendable {
        let ratingKey: String
        let status: DownloadStatus
        let durableBytes: Int
        let resumeManifestRecorded: Bool
        let resumeBlobPresent: Bool
        let resumeBlobBytes: Int
        let heldBodyCount: Int
        let heldBodyBytes: Int
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
            case ratingKey, attemptID, title, relativePath, bytes, progress, status, metadata
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
             bytes: Int, progress: Double, status: DownloadStatus,
             metadata: OfflineMetadata? = nil,
             legacyResetPending: Bool = false,
             legacyResetArtifactRelativePaths: [String]? = nil) {
            self.ratingKey = ratingKey
            self.attemptID = attemptID
            self.title = title
            self.relativePath = relativePath
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
        rows[record.ratingKey] = Row(
            ratingKey: record.ratingKey,
            attemptID: attemptID,
            title: record.title,
            relativePath: rel,
            bytes: record.bytes,
            progress: record.progress,
            status: record.status,
            metadata: metadata,
            legacyResetPending: previous?.legacyResetPending ?? false,
            legacyResetArtifactRelativePaths: previous?.legacyResetArtifactRelativePaths
        )
        sideAssetHydrationCache.removeValue(forKey: record.ratingKey)
        lock.unlock()
        let persistence = persist()
        guard persistence.result.committed(through: persistence.ticket) else {
            return .failed(key, persistence.result)
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
    func setLocalPlaybackPosition(ratingKey: String, positionMs: Int, durationMs: Int?) {
        updateMetadata(ratingKey: ratingKey) { meta in
            let effectiveDuration = durationMs ?? meta.duration
            meta.localPlaybackPositionMs = OfflinePlaybackPositionPolicy.standard
                .persistedPositionMs(currentMs: positionMs, durationMs: effectiveDuration)
        }
    }

    /// #84: persist the server-minted `PlaySessionId` for a transcoded JF/Emby (or Plex optimize)
    /// job so a hard app kill can still tear the encoder down on next launch. Status-change-grade:
    /// persists immediately (not throttled). No-op if the row/metadata is gone.
    func setPlaySessionID(ratingKey: String, _ playSessionID: String) {
        updateMetadata(ratingKey: ratingKey) { $0.playSessionID = playSessionID }
    }

    /// #84: clear the persisted `PlaySessionId` after the encoder has been torn down (the launch
    /// sweep is idempotent — clearing prevents it from firing twice). No-op if the row is gone.
    func clearPlaySessionID(ratingKey: String) {
        updateMetadata(ratingKey: ratingKey) { $0.playSessionID = nil }
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

    /// #95: the persisted resume blob for a row, if present on disk. `nil` when the row has no
    /// recorded resume path or the file is gone.
    func resumeData(ratingKey: String) -> Data? {
        lock.lock()
        let relative = rows[ratingKey]?.metadata?.resumeDataRelativePath
        lock.unlock()
        guard let relative, !relative.isEmpty else { return nil }
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

    /// #169: the HTTP validator (`ETag`/`Last-Modified`) for a static byte-range download, captured
    /// from the first successful range body and sent as `If-Range` on later requests so a server-side resource change is
    /// detected (200 full-replace) instead of silently corrupting the partial.
    func rangeValidator(ratingKey: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return rows[ratingKey]?.metadata?.rangeValidator
    }

    func setRangeValidator(ratingKey: String, _ validator: String) {
        updateMetadata(ratingKey: ratingKey) { $0.rangeValidator = validator }
    }

    func clearRangeValidator(ratingKey: String) {
        updateMetadata(ratingKey: ratingKey) { $0.rangeValidator = nil }
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

    /// Upgrade a v1/v2 index to v3 without admitting background callbacks. Existing nested tokens
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
            let malformed = rows.values
                .filter {
                    Self.requiresAttemptOwnership($0) && !$0.decodedTopLevelAttemptIDPresent
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
            // Mirror only during migration for safe rollback/dual-read. All new v3 authority lives
            // in `Row.attemptID` and later mutations must compare that typed value.
            if row.metadata?.downloadAttemptID == nil {
                row.metadata?.downloadAttemptID = attemptID.rawValue
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

        // Even an empty plan must commit the v3 envelope. Otherwise a completed-only v2 library
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
    /// pre-v3 tasks. The reset is attempt-conditional and the index commit happens before any file
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
        lock.unlock()

        let persistence = persist()
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
        lock.unlock()
        let cleanupPersistence = persist()
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
                  row.status != .complete, row.status != .unverified else { return nil }
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
                durableBytes: fileSize(relativePath: row.relativePath) ?? 0,
                resumeManifestRecorded: resumeRelative?.isEmpty == false,
                resumeBlobPresent: resumeURL.map { fileManager.fileExists(atPath: $0.path) } ?? false,
                resumeBlobBytes: resumeBytes,
                heldBodyCount: held.count,
                heldBodyBytes: held.reduce(0) { $0 + max(0, $1.length) }
            )
        }
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

    /// Promote a previously byte-complete but probe-inconclusive row once a later validation or
    /// actual local playback proves the file is usable. No-op for already-complete/active/failed rows
    /// so callers can safely invoke this from reconnect and playback-progress paths.
    @discardableResult
    func markCompleteIfUnverified(ratingKey: String) -> Bool {
        lock.lock()
        guard var row = rows[ratingKey], row.status == .unverified else {
            lock.unlock()
            return false
        }
        row.status = .complete
        rows[ratingKey] = row
        lock.unlock()
        AppDiagnostics.record(.downloads, "downloads.unverified_promoted", fields: [
            "download_id": .identifier(ratingKey),
            "source": .label("local_playback"),
        ])
        persist()
        return true
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
            let fileURL = baseDirectory.appendingPathComponent(row.relativePath)
            let partialBytes = fileSize(at: fileURL) ?? 0
            let fileExists = partialBytes > 0 || fileManager.fileExists(atPath: fileURL.path)
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
                try? fileManager.removeItem(
                    at: baseDirectory.appendingPathComponent(row.relativePath))
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
        if repairedSubtitleRows > 0 {
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
        nextPersistenceRevision += 1
        let revision = nextPersistenceRevision
        let snapshot = Array(rows.values)
        lock.unlock()
        indexWriter.submit(revision: revision, snapshot: snapshot)
        let result = indexWriter.waitSynchronouslyForOutcome(through: revision)
        return PersistenceAttempt(
            ticket: PersistenceTicket(revision: revision),
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
