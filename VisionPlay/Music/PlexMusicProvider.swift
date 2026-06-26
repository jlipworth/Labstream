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

    private func session() throws -> (server: URL, token: String, identity: ClientIdentity) {
        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
            throw NotConnected()
        }
        return (server, token, appModel.identity)
    }

    func musicLibraries() async throws -> [MusicLibrary] {
        let s = try session()
        let req = BrowseAPI.sections(server: s.server, token: s.token, identity: s.identity)
        let resp = try await appModel.client.send(req, as: SectionsResponse.self)
        return resp.mediaContainer.directory.filter(\.isMusic)
            .map { MusicLibrary(id: $0.key, title: $0.title) }
    }

    func artists(libraryID: String, sort: MusicBrowseSort, start: Int, size: Int) async throws -> MusicPage {
        let s = try session()
        let req = MusicRequest.artists(server: s.server, token: s.token, identity: s.identity,
                                       sectionKey: libraryID, sort: sort.plexArtistSort,
                                       containerStart: start, containerSize: size)
        return try await page(req)
    }

    func albums(libraryID: String, sort: MusicBrowseSort, start: Int, size: Int) async throws -> MusicPage {
        let s = try session()
        let req = MusicRequest.albums(server: s.server, token: s.token, identity: s.identity,
                                      sectionKey: libraryID, sort: sort.plexAlbumSort,
                                      containerStart: start, containerSize: size)
        return try await page(req)
    }

    func albumTracks(album: MediaItem) async throws -> [MediaItem] {
        let s = try session()
        let req = BrowseAPI.children(server: s.server, token: s.token,
                                     identity: s.identity, ratingKey: album.ratingKey)
        let resp = try await appModel.client.send(req, as: MetadataResponse.self)
        return resp.mediaContainer.metadata.sorted {
            ($0.parentIndex ?? 1, $0.index ?? 0) < ($1.parentIndex ?? 1, $1.index ?? 0)
        }
    }

    func discographyTracks(artist: MediaItem) async throws -> [MediaItem] {
        let s = try session()
        let req = MusicRequest.allLeaves(server: s.server, token: s.token,
                                         identity: s.identity, ratingKey: artist.ratingKey)
        let resp = try await appModel.client.send(req, as: MetadataResponse.self)
        return resp.mediaContainer.metadata.filter { $0.kind == .track }
    }

    func musicPlaylists() async throws -> [MediaItem] {
        let s = try session()
        let req = PlaylistRequest.audioPlaylists(server: s.server, token: s.token,
                                                 identity: s.identity)
        let resp = try await appModel.client.send(req, as: MetadataResponse.self)
        return resp.mediaContainer.metadata.filter { $0.kind == .playlist }
    }

    func playlistTracks(playlist: MediaItem) async throws -> [MediaItem] {
        let s = try session()
        let req = PlaylistRequest.items(server: s.server, token: s.token,
                                        identity: s.identity,
                                        ratingKey: playlist.ratingKey)
        let resp = try await appModel.client.send(req, as: MetadataResponse.self)
        // Playlist order is the user's order — keep the server sequence verbatim.
        return resp.mediaContainer.metadata.filter { $0.kind == .track }
    }

    func artistDetail(artist: MediaItem, libraryID: String?) async throws -> ArtistDetailContent {
        let s = try session()
        // No section key (cross-section search result): the legacy children walk, one
        // flat Albums shelf — matches the old ArtistDetailView fallback.
        guard let libraryID else {
            let req = BrowseAPI.children(server: s.server, token: s.token,
                                         identity: s.identity, ratingKey: artist.ratingKey)
            let resp = try await appModel.client.send(req, as: MetadataResponse.self)
            return ArtistDetailContent(albums: resp.mediaContainer.metadata.filter { $0.kind == .album })
        }

        // Discography is primary (drives the failure state); the rest are best-effort.
        async let relatedResp = try? appModel.client.send(
            MusicRequest.relatedHubs(server: s.server, token: s.token, identity: s.identity,
                                     ratingKey: artist.ratingKey),
            as: HubsResponse.self)
        async let appearsResp = try? appModel.client.send(
            MusicRequest.appearsOnAlbums(server: s.server, token: s.token, identity: s.identity,
                                         sectionKey: libraryID, artistTitle: artist.title),
            as: MetadataResponse.self)
        async let popularResp = try? appModel.client.send(
            MusicRequest.popularTracks(server: s.server, token: s.token, identity: s.identity,
                                       sectionKey: libraryID, artistRatingKey: artist.ratingKey),
            as: MetadataResponse.self)

        let ownResp = try await appModel.client.send(
            MusicRequest.artistAlbums(server: s.server, token: s.token, identity: s.identity,
                                      sectionKey: libraryID, artistRatingKey: artist.ratingKey),
            as: MetadataResponse.self)
        let own = ownResp.mediaContainer.metadata

        let hubs = (await relatedResp)?.mediaContainer.hub ?? []
        let categorized: [ArtistShelf] = hubs.compactMap { hub in
            guard (hub.hubIdentifier ?? "").hasPrefix("artist.albums.") else { return nil }
            let items = hub.metadata.filter { $0.kind == .album }
            guard !items.isEmpty else { return nil }
            return ArtistShelf(id: hub.hubIdentifier ?? hub.title, title: hub.title, items: items)
        }
        let similar = hubs.first { ($0.hubIdentifier ?? "").hasPrefix("artist.similar") }?
            .metadata.filter { $0.kind == .artist } ?? []

        let categorizedKeys = Set(categorized.flatMap(\.items).map(\.ratingKey))
        let albums = own.filter { !categorizedKeys.contains($0.ratingKey) }
        let ownKeys = Set(own.map(\.ratingKey))
        let appearsOn = ((await appearsResp)?.mediaContainer.metadata ?? [])
            .filter { $0.kind == .album && !ownKeys.contains($0.ratingKey) }
        let popular = (await popularResp)?.mediaContainer.metadata.filter { $0.kind == .track } ?? []

        return ArtistDetailContent(albums: albums, popular: popular,
                                   categorized: categorized, appearsOn: appearsOn, similar: similar)
    }

    private func page(_ req: PlexRequest) async throws -> MusicPage {
        let resp = try await appModel.client.send(req, as: MetadataResponse.self)
        let items = resp.mediaContainer.metadata
        let total = max(resp.mediaContainer.totalSize ?? items.count, items.count)
        return MusicPage(items: items, total: total)
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
