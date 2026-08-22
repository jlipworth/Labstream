#if DEBUG
import Foundation
import os
import PMSKit

@MainActor
protocol PlexBrowseProbeServing {
    func libraries() async throws -> [PlexSection]
    func sectionPage(sectionKey: String, startIndex: Int?, limit: Int?, sort: String?, firstCharacter: String?, browseQuery: LibraryBrowseQuery) async throws -> PlexBrowsePage
    func alphabetCounts(sectionKey: String, type: Int?) async throws -> [(display: String, count: Int)]
    func hubs() async throws -> [Hub]
    func searchWithLibraries(query: String) async throws -> PlexSearchSnapshot
    func onDeck() async throws -> [MediaItem]
    func metadata(ratingKey: String) async throws -> MediaItem
    func children(ratingKey: String) async throws -> [MediaItem]
    func musicArtists(libraryID: String, sort: String, start: Int, size: Int) async throws -> MusicPage
    func musicAlbums(libraryID: String, sort: String, start: Int, size: Int) async throws -> MusicPage
    func musicSectionHubs(sectionKey: String) async throws -> [Hub]
    func playHistory(librarySectionID: String, count: Int) async throws -> [MediaItem]
    func recentlyAddedAlbums(sectionKey: String) async throws -> [MediaItem]
    func randomTracks(sectionKey: String) async throws -> [MediaItem]
    func discographyTracks(artistRatingKey: String) async throws -> [MediaItem]
    func musicPlaylists() async throws -> [MediaItem]
    func playlistTracks(ratingKey: String) async throws -> [MediaItem]
    func artistDetail(artist: MediaItem, libraryID: String?) async throws -> ArtistDetailContent
}

extension PlexBrowseService: PlexBrowseProbeServing {}

/// Opt-in, read-only acceptance probe for the signed-in app's `PlexBrowseService` boundary.
/// Logs contain fixed stage names, counts, and booleans only — never server content or secrets.
@MainActor
enum DebugPlexBrowseProbe {
    static let flag = "--vp-probe-plex-browse"
    private static let log = Logger(subsystem: "org.labstream.Labstream", category: "PlexBrowseProbe")

    enum Stage: String { case readiness, libraries, page, alphabet, hubs, search, onDeck = "on_deck", metadata, children, music, session, assertions }
    @MainActor final class Progress { var stage: Stage = .readiness }

    struct Evidence: Equatable {
        var libraryCount = 0
        var pageCount = 0
        var pageTotal: Int?
        var repeatedPageOrderMatches = false
        var pageIDsPresent = false
        var alphabetApplicable = false
        var alphabetCount = 0
        var hubsDecoded = false
        var hubCount = 0
        var hubItemCount = 0
        var searchDecoded = false
        var searchHubCount = 0
        var searchItemCount = 0
        var searchLibraryCount = 0
        var searchLibrariesPresent = false
        var onDeckDecoded = false
        var onDeckCount = 0
        var onDeckIDsPresent = true
        var metadataIDMatches = false
        var childrenApplicable = false
        var childCount = 0
        var childIDsPresent = true
        var musicApplicable = false
        var musicArtistsAttempted = false
        var musicArtistCount = 0
        var musicAlbumsAttempted = false
        var musicAlbumCount = 0
        var musicHubsAttempted = false
        var musicHubCount = 0
        var musicRecentAttempted = false
        var musicRecentCount = 0
        var musicHistoryAttempted = false
        var musicHistoryCount = 0
        var musicRandomAttempted = false
        var musicRandomCount = 0
        var musicAlbumChildrenApplicable = false
        var musicAlbumChildrenAttempted = false
        var musicAlbumChildCount = 0
        var discographyApplicable = false
        var discographyAttempted = false
        var discographyCount = 0
        var playlistsAttempted = false
        var playlistCount = 0
        var playlistTracksApplicable = false
        var playlistTracksAttempted = false
        var playlistTrackCount = 0
        var artistDetailApplicable = false
        var artistDetailAttempted = false
        var artistDetailEmpty = true
        var sessionUnchanged = false

