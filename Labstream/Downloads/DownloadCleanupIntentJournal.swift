import Foundation
import PMSKit

/// Standalone durable queue for attempt-scoped server cleanup work. It deliberately has its own
/// lock and file instead of sharing the download index's transaction domain: cleanup must survive
/// row removal, and an unreadable queue must never be mistaken for an empty one.
final class DownloadCleanupIntentJournal: @unchecked Sendable {
    struct Persistence: Sendable {
        let read: @Sendable (URL) throws -> Data?
        let encode: @Sendable ([DurableDownloadCleanupIntent]) throws -> Data
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
            return .committed(existing)
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
            return existing == intent ? .committed(intent) : .conflictingID(existing)
        }
        values.append(intent)
        let data: Data
        do {
            data = try persistence.encode(values)
        } catch {
            return .failed(Self.failure(.encode, error))
        }
        do {
            try persistence.atomicWrite(data, fileURL)
        } catch {
            // Atomic replacement may have succeeded before throwing. Only the exact full value is
            // proof that this add committed; UUID presence alone could be a conflicting authority.
            switch readLocked() {
            case .loaded(let durable) where durable.contains(intent):
                return .committed(intent)
            case .loaded(let durable):
                if let conflict = durable.first(where: { $0.id == intent.id }) {
                    return .conflictingID(conflict)
                }
            case .failed:
                break
            }
            return .failed(Self.failure(.commit, error))
        }
        return .committed(intent)
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
        do {
            try persistence.atomicWrite(data, fileURL)
        } catch {
            // Absence of the exact triple after a thrown replace proves this removal committed.
            if case .loaded(let durable) = readLocked(),
               !durable.contains(where: {
                   $0.matchesForClear(id: id, attemptKey: attemptKey, operation: operation)
               }) {
                lock.unlock()
                return .committed(removed: true)
            }
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

        let quarantineURL = quarantineDirectory.appendingPathComponent(
            "download-cleanup-intents-quarantine-\(UUID().uuidString).json")
        do {
            try persistence.atomicWrite(data, quarantineURL)
        } catch {
            return .failed(Self.failure(.commit, error))
        }
        let repairedData: Data
        do {
            repairedData = try persistence.encode(recovered)
        } catch {
            return .failed(Self.failure(.encode, error))
        }
        do {
            try persistence.atomicWrite(repairedData, fileURL)
        } catch {
            // The canonical replace may have won before throwing. Exact recovered equality proves
            // repair committed, just as add/remove prove their postconditions after ambiguity.
            if let durableData = try? persistence.read(fileURL),
               let durable = try? JSONDecoder().decode(
                    [DurableDownloadCleanupIntent].self, from: durableData),
               durable == recovered {
                return .loaded(recovered)
            }
            return .failed(Self.failure(.commit, error))
        }
        return .loaded(recovered)
    }

    private static func failure(_ stage: Failure.Stage, _ error: any Error) -> Failure {
        Failure(stage: stage, errorType: String(reflecting: type(of: error)))
    }

    private struct DuplicateIntentID: Error {}
}
