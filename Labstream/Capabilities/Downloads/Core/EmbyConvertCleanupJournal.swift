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
        do {
            try persistence.atomicWrite(data, fileURL)
        } catch {
            // Atomic replacement can succeed before its injected/filesystem error is observed.
            // Re-read within this journal transaction: the generated UUID is exact add proof.
            if case .loaded(let durable) = readLocked(),
               durable.contains(where: { $0.id == tombstone.id }) {
                return .committed(tombstone)
            }
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
        do {
            try persistence.atomicWrite(data, fileURL)
        } catch {
            // Absence of this exact UUID after a thrown replacement proves removal won.
            if case .loaded(let durable) = readLocked(),
               !durable.contains(where: { $0.id == id }) {
                return .committed(removed: true)
            }
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
