import Foundation
import PMSKit

/// Process-local exclusion, shared by store reservations and actual session/side-cache writers.
/// Acquire before entering a physical I/O section, never while holding a session/range lock.
/// Reserve ALL source/destination paths atomically. Revalidate owner/source/file identity after
/// acquisition and immediately before the syscall. No callback or store lock spans the syscall.
/// A timed-out persistence waiter MUST NOT release this lease. Only physical completion releases
/// it; expiry never permits a successor append. Duplicate/stale release is harmless.
struct DownloadPathLease: Sendable, Equatable {
    enum Purpose: Sendable { case append, sideCacheWrite, checkpointHandoff, reconcile, artifact }
    let id: UUID
    let key: DownloadAttemptKey
    let relativePaths: Set<String>
    let purpose: Purpose
}

enum DownloadPathLeaseResult: Sendable, Equatable {
    case acquired(DownloadPathLease)
    case staleOrMissing
    case invalidPath
    case busy
    case timedOut
}
