import Foundation

/// Pure decision for how an in-flight background download should land when its transfer fails with an
/// auth HTTP status.
///
/// Logout proactively revokes the Jellyfin/Emby access token server-side (the logout path stays
/// instant — it does not pause or await in-flight transfers first). A background remainder task that
/// is still holding the pre-revocation token then 401/403s on its next bytes. That is not a real
/// error the user must act on: the download should park in the existing "waiting for a valid session"
/// deferred/paused state and resume once the account is signed back in.
///
/// The distinction that matters: only an auth status WITH the backend session actually gone maps to a
/// deferral. A genuine 401/403 while still signed in is a real authorization error and must still
/// surface as `.failed`, so the gate is specifically HTTP 401/403 + missing live session rather than
/// a blanket remap of every error.
public enum PostLogoutDownloadFailurePolicy {
    public enum Disposition: Sendable, Equatable {
        /// Park the row in the deferred "waiting for a valid session" state (backend signed out).
        case deferAwaitingSession
        /// A real failure the user needs to see.
        case fail
    }

    /// Auth statuses an in-flight transfer can hit purely because the user signed out mid-download and
    /// the backend revoked the token. Only these are candidates for a graceful deferral. Shares the
    /// same 401/403 set the static-Range rehydration path already treats as auth rejections.
    public static func isDeferrableAuthStatus(_ statusCode: Int) -> Bool {
        BackgroundDownloadTransientRetryPolicy.rehydratableHTTPStatusCodes.contains(statusCode)
    }

    /// Defer only for an auth status when no live backend session remains; everything else fails.
    public static func disposition(httpStatus: Int, hasLiveSession: Bool) -> Disposition {
        if isDeferrableAuthStatus(httpStatus) && !hasLiveSession {
            return .deferAwaitingSession
        }
        return .fail
    }
}
