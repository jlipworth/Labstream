import Foundation

/// Ephemeral progress overlay for active static byte-range chunks.
///
/// Persisted `DownloadRecord.bytes` stays checkpoint-only. This sample carries optimistic in-memory
/// bytes from the live URLSession chunk so the UI can show smooth progress/speed between durable
/// checkpoints without making pause/retry accounting depend on non-resumable temp files.
public struct DownloadLiveRangeProgressSample: Equatable, Sendable {
    public var bytes: Int
    public var expectedBytes: Int?
    public var updatedAt: Date

    public init(bytes: Int, expectedBytes: Int?, updatedAt: Date) {
        self.bytes = bytes
        self.expectedBytes = expectedBytes
        self.updatedAt = updatedAt
    }
}

/// Pure policy for merging and displaying live static-range progress samples.
public enum DownloadLiveRangeProgressPolicy {
    public static let staleIntervalSeconds: TimeInterval = 15

    /// Keep the largest live count within a transfer. Older bounded-checkpoint code allowed lower
    /// re-baselines between chunks, but #227 continuous-remainder tasks must not make the UI jump
    /// backwards when URLSession reports blob-resumed task bytes from a fresh per-task baseline.
    /// Preserve an earlier expected-byte total when the current callback omits it.
    public static func mergedSample(liveBytes: Int,
                                    expectedBytes: Int?,
                                    previous: DownloadLiveRangeProgressSample?,
                                    updatedAt: Date) -> DownloadLiveRangeProgressSample {
        let bytes = max(liveBytes, previous?.bytes ?? 0)
        return DownloadLiveRangeProgressSample(bytes: bytes,
                                               expectedBytes: expectedBytes ?? previous?.expectedBytes,
                                               updatedAt: updatedAt)
    }

    public static func isFresh(_ sample: DownloadLiveRangeProgressSample,
                               now: Date,
                               staleInterval: TimeInterval = staleIntervalSeconds) -> Bool {
        now.timeIntervalSince(sample.updatedAt) <= staleInterval
    }

    /// Normalize a task byte count against a persisted resume display watermark. A
    /// `downloadTask(withResumeData:)` can report `countOfBytesReceived` from the new task's own
    /// baseline (near zero) even though URLSession still owns prior temp bytes. If the fresh count is
    /// below the watermark, treat it as incremental-for-display; otherwise assume it is already
    /// cumulative and use it as-is.
    public static func displayBytesForResumedTask(taskBytes: Int,
                                                  resumeDisplayBytes: Int?) -> Int {
        guard let resumeDisplayBytes, resumeDisplayBytes > 0 else {
            return max(taskBytes, 0)
        }
        guard taskBytes > 0 else { return resumeDisplayBytes }
        if taskBytes < resumeDisplayBytes {
            return resumeDisplayBytes + taskBytes
        }
        return taskBytes
    }

    public static func liveDisplayBytes(for record: DownloadRecord,
                                        sample: DownloadLiveRangeProgressSample?,
                                        now: Date,
                                        staleInterval: TimeInterval = staleIntervalSeconds) -> Int? {
        guard record.status == .downloading,
              let sample,
              sample.bytes > record.bytes else { return nil }
        // Keep displaying the last known in-flight count while the row is still active. During
        // iPad/Mac sleep-wake the app can be foregrounded before URLSession delivers a fresh progress
        // callback; hiding a stale-but-active sample made the row flash back to the durable checkpoint
        // (often 0 bytes for a single continuous remainder) even though the task was still resumable.
        return sample.bytes
    }
}
