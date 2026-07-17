import Foundation
import PMSKit
import Testing
@testable import Labstream

@MainActor
struct AuthSecureStorageTests {
    @Test func clientIdentityWriteFailureStillBuildsServicesForBackgroundDrain() throws {
        let store = KeychainStore(
            service: "com.visionplay.tests.identity.\(UUID().uuidString)",
            synchronizesPlexToken: false,
            writeInterceptor: { account, _ in
                account == KeychainStore.clientIdentifierKey ? false : nil
            })

        #expect(store.clientIdentifier() == nil)
        let services = try #require(AppServices.make(keychain: store))
        #expect(!services.appModel.identity.clientIdentifier.isEmpty)
    }

    @Test func backendSelectionDoesNotPublishWhenSecureWriteFails() {
        let store = KeychainStore(
            service: "com.visionplay.tests.backend.\(UUID().uuidString)",
            synchronizesPlexToken: false,
            writeInterceptor: { account, _ in
                account == KeychainStore.selectedBackendKey ? false : nil
            })
        let identity = PlatformClientIdentity.make(clientIdentifier: "test-auth-storage")
        let model = AppModel(identity: identity, activeBackend: .plex)
        let manager = AuthManager(appModel: model, keychain: store)

        #expect(manager.selectBackend(.emby) == false)
        #expect(model.activeBackend == .plex)
        #expect(manager.state == .failed("Couldn’t securely save the selected backend."))
    }

    @Test func supersededCredentialAttemptPerformsNoCredentialWritesAfterAwait() async throws {
        let writes = WriteRecorder()
        let store = KeychainStore(
            service: "com.visionplay.tests.attempt.\(UUID().uuidString)",
            synchronizesPlexToken: false,
            writeInterceptor: { account, _ in
                writes.record(account)
                return true
            })
        let gate = AuthResponseGate()
        let identity = PlatformClientIdentity.make(clientIdentifier: "test-auth-attempt")
        let model = AppModel(identity: identity, activeBackend: .plex)
        let manager = AuthManager(appModel: model, keychain: store) { request in
            await gate.hold(request: request)
        }
        let server = try #require(URL(string: "https://media.example.invalid"))

        let attemptA = Task {
            await manager.loginToJellyfin(server: server, username: "user", password: "password")
        }
        await gate.waitUntilHeld()
        #expect(manager.selectBackend(.plex))
        await gate.releaseJellyfinSuccess()
        await attemptA.value

        #expect(model.activeBackend == .plex)
        #expect(model.jellyfinAccessToken == nil)
        let credentialKeys: Set<String> = [
            KeychainStore.jellyfinServerURLKey,
            KeychainStore.jellyfinAccessTokenKey,
            KeychainStore.jellyfinUserIDKey,
            KeychainStore.jellyfinServerIDKey,
        ]
        #expect(writes.accounts.allSatisfy { !credentialKeys.contains($0) })
    }

    @Test func credentialPersistenceFailureNeverPublishesAuthenticatedRuntimeState() async throws {
        let store = KeychainStore(
            service: "com.visionplay.tests.credentials.\(UUID().uuidString)",
            synchronizesPlexToken: false,
            writeInterceptor: { account, _ in
                account == KeychainStore.jellyfinAccessTokenKey ? false : true
            })
        let identity = PlatformClientIdentity.make(clientIdentifier: "test-auth-failure")
        let model = AppModel(identity: identity, activeBackend: .plex)
        let manager = AuthManager(appModel: model, keychain: store) { request in
            let data = Data(#"{"User":{"Id":"user"},"AccessToken":"token","ServerId":"server"}"#.utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
        let server = try #require(URL(string: "https://media.example.invalid"))

        await manager.loginToJellyfin(server: server, username: "user", password: "password")

        #expect(model.jellyfinServerBaseURL == nil)
        #expect(model.jellyfinAccessToken == nil)
        #expect(model.jellyfinUserID == nil)
        #expect(manager.state == .failed("Couldn’t securely save the Jellyfin session."))
    }

    @Test func canceledCallerCleansItsAuthorityGeneration() async throws {
        let store = KeychainStore(service: "com.visionplay.tests.cancel.\(UUID().uuidString)",
                                  synchronizesPlexToken: false,
                                  writeInterceptor: { _, _ in true })
        let gate = AuthResponseGate()
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "cancel-test"))
        let manager = AuthManager(appModel: model, keychain: store) { request in
            await gate.hold(request: request)
        }
        let server = try #require(URL(string: "https://media.example.invalid"))
        let task = Task {
            await manager.loginToJellyfin(server: server, username: "user", password: "password")
        }
        await gate.waitUntilHeld()
        task.cancel()
        await gate.releaseJellyfinSuccess()
        await task.value

        #expect(manager.state == .idle)
        #expect(model.jellyfinAccessToken == nil)
        #expect(manager.selectBackend(.emby))
    }