        var countCoherent: Bool { pageTotal.map { $0 >= pageCount } ?? true }
        var musicCoverageComplete: Bool {
            !musicApplicable || (musicArtistsAttempted && musicAlbumsAttempted && musicHubsAttempted
                && musicRecentAttempted && musicHistoryAttempted && musicRandomAttempted
                && playlistsAttempted
                && (!musicAlbumChildrenApplicable || musicAlbumChildrenAttempted)
                && (!discographyApplicable || discographyAttempted)
                && (!playlistTracksApplicable || playlistTracksAttempted)
                && (!artistDetailApplicable || artistDetailAttempted))
        }
        var passes: Bool {
            libraryCount > 0 && pageCount > 0 && repeatedPageOrderMatches && pageIDsPresent
                && countCoherent && (!alphabetApplicable || alphabetCount > 0)
                && hubsDecoded && searchDecoded && searchLibrariesPresent
                && onDeckDecoded && onDeckIDsPresent && metadataIDMatches && childIDsPresent
                && musicCoverageComplete && sessionUnchanged
        }
    }

    @MainActor struct Runner {
        let service: any PlexBrowseProbeServing
        let capturedAuthorityKey: String
        let currentAuthorityKey: @MainActor () -> String

        func collect(progress: Progress = Progress()) async throws -> Evidence {
            var e = Evidence()
            progress.stage = .libraries
            let libraries = try await service.libraries()
            e.libraryCount = libraries.count
            guard let library = libraries.first(where: { $0.type == "show" })
                    ?? libraries.first(where: { !$0.isMusic }) ?? libraries.first else { throw ProbeFailure.assertion }

            progress.stage = .page
            let page = try await service.sectionPage(sectionKey: library.key, startIndex: 0, limit: 10, sort: "titleSort", firstCharacter: nil, browseQuery: .default)
            let repeated = try await service.sectionPage(sectionKey: library.key, startIndex: 0, limit: 10, sort: "titleSort", firstCharacter: nil, browseQuery: .default)
            e.pageCount = page.items.count
            e.pageTotal = page.total
            let ids = page.items.map(\.ratingKey)
            e.pageIDsPresent = !ids.isEmpty && ids.allSatisfy { !$0.isEmpty }
            e.repeatedPageOrderMatches = ids == repeated.items.map(\.ratingKey)
            guard let seed = page.items.first else { throw ProbeFailure.assertion }

            e.alphabetApplicable = library.type == "movie" || library.type == "show"
            if e.alphabetApplicable {
                progress.stage = .alphabet
                e.alphabetCount = try await service.alphabetCounts(sectionKey: library.key, type: nil).count
            }

            progress.stage = .hubs
            let hubs = try await service.hubs()
            e.hubsDecoded = true
            e.hubCount = hubs.count
            let hubItems = hubs.flatMap(\.metadata)
            e.hubItemCount = hubItems.count

            progress.stage = .search
            let query = String(seed.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            guard !query.isEmpty else { throw ProbeFailure.assertion }
            let search = try await service.searchWithLibraries(query: query)
            e.searchDecoded = true
            e.searchHubCount = search.hubs.count
            e.searchItemCount = search.hubs.reduce(0) { $0 + $1.metadata.count }
            e.searchLibraryCount = search.libraries.count
            e.searchLibrariesPresent = !search.libraries.isEmpty

            progress.stage = .onDeck
            let onDeck = try await service.onDeck()
            e.onDeckDecoded = true
            e.onDeckCount = onDeck.count
            e.onDeckIDsPresent = onDeck.allSatisfy { !$0.ratingKey.isEmpty }

            progress.stage = .metadata
            e.metadataIDMatches = try await service.metadata(ratingKey: seed.ratingKey).ratingKey == seed.ratingKey
            if let container = ([seed] + hubItems + onDeck).first(where: \.isContainer) {
                progress.stage = .children
                e.childrenApplicable = true
                let children = try await service.children(ratingKey: container.ratingKey)
                e.childCount = children.count
                e.childIDsPresent = children.allSatisfy { !$0.ratingKey.isEmpty }
            }

            if let music = libraries.first(where: \.isMusic) {
                progress.stage = .music
                e.musicApplicable = true
                let artists = try await service.musicArtists(libraryID: music.key, sort: "titleSort", start: 0, size: 10)
                e.musicArtistsAttempted = true; e.musicArtistCount = artists.items.count
                let albums = try await service.musicAlbums(libraryID: music.key, sort: "titleSort", start: 0, size: 10)
                e.musicAlbumsAttempted = true; e.musicAlbumCount = albums.items.count
                let musicHubs = try await service.musicSectionHubs(sectionKey: music.key)
                e.musicHubsAttempted = true; e.musicHubCount = musicHubs.count
                let recent = try await service.recentlyAddedAlbums(sectionKey: music.key)
                e.musicRecentAttempted = true; e.musicRecentCount = recent.count
                let history = try await service.playHistory(librarySectionID: music.key, count: 10)
                e.musicHistoryAttempted = true; e.musicHistoryCount = history.count
                let random = try await service.randomTracks(sectionKey: music.key)
                e.musicRandomAttempted = true; e.musicRandomCount = random.count

                if let album = (albums.items + recent + musicHubs.flatMap(\.metadata)).first(where: { $0.kind == .album }) {
                    e.musicAlbumChildrenApplicable = true
                    let children = try await service.children(ratingKey: album.ratingKey)
                    e.musicAlbumChildrenAttempted = true; e.musicAlbumChildCount = children.count
                }
                if let artist = (artists.items + musicHubs.flatMap(\.metadata)).first(where: { $0.kind == .artist }) {
                    e.discographyApplicable = true
                    e.artistDetailApplicable = true
                    let tracks = try await service.discographyTracks(artistRatingKey: artist.ratingKey)
                    e.discographyAttempted = true; e.discographyCount = tracks.count
                    let detail = try await service.artistDetail(artist: artist, libraryID: music.key)
                    e.artistDetailAttempted = true; e.artistDetailEmpty = detail.isEmpty
                }
                let playlists = try await service.musicPlaylists()
                e.playlistsAttempted = true; e.playlistCount = playlists.count
                if let playlist = playlists.first {
                    e.playlistTracksApplicable = true
                    let tracks = try await service.playlistTracks(ratingKey: playlist.ratingKey)
                    e.playlistTracksAttempted = true; e.playlistTrackCount = tracks.count
                }
            }

            progress.stage = .session
            let current = currentAuthorityKey()
            e.sessionUnchanged = capturedAuthorityKey == current
            progress.stage = .assertions
            guard e.passes else { throw ProbeFailure.assertion }
            return e
        }
    }

