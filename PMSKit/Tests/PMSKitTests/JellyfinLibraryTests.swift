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
        #expect(query["fields"]?.contains("Chapters") == true)
    }

    @Test func itemsRequestCarriesSearchTerm() throws {
        let request = try JellyfinLibrary.itemsRequest(server: server,
                                                       token: "token-abc",
                                                       identity: identity,
                                                       userId: "user-1",
                                                       recursive: true,
                                                       startIndex: 25,
                                                       limit: 50,
                                                       searchTerm: "pilot",
                                                       includeItemTypes: "Movie")
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.path == "/base/Items")
        #expect(query["recursive"] == "true")
        #expect(query["startIndex"] == "25")
        #expect(query["limit"] == "50")
        #expect(query["searchTerm"] == "pilot")
        #expect(query["includeItemTypes"] == "Movie")
    }

    @Test func resumeItemsRequestTargetsContinueWatching() throws {
        let request = try JellyfinLibrary.resumeItemsRequest(server: server,
                                                             token: "token-abc",
                                                             identity: identity,
                                                             userId: "user-1",
                                                             parentId: "view-1",
                                                             limit: 12)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.path == "/base/UserItems/Resume")
        #expect(query["userId"] == "user-1")
        #expect(query["parentId"] == "view-1")
        #expect(query["limit"] == "12")
        #expect(query["includeItemTypes"] == "Movie,Episode")
        #expect(query["enableUserData"] == "true")
        #expect(query["excludeActiveSessions"] == "false")
    }

    @Test func nextUpRequestTargetsShowsNextUp() throws {
        let request = try JellyfinLibrary.nextUpRequest(server: server,
                                                        token: "token-abc",
                                                        identity: identity,
                                                        userId: "user-1",
                                                        limit: 10)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.path == "/base/Shows/NextUp")
        #expect(query["userId"] == "user-1")
        #expect(query["limit"] == "10")
        #expect(query["enableResumable"] == "true")
        #expect(query["enableUserData"] == "true")
    }

    @Test func latestItemsRequestTargetsLatestMedia() throws {
        let request = try JellyfinLibrary.latestItemsRequest(server: server,
                                                             token: "token-abc",
                                                             identity: identity,
                                                             userId: "user-1",
                                                             parentId: "view-1",
                                                             includeItemTypes: "Movie",
                                                             limit: 8)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.path == "/base/Items/Latest")
        #expect(query["userId"] == "user-1")
        #expect(query["parentId"] == "view-1")
        #expect(query["includeItemTypes"] == "Movie")
        #expect(query["groupItems"] == "false")
        #expect(query["enableUserData"] == "true")
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

    @Test func markPlayedUsesUserDataEndpoint() throws {
        let played = try JellyfinLibrary.markPlayedRequest(server: server,
                                                           token: "token-abc",
                                                           identity: identity,
                                                           userId: "user-1",
                                                           itemId: "item-1",
                                                           played: true)
        let unplayed = try JellyfinLibrary.markPlayedRequest(server: server,
                                                             token: "token-abc",
                                                             identity: identity,
                                                             userId: "user-1",
                                                             itemId: "item-1",
                                                             played: false)

        #expect(played.httpMethod == "POST")
        #expect(unplayed.httpMethod == "DELETE")
        #expect(played.url?.path == "/base/Users/user-1/PlayedItems/item-1")
        #expect(played.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"token-abc\"") == true)
    }

    @Test func downloadRequestUsesHeadersNotURLToken() throws {
        let request = try JellyfinLibrary.downloadRequest(server: server,
                                                          token: "token-abc",
                                                          identity: identity,
                                                          itemId: "item-1",
                                                          mediaSourceId: "source-1",
                                                          container: "mp4")
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(request.httpMethod == nil || request.httpMethod == "GET")
        #expect(components.path == "/base/Videos/item-1/stream.mp4")
        #expect(query["api_key"] == nil)
        #expect(query["static"] == "true")
        #expect(query["mediaSourceId"] == "source-1")
        #expect(request.value(forHTTPHeaderField: "Accept") == "*/*")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"token-abc\"") == true)
    }

    @Test func transcodedDownloadRequestUsesHeaderAuthAndMp4Stream() throws {
        let request = try JellyfinLibrary.transcodedDownloadRequest(server: server,
                                                                    token: "token-abc",
                                                                    identity: identity,
                                                                    itemId: "item-1",
                                                                    mediaSourceId: "source-1",
                                                                    maxVideoBitrate: 4_000_000,
                                                                    maxWidth: 1280,
                                                                    maxHeight: 720)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(request.httpMethod == nil || request.httpMethod == "GET")
        #expect(components.path == "/base/Videos/item-1/stream.mp4")
        #expect(query["api_key"] == nil)
        #expect(query["static"] == "false")
        #expect(query["container"] == "mp4")
        #expect(query["videoCodec"] == "h264")
        #expect(query["audioCodec"] == "aac")
        #expect(query["videoBitRate"] == "4000000")
        #expect(query["maxWidth"] == "1280")
        #expect(query["maxHeight"] == "720")
        #expect(query["allowVideoStreamCopy"] == "false")
        #expect(request.value(forHTTPHeaderField: "Accept") == "*/*")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"token-abc\"") == true)
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
            "Chapters": [
              { "StartPositionTicks": 0, "Name": "Chapter 01" },
              { "StartPositionTicks": 3003420000, "Name": "Chapter 02" }
            ],
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
        #expect(item.chapters?.map(\.tag) == ["Chapter 01", "Chapter 02"])
        #expect(item.chapters?[1].startTimeOffset == 300_342)
        let media = try #require(item.media?.first)
        #expect(media.container == "mkv")
        #expect(media.bitrate == 8200)
        #expect(media.width == 1920)
        #expect(media.height == 1080)
        #expect(media.videoCodec == "hevc")
        #expect(media.audioCodec == "aac")
        let part = try #require(media.part.first)
        #expect(part.key == "jellyfin://item/movie-1/media/source-1")
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
          "CommunityRating": 1.0,
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
        #expect(item.rating == nil)
        #expect(item.grandparentRatingKey == "series-1")
        #expect(item.grandparentTitle == "A Show")
        #expect(item.parentRatingKey == "season-1")
        #expect(item.parentIndex == 1)
        #expect(item.index == 2)
    }
}
