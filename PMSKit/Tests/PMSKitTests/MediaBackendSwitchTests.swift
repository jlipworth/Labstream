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

/// Defense-in-depth for #100: an item's actions (play / watched / download) must always
/// target the backend the item ORIGINATED from, never whatever backend happens to be active
/// when the action fires (a stale detail can survive a backend switch).
@Suite("Playback backend resolver (#100)")
struct PlaybackBackendResolverTests {
    @Test func originAlwaysWinsRegardlessOfActiveBackend() {
        for origin in [MediaBackendChoice.plex, .jellyfin, .emby] {
            for active in [MediaBackendChoice.plex, .jellyfin, .emby] {
                let resolved = PlaybackBackendResolver.backend(forItemOrigin: origin,
                                                               currentActive: active)
                #expect(resolved == origin,
                        "origin \(origin) must win over active \(active)")
            }
        }
    }

    @Test func embyItemNeverResolvesToJellyfinAfterSwitch() {
        // The exact bug in the report: an Emby movie's Play after an Emby→Jellyfin switch.
        let resolved = PlaybackBackendResolver.backend(forItemOrigin: .emby,
                                                       currentActive: .jellyfin)
        #expect(resolved == .emby)
    }

    @Test func matchingBackendIsUnchanged() {
        // No switch occurred: origin == active, resolver still returns the origin.
        let resolved = PlaybackBackendResolver.backend(forItemOrigin: .plex,
                                                       currentActive: .plex)
        #expect(resolved == .plex)
    }
}
