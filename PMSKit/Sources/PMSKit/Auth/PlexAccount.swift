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
    public let id: Int?
    public let uuid: String?
    public let username: String?
    public let email: String?
    public let title: String?

    enum CodingKeys: String, CodingKey {
        case id
        case uuid
        case username
        case email
        case title
    }

    public init(id: Int? = nil,
                uuid: String? = nil,
                username: String? = nil,
                email: String? = nil,
                title: String? = nil) {
        self.id = id
        self.uuid = uuid
        self.username = username
        self.email = email
        self.title = title
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let intID = try? container.decodeIfPresent(Int.self, forKey: .id) {
            self.id = intID
        } else if let stringID = try? container.decodeIfPresent(String.self, forKey: .id) {
            self.id = Int(stringID)
        } else {
            self.id = nil
        }
        self.uuid = try container.decodeIfPresent(String.self, forKey: .uuid)
        self.username = try container.decodeIfPresent(String.self, forKey: .username)
        self.email = try container.decodeIfPresent(String.self, forKey: .email)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
    }

    public var displayName: String? {
        [title, username, email]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// Non-display account identity for local cache scoping. Prefer plex.tv's opaque ids; only
    /// fall back to username/email when the API omits ids. Callers hash this before persistence.
    public var stableUserID: String? {
        if let uuid = uuid?.trimmingCharacters(in: .whitespacesAndNewlines), !uuid.isEmpty {
            return "uuid:\(uuid)"
        }
        if let id {
            return "id:\(id)"
        }
        if let username = username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty {
            return "username:\(username)"
        }
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            return "email:\(email)"
        }
        return nil
    }
}
