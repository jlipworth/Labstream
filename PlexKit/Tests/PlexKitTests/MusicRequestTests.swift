import Testing
import Foundation
@testable import PlexKit

private let server = URL(string: "https://192.0.2.10:32400")!
private let id = ClientIdentity(clientIdentifier: "CID",
                                product: "plex-avp-app",
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
