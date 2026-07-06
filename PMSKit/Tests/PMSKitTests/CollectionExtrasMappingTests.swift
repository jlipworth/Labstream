import Foundation
import Testing
@testable import PMSKit

@Suite("Collections and related-media mapping")
struct CollectionExtrasMappingTests {
    @Test func mediaBrowserBoxSetMapsToNonPlayableCollectionContainer() throws {
        let dto = try JSONDecoder().decode(JellyfinBaseItemDto.self, from: Data(#"""
        {
          "Id": "boxset-1",
          "Name": "Curated Collection",
          "Type": "BoxSet",
          "Overview": "A redacted backend-defined collection.",
          "ImageTags": { "Primary": "poster-tag" },
          "BackdropImageTags": ["backdrop-tag"],
          "PrimaryImageAspectRatio": 0.6667
        }
        """#.utf8))

        let item = try #require(dto.toMediaItem())
        #expect(item.ratingKey == "boxset-1")
        #expect(item.title == "Curated Collection")
        #expect(item.type == "collection")
        #expect(item.kind == .collection)
        #expect(item.isCollection)
        #expect(item.isContainer)
        #expect(item.isPlayableLeaf == false)
        #expect(item.thumb == "jellyfin://item/boxset-1/Primary?tag=poster-tag")
        #expect(item.art == "jellyfin://item/boxset-1/Backdrop?tag=backdrop-tag")
    }

    @Test func mediaBrowserTrailerMapsToPlayableTrailerLeaf() throws {
        let dto = try JSONDecoder().decode(EmbyBaseItemDto.self, from: Data(#"""
        {
          "Id": "trailer-1",
          "Name": "Local Trailer",
          "Type": "Trailer",
          "RunTimeTicks": 900000000,
          "ImageTags": { "Primary": "trailer-poster" },
          "MediaSources": [{
            "Id": "source-1",
            "Container": "mp4",
            "SupportsDirectPlay": true,
            "MediaStreams": []
          }]
        }
        """#.utf8))

        let item = try #require(dto.toMediaItem())
        #expect(item.type == "trailer")
        #expect(item.kind == .trailer)
        #expect(item.isPlayableLeaf)
        #expect(item.isContainer == false)
        #expect(item.duration == 90_000)
        #expect(item.media?.first?.container == "mp4")
        #expect(item.thumb == "emby://item/trailer-1/Primary?tag=trailer-poster")
    }

    @Test func mediaBrowserVideoWithTrailerExtraTypeMapsToPlayableTrailerLeaf() throws {
        let dto = try JSONDecoder().decode(JellyfinBaseItemDto.self, from: Data(#"""
        {
          "Id": "video-trailer-1",
          "Name": "Local Trailer",
          "Type": "Video",
          "ExtraType": "Trailer",
          "MediaSources": [{ "Id": "source-1", "Container": "mp4" }]
        }
        """#.utf8))

        let item = try #require(dto.toMediaItem())
        #expect(dto.extraType == "Trailer")
        #expect(item.type == "trailer")
        #expect(item.kind == .trailer)
        #expect(item.isPlayableLeaf)
    }

    @Test func mediaBrowserVideoWithSpecialFeatureExtraTypeMapsToPlayableExtraLeaf() throws {
        for extraType in ["Featurette", "DeletedScene", "BehindTheScenes", "Other"] {
            let dto = try JSONDecoder().decode(EmbyBaseItemDto.self, from: Data("""
            {
              "Id": "video-extra-\(extraType)",
              "Name": "Special Feature",
              "Type": "Video",
              "ExtraType": "\(extraType)",
              "MediaSources": [{ "Id": "source-1", "Container": "mp4" }]
            }
            """.utf8))

            let item = try #require(dto.toMediaItem())
            #expect(item.type == "extra")
            #expect(item.kind == .extra)
            #expect(item.isPlayableLeaf)
        }
    }

    @Test func mediaBrowserFullItemDecodesRelatedMediaAvailabilityHints() throws {
        let dto = try JSONDecoder().decode(JellyfinBaseItemDto.self, from: Data(#"""
        {
          "Id": "movie-1",
          "Name": "Redacted Movie",
          "Type": "Movie",
          "ExtraIds": ["extra-1", "extra-2"],
          "LocalTrailerCount": 1,
          "SpecialFeatureCount": 2,
          "RemoteTrailers": [
            { "Name": "Official Trailer", "Url": "https://trailers.example.test/watch?v=redacted" }
          ]
        }
        """#.utf8))

        #expect(dto.extraIds == ["extra-1", "extra-2"])
        #expect(dto.localTrailerCount == 1)
        #expect(dto.specialFeatureCount == 2)
        #expect(dto.remoteTrailers.first?.name == "Official Trailer")

        let item = try #require(dto.toMediaItem())
        let availability = try #require(item.relatedAvailability)
        #expect(availability.extraIds == ["extra-1", "extra-2"])
        #expect(availability.hasLocalTrailers)
        #expect(availability.hasSpecialFeatures)
        #expect(availability.hasRemoteTrailers)
        #expect(availability.hasAnyRelatedMedia)
    }

    @Test func plexInlineExtrasDecodeAsRelatedPlayableItems() throws {
        let response = try JSONDecoder().decode(MetadataResponse.self, from: Data(#"""
        {
          "MediaContainer": {
            "Metadata": [{
              "ratingKey": "movie-1",
              "title": "Redacted Movie",
              "type": "movie",
              "Extras": {
                "Metadata": [{
                  "ratingKey": "extra-1",
                  "title": "Behind the Scenes",
                  "type": "clip",
                  "subtype": "behindTheScenes",
                  "duration": 60000,
                  "thumb": "/library/metadata/extra-1/thumb",
                  "Media": [{
                    "id": 1,
                    "Part": [{
                      "id": 11,
                      "key": "/library/parts/11/file.mp4"
                    }]
                  }]
                },
                {
                  "ratingKey": "extra-2",
                  "title": "Official Trailer",
                  "type": "clip",
                  "subtype": "trailer"
                }]
              }
            }]
          }
        }
        """#.utf8))

        let movie = try #require(response.mediaContainer.metadata.first)
        // Real Plex extras arrive as type "clip" with the classification in `subtype`.
        let extra = try #require(movie.relatedItems?.first)
        #expect(extra.ratingKey == "extra-1")
        #expect(extra.title == "Behind the Scenes")
        #expect(extra.kind == .extra)
        #expect(extra.isPlayableLeaf)
        #expect(extra.media?.first?.part.first?.key == "/library/parts/11/file.mp4")
        let trailer = try #require(movie.relatedItems?.last)
        #expect(trailer.kind == .trailer)
        #expect(trailer.isPlayableLeaf)
    }

    /// Extras are secondary media: a malformed extras row (or a whole malformed `Extras`
    /// subtree) must degrade to fewer/no extras — never fail the parent item's decode,
    /// which the outer lossy row decode would turn into a silently missing movie.
    @Test func plexMalformedExtrasRowsDoNotDropTheParentItem() throws {
        let response = try JSONDecoder().decode(MetadataResponse.self, from: Data(#"""
        {
          "MediaContainer": {
            "Metadata": [{
              "ratingKey": "movie-1",
              "title": "Redacted Movie",
              "type": "movie",
              "Extras": {
                "Metadata": [
                  { "title": "No ratingKey — malformed", "type": "extra" },
                  { "ratingKey": "extra-2", "title": "Featurette", "type": "extra" }
                ]
              }
            },
            {
              "ratingKey": "movie-2",
              "title": "Other Movie",
              "type": "movie",
              "Extras": "not-an-object"
            }]
          }
        }
        """#.utf8))

        #expect(response.mediaContainer.metadata.count == 2)
        let first = try #require(response.mediaContainer.metadata.first)
        #expect(first.relatedItems?.map(\.ratingKey) == ["extra-2"])
        let second = try #require(response.mediaContainer.metadata.last)
        #expect(second.ratingKey == "movie-2")
        #expect(second.relatedItems == nil)
    }
}
