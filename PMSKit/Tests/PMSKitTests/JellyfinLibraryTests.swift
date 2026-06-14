import Foundation
import Testing
@testable import PMSKit

@Suite("Jellyfin library")
struct JellyfinLibraryTests {
    private let server = URL(string: "https://jellyfin.example.test/base")!
    private let identity = JellyfinClientIdentity(client: "VisionPlex", device: "Apple Vision Pro", deviceId: "device-123", version: "0.1.0")

    @Test func decodesAuthenticationResult() throws {
        let result = try JSONDecoder().decode(JellyfinAuthenticationResult.self, from: Data(#"""
        {
          "User": { "Id": "user-1", "Name": "viewer" },
          "AccessToken": "token-abc",
          "ServerId": "server-1"
        }
        """#.utf8))

        #expect(result.user?.id == "user-1")
        #expect(result.user?.name == "viewer")
        #expect(result.accessToken == "token-abc")
        #expect(result.serverId == "server-1")
    }

    @Test func userViewsRequestCarriesUserAndAuth() throws {
        let request = try JellyfinLibrary.userViewsRequest(server: server, token: "token-abc", identity: identity, userId: "user-1")
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(request.httpMethod == "GET")
        #expect(components.scheme == "https")
        #expect(components.host == "jellyfin.example.test")
        #expect(components.path == "/base/UserViews")
        #expect(query["userId"] == "user-1")
        #expect(query["includeExternalContent"] == "false")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"token-abc\"") == true)
    }

    @Test func itemsRequestCarriesVideoQueryShape() throws {
        let request = try JellyfinLibrary.itemsRequest(server: server, token: "token-abc", identity: identity, userId: "user-1", parentId: "view-1", recursive: false)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.path == "/base/Items")
        #expect(query["userId"] == "user-1")
        #expect(query["parentId"] == "view-1")
        #expect(query["recursive"] == "false")
        #expect(query["includeItemTypes"] == "Movie,Series,Season,Episode")
        #expect(query["enableUserData"] == "true")
        #expect(query["fields"]?.contains("MediaSources") == true)
        #expect(query["fields"]?.contains("OfficialRating") == true)
        #expect(query["fields"]?.contains("CommunityRating") == true)
        #expect(query["fields"]?.contains("Genres") == true)
    }

    @Test func itemRequestTargetsSingleItem() throws {
        let request = try JellyfinLibrary.itemRequest(server: server, token: "token-abc", identity: identity, userId: "user-1", itemId: "item-1")
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.path == "/base/Items/item-1")
        #expect(query["userId"] == "user-1")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"token-abc\"") == true)
    }

    @Test func imageURLPreservesBasePathAndOptions() throws {
        let url = try JellyfinLibrary.imageURL(server: server, itemId: "item-1", imageType: .primary, tag: "tag-1", width: 400, height: 600)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.path == "/base/Items/item-1/Images/Primary")
        #expect(query["tag"] == "tag-1")
        #expect(query["width"] == "400")
        #expect(query["height"] == "600")
    }

    @Test func activeEncodingStopTargetsDeviceAndSession() throws {
        let request = try JellyfinLibrary.activeEncodingStopRequest(server: server, token: "token-abc", identity: identity, deviceId: "device-123", playSessionId: "play-1")
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(request.httpMethod == "DELETE")
        #expect(components.path == "/base/Videos/ActiveEncodings")
        #expect(query["deviceId"] == "device-123")
        #expect(query["playSessionId"] == "play-1")
    }

    @Test func mapsMovieDtoToMediaItem() throws {
        let response = try JSONDecoder().decode(JellyfinItemsResponse.self, from: Data(#"""
        {
          "Items": [{
            "Id": "movie-1",
            "Name": "A Movie",
            "Type": "Movie",
            "Overview": "Movie summary",
            "ProductionYear": 2020,
            "RunTimeTicks": 72000000000,
            "CommunityRating": 7.8,
            "OfficialRating": "PG-13",
            "Taglines": ["One dream can change everything"],
            "Genres": ["Adventure", "Drama"],
            "ImageTags": { "Primary": "poster-tag" },
            "BackdropImageTags": ["backdrop-tag"],
            "MediaSources": [{
              "Id": "source-1",
              "Container": "mkv",
              "Bitrate": 8200000,
              "Width": 1920,
              "Height": 1080,
              "VideoCodec": "hevc",
              "AudioCodec": "aac",
              "MediaStreams": [
                { "Index": 0, "Type": "Video", "Codec": "hevc", "Width": 1920, "Height": 1080 },
                { "Index": 1, "Type": "Audio", "Codec": "aac", "Language": "English", "DisplayTitle": "English AAC Stereo", "IsDefault": true, "Channels": 2 },
                { "Index": 2, "Type": "Subtitle", "Codec": "srt", "Language": "English", "DisplayTitle": "English", "IsForced": false }
              ]
            }],
            "UserData": { "PlaybackPositionTicks": 1200000000, "Played": true }
          }],
          "TotalRecordCount": 1
        }
        """#.utf8))

        let item = try #require(response.items.first?.toMediaItem())
        #expect(item.ratingKey == "movie-1")
        #expect(item.title == "A Movie")
        #expect(item.type == "movie")
        #expect(item.summary == "Movie summary")
        #expect(item.year == 2020)
        #expect(item.duration == 7_200_000)
        #expect(item.viewOffset == 120_000)
        #expect(item.viewCount == 1)
        #expect(item.thumb == "jellyfin://item/movie-1/Primary?tag=poster-tag")
        #expect(item.art == "jellyfin://item/movie-1/Backdrop?tag=backdrop-tag")
        #expect(item.rating == 7.8)
        #expect(item.contentRating == "PG-13")
        #expect(item.tagline == "One dream can change everything")
        #expect(item.genres?.map(\.tag) == ["Adventure", "Drama"])
        let media = try #require(item.media?.first)
        #expect(media.container == "mkv")
        #expect(media.bitrate == 8200)
        #expect(media.width == 1920)
        #expect(media.height == 1080)
        #expect(media.videoCodec == "hevc")
        #expect(media.audioCodec == "aac")
        let part = try #require(media.part.first)
        #expect(part.container == "mkv")
        #expect(part.videoStreams.first?.codec == "hevc")
        #expect(part.audioStreams.first?.displayTitle == "English AAC Stereo")
        #expect(part.subtitleStreams.first?.displayTitle == "English")
    }

    @Test func mapsEpisodeHierarchyToMediaItem() throws {
        let dto = try JSONDecoder().decode(JellyfinBaseItemDto.self, from: Data(#"""
        {
          "Id": "episode-1",
          "Name": "Pilot",
          "Type": "Episode",
          "SeriesId": "series-1",
          "SeriesName": "A Show",
          "ParentId": "season-1",
          "ParentIndexNumber": 1,
          "IndexNumber": 2,
          "ImageTags": { "Primary": "episode-tag" }
        }
        """#.utf8))

        let item = try #require(dto.toMediaItem())
        #expect(item.type == "episode")
        #expect(item.grandparentRatingKey == "series-1")
        #expect(item.grandparentTitle == "A Show")
        #expect(item.parentRatingKey == "season-1")
        #expect(item.parentIndex == 1)
        #expect(item.index == 2)
    }
}
