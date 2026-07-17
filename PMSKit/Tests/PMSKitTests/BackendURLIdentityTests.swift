import Testing
import Foundation
@testable import PMSKit

// GH #135 Stage 1e: base-URL identity + persisted-server matching extracted from DownloadManager.

@Suite("Backend URL identity")
struct BackendURLIdentityTests {

    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test func sameBaseURLIgnoresCaseAndImplicitPort() {
        #expect(BackendURLIdentity.sameBaseURL(url("https://Host.Example:443/"), url("https://host.example/")))
        #expect(BackendURLIdentity.sameBaseURL(url("http://h.local:80/base"), url("http://h.local/base/")))
        #expect(BackendURLIdentity.sameBaseURL(url("https://h/emby"), url("https://h/emby")))
    }

    @Test func differentHostPortSchemePathDiffer() {
        #expect(!BackendURLIdentity.sameBaseURL(url("https://a.local"), url("https://b.local")))
        #expect(!BackendURLIdentity.sameBaseURL(url("https://h.local:8096"), url("https://h.local:8920")))
        #expect(!BackendURLIdentity.sameBaseURL(url("http://h.local"), url("https://h.local")))
        #expect(!BackendURLIdentity.sameBaseURL(url("https://h.local/emby"), url("https://h.local/jellyfin")))
    }

    @Test func effectivePortDefaults() {
        #expect(BackendURLIdentity.effectivePort(url("https://h")) == 443)
        #expect(BackendURLIdentity.effectivePort(url("http://h")) == 80)
        #expect(BackendURLIdentity.effectivePort(url("https://h:32400")) == 32400)
    }

    @Test func matchesPersistedServerPrefersServerID() {
        let live = BackendSession(kind: .emby, baseURL: url("https://live.local"),
                                  token: "t", userID: "u", serverID: "SERVER-A")
        // serverID present on both → compared directly (URL irrelevant).
        let sameID = OfflineMetadata(ratingKey: "emby:1", title: "t", type: "movie",
                                     backendBaseURLString: "https://other.local", backendServerID: "SERVER-A")
        #expect(live.matchesPersistedServer(sameID))
        let diffID = OfflineMetadata(ratingKey: "emby:1", title: "t", type: "movie",
                                     backendServerID: "SERVER-B")
        #expect(!live.matchesPersistedServer(diffID))
    }

    @Test func matchesPersistedServerFallsBackToURLThenAllows() {
        let live = BackendSession(kind: .emby, baseURL: url("https://h.local:8096/emby"), token: "t")
        // No serverID → fall back to base-URL identity.
        let sameURL = OfflineMetadata(ratingKey: "emby:1", title: "t", type: "movie",
                                      backendBaseURLString: "https://h.local:8096/emby")
        #expect(live.matchesPersistedServer(sameURL))
        // Legacy/partial metadata with no server identity at all → best-effort allow.
        let legacy = OfflineMetadata(ratingKey: "emby:1", title: "t", type: "movie")
        #expect(live.matchesPersistedServer(legacy))
    }

    @Test func persistedUserOwnershipRejectsReplacementAccountButIgnoresGUIDFormatting() {
        let live = BackendSession(kind: .jellyfin, baseURL: url("https://h.local"),
                                  token: "t", userID: "4C1A2B3D-4E5F-6071-8293-A4B5C6D7E8F9",
                                  serverID: "server")
        let sameUser = OfflineMetadata(ratingKey: "jellyfin:1", title: "t", type: "movie",
                                       backendServerID: "server",
                                       backendUserID: "4c1a2b3d4e5f60718293a4b5c6d7e8f9")
        #expect(live.matchesPersistedServer(sameUser))

        let otherUser = OfflineMetadata(ratingKey: "jellyfin:1", title: "t", type: "movie",
                                        backendServerID: "server",
                                        backendUserID: "00000000-0000-0000-0000-000000000000")
        #expect(!live.matchesPersistedServer(otherUser))

        let signedOut = BackendSession(kind: .jellyfin, baseURL: url("https://h.local"),
                                       token: "t", userID: nil, serverID: "server")
        #expect(!signedOut.matchesPersistedServer(sameUser))
    }
}
