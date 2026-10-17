import Foundation
import PMSKit

/// Persistence owner for the compatibility Emby Convert cleanup queue.
///
/// Its private lock serializes each read-modify-write transaction without holding the broader
/// `DownloadStore` index lock across file I/O. The file remains in the sibling cleanup-authority
/// directory so destructive replacement of the versioned media root cannot erase it.
final class EmbyConvertCleanupJournal: @unchecked Sendable {
    struct Tombstone: Codable, Sendable, Equatable, Identifiable {
        let id: UUID
        let ratingKey: String
        let metadata: OfflineMetadata
    }

    struct Persistence: Sendable {
        let read: @Sendable (URL) throws -> Data?
        let encode: @Sendable ([Tombstone]) throws -> Data
        /// Full durable replace (B18): temp write, full fsync, rename, directory fsync.
        let commit: @Sendable (Data, URL) throws -> Void
        let syncDirectory: @Sendable (URL) throws -> Void

        init(
            read: @escaping @Sendable (URL) throws -> Data?,
            encode: @escaping @Sendable ([Tombstone]) throws -> Data,
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
        case loaded([Tombstone])
        case failed(Failure)
    }

    enum AddResult: Sendable, Equatable {
        case committed(Tombstone)
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
        self.fileURL = directory.appendingPathComponent("emby-convert-cleanup.json")
        self.persistence = persistence
    }

    func load() -> LoadResult {
        lock.lock(); defer { lock.unlock() }
        return readLocked()
    }

    @discardableResult
    func add(_ tombstone: Tombstone) -> AddResult {
        lock.lock(); defer { lock.unlock() }
        var values: [Tombstone]
        switch readLocked() {
        case .loaded(let loaded): values = loaded
        case .failed(let failure): return .failed(failure)
        }
        guard !values.contains(where: { $0.id == tombstone.id }) else {
            // Possibly visible from an earlier ambiguous commit; make it durable before relying on it.
            do {
                try persistence.syncDirectory(fileURL)
            } catch {
                return .failed(Self.failure(.commit, error))
            }
            return .committed(tombstone)
        }
        let expectedIDs = EmbyConvertRecoveryPolicy.appendingCleanupTombstoneID(
            tombstone.id, to: values.map(\.id))
        values.append(tombstone)
        assert(values.map(\.id) == expectedIDs)
        let data: Data
        do {
            data = try persistence.encode(values)
        } catch {
            return .failed(Self.failure(.encode, error))
        }
        if let error = DurableJournalCommit.commit(data, to: fileURL, using: persistence.commit) {
            return .failed(Self.failure(.commit, error))
        }
        return .committed(tombstone)
    }

    @discardableResult
    func remove(id: UUID) -> RemoveResult {
        lock.lock(); defer { lock.unlock() }
        var values: [Tombstone]
        switch readLocked() {
        case .loaded(let loaded): values = loaded
        case .failed(let failure): return .failed(failure)
        }
        let oldCount = values.count
        values.removeAll { $0.id == id }
        guard values.count != oldCount else { return .committed(removed: false) }
        let data: Data
        do {
            data = try persistence.encode(values)
        } catch {
            return .failed(Self.failure(.encode, error))
        }
        if let error = DurableJournalCommit.commit(data, to: fileURL, using: persistence.commit) {
            return .failed(Self.failure(.commit, error))
        }
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
            return .loaded(try JSONDecoder().decode([Tombstone].self, from: data))
        } catch {
            return .failed(Self.failure(.decode, error))
        }
    }

    private static func failure(_ stage: Failure.Stage, _ error: any Error) -> Failure {
        Failure(stage: stage, errorType: String(reflecting: type(of: error)))
    }
}
