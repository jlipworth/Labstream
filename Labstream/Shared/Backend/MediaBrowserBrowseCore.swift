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

struct MediaBrowserBrowsePage: Sendable {
    let items: [MediaItem]
    let total: Int?
}

/// Shared app-facing forwards for the Jellyfin and Emby browse facades.
///
/// Authentication, request construction, playback, cleanup, and mutable-session resolution stay
/// in each concrete facade. Only operations already expressed entirely by the backend-typed browse
/// core belong here.
@MainActor
protocol MediaBrowserBrowseFacade {
    associatedtype Adapter: MediaBrowserBrowseCoreAdapter

    func browseCore() throws -> MediaBrowserBrowseCore<Adapter>
}

extension MediaBrowserBrowseFacade {
    func userViewLinks() async throws -> [MediaBrowserLibraryLink] {
        try await browseCore().userViewLinks()
    }

    /// Tag-aggregated album artists for a music library via `/Artists/AlbumArtists`.
    func albumArtistsPage(parentId: String?,
                          startIndex: Int? = nil,
                          limit: Int? = nil,
                          nameStartsWith: String? = nil,
                          sortBy: String = "SortName",
                          sortOrder: String = "Ascending") async throws -> (items: [MediaItem], total: Int?) {
        let page = try await browseCore().albumArtistsPage(
            parentID: parentId, startIndex: startIndex, limit: limit,
            nameStartsWith: nameStartsWith, sortBy: sortBy, sortOrder: sortOrder
        )
        return (page.items, page.total)
    }

    /// Ordered tracks of an audio playlist. The backend endpoint preserves playlist order, so the
    /// caller must not re-sort.
    func playlistItems(playlistId: String) async throws -> [MediaItem] {
        try await browseCore().playlistItems(playlistID: playlistId)
    }

    func playlistItemsPage(playlistId: String,
                           startIndex: Int,
                           limit: Int) async throws -> (items: [MediaItem], total: Int?) {
        let page = try await browseCore().playlistItemsPage(
            playlistID: playlistId, startIndex: startIndex, limit: limit)
        return (page.items, page.total)
    }

    func searchResults(query: String,
                       views: [MediaBrowserLibraryLink],
                       limitPerLibrary: Int = 50) async throws -> SearchResults {
        try await browseCore().searchResults(query: query,
                                             limitPerLibrary: limitPerLibrary,
                                             views: views)
    }

    func resumeItems(parentId: String? = nil, limit: Int = 20) async throws -> [MediaItem] {
        try await resumeItemsPage(parentId: parentId, startIndex: 0, limit: limit).items
    }

    func resumeItemsPage(parentId: String? = nil,
                         startIndex: Int,
                         limit: Int) async throws -> (items: [MediaItem], total: Int?) {
        let page = try await browseCore().resumeItemsPage(
            parentID: parentId, startIndex: startIndex, limit: limit)
        return (page.items, page.total)
    }

    func nextUp(parentId: String? = nil, limit: Int = 20) async throws -> [MediaItem] {
        try await nextUpPage(parentId: parentId, startIndex: 0, limit: limit).items
    }

    func nextUpPage(parentId: String? = nil,
                    startIndex: Int,
                    limit: Int) async throws -> (items: [MediaItem], total: Int?) {
        let page = try await browseCore().nextUpPage(
            parentID: parentId, startIndex: startIndex, limit: limit)
        return (page.items, page.total)
    }

    func latestItems(parentId: String?,
                     includeItemTypes: String = "Movie,Episode,Video",
                     limit: Int = 20,
                     metadataProfile: MediaBrowserMetadataFieldProfile =
                         MediaBrowserMetadataFieldProfiles.home) async throws -> [MediaItem] {
        try await browseCore().latestItems(parentID: parentId,
                                           includeItemTypes: includeItemTypes,
                                           limit: limit,
                                           metadataProfile: metadataProfile)
    }
}

/// An immutable Jellyfin/Emby browse lane captured in the same MainActor turn as a catalog
/// request. Catalog-derived view ids must never be sent through a facade that can re-read a
/// newer `AppModel` session after the catalog await; this value binds the opaque authority and
/// request credentials together before either operation can suspend.
struct MediaBrowserCatalogClient: Sendable {
    private enum Core: Sendable {
        case jellyfin(MediaBrowserBrowseCore<JellyfinBrowseCoreAdapter>)
        case emby(MediaBrowserBrowseCore<EmbyBrowseCoreAdapter>)
    }

