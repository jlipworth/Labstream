import Foundation
import Testing
@testable import PMSKit

/// #111: `MediaBrowserBaseItemDto.toMediaItem()` must map the music item types (MusicArtist,
/// MusicAlbum, Audio, Playlist) onto PMS music kinds, carrying the album/artist hierarchy so
/// search + browse can facet and route them. Before this, those rows decoded and were dropped
/// (`toMediaItem()` returned nil), so requesting them in a search did nothing.
struct MediaBrowserMusicMappingTests {

    private func jellyfin(_ json: String) throws -> JellyfinBaseItemDto {
        try JSONDecoder().decode(JellyfinBaseItemDto.self, from: Data(json.utf8))
    }

    @Test func musicArtistMapsToArtistKind() throws {
        let dto = try jellyfin(#"""
        { "Id": "artist-1", "Name": "Boards of Canada", "Type": "MusicArtist",
          "ImageTags": { "Primary": "artist-art" } }
        """#)
        let item = try #require(dto.toMediaItem())
        #expect(item.type == "artist")
        #expect(item.kind == .artist)
        #expect(item.isMusic)
        #expect(item.isMusicContainer)
        #expect(item.title == "Boards of Canada")
        #expect(item.thumb == "jellyfin://item/artist-1/Primary?tag=artist-art")
    }

    @Test func musicAlbumMapsToAlbumKindWithArtistParent() throws {
        let dto = try jellyfin(#"""
        { "Id": "album-1", "Name": "Music Has the Right to Children", "Type": "MusicAlbum",
          "ParentId": "artist-1", "AlbumArtist": "Boards of Canada", "ProductionYear": 1998,
          "ImageTags": { "Primary": "album-art" } }
        """#)
        let item = try #require(dto.toMediaItem())
        #expect(item.type == "album")
        #expect(item.kind == .album)
        #expect(item.isMusicContainer)
        #expect(item.year == 1998)
        // An album's parent is its album-artist.
        #expect(item.parentTitle == "Boards of Canada")
        #expect(item.parentRatingKey == "artist-1")
        #expect(item.thumb == "jellyfin://item/album-1/Primary?tag=album-art")
    }

    @Test func audioMapsToTrackWithAlbumAndArtistHierarchy() throws {
        let dto = try jellyfin(#"""
        { "Id": "track-1", "Name": "Roygbiv", "Type": "Audio",
          "Album": "Music Has the Right to Children", "AlbumId": "album-1",
          "AlbumArtist": "Boards of Canada", "AlbumPrimaryImageTag": "album-art",
          "IndexNumber": 9, "ParentIndexNumber": 1, "RunTimeTicks": 1487000000,
          "ParentId": "album-1", "ImageTags": {} }
        """#)
        let item = try #require(dto.toMediaItem())
        #expect(item.type == "track")
        #expect(item.kind == .track)
        #expect(item.isMusic)
        #expect(item.isPlayableLeaf)            // a track is directly playable
        #expect(!item.isMusicContainer)
        // Track hierarchy: parent = album, grandparent = album-artist.
        #expect(item.parentTitle == "Music Has the Right to Children")
        #expect(item.parentRatingKey == "album-1")
        #expect(item.grandparentTitle == "Boards of Canada")
        #expect(item.index == 9)
        #expect(item.parentIndex == 1)
        // RunTimeTicks (100ns units) → ms.
        #expect(item.duration == 148_700)
        // A track with no own Primary borrows the album's poster, minted against the ALBUM id.
        #expect(item.thumb == "jellyfin://item/album-1/Primary?tag=album-art")
    }

    @Test func playlistMapsToPlaylistKind() throws {
        let dto = try jellyfin(#"""
        { "Id": "pl-1", "Name": "Late Night", "Type": "Playlist",
          "ImageTags": { "Primary": "pl-art" } }
        """#)
        let item = try #require(dto.toMediaItem())
        #expect(item.type == "playlist")
        #expect(item.kind == .playlist)
    }

    @Test func embyAudioUsesEmbyScheme() throws {
        let dto = try JSONDecoder().decode(EmbyBaseItemDto.self, from: Data(#"""
        { "Id": "track-9", "Name": "Olson", "Type": "Audio",
          "AlbumId": "album-9", "AlbumPrimaryImageTag": "art-9", "ImageTags": {} }
        """#.utf8))
        let item = try #require(dto.toMediaItem())
        #expect(item.type == "track")
        #expect(item.thumb == "emby://item/album-9/Primary?tag=art-9")
    }

    @Test func videoTypesAreUnaffectedByTheMusicMapping() throws {
        let movie = try jellyfin(#"""
        { "Id": "m-1", "Name": "Heat", "Type": "Movie", "ImageTags": { "Primary": "m-art" } }
        """#)
        let movieItem = try #require(movie.toMediaItem())
        #expect(movieItem.type == "movie")
        #expect(!movieItem.isMusic)
        #expect(movieItem.parentTitle == nil)
        #expect(movieItem.grandparentTitle == nil)
    }
}
