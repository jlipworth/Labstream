import Foundation

/// Pure retry-routing helpers for persisted offline download rows.
public enum DownloadRetryPolicy {
    /// A paused static-byte-range row can resume from an app-managed partial file even when no
    /// URLSession resume blob exists. Promote it out of `.paused` before backend-specific async
    /// retry guards run; otherwise those guards can treat the row as user-paused and no-op.
    public static func shouldPromotePausedStaticPartial(_ record: DownloadRecord,
                                                        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> Bool {
        record.status == .paused
            && hasStaticPartialCheckpoint(record, fileExists: fileExists)
    }

    /// A queued static-byte-range partial with no live task is not real active work: it is the
    /// residue left when a resume attempt was interrupted before URLSession was re-acquired.
    /// Normalize it back to paused/retryable so the UI offers Resume instead of Pause and the
    /// duplicate-start guard does not permanently strand the row as "queued".
    public static func shouldDemoteStaleQueuedStaticPartial(_ record: DownloadRecord,
                                                           isActive: Bool,
                                                           fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> Bool {
        record.status == .queued
            && !isActive
            && hasStaticPartialCheckpoint(record, fileExists: fileExists)
    }

    private static func hasStaticPartialCheckpoint(_ record: DownloadRecord,
                                                   fileExists: (URL) -> Bool) -> Bool {
        record.metadata?.resolvedResumeMode(ratingKey: record.ratingKey) == .staticByteRange
            && record.bytes > 0
            && record.progress < 0.999
            && fileExists(record.localURL)
    }
}