    let backend: MediaBackendKind
    let authority: BrowseSessionAuthority
    private let core: Core

    @MainActor
    init(appModel: AppModel) throws {
        guard let context = appModel.activeAuthenticatedBrowseSession,
              context.backend.isMediaBrowser else {
            throw LibraryCatalogRepositoryError.noAuthenticatedSession
        }
        backend = context.backend
        authority = context.authority
        switch context.backend {
        case .jellyfin:
            core = .jellyfin(try JellyfinBrowseService(appModel: appModel).browseCore())
        case .emby:
            core = .emby(try EmbyBrowseService(appModel: appModel).browseCore())
        case .plex:
            throw LibraryCatalogRepositoryError.backendMismatch
        }
    }

    func matches(_ catalog: LibraryCatalogSnapshot) -> Bool {
        catalog.backend == backend && catalog.authority == authority
    }

    @MainActor
    func isCurrent(in appModel: AppModel) -> Bool {
        guard let current = appModel.activeAuthenticatedBrowseSession else { return false }
        return current.backend == backend && current.authority == authority
    }

    func searchResults(query: String,
                       views: [MediaBrowserLibraryLink],
                       limitPerLibrary: Int = 50) async throws -> SearchResults {
        switch core {
        case .jellyfin(let core):
            return try await core.searchResults(query: query,
                                                limitPerLibrary: limitPerLibrary,
                                                views: views)
        case .emby(let core):
            return try await core.searchResults(query: query,
                                                limitPerLibrary: limitPerLibrary,
                                                views: views)
        }
    }

    func musicPlaylists(in viewID: String) async throws -> [MediaItem] {
        let query = MediaBrowserItemsQuery(
            parentID: viewID,
            recursive: false,
            sortBy: "SortName",
            sortOrder: "Ascending",
            includeItemTypes: "Playlist",
            fields: MediaBrowserMetadataFieldProfiles.music.fields + ",ChildCount"
        )
        switch core {
        case .jellyfin(let core): return try await core.itemsPage(query).items
        case .emby(let core): return try await core.itemsPage(query).items
        }
    }
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
    let browseQuery: LibraryBrowseQuery

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
         filters: [String] = [],
         browseQuery: LibraryBrowseQuery = .default) {
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
        self.browseQuery = browseQuery
    }
}

protocol MediaBrowserBrowseCoreAdapter: Sendable {
    associatedtype Flavor: MediaBrowserFlavor
    associatedtype Identity: Sendable

    var backendID: MediaBackendID { get }

    func userViewsRequest(_ context: MediaBrowserBrowseContext<Identity>) throws -> URLRequest
    func itemsRequest(_ context: MediaBrowserBrowseContext<Identity>,
                      query: MediaBrowserItemsQuery) throws -> URLRequest
    func albumArtistsRequest(_ context: MediaBrowserBrowseContext<Identity>,
                             parentID: String?, startIndex: Int?, limit: Int?,
                             nameStartsWith: String?, sortBy: String,
                             sortOrder: String) throws -> URLRequest
    func playlistItemsRequest(_ context: MediaBrowserBrowseContext<Identity>,
                              playlistID: String,
                              startIndex: Int?,
                              limit: Int?) throws -> URLRequest
    func resumeItemsRequest(_ context: MediaBrowserBrowseContext<Identity>,
                            parentID: String?, startIndex: Int?, limit: Int) throws -> URLRequest
    func nextUpRequest(_ context: MediaBrowserBrowseContext<Identity>,
                       parentID: String?, startIndex: Int?, limit: Int) throws -> URLRequest
    func latestItemsRequest(_ context: MediaBrowserBrowseContext<Identity>,
                            parentID: String?, includeItemTypes: String,
                            limit: Int,
                            metadataProfile: MediaBrowserMetadataFieldProfile) throws -> URLRequest
    func metadataRequest(_ context: MediaBrowserBrowseContext<Identity>,
                         itemID: String) throws -> URLRequest
    func setPlayedRequest(_ context: MediaBrowserBrowseContext<Identity>,
                          itemID: String, played: Bool) throws -> URLRequest
}

