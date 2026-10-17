import Testing
import Foundation
@testable import PMSKit

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
    let identity = ClientIdentity(clientIdentifier: "abc", product: "Labstream",
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
