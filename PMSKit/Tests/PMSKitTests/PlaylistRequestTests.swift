import Testing
import Foundation
@testable import PMSKit

private let server = TestFixtures.plexServer
private let id = TestFixtures.plexIdentity

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

@Test func playlistItemsCarriesPlexContainerWindowWithoutChangingOrderShape() {
    let r = PlaylistRequest.items(server: server, token: "tok", identity: id,
                                  ratingKey: "555", containerStart: 200,
                                  containerSize: 100)
    func value(_ name: String) -> String? {
        r.queryItems.first { $0.name == name }?.value
    }
    #expect(value("X-Plex-Container-Start") == "200")
    #expect(value("X-Plex-Container-Size") == "100")
    #expect(r.queryItems.count == 2)
}

@Test func decodesPlaylistRowFields() throws {
    // A /playlists row: type "playlist", mosaic art under `composite` (no thumb),
    // track count under `leafCount`, total duration in ms.
    let json = """
    {"MediaContainer":{"Metadata":[
      {"ratingKey":"555","key":"/playlists/555/items","title":"Road Trip",
       "type":"playlist","playlistType":"audio","smart":false,
       "composite":"/playlists/555/composite/1749500000",
       "leafCount":42,"duration":9876000}]}}
    """.data(using: .utf8)!
    let item = try JSONDecoder().decode(MetadataResponse.self, from: json)
        .mediaContainer.metadata[0]
    #expect(item.kind == .playlist)
    #expect(item.composite == "/playlists/555/composite/1749500000")
    #expect(item.leafCount == 42)
    #expect(item.duration == 9_876_000)
    #expect(item.thumb == nil)
    #expect(item.playlistType == "audio")
    #expect(item.isAudioPlaylist)
}

@Test func videoPlaylistIsNotAudio() throws {
    // A VIDEO playlist must never route into the music module.
    let json = """
    {"MediaContainer":{"Metadata":[
      {"ratingKey":"777","title":"Movie Night","type":"playlist",
       "playlistType":"video","leafCount":3}]}}
    """.data(using: .utf8)!
    let item = try JSONDecoder().decode(MetadataResponse.self, from: json)
        .mediaContainer.metadata[0]
    #expect(item.playlistType == "video")
    #expect(!item.isAudioPlaylist)
}

@Test func unlabeledPlaylistDefaultsToAudio() {
    // Lenient default: an absent playlistType counts as audio (music surfaces
    // always fetch with playlistType=audio, so they're labeled anyway).
    let item = MediaItem(ratingKey: "1", title: "Mystery", type: "playlist")
    #expect(item.isAudioPlaylist)
    let movie = MediaItem(ratingKey: "2", title: "Film", type: "movie",
                          playlistType: "audio")
    #expect(!movie.isAudioPlaylist)
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

@Test func metadataDecodeSkipsRowsForDeletedItems() throws {
    // /status/sessions/history/all keeps rows for since-deleted items WITHOUT a
    // ratingKey; the lossy container decode must skip them, not throw away the
    // whole response (the all-or-nothing failure mode the review flagged).
    let json = """
    {"MediaContainer":{"Metadata":[
      {"title":"Ghost Of A Deleted Track","type":"track"},
      {"ratingKey":"901","title":"Take Five","type":"track","parentRatingKey":"900"}]}}
    """.data(using: .utf8)!
    let c = try JSONDecoder().decode(MetadataResponse.self, from: json)
    #expect(c.mediaContainer.metadata.count == 1)
    #expect(c.mediaContainer.metadata[0].ratingKey == "901")
}

// MARK: - Kind classification for music types

@Test(arguments: [
    ("artist", MediaItem.Kind.artist, false),
    ("album", MediaItem.Kind.album, false),
    ("track", MediaItem.Kind.track, true),
    ("playlist", MediaItem.Kind.playlist, false),
])
func musicKindsClassify(type: String, expectedKind: MediaItem.Kind, isPlayableLeaf: Bool) {
    // Only a track owns a Part; artist/album/playlist must be drilled into. isContainer
    // stays video-only, so no music type is a (video) container.
    let item = MediaItem(ratingKey: "1", title: "X", type: type)
    #expect(item.kind == expectedKind)
    #expect(item.isPlayableLeaf == isPlayableLeaf)
    #expect(!item.isContainer)
}