    static func shouldRun(arguments: [String]) -> Bool { arguments.contains(flag) }
    @MainActor static func collectIfRequested(arguments: [String], runner: Runner, progress: Progress = Progress()) async throws -> Evidence? {
        guard shouldRun(arguments: arguments) else { return nil }
        return try await runner.collect(progress: progress)
    }

    @MainActor static func runIfRequested(appModel: AppModel, arguments: [String] = ProcessInfo.processInfo.arguments) async {
        guard shouldRun(arguments: arguments) else { return }
        log.notice("probe.start backend=plex read_only=true")
        guard appModel.activeBackend == .plex, appModel.isBrowseReady else {
            log.error("probe.fail stage=readiness status=not_ready")
            return
        }
        let progress = Progress()
        do {
            let service = try PlexBrowseService(appModel: appModel)
            let runner = Runner(service: service, capturedAuthorityKey: appModel.activeBrowseSessionKey,
                                currentAuthorityKey: { appModel.activeBrowseSessionKey })
            guard let evidence = try await collectIfRequested(arguments: arguments, runner: runner, progress: progress) else { return }
            logEvidence(evidence, passed: true)
        } catch ProbeFailure.assertion {
            log.error("probe.fail stage=\(progress.stage.rawValue, privacy: .public) status=assertion_failed")
        } catch {
            log.error("probe.fail stage=\(progress.stage.rawValue, privacy: .public) status=request_or_decode_failed")
        }
    }

