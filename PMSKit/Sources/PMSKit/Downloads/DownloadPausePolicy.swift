import Foundation

/// Pure pause decisions for a visible download row.
///
/// The app still owns URLSession cancellation, durable store writes, and diagnostics. This policy
/// pins which rows can be paused and how static byte-range rows differ from opaque/server-prep
/// rows, especially the checkpoint-draining path used by background range downloads.
public enum DownloadPausePolicy {
    public enum RowAction: Equatable, Sendable {
        case ignore
        /// Preparing/server-side work has no local URLSession task; park the row immediately.
        case parkPreparing
        /// A static byte-range task is live; mark checkpoint-draining before asking the session to
        /// pause so the current bounded chunk can append a durable checkpoint.
        case checkpointPauseAndCancelTask
        /// Static byte-range row has no live task to drain; park as paused immediately, then still
        /// ask the session to clear any delayed callbacks.
        case parkStaticWithoutLiveTask
        /// Opaque/live-forward rows pause through URLSession only.
        case cancelTaskOnly
    }

    public static func rowAction(status: DownloadStatus,
                                 isStaticRangeRecord: Bool,
                                 isTrackingTransfer: Bool) -> RowAction {
        switch status {
        case .queued, .downloading:
            if isStaticRangeRecord {
                return isTrackingTransfer ? .checkpointPauseAndCancelTask : .parkStaticWithoutLiveTask
            }
            return .cancelTaskOnly
        case .preparing:
            return .parkPreparing
        case .complete, .unverified, .failed, .paused:
            return .ignore
        }
    }

    /// Global queue pause should pause active rows except persistent Emby convert jobs, which can
    /// continue server-side polling while no local bytes are transferring.
    public static func shouldPauseDuringQueuePause(_ record: DownloadRecord) -> Bool {
        record.status.isActiveWork
            && !ServerPrepRefreshPolicy.shouldPollEmbyServerPrepWhileQueuePaused(record)
    }
}
