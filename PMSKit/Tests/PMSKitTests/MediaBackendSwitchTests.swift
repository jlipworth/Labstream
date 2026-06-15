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
}
