import Foundation
import Testing
@testable import PMSKit

/// Wire-shape tests for the Emby Connect PIN (short-code) sign-in flow (GH #72).
/// Endpoints/fields were reverse-engineered from Emby's official JS/Java clients and
/// live-verified against connect.emby.media + a real server — see
/// docs/research/17-emby-backend-support.md.
@Suite("Emby Connect PIN")
struct EmbyConnectTests {
    private let identity = EmbyClientIdentity(
        client: "VisionPlay",
        device: "Apple Vision Pro",
        deviceId: "device-123",
        version: "1.0")

    // MARK: X-Application

    @Test func xApplicationHeaderIsClientSlashVersion() {
        #expect(EmbyConnect.xApplication(identity) == "VisionPlay/1.0")
    }

    // MARK: Cloud request builders

    @Test func createPinRequestPostsDeviceIdWithXApplicationAndNoToken() {
        let request = EmbyConnect.createPinRequest(identity: identity)

        #expect(request.httpMethod == "POST")
        #expect(request.url == URL(string: "https://connect.emby.media/service/pin?deviceId=device-123"))
        #expect(request.value(forHTTPHeaderField: "X-Application") == "VisionPlay/1.0")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        // Cloud PIN endpoints carry no Emby/Connect token.
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Connect-UserToken") == nil)
    }

    @Test func pollPinRequestGetsDeviceIdAndPin() {
        let request = EmbyConnect.pollPinRequest(pin: "73494", identity: identity)

        #expect(request.httpMethod == "GET")
        #expect(request.url == URL(string: "https://connect.emby.media/service/pin?deviceId=device-123&pin=73494"))
        #expect(request.value(forHTTPHeaderField: "X-Application") == "VisionPlay/1.0")
        #expect(request.value(forHTTPHeaderField: "X-Connect-UserToken") == nil)
    }

    @Test func authenticatePinRequestPostsFormBodyWithDeviceIdAndPin() throws {
        let request = EmbyConnect.authenticatePinRequest(pin: "73494", identity: identity)

        #expect(request.httpMethod == "POST")
        #expect(request.url == URL(string: "https://connect.emby.media/service/pin/authenticate"))
        #expect(request.value(forHTTPHeaderField: "X-Application") == "VisionPlay/1.0")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")

        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        let pairs = Set(body.split(separator: "&").map(String.init))
        #expect(pairs == ["deviceId=device-123", "pin=73494"])
    }

    @Test func serversRequestGetsUserIdWithConnectUserToken() {
        let request = EmbyConnect.serversRequest(connectUserId: "1717410",
                                                 connectToken: "ctoken-abc",
                                                 identity: identity)

        #expect(request.httpMethod == "GET")
        #expect(request.url == URL(string: "https://connect.emby.media/service/servers?userId=1717410"))
        #expect(request.value(forHTTPHeaderField: "X-Application") == "VisionPlay/1.0")
        #expect(request.value(forHTTPHeaderField: "X-Connect-UserToken") == "ctoken-abc")
    }

    // MARK: Per-server exchange (against the target server)

