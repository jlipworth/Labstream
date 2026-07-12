import Foundation
import PMSKit

/// Authenticated values required by the shared Jellyfin/Emby browse core. Resolution from mutable
/// app state stays in each thin facade so an inactive backend can never borrow another lane.
struct MediaBrowserBrowseContext<Identity: Sendable>: Sendable {
    let server: URL
    let token: String
    let userID: String
    let identity: Identity
}

struct MediaBrowserLibraryLink: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let collectionType: String?
}

typealias JellyfinLibraryLink = MediaBrowserLibraryLink
typealias EmbyLibraryLink = MediaBrowserLibraryLink

struct MediaBrowserBrowsePage: Sendable {
    let items: [MediaItem]
    let total: Int?
}

/// Full items/paging/search query while the two public facades retain their existing parameter
/// lists and defaults. Query order and backend casing remain owned by the existing PMSKit wrappers.
struct MediaBrowserItemsQuery: Sendable {
    let parentID: String?
    let recursive: Bool
    let startIndex: Int?
    let limit: Int?
    let searchTerm: String?
    let nameStartsWith: String?
    let sortBy: String
    let sortOrder: String
    let includeItemTypes: String
    let fields: String
    let albumArtistIDs: String?
    let artistIDs: String?
    let filters: [String]

    init(parentID: String?,
         recursive: Bool = false,
         startIndex: Int? = nil,
         limit: Int? = nil,
         searchTerm: String? = nil,
         nameStartsWith: String? = nil,
         sortBy: String = "SortName",
         sortOrder: String = "Ascending",
         includeItemTypes: String = "Movie,Series,Season,Episode,Video",
         fields: String,
         albumArtistIDs: String? = nil,
         artistIDs: String? = nil,
         filters: [String] = []) {
        self.parentID = parentID
        self.recursive = recursive
        self.startIndex = startIndex
        self.limit = limit
        self.searchTerm = searchTerm
        self.nameStartsWith = nameStartsWith
        self.sortBy = sortBy
        self.sortOrder = sortOrder
        self.includeItemTypes = includeItemTypes
        self.fields = fields
        self.albumArtistIDs = albumArtistIDs
        self.artistIDs = artistIDs
        self.filters = filters
    }
}

protocol MediaBrowserBrowseCoreAdapter: Sendable {
    associatedtype Flavor: MediaBrowserFlavor
    associatedtype Identity: Sendable

    func userViewsRequest(_ context: MediaBrowserBrowseContext<Identity>) throws -> URLRequest
    func itemsRequest(_ context: MediaBrowserBrowseContext<Identity>,
                      query: MediaBrowserItemsQuery) throws -> URLRequest
    func albumArtistsRequest(_ context: MediaBrowserBrowseContext<Identity>,
                             parentID: String?, startIndex: Int?, limit: Int?,
                             nameStartsWith: String?, sortBy: String,
                             sortOrder: String) throws -> URLRequest
    func playlistItemsRequest(_ context: MediaBrowserBrowseContext<Identity>,
                              playlistID: String) throws -> URLRequest
    func resumeItemsRequest(_ context: MediaBrowserBrowseContext<Identity>,
                            parentID: String?, startIndex: Int?, limit: Int) throws -> URLRequest
    func nextUpRequest(_ context: MediaBrowserBrowseContext<Identity>,
                       parentID: String?, startIndex: Int?, limit: Int) throws -> URLRequest
    func latestItemsRequest(_ context: MediaBrowserBrowseContext<Identity>,
                            parentID: String?, includeItemTypes: String,
                            limit: Int) throws -> URLRequest
    func metadataRequest(_ context: MediaBrowserBrowseContext<Identity>,
                         itemID: String) throws -> URLRequest
    func setPlayedRequest(_ context: MediaBrowserBrowseContext<Identity>,
                          itemID: String, played: Bool) throws -> URLRequest
}

/// Shared browse-only execution/decode/map core. PlaybackInfo, downloads, device profiles, and
/// active-encoding cleanup deliberately remain outside this type so Phase 3 seams stay isolated.
@MainActor
struct MediaBrowserBrowseCore<Adapter: MediaBrowserBrowseCoreAdapter> {
    typealias Send = (URLRequest) async throws -> Data

