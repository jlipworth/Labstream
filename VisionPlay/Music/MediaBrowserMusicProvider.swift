import Foundation
import PMSKit

/// `MusicProvider` for the MediaBrowser backends (Jellyfin + Emby). Their browse services
/// are method-for-method identical, so this provider drives whichever one matches the
/// active backend through the small `MediaBrowserMusicBrowsing` seam below.
///
/// Music maps onto the standard `/Items` browse: a music view's children are its artists
/// and albums; an album's children are its tracks; an artist's recursive descendants are
/// their albums (or, for Play Artist, every track). `toMediaItem()` (#111 step 1) already
/// maps MusicArtist/MusicAlbum/Audio onto PMS kinds with the album/artist hierarchy, so
/// the rows the rest of the music UI expects fall out for free.
@MainActor
struct MediaBrowserMusicProvider: MusicProvider {
    let appModel: AppModel

    private var browser: MediaBrowserMusicBrowsing {
        switch appModel.activeBackend {
        case .emby: return EmbyBrowseService(appModel: appModel)
        default:    return JellyfinBrowseService(appModel: appModel)
        }
    }

    func musicLibraries() async throws -> [MusicLibrary] {
        try await browser.musicLibraryLinks()
            .filter { $0.collectionType?.lowercased() == "music" }
            .map { MusicLibrary(id: $0.id, title: $0.title) }
    }

    func artists(libraryID: String, sort: MusicBrowseSort, start: Int, size: Int) async throws -> MusicPage {
        // Album artists come from the dedicated `/Artists/AlbumArtists` endpoint, not a
        // `MusicArtist` items browse — the latter only surfaces folder-derived stubs (#111).
        let result = try await browser.musicAlbumArtistsPage(parentId: libraryID,
                                                            sortBy: sort.mediaBrowserSortBy,
                                                            sortOrder: sort.mediaBrowserSortOrder,
                                                            startIndex: start,
                                                            limit: size)
        return MusicPage(items: result.items, total: result.total ?? result.items.count)
    }

    func albums(libraryID: String, sort: MusicBrowseSort, start: Int, size: Int) async throws -> MusicPage {
        try await page(parentId: libraryID, includeItemTypes: "MusicAlbum", sort: sort, start: start, size: size)
    }

    func albumTracks(album: MediaItem) async throws -> [MediaItem] {
        let result = try await browser.musicItemsPage(parentId: album.ratingKey,
                                                      recursive: false,
                                                      includeItemTypes: "Audio",
                                                      sortBy: "ParentIndexNumber,IndexNumber,SortName",
                                                      sortOrder: "Ascending",
                                                      albumArtistIds: nil,
                                                      artistIds: nil,
                                                      filters: [],
                                                      startIndex: nil,
                                                      limit: nil)
        return result.items
    }

    func artistDetail(artist: MediaItem, libraryID: String?) async throws -> ArtistDetailContent {
        // An album-artist entity is a tag aggregate, so its albums are filtered by
        // `AlbumArtistIds`, not reached as folder children (#111). Newest first.
        let result = try await browser.musicItemsPage(parentId: nil,
                                                      recursive: true,
                                                      includeItemTypes: "MusicAlbum",
                                                      sortBy: "ProductionYear,SortName",
                                                      sortOrder: "Descending",
                                                      albumArtistIds: artist.ratingKey,
                                                      artistIds: nil,
                                                      filters: [],
                                                      startIndex: nil,
                                                      limit: nil)
        return ArtistDetailContent(albums: result.items)
    }

    func discographyTracks(artist: MediaItem) async throws -> [MediaItem] {
        // Every track crediting this artist (`ArtistIds` includes featured appearances).
        let result = try await browser.musicItemsPage(parentId: nil,
                                                      recursive: true,
                                                      includeItemTypes: "Audio",
                                                      sortBy: "AlbumArtist,Album,ParentIndexNumber,IndexNumber,SortName",
                                                      sortOrder: "Ascending",
                                                      albumArtistIds: nil,
                                                      artistIds: artist.ratingKey,
                                                      filters: [],
                                                      startIndex: nil,
                                                      limit: nil)
        return result.items
    }

    private func page(parentId: String,
                      includeItemTypes: String,
                      sort: MusicBrowseSort,
                      start: Int,
                      size: Int) async throws -> MusicPage {
        let result = try await browser.musicItemsPage(parentId: parentId,
                                                      recursive: true,
                                                      includeItemTypes: includeItemTypes,
                                                      sortBy: sort.mediaBrowserSortBy,
                                                      sortOrder: sort.mediaBrowserSortOrder,
                                                      albumArtistIds: nil,
                                                      artistIds: nil,
                                                      filters: [],
                                                      startIndex: start,
                                                      limit: size)
        return MusicPage(items: result.items, total: result.total ?? result.items.count)
    }

    // MARK: - Playlists & Home (#111, MediaBrowser-only)

