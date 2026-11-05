import Foundation

/// Pure deletion decisions for download rows (downloads overhaul P2).
///
/// Deleting a row is an app-side operation (URLSession cancellation, file removal, in-flight
/// release). Server work the row still owns is not cancelled here: delete journals a cleanup
/// intent first and the cleanup runner executes it once the row's removal has committed.
public enum DownloadDeletePolicy {
    /// The Plex optimize queue title a deleted row still owes cleanup for, if any.
    ///
    /// Owed only while the row is in SERVER PREP — the optimize job was triggered but no rendered
    /// Part has been handed off (`resumeMode == .serverPrepThenStatic`; the handoff rewrites it to
    /// `.staticByteRange`). After the handoff the queue item IS the rendered version and is kept.
    /// D2: queued, preparing, paused and failed prep rows all owe it. The runner still classifies
    /// the server's queue item and never deletes a completed render.
    public static func plexOptimizeCleanupQueueTitle(for record: DownloadRecord?) -> String? {
        guard let record,
              let metadata = record.metadata,
              metadata.resolvedBackendKind(ratingKey: record.ratingKey) == .plex,
              metadata.resolvedResumeMode(ratingKey: record.ratingKey) == .serverPrepThenStatic,
              [.queued, .preparing, .paused, .failed].contains(record.status),
              let queueTitle = metadata.optimizeQueueTitle, !queueTitle.isEmpty else {
            return nil
        }
        return queueTitle
    }

    /// Whether deleting this row cancels server-side preparation, so the confirmation can say so
    /// (D2): a Plex optimize item or an Emby Convert job that has not yet been handed off.
    public static func deletionCancelsServerPrep(_ record: DownloadRecord?) -> Bool {
        guard let record, let metadata = record.metadata,
              metadata.resolvedResumeMode(ratingKey: record.ratingKey) == .serverPrepThenStatic,
              [.queued, .preparing, .paused, .failed].contains(record.status) else { return false }
        switch metadata.resolvedBackendKind(ratingKey: record.ratingKey) {
        case .plex:
            return plexOptimizeCleanupQueueTitle(for: record) != nil
        case .emby:
            return metadata.embyConvertJobID != nil || metadata.hasEmbyConvertCrashWindowIdentity
        case .jellyfin:
            return false
        }
    }
}
