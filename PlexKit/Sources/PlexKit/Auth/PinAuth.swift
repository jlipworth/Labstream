import Foundation

public enum PinAuth {
    static let base = URL(string: "https://plex.tv/api/v2/pins")!

    public static func createPinRequest(identity: ClientIdentity) -> PlexRequest {
        PlexRequest(url: base, method: "POST",
                    queryItems: [.init(name: "strong", value: "true")],
                    headers: PlexHeaders.standard(identity: identity, token: nil))
    }

    public static func authAppURL(code: String, identity: ClientIdentity) -> URL {
        var c = URLComponents(string: "https://app.plex.tv/auth")!
        // Plex expects these AFTER the fragment.
        let frag = "?clientID=\(identity.clientIdentifier)&code=\(code)&context[device][product]=\(identity.product)"
        c.fragment = frag
        return c.url!
    }

    public static func pollPinRequest(pinID: Int, identity: ClientIdentity) -> PlexRequest {
        PlexRequest(url: base.appendingPathComponent("\(pinID)"), method: "GET",
                    headers: PlexHeaders.standard(identity: identity, token: nil))
    }
}

public struct PinResponse: Decodable, Sendable {
    public let id: Int
    public let code: String
    public let authToken: String?
}

public struct PinPollResponse: Decodable, Sendable {
    public let id: Int
    public let code: String
    public let authToken: String?
}
