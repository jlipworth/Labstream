import Foundation

/// Pure retry-routing helpers for persisted offline download rows.
public enum DownloadRetryPolicy {
    /// A Plex optimize row is resumable as server-prep work only before it has handed off to the
    /// rendered static Part. Once the row's persisted resume mode becomes `.staticByteRange`, the
    /// same `optimizeTargetName` is retained for display/retry metadata, but relaunch must continue
    /// the file transfer rather than reattaching a Plex prep poller.
    public static func isPlexServerPrepResumeCandidate(_ record: DownloadRecord) -> Bool {
        guard record.status == .queued,
              record.bytes == 0,
              record.progress == 0,
              let metadata = record.metadata,
              metadata.resolvedBackendKind(ratingKey: record.ratingKey) == .plex,
              metadata.resolvedResumeMode(ratingKey: record.ratingKey) == .serverPrepThenStatic,
              metadata.optimizeTargetName?.isEmpty == false else {
            return false
        }
        return true
    }

    /// A paused static-byte-range row can resume from an app-managed partial file even when no
    /// URLSession resume blob exists. Promote it out of `.paused` before backend-specific async
    /// retry guards run; otherwise those guards can treat the row as user-paused and no-op.
    public static func shouldPromotePausedStaticPartial(_ record: DownloadRecord,
                                                        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
                                                        fileSize: (URL) -> Int? = Self.defaultFileSize) -> Bool {
        record.status == .paused
            && hasStaticPartialCheckpoint(record, fileExists: fileExists, fileSize: fileSize)
    }

    /// A queued/downloading static-byte-range partial with no live task is not real active work: it
    /// is the residue left when a resume attempt was interrupted before URLSession was re-acquired.
    /// Normalize it back to paused/retryable (or auto-restart it when queue policy allows) so the UI
    /// does not show Pause/active work for a row with no URLSession task.
    public static func shouldDemoteStaleQueuedStaticPartial(_ record: DownloadRecord,
                                                           isActive: Bool,
                                                           hasPendingResumeIntent: Bool = false,
                                                           fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
                                                           fileSize: (URL) -> Int? = Self.defaultFileSize) -> Bool {
        (record.status == .queued || record.status == .downloading)
            && !isActive
            && !hasPendingResumeIntent
            && hasStaticPartialCheckpoint(record, fileExists: fileExists, fileSize: fileSize)
    }

    private static func hasStaticPartialCheckpoint(_ record: DownloadRecord,
                                                   fileExists: (URL) -> Bool,
                                                   fileSize: (URL) -> Int?) -> Bool {
        guard record.metadata?.resolvedResumeMode(ratingKey: record.ratingKey) == .staticByteRange else {
            return false
        }
        if let durableBytes = fileSize(record.localURL) {
            return durableBytes > 0
        }
        // Compatibility fallback for tests/callers that can only answer existence. Production callers
        // use `defaultFileSize`, so optimistic row bytes from an in-flight URLSession temp chunk are
        // not treated as a durable checkpoint when the partial file is absent or empty.
        return record.bytes > 0
            && record.progress < 0.999
            && fileExists(record.localURL)
    }

    @usableFromInline
    static func defaultFileSize(_ url: URL) -> Int? {
        guard let raw = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) else {
            return nil
        }
        if let number = raw as? NSNumber {
            return number.intValue
        }
        if let int = raw as? Int {
            return int
        }
        if let int64 = raw as? Int64 {
            return Int(int64)
        }
        return nil
    }
}
