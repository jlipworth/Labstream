import Foundation
import Observation
import PMSKit

/// Drives the Plex PIN-OAuth login flow and persists the result.
///
/// Flow:
///   1. `createPin()` — POST /pins, returns the 4-char code + the auth URL to open.
///   2. The UI opens `authAppURL` (Safari / web auth) so the user signs in.
///   3. `pollForToken()` — GET /pins/<id> every second until `authToken` arrives.
///   4. On token: persist to Keychain, set `AppModel.token`, run discovery, pick
///      the best connection, and set `AppModel.selectedServer` / `serverBaseURL`.
///
/// A 401 anywhere in the app should call `signOut()` to clear state and return
/// to login.
@MainActor
@Observable
final class AuthManager {
    enum State: Equatable {
        case idle
        case awaitingAuthorization(code: String, url: URL)
        case awaitingJellyfinQuickConnect(code: String)
        case awaitingEmbyConnectPin(code: String)
        case awaitingEmbyServerSelection(servers: [EmbyConnectServerChoice])
        case authenticated
        case failed(String)
    }

    /// One linked server shown to the user when an Emby Connect account has more than one.
    /// Carries only display data + an opaque selection id (the stable `SystemId` when Emby
    /// supplies one). The Connect token and per-server access key stay in `AuthManager`
    /// and are never surfaced or logged.
    struct EmbyConnectServerChoice: Equatable, Identifiable, Sendable {
        let id: String
        let name: String
        let addressLabel: String
    }

    private(set) var state: State = .idle

    private let appModel: AppModel
    private let keychain: KeychainStore
    private let authDataLoader: (URLRequest) async throws -> (Data, URLResponse)
    private let plexSessionDiscoverer: ((String) async throws -> PlexSessionDiscovery)?
    private let plexConnectionResolver: (([PlexConnection], String, String?) async -> (url: URL, isLocal: Bool)?)?
    private let plexProfileLoader: ((String) async -> PlexAccountProfile?)?
    private let authNow: () -> ContinuousClock.Instant
    private let authSleep: (Duration) async throws -> Void

    /// App-lifetime collaborators that must stop credential-bearing work before this manager
    /// clears the active backend's runtime session. The callback carries only the backend kind;
    /// it must never receive credentials. `AppRuntime` wires the download manager here.
    @ObservationIgnored var onBackendWillSignOut: ((MediaBackendKind) -> Void)?

    /// Poll cadence and ceiling for the PIN flow.
    private let pollInterval: Duration = .seconds(1)
    private let pollTimeout: Duration = .seconds(300)
    /// Jellyfin's SDK guidance recommends refreshing Quick Connect state about
    /// every 5 seconds while the user authorizes the displayed code.
    private let jellyfinQuickConnectPollInterval: Duration = .seconds(5)
    private let jellyfinQuickConnectPollTimeout: Duration = .seconds(300)
    /// Emby Connect PIN poll cadence and ceiling (matches Emby's own TV clients: ~5s).
    private let embyConnectPollInterval: Duration = .seconds(5)
    private let embyConnectPollTimeout: Duration = .seconds(300)
    private var pollTask: Task<Void, Never>?
    /// PINs being polled for the current login attempt (#16): the non-strong
    /// "link" PIN (its 4-char code is shown for plex.tv/link) and the strong
    /// PIN (its long code backs the on-device web-auth URL). Whichever the
    /// user completes authorizes first; both clear when the attempt ends.
    private var activePinIDs: Set<Int> = []
    private var activeAuthAttempt: AuthAttempt?
    private var plexSessionGeneration = UUID()
    /// Current Emby Connect attempt and the cloud session it produced. `pendingEmbyConnect`
    /// holds the Connect user id + linked-server list (incl. per-server access keys) while the
    /// user picks a server; it is in-memory only and cleared when the attempt ends.
    private var embyConnectServerSelections = EmbyConnectServerSelectionTracker()
    private var pendingEmbyConnect: PendingEmbyConnect?

    init(appModel: AppModel,
         keychain: KeychainStore = KeychainStore(),
         authDataLoader: ((URLRequest) async throws -> (Data, URLResponse))? = nil,
         plexSessionDiscoverer: ((String) async throws -> PlexSessionDiscovery)? = nil,
         plexConnectionResolver: (([PlexConnection], String, String?) async -> (url: URL, isLocal: Bool)?)? = nil,
         plexProfileLoader: ((String) async -> PlexAccountProfile?)? = nil,
         authNow: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
         authSleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.appModel = appModel
        self.keychain = keychain
        self.authDataLoader = authDataLoader ?? { request in
            try await AuthManager.mediaBrowserAuthSession.data(for: request)
        }
        self.plexSessionDiscoverer = plexSessionDiscoverer
        self.plexConnectionResolver = plexConnectionResolver
        self.plexProfileLoader = plexProfileLoader
        self.authNow = authNow
        self.authSleep = authSleep
    }

    @discardableResult
    func selectBackend(_ backend: MediaBackendKind) -> Bool {
        cancelPendingLogin()
        guard keychain.saveSelectedBackend(backend) else {
            state = .failed("Couldn’t securely save the selected backend.")
            return false
        }
        appModel.activeBackend = backend
        state = .idle
        // The Spotlight domain is shared across backends and system-entry routing only
        // resolves against the ACTIVE backend, so entries indexed under the previous
        // backend would surface as dead taps. Drop them; the new backend re-indexes as
        // the user browses.
        SpotlightIndexer.deleteAll()
        return true
    }

    func switchBackend(_ backend: MediaBackendKind) async {
        let resolution = MediaBackendSwitch.resolve(active: appModel.activeBackend.switchChoice,
                                                    target: backend.switchChoice,
                                                    credentials: keychain.mediaBackendCredentialSnapshot)
        guard resolution != .alreadyActive else { return }

        cancelPendingLogin()
        guard keychain.saveSelectedBackend(backend) else {
            state = .failed("Couldn’t securely save the selected backend.")
            return
        }
        appModel.activeBackend = backend
        // Same stale-entry sweep as `selectBackend` — routing rejects the old backend's
        // Spotlight results the moment the active backend changes.
        SpotlightIndexer.deleteAll()

        // The guard above already returned for `.alreadyActive`, so only the two
        // session-transition cases reach here at runtime. The `.alreadyActive` arm
        // is retained solely to keep this switch exhaustive.
        switch resolution {
        case .alreadyActive:
            break
        case .restoreSavedSession:
            appModel.isSwitchingBackend = true
            defer { appModel.isSwitchingBackend = false }
            _ = await restoreSession()
        case .requireLogin:
            clearRuntimeState(for: backend)
            appModel.isSwitchingBackend = false
            state = .idle
        }
    }

    /// Restore saved sessions at launch/switch time.
    ///
    /// The selected backend is still restored as the user-facing lane (and drives `state`), but
    /// download orchestration can now need credentials for OTHER saved lanes at the same time
    /// (#84: e.g. a Plex optimize row plus a Jellyfin transcode row after relaunch). Hydrate those
    /// inactive lanes too so `AppModel.backendSession(for:)` is not limited to the currently
    /// selected backend.
    @discardableResult
    func restoreSession() async -> Bool {
        cancelPendingLogin()
        let attemptID = beginAuthAttempt(.sessionRestore)
        defer { cleanupCancelledAuthAttempt(attemptID) }
        let selected = keychain.selectedBackend
        appModel.activeBackend = selected

        let selectedRestored: Bool
        switch selected {
        case .plex:
            selectedRestored = await restorePlexSession(updateState: true, attemptID: attemptID)
        case .jellyfin:
            selectedRestored = await restoreJellyfinSession(validateReachability: true, updateState: true, attemptID: attemptID)
        case .emby:
            selectedRestored = await restoreEmbySession(validateReachability: true, updateState: true, attemptID: attemptID)
        }

        guard isCurrentAuthAttempt(attemptID) else { return false }
        await restoreInactiveBackendSessions(excluding: selected, attemptID: attemptID)
        guard isCurrentAuthAttempt(attemptID) else { return false }
        finishAuthAttempt(attemptID)
        return selectedRestored
    }

    /// Background/system entry points may need to restore before a scene connects, but must not
    /// steal the unified auth authority from a login code the user is actively completing.
    /// Returning `nil` means admission was declined and leaves that attempt untouched; the caller
    /// can keep waiting for it. A non-nil value is the admitted restore's ordinary success result.
    @discardableResult
    func restoreSessionIfNoAuthorizationInProgress() async -> Bool? {
        guard activeAuthAttempt == nil else { return nil }
        return await restoreSession()
    }

    /// Hydrate non-selected backend lanes for downloads without taking over the UI state. Jellyfin
    /// and Emby can restore directly from their saved base URL + token + user id; Plex still needs
    /// discovery to recover the current PMS connection and server-scoped token.
    private func restoreInactiveBackendSessions(excluding selected: MediaBackendKind,
                                                attemptID: AuthAttemptID) async {
        for backend in MediaBackendKind.allCases where backend != selected {
            guard isCurrentAuthAttempt(attemptID) else { return }
            switch backend {
            case .plex:
                // Plex hydration is expensive (resource enumeration + per-connection probing).
                // `restoreSession()` runs on every backend switch, so re-discovering PMS each time
                // the user toggles Jellyfin↔Emby is wasted work. The Plex lane stays live for the
                // app's lifetime once hydrated, so only discover when it isn't already connected.
                if appModel.selectedServer == nil || appModel.serverBaseURL == nil {
                    _ = await restorePlexSession(updateState: false, attemptID: attemptID)
                }
            case .jellyfin:
                _ = await restoreJellyfinSession(validateReachability: false, updateState: false, attemptID: attemptID)
            case .emby:
                _ = await restoreEmbySession(validateReachability: false, updateState: false, attemptID: attemptID)
            }
        }
    }