    let context: MediaBrowserBrowseContext<Adapter.Identity>
    let adapter: Adapter
    let send: Send

    func userViews() async throws -> [MediaBrowserBaseItemDto<Adapter.Flavor>] {
        let request = try adapter.userViewsRequest(context)
        let response: MediaBrowserUserViewsResponse<Adapter.Flavor> = try await execute(request)
        return response.items
    }

    func userViewLinks() async throws -> [MediaBrowserLibraryLink] {
        try await userViews().map {
            MediaBrowserLibraryLink(id: $0.id, title: $0.name, collectionType: $0.collectionType)
        }
    }

    func items(_ query: MediaBrowserItemsQuery) async throws -> [MediaItem] {
        try await itemsPage(query).items
    }

    func itemsPage(_ query: MediaBrowserItemsQuery) async throws -> MediaBrowserBrowsePage {
        let request = try adapter.itemsRequest(context, query: query)
        let response: MediaBrowserItemsResponse<Adapter.Flavor> = try await execute(request)
        return page(response)
    }

    func albumArtistsPage(parentID: String?,
                          startIndex: Int?,
                          limit: Int?,
                          nameStartsWith: String?,
                          sortBy: String,
                          sortOrder: String) async throws -> MediaBrowserBrowsePage {
        let request = try adapter.albumArtistsRequest(context, parentID: parentID,
                                                      startIndex: startIndex, limit: limit,
                                                      nameStartsWith: nameStartsWith,
                                                      sortBy: sortBy, sortOrder: sortOrder)
        let response: MediaBrowserItemsResponse<Adapter.Flavor> = try await execute(request)
        return page(response)
    }

    func playlistItems(playlistID: String) async throws -> [MediaItem] {
        let request = try adapter.playlistItemsRequest(context, playlistID: playlistID)
        let response: MediaBrowserItemsResponse<Adapter.Flavor> = try await execute(request)
        // Server order is the user's playlist order. Mapping must never sort it.
        return map(response.items)
    }

    func resumeItems(parentID: String? = nil, limit: Int) async throws -> [MediaItem] {
        try await resumeItemsPage(parentID: parentID, startIndex: 0, limit: limit).items
    }

    func resumeItemsPage(parentID: String? = nil,
                         startIndex: Int,
                         limit: Int) async throws -> MediaBrowserBrowsePage {
        let request = try adapter.resumeItemsRequest(
            context, parentID: parentID, startIndex: startIndex, limit: limit)
        let response: MediaBrowserItemsResponse<Adapter.Flavor> = try await execute(request)
        return page(response)
    }

    func nextUp(parentID: String? = nil, limit: Int) async throws -> [MediaItem] {
        try await nextUpPage(parentID: parentID, startIndex: 0, limit: limit).items
    }

    func nextUpPage(parentID: String? = nil,
                    startIndex: Int,
                    limit: Int) async throws -> MediaBrowserBrowsePage {
        let request = try adapter.nextUpRequest(
            context, parentID: parentID, startIndex: startIndex, limit: limit)
        let response: MediaBrowserItemsResponse<Adapter.Flavor> = try await execute(request)
        return page(response)
    }

    func latestItems(parentID: String?,
                     includeItemTypes: String,
                     limit: Int) async throws -> [MediaItem] {
        let request = try adapter.latestItemsRequest(context, parentID: parentID,
                                                     includeItemTypes: includeItemTypes,
                                                     limit: limit)
        let response: [MediaBrowserBaseItemDto<Adapter.Flavor>] = try await execute(request)
        return map(response)
    }

    func metadata(itemID: String) async throws -> MediaItem? {
        let request = try adapter.metadataRequest(context, itemID: itemID)
        let dto: MediaBrowserBaseItemDto<Adapter.Flavor> = try await execute(request)
        return dto.toMediaItem()
    }

    func setPlayed(itemID: String, played: Bool) async throws {
        let request = try adapter.setPlayedRequest(context, itemID: itemID, played: played)
        _ = try await send(request)
    }

    private func execute<Value: Decodable>(_ request: URLRequest) async throws -> Value {
        let data = try await send(request)
        return try MediaBrowserRequestExecutor.decode(data, as: Value.self)
    }

