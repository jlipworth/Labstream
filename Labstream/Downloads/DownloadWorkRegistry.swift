import Foundation
import PMSKit

/// Main-actor ownership for asynchronous tails that outlive a download entry point. Cancellation
/// is attempt-scoped: deleting/retrying A never reaches B, and mandatory server cleanup is retained
/// until its own exact task completes.
@MainActor
final class DownloadWorkRegistry {
    struct Token: Hashable, Sendable, Identifiable {
        let id: UUID

        init(id: UUID = UUID()) { self.id = id }
    }

    enum SideCacheKind: String, CaseIterable, Hashable, Sendable {
        case poster
        case textSubtitles
        case plexBIF
        case jellyfinTrickPlay
        case chapterImages
    }

    enum Kind: Hashable, Sendable {
        case finalizer
        case sideCache(SideCacheKind)
        /// Encoder DELETE and other tombstone/journal-backed cleanup must survive ordinary row
        /// cancellation. Only exact task completion removes this work from the registry.
        case requiredCleanup

        var isCancellableWithAttempt: Bool {
            self != .requiredCleanup
        }

        fileprivate var sortKey: String {
            switch self {
            case .finalizer: return "0-finalizer"
            case .sideCache(let kind): return "1-side-cache-\(kind.rawValue)"
            case .requiredCleanup: return "2-required-cleanup"
            }
        }
    }

    struct EntrySnapshot: Equatable, Sendable {
        let token: Token
        let kind: Kind
        let isCancellableWithAttempt: Bool
    }

    struct AttemptSnapshot: Equatable, Sendable {
        let key: DownloadAttemptKey
        let entries: [EntrySnapshot]
    }

    struct Snapshot: Equatable, Sendable {
        let attempts: [AttemptSnapshot]

        var totalCount: Int { attempts.reduce(0) { $0 + $1.entries.count } }
        var cancellableCount: Int {
            attempts.reduce(0) { count, attempt in
                count + attempt.entries.count(where: \.isCancellableWithAttempt)
            }
        }
        var requiredCleanupCount: Int { totalCount - cancellableCount }
    }

    private struct Entry {
        let token: Token
        let kind: Kind
        let task: Task<Void, Never>
    }

    private var entriesByAttempt: [DownloadAttemptKey: [Token: Entry]] = [:]

    /// Register an already-created task. Its owner must call `complete` with the returned token;
    /// completion of another token/kind cannot remove this entry.
    @discardableResult
    func register(
        _ task: Task<Void, Never>,
        for key: DownloadAttemptKey,
        kind: Kind
    ) -> Token {
        let token = Token()
        entriesByAttempt[key, default: [:]][token] = Entry(
            token: token, kind: kind, task: task)
        return token
    }

    /// Create and register work whose natural completion automatically compare-removes its exact
    /// token. The task is installed before the inherited-main-actor task can run.
    @discardableResult
    func start(
        for key: DownloadAttemptKey,
        kind: Kind,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Token {
        let token = Token()
        let task = Task { [weak self] in
            await operation()
            self?.complete(key: key, token: token)
        }
        entriesByAttempt[key, default: [:]][token] = Entry(
            token: token, kind: kind, task: task)
        return token
    }

    /// Compare-remove exactly one task. A delayed completion from an old token is a no-op.
    @discardableResult
    func complete(key: DownloadAttemptKey, token: Token) -> Bool {
        guard entriesByAttempt[key]?.removeValue(forKey: token) != nil else { return false }
        if entriesByAttempt[key]?.isEmpty == true { entriesByAttempt.removeValue(forKey: key) }
        return true
    }

    /// Cancel and unregister finalizer/side-cache work for one exact attempt. Required cleanup is
    /// deliberately retained and not cancelled; it removes itself only after confirmed completion.
    @discardableResult
    func cancelCancellableWork(for key: DownloadAttemptKey) -> [Token] {
        guard var entries = entriesByAttempt[key] else { return [] }
        let cancellable = entries.values
            .filter { $0.kind.isCancellableWithAttempt }
            .sorted { $0.token.id.uuidString < $1.token.id.uuidString }
        for entry in cancellable {
            entries.removeValue(forKey: entry.token)
            entry.task.cancel()
        }
        if entries.isEmpty {
            entriesByAttempt.removeValue(forKey: key)
        } else {
            entriesByAttempt[key] = entries
        }
        return cancellable.map(\.token)
    }

    /// Stable ordering makes diagnostics and race tests independent of dictionary iteration order.
    func snapshot() -> Snapshot {
        let attempts = entriesByAttempt.map { key, entries in
            AttemptSnapshot(
                key: key,
                entries: entries.values.map { entry in
                    EntrySnapshot(
                        token: entry.token,
                        kind: entry.kind,
                        isCancellableWithAttempt: entry.kind.isCancellableWithAttempt)
                }.sorted {
                    if $0.kind.sortKey != $1.kind.sortKey {
                        return $0.kind.sortKey < $1.kind.sortKey
                    }
                    return $0.token.id.uuidString < $1.token.id.uuidString
                })
        }.sorted {
            if $0.key.ratingKey != $1.key.ratingKey {
                return $0.key.ratingKey < $1.key.ratingKey
            }
            return $0.key.attemptID.rawValue < $1.key.attemptID.rawValue
        }
        return Snapshot(attempts: attempts)
    }
}
