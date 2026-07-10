import Foundation

/// Pure deletion decisions for download rows.
///
/// Deleting a row always remains an app-side operation (URLSession cancellation, file removal,
/// in-flight release, diagnostics). This policy captures the backend-specific delete-time
/// nuances: an Emby convert row with a live Sync job may need a best-effort server-side job
/// cancel, and a Plex optimize row still in server prep may need its type-42 background queue
/// item removed — both before the local row disappears and the identifiers are lost.
public enum DownloadDeletePolicy {
    public enum EmbyConvertCancelDecision: Equatable, Sendable {
        case none
        case cancel(jobID: Int)
        case skip(jobID: Int, reason: String)
    }

    public static let embySessionUnavailableOrMismatchReason = "emby_session_mismatch_or_unavailable"

    /// `.preparing` is the normal in-prep shape. `.failed` is included too: a row can fail
    /// terminally on the app side (e.g. a terminal 401/403 poll status) while the server-side
    /// Convert job is still Converting — its persisted `embyConvertJobID` is the only remaining
    /// handle, and the server's own job-state check makes a DELETE of an already-finished job a
    /// harmless no-op.
    public static func embyConvertCancelDecision(for record: DownloadRecord?,
                                                 embySessionMatchesPersistedServer: Bool) -> EmbyConvertCancelDecision {
        guard let record,
              record.status == .preparing || record.status == .failed,
              let jobID = record.metadata?.embyConvertJobID else {
            return .none
        }
        return embySessionMatchesPersistedServer
            ? .cancel(jobID: jobID)
            : .skip(jobID: jobID, reason: embySessionUnavailableOrMismatchReason)
    }

    // MARK: - Plex optimize

    public enum PlexOptimizeCancelDecision: Equatable, Sendable {
        case none
        case cancel(queueTitle: String)
        case skip(queueTitle: String, reason: String)
    }

    public static let plexSessionUnavailableOrMismatchReason = "plex_session_mismatch_or_unavailable"

    /// Delete-time decision for a Plex optimize row: should the app try to remove this row's
    /// server-side optimize job (its type-42 background-processing item)?
    ///
    /// Cancel only while the row is still in SERVER PREP — the optimize job was triggered but no
    /// rendered Part has been handed off yet (`resumeMode == .serverPrepThenStatic`; the handoff
    /// in `startOptimizedPartDownload` rewrites it to `.staticByteRange`). Once handed off, the
    /// server job is complete and its type-42 item IS the rendered version — deleting it would
    /// destroy a server render other rows/relaunches may reuse, so the decision is `.none`.
    /// `.failed` prep rows are included: their queue item may still be pending/converting and the
    /// row's deletion loses the queue-title handle forever. `.paused` is deliberately excluded
    /// from active statuses (pause is an intentional keep), and the caller must still apply the
    /// completed-state check server-side (`BackgroundProcessingItems.cancellableItemID`) before
    /// deleting anything.
    public static func plexOptimizeCancelDecision(for record: DownloadRecord?,
                                                  plexSessionMatchesPersistedServer: Bool) -> PlexOptimizeCancelDecision {
        guard let record,
              let metadata = record.metadata,
              metadata.resolvedBackendKind(ratingKey: record.ratingKey) == .plex,
              metadata.resolvedResumeMode(ratingKey: record.ratingKey) == .serverPrepThenStatic,
              record.status == .queued || record.status == .preparing || record.status == .failed,
              let queueTitle = metadata.optimizeQueueTitle, !queueTitle.isEmpty else {
            return .none
        }
        return plexSessionMatchesPersistedServer
            ? .cancel(queueTitle: queueTitle)
            : .skip(queueTitle: queueTitle, reason: plexSessionUnavailableOrMismatchReason)
    }
}
