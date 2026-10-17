import Foundation
import PMSKit

/// Standalone durable queue for attempt-scoped server cleanup work. It deliberately has its own
/// lock and file instead of sharing the download index's transaction domain: cleanup must survive
/// row removal, and an unreadable queue must never be mistaken for an empty one.
final class DownloadCleanupIntentJournal: @unchecked Sendable {
    struct Persistence: Sendable {
        let read: @Sendable (URL) throws -> Data?
        let encode: @Sendable ([DurableDownloadCleanupIntent]) throws -> Data
        /// Full durable replace (B18): temp write, full fsync, rename, directory fsync.
        let commit: @Sendable (Data, URL) throws -> Void
        /// Makes an already-visible rename durable before an existing value is relied on.
        let syncDirectory: @Sendable (URL) throws -> Void

        init(
            read: @escaping @Sendable (URL) throws -> Data?,
            encode: @escaping @Sendable ([DurableDownloadCleanupIntent]) throws -> Data,
            commit: @escaping @Sendable (Data, URL) throws -> Void,
            syncDirectory: @escaping @Sendable (URL) throws -> Void = DurableJournalCommit.liveSyncDirectory
        ) {
            self.read = read
            self.encode = encode
            self.commit = commit
            self.syncDirectory = syncDirectory
        }

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
            commit: DurableJournalCommit.liveCommit
        )
    }

    struct Failure: Error, Sendable, Equatable {
        enum Stage: String, Sendable, Equatable {
            case read
            case decode
            case encode
            case commit
        }

        let stage: Stage
        let errorType: String
    }

    enum LoadResult: Sendable, Equatable {
        case loaded([DurableDownloadCleanupIntent])
        case failed(Failure)
    }

    enum AddResult: Sendable, Equatable {
        case committed(DurableDownloadCleanupIntent)
        /// UUIDs are exact queue identities. Reusing one for different authority is corruption-like
        /// input and must never append a second ambiguous value.
        case conflictingID(DurableDownloadCleanupIntent)
        case failed(Failure)
    }

    enum RemoveResult: Sendable, Equatable {
        case committed(removed: Bool)
        case failed(Failure)
    }

    private let lock = NSLock()
    private let fileURL: URL
    private let quarantineDirectory: URL
    private let persistence: Persistence

    init(directory: URL, persistence: Persistence = .live) {
        self.fileURL = directory.appendingPathComponent("download-cleanup-intents.json")
        self.quarantineDirectory = directory
        self.persistence = persistence
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // B18: the authority directory is protected and excluded from backup whether it is new or
        // was created by an older build; each committed file gets the same attributes.
        try? CredentialArtifactStorage.applyProtectionAndBackupExclusion(
            to: directory, protection: CredentialArtifactStorage.authArtifactProtection)
    }

    func load() -> LoadResult {
        lock.lock(); defer { lock.unlock() }
        return readLocked()
    }

    /// Return an existing exact operation or durably append the proposed authority. UUID is the
    /// queue identity, not the operation identity: a retry after an earlier partial success must
    /// reuse the already-durable value rather than append a duplicate operation with a fresh UUID.
    @discardableResult
    func ensure(_ proposed: DurableDownloadCleanupIntent) -> AddResult {
        lock.lock(); defer { lock.unlock() }
        var values: [DurableDownloadCleanupIntent]
        switch readLocked() {
        case .loaded(let loaded): values = loaded
        case .failed(let failure): return .failed(failure)
        }
        if let existing = values.first(where: {
            $0.attemptKey == proposed.attemptKey
                && $0.backend == proposed.backend
                && $0.server == proposed.server
                && $0.operation == proposed.operation
        }) {
            return existingCommittedLocked(existing)
        }
        return appendLocked(proposed, to: &values)
    }

    @discardableResult
    func add(_ intent: DurableDownloadCleanupIntent) -> AddResult {
        lock.lock(); defer { lock.unlock() }
        var values: [DurableDownloadCleanupIntent]
        switch readLocked() {
        case .loaded(let loaded): values = loaded
        case .failed(let failure): return .failed(failure)
        }
        return appendLocked(intent, to: &values)
    }

    /// UUID conflict validation and the append/replace are part of the caller's single locked
    /// transaction. In particular, `ensure` must not unlock between its semantic lookup and this
    /// append or two concurrent retries can both observe absence and persist duplicate authority.
    private func appendLocked(
        _ intent: DurableDownloadCleanupIntent,
        to values: inout [DurableDownloadCleanupIntent]
    ) -> AddResult {
        if let existing = values.first(where: { $0.id == intent.id }) {
            return existing == intent ? existingCommittedLocked(intent) : .conflictingID(existing)
        }
        values.append(intent)
        let data: Data
        do {
            data = try persistence.encode(values)
        } catch {
            return .failed(Self.failure(.encode, error))
        }
        if let error = DurableJournalCommit.commit(data, to: fileURL, using: persistence.commit) {
            return .failed(Self.failure(.commit, error))
        }
        return .committed(intent)
    }

    /// A value already present may be the visible-but-unsynced result of an earlier ambiguous
    /// commit. Sync its directory entry before reporting it as durable authority.
    private func existingCommittedLocked(_ existing: DurableDownloadCleanupIntent) -> AddResult {
        do {
            try persistence.syncDirectory(fileURL)
        } catch {
            return .failed(Self.failure(.commit, error))
        }
        return .committed(existing)
    }

    /// Durably replace the entry with `updated`'s id, attempt and operation (provenance
    /// classification). Returns false when the entry is gone or the commit fails.
    func replace(_ updated: DurableDownloadCleanupIntent) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard case .loaded(var values) = readLocked(),
              let index = values.firstIndex(where: {
                  $0.matchesForClear(id: updated.id, attemptKey: updated.attemptKey,
                                     operation: updated.operation)
              }) else { return false }
        values[index] = updated
        guard let data = try? persistence.encode(values) else { return false }
        return DurableJournalCommit.commit(data, to: fileURL, using: persistence.commit) == nil
    }

    /// Remove only the exact cleanup operation that completed. Matching UUID alone is insufficient:
    /// a stale completion must also prove the same attempt and operation authority.
    @discardableResult
    func remove(
        id: UUID,
        attemptKey: DownloadAttemptKey,
        operation: DurableDownloadCleanupIntent.Operation
    ) -> RemoveResult {
        lock.lock()
        var values: [DurableDownloadCleanupIntent]
        switch readLocked() {
        case .loaded(let loaded): values = loaded
        case .failed(let failure):
            lock.unlock()
            return .failed(failure)
        }
        guard let index = values.firstIndex(where: {
            $0.matchesForClear(id: id, attemptKey: attemptKey, operation: operation)
        }) else {
            lock.unlock()
            return .committed(removed: false)
        }
        values.remove(at: index)
        let data: Data
        do {
            data = try persistence.encode(values)
        } catch {
            lock.unlock()
            return .failed(Self.failure(.encode, error))
        }
        if let error = DurableJournalCommit.commit(data, to: fileURL, using: persistence.commit) {
            lock.unlock()
            return .failed(Self.failure(.commit, error))
        }
        lock.unlock()
        return .committed(removed: true)
    }

    private func readLocked() -> LoadResult {
        let data: Data
        do {
            guard let loaded = try persistence.read(fileURL) else { return .loaded([]) }
            data = loaded
        } catch {
            return .failed(Self.failure(.read, error))
        }
        do {
            let values = try JSONDecoder().decode([DurableDownloadCleanupIntent].self, from: data)
            guard Set(values.map(\.id)).count == values.count else {
                return .failed(Failure(
                    stage: .decode,
                    errorType: String(reflecting: DuplicateIntentID.self)
                ))
            }
            return .loaded(values)
        } catch {
            return repairElementDecodeFailureLocked(data: data, originalError: error)
        }
    }

    /// A forward-incompatible or corrupt element must not permanently block unrelated cleanup
    /// authority. Preserve the exact original bytes in a quarantine file, then rewrite only the
    /// independently decodable, UUID-unambiguous values. Top-level JSON corruption and duplicate
    /// UUIDs remain fail-closed because their boundaries/authority cannot be established safely.
    private func repairElementDecodeFailureLocked(
        data: Data,
        originalError: any Error
    ) -> LoadResult {
        guard let rawValues = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return .failed(Self.failure(.decode, originalError))
        }
        var recovered: [DurableDownloadCleanupIntent] = []
        var rejectedCount = 0
        for rawValue in rawValues {
            guard JSONSerialization.isValidJSONObject(rawValue),
                  let elementData = try? JSONSerialization.data(withJSONObject: rawValue),
                  let value = try? JSONDecoder().decode(
                    DurableDownloadCleanupIntent.self, from: elementData) else {
                rejectedCount += 1
                continue
            }
            recovered.append(value)
        }
        guard rejectedCount > 0 else {
            // The array decoded element-by-element, so the aggregate failure is a duplicate-ID
            // ambiguity (or an invariant introduced by a future decoder). Never guess.
            return .failed(Self.failure(.decode, originalError))
        }
        guard Set(recovered.map(\.id)).count == recovered.count else {
            return .failed(Failure(
                stage: .decode,
                errorType: String(reflecting: DuplicateIntentID.self)
            ))
        }

        // Evidence only: everything this build can decode is already back in the canonical queue,
        // so these files are never import candidates (see `importLegacyQuarantinedPlexIntents`).
        let quarantineURL = quarantineDirectory.appendingPathComponent(
            "\(Self.rejectedPrefix)\(UUID().uuidString).json")
        if let error = DurableJournalCommit.commit(data, to: quarantineURL, using: persistence.commit) {
            return .failed(Self.failure(.commit, error))
        }
        let repairedData: Data
        do {
            repairedData = try persistence.encode(recovered)
        } catch {
            return .failed(Self.failure(.encode, error))
        }
        if let error = DurableJournalCommit.commit(
            repairedData, to: fileURL, using: persistence.commit) {
            return .failed(Self.failure(.commit, error))
        }
        return .loaded(recovered)
    }

    // MARK: - Downgrade compatibility (P2.2)

    /// Builds before P2 quarantined elements they could not decode, rewriting the canonical queue
    /// without them. After a downgrade and re-upgrade those elements include `plexOptimize`
    /// intents that the older build could not run. This build's own repairs write
    /// `rejectedPrefix` files instead, so only the legacy name is an import candidate.
    static let legacyQuarantinePrefix = "download-cleanup-intents-quarantine-"
    static let rejectedPrefix = "download-cleanup-intents-rejected-"
    static let importedPrefix = "download-cleanup-intents-imported-"

    struct LegacyImportOutcome: Sendable, Equatable {
        var importedCount = 0
        /// IDs present in a legacy file whose import receipt is not yet durable. The runner must
        /// not execute them: once one drained, a later import would recreate it.
        var blockedIDs: Set<UUID> = []
        /// A legacy file could not be read or parsed, so its IDs are unknown; every `plexOptimize`
        /// intent waits until it can be processed.
        var blocksAllPlex = false
    }

    func hasLegacyQuarantineFiles(fileManager: FileManager = .default) -> Bool {
        guard let names = try? fileManager.contentsOfDirectory(atPath: quarantineDirectory.path)
        else { return true }
        return names.contains { $0.hasPrefix(Self.legacyQuarantinePrefix) }
    }

    /// Re-import only `plexOptimize` elements from legacy quarantine files, then rename each file
    /// to the imported prefix (the durable receipt). Elements that conflict with an existing ID or
    /// still do not decode stay in the renamed file as evidence. Run before the cleanup runner.
    func importLegacyQuarantinedPlexIntents(fileManager: FileManager = .default) -> LegacyImportOutcome {
        lock.lock(); defer { lock.unlock() }
        var outcome = LegacyImportOutcome()
        guard let names = try? fileManager.contentsOfDirectory(atPath: quarantineDirectory.path)
        else {
            // Unreadable is not empty: a legacy file may be hiding there.
            outcome.blocksAllPlex = true
            return outcome
        }
        for name in names.sorted() where name.hasPrefix(Self.legacyQuarantinePrefix) {
            let source = quarantineDirectory.appendingPathComponent(name)
            guard let data = try? persistence.read(source),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
                outcome.blocksAllPlex = true
                continue
            }
            let candidates: [DurableDownloadCleanupIntent] = raw.compactMap { element in
                guard let object = element as? [String: Any],
                      object["operationType"] as? String == "plexOptimize",
                      let elementData = try? JSONSerialization.data(withJSONObject: object)
                else { return nil }
                return try? JSONDecoder().decode(DurableDownloadCleanupIntent.self, from: elementData)
            }
            let fileIDs = Set(candidates.map(\.id))
            var values: [DurableDownloadCleanupIntent]
            switch readLocked() {
            case .loaded(let loaded): values = loaded
            case .failed:
                outcome.blockedIDs.formUnion(fileIDs)
                continue
            }
            let existingIDs = Set(values.map(\.id))
            let additions = candidates.filter { !existingIDs.contains($0.id) }
            if !additions.isEmpty {
                values.append(contentsOf: additions)
                guard let encoded = try? persistence.encode(values),
                      DurableJournalCommit.commit(encoded, to: fileURL, using: persistence.commit) == nil
                else {
                    outcome.blockedIDs.formUnion(fileIDs)
                    continue
                }
                outcome.importedCount += additions.count
            }
            let receipt = quarantineDirectory.appendingPathComponent(
                Self.importedPrefix + name.dropFirst(Self.legacyQuarantinePrefix.count))
            do {
                try fileManager.moveItem(at: source, to: receipt)
                try persistence.syncDirectory(receipt)
            } catch {
                outcome.blockedIDs.formUnion(fileIDs)
            }
        }
        return outcome
    }

    private static func failure(_ stage: Failure.Stage, _ error: any Error) -> Failure {
        Failure(stage: stage, errorType: String(reflecting: type(of: error)))
    }

    private struct DuplicateIntentID: Error {}
}
