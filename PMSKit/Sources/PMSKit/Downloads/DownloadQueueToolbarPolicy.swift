import Foundation

/// Pure queue-toolbar decision for the Offline downloads screen.
///
/// Idle incomplete rows should dominate active transfer states: in a mixed list, the one global
/// toolbar action should keep offering Resume until every resumable row has been kicked. Otherwise
/// a quick "Resume All" tap can turn into an accidental "Pause All" tap as soon as the first
/// transfer starts, parking the rest of the backlog before their async retry reaches URLSession.
/// Once no work is active, Resume is intentionally memoryless: it means "attempt every incomplete
/// idle row", not "only rows paused by the last global pause" (#172).
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
        // The persisted global gate is the authoritative state for the toolbar. Some backend
        // preparation rows intentionally keep polling while the queue is paused, and URLSession
        // rows can take a refresh turn to settle from active -> paused. In those windows the
        // visible control must still flip to Resume All so the next tap actually clears the gate.
        if isQueuePaused { return .resumeQueue }

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

        if hasIncompleteIdleWork { return .resumeQueue }
        if hasActiveWork { return .pauseQueue }
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
