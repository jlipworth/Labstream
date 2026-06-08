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
        state = .authenticated
        try? await refreshServers()
        return true
    }

    /// Start a fresh login: create a PIN and surface the auth URL for the UI to open.
    /// Returns the URL the UI should present.
    func createPin() async throws -> URL {
        let createReq = PinAuth.createPinRequest(identity: appModel.identity)
        let pin = try await appModel.client.send(createReq, as: PinResponse.self)
        let authURL = PinAuth.authAppURL(code: pin.code, identity: appModel.identity)
        state = .awaitingAuthorization(code: pin.code, url: authURL)

        // Kick off polling in the background; UI observes `state`.
        Task { await pollForToken(pinID: pin.id) }
        return authURL
    }

    /// Poll the PIN until it carries an `authToken` or we time out.
    private func pollForToken(pinID: Int) async {
        let deadline = ContinuousClock.now.advanced(by: pollTimeout)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: pollInterval)
            if Task.isCancelled { return }

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
        state = .failed("Authorization timed out.")
    }

    /// Persist the token, update the model, and discover servers.
    private func finishLogin(token: String) async {
        keychain.token = token
        appModel.token = token
        state = .authenticated
        do {
            try await refreshServers()
        } catch {
            // Authenticated but discovery failed; leave server selection empty.
            state = .failed("Signed in, but server discovery failed.")
        }
    }

    /// Run resource discovery and select the best server/connection.
    func refreshServers() async throws {
        guard let token = appModel.token else { throw PlexError.unauthorized }
        let req = ResourceDiscovery.resourcesRequest(token: token, identity: appModel.identity)
        let resources = try await appModel.client.send(req, as: ResourcesResponse.self)

        // Only devices that act as a media server.
        let servers = resources.devices.filter {
            ($0.provides ?? "").contains("server")
        }
        let chosen = servers.first { !$0.connections.isEmpty } ?? servers.first
        guard let server = chosen,
              let best = ResourceDiscovery.bestConnection(server.connections),
              let url = URL(string: best.uri)
        else { return }

        appModel.selectedServer = server
        appModel.serverBaseURL = url
    }

    /// Clear all auth state and return to login. Call on sign-out or any 401.
    func signOut() {
        keychain.token = nil
        appModel.token = nil
        appModel.selectedServer = nil
        appModel.serverBaseURL = nil
        state = .idle
    }
}
