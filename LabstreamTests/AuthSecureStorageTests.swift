import Foundation
import PMSKit
import Testing
@testable import Labstream

@MainActor
struct AuthSecureStorageTests {
    @Test func launchRestoreCompletesSelectedBackendWithoutHydratingInactiveCredentials() async throws {
        let store = KeychainStore(
            service: "com.visionplay.tests.selected-first.\(UUID().uuidString)",
            synchronizesPlexToken: false,
            usesDevelopmentFileStorage: true)
        #expect(store.saveSelectedBackend(.plex))
        #expect(store.saveToken("plex-account"))
        #expect(store.saveJellyfinSession(serverURLString: "https://jellyfin.invalid",
                                          accessToken: "jf-token", userID: "jf-user",
                                          serverID: "jf-server"))
        let server = PlexDevice(name: "Plex", clientIdentifier: "plex-server",
                                provides: "server", connections: [])
        let discovery = PlexSessionDiscovery(
            servers: [server], selectedServer: server, serverToken: "plex-server-token",
            baseURL: URL(string: "https://plex.invalid")!, isLocal: false,
            accountProfile: nil)
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "selected-first"))
        let manager = AuthManager(appModel: model, keychain: store,
                                  plexSessionDiscoverer: { _ in discovery })

        #expect(await manager.restoreSession())
        #expect(manager.sessionRestoreOutcome == .restored)
        #expect(model.backendSession(for: .plex) != nil)
        #expect(model.backendSession(for: .jellyfin) == nil)

        #if os(tvOS)
        #expect(await manager.hydrateSavedSessionForDownloads(backend: .jellyfin) == false)
        #expect(model.backendSession(for: .jellyfin) == nil)
        #else
        #expect(await manager.hydrateSavedSessionForDownloads(backend: .jellyfin))
        #expect(model.backendSession(for: .jellyfin) != nil)
        #expect(model.activeBackend == .plex)
        #expect(manager.state == .authenticated)
        #endif
        cleanupBackendKeys(store)
    }

    @Test func inactiveHydrationPolicyRequiresDownloadCapabilityAndDifferentBackend() {
        #expect(AuthBackendHydrationPolicy.shouldHydrateInactiveBackend(
            .jellyfin, selected: .plex, downloadsAvailable: true))
        #expect(!AuthBackendHydrationPolicy.shouldHydrateInactiveBackend(
            .plex, selected: .plex, downloadsAvailable: true))
        #expect(!AuthBackendHydrationPolicy.shouldHydrateInactiveBackend(
            .jellyfin, selected: .plex, downloadsAvailable: false))
    }

    @Test func inactivePlexHydrationRequiresAUsableDiscoveredSession() async {
        #if !os(tvOS)
        let store = KeychainStore(
            service: "com.visionplay.tests.plex-hydration-failure.\(UUID().uuidString)",
            synchronizesPlexToken: false,
            usesDevelopmentFileStorage: true)
        #expect(store.saveSelectedBackend(.jellyfin))
        #expect(store.saveToken("plex-account"))
        let model = AppModel(
            identity: PlatformClientIdentity.make(clientIdentifier: "plex-hydration-failure"),
            activeBackend: .jellyfin)
        let manager = AuthManager(appModel: model, keychain: store,
                                  plexSessionDiscoverer: { _ in throw PlexError.serverUnreachable })

        #expect(await manager.hydrateSavedSessionForDownloads(backend: .plex) == false)
        #expect(model.backendSession(for: .plex) == nil)
        cleanupBackendKeys(store)
        #endif
    }

    @Test func globalAttemptAuthorityRejectsStaleFinishAcrossBackendOwners() {
        var authority = AuthAttemptAuthority()
        let plex = authority.begin(.plexPIN)
        let emby = authority.begin(.embyCredentials)

        authority.finish(plex)

        #expect(!authority.isCurrent(plex, taskIsCancelled: false))
        #expect(authority.isCurrent(emby, taskIsCancelled: false))
        #expect(!authority.isCurrent(emby, taskIsCancelled: true))
        authority.finish(emby)
        #expect(authority.isIdle)
    }

    @Test func developmentCredentialFilesAreNonshippingMacOnly() {
        #if (DEBUG || PERFORMANCE_AUDIT) && os(macOS)
        #expect(KeychainStore.supportsDevelopmentFileStorage)
        #expect(DevelopmentCredentialStoragePolicy.allowsFileStorage(isCanonicalService: false))
        #else
        #expect(!KeychainStore.supportsDevelopmentFileStorage)
        #expect(!DevelopmentCredentialStoragePolicy.allowsFileStorage(isCanonicalService: false))
        #endif
        #expect(!DevelopmentCredentialStoragePolicy.allowsFileStorage(isCanonicalService: true))
    }

    @Test func releasePolicyDoesNotImportDebugDevelopmentCredentialFile() {
        #if (DEBUG || PERFORMANCE_AUDIT) && os(macOS)
        let service = "com.visionplay.tests.release-file-closed.\(UUID().uuidString)"
        let debugStore = KeychainStore(service: service,
                                       synchronizesPlexToken: false,
                                       usesDevelopmentFileStorage: true)
        #expect(debugStore.saveToken("debug-only-token"))

        let releaseStore = KeychainStore(
            service: service,
            synchronizesPlexToken: false,
            fallbackPolicy: SecretFileFallbackPolicy(buildConfiguration: .release,
                                                     runtimeEnvironment: .device))
        #expect(releaseStore.token == nil)
        #expect(debugStore.delete(KeychainStore.tokenKey))
        #endif
    }

    @Test func signOutNotifiesDownloadHandoffBeforeClearingRuntimeSession() throws {
        let store = KeychainStore(
            service: "com.visionplay.tests.signout-handoff.\(UUID().uuidString)",
            synchronizesPlexToken: false)
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "signout-handoff"),
                             activeBackend: .plex,
                             token: "account-token")
        model.serverBaseURL = URL(string: "https://plex.example.invalid")!
        model.serverToken = "server-token"
        let manager = AuthManager(appModel: model, keychain: store)
        var callbackBackend: MediaBackendKind?
        var hadLiveSessionDuringCallback = false
        manager.onBackendWillSignOut = { backend in
            callbackBackend = backend
            hadLiveSessionDuringCallback = model.backendSession(for: .plex) != nil
        }

        manager.signOut()

        #expect(callbackBackend == .plex)
        #expect(hadLiveSessionDuringCallback)
        #expect(model.backendSession(for: .plex) == nil)
    }

    @Test func signOutAllClearsEveryCredentialAndRuntimeLaneAfterCallbacks() throws {
        let store = KeychainStore(
            service: "com.visionplay.tests.signout-all.\(UUID().uuidString)",
            synchronizesPlexToken: false)
        #expect(store.saveSelectedBackend(.emby))
        #expect(store.saveToken("plex-token"))
        #expect(store.saveJellyfinSession(serverURLString: "https://jellyfin.invalid",
                                         accessToken: "jellyfin-token",
                                         userID: "jellyfin-user",
                                         serverID: "jellyfin-server"))
        #expect(store.saveEmbySession(serverURLString: "https://emby.invalid",
                                     accessToken: "emby-token",
                                     userID: "emby-user",
                                     serverID: "emby-server"))
        let model = AppModel(
            identity: PlatformClientIdentity.make(clientIdentifier: "signout-all"),
            activeBackend: .emby,
            token: "plex-token")
        model.serverBaseURL = URL(string: "https://plex.invalid")
        model.serverToken = "plex-server-token"
        model.applyMediaBrowserSession(
            backend: .jellyfin,
            server: URL(string: "https://jellyfin.invalid")!,
            token: "jellyfin-token",
            userID: "jellyfin-user",
            serverID: "jellyfin-server")
        model.applyMediaBrowserSession(
            backend: .emby,
            server: URL(string: "https://emby.invalid")!,
            token: "emby-token",
            userID: "emby-user",
            serverID: "emby-server")
        let manager = AuthManager(appModel: model, keychain: store)
        var callbacks: [MediaBackendKind] = []
        manager.onBackendWillSignOut = { backend in
            #expect(model.backendSession(for: backend) != nil)
            callbacks.append(backend)
        }

        manager.signOutAll()

        #expect(callbacks == [.plex, .jellyfin, .emby])
        #expect(manager.savedAuthenticatedBackends.isEmpty)
        #expect(MediaBackendKind.allCases.allSatisfy { model.backendSession(for: $0) == nil })
        #expect(model.activeBackend == .plex)
        #expect(store.selectedBackend == .plex)
        cleanupBackendKeys(store)
    }

    @Test func signOutAllDeletesPartialArtifactsAndIsRepeatable() {
        let store = KeychainStore(
            service: "com.visionplay.tests.signout-all-partial.\(UUID().uuidString)",
            synchronizesPlexToken: false)
        store.jellyfinServerURLString = "https://jellyfin.invalid"
        store.jellyfinUserID = "orphan-user"
        let model = AppModel(
            identity: PlatformClientIdentity.make(clientIdentifier: "signout-all-partial"),
            activeBackend: .jellyfin)
        let manager = AuthManager(appModel: model, keychain: store)
        var callbacks: [MediaBackendKind] = []
        manager.onBackendWillSignOut = { callbacks.append($0) }

        manager.signOutAll()
        manager.signOutAll()

        #expect(callbacks.isEmpty)
        #expect(store.jellyfinServerURLString == nil)
        #expect(store.jellyfinUserID == nil)
        #expect(manager.savedAuthenticatedBackends.isEmpty)
        #expect(model.activeBackend == .plex)
        cleanupBackendKeys(store)
    }

    @Test func clientIdentityWriteFailureStillBuildsRuntimeForBackgroundDrain() throws {
        let store = KeychainStore(
            service: "com.visionplay.tests.identity.\(UUID().uuidString)",
            synchronizesPlexToken: false,
            writeInterceptor: { account, _ in
                account == KeychainStore.clientIdentifierKey ? false : nil
            })
        let bootstrap = SessionBootstrap()

        #expect(store.clientIdentifier() == nil)
        let runtime = try #require(AppRuntime.make(keychain: store, bootstrap: bootstrap))
        #expect(!runtime.appModel.identity.clientIdentifier.isEmpty)
        #if !os(tvOS)
        #expect(runtime.downloadManager.appModel === runtime.appModel)
        #expect(runtime.authManager.onBackendWillSignOut != nil)
        #else
        #expect(runtime.authManager.onBackendWillSignOut == nil)
        #endif
        #expect(runtime.bootstrap === bootstrap)
        #expect(runtime.bootstrap.isRestoring)
        #expect(!runtime.bootstrap.didStartRestore)

        // Both recreated launch roots retain the exact app-owned runtime/bootstrap rather than
        // minting window-local restore state.
        let firstRoot = ContentView(runtime: runtime)
        let recreatedRoot = ContentView(runtime: runtime)
        #expect(firstRoot.runtime.bootstrap === recreatedRoot.runtime.bootstrap)
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
        let gate = HeldContinuation<(Data, URLResponse)>()
        let identity = PlatformClientIdentity.make(clientIdentifier: "test-auth-attempt")
        let model = AppModel(identity: identity, activeBackend: .plex)
        let manager = AuthManager(appModel: model, keychain: store) { _ in
            await gate.hold()
        }
        let server = try #require(URL(string: "https://media.example.invalid"))

        let attemptA = Task {
            await manager.loginToJellyfin(server: server, username: "user", password: "password")
        }
        await gate.waitUntilHeld()
        #expect(manager.selectBackend(.plex))
        await gate.release(returning: heldJellyfinSuccess())
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
        let gate = HeldContinuation<(Data, URLResponse)>()
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "cancel-test"))
        let manager = AuthManager(appModel: model, keychain: store) { _ in
            await gate.hold()
        }
        let server = try #require(URL(string: "https://media.example.invalid"))
        let task = Task {
            await manager.loginToJellyfin(server: server, username: "user", password: "password")
        }
        await gate.waitUntilHeld()
        task.cancel()
        await gate.release(returning: heldJellyfinSuccess())
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
        let gate = HeldContinuation<PlexSessionDiscovery>()
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "plex-attempt"))
        let manager = AuthManager(appModel: model, keychain: store,
                                  plexSessionDiscoverer: { _ in
                                      await gate.hold()
                                  })
        let restore = Task { await manager.restoreSession() }
        await gate.waitUntilHeld()
        #expect(manager.selectBackend(.jellyfin))
        await gate.release(returning: heldPlexDiscovery())
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
        #expect(manager.sessionRestoreOutcome == .temporarilyUnavailable)
        #expect(model.token == "saved-token")
        #expect(!model.isBrowseReady)
        #expect(manager.state == .failed("Signed in, but server discovery failed."))
        cleanupBackendKeys(store)
    }

    @Test(arguments: [401, 403, 429, 500])
    func plexHTTPRestoreOnlyUnauthorizedRetiresSavedCredentials(status: Int) async throws {
        let store = KeychainStore(service: "com.visionplay.tests.http-restore.\(UUID().uuidString)",
                                  synchronizesPlexToken: false, usesDevelopmentFileStorage: true)
        defer { cleanupBackendKeys(store) }
        #expect(store.saveToken("saved-token"))
        #expect(store.saveSelectedBackend(.plex))
        #expect(store.saveSelectedPlexServerID("preferred-server"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlexRestoreStatusURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let identity = PlatformClientIdentity.make(clientIdentifier: "http-restore")
        let client = PlexClient(session: session, identity: identity)
        let model = AppModel(identity: identity, client: client)
        let manager = AuthManager(appModel: model, keychain: store,
                                  plexSessionDiscoverer: { _ in
            try await client.send(PlexRequest(
                url: URL(string: "https://plex.invalid/\(status)")!, method: "GET"))
            throw PlexError.decoding(URLError(.cannotParseResponse))
        })
        _ = await manager.restoreSession()
        #expect(!model.isBrowseReady)
        let expected: SessionRestoreOutcome = switch status {
        case 401: .invalidCredential
        case 403: .unconfirmedCredential
        default: .temporarilyUnavailable
        }
        #expect(manager.sessionRestoreOutcome == expected)
        #expect(store.token == (status == 401 ? nil : "saved-token"))
        #expect(store.selectedPlexServerID == (status == 401 ? nil : "preferred-server"))
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
        // The complete hosted matrix runs hundreds of Swift Testing cases concurrently. Keep
        // this authorization completion bounded without mistaking scheduler starvation for an
        // authentication failure; focused runs normally complete well below this deadline.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
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

    @Test func plexConnectionBecomesUsableBeforeOptionalProfileMetadataReturns() async throws {
        let service = "com.visionplay.tests.plex-milestones.\(UUID().uuidString)"
        let store = KeychainStore(service: service, synchronizesPlexToken: false,
                                  usesDevelopmentFileStorage: true)
        #expect(store.saveToken("saved-token"))
        #expect(store.saveSelectedBackend(.plex))
        let server = PlexDevice(name: "Server", clientIdentifier: "server-id",
                                provides: "server", connections: [])
        let discovery = PlexSessionDiscovery(
            servers: [server], selectedServer: server, serverToken: "server-token",
            baseURL: URL(string: "https://server.invalid")!, isLocal: false,
            accountProfile: nil)
        let profileGate = HeldContinuation<PlexAccountProfile?>()
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "plex-milestones"))
        let manager = AuthManager(appModel: model, keychain: store,
                                  plexSessionDiscoverer: { _ in discovery },
                                  plexProfileLoader: { _ in await profileGate.hold() })

        #expect(await manager.restoreSession())
        #expect(model.isBrowseReady)
        #expect(manager.state == .authenticated)
        #expect(model.plexAccountProfile == nil)

        await profileGate.waitUntilHeld()
        await profileGate.release(returning: PlexAccountProfile(username: "stale"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while model.plexAccountProfile == nil, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(model.plexAccountProfile?.username == "stale")
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
        let gate = HeldContinuation<Void>()
        let events = LoginEventRecorder()
        let coordinator = LoginAuthTaskCoordinator()
        coordinator.launch {
            await gate.hold()
            guard !Task.isCancelled else { return }
            events.record("stale")
        }
        await gate.waitUntilHeld()
        coordinator.cancel()
        await gate.release(returning: ())
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
        let gate = HeldContinuation<PlexSessionDiscovery>()
        let manager = AuthManager(appModel: model, keychain: store,
                                  plexSessionDiscoverer: { _ in await gate.hold() })
        let refresh = Task { try await manager.refreshServers() }
        await gate.waitUntilHeld()
        manager.signOut()
        await gate.release(returning: heldPlexDiscovery())
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
        let gate = HeldContinuation<PlexSessionDiscovery>()
        let manager = AuthManager(appModel: model, keychain: store,
                                  plexSessionDiscoverer: { _ in await gate.hold() })
        let refresh = Task { try await manager.refreshServers() }
        await gate.waitUntilHeld()
        refresh.cancel()
        await gate.release(returning: heldPlexDiscovery())
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
        let gate = HeldContinuation<(url: URL, isLocal: Bool)?>()
        let manager = AuthManager(appModel: model, keychain: store,
                                  plexConnectionResolver: { _, _, _ in await gate.hold() })
        let selection = Task { try await manager.selectPlexServer(id: server.id) }
        await gate.waitUntilHeld()
        manager.signOut()
        await gate.release(returning: (URL(string: "https://server.invalid")!, false))
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
        let gate = HeldContinuation<PlexAccountProfile?>()
        let manager = AuthManager(appModel: model, keychain: store,
                                  plexProfileLoader: { _ in await gate.hold() })
        let refresh = Task { await manager.refreshPlexAccountProfile() }
        await gate.waitUntilHeld()
        manager.signOut()
        await gate.release(returning: PlexAccountProfile(username: "stale"))
        await refresh.value
        #expect(model.plexAccountProfile == nil)
    }

    @Test func embyConnectResetDiscardsPendingSecretSelectionState() async throws {
        let store = KeychainStore(
            service: "com.visionplay.tests.emby-connect-owner.\(UUID().uuidString)",
            synchronizesPlexToken: false,
            writeInterceptor: { _, _ in true })
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "connect-owner"))
        let loader = EmbyConnectMultiServerLoader()
        let flow = EmbyConnectAuthFlow(appModel: model, keychain: store,
                                       dataLoader: { request in try await loader.load(request) })

        let completion = try await flow.completeConfirmedPIN("ABCD", isCurrent: { true })
        guard case .serverSelectionRequired(let choices) = completion else {
            Issue.record("Expected linked-server selection")
            return
        }
        #expect(choices.count == 2)

        flow.reset()
        let result = try await flow.selectServer(id: choices[0].id,
                                                 attemptID: UUID(),
                                                 isCurrent: { true })
        guard case .stale = result else {
            Issue.record("Reset retained secret-bearing server selection state")
            return
        }
        #expect(await loader.requestCount == 2)
    }

    @Test func staleEmbyConnectSelectionFinishCannotClearReplacement() throws {
        var authority = EmbyConnectAuthFlow.SelectionAuthority()
        let maybeFirst = authority.begin(attemptID: UUID(), serverID: "same-server")
        let first = try #require(maybeFirst)
        authority.cancel()
        let maybeReplacement = authority.begin(attemptID: UUID(), serverID: "same-server")
        let replacement = try #require(maybeReplacement)

        authority.finish(first)

        #expect(authority.active == replacement)
    }

    // MARK: - #259 typed restore outcome

    @Test func plexRestoreWithoutSavedTokenIsMissingCredential() async {
        let store = KeychainStore(service: "com.visionplay.tests.plex-missing.\(UUID().uuidString)",
                                  synchronizesPlexToken: false, usesDevelopmentFileStorage: true)
        defer { cleanupBackendKeys(store) }
        #expect(store.saveSelectedBackend(.plex))
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "plex-missing"))
        let manager = AuthManager(appModel: model, keychain: store,
                                  plexSessionDiscoverer: { _ in throw PlexError.serverUnreachable })

        #expect(manager.sessionRestoreOutcome == nil)
        #expect(await manager.restoreSession() == false)
        #expect(manager.sessionRestoreOutcome == .missingCredential)
    }

    enum MediaBrowserProbe: String, CaseIterable, Sendable {
        case unauthorized, forbidden, serverError, offline, timedOut, otherUser
    }

    @Test(arguments: [MediaBackendKind.jellyfin, .emby], MediaBrowserProbe.allCases)
    func mediaBrowserRestoreClassifiesProbeResult(backend: MediaBackendKind,
                                                  probe: MediaBrowserProbe) async {
        let store = KeychainStore(
            service: "com.visionplay.tests.mb-outcome.\(UUID().uuidString)",
            synchronizesPlexToken: false, usesDevelopmentFileStorage: true)
        defer { cleanupBackendKeys(store) }
        #expect(store.saveSelectedBackend(backend))
        switch backend {
        case .jellyfin:
            #expect(store.saveJellyfinSession(serverURLString: "https://jellyfin.invalid",
                                              accessToken: "jf-token", userID: "saved-user",
                                              serverID: "jf-server"))
        case .emby:
            #expect(store.saveEmbySession(serverURLString: "https://emby.invalid",
                                          accessToken: "emby-token", userID: "saved-user",
                                          serverID: "emby-server"))
        case .plex:
            Issue.record("Plex is covered by the discovery tests")
        }
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "mb-outcome"))
        let manager = AuthManager(appModel: model, keychain: store, authDataLoader: { request in
            func reply(_ status: Int, _ body: String = "{}") -> (Data, URLResponse) {
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                                                  httpVersion: nil, headerFields: nil)!)
            }
            switch probe {
            case .unauthorized: return reply(401)
            case .forbidden: return reply(403)
            case .serverError: return reply(503)
            case .offline: throw URLError(.notConnectedToInternet)
            case .timedOut: throw URLError(.timedOut)
            case .otherUser: return reply(200, #"{"Id":"different-user"}"#)
            }
        })

        _ = await manager.restoreSession()

        let expected: SessionRestoreOutcome
        switch (probe, backend) {
        case (.unauthorized, _):
            expected = .invalidCredential
        case (.otherUser, .jellyfin), (.forbidden, _):
            // The server answered without accepting the session: keep the credential, no Offline.
            expected = .unconfirmedCredential
        case (.otherUser, _):
            // Emby's probe is /Users/{id}; a different id is treated as an auth failure.
            expected = .invalidCredential
        case (.serverError, _), (.offline, _), (.timedOut, _):
            expected = .temporarilyUnavailable
        }
        #expect(manager.sessionRestoreOutcome == expected)
        #expect(!model.isBrowseReady)
        let savedSnapshot = backend == .jellyfin ? store.jellyfinAccessToken : store.embyAccessToken
        #expect((savedSnapshot != nil) == expected.retainsSavedCredential)
    }

    @Test func plexRestoreFailureClassificationIsIndependentOfUpdateState() {
        // The selected (updateState: true) and inactive-hydration (updateState: false) Plex
        // restore paths share this classifier, so a 401 is always a rejected credential.
        #expect(AuthManager.plexRestoreFailureOutcome(for: PlexError.unauthorized)
            == .invalidCredential)
        #expect(AuthManager.plexRestoreFailureOutcome(for: PlexError.http(403))
            == .unconfirmedCredential)
        #expect(AuthManager.plexRestoreFailureOutcome(for: PlexError.http(429))
            == .temporarilyUnavailable)
        #expect(AuthManager.plexRestoreFailureOutcome(for: PlexError.http(503))
            == .temporarilyUnavailable)
        #expect(AuthManager.plexRestoreFailureOutcome(for: PlexError.serverUnreachable)
            == .temporarilyUnavailable)
        #expect(AuthManager.plexRestoreFailureOutcome(for: URLError(.timedOut))
            == .temporarilyUnavailable)
    }

    @Test func inactivePlexHydration401KeepsTokenButIsNotUsable() async {
        #if !os(tvOS)
        let store = KeychainStore(service: "com.visionplay.tests.plex-inactive-401.\(UUID().uuidString)",
                                  synchronizesPlexToken: false, usesDevelopmentFileStorage: true)
        defer { cleanupBackendKeys(store) }
        #expect(store.saveSelectedBackend(.jellyfin))
        #expect(store.saveToken("plex-account"))
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "plex-inactive-401"))
        let manager = AuthManager(appModel: model, keychain: store,
                                  plexSessionDiscoverer: { _ in throw PlexError.unauthorized })

        #expect(await manager.hydrateSavedSessionForDownloads(backend: .plex) == false)
        #expect(store.token == "plex-account")
        #expect(model.backendSession(for: .plex) == nil)
        // Hydration never writes the selected-session outcome the launch gate reads.
        #expect(manager.sessionRestoreOutcome == nil)
        #endif
    }

    @Test func explicitSignOutResetsRestoreOutcomeToMissingCredential() async {
        let store = KeychainStore(service: "com.visionplay.tests.signout-outcome.\(UUID().uuidString)",
                                  synchronizesPlexToken: false, usesDevelopmentFileStorage: true)
        defer { cleanupBackendKeys(store) }
        #expect(store.saveToken("saved-token"))
        #expect(store.saveSelectedBackend(.plex))
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "signout-outcome"))
        let manager = AuthManager(appModel: model, keychain: store,
                                  plexSessionDiscoverer: { _ in throw PlexError.serverUnreachable })

        _ = await manager.restoreSession()
        #expect(manager.sessionRestoreOutcome == .temporarilyUnavailable)
        manager.signOut()
        #expect(manager.sessionRestoreOutcome == .missingCredential)
        #expect(store.token == nil)
    }

    @Test func switchingToBackendWithoutCredentialsClearsTransientOutcome() async {
        let store = KeychainStore(service: "com.visionplay.tests.switch-outcome.\(UUID().uuidString)",
                                  synchronizesPlexToken: false, usesDevelopmentFileStorage: true)
        defer { cleanupBackendKeys(store) }
        #expect(store.saveToken("saved-token"))
        #expect(store.saveSelectedBackend(.plex))
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "switch-outcome"))
        let manager = AuthManager(appModel: model, keychain: store,
                                  plexSessionDiscoverer: { _ in throw PlexError.serverUnreachable })

        _ = await manager.restoreSession()
        #expect(manager.sessionRestoreOutcome == .temporarilyUnavailable)
        await manager.switchBackend(.jellyfin)
        #expect(model.activeBackend == .jellyfin)
        #expect(manager.sessionRestoreOutcome == .missingCredential)
    }

    // MARK: - Username/password sign-in: 401 vs 403

    @Test(arguments: [MediaBackendKind.jellyfin, .emby], [401, 403])
    func passwordSignInDistinguishesRejectedPasswordFromRefusedAccount(backend: MediaBackendKind,
                                                                       status: Int) async throws {
        let store = KeychainStore(service: "com.visionplay.tests.signin-status.\(UUID().uuidString)",
                                  synchronizesPlexToken: false, usesDevelopmentFileStorage: true)
        defer { cleanupBackendKeys(store) }
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "signin-status"))
        let manager = AuthManager(appModel: model, keychain: store, authDataLoader: { request in
            (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                                              httpVersion: nil, headerFields: nil)!)
        })
        let server = try #require(URL(string: "https://media.example.invalid"))

        let backendName: String
        switch backend {
        case .jellyfin:
            backendName = "Jellyfin"
            await manager.loginToJellyfin(server: server, username: "user", password: "password")
        case .emby:
            backendName = "Emby"
            await manager.loginToEmby(server: server, username: "user", password: "password")
        case .plex:
            Issue.record("Plex sign-in is PIN-based and has no username/password path")
            return
        }

        let expected = status == 401
            ? "Invalid \(backendName) username or password."
            : AuthManager.forbiddenSignInMessage(backendName: backendName)
        #expect(manager.state == .failed(expected))
        #expect(!model.isBrowseReady)
        #expect(store.jellyfinAccessToken == nil)
        #expect(store.embyAccessToken == nil)
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

