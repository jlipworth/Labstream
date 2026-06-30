import Foundation

/// Last emitted durable-progress diagnostic for a background static-range task.
public struct BackgroundRangeProgressDiagnosticSnapshot: Sendable, Equatable {
    public let time: Date
    public let bytes: Int

    public init(time: Date, bytes: Int) {
        self.time = time
        self.bytes = bytes
    }
}

/// Pure progress-derived decisions for the background download transfer engine.
public enum BackgroundDownloadProgressPolicy {
    /// Recover the final-size estimate for a row adopted on relaunch (#169). `progress` was computed
    /// as `bytes / expected`, so invert it; nil when there is no usable signal.
    public static func derivedExpectedBytes(_ record: DownloadRecord) -> Int? {
        derivedExpectedBytes(downloadedBytes: record.bytes, progress: record.progress)
    }

    public static func derivedExpectedBytes(downloadedBytes: Int, progress: Double) -> Int? {
        guard downloadedBytes > 0, progress > 0.0001 else { return nil }
        let expected = Int((Double(downloadedBytes) / min(progress, 1.0)).rounded())
        return expected > 0 ? expected : nil
    }

    /// Decide whether to emit a durable range-progress breadcrumb. The first callback and first
    /// observation always log; otherwise the diagnostic is throttled by either time or chunk-sized
    /// byte movement.
    public static func shouldRecordRangeProgress(last: BackgroundRangeProgressDiagnosticSnapshot?,
                                                 now: Date,
                                                 totalBytes: Int,
                                                 rangeChunkSize: Int,
                                                 isFirstCallback: Bool) -> Bool {
        guard !isFirstCallback else { return true }
        guard let last else { return true }
        let elapsed = now.timeIntervalSince(last.time)
        let byteDelta = totalBytes - last.bytes
        return elapsed >= 10 || byteDelta >= rangeChunkSize
    }

    /// Decide whether to publish a UI refresh for transfer progress. Completion always publishes
    /// even if it arrives inside the normal throttle window.
    public static func shouldNotifyProgressChange(lastNotification: Date?,
                                                  now: Date,
                                                  progress: Double,
                                                  interval: TimeInterval) -> Bool {
        (lastNotification.map { now.timeIntervalSince($0) >= interval } ?? true)
            || progress >= 1.0
    }
}
