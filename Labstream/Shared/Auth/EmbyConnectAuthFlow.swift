import Foundation
import PMSKit

/// Owns the secret-bearing, in-memory state and backend operations for one Emby Connect flow.
///
/// This type deliberately does not own an authorization generation or a polling `Task`.
/// `AuthManager` remains the single publication authority and
/// `AuthorizationPollingCoordinator` remains the single polling-task owner. Callers supply an
/// exact-attempt check so this flow can fence every credential-bearing follow-up and commit.
@MainActor
final class EmbyConnectAuthFlow {
    enum Completion {
        case superseded
        case serverSelectionRequired([AuthManager.EmbyConnectServerChoice])
        case authenticated
    }

    enum SelectionResult {
        case stale
        case ignored
        case superseded
        case authenticated
    }

    struct Failure: Error {
        let message: String
        let reason: String
        let fields: [String: DiagnosticFieldValue]

        init(_ message: String,
             reason: String,
             fields: [String: DiagnosticFieldValue] = [:]) {
            self.message = message
            self.reason = reason
            self.fields = fields
        }
    }

    private struct PendingConnect {
        let connectUserID: String
        let servers: [EmbyConnectServer]
    }

    struct SelectionLease: Equatable {
        let attemptID: AuthAttemptID
        let serverID: String
    }

    struct SelectionAuthority {
        private(set) var active: SelectionLease?

        mutating func begin(attemptID: AuthAttemptID, serverID: String) -> SelectionLease? {
            guard active == nil else { return nil }
            let lease = SelectionLease(attemptID: attemptID, serverID: serverID)
            active = lease
            return lease
        }

        mutating func finish(_ lease: SelectionLease) {
            guard active == lease else { return }
            active = nil
        }

        mutating func cancel() { active = nil }
    }

    private let appModel: AppModel
    private let keychain: KeychainStore
    private let dataLoader: (URLRequest) async throws -> (Data, URLResponse)
    private var pendingConnect: PendingConnect?
    private var selectionAuthority = SelectionAuthority()

    init(appModel: AppModel,
         keychain: KeychainStore,
         dataLoader: @escaping (URLRequest) async throws -> (Data, URLResponse)) {
        self.appModel = appModel
        self.keychain = keychain
        self.dataLoader = dataLoader
    }

    /// Drops all secret-bearing pending state. Exact-owner task cancellation remains outside.
    func reset() {
        selectionAuthority.cancel()
        pendingConnect = nil
    }

    func createPIN() async throws -> String {
        let data = try await connectData(for: EmbyConnect.createPinRequest(identity: identity))
        let pin = try JSONDecoder().decode(EmbyConnectPin.self, from: data)
        guard let code = pin.pin, !code.isEmpty else { throw EmbyAuthError.missingCredentials }
        return code
    }

    func pollPIN(_ pin: String) async throws -> EmbyConnectPin {
        let data = try await connectData(for: EmbyConnect.pollPinRequest(pin: pin, identity: identity))
        return try JSONDecoder().decode(EmbyConnectPin.self, from: data)
    }

    /// Completes the cloud exchange and either commits a one-server session or privately retains
    /// the linked-server secrets while the user chooses among non-secret display choices.
    func completeConfirmedPIN(_ pin: String,
                              isCurrent: @escaping @MainActor () -> Bool) async throws -> Completion {
        guard isCurrent() else { return .superseded }
        record("auth.emby_connect.confirm_start")

        let authData = try await connectData(
            for: EmbyConnect.authenticatePinRequest(pin: pin, identity: identity)
        )
        guard isCurrent() else { return .superseded }
        let authResult = try JSONDecoder().decode(EmbyConnectExchangePinResult.self, from: authData)
        guard let connectUserID = authResult.userId, !connectUserID.isEmpty,
              let connectToken = authResult.accessToken, !connectToken.isEmpty else {
            throw EmbyAuthError.missingCredentials
        }
        record("auth.emby_connect.confirm_authenticated")

        // The Connect token is first attached only after the exact global attempt is rechecked.
        guard isCurrent() else { return .superseded }
        let serversData = try await connectData(for: EmbyConnect.serversRequest(
            connectUserId: connectUserID,
            connectToken: connectToken,
            identity: identity
        ))
        guard isCurrent() else { return .superseded }
        let servers = try JSONDecoder().decode([EmbyConnectServer].self, from: serversData)
        record("auth.emby_connect.servers_listed",
               fields: ["server_count": .string(serverCountBucket(servers.count))])
        guard !servers.isEmpty else {
            throw Failure("No Emby servers are linked to this Connect account.",
                          reason: "no_linked_servers")
        }

        if servers.count == 1 {
            return try await performExchange(server: servers[0],
                                             connectUserID: connectUserID,
                                             isCurrent: isCurrent)
                ? .authenticated : .superseded
        }

        pendingConnect = PendingConnect(connectUserID: connectUserID, servers: servers)
        record("auth.emby_connect.server_selection_required",
               fields: ["server_count": .string(serverCountBucket(servers.count))])
        return .serverSelectionRequired(servers.map(serverChoice))
    }

