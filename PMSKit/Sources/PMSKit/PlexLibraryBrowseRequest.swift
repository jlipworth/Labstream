import Foundation

/// Request builders for Plex video library browse grids.
///
/// Kept in PMSKit so sort/filter URL shapes are unit-testable while the app can
/// continue to layer UI-specific browse services above these pure builders.
public enum PlexLibraryBrowseRequest {
    /// `GET /library/sections/{sectionKey}/all` — every item in a video section.
    public static func sectionItems(server: URL,
                                    token: String,
                                    identity: ClientIdentity,
                                    sectionKey: String,
                                    containerStart: Int? = nil,
                                    containerSize: Int? = nil,
                                    sort: String? = nil,
                                    firstCharacter: String? = nil,
                                    browseQuery: LibraryBrowseQuery = .default,
                                    extraQueryItems: [URLQueryItem] = []) -> PlexRequest {
        var queryItems: [URLQueryItem] = []
        if let sort {
            queryItems.append(.init(name: "sort", value: sort))
            queryItems.append(contentsOf: browseQuery.filter.plexQueryItems)
        } else {
            queryItems.append(contentsOf: browseQuery.plexQueryItems)
        }
        if let firstCharacter { queryItems.append(.init(name: "firstCharacter", value: firstCharacter)) }
        queryItems.append(contentsOf: extraQueryItems)
        if let containerStart, let containerSize {
            queryItems.append(.init(name: "X-Plex-Container-Start", value: String(containerStart)))
            queryItems.append(.init(name: "X-Plex-Container-Size", value: String(containerSize)))
        }
        return PlexRequest(url: server.appendingPathComponent("/library/sections/\(sectionKey)/all"),
                           method: "GET",
                           queryItems: queryItems,
                           headers: PlexHeaders.standard(identity: identity, token: token))
    }
    /// `GET /library/sections/{sectionKey}/filters` — section-advertised filter facets.
    public static func sectionFilters(server: URL,
                                      token: String,
                                      identity: ClientIdentity,
                                      sectionKey: String) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/library/sections/\(sectionKey)/filters"),
                    method: "GET",
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// `GET /library/sections/{sectionKey}/sorts` — section-advertised sort facets.
    public static func sectionSorts(server: URL,
                                    token: String,
                                    identity: ClientIdentity,
                                    sectionKey: String) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/library/sections/\(sectionKey)/sorts"),
                    method: "GET",
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

}
