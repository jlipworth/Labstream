#if DEBUG
import Foundation
import Testing
@testable import Labstream
@testable import PMSKit

@Suite("Debug Plex browse probe")
@MainActor
struct DebugPlexBrowseProbeTests {
    @Test func missingFlagIsInertAtInjectedRunnerSeam() async throws {
        let service = PlexBrowseProbeServiceDouble()
        let runner = DebugPlexBrowseProbe.Runner(service: service, capturedAuthorityKey: "A", currentAuthorityKey: { "A" })
        let result = try await DebugPlexBrowseProbe.collectIfRequested(arguments: [], runner: runner)
        #expect(result == nil)
        #expect(service.calls.isEmpty)
    }

    @Test func runnerUsesSearchWithLibrariesAndPinsAuthorityWhileEmptyNativeResultsRemainValid() async throws {
        let service = PlexBrowseProbeServiceDouble()
        let runner = DebugPlexBrowseProbe.Runner(service: service, capturedAuthorityKey: "session-A", currentAuthorityKey: { "session-A" })
        let evidence = try #require(try await DebugPlexBrowseProbe.collectIfRequested(
            arguments: [DebugPlexBrowseProbe.flag], runner: runner))

        #expect(evidence.passes)
        #expect(evidence.hubsDecoded && evidence.hubCount == 0)
        #expect(evidence.searchDecoded && evidence.searchHubCount == 0)
        #expect(evidence.searchLibrariesPresent)
        #expect(evidence.sessionUnchanged)
        #expect(service.calls.filter { $0 == "searchWithLibraries" }.count == 1)
        #expect(!service.lastSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func passRequiresBestEffortSearchLibrariesHalfWhenBaseLibrariesExist() async {
        let service = PlexBrowseProbeServiceDouble()
        service.includeSearchLibraries = false
        let runner = DebugPlexBrowseProbe.Runner(service: service, capturedAuthorityKey: "A", currentAuthorityKey: { "A" })
        await #expect(throws: DebugPlexBrowseProbe.ProbeFailure.self) {
            _ = try await runner.collect()
        }
    }

    @Test func runnerRejectsAuthorityChangeAfterSessionPinnedRequests() async {
        let service = PlexBrowseProbeServiceDouble()
        let runner = DebugPlexBrowseProbe.Runner(service: service,
                                                 capturedAuthorityKey: "session-A",
                                                 currentAuthorityKey: { "session-B" })
        await #expect(throws: DebugPlexBrowseProbe.ProbeFailure.self) {
            _ = try await runner.collect()
        }
        #expect(service.calls.contains("searchWithLibraries"))
    }

    @Test func musicLibraryConditionallyAttemptsMigratedServiceCapabilities() async throws {
        let service = PlexBrowseProbeServiceDouble(includeMusic: true)
        let runner = DebugPlexBrowseProbe.Runner(service: service, capturedAuthorityKey: "A", currentAuthorityKey: { "A" })
        let evidence = try await runner.collect()

        #expect(evidence.musicApplicable && evidence.musicCoverageComplete)
        #expect(evidence.musicArtistsAttempted && evidence.musicAlbumsAttempted)
        #expect(evidence.musicHubsAttempted && evidence.musicRecentAttempted)
        #expect(evidence.musicHistoryAttempted && evidence.musicRandomAttempted)
        #expect(evidence.musicAlbumChildrenAttempted && evidence.discographyAttempted)
        #expect(evidence.playlistsAttempted && evidence.playlistTracksAttempted)
        #expect(evidence.artistDetailAttempted)
        for call in ["musicArtists", "musicAlbums", "musicSectionHubs", "recentlyAddedAlbums",
                     "playHistory", "randomTracks", "discographyTracks", "musicPlaylists",
                     "playlistTracks", "artistDetail"] {
            #expect(service.calls.contains(call))
        }
    }
}

