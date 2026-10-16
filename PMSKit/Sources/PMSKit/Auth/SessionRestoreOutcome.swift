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
    /// The server answered, but the saved identity could not be confirmed (e.g. a 2xx probe for
    /// a different user). The credential is preserved for retry, but this is not a reachability
    /// failure, so it does not admit the Offline launch surface.
    case unconfirmedIdentity
    /// The credential is preserved but the server could not be used right now: network, DNS,
    /// TLS, timeout, discovery, server-unreachable, or a non-401 HTTP failure.
    case temporarilyUnavailable

    /// True when the saved credential survives this outcome (a later retry can restore it).
    public var retainsSavedCredential: Bool {
        switch self {
        case .restored, .unconfirmedIdentity, .temporarilyUnavailable: true
        case .missingCredential, .invalidCredential: false
        }
    }

    /// Runtime readiness is authoritative: a live lane is `.restored` whatever the helper
    /// reported, and a helper that claimed success without publishing a usable lane is only
    /// temporarily unavailable.
    public func reconciled(hasUsableSession: Bool) -> Self {
        if hasUsableSession { return .restored }
        return self == .restored ? .temporarilyUnavailable : self
    }
}
