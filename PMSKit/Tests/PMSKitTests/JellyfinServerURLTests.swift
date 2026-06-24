import Foundation
import Testing
@testable import PMSKit

@Suite("Jellyfin server URL")
struct JellyfinServerURLTests {
    @Test func bareHostDefaultsToHTTPS() throws {
        let url = try JellyfinServerURL.normalized("jellyfin.example.internal")

        #expect(url == URL(string: "https://jellyfin.example.internal"))
    }

    @Test func trimsWhitespaceBeforeNormalizing() throws {
        let url = try JellyfinServerURL.normalized("  jellyfin.example.internal  ")

        #expect(url == URL(string: "https://jellyfin.example.internal"))
    }

    @Test func preservesExplicitHTTPSURL() throws {
        let url = try JellyfinServerURL.normalized("https://jellyfin.example.internal/base")

        #expect(url == URL(string: "https://jellyfin.example.internal/base"))
    }

    @Test func preservesExplicitHTTPForLocalTesting() throws {
        let url = try JellyfinServerURL.normalized("http://192.0.2.50:8096")

        #expect(url == URL(string: "http://192.0.2.50:8096"))
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
