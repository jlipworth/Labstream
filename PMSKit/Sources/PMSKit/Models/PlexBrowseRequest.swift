import Foundation

/// Pure request builders for Plex library browsing.
///
/// These methods only describe requests; callers retain ownership of execution,
/// decoding, retries, and UI state. Keeping the wire shape in PMSKit makes the
/// browse API independently testable without changing the app's networking path.
public enum PlexBrowseRequest {
    /// `GET /library/sections` — the libraries available on the server.
    public static func sections(server: URL,
                                token: String,
                                identity: ClientIdentity) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/library/sections"),
                    method: "GET",
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// `GET /library/sections/<key>/all` — items in one library section.
    public static func sectionItems(server: URL,
                                    token: String,
                                    identity: ClientIdentity,
                                    sectionKey: String,
                                    containerStart: Int? = nil,
                                    containerSize: Int? = nil,
                                    sort: String? = nil,
                                    firstCharacter: String? = nil) -> PlexRequest {
        var queryItems: [URLQueryItem] = []
        if let sort { queryItems.append(.init(name: "sort", value: sort)) }
        if let firstCharacter {
            queryItems.append(.init(name: "firstCharacter", value: firstCharacter))
        }
        if let containerStart, let containerSize {
            queryItems.append(.init(name: "X-Plex-Container-Start", value: String(containerStart)))
            queryItems.append(.init(name: "X-Plex-Container-Size", value: String(containerSize)))
        }
        return PlexRequest(
            url: server.appendingPathComponent("/library/sections/\(sectionKey)/all"),
            method: "GET",
            queryItems: queryItems,
            headers: PlexHeaders.standard(identity: identity, token: token)
        )
    }

    /// `GET /library/sections/<key>/firstCharacter` — initials and item counts.
    public static func firstCharacters(server: URL,
                                       token: String,
                                       identity: ClientIdentity,
                                       sectionKey: String,
                                       type: Int? = nil) -> PlexRequest {
        var queryItems: [URLQueryItem] = []
        if let type { queryItems.append(.init(name: "type", value: String(type))) }
        return PlexRequest(
            url: server.appendingPathComponent("/library/sections/\(sectionKey)/firstCharacter"),
            method: "GET",
            queryItems: queryItems,
            headers: PlexHeaders.standard(identity: identity, token: token)
        )
    }

    /// `GET /hubs` — the home-screen hubs.
    public static func hubs(server: URL,
                            token: String,
                            identity: ClientIdentity) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/hubs"),
                    method: "GET",
                    queryItems: [.init(name: "count", value: "20")],
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// `GET /library/onDeck` — the global Continue Watching / On Deck list.
    public static func onDeck(server: URL,
                              token: String,
                              identity: ClientIdentity) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/library/onDeck"),
                    method: "GET",
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// `GET /hubs/search?query=` — global search grouped into hubs.
    public static func search(server: URL,
                              token: String,
                              identity: ClientIdentity,
                              query: String) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/hubs/search"),
                    method: "GET",
                    queryItems: [
                        .init(name: "query", value: query),
                        .init(name: "limit", value: "30"),
                    ],
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// `GET /library/metadata/<ratingKey>/children` — one hierarchy level.
    /// Delegates to the existing authoritative builder rather than duplicating it.
    public static func children(server: URL,
                                token: String,
                                identity: ClientIdentity,
                                ratingKey: String) -> PlexRequest {
        ChildrenRequest.children(server: server,
                                 token: token,
                                 identity: identity,
                                 ratingKey: ratingKey)
    }

    /// `GET /library/metadata/<ratingKey>` — full detail/player metadata.
    public static func metadata(server: URL,
                                token: String,
                                identity: ClientIdentity,
                                ratingKey: String) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/library/metadata/\(ratingKey)"),
                    method: "GET",
                    queryItems: [
                        .init(name: "includeChapters", value: "1"),
                        .init(name: "includeMarkers", value: "1"),
                        .init(name: "includeExtras", value: "1"),
                    ],
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }
}
