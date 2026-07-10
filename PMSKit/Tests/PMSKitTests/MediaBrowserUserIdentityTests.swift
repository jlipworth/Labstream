import Testing
@testable import PMSKit

@Suite("Media Browser user identity")
struct MediaBrowserUserIdentityTests {
    @Test func dashedAndDashlessSameGuidAreSameUser() {
        // The canonical Jellyfin/Emby restore case: the saved id and the probed id are the same
        // GUID serialized differently, which must NOT read as a different user (would wipe creds).
        #expect(MediaBrowserUserIdentity.sameUser("4c1a2b3c-4d5e-6f70-8091-a2b3c4d5e6f7",
                                                  "4c1a2b3c4d5e6f708091a2b3c4d5e6f7"))
    }

    @Test func caseDiffersButSameUser() {
        #expect(MediaBrowserUserIdentity.sameUser("4C1A2B3C4D5E6F708091A2B3C4D5E6F7",
                                                  "4c1a2b3c4d5e6f708091a2b3c4d5e6f7"))
        #expect(MediaBrowserUserIdentity.sameUser("4C1A2B3C-4D5E-6F70-8091-A2B3C4D5E6F7",
                                                  "4c1a2b3c4d5e6f708091a2b3c4d5e6f7"))
    }

    @Test func genuinelyDifferentUsersAreNotSame() {
        // A real remap to another account must NOT normalize to equal — the softened restore path
        // preserves the credential here but must never treat the session as confirmed/valid.
        #expect(!MediaBrowserUserIdentity.sameUser("4c1a2b3c-4d5e-6f70-8091-a2b3c4d5e6f7",
                                                   "00000000-0000-0000-0000-000000000000"))
        #expect(!MediaBrowserUserIdentity.sameUser("alice", "bob"))
    }

    @Test func normalizedStripsDashesAndLowercases() {
        #expect(MediaBrowserUserIdentity.normalized("4C1A-2B3C") == "4c1a2b3c")
        #expect(MediaBrowserUserIdentity.normalized("") == "")
    }
}
