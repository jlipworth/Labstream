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

    /// Canonical migration fallback: infer the backend from a download's ratingKey prefix
    /// (`jellyfin:` / `emby:` / bare = Plex). The single source of truth for prefix-based
    /// resolution — `OfflineMetadata.resolvedBackendKind` and any caller without stored
    /// `backendKind` (e.g. a nil-metadata row) must route through here so they never disagree.
    public init(ratingKeyPrefix ratingKey: String) {
        if ratingKey.hasPrefix("jellyfin:") { self = .jellyfin }
        else if ratingKey.hasPrefix("emby:") { self = .emby }
        else { self = .plex }
    }
}

/// An immutable, per-job authentication + server-identity snapshot. Resolved at
/// ENQUEUE time from the job's own backend lane and carried with the download so
/// resume/retry/cleanup never read `appModel.active*`.
///
/// `token` is the credential requests authenticate with (Plex: the resource/
/// server-scoped token; Jellyfin/Emby: the access token). Jellyfin/Emby carry a
/// `userID`. `serverID` is the stable server identity used to match a persisted
/// job to a live session when present; `baseURL` is the resolved connection.
public struct BackendSession: Codable, Sendable, Equatable {
    public let kind: DownloadBackendKind
    public let baseURL: URL
    /// Plex: resource/server-scoped token. Jellyfin/Emby: the access token.
    public let token: String
    /// Jellyfin/Emby only: the authenticated user id. nil for Plex.
    public let userID: String?
    /// Stable server identity when known (Plex machineIdentifier, JF/Emby serverId).
    /// Used to match a persisted job to a live session.
    public let serverID: String?

    public init(kind: DownloadBackendKind,
                baseURL: URL,
                token: String,
                userID: String? = nil,
                serverID: String? = nil) {
        self.kind = kind
        self.baseURL = baseURL
        self.token = token
        self.userID = userID
        self.serverID = serverID
    }
}
