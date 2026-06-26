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
                                                      startIndex: start,
                                                      limit: size)
        return MusicPage(items: result.items, total: result.total ?? result.items.count)
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
                        startIndex: Int?,
                        limit: Int?) async throws -> (items: [MediaItem], total: Int?)
    /// Real, tag-aggregated album artists (`/Artists/AlbumArtists`) — not the folder-derived
    /// `MusicArtist` stubs a plain items browse returns (#111).
    func musicAlbumArtistsPage(parentId: String?,
                               sortBy: String,
                               sortOrder: String,
                               startIndex: Int?,
                               limit: Int?) async throws -> (items: [MediaItem], total: Int?)
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
                            artistIds: artistIds)
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
                            artistIds: artistIds)
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
}
