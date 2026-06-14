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
        case authenticated
        case failed(String)
    }

    private(set) var state: State = .idle

    private let appModel: AppModel
    private let keychain: KeychainStore

    /// Poll cadence and ceiling for the PIN flow.
    private let pollInterval: Duration = .seconds(1)
    private let pollTimeout: Duration = .seconds(300)
    private var pollTask: Task<Void, Never>?
    /// PINs being polled for the current login attempt (#16): the non-strong
    /// "link" PIN (its 4-char code is shown for plex.tv/link) and the strong
    /// PIN (its long code backs the in-headset web-auth URL). Whichever the
    /// user completes authorizes first; both clear when the attempt ends.
    private var activePinIDs: Set<Int> = []

    init(appModel: AppModel, keychain: KeychainStore = KeychainStore()) {
        self.appModel = appModel
        self.keychain = keychain
    }

    /// Restore a previously-saved token (call on launch). Returns true if a token
    /// was found; the caller may then refresh discovery.
    @discardableResult
    func restoreSession() async -> Bool {
        guard let saved = keychain.token else { return false }
        appModel.token = saved
        do {
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

    /// Start a fresh login. Creates TWO PINs (#16): a non-strong one whose
    /// 4-character code the UI displays for plex.tv/link, and a strong one whose
    /// long code backs the `app.plex.tv/auth` web URL (a strong code cannot be
    /// typed at plex.tv/link, and the auth web page needs the strong one).
    /// Both are polled; whichever the user completes wins.
    /// Returns the URL the UI should present for the in-headset browser path.
    func createPin() async throws -> URL {
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
        guard keychain.saveToken(token) else {
            state = .failed("Couldn’t securely save the Plex token.")
            return
        }
        appModel.token = token
        do {
            try await refreshServers()
            activePinIDs = []
            pollTask = nil
            state = .authenticated
        } catch {
            state = .failed("Signed in, but server discovery failed.")
        }
    }

    /// Run resource discovery and select the best server/connection.
    func refreshServers() async throws {
        guard let accountToken = appModel.token else { throw PlexError.unauthorized }
        appModel.selectedServer = nil
        appModel.serverToken = nil
        appModel.serverBaseURL = nil
        let req = ResourceDiscovery.resourcesRequest(token: accountToken, identity: appModel.identity)
        let resources = try await appModel.client.send(req, as: ResourcesResponse.self)

        // Only devices that act as a media server.
        let servers = resources.devices.filter {
            ($0.provides ?? "").contains("server")
        }
        let chosen = servers.first { !$0.connections.isEmpty } ?? servers.first
        guard let server = chosen else { throw PlexError.serverUnreachable }
        let serverToken = server.accessToken ?? accountToken

        // A server advertises every interface as a "local" connection, including
        // unreachable container/VPN ones (e.g. a Docker 10.42.x.x bridge). Probe
        // candidates in priority order and use the first that actually answers;
        // only fall back to the static best pick if none respond.
        let ranked = ResourceDiscovery.rankedConnections(server.connections)
        let url = await firstReachable(ranked, token: serverToken)
            ?? ResourceDiscovery.bestConnection(server.connections).flatMap { URL(string: $0.uri) }
        guard let url else { throw PlexError.serverUnreachable }

        appModel.selectedServer = server
        appModel.serverToken = serverToken
        appModel.serverBaseURL = url
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
    /// responds with a 2xx within the timeout. Returns nil if none answer.
    private func firstReachable(_ ranked: [PlexConnection], token: String) async -> URL? {
        await withTaskGroup(of: (Int, URL)?.self) { group in
            for (index, conn) in ranked.enumerated() {
                guard let base = URL(string: conn.uri) else { continue }
                group.addTask {
                    var req = URLRequest(url: base.appendingPathComponent("identity"))
                    req.setValue(token, forHTTPHeaderField: "X-Plex-Token")
                    req.setValue("application/json", forHTTPHeaderField: "Accept")
                    do {
                        let (_, resp) = try await Self.probeSession.data(for: req)
                        if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                            return (index, base)
                        }
                    } catch { /* unreachable / timed out */ }
                    return nil
                }
            }
            var best: (Int, URL)?
            for await result in group {
                if let r = result, best == nil || r.0 < best!.0 { best = r }
            }
            return best?.1
        }
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
            let (_, resp) = try await Self.probeSession.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    /// Clear all auth state and return to login. Call on sign-out or any 401.
    func signOut() {
        cancelPendingLogin()
        keychain.token = nil
        appModel.token = nil
        appModel.serverToken = nil
        appModel.selectedServer = nil
        appModel.serverBaseURL = nil
        state = .idle
    }

    func cancelPendingLogin() {
        pollTask?.cancel()
        pollTask = nil
        activePinIDs = []
    }
}