    @Test func stalePlexRestoreCannotPersistOrPublishHeldDiscovery() async throws {
        let writes = WriteRecorder()
        let service = "com.visionplay.tests.plex-attempt.\(UUID().uuidString)"
        let store = KeychainStore(service: service,
                                  synchronizesPlexToken: false,
                                  usesDevelopmentFileStorage: true,
                                  writeInterceptor: { account, _ in
                                      writes.record(account)
                                      return nil
                                  })
        #expect(store.saveToken("saved-token"))
        #expect(store.saveSelectedBackend(.plex))
        writes.reset()
        let gate = PlexDiscoveryGate()
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "plex-attempt"))
        let manager = AuthManager(appModel: model, keychain: store,
                                  plexSessionDiscoverer: { token in
                                      await gate.hold(token: token)
                                  })
        let restore = Task { await manager.restoreSession() }
        await gate.waitUntilHeld()
        #expect(manager.selectBackend(.jellyfin))
        await gate.releaseSuccess()
        #expect(await restore.value == false)

        #expect(model.activeBackend == .jellyfin)
        // The already-durable account token is safe to hydrate before discovery; only the held
        // server result is forbidden from publishing after the attempt is superseded.
        #expect(model.token == "saved-token")
        #expect(model.selectedServer == nil)
        #expect(!writes.accounts.contains(KeychainStore.tokenKey))
        #expect(!writes.accounts.contains(KeychainStore.selectedPlexServerIDKey))
        cleanupBackendKeys(store)
    }

    @Test func plexRestoreDiscoveryFailureKeepsSavedAccountTokenForRetryUI() async {
        let service = "com.visionplay.tests.plex-retry.\(UUID().uuidString)"
        let store = KeychainStore(service: service, synchronizesPlexToken: false,
                                  usesDevelopmentFileStorage: true)
        #expect(store.saveToken("saved-token"))
        #expect(store.saveSelectedBackend(.plex))
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "plex-retry"))
        let manager = AuthManager(appModel: model, keychain: store,
                                  plexSessionDiscoverer: { _ in throw PlexError.serverUnreachable })

        #expect(await manager.restoreSession())
        #expect(model.token == "saved-token")
        #expect(!model.isBrowseReady)
        #expect(manager.state == .failed("Signed in, but server discovery failed."))
        cleanupBackendKeys(store)
    }

    @Test func authorizedPlexPINSurvivesDiscoveryFailure() async throws {
        let service = "com.visionplay.tests.plex-authorized.\(UUID().uuidString)"
        let store = KeychainStore(service: service, synchronizesPlexToken: false,
                                  usesDevelopmentFileStorage: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthorizedPlexPINURLProtocol.self]
        let identity = PlatformClientIdentity.make(clientIdentifier: "plex-authorized")
        let client = PlexClient(session: URLSession(configuration: configuration), identity: identity)
        let model = AppModel(identity: identity, client: client)
        let manager = AuthManager(appModel: model, keychain: store,
                                  plexSessionDiscoverer: { _ in throw PlexError.serverUnreachable },
                                  authSleep: { _ in await Task.yield() })

        _ = try await manager.createPin()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if case .failed = manager.state { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.token == "authorized-token")
        #expect(model.token == "authorized-token")
        #expect(!model.isBrowseReady)
        #expect(manager.state == .failed("Signed in, but server discovery failed."))
        cleanupBackendKeys(store)
    }

    @Test func plexRestoreDoesNotRequirePreferredServerWrite() async {
        let service = "com.visionplay.tests.plex-restore-write.\(UUID().uuidString)"
        let store = KeychainStore(service: service, synchronizesPlexToken: false,
                                  usesDevelopmentFileStorage: true,
                                  writeInterceptor: { account, _ in
                                      account == KeychainStore.selectedPlexServerIDKey ? false : nil
                                  })
        #expect(store.saveToken("saved-token"))
        #expect(store.saveSelectedBackend(.plex))
        let server = PlexDevice(name: "Server", clientIdentifier: "server-id",
                                provides: "server", connections: [])
        let discovery = PlexSessionDiscovery(
            servers: [server], selectedServer: server, serverToken: "server-token",
            baseURL: URL(string: "https://server.invalid")!, isLocal: false,
            accountProfile: nil)
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "plex-write"))
        let manager = AuthManager(appModel: model, keychain: store,
                                  plexSessionDiscoverer: { _ in discovery })

        #expect(await manager.restoreSession())
        #expect(model.isBrowseReady)
        #expect(manager.state == .authenticated)
        cleanupBackendKeys(store)
    }

    @Test func backgroundRestoreDoesNotCancelInteractiveAuthorization() async {
        let store = KeychainStore(service: "com.visionplay.tests.restore-admission.\(UUID().uuidString)",
                                  synchronizesPlexToken: false,
                                  writeInterceptor: { _, _ in true })
        let loader = EmbyConnectLoaderGate()
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "restore-admission"))
        let manager = AuthManager(appModel: model, keychain: store,
                                  authDataLoader: { request in try await loader.load(request) },
                                  authSleep: { _ in await Task.yield() })

        await manager.startEmbyConnect()
        #expect(manager.state == .awaitingEmbyConnectPin(code: "ABCD"))
        #expect(await manager.restoreSessionIfNoAuthorizationInProgress() == nil)
        #expect(manager.state == .awaitingEmbyConnectPin(code: "ABCD"))
        manager.cancelCurrentAuthorization()
    }

    @Test func multiKeyReplacementRestoresPreviousSessionAfterWriteFailure() {
        let faults = StorageFaults()
        let store = makeDevelopmentStore(faults: faults)
        #expect(store.saveJellyfinSession(serverURLString: "https://old.invalid",
                                          accessToken: "old-token", userID: "old-user",
                                          serverID: "old-server"))
        faults.failNextWrite(to: KeychainStore.jellyfinAccessTokenKey)

        #expect(!store.saveJellyfinSession(serverURLString: "https://new.invalid",
                                           accessToken: "new-token", userID: "new-user",
                                           serverID: "new-server"))
        #expect(store.jellyfinServerURLString == "https://old.invalid")
        #expect(store.jellyfinAccessToken == "old-token")
        #expect(store.jellyfinUserID == "old-user")
        #expect(store.jellyfinServerID == "old-server")
        cleanupBackendKeys(store)
    }

    @Test func optionalKeyDeleteFailureRollsBackWholeReplacement() {
        let faults = StorageFaults()
        let store = makeDevelopmentStore(faults: faults)
        #expect(store.saveEmbySession(serverURLString: "https://old.invalid",
                                     accessToken: "old-token", userID: "old-user",
                                     serverID: "old-server"))
        faults.failNextDelete(of: KeychainStore.embyServerIDKey)

        #expect(!store.saveEmbySession(serverURLString: "https://new.invalid",
                                      accessToken: "new-token", userID: "new-user",
                                      serverID: nil))
        #expect(store.embyServerURLString == "https://old.invalid")
        #expect(store.embyAccessToken == "old-token")
        #expect(store.embyUserID == "old-user")
        #expect(store.embyServerID == "old-server")
        cleanupBackendKeys(store)
    }

    @Test func canceledEmbyConnectDoesNotIssueCredentialBearingFollowup() async {
        let store = KeychainStore(service: "com.visionplay.tests.emby-guard.\(UUID().uuidString)",
                                  synchronizesPlexToken: false,
                                  writeInterceptor: { _, _ in true })
        let loader = EmbyConnectLoaderGate()
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "emby-guard"))
        let manager = AuthManager(appModel: model, keychain: store,
                                  authDataLoader: { request in try await loader.load(request) },
                                  authSleep: { _ in await Task.yield() })

        await manager.startEmbyConnect()
        await loader.waitUntilPollHeld()
        #expect(manager.selectBackend(.plex))
        await loader.releaseConfirmedPoll()
        for _ in 0..<10 { await Task.yield() }

        #expect(await loader.requestCount == 2)
        #expect(model.embyAccessToken == nil)
        #expect(model.activeBackend == .plex)
    }

    @Test func selectedPlexServerWriteFailureDoesNotPublishSelection() async {
        let store = KeychainStore(
            service: "com.visionplay.tests.plex-selection.\(UUID().uuidString)",
            synchronizesPlexToken: false,
            writeInterceptor: { account, _ in
                account == KeychainStore.selectedPlexServerIDKey ? false : nil
            })
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "plex-selection"),
                             token: "account-token")
        let connection = PlexConnection(uri: "https://server.invalid", local: false, relay: false)
        let server = PlexDevice(name: "Server", clientIdentifier: "server-id",
                                provides: "server", connections: [connection])
        model.plexServers = [server]
        let manager = AuthManager(appModel: model, keychain: store,
                                  plexConnectionResolver: { _, _, _ in
                                      (URL(string: "https://server.invalid")!, false)
                                  })

        do {
            try await manager.selectPlexServer(id: server.clientIdentifier)
            Issue.record("Expected secure-storage failure")
        } catch { }

        #expect(model.selectedServer == nil)
        #expect(model.serverToken == nil)
        #expect(model.serverBaseURL == nil)
    }

    @Test func loginTaskCancellationRejectsHeldUICompletion() async {
        let gate = VoidGate()
        let events = LoginEventRecorder()
        let coordinator = LoginAuthTaskCoordinator()
        coordinator.launch {
            await gate.hold()
            guard !Task.isCancelled else { return }
            events.record("stale")
        }
        await gate.waitUntilHeld()
        coordinator.cancel()
        await gate.release()
        for _ in 0..<10 { await Task.yield() }
        #expect(events.values.isEmpty)
    }

    @Test func signOutDuringHeldRefreshServersCannotRepersistSession() async throws {
        let service = "com.visionplay.tests.plex-refresh.\(UUID().uuidString)"
        let store = KeychainStore(service: service, synchronizesPlexToken: false,
                                  usesDevelopmentFileStorage: true)
        #expect(store.saveToken("token"))
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "refresh"),
                             token: "token")
        let gate = PlexDiscoveryGate()
        let manager = AuthManager(appModel: model, keychain: store,
                                  plexSessionDiscoverer: { token in await gate.hold(token: token) })
        let refresh = Task { try await manager.refreshServers() }
        await gate.waitUntilHeld()
        manager.signOut()
        await gate.releaseSuccess()
        do {
            try await refresh.value
            Issue.record("Expected canceled refresh")
        } catch { }
        #expect(model.token == nil)
        #expect(model.selectedServer == nil)
        #expect(store.token == nil)
        #expect(store.selectedPlexServerID == nil)
        cleanupBackendKeys(store)
    }

    @Test func canceledHeldRefreshServersCannotPersistOrPublish() async throws {
        let service = "com.visionplay.tests.plex-refresh-cancel.\(UUID().uuidString)"
        let store = KeychainStore(service: service, synchronizesPlexToken: false,
                                  usesDevelopmentFileStorage: true)
        #expect(store.saveToken("token"))
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "refresh-cancel"),
                             token: "token")
        let gate = PlexDiscoveryGate()
        let manager = AuthManager(appModel: model, keychain: store,
                                  plexSessionDiscoverer: { token in await gate.hold(token: token) })
        let refresh = Task { try await manager.refreshServers() }
        await gate.waitUntilHeld()
        refresh.cancel()
        await gate.releaseSuccess()
        do {
            try await refresh.value
            Issue.record("Expected canceled refresh")
        } catch { }

        #expect(model.token == "token")
        #expect(model.selectedServer == nil)
        #expect(model.serverBaseURL == nil)
        #expect(store.selectedPlexServerID == nil)
        cleanupBackendKeys(store)
    }

    @Test func failedRefreshClearsStaleResolvedPlexServerButKeepsAccountToken() async {
        let store = KeychainStore(service: "com.visionplay.tests.refresh-clear.\(UUID().uuidString)",
                                  synchronizesPlexToken: false,
                                  writeInterceptor: { _, _ in true })
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "refresh-clear"),
                             token: "token")
        let staleServer = PlexDevice(name: "Stale", clientIdentifier: "stale-id",
                                     provides: "server", connections: [])
        model.selectedServer = staleServer
        model.plexServers = [staleServer]
        model.serverToken = "stale-server-token"
        model.serverBaseURL = URL(string: "https://stale.invalid")
        let manager = AuthManager(appModel: model, keychain: store,
                                  plexSessionDiscoverer: { _ in throw PlexError.serverUnreachable })

        do {
            try await manager.refreshServers()
            Issue.record("Expected discovery failure")
        } catch { }

        #expect(model.token == "token")
        #expect(model.selectedServer == nil)
        #expect(model.plexServers.isEmpty)
        #expect(model.serverToken == nil)
        #expect(model.serverBaseURL == nil)
        #expect(!model.isBrowseReady)
    }

    @Test func signOutDuringHeldServerSelectionCannotPublishOrPersist() async throws {
        let service = "com.visionplay.tests.plex-select-race.\(UUID().uuidString)"
        let store = KeychainStore(service: service, synchronizesPlexToken: false,
                                  usesDevelopmentFileStorage: true)
        #expect(store.saveToken("token"))
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "select-race"),
                             token: "token")
        let connection = PlexConnection(uri: "https://server.invalid", local: false, relay: false)
        let server = PlexDevice(name: "Server", clientIdentifier: "server-id",
                                provides: "server", connections: [connection])
        model.plexServers = [server]
        let gate = PlexConnectionGate()
        let manager = AuthManager(appModel: model, keychain: store,
                                  plexConnectionResolver: { _, _, _ in await gate.hold() })
        let selection = Task { try await manager.selectPlexServer(id: server.id) }
        await gate.waitUntilHeld()
        manager.signOut()
        await gate.release()
        do {
            try await selection.value
            Issue.record("Expected canceled selection")
        } catch { }
        #expect(model.selectedServer == nil)
        #expect(store.selectedPlexServerID == nil)
        cleanupBackendKeys(store)
    }

    @Test func signOutDuringHeldProfileRefreshCannotRestoreProfile() async {
        let store = KeychainStore(service: "com.visionplay.tests.plex-profile.\(UUID().uuidString)",
                                  synchronizesPlexToken: false,
                                  writeInterceptor: { _, _ in true })
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "profile-race"),
                             token: "token")
        let gate = PlexProfileGate()
        let manager = AuthManager(appModel: model, keychain: store,
                                  plexProfileLoader: { _ in await gate.hold() })
        let refresh = Task { await manager.refreshPlexAccountProfile() }
        await gate.waitUntilHeld()
        manager.signOut()
        await gate.release()
        await refresh.value
        #expect(model.plexAccountProfile == nil)
    }

    @Test func staleSameServerSelectionCleanupCannotClearNewAttempt() throws {
        var tracker = EmbyConnectServerSelectionTracker()
        let attemptA = UUID()
        let attemptB = UUID()
        let maybeWorkA = tracker.begin(attemptID: attemptA, serverID: "same-server")
        let workA = try #require(maybeWorkA)
        tracker.cancel()
        let maybeWorkB = tracker.begin(attemptID: attemptB, serverID: "same-server")
        let workB = try #require(maybeWorkB)

        tracker.finish(workA)

        #expect(tracker.active == workB)
    }

    private func makeDevelopmentStore(faults: StorageFaults) -> KeychainStore {
        KeychainStore(service: "com.visionplay.tests.rollback.\(UUID().uuidString)",
                      synchronizesPlexToken: false,
                      usesDevelopmentFileStorage: true,
                      writeInterceptor: { account, _ in faults.writeOutcome(account) },
                      deleteInterceptor: { account in faults.deleteOutcome(account) })
    }

    private func cleanupBackendKeys(_ store: KeychainStore) {
        [KeychainStore.tokenKey, KeychainStore.selectedBackendKey,
         KeychainStore.selectedPlexServerIDKey,
         KeychainStore.jellyfinServerURLKey, KeychainStore.jellyfinAccessTokenKey,
         KeychainStore.jellyfinUserIDKey, KeychainStore.jellyfinServerIDKey,
         KeychainStore.embyServerURLKey, KeychainStore.embyAccessTokenKey,
         KeychainStore.embyUserIDKey, KeychainStore.embyServerIDKey].forEach { _ = store.delete($0) }
    }
}

