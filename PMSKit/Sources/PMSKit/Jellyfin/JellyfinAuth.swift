import Foundation

public struct JellyfinClientIdentity: Sendable, Equatable {
    public let client: String
    public let device: String
    public let deviceId: String
    public let version: String

    public init(client: String, device: String, deviceId: String, version: String) {
        self.client = client
        self.device = device
        self.deviceId = deviceId
        self.version = version
    }
}

public struct JellyfinQuickConnectResult: Decodable, Sendable, Equatable {
    public let authenticated: Bool
    public let secret: String?
    public let code: String?
    public let deviceId: String?
    public let deviceName: String?
    public let appName: String?
    public let appVersion: String?
    public let dateAdded: Date?

    enum CodingKeys: String, CodingKey {
        case authenticated = "Authenticated"
        case secret = "Secret"
        case code = "Code"
        case deviceId = "DeviceId"
        case deviceName = "DeviceName"
        case appName = "AppName"
        case appVersion = "AppVersion"
        case dateAdded = "DateAdded"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        authenticated = try c.decodeIfPresent(Bool.self, forKey: .authenticated) ?? false
        secret = try c.decodeIfPresent(String.self, forKey: .secret)
        code = try c.decodeIfPresent(String.self, forKey: .code)
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion)
        if let rawDate = try c.decodeIfPresent(String.self, forKey: .dateAdded) {
            dateAdded = Self.parseDate(rawDate)
        } else {
            dateAdded = nil
        }
    }

    private static func parseDate(_ rawValue: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: rawValue) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: rawValue)
    }
}

public enum JellyfinAuth {
    public static func authorizationHeader(identity: JellyfinClientIdentity,
                                           token: String? = nil) -> String {
        var parts = [
            "Client=\"\(quote(identity.client))\"",
            "Device=\"\(quote(identity.device))\"",
            "DeviceId=\"\(quote(identity.deviceId))\"",
            "Version=\"\(quote(identity.version))\"",
        ]
        if let token, !token.isEmpty {
            parts.append("Token=\"\(quote(token))\"")
        }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }

    public static func authenticateByNameRequest(server: URL,
                                                 username: String,
                                                 password: String,
                                                 identity: JellyfinClientIdentity) throws -> URLRequest {
        var req = URLRequest(url: server.appendingPathComponent("Users/AuthenticateByName"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(authorizationHeader(identity: identity), forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "Username": username,
            "Pw": password,
        ], options: [.sortedKeys])
        return req
    }

    public static func quickConnectEnabledRequest(server: URL,
                                                  identity: JellyfinClientIdentity) -> URLRequest {
        var req = URLRequest(url: server.appendingPathComponent("QuickConnect/Enabled"))
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(authorizationHeader(identity: identity), forHTTPHeaderField: "Authorization")
        return req
    }

    public static func initiateQuickConnectRequest(server: URL,
                                                   identity: JellyfinClientIdentity) -> URLRequest {
        var req = URLRequest(url: server.appendingPathComponent("QuickConnect/Initiate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(authorizationHeader(identity: identity), forHTTPHeaderField: "Authorization")
        return req
    }

    public static func quickConnectStateRequest(server: URL,
                                                secret: String,
                                                identity: JellyfinClientIdentity) throws -> URLRequest {
        let url = try quickConnectStateURL(server: server, secret: secret)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(authorizationHeader(identity: identity), forHTTPHeaderField: "Authorization")
        return req
    }

    public static func authenticateWithQuickConnectRequest(server: URL,
                                                           secret: String,
                                                           identity: JellyfinClientIdentity) throws -> URLRequest {
        var req = URLRequest(url: server.appendingPathComponent("Users/AuthenticateWithQuickConnect"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(authorizationHeader(identity: identity), forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "Secret": secret,
        ], options: [.sortedKeys])
        return req
    }

    private static func quickConnectStateURL(server: URL, secret: String) throws -> URL {
        let endpoint = server.appendingPathComponent("QuickConnect/Connect")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw JellyfinServerURLError.invalid
        }
        components.queryItems = [URLQueryItem(name: "secret", value: secret)]
        guard let url = components.url else { throw JellyfinServerURLError.invalid }
        return url
    }

    static func quote(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
