import Foundation

/// Pure pause decisions for a visible download row.
///
/// The app still owns URLSession cancellation, durable store writes, and diagnostics. This policy
/// pins which rows can be paused and how static byte-range rows differ from opaque/server-prep
/// rows. Static byte-range downloads now pause like normal background downloads: cancel the single
/// open-ended task and keep URLSession resume data when the OS can provide it.
public enum DownloadPausePolicy {
    public enum RowAction: Equatable, Sendable {
        case ignore
        /// Preparing/server-side work has no local URLSession task; park the row immediately.
        case parkPreparing
        /// Static byte-range row has no live task to drain; park as paused immediately, then still
        /// ask the session to clear any delayed callbacks.
        case parkStaticWithoutLiveTask
        /// Opaque/live-forward rows pause through URLSession only.
        case cancelTaskOnly
    }

    public static func rowAction(status: DownloadStatus,
                                 isStaticRangeRecord: Bool,
                                 isTrackingTransfer: Bool,
                                 isServerPrepRecord: Bool = false) -> RowAction {
        switch status {
        case .queued, .downloading:
            // Plex persists server preparation as `.queued` even though no URLSession task exists.
            // Park it synchronously; routing it through the async no-task URLSession pause path can
            // race refresh-time poller reattachment and leave contradictory paused/active state.
            if isServerPrepRecord { return .parkPreparing }
            if isStaticRangeRecord {
                return isTrackingTransfer ? .cancelTaskOnly : .parkStaticWithoutLiveTask
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
