import Testing
@testable import PMSKit

@Suite("Media backend switch")
struct MediaBackendSwitchTests {
    struct SwitchCase: Sendable, CustomTestStringConvertible {
        let name: String
        let credentials: MediaBackendCredentialSnapshot
        let active: MediaBackendChoice
        let target: MediaBackendChoice
        let expected: MediaBackendSwitchResolution
        /// When non-nil, also pins `hasSavedSession(for: target)`.
        var expectedTargetHasSavedSession: Bool? = nil

        var testDescription: String { name }
    }

    private static let plexOnly = MediaBackendCredentialSnapshot(plexToken: "plex-token",
                                                                 jellyfinServerURLString: nil,
                                                                 jellyfinAccessToken: nil,
                                                                 jellyfinUserID: nil)
    private static let plexAndJellyfin = MediaBackendCredentialSnapshot(
        plexToken: "plex-token",
        jellyfinServerURLString: "https://jellyfin.example.test",
        jellyfinAccessToken: "jellyfin-token",
        jellyfinUserID: "user-1")

    static let cases: [SwitchCase] = [
        SwitchCase(name: "same backend is a no-op",
                   credentials: plexOnly,
                   active: .plex, target: .plex,
                   expected: .alreadyActive),
        SwitchCase(name: "saved Plex token restores Plex when switching back",
                   credentials: plexAndJellyfin,
                   active: .jellyfin, target: .plex,
                   expected: .restoreSavedSession),
        SwitchCase(name: "saved Jellyfin session restores Jellyfin when switching from Plex",
                   credentials: plexAndJellyfin,
                   active: .plex, target: .jellyfin,
                   expected: .restoreSavedSession),
        SwitchCase(name: "missing Jellyfin session requires login without forgetting Plex",
                   credentials: plexOnly,
                   active: .plex, target: .jellyfin,
                   expected: .requireLogin),
        SwitchCase(name: "partial Jellyfin session requires login",
                   credentials: MediaBackendCredentialSnapshot(
                       plexToken: "plex-token",
                       jellyfinServerURLString: "https://jellyfin.example.test",
                       jellyfinAccessToken: "jellyfin-token",
                       jellyfinUserID: nil),
                   active: .plex, target: .jellyfin,
                   expected: .requireLogin),
        SwitchCase(name: "saved Emby session restores Emby when switching from Plex",
                   credentials: MediaBackendCredentialSnapshot(
                       plexToken: "plex-token",
                       jellyfinServerURLString: nil,
                       jellyfinAccessToken: nil,
                       jellyfinUserID: nil,
                       embyServerURLString: "https://emby.example.test/emby",
                       embyAccessToken: "emby-token",
                       embyUserID: "emby-user-1"),
                   active: .plex, target: .emby,
                   expected: .restoreSavedSession,
                   expectedTargetHasSavedSession: true),
        SwitchCase(name: "missing Emby session requires login without forgetting Plex",
                   credentials: plexOnly,
                   active: .plex, target: .emby,
                   expected: .requireLogin,
                   expectedTargetHasSavedSession: false),
        SwitchCase(name: "partial Emby session requires login",
                   credentials: MediaBackendCredentialSnapshot(
                       plexToken: "plex-token",
                       jellyfinServerURLString: nil,
                       jellyfinAccessToken: nil,
                       jellyfinUserID: nil,
                       embyServerURLString: "https://emby.example.test/emby",
                       embyAccessToken: "emby-token",
                       embyUserID: nil),
                   active: .plex, target: .emby,
                   expected: .requireLogin,
                   expectedTargetHasSavedSession: false),
    ]

    @Test(arguments: MediaBackendSwitchTests.cases)
    func resolvesSwitch(_ switchCase: SwitchCase) {
        let resolution = MediaBackendSwitch.resolve(active: switchCase.active,
                                                    target: switchCase.target,
                                                    credentials: switchCase.credentials)

        #expect(resolution == switchCase.expected)
        if let expectedSaved = switchCase.expectedTargetHasSavedSession {
            #expect(switchCase.credentials.hasSavedSession(for: switchCase.target) == expectedSaved)
        }
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
        // Covers every origin/active pair, including the exact #100 bug (an Emby item's Play
        // after an Emby→Jellyfin switch) and the no-switch case (origin == active).
        for origin in [MediaBackendChoice.plex, .jellyfin, .emby] {
            for active in [MediaBackendChoice.plex, .jellyfin, .emby] {
                let resolved = PlaybackBackendResolver.backend(forItemOrigin: origin,
                                                               currentActive: active)
                #expect(resolved == origin,
                        "origin \(origin) must win over active \(active)")
            }
        }
    }
}
