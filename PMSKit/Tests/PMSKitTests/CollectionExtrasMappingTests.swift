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
                  "type": "extra",
                  "duration": 60000,
                  "thumb": "/library/metadata/extra-1/thumb",
                  "Media": [{
                    "id": 1,
                    "Part": [{
                      "id": 11,
                      "key": "/library/parts/11/file.mp4"
                    }]
                  }]
                }]
              }
            }]
          }
        }
        """#.utf8))

        let movie = try #require(response.mediaContainer.metadata.first)
        let extra = try #require(movie.relatedItems?.first)
        #expect(extra.ratingKey == "extra-1")
        #expect(extra.title == "Behind the Scenes")
        #expect(extra.kind == .extra)
        #expect(extra.isPlayableLeaf)
        #expect(extra.media?.first?.part.first?.key == "/library/parts/11/file.mp4")
    }
}
