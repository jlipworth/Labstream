import Foundation

/// Pure queue-toolbar decision for the Offline downloads screen.
///
/// Running or requested work takes precedence over parked rows, so a mixed queue always
/// offers a way to stop it. Resume is memoryless: it attempts every incomplete idle row.
public enum DownloadQueueToolbarPolicy {
    public enum Action: String, Sendable, Equatable {
        case pauseQueue
        case resumeQueue

        public var title: String {
            switch self {
            case .pauseQueue: return "Pause All"
            case .resumeQueue: return "Resume All"
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
        var hasIncompleteIdleWork = false
        var hasActiveWork = false

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
        if hasIncompleteIdleWork || isQueuePaused { return .resumeQueue }
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