    /// Audio playlists for the Playlists pivot. MediaBrowser keeps playlists in their own
    /// `playlists` collection view (separate from the `music` view), so this lists that
    /// view's `Playlist` children. Empty when the server exposes no playlists view.
    func musicPlaylists() async throws -> [MediaItem] {
        let playlistViews = try await browser.musicLibraryLinks()
            .filter { $0.collectionType?.lowercased() == "playlists" }
        guard let view = playlistViews.first else { return [] }
        let result = try await browser.musicItemsPage(parentId: view.id,
                                                      recursive: false,
                                                      includeItemTypes: "Playlist",
                                                      sortBy: "SortName",
                                                      sortOrder: "Ascending",
                                                      albumArtistIds: nil,
                                                      artistIds: nil,
                                                      filters: [],
                                                      startIndex: nil,
                                                      limit: nil)
        return result.items
    }

    /// A playlist's tracks in PLAYLIST ORDER (`/Playlists/{id}/Items`) — not re-sorted.
    func playlistTracks(playlist: MediaItem) async throws -> [MediaItem] {
        try await browser.musicPlaylistItems(playlistId: playlist.ratingKey)
    }

    /// The music Home rails (#111): Recently Added albums, Recently Played tracks, Favorite
    /// albums. An EMPTY rail is dropped, and a FAILED rail is tolerated (it just doesn't
    /// appear) so one bad request can't blank the whole Home — mirroring the video
    /// `homeRails` degraded-load tolerance (`HomeRailsLoadTracker.attempt`). Fetched
    /// sequentially (the `browser` existential is main-actor-bound, not Sendable, so it
    /// can't ride an `async let` child task — same shape as the video per-view rail loop).
    func musicHomeRails(libraryID: String) async throws -> [MusicHomeRail] {
        var tracker = HomeRailsLoadTracker()
        var rails: [MusicHomeRail] = []

        // Discover leads: a random album shelf. Unlike Recently Added (whose freshest items
        // are mostly art-less here), a random draw is ~95% covered art, so it reads well at the
        // top of Home and surfaces the back catalog (#111).
        let discover = await tracker.attempt {
            try await browser.musicItemsPage(parentId: libraryID,
                                             recursive: true,
                                             includeItemTypes: "MusicAlbum",
                                             sortBy: "Random",
                                             sortOrder: "Ascending",
                                             albumArtistIds: nil,
                                             artistIds: nil,
                                             filters: [],
                                             startIndex: nil,
                                             limit: 20).items
        } ?? []
        if !discover.isEmpty {
            rails.append(MusicHomeRail(id: "discover", title: "Discover",
                                       items: discover, style: .albums))
        }

        let recentlyAdded = await tracker.attempt {
            try await browser.musicLatestItems(parentId: libraryID,
                                               includeItemTypes: "MusicAlbum",
                                               limit: 20)
        } ?? []
        if !recentlyAdded.isEmpty {
            rails.append(MusicHomeRail(id: "recently-added", title: "Recently Added",
                                       items: recentlyAdded, style: .albums))
        }

        let recentlyPlayed = await tracker.attempt {
            try await browser.musicItemsPage(parentId: libraryID,
                                             recursive: true,
                                             includeItemTypes: "Audio",
                                             sortBy: "DatePlayed",
                                             sortOrder: "Descending",
                                             albumArtistIds: nil,
                                             artistIds: nil,
                                             filters: ["IsPlayed"],
                                             startIndex: nil,
                                             limit: 20).items
        } ?? []
        if !recentlyPlayed.isEmpty {
            rails.append(MusicHomeRail(id: "recently-played", title: "Recently Played",
                                       items: recentlyPlayed, style: .tracks))
        }

        let favorites = await tracker.attempt {
            try await browser.musicItemsPage(parentId: libraryID,
                                             recursive: true,
                                             includeItemTypes: "MusicAlbum",
                                             sortBy: "SortName",
                                             sortOrder: "Ascending",
                                             albumArtistIds: nil,
                                             artistIds: nil,
                                             filters: ["IsFavorite"],
                                             startIndex: nil,
                                             limit: 20).items
        } ?? []
        if !favorites.isEmpty {
            rails.append(MusicHomeRail(id: "favorite-albums", title: "Favorite Albums",
                                       items: favorites, style: .albums))
        }
        return rails
    }
}

private extension MusicBrowseSort {
    var mediaBrowserSortBy: String {
        switch self {
        case .name:          return "SortName"
        case .recentlyAdded: return "DateCreated,SortName"
        case .year:          return "ProductionYear,SortName"
        }
    }

    var mediaBrowserSortOrder: String {
        switch self {
        case .name:          return "Ascending"
        case .recentlyAdded: return "Descending"
        case .year:          return "Descending"
        }
    }
}

