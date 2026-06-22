import Foundation
import Testing
@testable import PMSKit

// Covers GH #101: poster artwork shape. Jellyfin/Emby report a per-item
// `PrimaryImageAspectRatio` (width / height) — 16:9 YouTube art, square Twitch channel
// art, 16:9 episode stills — which must flow onto `MediaItem.primaryImageAspectRatio` so
// poster cells size to the real shape instead of force-cropping into a fixed 2:3 box.
// Items WITHOUT the field (notably Plex, which never sends it) decode to nil and fall back
// to the canonical 2:3 poster.

@Suite("Poster aspect ratio (#101)")
struct PosterAspectTests {
    private func fieldSet(_ fields: String) -> Set<String> {
        Set(fields.split(separator: ",").map(String.init))
    }

    // MARK: - Field-set requests

    @Test func allMediaBrowserFieldStringsRequestPrimaryImageAspectRatio() {
        // Without PrimaryImageAspectRatio in the grid + full field sets the server omits the
        // value, so every cell would silently fall back to 2:3 — defeating the fix.
        for fields in [
            JellyfinLibrary.gridItemFields,
            JellyfinLibrary.fullItemFields,
            EmbyLibrary.gridItemFields,
            EmbyLibrary.fullItemFields,
        ] {
            #expect(fieldSet(fields).contains("PrimaryImageAspectRatio"))
        }
    }

    // MARK: - Decode → MediaItem.primaryImageAspectRatio (Jellyfin)

    @Test func jellyfinDecodesSixteenNineAspect() throws {
        let dto = try JSONDecoder().decode(JellyfinBaseItemDto.self, from: Data(#"""
        {
          "Id": "yt-1", "Name": "A YouTube video", "Type": "Movie",
          "PrimaryImageAspectRatio": 1.7777777777777777,
          "ImageTags": { "Primary": "poster" }
        }
        """#.utf8))
        let item = try #require(dto.toMediaItem())
        let aspect = try #require(item.primaryImageAspectRatio)
        #expect(abs(aspect - 16.0 / 9.0) < 0.0001)
        // 16:9 is preserved by the resolver (not collapsed to the 2:3 fallback).
        #expect(abs(item.resolvedPosterAspect() - 16.0 / 9.0) < 0.0001)
    }

    @Test func jellyfinDecodesSquareAspect() throws {
        let dto = try JSONDecoder().decode(JellyfinBaseItemDto.self, from: Data(#"""
        {
          "Id": "twitch-1", "Name": "A Twitch channel", "Type": "Video",
          "PrimaryImageAspectRatio": 1.0,
          "ImageTags": { "Primary": "poster" }
        }
        """#.utf8))
        let item = try #require(dto.toMediaItem())
        #expect(item.primaryImageAspectRatio == 1.0)
        #expect(item.resolvedPosterAspect() == 1.0)
    }

    // MARK: - Decode → MediaItem.primaryImageAspectRatio (Emby — shared struct, diff scheme)

    @Test func embyDecodesSixteenNineAspect() throws {
        let dto = try JSONDecoder().decode(EmbyBaseItemDto.self, from: Data(#"""
        {
          "Id": "yt-2", "Name": "A YouTube video", "Type": "Movie",
          "PrimaryImageAspectRatio": 1.7777777777777777,
          "ImageTags": { "Primary": "poster" }
        }
        """#.utf8))
        let item = try #require(dto.toMediaItem())
        let aspect = try #require(item.primaryImageAspectRatio)
        #expect(abs(aspect - 16.0 / 9.0) < 0.0001)
    }

    // MARK: - Missing field → nil → 2:3 fallback

    @Test func itemWithoutAspectDecodesToNilAndFallsBackToTwoThirds() throws {
        let dto = try JSONDecoder().decode(JellyfinBaseItemDto.self, from: Data(#"""
        {
          "Id": "movie-1", "Name": "A Movie", "Type": "Movie",
          "ImageTags": { "Primary": "poster" }
        }
        """#.utf8))
        let item = try #require(dto.toMediaItem())
        #expect(item.primaryImageAspectRatio == nil)
        // Falls back to the canonical 2:3 poster shape.
        #expect(item.resolvedPosterAspect() == 2.0 / 3.0)
        #expect(item.resolvedPosterAspect() == MediaItem.defaultPosterAspect)
    }

    @Test func plexItemHasNoPrimaryImageAspectRatio() throws {
        // Plex never sends PrimaryImageAspectRatio; its posters are genuinely 2:3, so the
        // fallback keeps Plex unchanged.
        let json = """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"1","title":"A Plex Movie","type":"movie"}]}}
        """.data(using: .utf8)!
        let c = try JSONDecoder().decode(MetadataResponse.self, from: json)
        let item = c.mediaContainer.metadata[0]
        #expect(item.primaryImageAspectRatio == nil)
        #expect(item.resolvedPosterAspect() == 2.0 / 3.0)
    }

    // MARK: - Resolver hardening

    @Test func resolverIgnoresNonPositiveOrNonFiniteAspect() {
        for bad: Double in [0, -1.5, .nan, .infinity] {
            let item = MediaItem(ratingKey: "x", title: "X", type: "movie",
                                 primaryImageAspectRatio: bad)
            #expect(item.resolvedPosterAspect() == 2.0 / 3.0)
        }
    }

    @Test func resolverHonorsExplicitFallback() {
        let item = MediaItem(ratingKey: "x", title: "X", type: "movie")
        #expect(item.resolvedPosterAspect(fallback: 16.0 / 9.0) == 16.0 / 9.0)
    }
}
