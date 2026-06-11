import Testing
import Foundation
@testable import PlexKit

private let server = URL(string: "https://192.168.1.10:32400")!
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

@Test func asymmetricPagingEmitsNeitherItem() {
    // Start and size only emit together — a lone X-Plex-Container-Start would
    // make PMS page wrongly. Either half alone must produce NO paging items.
    let startOnly = MusicRequest.artists(server: server, token: "tok", identity: id,
                                         sectionKey: "3", containerStart: 100)
    let sizeOnly = MusicRequest.artists(server: server, token: "tok", identity: id,
                                        sectionKey: "3", containerSize: 50)
    for r in [startOnly, sizeOnly] {
        let names = r.queryItems.map(\.name)
        #expect(!names.contains("X-Plex-Container-Start"))
        #expect(!names.contains("X-Plex-Container-Size"))
    }
}

@Test func sortAloneEmitsNoPaging() {
    let r = MusicRequest.artists(server: server, token: "tok", identity: id,
                                 sectionKey: "3", sort: "titleSort")
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("sort") == "titleSort")
    #expect(!r.queryItems.map(\.name).contains("X-Plex-Container-Start"))
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
    // No account scoping unless asked: server-wide history by default.
    #expect(!r.queryItems.map(\.name).contains("accountID"))
}

@Test func playHistoryScopesToAccountWhenGiven() {
    // With an owner token PMS returns EVERY household member's plays unless
    // accountID filters; the owner is accountID=1 on the server's own endpoint.
    let r = MusicRequest.playHistory(server: server, token: "tok", identity: id,
                                     librarySectionID: "3", accountID: "1")
    #expect(r.queryItems.first { $0.name == "accountID" }?.value == "1")
}

// MARK: - Artist discography

@Test func artistAlbumsSearchesSectionByArtistId() {
    // /library/metadata/{rk}/children under-lists discographies (proven live:
    // size=0 for an artist with two own albums; a third "appears on" album
    // missing for another). The section search filtered by artist.id is what
    // plexapi/Plex Web use and returns the full set.
    let r = MusicRequest.artistAlbums(server: server, token: "tok", identity: id,
                                      sectionKey: "3", artistRatingKey: "2982")
    #expect(r.url.path == "/library/sections/3/all")
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("type") == "9")
    #expect(v("artist.id") == "2982")
    #expect(v("sort") == "originallyAvailableAt:desc")
    #expect(r.headers["X-Plex-Token"] == "tok")
}

@Test func appearsOnAlbumsFiltersByTrackOriginalTitle() {
    // Compilation appearances are TEXT-matched (track.originalTitle is an
    // exact-match filter; PMS links no artist node for them — proven live).
    let r = MusicRequest.appearsOnAlbums(server: server, token: "tok", identity: id,
                                         sectionKey: "3", artistTitle: "Wolfgang Lohr")
    #expect(r.url.path == "/library/sections/3/all")
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("type") == "9")
    #expect(v("track.originalTitle") == "Wolfgang Lohr")
    #expect(v("sort") == "originallyAvailableAt:desc")
}

@Test func relatedHubsTargetsMetadataRelated() {
    let r = MusicRequest.relatedHubs(server: server, token: "tok", identity: id,
                                     ratingKey: "2982")
    #expect(r.url.path == "/library/metadata/2982/related")
    #expect(r.method == "GET")
    #expect(r.queryItems.first { $0.name == "excludeFields" }?.value == "summary")
    #expect(r.headers["X-Plex-Token"] == "tok")
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
    // Filter operators live in the item NAME: `ratingCount>>` = "0", and the
    // plexapi subformat exclusion keeps compilation/live dupes out of Popular.
    #expect(v("ratingCount>>") == "0")
    #expect(v("album.subformat!") == "Compilation,Live")
}

@Test func popularTracksFilterOperatorsPercentEncodeOnTheWire() throws {
    // Exercise the REAL assembly path (PlexRequest.urlRequest), not a parallel
    // reconstruction: PMS must see `ratingCount%3E%3E=0` and the encoded `!`
    // name `album.subformat%21=Compilation,Live` (or a raw `!`, which is legal
    // in a query) — what matters is the operator survives into the final URL.
    let r = MusicRequest.popularTracks(server: server, token: "tok", identity: id,
                                       sectionKey: "3", artistRatingKey: "777")
    let query = try #require(r.urlRequest().url?.query)
    #expect(query.contains("ratingCount%3E%3E=0"))
    #expect(query.contains("album.subformat!=Compilation,Live")
            || query.contains("album.subformat%21=Compilation,Live"))
}

// MARK: - Track stream URL

@Test func trackStreamURLCarriesTokenAndNoDownloadFlag() {
    let url = MusicRequest.trackStreamURL(server: server, token: "tok",
                                          partKey: "library/parts/123/456/file.mp3")
    #expect(url.absoluteString
        == "https://192.168.1.10:32400/library/parts/123/456/file.mp3?X-Plex-Token=tok")
    // Inline playback: download=1 would force attachment disposition.
    #expect(url.absoluteString.contains("download") == false)
}

@Test func trackStreamURLHandlesLeadingSlashPartKey() {
    let url = MusicRequest.trackStreamURL(server: server, token: "tok",
                                          partKey: "/library/parts/123/456/file.mp3")
    #expect(url.path == "/library/parts/123/456/file.mp3")
    #expect(url.absoluteString
        == "https://192.168.1.10:32400/library/parts/123/456/file.mp3?X-Plex-Token=tok")
}
