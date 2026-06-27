import Foundation

/// Pure queue-toolbar decision for the Offline downloads screen.
///
/// Active transfer states should dominate idle incomplete rows: in a mixed list, the one global
/// toolbar action should pause the currently active work, not offer Resume merely because another
/// row is paused/failed. Once no work is active, Resume is intentionally memoryless: it means
/// "attempt every incomplete idle row", not "only rows paused by the last global pause" (#172).
public enum DownloadQueueToolbarPolicy {
    public enum Action: String, Sendable, Equatable {
        case pauseQueue
        case resumeQueue

        public var title: String {
            switch self {
            case .pauseQueue: return "Pause Queue"
            case .resumeQueue: return "Resume Queue"
            }
        }

        public var systemImage: String {
            switch self {
            case .pauseQueue: return "pause.circle"
            case .resumeQueue: return "play.circle"
            }
        }
    }

    public static func action(isQueuePaused: Bool, statuses: some Sequence<DownloadStatus>) -> Action? {
        var hasActiveWork = false
        var hasIncompleteIdleWork = false

        for status in statuses {
            switch status {
            case .queued, .preparing, .downloading:
                hasActiveWork = true
            case .paused, .failed:
                hasIncompleteIdleWork = true
            case .complete, .unverified:
                break
            }
        }

        if hasActiveWork { return .pauseQueue }
        if isQueuePaused || hasIncompleteIdleWork { return .resumeQueue }
        return nil
    }

    public static func shouldRetryWhenResumingQueue(_ status: DownloadStatus) -> Bool {
        switch status {
        case .paused, .failed:
            return true
        case .queued, .preparing, .downloading, .complete, .unverified:
            return false
        }
    }
}