    @Test func exchangeRequestHitsServerConnectExchangeWithEmbyTokenAndIdentity() throws {
        // The AuthManager resolves the reachable address and appends the /emby base path
        // before calling this; the builder preserves whatever base path it is given.
        let server = try #require(URL(string: "https://emby.example.test/emby"))
        let request = try EmbyConnect.exchangeRequest(server: server,
                                                      accessKey: "server-access-key",
                                                      connectUserId: "1717410",
                                                      identity: identity)

        #expect(request.httpMethod == "GET")
        let url = try #require(request.url)
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(comps.path == "/emby/Connect/Exchange")
        let items = Set(comps.queryItems ?? [])
        #expect(items.contains(URLQueryItem(name: "format", value: "json")))
        #expect(items.contains(URLQueryItem(name: "ConnectUserId", value: "1717410")))
        // The AccessKey authenticates the exchange via X-Emby-Token.
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "server-access-key")
        // Plus the standard Emby identity header (no per-user token yet).
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Emby ") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=") == false)
    }

    // MARK: Decoding (shapes confirmed live)

    @Test func pinDecodesConfirmedShapeWithStringNoneAccessToken() throws {
        // Live: a confirmed poll returns AccessToken as the literal string "none" pre-exchange.
        let data = #"""
        {"Id":"22153871","Pin":"73494","DeviceId":"device-123","IsExpired":false,"IsConfirmed":true,"AccessToken":"none"}
        """#.data(using: .utf8)!

        let pin = try JSONDecoder().decode(EmbyConnectPin.self, from: data)

        #expect(pin.id == "22153871")
        #expect(pin.pin == "73494")
        #expect(pin.isConfirmed == true)
        #expect(pin.isExpired == false)
        #expect(pin.accessToken == "none")
    }

    @Test func pinDecodesCreateShapeWithNullIdAndDefaultsFlags() throws {
        // Live: create returns Id/AccessToken null and the flags false.
        let data = #"""
        {"Id":null,"Pin":"73494","DeviceId":"device-123","IsExpired":false,"IsConfirmed":false,"AccessToken":null}
        """#.data(using: .utf8)!

        let pin = try JSONDecoder().decode(EmbyConnectPin.self, from: data)

        #expect(pin.id == nil)
        #expect(pin.accessToken == nil)
        #expect(pin.isConfirmed == false)
    }

    @Test func exchangePinResultDecodesUserIdAndAccessToken() throws {
        let data = #"{"UserId":"1717410","AccessToken":"connect-token"}"#.data(using: .utf8)!
        let result = try JSONDecoder().decode(EmbyConnectExchangePinResult.self, from: data)

        #expect(result.userId == "1717410")
        #expect(result.accessToken == "connect-token")
    }

    @Test func serverListDecodesAllObservedFields() throws {
        // Field set confirmed live, including SupporterKey (absent from the client source).
        let data = #"""
        [{"Id":"93555d42","Url":"https://emby.example.org","Name":"emby-server",
          "SystemId":"ec061cd8","AccessKey":"0ac5e2c3","LocalAddress":"http://192.0.2.10:8096",
          "UserType":"Linked","SupporterKey":""}]
        """#.data(using: .utf8)!

        let servers = try JSONDecoder().decode([EmbyConnectServer].self, from: data)
        let server = try #require(servers.first)

        #expect(server.systemId == "ec061cd8")
        #expect(server.name == "emby-server")
        #expect(server.url == "https://emby.example.org")
        #expect(server.localAddress == "http://192.0.2.10:8096")
        #expect(server.accessKey == "0ac5e2c3")
        #expect(server.userType == "Linked")
    }

    @Test func exchangeResultDecodesLocalUserIdAndAccessToken() throws {
        let data = #"{"LocalUserId":"0e4d26e2","AccessToken":"server-token"}"#.data(using: .utf8)!
        let result = try JSONDecoder().decode(EmbyConnectExchangeResult.self, from: data)

        #expect(result.localUserId == "0e4d26e2")
        #expect(result.accessToken == "server-token")
    }

    // MARK: API base from a Connect address

    @Test func apiBaseAppendsEmbyToBareWanAddress() throws {
        let url = try EmbyConnect.apiBaseURL(forConnectAddress: "https://emby.example.org")
        #expect(url == URL(string: "https://emby.example.org/emby"))
    }

    @Test func apiBaseAppendsEmbyToLanAddressWithPort() throws {
        let url = try EmbyConnect.apiBaseURL(forConnectAddress: "http://192.0.2.10:8096")
        #expect(url == URL(string: "http://192.0.2.10:8096/emby"))
    }

    @Test func apiBaseDoesNotDoubleEmbyWhenAlreadyPresent() throws {
        let url = try EmbyConnect.apiBaseURL(forConnectAddress: "https://emby.example.org/emby")
        #expect(url == URL(string: "https://emby.example.org/emby"))
    }

    @Test func apiBaseThrowsOnGarbage() {
        #expect(throws: (any Error).self) {
            try EmbyConnect.apiBaseURL(forConnectAddress: "not a url")
        }
    }
}
