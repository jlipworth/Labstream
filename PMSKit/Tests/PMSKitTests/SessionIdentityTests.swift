import Foundation
import Testing
@testable import PMSKit

@Suite("Session identity (GH #136)")
struct SessionIdentityTests {
    @Test func stableKeyUsesServerAndUserWithoutRawHostOrToken() throws {
        let key = try #require(SessionIdentity.stableServerUserKey(
            backend: .jellyfin,
            serverID: "server-123",
            baseURL: URL(string: "https://jelly.example.internal:8096/library?api_key=secret")!,
            userID: "user-456"
        ))

        #expect(key.hasPrefix("jellyfin:sid#"))
        #expect(key.contains("server-123") == false)
        #expect(key.contains("user-456") == false)
        #expect(key.contains("jelly.example.internal") == false)
        #expect(key.contains("secret") == false)
    }

    @Test func stableKeyFallsBackToHashedCanonicalBaseURL() throws {
        let a = try #require(SessionIdentity.stableServerUserKey(
            backend: .emby,
            serverID: nil,
            baseURL: URL(string: "HTTPS://Emby.Example.Internal:8920/emby/?ApiKey=secret#frag")!,
            userID: "user-1"
        ))
        let b = try #require(SessionIdentity.stableServerUserKey(
            backend: .emby,
            serverID: nil,
            baseURL: URL(string: "https://emby.example.internal:8920/emby")!,
            userID: "user-1"
        ))

        #expect(a == b)
        #expect(a.hasPrefix("emby:url#"))
        #expect(a.contains("Emby.Example.Internal") == false)
        #expect(a.contains("emby.example.internal") == false)
        #expect(a.contains("secret") == false)
    }

    @Test func browseKeyChangesWithRevisionButStableKeyDoesNot() throws {
        let server = URL(string: "https://media.example.test")!
        let stable = try #require(SessionIdentity.stableServerUserKey(
            backend: .plex,
            serverID: "machine-1",
            baseURL: server,
            userID: "user-1"
        ))
        let rev1 = SessionIdentity.browseSessionKey(backend: .plex,
                                                    serverID: "machine-1",
                                                    baseURL: server,
                                                    userID: "user-1",
                                                    authRevision: 1)
        let rev2 = SessionIdentity.browseSessionKey(backend: .plex,
                                                    serverID: "machine-1",
                                                    baseURL: server,
                                                    userID: "user-1",
                                                    authRevision: 2)

        #expect(rev1 != rev2)
        #expect(rev1.hasPrefix(stable))
        #expect(rev2.hasPrefix(stable))
        #expect(rev1.contains("token") == false)
    }

    @Test func canonicalBaseURLDropsQueryFragmentAndTrailingSlash() {
        let url = URL(string: "https://example.test:443/emby/?X-Emby-Token=secret#frag")!
        #expect(SessionIdentity.canonicalBaseURLIdentity(url) == "https://example.test:443/emby")
    }
}
