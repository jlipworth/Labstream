import Foundation
import Testing
@testable import PMSKit

@Suite("Jellyfin auth")
struct JellyfinAuthTests {
    @Test func authorizationHeaderUsesMediaBrowserScheme() throws {
        let identity = JellyfinClientIdentity(
            client: "VisionPlex",
            device: "Apple Vision Pro",
            deviceId: "device-123",
            version: "0.1.0")

        let header = JellyfinAuth.authorizationHeader(identity: identity, token: "token-abc")

        #expect(header == "MediaBrowser Client=\"VisionPlex\", Device=\"Apple Vision Pro\", DeviceId=\"device-123\", Version=\"0.1.0\", Token=\"token-abc\"")
    }

    @Test func authenticateByNameRequestPostsExpectedJSON() throws {
        let server = try #require(URL(string: "https://jellyfin.example.test"))
        let identity = JellyfinClientIdentity(
            client: "VisionPlex",
            device: "Apple Vision Pro",
            deviceId: "device-123",
            version: "0.1.0")

        let request = try JellyfinAuth.authenticateByNameRequest(
            server: server,
            username: "viewer",
            password: "secret",
            identity: identity)

        #expect(request.url == URL(string: "https://jellyfin.example.test/Users/AuthenticateByName"))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "MediaBrowser Client=\"VisionPlex\", Device=\"Apple Vision Pro\", DeviceId=\"device-123\", Version=\"0.1.0\"")

        let body = try #require(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(object?["Username"] == "viewer")
        #expect(object?["Pw"] == "secret")
    }
}