    private func restorePlexSession(updateState: Bool = true, attemptID: AuthAttemptID) async -> Bool {
        let restoreFields: [String: DiagnosticFieldValue] = [
            "update_state": .bool(updateState)
        ]
        guard let saved = keychain.token else {
            // A background URLSession task can outlive the process that performed sign-out.
            // Keychain is the durable authority at restore time: no saved token means any
            // surviving Plex task must be parked before it can keep streaming a retired request.
            onBackendWillSignOut?(.plex)
            recordAuthDiagnostic("auth.plex.restore.missing_token", fields: restoreFields)
            return false
        }
        // A saved account token is a valid authenticated milestone even before a PMS connection
        // is resolved. Publish it before suspension so discovery failure reaches the signed-in
        // Retry UI instead of presenting a fresh-login screen.
        appModel.token = saved
        clearResolvedPlexServerState()
        recordAuthDiagnostic("auth.plex.restore.start", fields: restoreFields)
        do {
            let discovery = try await loadPlexSessionDiscovery(token: saved, attemptID: attemptID)
            guard isCurrentAuthAttempt(attemptID) else { return false }
            // The account token is already durable. A transient inability to update the preferred
            // server must not invalidate an otherwise healthy restored session.
            if !keychain.saveSelectedPlexServerID(discovery.selectedServer.clientIdentifier) {
                recordAuthDiagnostic("auth.plex.restore.preferred_server_write_failed",
                                     fields: restoreFields)
            }
            applyPlexSession(discovery, token: saved)
            if updateState { state = .authenticated }
            recordAuthDiagnostic("auth.plex.restore.success", fields: restoreFields)
            return true
        } catch PlexError.unauthorized {
            guard isCurrentAuthAttempt(attemptID) else { return false }
            // Only wipe the Plex lane when it is the ACTIVE, user-facing backend. On the inactive
            // hydration path (a JF/Emby session warming Plex for cross-backend downloads), a transient
            // discovery 401 must NOT silently sign the user out of Plex — leave the saved token in
            // place and let the lane stay unhydrated until they switch back, where `updateState: true`
            // handles a genuine sign-out with the proper UI teardown.
            recordAuthDiagnostic("auth.plex.restore.unauthorized", fields: restoreFields)
            guard updateState else { return false }
            SpotlightIndexer.deleteAll()
            appModel.isSwitchingBackend = false
            onBackendWillSignOut?(.plex)
            signOutPlex()
            state = .idle
            return false
        } catch {
            guard isCurrentAuthAttempt(attemptID) else { return false }
            var fields = restoreFields
            fields.merge(authErrorFields(error)) { _, new in new }
            recordAuthDiagnostic("auth.plex.restore.discovery_failed", fields: fields)
            if updateState { state = .failed("Signed in, but server discovery failed.") }
            return true
        }
    }

    private func restoreJellyfinSession(validateReachability: Bool = true,
                                        updateState: Bool = true,
                                        attemptID: AuthAttemptID) async -> Bool {
        guard let snapshot = readJellyfinSessionSnapshot() else {
            // The durable Jellyfin credential has already been removed (for example, a
            // sign-out immediately before process termination). Do not let a reattached
            // background request continue with the old header.
            onBackendWillSignOut?(.jellyfin)
            return false
        }
        guard validateReachability else {
            applyJellyfinSessionSnapshot(snapshot)
            return true
        }
        do {
            try await validateJellyfinSession(server: snapshot.server,
                                              token: snapshot.token,
                                              expectedUserID: snapshot.userID)
            guard isCurrentAuthAttempt(attemptID) else { return false }
            applyJellyfinSessionSnapshot(snapshot)
            if updateState { state = .authenticated }
            return true
        } catch JellyfinAuthError.unauthorized {
            guard isCurrentAuthAttempt(attemptID) else { return false }
            NSLog("[#93] restoreJellyfinSession wiping creds: probe returned unauthorized (updateState=%@)",
                  updateState ? "true" : "false")
            onBackendWillSignOut?(.jellyfin)
            signOutJellyfin()
            if updateState { state = .idle }
            return false
        } catch JellyfinAuthError.identityMismatch {
            guard isCurrentAuthAttempt(attemptID) else { return false }
            // Ambiguous, not a proven-bad credential: the probe succeeded (2xx) but reported a
            // different user id. Preserve the keychain snapshot for a later retry (a true 401 is the
            // only wipe trigger), but clear the runtime lane so browse/download paths don't act on a
            // session the live probe did not confirm — same credential-preserving handling as the
            // generic transport-failure branch below.
            NSLog("[#93] restoreJellyfinSession preserving creds: probe user id mismatch (updateState=%@)",
                  updateState ? "true" : "false")
            clearRuntimeState(for: .jellyfin)
            if updateState { state = .failed("Signed in, but the Jellyfin session could not be confirmed.") }
            return true
        } catch {
            guard isCurrentAuthAttempt(attemptID) else { return false }
            // Preserve the keychain snapshot for a later retry, but do not leave the runtime lane
            // looking browse-ready when the live probe did not prove the session. Otherwise
            // ContentView/download/browse paths can act on a half-restored Jellyfin lane while the
            // user is trying to re-authenticate on a flaky network.
            clearRuntimeState(for: .jellyfin)
            if updateState { state = .failed("Signed in, but the Jellyfin server could not be reached.") }
            return true
        }
    }

