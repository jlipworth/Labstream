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
    func musicLibraries() async throws -> [MusicLibrary]

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
}

/// A browsable music library/section.
struct MusicLibrary: Identifiable, Hashable {
    let id: String
    let title: String
}

/// One page of a paged listing, carrying the full library size so a grid can pre-size.
struct MusicPage {
    let items: [MediaItem]
    /// Total items in the listing (for scroll pre-sizing); falls back to `items.count`.
    let total: Int
}

/// Cross-backend sort options for the artist/album grids. Each provider maps these onto
/// its own server's sort parameters.
enum MusicBrowseSort {
    case name
    case recentlyAdded
    case year
}

/// Everything an artist page renders. The categorized shelves / popular / appears-on /
/// similar lists are Plex-specific enrichments; MediaBrowser providers leave them empty.
struct ArtistDetailContent {
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
struct ArtistShelf: Identifiable {
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
