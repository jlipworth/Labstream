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

    static func quote(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
