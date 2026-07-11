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
    private let persistence: Persistence

    init(directory: URL, persistence: Persistence = .live) {
        self.fileURL = directory.appendingPathComponent("download-cleanup-intents.json")
        self.persistence = persistence
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func load() -> LoadResult {
        lock.lock(); defer { lock.unlock() }
        return readLocked()
    }

    @discardableResult
    func add(_ intent: DurableDownloadCleanupIntent) -> AddResult {
        lock.lock()
        var values: [DurableDownloadCleanupIntent]
        switch readLocked() {
        case .loaded(let loaded): values = loaded
        case .failed(let failure):
            lock.unlock()
            return .failed(failure)
        }
        if let existing = values.first(where: { $0.id == intent.id }) {
            lock.unlock()
            return existing == intent ? .committed(intent) : .conflictingID(existing)
        }
        values.append(intent)
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
            // Atomic replacement may have succeeded before throwing. Only the exact full value is
            // proof that this add committed; UUID presence alone could be a conflicting authority.
            switch readLocked() {
            case .loaded(let durable) where durable.contains(intent):
                lock.unlock()
                return .committed(intent)
            case .loaded(let durable):
                if let conflict = durable.first(where: { $0.id == intent.id }) {
                    lock.unlock()
                    return .conflictingID(conflict)
                }
            case .failed:
                break
            }
            lock.unlock()
            return .failed(Self.failure(.commit, error))
        }
        lock.unlock()
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
            return .failed(Self.failure(.decode, error))
        }
    }

    private static func failure(_ stage: Failure.Stage, _ error: any Error) -> Failure {
        Failure(stage: stage, errorType: String(reflecting: type(of: error)))
    }

    private struct DuplicateIntentID: Error {}
}
