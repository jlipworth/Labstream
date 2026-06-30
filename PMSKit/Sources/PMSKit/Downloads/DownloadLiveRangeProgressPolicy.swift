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

    /// Keep the largest live count within a chunk, but allow a new chunk/checkpoint to re-baseline
    /// from a lower byte count. Preserve an earlier expected-byte total when the current callback
    /// omits it.
    public static func mergedSample(liveBytes: Int,
                                    expectedBytes: Int?,
                                    previous: DownloadLiveRangeProgressSample?,
                                    updatedAt: Date) -> DownloadLiveRangeProgressSample {
        let bytes: Int
        if let previous, liveBytes < previous.bytes {
            bytes = liveBytes
        } else {
            bytes = max(liveBytes, previous?.bytes ?? 0)
        }
        return DownloadLiveRangeProgressSample(bytes: bytes,
                                               expectedBytes: expectedBytes ?? previous?.expectedBytes,
                                               updatedAt: updatedAt)
    }

    public static func isFresh(_ sample: DownloadLiveRangeProgressSample,
                               now: Date,
                               staleInterval: TimeInterval = staleIntervalSeconds) -> Bool {
        now.timeIntervalSince(sample.updatedAt) <= staleInterval
    }

    public static func liveDisplayBytes(for record: DownloadRecord,
                                        sample: DownloadLiveRangeProgressSample?,
                                        now: Date,
                                        isCheckpointPausing: Bool,
                                        staleInterval: TimeInterval = staleIntervalSeconds) -> Int? {
        guard record.status == .downloading || isCheckpointPausing,
              let sample,
              isFresh(sample, now: now, staleInterval: staleInterval),
              sample.bytes > record.bytes else { return nil }
        return sample.bytes
    }
}
