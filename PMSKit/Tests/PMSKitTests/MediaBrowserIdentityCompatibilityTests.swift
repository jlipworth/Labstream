import Foundation
import Testing
@testable import PMSKit

@Suite("MediaBrowser identity compatibility")
struct MediaBrowserIdentityCompatibilityTests {
    @Test("Shared authentication result decodes the golden wire shape")
    func authenticationGoldenDecode() throws {
        let data = Data(#"""
        {
          "AccessToken": "access-xyz",
          "ServerId": "server-1",
          "User": { "Id": "user-9", "Name": "viewer" },
          "SessionInfo": { "Id": "ignored-backend-field" }
        }
        """#.utf8)

        let jellyfin = try JSONDecoder().decode(JellyfinAuthenticationResult.self, from: data)

        #expect(jellyfin == MediaBrowserAuthenticationResult(
            user: MediaBrowserAuthenticatedUser(id: "user-9", name: "viewer"),
            accessToken: "access-xyz",
            serverId: "server-1"
        ))
    }

    @Test("Shared authentication result emits the unchanged PascalCase wire keys")
    func authenticationGoldenEncode() throws {
        let value = MediaBrowserAuthenticationResult(
            user: MediaBrowserAuthenticatedUser(id: "user-9", name: "viewer"),
            accessToken: "access-xyz",
            serverId: "server-1"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let encoded = try encoder.encode(value)

        #expect(String(decoding: encoded, as: UTF8.self) ==
            #"{"AccessToken":"access-xyz","ServerId":"server-1","User":{"Id":"user-9","Name":"viewer"}}"#)
        #expect(try JSONDecoder().decode(JellyfinAuthenticationResult.self, from: encoded) == value)
    }

    @Test("Both backend URL wrappers preserve shared successful normalization")
    func backendURLGoldenNormalization() throws {
        let inputs: [(String, String)] = [
            ("  media.example.test  ", "https://media.example.test"),
            ("http://192.0.2.10:8096", "http://192.0.2.10:8096"),
            ("https://media.example.test/base/path", "https://media.example.test/base/path"),
            // DIVERGENCE FROM JELLYFIN: a user-entered `/emby` base path must survive
            // (formerly pinned by EmbyServerURLTests.preservesEmbyBasePath).
            ("media.example.test/emby", "https://media.example.test/emby"),
        ]

        for (input, expected) in inputs {
            let expectedURL = try #require(URL(string: expected))
            #expect(MediaBrowserServerURL(input)?.url == expectedURL)
            #expect(try JellyfinServerURL.normalized(input) == expectedURL)
            #expect(try EmbyServerURL.normalized(input) == expectedURL)
        }
    }

    @Test("Backend URL wrappers retain their distinct errors for shared invalid input")
    func backendURLGoldenFailures() {
        let inputs = ["", "   ", "ftp://media.example.test", "https:///missing-host"]

        for input in inputs {
            #expect(MediaBrowserServerURL(input) == nil)
            #expect(throws: JellyfinServerURLError.invalid) {
                _ = try JellyfinServerURL.normalized(input)
            }
            #expect(throws: EmbyServerURLError.invalid) {
                _ = try EmbyServerURL.normalized(input)
            }
        }
    }
}