    private func page(_ response: MediaBrowserItemsResponse<Adapter.Flavor>) -> MediaBrowserBrowsePage {
        MediaBrowserBrowsePage(items: map(response.items), total: response.totalRecordCount)
    }

    private func map(_ values: [MediaBrowserBaseItemDto<Adapter.Flavor>]) -> [MediaItem] {
        values.compactMap { $0.toMediaItem() }
    }
}

struct JellyfinBrowseCoreAdapter: MediaBrowserBrowseCoreAdapter {
    typealias Flavor = JellyfinFlavor
    typealias Identity = JellyfinClientIdentity

    func userViewsRequest(_ c: MediaBrowserBrowseContext<Identity>) throws -> URLRequest {
        try JellyfinLibrary.userViewsRequest(server: c.server, token: c.token,
                                             identity: c.identity, userId: c.userID)
    }

    func itemsRequest(_ c: MediaBrowserBrowseContext<Identity>,
                      query q: MediaBrowserItemsQuery) throws -> URLRequest {
        try JellyfinLibrary.itemsRequest(server: c.server, token: c.token, identity: c.identity,
                                         userId: c.userID, parentId: q.parentID,
                                         recursive: q.recursive, startIndex: q.startIndex,
                                         limit: q.limit, searchTerm: q.searchTerm,
                                         nameStartsWith: q.nameStartsWith, sortBy: q.sortBy,
                                         sortOrder: q.sortOrder, includeItemTypes: q.includeItemTypes,
                                         fields: q.fields, albumArtistIds: q.albumArtistIDs,
                                         artistIds: q.artistIDs, filters: q.filters)
    }

    func albumArtistsRequest(_ c: MediaBrowserBrowseContext<Identity>, parentID: String?,
                             startIndex: Int?, limit: Int?, nameStartsWith: String?,
                             sortBy: String, sortOrder: String) throws -> URLRequest {
        try JellyfinLibrary.albumArtistsRequest(server: c.server, token: c.token,
                                                identity: c.identity, userId: c.userID,
                                                parentId: parentID, startIndex: startIndex,
                                                limit: limit, nameStartsWith: nameStartsWith,
                                                sortBy: sortBy, sortOrder: sortOrder)
    }

    func playlistItemsRequest(_ c: MediaBrowserBrowseContext<Identity>, playlistID: String) throws -> URLRequest {
        try JellyfinLibrary.playlistItemsRequest(server: c.server, token: c.token,
                                                 identity: c.identity, userId: c.userID,
                                                 playlistId: playlistID)
    }

    func resumeItemsRequest(_ c: MediaBrowserBrowseContext<Identity>, parentID: String?, startIndex: Int?, limit: Int) throws -> URLRequest {
        try JellyfinLibrary.resumeItemsRequest(server: c.server, token: c.token,
                                               identity: c.identity, userId: c.userID,
                                               parentId: parentID, startIndex: startIndex, limit: limit)
    }

    func nextUpRequest(_ c: MediaBrowserBrowseContext<Identity>, parentID: String?, startIndex: Int?, limit: Int) throws -> URLRequest {
        try JellyfinLibrary.nextUpRequest(server: c.server, token: c.token,
                                         identity: c.identity, userId: c.userID,
                                         parentId: parentID, startIndex: startIndex, limit: limit)
    }

    func latestItemsRequest(_ c: MediaBrowserBrowseContext<Identity>, parentID: String?,
                            includeItemTypes: String, limit: Int) throws -> URLRequest {
        try JellyfinLibrary.latestItemsRequest(server: c.server, token: c.token,
                                               identity: c.identity, userId: c.userID,
                                               parentId: parentID,
                                               includeItemTypes: includeItemTypes, limit: limit)
    }

    func metadataRequest(_ c: MediaBrowserBrowseContext<Identity>, itemID: String) throws -> URLRequest {
        try JellyfinLibrary.itemRequest(server: c.server, token: c.token,
                                       identity: c.identity, userId: c.userID, itemId: itemID)
    }

