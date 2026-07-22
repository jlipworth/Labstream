import Foundation
import Observation
import PMSKit

/// App-domain compatibility name for PMSKit's canonical backend identifier.
typealias MediaBackendKind = MediaBackendID

/// Opaque, process-local authority for one authenticated browse lane.
///
/// Repository and in-flight work may compare this value, but must never derive cache identity
/// from a credential, request URL, server hostname, or user identifier. A new value is minted
/// whenever any input that can change authenticated browse results changes.
struct BrowseSessionAuthority: Hashable, Sendable {
    fileprivate let value = UUID()
}

/// Immutable credentials, request identity, and authority captured for one browse operation.
///
/// `session` deliberately remains private data-plane material: callers may execute requests with
/// it, while cache/provenance code keys only on `backend` plus the opaque `authority`.
struct AuthenticatedBrowseSessionContext: Equatable, Sendable {
    let backend: MediaBackendKind
    let session: BackendSession
    let clientIdentity: ClientIdentity
    let authority: BrowseSessionAuthority
}

/// SwiftUI task/publication identity for authenticated browse surfaces. The display/session key
/// preserves existing navigation behavior, while the opaque authority also restarts work for
/// credential context changes (such as client-identity replacement) that intentionally do not
/// expose themselves in that key.
struct AuthenticatedBrowseLoadIdentity: Hashable {
    let sessionKey: String
    let authority: BrowseSessionAuthority?