    /// Validate the saved Jellyfin session with a live current-user identity probe.
    ///
    /// Only a 401 proves that the token is invalid. A 403 is an authorization/policy failure,
    /// not evidence of revocation, so it must preserve the credential just like availability
    /// and server errors. This keeps a restricted library or reverse proxy from signing users out.
    private func validateJellyfinSession(server: URL, token: String, expectedUserID: String) async throws {
        let request = JellyfinAuth.currentUserRequest(server: server, token: token, identity: jellyfinIdentity)
        let (data, response) = try await authDataLoader(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        switch CredentialValidationPolicy.decision(httpStatus: status) {
        case .valid:
            let user = try JSONDecoder().decode(JellyfinAuthenticatedUser.self, from: data)
            // Compare GUID-format-insensitively (dashed/dashless, case) so a server or proxy that
            // re-serializes the same id doesn't read as a different user. A normalized MISMATCH on
            // an otherwise-valid 2xx probe is ambiguous (proxy/user remap), NOT proof the credential
            // is invalid — surface it as identity-mismatch so restore PRESERVES the credential.
            // Only a real 401 (`.invalidCredential`) wipes.
            guard MediaBrowserUserIdentity.sameUser(user.id, expectedUserID) else {
                throw JellyfinAuthError.identityMismatch
            }
        case .invalidCredential:
            throw JellyfinAuthError.unauthorized
        case .preserveCredential, .refreshExpiredCredential:
            throw JellyfinAuthError.http(status)
        }
    }

    private func readJellyfinSessionSnapshot() -> JellyfinSessionSnapshot? {
        guard let urlString = keychain.jellyfinServerURLString,
              let server = URL(string: urlString),
              let token = keychain.jellyfinAccessToken,
              let userID = keychain.jellyfinUserID else { return nil }
        return JellyfinSessionSnapshot(server: server,
                                       token: token,
                                       userID: userID,
                                       serverID: keychain.jellyfinServerID)
    }

    private func applyJellyfinSessionSnapshot(_ snapshot: JellyfinSessionSnapshot) {
        appModel.applyMediaBrowserSession(backend: .jellyfin,
                                          server: snapshot.server,
                                          token: snapshot.token,
                                          userID: snapshot.userID,
                                          serverID: snapshot.serverID)
    }

    private func restoreEmbySession(validateReachability: Bool = true,
                                    updateState: Bool = true,
                                    attemptID: AuthAttemptID) async -> Bool {
        let restoreFields: [String: DiagnosticFieldValue] = [
            "validate_reachability": .bool(validateReachability),
            "update_state": .bool(updateState)
        ]
        guard let snapshot = readEmbySessionSnapshot() else {
            // See the matching Jellyfin case: a background task may have survived a prior
            // process while secure storage records that the account is signed out.
            onBackendWillSignOut?(.emby)
            recordAuthDiagnostic("auth.emby.restore.missing_snapshot", fields: restoreFields)
            return false
        }
        guard validateReachability else {
            applyEmbySessionSnapshot(snapshot)
            recordAuthDiagnostic("auth.emby.restore.snapshot_loaded", fields: restoreFields)
            return true
        }
        recordAuthDiagnostic("auth.emby.restore.start", fields: restoreFields)
        do {
            let req = try EmbyAuth.currentUserRequest(server: snapshot.server,
                                                      token: snapshot.token,
                                                      identity: embyIdentity,
                                                      userId: snapshot.userID)
            let (data, response) = try await authDataLoader(req)
            if let http = response as? HTTPURLResponse {
                switch CredentialValidationPolicy.decision(httpStatus: http.statusCode) {
                case .valid: break
                case .invalidCredential: throw EmbyAuthError.unauthorized
                case .preserveCredential, .refreshExpiredCredential:
                    throw EmbyAuthError.http(http.statusCode)
                }
            }
            guard isCurrentAuthAttempt(attemptID) else { return false }
            let user = try JSONDecoder().decode(EmbyAuthenticatedUser.self, from: data)
            // GUID-format-insensitive compare for parity with Jellyfin restore. The Emby probe is
            // /Users/{id}, which echoes the requested id, so a mismatch here is not expected.
            guard MediaBrowserUserIdentity.sameUser(user.id, snapshot.userID) else {
                throw EmbyAuthError.unauthorized
            }
            applyEmbySessionSnapshot(snapshot)
            if updateState { state = .authenticated }
            recordAuthDiagnostic("auth.emby.restore.success", fields: restoreFields)
            return true
        } catch EmbyAuthError.unauthorized {
            guard isCurrentAuthAttempt(attemptID) else { return false }
            // Invalid/expired creds — drop the saved session and require re-login.
            onBackendWillSignOut?(.emby)
            signOutEmby()
            if updateState { state = .idle }
            recordAuthDiagnostic("auth.emby.restore.unauthorized", fields: restoreFields)
            return false
        } catch {
            guard isCurrentAuthAttempt(attemptID) else { return false }
            // Unreachable host (or other transient error) — keep the saved session so a
            // later launch with connectivity restores cleanly, but clear the runtime lane so
            // `isBrowseReady`/`backendSession(for:)` do not expose an unproven Emby session.
            clearRuntimeState(for: .emby)
            if updateState { state = .failed("Signed in, but the Emby server could not be reached.") }
            var fields = restoreFields
            if case EmbyAuthError.http(let status) = error {
                fields["status"] = .int(status)
                recordAuthDiagnostic("auth.emby.restore.http", fields: fields)
            } else {
                fields.merge(authErrorFields(error)) { _, new in new }
                recordAuthDiagnostic("auth.emby.restore.transport", fields: fields)
            }
            return true
        }
    }

    private func readEmbySessionSnapshot() -> EmbySessionSnapshot? {
        guard let urlString = keychain.embyServerURLString,
              let server = URL(string: urlString),
              let token = keychain.embyAccessToken,
              let userID = keychain.embyUserID else { return nil }
        return EmbySessionSnapshot(server: server,
                                   token: token,
                                   userID: userID,
                                   serverID: keychain.embyServerID)
    }

    private func applyEmbySessionSnapshot(_ snapshot: EmbySessionSnapshot) {
        appModel.applyMediaBrowserSession(backend: .emby,
                                          server: snapshot.server,
                                          token: snapshot.token,
                                          userID: snapshot.userID,
                                          serverID: snapshot.serverID)
    }

    /// Start a fresh login. Creates TWO PINs (#16): a non-strong one whose
    /// 4-character code the UI displays for plex.tv/link, and a strong one whose
    /// long code backs the `app.plex.tv/auth` web URL (a strong code cannot be
    /// typed at plex.tv/link, and the auth web page needs the strong one).
    /// Both are polled; whichever the user completes wins.
    /// Returns the URL the UI should present for the on-device browser path.
    func createPin() async throws -> URL {
        guard selectBackend(.plex) else { throw AuthCoordinationError.secureStorageFailed }
        cancelPendingLogin()
        let attemptID = beginAuthAttempt(.plexPIN)
        defer { cleanupCancelledAuthAttempt(attemptID) }
        async let linkReq = appModel.client.send(
            PinAuth.createPinRequest(identity: appModel.identity, strong: false),
            as: PinResponse.self)
        async let strongReq = appModel.client.send(
            PinAuth.createPinRequest(identity: appModel.identity, strong: true),
            as: PinResponse.self)
        let (linkPin, strongPin): (PinResponse, PinResponse)
        do {
            (linkPin, strongPin) = try await (linkReq, strongReq)
        } catch {
            finishAuthAttempt(attemptID)
            throw error
        }
        guard isCurrentAuthAttempt(attemptID) else { throw CancellationError() }

        let authURL = PinAuth.authAppURL(code: strongPin.code, identity: appModel.identity)
        activePinIDs = [linkPin.id, strongPin.id]
        state = .awaitingAuthorization(code: linkPin.code, url: authURL)

        // Kick off polling in the background; UI observes `state`.
        let ids = activePinIDs
        pollTask = Task { await pollForToken(pinIDs: ids, attemptID: attemptID) }
        return authURL
    }

    /// Poll the attempt's PINs until one carries an `authToken` or we time out.
    private func pollForToken(pinIDs: Set<Int>, attemptID: AuthAttemptID) async {
        let deadline = authNow().advanced(by: pollTimeout)
        while authNow() < deadline {
            try? await authSleep(pollInterval)
            if Task.isCancelled { return }
            guard activePinIDs == pinIDs, isCurrentAuthAttempt(attemptID) else { return }

            for pinID in pinIDs {
                let pollReq = PinAuth.pollPinRequest(pinID: pinID, identity: appModel.identity)
                do {
                    let poll = try await appModel.client.send(pollReq, as: PinPollResponse.self)
                    guard isCurrentAuthAttempt(attemptID) else { return }
                    if let token = poll.authToken, !token.isEmpty {
                        await finishLogin(token: token, attemptID: attemptID)
                        return
                    }
                } catch {
                    guard isCurrentAuthAttempt(attemptID) else { return }
                    // Transient errors are expected while the user is still authorizing;
                    // keep polling until the deadline.
                    continue
                }
            }
        }
        guard activePinIDs == pinIDs, isCurrentAuthAttempt(attemptID) else { return }
        activePinIDs = []
        pollTask = nil
        finishAuthAttempt(attemptID)
        state = .failed("Authorization timed out.")
    }

    /// Persist the token, update the model, and discover servers.
    private func finishLogin(token: String, attemptID: AuthAttemptID) async {
        guard isCurrentAuthAttempt(attemptID) else { return }
        // Authorization and server discovery are separate milestones. Preserve the account token
        // as soon as Plex authorizes the PIN so a transient discovery outage exposes Retry rather
        // than throwing away a sign-in the user just completed.
        guard keychain.saveToken(token) else {
            activePinIDs = []
            pollTask = nil
            finishAuthAttempt(attemptID)
            state = .failed("Couldn’t securely save the Plex session.")
            return
        }
        appModel.token = token
        do {
            let discovery = try await loadPlexSessionDiscovery(token: token, attemptID: attemptID)
            guard isCurrentAuthAttempt(attemptID) else { return }
            if !keychain.saveSelectedPlexServerID(discovery.selectedServer.clientIdentifier) {
                recordAuthDiagnostic("auth.plex.login.preferred_server_write_failed")
            }
            applyPlexSession(discovery, token: token)
            activePinIDs = []
            pollTask = nil
            finishAuthAttempt(attemptID)
            state = .authenticated
        } catch {
            guard isCurrentAuthAttempt(attemptID) else { return }
            activePinIDs = []
            pollTask = nil
            finishAuthAttempt(attemptID)
            state = .failed("Signed in, but server discovery failed.")
        }
    }

    func loginToJellyfin(server: URL, username: String, password: String) async {
        cancelPendingLogin()
        guard keychain.saveSelectedBackend(.jellyfin) else {
            state = .failed("Couldn’t securely save the selected backend.")
            return
        }
        let attemptID = beginAuthAttempt(.jellyfinCredentials)
        defer { cleanupCancelledAuthAttempt(attemptID) }
        appModel.activeBackend = .jellyfin
        state = .idle
        do {
            let request = try JellyfinAuth.authenticateByNameRequest(server: server,
                                                                    username: username,
                                                                    password: password,
                                                                    identity: jellyfinIdentity)
            let (data, response) = try await authDataLoader(request)
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200..<300:
                    break
                case 401, 403:
                    throw JellyfinAuthError.unauthorized
                default:
                    throw JellyfinAuthError.http(http.statusCode)
                }
            }
            let result = try JSONDecoder().decode(JellyfinAuthenticationResult.self, from: data)
            guard isCurrentAuthAttempt(attemptID) else { return }
            try persistJellyfinAuthentication(result, server: server)
            finishAuthAttempt(attemptID)
            state = .authenticated
        } catch JellyfinAuthError.unauthorized {
            guard isCurrentAuthAttempt(attemptID) else { return }
            finishAuthAttempt(attemptID)
            state = .failed("Invalid Jellyfin username or password.")
        } catch JellyfinAuthError.http(let status) {
            guard isCurrentAuthAttempt(attemptID) else { return }
            finishAuthAttempt(attemptID)
            state = .failed("Jellyfin sign-in failed (HTTP \(status)).")
        } catch JellyfinAuthError.missingCredentials {
            guard isCurrentAuthAttempt(attemptID) else { return }
            finishAuthAttempt(attemptID)
            state = .failed("Jellyfin did not return a usable session.")
        } catch JellyfinAuthError.secureStorageFailed {
            guard isCurrentAuthAttempt(attemptID) else { return }
            finishAuthAttempt(attemptID)
            state = .failed("Couldn’t securely save the Jellyfin session.")
        } catch {
            guard isCurrentAuthAttempt(attemptID) else { return }
            finishAuthAttempt(attemptID)
            state = .failed("Couldn’t reach Jellyfin server.")
        }
    }

    func startJellyfinQuickConnect(server: URL) async {
        cancelPendingLogin()
        guard keychain.saveSelectedBackend(.jellyfin) else {
            state = .failed("Couldn’t securely save the selected backend.")
            return
        }
        let attemptID = beginAuthAttempt(.jellyfinQuickConnect)
        defer { cleanupCancelledAuthAttempt(attemptID) }
        appModel.activeBackend = .jellyfin
        state = .idle

        do {
            if let enabled = try await jellyfinQuickConnectEnabled(server: server), enabled == false {
                guard isCurrentAuthAttempt(attemptID) else { return }
                finishAuthAttempt(attemptID)
                state = .failed("Jellyfin Quick Connect is disabled on this server. Use username and password instead.")
                return
            }
            guard isCurrentAuthAttempt(attemptID) else { return }

            let request = JellyfinAuth.initiateQuickConnectRequest(server: server,
                                                                   identity: jellyfinIdentity)
            let data = try await jellyfinData(for: request, disabledMeansUnauthorized: true)
            guard isCurrentAuthAttempt(attemptID) else { return }
            let result = try JSONDecoder().decode(JellyfinQuickConnectResult.self, from: data)
            guard let code = result.code, !code.isEmpty,
                  let secret = result.secret, !secret.isEmpty else {
                throw JellyfinAuthError.missingCredentials
            }

            guard isCurrentAuthAttempt(attemptID) else { return }
            state = .awaitingJellyfinQuickConnect(code: code)
            pollTask = Task { await pollJellyfinQuickConnect(server: server,
                                                             secret: secret,
                                                             attemptID: attemptID) }
        } catch JellyfinAuthError.quickConnectDisabled {
            guard isCurrentAuthAttempt(attemptID) else { return }
            finishAuthAttempt(attemptID)
            state = .failed("Jellyfin Quick Connect is disabled on this server. Use username and password instead.")
        } catch JellyfinAuthError.unauthorized {
            guard isCurrentAuthAttempt(attemptID) else { return }
            finishAuthAttempt(attemptID)
            state = .failed("Jellyfin Quick Connect is disabled on this server. Use username and password instead.")
        } catch JellyfinAuthError.http(let status) {
            guard isCurrentAuthAttempt(attemptID) else { return }
            finishAuthAttempt(attemptID)
            state = .failed("Jellyfin Quick Connect failed (HTTP \(status)).")
        } catch JellyfinAuthError.missingCredentials {
            guard isCurrentAuthAttempt(attemptID) else { return }
            finishAuthAttempt(attemptID)
            state = .failed("Jellyfin did not return a Quick Connect code. Use username and password instead.")
        } catch {
            guard isCurrentAuthAttempt(attemptID) else { return }
            finishAuthAttempt(attemptID)
            state = .failed("Couldn’t reach Jellyfin server.")
        }
    }

    func cancelCurrentAuthorization() {
        cancelPendingLogin()
        state = .idle
    }

    private func jellyfinQuickConnectEnabled(server: URL) async throws -> Bool? {
        let request = JellyfinAuth.quickConnectEnabledRequest(server: server,
                                                              identity: jellyfinIdentity)
        let data = try await jellyfinData(for: request, disabledMeansUnauthorized: false)
        return try JSONDecoder().decode(Bool.self, from: data)
    }

    private func pollJellyfinQuickConnect(server: URL, secret: String, attemptID: UUID) async {
        let deadline = authNow().advanced(by: jellyfinQuickConnectPollTimeout)
        while authNow() < deadline {
            try? await authSleep(jellyfinQuickConnectPollInterval)
            if Task.isCancelled { return }
            guard isCurrentAuthAttempt(attemptID) else { return }

            do {
                let request = try JellyfinAuth.quickConnectStateRequest(server: server,
                                                                        secret: secret,
                                                                        identity: jellyfinIdentity)
                let data = try await jellyfinData(for: request, disabledMeansUnauthorized: false)
                guard isCurrentAuthAttempt(attemptID) else { return }
                let result = try JSONDecoder().decode(JellyfinQuickConnectResult.self, from: data)
                guard result.authenticated else { continue }
                do {
                    try await finishJellyfinQuickConnect(server: server, secret: secret, attemptID: attemptID)
                } catch JellyfinAuthError.http(let status) {
                    guard isCurrentAuthAttempt(attemptID) else { return }
                    finishAuthAttempt(attemptID)
                    pollTask = nil
                    state = .failed("Jellyfin Quick Connect sign-in failed (HTTP \(status)). Use username and password instead.")
                } catch JellyfinAuthError.missingCredentials {
                    guard isCurrentAuthAttempt(attemptID) else { return }
                    finishAuthAttempt(attemptID)
                    pollTask = nil
                    state = .failed("Jellyfin did not return a usable session. Use username and password instead.")
                } catch JellyfinAuthError.secureStorageFailed {
                    guard isCurrentAuthAttempt(attemptID) else { return }
                    finishAuthAttempt(attemptID)
                    pollTask = nil
                    state = .failed("Couldn’t securely save the Jellyfin session.")
                } catch {
                    guard isCurrentAuthAttempt(attemptID) else { return }
                    finishAuthAttempt(attemptID)
                    pollTask = nil
                    state = .failed("Jellyfin Quick Connect sign-in failed. Use username and password instead.")
                }
                return
            } catch JellyfinAuthError.http(404) {
                guard isCurrentAuthAttempt(attemptID) else { return }
                finishAuthAttempt(attemptID)
                pollTask = nil
                state = .failed("Jellyfin Quick Connect code expired or was cancelled. Try again or use username and password.")
                return
            } catch {
                // Transient network/server errors can happen while the user is
                // still authorizing. Keep polling until the deadline.
                continue
            }
        }

        guard isCurrentAuthAttempt(attemptID) else { return }
        finishAuthAttempt(attemptID)
        pollTask = nil
        state = .failed("Jellyfin Quick Connect timed out. Try again or use username and password.")
    }

    private func finishJellyfinQuickConnect(server: URL, secret: String, attemptID: UUID) async throws {
        guard isCurrentAuthAttempt(attemptID) else { return }
        let request = try JellyfinAuth.authenticateWithQuickConnectRequest(server: server,
                                                                          secret: secret,
                                                                          identity: jellyfinIdentity)
        let data = try await jellyfinData(for: request, disabledMeansUnauthorized: false)
        let result = try JSONDecoder().decode(JellyfinAuthenticationResult.self, from: data)
        guard isCurrentAuthAttempt(attemptID) else { return }
        try persistJellyfinAuthentication(result, server: server)
        finishAuthAttempt(attemptID)
        pollTask = nil
        state = .authenticated
    }

    private func persistJellyfinAuthentication(_ result: JellyfinAuthenticationResult, server: URL) throws {
        guard let token = result.accessToken, !token.isEmpty,
              let userID = result.user?.id, !userID.isEmpty else {
            throw JellyfinAuthError.missingCredentials
        }
        guard keychain.saveJellyfinSession(serverURLString: server.absoluteString,
                                            accessToken: token,
                                            userID: userID,
                                            serverID: result.serverId) else {
            throw JellyfinAuthError.secureStorageFailed
        }
        appModel.applyMediaBrowserSession(backend: .jellyfin,
                                          server: server,
                                          token: token,
                                          userID: userID,
                                          serverID: result.serverId)
    }

    /// Emby username/password sign-in (NO Quick Connect — slice 1 is password-only).
    /// Mirrors `loginToJellyfin` but uses the Emby-specific auth/header lane.
    func loginToEmby(server: URL, username: String, password: String) async {
        cancelPendingLogin()
        guard keychain.saveSelectedBackend(.emby) else {
            state = .failed("Couldn’t securely save the selected backend.")
            return
        }
        let attemptID = beginAuthAttempt(.embyCredentials)
        defer { cleanupCancelledAuthAttempt(attemptID) }
        appModel.activeBackend = .emby
        state = .idle
        recordAuthDiagnostic("auth.emby.login.start")
        do {
            let request = try EmbyAuth.authenticateByNameRequest(server: server,
                                                                 username: username,
                                                                 password: password,
                                                                 identity: embyIdentity)
            let (data, response) = try await authDataLoader(request)
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200..<300:
                    break
                case 401, 403:
                    throw EmbyAuthError.unauthorized
                default:
                    throw EmbyAuthError.http(http.statusCode)
                }
            }
            let result = try JSONDecoder().decode(EmbyAuthenticationResult.self, from: data)
            guard isCurrentAuthAttempt(attemptID) else { return }
            try persistEmbyAuthentication(result, server: server)
            finishAuthAttempt(attemptID)
            state = .authenticated
            recordAuthDiagnostic("auth.emby.login.success")
        } catch EmbyAuthError.unauthorized {
            guard isCurrentAuthAttempt(attemptID) else { return }
            finishAuthAttempt(attemptID)
            recordAuthDiagnostic("auth.emby.login.unauthorized")
            state = .failed("Invalid Emby username or password.")
        } catch EmbyAuthError.http(let status) {
            guard isCurrentAuthAttempt(attemptID) else { return }
            finishAuthAttempt(attemptID)
            recordAuthDiagnostic("auth.emby.login.http", fields: ["status": .int(status)])
            state = .failed("Emby sign-in failed (HTTP \(status)).")
        } catch EmbyAuthError.missingCredentials {
            guard isCurrentAuthAttempt(attemptID) else { return }
            finishAuthAttempt(attemptID)
            recordAuthDiagnostic("auth.emby.login.failed", fields: ["reason": .string("missing_credentials")])
            state = .failed("Emby did not return a usable session.")
        } catch EmbyAuthError.secureStorageFailed {
            guard isCurrentAuthAttempt(attemptID) else { return }
            finishAuthAttempt(attemptID)
            recordAuthDiagnostic("auth.emby.login.failed", fields: ["reason": .string("secure_storage")])
            state = .failed("Couldn’t securely save the Emby session.")
        } catch {
            guard isCurrentAuthAttempt(attemptID) else { return }
            finishAuthAttempt(attemptID)
            recordAuthDiagnostic("auth.emby.login.transport", fields: authErrorFields(error))
            state = .failed("Couldn’t reach Emby server.")
        }
    }

    private func persistEmbyAuthentication(_ result: EmbyAuthenticationResult, server: URL) throws {
        guard let token = result.accessToken, !token.isEmpty,
              let userID = result.user?.id, !userID.isEmpty else {
            throw EmbyAuthError.missingCredentials
        }
        try persistEmbySession(server: server, token: token, userID: userID, serverID: result.serverId)
    }

    /// Persist a resolved Emby server session to keychain + app model. Shared by the
    /// username/password path and the Emby Connect PIN path — once Connect exchange yields a
    /// normal per-server token, the saved session is identical, so restore/refresh is shared.
    private func persistEmbySession(server: URL, token: String, userID: String, serverID: String?) throws {
        guard keychain.saveEmbySession(serverURLString: server.absoluteString,
                                       accessToken: token,
                                       userID: userID,
                                       serverID: serverID) else {
            throw EmbyAuthError.secureStorageFailed
        }
        appModel.applyMediaBrowserSession(backend: .emby,
                                          server: server,
                                          token: token,
                                          userID: userID,
                                          serverID: serverID)
    }

    // MARK: - Emby Connect PIN sign-in (GH #72)

    /// Start the Emby Connect PIN flow: mint a short code, display it, and poll
    /// connect.emby.media until the user confirms it at emby.media/pin.html. Unlike the
    /// username/password path this needs no server URL — Connect discovers the linked
    /// servers itself. Mirrors `startJellyfinQuickConnect` but against Emby's cloud host.
    func startEmbyConnect() async {
        cancelPendingLogin()
        guard keychain.saveSelectedBackend(.emby) else {
            state = .failed("Couldn’t securely save the selected backend.")
            return
        }
        let attemptID = beginAuthAttempt(.embyConnect)
        defer { cleanupCancelledAuthAttempt(attemptID) }
        appModel.activeBackend = .emby
        state = .idle
        recordAuthDiagnostic("auth.emby_connect.start")

        do {
            let data = try await embyConnectData(for: EmbyConnect.createPinRequest(identity: embyIdentity))
            guard isCurrentAuthAttempt(attemptID) else { return }
            let pin = try JSONDecoder().decode(EmbyConnectPin.self, from: data)
            guard let code = pin.pin, !code.isEmpty else { throw EmbyAuthError.missingCredentials }

            guard isCurrentAuthAttempt(attemptID) else { return }
            recordAuthDiagnostic("auth.emby_connect.pin_created")
            state = .awaitingEmbyConnectPin(code: code)
            pollTask = Task { await pollEmbyConnectPin(pin: code, attemptID: attemptID) }
        } catch EmbyAuthError.http(let status) {
            guard isCurrentAuthAttempt(attemptID) else { return }
            finishAuthAttempt(attemptID)
            recordAuthDiagnostic("auth.emby_connect.start_http", fields: ["status": .int(status)])
            state = .failed("Emby Connect sign-in failed (HTTP \(status)).")
        } catch EmbyAuthError.missingCredentials {
            guard isCurrentAuthAttempt(attemptID) else { return }
            finishAuthAttempt(attemptID)
            recordAuthDiagnostic("auth.emby_connect.start_failed", fields: ["reason": .string("missing_pin")])
            state = .failed("Emby Connect did not return a code. Use a server URL instead.")
        } catch {
            guard isCurrentAuthAttempt(attemptID) else { return }
            finishAuthAttempt(attemptID)
            recordAuthDiagnostic("auth.emby_connect.start_transport", fields: authErrorFields(error))
            state = .failed("Couldn’t reach Emby Connect.")
        }
    }

    /// Resume the flow after the user picks one of several linked servers.
    func selectEmbyConnectServer(id: String) async {
        guard let attemptID = currentAuthAttemptID(for: .embyConnect),
              let pending = pendingEmbyConnect,
              let server = pending.servers.first(where: { serverChoiceID($0) == id }) else {
            // The attempt ended out from under the picker (cancel / backend switch / expiry).
            // Drop back to the chooser instead of leaving the user tapping a dead list.
            recordAuthDiagnostic("auth.emby_connect.server_selection_stale")
            if case .awaitingEmbyServerSelection = state { state = .idle }
            return
        }
        guard let selectionWork = embyConnectServerSelections.begin(attemptID: attemptID,
                                                                     serverID: id) else {
            recordAuthDiagnostic("auth.emby_connect.server_selection_ignored",
                                 fields: ["reason": .string("selection_in_progress")])
            return
        }
        recordAuthDiagnostic("auth.emby_connect.server_selected",
                             fields: ["server_count": .string(serverCountBucket(pending.servers.count))])
        defer {
            embyConnectServerSelections.finish(selectionWork)
        }
        await exchangeAndPersistEmbyConnect(server: server,
                                            connectUserId: pending.connectUserId,
                                            attemptID: attemptID)
    }

    private func pollEmbyConnectPin(pin: String, attemptID: UUID) async {
        let deadline = authNow().advanced(by: embyConnectPollTimeout)
        var recordedTransientPollFailure = false
        while authNow() < deadline {
            try? await authSleep(embyConnectPollInterval)
            if Task.isCancelled { return }
            guard isCurrentAuthAttempt(attemptID) else { return }

            do {
                let data = try await embyConnectData(for: EmbyConnect.pollPinRequest(pin: pin, identity: embyIdentity))
                guard isCurrentAuthAttempt(attemptID) else { return }
                let status = try JSONDecoder().decode(EmbyConnectPin.self, from: data)
                if status.isExpired {
                    failEmbyConnect(attemptID,
                                    "Emby Connect code expired. Try again.",
                                    reason: "poll_expired")
                    return
                }
                guard status.isConfirmed else { continue }
                recordAuthDiagnostic("auth.emby_connect.poll_confirmed")
                await completeEmbyConnectAfterConfirmation(pin: pin, attemptID: attemptID)
                return
            } catch EmbyAuthError.http(404) {
                failEmbyConnect(attemptID,
                                "Emby Connect code expired or was cancelled. Try again.",
                                reason: "poll_not_found",
                                fields: ["status": .int(404)])
                return
            } catch EmbyAuthError.http(let status) {
                if !recordedTransientPollFailure {
                    recordedTransientPollFailure = true
                    recordAuthDiagnostic("auth.emby_connect.poll_http", fields: ["status": .int(status)])
                }
                continue
            } catch EmbyAuthError.unauthorized {
                // A rejected device/app won't recover by polling — fail fast instead of
                // spinning for the full timeout.
                failEmbyConnect(attemptID,
                                "Emby Connect rejected this device. Try again or use a server URL.",
                                reason: "poll_unauthorized")
                return
            } catch {
                // Transient network/server errors can happen while the user is still
                // entering the code — keep polling until the deadline.
                if !recordedTransientPollFailure {
                    recordedTransientPollFailure = true
                    recordAuthDiagnostic("auth.emby_connect.poll_transport", fields: authErrorFields(error))
                }
                continue
            }
        }
        failEmbyConnect(attemptID,
                        "Emby Connect timed out. Try again or use a server URL.",
                        reason: "poll_timeout")
    }

    /// PIN confirmed → exchange it for a Connect token, list linked servers, then either
    /// auto-exchange (one server) or ask the user to choose (more than one).
    private func completeEmbyConnectAfterConfirmation(pin: String, attemptID: UUID) async {
        guard isCurrentAuthAttempt(attemptID) else { return }
        recordAuthDiagnostic("auth.emby_connect.confirm_start")
        do {
            let authData = try await embyConnectData(for: EmbyConnect.authenticatePinRequest(pin: pin, identity: embyIdentity))
            guard isCurrentAuthAttempt(attemptID) else { return }
            let authResult = try JSONDecoder().decode(EmbyConnectExchangePinResult.self, from: authData)
            guard let connectUserId = authResult.userId, !connectUserId.isEmpty,
                  let connectToken = authResult.accessToken, !connectToken.isEmpty else {
                throw EmbyAuthError.missingCredentials
            }
            recordAuthDiagnostic("auth.emby_connect.confirm_authenticated")

            let serversData = try await embyConnectData(for: EmbyConnect.serversRequest(
                connectUserId: connectUserId, connectToken: connectToken, identity: embyIdentity))
            guard isCurrentAuthAttempt(attemptID) else { return }
            let servers = try JSONDecoder().decode([EmbyConnectServer].self, from: serversData)
            recordAuthDiagnostic("auth.emby_connect.servers_listed",
                                 fields: ["server_count": .string(serverCountBucket(servers.count))])
            guard !servers.isEmpty else {
                failEmbyConnect(attemptID,
                                "No Emby servers are linked to this Connect account.",
                                reason: "no_linked_servers")
                return
            }

            if servers.count == 1 {
                await exchangeAndPersistEmbyConnect(server: servers[0],
                                                    connectUserId: connectUserId,
                                                    attemptID: attemptID)
            } else {
                // The PIN poll is finished; the attempt now waits on the user's pick.
                pollTask = nil
                pendingEmbyConnect = PendingEmbyConnect(connectUserId: connectUserId, servers: servers)
                recordAuthDiagnostic("auth.emby_connect.server_selection_required",
                                     fields: ["server_count": .string(serverCountBucket(servers.count))])
                state = .awaitingEmbyServerSelection(servers: servers.map(serverChoice))
            }
        } catch EmbyAuthError.http(let status) {
            failEmbyConnect(attemptID,
                            "Emby Connect sign-in failed (HTTP \(status)).",
                            reason: "confirm_http",
                            fields: ["status": .int(status)])
        } catch EmbyAuthError.missingCredentials {
            failEmbyConnect(attemptID,
                            "Emby Connect did not return a usable session.",
                            reason: "confirm_missing_credentials")
        } catch {
            failEmbyConnect(attemptID,
                            "Couldn’t complete Emby Connect sign-in.",
                            reason: "confirm_failed",
                            fields: authErrorFields(error))
        }
    }

    /// Exchange the chosen server's access key for a normal local token, then persist the
    /// session via the shared Emby persistence so restore/refresh matches manual login.
    private func exchangeAndPersistEmbyConnect(server: EmbyConnectServer,
                                               connectUserId: String,
                                               attemptID: UUID) async {
        recordAuthDiagnostic("auth.emby_connect.exchange_start")
        do {
            guard let accessKey = server.accessKey, !accessKey.isEmpty else {
                throw EmbyAuthError.missingCredentials
            }
            guard let expectedSystemID = server.systemId, !expectedSystemID.isEmpty else {
                failEmbyConnect(attemptID,
                                "Emby Connect did not identify the selected server. Use a server URL instead.",
                                reason: "missing_system_id")
                return
            }
            guard let base = await resolveEmbyServerBaseURL(server, expectedSystemID: expectedSystemID) else {
                failEmbyConnect(attemptID,
                                "Couldn’t reach the selected Emby server.",
                                reason: "resolve_failed")
                return
            }
            guard isCurrentAuthAttempt(attemptID) else { return }
            let request = try EmbyConnect.exchangeRequest(server: base,
                                                          accessKey: accessKey,
                                                          connectUserId: connectUserId,
                                                          identity: embyIdentity)
            let data = try await embyConnectData(for: request)
            let result = try JSONDecoder().decode(EmbyConnectExchangeResult.self, from: data)
            guard let token = result.accessToken, !token.isEmpty,
                  let userID = result.localUserId, !userID.isEmpty else {
                throw EmbyAuthError.missingCredentials
            }
            guard isCurrentAuthAttempt(attemptID) else { return }
            try persistEmbySession(server: base, token: token, userID: userID, serverID: expectedSystemID)
            finishAuthAttempt(attemptID)
            pendingEmbyConnect = nil
            pollTask = nil
            state = .authenticated
            recordAuthDiagnostic("auth.emby_connect.exchange_success")
        } catch EmbyAuthError.http(let status) {
            failEmbyConnect(attemptID,
                            "Emby server exchange failed (HTTP \(status)).",
                            reason: "exchange_http",
                            fields: ["status": .int(status)])
        } catch EmbyAuthError.missingCredentials {
            failEmbyConnect(attemptID,
                            "The Emby server did not return a usable session.",
                            reason: "exchange_missing_credentials")
        } catch EmbyAuthError.secureStorageFailed {
            failEmbyConnect(attemptID,
                            "Couldn’t securely save the Emby session.",
                            reason: "secure_storage")
        } catch {
            failEmbyConnect(attemptID,
                            "Couldn’t complete Emby sign-in with the selected server.",
                            reason: "exchange_failed",
                            fields: authErrorFields(error))
        }
    }

    /// Resolve the address used for the access-key exchange + the saved session. Prefer the
    /// LAN address (fast, on-network in the headset) but ONLY when the host proves it is THIS
    /// server: its public `System/Info` `Id` must equal the Connect-supplied `SystemId`. This
    /// mirrors the Plex `firstReachable` identity binding and ensures the per-server access key
    /// is never sent to a wrong/spoofed host — the cloud-supplied `LocalAddress` is otherwise
    /// trusted blindly. Falls back to the WAN URL, verified the same way. Missing `SystemId`
    /// fails closed before this function is called; missing/garbled probed identity also fails
    /// closed here instead of persisting an unreachable/unverified address.
    private func resolveEmbyServerBaseURL(_ server: EmbyConnectServer, expectedSystemID: String) async -> URL? {
        let localBase = embyConnectBase(server.localAddress)
        let wanBase = embyConnectBase(server.url)
        recordAuthDiagnostic("auth.emby_connect.resolve_start", fields: [
            "has_local": .bool(localBase != nil),
            "has_wan": .bool(wanBase != nil)
        ])
        // Short timeout on the LAN probe so it fails over fast when away from home; the WAN
        // probe uses the normal session so a slow internet path isn't cut off prematurely.
        if let localBase, await embyServerIdentityMatches(localBase,
                                                          expectedSystemID: expectedSystemID,
                                                          session: Self.probeSession,
                                                          route: "local") {
            recordAuthDiagnostic("auth.emby_connect.resolve_success", fields: ["route": .string("local")])
            return localBase
        } else if localBase == nil {
            recordAuthDiagnostic("auth.emby_connect.identity_probe_skipped", fields: [
                "route": .string("local"),
                "reason": .string("missing_candidate")
            ])
        }
        if let wanBase, await embyServerIdentityMatches(wanBase,
                                                        expectedSystemID: expectedSystemID,
                                                        session: Self.mediaBrowserAuthSession,
                                                        route: "wan") {
            recordAuthDiagnostic("auth.emby_connect.resolve_success", fields: ["route": .string("wan")])
            return wanBase
        } else if wanBase == nil {
            recordAuthDiagnostic("auth.emby_connect.identity_probe_skipped", fields: [
                "route": .string("wan"),
                "reason": .string("missing_candidate")
            ])
        }
        recordAuthDiagnostic("auth.emby_connect.resolve_failed")
        return nil
    }

    private func embyConnectBase(_ address: String?) -> URL? {
        guard let address, !address.isEmpty else { return nil }
        return try? EmbyConnect.apiBaseURL(forConnectAddress: address)
    }

    private func recordAuthDiagnostic(_ name: String,
                                      fields: [String: DiagnosticFieldValue] = [:]) {
        AppDiagnostics.record(.auth, name, fields: fields)
    }

    private func authErrorFields(_ error: Error) -> [String: DiagnosticFieldValue] {
        let nsError = error as NSError
        return [
            "error_class": .string(DiagnosticRedactor.errorClass(for: nsError)),
            "error_domain": .string(DiagnosticRedactor.errorDomainFamily(nsError.domain)),
            "error_code": .int(nsError.code)
        ]
    }

    private func serverCountBucket(_ count: Int) -> String {
        switch count {
        case ..<1: return "none"
        case 1: return "one"
        case 2...4: return "multiple"
        default: return "many"
        }
    }

    private func embyServerIdentityMatches(_ base: URL,
                                           expectedSystemID: String,
                                           session: URLSession,
                                           route: String) async -> Bool {
        let baseFields: [String: DiagnosticFieldValue] = ["route": .string(route)]
        guard let request = try? EmbyAuth.serverInfoRequest(server: base) else {
            var fields = baseFields
            fields["reason"] = .string("request_build_failed")
            recordAuthDiagnostic("auth.emby_connect.identity_probe_failed", fields: fields)
            return false
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            var fields = baseFields
            fields.merge(authErrorFields(error)) { _, new in new }
            recordAuthDiagnostic("auth.emby_connect.identity_probe_transport", fields: fields)
            return false
        }
        guard let http = response as? HTTPURLResponse else {
            var fields = baseFields
            fields["reason"] = .string("non_http")
            recordAuthDiagnostic("auth.emby_connect.identity_probe_failed", fields: fields)
            return false
        }
        guard (200..<300).contains(http.statusCode) else {
            var fields = baseFields
            fields["status"] = .int(http.statusCode)
            recordAuthDiagnostic("auth.emby_connect.identity_probe_http", fields: fields)
            return false
        }
        // Require the probed server identity to match before we trust it with the
        // per-server access key. Missing/garbled info → reject closed.
        guard let info = try? JSONDecoder().decode(EmbyServerInfo.self, from: data) else {
            var fields = baseFields
            fields["reason"] = .string("identity_decode_failed")
            fields["status"] = .int(http.statusCode)
            recordAuthDiagnostic("auth.emby_connect.identity_probe_failed", fields: fields)
            return false
        }
        guard info.id == expectedSystemID else {
            var fields = baseFields
            fields["status"] = .int(http.statusCode)
            recordAuthDiagnostic("auth.emby_connect.identity_probe_mismatch", fields: fields)
            return false
        }
        var fields = baseFields
        fields["status"] = .int(http.statusCode)
        recordAuthDiagnostic("auth.emby_connect.identity_probe_success", fields: fields)
        return true
    }

    private func failEmbyConnect(_ attemptID: UUID,
                                 _ message: String,
                                 reason: String,
                                 fields: [String: DiagnosticFieldValue] = [:]) {
        guard isCurrentAuthAttempt(attemptID) else { return }
        var diagnosticFields = fields
        diagnosticFields["reason"] = .string(reason)
        recordAuthDiagnostic("auth.emby_connect.failed", fields: diagnosticFields)
        finishAuthAttempt(attemptID)
        embyConnectServerSelections.cancel()
        pendingEmbyConnect = nil
        pollTask = nil
        state = .failed(message)
    }

    private func serverChoice(_ server: EmbyConnectServer) -> EmbyConnectServerChoice {
        EmbyConnectServerChoice(id: serverChoiceID(server),
                                name: server.name ?? "Emby Server",
                                addressLabel: server.url ?? server.localAddress ?? "")
    }

    private func serverChoiceID(_ server: EmbyConnectServer) -> String {
        server.systemId ?? server.id ?? server.url ?? server.localAddress ?? ""
    }

    private func embyConnectData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await authDataLoader(request)
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 401, 403: throw EmbyAuthError.unauthorized
            default: throw EmbyAuthError.http(http.statusCode)
            }
        }
        return data
    }

    private func jellyfinData(for request: URLRequest, disabledMeansUnauthorized: Bool) async throws -> Data {
        let (data, response) = try await authDataLoader(request)
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300:
                break
            case 401, 403:
                if disabledMeansUnauthorized {
                    throw JellyfinAuthError.quickConnectDisabled
                }
                throw JellyfinAuthError.unauthorized
            default:
                throw JellyfinAuthError.http(http.statusCode)
            }
        }
        return data
    }

    /// Run resource discovery and select the best server/connection.
    func refreshServers() async throws {
        guard let accountToken = appModel.token else { throw PlexError.unauthorized }
        let generation = plexSessionGeneration
        let discovery: PlexSessionDiscovery
        do {
            if let plexSessionDiscoverer {
                discovery = try await plexSessionDiscoverer(accountToken)
            } else {
                discovery = try await discoverPlexSession(token: accountToken,
                                                           sessionGeneration: generation)
            }
        } catch {
            guard isCurrentPlexSession(token: accountToken, generation: generation) else {
                throw CancellationError()
            }
            clearResolvedPlexServerState()
            throw error
        }
        guard isCurrentPlexSession(token: accountToken, generation: generation) else {
            throw CancellationError()
        }
        guard keychain.saveSelectedPlexServerID(discovery.selectedServer.clientIdentifier) else {
            throw AuthCoordinationError.secureStorageFailed
        }
        applyPlexSession(discovery, token: accountToken)
    }

    /// Clear only the server-scoped portion of Plex runtime state. The account token remains
    /// available for retry/sign-out UI, while `isBrowseReady` honestly reports that discovery
    /// did not produce a usable server.
    private func clearResolvedPlexServerState() {
        appModel.clearResolvedPlexBrowseSession()
    }

    /// Performs all suspension-prone Plex work without touching runtime or secure state.
    /// Callers can generation-check the result and then commit synchronously on MainActor.
    private func discoverPlexSession(token accountToken: String,
                                     attemptID: AuthAttemptID? = nil,
                                     sessionGeneration: UUID? = nil) async throws -> PlexSessionDiscovery {
        let req = ResourceDiscovery.resourcesRequest(token: accountToken, identity: appModel.identity)
        let resources = try await appModel.client.send(req, as: ResourcesResponse.self)
        guard isPlexAuthorityCurrent(attemptID: attemptID, token: accountToken,
                                     sessionGeneration: sessionGeneration) else { throw CancellationError() }

        // Only devices that act as a media server.
        let servers = resources.devices.filter {
            ($0.provides ?? "").contains("server")
        }
        let preferredID = keychain.selectedPlexServerID
            ?? appModel.selectedServer?.clientIdentifier

        let candidates: [PlexDevice]
        if let preferredID, let preferred = servers.first(where: { $0.clientIdentifier == preferredID }) {
            candidates = [preferred] + servers.filter { $0.clientIdentifier != preferredID }
        } else {
            candidates = servers
        }

        for server in candidates {
            guard isPlexAuthorityCurrent(attemptID: attemptID, token: accountToken,
                                         sessionGeneration: sessionGeneration) else { throw CancellationError() }
            let serverToken = server.accessToken ?? accountToken
            let ranked = ResourceDiscovery.rankedConnections(server.connections)
            if let connection = await resolvePlexConnection(ranked,
                                                             token: serverToken,
                                                             expectedMachineIdentifier: server.clientIdentifier) {
                guard isPlexAuthorityCurrent(attemptID: attemptID, token: accountToken,
                                             sessionGeneration: sessionGeneration) else { throw CancellationError() }
                let profile = await fetchPlexAccountProfile(token: accountToken)
                guard isPlexAuthorityCurrent(attemptID: attemptID, token: accountToken,
                                             sessionGeneration: sessionGeneration) else { throw CancellationError() }
                return PlexSessionDiscovery(servers: servers,
                                            selectedServer: server,
                                            serverToken: serverToken,
                                            baseURL: connection.url,
                                            isLocal: connection.isLocal,
                                            accountProfile: profile)
            }
        }
        throw PlexError.serverUnreachable
    }

    private func loadPlexSessionDiscovery(token: String,
                                          attemptID: AuthAttemptID) async throws -> PlexSessionDiscovery {
        if let plexSessionDiscoverer {
            let result = try await plexSessionDiscoverer(token)
            guard isCurrentAuthAttempt(attemptID) else { throw CancellationError() }
            return result
        }
        return try await discoverPlexSession(token: token, attemptID: attemptID)
    }

    private func applyPlexSession(_ discovery: PlexSessionDiscovery, token: String) {
        appModel.applyPlexBrowseSession(accountToken: token,
                                        servers: discovery.servers,
                                        selectedServer: discovery.selectedServer,
                                        serverToken: discovery.serverToken,
                                        baseURL: discovery.baseURL,
                                        isLocal: discovery.isLocal,
                                        accountProfile: discovery.accountProfile)
        plexSessionGeneration = UUID()
    }

    /// Select a Plex server from Settings and persist that server identity for future launches.
    func selectPlexServer(id serverID: String) async throws {
        guard let server = appModel.plexServers.first(where: { $0.clientIdentifier == serverID }) else {
            throw PlexError.serverUnreachable
        }
        guard let accountToken = appModel.token else { throw PlexError.unauthorized }
        let generation = plexSessionGeneration
        let serverToken = server.accessToken ?? accountToken
        let ranked = ResourceDiscovery.rankedConnections(server.connections)
        guard let connection = await resolvePlexConnection(ranked,
                                                           token: serverToken,
                                                           expectedMachineIdentifier: server.clientIdentifier) else {
            throw PlexError.serverUnreachable
        }
        guard isCurrentPlexSession(token: accountToken, generation: generation) else {
            throw CancellationError()
        }
        guard keychain.saveSelectedPlexServerID(server.clientIdentifier) else {
            throw AuthCoordinationError.secureStorageFailed
        }
        appModel.applySelectedPlexServer(server,
                                         serverToken: serverToken,
                                         baseURL: connection.url,
                                         isLocal: connection.isLocal)
        plexSessionGeneration = UUID()
    }

    /// Fetch non-secret Plex account display metadata for Settings. Failure is non-fatal:
    /// browsing and playback are server-token driven, and Settings can show "Unavailable".
    func refreshPlexAccountProfile() async {
        guard let token = appModel.token else {
            appModel.plexAccountProfile = nil
            return
        }
        let generation = plexSessionGeneration
        let profile = await fetchPlexAccountProfile(token: token)
        guard isCurrentPlexSession(token: token, generation: generation) else { return }
        appModel.plexAccountProfile = profile
    }

    private func fetchPlexAccountProfile(token: String) async -> PlexAccountProfile? {
        if let plexProfileLoader { return await plexProfileLoader(token) }
        do {
            let req = PlexAccount.profileRequest(token: token, identity: appModel.identity)
            return try await appModel.client.send(req, as: PlexAccountProfile.self)
        } catch {
            return nil
        }
    }

    /// Short-timeout session used only for connection reachability probes.
    private static let probeSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 3
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    /// Probe every candidate connection in parallel by hitting `<uri>/identity`
    /// and return the highest-priority one (lowest index in `ranked`) that
    /// responds with a 2xx within the timeout. When `expectedMachineIdentifier`
    /// is supplied, the identity payload must also identify that exact Plex
    /// server; this prevents selecting a stale/reverse-proxy URL that answers as
    /// some other server and then browsing the wrong libraries. Returns nil if
    /// no candidate matches.
    private func firstReachable(_ ranked: [PlexConnection],
                                token: String,
                                expectedMachineIdentifier: String?) async -> (url: URL, isLocal: Bool)? {
        await withTaskGroup(of: (Int, URL, Bool)?.self) { group in
            for (index, conn) in ranked.enumerated() {
                guard let base = URL(string: conn.uri) else { continue }
                let isLocal = conn.local
                group.addTask {
                    var req = URLRequest(url: base.appendingPathComponent("identity"))
                    req.setValue(token, forHTTPHeaderField: "X-Plex-Token")
                    req.setValue("application/json", forHTTPHeaderField: "Accept")
                    do {
                        let (data, resp) = try await Self.probeSession.data(for: req)
                        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                            return nil
                        }
                        if let expectedMachineIdentifier,
                           Self.plexMachineIdentifier(in: data) != expectedMachineIdentifier {
                            return nil
                        }
                        return (index, base, isLocal)
                    } catch { /* unreachable / timed out */ }
                    return nil
                }
            }
            var best: (Int, URL, Bool)?
            for await result in group {
                if let r = result, best == nil || r.0 < best!.0 { best = r }
            }
            guard let best else { return nil }
            return (best.1, best.2)
        }
    }

    private func resolvePlexConnection(_ ranked: [PlexConnection],
                                       token: String,
                                       expectedMachineIdentifier: String?) async -> (url: URL, isLocal: Bool)? {
        if let plexConnectionResolver {
            return await plexConnectionResolver(ranked, token, expectedMachineIdentifier)
        }
        return await firstReachable(ranked, token: token,
                                    expectedMachineIdentifier: expectedMachineIdentifier)
    }

    nonisolated private static func plexMachineIdentifier(in data: Data) -> String? {
        guard let body = String(data: data, encoding: .utf8) else { return nil }
        let patterns = [
            #"machineIdentifier\s*=\s*[\"']([^\"']+)"#,
            #"\"machineIdentifier\"\s*:\s*\"([^\"]+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(body.startIndex..<body.endIndex, in: body)
            guard let match = regex.firstMatch(in: body, range: range),
                  match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: body) else { continue }
            return String(body[valueRange])
        }
        return nil
    }

    /// One-shot reachability check of the CURRENTLY selected connection, for the Settings
    /// connection-status row (#26). Same `<uri>/identity` probe as `firstReachable`, but
    /// against the single resolved `serverBaseURL` — no re-discovery, no state changes.
    func probeSelectedServer() async -> Bool {
        guard let base = appModel.serverBaseURL, let token = appModel.serverToken else {
            return false
        }
        var req = URLRequest(url: base.appendingPathComponent("identity"))
        req.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await Self.probeSession.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return false
            }
            guard let expectedMachineIdentifier = appModel.selectedServer?.clientIdentifier else {
                return true
            }
            return Self.plexMachineIdentifier(in: data) == expectedMachineIdentifier
        } catch {
            return false
        }
    }

    /// One-shot reachability check for a discovered Plex server. Used by the Settings picker
    /// to show healthy/unreachable state without exposing candidate connection URLs.
    func probePlexServer(id serverID: String) async -> Bool {
        guard let server = appModel.plexServers.first(where: { $0.clientIdentifier == serverID }),
              let accountToken = appModel.token else {
            return false
        }
        let serverToken = server.accessToken ?? accountToken
        return await firstReachable(ResourceDiscovery.rankedConnections(server.connections),
                                    token: serverToken,
                                    expectedMachineIdentifier: server.clientIdentifier) != nil
    }

    /// Clear all auth state and return to login. Call on sign-out or any 401.
    func signOut() {
        cancelPendingLogin()
        // Library titles must not linger in system search after sign-out (#24).
        SpotlightIndexer.deleteAll()
        appModel.isSwitchingBackend = false
        let backend = appModel.activeBackend
        // A URLSession request retains its auth header after it has been created. Pause every
        // affected download synchronously while the backend session is still available so the
        // range task can produce resume data and its server-side encoder can be torn down. The
        // local credential clear immediately below then prevents a new authenticated request.
        onBackendWillSignOut?(backend)
        switch backend {
        case .plex:
            signOutPlex()
        case .jellyfin:
            revokeJellyfinSessionIfPossible()
            signOutJellyfin()
        case .emby:
            revokeEmbySessionIfPossible()
            signOutEmby()
        }
        state = .idle
    }

    /// Remote revocation is deliberately best effort. Capture the live values before local
    /// clearing, then always complete the local sign-out synchronously from the caller's view.
    private func revokeJellyfinSessionIfPossible() {
        guard let server = appModel.jellyfinServerBaseURL,
              let token = appModel.jellyfinAccessToken else { return }
        let request = JellyfinAuth.logoutRequest(server: server, token: token, identity: jellyfinIdentity)
        Task { _ = try? await Self.mediaBrowserAuthSession.data(for: request) }
    }

    private func revokeEmbySessionIfPossible() {
        guard let server = appModel.embyServerBaseURL,
              let token = appModel.embyAccessToken,
              let userID = appModel.embyUserID,
              let request = try? EmbyAuth.logoutRequest(server: server,
                                                        token: token,
                                                        identity: embyIdentity,
                                                        userId: userID) else { return }
        Task { _ = try? await Self.mediaBrowserAuthSession.data(for: request) }
    }

    private func signOutPlex() {
        plexSessionGeneration = UUID()
        keychain.token = nil
        keychain.selectedPlexServerID = nil
        clearRuntimeState(for: .plex)
    }

    private func signOutJellyfin() {
        // #93: log every Jellyfin credential wipe so a future live repro of the unexpected
        // sign-out shows which path fired (manual Settings sign-out vs restore probe).
        NSLog("[#93] signOutJellyfin: clearing saved Jellyfin session")
        keychain.jellyfinServerURLString = nil
        keychain.jellyfinAccessToken = nil
        keychain.jellyfinUserID = nil
        keychain.jellyfinServerID = nil
        clearRuntimeState(for: .jellyfin)
    }

    private func signOutEmby() {
        keychain.embyServerURLString = nil
        keychain.embyAccessToken = nil
        keychain.embyUserID = nil
        keychain.embyServerID = nil
        clearRuntimeState(for: .emby)
    }

    private func clearRuntimeState(for backend: MediaBackendKind) {
        appModel.clearBrowseSession(for: backend)
    }

    /// Starts the single authority generation used by the auth and legacy-session
    /// restore flows coordinated in this type. Saved-profile restoration adopts the
    /// same authority when that feature lands.
    /// Attempt identities are deliberately ephemeral and never enter Keychain state.
    private func beginAuthAttempt(_ operation: AuthOperation) -> AuthAttemptID {
        let attempt = AuthAttempt(id: UUID(), operation: operation)
        activeAuthAttempt = attempt
        return attempt.id
    }

    private func isCurrentAuthAttempt(_ id: AuthAttemptID) -> Bool {
        activeAuthAttempt?.id == id && !Task.isCancelled
    }

    private func currentAuthAttemptID(for operation: AuthOperation) -> AuthAttemptID? {
        guard activeAuthAttempt?.operation == operation else { return nil }
        return activeAuthAttempt?.id
    }

    private func finishAuthAttempt(_ id: AuthAttemptID) {
        guard activeAuthAttempt?.id == id else { return }
        activeAuthAttempt = nil
    }

    private func isCurrentPlexSession(token: String, generation: UUID) -> Bool {
        !Task.isCancelled && plexSessionGeneration == generation && appModel.token == token
    }

    private func isPlexAuthorityCurrent(attemptID: AuthAttemptID?,
                                        token: String,
                                        sessionGeneration: UUID?) -> Bool {
        if let attemptID { return isCurrentAuthAttempt(attemptID) }
        if let sessionGeneration {
            return isCurrentPlexSession(token: token, generation: sessionGeneration)
        }
        return true
    }

    private func cleanupCancelledAuthAttempt(_ id: AuthAttemptID) {
        guard Task.isCancelled, activeAuthAttempt?.id == id else { return }
        activeAuthAttempt = nil
        activePinIDs = []
        pollTask?.cancel()
        pollTask = nil
        pendingEmbyConnect = nil
        embyConnectServerSelections.cancel()
        state = .idle
    }

    func cancelPendingLogin() {
        pollTask?.cancel()
        pollTask = nil
        activePinIDs = []
        activeAuthAttempt = nil
        embyConnectServerSelections.cancel()
        pendingEmbyConnect = nil
    }

    private var jellyfinIdentity: JellyfinClientIdentity {
        appModel.identity.jellyfin
    }

    private var embyIdentity: EmbyClientIdentity {
        appModel.identity.emby
    }

    private static let mediaBrowserAuthSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()
}

