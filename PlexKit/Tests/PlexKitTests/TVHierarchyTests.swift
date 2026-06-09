import Testing
import Foundation
@testable import PlexKit

// MARK: - Episode hierarchy decoding

@Test func decodesEpisodeHierarchyFields() throws {
    // A representative `/library/metadata/{episode}` payload: episode decorated with its
    // season (`parent…`) and show (`grandparent…`) context, plus a real Media/Part.
    let json = """
    {"MediaContainer":{"size":1,"Metadata":[
      {"ratingKey":"310","key":"/library/metadata/310","title":"…And the Bag's in the River",
       "type":"episode","index":3,"parentIndex":1,
       "grandparentTitle":"Breaking Bad","grandparentRatingKey":"100","grandparentThumb":"/library/metadata/100/thumb/1",
       "parentTitle":"Season 1","parentRatingKey":"200","parentThumb":"/library/metadata/200/thumb/1",
       "duration":2820000,"viewOffset":60000,
       "Media":[{"id":5,"Part":[{"id":50,"key":"/library/parts/50/file.mkv","duration":2820000}]}]}]}}
    """.data(using: .utf8)!
    let c = try JSONDecoder().decode(MetadataResponse.self, from: json)
    let ep = c.mediaContainer.metadata[0]
    #expect(ep.type == "episode")
    #expect(ep.index == 3)
    #expect(ep.parentIndex == 1)
    #expect(ep.grandparentTitle == "Breaking Bad")
    #expect(ep.grandparentRatingKey == "100")
    #expect(ep.grandparentThumb == "/library/metadata/100/thumb/1")
    #expect(ep.parentTitle == "Season 1")
    #expect(ep.parentRatingKey == "200")
    #expect(ep.parentThumb == "/library/metadata/200/thumb/1")
    #expect(ep.kind == .episode)
    #expect(ep.isPlayableLeaf == true)
    #expect(ep.seasonEpisodeCode == "S1E3")
    #expect(ep.displaySubtitleLine == "Breaking Bad · S1E3 · …And the Bag's in the River")
}

@Test func movieHasNoHierarchyFields() throws {
    let json = """
    {"MediaContainer":{"Metadata":[
      {"ratingKey":"42","title":"Arrival","type":"movie","year":2016}]}}
    """.data(using: .utf8)!
    let c = try JSONDecoder().decode(MetadataResponse.self, from: json)
    let m = c.mediaContainer.metadata[0]
    #expect(m.grandparentTitle == nil)
    #expect(m.parentIndex == nil)
    #expect(m.index == nil)
    #expect(m.kind == .movie)
    #expect(m.isPlayableLeaf == true)
    #expect(m.isContainer == false)
    // A movie's subtitle line is just its title (no SxEy decoration).
    #expect(m.displaySubtitleLine == "Arrival")
}

@Test func showAndSeasonClassifyAsContainers() throws {
    let json = """
    {"MediaContainer":{"Metadata":[
      {"ratingKey":"100","title":"Breaking Bad","type":"show"},
      {"ratingKey":"200","title":"Season 1","type":"season","index":1,
       "parentTitle":"Breaking Bad","parentRatingKey":"100"}]}}
    """.data(using: .utf8)!
    let c = try JSONDecoder().decode(MetadataResponse.self, from: json)
    let show = c.mediaContainer.metadata[0]
    let season = c.mediaContainer.metadata[1]
    #expect(show.kind == .show)
    #expect(show.isContainer == true)
    #expect(show.isPlayableLeaf == false)
    #expect(season.kind == .season)
    #expect(season.isContainer == true)
    #expect(season.isPlayableLeaf == false)
    #expect(season.index == 1)
}

@Test func episodeSubtitleFallsBackGracefully() {
    // Missing show name → drop it; missing title → still produce the code.
    let noShow = MediaItem(ratingKey: "1", title: "Pilot", type: "episode",
                           parentIndex: 1, index: 1)
    #expect(noShow.displaySubtitleLine == "S1E1 · Pilot")

    let noCode = MediaItem(ratingKey: "2", title: "Pilot", type: "episode",
                           grandparentTitle: "Lost")
    #expect(noCode.displaySubtitleLine == "Lost · Pilot")

    let bare = MediaItem(ratingKey: "3", title: "Pilot", type: "episode")
    #expect(bare.displaySubtitleLine == "Pilot")
}

// MARK: - Children request builder

@Test func childrenRequestURLAndParams() throws {
    let server = URL(string: "https://example.plex.direct:32400")!
    let identity = ClientIdentity(clientIdentifier: "abc", product: "PlexAVP",
                                  version: "1.0", deviceName: "Headset")
    let req = ChildrenRequest.children(server: server, token: "TOKEN",
                                       identity: identity, ratingKey: "100")
    #expect(req.method == "GET")
    #expect(req.url.path == "/library/metadata/100/children")
    let names = Set(req.queryItems.map(\.name))
    #expect(names.contains("includeChapters"))
    #expect(names.contains("includeMarkers"))
    // Token never leaks into the URL path; it rides the standard headers.
    #expect(!req.url.absoluteString.contains("TOKEN"))
}