/// Shared browse-only execution/decode/map core. The main-actor facades snapshot immutable
/// authentication context before creating this Sendable value; request execution, response decode,
/// and DTO mapping then stay off the main actor. PlaybackInfo, downloads, device profiles, and
/// active-encoding cleanup deliberately remain outside this type so Phase 3 seams stay isolated.
struct MediaBrowserBrowseCore<Adapter: MediaBrowserBrowseCoreAdapter>: Sendable {
    typealias Send = @Sendable (URLRequest) async throws -> Data

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
        return try await execute(
            request,
            as: MediaBrowserItemsResponse<Adapter.Flavor>.self,
            transform: Self.page
        )
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
        return try await execute(
            request,
            as: MediaBrowserItemsResponse<Adapter.Flavor>.self,
            transform: Self.page
        )
    }

    func playlistItems(playlistID: String) async throws -> [MediaItem] {
        try await playlistItemsPage(playlistID: playlistID,
                                    startIndex: nil,
                                    limit: nil).items
    }

    func playlistItemsPage(playlistID: String,
                           startIndex: Int?,
                           limit: Int?) async throws -> MediaBrowserBrowsePage {
        let request = try adapter.playlistItemsRequest(context,
                                                       playlistID: playlistID,
                                                       startIndex: startIndex,
                                                       limit: limit)
        // Server order is the user's playlist order. Mapping must never sort it.
        return try await execute(
            request,
            as: MediaBrowserItemsResponse<Adapter.Flavor>.self,
            transform: Self.page
        )
    }

    /// Search policy consumes a caller-supplied catalog so user-facing Search can share the
    /// exact-authority enumeration repository with Home, Libraries, Music, and Settings.
    func searchResults(query: String,
                       limitPerLibrary: Int,
                       views: [MediaBrowserLibraryLink]) async throws -> SearchResults {
        return try await MediaBrowserSearchFanout.search(
            views: views,
            query: query,
            limitPerLibrary: limitPerLibrary,
            backendID: adapter.backendID
        ) { view, query, limit, itemTypes in
            try await items(MediaBrowserItemsQuery(
                parentID: view.id,
                recursive: true,
                limit: limit,
                searchTerm: query,
                sortBy: "SortName",
                sortOrder: "Ascending",
                includeItemTypes: itemTypes,
                fields: MediaBrowserMetadataFieldProfiles.search.fields
            ))
        }
    }

    func resumeItems(parentID: String? = nil, limit: Int) async throws -> [MediaItem] {
        try await resumeItemsPage(parentID: parentID, startIndex: 0, limit: limit).items
    }

    func resumeItemsPage(parentID: String? = nil,
                         startIndex: Int,
                         limit: Int) async throws -> MediaBrowserBrowsePage {
        let request = try adapter.resumeItemsRequest(
            context, parentID: parentID, startIndex: startIndex, limit: limit)
        return try await execute(
            request,
            as: MediaBrowserItemsResponse<Adapter.Flavor>.self,
            transform: Self.page
        )
    }

    func nextUp(parentID: String? = nil, limit: Int) async throws -> [MediaItem] {
        try await nextUpPage(parentID: parentID, startIndex: 0, limit: limit).items
    }

    func nextUpPage(parentID: String? = nil,
                    startIndex: Int,
                    limit: Int) async throws -> MediaBrowserBrowsePage {
        let request = try adapter.nextUpRequest(
            context, parentID: parentID, startIndex: startIndex, limit: limit)
        return try await execute(
            request,
            as: MediaBrowserItemsResponse<Adapter.Flavor>.self,
            transform: Self.page
        )
    }

    func latestItems(parentID: String?,
                     includeItemTypes: String,
                     limit: Int,
                     metadataProfile: MediaBrowserMetadataFieldProfile =
                         MediaBrowserMetadataFieldProfiles.home) async throws -> [MediaItem] {
        let request = try adapter.latestItemsRequest(context, parentID: parentID,
                                                     includeItemTypes: includeItemTypes,
                                                     limit: limit,
                                                     metadataProfile: metadataProfile)
        return try await execute(
            request,
            as: [MediaBrowserBaseItemDto<Adapter.Flavor>].self,
            transform: Self.map
        )
    }

    func metadata(itemID: String) async throws -> MediaItem? {
        let request = try adapter.metadataRequest(context, itemID: itemID)
        return try await execute(
            request,
            as: MediaBrowserBaseItemDto<Adapter.Flavor>.self
        ) { dto in
            dto.toMediaItem()
        }
    }

    func setPlayed(itemID: String, played: Bool) async throws {
        let request = try adapter.setPlayedRequest(context, itemID: itemID, played: played)
        _ = try await send(request)
    }

    private func execute<Value: Decodable & Sendable>(_ request: URLRequest) async throws -> Value {
        let data = try await send(request)
        return try MediaBrowserRequestExecutor.decode(data, as: Value.self)
    }

    /// Internal so the hosted execution-boundary test can prove both decode and transform run on
    /// this nonisolated executor rather than accidentally hopping back to a calling MainActor.
    func execute<Value: Decodable & Sendable, Output: Sendable>(
        _ request: URLRequest,
        as type: Value.Type,
        transform: @escaping @Sendable (Value) throws -> Output
    ) async throws -> Output {
        let data = try await send(request)
        let decoded = try MediaBrowserRequestExecutor.decode(data, as: type)
        return try transform(decoded)
    }

    private static func page(
        _ response: MediaBrowserItemsResponse<Adapter.Flavor>
    ) -> MediaBrowserBrowsePage {
        MediaBrowserBrowsePage(items: map(response.items), total: response.totalRecordCount)
    }

    private static func map(
        _ values: [MediaBrowserBaseItemDto<Adapter.Flavor>]
    ) -> [MediaItem] {
        values.compactMap { $0.toMediaItem() }
    }
}