    private static func logEvidence(_ e: Evidence, passed: Bool) {
        let prefix = passed ? "probe.pass" : "probe.fail"
        log.notice("\(prefix, privacy: .public) libraries=\(e.libraryCount, privacy: .public) page=\(e.pageCount, privacy: .public) count_ok=\(e.countCoherent, privacy: .public) order_ok=\(e.repeatedPageOrderMatches, privacy: .public) page_ids=\(e.pageIDsPresent, privacy: .public) alphabet_applicable=\(e.alphabetApplicable, privacy: .public) alphabet=\(e.alphabetCount, privacy: .public) hubs_decoded=\(e.hubsDecoded, privacy: .public) hubs=\(e.hubCount, privacy: .public) hub_items=\(e.hubItemCount, privacy: .public) search_decoded=\(e.searchDecoded, privacy: .public) search_hubs=\(e.searchHubCount, privacy: .public) search_items=\(e.searchItemCount, privacy: .public) search_libraries=\(e.searchLibraryCount, privacy: .public) search_libraries_present=\(e.searchLibrariesPresent, privacy: .public) on_deck_decoded=\(e.onDeckDecoded, privacy: .public) on_deck=\(e.onDeckCount, privacy: .public) metadata_id=\(e.metadataIDMatches, privacy: .public) children_applicable=\(e.childrenApplicable, privacy: .public) children=\(e.childCount, privacy: .public) music_applicable=\(e.musicApplicable, privacy: .public) music_artists_attempted=\(e.musicArtistsAttempted, privacy: .public) music_artists=\(e.musicArtistCount, privacy: .public) music_albums_attempted=\(e.musicAlbumsAttempted, privacy: .public) music_albums=\(e.musicAlbumCount, privacy: .public) music_hubs_attempted=\(e.musicHubsAttempted, privacy: .public) music_hubs=\(e.musicHubCount, privacy: .public) music_recent_attempted=\(e.musicRecentAttempted, privacy: .public) music_recent=\(e.musicRecentCount, privacy: .public) music_history_attempted=\(e.musicHistoryAttempted, privacy: .public) music_history=\(e.musicHistoryCount, privacy: .public) music_random_attempted=\(e.musicRandomAttempted, privacy: .public) music_random=\(e.musicRandomCount, privacy: .public) album_children_applicable=\(e.musicAlbumChildrenApplicable, privacy: .public) album_children_attempted=\(e.musicAlbumChildrenAttempted, privacy: .public) album_children=\(e.musicAlbumChildCount, privacy: .public) discography_applicable=\(e.discographyApplicable, privacy: .public) discography_attempted=\(e.discographyAttempted, privacy: .public) discography=\(e.discographyCount, privacy: .public) playlists_attempted=\(e.playlistsAttempted, privacy: .public) playlists=\(e.playlistCount, privacy: .public) playlist_tracks_applicable=\(e.playlistTracksApplicable, privacy: .public) playlist_tracks_attempted=\(e.playlistTracksAttempted, privacy: .public) playlist_tracks=\(e.playlistTrackCount, privacy: .public) artist_detail_applicable=\(e.artistDetailApplicable, privacy: .public) artist_detail_attempted=\(e.artistDetailAttempted, privacy: .public) artist_detail_empty=\(e.artistDetailEmpty, privacy: .public) session_ok=\(e.sessionUnchanged, privacy: .public)")
    }

    enum ProbeFailure: Error { case assertion }
}
#endif