    func selectServer(id: String,
                      attemptID: AuthAttemptID,
                      isCurrent: @escaping @MainActor () -> Bool) async throws -> SelectionResult {
        guard isCurrent(),
              let pending = pendingConnect,
              let server = pending.servers.first(where: { serverChoiceID($0) == id }) else {
            return .stale
        }
        guard let lease = selectionAuthority.begin(attemptID: attemptID, serverID: id) else {
            return .ignored
        }
        record("auth.emby_connect.server_selected",
               fields: ["server_count": .string(serverCountBucket(pending.servers.count))])
        defer {
            // A stale completion must never clear a replacement selection.
            selectionAuthority.finish(lease)
        }

        let authenticated = try await performExchange(server: server,
                                                      connectUserID: pending.connectUserID,
                                                      isCurrent: isCurrent)
        guard authenticated else { return .superseded }
        pendingConnect = nil
        return .authenticated
    }

    /// Keeps exchange-specific user messaging and diagnostic reasons stable even when a
    /// one-server exchange is reached from the PIN-confirmation method.
    private func performExchange(server: EmbyConnectServer,
                                 connectUserID: String,
                                 isCurrent: @escaping @MainActor () -> Bool) async throws -> Bool {
        do {
            return try await exchangeAndPersist(server: server,
                                                connectUserID: connectUserID,
                                                isCurrent: isCurrent)
        } catch let failure as Failure {
            throw failure
        } catch EmbyAuthError.http(let status) {
            throw Failure("Emby server exchange failed (HTTP \(status)).",
                          reason: "exchange_http",
                          fields: ["status": .int(status)])
        } catch EmbyAuthError.missingCredentials {
            throw Failure("The Emby server did not return a usable session.",
                          reason: "exchange_missing_credentials")
        } catch EmbyAuthError.secureStorageFailed {
            throw Failure("Couldn’t securely save the Emby session.", reason: "secure_storage")
        } catch {
            throw Failure("Couldn’t complete Emby sign-in with the selected server.",
                          reason: "exchange_failed",
                          fields: errorFields(error))
        }
    }

    private func exchangeAndPersist(server: EmbyConnectServer,
                                    connectUserID: String,
                                    isCurrent: @escaping @MainActor () -> Bool) async throws -> Bool {
        record("auth.emby_connect.exchange_start")
        guard let accessKey = server.accessKey, !accessKey.isEmpty else {
            throw EmbyAuthError.missingCredentials
        }
        guard let expectedSystemID = server.systemId, !expectedSystemID.isEmpty else {
            throw Failure(
                "Emby Connect did not identify the selected server. Use a server URL instead.",
                reason: "missing_system_id"
            )
        }
        guard let base = await resolveServerBaseURL(
            server,
            expectedSystemID: expectedSystemID,
            isCurrent: isCurrent
        ) else {
            throw Failure("Couldn’t reach the selected Emby server.", reason: "resolve_failed")
        }

        // The per-server access key must not leave the process after authority is superseded.
        guard isCurrent() else { return false }
        let request = try EmbyConnect.exchangeRequest(server: base,
                                                      accessKey: accessKey,
                                                      connectUserId: connectUserID,
                                                      identity: identity)
        let data = try await connectData(for: request)
        let result = try JSONDecoder().decode(EmbyConnectExchangeResult.self, from: data)
        guard let token = result.accessToken, !token.isEmpty,
              let userID = result.localUserId, !userID.isEmpty else {
            throw EmbyAuthError.missingCredentials
        }

        // Secure persistence and runtime publication form the final exact-attempt commit.
        guard isCurrent() else { return false }
        guard keychain.saveEmbySession(serverURLString: base.absoluteString,
                                       accessToken: token,
                                       userID: userID,
                                       serverID: expectedSystemID) else {
            throw EmbyAuthError.secureStorageFailed
        }
        appModel.applyMediaBrowserSession(backend: .emby,
                                          server: base,
                                          token: token,
                                          userID: userID,
                                          serverID: expectedSystemID)
        record("auth.emby_connect.exchange_success")
        return true
    }

