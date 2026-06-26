import Foundation

/// Pure retry-routing helpers for persisted offline download rows.
public enum DownloadRetryPolicy {
    /// A paused static-byte-range row can resume from an app-managed partial file even when no
    /// URLSession resume blob exists. Promote it out of `.paused` before backend-specific async
    /// retry guards run; otherwise those guards can treat the row as user-paused and no-op.
    public static func shouldPromotePausedStaticPartial(_ record: DownloadRecord,
                                                        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> Bool {
        record.status == .paused
            && record.metadata?.resolvedResumeMode(ratingKey: record.ratingKey) == .staticByteRange
            && record.bytes > 0
            && record.progress < 0.999
            && fileExists(record.localURL)
    }
}
