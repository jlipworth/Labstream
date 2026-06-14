import Foundation
import Testing
@testable import PMSKit

@Suite("Jellyfin server URL")
struct JellyfinServerURLTests {
    @Test func bareHostDefaultsToHTTPS() throws {
        let url = try JellyfinServerURL.normalized("jelly.crapmaster.org")

        #expect(url == URL(string: "https://jelly.crapmaster.org"))
    }

    @Test func trimsWhitespaceBeforeNormalizing() throws {
        let url = try JellyfinServerURL.normalized("  jelly.crapmaster.org  ")

        #expect(url == URL(string: "https://jelly.crapmaster.org"))
    }

    @Test func preservesExplicitHTTPSURL() throws {
        let url = try JellyfinServerURL.normalized("https://jelly.crapmaster.org/base")

        #expect(url == URL(string: "https://jelly.crapmaster.org/base"))
    }

    @Test func preservesExplicitHTTPForLocalTesting() throws {
        let url = try JellyfinServerURL.normalized("http://192.168.1.50:8096")

        #expect(url == URL(string: "http://192.168.1.50:8096"))
    }

    @Test func rejectsEmptyInput() {
        #expect(throws: JellyfinServerURLError.invalid) {
            _ = try JellyfinServerURL.normalized("   ")
        }
    }

    @Test func rejectsHostlessURLs() {
        #expect(throws: JellyfinServerURLError.invalid) {
            _ = try JellyfinServerURL.normalized("https:///missing-host")
        }
    }
}
