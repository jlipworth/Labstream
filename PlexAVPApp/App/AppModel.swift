import Foundation
import Observation
import PMSKit

enum MediaBackendKind: String, Codable, CaseIterable, Identifiable {
    case plex
    case jellyfin

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .plex: return "Plex"
        case .jellyfin: return "Jellyfin"
        }
    }
}

/// Central app state, observed by SwiftUI.
///
/// Holds the stable client identity, the current auth token, the selected server
/// and its resolved base URL, and the shared `PlexClient` used for all API calls.
///
/// Deliberately does NOT own the player or download controllers: the UI layer
/// instantiates a single `DownloadManager` at the root and creates `CustomPlayerView`s
/// on demand. Keeping those out of `AppModel` avoids reference cycles (the
/// download/player controllers themselves reference back into `AppModel`).
@MainActor
@Observable
final class AppModel {
    /// Active media backend. Plex remains the default for existing installs; Jellyfin
    /// carries separate credentials/session state so the two modes do not overwrite each other.
    var activeBackend: MediaBackendKind

    /// True while Settings is restoring a saved session for a different backend.
    var isSwitchingBackend = false

    /// Stable client identity (clientIdentifier from Keychain, fixed product/version).
    var identity: ClientIdentity

    /// Current Plex auth token; `nil` means signed out.
    var token: String?

    /// Token to use against the selected PMS resource. Plex discovery can return
    /// a resource-specific access token for shared/token-scoped servers; fall
    /// back to the account token when discovery does not provide one.
    var serverToken: String?

    /// The server the user has selected from discovery.
    var selectedServer: PlexDevice?

    /// The resolved base URL for `selectedServer` (best-ranked connection).
    var serverBaseURL: URL?

    /// Jellyfin session state. These mirror the Plex fields above but are intentionally
    /// separate so a Jellyfin sign-in never clobbers Plex credentials.
    var jellyfinServerBaseURL: URL?
    var jellyfinAccessToken: String?
    var jellyfinUserID: String?
    var jellyfinServerID: String?

    /// Shared live executor for all Plex API requests.
    let client: PlexClient

    var isAuthenticated: Bool {
        switch activeBackend {
        case .plex:
            return token != nil
        case .jellyfin:
            return jellyfinAccessToken != nil
        }
    }

    var isBrowseReady: Bool {
        switch activeBackend {
        case .plex:
            return token != nil && serverToken != nil && serverBaseURL != nil
        case .jellyfin:
            return jellyfinServerBaseURL != nil && jellyfinAccessToken != nil && jellyfinUserID != nil
        }
    }

    init(identity: ClientIdentity,
         activeBackend: MediaBackendKind = .plex,
         token: String? = nil,
         client: PlexClient? = nil) {
        self.activeBackend = activeBackend
        self.identity = identity
        self.token = token
        self.client = client ?? PlexClient(identity: identity)
    }
}
