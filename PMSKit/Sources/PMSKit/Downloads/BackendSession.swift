import Foundation

/// Identifies which backend a download belongs to. Mirrors `MediaBackendKind`
/// (app layer) / `MediaBackendChoice` (PMSKit) but is OWNED by the download
/// subsystem and persisted on each row, so backend is no longer inferred only
/// from the ratingKey prefix.
public enum DownloadBackendKind: String, Codable, Sendable, Equatable, CaseIterable {
    case plex
    case jellyfin
    case emby

    public var displayName: String {
        switch self {
        case .plex: return "Plex"
        case .jellyfin: return "Jellyfin"
        case .emby: return "Emby"
        }
    }
}

/// An immutable, per-job authentication + server-identity snapshot. Resolved at
/// ENQUEUE time from the job's own backend lane and carried/persisted with the
/// download so resume/retry/cleanup never read `appModel.active*`.
///
/// Plex carries BOTH `accountToken` (the plex.tv account token) and the
/// resource-scoped `token` (used against the PMS; may equal the account token).
/// Requests use `token`; `accountToken` is retained for flows (e.g. discovery
/// re-resolve) that need it. Jellyfin/Emby carry a single access token plus
/// `userID`. `serverID` is the stable server identity used as the lookup key
/// when present; `baseURL` is the resolved connection.
public struct BackendSession: Codable, Sendable, Equatable {
    public let kind: DownloadBackendKind
    public let baseURL: URL
    /// Plex: resource/server-scoped token (falls back to account token).
    /// Jellyfin/Emby: the access token.
    public let token: String
    /// Plex only: the plex.tv account token, when distinct from `token`. nil for JF/Emby.
    public let accountToken: String?
    /// Jellyfin/Emby only: the authenticated user id. nil for Plex.
    public let userID: String?
    /// Stable server identity when known (Plex machineIdentifier, JF/Emby serverId).
    /// Used as the lookup key for matching a persisted job to a live session.
    public let serverID: String?

    public init(kind: DownloadBackendKind,
                baseURL: URL,
                token: String,
                accountToken: String? = nil,
                userID: String? = nil,
                serverID: String? = nil) {
        self.kind = kind
        self.baseURL = baseURL
        self.token = token
        self.accountToken = accountToken
        self.userID = userID
        self.serverID = serverID
    }

    /// Stable, non-secret lookup key for matching a persisted download's required
    /// session to a currently-configured one (kind + serverID when known, else host).
    public var lookupKey: String {
        let serverPart = serverID ?? baseURL.host ?? baseURL.absoluteString
        return "\(kind.rawValue)|\(serverPart)"
    }
}
