import Foundation

/// Pure launch/auth-edge retry schedule for download resume scanners.
///
/// Backend authentication can arrive after URLSession reattachment on cold launch. The app layer
/// still owns `Task.sleep` and idempotent scanner calls; this policy pins the retry cadence and the
/// queue-paused routing choice so it can be tested outside `DownloadManager`.
public enum DownloadResumeRetrySchedulePolicy {
    public enum ServerPrepAction: Equatable, Sendable {
        case resumePendingServerPrep
        case resumePendingEmbyConvertOnly
    }

    /// Plex inactive-lane hydration can lag selected-backend restore; keep scanning for about two
    /// minutes without stacking duplicate tasks.
    public static let retryDelaysSeconds: [Double] = [1.0, 5.0, 15.0, 30.0, 60.0]

    public static func serverPrepAction(isQueuePaused: Bool) -> ServerPrepAction {
        isQueuePaused ? .resumePendingEmbyConvertOnly : .resumePendingServerPrep
    }
}
