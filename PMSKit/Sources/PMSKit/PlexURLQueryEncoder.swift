import Foundation

/// Percent-encodes Plex query item names and values for URL builders that need to
/// return a concrete `URL` instead of a `PlexRequest`.
///
/// `URLComponents.queryItems` leaves several RFC 3986 reserved characters
/// unescaped in query values (`;`, `:`, `/`, `,`, ...). Plex Media Server treats
/// at least `;` as a query separator on some endpoints, so media/server/user
/// strings must be encoded with the unreserved set only.
public enum PlexURLQueryEncoder {
    /// RFC 3986 unreserved characters: ALPHA / DIGIT / "-" / "." / "_" / "~".
    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    public static func percentEncode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: unreserved) ?? component
    }

    /// Builds a `percentEncodedQuery` string from query items.
    ///
    /// Nil values are emitted as bare keys, matching `URLQueryItem` semantics;
    /// empty strings are emitted as `name=`.
    public static func percentEncodedQuery(for queryItems: [URLQueryItem]) -> String {
        queryItems
            .map { item in
                let name = percentEncode(item.name)
                guard let value = item.value else { return name }
                return "\(name)=\(percentEncode(value))"
            }
            .joined(separator: "&")
    }

    /// Replaces a component's query with the strictly encoded query items.
    public static func replaceQueryItems(_ queryItems: [URLQueryItem],
                                         in components: inout URLComponents) {
        let encoded = percentEncodedQuery(for: queryItems)
        components.percentEncodedQuery = encoded.isEmpty ? nil : encoded
    }

    /// Appends strictly encoded query items to an existing component query.
    public static func appendQueryItems(_ queryItems: [URLQueryItem],
                                        to components: inout URLComponents) {
        let encoded = percentEncodedQuery(for: queryItems)
        guard !encoded.isEmpty else { return }
        components.percentEncodedQuery = [components.percentEncodedQuery, encoded]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "&")
    }
}
