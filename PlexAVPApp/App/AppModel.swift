import Foundation
import Observation
import PMSKit

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

    /// Shared live executor for all Plex API requests.
    let client: PlexClient

    var isAuthenticated: Bool { token != nil }
    var isBrowseReady: Bool { token != nil && serverToken != nil && serverBaseURL != nil }

    init(identity: ClientIdentity,
         token: String? = nil,
         client: PlexClient? = nil) {
        self.identity = identity
        self.token = token
        self.client = client ?? PlexClient(identity: identity)
    }
}
