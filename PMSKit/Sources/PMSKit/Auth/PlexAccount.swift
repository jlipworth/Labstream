import Foundation

/// Small plex.tv account/profile surface used only for non-secret Settings display metadata.
public enum PlexAccount {
    static let base = URL(string: "https://plex.tv/api/v2/user")!

    /// Fetch the signed-in Plex account profile for the current token.
    public static func profileRequest(token: String, identity: ClientIdentity) -> PlexRequest {
        PlexRequest(url: base, method: "GET",
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }
}

/// Non-secret display metadata for the signed-in Plex account.
///
/// The token/auth fields sometimes present in plex.tv responses are intentionally not modeled.
public struct PlexAccountProfile: Decodable, Equatable, Sendable {
    public let username: String?
    public let email: String?
    public let title: String?

    enum CodingKeys: String, CodingKey {
        case username
        case email
        case title
    }

    public init(username: String? = nil, email: String? = nil, title: String? = nil) {
        self.username = username
        self.email = email
        self.title = title
    }

    public var displayName: String? {
        [title, username, email]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}