@MainActor
private final class WriteRecorder {
    private(set) var accounts: [String] = []
    func record(_ account: String) { accounts.append(account) }
    func reset() { accounts = [] }
}

@MainActor
private final class LoginEventRecorder {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}

@MainActor
private final class StorageFaults {
    private var writeKey: String?
    private var deleteKey: String?
    func failNextWrite(to key: String) { writeKey = key }
    func failNextDelete(of key: String) { deleteKey = key }
    func writeOutcome(_ key: String) -> Bool? {
        guard writeKey == key else { return nil }
        writeKey = nil
        return false
    }
    func deleteOutcome(_ key: String) -> Bool? {
        guard deleteKey == key else { return nil }
        deleteKey = nil
        return false
    }
}

private actor AuthResponseGate {
    private var continuation: CheckedContinuation<(Data, URLResponse), Never>?

    func hold(request: URLRequest) async -> (Data, URLResponse) {
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilHeld() async {
        while continuation == nil { await Task.yield() }
    }

    func releaseJellyfinSuccess() {
        let data = Data(#"{"User":{"Id":"stale-user"},"AccessToken":"stale-token","ServerId":"server"}"#.utf8)
        let url = URL(string: "https://media.example.invalid")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        continuation?.resume(returning: (data, response))
        continuation = nil
    }
}

private actor PlexDiscoveryGate {
    private var continuation: CheckedContinuation<PlexSessionDiscovery, Never>?

    func hold(token: String) async -> PlexSessionDiscovery {
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilHeld() async {
        while continuation == nil { await Task.yield() }
    }

    func releaseSuccess() {
        let server = PlexDevice(name: "Held server", clientIdentifier: "held-server",
                                provides: "server", connections: [])
        continuation?.resume(returning: PlexSessionDiscovery(
            servers: [server], selectedServer: server, serverToken: "held-token",
            baseURL: URL(string: "https://held.invalid")!, isLocal: false,
            accountProfile: nil))
        continuation = nil
    }
}

private actor EmbyConnectLoaderGate {
    private(set) var requestCount = 0
    private var pollContinuation: CheckedContinuation<(Data, URLResponse), Never>?

    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        if requestCount == 1 {
            return response(for: request, json: #"{"Pin":"ABCD"}"#)
        }
        return await withCheckedContinuation { pollContinuation = $0 }
    }

    func waitUntilPollHeld() async {
        while pollContinuation == nil { await Task.yield() }
    }

    func releaseConfirmedPoll() {
        let url = URL(string: "https://connect.emby.media")!
        let response = HTTPURLResponse(url: url, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        pollContinuation?.resume(returning: (Data(#"{"IsConfirmed":true}"#.utf8), response))
        pollContinuation = nil
    }

    private func response(for request: URLRequest, json: String) -> (Data, URLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        return (Data(json.utf8), response)
    }
}

private actor VoidGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async { await withCheckedContinuation { continuation = $0 } }
    func waitUntilHeld() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}

private actor PlexConnectionGate {
    private var continuation: CheckedContinuation<(url: URL, isLocal: Bool)?, Never>?
    func hold() async -> (url: URL, isLocal: Bool)? {
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilHeld() async { while continuation == nil { await Task.yield() } }
    func release() {
        continuation?.resume(returning: (URL(string: "https://server.invalid")!, false))
        continuation = nil
    }
}

private actor PlexProfileGate {
    private var continuation: CheckedContinuation<PlexAccountProfile?, Never>?
    func hold() async -> PlexAccountProfile? {
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilHeld() async { while continuation == nil { await Task.yield() } }
    func release() {
        continuation?.resume(returning: PlexAccountProfile(username: "stale"))
        continuation = nil
    }
}

private final class AuthorizedPlexPINURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "plex.tv"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let json: String
        if request.httpMethod == "POST" {
            let strong = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "strong" })?.value == "true"
            json = strong
                ? #"{"id":2,"code":"STRONG","authToken":null}"#
                : #"{"id":1,"code":"LINK","authToken":null}"#
        } else {
            json = #"{"id":1,"code":"LINK","authToken":"authorized-token"}"#
        }
        let response = HTTPURLResponse(url: url, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
