import Foundation
import Observation
import PlexKit

/// Central app state, observed by SwiftUI.
///
/// Holds the stable client identity, the current auth token, the selected server
/// and its resolved base URL, and the shared `PlexClient` used for all API calls.
///
/// Deliberately does NOT own the player or download controllers: the UI layer
/// instantiates a single `DownloadManager` at the root and creates `PlayerView`s
/// on demand. Keeping those out of `AppModel` avoids reference cycles (the
/// download/player controllers themselves reference back into `AppModel`).
@MainActor
@Observable
final class AppModel {
    /// Stable client identity (clientIdentifier from Keychain, fixed product/version).
    var identity: ClientIdentity

    /// Current Plex auth token; `nil` means signed out.
    var token: String?

    /// The server the user has selected from discovery.
    var selectedServer: PlexDevice?

    /// The resolved base URL for `selectedServer` (best-ranked connection).
    var serverBaseURL: URL?

    /// Shared live executor for all Plex API requests.
    let client: PlexClient

    var isAuthenticated: Bool { token != nil }

    init(identity: ClientIdentity,
         token: String? = nil,
         client: PlexClient? = nil) {
        self.identity = identity
        self.token = token
        self.client = client ?? PlexClient(identity: identity)
    }
}
