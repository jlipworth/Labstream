import Foundation

public struct EmbyClientIdentity: Sendable, Equatable {
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

public struct EmbyAuthenticatedUser: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
    }
}

public struct EmbyAuthenticationResult: Decodable, Sendable, Equatable {
    public let user: EmbyAuthenticatedUser?
    public let accessToken: String?
    public let serverId: String?

    enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
        case serverId = "ServerId"
    }
}

/// `/System/Info/Public` shape — unauthenticated, used for pre-login validation.
public struct EmbyServerInfo: Decodable, Sendable, Equatable {
    public let serverName: String?
    public let version: String?
    public let id: String?

    enum CodingKeys: String, CodingKey {
        case serverName = "ServerName"
        case version = "Version"
        case id = "Id"
    }
}

public enum EmbyAuth {
    /// Build the canonical Emby identity header value.
    ///
    /// DIVERGENCE FROM JELLYFIN: the scheme prefix is `Emby ` (NOT `MediaBrowser `), and
    /// the canonical Emby form additionally carries `UserId=".."` inside the header when
    /// known. `UserId`/`Token` are only included once available.
    public static func authorizationHeader(identity: EmbyClientIdentity,
                                           userId: String? = nil,
                                           token: String? = nil) -> String {
        var parts: [String] = []
        if let userId, !userId.isEmpty {
            parts.append("UserId=\"\(quote(userId))\"")
        }
        parts.append("Client=\"\(quote(identity.client))\"")
        parts.append("Device=\"\(quote(identity.device))\"")
        parts.append("DeviceId=\"\(quote(identity.deviceId))\"")
        parts.append("Version=\"\(quote(identity.version))\"")
        if let token, !token.isEmpty {
            parts.append("Token=\"\(quote(token))\"")
        }
        return "Emby " + parts.joined(separator: ", ")
    }

    /// Apply BOTH the identity `Authorization` header AND, when a token is present, the
    /// `X-Emby-Token` header. REDACT the token in any log/diagnostic string.
    static func applyAuth(to request: inout URLRequest,
                          identity: EmbyClientIdentity,
                          userId: String? = nil,
                          token: String? = nil) {
        request.setValue(authorizationHeader(identity: identity, userId: userId, token: token),
                         forHTTPHeaderField: "Authorization")
        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        }
    }

    /// `GET /System/Info/Public` — UNAUTHENTICATED. Used for pre-login validation.
    public static func serverInfoRequest(server: URL) throws -> URLRequest {
        let url = try EmbyPlayback.embyURL(server: server, path: "/System/Info/Public")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    /// `POST /Users/AuthenticateByName` with `{"Username","Pw"}` plus the identity header
    /// and no token. Never persist or log the password.
    public static func authenticateByNameRequest(server: URL,
                                                 username: String,
                                                 password: String,
                                                 identity: EmbyClientIdentity) throws -> URLRequest {
        let url = try EmbyPlayback.embyURL(server: server, path: "/Users/AuthenticateByName")
        var req = URLRequest(url: url)
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

    /// `POST /Sessions/Logout`. Clear the local session even if this fails.
    public static func logoutRequest(server: URL,
                                     token: String,
                                     identity: EmbyClientIdentity,
                                     userId: String) throws -> URLRequest {
        let url = try EmbyPlayback.embyURL(server: server, path: "/Sessions/Logout")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuth(to: &req, identity: identity, userId: userId, token: token)
        return req
    }

    static func quote(_ value: String) -> String {
        MediaBrowserAuth.quote(value)
    }
}
