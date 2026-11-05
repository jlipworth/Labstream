import Foundation

/// Gate in front of reattach's task classification (B02).
///
/// Pause and cancel remove a task's tracking and persist their row state synchronously, then cancel
/// the URLSession task asynchronously. A reattach enumeration (relaunch or scene-active foreground)
/// that lands in that window still sees the task. Adopting it would force the row back to
/// `.downloading`, and its rebuild branch would re-queue a paused row.
public enum BackgroundReattachTaskGatePolicy {
    public enum Disposition: Equatable, Sendable {
        /// A pause, cancel or supersede already owns this task's teardown; do not touch it.
        case leaveAlone
        /// The row is paused but nothing in this process is tearing the task down (for example an
        /// OS-resumed task after relaunch). Cancel it; never adopt or rebuild a paused row.
        case cancelForPausedRow
        /// Continue with the normal adopt / reject / rebuild classification.
        case classify
    }

    public static func disposition(isSuperseded: Bool,
                                   isCanceling: Bool,
                                   isAttemptHalted: Bool,
                                   rowStatus: DownloadStatus?) -> Disposition {
        if isSuperseded || isCanceling || isAttemptHalted { return .leaveAlone }
        if rowStatus == .paused { return .cancelForPausedRow }
        return .classify
    }

    /// Whether reattach may write `.downloading` (adoption) or `.queued` (rebuild) for a row. The
    /// row is re-read at write time because a pause can land after classification.
    public static func mayWriteActiveStatus(currentStatus: DownloadStatus?,
                                            isAttemptHalted: Bool) -> Bool {
        guard let currentStatus, !isAttemptHalted else { return false }
        return currentStatus != .paused
    }
}
