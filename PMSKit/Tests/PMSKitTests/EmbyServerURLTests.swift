import Foundation
import Testing
@testable import PMSKit

@Suite("Emby server URL")
struct EmbyServerURLTests {
    @Test func bareHostDefaultsToHTTPS() throws {
        let url = try EmbyServerURL.normalized("emby.example.test")

        #expect(url == URL(string: "https://emby.example.test"))
    }

    @Test func trimsWhitespaceBeforeNormalizing() throws {
        let url = try EmbyServerURL.normalized("  emby.example.test  ")

        #expect(url == URL(string: "https://emby.example.test"))
    }

    @Test func preservesExplicitHTTPSURL() throws {
        let url = try EmbyServerURL.normalized("https://emby.example.test")

        #expect(url == URL(string: "https://emby.example.test"))
    }

    @Test func preservesEmbyBasePath() throws {
        // DIVERGENCE FROM JELLYFIN: a user-entered `/emby` base path must survive.
        let url = try EmbyServerURL.normalized("https://emby.example.test/emby")

        #expect(url == URL(string: "https://emby.example.test/emby"))
        #expect(url.path == "/emby")
    }

    @Test func preservesBasePathWhenSchemeOmitted() throws {
        let url = try EmbyServerURL.normalized("emby.example.test/emby")

        #expect(url == URL(string: "https://emby.example.test/emby"))
        #expect(url.path == "/emby")
    }

    @Test func preservesExplicitHTTPAndPortForLocalTesting() throws {
        let url = try EmbyServerURL.normalized("http://192.0.2.10:8096")

        #expect(url == URL(string: "http://192.0.2.10:8096"))
    }

    @Test func rejectsEmptyInput() {
        #expect(throws: EmbyServerURLError.invalid) {
            _ = try EmbyServerURL.normalized("   ")
        }
    }

    @Test func rejectsHostlessURLs() {
        #expect(throws: EmbyServerURLError.invalid) {
            _ = try EmbyServerURL.normalized("https:///missing-host")
        }
    }
}