@Test func childrenResponseDecodesAsMetadata() throws {
    // `/children` of a show returns its seasons in a normal MediaContainer.
    let json = """
    {"MediaContainer":{"size":2,"Metadata":[
      {"ratingKey":"200","title":"Season 1","type":"season","index":1,
       "parentTitle":"Breaking Bad","parentRatingKey":"100"},
      {"ratingKey":"201","title":"Season 2","type":"season","index":2,
       "parentTitle":"Breaking Bad","parentRatingKey":"100"}]}}
    """.data(using: .utf8)!
    let c = try JSONDecoder().decode(MetadataResponse.self, from: json)
    #expect(c.mediaContainer.metadata.count == 2)
    #expect(c.mediaContainer.metadata[0].type == "season")
    #expect(c.mediaContainer.metadata[0].index == 1)
}

// MARK: - Episode-leaf resolver (HTTP 400 regression guard)

@Test func resolverReturnsMovieItself() async throws {
    let movie = MediaItem(ratingKey: "42", title: "Arrival", type: "movie")
    let leaf = try await EpisodeResolver.resolveLeaf(from: movie) { _ in
        Issue.record("should not fetch children for a movie")
        return []
    }
    #expect(leaf.ratingKey == "42")
    #expect(leaf.isPlayableLeaf)
}

@Test func resolverReturnsEpisodeItself() async throws {
    let ep = MediaItem(ratingKey: "310", title: "Pilot", type: "episode",
                       parentIndex: 1, index: 1)
    let leaf = try await EpisodeResolver.resolveLeaf(from: ep) { _ in
        Issue.record("should not fetch children for an episode")
        return []
    }
    #expect(leaf.ratingKey == "310")
}

@Test func resolverSeasonResolvesToFirstEpisode() async throws {
    let season = MediaItem(ratingKey: "200", title: "Season 1", type: "season", index: 1)
    let episodes = [
        MediaItem(ratingKey: "312", title: "Ep 3", type: "episode", parentIndex: 1, index: 3),
        MediaItem(ratingKey: "310", title: "Ep 1", type: "episode", parentIndex: 1, index: 1),
        MediaItem(ratingKey: "311", title: "Ep 2", type: "episode", parentIndex: 1, index: 2),
    ]
    let leaf = try await EpisodeResolver.resolveLeaf(from: season) { ratingKey in
        #expect(ratingKey == "200")
        return episodes
    }
    // Resolves to the LOWEST-numbered episode, never the season container itself.
    #expect(leaf.ratingKey == "310")
    #expect(leaf.type == "episode")
    #expect(leaf.isPlayableLeaf)
    #expect(leaf.type != "season")
}

@Test func resolverShowResolvesToFirstEpisodeOfFirstSeason() async throws {
    let show = MediaItem(ratingKey: "100", title: "Breaking Bad", type: "show")
    let seasons = [
        MediaItem(ratingKey: "200", title: "Season 1", type: "season", index: 1),
        MediaItem(ratingKey: "201", title: "Season 2", type: "season", index: 2),
    ]
    let season1Episodes = [
        MediaItem(ratingKey: "310", title: "Pilot", type: "episode", parentIndex: 1, index: 1),
        MediaItem(ratingKey: "311", title: "Cat's in the Bag…", type: "episode", parentIndex: 1, index: 2),
    ]
    let leaf = try await EpisodeResolver.resolveLeaf(from: show) { ratingKey in
        switch ratingKey {
        case "100": return seasons
        case "200": return season1Episodes
        case "201": return []
        default:
            Issue.record("unexpected ratingKey \(ratingKey)")
            return []
        }
    }
    #expect(leaf.ratingKey == "310")
    #expect(leaf.type == "episode")
    // CRITICAL: never hand a show/season ratingKey to the transcode/download path.
    #expect(leaf.ratingKey != "100")
    #expect(leaf.ratingKey != "200")
    #expect(leaf.type != "show")
    #expect(leaf.type != "season")
}

@Test func resolverSkipsEmptySeasonsToFindEpisode() async throws {
    let show = MediaItem(ratingKey: "100", title: "Show", type: "show")
    let seasons = [
        MediaItem(ratingKey: "200", title: "Specials", type: "season", index: 0),
        MediaItem(ratingKey: "201", title: "Season 1", type: "season", index: 1),
    ]
    let leaf = try await EpisodeResolver.resolveLeaf(from: show) { ratingKey in
        switch ratingKey {
        case "100": return seasons
        case "200": return [] // empty season
        case "201": return [MediaItem(ratingKey: "999", title: "Ep", type: "episode",
                                      parentIndex: 1, index: 1)]
        default: return []
        }
    }
    #expect(leaf.ratingKey == "999")
}

@Test func resolverThrowsWhenNoEpisodes() async {
    let show = MediaItem(ratingKey: "100", title: "Empty Show", type: "show")
    await #expect(throws: EpisodeResolver.ResolveError.noEpisodes) {
        try await EpisodeResolver.resolveLeaf(from: show) { _ in [] }
    }
}

@Test func leafIfAvailableOnlyForLeaves() {
    #expect(EpisodeResolver.leafIfAvailable(
        MediaItem(ratingKey: "1", title: "M", type: "movie"))?.ratingKey == "1")
    #expect(EpisodeResolver.leafIfAvailable(
        MediaItem(ratingKey: "2", title: "S", type: "show")) == nil)
    #expect(EpisodeResolver.leafIfAvailable(
        MediaItem(ratingKey: "3", title: "Se", type: "season")) == nil)
}