private typealias AuthAttemptID = UUID

private struct AuthAttempt: Equatable {
    let id: AuthAttemptID
    let operation: AuthOperation
}

private enum AuthOperation: Equatable {
    case plexPIN
    case jellyfinCredentials
    case jellyfinQuickConnect
    case embyCredentials
    case embyConnect
    case sessionRestore
}

private enum AuthCoordinationError: Error {
    case secureStorageFailed
}

/// In-flight Emby Connect state held while the user picks among multiple linked servers.
/// In-memory only; carries per-server access keys, so it is never logged or persisted.
private struct PendingEmbyConnect {
    let connectUserId: String
    let servers: [EmbyConnectServer]
}

struct EmbyConnectServerSelectionWork: Equatable {
    let attemptID: UUID
    let serverID: String
}

struct EmbyConnectServerSelectionTracker {
    private(set) var active: EmbyConnectServerSelectionWork?

    mutating func begin(attemptID: UUID, serverID: String) -> EmbyConnectServerSelectionWork? {
        guard active == nil else { return nil }
        let work = EmbyConnectServerSelectionWork(attemptID: attemptID, serverID: serverID)
        active = work
        return work
    }

    mutating func finish(_ work: EmbyConnectServerSelectionWork) {
        guard active == work else { return }
        active = nil
    }

