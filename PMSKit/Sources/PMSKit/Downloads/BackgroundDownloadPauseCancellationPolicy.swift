import Foundation

/// Pure pause/cancel race decisions for background transfer callbacks.
public enum BackgroundDownloadPauseCancellationPolicy {
    /// A delayed cancel/resumeData callback may mark the row paused only while the visible row is
    /// still in an active pre-terminal state and no replacement URLSession task has taken ownership.
    public static func pauseStillApplies(status: DownloadStatus?,
                                         hasReplacementTask: Bool) -> Bool {
        guard status == .queued || status == .downloading else { return false }
        return !hasReplacementTask
    }

    /// `startRangeChunk` can throw during user pause/delete races. A halted row or explicit
    /// cancellation is owned by the pause/delete path and should not be surfaced as a transfer error.
    public static func shouldSuppressRangeStartFailure(isHalted: Bool,
                                                       isCancellation: Bool) -> Bool {
        isHalted || isCancellation
    }
}
