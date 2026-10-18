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

    /// Journal syscalls run on a worker. Expiry releases only this waiter; index authority
    /// remains fenced until a later retry proves the journal and exact row deletion durable.
    static func prepareForDestructiveDeletionAsync(
        candidates: [DurableDownloadCleanupIntent], key: DownloadAttemptKey,
        journal: DownloadCleanupIntentJournal, store: DownloadStore,
        deadline: DownloadStoreDeadline,
        reservation submittedReservation: DownloadStore.AttemptMutationSubmission? = nil
    ) async -> Result {
        guard !candidates.isEmpty, candidates.allSatisfy({ $0.attemptKey == key }) else {
            return .staleOrMissing
        }
        let reservation = submittedReservation ?? store.submitDeletionPending(for: key, cleanupIntents: candidates)
        guard case .accepted = reservation else { return .staleOrMissing }
        let journalWork = DownloadStoreWork<Result> {
            var durable: [DurableDownloadCleanupIntent] = []
            for candidate in candidates {
                switch journal.ensure(candidate) {
                case .committed(let intent): durable.append(intent)
                case .conflictingID: return .deletionPending(key, .conflictingID)
                case .failed(let failure): return .deletionPending(key, .persistence(failure))
                }
            }
            return .ready(durable)
        }
        let proof = await store.resolve(reservation, deadline: deadline)
        guard store.isDeletionPending(for: key) else { return .staleOrMissing }
        switch proof {
        case .applied, .noChange: break
        case .staleOrMissing: return .staleOrMissing
        case .persistenceFailed(let failure): return .indexPersistenceFailed(key, failure)
        }
        let result = await journalWork.resolve(deadline: deadline, timedOut: {
            .indexPersistenceFailed(key, .timedOut(
                targetRevision: store.currentPersistenceTicket().revision, committedRevision: 0))
        })
        guard store.isDeletionPending(for: key) else { return .staleOrMissing }
        return result
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
