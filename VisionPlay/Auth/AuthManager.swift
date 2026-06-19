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
        case authenticated
        case failed(String)
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
    private var pollTask: Task<Void, Never>?
    /// PINs being polled for the current login attempt (#16): the non-strong
    /// "link" PIN (its 4-char code is shown for plex.tv/link) and the strong
    /// PIN (its long code backs the in-headset web-auth URL). Whichever the
    /// user completes authorizes first; both clear when the attempt ends.
    private var activePinIDs: Set<Int> = []
    private var activeJellyfinQuickConnectAttemptID: UUID?

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

    /// Restore a previously-saved token (call on launch). Returns true if a token
    /// was found; the caller may then refresh discovery.
    @discardableResult
    func restoreSession() async -> Bool {
        appModel.activeBackend = keychain.selectedBackend
        switch appModel.activeBackend {
        case .plex:
            return await restorePlexSession()
        case .jellyfin:
            return await restoreJellyfinSession()
        }
    }

    private func restorePlexSession() async -> Bool {
        guard let saved = keychain.token else { return false }
        appModel.token = saved
        do {
            await refreshPlexAccountProfile()
            try await refreshServers()
            state = .authenticated
            return true
        } catch PlexError.unauthorized {
            signOut()
            return false
        } catch {
            state = .failed("Signed in, but server discovery failed.")
            return true
        }
    }

    private func restoreJellyfinSession() async -> Bool {
        guard let urlString = keychain.jellyfinServerURLString,
              let server = URL(string: urlString),
              let token = keychain.jellyfinAccessToken,
              let userID = keychain.jellyfinUserID else { return false }
        appModel.jellyfinServerBaseURL = server
        appModel.jellyfinAccessToken = token
        appModel.jellyfinUserID = userID
        appModel.jellyfinServerID = keychain.jellyfinServerID
        do {
            let req = try JellyfinLibrary.userViewsRequest(server: server,
                                                           token: token,
                                                           identity: jellyfinIdentity,
                                                           userId: userID)
            let (_, response) = try await Self.jellyfinSession.data(for: req)
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200..<300: break
                case 401, 403: throw JellyfinAuthError.unauthorized
                default: throw JellyfinAuthError.http(http.statusCode)
                }
            }
            state = .authenticated
            return true
        } catch JellyfinAuthError.unauthorized {
            signOutJellyfin()
            return false
        } catch {
            state = .failed("Signed in, but the Jellyfin server could not be reached.")
            return true
        }
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
            try persistJellyfinAuthentication(result, server: server)
            state = .authenticated
        } catch JellyfinAuthError.unauthorized {
            state = .failed("Invalid Jellyfin username or password.")
        } catch JellyfinAuthError.http(let status) {
            state = .failed("Jellyfin sign-in failed (HTTP \(status)).")
        } catch JellyfinAuthError.missingCredentials {
            state = .failed("Jellyfin did not return a usable session.")
        } catch {
            state = .failed("Couldn’t reach Jellyfin server.")
        }
    }

    func startJellyfinQuickConnect(server: URL) async {
        cancelPendingLogin()
        appModel.activeBackend = .jellyfin
        keychain.selectedBackend = .jellyfin
        state = .idle

        do {
            if let enabled = try await jellyfinQuickConnectEnabled(server: server), enabled == false {
                state = .failed("Jellyfin Quick Connect is disabled on this server. Use username and password instead.")
                return
            }

            let request = JellyfinAuth.initiateQuickConnectRequest(server: server,
                                                                   identity: jellyfinIdentity)
            let data = try await jellyfinData(for: request, disabledMeansUnauthorized: true)
            let result = try JSONDecoder().decode(JellyfinQuickConnectResult.self, from: data)
            guard let code = result.code, !code.isEmpty,
                  let secret = result.secret, !secret.isEmpty else {
                throw JellyfinAuthError.missingCredentials
            }

            let attemptID = UUID()
            activeJellyfinQuickConnectAttemptID = attemptID
            state = .awaitingJellyfinQuickConnect(code: code)
            pollTask = Task { await pollJellyfinQuickConnect(server: server,
                                                             secret: secret,
                                                             attemptID: attemptID) }
        } catch JellyfinAuthError.quickConnectDisabled {
            state = .failed("Jellyfin Quick Connect is disabled on this server. Use username and password instead.")
        } catch JellyfinAuthError.unauthorized {
            state = .failed("Jellyfin Quick Connect is disabled on this server. Use username and password instead.")
        } catch JellyfinAuthError.http(let status) {
            state = .failed("Jellyfin Quick Connect failed (HTTP \(status)).")
        } catch JellyfinAuthError.missingCredentials {
            state = .failed("Jellyfin did not return a Quick Connect code. Use username and password instead.")
        } catch {
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
        keychain.jellyfinServerURLString = server.absoluteString
        keychain.jellyfinAccessToken = token
        keychain.jellyfinUserID = userID
        keychain.jellyfinServerID = result.serverId
        appModel.jellyfinServerBaseURL = server
        appModel.jellyfinAccessToken = token
        appModel.jellyfinUserID = userID
        appModel.jellyfinServerID = result.serverId
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
        appModel.selectedServer = nil
        appModel.serverToken = nil
        appModel.serverBaseURL = nil
        appModel.selectedServerConnectionIsLocal = false

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
        }
        state = .idle
    }

    private func signOutPlex() {
        keychain.token = nil
        keychain.selectedPlexServerID = nil
        clearRuntimeState(for: .plex)
    }

    private func signOutJellyfin() {
        keychain.jellyfinServerURLString = nil
        keychain.jellyfinAccessToken = nil
        keychain.jellyfinUserID = nil
        keychain.jellyfinServerID = nil
        clearRuntimeState(for: .jellyfin)
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
        }
    }

    func cancelPendingLogin() {
        pollTask?.cancel()
        pollTask = nil
        activePinIDs = []
        activeJellyfinQuickConnectAttemptID = nil
    }

    private var jellyfinIdentity: JellyfinClientIdentity {
        JellyfinClientIdentity(client: appModel.identity.product,
                               device: appModel.identity.deviceName,
                               deviceId: appModel.identity.clientIdentifier,
                               version: appModel.identity.version)
    }

    private static let jellyfinSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()
}

private enum JellyfinAuthError: Error {
    case unauthorized
    case quickConnectDisabled
    case http(Int)
    case missingCredentials
}

private extension MediaBackendKind {
    var switchChoice: MediaBackendChoice {
        switch self {
        case .plex: return .plex
        case .jellyfin: return .jellyfin
        }
    }
}

private extension KeychainStore {
    var mediaBackendCredentialSnapshot: MediaBackendCredentialSnapshot {
        MediaBackendCredentialSnapshot(plexToken: token,
                                       jellyfinServerURLString: jellyfinServerURLString,
                                       jellyfinAccessToken: jellyfinAccessToken,
                                       jellyfinUserID: jellyfinUserID)
    }
}
