import Foundation

/// Pure decisions for replacing a remote Jellyfin/Emby stream without coupling tests to AVPlayer.
public enum RemoteStreamLifecyclePolicy {
    public enum PriorSessionStopDecision: Sendable, Equatable {
        case skip(reason: String)
        case deferStop(reason: String)
    }

    /// A remote reopen result belongs to the currently-active playback generation only while the
    /// task is not cancelled and the captured generation still matches the controller generation.
    public static func acceptsReopenResult(capturedGeneration: Int,
                                           currentGeneration: Int,
                                           isCancelled: Bool) -> Bool {
        !isCancelled && capturedGeneration == currentGeneration
    }

    /// Decide what to do with the prior remote server session after a replacement stream loads.
    /// If the backend reused the same play-session id, stopping the prior closure can tear down the
    /// newly-active stream; otherwise the old encoder/session should be stopped after AVPlayer has
    /// detached from it.
    public static func priorSessionStopDecision(priorPlaySessionID: String?,
                                                reopenedPlaySessionID: String?) -> PriorSessionStopDecision {
        if let priorPlaySessionID,
           let reopenedPlaySessionID,
           priorPlaySessionID == reopenedPlaySessionID {
            return .skip(reason: "same_play_session")
        }
        return .deferStop(reason: "after_reopen_item_detached")
    }
}
