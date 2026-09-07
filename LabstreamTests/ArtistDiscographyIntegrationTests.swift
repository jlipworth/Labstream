import Foundation
import PMSKit
import Testing
@testable import Labstream

@MainActor
struct ArtistDiscographyIntegrationTests {
    enum Interruption: CaseIterable {
        case backend, server, signOut, newerAlbum, newerArtist, stop, cancel, none
    }

    @Test(arguments: Interruption.allCases, [false, true])
    func heldProviderCannotPublishObsoleteTracks(interruption: Interruption,
                                                shuffled: Bool) async throws {
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "artist-integration"))
        model.activeBackend = .plex
        model.token = "fixture-token"
        model.serverBaseURL = URL(string: "https://music.example.invalid")
        var resolved: [String] = []
        let player = MusicPlayerController(appModel: model, artworkPipeline: ArtworkPipeline(),
                                          resolveStream: { track, _ in
            resolved.append(track.ratingKey)
            // Observe real controller resolution without starting AVFoundation/network work.
            throw MusicStreamResolver.ResolveError.notConnected
        })
        defer { player.stop() }
        let provider = HeldDiscographyProvider()
        let artist = MediaItem(ratingKey: "artist-a", title: "Artist fixture", type: "artist")
        let request = Task { await player.playDiscography(
            artist: artist, shuffled: shuffled, provider: provider) }
        defer {
            request.cancel()
            provider.pending?.resume(throwing: CancellationError())
            provider.pending = nil
        }
        for _ in 0..<10_000 {
            if provider.pending != nil { break }
            await Task.yield()
        }
        let pending = try #require(provider.pending)
        #expect(provider.requestedArtists == ["artist-a"])
        switch interruption {
        case .backend: model.activeBackend = .jellyfin
        case .server: model.serverBaseURL = URL(string: "https://other.example.invalid")
        case .signOut: model.clearBrowseSession(for: .plex)
        case .newerAlbum:
            player.play(tracks: [MediaItem(ratingKey: "album-b", title: "New fixture", type: "track")],
                        startingAt: 0)
        case .newerArtist: _ = player.beginQueueIntent()
        case .stop: player.stop()
        case .cancel: request.cancel()
        case .none: break
        }
        pending.resume(returning: [
            MediaItem(ratingKey: "a-1", title: "Track one", type: "track"),
            MediaItem(ratingKey: "a-2", title: "Track two", type: "track")
        ])
        provider.pending = nil
        #expect(await request.value == nil)
        if interruption == .none {
            #expect(player.queue.map(\.ratingKey) == ["a-1", "a-2"])
            #expect(resolved.count == 1)
            #expect(resolved.first.map { ["a-1", "a-2"].contains($0) } == true)
            #expect(player.shuffleEnabled == shuffled)
        } else if interruption == .newerAlbum {
            #expect(player.queue.map(\.ratingKey) == ["album-b"])
            #expect(resolved == ["album-b"])
        } else {
            #expect(player.queue.isEmpty)
            #expect(resolved.isEmpty)
        }
    }
}

/// Only the suspended method is permitted; accidental extra provider work fails the test.
@MainActor
private final class HeldDiscographyProvider: MusicProvider {
    var pending: CheckedContinuation<[MediaItem], Error>?
    var requestedArtists: [String] = []
    func discographyTracks(artist: MediaItem) async throws -> [MediaItem] {
        requestedArtists.append(artist.ratingKey)
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    private func unexpected<T>() throws -> T {
        Issue.record("Unexpected music provider request")
        throw CancellationError()
    }
    func musicLibraries(catalogRepository: LibraryCatalogRepository, forceRefresh: Bool) async throws -> [MusicLibrary] { try unexpected() }
    func artists(libraryID: String, sort: MusicBrowseSort, start: Int, size: Int) async throws -> MusicPage { try unexpected() }
    func albums(libraryID: String, sort: MusicBrowseSort, start: Int, size: Int) async throws -> MusicPage { try unexpected() }
    func albumTracks(album: MediaItem) async throws -> [MediaItem] { try unexpected() }
    func artistDetail(artist: MediaItem, libraryID: String?) async throws -> ArtistDetailContent { try unexpected() }
    func musicPlaylists(catalogRepository: LibraryCatalogRepository, forceRefresh: Bool) async throws -> [MediaItem] { try unexpected() }
    func playlistTracksPage(playlist: MediaItem, start: Int, size: Int) async throws -> PlaylistPage { try unexpected() }
}