    private func resolveServerBaseURL(
        _ server: EmbyConnectServer,
        expectedSystemID: String,
        isCurrent: @escaping @MainActor () -> Bool
    ) async -> URL? {
        guard isCurrent() else { return nil }
        let localBase = connectBase(server.localAddress)
        let wanBase = connectBase(server.url)
        record("auth.emby_connect.resolve_start", fields: [
            "has_local": .bool(localBase != nil),
            "has_wan": .bool(wanBase != nil)
        ])
        if let localBase, await serverIdentityMatches(localBase,
                                                      expectedSystemID: expectedSystemID,
                                                      session: Self.probeSession,
                                                      route: "local") {
            record("auth.emby_connect.resolve_success", fields: ["route": .string("local")])
            return localBase
        } else if localBase == nil {
            record("auth.emby_connect.identity_probe_skipped", fields: [
                "route": .string("local"), "reason": .string("missing_candidate")
            ])
        }
        // A local identity probe suspends. Do not start the WAN fallback after the global auth
        // attempt has been cancelled or replaced.
        guard isCurrent() else { return nil }
        if let wanBase, await serverIdentityMatches(wanBase,
                                                    expectedSystemID: expectedSystemID,
                                                    session: Self.authSession,
                                                    route: "wan") {
            record("auth.emby_connect.resolve_success", fields: ["route": .string("wan")])
            return wanBase
        } else if wanBase == nil {
            record("auth.emby_connect.identity_probe_skipped", fields: [
                "route": .string("wan"), "reason": .string("missing_candidate")
            ])
        }
        record("auth.emby_connect.resolve_failed")
        return nil
    }

    private func serverIdentityMatches(_ base: URL,
                                       expectedSystemID: String,
                                       session: URLSession,
                                       route: String) async -> Bool {
        let baseFields: [String: DiagnosticFieldValue] = ["route": .string(route)]
        guard let request = try? EmbyAuth.serverInfoRequest(server: base) else {
            record("auth.emby_connect.identity_probe_failed",
                   fields: merging(baseFields, "reason", .string("request_build_failed")))
            return false
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            var fields = baseFields
            fields.merge(errorFields(error)) { _, new in new }
            record("auth.emby_connect.identity_probe_transport", fields: fields)
            return false
        }
        guard let http = response as? HTTPURLResponse else {
            record("auth.emby_connect.identity_probe_failed",
                   fields: merging(baseFields, "reason", .string("non_http")))
            return false
        }
        guard (200..<300).contains(http.statusCode) else {
            record("auth.emby_connect.identity_probe_http",
                   fields: merging(baseFields, "status", .int(http.statusCode)))
            return false
        }
        guard let info = try? JSONDecoder().decode(EmbyServerInfo.self, from: data) else {
            var fields = baseFields
            fields["reason"] = .string("identity_decode_failed")
            fields["status"] = .int(http.statusCode)
            record("auth.emby_connect.identity_probe_failed", fields: fields)
            return false
        }
        guard info.id == expectedSystemID else {
            record("auth.emby_connect.identity_probe_mismatch",
                   fields: merging(baseFields, "status", .int(http.statusCode)))
            return false
        }
        record("auth.emby_connect.identity_probe_success",
               fields: merging(baseFields, "status", .int(http.statusCode)))
        return true
    }

    private func connectData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await dataLoader(request)
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 401, 403: throw EmbyAuthError.unauthorized
            default: throw EmbyAuthError.http(http.statusCode)
            }
        }
        return data
    }

    private var identity: EmbyClientIdentity { appModel.identity.emby }

    private func connectBase(_ address: String?) -> URL? {
        guard let address, !address.isEmpty else { return nil }
        return try? EmbyConnect.apiBaseURL(forConnectAddress: address)
    }

    private func serverChoice(_ server: EmbyConnectServer) -> AuthManager.EmbyConnectServerChoice {
        AuthManager.EmbyConnectServerChoice(id: serverChoiceID(server),
                                            name: server.name ?? "Emby Server",
                                            addressLabel: server.url ?? server.localAddress ?? "")
    }

    private func serverChoiceID(_ server: EmbyConnectServer) -> String {
        server.systemId ?? server.id ?? server.url ?? server.localAddress ?? ""
    }

    private func serverCountBucket(_ count: Int) -> String {
        switch count {
        case ..<1: return "none"
        case 1: return "one"
        case 2...4: return "multiple"
        default: return "many"
        }
    }

    private func record(_ name: String,
                        fields: [String: DiagnosticFieldValue] = [:]) {
        AppDiagnostics.record(.auth, name, fields: fields)
    }

    private func errorFields(_ error: Error) -> [String: DiagnosticFieldValue] {
        let nsError = error as NSError
        return [
            "error_class": .string(DiagnosticRedactor.errorClass(for: nsError)),
            "error_domain": .string(DiagnosticRedactor.errorDomainFamily(nsError.domain)),
            "error_code": .int(nsError.code)
        ]
    }

    private func merging(_ fields: [String: DiagnosticFieldValue],
                         _ key: String,
                         _ value: DiagnosticFieldValue) -> [String: DiagnosticFieldValue] {
        var result = fields
        result[key] = value
        return result
    }

    private static let probeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private static let authSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}
