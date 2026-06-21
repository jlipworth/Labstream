import Foundation
import Testing
@testable import PMSKit

// Covers GH #86 (Jellyfin/Emby parent/series artwork fallback) and the cross-backend
// artwork/metadata surfacing in GH #76 (Logo + episode Thumb, cast/studios, critic rating).
//
// The MediaBrowser DTO is shared by Jellyfin and Emby, so each fallback assertion is run
// once on a `JellyfinBaseItemDto` and once on an `EmbyBaseItemDto` where the scheme is the
// only difference; Plex paths are exercised through `MetadataResponse`.

@Suite("Artwork & metadata (#86 / #76)")
struct ArtworkMetadataTests {

    // MARK: - #86 — parent/series artwork fallback (Jellyfin)

    @Test func episodeWithOwnPrimaryUsesItsOwnImage() throws {
        let dto = try JSONDecoder().decode(JellyfinBaseItemDto.self, from: Data(#"""
        {
          "Id": "episode-1", "Name": "Pilot", "Type": "Episode",
          "SeriesId": "series-1", "SeasonId": "season-1", "ParentId": "season-1",
          "ImageTags": { "Primary": "own-ep-tag" },
          "ParentThumbItemId": "season-1", "ParentThumbImageTag": "season-thumb-tag",
          "SeriesPrimaryImageTag": "series-poster-tag"
        }
        """#.utf8))
        let item = try #require(dto.toMediaItem())
        // Own Primary wins over any parent/series fallback.
        #expect(item.thumb == "jellyfin://item/episode-1/Primary?tag=own-ep-tag")
    }

    @Test func episodeMissingPrimaryFallsBackToSeasonThumb() throws {
        let dto = try JSONDecoder().decode(JellyfinBaseItemDto.self, from: Data(#"""
        {
          "Id": "episode-2", "Name": "Cat's in the Bag", "Type": "Episode",
          "SeriesId": "series-1", "SeasonId": "season-1", "ParentId": "season-1",
          "ImageTags": {},
          "ParentThumbItemId": "season-1", "ParentThumbImageTag": "season-thumb-tag",
          "SeriesPrimaryImageTag": "series-poster-tag"
        }
        """#.utf8))
        let item = try #require(dto.toMediaItem())
        // No own Primary → season thumb, minted against the SEASON id, not the episode id.
        #expect(item.thumb == "jellyfin://item/season-1/Thumb?tag=season-thumb-tag")
        // parentThumb is populated for the episode-row `thumb ?? parentThumb` render.
        #expect(item.parentThumb == "jellyfin://item/season-1/Thumb?tag=season-thumb-tag")
        // The series poster is exposed as grandparentThumb for the show link.
        #expect(item.grandparentThumb == "jellyfin://item/series-1/Primary?tag=series-poster-tag")
    }

    @Test func episodeMissingPrimaryAndSeasonThumbFallsBackToSeriesPoster() throws {
        let dto = try JSONDecoder().decode(JellyfinBaseItemDto.self, from: Data(#"""
        {
          "Id": "episode-3", "Name": "Gray Matter", "Type": "Episode",
          "SeriesId": "series-1", "SeasonId": "season-1", "ParentId": "season-1",
          "ImageTags": {},
          "SeriesPrimaryImageTag": "series-poster-tag"
        }
        """#.utf8))
        let item = try #require(dto.toMediaItem())
        #expect(item.thumb == "jellyfin://item/series-1/Primary?tag=series-poster-tag")
    }

    @Test func seasonMissingPrimaryFallsBackToSeriesPoster() throws {
        let dto = try JSONDecoder().decode(JellyfinBaseItemDto.self, from: Data(#"""
        {
          "Id": "season-9", "Name": "Season 1", "Type": "Season",
          "SeriesId": "series-1", "ParentId": "series-1",
          "ImageTags": {},
          "SeriesPrimaryImageTag": "series-poster-tag"
        }
        """#.utf8))
        let item = try #require(dto.toMediaItem())
        #expect(item.thumb == "jellyfin://item/series-1/Primary?tag=series-poster-tag")
    }

    @Test func episodeBackdropFallsBackToParentBackdrop() throws {
        let dto = try JSONDecoder().decode(JellyfinBaseItemDto.self, from: Data(#"""
        {
          "Id": "episode-4", "Name": "Crazy Handful", "Type": "Episode",
          "SeriesId": "series-1", "SeasonId": "season-1", "ParentId": "season-1",
          "BackdropImageTags": [],
          "ParentBackdropItemId": "series-1", "ParentBackdropImageTags": ["series-backdrop-tag"]
        }
        """#.utf8))
        let item = try #require(dto.toMediaItem())
        #expect(item.art == "jellyfin://item/series-1/Backdrop?tag=series-backdrop-tag")
    }

    // MARK: - #86 — same fallback on the Emby flavor (shared struct, different scheme)

    @Test func embyEpisodeMissingPrimaryFallsBackToSeasonThumb() throws {
        let dto = try JSONDecoder().decode(EmbyBaseItemDto.self, from: Data(#"""
        {
          "Id": "episode-2", "Name": "Episode", "Type": "Episode",
          "SeriesId": "series-1", "SeasonId": "season-1", "ParentId": "season-1",
          "ImageTags": {},
          "ParentThumbItemId": "season-1", "ParentThumbImageTag": "season-thumb-tag",
          "SeriesPrimaryImageTag": "series-poster-tag"
        }
        """#.utf8))
        let item = try #require(dto.toMediaItem())
        #expect(item.thumb == "emby://item/season-1/Thumb?tag=season-thumb-tag")
        #expect(item.grandparentThumb == "emby://item/series-1/Primary?tag=series-poster-tag")
    }

    // MARK: - #76 — episode-still Thumb preferred over poster for the still slot

    @Test func episodeStillThumbPreferredWhenPresent() throws {
        let dto = try JSONDecoder().decode(JellyfinBaseItemDto.self, from: Data(#"""
        {
          "Id": "episode-5", "Name": "A No-Rough-Stuff-Type Deal", "Type": "Episode",
          "ImageTags": { "Primary": "own-ep-poster", "Thumb": "own-ep-still" }
        }
        """#.utf8))
        let item = try #require(dto.toMediaItem())
        // The still slot (thumb) prefers the dedicated Thumb image when present.
        #expect(item.thumb == "jellyfin://item/episode-5/Thumb?tag=own-ep-still")
    }

    // MARK: - #76 — Logo, cast/studios, critic rating (Jellyfin/Emby)

    @Test func mapsLogoCastStudiosCriticRating() throws {
        let dto = try JSONDecoder().decode(JellyfinBaseItemDto.self, from: Data(#"""
        {
          "Id": "movie-7", "Name": "A Movie", "Type": "Movie",
          "CommunityRating": 8.1, "CriticRating": 93,
          "ImageTags": { "Primary": "poster-tag", "Logo": "logo-tag" },
          "People": [
            { "Name": "Lead Actor", "Type": "Actor", "Role": "Hero" },
            { "Name": "Side Actor", "Type": "Actor" },
            { "Name": "The Director", "Type": "Director" },
            { "Name": "A Writer", "Type": "Writer" }
          ],
          "Studios": [ { "Name": "Studio One" }, { "Name": "Studio Two" } ]
        }
        """#.utf8))
        let item = try #require(dto.toMediaItem())
        #expect(item.logo == "jellyfin://item/movie-7/Logo?tag=logo-tag")
        #expect(item.rating == 8.1)
        #expect(item.criticRating == 93)
        #expect(item.roles?.map(\.tag) == ["Lead Actor", "Side Actor"])
        #expect(item.directors?.map(\.tag) == ["The Director"])
        #expect(item.studios?.map(\.tag) == ["Studio One", "Studio Two"])
    }

    @Test func missingExtendedMetadataDecodesToNil() throws {
        let dto = try JSONDecoder().decode(JellyfinBaseItemDto.self, from: Data(#"""
        { "Id": "movie-8", "Name": "Bare Movie", "Type": "Movie",
          "ImageTags": { "Primary": "poster" } }
        """#.utf8))
        let item = try #require(dto.toMediaItem())
        #expect(item.logo == nil)
        #expect(item.criticRating == nil)
        #expect(item.roles == nil)
        #expect(item.directors == nil)
        #expect(item.studios == nil)
    }

    // MARK: - #76 — Plex cast/studios/critic/logo decoding

    @Test func plexDecodesCastStudiosCriticAndLogo() throws {
        let json = """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"42","title":"Arrival","type":"movie","year":2016,
           "rating":7.9,"audienceRating":8.4,
           "Role":[{"tag":"Amy Adams"},{"tag":"Jeremy Renner"}],
           "Director":[{"tag":"Denis Villeneuve"}],
           "Country":[{"tag":"United States of America"}],
           "Image":[
             {"alt":"Arrival","type":"coverPoster","url":"/library/metadata/42/thumb/1"},
             {"alt":"Arrival","type":"clearLogo","url":"/library/metadata/42/clearLogo/1"}
           ]}]}}
        """.data(using: .utf8)!
        let c = try JSONDecoder().decode(MetadataResponse.self, from: json)
        let item = c.mediaContainer.metadata[0]
        #expect(item.rating == 7.9)
        #expect(item.criticRating == 8.4)
        #expect(item.roles?.map(\.tag) == ["Amy Adams", "Jeremy Renner"])
        #expect(item.directors?.map(\.tag) == ["Denis Villeneuve"])
        #expect(item.studios?.map(\.tag) == ["United States of America"])
        #expect(item.logo == "/library/metadata/42/clearLogo/1")
    }

    @Test func plexBareItemHasNoExtendedMetadata() throws {
        let json = """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"1","title":"Bare","type":"movie"}]}}
        """.data(using: .utf8)!
        let c = try JSONDecoder().decode(MetadataResponse.self, from: json)
        let item = c.mediaContainer.metadata[0]
        #expect(item.criticRating == nil)
        #expect(item.roles == nil)
        #expect(item.directors == nil)
        #expect(item.studios == nil)
        #expect(item.logo == nil)
    }
}
