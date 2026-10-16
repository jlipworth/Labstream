import Foundation

/// Typed result of restoring the selected backend's saved session (#259).
///
/// Product behavior (sign-in vs. retry vs. the restricted Offline launch surface) is derived from
/// this classification rather than from a Boolean plus user-facing error text. Every backend
/// (Plex, Jellyfin, Emby) maps its restore path onto the same cases.
public enum SessionRestoreOutcome: Sendable, Equatable {
    /// The selected lane is live and browse-ready.
    case restored
    /// No saved credential exists (never signed in, or an explicit sign-out removed it).
    case missingCredential
    /// The server explicitly rejected the saved credential (HTTP 401); it has been retired.
    case invalidCredential
    /// The server answered but did not accept the saved session as usable: HTTP 403, or a 2xx
    /// identity probe for a different user. The credential is preserved for retry (only a 401
    /// proves revocation), but this is not a reachability failure, so it does not admit the
    /// Offline launch surface.
    case unconfirmedCredential
    /// The credential is preserved but the server could not be used right now: network, DNS,
    /// TLS, timeout, discovery, server-unreachable, HTTP 429/5xx, or an unreadable reply.
    case temporarilyUnavailable

    /// True when the saved credential survives this outcome (a later retry can restore it).
    public var retainsSavedCredential: Bool {
        switch self {
        case .restored, .unconfirmedCredential, .temporarilyUnavailable: true
        case .missingCredential, .invalidCredential: false
        }
    }

    /// Classify a restore failure that preserved the saved credential. An HTTP 403 is the server
    /// answering with a denial, so it never counts as transient; every other preserved failure
    /// (transport, discovery, 429, 5xx, unreadable reply) is temporarily unavailable.
    public static func preservedFailure(httpStatus: Int?) -> Self {
        httpStatus == 403 ? .unconfirmedCredential : .temporarilyUnavailable
    }

    /// Runtime readiness is authoritative: a live lane is `.restored` whatever the helper
    /// reported, and a helper that claimed success without publishing a usable lane is only
    /// temporarily unavailable.
    public func reconciled(hasUsableSession: Bool) -> Self {
        if hasUsableSession { return .restored }
        return self == .restored ? .temporarilyUnavailable : self
    }
}
