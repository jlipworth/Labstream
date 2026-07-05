import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PMSKit

@Suite("Emby auth")
struct EmbyAuthTests {
    private let identity = EmbyClientIdentity(
        client: "Labstream",
        device: "Apple Vision Pro",
        deviceId: "device-123",
        version: "0.1.0")

    @Test func authorizationHeaderUsesEmbySchemeWithoutUserIdOrTokenWhenUnknown() {
        let header = EmbyAuth.authorizationHeader(identity: identity)

        // DIVERGENCE FROM JELLYFIN: prefix is "Emby " not "MediaBrowser ".
        #expect(header == "Emby Client=\"Labstream\", Device=\"Apple Vision Pro\", DeviceId=\"device-123\", Version=\"0.1.0\"")
        #expect(!header.contains("MediaBrowser"))
        #expect(!header.contains("UserId="))
        #expect(!header.contains("Token="))
    }

    @Test func authorizationHeaderCarriesUserIdAndToken() {
        let header = EmbyAuth.authorizationHeader(identity: identity, userId: "user-9", token: "token-abc")

        #expect(header.hasPrefix("Emby "))
        #expect(header.contains("UserId=\"user-9\""))
        #expect(header.contains("Client=\"Labstream\""))
        #expect(header.contains("DeviceId=\"device-123\""))
        #expect(header.contains("Token=\"token-abc\""))
    }

    @Test func applyAuthSetsBothAuthorizationAndXEmbyToken() {
        var request = URLRequest(url: URL(string: "https://emby.example.test/Sessions")!)
        EmbyAuth.applyAuth(to: &request, identity: identity, userId: "user-9", token: "token-abc")

        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Emby ") == true)
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "token-abc")
    }

    @Test func applyAuthOmitsXEmbyTokenWhenNoToken() {
        var request = URLRequest(url: URL(string: "https://emby.example.test/Sessions")!)
        EmbyAuth.applyAuth(to: &request, identity: identity)

        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Emby ") == true)
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == nil)
    }


    @Test func authorizationHeaderEscapesUserIdTokenAndOmitsEmptyTokenHeader() {
        let escapedIdentity = EmbyClientIdentity(
            client: "Vision\"Play",
            device: "Back\\Slash",
            deviceId: "device-123",
            version: "0.1.0")
        var request = URLRequest(url: URL(string: "https://emby.example.test/Sessions")!)

        EmbyAuth.applyAuth(to: &request,
                           identity: escapedIdentity,
                           userId: "user\"9",
                           token: "")

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Emby UserId=\"user\\\"9\", Client=\"Vision\\\"Play\", Device=\"Back\\\\Slash\", DeviceId=\"device-123\", Version=\"0.1.0\"")
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == nil)
    }

    @Test func serverInfoRequestIsUnauthenticatedGET() throws {
        let server = try #require(URL(string: "https://emby.example.test/emby"))
        let request = try EmbyAuth.serverInfoRequest(server: server)

        #expect(request.httpMethod == "GET")
        #expect(request.url == URL(string: "https://emby.example.test/emby/System/Info/Public"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == nil)
    }

    @Test func authenticateByNameRequestPostsExpectedJSONWithIdentityAndNoToken() throws {
        let server = try #require(URL(string: "https://emby.example.test/emby"))

        let request = try EmbyAuth.authenticateByNameRequest(
            server: server,
            username: "viewer",
            password: "secret",
            identity: identity)

        #expect(request.url == URL(string: "https://emby.example.test/emby/Users/AuthenticateByName"))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Emby ") == true)
        // No token yet at login time.
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=") == false)
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == nil)

        let body = try #require(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(object?["Username"] == "viewer")
        #expect(object?["Pw"] == "secret")
    }

    @Test func logoutRequestPostsWithAuth() throws {
        let server = try #require(URL(string: "https://emby.example.test/emby"))
        let request = try EmbyAuth.logoutRequest(server: server, token: "token-abc", identity: identity, userId: "user-9")

        #expect(request.url == URL(string: "https://emby.example.test/emby/Sessions/Logout"))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "token-abc")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"token-abc\"") == true)
    }

    @Test func authenticationResultDecodesOfficialPascalCaseShape() throws {
        let data = #"""
        {
          "AccessToken": "access-xyz",
          "ServerId": "server-1",
          "User": { "Id": "user-9", "Name": "viewer" },
          "SessionInfo": { "Id": "session-1" }
        }
        """#.data(using: .utf8)!

        let result = try JSONDecoder().decode(EmbyAuthenticationResult.self, from: data)

        #expect(result.accessToken == "access-xyz")
        #expect(result.serverId == "server-1")
        #expect(result.user?.id == "user-9")
        #expect(result.user?.name == "viewer")
    }

    @Test func serverInfoDecodesPublicShape() throws {
        let data = #"""
        { "ServerName": "Home Emby", "Version": "4.9.3.0", "Id": "abc123" }
        """#.data(using: .utf8)!

        let info = try JSONDecoder().decode(EmbyServerInfo.self, from: data)

        #expect(info.serverName == "Home Emby")
        #expect(info.version == "4.9.3.0")
        #expect(info.id == "abc123")
    }
}
