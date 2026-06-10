import Testing
import Foundation
@testable import PlexKit

private let server = URL(string: "https://192.0.2.10:32400")!
private let id = ClientIdentity(clientIdentifier: "CID",
                                product: "VisionPlex",
                                version: "0.1.0",
                                deviceName: "AVP")

// MARK: - Section listings

@Test func artistsRequestTargetsSectionAllWithArtistType() {
    let r = MusicRequest.artists(server: server, token: "tok", identity: id, sectionKey: "3")
    #expect(r.url.path == "/library/sections/3/all")
    #expect(r.method == "GET")
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("type") == "8")
    #expect(r.headers["X-Plex-Token"] == "tok")
    #expect(r.headers["X-Plex-Client-Identifier"] == "CID")
}

@Test func albumsRequestUsesAlbumType() {
    let r = MusicRequest.albums(server: server, token: "tok", identity: id, sectionKey: "3")
    #expect(r.url.path == "/library/sections/3/all")
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("type") == "9")
}

@Test func recentlyAddedAlbumsSortsByAddedAtDescending() {
    let r = MusicRequest.recentlyAddedAlbums(server: server, token: "tok",
                                             identity: id, sectionKey: "3")
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("type") == "9")
    #expect(v("sort") == "addedAt:desc")
    // Paged: without an explicit container size PMS returns the whole album list.
    #expect(v("X-Plex-Container-Start") == "0")
    #expect(v("X-Plex-Container-Size") == "20")
}

@Test func artistsDefaultsCarryNoSortOrPaging() {
    let r = MusicRequest.artists(server: server, token: "tok", identity: id, sectionKey: "3")
    let names = r.queryItems.map(\.name)
    #expect(!names.contains("sort"))
    #expect(!names.contains("X-Plex-Container-Start"))
    #expect(!names.contains("X-Plex-Container-Size"))
}

@Test func artistsAcceptSortAndPaging() {
    let r = MusicRequest.artists(server: server, token: "tok", identity: id, sectionKey: "3",
                                 sort: "titleSort", containerStart: 100, containerSize: 50)
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("type") == "8")
    #expect(v("sort") == "titleSort")
    #expect(v("X-Plex-Container-Start") == "100")
    #expect(v("X-Plex-Container-Size") == "50")
}

@Test func albumsAcceptSortAndPaging() {
    let r = MusicRequest.albums(server: server, token: "tok", identity: id, sectionKey: "3",
                                sort: "titleSort", containerStart: 0, containerSize: 60)
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("type") == "9")
    #expect(v("sort") == "titleSort")
    #expect(v("X-Plex-Container-Size") == "60")
}

// MARK: - Section hubs + play history (MUSIC-DESIGN §6)

@Test func sectionHubsTargetsHubsSectionsPath() {
    let r = MusicRequest.sectionHubs(server: server, token: "tok", identity: id, sectionKey: "3")
    #expect(r.url.path == "/hubs/sections/3")
    #expect(r.method == "GET")
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("count") == "20")
    #expect(v("excludeFields") == "summary")
    #expect(r.headers["X-Plex-Token"] == "tok")
}

@Test func playHistorySortsNewestFirstAndScopesToSection() {
    let r = MusicRequest.playHistory(server: server, token: "tok", identity: id,
                                     librarySectionID: "3")
    #expect(r.url.path == "/status/sessions/history/all")
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("sort") == "viewedAt:desc")
    #expect(v("librarySectionID") == "3")
    // Paged: history is unbounded, a rail only needs the head.
    #expect(v("X-Plex-Container-Start") == "0")
    #expect(v("X-Plex-Container-Size") == "20")
}

// MARK: - Shuffle Library / artist leaves / popular

@Test func randomTracksIsSingleRandomSortedTrackPage() {
    let r = MusicRequest.randomTracks(server: server, token: "tok", identity: id, sectionKey: "3")
    #expect(r.url.path == "/library/sections/3/all")
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("type") == "10")
    #expect(v("sort") == "random")
    #expect(v("X-Plex-Container-Start") == "0")
    #expect(v("X-Plex-Container-Size") == "200")
}

@Test func allLeavesTargetsMetadataAllLeaves() {
    let r = MusicRequest.allLeaves(server: server, token: "tok", identity: id, ratingKey: "777")
    #expect(r.url.path == "/library/metadata/777/allLeaves")
    #expect(r.method == "GET")
    #expect(r.headers["X-Plex-Token"] == "tok")
}

@Test func popularTracksUsesPlexapiQueryShape() {
    let r = MusicRequest.popularTracks(server: server, token: "tok", identity: id,
                                       sectionKey: "3", artistRatingKey: "777")
    #expect(r.url.path == "/library/sections/3/all")
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("type") == "10")
    #expect(v("artist.id") == "777")
    #expect(v("group") == "title")
    #expect(v("sort") == "ratingCount:desc")
    #expect(v("limit") == "5")
    // The greater-than filter lives in the item NAME: `ratingCount>>` = "0".
    #expect(v("ratingCount>>") == "0")
}

@Test func popularTracksGreaterThanFilterPercentEncodes() throws {
    // Documents the wire shape: URLComponents must encode `>` so PMS sees
    // `ratingCount%3E%3E=0` (decoding back to `ratingCount>>=0`).
    let r = MusicRequest.popularTracks(server: server, token: "tok", identity: id,
                                       sectionKey: "3", artistRatingKey: "777")
    var components = try #require(URLComponents(url: r.url, resolvingAgainstBaseURL: false))
    components.queryItems = r.queryItems
    let query = try #require(components.url?.query)
    #expect(query.contains("ratingCount%3E%3E=0"))
}

// MARK: - Track stream URL

@Test func trackStreamURLCarriesTokenAndNoDownloadFlag() {
    let url = MusicRequest.trackStreamURL(server: server, token: "tok",
                                          partKey: "library/parts/123/456/file.mp3")
    #expect(url.absoluteString
        == "https://192.0.2.10:32400/library/parts/123/456/file.mp3?X-Plex-Token=tok")
    // Inline playback: download=1 would force attachment disposition.
    #expect(url.absoluteString.contains("download") == false)
}

@Test func trackStreamURLHandlesLeadingSlashPartKey() {
    let url = MusicRequest.trackStreamURL(server: server, token: "tok",
                                          partKey: "/library/parts/123/456/file.mp3")
    #expect(url.path == "/library/parts/123/456/file.mp3")
    #expect(url.absoluteString
        == "https://192.0.2.10:32400/library/parts/123/456/file.mp3?X-Plex-Token=tok")
}