    mutating func cancel() { active = nil }
}

private struct JellyfinSessionSnapshot {
    let server: URL
    let token: String
    let userID: String
    let serverID: String?
}

private struct EmbySessionSnapshot {
    let server: URL
    let token: String
    let userID: String
    let serverID: String?
}

struct PlexSessionDiscovery {
    let servers: [PlexDevice]
    let selectedServer: PlexDevice
    let serverToken: String
    let baseURL: URL
    let isLocal: Bool
    let accountProfile: PlexAccountProfile?
}

private enum JellyfinAuthError: Error {
    case unauthorized
    /// A 2xx identity probe returned a different (normalized) user id than the saved session.
    /// Ambiguous, not a revoked credential — restore preserves the keychain snapshot.
    case identityMismatch
    case quickConnectDisabled
    case http(Int)
    case missingCredentials
    case secureStorageFailed
}

private enum EmbyAuthError: Error {
    case unauthorized
    case http(Int)
    case missingCredentials
    case secureStorageFailed
}

private extension MediaBackendKind {
    var switchChoice: MediaBackendChoice {
        self
    }
}

private extension KeychainStore {
    var mediaBackendCredentialSnapshot: MediaBackendCredentialSnapshot {
        MediaBackendCredentialSnapshot(plexToken: token,
                                       jellyfinServerURLString: jellyfinServerURLString,
                                       jellyfinAccessToken: jellyfinAccessToken,
                                       jellyfinUserID: jellyfinUserID,
                                       embyServerURLString: embyServerURLString,
                                       embyAccessToken: embyAccessToken,
                                       embyUserID: embyUserID)
    }
}
