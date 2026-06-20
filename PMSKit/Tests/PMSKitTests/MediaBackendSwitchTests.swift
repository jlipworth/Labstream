import Testing
@testable import PMSKit

@Suite("Media backend switch")
struct MediaBackendSwitchTests {
    @Test func sameBackendIsNoOp() {
        let credentials = MediaBackendCredentialSnapshot(plexToken: "plex-token",
                                                         jellyfinServerURLString: nil,
                                                         jellyfinAccessToken: nil,
                                                         jellyfinUserID: nil)

        let resolution = MediaBackendSwitch.resolve(active: .plex,
                                                    target: .plex,
                                                    credentials: credentials)

        #expect(resolution == .alreadyActive)
    }

    @Test func savedPlexTokenCanRestorePlexWhenSwitchingBack() {
        let credentials = MediaBackendCredentialSnapshot(plexToken: "plex-token",
                                                         jellyfinServerURLString: "https://jellyfin.example.test",
                                                         jellyfinAccessToken: "jellyfin-token",
                                                         jellyfinUserID: "user-1")

        let resolution = MediaBackendSwitch.resolve(active: .jellyfin,
                                                    target: .plex,
                                                    credentials: credentials)

        #expect(resolution == .restoreSavedSession)
    }

    @Test func savedJellyfinSessionCanRestoreJellyfinWhenSwitchingFromPlex() {
        let credentials = MediaBackendCredentialSnapshot(plexToken: "plex-token",
                                                         jellyfinServerURLString: "https://jellyfin.example.test",
                                                         jellyfinAccessToken: "jellyfin-token",
                                                         jellyfinUserID: "user-1")

        let resolution = MediaBackendSwitch.resolve(active: .plex,
                                                    target: .jellyfin,
                                                    credentials: credentials)

        #expect(resolution == .restoreSavedSession)
    }

    @Test func missingJellyfinSessionRequiresLoginWithoutForgettingPlex() {
        let credentials = MediaBackendCredentialSnapshot(plexToken: "plex-token",
                                                         jellyfinServerURLString: nil,
                                                         jellyfinAccessToken: nil,
                                                         jellyfinUserID: nil)

        let resolution = MediaBackendSwitch.resolve(active: .plex,
                                                    target: .jellyfin,
                                                    credentials: credentials)

        #expect(resolution == .requireLogin)
    }

    @Test func partialJellyfinSessionRequiresLogin() {
        let credentials = MediaBackendCredentialSnapshot(plexToken: "plex-token",
                                                         jellyfinServerURLString: "https://jellyfin.example.test",
                                                         jellyfinAccessToken: "jellyfin-token",
                                                         jellyfinUserID: nil)

        let resolution = MediaBackendSwitch.resolve(active: .plex,
                                                    target: .jellyfin,
                                                    credentials: credentials)

        #expect(resolution == .requireLogin)
    }

    @Test func savedEmbySessionCanRestoreEmbyWhenSwitchingFromPlex() {
        let credentials = MediaBackendCredentialSnapshot(plexToken: "plex-token",
                                                         jellyfinServerURLString: nil,
                                                         jellyfinAccessToken: nil,
                                                         jellyfinUserID: nil,
                                                         embyServerURLString: "https://emby.example.test/emby",
                                                         embyAccessToken: "emby-token",
                                                         embyUserID: "emby-user-1")

        let resolution = MediaBackendSwitch.resolve(active: .plex,
                                                    target: .emby,
                                                    credentials: credentials)

        #expect(resolution == .restoreSavedSession)
        #expect(credentials.hasSavedSession(for: .emby))
    }

    @Test func missingEmbySessionRequiresLoginWithoutForgettingPlex() {
        let credentials = MediaBackendCredentialSnapshot(plexToken: "plex-token",
                                                         jellyfinServerURLString: nil,
                                                         jellyfinAccessToken: nil,
                                                         jellyfinUserID: nil)

        let resolution = MediaBackendSwitch.resolve(active: .plex,
                                                    target: .emby,
                                                    credentials: credentials)

        #expect(resolution == .requireLogin)
        #expect(!credentials.hasSavedSession(for: .emby))
    }

    @Test func partialEmbySessionRequiresLogin() {
        let credentials = MediaBackendCredentialSnapshot(plexToken: "plex-token",
                                                         jellyfinServerURLString: nil,
                                                         jellyfinAccessToken: nil,
                                                         jellyfinUserID: nil,
                                                         embyServerURLString: "https://emby.example.test/emby",
                                                         embyAccessToken: "emby-token",
                                                         embyUserID: nil)

        let resolution = MediaBackendSwitch.resolve(active: .plex,
                                                    target: .emby,
                                                    credentials: credentials)

        #expect(resolution == .requireLogin)
        #expect(!credentials.hasSavedSession(for: .emby))
    }

    @Test func savedEmbyAndJellyfinAreIndependent() {
        let credentials = MediaBackendCredentialSnapshot(plexToken: nil,
                                                         jellyfinServerURLString: "https://jellyfin.example.test",
                                                         jellyfinAccessToken: "jellyfin-token",
                                                         jellyfinUserID: "user-1",
                                                         embyServerURLString: "https://emby.example.test/emby",
                                                         embyAccessToken: "emby-token",
                                                         embyUserID: "emby-user-1")

        #expect(credentials.hasSavedSession(for: .jellyfin))
        #expect(credentials.hasSavedSession(for: .emby))
        #expect(!credentials.hasSavedSession(for: .plex))
    }
}