    func setPlayedRequest(_ c: MediaBrowserBrowseContext<Identity>, itemID: String,
                          played: Bool) throws -> URLRequest {
        try JellyfinLibrary.markPlayedRequest(server: c.server, token: c.token,
                                              identity: c.identity, userId: c.userID,
                                              itemId: itemID, played: played)
    }
}

struct EmbyBrowseCoreAdapter: MediaBrowserBrowseCoreAdapter {
    typealias Flavor = EmbyFlavor
    typealias Identity = EmbyClientIdentity

    func userViewsRequest(_ c: MediaBrowserBrowseContext<Identity>) throws -> URLRequest {
        try EmbyLibrary.userViewsRequest(server: c.server, token: c.token,
                                        identity: c.identity, userId: c.userID)
    }

    func itemsRequest(_ c: MediaBrowserBrowseContext<Identity>,
                      query q: MediaBrowserItemsQuery) throws -> URLRequest {
        try EmbyLibrary.itemsRequest(server: c.server, token: c.token, identity: c.identity,
                                    userId: c.userID, parentId: q.parentID,
                                    recursive: q.recursive, startIndex: q.startIndex,
                                    limit: q.limit, searchTerm: q.searchTerm,
                                    nameStartsWith: q.nameStartsWith, sortBy: q.sortBy,
                                    sortOrder: q.sortOrder, includeItemTypes: q.includeItemTypes,
                                    fields: q.fields, albumArtistIds: q.albumArtistIDs,
                                    artistIds: q.artistIDs, filters: q.filters)
    }

    func albumArtistsRequest(_ c: MediaBrowserBrowseContext<Identity>, parentID: String?,
                             startIndex: Int?, limit: Int?, nameStartsWith: String?,
                             sortBy: String, sortOrder: String) throws -> URLRequest {
        try EmbyLibrary.albumArtistsRequest(server: c.server, token: c.token,
                                           identity: c.identity, userId: c.userID,
                                           parentId: parentID, startIndex: startIndex,
                                           limit: limit, nameStartsWith: nameStartsWith,
                                           sortBy: sortBy, sortOrder: sortOrder)
    }

    func playlistItemsRequest(_ c: MediaBrowserBrowseContext<Identity>, playlistID: String) throws -> URLRequest {
        try EmbyLibrary.playlistItemsRequest(server: c.server, token: c.token,
                                            identity: c.identity, userId: c.userID,
                                            playlistId: playlistID)
    }

    func resumeItemsRequest(_ c: MediaBrowserBrowseContext<Identity>, parentID: String?, startIndex: Int?, limit: Int) throws -> URLRequest {
        try EmbyLibrary.resumeItemsRequest(server: c.server, token: c.token,
                                          identity: c.identity, userId: c.userID,
                                          parentId: parentID, startIndex: startIndex, limit: limit)
    }

    func nextUpRequest(_ c: MediaBrowserBrowseContext<Identity>, parentID: String?, startIndex: Int?, limit: Int) throws -> URLRequest {
        try EmbyLibrary.nextUpRequest(server: c.server, token: c.token,
                                     identity: c.identity, userId: c.userID,
                                     parentId: parentID, startIndex: startIndex, limit: limit)
    }

    func latestItemsRequest(_ c: MediaBrowserBrowseContext<Identity>, parentID: String?,
                            includeItemTypes: String, limit: Int) throws -> URLRequest {
        try EmbyLibrary.latestItemsRequest(server: c.server, token: c.token,
                                          identity: c.identity, userId: c.userID,
                                          parentId: parentID,
                                          includeItemTypes: includeItemTypes, limit: limit)
    }

    func metadataRequest(_ c: MediaBrowserBrowseContext<Identity>, itemID: String) throws -> URLRequest {
        try EmbyLibrary.itemRequest(server: c.server, token: c.token,
                                   identity: c.identity, userId: c.userID, itemId: itemID)
    }

    func setPlayedRequest(_ c: MediaBrowserBrowseContext<Identity>, itemID: String,
                          played: Bool) throws -> URLRequest {
        try EmbyLibrary.markPlayedRequest(server: c.server, token: c.token,
                                         identity: c.identity, userId: c.userID,
                                         itemId: itemID, played: played)
    }
}
