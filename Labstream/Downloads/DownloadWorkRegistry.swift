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
        case sourceMetadataRefresh
        case jellyfinTrickPlay
        case chapterImages
    }

    enum Kind: Hashable, Sendable {
        case finalizer
        /// Foreground-only local AVFoundation verification for an already-published
        /// `.unverified` row. Unlike a publishing finalizer, this work may be cancelled when the
        /// scene resigns active without interrupting transfer publication.
        case revalidationFinalizer
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
            case .revalidationFinalizer: return "1-revalidation-finalizer"
            case .sideCache(let kind): return "2-side-cache-\(kind.rawValue)"
            case .requiredCleanup: return "3-required-cleanup"
            }
        }
    }

    /// Cancel only foreground revalidation probes. Publishing finalizers use the distinct
    /// `.finalizer` kind and must continue while the app is inactive so completed transfers can
    /// reach their durable `.unverified` terminal state and release the OS wake handler.
    @discardableResult
    func cancelRevalidationFinalizer(for key: DownloadAttemptKey) -> [Token] {
        guard var entries = entriesByAttempt[key] else { return [] }
        let cancelled = entries.values
            .filter { $0.kind == .revalidationFinalizer }
            .sorted { $0.token.id.uuidString < $1.token.id.uuidString }
        for entry in cancelled {
            entries.removeValue(forKey: entry.token)
            entry.task.cancel()
        }
        if entries.isEmpty {
            entriesByAttempt.removeValue(forKey: key)
        } else {
            entriesByAttempt[key] = entries
        }
        return cancelled.map(\.token)
    }

    enum AttemptCancellationMode: Sendable, Equatable {
        case allCancellable
        /// Terminal refresh releases network/server ownership while allowing the finalizer that
        /// published that terminal row to finish its callback and accounting defers.
        case preservingFinalizer
        /// Retains optional hydration ownership while Pause/Pause All park its coordinator owner.
        /// Resume can then continue the same exact-attempt work without duplicating requests.
        case preservingSideCache
        /// Successful publication releases transfer/server ownership while both the publishing
        /// finalizer and independent side assets finish their exact-attempt work.
        case preservingFinalizerAndSideCache
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

    /// Atomically admit one work item of `kind` for an exact attempt. Finalization uses this
    /// instead of a check-then-start pair: duplicate delegate/recovery callbacks cannot create two
    /// validators for the same attempt, even when both reach the main actor in one run-loop turn.
    @discardableResult
    func startIfAbsent(
        for key: DownloadAttemptKey,
        kind: Kind,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Token? {
        guard entriesByAttempt[key]?.values.contains(where: { $0.kind == kind }) != true else {
            return nil
        }
        return start(for: key, kind: kind, operation: operation)
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
    func cancelCancellableWork(
        for key: DownloadAttemptKey,
        mode: AttemptCancellationMode = .allCancellable
    ) -> [Token] {
        guard var entries = entriesByAttempt[key] else { return [] }
        let cancellable = entries.values
            .filter {
                guard $0.kind.isCancellableWithAttempt else { return false }
                switch (mode, $0.kind) {
                case (.preservingFinalizer, .finalizer),
                     (.preservingFinalizer, .revalidationFinalizer),
                     (.preservingSideCache, .sideCache(_)),
                     (.preservingFinalizerAndSideCache, .finalizer),
                     (.preservingFinalizerAndSideCache, .revalidationFinalizer),
                     (.preservingFinalizerAndSideCache, .sideCache(_)):
                    return false
                default:
                    return true
                }
            }
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
