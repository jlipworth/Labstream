import Foundation
import Observation
import PlexKit

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
    private var activePinID: Int?

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

    /// Start a fresh login: create a PIN and surface the auth URL for the UI to open.
    /// Returns the URL the UI should present.
    func createPin() async throws -> URL {
        cancelPendingLogin()
        let createReq = PinAuth.createPinRequest(identity: appModel.identity)
        let pin = try await appModel.client.send(createReq, as: PinResponse.self)
        let authURL = PinAuth.authAppURL(code: pin.code, identity: appModel.identity)
        activePinID = pin.id
        state = .awaitingAuthorization(code: pin.code, url: authURL)

        // Kick off polling in the background; UI observes `state`.
        pollTask = Task { await pollForToken(pinID: pin.id) }
        return authURL
    }

    /// Poll the PIN until it carries an `authToken` or we time out.
    private func pollForToken(pinID: Int) async {
        let deadline = ContinuousClock.now.advanced(by: pollTimeout)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: pollInterval)
            if Task.isCancelled { return }
            guard activePinID == pinID else { return }

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
        guard activePinID == pinID else { return }
        activePinID = nil
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
            activePinID = nil
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
        activePinID = nil
    }
}
