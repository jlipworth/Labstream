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

    /// Whether THIS live session is the same server a persisted job was downloaded from — so a
    /// resume/retry/cleanup is allowed to reuse the live encoder/PlaySession instead of leaking it
    /// against a foreign server (GH #135 Stage 1e, extracted from `DownloadManager`).
    ///
    /// Prefer the stable `serverID` when both sides have one; otherwise fall back to base-URL
    /// identity. Legacy/partial metadata with no server identity returns `true` (best-effort cleanup
    /// rather than permanently leaking a known PlaySessionId).
    public func matchesPersistedServer(_ metadata: OfflineMetadata) -> Bool {
        if let persistedID = metadata.backendServerID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !persistedID.isEmpty {
            return serverID == persistedID
        }
        guard let persistedURLString = metadata.backendBaseURLString,
              let persistedURL = URL(string: persistedURLString) else {
            return true
        }
        return BackendURLIdentity.sameBaseURL(persistedURL, baseURL)
    }
}

/// Pure base-URL identity for matching a persisted download's server to a live session
/// (GH #135 Stage 1e). Scheme + host (case-insensitive) + effective port + normalized base path.
public enum BackendURLIdentity {
    public static func sameBaseURL(_ lhs: URL, _ rhs: URL) -> Bool {
        guard lhs.scheme?.lowercased() == rhs.scheme?.lowercased(),
              lhs.host?.lowercased() == rhs.host?.lowercased(),
              effectivePort(lhs) == effectivePort(rhs) else { return false }
        return normalizedBasePath(lhs.path) == normalizedBasePath(rhs.path)
    }

    /// The port the connection actually uses, defaulting the well-known http/https ports so an
    /// explicit `:443` and an implicit https compare equal.
    public static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    public static func normalizedBasePath(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
