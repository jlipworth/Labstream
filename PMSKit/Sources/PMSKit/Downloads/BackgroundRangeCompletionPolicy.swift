import Foundation

public enum BackgroundRangeRequestReason: String, Sendable, Equatable {
    /// The transfer engine no longer has the authenticated base request needed to create the next
    /// open-ended remainder, so the manager/backend layer must rebuild one from the durable partial.
    case requestRebuildNeeded
    /// A legacy closed-Range task was dropped on reattach; rebuild an authenticated open-ended
    /// remainder from the durable partial.
    case unownedRangeRejected
    /// The pinned HTTP validator changed. The stale partial was discarded and the manager/backend
    /// layer must rebuild an authenticated request to restart from byte 0.
    case validatorChanged
    /// The server rejected a static Range request as unauthorized/forbidden. The durable partial
    /// remains valid, but the manager/backend layer should mint a fresh per-row download request
    /// instead of blindly retrying the same forbidden URL/session.
    case serverAuthorizationRejected
}

public enum BackgroundRangeCompletionDisposition: Sendable, Equatable {
    case successAlreadyHandled
    case cancelled
    case requestNeeded(BackgroundRangeRequestReason)
    case pauseResumable
}

/// Pure terminal mapping for static byte-range URLSession task completion after any immediate
/// transient retry attempt has declined.
public enum BackgroundRangeCompletionPolicy {
    public static func disposition(hasError: Bool,
                                   errorCode: Int?,
                                   hasRequest: Bool) -> BackgroundRangeCompletionDisposition {
        guard hasError else { return .successAlreadyHandled }
        if errorCode == NSURLErrorCancelled {
            return .cancelled
        }
        return hasRequest ? .pauseResumable : .requestNeeded(.requestRebuildNeeded)
    }
}
