import Foundation

// MARK: - Decodable models

/// A PIN record from `connect.emby.media/service/pin`. All fields are nullable: create
/// returns `Id`/`AccessToken` null, and a confirmed poll returns `AccessToken` as the
/// literal string `"none"` until the PIN is exchanged. The flags default to `false` when
/// absent. Never log `accessToken`.
public struct EmbyConnectPin: Decodable, Sendable, Equatable {
    public let id: String?
    public let pin: String?
    public let deviceId: String?
    public let isExpired: Bool
    public let isConfirmed: Bool
    public let accessToken: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case pin = "Pin"
        case deviceId = "DeviceId"
        case isExpired = "IsExpired"
        case isConfirmed = "IsConfirmed"
        case accessToken = "AccessToken"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        pin = try c.decodeIfPresent(String.self, forKey: .pin)
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId)
        isExpired = try c.decodeIfPresent(Bool.self, forKey: .isExpired) ?? false
        isConfirmed = try c.decodeIfPresent(Bool.self, forKey: .isConfirmed) ?? false
        accessToken = try c.decodeIfPresent(String.self, forKey: .accessToken)
    }
}

/// Result of `POST /service/pin/authenticate`: the Connect user token + Connect user id.
public struct EmbyConnectExchangePinResult: Decodable, Sendable, Equatable {
    public let userId: String?
    public let accessToken: String?

    enum CodingKeys: String, CodingKey {
        case userId = "UserId"
        case accessToken = "AccessToken"
    }
}

/// One linked server from `GET /service/servers`. `accessKey` is the per-server exchange
/// token; `url` is the WAN address and `localAddress` the LAN one. `SupporterKey` is
/// returned by the server but intentionally not modeled — we don't use it.
public struct EmbyConnectServer: Decodable, Sendable, Equatable {
    public let id: String?
    public let systemId: String?
    public let name: String?
    public let url: String?
    public let localAddress: String?
    public let accessKey: String?
    public let userType: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case systemId = "SystemId"
        case name = "Name"
        case url = "Url"
        case localAddress = "LocalAddress"
        case accessKey = "AccessKey"
        case userType = "UserType"
    }
}

/// Result of the per-server `GET /Connect/Exchange`: the normal local server token + user id.
public struct EmbyConnectExchangeResult: Decodable, Sendable, Equatable {
    public let localUserId: String?
    public let accessToken: String?

    enum CodingKeys: String, CodingKey {
        case localUserId = "LocalUserId"
        case accessToken = "AccessToken"
    }
}

// MARK: - Request builders

/// Emby Connect PIN (short-code) sign-in (GH #72). Pure request builders + models; no
/// networking. Steps 1–5 hit the cloud account host `connect.emby.media`; step 6 (exchange)
/// hits the target Emby server. See docs/research/17-emby-backend-support.md for the
/// reverse-engineered, live-verified wire shape. Keep Connect tokens / access keys out of
/// logs and persistence.
public enum EmbyConnect {
    /// Cloud account service base. Not the user's server.
    static let serviceBase = URL(string: "https://connect.emby.media/service")!

    /// Every cloud call identifies the app via `X-Application: <client>/<version>`.
    public static func xApplication(_ identity: EmbyClientIdentity) -> String {
        "\(identity.client)/\(identity.version)"
    }

    /// 1. `POST /service/pin?deviceId=` — mint a short code for this device.
    public static func createPinRequest(identity: EmbyClientIdentity) -> URLRequest {
        var req = cloudRequest(handler: "pin",
                               queryItems: [.init(name: "deviceId", value: identity.deviceId)],
                               identity: identity)
        req.httpMethod = "POST"
        return req
    }

    /// 2. `GET /service/pin?deviceId=&pin=` — poll until `isConfirmed` (or `isExpired`/404).
    public static func pollPinRequest(pin: String, identity: EmbyClientIdentity) -> URLRequest {
        var req = cloudRequest(handler: "pin",
                               queryItems: [.init(name: "deviceId", value: identity.deviceId),
                                            .init(name: "pin", value: pin)],
                               identity: identity)
        req.httpMethod = "GET"
        return req
    }

    /// 3. `POST /service/pin/authenticate` — exchange a confirmed PIN for a Connect token.
    public static func authenticatePinRequest(pin: String, identity: EmbyClientIdentity) -> URLRequest {
        var req = cloudRequest(handler: "pin/authenticate", queryItems: [], identity: identity)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formBody(["deviceId": identity.deviceId, "pin": pin])
        return req
    }

    /// 5. `GET /service/servers?userId=` — list the servers linked to the Connect user.
    public static func serversRequest(connectUserId: String,
                                      connectToken: String,
                                      identity: EmbyClientIdentity) -> URLRequest {
        var req = cloudRequest(handler: "servers",
                               queryItems: [.init(name: "userId", value: connectUserId)],
                               identity: identity)
        req.httpMethod = "GET"
        req.setValue(connectToken, forHTTPHeaderField: "X-Connect-UserToken")
        return req
    }

    /// 6. `GET <server>/Connect/Exchange?format=json&ConnectUserId=` — trade the per-server
    /// `accessKey` (sent as `X-Emby-Token`) for a normal local server token. `server` must
    /// already include the server's API base path (e.g. `…/emby`); this preserves it.
    public static func exchangeRequest(server: URL,
                                       accessKey: String,
                                       connectUserId: String,
                                       identity: EmbyClientIdentity) throws -> URLRequest {
        let url = try EmbyPlayback.embyURL(server: server, path: "/Connect/Exchange",
                                           queryItems: [.init(name: "format", value: "json"),
                                                        .init(name: "ConnectUserId", value: connectUserId)])
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(accessKey, forHTTPHeaderField: "X-Emby-Token")
        req.setValue(EmbyAuth.authorizationHeader(identity: identity), forHTTPHeaderField: "Authorization")
        return req
    }

    /// Turn a Connect server address (the bare `Url`/`LocalAddress` from `/service/servers`,
    /// e.g. `https://host` or `http://10.0.0.2:8096`) into the Emby API base by appending the
    /// `/emby` path segment Emby's clients always use — unless it is already present. The
    /// result is what the rest of the Emby lane treats as `server` (path-preserving joins
    /// then produce `…/emby/<handler>`).
    public static func apiBaseURL(forConnectAddress address: String) throws -> URL {
        let normalized = try EmbyServerURL.normalized(address)
        let lastComponent = normalized.lastPathComponent.lowercased()
        if lastComponent == "emby" { return normalized }
        return normalized.appendingPathComponent("emby")
    }

    // MARK: Helpers

    private static func cloudRequest(handler: String,
                                     queryItems: [URLQueryItem],
                                     identity: EmbyClientIdentity) -> URLRequest {
        let base = serviceBase.appendingPathComponent(handler)
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.queryItems = queryItems.isEmpty ? nil : queryItems
        var req = URLRequest(url: comps.url!)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(xApplication(identity), forHTTPHeaderField: "X-Application")
        return req
    }

    private static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }
}
