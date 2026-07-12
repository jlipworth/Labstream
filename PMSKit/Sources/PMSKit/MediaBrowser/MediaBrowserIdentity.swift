import Foundation

/// Wire-neutral client identity shared by the Jellyfin and Emby API families.
///
/// Authorization header schemes and token placement deliberately remain in the
/// backend-specific auth builders. This value only captures the four fields whose
/// meaning and representation are identical on both wires.
public struct MediaBrowserClientIdentity: Sendable, Equatable {
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

/// The common authenticated-user shape returned by both Jellyfin and Emby.
public struct MediaBrowserAuthenticatedUser: Codable, Sendable, Equatable {
    public let id: String
    public let name: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
    }

    public init(id: String, name: String?) {
        self.id = id
        self.name = name
    }
}

/// The common successful-authentication envelope returned by both Jellyfin and Emby.
/// Unknown backend-specific response fields continue to be ignored by `Codable`.
public struct MediaBrowserAuthenticationResult: Codable, Sendable, Equatable {
    public let user: MediaBrowserAuthenticatedUser?
    public let accessToken: String?
    public let serverId: String?

    enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
        case serverId = "ServerId"
    }

    public init(user: MediaBrowserAuthenticatedUser?, accessToken: String?, serverId: String?) {
        self.user = user
        self.accessToken = accessToken
        self.serverId = serverId
    }
}

// Source-compatible backend spellings. Their wire shapes are identical; backend auth
// request construction remains separate because schemes and token placement are not.
public typealias JellyfinClientIdentity = MediaBrowserClientIdentity
public typealias EmbyClientIdentity = MediaBrowserClientIdentity
public typealias JellyfinAuthenticatedUser = MediaBrowserAuthenticatedUser
public typealias EmbyAuthenticatedUser = MediaBrowserAuthenticatedUser
public typealias JellyfinAuthenticationResult = MediaBrowserAuthenticationResult
public typealias EmbyAuthenticationResult = MediaBrowserAuthenticationResult
