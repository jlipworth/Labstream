import Foundation
import PMSKit

/// Orders the two durability domains used by destructive download deletion. Required server
/// cleanup moves into the independent journal first. If that domain is unavailable, the exact
/// index row is durably marked deletion-pending and remains the recoverable authority; callers may
/// cancel live work but must not remove the row or its files.
enum DownloadCleanupOrdering {
    enum JournalFailure: Sendable, Equatable {
        case conflictingID
        case persistence(DownloadCleanupIntentJournal.Failure)
    }

    enum Result: Sendable, Equatable {
        case ready([DurableDownloadCleanupIntent])
        case deletionPending(DownloadAttemptKey, JournalFailure)
        case indexPersistenceFailed(DownloadAttemptKey, DownloadStore.PersistenceFlushResult)
        case staleOrMissing
    }

    static func prepareForDestructiveDeletion(
        candidates: [DurableDownloadCleanupIntent],
        key: DownloadAttemptKey,
        journal: DownloadCleanupIntentJournal,
        store: DownloadStore
    ) -> Result {
        guard !candidates.isEmpty,
              candidates.allSatisfy({ $0.attemptKey == key }) else {
            return .staleOrMissing
        }
        var durable: [DurableDownloadCleanupIntent] = []
        for candidate in candidates {
            switch journal.ensure(candidate) {
            case .committed(let intent):
                durable.append(intent)
            case .conflictingID:
                return reserveIndexAuthority(
                    key: key, candidates: candidates,
                    failure: .conflictingID, store: store)
            case .failed(let failure):
                return reserveIndexAuthority(
                    key: key, candidates: candidates,
                    failure: .persistence(failure), store: store)
            }
        }
        return .ready(durable)
    }

    private static func reserveIndexAuthority(
        key: DownloadAttemptKey,
        candidates: [DurableDownloadCleanupIntent],
        failure: JournalFailure,
        store: DownloadStore
    ) -> Result {
        switch store.markDeletionPending(for: key, cleanupIntents: candidates) {
        case .applied, .noChange:
            return .deletionPending(key, failure)
        case .staleOrMissing:
            return .staleOrMissing
        case .persistenceFailed(let persistence):
            return .indexPersistenceFailed(key, persistence)
        }
    }
}
