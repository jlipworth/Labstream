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
    /// PIN (its long code backs the in-headset web-auth URL). Whichever the
    /// user completes authorizes first; both clear when the attempt ends.
    private var activePinIDs: Set<Int> = []
    private var activeJellyfinQuickConnectAttemptID: UUID?
    private var activeJellyfinCredentialAttemptID: UUID?
    /// Current Emby Connect attempt and the cloud session it produced. `pendingEmbyConnect`
    /// holds the Connect user id + linked-server list (incl. per-server access keys) while the
    /// user picks a server; it is in-memory only and cleared when the attempt ends.
    private var activeEmbyConnectAttemptID: UUID?
    private var activeEmbyCredentialAttemptID: UUID?
    private var activeEmbyConnectServerSelectionID: String?
    private var pendingEmbyConnect: PendingEmbyConnect?

    init(appModel: AppModel, keychain: KeychainStore = KeychainStore()) {
        self.appModel = appModel
        self.keychain = keychain
    }

    func selectBackend(_ backend: MediaBackendKind) {
        cancelPendingLogin()
        appModel.activeBackend = backend
        keychain.selectedBackend = backend
        state = .idle
    }

    func switchBackend(_ backend: MediaBackendKind) async {
        let resolution = MediaBackendSwitch.resolve(active: appModel.activeBackend.switchChoice,
                                                    target: backend.switchChoice,
                                                    credentials: keychain.mediaBackendCredentialSnapshot)
        guard resolution != .alreadyActive else { return }

        cancelPendingLogin()
        appModel.activeBackend = backend
        keychain.selectedBackend = backend

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
        let selected = keychain.selectedBackend
        appModel.activeBackend = selected

        let selectedRestored: Bool
        switch selected {
        case .plex:
            selectedRestored = await restorePlexSession(updateState: true)
        case .jellyfin:
            selectedRestored = await restoreJellyfinSession(validateReachability: true, updateState: true)
        case .emby:
            selectedRestored = await restoreEmbySession(validateReachability: true, updateState: true)
        }

        await restoreInactiveBackendSessions(excluding: selected)
        return selectedRestored
    }

    /// Hydrate non-selected backend lanes for downloads without taking over the UI state. Jellyfin
    /// and Emby can restore directly from their saved base URL + token + user id; Plex still needs
    /// discovery to recover the current PMS connection and server-scoped token.
    private func restoreInactiveBackendSessions(excluding selected: MediaBackendKind) async {
        for backend in MediaBackendKind.allCases where backend != selected {
            switch backend {
            case .plex:
                // Plex hydration is expensive (resource enumeration + per-connection probing).
                // `restoreSession()` runs on every backend switch, so re-discovering PMS each time
                // the user toggles Jellyfin↔Emby is wasted work. The Plex lane stays live for the
                // app's lifetime once hydrated, so only discover when it isn't already connected.
                if appModel.selectedServer == nil || appModel.serverBaseURL == nil {
                    _ = await restorePlexSession(updateState: false)
                }
            case .jellyfin:
                _ = await restoreJellyfinSession(validateReachability: false, updateState: false)
            case .emby:
                _ = await restoreEmbySession(validateReachability: false, updateState: false)
            }
        }
    }

    private func restorePlexSession(updateState: Bool = true) async -> Bool {
        guard let saved = keychain.token else { return false }
        appModel.token = saved
        do {
            await refreshPlexAccountProfile()
            try await refreshServers()
            if updateState { state = .authenticated }
            return true
        } catch PlexError.unauthorized {
            // Only wipe the Plex lane when it is the ACTIVE, user-facing backend. On the inactive
            // hydration path (a JF/Emby session warming Plex for cross-backend downloads), a transient
            // discovery 401 must NOT silently sign the user out of Plex — leave the saved token in
            // place and let the lane stay unhydrated until they switch back, where `updateState: true`
            // handles a genuine sign-out with the proper UI teardown.
            guard updateState else { return false }
            SpotlightIndexer.deleteAll()
            appModel.isSwitchingBackend = false
            signOutPlex()
            state = .idle
            return false
        } catch {
            if updateState { state = .failed("Signed in, but server discovery failed.") }
            return true
        }
    }

    private func restoreJellyfinSession(validateReachability: Bool = true,
                                        updateState: Bool = true) async -> Bool {
        guard loadJellyfinSessionSnapshot() else { return false }
        guard validateReachability else { return true }
        guard let server = appModel.jellyfinServerBaseURL,
              let token = appModel.jellyfinAccessToken,
              let userID = appModel.jellyfinUserID else { return false }
        do {
            try await probeJellyfinReachability(server: server, token: token, userID: userID)
            if updateState { state = .authenticated }
            return true
        } catch JellyfinAuthError.unauthorized {
            NSLog("[#93] restoreJellyfinSession wiping creds: probe returned unauthorized (updateState=%@)",
                  updateState ? "true" : "false")
            signOutJellyfin()
            if updateState { state = .idle }
            return false
        } catch {
            if updateState { state = .failed("Signed in, but the Jellyfin server could not be reached.") }
            return true
        }
    }

    /// Validate the saved Jellyfin session with a live `userViews` probe.
    ///
    /// A 401 is treated as an invalid token immediately. A 403, however, is NOT proof of an
    /// expired token during a network reconnect (#93): some setups answer 403 transiently
    /// for a still-valid token while a Wi-Fi transition settles. So a 403 gets ONE bounded
    /// retry; only if the retry also returns 401/403 do we treat the session as unauthorized
    /// and let the caller wipe creds. Any other error (timeout/unreachable) propagates and is
    /// preserved as `.failed` without wiping, matching `restorePlexSession`.
    private func probeJellyfinReachability(server: URL, token: String, userID: String) async throws {
        let status = try await jellyfinUserViewsStatus(server: server, token: token, userID: userID)
        switch status {
        case 200..<300:
            return
        case 401:
            throw JellyfinAuthError.unauthorized
        case 403:
            // Bounded single retry before trusting a 403 enough to sign the user out.
            NSLog("[#93] restoreJellyfinSession: probe returned 403; retrying once before wiping creds")
            let retry = try await jellyfinUserViewsStatus(server: server, token: token, userID: userID)
            switch retry {
            case 200..<300: return
            case 401, 403: throw JellyfinAuthError.unauthorized
            default: throw JellyfinAuthError.http(retry)
            }
        default:
            throw JellyfinAuthError.http(status)
        }
    }

    /// One `userViews` probe; returns the HTTP status code (or rethrows a transport error).
    private func jellyfinUserViewsStatus(server: URL, token: String, userID: String) async throws -> Int {
        let req = try JellyfinLibrary.userViewsRequest(server: server,
                                                       token: token,
                                                       identity: jellyfinIdentity,
                                                       userId: userID)
        let (_, response) = try await Self.jellyfinSession.data(for: req)
        guard let http = response as? HTTPURLResponse else { return 200 }
        return http.statusCode
    }

    private func loadJellyfinSessionSnapshot() -> Bool {
        guard let urlString = keychain.jellyfinServerURLString,
              let server = URL(string: urlString),
              let token = keychain.jellyfinAccessToken,
              let userID = keychain.jellyfinUserID else { return false }
        appModel.jellyfinServerBaseURL = server
        appModel.jellyfinAccessToken = token
        appModel.jellyfinUserID = userID
        appModel.jellyfinServerID = keychain.jellyfinServerID
        return true
    }

    private func restoreEmbySession(validateReachability: Bool = true,
                                    updateState: Bool = true) async -> Bool {
        guard loadEmbySessionSnapshot() else { return false }
        guard validateReachability else { return true }
        guard let server = appModel.embyServerBaseURL,
              let token = appModel.embyAccessToken,
              let userID = appModel.embyUserID else { return false }
        do {
            let req = try EmbyLibrary.userViewsRequest(server: server,
                                                       token: token,
                                                       identity: embyIdentity,
                                                       userId: userID)
            let (_, response) = try await Self.jellyfinSession.data(for: req)
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200..<300: break
                case 401, 403: throw EmbyAuthError.unauthorized
                default: throw EmbyAuthError.http(http.statusCode)
                }
            }
            if updateState { state = .authenticated }
            return true
        } catch EmbyAuthError.unauthorized {
            // Invalid/expired creds — drop the saved session and require re-login.
            signOutEmby()
            if updateState { state = .idle }
            return false
        } catch {
            // Unreachable host (or other transient error) — keep the saved session so a
            // later launch with connectivity restores cleanly.
            if updateState { state = .failed("Signed in, but the Emby server could not be reached.") }
            return true
        }
    }

    private func loadEmbySessionSnapshot() -> Bool {
        guard let urlString = keychain.embyServerURLString,
              let server = URL(string: urlString),
              let token = keychain.embyAccessToken,
              let userID = keychain.embyUserID else { return false }
        appModel.embyServerBaseURL = server
        appModel.embyAccessToken = token
        appModel.embyUserID = userID
        appModel.embyServerID = keychain.embyServerID
        return true
    }

    /// Start a fresh login. Creates TWO PINs (#16): a non-strong one whose
    /// 4-character code the UI displays for plex.tv/link, and a strong one whose
    /// long code backs the `app.plex.tv/auth` web URL (a strong code cannot be
    /// typed at plex.tv/link, and the auth web page needs the strong one).
    /// Both are polled; whichever the user completes wins.
    /// Returns the URL the UI should present for the in-headset browser path.
    func createPin() async throws -> URL {
        selectBackend(.plex)
        cancelPendingLogin()
        async let linkReq = appModel.client.send(
            PinAuth.createPinRequest(identity: appModel.identity, strong: false),
            as: PinResponse.self)
        async let strongReq = appModel.client.send(
            PinAuth.createPinRequest(identity: appModel.identity, strong: true),
            as: PinResponse.self)
        let (linkPin, strongPin) = try await (linkReq, strongReq)

        let authURL = PinAuth.authAppURL(code: strongPin.code, identity: appModel.identity)
        activePinIDs = [linkPin.id, strongPin.id]
        state = .awaitingAuthorization(code: linkPin.code, url: authURL)

        // Kick off polling in the background; UI observes `state`.
        let ids = activePinIDs
        pollTask = Task { await pollForToken(pinIDs: ids) }
        return authURL
    }

    /// Poll the attempt's PINs until one carries an `authToken` or we time out.
    private func pollForToken(pinIDs: Set<Int>) async {
        let deadline = ContinuousClock.now.advanced(by: pollTimeout)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: pollInterval)
            if Task.isCancelled { return }
            guard activePinIDs == pinIDs else { return }

            for pinID in pinIDs {
                let pollReq = PinAuth.pollPinRequest(pinID: pinID, identity: appModel.identity)
                do {
                    let poll = try await appModel.client.send(pollReq, as: PinPollResponse.self)
                    if let token = poll.authToken, !token.isEmpty {
                        await finishLogin(token: token)
                        return
                    }
                } catch {
                    // Transient errors are expected while the user is still authorizing;
                    // keep polling until the deadline.
                    continue
                }
            }
        }
        guard activePinIDs == pinIDs else { return }
        activePinIDs = []
        pollTask = nil
        state = .failed("Authorization timed out.")
    }

    /// Persist the token, update the model, and discover servers.
    private func finishLogin(token: String) async {
        keychain.selectedBackend = .plex
        guard keychain.saveToken(token) else {
            state = .failed("Couldn’t securely save the Plex token.")
            return
        }
        appModel.token = token
        do {
            await refreshPlexAccountProfile()
            try await refreshServers()
            activePinIDs = []
            pollTask = nil
            state = .authenticated
        } catch {
            state = .failed("Signed in, but server discovery failed.")
        }
    }

    func loginToJellyfin(server: URL, username: String, password: String) async {
        cancelPendingLogin()
        let attemptID = UUID()
        activeJellyfinCredentialAttemptID = attemptID
        appModel.activeBackend = .jellyfin
        keychain.selectedBackend = .jellyfin
        state = .idle
        do {
            let request = try JellyfinAuth.authenticateByNameRequest(server: server,
                                                                    username: username,
                                                                    password: password,
                                                                    identity: jellyfinIdentity)
            let (data, response) = try await Self.jellyfinSession.data(for: request)
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
            guard activeJellyfinCredentialAttemptID == attemptID else { return }
            try persistJellyfinAuthentication(result, server: server)
            activeJellyfinCredentialAttemptID = nil
            state = .authenticated
        } catch JellyfinAuthError.unauthorized {
            guard activeJellyfinCredentialAttemptID == attemptID else { return }
            activeJellyfinCredentialAttemptID = nil
            state = .failed("Invalid Jellyfin username or password.")
        } catch JellyfinAuthError.http(let status) {
            guard activeJellyfinCredentialAttemptID == attemptID else { return }
            activeJellyfinCredentialAttemptID = nil
            state = .failed("Jellyfin sign-in failed (HTTP \(status)).")
        } catch JellyfinAuthError.missingCredentials {
            guard activeJellyfinCredentialAttemptID == attemptID else { return }
            activeJellyfinCredentialAttemptID = nil
            state = .failed("Jellyfin did not return a usable session.")
        } catch JellyfinAuthError.secureStorageFailed {
            guard activeJellyfinCredentialAttemptID == attemptID else { return }
            activeJellyfinCredentialAttemptID = nil
            state = .failed("Couldn’t securely save the Jellyfin session.")
        } catch {
            guard activeJellyfinCredentialAttemptID == attemptID else { return }
            activeJellyfinCredentialAttemptID = nil
            state = .failed("Couldn’t reach Jellyfin server.")
        }
    }

    func startJellyfinQuickConnect(server: URL) async {
        cancelPendingLogin()
        let attemptID = UUID()
        activeJellyfinQuickConnectAttemptID = attemptID
        appModel.activeBackend = .jellyfin
        keychain.selectedBackend = .jellyfin
        state = .idle

        do {
            if let enabled = try await jellyfinQuickConnectEnabled(server: server), enabled == false {
                guard activeJellyfinQuickConnectAttemptID == attemptID else { return }
                activeJellyfinQuickConnectAttemptID = nil
                state = .failed("Jellyfin Quick Connect is disabled on this server. Use username and password instead.")
                return
            }
            guard activeJellyfinQuickConnectAttemptID == attemptID else { return }

            let request = JellyfinAuth.initiateQuickConnectRequest(server: server,
                                                                   identity: jellyfinIdentity)
            let data = try await jellyfinData(for: request, disabledMeansUnauthorized: true)
            guard activeJellyfinQuickConnectAttemptID == attemptID else { return }
            let result = try JSONDecoder().decode(JellyfinQuickConnectResult.self, from: data)
            guard let code = result.code, !code.isEmpty,
                  let secret = result.secret, !secret.isEmpty else {
                throw JellyfinAuthError.missingCredentials
            }

            guard activeJellyfinQuickConnectAttemptID == attemptID else { return }
            state = .awaitingJellyfinQuickConnect(code: code)
            pollTask = Task { await pollJellyfinQuickConnect(server: server,
                                                             secret: secret,
                                                             attemptID: attemptID) }
        } catch JellyfinAuthError.quickConnectDisabled {
            guard activeJellyfinQuickConnectAttemptID == attemptID else { return }
            activeJellyfinQuickConnectAttemptID = nil
            state = .failed("Jellyfin Quick Connect is disabled on this server. Use username and password instead.")
        } catch JellyfinAuthError.unauthorized {
            guard activeJellyfinQuickConnectAttemptID == attemptID else { return }
            activeJellyfinQuickConnectAttemptID = nil
            state = .failed("Jellyfin Quick Connect is disabled on this server. Use username and password instead.")
        } catch JellyfinAuthError.http(let status) {
            guard activeJellyfinQuickConnectAttemptID == attemptID else { return }
            activeJellyfinQuickConnectAttemptID = nil
            state = .failed("Jellyfin Quick Connect failed (HTTP \(status)).")
        } catch JellyfinAuthError.missingCredentials {
            guard activeJellyfinQuickConnectAttemptID == attemptID else { return }
            activeJellyfinQuickConnectAttemptID = nil
            state = .failed("Jellyfin did not return a Quick Connect code. Use username and password instead.")
        } catch {
            guard activeJellyfinQuickConnectAttemptID == attemptID else { return }
            activeJellyfinQuickConnectAttemptID = nil
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
        let deadline = ContinuousClock.now.advanced(by: jellyfinQuickConnectPollTimeout)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: jellyfinQuickConnectPollInterval)
            if Task.isCancelled { return }
            guard activeJellyfinQuickConnectAttemptID == attemptID else { return }

            do {
                let request = try JellyfinAuth.quickConnectStateRequest(server: server,
                                                                        secret: secret,
                                                                        identity: jellyfinIdentity)
                let data = try await jellyfinData(for: request, disabledMeansUnauthorized: false)
                let result = try JSONDecoder().decode(JellyfinQuickConnectResult.self, from: data)
                guard result.authenticated else { continue }
                do {
                    try await finishJellyfinQuickConnect(server: server, secret: secret, attemptID: attemptID)
                } catch JellyfinAuthError.http(let status) {
                    guard activeJellyfinQuickConnectAttemptID == attemptID else { return }
                    activeJellyfinQuickConnectAttemptID = nil
                    pollTask = nil
                    state = .failed("Jellyfin Quick Connect sign-in failed (HTTP \(status)). Use username and password instead.")
                } catch JellyfinAuthError.missingCredentials {
                    guard activeJellyfinQuickConnectAttemptID == attemptID else { return }
                    activeJellyfinQuickConnectAttemptID = nil
                    pollTask = nil
                    state = .failed("Jellyfin did not return a usable session. Use username and password instead.")
                } catch JellyfinAuthError.secureStorageFailed {
                    guard activeJellyfinQuickConnectAttemptID == attemptID else { return }
                    activeJellyfinQuickConnectAttemptID = nil
                    pollTask = nil
                    state = .failed("Couldn’t securely save the Jellyfin session.")
                } catch {
                    guard activeJellyfinQuickConnectAttemptID == attemptID else { return }
                    activeJellyfinQuickConnectAttemptID = nil
                    pollTask = nil
                    state = .failed("Jellyfin Quick Connect sign-in failed. Use username and password instead.")
                }
                return
            } catch JellyfinAuthError.http(404) {
                guard activeJellyfinQuickConnectAttemptID == attemptID else { return }
                activeJellyfinQuickConnectAttemptID = nil
                pollTask = nil
                state = .failed("Jellyfin Quick Connect code expired or was cancelled. Try again or use username and password.")
                return
            } catch {
                // Transient network/server errors can happen while the user is
                // still authorizing. Keep polling until the deadline.
                continue
            }
        }

        guard activeJellyfinQuickConnectAttemptID == attemptID else { return }
        activeJellyfinQuickConnectAttemptID = nil
        pollTask = nil
        state = .failed("Jellyfin Quick Connect timed out. Try again or use username and password.")
    }

    private func finishJellyfinQuickConnect(server: URL, secret: String, attemptID: UUID) async throws {
        guard activeJellyfinQuickConnectAttemptID == attemptID else { return }
        let request = try JellyfinAuth.authenticateWithQuickConnectRequest(server: server,
                                                                          secret: secret,
                                                                          identity: jellyfinIdentity)
        let data = try await jellyfinData(for: request, disabledMeansUnauthorized: false)
        let result = try JSONDecoder().decode(JellyfinAuthenticationResult.self, from: data)
        try persistJellyfinAuthentication(result, server: server)
        activeJellyfinQuickConnectAttemptID = nil
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
        appModel.jellyfinServerBaseURL = server
        appModel.jellyfinAccessToken = token
        appModel.jellyfinUserID = userID
        appModel.jellyfinServerID = result.serverId
    }

    /// Emby username/password sign-in (NO Quick Connect — slice 1 is password-only).
    /// Mirrors `loginToJellyfin` but uses the Emby-specific auth/header lane.
    func loginToEmby(server: URL, username: String, password: String) async {
        cancelPendingLogin()
        let attemptID = UUID()
        activeEmbyCredentialAttemptID = attemptID
        appModel.activeBackend = .emby
        keychain.selectedBackend = .emby
        state = .idle
        do {
            let request = try EmbyAuth.authenticateByNameRequest(server: server,
                                                                 username: username,
                                                                 password: password,
                                                                 identity: embyIdentity)
            let (data, response) = try await Self.jellyfinSession.data(for: request)
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
            guard activeEmbyCredentialAttemptID == attemptID else { return }
            try persistEmbyAuthentication(result, server: server)
            activeEmbyCredentialAttemptID = nil
            state = .authenticated
        } catch EmbyAuthError.unauthorized {
            guard activeEmbyCredentialAttemptID == attemptID else { return }
            activeEmbyCredentialAttemptID = nil
            state = .failed("Invalid Emby username or password.")
        } catch EmbyAuthError.http(let status) {
            guard activeEmbyCredentialAttemptID == attemptID else { return }
            activeEmbyCredentialAttemptID = nil
            state = .failed("Emby sign-in failed (HTTP \(status)).")
        } catch EmbyAuthError.missingCredentials {
            guard activeEmbyCredentialAttemptID == attemptID else { return }
            activeEmbyCredentialAttemptID = nil
            state = .failed("Emby did not return a usable session.")
        } catch EmbyAuthError.secureStorageFailed {
            guard activeEmbyCredentialAttemptID == attemptID else { return }
            activeEmbyCredentialAttemptID = nil
            state = .failed("Couldn’t securely save the Emby session.")
        } catch {
            guard activeEmbyCredentialAttemptID == attemptID else { return }
            activeEmbyCredentialAttemptID = nil
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
        appModel.embyServerBaseURL = server
        appModel.embyAccessToken = token
        appModel.embyUserID = userID
        appModel.embyServerID = serverID
    }

    // MARK: - Emby Connect PIN sign-in (GH #72)

    /// Start the Emby Connect PIN flow: mint a short code, display it, and poll
    /// connect.emby.media until the user confirms it at emby.media/pin.html. Unlike the
    /// username/password path this needs no server URL — Connect discovers the linked
    /// servers itself. Mirrors `startJellyfinQuickConnect` but against Emby's cloud host.
    func startEmbyConnect() async {
        cancelPendingLogin()
        let attemptID = UUID()
        activeEmbyConnectAttemptID = attemptID
        appModel.activeBackend = .emby
        keychain.selectedBackend = .emby
        state = .idle

        do {
            let data = try await embyConnectData(for: EmbyConnect.createPinRequest(identity: embyIdentity))
            guard activeEmbyConnectAttemptID == attemptID else { return }
            let pin = try JSONDecoder().decode(EmbyConnectPin.self, from: data)
            guard let code = pin.pin, !code.isEmpty else { throw EmbyAuthError.missingCredentials }

            guard activeEmbyConnectAttemptID == attemptID else { return }
            state = .awaitingEmbyConnectPin(code: code)
            pollTask = Task { await pollEmbyConnectPin(pin: code, attemptID: attemptID) }
        } catch EmbyAuthError.http(let status) {
            guard activeEmbyConnectAttemptID == attemptID else { return }
            activeEmbyConnectAttemptID = nil
            state = .failed("Emby Connect sign-in failed (HTTP \(status)).")
        } catch EmbyAuthError.missingCredentials {
            guard activeEmbyConnectAttemptID == attemptID else { return }
            activeEmbyConnectAttemptID = nil
            state = .failed("Emby Connect did not return a code. Use a server URL instead.")
        } catch {
            guard activeEmbyConnectAttemptID == attemptID else { return }
            activeEmbyConnectAttemptID = nil
            state = .failed("Couldn’t reach Emby Connect.")
        }
    }

    /// Resume the flow after the user picks one of several linked servers.
    func selectEmbyConnectServer(id: String) async {
        guard let attemptID = activeEmbyConnectAttemptID,
              let pending = pendingEmbyConnect,
              let server = pending.servers.first(where: { serverChoiceID($0) == id }) else {
            // The attempt ended out from under the picker (cancel / backend switch / expiry).
            // Drop back to the chooser instead of leaving the user tapping a dead list.
            if case .awaitingEmbyServerSelection = state { state = .idle }
            return
        }
        guard activeEmbyConnectServerSelectionID == nil else { return }
        activeEmbyConnectServerSelectionID = id
        defer {
            if activeEmbyConnectServerSelectionID == id {
                activeEmbyConnectServerSelectionID = nil
            }
        }
        await exchangeAndPersistEmbyConnect(server: server,
                                            connectUserId: pending.connectUserId,
                                            attemptID: attemptID)
    }

    private func pollEmbyConnectPin(pin: String, attemptID: UUID) async {
        let deadline = ContinuousClock.now.advanced(by: embyConnectPollTimeout)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: embyConnectPollInterval)
            if Task.isCancelled { return }
            guard activeEmbyConnectAttemptID == attemptID else { return }

            do {
                let data = try await embyConnectData(for: EmbyConnect.pollPinRequest(pin: pin, identity: embyIdentity))
                let status = try JSONDecoder().decode(EmbyConnectPin.self, from: data)
                if status.isExpired {
                    failEmbyConnect(attemptID, "Emby Connect code expired. Try again.")
                    return
                }
                guard status.isConfirmed else { continue }
                await completeEmbyConnectAfterConfirmation(pin: pin, attemptID: attemptID)
                return
            } catch EmbyAuthError.http(404) {
                failEmbyConnect(attemptID, "Emby Connect code expired or was cancelled. Try again.")
                return
            } catch EmbyAuthError.unauthorized {
                // A rejected device/app won't recover by polling — fail fast instead of
                // spinning for the full timeout.
                failEmbyConnect(attemptID, "Emby Connect rejected this device. Try again or use a server URL.")
                return
            } catch {
                // Transient network/server errors can happen while the user is still
                // entering the code — keep polling until the deadline.
                continue
            }
        }
        failEmbyConnect(attemptID, "Emby Connect timed out. Try again or use a server URL.")
    }

    /// PIN confirmed → exchange it for a Connect token, list linked servers, then either
    /// auto-exchange (one server) or ask the user to choose (more than one).
    private func completeEmbyConnectAfterConfirmation(pin: String, attemptID: UUID) async {
        do {
            let authData = try await embyConnectData(for: EmbyConnect.authenticatePinRequest(pin: pin, identity: embyIdentity))
            let authResult = try JSONDecoder().decode(EmbyConnectExchangePinResult.self, from: authData)
            guard let connectUserId = authResult.userId, !connectUserId.isEmpty,
                  let connectToken = authResult.accessToken, !connectToken.isEmpty else {
                throw EmbyAuthError.missingCredentials
            }

            let serversData = try await embyConnectData(for: EmbyConnect.serversRequest(
                connectUserId: connectUserId, connectToken: connectToken, identity: embyIdentity))
            let servers = try JSONDecoder().decode([EmbyConnectServer].self, from: serversData)
            guard activeEmbyConnectAttemptID == attemptID else { return }
            guard !servers.isEmpty else {
                failEmbyConnect(attemptID, "No Emby servers are linked to this Connect account.")
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
                state = .awaitingEmbyServerSelection(servers: servers.map(serverChoice))
            }
        } catch EmbyAuthError.http(let status) {
            failEmbyConnect(attemptID, "Emby Connect sign-in failed (HTTP \(status)).")
        } catch EmbyAuthError.missingCredentials {
            failEmbyConnect(attemptID, "Emby Connect did not return a usable session.")
        } catch {
            failEmbyConnect(attemptID, "Couldn’t complete Emby Connect sign-in.")
        }
    }

    /// Exchange the chosen server's access key for a normal local token, then persist the
    /// session via the shared Emby persistence so restore/refresh matches manual login.
    private func exchangeAndPersistEmbyConnect(server: EmbyConnectServer,
                                               connectUserId: String,
                                               attemptID: UUID) async {
        do {
            guard let accessKey = server.accessKey, !accessKey.isEmpty else {
                throw EmbyAuthError.missingCredentials
            }
            guard let expectedSystemID = server.systemId, !expectedSystemID.isEmpty else {
                failEmbyConnect(attemptID, "Emby Connect did not identify the selected server. Use a server URL instead.")
                return
            }
            guard let base = await resolveEmbyServerBaseURL(server, expectedSystemID: expectedSystemID) else {
                failEmbyConnect(attemptID, "Couldn’t reach the selected Emby server.")
                return
            }
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
            guard activeEmbyConnectAttemptID == attemptID else { return }
            try persistEmbySession(server: base, token: token, userID: userID, serverID: expectedSystemID)
            activeEmbyConnectAttemptID = nil
            pendingEmbyConnect = nil
            pollTask = nil
            state = .authenticated
        } catch EmbyAuthError.http(let status) {
            failEmbyConnect(attemptID, "Emby server exchange failed (HTTP \(status)).")
        } catch EmbyAuthError.missingCredentials {
            failEmbyConnect(attemptID, "The Emby server did not return a usable session.")
        } catch EmbyAuthError.secureStorageFailed {
            failEmbyConnect(attemptID, "Couldn’t securely save the Emby session.")
        } catch {
            failEmbyConnect(attemptID, "Couldn’t complete Emby sign-in with the selected server.")
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
        // Short timeout on the LAN probe so it fails over fast when away from home; the WAN
        // probe uses the normal session so a slow internet path isn't cut off prematurely.
        if let localBase, await embyServerIdentityMatches(localBase, expectedSystemID: expectedSystemID, session: Self.probeSession) {
            return localBase
        }
        if let wanBase, await embyServerIdentityMatches(wanBase, expectedSystemID: expectedSystemID, session: Self.jellyfinSession) {
            return wanBase
        }
        return nil
    }

    private func embyConnectBase(_ address: String?) -> URL? {
        guard let address, !address.isEmpty else { return nil }
        return try? EmbyConnect.apiBaseURL(forConnectAddress: address)
    }

    private func embyServerIdentityMatches(_ base: URL, expectedSystemID: String, session: URLSession) async -> Bool {
        guard let request = try? EmbyAuth.serverInfoRequest(server: base),
              let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return false
        }
        // Require the probed server identity to match before we trust it with the
        // per-server access key. Missing/garbled info → reject closed.
        guard let info = try? JSONDecoder().decode(EmbyServerInfo.self, from: data) else { return false }
        return info.id == expectedSystemID
    }

    private func failEmbyConnect(_ attemptID: UUID, _ message: String) {
        guard activeEmbyConnectAttemptID == attemptID else { return }
        activeEmbyConnectAttemptID = nil
        activeEmbyConnectServerSelectionID = nil
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
        let (data, response) = try await Self.jellyfinSession.data(for: request)
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
        let (data, response) = try await Self.jellyfinSession.data(for: request)
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
        let req = ResourceDiscovery.resourcesRequest(token: accountToken, identity: appModel.identity)
        let resources = try await appModel.client.send(req, as: ResourcesResponse.self)

        // Only devices that act as a media server.
        let servers = resources.devices.filter {
            ($0.provides ?? "").contains("server")
        }
        let preferredID = keychain.selectedPlexServerID
            ?? appModel.selectedServer?.clientIdentifier
        appModel.plexServers = servers
        // Do NOT clear selectedServer/serverToken/serverBaseURL up front. Nulling them here
        // dropped `isBrowseReady` to false for the entire discovery window, so switching TO Plex
        // made ContentView swap RootView for the "Connecting…" splash and rebuild at Home —
        // unlike a Jellyfin↔Emby switch, whose already-hydrated lane keeps `isBrowseReady` true.
        // Keep the existing connection live until a new one is resolved (applyPlexServerSelection
        // overwrites on success); only clear below if discovery finds nothing reachable.

        let candidates: [PlexDevice]
        if let preferredID, let preferred = servers.first(where: { $0.clientIdentifier == preferredID }) {
            candidates = [preferred] + servers.filter { $0.clientIdentifier != preferredID }
        } else {
            candidates = servers
        }

        for server in candidates {
            do {
                try await applyPlexServerSelection(server, persist: preferredID == nil || preferredID != server.clientIdentifier)
                return
            } catch PlexError.serverUnreachable {
                continue
            }
        }
        // No reachable server — now clear the stale selection so `isBrowseReady` honestly reports
        // not-ready (the caller surfaces a discovery-failed/sign-out state).
        appModel.selectedServer = nil
        appModel.serverToken = nil
        appModel.serverBaseURL = nil
        appModel.selectedServerConnectionIsLocal = false
        throw PlexError.serverUnreachable
    }

    /// Select a Plex server from Settings and persist that server identity for future launches.
    func selectPlexServer(id serverID: String) async throws {
        guard let server = appModel.plexServers.first(where: { $0.clientIdentifier == serverID }) else {
            throw PlexError.serverUnreachable
        }
        try await applyPlexServerSelection(server, persist: true)
    }

    /// Fetch non-secret Plex account display metadata for Settings. Failure is non-fatal:
    /// browsing and playback are server-token driven, and Settings can show "Unavailable".
    func refreshPlexAccountProfile() async {
        guard let token = appModel.token else {
            appModel.plexAccountProfile = nil
            return
        }
        do {
            let req = PlexAccount.profileRequest(token: token, identity: appModel.identity)
            appModel.plexAccountProfile = try await appModel.client.send(req, as: PlexAccountProfile.self)
        } catch {
            appModel.plexAccountProfile = nil
        }
    }

    private func applyPlexServerSelection(_ server: PlexDevice, persist: Bool) async throws {
        guard let accountToken = appModel.token else { throw PlexError.unauthorized }
        let serverToken = server.accessToken ?? accountToken

        // A server advertises every interface as a "local" connection, including
        // unreachable container/VPN ones (e.g. a Docker 10.42.x.x bridge) and, in
        // some setups, stale/reverse-proxy URLs that can answer as a different
        // Plex server. Probe candidates in priority order and require `/identity`
        // to return this server's machine identifier before accepting a URL.
        let ranked = ResourceDiscovery.rankedConnections(server.connections)
        guard let selectedConnection = await firstReachable(ranked,
                                                            token: serverToken,
                                                            expectedMachineIdentifier: server.clientIdentifier) else {
            throw PlexError.serverUnreachable
        }

        appModel.selectedServer = server
        appModel.serverToken = serverToken
        appModel.serverBaseURL = selectedConnection.url
        appModel.selectedServerConnectionIsLocal = selectedConnection.isLocal
        if persist {
            keychain.selectedPlexServerID = server.clientIdentifier
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
        switch appModel.activeBackend {
        case .plex:
            signOutPlex()
        case .jellyfin:
            signOutJellyfin()
        case .emby:
            signOutEmby()
        }
        state = .idle
    }

    private func signOutPlex() {
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
        switch backend {
        case .plex:
            appModel.token = nil
            appModel.serverToken = nil
            appModel.selectedServer = nil
            appModel.plexServers = []
            appModel.serverBaseURL = nil
            appModel.plexAccountProfile = nil
            appModel.selectedServerConnectionIsLocal = false
        case .jellyfin:
            appModel.jellyfinServerBaseURL = nil
            appModel.jellyfinAccessToken = nil
            appModel.jellyfinUserID = nil
            appModel.jellyfinServerID = nil
        case .emby:
            appModel.embyServerBaseURL = nil
            appModel.embyAccessToken = nil
            appModel.embyUserID = nil
            appModel.embyServerID = nil
        }
    }

    func cancelPendingLogin() {
        pollTask?.cancel()
        pollTask = nil
        activePinIDs = []
        activeJellyfinQuickConnectAttemptID = nil
        activeJellyfinCredentialAttemptID = nil
        activeEmbyConnectAttemptID = nil
        activeEmbyCredentialAttemptID = nil
        activeEmbyConnectServerSelectionID = nil
        pendingEmbyConnect = nil
    }

    private var jellyfinIdentity: JellyfinClientIdentity {
        appModel.identity.jellyfin
    }

    private var embyIdentity: EmbyClientIdentity {
        appModel.identity.emby
    }

    private static let jellyfinSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()
}

/// In-flight Emby Connect state held while the user picks among multiple linked servers.
/// In-memory only; carries per-server access keys, so it is never logged or persisted.
private struct PendingEmbyConnect {
    let connectUserId: String
    let servers: [EmbyConnectServer]
}

private enum JellyfinAuthError: Error {
    case unauthorized
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
        switch self {
        case .plex: return .plex
        case .jellyfin: return .jellyfin
        case .emby: return .emby
        }
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