    @MainActor
    init(appModel: AppModel) {
        sessionKey = appModel.activeBrowseSessionKey
        authority = appModel.activeAuthenticatedBrowseSession?.authority
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
    var identity: ClientIdentity {
        didSet {
            guard identity != oldValue else { return }
            invalidateBrowseAuthorities(for: Set(MediaBackendKind.allCases))
        }
    }

    /// Current Plex auth token; `nil` means signed out.
    var token: String? {
        didSet {
            if token != oldValue {
                plexAuthSessionRevision += 1
                noteBrowseAuthorityChange(for: .plex)
            }
        }
    }

    /// Token to use against the selected PMS resource. Plex discovery can return
    /// a resource-specific access token for shared/token-scoped servers; fall
    /// back to the account token when discovery does not provide one.
    var serverToken: String? {
        didSet {
            if serverToken != oldValue {
                plexAuthSessionRevision += 1
                noteBrowseAuthorityChange(for: .plex)
            }
        }
    }

    /// The server the user has selected from discovery.
    var selectedServer: PlexDevice? {
        didSet {
            if selectedServer?.clientIdentifier != oldValue?.clientIdentifier {
                noteBrowseAuthorityChange(for: .plex)
            }
        }
    }

    /// Plex servers discovered for the signed-in account. Kept in app state so
    /// Settings can present a real picker instead of forcing first-reachable.
    var plexServers: [PlexDevice] = []

    /// The resolved base URL for `selectedServer` (best-ranked connection).
    var serverBaseURL: URL? {
        didSet {
            if serverBaseURL != oldValue { noteBrowseAuthorityChange(for: .plex) }
        }
    }

    /// Non-secret display metadata for the signed-in Plex account.
    var plexAccountProfile: PlexAccountProfile? {
        didSet {
            if plexAccountProfile?.stableUserID != oldValue?.stableUserID {
                noteBrowseAuthorityChange(for: .plex)
            }
        }
    }

    /// Whether the resolved Plex connection is advertised as local/LAN. Used to choose
    /// between Home/Local and Internet/Remote quality caps without re-probing on playback.
    var selectedServerConnectionIsLocal = false

    /// Jellyfin session state. These mirror the Plex fields above but are intentionally
    /// separate so a Jellyfin sign-in never clobbers Plex credentials.
    var jellyfinServerBaseURL: URL? {
        didSet {
            if jellyfinServerBaseURL != oldValue { noteBrowseAuthorityChange(for: .jellyfin) }
        }
    }
    var jellyfinAccessToken: String? {
        didSet {
            if jellyfinAccessToken != oldValue {
                jellyfinAuthSessionRevision += 1
                noteBrowseAuthorityChange(for: .jellyfin)
            }
        }
    }
    var jellyfinUserID: String? {
        didSet {
            if jellyfinUserID != oldValue { noteBrowseAuthorityChange(for: .jellyfin) }
        }
    }
    var jellyfinServerID: String? {
        didSet {
            if jellyfinServerID != oldValue { noteBrowseAuthorityChange(for: .jellyfin) }
        }
    }

    /// Emby session state. A separate parallel lane from Jellyfin (different auth header
    /// scheme, base-path preservation, PlaybackInfo semantics) so the two never clobber
    /// each other.
    var embyServerBaseURL: URL? {
        didSet {
            if embyServerBaseURL != oldValue { noteBrowseAuthorityChange(for: .emby) }
        }
    }
    var embyAccessToken: String? {
        didSet {
            if embyAccessToken != oldValue {
                embyAuthSessionRevision += 1
                noteBrowseAuthorityChange(for: .emby)
            }
        }
    }
    var embyUserID: String? {
        didSet {
            if embyUserID != oldValue { noteBrowseAuthorityChange(for: .emby) }
        }
    }
    var embyServerID: String? {
        didSet {
            if embyServerID != oldValue { noteBrowseAuthorityChange(for: .emby) }
        }
    }

    /// Per-backend, process-local non-secret auth/session revisions. These let runtime
    /// SwiftUI identities refresh after same-server re-auth without ever embedding raw tokens.
    private var plexAuthSessionRevision = 0
    private var jellyfinAuthSessionRevision = 0
    private var embyAuthSessionRevision = 0
    private var plexBrowseAuthority = BrowseSessionAuthority()
    private var jellyfinBrowseAuthority = BrowseSessionAuthority()
    private var embyBrowseAuthority = BrowseSessionAuthority()
    @ObservationIgnored private var browseAuthorityMutationDepth = 0
    @ObservationIgnored private var pendingBrowseAuthorityChanges: Set<MediaBackendKind> = []

    /// Shared live executor for all Plex API requests.
    let client: PlexClient

    var isAuthenticated: Bool {
        switch activeBackend {
        case .plex:
            return token != nil
        case .jellyfin:
            return jellyfinAccessToken != nil
        case .emby:
            return embyAccessToken != nil
        }
    }

    var activeStreamingQualityDefaultsKey: String {
        switch activeBackend {
        case .plex:
            return selectedServerConnectionIsLocal
                ? PlaybackPreferences.Keys.homeQualityKbps
                : PlaybackPreferences.Keys.remoteQualityKbps
        case .jellyfin:
            // Jellyfin does not yet carry Plex resource-locality metadata; use the
            // internet/remote cap so the default stays conservative.
            return PlaybackPreferences.Keys.remoteQualityKbps
        case .emby:
            // Emby likewise has no locality metadata; conservative remote cap.
            return PlaybackPreferences.Keys.remoteQualityKbps
        }
    }

    var activeStreamingQualityKbps: Int {
        PlaybackPreferences.qualityKbps(forDefaultsKey: activeStreamingQualityDefaultsKey)
    }

    var activeStreamingQualityScopeLabel: String {
        switch activeBackend {
        case .plex:
            return selectedServerConnectionIsLocal ? "Home/Local" : "Internet/Remote"
        case .jellyfin:
            return "Internet/Remote"
        case .emby:
            return "Internet/Remote"
        }
    }

    /// Stable, token-free identity used for preferences that should survive re-authentication.
    /// `nil` for an unresolvable identity, which callers treat as "all libraries visible".
    var activeStableServerUserKey: String? {
        stableServerUserKey(for: activeBackend)
    }

    /// Runtime, token-free identity for browse UI, search, and music state. It changes with
    /// backend/server/user changes and with the per-backend non-secret auth/session revision.
    var activeBrowseSessionKey: String {
        browseSessionKey(for: activeBackend)
    }

    /// Token-free, per-backend identity used to scope library-visibility persistence (#104).
    /// Survives re-auth (the auth revision changes, the server/user identity does not).
    var libraryVisibilityBackendKey: String? {
        activeStableServerUserKey
    }

    var libraryVisibilityLegacyBackendKeys: [String] {
        switch activeBackend {
        case .plex:
            return LibraryVisibility.legacyRawBackendKeys(backend: .plex,
                                                          serverID: selectedServer?.clientIdentifier,
                                                          baseURLHost: serverBaseURL?.host)
        case .jellyfin:
            return LibraryVisibility.legacyRawBackendKeys(backend: .jellyfin,
                                                          serverID: jellyfinServerID,
                                                          baseURLHost: jellyfinServerBaseURL?.host)
        case .emby:
            return LibraryVisibility.legacyRawBackendKeys(backend: .emby,
                                                          serverID: embyServerID,
                                                          baseURLHost: embyServerBaseURL?.host)
        }
    }

    func migrateLibraryVisibilityKeysIfNeeded(store: LibraryVisibilityStore = LibraryVisibilityStore()) {
        store.migrateLegacyBackendKeys(libraryVisibilityLegacyBackendKeys,
                                       toBackendKey: libraryVisibilityBackendKey)
    }

    var isBrowseReady: Bool {
        switch activeBackend {
        case .plex:
            return token != nil && serverToken != nil && serverBaseURL != nil
        case .jellyfin:
            return jellyfinServerBaseURL != nil && jellyfinAccessToken != nil && jellyfinUserID != nil
        case .emby:
            return embyServerBaseURL != nil && embyAccessToken != nil && embyUserID != nil
        }
    }

    /// Vend the live session for a SPECIFIC backend, regardless of `activeBackend`.
    /// Returns nil when that backend lane is not configured (no creds yet). This is
    /// the single entry point the download pipeline uses instead of reading
    /// `serverToken` / `jellyfinAccessToken` / `embyAccessToken` directly, so a job
    /// always authenticates against its own backend even after the user switches.
    func backendSession(for kind: DownloadBackendKind) -> BackendSession? {
        switch kind {
        case .plex:
            guard let server = serverBaseURL, let srvToken = serverToken else { return nil }
            return BackendSession(kind: .plex,
                                  baseURL: server,
                                  token: srvToken,
                                  userID: nil,
                                  serverID: selectedServer?.clientIdentifier)
        case .jellyfin:
            guard let server = jellyfinServerBaseURL,
                  let token = jellyfinAccessToken,
                  let userID = jellyfinUserID else { return nil }
            return BackendSession(kind: .jellyfin, baseURL: server, token: token,
                                  userID: userID, serverID: jellyfinServerID)
        case .emby:
            guard let server = embyServerBaseURL,
                  let token = embyAccessToken,
                  let userID = embyUserID else { return nil }
            return BackendSession(kind: .emby, baseURL: server, token: token,
                                  userID: userID, serverID: embyServerID)
        }
    }

    /// Capture one coherent authenticated browse context for a specific backend lane.
    ///
    /// The returned authority changes on credential, server, base-URL, authenticated-user, or
    /// client-identity replacement. Changing another backend lane does not disturb it.
    func authenticatedBrowseSession(for kind: MediaBackendKind) -> AuthenticatedBrowseSessionContext? {
        guard let session = backendSession(for: kind.downloadBackendKind) else { return nil }
        return AuthenticatedBrowseSessionContext(
            backend: kind,
            session: session,
            clientIdentity: identity,
            authority: browseAuthority(for: kind)
        )
    }

    /// The exact context selected for user-facing browse work right now.
    var activeAuthenticatedBrowseSession: AuthenticatedBrowseSessionContext? {
        authenticatedBrowseSession(for: activeBackend)
    }

    /// Publish a complete Plex browse lane as one authority transition. Property observation may
    /// still report the individual display fields, but no repository context minted after this
    /// synchronous method returns can combine old credentials with a new server (or vice versa).
    func applyPlexBrowseSession(accountToken: String,
                                servers: [PlexDevice],
                                selectedServer: PlexDevice,
                                serverToken: String,
                                baseURL: URL,
                                isLocal: Bool,
                                accountProfile: PlexAccountProfile?) {
        withCoherentBrowseAuthorityMutation {
            token = accountToken
            plexServers = servers
            self.selectedServer = selectedServer
            self.serverToken = serverToken
            serverBaseURL = baseURL
            selectedServerConnectionIsLocal = isLocal
            plexAccountProfile = accountProfile
        }
    }

    /// Replace only the resolved Plex resource while retaining the authenticated account.
    func applySelectedPlexServer(_ server: PlexDevice,
                                 serverToken: String,
                                 baseURL: URL,
                                 isLocal: Bool) {
        withCoherentBrowseAuthorityMutation {
            selectedServer = server
            self.serverToken = serverToken
            serverBaseURL = baseURL
            selectedServerConnectionIsLocal = isLocal
        }
    }

    func clearResolvedPlexBrowseSession() {
        withCoherentBrowseAuthorityMutation {
            serverToken = nil
            selectedServer = nil
            plexServers = []
            serverBaseURL = nil
            selectedServerConnectionIsLocal = false
        }
    }

    func applyMediaBrowserSession(backend: MediaBackendKind,
                                  server: URL,
                                  token: String,
                                  userID: String,
                                  serverID: String?) {
        precondition(backend != .plex, "Use applyPlexBrowseSession for Plex")
        withCoherentBrowseAuthorityMutation {
            switch backend {
            case .jellyfin:
                jellyfinServerBaseURL = server
                jellyfinAccessToken = token
                jellyfinUserID = userID
                jellyfinServerID = serverID
            case .emby:
                embyServerBaseURL = server
                embyAccessToken = token
                embyUserID = userID
                embyServerID = serverID
            case .plex:
                preconditionFailure("Use applyPlexBrowseSession for Plex")
            }
        }
    }

    func clearBrowseSession(for backend: MediaBackendKind) {
        withCoherentBrowseAuthorityMutation {
            switch backend {
            case .plex:
                token = nil
                serverToken = nil
                selectedServer = nil
                plexServers = []
                serverBaseURL = nil
                selectedServerConnectionIsLocal = false
                plexAccountProfile = nil
            case .jellyfin:
                jellyfinServerBaseURL = nil
                jellyfinAccessToken = nil
                jellyfinUserID = nil
                jellyfinServerID = nil
            case .emby:
                embyServerBaseURL = nil
                embyAccessToken = nil
                embyUserID = nil
                embyServerID = nil
            }
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

    func stableServerUserKey(for kind: MediaBackendKind) -> String? {
        let input = sessionIdentityInput(for: kind)
        return SessionIdentity.stableServerUserKey(backend: kind.backendChoice,
                                                   serverID: input.serverID,
                                                   baseURL: input.baseURL,
                                                   userID: input.userID)
    }

    func browseSessionKey(for kind: MediaBackendKind) -> String {
        let input = sessionIdentityInput(for: kind)
        return SessionIdentity.browseSessionKey(backend: kind.backendChoice,
                                                serverID: input.serverID,
                                                baseURL: input.baseURL,
                                                userID: input.userID,
                                                authRevision: input.authRevision)
    }

    /// Process-local credential generation for async work that must reject a result minted before
    /// a same-server sign-out/sign-in or token replacement. The credential itself stays in the
    /// accompanying `BackendSession`; this counter is safe to compare and log.
    func authSessionRevision(for kind: MediaBackendKind) -> Int {
        sessionIdentityInput(for: kind).authRevision
    }

    private func browseAuthority(for kind: MediaBackendKind) -> BrowseSessionAuthority {
        switch kind {
        case .plex: plexBrowseAuthority
        case .jellyfin: jellyfinBrowseAuthority
        case .emby: embyBrowseAuthority
        }
    }

    private func withCoherentBrowseAuthorityMutation(_ mutation: () -> Void) {
        browseAuthorityMutationDepth += 1
        mutation()
        browseAuthorityMutationDepth -= 1
        guard browseAuthorityMutationDepth == 0, !pendingBrowseAuthorityChanges.isEmpty else { return }
        let changed = pendingBrowseAuthorityChanges
        pendingBrowseAuthorityChanges.removeAll(keepingCapacity: true)
        invalidateBrowseAuthorities(for: changed)
    }

    private func noteBrowseAuthorityChange(for kind: MediaBackendKind) {
        guard browseAuthorityMutationDepth == 0 else {
            pendingBrowseAuthorityChanges.insert(kind)
            return
        }
        invalidateBrowseAuthorities(for: [kind])
    }

    private func invalidateBrowseAuthorities(for kinds: Set<MediaBackendKind>) {
        for kind in kinds {
            switch kind {
            case .plex:
                plexBrowseAuthority = BrowseSessionAuthority()
            case .jellyfin:
                jellyfinBrowseAuthority = BrowseSessionAuthority()
            case .emby:
                embyBrowseAuthority = BrowseSessionAuthority()
            }
        }
    }

    private func sessionIdentityInput(for kind: MediaBackendKind) -> (serverID: String?,
                                                                      baseURL: URL?,
                                                                      userID: String?,
                                                                      authRevision: Int) {
        switch kind {
        case .plex:
            return (selectedServer?.clientIdentifier,
                    serverBaseURL,
                    plexAccountProfile?.stableUserID,
                    plexAuthSessionRevision)
        case .jellyfin:
            return (jellyfinServerID,
                    jellyfinServerBaseURL,
                    jellyfinUserID,
                    jellyfinAuthSessionRevision)
        case .emby:
            return (embyServerID,
                    embyServerBaseURL,
                    embyUserID,
                    embyAuthSessionRevision)
        }
    }
}

extension MediaBackendKind {
    var downloadBackendKind: DownloadBackendKind {
        self
    }

    /// Bridge to PMSKit's backend enum (used by the pure backend-resolution helpers, #100).
    var backendChoice: MediaBackendChoice {
        self
    }

    init(_ choice: MediaBackendChoice) {
        self = choice
    }
}
