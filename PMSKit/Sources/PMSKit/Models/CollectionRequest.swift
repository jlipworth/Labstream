import Foundation

/// Pure request builders for Plex collection reads. Kept in PMSKit so
/// backend URL semantics are covered by unit tests before UI wiring consumes them.
public enum CollectionRequest {
    /// `GET /library/sections/{sectionKey}/collections` — list backend-defined Plex
    /// collections for one library section.
    public static func plexCollections(server: URL,
                                       token: String,
                                       identity: ClientIdentity,
                                       sectionKey: String,
                                       containerStart: Int? = nil,
                                       containerSize: Int? = nil) -> PlexRequest {
        var queryItems: [URLQueryItem] = []
        appendPlexPaging(start: containerStart, size: containerSize, to: &queryItems)
        return PlexRequest(url: server.appendingPathComponent("/library/sections/\(sectionKey)/collections"),
                           method: "GET",
                           queryItems: queryItems,
                           headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// `GET /library/collections/{collectionId}/items` — list children in a Plex
    /// collection. This is a read endpoint, distinct from MediaBrowser-family collection
    /// management paths. No sort/extra payload params: the grid only needs poster rows,
    /// and the server's curated collection order must be preserved.
    public static func plexCollectionItems(server: URL,
                                           token: String,
                                           identity: ClientIdentity,
                                           collectionId: String,
                                           containerStart: Int? = nil,
                                           containerSize: Int? = nil) -> PlexRequest {
        var queryItems: [URLQueryItem] = []
        appendPlexPaging(start: containerStart, size: containerSize, to: &queryItems)
        return PlexRequest(url: server.appendingPathComponent("/library/collections/\(collectionId)/items"),
                           method: "GET",
                           queryItems: queryItems,
                           headers: PlexHeaders.standard(identity: identity, token: token))
    }

    private static func appendPlexPaging(start: Int?, size: Int?, to queryItems: inout [URLQueryItem]) {
        guard let start, let size else { return }
        queryItems.append(.init(name: "X-Plex-Container-Start", value: String(start)))
        queryItems.append(.init(name: "X-Plex-Container-Size", value: String(size)))
    }
}
