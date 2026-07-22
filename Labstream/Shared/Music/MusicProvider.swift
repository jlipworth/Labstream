import Foundation
import PMSKit

/// Backend-agnostic music browsing surface (#111). The music views and detail screens
/// talk to a `MusicProvider` instead of reaching for Plex's `MusicRequest` directly, so
/// Plex, Jellyfin, and Emby each supply the same shapes (`[MediaItem]`, already mapped to
/// PMS music kinds by `MediaBrowserBaseItemDto.toMediaItem()`).
///
/// Plex-only richness (Popular tracks, PMS-categorized release shelves, Appears On,
/// Similar Artists) is expressed through `ArtistDetailContent`: the Plex provider fills
/// those fields, the MediaBrowser provider leaves them empty, and the view renders
/// whatever it's given — no `if activeBackend == .plex` branching in the UI.
@MainActor
protocol MusicProvider {
    /// The server's music libraries (Plex `artist` sections / MediaBrowser music views).
    func musicLibraries(catalogRepository: LibraryCatalogRepository,
                        forceRefresh: Bool) async throws -> [MusicLibrary]

    /// One page of artists in a library.
    func artists(libraryID: String, sort: MusicBrowseSort, start: Int, size: Int) async throws -> MusicPage

    /// One page of albums in a library.
    func albums(libraryID: String, sort: MusicBrowseSort, start: Int, size: Int) async throws -> MusicPage

    /// An album's tracks, in disc-then-track order.
    func albumTracks(album: MediaItem) async throws -> [MediaItem]

    /// Everything an artist page shows. `libraryID` scopes the richer Plex queries; pass
    /// nil from a cross-library search result (Plex then falls back to a children walk).
    func artistDetail(artist: MediaItem, libraryID: String?) async throws -> ArtistDetailContent

    /// Every playable track under an artist, in album order — Play/Shuffle Artist.
    func discographyTracks(artist: MediaItem) async throws -> [MediaItem]

    /// Audio playlists in the provider's natural display order.
    func musicPlaylists(catalogRepository: LibraryCatalogRepository,
                        forceRefresh: Bool) async throws -> [MediaItem]

    /// One page of a playlist in server order. Duplicate entries must be preserved, including
    /// repeated backend ids within one page or across page boundaries.
    func playlistTracksPage(playlist: MediaItem, start: Int, size: Int) async throws -> PlaylistPage
}

extension MusicProvider {
    /// Compatibility/full-list convenience for non-UI probes. Playlist detail uses the dedicated
    /// pager, but callers that need a complete queue still receive every positional occurrence.
    func playlistTracks(playlist: MediaItem) async throws -> [MediaItem] {
        let pageSize = PlaylistPagingSource.defaultPageSize
        var items: [MediaItem] = []
        var offset = 0
        while true {
            let page = try await playlistTracksPage(playlist: playlist, start: offset, size: pageSize)
            items.append(contentsOf: page.items)
            offset += page.items.count
            if page.items.isEmpty
                || page.reportedTotal.map({ offset >= max($0, 0) }) == true
                || (page.reportedTotal == nil && page.items.count < pageSize) {
                return items
            }
        }
    }
}

/// A browsable music library/section.
struct MusicLibrary: Identifiable, Hashable {
    let id: String
    let title: String
}

/// Music owns its catalog filtering and destination inputs; the shared repository deliberately
/// knows only the server's ordered section/view descriptors.
enum MusicCatalogPolicy {
    static func musicLibraries(from catalog: [LibraryCatalogDescriptor]) -> [MusicLibrary] {
        catalog.filter { $0.kind == .music }
            .map { MusicLibrary(id: $0.sourceID, title: $0.title) }
    }

    static func firstPlaylistViewID(from catalog: [LibraryCatalogDescriptor]) -> String? {
        catalog.first { $0.sourceKind?.lowercased() == "playlists" }?.sourceID
    }
}

/// Catalog task/publication identity for Music. The opaque authority closes credential and
/// client-identity changes that intentionally leave the display-oriented session key unchanged;
/// the allowed-id set also makes a live macOS sidebar visibility edit refilter mounted content.
struct MusicCatalogLoadIdentity: Hashable {
    let browse: AuthenticatedBrowseLoadIdentity
    let allowedLibraryIDs: Set<String>?

    @MainActor
    init(appModel: AppModel, allowedLibraryIDs: Set<String>?) {
        browse = AuthenticatedBrowseLoadIdentity(appModel: appModel)
        self.allowedLibraryIDs = allowedLibraryIDs
    }
}

/// One page of a paged listing, carrying the full library size so a grid can pre-size.
struct MusicPage: Sendable {
    let items: [MediaItem]
    /// Total items in the listing (for scroll pre-sizing); falls back to `items.count`.
    let total: Int
}

/// A page of a playlist. Unlike grids/rails, playlist rows are positional: `items` may contain
/// the same backend identity any number of times and callers must append every occurrence.
struct PlaylistPage: Sendable {
    let items: [MediaItem]
    let reportedTotal: Int?
}

/// Cross-backend sort options for the artist/album grids. Each provider maps these onto
/// its own server's sort parameters. `rawValue` is a stable key, folded into the shared
/// paging source's identity so a sort change rebuilds the grid (#111).
enum MusicBrowseSort: String, CaseIterable, Identifiable, Sendable {
    case name
    case recentlyAdded
    case year

    var id: String { rawValue }

    /// Menu label. "Name" reads as "Title" for albums but the same key drives both grids.
    var label: String {
        switch self {
        case .name:          return "Name"
        case .recentlyAdded: return "Recently Added"
        case .year:          return "Year"
        }
    }

    /// Only an alphabetical sort makes the A–Z rail's offsets meaningful; the other
    /// orderings hide the rail (#111).
    var isAlphabetical: Bool { self == .name }

    /// Sort options offered for each grid: albums get Year, artists don't (no release year).
    static let albumCases: [MusicBrowseSort] = [.recentlyAdded, .name, .year]
    static let artistCases: [MusicBrowseSort] = [.name, .recentlyAdded]
}

/// Everything an artist page renders. The categorized shelves / popular / appears-on /
/// similar lists are Plex-specific enrichments; MediaBrowser providers leave them empty.
struct ArtistDetailContent: Sendable {
    var albums: [MediaItem] = []
    var popular: [MediaItem] = []
    var categorized: [ArtistShelf] = []
    var appearsOn: [MediaItem] = []
    var similar: [MediaItem] = []

    var isEmpty: Bool {
        albums.isEmpty && popular.isEmpty && categorized.isEmpty
            && appearsOn.isEmpty && similar.isEmpty
    }
}

/// A named shelf of album items on the artist page (PMS "Singles & EPs", "Compilations", …).
struct ArtistShelf: Identifiable, Sendable {
    let id: String
    let title: String
    let items: [MediaItem]
}

/// One horizontal rail on the MediaBrowser music Home (#111): Recently Added albums,
/// Recently Played tracks, Favorite albums. `style` decides the tap behavior — an album
/// rail navigates to the album detail, a track rail plays the rail starting at the tap.
struct MusicHomeRail: Identifiable {
    enum Style { case albums, tracks }

    let id: String
    let title: String
    let items: [MediaItem]
    let style: Style
    let destination: RailViewAllDestination?
}

extension AppModel {
    /// The music provider for the active backend.
    var musicProvider: MusicProvider {
        switch activeBackend {
        case .plex:
            return PlexMusicProvider(appModel: self)
        case .jellyfin, .emby:
            return MediaBrowserMusicProvider(appModel: self)
        }
    }
}
