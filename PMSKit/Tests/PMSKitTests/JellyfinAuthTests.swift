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

@Suite("Jellyfin Quick Connect auth")
struct JellyfinQuickConnectAuthTests {
    private let server = URL(string: "https://jellyfin.example.test/base")!
    private let identity = JellyfinClientIdentity(
        client: "VisionPlex",
        device: "Apple Vision Pro",
        deviceId: "device-123",
        version: "0.1.0")

    @Test func enabledRequestUsesOfficialPathAndHeader() throws {
        let request = JellyfinAuth.quickConnectEnabledRequest(server: server, identity: identity)

        #expect(request.url == URL(string: "https://jellyfin.example.test/base/QuickConnect/Enabled"))
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "MediaBrowser Client=\"VisionPlex\", Device=\"Apple Vision Pro\", DeviceId=\"device-123\", Version=\"0.1.0\"")
        #expect(request.httpBody == nil)
    }

    @Test func initiateRequestPostsNoSecretInURLOrBody() throws {
        let request = JellyfinAuth.initiateQuickConnectRequest(server: server, identity: identity)

        #expect(request.url == URL(string: "https://jellyfin.example.test/base/QuickConnect/Initiate"))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "MediaBrowser Client=\"VisionPlex\", Device=\"Apple Vision Pro\", DeviceId=\"device-123\", Version=\"0.1.0\"")
        #expect(request.httpBody == nil)
    }

    @Test func stateRequestUsesRequiredSecretQueryOnly() throws {
        let request = try JellyfinAuth.quickConnectStateRequest(
            server: server,
            secret: "secret with spaces/and/slashes",
            identity: identity)

        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "MediaBrowser Client=\"VisionPlex\", Device=\"Apple Vision Pro\", DeviceId=\"device-123\", Version=\"0.1.0\"")
        let url = try #require(request.url)
        #expect(url.path == "/base/QuickConnect/Connect")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems == [URLQueryItem(name: "secret", value: "secret with spaces/and/slashes")])
        #expect(request.httpBody == nil)
    }

    @Test func quickConnectAuthenticatePostsSecretInJSONBody() throws {
        let request = try JellyfinAuth.authenticateWithQuickConnectRequest(
            server: server,
            secret: "qc-secret",
            identity: identity)

        #expect(request.url == URL(string: "https://jellyfin.example.test/base/path/to/user"))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "MediaBrowser Client=\"VisionPlex\", Device=\"Apple Vision Pro\", DeviceId=\"device-123\", Version=\"0.1.0\"")
        let body = try #require(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(object == ["Secret": "qc-secret"])
    }

    @Test func quickConnectResultDecodesOfficialPascalCaseShape() throws {
        let data = #"""
        {
          "Authenticated": true,
          "Secret": "qc-secret",
          "Code": "ABC123",
          "DeviceId": "device-123",
          "DeviceName": "Apple Vision Pro",
          "AppName": "VisionPlex",
          "AppVersion": "0.1.0",
          "DateAdded": "2026-06-16T12:34:56.789Z"
        }
        """#.data(using: .utf8)!

        let result = try JSONDecoder().decode(JellyfinQuickConnectResult.self, from: data)

        #expect(result.authenticated == true)
        #expect(result.secret == "qc-secret")
        #expect(result.code == "ABC123")
        #expect(result.deviceId == "device-123")
        #expect(result.deviceName == "Apple Vision Pro")
        #expect(result.appName == "VisionPlex")
        #expect(result.appVersion == "0.1.0")
        #expect(result.dateAdded != nil)
    }
}