@MainActor
private final class PlexBrowseProbeServiceDouble: PlexBrowseProbeServing {
    var calls: [String] = []
    var includeSearchLibraries = true
    var lastSearchQuery = ""
    private let includeMusic: Bool
    private let show = PlexBrowseProbeServiceDouble.item(id: "show", title: "Safe Seed", type: "show")
    private let artist = PlexBrowseProbeServiceDouble.item(id: "artist", title: "Artist", type: "artist")
    private let album = PlexBrowseProbeServiceDouble.item(id: "album", title: "Album", type: "album")
    private let playlist = PlexBrowseProbeServiceDouble.item(id: "playlist", title: "Playlist", type: "playlist")

    init(includeMusic: Bool = false) { self.includeMusic = includeMusic }

    func libraries() async throws -> [PlexSection] {
        calls.append("libraries")
        var result = [PlexSection(key: "video", title: "Video", type: "show")]
        if includeMusic { result.append(PlexSection(key: "music", title: "Music", type: "artist")) }
        return result
    }
    func sectionPage(sectionKey: String, startIndex: Int?, limit: Int?, sort: String?, firstCharacter: String?) async throws -> PlexBrowsePage {
        calls.append("sectionPage"); return PlexBrowsePage(items: [show], total: 1)
    }
    func alphabetCounts(sectionKey: String, type: Int?) async throws -> [(display: String, count: Int)] {
        calls.append("alphabetCounts"); return [("S", 1)]
    }
    func hubs() async throws -> [Hub] { calls.append("hubs"); return [] }
    func searchWithLibraries(query: String) async throws -> PlexSearchSnapshot {
        calls.append("searchWithLibraries"); lastSearchQuery = query
        return PlexSearchSnapshot(hubs: [], libraries: includeSearchLibraries ? [PlexSection(key: "video", title: "Video", type: "show")] : [])
    }
    func onDeck() async throws -> [MediaItem] { calls.append("onDeck"); return [] }
    func metadata(ratingKey: String) async throws -> MediaItem { calls.append("metadata"); return show }
    func children(ratingKey: String) async throws -> [MediaItem] { calls.append("children"); return [] }
    func musicArtists(libraryID: String, sort: String, start: Int, size: Int) async throws -> MusicPage {
        calls.append("musicArtists"); return MusicPage(items: [artist], total: 1)
    }
    func musicAlbums(libraryID: String, sort: String, start: Int, size: Int) async throws -> MusicPage {
        calls.append("musicAlbums"); return MusicPage(items: [album], total: 1)
    }
    func musicSectionHubs(sectionKey: String) async throws -> [Hub] { calls.append("musicSectionHubs"); return [] }
    func playHistory(librarySectionID: String, count: Int) async throws -> [MediaItem] { calls.append("playHistory"); return [] }
    func recentlyAddedAlbums(sectionKey: String) async throws -> [MediaItem] { calls.append("recentlyAddedAlbums"); return [] }
    func randomTracks(sectionKey: String) async throws -> [MediaItem] { calls.append("randomTracks"); return [] }
    func discographyTracks(artistRatingKey: String) async throws -> [MediaItem] { calls.append("discographyTracks"); return [] }
    func musicPlaylists() async throws -> [MediaItem] { calls.append("musicPlaylists"); return includeMusic ? [playlist] : [] }
    func playlistTracks(ratingKey: String) async throws -> [MediaItem] { calls.append("playlistTracks"); return [] }
    func artistDetail(artist: MediaItem, libraryID: String?) async throws -> ArtistDetailContent {
        calls.append("artistDetail"); return ArtistDetailContent()
    }

    nonisolated private static func item(id: String, title: String, type: String) -> MediaItem {
        try! JSONDecoder().decode(MediaItem.self, from: Data(#"{"ratingKey":"\#(id)","title":"\#(title)","type":"\#(type)"}"#.utf8))
    }
}
#endif
