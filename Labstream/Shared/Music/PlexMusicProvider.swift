import Foundation
import PMSKit

/// `MusicProvider` for Plex — a thin wrapper over the existing `MusicRequest` / `BrowseAPI`
/// calls the music views used to make inline. Behavior is unchanged; it just lives behind
/// the protocol so `AlbumDetailView` / `ArtistDetailView` stop hard-coding Plex.
@MainActor
struct PlexMusicProvider: MusicProvider {
    let appModel: AppModel

    /// `LocalizedError` so `friendlyMessage` surfaces "No server selected." rather than the raw
    /// Foundation string. This replaces the per-view `guard let server, token` checks the music
    /// detail views used to carry — the not-connected case now reads friendly from any provider
    /// method that calls `session()` (load, playDiscography, …).
    private struct NotConnected: LocalizedError {
        var errorDescription: String? { "No server selected." }
    }

    func musicLibraries(catalogRepository: LibraryCatalogRepository,
                        forceRefresh: Bool) async throws -> [MusicLibrary] {
        let snapshot = try await catalogRepository.catalog(appModel: appModel,
                                                           forceRefresh: forceRefresh)
        return MusicCatalogPolicy.musicLibraries(from: snapshot.descriptors)
    }

    func artists(libraryID: String, sort: MusicBrowseSort, start: Int, size: Int) async throws -> MusicPage {
        guard let service = try? PlexBrowseService(appModel: appModel) else { throw NotConnected() }
        return try await service.musicArtists(libraryID: libraryID, sort: sort.plexArtistSort,
                                              start: start, size: size)
    }

    func albums(libraryID: String, sort: MusicBrowseSort, start: Int, size: Int) async throws -> MusicPage {
        guard let service = try? PlexBrowseService(appModel: appModel) else { throw NotConnected() }
        return try await service.musicAlbums(libraryID: libraryID, sort: sort.plexAlbumSort,
                                             start: start, size: size)
    }

    func albumTracks(album: MediaItem) async throws -> [MediaItem] {
        guard let service = try? PlexBrowseService(appModel: appModel) else { throw NotConnected() }
        return try await service.children(ratingKey: album.ratingKey).sorted {
            ($0.parentIndex ?? 1, $0.index ?? 0) < ($1.parentIndex ?? 1, $1.index ?? 0)
        }
    }

    func discographyTracks(artist: MediaItem) async throws -> [MediaItem] {
        guard let service = try? PlexBrowseService(appModel: appModel) else { throw NotConnected() }
        return try await service.discographyTracks(artistRatingKey: artist.ratingKey)
    }

    func musicPlaylists(catalogRepository: LibraryCatalogRepository,
                        forceRefresh: Bool) async throws -> [MediaItem] {
        guard let service = try? PlexBrowseService(appModel: appModel) else { throw NotConnected() }
        return try await service.musicPlaylists()
    }

    func playlistTracksPage(playlist: MediaItem, start: Int, size: Int) async throws -> PlaylistPage {
        guard let service = try? PlexBrowseService(appModel: appModel) else { throw NotConnected() }
        return try await service.playlistTracksPage(ratingKey: playlist.ratingKey,
                                                    start: start,
                                                    size: size)
    }

    func artistDetail(artist: MediaItem, libraryID: String?) async throws -> ArtistDetailContent {
        guard let service = try? PlexBrowseService(appModel: appModel) else { throw NotConnected() }
        return try await service.artistDetail(artist: artist, libraryID: libraryID)
    }
}

private extension MusicBrowseSort {
    var plexArtistSort: String {
        switch self {
        case .name:          return "titleSort"
        case .recentlyAdded: return "addedAt:desc"
        case .year:          return "titleSort"   // artists have no release year
        }
    }

    var plexAlbumSort: String {
        switch self {
        case .name:          return "titleSort"
        case .recentlyAdded: return "addedAt:desc"
        case .year:          return "originallyAvailableAt:desc"
        }
    }
}
