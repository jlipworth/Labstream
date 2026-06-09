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
        let items = [
            ("clientID", identity.clientIdentifier),
            ("code", code),
            ("context[device][product]", identity.product),
        ]
        let frag = "?" + items
            .map { "\($0.0.plexFragmentEscaped)=\($0.1.plexFragmentEscaped)" }
            .joined(separator: "&")
        c.percentEncodedFragment = frag
        return c.url!
    }

    public static func pollPinRequest(pinID: Int, identity: ClientIdentity) -> PlexRequest {
        PlexRequest(url: base.appendingPathComponent("\(pinID)"), method: "GET",
                    headers: PlexHeaders.standard(identity: identity, token: nil))
    }
}

private extension String {
    var plexFragmentEscaped: String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=/ ?")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
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
