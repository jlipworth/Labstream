import Foundation
import PMSKit

// MARK: - Plex browse request builders
//
// The committed PMSKit ships builders for auth/transcode/timeline/optimize but
// not for the plain browse endpoints (sections, hubs, search, item children).
// Those are simple GETs, so the app builds the `PlexRequest`s directly using the
// shared `PlexHeaders.standard(...)`. This file keeps browse wiring discoverable
// without hiding it inside `RootView`.
enum BrowseAPI {
    /// `GET /library/sections` — the list of libraries on the server.
    static func sections(server: URL, token: String, identity: ClientIdentity) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/library/sections"),
                    method: "GET",
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// `GET /library/sections/<key>/all` — every item in a section.
    static func sectionItems(server: URL, token: String, identity: ClientIdentity,
                             sectionKey: String,
                             containerStart: Int? = nil,
                             containerSize: Int? = nil,
                             sort: String? = nil,
                             firstCharacter: String? = nil) -> PlexRequest {
        var queryItems: [URLQueryItem] = []
        if let sort { queryItems.append(.init(name: "sort", value: sort)) }
        if let firstCharacter { queryItems.append(.init(name: "firstCharacter", value: firstCharacter)) }
        if let containerStart, let containerSize {
            queryItems.append(.init(name: "X-Plex-Container-Start", value: String(containerStart)))
            queryItems.append(.init(name: "X-Plex-Container-Size", value: String(containerSize)))
        }
        return PlexRequest(url: server.appendingPathComponent("/library/sections/\(sectionKey)/all"),
                           method: "GET",
                           queryItems: queryItems,
                           headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// `GET /library/sections/<key>/firstCharacter` — available initials + counts for fast jumps.
    /// `type` scopes the initials to one item type within the section (8 = artist, 9 = album),
    /// so a music section's Artists and Albums rails get their own letter runs (#111). Omitted
    /// for the video grids, which use the section's default type.
    static func firstCharacters(server: URL, token: String, identity: ClientIdentity,
                                sectionKey: String, type: Int? = nil) -> PlexRequest {
        var queryItems: [URLQueryItem] = []
        if let type { queryItems.append(.init(name: "type", value: String(type))) }
        return PlexRequest(url: server.appendingPathComponent("/library/sections/\(sectionKey)/firstCharacter"),
                           method: "GET",
                           queryItems: queryItems,
                           headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// `GET /hubs` — the home hubs (Continue Watching, Recently Added, …).
    static func hubs(server: URL, token: String, identity: ClientIdentity) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/hubs"),
                    method: "GET",
                    queryItems: [.init(name: "count", value: "20")],
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// `GET /library/onDeck` — the global Continue Watching / On Deck list (the
    /// movies/episodes with a resume point). Drives the Continue Watching intent
    /// and the Shortcuts parameter suggestions (#24).
    static func onDeck(server: URL, token: String, identity: ClientIdentity) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/library/onDeck"),
                    method: "GET",
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// `GET /hubs/search?query=` — global search grouped into hubs.
    static func search(server: URL, token: String, identity: ClientIdentity,
                       query: String) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/hubs/search"),
                    method: "GET",
                    queryItems: [
                        .init(name: "query", value: query),
                        .init(name: "limit", value: "30"),
                    ],
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// `GET /library/metadata/<ratingKey>/children` — one level of the TV hierarchy:
    /// a show's seasons, or a season's episodes. Delegates to the pure PMSKit builder.
    static func children(server: URL, token: String, identity: ClientIdentity,
                         ratingKey: String) -> PlexRequest {
        ChildrenRequest.children(server: server, token: token,
                                 identity: identity, ratingKey: ratingKey)
    }

    /// `GET /library/metadata/<ratingKey>` — full metadata for one item.
    ///
    /// Requests chapters, intro/credits markers and extras inline so the detail/player
    /// UI can render chapter rows and Skip Intro / Skip Credits without extra round-trips.
    /// These are additive query params; PMS simply omits the corresponding elements when
    /// the item has none.
    static func metadata(server: URL, token: String, identity: ClientIdentity,
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