/// Holds one async dependency call until the test releases it with a value.
private actor HeldContinuation<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?

    func hold() async -> Value {
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilHeld() async {
        while continuation == nil { await Task.yield() }
    }

    func release(returning value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

private func heldJellyfinSuccess() -> (Data, URLResponse) {
    let data = Data(#"{"User":{"Id":"stale-user"},"AccessToken":"stale-token","ServerId":"server"}"#.utf8)
    let url = URL(string: "https://media.example.invalid")!
    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
    return (data, response)
}

private func heldPlexDiscovery() -> PlexSessionDiscovery {
    let server = PlexDevice(name: "Held server", clientIdentifier: "held-server",
                            provides: "server", connections: [])
    return PlexSessionDiscovery(
        servers: [server], selectedServer: server, serverToken: "held-token",
        baseURL: URL(string: "https://held.invalid")!, isLocal: false,
        accountProfile: nil)
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

private actor EmbyConnectMultiServerLoader {
    private(set) var requestCount = 0

    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        let json: String
        switch requestCount {
        case 1:
            json = #"{"UserId":"connect-user","AccessToken":"connect-token"}"#
        case 2:
            json = #"""
            [
              {"Id":"one","SystemId":"system-one","Name":"One","Url":"https://one.invalid","AccessKey":"secret-one"},
              {"Id":"two","SystemId":"system-two","Name":"Two","Url":"https://two.invalid","AccessKey":"secret-two"}
            ]
            """#
        default:
            Issue.record("Pending Connect state issued an unexpected request")
            json = "{}"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        return (Data(json.utf8), response)
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

private final class PlexRestoreStatusURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let response = HTTPURLResponse(url: url, statusCode: Int(url.lastPathComponent)!,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