/// Bounded concurrent per-library MediaBrowser search. Successful empty libraries degrade to no
/// group, while any request failure preserves the existing all-or-error facade contract. Results
/// remain in server view order rather than task completion order.
@MainActor
enum MediaBrowserSearchFanout {
    static let maximumConcurrentTasks = 4

    typealias FetchItems = @MainActor @Sendable (
        _ view: MediaBrowserLibraryLink,
        _ query: String,
        _ limit: Int,
        _ includeItemTypes: String
    ) async throws -> [MediaItem]

    static func search(views: [MediaBrowserLibraryLink],
                       query: String,
                       limitPerLibrary: Int,
                       backendID: MediaBackendID,
                       fetchItems: @escaping FetchItems) async throws -> SearchResults {
        let groups = try await BoundedAsyncMap.values(
            views,
            maximumConcurrentTasks: maximumConcurrentTasks
        ) { view in
            let items = try await fetchItems(
                view,
                query,
                limitPerLibrary,
                mediaBrowserSearchItemTypes(forCollectionType: view.collectionType)
            )
            return SearchResultGroup.mediaBrowserLibrary(
                backendID: backendID,
                libraryID: view.id,
                title: view.title,
                items: items
            )
        }
        return SearchResults(groups: groups.compactMap { $0 })
    }
}

struct JellyfinBrowseCoreAdapter: MediaBrowserBrowseCoreAdapter {
    typealias Flavor = JellyfinFlavor
    typealias Identity = JellyfinClientIdentity

    let backendID: MediaBackendID = .jellyfin

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
                                         artistIds: q.artistIDs, filters: q.filters,
                                         browseQuery: q.browseQuery)
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

    func playlistItemsRequest(_ c: MediaBrowserBrowseContext<Identity>, playlistID: String,
                              startIndex: Int?, limit: Int?) throws -> URLRequest {
        try JellyfinLibrary.playlistItemsRequest(server: c.server, token: c.token,
                                                 identity: c.identity, userId: c.userID,
                                                 playlistId: playlistID,
                                                 startIndex: startIndex, limit: limit)
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
                            includeItemTypes: String, limit: Int,
                            metadataProfile: MediaBrowserMetadataFieldProfile) throws -> URLRequest {
        try JellyfinLibrary.latestItemsRequest(server: c.server, token: c.token,
                                               identity: c.identity, userId: c.userID,
                                               parentId: parentID,
                                               includeItemTypes: includeItemTypes, limit: limit,
                                               metadataProfile: metadataProfile)
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

    let backendID: MediaBackendID = .emby

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
                                    artistIds: q.artistIDs, filters: q.filters,
                                    browseQuery: q.browseQuery)
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

    func playlistItemsRequest(_ c: MediaBrowserBrowseContext<Identity>, playlistID: String,
                              startIndex: Int?, limit: Int?) throws -> URLRequest {
        try EmbyLibrary.playlistItemsRequest(server: c.server, token: c.token,
                                            identity: c.identity, userId: c.userID,
                                            playlistId: playlistID,
                                            startIndex: startIndex, limit: limit)
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
                            includeItemTypes: String, limit: Int,
                            metadataProfile: MediaBrowserMetadataFieldProfile) throws -> URLRequest {
        try EmbyLibrary.latestItemsRequest(server: c.server, token: c.token,
                                          identity: c.identity, userId: c.userID,
                                          parentId: parentID,
                                          includeItemTypes: includeItemTypes, limit: limit,
                                          metadataProfile: metadataProfile)
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
