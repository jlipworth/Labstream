import Foundation

public enum BackgroundRangeRequestReason: String, Sendable, Equatable {
    /// A background Range chunk was adopted after relaunch and finished, but the session object no
    /// longer has the authenticated base request needed to schedule the next chunk.
    case adoptedChunkFinished
    /// The pinned HTTP validator changed under an adopted chunk. The stale partial was discarded and
    /// the manager/backend layer must rebuild an authenticated request to restart from byte 0.
    case validatorChanged
    /// A Range chunk failed after relaunch before it could be appended. The durable partial remains
    /// the checkpoint and the manager/backend layer must rebuild the authenticated request.
    case adoptedChunkFailed
    /// The server rejected a static Range chunk as unauthorized/forbidden. The durable partial
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
///
/// The durable partial file remains the checkpoint for non-cancelled failures. Relaunch-adopted
/// chunks cannot rebuild the authenticated request in the transfer engine, so they persist queued
/// request-needed intent for DownloadManager/backends to resume. In-memory chunks with a base
/// request pause as user-resumable work.
public enum BackgroundRangeCompletionPolicy {
    public static func disposition(hasError: Bool,
                                   errorCode: Int?,
                                   hasRequest: Bool) -> BackgroundRangeCompletionDisposition {
        guard hasError else { return .successAlreadyHandled }
        if errorCode == NSURLErrorCancelled {
            return .cancelled
        }
        return hasRequest ? .pauseResumable : .requestNeeded(.adoptedChunkFailed)
    }
}
