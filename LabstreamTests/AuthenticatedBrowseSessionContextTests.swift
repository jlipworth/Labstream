import Foundation
import PMSKit
import Testing
@testable import Labstream

@MainActor
struct AuthenticatedBrowseSessionContextTests {
    @Test func tokenABAInvalidatesOpaqueAuthorityEvenWhenCredentialsCompareEqualAgain() throws {
        let model = makeModel(activeBackend: .jellyfin)
        applyMediaBrowser(.jellyfin, to: model, token: "token-A")
        let first = try #require(model.activeAuthenticatedBrowseSession)

        model.jellyfinAccessToken = "token-B"
        let second = try #require(model.activeAuthenticatedBrowseSession)
        model.jellyfinAccessToken = "token-A"
        let third = try #require(model.activeAuthenticatedBrowseSession)

        #expect(first.authority != second.authority)
        #expect(second.authority != third.authority)
        #expect(first.authority != third.authority)
        #expect(first.session == third.session)
    }

    @Test func serverBaseURLAndUserChangesEachInvalidateAuthority() throws {
        let model = makeModel(activeBackend: .emby)
        applyMediaBrowser(.emby, to: model)
        let original = try #require(model.activeAuthenticatedBrowseSession)

        model.embyServerID = "server-2"
        let changedServer = try #require(model.activeAuthenticatedBrowseSession)
        model.embyServerBaseURL = try #require(URL(string: "https://replacement.example.test/emby"))
        let changedBaseURL = try #require(model.activeAuthenticatedBrowseSession)
        model.embyUserID = "user-2"
        let changedUser = try #require(model.activeAuthenticatedBrowseSession)

        #expect(original.authority != changedServer.authority)
        #expect(changedServer.authority != changedBaseURL.authority)
        #expect(changedBaseURL.authority != changedUser.authority)
    }

    @Test func clientIdentityChangeInvalidatesEveryConfiguredLane() throws {
        let model = makeModel(activeBackend: .plex)
        applyPlex(to: model)
        applyMediaBrowser(.jellyfin, to: model)
        applyMediaBrowser(.emby, to: model)
        let before = try contexts(in: model)

        model.identity = ClientIdentity(clientIdentifier: "replacement-device",
                                        product: "Labstream",
                                        version: "2",
                                        deviceName: "Replacement")
        let after = try contexts(in: model)

        for backend in MediaBackendKind.allCases {
            #expect(before[backend]?.authority != after[backend]?.authority)
            #expect(after[backend]?.clientIdentity == model.identity)
        }
    }

    @Test func backendSwitchSelectsExactLaneWithoutInvalidatingEitherLane() throws {
        let model = makeModel(activeBackend: .plex)
        applyPlex(to: model)
        applyMediaBrowser(.jellyfin, to: model)
        let plex = try #require(model.authenticatedBrowseSession(for: .plex))
        let jellyfin = try #require(model.authenticatedBrowseSession(for: .jellyfin))

        #expect(model.activeAuthenticatedBrowseSession?.authority == plex.authority)
        model.activeBackend = .jellyfin
        #expect(model.activeAuthenticatedBrowseSession?.authority == jellyfin.authority)
        #expect(model.activeAuthenticatedBrowseSession?.backend == .jellyfin)
        model.activeBackend = .plex
        #expect(model.activeAuthenticatedBrowseSession?.authority == plex.authority)
        #expect(model.authenticatedBrowseSession(for: .jellyfin)?.authority == jellyfin.authority)
    }

    @Test func signOutRetiresAuthorityBeforeIdenticalSessionCanReturn() throws {
        let model = makeModel(activeBackend: .jellyfin)
        applyMediaBrowser(.jellyfin, to: model)
        let before = try #require(model.activeAuthenticatedBrowseSession)
        let store = KeychainStore(service: "com.labstream.tests.browse-authority.\(UUID().uuidString)",
                                  synchronizesPlexToken: false,
                                  writeInterceptor: { _, _ in true })
        let manager = AuthManager(appModel: model, keychain: store)

        manager.signOut()
        #expect(model.activeAuthenticatedBrowseSession == nil)

        applyMediaBrowser(.jellyfin, to: model)
        let restored = try #require(model.activeAuthenticatedBrowseSession)
        #expect(restored.session == before.session)
        #expect(restored.authority != before.authority)
    }

    @Test func inactiveLaneMutationDoesNotInvalidateActiveAuthority() throws {
        let model = makeModel(activeBackend: .plex)
        applyPlex(to: model)
        applyMediaBrowser(.jellyfin, to: model)
        let activeBefore = try #require(model.activeAuthenticatedBrowseSession)
        let inactiveBefore = try #require(model.authenticatedBrowseSession(for: .jellyfin))

        model.jellyfinAccessToken = "replacement-token"

        let activeAfter = try #require(model.activeAuthenticatedBrowseSession)
        let inactiveAfter = try #require(model.authenticatedBrowseSession(for: .jellyfin))
        #expect(activeAfter.authority == activeBefore.authority)
        #expect(inactiveAfter.authority != inactiveBefore.authority)
    }

    @Test func coherentLanePublicationAdvancesRevisionExactlyOnce() throws {
        let model = makeModel(activeBackend: .jellyfin)
        let before = model.authSessionRevision(for: .jellyfin)

        applyMediaBrowser(.jellyfin, to: model)

        #expect(model.authSessionRevision(for: .jellyfin) == before + 1)
        let context = try #require(model.activeAuthenticatedBrowseSession)
        #expect(context.session.baseURL == URL(string: "https://jellyfin.example.test"))
        #expect(context.session.token == "token-A")
        #expect(context.session.userID == "user-1")
        #expect(context.session.serverID == "server-1")
    }

    private func makeModel(activeBackend: MediaBackendKind) -> AppModel {
        AppModel(identity: ClientIdentity(clientIdentifier: "device-1",
                                          product: "Labstream",
                                          version: "1",
                                          deviceName: "Test Device"),
                 activeBackend: activeBackend)
    }

    private func applyMediaBrowser(_ backend: MediaBackendKind,
                                   to model: AppModel,
                                   token: String = "token-A") {
        model.applyMediaBrowserSession(
            backend: backend,
            server: URL(string: "https://\(backend.rawValue).example.test")!,
            token: token,
            userID: "user-1",
            serverID: "server-1"
        )
    }

    private func applyPlex(to model: AppModel) {
        let server = PlexDevice(name: "Plex",
                                clientIdentifier: "plex-server-1",
                                provides: "server",
                                connections: [])
        model.applyPlexBrowseSession(accountToken: "plex-account-token",
                                     servers: [server],
                                     selectedServer: server,
                                     serverToken: "plex-server-token",
                                     baseURL: URL(string: "https://plex.example.test")!,
                                     isLocal: false,
                                     accountProfile: PlexAccountProfile(uuid: "plex-user-1"))
    }

    private func contexts(in model: AppModel) throws -> [MediaBackendKind: AuthenticatedBrowseSessionContext] {
        var result: [MediaBackendKind: AuthenticatedBrowseSessionContext] = [:]
        for backend in MediaBackendKind.allCases {
            result[backend] = try #require(model.authenticatedBrowseSession(for: backend))
        }
        return result
    }
}
