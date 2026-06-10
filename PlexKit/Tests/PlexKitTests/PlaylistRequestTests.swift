import Testing
import Foundation
@testable import PlexKit

private let server = URL(string: "https://192.0.2.10:32400")!
private let id = ClientIdentity(clientIdentifier: "CID",
                                product: "VisionPlex",
                                version: "0.1.0",
                                deviceName: "AVP")

// MARK: - Playlist builders (read-only v1, MUSIC-DESIGN §3.4)

@Test func audioPlaylistsFiltersToAudioType() {
    let r = PlaylistRequest.audioPlaylists(server: server, token: "tok", identity: id)
    #expect(r.url.path == "/playlists")
    #expect(r.method == "GET")
    func v(_ n: String) -> String? { r.queryItems.first { $0.name == n }?.value }
    #expect(v("playlistType") == "audio")
    #expect(r.headers["X-Plex-Token"] == "tok")
    #expect(r.headers["X-Plex-Client-Identifier"] == "CID")
}

@Test func playlistItemsTargetsItemsPath() {
    let r = PlaylistRequest.items(server: server, token: "tok", identity: id, ratingKey: "555")
    #expect(r.url.path == "/playlists/555/items")
    #expect(r.method == "GET")
    #expect(r.headers["X-Plex-Token"] == "tok")
}

// MARK: - Music MediaItem decodes (MUSIC-DESIGN §6 additive fields)

@Test func decodesMusicFieldsOnTrack() throws {
    let json = """
    {"MediaContainer":{"Metadata":[
      {"ratingKey":"901","title":"Take Five","type":"track",
       "originalTitle":"The Dave Brubeck Quartet",
       "grandparentTitle":"Various Artists","parentTitle":"Jazz Comp",
       "lastViewedAt":1749500000,"parentYear":1959,"ratingCount":42,
       "index":3,"parentIndex":1,"duration":324000}]}}
    """.data(using: .utf8)!
    let item = try JSONDecoder().decode(MetadataResponse.self, from: json)
        .mediaContainer.metadata[0]
    #expect(item.originalTitle == "The Dave Brubeck Quartet")
    #expect(item.lastViewedAt == 1_749_500_000)
    #expect(item.parentYear == 1959)
    #expect(item.ratingCount == 42)
}

@Test func musicFieldsDecodeNilWhenAbsent() throws {
    let json = """
    {"MediaContainer":{"Metadata":[
      {"ratingKey":"101","title":"Blade Runner","type":"movie"}]}}
    """.data(using: .utf8)!
    let item = try JSONDecoder().decode(MetadataResponse.self, from: json)
        .mediaContainer.metadata[0]
    #expect(item.originalTitle == nil)
    #expect(item.lastViewedAt == nil)
    #expect(item.parentYear == nil)
    #expect(item.ratingCount == nil)
}

// MARK: - Kind classification for music types

@Test func musicKindsClassify() {
    #expect(MediaItem(ratingKey: "1", title: "A", type: "artist").kind == .artist)
    #expect(MediaItem(ratingKey: "2", title: "B", type: "album").kind == .album)
    #expect(MediaItem(ratingKey: "3", title: "C", type: "track").kind == .track)
    #expect(MediaItem(ratingKey: "4", title: "D", type: "playlist").kind == .playlist)
}

@Test func musicLeafnessMatchesPartOwnership() {
    // Only a track owns a Part; artist/album/playlist must be drilled into.
    #expect(MediaItem(ratingKey: "3", title: "C", type: "track").isPlayableLeaf)
    #expect(!MediaItem(ratingKey: "1", title: "A", type: "artist").isPlayableLeaf)
    #expect(!MediaItem(ratingKey: "2", title: "B", type: "album").isPlayableLeaf)
    #expect(!MediaItem(ratingKey: "4", title: "D", type: "playlist").isPlayableLeaf)
}

@Test func musicContainerFlagUnchangedByKindAdditions() {
    // isMusicContainer drives music routing (artist/album only — a playlist
    // routes via its own case); isContainer stays video-only.
    #expect(MediaItem(ratingKey: "1", title: "A", type: "artist").isMusicContainer)
    #expect(MediaItem(ratingKey: "2", title: "B", type: "album").isMusicContainer)
    #expect(!MediaItem(ratingKey: "3", title: "C", type: "track").isMusicContainer)
    #expect(!MediaItem(ratingKey: "1", title: "A", type: "artist").isContainer)
}
