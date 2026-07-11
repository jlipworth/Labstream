import Foundation

/// Ephemeral progress overlay for an active static byte-range remainder.
///
/// Persisted `DownloadRecord.bytes` stays checkpoint-only. This sample carries optimistic in-memory
/// bytes from the live URLSession body so the UI can show smooth progress/speed between durable
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
///
/// Samples deliberately have NO time-based staleness: an active background URLSession can keep
/// writing while the suspended app receives no delegate callbacks, and expiring the last sample
/// made the toolbar total fall to the durable checkpoint and jump back at wake. A sample lives
/// exactly as long as its row stays `.downloading` (terminal/pause cleanup removes it).
public enum DownloadLiveRangeProgressPolicy {
    /// Keep the largest live count within the active continuous-remainder transfer. #227/#231
    /// should not make the UI jump backwards when URLSession reports blob-resumed task bytes from a
    /// fresh per-task baseline. Preserve an earlier expected-byte total when the current callback
    /// omits it.
    public static func mergedSample(liveBytes: Int,
                                    expectedBytes: Int?,
                                    previous: DownloadLiveRangeProgressSample?,
                                    updatedAt: Date) -> DownloadLiveRangeProgressSample {
        let bytes = max(liveBytes, previous?.bytes ?? 0)
        return DownloadLiveRangeProgressSample(bytes: bytes,
                                               expectedBytes: expectedBytes ?? previous?.expectedBytes,
                                               updatedAt: updatedAt)
    }

    /// Normalize a task byte count against a persisted resume display watermark. A
    /// `downloadTask(withResumeData:)` can report `countOfBytesReceived` from the new task's own
    /// baseline (near zero) even though URLSession still owns prior temp bytes.
    ///
    /// `taskBytes` is always `baseOffset` + the task's reported bytes, and the watermark itself
    /// already contains the base offset (it was persisted as `baseOffset + temp bytes` at pause).
    /// So when a fresh-baseline report comes in below the watermark, only the fresh delta above
    /// `baseOffset` is added — adding the whole `taskBytes` would count the durable base twice
    /// and compound the watermark on every pause/resume cycle.
    public static func displayBytesForResumedTask(taskBytes: Int,
                                                  baseOffset: Int,
                                                  resumeDisplayBytes: Int?) -> Int {
        guard let resumeDisplayBytes, resumeDisplayBytes > 0 else {
            return max(taskBytes, 0)
        }
        guard taskBytes > 0 else { return resumeDisplayBytes }
        if taskBytes < resumeDisplayBytes {
            return resumeDisplayBytes + max(taskBytes - max(baseOffset, 0), 0)
        }
        return taskBytes
    }

    /// Live display bytes across an active segment train: the durable partial already on disk plus
    /// the sum of every still-in-flight segment's optimistic body bytes (#A5, segment train follow-up
    /// to #212/#227/#231). Each segment's body is bytes accumulated in that task's own OS temp file
    /// since its own `baseOffset`; segments are disjoint byte ranges by construction, so summing their
    /// bodies alongside the shared destination file's durable size never double-counts.
    ///
    /// For the historical single-continuous-remainder case (`.openEndedRemainder`, exactly one live
    /// segment) the destination file is untouched until the task finishes, so `durableBytes` stays
    /// exactly equal to that segment's `baseOffset` for the task's whole life — this reduces to the
    /// pre-existing `baseOffset + bodyBytesWritten` total byte-for-byte.
    ///
    /// The raw result here can transiently DIP: `finishRangeRemainder` removes a completed segment
    /// from the live set before its body is asynchronously appended into the durable file, so a
    /// callback that lands in that window undercounts. Callers MUST still route this value through
    /// `mergedSample`, whose watermark keeps the published sample monotonic across that window.
    public static func aggregatedLiveBytes(durableBytes: Int, liveSegmentBodyBytes: [Int]) -> Int {
        let base = max(durableBytes, 0)
        let liveSum = liveSegmentBodyBytes.reduce(0) { $0 + max($1, 0) }
        return base + liveSum
    }

    public static func liveDisplayBytes(for record: DownloadRecord,
                                        sample: DownloadLiveRangeProgressSample?) -> Int? {
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