/// The slice of a MediaBrowser browse service the music provider needs. Both
/// `JellyfinBrowseService` and `EmbyBrowseService` already expose these shapes; the
/// conformances below just rename onto the common seam.
@MainActor
protocol MediaBrowserMusicBrowsing {
    func musicLibraryLinks() async throws -> [(id: String, title: String, collectionType: String?)]
    func musicItemsPage(parentId: String?,
                        recursive: Bool,
                        includeItemTypes: String,
                        sortBy: String,
                        sortOrder: String,
                        albumArtistIds: String?,
                        artistIds: String?,
                        filters: [String],
                        startIndex: Int?,
                        limit: Int?) async throws -> (items: [MediaItem], total: Int?)
    /// Real, tag-aggregated album artists (`/Artists/AlbumArtists`) — not the folder-derived
    /// `MusicArtist` stubs a plain items browse returns (#111).
    func musicAlbumArtistsPage(parentId: String?,
                               sortBy: String,
                               sortOrder: String,
                               startIndex: Int?,
                               limit: Int?) async throws -> (items: [MediaItem], total: Int?)
    /// `/Items/Latest` newest-first items in a library — the Recently Added Home rail (#111).
    func musicLatestItems(parentId: String,
                          includeItemTypes: String,
                          limit: Int) async throws -> [MediaItem]
    /// Ordered tracks of an audio playlist (`/Playlists/{id}/Items`), playlist order
    /// preserved (#111).
    func musicPlaylistItems(playlistId: String) async throws -> [MediaItem]
}

extension JellyfinBrowseService: MediaBrowserMusicBrowsing {
    func musicLibraryLinks() async throws -> [(id: String, title: String, collectionType: String?)] {
        try await userViewLinks().map { ($0.id, $0.title, $0.collectionType) }
    }

    func musicItemsPage(parentId: String?,
                        recursive: Bool,
                        includeItemTypes: String,
                        sortBy: String,
                        sortOrder: String,
                        albumArtistIds: String?,
                        artistIds: String?,
                        filters: [String],
                        startIndex: Int?,
                        limit: Int?) async throws -> (items: [MediaItem], total: Int?) {
        try await itemsPage(parentId: parentId,
                            recursive: recursive,
                            startIndex: startIndex,
                            limit: limit,
                            sortBy: sortBy,
                            sortOrder: sortOrder,
                            includeItemTypes: includeItemTypes,
                            albumArtistIds: albumArtistIds,
                            artistIds: artistIds,
                            filters: filters)
    }

    func musicAlbumArtistsPage(parentId: String?,
                               sortBy: String,
                               sortOrder: String,
                               startIndex: Int?,
                               limit: Int?) async throws -> (items: [MediaItem], total: Int?) {
        try await albumArtistsPage(parentId: parentId,
                                   startIndex: startIndex,
                                   limit: limit,
                                   sortBy: sortBy,
                                   sortOrder: sortOrder)
    }

    func musicLatestItems(parentId: String,
                          includeItemTypes: String,
                          limit: Int) async throws -> [MediaItem] {
        try await latestItems(parentId: parentId, includeItemTypes: includeItemTypes, limit: limit)
    }

    func musicPlaylistItems(playlistId: String) async throws -> [MediaItem] {
        try await playlistItems(playlistId: playlistId)
    }
}

extension EmbyBrowseService: MediaBrowserMusicBrowsing {
    func musicLibraryLinks() async throws -> [(id: String, title: String, collectionType: String?)] {
        try await userViewLinks().map { ($0.id, $0.title, $0.collectionType) }
    }

    func musicItemsPage(parentId: String?,
                        recursive: Bool,
                        includeItemTypes: String,
                        sortBy: String,
                        sortOrder: String,
                        albumArtistIds: String?,
                        artistIds: String?,
                        filters: [String],
                        startIndex: Int?,
                        limit: Int?) async throws -> (items: [MediaItem], total: Int?) {
        try await itemsPage(parentId: parentId,
                            recursive: recursive,
                            startIndex: startIndex,
                            limit: limit,
                            sortBy: sortBy,
                            sortOrder: sortOrder,
                            includeItemTypes: includeItemTypes,
                            albumArtistIds: albumArtistIds,
                            artistIds: artistIds,
                            filters: filters)
    }

    func musicAlbumArtistsPage(parentId: String?,
                               sortBy: String,
                               sortOrder: String,
                               startIndex: Int?,
                               limit: Int?) async throws -> (items: [MediaItem], total: Int?) {
        try await albumArtistsPage(parentId: parentId,
                                   startIndex: startIndex,
                                   limit: limit,
                                   sortBy: sortBy,
                                   sortOrder: sortOrder)
    }

    func musicLatestItems(parentId: String,
                          includeItemTypes: String,
                          limit: Int) async throws -> [MediaItem] {
        try await latestItems(parentId: parentId, includeItemTypes: includeItemTypes, limit: limit)
    }

    func musicPlaylistItems(playlistId: String) async throws -> [MediaItem] {
        try await playlistItems(playlistId: playlistId)
    }
}
