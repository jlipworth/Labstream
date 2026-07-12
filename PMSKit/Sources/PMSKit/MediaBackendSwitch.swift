import Foundation

/// Canonical identity for every media-server backend supported by Labstream.
///
/// The raw values are persisted in credentials, download metadata, and system-entry
/// identifiers. They are therefore a wire-format contract and must remain stable.
public enum MediaBackendID: String, Sendable, Equatable, Hashable, Codable, CaseIterable, Identifiable {
    case plex
    case jellyfin
    case emby

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .plex: return "Plex"
        case .jellyfin: return "Jellyfin"
        case .emby: return "Emby"
        }
    }
}

/// Source-compatible name retained for callers that describe a backend UI choice.
public typealias MediaBackendChoice = MediaBackendID

public struct MediaBackendCredentialSnapshot: Sendable, Equatable {
    public let plexToken: String?
    public let jellyfinServerURLString: String?
    public let jellyfinAccessToken: String?
    public let jellyfinUserID: String?
    public let embyServerURLString: String?
    public let embyAccessToken: String?
    public let embyUserID: String?

    public init(plexToken: String?,
                jellyfinServerURLString: String?,
                jellyfinAccessToken: String?,
                jellyfinUserID: String?,
                embyServerURLString: String? = nil,
                embyAccessToken: String? = nil,
                embyUserID: String? = nil) {
        self.plexToken = plexToken
        self.jellyfinServerURLString = jellyfinServerURLString
        self.jellyfinAccessToken = jellyfinAccessToken
        self.jellyfinUserID = jellyfinUserID
        self.embyServerURLString = embyServerURLString
        self.embyAccessToken = embyAccessToken
        self.embyUserID = embyUserID
    }

    public func hasSavedSession(for backend: MediaBackendChoice) -> Bool {
        switch backend {
        case .plex:
            return !(plexToken ?? "").isEmpty
        case .jellyfin:
            return !(jellyfinServerURLString ?? "").isEmpty &&
                !(jellyfinAccessToken ?? "").isEmpty &&
                !(jellyfinUserID ?? "").isEmpty
        case .emby:
            return !(embyServerURLString ?? "").isEmpty &&
                !(embyAccessToken ?? "").isEmpty &&
                !(embyUserID ?? "").isEmpty
        }
    }
}

public enum MediaBackendSwitchResolution: Sendable, Equatable {
    case alreadyActive
    case restoreSavedSession
    case requireLogin
}

public enum MediaBackendSwitch {
    public static func resolve(active: MediaBackendChoice,
                               target: MediaBackendChoice,
                               credentials: MediaBackendCredentialSnapshot) -> MediaBackendSwitchResolution {
        guard active != target else { return .alreadyActive }
        return credentials.hasSavedSession(for: target) ? .restoreSavedSession : .requireLogin
    }
}

/// Decides which backend an already-loaded media item must be played/acted against.
///
/// A detail screen captures a `MediaItem` value with no backend tag and may outlive a
/// backend switch (#100). Playback, watched-toggle, and download must target the backend
/// the item ORIGINATED from — resolving a stale ratingKey against whatever backend happens
/// to be active now sends, e.g., an Emby ratingKey to a Jellyfin server. This is a pure
/// function so the rule ("origin always wins, regardless of the current active backend")
/// is unit-testable without the SwiftUI view tree.
public enum PlaybackBackendResolver {
    /// The backend an item's actions must use. Always the item's origin backend; the
    /// currently-active backend is intentionally ignored (it exists only to document that
    /// the decision does NOT depend on it).
    public static func backend(forItemOrigin origin: MediaBackendChoice,
                               currentActive: MediaBackendChoice) -> MediaBackendChoice {
        _ = currentActive
        return origin
    }
}
