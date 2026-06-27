import Foundation

/// Pure queue-toolbar decision for the Offline downloads screen.
///
/// Active transfer states should dominate paused rows: in a mixed list, the one global toolbar
/// action should pause the currently active work, not offer Resume merely because another row is
/// paused. Keeping this here pins the matrix outside SwiftUI (#172).
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
        var hasPausedWork = false

        for status in statuses {
            switch status {
            case .queued, .preparing, .downloading:
                hasActiveWork = true
            case .paused:
                hasPausedWork = true
            case .complete, .unverified, .failed:
                break
            }
        }

        if hasActiveWork { return .pauseQueue }
        if isQueuePaused || hasPausedWork { return .resumeQueue }
        return nil
    }
}
