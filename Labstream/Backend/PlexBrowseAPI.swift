import Foundation
import PMSKit

// Source-compatible app facade over PMSKit's pure Plex browse builders. Request
// execution and decoding deliberately remain in the app at the existing call sites.
enum BrowseAPI {
    /// `GET /library/sections` — the list of libraries on the server.
    static func sections(server: URL, token: String, identity: ClientIdentity) -> PlexRequest {
        PlexBrowseRequest.sections(server: server, token: token, identity: identity)
    }

    /// `GET /library/sections/<key>/all` — every item in a section.
    static func sectionItems(server: URL, token: String, identity: ClientIdentity,
                             sectionKey: String,
                             containerStart: Int? = nil,
                             containerSize: Int? = nil,
                             sort: String? = nil,
                             firstCharacter: String? = nil,
                             browseQuery: LibraryBrowseQuery = .default) -> PlexRequest {
        PlexLibraryBrowseRequest.sectionItems(server: server,
                                              token: token,
                                              identity: identity,
                                              sectionKey: sectionKey,
                                              containerStart: containerStart,
                                              containerSize: containerSize,
                                              sort: sort,
                                              firstCharacter: firstCharacter,
                                              browseQuery: browseQuery)
    }

    /// `GET /library/sections/<key>/filters` — section-advertised filter facets.
    static func sectionFilters(server: URL, token: String, identity: ClientIdentity,
                               sectionKey: String) -> PlexRequest {
        PlexLibraryBrowseRequest.sectionFilters(server: server,
                                                token: token,
                                                identity: identity,
                                                sectionKey: sectionKey)
    }

    /// `GET /library/sections/<key>/sorts` — section-advertised sort facets.
    static func sectionSorts(server: URL, token: String, identity: ClientIdentity,
                             sectionKey: String) -> PlexRequest {
        PlexLibraryBrowseRequest.sectionSorts(server: server,
                                              token: token,
                                              identity: identity,
                                              sectionKey: sectionKey)
    }

    /// `GET /library/sections/<key>/firstCharacter` — available initials + counts for fast jumps.
    /// `type` scopes the initials to one item type within the section (8 = artist, 9 = album),
    /// so a music section's Artists and Albums rails get their own letter runs (#111). Omitted
    /// for the video grids, which use the section's default type.
    static func firstCharacters(server: URL, token: String, identity: ClientIdentity,
                                sectionKey: String, type: Int? = nil) -> PlexRequest {
        PlexBrowseRequest.firstCharacters(server: server, token: token, identity: identity,
                                          sectionKey: sectionKey, type: type)
    }

    /// `GET /hubs` — the home hubs (Continue Watching, Recently Added, …).
    static func hubs(server: URL, token: String, identity: ClientIdentity) -> PlexRequest {
        PlexBrowseRequest.hubs(server: server, token: token, identity: identity)
    }

    /// `GET /library/onDeck` — the global Continue Watching / On Deck list (the
    /// movies/episodes with a resume point). Drives the Continue Watching intent
    /// and the Shortcuts parameter suggestions (#24).
    static func onDeck(server: URL, token: String, identity: ClientIdentity) -> PlexRequest {
        PlexBrowseRequest.onDeck(server: server, token: token, identity: identity)
    }

    /// `GET /hubs/search?query=` — global search grouped into hubs.
    static func search(server: URL, token: String, identity: ClientIdentity,
                       query: String) -> PlexRequest {
        PlexBrowseRequest.search(server: server, token: token, identity: identity, query: query)
    }

    /// `GET /library/metadata/<ratingKey>/children` — one level of the TV hierarchy:
    /// a show's seasons, or a season's episodes. Delegates to the pure PMSKit builder.
    static func children(server: URL, token: String, identity: ClientIdentity,
                         ratingKey: String) -> PlexRequest {
        PlexBrowseRequest.children(server: server, token: token,
                                   identity: identity, ratingKey: ratingKey)
    }

    /// `GET /library/collections/<collectionId>/items` — children of a Plex collection.
    /// Collection detail must not reuse the TV `/metadata/{id}/children` endpoint.
    static func collectionItems(server: URL, token: String, identity: ClientIdentity,
                                collectionId: String) -> PlexRequest {
        CollectionRequest.plexCollectionItems(server: server,
                                              token: token,
                                              identity: identity,
                                              collectionId: collectionId)
    }

    /// `GET /library/metadata/<ratingKey>` — full metadata for one item.
    ///
    /// Requests chapters, intro/credits markers and extras inline so the detail/player
    /// UI can render chapter rows and Skip Intro / Skip Credits without extra round-trips.
    /// These are additive query params; PMS simply omits the corresponding elements when
    /// the item has none.
    static func metadata(server: URL, token: String, identity: ClientIdentity,
                         ratingKey: String) -> PlexRequest {
        PlexBrowseRequest.metadata(server: server, token: token,
                                   identity: identity, ratingKey: ratingKey)
    }
}
